"""
=============================================================
INVENTORY CONTROL MANAGEMENT SYSTEM
Flask Backend Application
=============================================================
"""

from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
import mysql.connector
from mysql.connector import Error
from datetime import date, datetime
import os

app = Flask(__name__)
app.secret_key = 'inventory_secret_key_2024'

# ─── Database Configuration ───────────────────────────────
DB_CONFIG = {
    'host': 'localhost',
    'database': 'inventory_db',
    'user': 'root',       # Change to your MySQL username
    'password': 'qwerty',       # Change to your MySQL password
    'charset': 'utf8mb4'
}

def get_db():
    """Create and return a database connection."""
    try:
        conn = mysql.connector.connect(**DB_CONFIG)
        return conn
    except Error as e:
        print(f"Database connection error: {e}")
        return None

def query_db(sql, params=None, fetchone=False, commit=False):
    """
    Utility function to execute a query.
    Returns rows for SELECT, lastrowid for INSERT, or None on error.
    """
    conn = get_db()
    if not conn:
        return None
    try:
        cursor = conn.cursor(dictionary=True)
        cursor.execute(sql, params or ())
        if commit:
            conn.commit()
            return cursor.lastrowid
        if fetchone:
            return cursor.fetchone()
        return cursor.fetchall()
    except Error as e:
        conn.rollback()
        raise e
    finally:
        if conn.is_connected():
            conn.close()

# ─── HOME / DASHBOARD ─────────────────────────────────────

@app.route('/')
def dashboard():
    """Main dashboard with aggregate statistics."""
    # Total products count
    total_products = query_db("SELECT COUNT(*) AS cnt FROM Product", fetchone=True)['cnt']

    # Total suppliers
    total_suppliers = query_db("SELECT COUNT(*) AS cnt FROM Supplier", fetchone=True)['cnt']

    # Total revenue (SUM of sale_quantity × sale_price)
    rev = query_db("SELECT COALESCE(SUM(quantity * sale_price), 0) AS total FROM Sale", fetchone=True)
    total_revenue = rev['total']

    # Total purchases value
    pv = query_db("SELECT COALESCE(SUM(quantity * unit_cost), 0) AS total FROM Purchase", fetchone=True)
    total_purchase_value = pv['total']

    # Low stock count
    low_stock_count = query_db("SELECT COUNT(*) AS cnt FROM LowStockProducts", fetchone=True)['cnt']

    # Top 5 selling products (by quantity sold)
    top_products = query_db("""
        SELECT p.name, SUM(s.quantity) AS total_sold,
               SUM(s.quantity * s.sale_price) AS revenue
        FROM Sale s
        JOIN Product p ON s.product_id = p.product_id
        GROUP BY p.product_id, p.name
        ORDER BY total_sold DESC
        LIMIT 5
    """)

    # Monthly revenue (last 6 months)
    monthly = query_db("""
        SELECT sale_month, total_revenue, total_transactions
        FROM MonthlySalesRevenue
        LIMIT 6
    """)

    # Recent sales (last 5)
    recent_sales = query_db("""
        SELECT s.sale_id, p.name AS product_name, s.quantity,
               s.sale_price, s.sale_date, s.customer
        FROM Sale s
        JOIN Product p ON s.product_id = p.product_id
        ORDER BY s.sale_date DESC, s.sale_id DESC
        LIMIT 5
    """)

    # Low stock alert products
    low_stock = query_db("SELECT * FROM LowStockProducts LIMIT 5")

    return render_template('dashboard.html',
        total_products=total_products,
        total_suppliers=total_suppliers,
        total_revenue=total_revenue,
        total_purchase_value=total_purchase_value,
        low_stock_count=low_stock_count,
        top_products=top_products,
        monthly=monthly,
        recent_sales=recent_sales,
        low_stock=low_stock
    )

# ─── PRODUCTS ─────────────────────────────────────────────

@app.route('/products')
def products():
    """List all products with optional search/filter."""
    # Collect filter params
    name       = request.args.get('name', '').strip()
    category   = request.args.get('category', '').strip()
    min_price  = request.args.get('min_price', '').strip()
    max_price  = request.args.get('max_price', '').strip()
    min_stock  = request.args.get('min_stock', '').strip()
    max_stock  = request.args.get('max_stock', '').strip()
    supplier_id= request.args.get('supplier_id', '').strip()
    sort_by    = request.args.get('sort_by', 'name')
    sort_dir   = request.args.get('sort_dir', 'asc')

    # Validate sort fields to prevent SQL injection
    allowed_sorts = {
        'name': 'p.name',
        'price_asc': 'p.price ASC',
        'price_desc': 'p.price DESC',
        'stock': 'p.stock_quantity',
        'total_sold': 'COALESCE(SUM(s.quantity),0) DESC',
        'revenue': 'COALESCE(SUM(s.quantity * s.sale_price),0) DESC',
        'newest': 'p.created_at DESC'
    }
    sort_clause = allowed_sorts.get(sort_by, 'p.name')

    # Build dynamic WHERE
    where = []
    params = []
    if name:
        where.append("p.name LIKE %s")
        params.append(f'%{name}%')
    if category:
        where.append("p.category = %s")
        params.append(category)
    if min_price:
        where.append("p.price >= %s")
        params.append(float(min_price))
    if max_price:
        where.append("p.price <= %s")
        params.append(float(max_price))
    if min_stock:
        where.append("p.stock_quantity >= %s")
        params.append(int(min_stock))
    if max_stock:
        where.append("p.stock_quantity <= %s")
        params.append(int(max_stock))
    if supplier_id:
        where.append("pu.supplier_id = %s")
        params.append(int(supplier_id))

    where_sql = ("WHERE " + " AND ".join(where)) if where else ""
    supplier_join = "LEFT JOIN Purchase pu ON p.product_id = pu.product_id" if supplier_id else ""

    sql = f"""
        SELECT p.product_id, p.name, p.category, p.price, p.stock_quantity, p.unit,
               COALESCE(SUM(s.quantity), 0) AS total_sold,
               COALESCE(SUM(s.quantity * s.sale_price), 0) AS revenue
        FROM Product p
        {supplier_join}
        LEFT JOIN Sale s ON p.product_id = s.product_id
        {where_sql}
        GROUP BY p.product_id, p.name, p.category, p.price, p.stock_quantity, p.unit
        ORDER BY {sort_clause}
    """
    products_list = query_db(sql, params)

    # Categories for dropdown
    categories = query_db("SELECT DISTINCT category FROM Product ORDER BY category")
    suppliers  = query_db("SELECT supplier_id, name FROM Supplier ORDER BY name")

    return render_template('products.html',
        products=products_list,
        categories=categories,
        suppliers=suppliers,
        filters=request.args
    )

@app.route('/products/add', methods=['GET', 'POST'])
def add_product():
    categories = query_db("SELECT DISTINCT category FROM Product ORDER BY category")
    if request.method == 'POST':
        name     = request.form['name'].strip()
        category = request.form['category'].strip()
        price    = request.form['price']
        unit     = request.form.get('unit', 'piece').strip()
        try:
            query_db(
                "INSERT INTO Product (name, category, price, stock_quantity, unit) VALUES (%s,%s,%s,0,%s)",
                (name, category, float(price), unit), commit=True
            )
            flash(f'Product "{name}" added successfully!', 'success')
            return redirect(url_for('products'))
        except Error as e:
            flash(f'Error adding product: {str(e)}', 'danger')
    return render_template('product_form.html', product=None, categories=categories, action='Add')

@app.route('/products/edit/<int:pid>', methods=['GET', 'POST'])
def edit_product(pid):
    product    = query_db("SELECT * FROM Product WHERE product_id=%s", (pid,), fetchone=True)
    categories = query_db("SELECT DISTINCT category FROM Product ORDER BY category")
    if not product:
        flash('Product not found.', 'danger')
        return redirect(url_for('products'))
    if request.method == 'POST':
        name     = request.form['name'].strip()
        category = request.form['category'].strip()
        price    = request.form['price']
        unit     = request.form.get('unit', 'piece').strip()
        try:
            query_db(
                "UPDATE Product SET name=%s, category=%s, price=%s, unit=%s WHERE product_id=%s",
                (name, category, float(price), unit, pid), commit=True
            )
            flash(f'Product "{name}" updated successfully!', 'success')
            return redirect(url_for('products'))
        except Error as e:
            flash(f'Error updating product: {str(e)}', 'danger')
    return render_template('product_form.html', product=product, categories=categories, action='Edit')

@app.route('/products/delete/<int:pid>', methods=['POST'])
def delete_product(pid):
    product = query_db("SELECT name FROM Product WHERE product_id=%s", (pid,), fetchone=True)
    if not product:
        flash('Product not found.', 'danger')
        return redirect(url_for('products'))
    try:
        query_db("DELETE FROM Product WHERE product_id=%s", (pid,), commit=True)
        flash(f'Product "{product["name"]}" deleted.', 'success')
    except Error as e:
        flash(f'Cannot delete: {str(e)}', 'danger')
    return redirect(url_for('products'))

# ─── SUPPLIERS ────────────────────────────────────────────

@app.route('/suppliers')
def suppliers():
    rows = query_db("""
        SELECT s.*, COUNT(DISTINCT p.purchase_id) AS total_orders,
               COALESCE(SUM(p.quantity * p.unit_cost), 0) AS total_value
        FROM Supplier s
        LEFT JOIN Purchase p ON s.supplier_id = p.supplier_id
        GROUP BY s.supplier_id
        ORDER BY s.name
    """)
    return render_template('suppliers.html', suppliers=rows)

@app.route('/suppliers/add', methods=['GET', 'POST'])
def add_supplier():
    if request.method == 'POST':
        name    = request.form['name'].strip()
        contact = request.form['contact_info'].strip()
        email   = request.form.get('email', '').strip()
        city    = request.form.get('city', '').strip()
        try:
            query_db(
                "INSERT INTO Supplier (name, contact_info, email, city) VALUES (%s,%s,%s,%s)",
                (name, contact, email, city), commit=True
            )
            flash(f'Supplier "{name}" added!', 'success')
            return redirect(url_for('suppliers'))
        except Error as e:
            flash(f'Error: {str(e)}', 'danger')
    return render_template('supplier_form.html', supplier=None, action='Add')

@app.route('/suppliers/edit/<int:sid>', methods=['GET', 'POST'])
def edit_supplier(sid):
    supplier = query_db("SELECT * FROM Supplier WHERE supplier_id=%s", (sid,), fetchone=True)
    if not supplier:
        flash('Supplier not found.', 'danger')
        return redirect(url_for('suppliers'))
    if request.method == 'POST':
        name    = request.form['name'].strip()
        contact = request.form['contact_info'].strip()
        email   = request.form.get('email', '').strip()
        city    = request.form.get('city', '').strip()
        try:
            query_db(
                "UPDATE Supplier SET name=%s, contact_info=%s, email=%s, city=%s WHERE supplier_id=%s",
                (name, contact, email, city, sid), commit=True
            )
            flash(f'Supplier "{name}" updated!', 'success')
            return redirect(url_for('suppliers'))
        except Error as e:
            flash(f'Error: {str(e)}', 'danger')
    return render_template('supplier_form.html', supplier=supplier, action='Edit')

@app.route('/suppliers/delete/<int:sid>', methods=['POST'])
def delete_supplier(sid):
    supplier = query_db("SELECT name FROM Supplier WHERE supplier_id=%s", (sid,), fetchone=True)
    if not supplier:
        flash('Supplier not found.', 'danger')
        return redirect(url_for('suppliers'))
    try:
        query_db("DELETE FROM Supplier WHERE supplier_id=%s", (sid,), commit=True)
        flash(f'Supplier "{supplier["name"]}" deleted.', 'success')
    except Error as e:
        flash(f'Cannot delete: {str(e)}', 'danger')
    return redirect(url_for('suppliers'))

# ─── PURCHASES ────────────────────────────────────────────

@app.route('/purchases')
def purchases():
    date_from = request.args.get('date_from', '')
    date_to   = request.args.get('date_to', '')
    supplier_id = request.args.get('supplier_id', '')
    product_id  = request.args.get('product_id', '')

    where, params = [], []
    if date_from:
        where.append("pu.purchase_date >= %s"); params.append(date_from)
    if date_to:
        where.append("pu.purchase_date <= %s"); params.append(date_to)
    if supplier_id:
        where.append("pu.supplier_id = %s"); params.append(int(supplier_id))
    if product_id:
        where.append("pu.product_id = %s"); params.append(int(product_id))

    where_sql = ("WHERE " + " AND ".join(where)) if where else ""
    rows = query_db(f"""
        SELECT pu.*, p.name AS product_name, s.name AS supplier_name,
               (pu.quantity * pu.unit_cost) AS total_cost
        FROM Purchase pu
        JOIN Product  p ON pu.product_id  = p.product_id
        JOIN Supplier s ON pu.supplier_id = s.supplier_id
        {where_sql}
        ORDER BY pu.purchase_date DESC, pu.purchase_id DESC
    """, params)

    products_list = query_db("SELECT product_id, name FROM Product ORDER BY name")
    suppliers_list = query_db("SELECT supplier_id, name FROM Supplier ORDER BY name")
    return render_template('purchases.html', purchases=rows,
        products=products_list, suppliers=suppliers_list, filters=request.args)

@app.route('/purchases/add', methods=['GET', 'POST'])
def add_purchase():
    products_list  = query_db("SELECT product_id, name, price FROM Product ORDER BY name")
    suppliers_list = query_db("SELECT supplier_id, name FROM Supplier ORDER BY name")
    if request.method == 'POST':
        product_id  = int(request.form['product_id'])
        supplier_id = int(request.form['supplier_id'])
        quantity    = int(request.form['quantity'])
        unit_cost   = float(request.form['unit_cost'])
        pdate       = request.form['purchase_date']
        notes       = request.form.get('notes', '').strip()
        try:
            query_db(
                "INSERT INTO Purchase (product_id,supplier_id,quantity,unit_cost,purchase_date,notes) VALUES(%s,%s,%s,%s,%s,%s)",
                (product_id, supplier_id, quantity, unit_cost, pdate, notes), commit=True
            )
            flash('Purchase recorded successfully!', 'success')
            return redirect(url_for('purchases'))
        except Error as e:
            flash(f'Error: {str(e)}', 'danger')
    return render_template('purchase_form.html',
        products=products_list, suppliers=suppliers_list, today=date.today())

# ─── SALES ────────────────────────────────────────────────

@app.route('/sales')
def sales():
    date_from  = request.args.get('date_from', '')
    date_to    = request.args.get('date_to', '')
    product_id = request.args.get('product_id', '')

    where, params = [], []
    if date_from:
        where.append("s.sale_date >= %s"); params.append(date_from)
    if date_to:
        where.append("s.sale_date <= %s"); params.append(date_to)
    if product_id:
        where.append("s.product_id = %s"); params.append(int(product_id))

    where_sql = ("WHERE " + " AND ".join(where)) if where else ""
    rows = query_db(f"""
        SELECT s.*, p.name AS product_name, (s.quantity * s.sale_price) AS total_revenue
        FROM Sale s
        JOIN Product p ON s.product_id = p.product_id
        {where_sql}
        ORDER BY s.sale_date DESC, s.sale_id DESC
    """, params)

    products_list = query_db("SELECT product_id, name, stock_quantity FROM Product ORDER BY name")
    return render_template('sales.html', sales=rows,
        products=products_list, filters=request.args)

@app.route('/sales/add', methods=['GET', 'POST'])
def add_sale():
    products_list = query_db(
        "SELECT product_id, name, price, stock_quantity FROM Product ORDER BY name"
    )
    if request.method == 'POST':
        product_id = int(request.form['product_id'])
        quantity   = int(request.form['quantity'])
        sale_price = float(request.form['sale_price'])
        sdate      = request.form['sale_date']
        customer   = request.form.get('customer', 'Walk-in').strip()
        notes      = request.form.get('notes', '').strip()
        try:
            query_db(
                "INSERT INTO Sale (product_id,quantity,sale_price,sale_date,customer,notes) VALUES(%s,%s,%s,%s,%s,%s)",
                (product_id, quantity, sale_price, sdate, customer, notes), commit=True
            )
            flash('Sale recorded successfully!', 'success')
            return redirect(url_for('sales'))
        except Error as e:
            flash(f'Error: {str(e)}', 'danger')
    return render_template('sale_form.html', products=products_list, today=date.today())

# ─── INVENTORY ────────────────────────────────────────────

@app.route('/inventory')
def inventory():
    rows = query_db("SELECT * FROM InventorySummary ORDER BY product_name")
    low  = query_db("SELECT * FROM LowStockProducts")
    return render_template('inventory.html', inventory=rows, low_stock=low)

# ─── REPORTS ──────────────────────────────────────────────

@app.route('/reports')
def reports():
    # Aggregate stats
    stats = {
        'total_products':  query_db("SELECT COUNT(*) AS c FROM Product", fetchone=True)['c'],
        'total_suppliers': query_db("SELECT COUNT(*) AS c FROM Supplier", fetchone=True)['c'],
        'total_purchases': query_db("SELECT COUNT(*) AS c FROM Purchase", fetchone=True)['c'],
        'total_sales':     query_db("SELECT COUNT(*) AS c FROM Sale", fetchone=True)['c'],
        'total_revenue':   query_db("SELECT COALESCE(SUM(quantity*sale_price),0) AS r FROM Sale", fetchone=True)['r'],
        'avg_price':       query_db("SELECT ROUND(AVG(price),2) AS a FROM Product", fetchone=True)['a'],
    }

    # Monthly sales revenue (all months)
    monthly = query_db("SELECT * FROM MonthlySalesRevenue")

    # Supplier-wise purchase summary (JOIN + aggregate)
    supplier_summary = query_db("SELECT * FROM SupplierPurchaseSummary ORDER BY total_purchase_value DESC")

    # Top 10 selling products
    top_products = query_db("""
        SELECT p.name, p.category,
               SUM(s.quantity)              AS total_sold,
               SUM(s.quantity*s.sale_price) AS revenue,
               p.stock_quantity             AS current_stock
        FROM Sale s
        JOIN Product p ON s.product_id = p.product_id
        GROUP BY p.product_id, p.name, p.category, p.stock_quantity
        ORDER BY total_sold DESC
        LIMIT 10
    """)

    # Category summary (GROUP BY + aggregate)
    category_summary = query_db("""
        SELECT p.category,
               COUNT(DISTINCT p.product_id)     AS num_products,
               ROUND(AVG(p.price), 2)           AS avg_price,
               SUM(p.stock_quantity)            AS total_stock,
               COALESCE(SUM(s.quantity * s.sale_price), 0) AS total_revenue
        FROM Product p
        LEFT JOIN Sale s ON p.product_id = s.product_id
        GROUP BY p.category
        ORDER BY total_revenue DESC
    """)

    # Stock log (recent 20)
    stock_log = query_db("""
        SELECT sl.*, p.name AS product_name
        FROM StockLog sl
        JOIN Product p ON sl.product_id = p.product_id
        ORDER BY sl.log_time DESC
        LIMIT 20
    """)

    return render_template('reports.html',
        stats=stats,
        monthly=monthly,
        supplier_summary=supplier_summary,
        top_products=top_products,
        category_summary=category_summary,
        stock_log=stock_log
    )

# ─── API ENDPOINT: Get product price ──────────────────────

@app.route('/api/product/<int:pid>')
def api_product(pid):
    product = query_db(
        "SELECT product_id, name, price, stock_quantity FROM Product WHERE product_id=%s",
        (pid,), fetchone=True
    )
    if product:
        return jsonify(product)
    return jsonify({'error': 'not found'}), 404

# ─── RUN ──────────────────────────────────────────────────

if __name__ == '__main__':
    app.run(debug=True, port=5000)
