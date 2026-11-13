"""Export clean tables for the Power BI dashboard -> powerbi/data/*.csv

Usage:  python src/export_powerbi.py
Star schema:  fact_orders (1 row per order)  ->  dim_customer, dim_seller, dim_date
plus the pre-aggregated cohort table (retention is easier to model in SQL than DAX).
"""
import shutil
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "data" / "olist.db"
OUT = ROOT / "powerbi" / "data"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB)
    fact = pd.read_sql_query("""
        SELECT order_id, customer_unique_id, customer_state, seller_id, seller_state,
               category, order_status, date(purchased_at) AS purchase_date, purchase_month,
               approved_at, shipped_at, delivered_at, estimated_at, reviewed_at,
               review_score, on_time, ROUND(delay_days, 0) AS delay_days,
               ROUND(delivery_days, 2) AS delivery_days, ROUND(promised_days, 0) AS promised_days,
               n_items, n_sellers, ROUND(items_value, 2) AS items_value,
               ROUND(freight_value, 2) AS freight_value, ROUND(payment_value, 2) AS payment_value,
               payment_type, installments
        FROM v_order_fact
        WHERE purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
    """, con)
    # Funnel flags as columns so Power BI can sum them directly
    fact["is_approved"] = fact["approved_at"].notna().astype(int)
    fact["is_shipped"] = (fact["is_approved"] & fact["shipped_at"].notna()).astype(int)
    fact["is_delivered"] = (fact["is_shipped"] & (fact["order_status"] == "delivered")
                            & fact["delivered_at"].notna()).astype(int)
    fact["is_reviewed"] = (fact["is_delivered"] & fact["review_score"].notna()).astype(int)
    fact["is_valid_purchase"] = (~fact["order_status"].isin(["canceled", "unavailable"])).astype(int)
    fact["delay_bucket"] = pd.cut(fact["delay_days"], [-999, -10, -5, -1, 0, 3, 7, 14, 999],
                                  labels=["10+ early", "5-9 early", "1-4 early", "on the day",
                                          "1-3 late", "4-7 late", "8-14 late", "15+ late"]).astype(str)
    fact["basket_type"] = (fact["n_sellers"].gt(1).map({True: "multiple sellers", False: None})
                           .fillna(fact["n_items"].gt(1).map({True: "2+ items, one seller",
                                                              False: "single item"})))
    fact.to_csv(OUT / "fact_orders.csv", index=False)

    pd.read_sql_query("""
        SELECT customer_unique_id, MIN(purchase_month) AS cohort_month,
               COUNT(*) AS lifetime_orders, MAX(customer_state) AS customer_state
        FROM v_order_fact WHERE order_status NOT IN ('canceled','unavailable')
        GROUP BY customer_unique_id""", con).to_csv(OUT / "dim_customer.csv", index=False)
    pd.read_sql_query("SELECT seller_id, seller_city, seller_state FROM sellers", con) \
        .to_csv(OUT / "dim_seller.csv", index=False)
    con.close()

    dates = pd.DataFrame({"date": pd.date_range("2017-01-01", "2018-08-31")})
    dates["month"] = dates["date"].dt.strftime("%Y-%m")
    dates["year"] = dates["date"].dt.year
    dates.to_csv(OUT / "dim_date.csv", index=False)

    tables = ROOT / "outputs" / "tables"
    for name in ["cohort_retention", "repeat_purchase_by_cohort", "funnel_stages",
                 "funnel_stage_times", "drivers_by_seller", "model_rf_group_importance"]:
        shutil.copy(tables / f"{name}.csv", OUT / f"{name}.csv")
    print(f"fact_orders: {len(fact):,} rows -> {OUT}")


if __name__ == "__main__":
    main()
