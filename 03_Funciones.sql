USE ecommerce;
DELIMITER $$
-- 1. Total bruto historico; las devoluciones se registran por separado.
CREATE FUNCTION fn_CalcularTotalVenta(p_id INT) RETURNS DECIMAL(16,2) READS SQL DATA
BEGIN RETURN (SELECT COALESCE(SUM(cantidad*precio_unitario_congelado),0) FROM detalle_ventas WHERE id_venta=p_id); END$$
-- 2.
CREATE FUNCTION fn_VerificarDisponibilidadStock(p_id INT,p_cantidad INT) RETURNS BOOLEAN READS SQL DATA
BEGIN RETURN COALESCE((SELECT activo AND stock>=p_cantidad AND p_cantidad>0 FROM productos WHERE id_producto=p_id),FALSE); END$$
-- 3.
CREATE FUNCTION fn_ObtenerPrecioProducto(p_id INT) RETURNS DECIMAL(12,2) READS SQL DATA
BEGIN RETURN (SELECT precio FROM productos WHERE id_producto=p_id); END$$
-- 4.
CREATE FUNCTION fn_CalcularEdadCliente(p_id INT) RETURNS INT READS SQL DATA
BEGIN RETURN (SELECT TIMESTAMPDIFF(YEAR,fecha_nacimiento,UTC_DATE()) FROM clientes WHERE id_cliente=p_id); END$$
-- 5.
CREATE FUNCTION fn_FormatearNombreCompleto(p_id INT) RETURNS VARCHAR(201) READS SQL DATA
BEGIN RETURN (SELECT CONCAT(TRIM(nombre),' ',TRIM(apellido)) FROM clientes WHERE id_cliente=p_id); END$$
-- 6. Primera compra pagada, no fecha de registro.
CREATE FUNCTION fn_EsClienteNuevo(p_id INT) RETURNS BOOLEAN READS SQL DATA
BEGIN RETURN COALESCE((SELECT MIN(fecha_venta) BETWEEN UTC_TIMESTAMP()-INTERVAL 30 DAY AND UTC_TIMESTAMP() FROM ventas WHERE id_cliente=p_id AND estado IN ('Pagado','Procesando','Enviado','Entregado')),FALSE); END$$
-- 7. Tarifa didactica: base 5 + 2 por kg; no se agrega al total de mercancia.
CREATE FUNCTION fn_CalcularCostoEnvio(p_id INT) RETURNS DECIMAL(12,2) READS SQL DATA
BEGIN RETURN (SELECT IF(COUNT(*)=0,0,ROUND(5+2*SUM(d.cantidad*p.peso_kg),2)) FROM detalle_ventas d JOIN productos p USING(id_producto) WHERE d.id_venta=p_id); END$$
-- 8.
CREATE FUNCTION fn_AplicarDescuento(p_monto DECIMAL(16,2),p_porcentaje DECIMAL(7,2)) RETURNS DECIMAL(16,2) DETERMINISTIC NO SQL
BEGIN
 IF p_monto IS NULL OR p_monto<0 OR p_porcentaje IS NULL OR p_porcentaje NOT BETWEEN 0 AND 100 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Monto o descuento invalido'; END IF;
 RETURN ROUND(p_monto*(1-p_porcentaje/100),2);
END$$
-- 9.
CREATE FUNCTION fn_ObtenerUltimaFechaCompra(p_id INT) RETURNS DATETIME READS SQL DATA
BEGIN RETURN (SELECT MAX(fecha_venta) FROM ventas WHERE id_cliente=p_id AND estado IN ('Pagado','Procesando','Enviado','Entregado')); END$$
-- 10. Validacion sintactica basica, no comprueba existencia del buzon.
CREATE FUNCTION fn_ValidarFormatoEmail(p_email VARCHAR(254)) RETURNS BOOLEAN DETERMINISTIC NO SQL
BEGIN RETURN COALESCE(REGEXP_LIKE(p_email,'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$','c'),FALSE); END$$
-- 11.
CREATE FUNCTION fn_ObtenerNombreCategoria(p_id INT) RETURNS VARCHAR(100) READS SQL DATA
BEGIN RETURN (SELECT c.nombre FROM productos p JOIN categorias c USING(id_categoria) WHERE p.id_producto=p_id); END$$
-- 12.
CREATE FUNCTION fn_ContarVentasCliente(p_id INT) RETURNS INT READS SQL DATA
BEGIN RETURN (SELECT COUNT(*) FROM ventas WHERE id_cliente=p_id AND estado IN ('Pagado','Procesando','Enviado','Entregado')); END$$
-- 13. NULL significa que nunca ha comprado.
CREATE FUNCTION fn_CalcularDiasDesdeUltimaCompra(p_id INT) RETURNS INT READS SQL DATA
BEGIN RETURN DATEDIFF(UTC_DATE(),fn_ObtenerUltimaFechaCompra(p_id)); END$$
-- 14. Umbrales de demostracion en unidades monetarias del proyecto.
CREATE FUNCTION fn_DeterminarEstadoLealtad(p_id INT) RETURNS VARCHAR(10) READS SQL DATA
BEGIN RETURN (SELECT CASE WHEN total_gastado>=5000 THEN 'Oro' WHEN total_gastado>=1000 THEN 'Plata' ELSE 'Bronce' END FROM clientes WHERE id_cliente=p_id); END$$
-- 15. El ID autoincremental aporta unicidad; UNIQUE en productos es la garantia final.
CREATE FUNCTION fn_GenerarSKU(p_nombre VARCHAR(150),p_categoria INT,p_id INT) RETURNS VARCHAR(100) DETERMINISTIC NO SQL
BEGIN
 IF p_id IS NULL OR p_id<=0 OR p_categoria IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='SKU requiere ID y categoria'; END IF;
 RETURN CONCAT('C',p_categoria,'-',UPPER(LEFT(REGEXP_REPLACE(p_nombre,'[^A-Za-z0-9]',''),12)),'-',p_id);
END$$
-- 16. Tasa explicita: ejemplo academico, no regla fiscal de una jurisdiccion.
CREATE FUNCTION fn_CalcularIVA(p_id INT,p_tasa DECIMAL(7,2)) RETURNS DECIMAL(16,2) READS SQL DATA
BEGIN
 IF p_tasa IS NULL OR p_tasa NOT BETWEEN 0 AND 100 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Tasa invalida'; END IF;
 RETURN ROUND(fn_CalcularTotalVenta(p_id)*p_tasa/100,2);
END$$
-- 17.
CREATE FUNCTION fn_ObtenerStockTotalPorCategoria(p_id INT) RETURNS BIGINT READS SQL DATA
BEGIN RETURN (SELECT COALESCE(SUM(stock),0) FROM productos WHERE id_categoria=p_id); END$$
-- 18. Dias naturales: Centro 2, Norte 3, otras regiones 5.
CREATE FUNCTION fn_EstimarFechaEntrega(p_id INT) RETURNS DATE READS SQL DATA
BEGIN RETURN (SELECT DATE(fecha_venta)+INTERVAL (CASE region_envio WHEN 'Centro' THEN 2 WHEN 'Norte' THEN 3 ELSE 5 END) DAY FROM ventas WHERE id_venta=p_id); END$$
-- 19. Tasa fija proporcionada por quien llama, sin cotizaciones externas.
CREATE FUNCTION fn_ConvertirMoneda(p_monto DECIMAL(16,2),p_tasa DECIMAL(16,6)) RETURNS DECIMAL(18,2) DETERMINISTIC NO SQL
BEGIN
 IF p_monto IS NULL OR p_monto<0 OR p_tasa IS NULL OR p_tasa<=0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Monto o tasa invalida'; END IF;
 RETURN ROUND(p_monto*p_tasa,2);
END$$
-- 20. Solo demostracion. La aplicacion valida ANTES de generar Argon2id/bcrypt.
CREATE FUNCTION fn_ValidarComplejidadContrasena(p_texto VARCHAR(255)) RETURNS BOOLEAN DETERMINISTIC NO SQL
BEGIN RETURN COALESCE(CHAR_LENGTH(p_texto)>=12 AND REGEXP_LIKE(p_texto,'[A-Z]','c') AND REGEXP_LIKE(p_texto,'[a-z]','c') AND REGEXP_LIKE(p_texto,'[0-9]','c') AND REGEXP_LIKE(p_texto,'[^A-Za-z0-9]','c'),FALSE); END$$
DELIMITER ;
