USE ecommerce;
-- Ejecutar como DBA en una instalacion local de desarrollo.
-- Las cuentas nuevas son solo localhost. Se bloquean cuentas root remotas si existen.
-- 1-6,17. Administrador global de MySQL, segun el enunciado.
CREATE ROLE IF NOT EXISTS 'Administrador_Sistema','Gerente_Marketing','Analista_Datos','Empleado_Inventario','Atencion_Cliente','Auditor_Financiero','Visitante';
GRANT ALL PRIVILEGES ON *.* TO 'Administrador_Sistema' WITH GRANT OPTION;

-- 13,19. Filtro basado en usuario CONECTADO, nunca en CURRENT_USER() del definidor.
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_ventas_sucursal AS
SELECT v.* FROM ventas v WHERE SUBSTRING_INDEX(USER(),'@',1) IN ('root','admin_user')
OR EXISTS(SELECT 1 FROM usuarios_sucursal u WHERE u.id_sucursal=v.id_sucursal AND u.usuario=SUBSTRING_INDEX(USER(),'@',1));
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_detalles_sucursal AS
SELECT d.* FROM detalle_ventas d JOIN v_ventas_sucursal v USING(id_venta);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_info_clientes_basica AS
SELECT c.id_cliente,c.nombre,c.apellido,c.ciudad,c.region,c.fecha_registro
FROM clientes c WHERE EXISTS(SELECT 1 FROM v_ventas_sucursal v WHERE v.id_cliente=c.id_cliente);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_pagos_sucursal AS
SELECT p.* FROM pagos p JOIN v_ventas_sucursal v USING(id_venta);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_devoluciones_sucursal AS
SELECT r.* FROM devoluciones r JOIN v_detalles_sucursal d USING(id_detalle);
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_catalogo AS
SELECT id_producto,nombre,descripcion,precio,stock,sku,id_categoria FROM productos WHERE activo;
-- 2. Marketing ve informacion basica y ventas de su sucursal, nunca hashes.
GRANT SELECT ON ecommerce.v_ventas_sucursal TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce.v_detalles_sucursal TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce.v_info_clientes_basica TO 'Gerente_Marketing';
-- 3,11. Sin privilegios DELETE, DROP (TRUNCATE), UPDATE ni acceso a auditoria.
-- Listas cerradas tambien en ecommerce para impedir eludir las vistas de analitica.
REVOKE IF EXISTS SELECT ON ecommerce.v_ventas_sucursal FROM 'Analista_Datos';
GRANT SELECT (id_venta,id_cliente,id_sucursal,fecha_venta,estado,total,ciudad_envio,region_envio) ON ecommerce.v_ventas_sucursal TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.v_detalles_sucursal FROM 'Analista_Datos';
GRANT SELECT (id_detalle,id_venta,id_producto,cantidad,precio_unitario_congelado,costo_unitario_congelado) ON ecommerce.v_detalles_sucursal TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.v_info_clientes_basica FROM 'Analista_Datos';
GRANT SELECT (id_cliente,nombre,apellido,ciudad,region,fecha_registro) ON ecommerce.v_info_clientes_basica TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.v_pagos_sucursal FROM 'Analista_Datos';
GRANT SELECT (id_pago,id_venta,monto,resultado,fecha) ON ecommerce.v_pagos_sucursal TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.v_devoluciones_sucursal FROM 'Analista_Datos';
GRANT SELECT (id_devolucion,id_detalle,cantidad,credito,fecha) ON ecommerce.v_devoluciones_sucursal TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.productos FROM 'Analista_Datos';
GRANT SELECT (id_producto,nombre,descripcion,precio,costo,stock,sku,activo,id_categoria,id_proveedor,stock_minimo) ON ecommerce.productos TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.categorias FROM 'Analista_Datos';
GRANT SELECT (id_categoria,nombre,descripcion,id_padre,producto_count) ON ecommerce.categorias TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.proveedores FROM 'Analista_Datos';
GRANT SELECT (id_proveedor,nombre) ON ecommerce.proveedores TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.sucursales FROM 'Analista_Datos';
GRANT SELECT (id_sucursal,nombre) ON ecommerce.sucursales TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.promociones FROM 'Analista_Datos';
GRANT SELECT (id_promocion,nombre,id_producto,inicio,fin,descuento,activo) ON ecommerce.promociones TO 'Analista_Datos';
REVOKE IF EXISTS SELECT ON ecommerce.inventario_diario FROM 'Analista_Datos';
GRANT SELECT (fecha,id_producto,stock,costo) ON ecommerce.inventario_diario TO 'Analista_Datos';
-- 4,14. Se demuestra REVOKE antes de conceder el rol a ningun usuario.
GRANT SELECT ON ecommerce.productos TO 'Empleado_Inventario';
GRANT UPDATE(stock,ubicacion,precio) ON ecommerce.productos TO 'Empleado_Inventario';
REVOKE UPDATE(precio) ON ecommerce.productos FROM 'Empleado_Inventario';
-- 5,13. Sin SELECT directo a clientes que permita eludir la vista.
GRANT SELECT ON ecommerce.v_info_clientes_basica TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce.v_ventas_sucursal TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce.v_detalles_sucursal TO 'Atencion_Cliente';
-- 6. El permiso sobre log_cambios_precio se otorga al final de 05, cuando existe.
GRANT SELECT ON ecommerce.v_ventas_sucursal TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce.v_detalles_sucursal TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce.productos TO 'Auditor_Financiero';
-- 17. Solo catalogo publico, sin costos internos.
-- IF EXISTS permite instalar desde cero y corregir un permiso previo (MySQL 8.4).
REVOKE IF EXISTS SELECT ON ecommerce.productos FROM 'Visitante';
GRANT SELECT ON ecommerce.v_catalogo TO 'Visitante';
-- Pruebas manuales en una NUEVA conexion como visitor_user, nunca como DBA:
-- SET ROLE 'Visitante';
-- SELECT costo, ubicacion FROM ecommerce.productos;
-- Esperado: ERROR 1142 (42000), SELECT denegado sobre productos.
-- SELECT * FROM ecommerce.v_catalogo;
-- Esperado: consulta permitida; solo id_producto,nombre,descripcion,precio,stock,sku,id_categoria.

-- 15. Componente oficial de MySQL Community. Requiere privilegios de administrador.
-- Si el DBA ya instalo este componente, omitir solamente la siguiente sentencia.
INSTALL COMPONENT 'file://component_validate_password';
SET PERSIST validate_password.policy='MEDIUM';
SET PERSIST validate_password.length=12;
-- Para persistir estos dos valores tras reiniciar: repetir con SET PERSIST (DBA).
-- Las contrasenas de clientes de la tienda son hashes externos, no usuarios del servidor.

-- 7-10. Generacion aleatoria con reintento si una clave no satisface la politica.
-- Auxiliar de instalacion: se elimina al terminar, no aumenta las 20 rutinas de negocio.
DELIMITER $$
CREATE PROCEDURE _crear_usuario_seguro(IN p_nombre VARCHAR(32))
BEGIN
 DECLARE v_error BOOLEAN DEFAULT FALSE; DECLARE v_intento INT DEFAULT 0;
 IF NOT EXISTS(SELECT 1 FROM mysql.user WHERE User=p_nombre AND Host='localhost') THEN
  SET @crear=CONCAT('CREATE USER ',QUOTE(p_nombre),'@''localhost'' IDENTIFIED BY RANDOM PASSWORD');
  PREPARE cuenta FROM @crear;
  reintento: LOOP
   SET v_error=FALSE;
   BEGIN
    DECLARE CONTINUE HANDLER FOR 1819 SET v_error=TRUE;
    EXECUTE cuenta;
   END;
   SET v_intento=v_intento+1;
   IF NOT v_error THEN LEAVE reintento; END IF;
   IF v_intento>=20 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='No se pudo generar una clave conforme'; END IF;
  END LOOP;
  DEALLOCATE PREPARE cuenta;
 END IF;
END$$
DELIMITER ;
CALL _crear_usuario_seguro('admin_user');
CALL _crear_usuario_seguro('marketing_user');
CALL _crear_usuario_seguro('inventory_user');
CALL _crear_usuario_seguro('support_user');
CALL _crear_usuario_seguro('analyst_user');
CALL _crear_usuario_seguro('auditor_user');
CALL _crear_usuario_seguro('visitor_user');
DROP PROCEDURE _crear_usuario_seguro;
GRANT 'Administrador_Sistema' TO 'admin_user'@'localhost';
GRANT 'Gerente_Marketing' TO 'marketing_user'@'localhost';
GRANT 'Empleado_Inventario' TO 'inventory_user'@'localhost';
GRANT 'Atencion_Cliente' TO 'support_user'@'localhost';
GRANT 'Analista_Datos' TO 'analyst_user'@'localhost';
GRANT 'Auditor_Financiero' TO 'auditor_user'@'localhost';
GRANT 'Visitante' TO 'visitor_user'@'localhost';
SET DEFAULT ROLE ALL TO 'admin_user'@'localhost','marketing_user'@'localhost','inventory_user'@'localhost','support_user'@'localhost','analyst_user'@'localhost','auditor_user'@'localhost','visitor_user'@'localhost';
-- 18. MySQL limita CUENTAS, no roles. Aplicar a cada miembro nuevo de Analista_Datos.
ALTER USER 'analyst_user'@'localhost' WITH MAX_QUERIES_PER_HOUR 200 MAX_USER_CONNECTIONS 3;
-- 12. EXECUTE de reportes: al final de 07 para respetar dependencias.

-- 16. Ejecutar desde root LOCAL: bloquea todas las identidades root remotas.
SET SESSION group_concat_max_len=65535;
SELECT GROUP_CONCAT(CONCAT(QUOTE(User),'@',QUOTE(Host)) SEPARATOR ',') INTO @root_remotos
FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
SET @bloquear_root=IF(@root_remotos IS NULL,'DO 0',CONCAT('ALTER USER ',@root_remotos,' ACCOUNT LOCK'));
PREPARE bloquear FROM @bloquear_root;
EXECUTE bloquear;
DEALLOCATE PREPARE bloquear;
-- Resultado esperado vacio: ninguna cuenta root remota desbloqueada.
SELECT User,Host FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1') AND account_locked='N';
-- 20. Captura nativa de conexiones rechazadas y sentencias de permisos.
-- El servicio incluido conserva una copia deduplicada en las tablas de auditoria.
SET PERSIST log_output='TABLE';
SET PERSIST general_log=ON;
SET PERSIST log_error_verbosity=3;
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_intentos_login_fallidos AS
SELECT event_time,thread_id,user_host,argument FROM mysql.general_log
WHERE command_type='Connect' AND argument LIKE 'Access denied%';
