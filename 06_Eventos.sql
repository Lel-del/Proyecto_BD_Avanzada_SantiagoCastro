USE ecommerce;
SET time_zone='+00:00';
-- Excepcion de ubicacion de tabla pedida por el enunciado.
CREATE TABLE reporte_ventas_semanales (
 semana DATE NOT NULL,id_sucursal INT NOT NULL,pedidos INT NOT NULL,ingresos DECIMAL(18,2) NOT NULL,
 PRIMARY KEY(semana,id_sucursal)
);
-- Deshabilitados durante instalacion; 08 activa tras validar todos los objetos.
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
 INSERT INTO reabastecimiento(id_sucursal,id_producto,stock,sugerido,fecha)
 SELECT i.id_sucursal,i.id_producto,i.stock,GREATEST(i.stock_minimo*2-i.stock,1),UTC_DATE() FROM inventario_sucursal i JOIN productos p USING(id_producto) WHERE p.activo AND i.stock<i.stock_minimo;
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
 INSERT INTO inventario_diario(fecha,id_sucursal,id_producto,stock,costo,id_categoria_historica)
 SELECT UTC_DATE(),i.id_sucursal,i.id_producto,i.stock,p.costo,p.id_categoria FROM inventario_sucursal i JOIN productos p USING(id_producto) ON DUPLICATE KEY UPDATE stock=VALUES(stock),costo=VALUES(costo),id_categoria_historica=VALUES(id_categoria_historica);
 COMMIT;
END$$
-- 10. Alerta, no modifica silenciosamente operaciones financieras.
CREATE EVENT evt_check_data_consistency_nightly ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE+INTERVAL 1 DAY+INTERVAL 3 HOUR) DISABLE
DO BEGIN
 -- Evidencia recibida por el servidor, no certificacion de exito.
 -- Se incluyen candidatos con comentarios; puede haber falsos positivos en literales SQL.
 INSERT IGNORE INTO accesos_fallidos(fecha,conexion,mensaje,huella)
 SELECT g.event_time,g.thread_id,CONVERT(g.argument USING utf8mb4),
 SHA2(CONCAT_WS('|',g.event_time,g.thread_id,g.command_type,g.argument),256)
 FROM mysql.general_log g
 WHERE g.command_type='Connect' AND CONVERT(g.argument USING utf8mb4) LIKE 'Access denied%'
 AND NOT EXISTS(SELECT 1 FROM accesos_fallidos_historico h WHERE h.huella=SHA2(CONCAT_WS('|',g.event_time,g.thread_id,g.command_type,g.argument),256));
 INSERT IGNORE INTO cambios_permisos(cuenta,descripcion,fecha,huella,origen)
 SELECT LEFT(g.user_host,288),CONVERT(g.argument USING utf8mb4),g.event_time,
 SHA2(CONCAT_WS('|',g.event_time,g.thread_id,g.command_type,g.argument),256),'mysql.general_log'
 FROM mysql.general_log g
 WHERE g.command_type IN ('Query','Execute')
 AND REGEXP_LIKE(CONVERT(g.argument USING utf8mb4),'(^|[^[:alnum:]_])(GRANT|REVOKE)[[:space:]/]','i')
 AND NOT EXISTS(SELECT 1 FROM cambios_permisos_historico h WHERE h.huella=SHA2(CONCAT_WS('|',g.event_time,g.thread_id,g.command_type,g.argument),256));
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
-- 13. Copia logica interna consistente; no es un respaldo externo contra perdida del servidor.
CREATE EVENT evt_backup_critical_tables_daily ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE+INTERVAL 1 DAY+INTERVAL 2 HOUR) DISABLE
DO BEGIN
 DECLARE v_copia BIGINT; DECLARE v_datos JSON; DECLARE v_filas BIGINT DEFAULT 0;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
 START TRANSACTION WITH CONSISTENT SNAPSHOT;
 INSERT INTO copias_logicas(estado) VALUES('En curso');
 SET v_copia=LAST_INSERT_ID();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_sucursal',`id_sucursal`,'nombre',`nombre`)),JSON_ARRAY()) INTO v_datos FROM sucursales;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'sucursales',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_categoria',`id_categoria`,'nombre',`nombre`,'descripcion',`descripcion`,'id_padre',`id_padre`,'producto_count',`producto_count`)),JSON_ARRAY()) INTO v_datos FROM categorias;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'categorias',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_proveedor',`id_proveedor`,'nombre',`nombre`,'email_contacto',`email_contacto`,'telefono_contacto',`telefono_contacto`)),JSON_ARRAY()) INTO v_datos FROM proveedores;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'proveedores',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_producto',`id_producto`,'nombre',`nombre`,'descripcion',`descripcion`,'precio',`precio`,'costo',`costo`,'sku',`sku`,'fecha_creacion',`fecha_creacion`,'fecha_modificacion',`fecha_modificacion`,'activo',`activo`,'eliminado_en',`eliminado_en`,'id_categoria',`id_categoria`,'id_proveedor',`id_proveedor`,'peso_kg',`peso_kg`)),JSON_ARRAY()) INTO v_datos FROM productos;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'productos',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_sucursal',`id_sucursal`,'id_producto',`id_producto`,'stock',`stock`,'stock_minimo',`stock_minimo`,'ubicacion',`ubicacion`)),JSON_ARRAY()) INTO v_datos FROM inventario_sucursal;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'inventario_sucursal',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_cliente',`id_cliente`,'nombre',`nombre`,'apellido',`apellido`,'email',`email`,'contrasena_hash',`contrasena_hash`,'direccion_envio',`direccion_envio`,'ciudad',`ciudad`,'region',`region`,'fecha_nacimiento',`fecha_nacimiento`,'fecha_registro',`fecha_registro`,'total_gastado',`total_gastado`,'ultima_compra',`ultima_compra`,'nivel_lealtad',`nivel_lealtad`,'activo',`activo`,'eliminado_en',`eliminado_en`,'id_referente',`id_referente`)),JSON_ARRAY()) INTO v_datos FROM clientes;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'clientes',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_venta',`id_venta`,'id_cliente',`id_cliente`,'id_sucursal',`id_sucursal`,'fecha_venta',`fecha_venta`,'estado',`estado`,'total',`total`,'direccion_envio',`direccion_envio`,'ciudad_envio',`ciudad_envio`,'region_envio',`region_envio`,'eliminado_en',`eliminado_en`)),JSON_ARRAY()) INTO v_datos FROM ventas;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'ventas',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_detalle',`id_detalle`,'id_venta',`id_venta`,'id_producto',`id_producto`,'cantidad',`cantidad`,'precio_unitario_congelado',`precio_unitario_congelado`,'costo_unitario_congelado',`costo_unitario_congelado`,'id_categoria_historica',`id_categoria_historica`,'categoria_historica',`categoria_historica`,'id_proveedor_historico',`id_proveedor_historico`,'proveedor_historico',`proveedor_historico`)),JSON_ARRAY()) INTO v_datos FROM detalle_ventas;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'detalle_ventas',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_pago',`id_pago`,'id_venta',`id_venta`,'referencia',`referencia`,'monto',`monto`,'resultado',`resultado`,'fecha',`fecha`)),JSON_ARRAY()) INTO v_datos FROM pagos;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'pagos',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_devolucion',`id_devolucion`,'id_detalle',`id_detalle`,'cantidad',`cantidad`,'credito',`credito`,'motivo',`motivo`,'fecha',`fecha`)),JSON_ARRAY()) INTO v_datos FROM devoluciones;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'devoluciones',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('usuario',`usuario`,'id_sucursal',`id_sucursal`)),JSON_ARRAY()) INTO v_datos FROM usuarios_sucursal;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'usuarios_sucursal',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_movimiento',`id_movimiento`,'id_producto',`id_producto`,'id_sucursal',`id_sucursal`,'diferencia',`diferencia`,'motivo',`motivo`,'usuario',`usuario`,'fecha',`fecha`)),JSON_ARRAY()) INTO v_datos FROM movimientos_stock;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'movimientos_stock',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('fecha',`fecha`,'id_sucursal',`id_sucursal`,'id_producto',`id_producto`,'stock',`stock`,'costo',`costo`,'id_categoria_historica',`id_categoria_historica`)),JSON_ARRAY()) INTO v_datos FROM inventario_diario;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'inventario_diario',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_notificacion',`id_notificacion`,'tipo',`tipo`,'entidad_id',`entidad_id`,'contenido',`contenido`,'fecha',`fecha`,'enviado',`enviado`)),JSON_ARRAY()) INTO v_datos FROM notificaciones;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'notificaciones',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_archivo',`id_archivo`,'id_venta',`id_venta`,'encabezado',`encabezado`,'detalles',`detalles`,'fecha_archivo',`fecha_archivo`)),JSON_ARRAY()) INTO v_datos FROM ventas_archivo;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'ventas_archivo',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_log',`id_log`,'tipo',`tipo`,'entidad_id',`entidad_id`,'datos',`datos`,'usuario',`usuario`,'fecha',`fecha`)),JSON_ARRAY()) INTO v_datos FROM auditoria;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'auditoria',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_log',`id_log`,'tipo',`tipo`,'entidad_id',`entidad_id`,'datos',`datos`,'usuario',`usuario`,'fecha',`fecha`)),JSON_ARRAY()) INTO v_datos FROM auditoria_historica;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'auditoria_historica',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_log',`id_log`,'id_producto',`id_producto`,'precio_anterior',`precio_anterior`,'precio_nuevo',`precio_nuevo`,'usuario',`usuario`,'fecha',`fecha`)),JSON_ARRAY()) INTO v_datos FROM log_cambios_precio;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'log_cambios_precio',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_log',`id_log`,'id_producto',`id_producto`,'precio_anterior',`precio_anterior`,'precio_nuevo',`precio_nuevo`,'usuario',`usuario`,'fecha',`fecha`)),JSON_ARRAY()) INTO v_datos FROM log_cambios_precio_historico;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'log_cambios_precio_historico',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_cambio',`id_cambio`,'cuenta',`cuenta`,'descripcion',`descripcion`,'fecha',`fecha`,'huella',`huella`,'origen',`origen`)),JSON_ARRAY()) INTO v_datos FROM cambios_permisos;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'cambios_permisos',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_acceso',`id_acceso`,'fecha',`fecha`,'conexion',`conexion`,'mensaje',`mensaje`,'huella',`huella`)),JSON_ARRAY()) INTO v_datos FROM accesos_fallidos;
 INSERT INTO copias_filas(id_copia,tabla,clave,datos)
 SELECT v_copia,'accesos_fallidos',CAST(j.orden AS CHAR),j.datos FROM JSON_TABLE(v_datos,'$[*]' COLUMNS(orden FOR ORDINALITY,datos JSON PATH '$')) j;
 SET v_filas=v_filas+ROW_COUNT();
 UPDATE copias_logicas SET estado='Completa',filas=v_filas WHERE id_copia=v_copia;
 COMMIT;
END$$
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
 INSERT INTO rendimiento_proveedores SELECT v_mes,d.id_proveedor_historico,SUM(d.cantidad),SUM(d.cantidad*d.precio_unitario_congelado) FROM ventas v JOIN detalle_ventas d USING(id_venta) WHERE v.fecha_venta>=v_mes AND v.fecha_venta<v_mes+INTERVAL 1 MONTH AND v.estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY d.id_proveedor_historico
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
 WHERE p.eliminado_en<UTC_TIMESTAMP()-INTERVAL 30 DAY AND NOT EXISTS(SELECT 1 FROM detalle_ventas d WHERE d.id_producto=p.id_producto)
 AND NOT EXISTS(SELECT 1 FROM inventario_sucursal i WHERE i.id_producto=p.id_producto AND i.stock<>0)
 AND NOT EXISTS(SELECT 1 FROM inventario_diario_legacy l WHERE l.id_producto=p.id_producto)
 AND NOT EXISTS(SELECT 1 FROM inventario_diario i WHERE i.id_producto=p.id_producto)
 AND NOT EXISTS(SELECT 1 FROM movimientos_stock m WHERE m.id_producto=p.id_producto);
 DELETE v FROM visitas_producto v JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=v.id_producto;
 DELETE d FROM detalle_carrito d JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=d.id_producto;
 DELETE x FROM promociones x JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=x.id_producto;
 DELETE x FROM resenas x JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=x.id_producto;
 DELETE x FROM reabastecimiento x JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=x.id_producto;
 DELETE x FROM rankings_productos x JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=x.id_producto;
 DELETE i FROM inventario_sucursal i JOIN registros_purgados r ON r.entidad='productos' AND r.entidad_id=i.id_producto;
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
-- 08 habilita los 20 eventos al completar todas sus dependencias.
