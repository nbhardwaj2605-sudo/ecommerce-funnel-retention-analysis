"""Load the 9 Olist CSVs into a SQLite database (data/olist.db).

Usage:  python src/load_data.py
Expects the Kaggle CSVs in data/raw/ (see README for download steps).
"""
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
DB = ROOT / "data" / "olist.db"

TABLES = {
    "orders": "olist_orders_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "payments": "olist_order_payments_dataset.csv",
    "reviews": "olist_order_reviews_dataset.csv",
    "customers": "olist_customers_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "products": "olist_products_dataset.csv",
    "geolocation": "olist_geolocation_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
}

# Indexes that make the joins in sql/ fast
INDEXES = [
    "CREATE INDEX IF NOT EXISTS ix_orders_order ON orders(order_id)",
    "CREATE INDEX IF NOT EXISTS ix_orders_cust ON orders(customer_id)",
    "CREATE INDEX IF NOT EXISTS ix_items_order ON order_items(order_id)",
    "CREATE INDEX IF NOT EXISTS ix_items_seller ON order_items(seller_id)",
    "CREATE INDEX IF NOT EXISTS ix_items_product ON order_items(product_id)",
    "CREATE INDEX IF NOT EXISTS ix_pay_order ON payments(order_id)",
    "CREATE INDEX IF NOT EXISTS ix_rev_order ON reviews(order_id)",
    "CREATE INDEX IF NOT EXISTS ix_cust_id ON customers(customer_id)",
    "CREATE INDEX IF NOT EXISTS ix_cust_unique ON customers(customer_unique_id)",
    "CREATE INDEX IF NOT EXISTS ix_prod_id ON products(product_id)",
    "CREATE INDEX IF NOT EXISTS ix_seller_id ON sellers(seller_id)",
]


def main() -> None:
    DB.unlink(missing_ok=True)
    con = sqlite3.connect(DB)
    for table, fname in TABLES.items():
        df = pd.read_csv(RAW / fname, dtype=str)  # keep raw text; cast in SQL
        df.to_sql(table, con, index=False)
        print(f"{table:22s} {len(df):>9,d} rows")
    for stmt in INDEXES:
        con.execute(stmt)
    # Build the analysis views (one row per order, etc.)
    con.executescript((ROOT / "sql" / "00_views.sql").read_text())
    con.commit()
    con.close()
    print(f"\nSaved -> {DB}")


if __name__ == "__main__":
    main()
