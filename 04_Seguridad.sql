USE ecommerce;
-- Ejecutar como DBA en una instalacion local de desarrollo.
-- Las cuentas nuevas son solo localhost. Se bloquean cuentas root remotas si existen.
-- 1-6,17. Administrador global de MySQL, segun el enunciado.
CREATE ROLE 'Administrador_Sistema','Gerente_Marketing','Analista_Datos','Empleado_Inventario','Atencion_Cliente','Auditor_Financiero','Visitante';
GRANT ALL PRIVILEGES ON *.* TO 'Administrador_Sistema' WITH GRANT OPTION;

-- 13,19. Filtro basado en usuario CONECTADO, nunca en CURRENT_USER() del definidor.
CREATE SQL SECURITY DEFINER VIEW v_ventas_sucursal AS
SELECT v.* FROM ventas v JOIN usuarios_sucursal u ON u.id_sucursal=v.id_sucursal
WHERE u.usuario=SUBSTRING_INDEX(USER(),'@',1);
CREATE SQL SECURITY DEFINER VIEW v_detalles_sucursal AS
SELECT d.* FROM detalle_ventas d JOIN v_ventas_sucursal v USING(id_venta);
CREATE SQL SECURITY DEFINER VIEW v_info_clientes_basica AS
SELECT c.id_cliente,c.nombre,c.apellido,c.ciudad,c.region,c.fecha_registro
FROM clientes c WHERE EXISTS(SELECT 1 FROM v_ventas_sucursal v WHERE v.id_cliente=c.id_cliente);
CREATE SQL SECURITY DEFINER VIEW v_pagos_sucursal AS
SELECT p.* FROM pagos p JOIN v_ventas_sucursal v USING(id_venta);
CREATE SQL SECURITY DEFINER VIEW v_devoluciones_sucursal AS
SELECT r.* FROM devoluciones r JOIN v_detalles_sucursal d USING(id_detalle);
CREATE SQL SECURITY DEFINER VIEW v_catalogo AS
SELECT id_producto,nombre,descripcion,precio,stock,sku,id_categoria FROM productos WHERE activo;
-- 2. Marketing ve informacion basica y ventas de su sucursal, nunca hashes.
GRANT SELECT ON ecommerce.v_ventas_sucursal TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce.v_detalles_sucursal TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce.v_info_clientes_basica TO 'Gerente_Marketing';
-- 3,11. Sin privilegios DELETE, DROP (TRUNCATE), UPDATE ni acceso a auditoria.
GRANT SELECT ON ecommerce.v_ventas_sucursal TO 'Analista_Datos';
GRANT SELECT ON ecommerce.v_detalles_sucursal TO 'Analista_Datos';
GRANT SELECT ON ecommerce.v_info_clientes_basica TO 'Analista_Datos';
GRANT SELECT ON ecommerce.v_pagos_sucursal TO 'Analista_Datos';
GRANT SELECT ON ecommerce.v_devoluciones_sucursal TO 'Analista_Datos';
GRANT SELECT ON ecommerce.productos TO 'Analista_Datos';
GRANT SELECT ON ecommerce.categorias TO 'Analista_Datos';
GRANT SELECT ON ecommerce.proveedores TO 'Analista_Datos';
GRANT SELECT ON ecommerce.sucursales TO 'Analista_Datos';
GRANT SELECT ON ecommerce.promociones TO 'Analista_Datos';
GRANT SELECT ON ecommerce.inventario_diario TO 'Analista_Datos';
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
GRANT SELECT ON ecommerce.v_catalogo TO 'Visitante';

-- 15. Componente oficial de MySQL Community. Requiere privilegios de administrador.
-- Si el DBA ya instalo este componente, omitir solamente la siguiente sentencia.
INSTALL COMPONENT 'file://component_validate_password';
SET GLOBAL validate_password.policy='MEDIUM';
SET GLOBAL validate_password.length=12;
-- Para persistir estos dos valores tras reiniciar: repetir con SET PERSIST (DBA).
-- Las contrasenas de clientes de la tienda son hashes externos, no usuarios del servidor.

-- 7-10. MySQL imprime contrasenas ALEATORIAS al ejecutar; guardarlas fuera del repositorio.
CREATE USER 'admin_user'@'localhost' IDENTIFIED BY RANDOM PASSWORD;
CREATE USER 'marketing_user'@'localhost' IDENTIFIED BY RANDOM PASSWORD;
CREATE USER 'inventory_user'@'localhost' IDENTIFIED BY RANDOM PASSWORD;
CREATE USER 'support_user'@'localhost' IDENTIFIED BY RANDOM PASSWORD;
CREATE USER 'analyst_user'@'localhost' IDENTIFIED BY RANDOM PASSWORD;
CREATE USER 'auditor_user'@'localhost' IDENTIFIED BY RANDOM PASSWORD;
CREATE USER 'visitor_user'@'localhost' IDENTIFIED BY RANDOM PASSWORD;
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
-- 20. Auditoria completa de accesos fallidos NO es un trigger SQL.
-- MySQL Enterprise Audit / plugin compatible o colector del error log son requisitos externos.
-- Consultar README: esta entrega Community no afirma capturar todos los intentos fallidos.
