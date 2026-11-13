# Power BI dashboard — build guide

The data is ready in `powerbi/data/` (run `python src/export_powerbi.py`).
Build time: about 45–60 minutes. Save the result as `powerbi/olist_funnel_retention.pbix`
and export a screenshot of each page to `powerbi/screenshots/` for the README.

## 1. Load and model

**Get Data → Text/CSV** for each file in `powerbi/data/`. In Power Query, set types:
`purchase_date`, `date` → Date; `*_at` → Date/Time; flags and counts → Whole number;
values → Decimal. `on_time` and `review_score` have blanks (undelivered / unreviewed) — keep them blank, don't replace with 0.

Relationships (Model view, single direction, many → one):

| From (many) | To (one) |
|---|---|
| `fact_orders[purchase_date]` | `dim_date[date]` |
| `fact_orders[customer_unique_id]` | `dim_customer[customer_unique_id]` |
| `fact_orders[seller_id]` | `dim_seller[seller_id]` |

`cohort_retention`, `funnel_stage_times`, `drivers_by_seller` and `model_rf_group_importance` stay unrelated (they're pre-aggregated in SQL).
Mark `dim_date` as the date table.

## 2. DAX measures

Create a blank table called `_Measures` and add:

```DAX
Orders = COUNTROWS ( fact_orders )

Delivered Orders = SUM ( fact_orders[is_delivered] )

On-Time Delivery Rate =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_orders ), fact_orders[on_time] = 1, fact_orders[is_delivered] = 1 ),
    CALCULATE ( COUNTROWS ( fact_orders ), NOT ISBLANK ( fact_orders[on_time] ), fact_orders[is_delivered] = 1 )
)

Late Orders =
CALCULATE ( COUNTROWS ( fact_orders ), fact_orders[on_time] = 0, fact_orders[is_delivered] = 1 )

Avg Delivery Days =
CALCULATE ( AVERAGE ( fact_orders[delivery_days] ), fact_orders[is_delivered] = 1 )

Reviewed Orders = CALCULATE ( COUNTROWS ( fact_orders ), NOT ISBLANK ( fact_orders[review_score] ) )

1-Star Rate =
DIVIDE ( CALCULATE ( COUNTROWS ( fact_orders ), fact_orders[review_score] = 1 ), [Reviewed Orders] )

Low Review Rate (1-2) =
DIVIDE ( CALCULATE ( COUNTROWS ( fact_orders ), fact_orders[review_score] <= 2 ), [Reviewed Orders] )

Avg Review = AVERAGE ( fact_orders[review_score] )

AOV =
CALCULATE (
    AVERAGEX ( fact_orders, fact_orders[items_value] + fact_orders[freight_value] ),
    fact_orders[is_valid_purchase] = 1
)

Customers = DISTINCTCOUNT ( fact_orders[customer_unique_id] )

Repeat Customer Rate =
-- share of customers in the current filter context with 2+ purchase DAYS
VAR t =
    ADDCOLUMNS (
        VALUES ( fact_orders[customer_unique_id] ),
        "days", CALCULATE ( DISTINCTCOUNT ( fact_orders[purchase_date] ), fact_orders[is_valid_purchase] = 1 )
    )
RETURN DIVIDE ( COUNTROWS ( FILTER ( t, [days] >= 2 ) ), COUNTROWS ( t ) )

Share of Late Orders =
DIVIDE ( [Late Orders], CALCULATE ( [Late Orders], ALLSELECTED ( fact_orders[customer_state] ) ) )

-- Funnel stage counts (for the funnel visual)
Stage Approved  = SUM ( fact_orders[is_approved] )
Stage Shipped   = SUM ( fact_orders[is_shipped] )
Stage Delivered = SUM ( fact_orders[is_delivered] )
Stage Reviewed  = SUM ( fact_orders[is_reviewed] )
```

Format the rate measures as Percentage (1 decimal), AOV as currency (R$).

## 3. Pages

Put one slicer row at the top of every page: **purchase month range** (`dim_date[month]`), **customer state**, **category**. Sync slicers across pages (View → Sync slicers).

**Page 1 — Overview (the scorecard)**
- 5 Card visuals: On-Time Delivery Rate · Avg Delivery Days · 1-Star Rate · AOV · Repeat Customer Rate
- Line chart: On-Time Delivery Rate by `dim_date[month]`
- Line chart directly below it (not a dual axis): 1-Star Rate by month — the two dips line up (Nov-17, Feb–Mar-18)

**Page 2 — Funnel**
- Funnel visual using a small "stage" table. Easiest: Enter Data → table `Stage` with rows placed/approved/shipped/delivered/reviewed and a `sort` column, then a measure
  `Stage Orders = SWITCH ( SELECTEDVALUE ( Stage[stage] ), "placed", [Orders], "approved", [Stage Approved], "shipped", [Stage Shipped], "delivered", [Stage Delivered], "reviewed", [Stage Reviewed] )`
- Bar chart from `funnel_stage_times`: median_days and p90_days by transition
- Donut / bar: Orders by `order_status` where `is_delivered = 0` (where lost orders end up)

**Page 3 — Review drivers**
- Clustered column: Low Review Rate (1-2) by `delay_bucket` (sort by a custom order column — or prefix the labels 1–8)
- Bar: Late Orders by `customer_state` with tooltip On-Time Delivery Rate, Low Review Rate
- Bar: Low Review Rate by `basket_type`
- Table: `drivers_by_seller` top 25 by late_orders, with on_time_rate, avg_days_to_ship, low_review_rate — conditional formatting (background) on on_time_rate
- Optional: Filled map of `customer_state` coloured by On-Time Delivery Rate (set the data category of `customer_state` to State or Province and add "Brazil" as country)

**Page 4 — Retention**
- Matrix from `cohort_retention`: rows `cohort_month`, columns `month_number` (filter 1–12), values `pct_retained`, conditional formatting with a single-hue colour scale (white → blue)
- Column chart from `repeat_purchase_by_cohort`: repeat_rate_90d by cohort_month
- Card: Repeat Customer Rate · Card: Customers

**Page 5 — Model (optional)**
- Bar chart from `model_rf_group_importance`: auc_drop_mean by feature_group
- Text box with the takeaway: "Delivery features carry most of the signal; removing them drops test ROC-AUC from 0.72 to 0.66."

## 4. Design notes
- One accent colour for "bad" (late, low reviews); everything else neutral blue/grey.
- Titles state the takeaway ("RJ has 13% of orders but 23% of late deliveries"), not the field names.
- No dual-axis charts — stack two line charts instead.
