-- MySQL 8.4 LTS. Base nueva: este archivo no borra bases existentes.
CREATE DATABASE ecommerce CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE ecommerce;
SET NAMES utf8mb4;
SET time_zone = '+00:00';

CREATE TABLE sucursales (
 id_sucursal INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(100) NOT NULL UNIQUE
) ENGINE=InnoDB;
CREATE TABLE categorias (
 id_categoria INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(100) NOT NULL UNIQUE,
 descripcion TEXT, id_padre INT NULL, producto_count INT NOT NULL DEFAULT 0,
 FOREIGN KEY(id_padre) REFERENCES categorias(id_categoria),
 CHECK(producto_count >= 0)
) ENGINE=InnoDB;
CREATE TABLE proveedores (
 id_proveedor INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(150) NOT NULL,
 email_contacto VARCHAR(254) UNIQUE, telefono_contacto VARCHAR(30)
) ENGINE=InnoDB;
CREATE TABLE productos (
 id_producto INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(150) NOT NULL UNIQUE,
 descripcion TEXT, precio DECIMAL(12,2) NOT NULL CHECK(precio > 0),
 costo DECIMAL(12,2) NOT NULL CHECK(costo >= 0),
 stock INT NOT NULL DEFAULT 0 CHECK(stock >= 0), sku VARCHAR(100) NOT NULL UNIQUE,
 fecha_creacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 fecha_modificacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 activo BOOLEAN NOT NULL DEFAULT TRUE, eliminado_en DATETIME NULL,
 id_categoria INT NOT NULL, id_proveedor INT NOT NULL,
 stock_minimo INT NOT NULL DEFAULT 5 CHECK(stock_minimo >= 0),
 peso_kg DECIMAL(8,3) NOT NULL DEFAULT 0 CHECK(peso_kg >= 0), ubicacion VARCHAR(100),
 FOREIGN KEY(id_categoria) REFERENCES categorias(id_categoria),
 FOREIGN KEY(id_proveedor) REFERENCES proveedores(id_proveedor)
) ENGINE=InnoDB;
CREATE TABLE clientes (
 id_cliente INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(100) NOT NULL,
 apellido VARCHAR(100) NOT NULL, email VARCHAR(254) NOT NULL UNIQUE,
 contrasena_hash VARCHAR(255) NOT NULL, direccion_envio VARCHAR(300),
 ciudad VARCHAR(100), region VARCHAR(100), fecha_nacimiento DATE,
 fecha_registro DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 total_gastado DECIMAL(16,2) NOT NULL DEFAULT 0 CHECK(total_gastado >= 0),
 ultima_compra DATETIME NULL, nivel_lealtad ENUM('Bronce','Plata','Oro') NOT NULL DEFAULT 'Bronce',
 activo BOOLEAN NOT NULL DEFAULT TRUE, eliminado_en DATETIME,
 id_referente INT NULL, FOREIGN KEY(id_referente) REFERENCES clientes(id_cliente)
) ENGINE=InnoDB;
CREATE TABLE ventas (
 id_venta INT PRIMARY KEY AUTO_INCREMENT, id_cliente INT NOT NULL, id_sucursal INT NOT NULL,
 fecha_venta DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 estado ENUM('Pendiente de Pago','Pagado','Procesando','Enviado','Entregado','Cancelado') NOT NULL DEFAULT 'Pendiente de Pago',
 total DECIMAL(16,2) NOT NULL DEFAULT 0 CHECK(total >= 0),
 direccion_envio VARCHAR(300), ciudad_envio VARCHAR(100), region_envio VARCHAR(100),
 eliminado_en DATETIME NULL,
 FOREIGN KEY(id_cliente) REFERENCES clientes(id_cliente),
 FOREIGN KEY(id_sucursal) REFERENCES sucursales(id_sucursal),
 INDEX ix_ventas_cliente_fecha(id_cliente,fecha_venta), INDEX ix_ventas_fecha(fecha_venta)
) ENGINE=InnoDB;
CREATE TABLE detalle_ventas (
 id_detalle INT PRIMARY KEY AUTO_INCREMENT, id_venta INT NOT NULL, id_producto INT NOT NULL,
 cantidad INT NOT NULL CHECK(cantidad > 0),
 precio_unitario_congelado DECIMAL(12,2) NOT NULL CHECK(precio_unitario_congelado > 0),
 costo_unitario_congelado DECIMAL(12,2) NOT NULL CHECK(costo_unitario_congelado >= 0),
 UNIQUE(id_venta,id_producto), FOREIGN KEY(id_venta) REFERENCES ventas(id_venta),
 FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;
CREATE TABLE devoluciones (
 id_devolucion INT PRIMARY KEY AUTO_INCREMENT, id_detalle INT NOT NULL,
 cantidad INT NOT NULL CHECK(cantidad > 0), credito DECIMAL(16,2) NOT NULL CHECK(credito >= 0),
 motivo VARCHAR(300) NOT NULL, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 FOREIGN KEY(id_detalle) REFERENCES detalle_ventas(id_detalle)
) ENGINE=InnoDB;
CREATE TABLE pagos (
 id_pago INT PRIMARY KEY AUTO_INCREMENT, id_venta INT NOT NULL,
 referencia VARCHAR(100) NOT NULL UNIQUE, monto DECIMAL(16,2) NOT NULL CHECK(monto > 0),
 resultado ENUM('Aprobado','Fallido') NOT NULL, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 FOREIGN KEY(id_venta) REFERENCES ventas(id_venta)
) ENGINE=InnoDB;
CREATE TABLE resenas (
 id_resena INT PRIMARY KEY AUTO_INCREMENT, id_cliente INT NOT NULL, id_producto INT NOT NULL,
 calificacion INT NOT NULL CHECK(calificacion BETWEEN 1 AND 5), comentario TEXT,
 fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE(id_cliente,id_producto),
 FOREIGN KEY(id_cliente) REFERENCES clientes(id_cliente), FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;
CREATE TABLE carritos (
 id_carrito INT PRIMARY KEY AUTO_INCREMENT, id_cliente INT NOT NULL,
 actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 estado ENUM('Abierto','Convertido','Vaciado') NOT NULL DEFAULT 'Abierto', id_venta INT UNIQUE,
 FOREIGN KEY(id_cliente) REFERENCES clientes(id_cliente), FOREIGN KEY(id_venta) REFERENCES ventas(id_venta)
) ENGINE=InnoDB;
CREATE TABLE detalle_carrito (
 id_carrito INT NOT NULL, id_producto INT NOT NULL, cantidad INT NOT NULL CHECK(cantidad > 0),
 PRIMARY KEY(id_carrito,id_producto), FOREIGN KEY(id_carrito) REFERENCES carritos(id_carrito),
 FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;
CREATE TABLE promociones (
 id_promocion INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(100) NOT NULL,
 codigo VARCHAR(50) NOT NULL UNIQUE,
 id_producto INT NOT NULL, inicio DATETIME NOT NULL, fin DATETIME NOT NULL,
 descuento DECIMAL(5,2) NOT NULL CHECK(descuento > 0 AND descuento < 100),
 activo BOOLEAN NOT NULL DEFAULT TRUE, CHECK(fin > inicio),
 FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;
CREATE TABLE visitas_producto (
 id_visita BIGINT PRIMARY KEY AUTO_INCREMENT, id_producto INT NOT NULL, id_cliente INT NULL,
 fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 FOREIGN KEY(id_producto) REFERENCES productos(id_producto), FOREIGN KEY(id_cliente) REFERENCES clientes(id_cliente),
 INDEX ix_visitas_fecha_producto(fecha,id_producto)
) ENGINE=InnoDB;
CREATE TABLE inventario_diario (
 fecha DATE NOT NULL, id_producto INT NOT NULL, stock INT NOT NULL CHECK(stock >= 0),
 costo DECIMAL(12,2) NOT NULL CHECK(costo >= 0), PRIMARY KEY(fecha,id_producto),
 FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;
CREATE TABLE movimientos_stock (
 id_movimiento BIGINT PRIMARY KEY AUTO_INCREMENT, id_producto INT NOT NULL,
 diferencia INT NOT NULL, motivo VARCHAR(300) NOT NULL, usuario VARCHAR(288) NOT NULL,
 fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;
CREATE TABLE auditoria (
 id_log BIGINT PRIMARY KEY AUTO_INCREMENT, tipo VARCHAR(60) NOT NULL, entidad_id INT,
 datos JSON, usuario VARCHAR(288) NOT NULL, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
CREATE TABLE auditoria_historica LIKE auditoria;
CREATE TABLE alertas (
 id_alerta BIGINT PRIMARY KEY AUTO_INCREMENT, tipo VARCHAR(50) NOT NULL,
 entidad_id INT, mensaje VARCHAR(300) NOT NULL, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
CREATE TABLE ventas_archivo (
 id_archivo BIGINT PRIMARY KEY AUTO_INCREMENT, id_venta INT NOT NULL,
 encabezado JSON NOT NULL, detalles JSON, fecha_archivo DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
-- El colector automatico copia GRANT/REVOKE del general_log a esta tabla.
CREATE TABLE cambios_permisos (
 id_cambio BIGINT PRIMARY KEY AUTO_INCREMENT, cuenta VARCHAR(288) NOT NULL,
 descripcion TEXT NOT NULL, fecha DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
 huella CHAR(64) UNIQUE, origen VARCHAR(40) NOT NULL DEFAULT 'mysql.general_log'
) ENGINE=InnoDB;
CREATE TABLE accesos_fallidos (
 id_acceso BIGINT PRIMARY KEY AUTO_INCREMENT, fecha DATETIME(6) NOT NULL,
 conexion BIGINT UNSIGNED NOT NULL, mensaje TEXT NOT NULL, huella CHAR(64) NOT NULL UNIQUE
) ENGINE=InnoDB;
CREATE TABLE accesos_fallidos_historico LIKE accesos_fallidos;
CREATE TABLE cambios_permisos_historico LIKE cambios_permisos;
CREATE TABLE control_servicio (
 nombre VARCHAR(50) PRIMARY KEY, valor VARCHAR(255), actualizado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;
CREATE TABLE respaldos (
 id_respaldo BIGINT PRIMARY KEY AUTO_INCREMENT, id_trabajo BIGINT NOT NULL UNIQUE,
 archivo VARCHAR(1000) NOT NULL, sha256 CHAR(64) NOT NULL, bytes BIGINT NOT NULL,
 fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, verificado BOOLEAN NOT NULL DEFAULT FALSE
) ENGINE=InnoDB;
CREATE TABLE registros_purgados (
 id BIGINT PRIMARY KEY AUTO_INCREMENT, entidad VARCHAR(50) NOT NULL, entidad_id INT NOT NULL,
 datos JSON NOT NULL, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
CREATE TABLE usuarios_sucursal (
 usuario VARCHAR(32) PRIMARY KEY, id_sucursal INT NOT NULL,
 FOREIGN KEY(id_sucursal) REFERENCES sucursales(id_sucursal)
) ENGINE=InnoDB;
CREATE TABLE notificaciones (
 id_notificacion BIGINT PRIMARY KEY AUTO_INCREMENT, tipo VARCHAR(50) NOT NULL,
 entidad_id INT, contenido JSON, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 enviado BOOLEAN NOT NULL DEFAULT FALSE
) ENGINE=InnoDB;
CREATE TABLE reabastecimiento (
 id_producto INT PRIMARY KEY, stock INT NOT NULL, sugerido INT NOT NULL, fecha DATE NOT NULL,
 FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;
CREATE TABLE resumen_ventas_diarias (
 fecha DATE NOT NULL, id_sucursal INT NOT NULL, pedidos INT NOT NULL,
 ingresos DECIMAL(18,2) NOT NULL, PRIMARY KEY(fecha,id_sucursal)
) ENGINE=InnoDB;
CREATE TABLE rankings_productos (
 id_producto INT PRIMARY KEY, posicion INT NOT NULL, ingresos DECIMAL(18,2) NOT NULL,
 actualizado_en DATETIME NOT NULL, FOREIGN KEY(id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;
CREATE TABLE kpis_mensuales (
 mes DATE PRIMARY KEY, pedidos INT NOT NULL, ingresos DECIMAL(18,2) NOT NULL,
 ticket_promedio DECIMAL(16,2), clientes INT NOT NULL
) ENGINE=InnoDB;
CREATE TABLE rendimiento_proveedores (
 mes DATE NOT NULL, id_proveedor INT NOT NULL, unidades BIGINT NOT NULL, ingresos DECIMAL(18,2) NOT NULL,
 PRIMARY KEY(mes,id_proveedor), FOREIGN KEY(id_proveedor) REFERENCES proveedores(id_proveedor)
) ENGINE=InnoDB;
CREATE TABLE tamano_bd (
 id_registro BIGINT PRIMARY KEY AUTO_INCREMENT, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 bytes_aproximados BIGINT NOT NULL
) ENGINE=InnoDB;
CREATE TABLE trabajos_externos (
 id_trabajo BIGINT PRIMARY KEY AUTO_INCREMENT, tipo VARCHAR(50) NOT NULL, fecha DATE NOT NULL,
 estado ENUM('Pendiente','Completado','Error') NOT NULL DEFAULT 'Pendiente',
 detalle VARCHAR(500) NOT NULL, intentos INT NOT NULL DEFAULT 0,
 actualizado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, UNIQUE(tipo,fecha)
) ENGINE=InnoDB;
CREATE TABLE cupones_cumpleanos (
 id_cliente INT NOT NULL, anio INT NOT NULL, codigo VARCHAR(100) NOT NULL UNIQUE,
 PRIMARY KEY(id_cliente,anio), FOREIGN KEY(id_cliente) REFERENCES clientes(id_cliente)
) ENGINE=InnoDB;
-- Staging persistente con caducidad. Las TEMPORARY TABLES reales son por sesion.
CREATE TABLE staging_importacion (
 id BIGINT PRIMARY KEY AUTO_INCREMENT, datos JSON, creado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO sucursales(nombre) VALUES ('Centro'),('Norte');
INSERT INTO categorias(nombre,descripcion) VALUES ('General','Sin clasificacion'),('Tecnologia','Dispositivos'),('Hogar','Casa'),('Libros','Lectura');
INSERT INTO proveedores(nombre,email_contacto,telefono_contacto) VALUES
 ('Suministros Atlas','ventas@atlas.example','5550101'),('Distribuciones Luna','ventas@luna.example','5550102');
INSERT INTO productos(nombre,precio,costo,stock,sku,id_categoria,id_proveedor,stock_minimo,peso_kg,ubicacion) VALUES
 ('Teclado',120,65,50,'TEC-001',2,1,10,0.700,'A1'),('Raton',60,25,60,'TEC-002',2,1,10,0.200,'A2'),
 ('Monitor',800,520,30,'TEC-003',2,1,5,4.500,'A3'),('Auriculares',150,70,40,'TEC-004',2,1,8,0.300,'A4'),
 ('Lampara',90,40,35,'HOG-001',3,2,5,1.200,'B1'),('Taza',25,8,80,'HOG-002',3,2,15,0.400,'B2'),
 ('Cuaderno',20,7,100,'LIB-001',4,2,10,0.250,'C1'),('Novela',55,25,45,'LIB-002',4,2,5,0.500,'C2'),
 ('Cable USB',15,4,100,'TEC-005',2,1,20,0.050,'A5'),('Soporte',75,30,3,'TEC-006',2,1,5,0.600,'A6'),
 ('Jarron',65,28,2,'HOG-003',3,2,5,1.000,'B3'),('Agenda',40,15,0,'LIB-003',4,2,8,0.300,'C3');
-- Hash bcrypt real, coste 12, de una clave aleatoria descartada (no hay clave publicada).
INSERT INTO clientes(nombre,apellido,email,contrasena_hash,direccion_envio,ciudad,region,fecha_nacimiento,fecha_registro)
SELECT CONCAT('Cliente',n), 'Ejemplo', CONCAT('cliente',n,'@example.com'), '$2b$12$mozrGMvsxlNdgtkgvJye/uZvplUCWPnEmJ6ph8sVBIcTXj95xYxfi',
 CONCAT('Calle de ejemplo ',n), IF(MOD(n,2)=0,'Ciudad Norte','Ciudad Centro'),
 IF(MOD(n,2)=0,'Norte','Centro'), DATE_ADD('1995-01-01',INTERVAL n MONTH),
 DATE_SUB(UTC_TIMESTAMP(),INTERVAL (240-n*7) DAY)
FROM JSON_TABLE('[1,2,3,4,5,6,7,8,9,10,11,12]', '$[*]' COLUMNS(n INT PATH '$')) j;

-- Ventas distribuidas en seis meses; 11 y 12 son clientes sin compras.
INSERT INTO ventas(id_cliente,id_sucursal,fecha_venta,estado,direccion_envio,ciudad_envio,region_envio)
SELECT MOD(n-1,10)+1, MOD(n,2)+1,
 TIMESTAMP(DATE_SUB(UTC_DATE(),INTERVAL (n*3) DAY),MAKETIME(MOD(n*7,24),0,0)),
 CASE WHEN MOD(n,11)=0 THEN 'Cancelado' WHEN MOD(n,7)=0 THEN 'Pendiente de Pago' ELSE 'Entregado' END,
 CONCAT('Calle de ejemplo ',MOD(n-1,10)+1),IF(MOD(n,2)=0,'Ciudad Centro','Ciudad Norte'),
 IF(MOD(n,2)=0,'Centro','Norte')
FROM JSON_TABLE('[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60]', '$[*]' COLUMNS(n INT PATH '$')) j;
INSERT INTO detalle_ventas(id_venta,id_producto,cantidad,precio_unitario_congelado,costo_unitario_congelado)
SELECT v.id_venta,p.id_producto,MOD(v.id_venta,3)+1,p.precio,p.costo FROM ventas v
JOIN productos p ON p.id_producto IN (MOD(v.id_venta,8)+1,MOD(v.id_venta+1,8)+1);
UPDATE ventas v SET total=(SELECT SUM(d.cantidad*d.precio_unitario_congelado) FROM detalle_ventas d WHERE d.id_venta=v.id_venta);
-- El stock cargado es el saldo actual; las ventas historicas no se descuentan de nuevo.
UPDATE clientes c SET total_gastado=COALESCE((SELECT SUM(v.total) FROM ventas v WHERE v.id_cliente=c.id_cliente AND v.estado IN ('Pagado','Procesando','Enviado','Entregado')),0),
 ultima_compra=(SELECT MAX(v.fecha_venta) FROM ventas v WHERE v.id_cliente=c.id_cliente AND v.estado IN ('Pagado','Procesando','Enviado','Entregado'));
UPDATE categorias c SET producto_count=(SELECT COUNT(*) FROM productos p WHERE p.id_categoria=c.id_categoria);
INSERT INTO carritos(id_cliente,actualizado_en) VALUES (11,UTC_TIMESTAMP()-INTERVAL 5 DAY),(12,UTC_TIMESTAMP()-INTERVAL 2 DAY);
INSERT INTO detalle_carrito VALUES (1,1,1),(1,2,1),(2,5,2);
INSERT INTO promociones(nombre,codigo,id_producto,inicio,fin,descuento) VALUES
 ('Campana teclado','TECLADO10',1,UTC_DATE()-INTERVAL 90 DAY,UTC_DATE()-INTERVAL 60 DAY,10),
 ('Campana hogar','HOGAR15',5,UTC_DATE()-INTERVAL 2 DAY,UTC_DATE()+INTERVAL 5 DAY,15);
INSERT INTO visitas_producto(id_producto,id_cliente,fecha)
SELECT p.id_producto,c.id_cliente,UTC_TIMESTAMP()-INTERVAL c.id_cliente DAY FROM productos p CROSS JOIN clientes c WHERE c.id_cliente<=p.id_producto;
-- Observaciones simuladas para practicar rotacion; no pretenden ser reconstruccion historica real.
INSERT INTO inventario_diario(fecha,id_producto,stock,costo)
WITH RECURSIVE dias AS (SELECT UTC_DATE()-INTERVAL 30 DAY AS fecha UNION ALL SELECT fecha+INTERVAL 1 DAY FROM dias WHERE fecha<UTC_DATE()-INTERVAL 1 DAY)
SELECT fecha,p.id_producto,p.stock+5,p.costo FROM dias CROSS JOIN productos p;
INSERT INTO usuarios_sucursal VALUES ('marketing_user',1),('support_user',1),('analyst_user',1),('auditor_user',1);
