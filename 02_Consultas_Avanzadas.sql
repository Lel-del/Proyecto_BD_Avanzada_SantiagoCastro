USE ecommerce;
SET time_zone = '+00:00';
-- Convencion: compra historica = Pagado, Procesando, Enviado, Entregado o devuelta.
-- Los estados de devolucion se incorporan con 08_Examen_Devoluciones.sql.
-- Ingresos brutos de mercancia, salvo donde se indica netos. No incluye envio ni IVA.
-- 1. Top 10 productos por ingresos, no por cantidad.
SELECT p.id_producto,p.nombre,SUM(d.cantidad*d.precio_unitario_congelado) ingresos
FROM productos p JOIN detalle_ventas d USING(id_producto) JOIN ventas v USING(id_venta)
WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') GROUP BY p.id_producto,p.nombre ORDER BY ingresos DESC,p.id_producto LIMIT 10;
-- 2. 10% inferior por unidades; incluye productos con cero ventas. Desempate por ID.
WITH unidades AS (
 SELECT p.id_producto,p.nombre,COALESCE(SUM(IF(v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente'),d.cantidad,0)),0) unidades
 FROM productos p LEFT JOIN detalle_ventas d USING(id_producto) LEFT JOIN ventas v USING(id_venta) GROUP BY p.id_producto,p.nombre
), ranking AS (SELECT *,ROW_NUMBER() OVER(ORDER BY unidades,id_producto) puesto,COUNT(*) OVER() n FROM unidades)
SELECT id_producto,nombre,unidades FROM ranking WHERE puesto<=CEIL(n*0.10) ORDER BY puesto;
-- 3. Clientes VIP: LTV neto de devoluciones.
SELECT id_cliente,nombre,apellido,total_gastado ltv_neto FROM clientes ORDER BY total_gastado DESC,id_cliente LIMIT 5;
-- 4. Ventas mensuales.
SELECT YEAR(fecha_venta) anio,MONTH(fecha_venta) mes,COUNT(*) pedidos,SUM(total) ingresos_brutos
FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') GROUP BY anio,mes ORDER BY anio,mes;
-- 5. Nuevos registros por trimestre.
SELECT YEAR(fecha_registro) anio,QUARTER(fecha_registro) trimestre,COUNT(*) nuevos FROM clientes GROUP BY anio,trimestre ORDER BY anio,trimestre;
-- 6. Repeticion: denominador = clientes con al menos una compra, no todos los registros.
WITH compras AS (SELECT id_cliente,COUNT(*) n FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') GROUP BY id_cliente)
SELECT COUNT(*) compradores,COALESCE(SUM(n>1),0) recurrentes,ROUND(100*SUM(n>1)/NULLIF(COUNT(*),0),2) porcentaje FROM compras;
-- 7. Pares sin duplicados inversos, por numero de pedidos compartidos.
SELECT a.id_producto producto_a,b.id_producto producto_b,COUNT(*) pedidos_juntos
FROM detalle_ventas a JOIN detalle_ventas b ON a.id_venta=b.id_venta AND a.id_producto<b.id_producto
JOIN ventas v ON v.id_venta=a.id_venta WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente')
GROUP BY a.id_producto,b.id_producto ORDER BY pedidos_juntos DESC,producto_a,producto_b;
-- 8. Rotacion por sucursal; sin historia local suficiente devuelve NULL, no historia inventada.
WITH salidas AS (
 SELECT v.id_sucursal,d.id_categoria_historica AS id_categoria,SUM(d.cantidad*d.costo_unitario_congelado) costo_ventas
 FROM detalle_ventas d JOIN ventas v USING(id_venta) JOIN productos p USING(id_producto)
 WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') AND v.fecha_venta>=UTC_DATE()-INTERVAL 30 DAY AND v.fecha_venta<UTC_DATE()
 GROUP BY v.id_sucursal,d.id_categoria_historica
), diarios AS (
 SELECT i.fecha,i.id_sucursal,i.id_categoria_historica AS id_categoria,SUM(i.stock*i.costo) valor FROM inventario_diario i JOIN productos p USING(id_producto)
 WHERE i.fecha>=UTC_DATE()-INTERVAL 30 DAY AND i.fecha<UTC_DATE() GROUP BY i.fecha,i.id_sucursal,i.id_categoria_historica
), promedio AS (SELECT id_sucursal,id_categoria,AVG(valor) inventario_promedio,COUNT(*) dias_observados FROM diarios GROUP BY id_sucursal,id_categoria)
SELECT su.id_sucursal,c.nombre,COALESCE(s.costo_ventas,0) costo_ventas,pr.inventario_promedio,pr.dias_observados,
 ROUND(COALESCE(s.costo_ventas,0)/NULLIF(pr.inventario_promedio,0),4) rotacion
FROM (SELECT DISTINCT id_sucursal FROM inventario_sucursal) su CROSS JOIN categorias c
LEFT JOIN salidas s ON s.id_sucursal=su.id_sucursal AND s.id_categoria=c.id_categoria
LEFT JOIN promedio pr ON pr.id_sucursal=su.id_sucursal AND pr.id_categoria=c.id_categoria;
-- 9. Reabastecimiento independiente por sucursal.
SELECT i.id_sucursal,p.id_producto,p.nombre,i.stock,i.stock_minimo
FROM inventario_sucursal i JOIN productos p USING(id_producto)
WHERE p.activo AND i.stock<i.stock_minimo ORDER BY i.id_sucursal,i.stock,p.id_producto;
-- 10. Carritos abiertos sin conversion, inactivos al menos 24 horas.
SELECT c.id_cliente,c.nombre,ca.id_carrito,ca.actualizado_en,COUNT(*) productos
FROM carritos ca JOIN clientes c USING(id_cliente) JOIN detalle_carrito d USING(id_carrito)
WHERE ca.estado='Abierto' AND ca.id_venta IS NULL AND ca.actualizado_en<UTC_TIMESTAMP()-INTERVAL 24 HOUR
GROUP BY c.id_cliente,c.nombre,ca.id_carrito,ca.actualizado_en;
-- 11. Proveedor congelado al vender; conserva etiquetas historicas y proveedores sin ventas.
WITH identidad AS (
 SELECT id_proveedor,nombre FROM proveedores
 UNION SELECT id_proveedor_historico,proveedor_historico FROM detalle_ventas WHERE id_proveedor_historico IS NOT NULL
)
SELECT pr.id_proveedor,pr.nombre,COALESCE(SUM(IF(v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente'),d.cantidad,0)),0) unidades
FROM identidad pr LEFT JOIN detalle_ventas d ON d.id_proveedor_historico=pr.id_proveedor AND d.proveedor_historico=pr.nombre
LEFT JOIN ventas v USING(id_venta)
GROUP BY pr.id_proveedor,pr.nombre ORDER BY unidades DESC,pr.id_proveedor,pr.nombre;
-- 12. Geografia historica de envio (no direccion actual del cliente).
SELECT region_envio,ciudad_envio,COUNT(*) pedidos,SUM(total) ingresos FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') GROUP BY region_envio,ciudad_envio ORDER BY ingresos DESC;
-- 13. Horas pico en UTC.
SELECT HOUR(fecha_venta) hora_utc,COUNT(*) pedidos,SUM(total) ingresos FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') GROUP BY hora_utc ORDER BY pedidos DESC,hora_utc;
-- 14. Ventanas iguales antes/durante/despues de cada promocion. Correlacion, no causalidad.
WITH periodos AS (
 SELECT id_promocion,id_producto,nombre,'Antes' periodo,inicio-INTERVAL TIMESTAMPDIFF(SECOND,inicio,fin) SECOND desde,inicio hasta FROM promociones
 UNION ALL SELECT id_promocion,id_producto,nombre,'Durante',inicio,fin FROM promociones
 UNION ALL SELECT id_promocion,id_producto,nombre,'Despues',fin,fin+INTERVAL TIMESTAMPDIFF(SECOND,inicio,fin) SECOND FROM promociones
)
SELECT x.id_promocion,x.nombre,x.periodo,COALESCE(SUM(IF(v.id_venta IS NOT NULL,d.cantidad,0)),0) unidades,
 COALESCE(SUM(IF(v.id_venta IS NOT NULL,d.cantidad*d.precio_unitario_congelado,0)),0) ingresos
FROM periodos x LEFT JOIN detalle_ventas d ON d.id_producto=x.id_producto
LEFT JOIN ventas v ON v.id_venta=d.id_venta AND v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') AND v.fecha_venta>=x.desde AND v.fecha_venta<x.hasta
GROUP BY x.id_promocion,x.nombre,x.periodo ORDER BY x.id_promocion,FIELD(x.periodo,'Antes','Durante','Despues');
-- 15. Cohortes desde primera compra. Incluye meses sin retorno y excluye meses futuros.
WITH RECURSIVE compras AS (
 SELECT DISTINCT id_cliente,CAST(DATE_FORMAT(fecha_venta,'%Y-%m-01') AS DATE) mes FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente')
), primeras AS (SELECT id_cliente,MIN(mes) cohorte FROM compras GROUP BY id_cliente),
 tamanos AS (SELECT cohorte,COUNT(*) tamano FROM primeras GROUP BY cohorte),
 calendario AS (SELECT MIN(cohorte) mes FROM primeras UNION ALL SELECT mes+INTERVAL 1 MONTH FROM calendario WHERE mes<CAST(DATE_FORMAT(UTC_DATE(),'%Y-%m-01') AS DATE)),
 actividad AS (SELECT p.cohorte,c.mes,COUNT(*) activos FROM primeras p JOIN compras c USING(id_cliente) GROUP BY p.cohorte,c.mes)
SELECT t.cohorte,TIMESTAMPDIFF(MONTH,t.cohorte,ca.mes) mes_desde_primera,t.tamano,COALESCE(a.activos,0) activos,
 ROUND(100*COALESCE(a.activos,0)/t.tamano,2) retencion FROM tamanos t JOIN calendario ca ON ca.mes>=t.cohorte
LEFT JOIN actividad a ON a.cohorte=t.cohorte AND a.mes=ca.mes ORDER BY t.cohorte,mes_desde_primera;
-- 16. Margen historico neto por producto (sin gastos operativos).
WITH dev AS (SELECT id_detalle,SUM(cantidad) n FROM devoluciones GROUP BY id_detalle)
SELECT p.id_producto,p.nombre,SUM((d.cantidad-COALESCE(r.n,0))*d.precio_unitario_congelado) ingreso_neto,
 SUM((d.cantidad-COALESCE(r.n,0))*(d.precio_unitario_congelado-d.costo_unitario_congelado)) beneficio,
 ROUND(100*SUM((d.cantidad-COALESCE(r.n,0))*(d.precio_unitario_congelado-d.costo_unitario_congelado))/NULLIF(SUM((d.cantidad-COALESCE(r.n,0))*d.precio_unitario_congelado),0),2) margen_pct
FROM productos p JOIN detalle_ventas d USING(id_producto) JOIN ventas v USING(id_venta) LEFT JOIN dev r USING(id_detalle)
WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') GROUP BY p.id_producto,p.nombre;
-- 17. Intervalo entre compras; sin intervalo para compradores de una sola compra.
WITH secuencia AS (SELECT id_cliente,fecha_venta,LAG(fecha_venta) OVER(PARTITION BY id_cliente ORDER BY fecha_venta,id_venta) anterior FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente'))
SELECT id_cliente,ROUND(AVG(TIMESTAMPDIFF(SECOND,anterior,fecha_venta))/86400,2) dias_promedio FROM secuencia WHERE anterior IS NOT NULL GROUP BY id_cliente;
-- 18. Vistas y compras ultimos 30 dias; agregaciones independientes evitan multiplicacion.
WITH vistas AS (SELECT id_producto,COUNT(*) n FROM visitas_producto WHERE fecha>=UTC_TIMESTAMP()-INTERVAL 30 DAY GROUP BY id_producto),
 compras AS (SELECT d.id_producto,COUNT(*) n FROM detalle_ventas d JOIN ventas v USING(id_venta) WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') AND v.fecha_venta>=UTC_TIMESTAMP()-INTERVAL 30 DAY GROUP BY d.id_producto)
SELECT p.id_producto,p.nombre,COALESCE(vi.n,0) visitas,COALESCE(co.n,0) pedidos,
 ROUND(100*COALESCE(co.n,0)/NULLIF(vi.n,0),2) pedidos_por_100_visitas FROM productos p LEFT JOIN vistas vi USING(id_producto) LEFT JOIN compras co USING(id_producto) ORDER BY visitas DESC;
-- 19. RFM: puntuacion alta = mejor. Quintiles con desempate por ID.
WITH base AS (SELECT id_cliente,DATEDIFF(UTC_DATE(),MAX(fecha_venta)) recencia,COUNT(*) frecuencia,SUM(total) monetario FROM ventas WHERE estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') GROUP BY id_cliente),
 puntos AS (SELECT *,NTILE(5) OVER(ORDER BY recencia DESC,id_cliente) r,NTILE(5) OVER(ORDER BY frecuencia,id_cliente) f,NTILE(5) OVER(ORDER BY monetario,id_cliente) m FROM base)
SELECT *,CASE WHEN r>=4 AND f>=4 AND m>=4 THEN 'VIP' WHEN r<=2 THEN 'En riesgo' WHEN f>=4 THEN 'Frecuentes' ELSE 'Regulares' END segmento FROM puntos ORDER BY r+f+m DESC,id_cliente;
-- 20. Media movil de 3 meses COMPLETOS, incluidos meses con cero ventas.
SET @categoria_prediccion=2;
WITH meses AS (SELECT CAST(DATE_FORMAT(UTC_DATE()-INTERVAL 1 MONTH,'%Y-%m-01') AS DATE) mes UNION ALL SELECT CAST(DATE_FORMAT(UTC_DATE()-INTERVAL 2 MONTH,'%Y-%m-01') AS DATE) UNION ALL SELECT CAST(DATE_FORMAT(UTC_DATE()-INTERVAL 3 MONTH,'%Y-%m-01') AS DATE)),
 volumen AS (SELECT CAST(DATE_FORMAT(v.fecha_venta,'%Y-%m-01') AS DATE) mes,SUM(d.cantidad) unidades FROM ventas v JOIN detalle_ventas d USING(id_venta) JOIN productos p USING(id_producto) WHERE v.estado IN ('Pagado','Procesando','Enviado','Entregado','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente','Devolución Parcial','Devuelto Totalmente') AND d.id_categoria_historica=@categoria_prediccion GROUP BY mes)
SELECT @categoria_prediccion id_categoria,DATE_FORMAT(UTC_DATE()+INTERVAL 1 MONTH,'%Y-%m') mes_proyectado,ROUND(AVG(COALESCE(v.unidades,0)),2) unidades_estimadas FROM meses m LEFT JOIN volumen v USING(mes);
