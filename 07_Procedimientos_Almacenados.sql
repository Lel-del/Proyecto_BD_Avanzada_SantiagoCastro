USE ecommerce;
DELIMITER $$
-- Invocar procedimientos transaccionales fuera de una transaccion del llamador.
-- 1. Items JSON: [{"id_producto":1,"cantidad":2}]. Devuelve @venta mediante OUT.
CREATE PROCEDURE sp_RealizarNuevaVenta(IN p_cliente INT,IN p_sucursal INT,IN p_items JSON,OUT p_venta INT)
SQL SECURITY DEFINER
BEGIN
 DECLARE v_fin BOOLEAN DEFAULT FALSE; DECLARE v_producto INT; DECLARE v_cantidad INT; DECLARE v_activo BOOLEAN;
 DECLARE cur CURSOR FOR SELECT id_producto,cantidad FROM JSON_TABLE(p_items,'$[*]' COLUMNS(id_producto INT PATH '$.id_producto' ERROR ON EMPTY ERROR ON ERROR,cantidad INT PATH '$.cantidad' ERROR ON EMPTY ERROR ON ERROR)) j ORDER BY id_producto;
 DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin=TRUE;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET p_venta=NULL; RESIGNAL; END;
 SET p_venta=NULL;
 IF p_items IS NULL OR JSON_TYPE(p_items)<>'ARRAY' OR JSON_LENGTH(p_items)=0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Se requiere una lista de productos'; END IF;
 IF EXISTS(SELECT 1 FROM JSON_TABLE(p_items,'$[*]' COLUMNS(id_producto INT PATH '$.id_producto',cantidad INT PATH '$.cantidad')) j WHERE id_producto IS NULL OR cantidad IS NULL OR cantidad<=0) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Item invalido'; END IF;
 IF EXISTS(SELECT id_producto FROM JSON_TABLE(p_items,'$[*]' COLUMNS(id_producto INT PATH '$.id_producto')) j GROUP BY id_producto HAVING COUNT(*)>1) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Producto repetido'; END IF;
 START TRANSACTION;
 SELECT activo INTO v_activo FROM clientes WHERE id_cliente=p_cliente FOR UPDATE;
 IF v_activo IS NULL OR NOT v_activo THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cliente inexistente o inactivo'; END IF;
 INSERT INTO ventas(id_cliente,id_sucursal,direccion_envio,ciudad_envio,region_envio)
 SELECT id_cliente,p_sucursal,direccion_envio,ciudad,region FROM clientes WHERE id_cliente=p_cliente;
 SET p_venta=LAST_INSERT_ID();
 SET v_fin=FALSE;
 OPEN cur;
 items: LOOP
  FETCH cur INTO v_producto,v_cantidad;
  IF v_fin THEN LEAVE items; END IF;
  INSERT INTO detalle_ventas(id_venta,id_producto,cantidad,precio_unitario_congelado,costo_unitario_congelado) VALUES(p_venta,v_producto,v_cantidad,1,0);
 END LOOP;
 CLOSE cur;
 COMMIT;
END$$
-- 2. SKU temporal unico, sustituido por el SKU basado en ID dentro de la misma transaccion.
CREATE PROCEDURE sp_AgregarNuevoProducto(IN p_nombre VARCHAR(150),IN p_descripcion TEXT,IN p_precio DECIMAL(12,2),IN p_costo DECIMAL(12,2),IN p_stock INT,IN p_categoria INT,IN p_proveedor INT,IN p_peso DECIMAL(8,3),OUT p_id INT)
BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET p_id=NULL; RESIGNAL; END;
 START TRANSACTION;
 INSERT INTO productos(nombre,descripcion,precio,costo,stock,sku,id_categoria,id_proveedor,peso_kg)
 VALUES(p_nombre,p_descripcion,p_precio,p_costo,p_stock,CONCAT('TMP-',UUID()),p_categoria,p_proveedor,p_peso);
 SET p_id=LAST_INSERT_ID();
 UPDATE productos SET sku=fn_GenerarSKU(nombre,id_categoria,id_producto) WHERE id_producto=p_id;
 COMMIT;
END$$
-- 3. Actualiza perfil y pedidos pendientes. Conserva direccion historica de pedidos pagados.
CREATE PROCEDURE sp_ActualizarDireccionCliente(IN p_id INT,IN p_direccion VARCHAR(300),IN p_ciudad VARCHAR(100),IN p_region VARCHAR(100))
BEGIN
 DECLARE v_id INT;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_direccion IS NULL OR TRIM(p_direccion)='' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Direccion requerida'; END IF;
 START TRANSACTION;
 SELECT id_cliente INTO v_id FROM clientes WHERE id_cliente=p_id FOR UPDATE;
 IF v_id IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cliente inexistente'; END IF;
 UPDATE clientes SET direccion_envio=p_direccion,ciudad=p_ciudad,region=p_region WHERE id_cliente=p_id;
 UPDATE ventas SET direccion_envio=p_direccion,ciudad_envio=p_ciudad,region_envio=p_region WHERE id_cliente=p_id AND estado='Pendiente de Pago';
 COMMIT;
END$$
-- 4. Credito simulado, no transferencia de dinero. Bloquea la venta para evitar doble devolucion.
CREATE PROCEDURE sp_ProcesarDevolucion(IN p_detalle INT,IN p_cantidad INT,IN p_motivo VARCHAR(300))
BEGIN
 DECLARE v_venta INT; DECLARE v_cliente INT; DECLARE v_producto INT; DECLARE v_cantidad INT; DECLARE v_devuelto INT;
 DECLARE v_precio DECIMAL(12,2); DECLARE v_estado VARCHAR(30);
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_cantidad IS NULL OR p_cantidad<=0 OR p_motivo IS NULL OR TRIM(p_motivo)='' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cantidad y motivo requeridos'; END IF;
 START TRANSACTION;
 SELECT id_venta INTO v_venta FROM detalle_ventas WHERE id_detalle=p_detalle;
 SELECT estado,id_cliente INTO v_estado,v_cliente FROM ventas WHERE id_venta=v_venta FOR UPDATE;
 IF v_estado IS NULL OR v_estado<>'Entregado' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Solo se devuelve mercancia entregada'; END IF;
 SELECT id_producto,cantidad,precio_unitario_congelado INTO v_producto,v_cantidad,v_precio FROM detalle_ventas WHERE id_detalle=p_detalle FOR UPDATE;
 SELECT COALESCE(SUM(cantidad),0) INTO v_devuelto FROM devoluciones WHERE id_detalle=p_detalle;
 IF p_cantidad>v_cantidad-v_devuelto THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Devolucion excede cantidad comprada'; END IF;
 INSERT INTO devoluciones(id_detalle,cantidad,credito,motivo) VALUES(p_detalle,p_cantidad,p_cantidad*v_precio,p_motivo);
 UPDATE productos SET stock=stock+p_cantidad WHERE id_producto=v_producto;
 UPDATE clientes SET total_gastado=total_gastado-p_cantidad*v_precio WHERE id_cliente=v_cliente;
 INSERT INTO movimientos_stock(id_producto,diferencia,motivo,usuario) VALUES(v_producto,p_cantidad,CONCAT('Devolucion: ',p_motivo),USER());
 INSERT INTO notificaciones(tipo,entidad_id,contenido) VALUES('Credito devolucion',v_venta,JSON_OBJECT('monto',p_cantidad*v_precio,'simulado',TRUE));
 COMMIT;
END$$
-- 5. Usa la vista filtrada por sucursal; el administrador root consulta tablas directamente.
CREATE PROCEDURE sp_ObtenerHistorialComprasCliente(IN p_cliente INT)
BEGIN SELECT * FROM v_ventas_sucursal WHERE id_cliente=p_cliente ORDER BY fecha_venta DESC,id_venta; END$$
-- 6. Delta positivo o negativo, con motivo obligatorio.
CREATE PROCEDURE sp_AjustarNivelStock(IN p_producto INT,IN p_delta INT,IN p_motivo VARCHAR(300))
SQL SECURITY DEFINER
BEGIN
 DECLARE v_stock INT;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_delta IS NULL OR p_motivo IS NULL OR TRIM(p_motivo)='' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Delta y motivo requeridos'; END IF;
 START TRANSACTION;
 SELECT stock INTO v_stock FROM productos WHERE id_producto=p_producto FOR UPDATE;
 IF v_stock IS NULL OR v_stock+p_delta<0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Ajuste invalido'; END IF;
 UPDATE productos SET stock=stock+p_delta WHERE id_producto=p_producto;
 INSERT INTO movimientos_stock(id_producto,diferencia,motivo,usuario) VALUES(p_producto,p_delta,p_motivo,USER());
 COMMIT;
END$$
-- 7. Conserva IDs y operaciones contables. Bloquea anonimizacion con pedidos pendientes.
CREATE PROCEDURE sp_EliminarClienteDeFormaSegura(IN p_cliente INT)
BEGIN
 DECLARE v_id INT;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 SELECT id_cliente INTO v_id FROM clientes WHERE id_cliente=p_cliente FOR UPDATE;
 IF v_id IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cliente inexistente'; END IF;
 IF EXISTS(SELECT 1 FROM ventas WHERE id_cliente=p_cliente AND estado NOT IN ('Entregado','Cancelado')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Hay pedidos activos'; END IF;
 UPDATE clientes SET nombre='Anonimo',apellido=CONCAT('Cliente',p_cliente),email=CONCAT('anonimo-',p_cliente,'@example.invalid'),contrasena_hash='!DESACTIVADA!',direccion_envio=NULL,ciudad=NULL,region=NULL,fecha_nacimiento=NULL,id_referente=NULL,activo=FALSE,eliminado_en=UTC_TIMESTAMP() WHERE id_cliente=p_cliente;
 UPDATE ventas SET direccion_envio=NULL,ciudad_envio=NULL,region_envio=NULL WHERE id_cliente=p_cliente;
 UPDATE resenas SET comentario=NULL WHERE id_cliente=p_cliente;
 UPDATE visitas_producto SET id_cliente=NULL WHERE id_cliente=p_cliente;
 DELETE dc FROM detalle_carrito dc JOIN carritos c USING(id_carrito) WHERE c.id_cliente=p_cliente;
 DELETE FROM carritos WHERE id_cliente=p_cliente;
 DELETE FROM cupones_cumpleanos WHERE id_cliente=p_cliente;
 COMMIT;
END$$
-- 8. Descuento sobre precio actual; afecta catalogo, nunca detalles historicos.
CREATE PROCEDURE sp_AplicarDescuentoPorCategoria(IN p_categoria INT,IN p_porcentaje DECIMAL(7,2))
BEGIN
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_porcentaje IS NULL OR p_porcentaje<0 OR p_porcentaje>=100 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Descuento debe estar entre 0 y menos de 100'; END IF;
 START TRANSACTION;
 UPDATE productos SET precio=fn_AplicarDescuento(precio,p_porcentaje) WHERE id_categoria=p_categoria AND activo;
 COMMIT;
END$$
-- 9. Reporte de marketing limitado a la sucursal del usuario conectado.
CREATE PROCEDURE sp_GenerarReporteMensualVentas(IN p_anio INT,IN p_mes INT)
BEGIN
 DECLARE v_desde DATE;
 IF p_anio IS NULL OR p_anio NOT BETWEEN 1000 AND 9998 OR p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Mes o anio invalido'; END IF;
 SET v_desde=STR_TO_DATE(CONCAT(p_anio,'-',LPAD(p_mes,2,'0'),'-01'),'%Y-%m-%d');
 SELECT COUNT(*) pedidos,COALESCE(SUM(total),0) ingresos_brutos,AVG(total) ticket_promedio FROM v_ventas_sucursal WHERE fecha_venta>=v_desde AND fecha_venta<v_desde+INTERVAL 1 MONTH AND estado IN ('Pagado','Procesando','Enviado','Entregado');
END$$
-- 10. Pago solo mediante sp_ProcesarPago; notificacion en bandeja de salida.
CREATE PROCEDURE sp_CambiarEstadoPedido(IN p_venta INT,IN p_estado VARCHAR(30))
BEGIN
 DECLARE v_estado VARCHAR(30);
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_estado IS NULL OR p_estado NOT IN ('Procesando','Enviado','Entregado','Cancelado') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Estado destino invalido'; END IF;
 START TRANSACTION;
 SELECT estado INTO v_estado FROM ventas WHERE id_venta=p_venta FOR UPDATE;
 IF v_estado IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Venta inexistente'; END IF;
 UPDATE ventas SET estado=p_estado WHERE id_venta=p_venta;
 IF v_estado<>p_estado THEN INSERT INTO notificaciones(tipo,entidad_id,contenido) VALUES('Estado pedido',p_venta,JSON_OBJECT('estado',p_estado)); END IF;
 COMMIT;
END$$
-- 11. Recibe HASH de la aplicacion; no guarda ni hashea contrasenas en texto plano.
CREATE PROCEDURE sp_RegistrarNuevoCliente(IN p_nombre VARCHAR(100),IN p_apellido VARCHAR(100),IN p_email VARCHAR(254),IN p_hash VARCHAR(255),IN p_nacimiento DATE,OUT p_id INT)
BEGIN
 IF p_nombre IS NULL OR TRIM(p_nombre)='' OR p_apellido IS NULL OR TRIM(p_apellido)='' OR NOT fn_ValidarFormatoEmail(p_email) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Datos de cliente invalidos'; END IF;
 IF p_hash IS NULL OR NOT (p_hash LIKE '$argon2id$%' OR (LEFT(p_hash,4) IN ('$2a$','$2b$','$2y$') AND CHAR_LENGTH(p_hash)=60)) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Se requiere hash Argon2id o bcrypt generado externamente'; END IF;
 INSERT INTO clientes(nombre,apellido,email,contrasena_hash,fecha_nacimiento) VALUES(p_nombre,p_apellido,LOWER(TRIM(p_email)),p_hash,p_nacimiento);
 SET p_id=LAST_INSERT_ID();
END$$
-- 12.
CREATE PROCEDURE sp_ObtenerDetallesProductoCompleto(IN p_id INT)
BEGIN SELECT p.*,c.nombre categoria,pr.nombre proveedor,pr.email_contacto FROM productos p JOIN categorias c USING(id_categoria) JOIN proveedores pr USING(id_proveedor) WHERE p.id_producto=p_id; END$$
-- 13. Solo fusion de cuentas sin pedidos en curso; recalcula gasto neto y referencias.
CREATE PROCEDURE sp_FusionarCuentasCliente(IN p_origen INT,IN p_destino INT)
BEGIN
 DECLARE v_id INT; DECLARE v_activo BOOLEAN;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_origen IS NULL OR p_destino IS NULL OR p_origen=p_destino THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cuentas deben ser distintas'; END IF;
 START TRANSACTION;
 SELECT id_cliente INTO v_id FROM clientes WHERE id_cliente=LEAST(p_origen,p_destino) FOR UPDATE;
 IF v_id IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cuenta inexistente'; END IF;
 SET v_id=NULL;
 SELECT id_cliente INTO v_id FROM clientes WHERE id_cliente=GREATEST(p_origen,p_destino) FOR UPDATE;
 SELECT activo INTO v_activo FROM clientes WHERE id_cliente=p_destino;
 IF v_id IS NULL OR NOT v_activo THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cuenta destino inexistente o inactiva'; END IF;
 IF EXISTS(SELECT 1 FROM ventas WHERE id_cliente IN (p_origen,p_destino) AND estado NOT IN ('Entregado','Cancelado')) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Finalice pedidos antes de fusionar'; END IF;
 UPDATE clientes SET id_referente=NULL WHERE id_cliente=p_destino AND id_referente=p_origen;
 UPDATE clientes SET id_referente=p_destino WHERE id_referente=p_origen AND id_cliente<>p_destino;
 DELETE r FROM resenas r JOIN resenas d ON d.id_producto=r.id_producto AND d.id_cliente=p_destino WHERE r.id_cliente=p_origen;
 UPDATE resenas SET id_cliente=p_destino WHERE id_cliente=p_origen;
 DELETE a FROM cupones_cumpleanos a JOIN cupones_cumpleanos b ON a.anio=b.anio AND b.id_cliente=p_destino WHERE a.id_cliente=p_origen;
 UPDATE cupones_cumpleanos SET id_cliente=p_destino WHERE id_cliente=p_origen;
 UPDATE carritos SET id_cliente=p_destino WHERE id_cliente=p_origen;
 UPDATE visitas_producto SET id_cliente=p_destino WHERE id_cliente=p_origen;
 UPDATE ventas SET id_cliente=p_destino WHERE id_cliente=p_origen;
 UPDATE clientes SET total_gastado=COALESCE((SELECT SUM(total) FROM ventas WHERE id_cliente=p_destino AND estado IN ('Pagado','Procesando','Enviado','Entregado')),0)-COALESCE((SELECT SUM(r.credito) FROM devoluciones r JOIN detalle_ventas d USING(id_detalle) JOIN ventas v USING(id_venta) WHERE v.id_cliente=p_destino),0),ultima_compra=fn_ObtenerUltimaFechaCompra(p_destino) WHERE id_cliente=p_destino;
 UPDATE clientes SET total_gastado=0,ultima_compra=NULL,nombre='Fusionado',apellido=CONCAT('Cliente',p_origen),email=CONCAT('fusionado-',p_origen,'@example.invalid'),contrasena_hash='!DESACTIVADA!',direccion_envio=NULL,ciudad=NULL,region=NULL,fecha_nacimiento=NULL,id_referente=NULL,activo=FALSE,eliminado_en=UTC_TIMESTAMP() WHERE id_cliente=p_origen;
 INSERT INTO auditoria(tipo,entidad_id,datos,usuario) VALUES('Fusion clientes',p_destino,JSON_OBJECT('origen',p_origen),USER());
 COMMIT;
END$$
-- 14.
CREATE PROCEDURE sp_AsignarProductoAProveedor(IN p_producto INT,IN p_proveedor INT)
BEGIN
 IF NOT EXISTS(SELECT 1 FROM productos WHERE id_producto=p_producto) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Producto inexistente'; END IF;
 UPDATE productos SET id_proveedor=p_proveedor WHERE id_producto=p_producto;
END$$
-- 15. Filtros opcionales NULL.
CREATE PROCEDURE sp_BuscarProductos(IN p_nombre VARCHAR(150),IN p_categoria INT,IN p_min DECIMAL(12,2),IN p_max DECIMAL(12,2))
BEGIN
 SELECT id_producto,nombre,precio,stock,id_categoria FROM productos WHERE activo AND (p_nombre IS NULL OR nombre LIKE CONCAT('%',p_nombre,'%')) AND (p_categoria IS NULL OR id_categoria=p_categoria) AND (p_min IS NULL OR precio>=p_min) AND (p_max IS NULL OR precio<=p_max) ORDER BY nombre;
END$$
-- 16. Solo administrador: acceso a indicadores globales.
CREATE PROCEDURE sp_ObtenerDashboardAdmin()
BEGIN
 SELECT (SELECT COALESCE(SUM(total),0) FROM ventas WHERE fecha_venta>=UTC_DATE() AND fecha_venta<UTC_DATE()+INTERVAL 1 DAY AND estado IN ('Pagado','Procesando','Enviado','Entregado')) ventas_hoy,
 (SELECT COUNT(*) FROM clientes WHERE fecha_registro>=UTC_DATE()) nuevos_clientes,
 (SELECT COUNT(*) FROM productos WHERE activo AND stock<stock_minimo) productos_stock_bajo;
END$$
-- 17. Simulacion idempotente por referencia. Reintentos no duplican pagos.
CREATE PROCEDURE sp_ProcesarPago(IN p_venta INT,IN p_referencia VARCHAR(100),IN p_aprobado BOOLEAN)
BEGIN
 DECLARE v_estado VARCHAR(30); DECLARE v_total DECIMAL(16,2); DECLARE v_existente INT; DECLARE v_resultado VARCHAR(15);
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_referencia IS NULL OR TRIM(p_referencia)='' OR p_aprobado IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Referencia y resultado requeridos'; END IF;
 START TRANSACTION;
 SELECT estado,total INTO v_estado,v_total FROM ventas WHERE id_venta=p_venta FOR UPDATE;
 IF v_estado IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Venta inexistente'; END IF;
 SELECT MAX(id_venta),MAX(resultado) INTO v_existente,v_resultado FROM pagos WHERE referencia=p_referencia;
 IF v_existente IS NOT NULL THEN
  IF v_existente<>p_venta OR v_resultado<>IF(p_aprobado,'Aprobado','Fallido') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Referencia usada con otros datos'; END IF;
 ELSE
  IF v_estado<>'Pendiente de Pago' OR v_total<=0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Venta no admite pago'; END IF;
  INSERT INTO pagos(id_venta,referencia,monto,resultado) VALUES(p_venta,p_referencia,v_total,IF(p_aprobado,'Aprobado','Fallido'));
  IF p_aprobado THEN UPDATE ventas SET estado='Pagado' WHERE id_venta=p_venta; END IF;
 END IF;
 COMMIT;
END$$
-- 18. Nombre ASCII equivalente al sp_AnadirResenaProducto del enunciado.
CREATE PROCEDURE sp_AnadirResenaProducto(IN p_cliente INT,IN p_producto INT,IN p_calificacion INT,IN p_comentario TEXT)
BEGIN
 IF NOT EXISTS(SELECT 1 FROM ventas v JOIN detalle_ventas d USING(id_venta) WHERE v.id_cliente=p_cliente AND d.id_producto=p_producto AND v.estado='Entregado') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Solo compradores con entrega pueden opinar'; END IF;
 INSERT INTO resenas(id_cliente,id_producto,calificacion,comentario) VALUES(p_cliente,p_producto,p_calificacion,p_comentario);
END$$
-- 19. Solo devuelve catalogo y conteos anonimos.
CREATE PROCEDURE sp_ObtenerProductosRelacionados(IN p_producto INT)
BEGIN
 SELECT p.id_producto,p.nombre,COUNT(*) compras_juntas FROM detalle_ventas a JOIN detalle_ventas b ON a.id_venta=b.id_venta AND a.id_producto<>b.id_producto JOIN ventas v ON v.id_venta=a.id_venta JOIN productos p ON p.id_producto=b.id_producto WHERE a.id_producto=p_producto AND p.activo AND v.estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY p.id_producto,p.nombre ORDER BY compras_juntas DESC,p.id_producto LIMIT 5;
END$$
-- 20. JSON de IDs; atomico si alguno no pertenece a la categoria origen.
CREATE PROCEDURE sp_MoverProductosEntreCategorias(IN p_origen INT,IN p_destino INT,IN p_ids JSON)
BEGIN
 DECLARE v_categoria INT; DECLARE v_esperados INT;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 IF p_origen IS NULL OR p_destino IS NULL OR p_origen=p_destino OR p_ids IS NULL OR JSON_TYPE(p_ids)<>'ARRAY' OR JSON_LENGTH(p_ids)=0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Categorias o lista invalidas'; END IF;
 START TRANSACTION;
 SELECT id_categoria INTO v_categoria FROM categorias WHERE id_categoria=p_destino FOR UPDATE;
 IF v_categoria IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Categoria destino inexistente'; END IF;
 IF EXISTS(SELECT 1 FROM JSON_TABLE(p_ids,'$[*]' COLUMNS(id INT PATH '$' ERROR ON ERROR)) j LEFT JOIN productos p ON p.id_producto=j.id WHERE p.id_producto IS NULL OR p.id_categoria<>p_origen) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Producto no pertenece a categoria origen'; END IF;
 SELECT COUNT(DISTINCT id) INTO v_esperados FROM JSON_TABLE(p_ids,'$[*]' COLUMNS(id INT PATH '$' ERROR ON ERROR)) j;
 UPDATE productos SET id_categoria=p_destino WHERE id_categoria=p_origen AND id_producto IN (SELECT id FROM JSON_TABLE(p_ids,'$[*]' COLUMNS(id INT PATH '$')) j);
 IF ROW_COUNT()<>v_esperados THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Los productos cambiaron concurrentemente; reintente'; END IF;
 COMMIT;
END$$
DELIMITER ;
-- Permisos de 04 que requieren que los procedimientos ya existan.
GRANT EXECUTE ON PROCEDURE ecommerce.sp_AjustarNivelStock TO 'Empleado_Inventario';
GRANT EXECUTE ON PROCEDURE ecommerce.sp_GenerarReporteMensualVentas TO 'Gerente_Marketing';
GRANT EXECUTE ON PROCEDURE ecommerce.sp_ObtenerHistorialComprasCliente TO 'Atencion_Cliente';

-- Acceso de lectura a TODAS las tablas de negocio mediante un esquema de vistas.
-- Listas cerradas: nuevas columnas internas nunca se publican automaticamente.
-- 02 requiere nombres para VIP/carritos, fechas para cohortes y costos para margen/rotacion.
-- Se excluyen autenticacion, contactos, direcciones exactas, codigos y payloads libres.
-- Las tablas de auditoria/operacion del servicio quedan excluidas expresamente.
-- MySQL no tiene RLS nativo: conceder SELECT directo en ventas eludiria la sucursal.
CREATE DATABASE IF NOT EXISTS analitica CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.sucursales AS SELECT id_sucursal,nombre FROM ecommerce.sucursales;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.categorias AS SELECT id_categoria,nombre,descripcion,id_padre,producto_count FROM ecommerce.categorias;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.proveedores AS SELECT id_proveedor,nombre FROM ecommerce.proveedores;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.productos AS SELECT id_producto,nombre,descripcion,precio,costo,stock,sku,activo,id_categoria,id_proveedor,stock_minimo FROM ecommerce.productos;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.clientes AS SELECT c.id_cliente,c.nombre,c.apellido,c.ciudad,c.region,c.fecha_registro,c.total_gastado,c.ultima_compra,c.nivel_lealtad,c.activo FROM ecommerce.clientes c
WHERE EXISTS(SELECT 1 FROM ecommerce.v_ventas_sucursal v WHERE v.id_cliente=c.id_cliente)
OR NOT EXISTS(SELECT 1 FROM ecommerce.ventas v WHERE v.id_cliente=c.id_cliente);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.ventas AS SELECT id_venta,id_cliente,id_sucursal,fecha_venta,estado,total,ciudad_envio,region_envio FROM ecommerce.v_ventas_sucursal;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.detalle_ventas AS SELECT id_detalle,id_venta,id_producto,cantidad,precio_unitario_congelado,costo_unitario_congelado FROM ecommerce.v_detalles_sucursal;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.devoluciones AS SELECT id_devolucion,id_detalle,cantidad,credito,fecha FROM ecommerce.v_devoluciones_sucursal;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.pagos AS SELECT id_pago,id_venta,monto,resultado,fecha FROM ecommerce.v_pagos_sucursal;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.resenas AS SELECT r.id_resena,r.id_cliente,r.id_producto,r.calificacion,r.fecha FROM ecommerce.resenas r JOIN analitica.clientes c USING(id_cliente);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.carritos AS SELECT r.id_carrito,r.id_cliente,r.actualizado_en,r.estado,r.id_venta FROM ecommerce.carritos r JOIN analitica.clientes c USING(id_cliente);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.detalle_carrito AS SELECT d.id_carrito,d.id_producto,d.cantidad FROM ecommerce.detalle_carrito d JOIN analitica.carritos c USING(id_carrito);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.promociones AS SELECT id_promocion,nombre,id_producto,inicio,fin,descuento,activo FROM ecommerce.promociones;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.visitas_producto AS SELECT v.id_visita,v.id_producto,v.id_cliente,v.fecha FROM ecommerce.visitas_producto v
WHERE id_cliente IS NULL OR EXISTS(SELECT 1 FROM analitica.clientes c WHERE c.id_cliente=v.id_cliente);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.inventario_diario AS SELECT fecha,id_producto,stock,costo FROM ecommerce.inventario_diario;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.usuarios_sucursal AS SELECT id_sucursal FROM ecommerce.usuarios_sucursal WHERE usuario=SUBSTRING_INDEX(USER(),'@',1);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.notificaciones AS SELECT n.id_notificacion,n.tipo,n.entidad_id,n.fecha,n.enviado FROM ecommerce.notificaciones n JOIN ecommerce.v_ventas_sucursal v ON v.id_venta=n.entidad_id;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.reabastecimiento AS SELECT id_producto,stock,sugerido,fecha FROM ecommerce.reabastecimiento;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.resumen_ventas_diarias AS
SELECT DATE(fecha_venta) fecha,id_sucursal,COUNT(*) pedidos,SUM(total) ingresos FROM ecommerce.v_ventas_sucursal WHERE estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY DATE(fecha_venta),id_sucursal;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.rankings_productos AS
SELECT d.id_producto,ROW_NUMBER() OVER(ORDER BY SUM(d.cantidad*d.precio_unitario_congelado) DESC,d.id_producto) posicion,
SUM(d.cantidad*d.precio_unitario_congelado) ingresos FROM ecommerce.v_detalles_sucursal d JOIN ecommerce.v_ventas_sucursal v USING(id_venta)
WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY d.id_producto;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.kpis_mensuales AS
SELECT CAST(DATE_FORMAT(fecha_venta,'%Y-%m-01') AS DATE) mes,COUNT(*) pedidos,SUM(total) ingresos,AVG(total) ticket_promedio,COUNT(DISTINCT id_cliente) clientes
FROM ecommerce.v_ventas_sucursal WHERE estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY mes;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.rendimiento_proveedores AS
SELECT CAST(DATE_FORMAT(v.fecha_venta,'%Y-%m-01') AS DATE) mes,p.id_proveedor,SUM(d.cantidad) unidades,SUM(d.cantidad*d.precio_unitario_congelado) ingresos
FROM ecommerce.v_ventas_sucursal v JOIN ecommerce.v_detalles_sucursal d USING(id_venta) JOIN ecommerce.productos p USING(id_producto)
WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado') GROUP BY mes,p.id_proveedor;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.reporte_ventas_semanales AS
SELECT r.semana,r.id_sucursal,r.pedidos,r.ingresos FROM ecommerce.reporte_ventas_semanales r WHERE EXISTS(SELECT 1 FROM ecommerce.usuarios_sucursal u WHERE u.id_sucursal=r.id_sucursal AND u.usuario=SUBSTRING_INDEX(USER(),'@',1));
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.cupones_cumpleanos AS SELECT r.id_cliente,r.anio FROM ecommerce.cupones_cumpleanos r JOIN analitica.clientes c USING(id_cliente);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW analitica.staging_importacion AS SELECT id,creado_en FROM ecommerce.staging_importacion;
GRANT SELECT ON analitica.* TO 'Analista_Datos';

-- Se habilitan al final de la instalacion, cuando todas las dependencias existen.
ALTER EVENT evt_generate_weekly_sales_report ENABLE;
ALTER EVENT evt_cleanup_temp_tables_daily ENABLE;
ALTER EVENT evt_archive_old_logs_monthly ENABLE;
ALTER EVENT evt_deactivate_expired_promotions_hourly ENABLE;
ALTER EVENT evt_recalculate_customer_loyalty_tiers_nightly ENABLE;
ALTER EVENT evt_generate_reorder_list_daily ENABLE;
ALTER EVENT evt_rebuild_indexes_weekly ENABLE;
ALTER EVENT evt_suspend_inactive_accounts_quarterly ENABLE;
ALTER EVENT evt_aggregate_daily_sales_data ENABLE;
ALTER EVENT evt_check_data_consistency_nightly ENABLE;
ALTER EVENT evt_send_birthday_greetings_daily ENABLE;
ALTER EVENT evt_update_product_rankings_hourly ENABLE;
ALTER EVENT evt_backup_critical_tables_daily ENABLE;
ALTER EVENT evt_clear_abandoned_carts_daily ENABLE;
ALTER EVENT evt_calculate_monthly_kpis ENABLE;
ALTER EVENT evt_refresh_materialized_views_nightly ENABLE;
ALTER EVENT evt_log_database_size_weekly ENABLE;
ALTER EVENT evt_detect_fraudulent_activity_hourly ENABLE;
ALTER EVENT evt_generate_supplier_performance_report_monthly ENABLE;
ALTER EVENT evt_purge_soft_deleted_records_weekly ENABLE;
