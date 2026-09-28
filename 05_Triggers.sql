USE ecommerce;
-- Excepcion explicita del enunciado: esta tabla se crea en 05.
CREATE TABLE log_cambios_precio (
 id_log BIGINT PRIMARY KEY AUTO_INCREMENT, id_producto INT NOT NULL,
 precio_anterior DECIMAL(12,2) NOT NULL, precio_nuevo DECIMAL(12,2) NOT NULL,
 usuario VARCHAR(288) NOT NULL, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
DELIMITER $$
-- 1.
CREATE TRIGGER trg_audit_precio_producto_after_update AFTER UPDATE ON productos FOR EACH ROW
BEGIN
 IF NEW.precio<>OLD.precio THEN INSERT INTO log_cambios_precio(id_producto,precio_anterior,precio_nuevo,usuario) VALUES(NEW.id_producto,OLD.precio,NEW.precio,USER()); END IF;
END$$
-- 2. Se reserva inventario al insertar LINEAS, no un encabezado sin productos.
CREATE TRIGGER trg_check_stock_before_insert_venta BEFORE INSERT ON detalle_ventas FOR EACH ROW
BEGIN
 DECLARE v_estado VARCHAR(30); DECLARE v_stock INT; DECLARE v_activo BOOLEAN;
 DECLARE v_precio DECIMAL(12,2); DECLARE v_costo DECIMAL(12,2);
 SELECT estado INTO v_estado FROM ventas WHERE id_venta=NEW.id_venta FOR UPDATE;
 IF v_estado IS NULL OR v_estado<>'Pendiente de Pago' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Solo se agregan lineas a pedidos pendientes'; END IF;
 SELECT stock,activo,precio,costo INTO v_stock,v_activo,v_precio,v_costo FROM productos WHERE id_producto=NEW.id_producto FOR UPDATE;
 IF v_stock IS NULL OR NOT v_activo OR NEW.cantidad IS NULL OR NEW.cantidad<=0 OR NEW.cantidad>v_stock THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Producto inactivo o stock insuficiente'; END IF;
 SET NEW.precio_unitario_congelado=v_precio;
 SET NEW.costo_unitario_congelado=v_costo;
END$$
-- 3. El procedimiento NO vuelve a descontar stock.
CREATE TRIGGER trg_update_stock_after_insert_venta AFTER INSERT ON detalle_ventas FOR EACH ROW
BEGIN
 UPDATE productos SET stock=stock-NEW.cantidad WHERE id_producto=NEW.id_producto;
 UPDATE ventas SET total=total+NEW.cantidad*NEW.precio_unitario_congelado WHERE id_venta=NEW.id_venta;
 INSERT INTO movimientos_stock(id_producto,diferencia,motivo,usuario) VALUES(NEW.id_producto,-NEW.cantidad,CONCAT('Reserva venta ',NEW.id_venta),USER());
END$$
-- 4. La FK tambien protege esta regla.
CREATE TRIGGER trg_prevent_delete_categoria_with_products BEFORE DELETE ON categorias FOR EACH ROW
BEGIN
 IF EXISTS(SELECT 1 FROM productos WHERE id_categoria=OLD.id_categoria) OR OLD.nombre='General' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Categoria protegida o con productos'; END IF;
END$$
-- 5.
CREATE TRIGGER trg_log_new_customer_after_insert AFTER INSERT ON clientes FOR EACH ROW
BEGIN INSERT INTO auditoria(tipo,entidad_id,datos,usuario) VALUES('Cliente creado',NEW.id_cliente,JSON_OBJECT('id',NEW.id_cliente),USER()); END$$
-- 6. Gasto pagado neto; cancelar restituye la reserva una sola vez.
CREATE TRIGGER trg_update_total_gastado_cliente AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
 DECLARE v_antes DECIMAL(16,2); DECLARE v_despues DECIMAL(16,2);
 SET v_antes=IF(OLD.estado IN ('Pagado','Procesando','Enviado','Entregado'),OLD.total,0);
 SET v_despues=IF(NEW.estado IN ('Pagado','Procesando','Enviado','Entregado'),NEW.total,0);
 IF NEW.id_cliente=OLD.id_cliente THEN
  UPDATE clientes SET total_gastado=total_gastado+v_despues-v_antes WHERE id_cliente=NEW.id_cliente;
 END IF;
 IF NEW.estado='Cancelado' AND OLD.estado<>'Cancelado' THEN
  INSERT INTO movimientos_stock(id_producto,diferencia,motivo,usuario) SELECT id_producto,cantidad,CONCAT('Cancelacion ',NEW.id_venta),USER() FROM detalle_ventas WHERE id_venta=NEW.id_venta;
  UPDATE productos p JOIN detalle_ventas d ON d.id_producto=p.id_producto SET p.stock=p.stock+d.cantidad WHERE d.id_venta=NEW.id_venta;
  IF v_antes>0 THEN INSERT INTO notificaciones(tipo,entidad_id,contenido) VALUES('Credito cancelacion',NEW.id_venta,JSON_OBJECT('monto',OLD.total,'simulado',TRUE)); END IF;
 END IF;
END$$
-- 7. Mantiene tambien contador al cambiar categoria.
CREATE TRIGGER trg_set_fecha_modificacion_producto BEFORE UPDATE ON productos FOR EACH ROW
BEGIN
 SET NEW.fecha_modificacion=UTC_TIMESTAMP();
 IF NEW.id_categoria<>OLD.id_categoria THEN
  UPDATE categorias SET producto_count=producto_count-1 WHERE id_categoria=OLD.id_categoria;
  UPDATE categorias SET producto_count=producto_count+1 WHERE id_categoria=NEW.id_categoria;
 END IF;
END$$
-- 8.
CREATE TRIGGER trg_prevent_negative_stock BEFORE UPDATE ON productos FOR EACH ROW
BEGIN IF NEW.stock IS NULL OR NEW.stock<0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Stock no puede ser negativo'; END IF; END$$
-- 9.
CREATE TRIGGER trg_capitalize_nombre_cliente BEFORE INSERT ON clientes FOR EACH ROW
BEGIN
 SET NEW.nombre=CONCAT(UPPER(LEFT(TRIM(NEW.nombre),1)),LOWER(SUBSTRING(TRIM(NEW.nombre),2)));
 SET NEW.apellido=CONCAT(UPPER(LEFT(TRIM(NEW.apellido),1)),LOWER(SUBSTRING(TRIM(NEW.apellido),2)));
 IF NEW.fecha_nacimiento>UTC_DATE() THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Fecha de nacimiento futura'; END IF;
END$$
-- 10. Lineas editables solo antes de pagar; precio y costo historicos inmutables.
CREATE TRIGGER trg_recalculate_total_venta_on_detalle_change BEFORE UPDATE ON detalle_ventas FOR EACH ROW
BEGIN
 DECLARE v_estado VARCHAR(30); DECLARE v_stock INT;
 SELECT estado INTO v_estado FROM ventas WHERE id_venta=OLD.id_venta FOR UPDATE;
 IF v_estado<>'Pendiente de Pago' OR NEW.id_venta<>OLD.id_venta OR NEW.id_producto<>OLD.id_producto OR NEW.precio_unitario_congelado<>OLD.precio_unitario_congelado OR NEW.costo_unitario_congelado<>OLD.costo_unitario_congelado THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Linea historica inmutable; use devolucion'; END IF;
 IF NEW.cantidad IS NULL OR NEW.cantidad<=0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cantidad invalida'; END IF;
 SELECT stock INTO v_stock FROM productos WHERE id_producto=OLD.id_producto FOR UPDATE;
 IF NEW.cantidad-OLD.cantidad>v_stock THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Stock insuficiente al editar'; END IF;
 UPDATE productos SET stock=stock+OLD.cantidad-NEW.cantidad WHERE id_producto=OLD.id_producto;
 UPDATE ventas SET total=total+(NEW.cantidad-OLD.cantidad)*OLD.precio_unitario_congelado WHERE id_venta=OLD.id_venta;
 INSERT INTO movimientos_stock(id_producto,diferencia,motivo,usuario) VALUES(OLD.id_producto,OLD.cantidad-NEW.cantidad,'Edicion de reserva',USER());
END$$
-- 11. Maquina de estados; no permite reabrir cancelados ni cancelar entregados.
CREATE TRIGGER trg_log_order_status_change BEFORE UPDATE ON ventas FOR EACH ROW
BEGIN
 IF NEW.id_sucursal<>OLD.id_sucursal THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='La sucursal historica es inmutable'; END IF;
 IF NEW.estado<>OLD.estado THEN
  IF NOT ((OLD.estado='Pendiente de Pago' AND NEW.estado IN ('Pagado','Cancelado')) OR (OLD.estado='Pagado' AND NEW.estado IN ('Procesando','Cancelado')) OR (OLD.estado='Procesando' AND NEW.estado IN ('Enviado','Cancelado')) OR (OLD.estado='Enviado' AND NEW.estado='Entregado')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Transicion de estado no permitida'; END IF;
  IF NEW.estado='Pagado' AND (NEW.total<=0 OR NOT EXISTS(SELECT 1 FROM detalle_ventas WHERE id_venta=OLD.id_venta)) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='No se paga una venta vacia'; END IF;
  INSERT INTO auditoria(tipo,entidad_id,datos,usuario) VALUES('Estado pedido',OLD.id_venta,JSON_OBJECT('antes',OLD.estado,'despues',NEW.estado),USER());
 END IF;
 IF OLD.estado<>'Pendiente de Pago' AND NEW.total<>OLD.total THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Total historico inmutable'; END IF;
END$$
-- 12. CHECK cubre tambien INSERT.
CREATE TRIGGER trg_prevent_price_zero_or_less BEFORE UPDATE ON productos FOR EACH ROW
BEGIN IF NEW.precio IS NULL OR NEW.precio<=0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Precio debe ser positivo'; END IF; END$$
-- 13. Al cruzar el umbral, evita repetir alertas en cada cambio de precio.
CREATE TRIGGER trg_send_stock_alert_on_low_stock AFTER UPDATE ON productos FOR EACH ROW
BEGIN IF NEW.stock<NEW.stock_minimo AND OLD.stock>=OLD.stock_minimo THEN INSERT INTO alertas(tipo,entidad_id,mensaje) VALUES('Stock bajo',NEW.id_producto,'Revisar reabastecimiento'); END IF; END$$
-- 14. Archivo de cabecera y detalles antes de borrar. Solo canceladas, conservacion 30 dias.
CREATE TRIGGER trg_archive_deleted_venta BEFORE DELETE ON ventas FOR EACH ROW
BEGIN
 IF OLD.estado<>'Cancelado' OR OLD.eliminado_en IS NULL OR OLD.eliminado_en>UTC_TIMESTAMP()-INTERVAL 30 DAY THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Solo purga de canceladas marcadas hace 30 dias'; END IF;
 IF EXISTS(SELECT 1 FROM pagos WHERE id_venta=OLD.id_venta) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Conservar venta con movimientos financieros'; END IF;
 INSERT INTO ventas_archivo(id_venta,encabezado,detalles)
 SELECT OLD.id_venta,JSON_OBJECT('id_cliente',OLD.id_cliente,'id_sucursal',OLD.id_sucursal,'fecha',OLD.fecha_venta,'estado',OLD.estado,'total',OLD.total),
 (SELECT JSON_ARRAYAGG(JSON_OBJECT('producto',id_producto,'cantidad',cantidad,'precio',precio_unitario_congelado,'costo',costo_unitario_congelado)) FROM detalle_ventas WHERE id_venta=OLD.id_venta);
 DELETE FROM detalle_ventas WHERE id_venta=OLD.id_venta;
END$$
-- 15. INSERT; complemento UPDATE al final.
CREATE TRIGGER trg_validate_email_format_on_customer BEFORE INSERT ON clientes FOR EACH ROW
BEGIN IF NOT fn_ValidarFormatoEmail(NEW.email) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Email invalido'; END IF; END$$
-- 16.
CREATE TRIGGER trg_update_last_order_date_customer AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
 IF NEW.estado<>OLD.estado OR NEW.id_cliente<>OLD.id_cliente THEN
 UPDATE clientes SET ultima_compra=(SELECT MAX(fecha_venta) FROM ventas WHERE id_cliente=NEW.id_cliente AND estado IN ('Pagado','Procesando','Enviado','Entregado')) WHERE id_cliente=NEW.id_cliente;
 END IF;
END$$
-- 17. La autorreferencia con ID autogenerado no puede existir antes del INSERT por la FK.
CREATE TRIGGER trg_prevent_self_referral BEFORE UPDATE ON clientes FOR EACH ROW
BEGIN
 IF NEW.id_referente=NEW.id_cliente THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Autorreferencia no permitida'; END IF;
 IF NOT fn_ValidarFormatoEmail(NEW.email) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Email invalido'; END IF;
 IF NEW.fecha_nacimiento>UTC_DATE() THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Fecha de nacimiento futura'; END IF;
END$$
-- 18. SOLO audita anotaciones manuales; MySQL no tiene triggers de GRANT/REVOKE.
CREATE TRIGGER trg_log_permission_changes AFTER INSERT ON cambios_permisos FOR EACH ROW
BEGIN INSERT INTO auditoria(tipo,entidad_id,datos,usuario) VALUES('Permiso documentado',NEW.id_cambio,JSON_OBJECT('cuenta',NEW.cuenta,'descripcion',NEW.descripcion),USER()); END$$
-- 19.
CREATE TRIGGER trg_assign_default_category_on_null BEFORE INSERT ON productos FOR EACH ROW
BEGIN IF NEW.id_categoria IS NULL THEN SET NEW.id_categoria=(SELECT id_categoria FROM categorias WHERE nombre='General'); END IF; END$$
-- 20.
CREATE TRIGGER trg_update_producto_count_in_categoria AFTER INSERT ON productos FOR EACH ROW
BEGIN UPDATE categorias SET producto_count=producto_count+1 WHERE id_categoria=NEW.id_categoria; END$$

-- Complementos necesarios: MySQL exige un trigger distinto por operacion.
CREATE TRIGGER trg_producto_count_after_delete AFTER DELETE ON productos FOR EACH ROW
BEGIN UPDATE categorias SET producto_count=producto_count-1 WHERE id_categoria=OLD.id_categoria; END$$
CREATE TRIGGER trg_cliente_self_referral_insert BEFORE INSERT ON clientes FOR EACH ROW
BEGIN IF NEW.id_cliente<>0 AND NEW.id_referente=NEW.id_cliente THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Autorreferencia no permitida'; END IF; END$$
-- Las lineas pendientes pueden borrarse y liberar reserva. Canceladas solo durante archivo.
CREATE TRIGGER trg_detalle_before_delete BEFORE DELETE ON detalle_ventas FOR EACH ROW
BEGIN
 DECLARE v_estado VARCHAR(30);
 SELECT estado INTO v_estado FROM ventas WHERE id_venta=OLD.id_venta;
 IF v_estado='Pendiente de Pago' THEN
  UPDATE productos SET stock=stock+OLD.cantidad WHERE id_producto=OLD.id_producto;
  UPDATE ventas SET total=total-OLD.cantidad*OLD.precio_unitario_congelado WHERE id_venta=OLD.id_venta;
  INSERT INTO movimientos_stock(id_producto,diferencia,motivo,usuario) VALUES(OLD.id_producto,OLD.cantidad,'Eliminacion de reserva',USER());
 ELSEIF v_estado<>'Cancelado' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Detalle pagado inmutable';
 END IF;
END$$
DELIMITER ;
GRANT SELECT ON ecommerce.log_cambios_precio TO 'Auditor_Financiero';
