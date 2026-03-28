-- ============================================================
-- INVENTORY CONTROL MANAGEMENT SYSTEM - DATABASE SETUP
-- ============================================================
-- Run this script first before starting the Flask application
-- Compatible with MySQL 5.7+
-- ============================================================

-- Create and select the database
DROP DATABASE IF EXISTS inventory_db;
CREATE DATABASE inventory_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE inventory_db;

-- ============================================================
-- DDL: CREATE TABLES WITH INTEGRITY CONSTRAINTS
-- ============================================================

-- 1. Supplier Table
CREATE TABLE Supplier (
    supplier_id   INT AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(150) NOT NULL,
    contact_info  VARCHAR(255) NOT NULL,
    email         VARCHAR(150),
    city          VARCHAR(100),
    created_at    DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 2. Product Table
CREATE TABLE Product (
    product_id     INT AUTO_INCREMENT PRIMARY KEY,
    name           VARCHAR(200) NOT NULL UNIQUE,           -- UNIQUE constraint
    category       VARCHAR(100) NOT NULL,
    price          DECIMAL(10,2) NOT NULL CHECK (price >= 0),          -- CHECK constraint
    stock_quantity INT NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0), -- CHECK constraint
    unit           VARCHAR(50) DEFAULT 'piece',
    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 3. Purchase Table
CREATE TABLE Purchase (
    purchase_id   INT AUTO_INCREMENT PRIMARY KEY,
    product_id    INT NOT NULL,
    supplier_id   INT NOT NULL,
    quantity      INT NOT NULL CHECK (quantity > 0),        -- CHECK constraint
    unit_cost     DECIMAL(10,2) NOT NULL DEFAULT 0,
    purchase_date DATE NOT NULL,
    notes         TEXT,
    FOREIGN KEY (product_id)  REFERENCES Product(product_id)  ON DELETE RESTRICT,  -- FK constraint
    FOREIGN KEY (supplier_id) REFERENCES Supplier(supplier_id) ON DELETE RESTRICT   -- FK constraint
);

-- 4. Sale Table
CREATE TABLE Sale (
    sale_id      INT AUTO_INCREMENT PRIMARY KEY,
    product_id   INT NOT NULL,
    quantity     INT NOT NULL CHECK (quantity > 0),          -- CHECK constraint
    sale_price   DECIMAL(10,2) NOT NULL DEFAULT 0,
    sale_date    DATE NOT NULL,
    customer     VARCHAR(150) DEFAULT 'Walk-in',
    notes        TEXT,
    FOREIGN KEY (product_id) REFERENCES Product(product_id) ON DELETE RESTRICT      -- FK constraint
);

-- 5. Stock Log Table (for trigger logging)
CREATE TABLE StockLog (
    log_id       INT AUTO_INCREMENT PRIMARY KEY,
    product_id   INT NOT NULL,
    change_type  ENUM('PURCHASE','SALE') NOT NULL,
    quantity     INT NOT NULL,
    stock_before INT NOT NULL,
    stock_after  INT NOT NULL,
    log_time     DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES Product(product_id) ON DELETE CASCADE
);

-- ============================================================
-- VIEWS
-- ============================================================

-- View 1: Inventory Summary
CREATE VIEW InventorySummary AS
SELECT
    p.product_id,
    p.name          AS product_name,
    p.category,
    p.price,
    p.unit,
    COALESCE(SUM(pu.quantity), 0)  AS total_purchased,
    COALESCE(SUM(s.quantity), 0)   AS total_sold,
    p.stock_quantity               AS current_stock
FROM Product p
LEFT JOIN Purchase pu ON p.product_id = pu.product_id
LEFT JOIN Sale     s  ON p.product_id = s.product_id
GROUP BY p.product_id, p.name, p.category, p.price, p.unit, p.stock_quantity;

-- View 2: Low Stock Products (stock < 10)
CREATE VIEW LowStockProducts AS
SELECT
    product_id,
    name,
    category,
    price,
    stock_quantity,
    unit
FROM Product
WHERE stock_quantity < 10
ORDER BY stock_quantity ASC;

-- View 3: Monthly Sales Revenue
CREATE VIEW MonthlySalesRevenue AS
SELECT
    DATE_FORMAT(s.sale_date, '%Y-%m') AS sale_month,
    SUM(s.quantity * s.sale_price)    AS total_revenue,
    COUNT(s.sale_id)                  AS total_transactions,
    SUM(s.quantity)                   AS total_units_sold
FROM Sale s
GROUP BY DATE_FORMAT(s.sale_date, '%Y-%m')
ORDER BY sale_month DESC;

-- View 4: Supplier Purchase Summary
CREATE VIEW SupplierPurchaseSummary AS
SELECT
    sup.supplier_id,
    sup.name          AS supplier_name,
    sup.city,
    COUNT(pu.purchase_id)               AS total_orders,
    COALESCE(SUM(pu.quantity), 0)       AS total_units_purchased,
    COALESCE(SUM(pu.quantity * pu.unit_cost), 0) AS total_purchase_value
FROM Supplier sup
LEFT JOIN Purchase pu ON sup.supplier_id = pu.supplier_id
GROUP BY sup.supplier_id, sup.name, sup.city;

-- ============================================================
-- TRIGGERS
-- ============================================================

DELIMITER $$

-- Trigger 1: Increase stock after purchase INSERT
CREATE TRIGGER after_purchase_insert
AFTER INSERT ON Purchase
FOR EACH ROW
BEGIN
    DECLARE old_stock INT;
    SELECT stock_quantity INTO old_stock FROM Product WHERE product_id = NEW.product_id;

    -- Update stock
    UPDATE Product
    SET stock_quantity = stock_quantity + NEW.quantity
    WHERE product_id = NEW.product_id;

    -- Log the stock movement
    INSERT INTO StockLog (product_id, change_type, quantity, stock_before, stock_after)
    VALUES (NEW.product_id, 'PURCHASE', NEW.quantity, old_stock, old_stock + NEW.quantity);
END$$

-- Trigger 2: Decrease stock after sale INSERT
CREATE TRIGGER after_sale_insert
AFTER INSERT ON Sale
FOR EACH ROW
BEGIN
    DECLARE old_stock INT;
    SELECT stock_quantity INTO old_stock FROM Product WHERE product_id = NEW.product_id;

    UPDATE Product
    SET stock_quantity = stock_quantity - NEW.quantity
    WHERE product_id = NEW.product_id;

    INSERT INTO StockLog (product_id, change_type, quantity, stock_before, stock_after)
    VALUES (NEW.product_id, 'SALE', NEW.quantity, old_stock, old_stock - NEW.quantity);
END$$

-- Trigger 3: Prevent sale if insufficient stock
CREATE TRIGGER before_sale_insert
BEFORE INSERT ON Sale
FOR EACH ROW
BEGIN
    DECLARE available_stock INT;
    SELECT stock_quantity INTO available_stock FROM Product WHERE product_id = NEW.product_id;

    IF available_stock < NEW.quantity THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Insufficient stock: cannot process sale';
    END IF;

    -- Auto-populate sale_price from product price if not set
    IF NEW.sale_price = 0 THEN
        SELECT price INTO NEW.sale_price FROM Product WHERE product_id = NEW.product_id;
    END IF;
END$$

-- Trigger 4: Prevent deletion of product if sales exist
CREATE TRIGGER before_product_delete
BEFORE DELETE ON Product
FOR EACH ROW
BEGIN
    DECLARE sale_count INT;
    SELECT COUNT(*) INTO sale_count FROM Sale WHERE product_id = OLD.product_id;

    IF sale_count > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Cannot delete product: sales records exist';
    END IF;
END$$

-- Trigger 5: Prevent deletion of supplier if purchases exist
CREATE TRIGGER before_supplier_delete
BEFORE DELETE ON Supplier
FOR EACH ROW
BEGIN
    DECLARE purchase_count INT;
    SELECT COUNT(*) INTO purchase_count FROM Purchase WHERE supplier_id = OLD.supplier_id;

    IF purchase_count > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Cannot delete supplier: purchase records exist';
    END IF;
END$$

DELIMITER ;

-- ============================================================
-- SAMPLE DATA: 50+ Records Per Table
-- ============================================================

-- Suppliers (15 records)
INSERT INTO Supplier (name, contact_info, email, city) VALUES
('TechParts Global',      '+1-800-555-0101', 'contact@techparts.com',    'New York'),
('Office Essentials Inc', '+1-800-555-0102', 'sales@officeessentials.com','Chicago'),
('ElectroSupply Co',      '+1-800-555-0103', 'info@electrosupply.com',   'Los Angeles'),
('FurniturePro Ltd',      '+1-800-555-0104', 'order@furniturepro.com',   'Houston'),
('StatioMart',            '+1-800-555-0105', 'hello@stationmart.com',    'Phoenix'),
('GreenTech Distributors','+1-800-555-0106', 'green@techdistr.com',      'Philadelphia'),
('SafetyFirst Supplies',  '+1-800-555-0107', 'safe@safetyfirst.com',     'San Antonio'),
('MegaWholesale Corp',    '+1-800-555-0108', 'mega@wholesale.com',       'Dallas'),
('PrimeParts Inc',        '+1-800-555-0109', 'prime@primeparts.com',     'San Jose'),
('QuickShip Trading',     '+1-800-555-0110', 'quick@quickship.com',      'Austin'),
('GlobalGoods Ltd',       '+1-800-555-0111', 'global@globalgoods.com',   'Jacksonville'),
('EcoSupply Chain',       '+1-800-555-0112', 'eco@ecosupply.com',        'San Francisco'),
('MetroDistributors',     '+1-800-555-0113', 'metro@metrodist.com',      'Indianapolis'),
('ValueVendors Co',       '+1-800-555-0114', 'value@valuevendors.com',   'Columbus'),
('SwiftSource LLC',       '+1-800-555-0115', 'swift@swiftsource.com',    'Fort Worth');

-- Products (55 records)
INSERT INTO Product (name, category, price, stock_quantity, unit) VALUES
('Laptop Pro 15"',           'Electronics',    1299.99,  0, 'piece'),
('Wireless Mouse',           'Electronics',      29.99,  0, 'piece'),
('Mechanical Keyboard',      'Electronics',      89.99,  0, 'piece'),
('27" Monitor',              'Electronics',     399.99,  0, 'piece'),
('USB-C Hub 7-port',         'Electronics',      49.99,  0, 'piece'),
('Noise-Cancel Headphones',  'Electronics',     199.99,  0, 'piece'),
('Webcam 1080p',             'Electronics',      79.99,  0, 'piece'),
('Portable SSD 1TB',         'Electronics',     119.99,  0, 'piece'),
('Smartphone Stand',         'Electronics',      19.99,  0, 'piece'),
('Surge Protector 8-port',   'Electronics',      39.99,  0, 'piece'),
('Office Chair Ergonomic',   'Furniture',       299.99,  0, 'piece'),
('Standing Desk 60"',        'Furniture',       549.99,  0, 'piece'),
('3-Drawer Filing Cabinet',  'Furniture',       179.99,  0, 'piece'),
('Bookshelf 5-tier',         'Furniture',       149.99,  0, 'piece'),
('Whiteboard 4x6ft',         'Furniture',       124.99,  0, 'piece'),
('Monitor Arm Dual',         'Furniture',        79.99,  0, 'piece'),
('Cable Management Tray',    'Furniture',        29.99,  0, 'piece'),
('Meeting Table 8-person',   'Furniture',       899.99,  0, 'piece'),
('Task Chair Basic',         'Furniture',       149.99,  0, 'piece'),
('Desk Lamp LED',            'Furniture',        44.99,  0, 'piece'),
('Ballpoint Pens Box/50',    'Stationery',        9.99,  0, 'box'),
('Sticky Notes 12-pack',     'Stationery',        7.99,  0, 'pack'),
('A4 Paper 500 sheets',      'Stationery',        8.49,  0, 'ream'),
('Stapler Heavy Duty',       'Stationery',       24.99,  0, 'piece'),
('Scissors Pack/3',          'Stationery',        6.99,  0, 'pack'),
('Highlighters 10-pack',     'Stationery',        8.99,  0, 'pack'),
('File Folders 25-pack',     'Stationery',       11.99,  0, 'pack'),
('Binder 3-ring 2"',         'Stationery',        4.99,  0, 'piece'),
('Whiteboard Markers 8-pk',  'Stationery',        9.99,  0, 'pack'),
('Tape Dispenser + 3 Rolls', 'Stationery',        5.99,  0, 'piece'),
('Safety Helmet',            'Safety',           34.99,  0, 'piece'),
('Hi-Vis Vest',              'Safety',           14.99,  0, 'piece'),
('Safety Gloves Pair',       'Safety',           12.99,  0, 'pair'),
('First Aid Kit Basic',      'Safety',           29.99,  0, 'piece'),
('Fire Extinguisher 5lb',    'Safety',           59.99,  0, 'piece'),
('Safety Goggles',           'Safety',            9.99,  0, 'piece'),
('Ear Muffs Protective',     'Safety',           19.99,  0, 'piece'),
('Dust Mask N95 10-pack',    'Safety',           14.99,  0, 'pack'),
('Steel Toe Boots',          'Safety',           89.99,  0, 'pair'),
('Caution Tape 1000ft',      'Safety',           11.99,  0, 'roll'),
('Printer Ink Black',        'Consumables',       19.99,  0, 'cartridge'),
('Printer Ink Color 4-set',  'Consumables',       39.99,  0, 'set'),
('Toner Cartridge Black',    'Consumables',       69.99,  0, 'cartridge'),
('Thermal Paper Roll 10-pk', 'Consumables',       12.99,  0, 'pack'),
('Battery AA 24-pack',       'Consumables',       18.99,  0, 'pack'),
('Battery AAA 24-pack',      'Consumables',       17.99,  0, 'pack'),
('Cleaning Spray 32oz',      'Consumables',        6.99,  0, 'bottle'),
('Microfiber Cloths 10-pk',  'Consumables',        9.99,  0, 'pack'),
('Hand Sanitizer 1L',        'Consumables',       11.99,  0, 'bottle'),
('Coffee Single-Serve 50pk', 'Consumables',       34.99,  0, 'box'),
('Network Switch 24-port',   'Networking',       199.99,  0, 'piece'),
('Cat6 Cable 100ft',         'Networking',        24.99,  0, 'piece'),
('Wi-Fi Router AC1200',      'Networking',        79.99,  0, 'piece'),
('Patch Panel 24-port',      'Networking',        89.99,  0, 'piece'),
('Network Rack Cabinet',     'Networking',       349.99,  0, 'piece');

-- Purchases (60 records) - triggers will update stock
INSERT INTO Purchase (product_id, supplier_id, quantity, unit_cost, purchase_date, notes) VALUES
(1,  1,  15, 1100.00, '2024-01-05', 'Q1 bulk order'),
(2,  3,  80,   22.00, '2024-01-06', NULL),
(3,  3,  50,   70.00, '2024-01-07', NULL),
(4,  3,  25,  320.00, '2024-01-08', NULL),
(5,  9,  60,   38.00, '2024-01-10', NULL),
(6,  3, 30,  160.00,  '2024-01-12', NULL),
(7,  3,  40,   60.00, '2024-01-15', NULL),
(8,  9,  35,   90.00, '2024-01-18', NULL),
(9,  5,  100,  14.00, '2024-01-20', NULL),
(10, 6,  70,   28.00, '2024-01-22', NULL),
(11, 4,  20,  230.00, '2024-02-01', 'Furniture refresh'),
(12, 4,  10,  420.00, '2024-02-03', NULL),
(13, 4,  15,  140.00, '2024-02-05', NULL),
(14, 4,  20,  110.00, '2024-02-08', NULL),
(15, 8,  12,   95.00, '2024-02-10', NULL),
(16, 4,  25,   60.00, '2024-02-12', NULL),
(17, 5,  40,   20.00, '2024-02-14', NULL),
(18, 4,   5,  700.00, '2024-02-18', 'Conference room'),
(19, 4,  18,  120.00, '2024-02-20', NULL),
(20, 5,  30,   33.00, '2024-02-22', NULL),
(21, 2, 200,    6.50, '2024-03-01', 'Stationery restock'),
(22, 2, 150,    5.00, '2024-03-02', NULL),
(23, 2, 300,    5.50, '2024-03-03', NULL),
(24, 2,  50,   18.00, '2024-03-05', NULL),
(25, 2,  80,    4.50, '2024-03-06', NULL),
(26, 2, 120,    6.00, '2024-03-08', NULL),
(27, 2, 100,    8.00, '2024-03-10', NULL),
(28, 2, 200,    2.50, '2024-03-12', NULL),
(29, 2,  80,    7.00, '2024-03-14', NULL),
(30, 2, 100,    3.50, '2024-03-16', NULL),
(31, 7,  60,   25.00, '2024-04-01', 'Safety restock'),
(32, 7, 100,   10.00, '2024-04-02', NULL),
(33, 7,  80,    8.00, '2024-04-03', NULL),
(34, 7,  30,   22.00, '2024-04-05', NULL),
(35, 7,  20,   45.00, '2024-04-08', NULL),
(36, 7, 150,    6.50, '2024-04-10', NULL),
(37, 7,  60,   14.00, '2024-04-12', NULL),
(38, 7, 100,   10.00, '2024-04-15', NULL),
(39, 7,  25,   70.00, '2024-04-18', NULL),
(40, 7,  50,    7.50, '2024-04-20', NULL),
(41, 10, 100,  14.00, '2024-05-01', 'Consumables Q2'),
(42, 10,  80,  28.00, '2024-05-03', NULL),
(43, 10,  50,  55.00, '2024-05-05', NULL),
(44, 10, 120,   8.00, '2024-05-08', NULL),
(45, 10, 150,  12.00, '2024-05-10', NULL),
(46, 10, 150,  11.50, '2024-05-12', NULL),
(47, 12, 200,   4.00, '2024-05-15', NULL),
(48, 12, 150,   6.50, '2024-05-18', NULL),
(49, 12, 100,   8.00, '2024-05-20', NULL),
(50, 12,  80,  25.00, '2024-05-22', NULL),
(51, 13,  15, 160.00, '2024-06-01', 'Networking Q2'),
(52, 13,  50,  18.00, '2024-06-03', NULL),
(53, 13,  20,  60.00, '2024-06-05', NULL),
(54, 13,  12,  70.00, '2024-06-08', NULL),
(55, 13,   8, 270.00, '2024-06-10', NULL),
(1,  1,  10, 1100.00, '2024-07-01', 'Mid-year restock'),
(2,  3,  50,   22.00, '2024-07-03', NULL),
(11, 4,  10,  230.00, '2024-07-05', NULL),
(21, 2, 100,    6.50, '2024-07-08', NULL),
(31, 7,  40,   25.00, '2024-07-10', NULL),
(41, 10, 50,   14.00, '2024-07-12', NULL);

-- Sales (60 records)
INSERT INTO Sale (product_id, quantity, sale_price, sale_date, customer) VALUES
(1,  2, 1299.99, '2024-01-15', 'Acme Corp'),
(2,  10,   29.99, '2024-01-16', 'TechStart LLC'),
(3,   5,   89.99, '2024-01-18', 'DevStudio'),
(4,   3,  399.99, '2024-01-20', 'DesignHub'),
(5,  15,   49.99, '2024-01-22', 'Freelancer Mike'),
(6,   4,  199.99, '2024-01-25', 'Remote Inc'),
(7,   6,   79.99, '2024-01-28', 'VideoCall Pro'),
(8,   5,  119.99, '2024-02-01', 'DataStore Co'),
(9,  20,   19.99, '2024-02-03', 'MobileTech'),
(10, 12,   39.99, '2024-02-05', 'Office Park'),
(11,  3,  299.99, '2024-02-08', 'StartupBase'),
(12,  2,  549.99, '2024-02-10', 'StandFirst'),
(13,  3,  179.99, '2024-02-12', 'PaperTrail Co'),
(14,  5,  149.99, '2024-02-15', 'ReadAlot Inc'),
(15,  2,  124.99, '2024-02-18', 'AgileSprint'),
(21, 30,    9.99, '2024-02-20', 'WriteRight'),
(22, 25,    7.99, '2024-02-22', 'NoteIt'),
(23, 50,    8.49, '2024-02-25', 'PrintFast'),
(24,  8,   24.99, '2024-03-01', 'Binders R Us'),
(25, 15,    6.99, '2024-03-03', 'CutCo'),
(31, 10,   34.99, '2024-03-05', 'BuildSafe LLC'),
(32, 20,   14.99, '2024-03-08', 'YellowVest Co'),
(33, 15,   12.99, '2024-03-10', 'GloveWorks'),
(34,  5,   29.99, '2024-03-12', 'SafetyFirst'),
(35,  3,   59.99, '2024-03-15', 'FireDept Local'),
(41, 20,   19.99, '2024-03-18', 'PrintShop'),
(42, 15,   39.99, '2024-03-20', 'ColorPrint'),
(43, 10,   69.99, '2024-03-22', 'LaserPrint Pro'),
(44, 25,   12.99, '2024-03-25', 'TicketMaster'),
(45, 30,   18.99, '2024-03-28', 'PowerHub'),
(1,   3, 1299.99, '2024-04-01', 'Corp Solutions'),
(2,  15,   29.99, '2024-04-03', 'MousePad World'),
(6,   5,  199.99, '2024-04-05', 'SoundSpace'),
(11,  4,  299.99, '2024-04-08', 'SitRight Inc'),
(23, 40,    8.49, '2024-04-10', 'BulkPrint'),
(26, 20,    8.99, '2024-04-12', 'HighMark'),
(31, 12,   34.99, '2024-04-15', 'HardHat LLC'),
(41, 15,   19.99, '2024-04-18', 'InkWell'),
(45, 20,   18.99, '2024-04-20', 'BatteryWorld'),
(51,  3,  199.99, '2024-04-22', 'NetConnect'),
(52, 10,   24.99, '2024-04-25', 'CableRun'),
(53,  5,   79.99, '2024-04-28', 'WirelessWave'),
(1,   2, 1299.99, '2024-05-01', 'DevOps Team'),
(4,   4,  399.99, '2024-05-03', 'ScreenCity'),
(8,   8,  119.99, '2024-05-05', 'FastStore'),
(12,  1,  549.99, '2024-05-08', 'RiseDesk'),
(21, 40,    9.99, '2024-05-10', 'PenPoint'),
(27, 20,   11.99, '2024-05-12', 'FileCity'),
(33, 20,   12.99, '2024-05-15', 'SafeHands'),
(47, 30,    6.99, '2024-05-18', 'CleanSweep'),
(2,  12,   29.99, '2024-06-01', 'ClickCo'),
(3,   8,   89.99, '2024-06-03', 'TypeMaster'),
(5,  10,   49.99, '2024-06-05', 'HubWorld'),
(22, 30,    7.99, '2024-06-08', 'StickyBiz'),
(32, 25,   14.99, '2024-06-10', 'VestVault'),
(36, 30,    9.99, '2024-06-12', 'GogglesInc'),
(42, 10,   39.99, '2024-06-15', 'ColorInk'),
(46, 20,   17.99, '2024-06-18', 'BatteryPlus'),
(48, 20,    9.99, '2024-06-20', 'CleanTech'),
(49, 15,   11.99, '2024-06-22', 'HandyClean');
