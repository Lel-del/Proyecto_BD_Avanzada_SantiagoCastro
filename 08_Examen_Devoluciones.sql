-- =====================================================================
-- 08_Examen_Devoluciones.sql
-- Proceso de devolucion completo: tabla de auditoria + sp_ProcesarDevolucion.
-- MySQL 8.4 LTS. Ejecutar DESPUES de 01-07, como DBA, con utf8mb4:
--   mysql --default-character-set=utf8mb4 -u root -p
--   SOURCE 08_Examen_Devoluciones.sql;
-- (Los estados llevan tilde: 'Devolución Parcial'. Sin utf8mb4 se corrompen.)
--
-- ADAPTACIONES al proyecto existente (01-07), explicadas donde aplican:
--  a) La tabla `devoluciones` YA existe en 01 (con id_detalle, cantidad,
--     credito, motivo, fecha). CREATE TABLE IF NOT EXISTS la crea completa si
--     no existe; si ya existe, se le AGREGAN las columnas de auditoria que
--     faltan (id_venta, id_producto, estado_venta_resultante, usuario).
--     Se usa minuscula, igual que el resto del esquema (en Linux los nombres
--     de tabla distinguen mayusculas).
--  b) El stock NO esta en `productos`: vive en `inventario_sucursal` por
--     sucursal. El ajuste se aplica a la sucursal de la venta.
--  c) sp_ProcesarDevolucion ya existia en 07 con otra firma
--     (id_detalle, cantidad, motivo). MySQL no permite sobrecarga, asi que
--     se reemplaza por la firma pedida (id_venta, id_producto, cantidad).
--  d) 'Devolución Parcial' y 'Devuelto Totalmente' no existian en el ENUM de
--     ventas.estado; se agregan al final (cambio in-place, sin reordenar).
--  e) Tres triggers de 05 se recrean para aceptar los nuevos estados
--     (maquina de estados, total_gastado y ultima_compra).
-- =====================================================================
USE ecommerce;
SET NAMES utf8mb4;
SET time_zone = '+00:00';

-- ---------------------------------------------------------------------
-- 1. Nuevos estados de venta (se agregan AL FINAL del ENUM).
-- ---------------------------------------------------------------------
ALTER TABLE ventas MODIFY estado ENUM(
  'Pendiente de Pago','Pagado','Procesando','Enviado','Entregado','Cancelado',
  'Devolución Parcial','Devuelto Totalmente'
) NOT NULL DEFAULT 'Pendiente de Pago';

-- ---------------------------------------------------------------------
-- 2. Tabla de auditoria de devoluciones.
--    Instalacion nueva: se crea completa. Ya existente (caso del proyecto):
--    no hace nada y las columnas faltantes se agregan en el paso 3.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devoluciones (
 id_devolucion INT PRIMARY KEY AUTO_INCREMENT,
 id_detalle INT NOT NULL,                       -- linea de venta devuelta
 cantidad INT NOT NULL CHECK(cantidad > 0),     -- unidades devueltas
 credito DECIMAL(16,2) NOT NULL CHECK(credito >= 0), -- cantidad x precio congelado
 motivo VARCHAR(300) NOT NULL,
 fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 id_venta INT NOT NULL,
 id_producto INT NOT NULL,
 estado_venta_resultante VARCHAR(30) NOT NULL,  -- estado de la venta tras esta devolucion
 usuario VARCHAR(288) NOT NULL,                 -- quien la registro (USER())
 FOREIGN KEY(id_detalle) REFERENCES detalle_ventas(id_detalle),
 FOREIGN KEY(id_venta) REFERENCES ventas(id_venta),
 FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. Migracion de la tabla ya existente: agrega columnas solo si faltan.
--    Auxiliar de instalacion, se elimina al terminar.
-- ---------------------------------------------------------------------
DELIMITER $$
CREATE PROCEDURE _agregar_columna_si_falta(IN p_columna VARCHAR(64),IN p_definicion VARCHAR(100))
BEGIN
 IF NOT EXISTS(SELECT 1 FROM information_schema.columns
               WHERE table_schema=DATABASE() AND table_name='devoluciones' AND column_name=p_columna) THEN
  SET @ddl=CONCAT('ALTER TABLE devoluciones ADD COLUMN `',p_columna,'` ',p_definicion);
  PREPARE s FROM @ddl; EXECUTE s; DEALLOCATE PREPARE s;
 END IF;
END$$
DELIMITER ;
CALL _agregar_columna_si_falta('id_venta','INT NULL');
CALL _agregar_columna_si_falta('id_producto','INT NULL');
CALL _agregar_columna_si_falta('estado_venta_resultante','VARCHAR(30) NULL');
CALL _agregar_columna_si_falta('usuario','VARCHAR(288) NULL');
DROP PROCEDURE _agregar_columna_si_falta;
-- Relleno de filas anteriores (si las hubiera) y endurecimiento a NOT NULL.
UPDATE devoluciones r JOIN detalle_ventas d ON d.id_detalle=r.id_detalle
   JOIN ventas v ON v.id_venta=d.id_venta
   SET r.id_venta=d.id_venta, r.id_producto=d.id_producto,
       r.estado_venta_resultante=COALESCE(r.estado_venta_resultante,v.estado),
       r.usuario=COALESCE(r.usuario,'migracion')
 WHERE r.id_venta IS NULL OR r.id_producto IS NULL OR r.estado_venta_resultante IS NULL OR r.usuario IS NULL;
ALTER TABLE devoluciones
  MODIFY id_venta INT NOT NULL,
  MODIFY id_producto INT NOT NULL,
  MODIFY estado_venta_resultante VARCHAR(30) NOT NULL,
  MODIFY usuario VARCHAR(288) NOT NULL;

-- ---------------------------------------------------------------------
-- 4. Triggers de 05 recreados para reconocer los nuevos estados.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_log_order_status_change;
DROP TRIGGER IF EXISTS trg_update_total_gastado_cliente;
DROP TRIGGER IF EXISTS trg_update_last_order_date_customer;
DELIMITER $$
-- 4.1 Maquina de estados: igual que en 05 + Entregado -> devolucion,
--     y Devolucion Parcial -> Devuelto Totalmente. Cancelados siguen cerrados.
CREATE TRIGGER trg_log_order_status_change BEFORE UPDATE ON ventas FOR EACH ROW
BEGIN
 IF NEW.id_cliente<>OLD.id_cliente AND NOT EXISTS(SELECT 1 FROM contexto_fusion WHERE conexion=CONNECTION_ID() AND origen=OLD.id_cliente AND destino=NEW.id_cliente) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cliente de venta inmutable; use fusion controlada'; END IF;
 IF NEW.id_sucursal<>OLD.id_sucursal THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='La sucursal historica es inmutable'; END IF;
 IF NEW.estado<>OLD.estado THEN
  IF NOT ((OLD.estado='Pendiente de Pago' AND NEW.estado IN ('Pagado','Cancelado'))
       OR (OLD.estado='Pagado' AND NEW.estado IN ('Procesando','Cancelado'))
       OR (OLD.estado='Procesando' AND NEW.estado IN ('Enviado','Cancelado'))
       OR (OLD.estado='Enviado' AND NEW.estado='Entregado')
       OR (OLD.estado='Entregado' AND NEW.estado IN ('Devolución Parcial','Devuelto Totalmente'))
       OR (OLD.estado='Devolución Parcial' AND NEW.estado='Devuelto Totalmente')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Transicion de estado no permitida'; END IF;
  IF NEW.estado='Pagado' AND (NEW.total<=0 OR NOT EXISTS(SELECT 1 FROM detalle_ventas WHERE id_venta=OLD.id_venta)) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='No se paga una venta vacia'; END IF;
  INSERT INTO auditoria(tipo,entidad_id,datos,usuario) VALUES('Estado pedido',OLD.id_venta,JSON_OBJECT('antes',OLD.estado,'despues',NEW.estado),USER());
 END IF;
 IF OLD.estado<>'Pendiente de Pago' AND NEW.total<>OLD.total THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Total historico inmutable'; END IF;
END$$
-- 4.2 total_gastado: una venta devuelta SIGUE contando como compra; el credito
--     lo descuenta sp_ProcesarDevolucion. Si no, se restaria dos veces.
CREATE TRIGGER trg_update_total_gastado_cliente AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
 DECLARE v_antes DECIMAL(16,2); DECLARE v_despues DECIMAL(16,2);
 SET v_antes=IF(OLD.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente'),OLD.total,0);
 SET v_despues=IF(NEW.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente'),NEW.total,0);
 IF NEW.id_cliente=OLD.id_cliente THEN
  UPDATE clientes SET total_gastado=total_gastado+v_despues-v_antes WHERE id_cliente=NEW.id_cliente;
 END IF;
 IF NEW.estado='Cancelado' AND OLD.estado<>'Cancelado' THEN
  INSERT INTO movimientos_stock(id_sucursal,id_producto,diferencia,motivo,usuario) SELECT NEW.id_sucursal,id_producto,cantidad,CONCAT('Cancelacion ',NEW.id_venta),USER() FROM detalle_ventas WHERE id_venta=NEW.id_venta;
  UPDATE inventario_sucursal i JOIN detalle_ventas d ON d.id_producto=i.id_producto SET i.stock=i.stock+d.cantidad WHERE d.id_venta=NEW.id_venta AND i.id_sucursal=NEW.id_sucursal;
  IF v_antes>0 THEN INSERT INTO notificaciones(tipo,entidad_id,contenido) VALUES('Credito cancelacion',NEW.id_venta,JSON_OBJECT('monto',OLD.total,'simulado',TRUE)); END IF;
 END IF;
END$$
-- 4.3 ultima_compra: las ventas devueltas tambien fueron compras.
CREATE TRIGGER trg_update_last_order_date_customer AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
 IF NEW.estado<>OLD.estado OR NEW.id_cliente<>OLD.id_cliente THEN
  UPDATE clientes SET ultima_compra=(SELECT MAX(fecha_venta) FROM ventas WHERE id_cliente=NEW.id_cliente AND estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente')) WHERE id_cliente=NEW.id_cliente;
 END IF;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 5. sp_ProcesarDevolucion(id_venta, id_producto, cantidad_devuelta)
--    Reemplaza la version de 07 (firma distinta).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ProcesarDevolucion;
DELIMITER $$
CREATE PROCEDURE sp_ProcesarDevolucion(IN p_id_venta INT,IN p_id_producto INT,IN p_cantidad_devuelta INT)
SQL SECURITY DEFINER
BEGIN
 DECLARE v_estado VARCHAR(30); DECLARE v_estado_nuevo VARCHAR(30);
 DECLARE v_cliente INT; DECLARE v_sucursal INT;
 DECLARE v_detalle INT; DECLARE v_comprada INT; DECLARE v_precio DECIMAL(12,2);
 DECLARE v_ya_devuelta INT; DECLARE v_stock INT;
 DECLARE v_total_comprado BIGINT; DECLARE v_total_devuelto BIGINT;
 DECLARE v_credito DECIMAL(16,2);
 -- 5.0 TRANSACCIONALIDAD: ante CUALQUIER error se deshace todo y se re-lanza.
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

 IF p_id_venta IS NULL OR p_id_producto IS NULL OR p_cantidad_devuelta IS NULL OR p_cantidad_devuelta<=0 THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Venta, producto y cantidad (>0) son requeridos';
 END IF;

 START TRANSACTION;
 -- Bloquea la venta: dos devoluciones simultaneas de la misma venta se serializan.
 SELECT estado,id_cliente,id_sucursal INTO v_estado,v_cliente,v_sucursal FROM ventas WHERE id_venta=p_id_venta FOR UPDATE;
 IF v_estado IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Venta inexistente'; END IF;
 -- Misma regla de sucursal que el resto de procedimientos (root/admin_user exentos).
 IF SUBSTRING_INDEX(USER(),'@',1) NOT IN ('root','admin_user') AND NOT EXISTS(SELECT 1 FROM usuarios_sucursal WHERE usuario=SUBSTRING_INDEX(USER(),'@',1) AND id_sucursal=v_sucursal) THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Sucursal no autorizada';
 END IF;
 -- Solo se devuelve mercancia ya entregada (o de una venta ya devuelta en parte).
 IF v_estado NOT IN ('Entregado','Devolución Parcial') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Solo se devuelve mercancia entregada'; END IF;

 -- 5.1 VALIDACION: la linea debe pertenecer a la venta (UNIQUE id_venta,id_producto).
 SELECT id_detalle,cantidad,precio_unitario_congelado INTO v_detalle,v_comprada,v_precio FROM detalle_ventas WHERE id_venta=p_id_venta AND id_producto=p_id_producto FOR UPDATE;
 IF v_detalle IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='El producto no pertenece a la venta'; END IF;
 -- La cantidad no puede superar lo comprado MENOS lo ya devuelto antes (evita devolver dos veces).
 SELECT COALESCE(SUM(cantidad),0) INTO v_ya_devuelta FROM devoluciones WHERE id_detalle=v_detalle;
 IF p_cantidad_devuelta>v_comprada-v_ya_devuelta THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Devolucion excede cantidad comprada'; END IF;
 -- El credito usa el precio CONGELADO al vender, no el precio actual del catalogo.
 SET v_credito=p_cantidad_devuelta*v_precio;

 -- 5.3 Estado resultante: totalmente devuelto solo si, sumando TODAS las lineas
 --     de la venta, lo devuelto (incluida esta devolucion) iguala lo comprado.
 SELECT SUM(cantidad) INTO v_total_comprado FROM detalle_ventas WHERE id_venta=p_id_venta;
 SELECT COALESCE(SUM(r.cantidad),0) INTO v_total_devuelto FROM devoluciones r JOIN detalle_ventas d ON d.id_detalle=r.id_detalle WHERE d.id_venta=p_id_venta;
 SET v_estado_nuevo=IF(v_total_devuelto+p_cantidad_devuelta>=v_total_comprado,'Devuelto Totalmente','Devolución Parcial');

 -- 5.4 AUDITORIA: registro de la operacion.
 INSERT INTO devoluciones(id_detalle,cantidad,credito,motivo,id_venta,id_producto,estado_venta_resultante,usuario)
 VALUES(v_detalle,p_cantidad_devuelta,v_credito,'Devolucion registrada por sp_ProcesarDevolucion',p_id_venta,p_id_producto,v_estado_nuevo,USER());

 -- 5.2 AJUSTE DE INVENTARIO: el stock vive en inventario_sucursal (sucursal de la venta).
 SELECT stock INTO v_stock FROM inventario_sucursal WHERE id_sucursal=v_sucursal AND id_producto=p_id_producto FOR UPDATE;
 IF v_stock IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Inventario no inicializado'; END IF;
 UPDATE inventario_sucursal SET stock=stock+p_cantidad_devuelta WHERE id_sucursal=v_sucursal AND id_producto=p_id_producto;
 INSERT INTO movimientos_stock(id_sucursal,id_producto,diferencia,motivo,usuario) VALUES(v_sucursal,p_id_producto,p_cantidad_devuelta,CONCAT('Devolucion venta ',p_id_venta),USER());

 -- 5.3 ESTADO DE LA VENTA (el trigger valida la transicion y deja rastro en auditoria).
 IF v_estado_nuevo<>v_estado THEN UPDATE ventas SET estado=v_estado_nuevo WHERE id_venta=p_id_venta; END IF;

 -- Gasto neto del cliente (el total bruto de la venta no se reescribe) y credito simulado.
 UPDATE clientes SET total_gastado=total_gastado-v_credito WHERE id_cliente=v_cliente;
 INSERT INTO notificaciones(tipo,entidad_id,contenido) VALUES('Credito devolucion',p_id_venta,JSON_OBJECT('monto',v_credito,'simulado',TRUE));
 COMMIT;

 SELECT p_id_venta AS id_venta,p_id_producto AS id_producto,p_cantidad_devuelta AS cantidad_devuelta,v_credito AS credito,v_estado_nuevo AS estado_venta;
END$$
DELIMITER ;

-- Atencion al cliente es quien opera devoluciones. Requiere los roles de 04.
-- (DROP PROCEDURE elimina permisos previos: se conceden de nuevo aqui.)
GRANT EXECUTE ON PROCEDURE ecommerce.sp_ProcesarDevolucion TO 'Atencion_Cliente';

-- =====================================================================
-- PRUEBAS (comentadas: modifican datos de demostracion; correr UNA vez).
-- Venta 2 de los datos de ejemplo: cliente 2, sucursal 1, Entregado,
-- 3 x Monitor (id 3, 800) + 3 x Auriculares (id 4, 150) = 2850 bruto.
-- =====================================================================
-- SET @m=(SELECT stock FROM inventario_sucursal WHERE id_sucursal=1 AND id_producto=3);
-- SET @a=(SELECT stock FROM inventario_sucursal WHERE id_sucursal=1 AND id_producto=4);
-- SET @g=(SELECT total_gastado FROM clientes WHERE id_cliente=2);
-- CALL sp_ProcesarDevolucion(2,3,1);  -- credito 800,  estado 'Devolución Parcial'
-- CALL sp_ProcesarDevolucion(2,3,2);  -- credito 1600, sigue Parcial (faltan auriculares)
-- CALL sp_ProcesarDevolucion(2,3,1);  -- ERROR: Devolucion excede cantidad comprada
-- CALL sp_ProcesarDevolucion(2,4,3);  -- credito 450,  estado 'Devuelto Totalmente'
-- SELECT stock=@m+3 AS monitor_ok FROM inventario_sucursal WHERE id_sucursal=1 AND id_producto=3;
-- SELECT stock=@a+3 AS auriculares_ok FROM inventario_sucursal WHERE id_sucursal=1 AND id_producto=4;
-- SELECT estado,total FROM ventas WHERE id_venta=2;           -- 'Devuelto Totalmente', 2850.00
-- SELECT total_gastado=@g-2850 AS gasto_neto_ok FROM clientes WHERE id_cliente=2;
-- SELECT id_devolucion,id_venta,id_producto,cantidad,credito,estado_venta_resultante,usuario FROM devoluciones WHERE id_venta=2;
-- SELECT tipo,datos FROM auditoria WHERE tipo='Estado pedido' AND entidad_id=2 ORDER BY id_log;
-- Pruebas negativas (cada una debe dar ERROR y no cambiar nada):
-- CALL sp_ProcesarDevolucion(2,4,1);   -- Solo se devuelve mercancia entregada (ya totalmente devuelta)
-- CALL sp_ProcesarDevolucion(7,1,1);   -- venta 7 esta Pendiente de Pago
-- CALL sp_ProcesarDevolucion(3,1,1);   -- el producto 1 no pertenece a la venta 3
-- CALL sp_ProcesarDevolucion(3,4,0);   -- cantidad invalida
-- Cuadre (debe devolver cero filas): totales brutos intactos.
-- SELECT id_venta,total FROM ventas v WHERE total<>(SELECT COALESCE(SUM(cantidad*precio_unitario_congelado),0) FROM detalle_ventas d WHERE d.id_venta=v.id_venta);
