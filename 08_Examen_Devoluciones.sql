-- EXAMEN: devoluciones seguras. Santiago Castro. MySQL Community 8.4.
-- BASE: Proyecto_BD_Avanzada_SantiagoCastro, commit cfc29d4.
-- INSTALACION: ejecutar UNA VEZ, como DBA, DESPUES de 01 a 07.
-- Guardar copia externa antes de aplicar a datos reales. Aplicar sin sesiones
-- de negocio concurrentes ni eventos habilitados. Este DDL NO es transaccional;
-- la atomicidad exigida se aplica a cada CALL del procedimiento de negocio.
-- Ejecutar en modo batch SIN --force; detenerse ante el primer error.
-- No ejecutar de nuevo los scripts originales 03/05/07 tras esta migracion.
--
-- CONTRATO NUEVO: CALL sp_ProcesarDevolucion(id_venta,id_producto,cantidad_devuelta).
-- Reemplaza el contrato anterior (id_detalle,cantidad,motivo).
-- Nombres en minusculas conservan compatibilidad Linux/Windows con el proyecto.
-- productos.stock = SUM(inventario_sucursal.stock): total global materializado.
-- Los triggers de inventario mantienen ese total en la MISMA transaccion.
-- Cantidades enteras, positivas; solo pedidos entregados o parcialmente devueltos.
-- Las devoluciones anteriores cuentan para impedir devolver dos veces lo comprado.
-- Los importes son creditos SIMULADOS, no transferencias bancarias.
-- Cada CALL representa una devolucion nueva; no reenviar a ciegas si se pierde
-- la respuesta. La firma de tres parametros no incluye una clave de idempotencia.
--
-- 1. Precondiciones: no alterar una instalacion distinta/incompleta.
USE ecommerce;
SET NAMES utf8mb4;
SET time_zone = '+00:00';
DROP PROCEDURE IF EXISTS _prevalidar_examen_devoluciones;
DELIMITER $$
CREATE PROCEDURE _prevalidar_examen_devoluciones()
BEGIN
 IF (SELECT COUNT(*) FROM information_schema.routines
     WHERE routine_schema='ecommerce' AND routine_name='sp_ProcesarDevolucion')<>1
    OR (SELECT COUNT(*) FROM information_schema.triggers
        WHERE trigger_schema='ecommerce' AND trigger_name IN
        ('trg_log_order_status_change','trg_update_total_gastado_cliente',
         'trg_update_last_order_date_customer'))<>3 THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Instale primero los scripts 01 a 07 completos';
 END IF;
 IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='ecommerce'
           AND table_name='productos' AND column_name='stock')
 OR EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='ecommerce'
           AND table_name='devoluciones_pre_examen') THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Migracion ya aplicada o esquema distinto; no repetir';
 END IF;
 IF EXISTS(SELECT 1 FROM information_schema.events WHERE event_schema='ecommerce'
           AND status='ENABLED') THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Deshabilite los eventos durante la migracion';
 END IF;
 IF (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema='ecommerce' AND routine_name IN ('fn_ContarVentasCliente','fn_EsClienteNuevo','fn_ObtenerUltimaFechaCompra','sp_AjustarNivelStock','sp_AnadirResenaProducto','sp_EliminarClienteDeFormaSegura','sp_FusionarCuentasCliente','sp_GenerarReporteMensualVentas','sp_ObtenerDashboardAdmin','sp_ObtenerProductosRelacionados','sp_ProcesarDevolucion'))<>11 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Faltan rutinas requeridos: instale 01 a 07 completos'; END IF;
 IF (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='ecommerce' AND trigger_name IN ('trg_check_stock_before_insert_venta','trg_detalle_before_delete','trg_log_order_status_change','trg_recalculate_total_venta_on_detalle_change','trg_update_last_order_date_customer','trg_update_total_gastado_cliente'))<>6 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Faltan triggers requeridos: instale 01 a 07 completos'; END IF;
 IF (SELECT COUNT(*) FROM information_schema.events WHERE event_schema='ecommerce' AND event_name IN ('evt_aggregate_daily_sales_data','evt_backup_critical_tables_daily','evt_calculate_monthly_kpis','evt_generate_supplier_performance_report_monthly','evt_generate_weekly_sales_report','evt_refresh_materialized_views_nightly','evt_suspend_inactive_accounts_quarterly','evt_update_product_rankings_hourly'))<>8 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Faltan eventos requeridos: instale 01 a 07 completos'; END IF;
 IF EXISTS(SELECT 1 FROM mysql.user WHERE User='') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Elimine cuentas anonimas antes de usar autorizacion por USER()'; END IF;
 IF EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='ecommerce' AND table_type='BASE TABLE' AND engine<>'InnoDB') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Se requiere InnoDB para atomicidad'; END IF;
 IF EXISTS(SELECT 1 FROM information_schema.statistics WHERE table_schema='ecommerce' AND table_name='detalle_ventas' AND index_name='uq_detalle_venta_producto') OR EXISTS(SELECT 1 FROM information_schema.triggers WHERE trigger_schema='ecommerce' AND trigger_name IN ('trg_examen_stock_insert','trg_examen_stock_update','trg_examen_stock_delete')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Conflicto de nombres de objetos del examen'; END IF;
 IF EXISTS(SELECT d.id_detalle FROM detalle_ventas d JOIN devoluciones r USING(id_detalle)
           GROUP BY d.id_detalle,d.cantidad HAVING SUM(r.cantidad)>d.cantidad) THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Hay devoluciones historicas superiores a la compra';
 END IF;
END$$
CALL _prevalidar_examen_devoluciones()$$
DROP PROCEDURE _prevalidar_examen_devoluciones$$
DELIMITER ;

-- 2. Nueva tabla solicitada, conservando una copia del historial anterior.
-- No se pierde ningun ID, cantidad, motivo, credito ni fecha ya registrados.
RENAME TABLE devoluciones TO devoluciones_pre_examen;
ALTER TABLE detalle_ventas ADD UNIQUE KEY uq_detalle_venta_producto
 (id_detalle,id_venta,id_producto);
CREATE TABLE devoluciones (
 id_devolucion INT PRIMARY KEY AUTO_INCREMENT,
 id_venta INT NOT NULL,
 id_producto INT NOT NULL,
 id_detalle INT NOT NULL,
 cantidad INT NOT NULL CHECK(cantidad>0),
 credito DECIMAL(16,2) NOT NULL CHECK(credito>=0),
 motivo VARCHAR(300) NOT NULL,
 fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 usuario VARCHAR(288) NULL COMMENT 'NULL solo para historial sin autor conocido',
 estado_anterior VARCHAR(30) NULL,
 estado_resultante VARCHAR(30) NULL,
 INDEX ix_devoluciones_venta(id_venta),
 CONSTRAINT fk_devolucion_detalle_examen
  FOREIGN KEY(id_detalle,id_venta,id_producto)
  REFERENCES detalle_ventas(id_detalle,id_venta,id_producto)
) ENGINE=InnoDB;
INSERT INTO devoluciones(id_devolucion,id_venta,id_producto,id_detalle,
                         cantidad,credito,motivo,fecha)
SELECT r.id_devolucion,d.id_venta,d.id_producto,r.id_detalle,
       r.cantidad,r.credito,r.motivo,r.fecha
FROM devoluciones_pre_examen r JOIN detalle_ventas d USING(id_detalle);

-- 3. Estados pedidos en el examen y stock total en Productos.
ALTER TABLE ventas MODIFY estado ENUM(
 'Pendiente de Pago','Pagado','Procesando','Enviado','Entregado','Cancelado',
 'Devolución Parcial','Devuelto Totalmente'
) NOT NULL DEFAULT 'Pendiente de Pago';
ALTER TABLE productos ADD COLUMN stock BIGINT NOT NULL DEFAULT 0 CHECK(stock>=0);
UPDATE productos p SET stock=COALESCE(
 (SELECT SUM(i.stock) FROM inventario_sucursal i WHERE i.id_producto=p.id_producto),0);

-- 4. Mantener Productos.stock para TODAS las operaciones de inventario:
-- altas, ventas, ajustes, cancelaciones y devoluciones. Se suma solo el delta;
-- evita sobrescribir cambios simultaneos hechos en otra sucursal.
DELIMITER $$
CREATE TRIGGER trg_examen_stock_insert AFTER INSERT ON inventario_sucursal
FOR EACH ROW
BEGIN
 UPDATE productos SET stock=stock+NEW.stock WHERE id_producto=NEW.id_producto;
END$$
CREATE TRIGGER trg_examen_stock_update AFTER UPDATE ON inventario_sucursal
FOR EACH ROW
BEGIN
 IF NEW.id_producto=OLD.id_producto THEN
  IF NEW.stock<>OLD.stock THEN
   UPDATE productos SET stock=stock+NEW.stock-OLD.stock WHERE id_producto=NEW.id_producto;
  END IF;
 ELSE
  UPDATE productos SET stock=stock-OLD.stock WHERE id_producto=OLD.id_producto;
  UPDATE productos SET stock=stock+NEW.stock WHERE id_producto=NEW.id_producto;
 END IF;
END$$
CREATE TRIGGER trg_examen_stock_delete AFTER DELETE ON inventario_sucursal
FOR EACH ROW
BEGIN
 UPDATE productos SET stock=stock-OLD.stock WHERE id_producto=OLD.id_producto;
END$$
DELIMITER ;

-- Compatibilidad: trg_log_order_status_change.
DROP TRIGGER trg_log_order_status_change;
DELIMITER $$
CREATE TRIGGER trg_log_order_status_change BEFORE UPDATE ON ventas FOR EACH ROW
BEGIN
 IF NEW.id_cliente<>OLD.id_cliente AND NOT EXISTS(SELECT 1 FROM contexto_fusion WHERE conexion=CONNECTION_ID() AND origen=OLD.id_cliente AND destino=NEW.id_cliente) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cliente de venta inmutable; use fusion controlada'; END IF;
 IF NEW.id_sucursal<>OLD.id_sucursal THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='La sucursal historica es inmutable'; END IF;
 -- El estado de devolucion debe coincidir con TODAS las lineas del pedido.
 IF NEW.estado IN ('Devolución Parcial','Devuelto Totalmente') THEN
  IF NOT EXISTS(SELECT 1 FROM devoluciones WHERE id_venta=OLD.id_venta) THEN
   SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='No hay devoluciones registradas';
  END IF;
  IF (NEW.estado='Devuelto Totalmente') <> (NOT EXISTS(
   SELECT 1 FROM detalle_ventas d WHERE d.id_venta=OLD.id_venta
   AND d.cantidad>COALESCE((SELECT SUM(r.cantidad) FROM devoluciones r
                           WHERE r.id_detalle=d.id_detalle),0)
  )) THEN
   SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Estado incompatible con unidades devueltas';
  END IF;
 END IF;
 IF NEW.estado<>OLD.estado THEN
  IF NOT ((OLD.estado='Pendiente de Pago' AND NEW.estado IN ('Pagado','Cancelado')) OR (OLD.estado='Pagado' AND NEW.estado IN ('Procesando','Cancelado')) OR (OLD.estado='Procesando' AND NEW.estado IN ('Enviado','Cancelado')) OR (OLD.estado='Enviado' AND NEW.estado='Entregado') OR (OLD.estado='Entregado' AND NEW.estado IN ('Devolución Parcial','Devuelto Totalmente')) OR (OLD.estado='Devolución Parcial' AND NEW.estado='Devuelto Totalmente')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Transicion de estado no permitida'; END IF;
  IF NEW.estado='Pagado' AND (NEW.total<=0 OR NOT EXISTS(SELECT 1 FROM detalle_ventas WHERE id_venta=OLD.id_venta)) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='No se paga una venta vacia'; END IF;
  INSERT INTO auditoria(tipo,entidad_id,datos,usuario) VALUES('Estado pedido',OLD.id_venta,JSON_OBJECT('antes',OLD.estado,'despues',NEW.estado),USER());
 END IF;
 IF OLD.estado<>'Pendiente de Pago' AND NEW.total<>OLD.total THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Total historico inmutable'; END IF;
END$$
DELIMITER ;

-- Compatibilidad: trg_update_total_gastado_cliente.
DROP TRIGGER trg_update_total_gastado_cliente;
DELIMITER $$
CREATE TRIGGER trg_update_total_gastado_cliente AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
 DECLARE v_fin BOOLEAN DEFAULT FALSE; DECLARE v_producto INT; DECLARE v_bloqueado INT;
 DECLARE v_antes DECIMAL(16,2); DECLARE v_despues DECIMAL(16,2);
 DECLARE cur_stock CURSOR FOR SELECT id_producto FROM detalle_ventas WHERE id_venta=NEW.id_venta ORDER BY id_producto;
 DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin=TRUE;
 SET v_antes=IF(OLD.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente'),OLD.total,0);
 SET v_despues=IF(NEW.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente'),NEW.total,0);
 IF NEW.id_cliente=OLD.id_cliente THEN
  UPDATE clientes SET total_gastado=total_gastado+v_despues-v_antes WHERE id_cliente=NEW.id_cliente;
 END IF;
 IF NEW.estado='Cancelado' AND OLD.estado<>'Cancelado' THEN
  OPEN cur_stock;
  bloquear_productos: LOOP
   FETCH cur_stock INTO v_producto;
   IF v_fin THEN LEAVE bloquear_productos; END IF;
   SELECT id_producto INTO v_bloqueado FROM productos WHERE id_producto=v_producto FOR UPDATE;
  END LOOP;
  CLOSE cur_stock;
  INSERT INTO movimientos_stock(id_sucursal,id_producto,diferencia,motivo,usuario) SELECT NEW.id_sucursal,id_producto,cantidad,CONCAT('Cancelacion ',NEW.id_venta),USER() FROM detalle_ventas WHERE id_venta=NEW.id_venta;
  UPDATE inventario_sucursal i JOIN detalle_ventas d ON d.id_producto=i.id_producto SET i.stock=i.stock+d.cantidad WHERE d.id_venta=NEW.id_venta AND i.id_sucursal=NEW.id_sucursal;
  IF v_antes>0 THEN INSERT INTO notificaciones(tipo,entidad_id,contenido) VALUES('Credito cancelacion',NEW.id_venta,JSON_OBJECT('monto',OLD.total,'simulado',TRUE)); END IF;
 END IF;
END$$
DELIMITER ;

-- Compatibilidad: trg_update_last_order_date_customer.
DROP TRIGGER trg_update_last_order_date_customer;
DELIMITER $$
CREATE TRIGGER trg_update_last_order_date_customer AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
 IF NEW.estado<>OLD.estado OR NEW.id_cliente<>OLD.id_cliente THEN
 UPDATE clientes SET ultima_compra=(SELECT MAX(fecha_venta) FROM ventas WHERE id_cliente=NEW.id_cliente AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente')) WHERE id_cliente=NEW.id_cliente;
 END IF;
END$$
DELIMITER ;

-- Orden producto exclusivo -> inventario.
DROP TRIGGER trg_check_stock_before_insert_venta;
DELIMITER $$
CREATE TRIGGER trg_check_stock_before_insert_venta BEFORE INSERT ON detalle_ventas FOR EACH ROW
BEGIN
 DECLARE v_sucursal INT; DECLARE v_estado VARCHAR(30); DECLARE v_stock INT; DECLARE v_activo BOOLEAN;
 DECLARE v_precio DECIMAL(12,2); DECLARE v_costo DECIMAL(12,2);
 DECLARE v_categoria INT; DECLARE v_proveedor INT;
 SELECT estado,id_sucursal INTO v_estado,v_sucursal FROM ventas WHERE id_venta=NEW.id_venta FOR UPDATE;
 IF v_estado IS NULL OR v_estado<>'Pendiente de Pago' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Solo se agregan lineas a pedidos pendientes'; END IF;
 SELECT activo,precio,costo,id_categoria,id_proveedor INTO v_activo,v_precio,v_costo,v_categoria,v_proveedor FROM productos WHERE id_producto=NEW.id_producto FOR UPDATE;
 SELECT stock INTO v_stock FROM inventario_sucursal WHERE id_sucursal=v_sucursal AND id_producto=NEW.id_producto FOR UPDATE;
 IF v_stock IS NULL OR NOT v_activo OR NEW.cantidad IS NULL OR NEW.cantidad<=0 OR NEW.cantidad>v_stock THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Producto inactivo o stock insuficiente'; END IF;
 SET NEW.precio_unitario_congelado=v_precio;
 SET NEW.costo_unitario_congelado=v_costo;
 SET NEW.id_categoria_historica=v_categoria;
 SET NEW.id_proveedor_historico=v_proveedor;
 SET NEW.categoria_historica=(SELECT nombre FROM categorias WHERE id_categoria=v_categoria);
 SET NEW.proveedor_historico=(SELECT nombre FROM proveedores WHERE id_proveedor=v_proveedor);
END$$
DELIMITER ;

-- Orden producto exclusivo -> inventario.
DROP TRIGGER trg_recalculate_total_venta_on_detalle_change;
DELIMITER $$
CREATE TRIGGER trg_recalculate_total_venta_on_detalle_change BEFORE UPDATE ON detalle_ventas FOR EACH ROW
BEGIN
 DECLARE v_producto_bloqueado INT;
 DECLARE v_sucursal INT; DECLARE v_estado VARCHAR(30); DECLARE v_stock INT;
 SELECT estado,id_sucursal INTO v_estado,v_sucursal FROM ventas WHERE id_venta=OLD.id_venta FOR UPDATE;
 IF v_estado<>'Pendiente de Pago' OR NEW.id_venta<>OLD.id_venta OR NEW.id_producto<>OLD.id_producto OR NEW.precio_unitario_congelado<>OLD.precio_unitario_congelado OR NEW.costo_unitario_congelado<>OLD.costo_unitario_congelado THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Linea historica inmutable; use devolucion'; END IF;
 IF NOT(NEW.id_categoria_historica<=>OLD.id_categoria_historica) OR NOT(NEW.categoria_historica<=>OLD.categoria_historica) OR NOT(NEW.id_proveedor_historico<=>OLD.id_proveedor_historico) OR NOT(NEW.proveedor_historico<=>OLD.proveedor_historico) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Contexto comercial historico inmutable'; END IF;
 IF NEW.cantidad IS NULL OR NEW.cantidad<=0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cantidad invalida'; END IF;
 SELECT id_producto INTO v_producto_bloqueado FROM productos WHERE id_producto=OLD.id_producto FOR UPDATE;
 SELECT stock INTO v_stock FROM inventario_sucursal WHERE id_sucursal=v_sucursal AND id_producto=OLD.id_producto FOR UPDATE;
 IF v_stock IS NULL OR NEW.cantidad-OLD.cantidad>v_stock THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Stock insuficiente al editar'; END IF;
 UPDATE inventario_sucursal SET stock=stock+OLD.cantidad-NEW.cantidad WHERE id_sucursal=v_sucursal AND id_producto=OLD.id_producto;
 UPDATE ventas SET total=total+(NEW.cantidad-OLD.cantidad)*OLD.precio_unitario_congelado WHERE id_venta=OLD.id_venta;
 INSERT INTO movimientos_stock(id_sucursal,id_producto,diferencia,motivo,usuario) VALUES(v_sucursal,OLD.id_producto,OLD.cantidad-NEW.cantidad,'Edicion de reserva',USER());
END$$
DELIMITER ;

-- Orden producto exclusivo -> inventario.
DROP TRIGGER trg_detalle_before_delete;
DELIMITER $$
CREATE TRIGGER trg_detalle_before_delete BEFORE DELETE ON detalle_ventas FOR EACH ROW
BEGIN
 DECLARE v_producto_bloqueado INT;
 DECLARE v_estado VARCHAR(30); DECLARE v_sucursal INT;
 SELECT estado,id_sucursal INTO v_estado,v_sucursal FROM ventas WHERE id_venta=OLD.id_venta;
 -- El archivo de canceladas ya bloquea ventas; no volver a bloquear la tabla invocante.
 IF v_estado='Pendiente de Pago' THEN
  SELECT estado,id_sucursal INTO v_estado,v_sucursal FROM ventas WHERE id_venta=OLD.id_venta FOR UPDATE;
 END IF;
 IF v_estado='Pendiente de Pago' THEN
 SELECT id_producto INTO v_producto_bloqueado FROM productos WHERE id_producto=OLD.id_producto FOR UPDATE;
  UPDATE inventario_sucursal SET stock=stock+OLD.cantidad WHERE id_sucursal=v_sucursal AND id_producto=OLD.id_producto;
  UPDATE ventas SET total=total-OLD.cantidad*OLD.precio_unitario_congelado WHERE id_venta=OLD.id_venta;
  INSERT INTO movimientos_stock(id_sucursal,id_producto,diferencia,motivo,usuario) VALUES(v_sucursal,OLD.id_producto,OLD.cantidad,'Eliminacion de reserva',USER());
 ELSEIF v_estado<>'Cancelado' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Detalle pagado inmutable';
 END IF;
END$$
DELIMITER ;

DROP PROCEDURE sp_AjustarNivelStock;
DELIMITER $$
CREATE PROCEDURE sp_AjustarNivelStock(IN p_sucursal INT,IN p_producto INT,IN p_delta INT,IN p_motivo VARCHAR(300))
SQL SECURITY DEFINER
BEGIN
 DECLARE v_stock INT; DECLARE v_producto_bloqueado INT;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_sucursal IS NULL OR (SUBSTRING_INDEX(USER(),'@',1) NOT IN ('root','admin_user') AND NOT EXISTS(SELECT 1 FROM usuarios_sucursal WHERE usuario=SUBSTRING_INDEX(USER(),'@',1) AND id_sucursal=p_sucursal)) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Sucursal no autorizada'; END IF;
 IF p_delta IS NULL OR p_motivo IS NULL OR TRIM(p_motivo)='' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Delta y motivo requeridos'; END IF;
 START TRANSACTION;
 SELECT id_producto INTO v_producto_bloqueado FROM productos WHERE id_producto=p_producto FOR UPDATE;
 SELECT stock INTO v_stock FROM inventario_sucursal WHERE id_sucursal=p_sucursal AND id_producto=p_producto FOR UPDATE;
 IF v_stock IS NULL OR v_stock+p_delta<0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Ajuste invalido'; END IF;
 UPDATE inventario_sucursal SET stock=stock+p_delta WHERE id_sucursal=p_sucursal AND id_producto=p_producto;
 INSERT INTO movimientos_stock(id_sucursal,id_producto,diferencia,motivo,usuario) VALUES(p_sucursal,p_producto,p_delta,p_motivo,USER());
 COMMIT;
END$$
DELIMITER ;
GRANT EXECUTE ON PROCEDURE ecommerce.sp_AjustarNivelStock TO 'Empleado_Inventario';

-- 5. Procedimiento central del examen.
-- SECURITY DEFINER permite conceder SOLO EXECUTE a Atencion_Cliente.
-- USER() conserva la cuenta de conexion; CURRENT_USER() aqui seria el definidor.
-- Cada cuenta operativa debe tener su asignacion en usuarios_sucursal.
-- Llamar fuera de una transaccion externa: MySQL no tiene transacciones anidadas.
DROP PROCEDURE sp_ProcesarDevolucion;
DELIMITER $$
CREATE PROCEDURE sp_ProcesarDevolucion(
 IN p_id_venta INT,
 IN p_id_producto INT,
 IN p_cantidad_devuelta LONGTEXT
)
SQL SECURITY DEFINER
MODIFIES SQL DATA
BEGIN
 DECLARE v_cantidad INT;
 DECLARE v_texto LONGTEXT;
 DECLARE v_producto_bloqueado INT;
 DECLARE v_cliente_previo INT DEFAULT NULL;
 DECLARE v_cliente INT DEFAULT NULL;
 DECLARE v_sucursal INT DEFAULT NULL;
 DECLARE v_detalle INT DEFAULT NULL;
 DECLARE v_stock INT DEFAULT NULL;
 DECLARE v_comprada INT;
 DECLARE v_devuelta BIGINT DEFAULT 0;
 DECLARE v_pendientes INT DEFAULT 0;
 DECLARE v_id_devolucion INT;
 DECLARE v_precio DECIMAL(12,2);
 DECLARE v_credito DECIMAL(16,2);
 DECLARE v_estado VARCHAR(30);
 DECLARE v_nuevo_estado VARCHAR(30);
 DECLARE v_usuario VARCHAR(288);
 DECLARE v_transaccion BOOLEAN DEFAULT FALSE;

 -- Si falla cualquier INSERT/UPDATE/validacion, se revierte la operacion completa.
 -- RESIGNAL entrega el error original al cliente en vez de ocultarlo.
 DECLARE EXIT HANDLER FOR SQLEXCEPTION
 BEGIN
  IF v_transaccion THEN ROLLBACK; END IF;
  RESIGNAL;
 END;

 -- Validar el texto ORIGINAL: DECIMAL/INT redondearian antes de entrar aqui.
 -- Contrato: digitos ASCII, sin signo, espacios, decimal ni exponente (max. 64).
 IF p_id_venta IS NULL OR p_id_venta<=0 OR p_id_producto IS NULL OR p_id_producto<=0
 OR p_cantidad_devuelta IS NULL OR CHAR_LENGTH(p_cantidad_devuelta)=0
 OR CHAR_LENGTH(p_cantidad_devuelta)>64
 OR REGEXP_LIKE(p_cantidad_devuelta,'[^0-9]','c') THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='IDs validos y cantidad entera positiva requeridos';
 END IF;
 SET v_texto=TRIM(LEADING '0' FROM p_cantidad_devuelta);
 IF CHAR_LENGTH(v_texto)=0 OR CHAR_LENGTH(v_texto)>10 THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='IDs validos y cantidad entera positiva requeridos';
 END IF;
 IF CAST(v_texto AS UNSIGNED)>2147483647 THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='IDs validos y cantidad entera positiva requeridos';
 END IF;
 SET v_cantidad=CAST(v_texto AS UNSIGNED);

 -- READ COMMITTED evita lecturas obsoletas de devoluciones concurrentes.
 SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
 START TRANSACTION;
 SET v_transaccion=TRUE;

 -- Ventas nuevas bloquean cliente antes de producto: conservar ese orden.
 SELECT id_cliente INTO v_cliente_previo FROM ventas WHERE id_venta=p_id_venta;
 IF v_cliente_previo IS NULL THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='La venta no existe';
 END IF;
 SELECT id_cliente INTO v_cliente FROM clientes WHERE id_cliente=v_cliente_previo FOR UPDATE;
 -- El bloqueo del pedido serializa devoluciones incluso de productos distintos.
 SELECT id_cliente,id_sucursal,estado INTO v_cliente,v_sucursal,v_estado
 FROM ventas WHERE id_venta=p_id_venta FOR UPDATE;
 IF v_cliente IS NULL THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='La venta no existe';
 END IF;
 IF v_cliente<>v_cliente_previo THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cliente de venta modificado concurrentemente; reintente';
 END IF;
 SET v_usuario=USER();
 -- El proyecto crea cuentas locales. Comparacion binaria: ROOT no es root.
 -- No se autoriza por nombre ignorando el host de la conexion.
 IF CAST(v_usuario AS BINARY) NOT IN (CAST('root@localhost' AS BINARY),CAST('admin_user@localhost' AS BINARY)) AND NOT EXISTS(
  SELECT 1 FROM usuarios_sucursal
  WHERE CAST(CONCAT(usuario,'@localhost') AS BINARY)=CAST(v_usuario AS BINARY)
    AND id_sucursal=v_sucursal
 ) THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Usuario no autorizado para la sucursal de la venta';
 END IF;
 IF v_estado NOT IN ('Entregado','Devolución Parcial') THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Solo se devuelve una venta entregada o parcialmente devuelta';
 END IF;

 SELECT id_detalle,cantidad,precio_unitario_congelado
 INTO v_detalle,v_comprada,v_precio
 FROM detalle_ventas WHERE id_venta=p_id_venta AND id_producto=p_id_producto FOR UPDATE;
 IF v_detalle IS NULL THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='El producto no pertenece a esta venta';
 END IF;
 SELECT COALESCE(SUM(cantidad),0) INTO v_devuelta
 FROM devoluciones WHERE id_detalle=v_detalle;
 IF v_cantidad>v_comprada-v_devuelta THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='La devolucion supera las unidades pendientes de devolver';
 END IF;
 -- Bloqueo exclusivo del producto ANTES del inventario; mismo orden que ventas.
 SELECT id_producto INTO v_producto_bloqueado FROM productos
 WHERE id_producto=p_id_producto FOR UPDATE;
 SELECT stock INTO v_stock FROM inventario_sucursal
 WHERE id_sucursal=v_sucursal AND id_producto=p_id_producto FOR UPDATE;
 IF v_stock IS NULL THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='No existe inventario para el producto en la sucursal';
 END IF;
 IF v_stock>2147483647-v_cantidad THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='El stock resultante excede la capacidad del campo';
 END IF;
 SET v_credito=v_cantidad*v_precio;

 -- Registrar primero permite calcular el estado incluyendo esta devolucion.
 INSERT INTO devoluciones(id_venta,id_producto,id_detalle,cantidad,credito,motivo,
                          fecha,usuario,estado_anterior)
 VALUES(p_id_venta,p_id_producto,v_detalle,v_cantidad,v_credito,
        'Devolucion procesada por atencion al cliente',UTC_TIMESTAMP(),USER(),v_estado);
 SET v_id_devolucion=LAST_INSERT_ID();

 -- Repone la sucursal original. trg_examen_stock_update ejecuta automaticamente:
 -- UPDATE productos SET stock=stock+NEW.stock-OLD.stock ...
 -- Por tanto Productos.stock aumenta exactamente cantidad_devuelta, UNA sola vez.
 UPDATE inventario_sucursal SET stock=stock+v_cantidad
 WHERE id_sucursal=v_sucursal AND id_producto=p_id_producto;

 -- Totalidad se decide sobre el pedido entero, incluyendo sus otras lineas.
 SELECT COUNT(*) INTO v_pendientes FROM detalle_ventas d
 WHERE d.id_venta=p_id_venta AND d.cantidad>COALESCE(
  (SELECT SUM(r.cantidad) FROM devoluciones r WHERE r.id_detalle=d.id_detalle),0);
 SET v_nuevo_estado=IF(v_pendientes=0,'Devuelto Totalmente','Devolución Parcial');
 UPDATE devoluciones SET estado_resultante=v_nuevo_estado WHERE id_devolucion=v_id_devolucion;
 UPDATE ventas SET estado=v_nuevo_estado WHERE id_venta=p_id_venta;

 -- La factura conserva total bruto. El gasto del cliente disminuye solo el credito.
 -- Los triggers adaptados NO restan de nuevo el total al cambiar a estado devuelto.
 UPDATE clientes SET total_gastado=total_gastado-v_credito WHERE id_cliente=v_cliente;
 INSERT INTO movimientos_stock(id_sucursal,id_producto,diferencia,motivo,usuario)
 VALUES(v_sucursal,p_id_producto,v_cantidad,
        CONCAT('Devolucion ',v_id_devolucion,' de venta ',p_id_venta),USER());
 INSERT INTO auditoria(tipo,entidad_id,datos,usuario)
 VALUES('Devolucion procesada',v_id_devolucion,
  JSON_OBJECT('id_venta',p_id_venta,'id_producto',p_id_producto,'id_sucursal',v_sucursal,
              'cantidad',v_cantidad,'credito',v_credito,
              'estado_anterior',v_estado,'estado_resultante',v_nuevo_estado),USER());
 INSERT INTO notificaciones(tipo,entidad_id,contenido)
 VALUES('Credito devolucion',p_id_venta,
        JSON_OBJECT('id_devolucion',v_id_devolucion,'monto',v_credito,'simulado',TRUE));
 COMMIT;
 SET v_transaccion=FALSE;
 SELECT v_id_devolucion AS id_devolucion,p_id_venta AS id_venta,
        p_id_producto AS id_producto,v_cantidad AS cantidad_devuelta,
        v_nuevo_estado AS estado,v_credito AS credito_simulado;
END$$
DELIMITER ;
GRANT EXECUTE ON PROCEDURE ecommerce.sp_ProcesarDevolucion TO 'Atencion_Cliente';
-- Consulta del historial limitada a la sucursal del usuario; sin escritura directa.
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_devoluciones_sucursal AS
SELECT r.id_devolucion,r.id_detalle,r.cantidad,r.credito,r.fecha,
       r.id_venta,r.id_producto,r.usuario,r.estado_anterior,r.estado_resultante
FROM devoluciones r JOIN ventas v ON v.id_venta=r.id_venta
WHERE CAST(USER() AS BINARY) IN (CAST('root@localhost' AS BINARY),CAST('admin_user@localhost' AS BINARY))
OR EXISTS(SELECT 1 FROM usuarios_sucursal u WHERE u.id_sucursal=v.id_sucursal
 AND CAST(CONCAT(u.usuario,'@localhost') AS BINARY)=CAST(USER() AS BINARY));
GRANT SELECT ON ecommerce.v_devoluciones_sucursal TO 'Atencion_Cliente';

-- 6. Compatibilidad de funciones, procedimientos, eventos y vistas existentes.
-- Una venta devuelta conserva su compra historica; los reportes NETOS restan
-- devoluciones y los BRUTOS conservan la facturacion original.

DROP FUNCTION fn_EsClienteNuevo;
DELIMITER $$
CREATE FUNCTION fn_EsClienteNuevo(p_id INT) RETURNS BOOLEAN READS SQL DATA
BEGIN RETURN COALESCE((SELECT MIN(fecha_venta) BETWEEN UTC_TIMESTAMP()-INTERVAL 30 DAY AND UTC_TIMESTAMP() FROM ventas WHERE id_cliente=p_id AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente')),FALSE); END$$
DELIMITER ;

DROP FUNCTION fn_ObtenerUltimaFechaCompra;
DELIMITER $$
CREATE FUNCTION fn_ObtenerUltimaFechaCompra(p_id INT) RETURNS DATETIME READS SQL DATA
BEGIN RETURN (SELECT MAX(fecha_venta) FROM ventas WHERE id_cliente=p_id AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente')); END$$
DELIMITER ;

DROP FUNCTION fn_ContarVentasCliente;
DELIMITER $$
CREATE FUNCTION fn_ContarVentasCliente(p_id INT) RETURNS INT READS SQL DATA
BEGIN RETURN (SELECT COUNT(*) FROM ventas WHERE id_cliente=p_id AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente')); END$$
DELIMITER ;

DROP PROCEDURE sp_EliminarClienteDeFormaSegura;
DELIMITER $$
CREATE PROCEDURE sp_EliminarClienteDeFormaSegura(IN p_cliente INT)
BEGIN
 DECLARE v_id INT;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF SUBSTRING_INDEX(USER(),'@',1) NOT IN ('root','admin_user') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Operacion global solo para administracion'; END IF;
 START TRANSACTION;
 SELECT id_cliente INTO v_id FROM clientes WHERE id_cliente=p_cliente FOR UPDATE;
 IF v_id IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cliente inexistente'; END IF;
 IF EXISTS(SELECT 1 FROM ventas WHERE id_cliente=p_cliente AND estado NOT IN ('Entregado','Cancelado','Devolución Parcial','Devuelto Totalmente')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Hay pedidos activos'; END IF;
 UPDATE clientes SET nombre='Anonimo',apellido=CONCAT('Cliente',p_cliente),email=CONCAT('anonimo-',p_cliente,'@example.invalid'),contrasena_hash='!DESACTIVADA!',direccion_envio=NULL,ciudad=NULL,region=NULL,fecha_nacimiento=NULL,id_referente=NULL,activo=FALSE,eliminado_en=UTC_TIMESTAMP() WHERE id_cliente=p_cliente;
 UPDATE ventas SET direccion_envio=NULL,ciudad_envio=NULL,region_envio=NULL WHERE id_cliente=p_cliente;
 UPDATE resenas SET comentario=NULL WHERE id_cliente=p_cliente;
 UPDATE visitas_producto SET id_cliente=NULL WHERE id_cliente=p_cliente;
 DELETE dc FROM detalle_carrito dc JOIN carritos c USING(id_carrito) WHERE c.id_cliente=p_cliente;
 DELETE FROM carritos WHERE id_cliente=p_cliente;
 DELETE FROM cupones_cumpleanos WHERE id_cliente=p_cliente;
 COMMIT;
END$$
DELIMITER ;

DROP PROCEDURE sp_GenerarReporteMensualVentas;
DELIMITER $$
CREATE PROCEDURE sp_GenerarReporteMensualVentas(IN p_anio INT,IN p_mes INT)
BEGIN
 DECLARE v_desde DATE;
 IF p_anio IS NULL OR p_anio NOT BETWEEN 1000 AND 9998 OR p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Mes o anio invalido'; END IF;
 SET v_desde=STR_TO_DATE(CONCAT(p_anio,'-',LPAD(p_mes,2,'0'),'-01'),'%Y-%m-%d');
 SELECT COUNT(*) pedidos,COALESCE(SUM(total),0) ingresos_brutos,AVG(total) ticket_promedio FROM v_ventas_sucursal WHERE fecha_venta>=v_desde AND fecha_venta<v_desde+INTERVAL 1 MONTH AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente');
END$$
DELIMITER ;

DROP PROCEDURE sp_FusionarCuentasCliente;
DELIMITER $$
CREATE PROCEDURE sp_FusionarCuentasCliente(IN p_origen INT,IN p_destino INT)
BEGIN
 DECLARE v_id INT; DECLARE v_activo BOOLEAN;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_origen IS NULL OR p_destino IS NULL OR p_origen=p_destino THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cuentas deben ser distintas'; END IF;
 IF SUBSTRING_INDEX(USER(),'@',1) NOT IN ('root','admin_user') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Operacion global solo para administracion'; END IF;
 START TRANSACTION;
 SELECT id_cliente INTO v_id FROM clientes WHERE id_cliente=LEAST(p_origen,p_destino) FOR UPDATE;
 IF v_id IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cuenta inexistente'; END IF;
 SET v_id=NULL;
 SELECT id_cliente INTO v_id FROM clientes WHERE id_cliente=GREATEST(p_origen,p_destino) FOR UPDATE;
 SELECT activo INTO v_activo FROM clientes WHERE id_cliente=p_destino;
 IF v_id IS NULL OR NOT v_activo THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cuenta destino inexistente o inactiva'; END IF;
 IF EXISTS(SELECT 1 FROM ventas WHERE id_cliente IN (p_origen,p_destino) AND estado NOT IN ('Entregado','Cancelado','Devolución Parcial','Devuelto Totalmente')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Finalice pedidos antes de fusionar'; END IF;
 UPDATE clientes SET id_referente=NULL WHERE id_cliente=p_destino AND id_referente=p_origen;
 UPDATE clientes SET id_referente=p_destino WHERE id_referente=p_origen AND id_cliente<>p_destino;
 DELETE r FROM resenas r JOIN resenas d ON d.id_producto=r.id_producto AND d.id_cliente=p_destino WHERE r.id_cliente=p_origen;
 UPDATE resenas SET id_cliente=p_destino WHERE id_cliente=p_origen;
 DELETE a FROM cupones_cumpleanos a JOIN cupones_cumpleanos b ON a.anio=b.anio AND b.id_cliente=p_destino WHERE a.id_cliente=p_origen;
 UPDATE cupones_cumpleanos SET id_cliente=p_destino WHERE id_cliente=p_origen;
 UPDATE carritos SET id_cliente=p_destino WHERE id_cliente=p_origen;
 UPDATE visitas_producto SET id_cliente=p_destino WHERE id_cliente=p_origen;
 INSERT INTO contexto_fusion(conexion,origen,destino) VALUES(CONNECTION_ID(),p_origen,p_destino);
 UPDATE ventas SET id_cliente=p_destino WHERE id_cliente=p_origen;
 DELETE FROM contexto_fusion WHERE conexion=CONNECTION_ID();
 UPDATE clientes SET total_gastado=COALESCE((SELECT SUM(total) FROM ventas WHERE id_cliente=p_destino AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente')),0)-COALESCE((SELECT SUM(r.credito) FROM devoluciones r JOIN detalle_ventas d USING(id_detalle) JOIN ventas v USING(id_venta) WHERE v.id_cliente=p_destino),0),ultima_compra=fn_ObtenerUltimaFechaCompra(p_destino) WHERE id_cliente=p_destino;
 UPDATE clientes SET total_gastado=0,ultima_compra=NULL,nombre='Fusionado',apellido=CONCAT('Cliente',p_origen),email=CONCAT('fusionado-',p_origen,'@example.invalid'),contrasena_hash='!DESACTIVADA!',direccion_envio=NULL,ciudad=NULL,region=NULL,fecha_nacimiento=NULL,id_referente=NULL,activo=FALSE,eliminado_en=UTC_TIMESTAMP() WHERE id_cliente=p_origen;
 INSERT INTO auditoria(tipo,entidad_id,datos,usuario) VALUES('Fusion clientes',p_destino,JSON_OBJECT('origen',p_origen),USER());
 COMMIT;
END$$
DELIMITER ;

DROP PROCEDURE sp_ObtenerDashboardAdmin;
DELIMITER $$
CREATE PROCEDURE sp_ObtenerDashboardAdmin()
BEGIN
 IF SUBSTRING_INDEX(USER(),'@',1) NOT IN ('root','admin_user') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Operacion global solo para administracion'; END IF;
 SELECT (SELECT COALESCE(SUM(total),0) FROM ventas WHERE fecha_venta>=UTC_DATE() AND fecha_venta<UTC_DATE()+INTERVAL 1 DAY AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente')) ventas_hoy,
 (SELECT COUNT(*) FROM clientes WHERE fecha_registro>=UTC_DATE()) nuevos_clientes,
 (SELECT COUNT(*) FROM inventario_sucursal i JOIN productos p USING(id_producto) WHERE p.activo AND i.stock<i.stock_minimo) productos_stock_bajo;
END$$
DELIMITER ;

DROP PROCEDURE sp_AnadirResenaProducto;
DELIMITER $$
CREATE PROCEDURE sp_AnadirResenaProducto(IN p_cliente INT,IN p_producto INT,IN p_calificacion INT,IN p_comentario TEXT)
BEGIN
 IF NOT EXISTS(SELECT 1 FROM v_ventas_sucursal v JOIN detalle_ventas d USING(id_venta) WHERE v.id_cliente=p_cliente AND d.id_producto=p_producto AND v.estado IN ('Entregado','Devolución Parcial','Devuelto Totalmente')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Solo compradores con entrega pueden opinar'; END IF;
 INSERT INTO resenas(id_cliente,id_producto,calificacion,comentario) VALUES(p_cliente,p_producto,p_calificacion,p_comentario);
END$$
DELIMITER ;

DROP PROCEDURE sp_ObtenerProductosRelacionados;
DELIMITER $$
CREATE PROCEDURE sp_ObtenerProductosRelacionados(IN p_producto INT)
BEGIN
 SELECT p.id_producto,p.nombre,COUNT(*) compras_juntas FROM detalle_ventas a JOIN detalle_ventas b ON a.id_venta=b.id_venta AND a.id_producto<>b.id_producto JOIN v_ventas_sucursal v ON v.id_venta=a.id_venta JOIN productos p ON p.id_producto=b.id_producto WHERE a.id_producto=p_producto AND p.activo AND v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY p.id_producto,p.nombre ORDER BY compras_juntas DESC,p.id_producto LIMIT 5;
END$$
DELIMITER ;

GRANT EXECUTE ON PROCEDURE ecommerce.sp_GenerarReporteMensualVentas TO 'Gerente_Marketing';

DELIMITER $$
ALTER EVENT evt_generate_weekly_sales_report
DO BEGIN
 INSERT INTO reporte_ventas_semanales SELECT UTC_DATE()-INTERVAL 7 DAY,id_sucursal,COUNT(*),SUM(total) FROM ventas
 WHERE fecha_venta>=UTC_DATE()-INTERVAL 7 DAY AND fecha_venta<UTC_DATE() AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY id_sucursal
 ON DUPLICATE KEY UPDATE pedidos=VALUES(pedidos),ingresos=VALUES(ingresos);
END$$
DELIMITER ;

DELIMITER $$
ALTER EVENT evt_suspend_inactive_accounts_quarterly
DO UPDATE clientes c SET activo=FALSE WHERE activo AND COALESCE(ultima_compra,fecha_registro)<UTC_TIMESTAMP()-INTERVAL 1 YEAR
 AND NOT EXISTS(SELECT 1 FROM ventas v WHERE v.id_cliente=c.id_cliente AND v.estado NOT IN ('Entregado','Cancelado','Devolución Parcial','Devuelto Totalmente'))$$
DELIMITER ;

DELIMITER $$
ALTER EVENT evt_aggregate_daily_sales_data
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE FROM resumen_ventas_diarias WHERE fecha=UTC_DATE()-INTERVAL 1 DAY;
 INSERT INTO resumen_ventas_diarias SELECT DATE(fecha_venta),id_sucursal,COUNT(*),SUM(total) FROM ventas WHERE fecha_venta>=UTC_DATE()-INTERVAL 1 DAY AND fecha_venta<UTC_DATE() AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY DATE(fecha_venta),id_sucursal;
 INSERT INTO inventario_diario(fecha,id_sucursal,id_producto,stock,costo,id_categoria_historica)
 SELECT UTC_DATE(),i.id_sucursal,i.id_producto,i.stock,p.costo,p.id_categoria FROM inventario_sucursal i JOIN productos p USING(id_producto) ON DUPLICATE KEY UPDATE stock=VALUES(stock),costo=VALUES(costo),id_categoria_historica=VALUES(id_categoria_historica);
 COMMIT;
END$$
DELIMITER ;

DELIMITER $$
ALTER EVENT evt_update_product_rankings_hourly
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE FROM rankings_productos;
 INSERT INTO rankings_productos SELECT p.id_producto,ROW_NUMBER() OVER(ORDER BY COALESCE(SUM(IF(v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente'),d.cantidad*d.precio_unitario_congelado,0)),0) DESC,p.id_producto),COALESCE(SUM(IF(v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente'),d.cantidad*d.precio_unitario_congelado,0)),0),UTC_TIMESTAMP() FROM productos p LEFT JOIN detalle_ventas d USING(id_producto) LEFT JOIN ventas v USING(id_venta) GROUP BY p.id_producto;
 COMMIT;
END$$
DELIMITER ;

DELIMITER $$
ALTER EVENT evt_calculate_monthly_kpis
DO BEGIN
 DECLARE v_mes DATE;
 SET v_mes=CAST(DATE_FORMAT(UTC_DATE()-INTERVAL 1 MONTH,'%Y-%m-01') AS DATE);
 INSERT INTO kpis_mensuales SELECT v_mes,COUNT(*),COALESCE(SUM(total),0),AVG(total),COUNT(DISTINCT id_cliente) FROM ventas WHERE fecha_venta>=v_mes AND fecha_venta<v_mes+INTERVAL 1 MONTH AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente')
 ON DUPLICATE KEY UPDATE pedidos=VALUES(pedidos),ingresos=VALUES(ingresos),ticket_promedio=VALUES(ticket_promedio),clientes=VALUES(clientes);
END$$
DELIMITER ;

DELIMITER $$
ALTER EVENT evt_refresh_materialized_views_nightly
DO BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 DELETE FROM resumen_ventas_diarias;
 INSERT INTO resumen_ventas_diarias SELECT DATE(fecha_venta),id_sucursal,COUNT(*),SUM(total) FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY DATE(fecha_venta),id_sucursal;
 COMMIT;
END$$
DELIMITER ;

DELIMITER $$
ALTER EVENT evt_generate_supplier_performance_report_monthly
DO BEGIN
 DECLARE v_mes DATE;
 SET v_mes=CAST(DATE_FORMAT(UTC_DATE()-INTERVAL 1 MONTH,'%Y-%m-01') AS DATE);
 INSERT INTO rendimiento_proveedores SELECT v_mes,d.id_proveedor_historico,SUM(d.cantidad),SUM(d.cantidad*d.precio_unitario_congelado) FROM ventas v JOIN detalle_ventas d USING(id_venta) WHERE v.fecha_venta>=v_mes AND v.fecha_venta<v_mes+INTERVAL 1 MONTH AND v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY d.id_proveedor_historico
 ON DUPLICATE KEY UPDATE unidades=VALUES(unidades),ingresos=VALUES(ingresos);
END$$
DELIMITER ;

DELIMITER $$
ALTER EVENT evt_backup_critical_tables_daily
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
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_producto',`id_producto`,'nombre',`nombre`,'descripcion',`descripcion`,'precio',`precio`,'costo',`costo`,'sku',`sku`,'fecha_creacion',`fecha_creacion`,'fecha_modificacion',`fecha_modificacion`,'activo',`activo`,'eliminado_en',`eliminado_en`,'id_categoria',`id_categoria`,'id_proveedor',`id_proveedor`,'peso_kg',`peso_kg`,'stock',`stock`)),JSON_ARRAY()) INTO v_datos FROM productos;
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
 SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id_devolucion',`id_devolucion`,'id_venta',`id_venta`,'id_producto',`id_producto`,'usuario',`usuario`,'estado_anterior',`estado_anterior`,'estado_resultante',`estado_resultante`,'id_detalle',`id_detalle`,'cantidad',`cantidad`,'credito',`credito`,'motivo',`motivo`,'fecha',`fecha`)),JSON_ARRAY()) INTO v_datos FROM devoluciones;
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
DELIMITER ;

CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.resumen_ventas_diarias AS
SELECT DATE(fecha_venta) fecha,id_sucursal,COUNT(*) pedidos,SUM(total) ingresos FROM ecommerce.v_ventas_sucursal WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY DATE(fecha_venta),id_sucursal;

CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.rankings_productos AS
SELECT d.id_producto,ROW_NUMBER() OVER(ORDER BY SUM(d.cantidad*d.precio_unitario_congelado) DESC,d.id_producto) posicion,
SUM(d.cantidad*d.precio_unitario_congelado) ingresos FROM ecommerce.v_detalles_sucursal d JOIN ecommerce.v_ventas_sucursal v USING(id_venta)
WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY d.id_producto;

CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.kpis_mensuales AS
SELECT CAST(DATE_FORMAT(fecha_venta,'%Y-%m-01') AS DATE) mes,COUNT(*) pedidos,SUM(total) ingresos,AVG(total) ticket_promedio,COUNT(DISTINCT id_cliente) clientes
FROM ecommerce.v_ventas_sucursal WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY mes;

CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.rendimiento_proveedores AS
SELECT CAST(DATE_FORMAT(v.fecha_venta,'%Y-%m-01') AS DATE) mes,d.id_proveedor_historico AS id_proveedor,SUM(d.cantidad) unidades,SUM(d.cantidad*d.precio_unitario_congelado) ingresos
FROM ecommerce.v_ventas_sucursal v JOIN ecommerce.v_detalles_sucursal d USING(id_venta) 
WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente') GROUP BY mes,d.id_proveedor_historico;

-- 7. Historial migrado: corregir estados sin reponer stock ni descontar credito otra vez.
UPDATE ventas v SET estado=IF(
 EXISTS(SELECT 1 FROM detalle_ventas d WHERE d.id_venta=v.id_venta
        AND d.cantidad>COALESCE((SELECT SUM(r.cantidad) FROM devoluciones r
                                WHERE r.id_detalle=d.id_detalle),0)),
 'Devolución Parcial','Devuelto Totalmente')
WHERE v.estado='Entregado' AND EXISTS(SELECT 1 FROM devoluciones r WHERE r.id_venta=v.id_venta);

-- 8. Comprobaciones de instalacion, sin crear ventas ni devoluciones de prueba.
SELECT 'Migracion de devoluciones instalada' AS resultado;
SELECT COUNT(*) AS stocks_desincronizados FROM productos p
WHERE p.stock<>COALESCE((SELECT SUM(i.stock) FROM inventario_sucursal i
                         WHERE i.id_producto=p.id_producto),0); -- Esperado: 0.
SELECT COUNT(*) AS devoluciones_excesivas FROM (
 SELECT d.id_detalle FROM detalle_ventas d JOIN devoluciones r USING(id_detalle)
 GROUP BY d.id_detalle,d.cantidad HAVING SUM(r.cantidad)>d.cantidad
) inconsistencias; -- Esperado: 0.

-- EJEMPLO (manual, solo datos de prueba; IDs de una venta ENTREGADA):
-- CALL sp_ProcesarDevolucion(61,1,1);
-- SELECT id_venta,estado,total FROM ventas WHERE id_venta=61;
-- SELECT id_producto,stock FROM productos WHERE id_producto=1;
-- SELECT * FROM v_devoluciones_sucursal WHERE id_venta=61;
-- CASOS A RECHAZAR: 0, negativo, NULL, fraccion, venta inexistente, producto ajeno,
-- venta pendiente/cancelada/totalmente devuelta, exceso acumulado y otra sucursal.
-- NOTA: no escribir directamente Productos.stock; se deriva del inventario local.
-- Los usuarios operativos no reciben UPDATE sobre ese campo ni sobre devoluciones.
