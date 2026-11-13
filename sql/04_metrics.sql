-- =====================================================================
-- 04_metrics.sql  —  the 5 product metrics, monthly, as the product team
-- would track them. Definitions live in README §Metrics.
-- =====================================================================

-- name: metrics_monthly
WITH base AS (
    SELECT * FROM v_order_fact
    WHERE purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
),
valid AS (     -- orders that count as a purchase
    SELECT * FROM base WHERE order_status NOT IN ('canceled', 'unavailable')
),
first_orders AS (   -- for repeat rate: each customer's first purchase, all history
    SELECT customer_unique_id,
           MIN(purchased_at) AS first_at
    FROM v_order_fact
    WHERE order_status NOT IN ('canceled', 'unavailable')
    GROUP BY customer_unique_id
),
repeat90 AS (
    SELECT strftime('%Y-%m', f.first_at)                         AS purchase_month,
           COUNT(DISTINCT f.customer_unique_id)                  AS new_customers,
           COUNT(DISTINCT CASE WHEN date(v.purchased_at) > date(f.first_at)
                                AND julianday(v.purchased_at) - julianday(f.first_at) <= 90
                               THEN f.customer_unique_id END)    AS repeat_90d
    FROM first_orders f
    JOIN v_order_fact v ON v.customer_unique_id = f.customer_unique_id
                       AND v.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY 1
)
SELECT b.purchase_month,
       COUNT(*)                                                         AS orders,
       -- 1. On-time delivery rate (delivered orders)
       ROUND(100.0 * AVG(CASE WHEN b.order_status = 'delivered' THEN b.on_time END), 2) AS on_time_rate,
       -- 2. Avg delivery time, purchase -> customer (days)
       ROUND(AVG(CASE WHEN b.order_status = 'delivered' THEN b.delivery_days END), 2)  AS avg_delivery_days,
       -- 3. 1-star review rate (all reviewed orders)
       ROUND(100.0 * AVG(CASE WHEN b.review_score IS NOT NULL
                              THEN b.review_score = 1 END), 2)                          AS one_star_rate,
       -- 4. Average order value (items + freight, valid orders)
       ROUND(AVG(CASE WHEN b.order_status NOT IN ('canceled','unavailable')
                      THEN b.items_value + b.freight_value END), 2)                     AS aov_brl,
       -- 5. 90-day repeat purchase rate of customers acquired this month
       r.new_customers,
       ROUND(100.0 * r.repeat_90d / r.new_customers, 2)                                AS repeat_rate_90d
FROM base b
LEFT JOIN repeat90 r ON r.purchase_month = b.purchase_month
GROUP BY b.purchase_month
ORDER BY b.purchase_month;

-- name: metrics_headline
-- One number per metric for the whole window (the scorecard)
WITH base AS (
    SELECT * FROM v_order_fact
    WHERE purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
),
firsts AS (
    SELECT customer_unique_id, MIN(purchased_at) AS first_at
    FROM v_order_fact WHERE order_status NOT IN ('canceled','unavailable')
    GROUP BY customer_unique_id
),
rep AS (
    SELECT f.customer_unique_id,
           MAX(CASE WHEN date(v.purchased_at) > date(f.first_at)
                     AND julianday(v.purchased_at) - julianday(f.first_at) <= 90 THEN 1 ELSE 0 END) AS r90
    FROM firsts f
    JOIN v_order_fact v ON v.customer_unique_id = f.customer_unique_id
                       AND v.order_status NOT IN ('canceled','unavailable')
    WHERE f.first_at >= '2017-01-01' AND f.first_at < '2018-06-01'   -- full 90d follow-up
    GROUP BY f.customer_unique_id
)
SELECT 'On-time delivery rate (%)' AS metric,
       ROUND(100.0 * AVG(CASE WHEN order_status = 'delivered' THEN on_time END), 2) AS value FROM base
UNION ALL
SELECT 'Avg delivery time (days)',
       ROUND(AVG(CASE WHEN order_status = 'delivered' THEN delivery_days END), 2) FROM base
UNION ALL
SELECT 'Delivered within 14 days (%)',
       ROUND(100.0 * AVG(CASE WHEN order_status = 'delivered' THEN delivery_days <= 14 END), 2) FROM base
UNION ALL
SELECT '1-star review rate (%)',
       ROUND(100.0 * AVG(CASE WHEN review_score IS NOT NULL THEN review_score = 1 END), 2) FROM base
UNION ALL
SELECT 'Average order value (BRL)',
       ROUND(AVG(CASE WHEN order_status NOT IN ('canceled','unavailable')
                      THEN items_value + freight_value END), 2) FROM base
UNION ALL
SELECT '90-day repeat purchase rate (%)', ROUND(100.0 * AVG(r90), 2) FROM rep;
