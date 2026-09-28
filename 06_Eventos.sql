USE ecommerce;
SET time_zone='+00:00';
-- Excepcion de ubicacion de tabla pedida por el enunciado.
CREATE TABLE reporte_ventas_semanales (
 semana DATE NOT NULL,id_sucursal INT NOT NULL,pedidos INT NOT NULL,ingresos DECIMAL(18,2) NOT NULL,
 PRIMARY KEY(semana,id_sucursal)
);
-- Persistente tras reiniciar; los eventos se habilitan al finalizar 07.
SET PERSIST event_scheduler=ON;
DELIMITER $$
-- 1. Ultimos siete dias completos, conservando un reporte por fecha de inicio.
CREATE EVENT evt_generate_weekly_sales_report ON SCHEDULE EVERY 1 WEEK STARTS CURRENT_TIMESTAMP+INTERVAL 1 WEEK DISABLE
DO BEGIN
 INSERT INTO reporte_ventas_semanales SELECT UTC_DATE()-INTERVAL 7 DAY,id_sucursal,COUNT(*),SUM(total) FROM ventas
 WHERE fecha_venta>=UTC_DATE()-INTERVAL 7 DAY AND fecha_venta<UTC_DATE() AND estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY id_sucursal
 ON DUPLICATE KEY UPDATE pedidos=VALUES(pedidos),ingresos=VALUES(ingresos);
END$$
-- 2. Limpia staging persistente; no puede acceder a TEMPORARY TABLES de otras sesiones.
CREATE EVENT evt_cleanup_temp_tables_daily ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP+INTERVAL 1 DAY DISABLE
DO DELETE FROM staging_importacion WHERE creado_en<UTC_TIMESTAMP()-INTERVAL 1 DAY$$
-- 3. INSERT y DELETE atomicos: no se pierden logs si hay un error.
CREATE EVENT evt_archive_old_logs_monthly ON SCHEDULE EVERY 1 MONTH STARTS CURRENT_TIMESTAMP+INTERVAL 1 MONTH DISABLE
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 INSERT INTO auditoria_historica SELECT * FROM auditoria WHERE fecha<UTC_TIMESTAMP()-INTERVAL 6 MONTH;
 DELETE FROM auditoria WHERE fecha<UTC_TIMESTAMP()-INTERVAL 6 MONTH;
 INSERT INTO log_cambios_precio_historico SELECT * FROM log_cambios_precio WHERE fecha<UTC_TIMESTAMP()-INTERVAL 6 MONTH;
 DELETE FROM log_cambios_precio WHERE fecha<UTC_TIMESTAMP()-INTERVAL 6 MONTH;
 INSERT INTO accesos_fallidos_historico SELECT * FROM accesos_fallidos WHERE fecha<UTC_TIMESTAMP()-INTERVAL 6 MONTH;
 DELETE FROM accesos_fallidos WHERE fecha<UTC_TIMESTAMP()-INTERVAL 6 MONTH;
 INSERT INTO cambios_permisos_historico SELECT * FROM cambios_permisos WHERE fecha<UTC_TIMESTAMP()-INTERVAL 6 MONTH;
 DELETE FROM cambios_permisos WHERE fecha<UTC_TIMESTAMP()-INTERVAL 6 MONTH;
 COMMIT;
END$$
-- 4.
CREATE EVENT evt_deactivate_expired_promotions_hourly ON SCHEDULE EVERY 1 HOUR STARTS CURRENT_TIMESTAMP+INTERVAL 1 HOUR DISABLE
DO UPDATE promociones SET activo=FALSE WHERE activo AND fin<=UTC_TIMESTAMP()$$
-- 5. No usa funcion que lea la misma tabla que actualiza.
CREATE EVENT evt_recalculate_customer_loyalty_tiers_nightly ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE+INTERVAL 1 DAY+INTERVAL 2 HOUR) DISABLE
DO UPDATE clientes SET nivel_lealtad=CASE WHEN total_gastado>=5000 THEN 'Oro' WHEN total_gastado>=1000 THEN 'Plata' ELSE 'Bronce' END$$
-- 6.
CREATE EVENT evt_generate_reorder_list_daily ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP+INTERVAL 1 DAY DISABLE
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE FROM reabastecimiento;
 INSERT INTO reabastecimiento SELECT id_producto,stock,GREATEST(stock_minimo*2-stock,1),UTC_DATE() FROM productos WHERE activo AND stock<stock_minimo;
 COMMIT;
END$$
-- 7. Reconstruccion real InnoDB (recreate + analyze) de las tablas de mayor uso.
CREATE EVENT evt_rebuild_indexes_weekly ON SCHEDULE EVERY 1 WEEK STARTS CURRENT_TIMESTAMP+INTERVAL 1 WEEK DISABLE
DO BEGIN
 OPTIMIZE TABLE productos,ventas,detalle_ventas;
 INSERT INTO auditoria(tipo,datos,usuario) VALUES('Indices reconstruidos',JSON_OBJECT('tablas','productos,ventas,detalle_ventas'),USER());
END$$
-- 8. Sin actividad por mas de un anio, no suspende clientes con pedidos en curso.
CREATE EVENT evt_suspend_inactive_accounts_quarterly ON SCHEDULE EVERY 3 MONTH STARTS CURRENT_TIMESTAMP+INTERVAL 3 MONTH DISABLE
DO UPDATE clientes c SET activo=FALSE WHERE activo AND COALESCE(ultima_compra,fecha_registro)<UTC_TIMESTAMP()-INTERVAL 1 YEAR
 AND NOT EXISTS(SELECT 1 FROM ventas v WHERE v.id_cliente=c.id_cliente AND v.estado NOT IN ('Entregado','Cancelado'))$$
-- 9. Resume el dia anterior y conserva instantanea de stock del momento de ejecucion.
CREATE EVENT evt_aggregate_daily_sales_data ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE+INTERVAL 1 DAY+INTERVAL 10 MINUTE) DISABLE
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE FROM resumen_ventas_diarias WHERE fecha=UTC_DATE()-INTERVAL 1 DAY;
 INSERT INTO resumen_ventas_diarias SELECT DATE(fecha_venta),id_sucursal,COUNT(*),SUM(total) FROM ventas WHERE fecha_venta>=UTC_DATE()-INTERVAL 1 DAY AND fecha_venta<UTC_DATE() AND estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY DATE(fecha_venta),id_sucursal;
 INSERT INTO inventario_diario SELECT UTC_DATE(),id_producto,stock,costo FROM productos ON DUPLICATE KEY UPDATE stock=VALUES(stock),costo=VALUES(costo);
 COMMIT;
END$$
-- 10. Alerta, no modifica silenciosamente operaciones financieras.
CREATE EVENT evt_check_data_consistency_nightly ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE+INTERVAL 1 DAY+INTERVAL 3 HOUR) DISABLE
DO BEGIN
 INSERT INTO alertas(tipo,entidad_id,mensaje) SELECT 'Inconsistencia venta',v.id_venta,'Venta vacia o total distinto al detalle' FROM ventas v LEFT JOIN detalle_ventas d USING(id_venta) GROUP BY v.id_venta,v.total HAVING COUNT(d.id_detalle)=0 OR v.total<>COALESCE(SUM(d.cantidad*d.precio_unitario_congelado),0);
 INSERT INTO alertas(tipo,entidad_id,mensaje) SELECT 'Contador categoria',c.id_categoria,'Contador distinto a productos actuales' FROM categorias c WHERE c.producto_count<>(SELECT COUNT(*) FROM productos p WHERE p.id_categoria=c.id_categoria);
END$$
-- 11. Genera cupon/lista, no envia correos reales. Un cupon por persona/anio.
CREATE EVENT evt_send_birthday_greetings_daily ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP+INTERVAL 1 DAY DISABLE
DO INSERT IGNORE INTO cupones_cumpleanos SELECT id_cliente,YEAR(UTC_DATE()),CONCAT('CUMPLE-',id_cliente,'-',YEAR(UTC_DATE())) FROM clientes WHERE activo AND MONTH(fecha_nacimiento)=MONTH(UTC_DATE()) AND DAY(fecha_nacimiento)=DAY(UTC_DATE())$$
-- 12.
CREATE EVENT evt_update_product_rankings_hourly ON SCHEDULE EVERY 1 HOUR STARTS CURRENT_TIMESTAMP+INTERVAL 1 HOUR DISABLE
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE FROM rankings_productos;
 INSERT INTO rankings_productos SELECT p.id_producto,ROW_NUMBER() OVER(ORDER BY COALESCE(SUM(IF(v.estado IN ('Pagado','Procesando','Enviado','Entregado'),d.cantidad*d.precio_unitario_congelado,0)),0) DESC,p.id_producto),COALESCE(SUM(IF(v.estado IN ('Pagado','Procesando','Enviado','Entregado'),d.cantidad*d.precio_unitario_congelado,0)),0),UTC_TIMESTAMP() FROM productos p LEFT JOIN detalle_ventas d USING(id_producto) LEFT JOIN ventas v USING(id_venta) GROUP BY p.id_producto;
 COMMIT;
END$$
-- 13. El servicio incluido consume la solicitud y ejecuta mysqldump, SHA-256 y manifiesto.
CREATE EVENT evt_backup_critical_tables_daily ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE+INTERVAL 1 DAY+INTERVAL 2 HOUR) DISABLE
DO INSERT IGNORE INTO trabajos_externos(tipo,fecha,detalle) VALUES('Backup logico',UTC_DATE(),'Respaldo SQL completo procesado por servicio_operaciones.py')$$
-- 14. No hay reserva de stock en carritos, solo al crear ventas.
CREATE EVENT evt_clear_abandoned_carts_daily ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP+INTERVAL 1 DAY DISABLE
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE d FROM detalle_carrito d JOIN carritos c USING(id_carrito) WHERE c.estado='Abierto' AND c.actualizado_en<UTC_TIMESTAMP()-INTERVAL 72 HOUR;
 UPDATE carritos SET estado='Vaciado' WHERE estado='Abierto' AND actualizado_en<UTC_TIMESTAMP()-INTERVAL 72 HOUR;
 COMMIT;
END$$
-- 15. Mes calendario anterior completo.
CREATE EVENT evt_calculate_monthly_kpis ON SCHEDULE EVERY 1 MONTH STARTS (LAST_DAY(CURRENT_DATE)+INTERVAL 1 DAY+INTERVAL 1 HOUR) DISABLE
DO BEGIN
 DECLARE v_mes DATE;
 SET v_mes=CAST(DATE_FORMAT(UTC_DATE()-INTERVAL 1 MONTH,'%Y-%m-01') AS DATE);
 INSERT INTO kpis_mensuales SELECT v_mes,COUNT(*),COALESCE(SUM(total),0),AVG(total),COUNT(DISTINCT id_cliente) FROM ventas WHERE fecha_venta>=v_mes AND fecha_venta<v_mes+INTERVAL 1 MONTH AND estado IN ('Pagado','Procesando','Enviado','Entregado')
 ON DUPLICATE KEY UPDATE pedidos=VALUES(pedidos),ingresos=VALUES(ingresos),ticket_promedio=VALUES(ticket_promedio),clientes=VALUES(clientes);
END$$
-- 16. MySQL no tiene vistas materializadas nativas; esta tabla resumen cumple esa funcion.
CREATE EVENT evt_refresh_materialized_views_nightly ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE+INTERVAL 1 DAY+INTERVAL 4 HOUR) DISABLE
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE FROM resumen_ventas_diarias;
 INSERT INTO resumen_ventas_diarias SELECT DATE(fecha_venta),id_sucursal,COUNT(*),SUM(total) FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY DATE(fecha_venta),id_sucursal;
 COMMIT;
END$$
-- 17. Aproximacion de information_schema, no bytes exactos en disco.
CREATE EVENT evt_log_database_size_weekly ON SCHEDULE EVERY 1 WEEK STARTS CURRENT_TIMESTAMP+INTERVAL 1 WEEK DISABLE
DO INSERT INTO tamano_bd(bytes_aproximados) SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema='ecommerce'$$
-- 18. Heuristica explicita, no decision automatica de fraude.
CREATE EVENT evt_detect_fraudulent_activity_hourly ON SCHEDULE EVERY 1 HOUR STARTS CURRENT_TIMESTAMP+INTERVAL 1 HOUR DISABLE
DO INSERT INTO alertas(tipo,entidad_id,mensaje) SELECT 'Revisar pagos',v.id_cliente,'Al menos 3 pagos fallidos en una hora' FROM pagos p JOIN ventas v USING(id_venta) WHERE p.resultado='Fallido' AND p.fecha>=UTC_TIMESTAMP()-INTERVAL 1 HOUR GROUP BY v.id_cliente HAVING COUNT(*)>=3$$
-- 19.
CREATE EVENT evt_generate_supplier_performance_report_monthly ON SCHEDULE EVERY 1 MONTH STARTS (LAST_DAY(CURRENT_DATE)+INTERVAL 1 DAY+INTERVAL 2 HOUR) DISABLE
DO BEGIN
 DECLARE v_mes DATE;
 SET v_mes=CAST(DATE_FORMAT(UTC_DATE()-INTERVAL 1 MONTH,'%Y-%m-01') AS DATE);
 INSERT INTO rendimiento_proveedores SELECT v_mes,p.id_proveedor,SUM(d.cantidad),SUM(d.cantidad*d.precio_unitario_congelado) FROM ventas v JOIN detalle_ventas d USING(id_venta) JOIN productos p USING(id_producto) WHERE v.fecha_venta>=v_mes AND v.fecha_venta<v_mes+INTERVAL 1 MONTH AND v.estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY p.id_proveedor
 ON DUPLICATE KEY UPDATE unidades=VALUES(unidades),ingresos=VALUES(ingresos);
END$$
-- 20. Solo canceladas sin pagos ni carritos vinculados. Trigger archiva antes de borrar.
CREATE EVENT evt_purge_soft_deleted_records_weekly ON SCHEDULE EVERY 1 WEEK STARTS CURRENT_TIMESTAMP+INTERVAL 1 WEEK DISABLE
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE FROM ventas WHERE estado='Cancelado' AND eliminado_en<UTC_TIMESTAMP()-INTERVAL 30 DAY
 AND NOT EXISTS(SELECT 1 FROM pagos p WHERE p.id_venta=ventas.id_venta)
 AND NOT EXISTS(SELECT 1 FROM carritos c WHERE c.id_venta=ventas.id_venta);
 -- Con FK historica se conserva la identidad; los datos personales ya se anonimizan.
 INSERT INTO registros_purgados(entidad,entidad_id,datos)
 SELECT 'productos',p.id_producto,JSON_OBJECT('nombre',p.nombre,'sku',p.sku) FROM productos p
 WHERE p.eliminado_en<UTC_TIMESTAMP()-INTERVAL 30 DAY AND NOT EXISTS(SELECT 1 FROM detalle_ventas d WHERE d.id_producto=p.id_producto);
 DELETE i FROM inventario_diario i JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=i.id_producto;
 DELETE m FROM movimientos_stock m JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=m.id_producto;
 DELETE v FROM visitas_producto v JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=v.id_producto;
 DELETE d FROM detalle_carrito d JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=d.id_producto;
 DELETE x FROM promociones x JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=x.id_producto;
 DELETE x FROM resenas x JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=x.id_producto;
 DELETE x FROM reabastecimiento x JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=x.id_producto;
 DELETE x FROM rankings_productos x JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=x.id_producto;
 DELETE p FROM productos p JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=p.id_producto;
 INSERT INTO registros_purgados(entidad,entidad_id,datos)
 SELECT 'clientes',c.id_cliente,JSON_OBJECT('anonimizado',TRUE) FROM clientes c WHERE c.eliminado_en<UTC_TIMESTAMP()-INTERVAL 30 DAY
 AND NOT EXISTS(SELECT 1 FROM ventas v WHERE v.id_cliente=c.id_cliente);
 UPDATE clientes c JOIN registros_purgados r ON r.entidad='clientes' AND r.entidad_id=c.id_referente SET c.id_referente=NULL;
 UPDATE visitas_producto v JOIN registros_purgados r ON r.entidad='clientes' AND r.entidad_id=v.id_cliente SET v.id_cliente=NULL;
 DELETE d FROM detalle_carrito d JOIN carritos c USING(id_carrito) JOIN registros_purgados r ON r.entidad='clientes' AND r.entidad_id=c.id_cliente;
 DELETE c FROM carritos c JOIN registros_purgados r ON r.entidad='clientes' AND r.entidad_id=c.id_cliente;
 DELETE c FROM cupones_cumpleanos c JOIN registros_purgados r ON r.entidad='clientes' AND r.entidad_id=c.id_cliente;
 DELETE c FROM resenas c JOIN registros_purgados r ON r.entidad='clientes' AND r.entidad_id=c.id_cliente;
 DELETE c FROM clientes c JOIN registros_purgados r ON r.entidad='clientes' AND r.entidad_id=c.id_cliente;
 COMMIT;
END$$
DELIMITER ;
-- 07 habilita los 20 eventos al completar todas sus dependencias.
