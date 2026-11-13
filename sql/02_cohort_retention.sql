-- =====================================================================
-- 02_cohort_retention.sql  —  month-of-first-purchase cohorts
-- GOTCHA: customer_id is a NEW id for every order. The person is
-- customer_unique_id. Using customer_id gives ~0% repeat by construction.
-- Valid purchase = any order not canceled / unavailable.
-- =====================================================================

-- name: id_gotcha
-- Proof of the gotcha: same orders, two different "customer" keys
SELECT 'customer_id'        AS key_used,
       COUNT(DISTINCT customer_id)                               AS customers,
       COUNT(*)                                                  AS orders,
       ROUND(1.0 * COUNT(*) / COUNT(DISTINCT customer_id), 4)    AS orders_per_customer
FROM v_order_fact
UNION ALL
SELECT 'customer_unique_id',
       COUNT(DISTINCT customer_unique_id),
       COUNT(*),
       ROUND(1.0 * COUNT(*) / COUNT(DISTINCT customer_unique_id), 4)
FROM v_order_fact;

-- name: cohort_retention
-- Long format: cohort_month x months_since_first -> active customers, % retained
WITH purchases AS (
    SELECT customer_unique_id,
           order_id,
           purchased_at,
           purchase_month
    FROM v_order_fact
    WHERE order_status NOT IN ('canceled', 'unavailable')
),
first_purchase AS (
    SELECT customer_unique_id,
           MIN(purchase_month) AS cohort_month
    FROM purchases
    GROUP BY customer_unique_id
),
activity AS (
    SELECT DISTINCT p.customer_unique_id,
           f.cohort_month,
           -- whole months between cohort month and this purchase month
           (CAST(substr(p.purchase_month, 1, 4) AS INT) - CAST(substr(f.cohort_month, 1, 4) AS INT)) * 12
         + (CAST(substr(p.purchase_month, 6, 2) AS INT) - CAST(substr(f.cohort_month, 6, 2) AS INT))
             AS month_number
    FROM purchases p
    JOIN first_purchase f USING (customer_unique_id)
),
cohort_counts AS (
    SELECT cohort_month, month_number, COUNT(*) AS active_customers
    FROM activity
    GROUP BY cohort_month, month_number
)
SELECT cohort_month,
       month_number,
       active_customers,
       FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month
                                           ORDER BY month_number)          AS cohort_size,
       ROUND(100.0 * active_customers /
             FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month
                                                 ORDER BY month_number), 3) AS pct_retained
FROM cohort_counts
WHERE cohort_month BETWEEN '2017-01' AND '2018-08'
ORDER BY cohort_month, month_number;

-- name: repeat_purchase_by_cohort
-- Repeat purchase rate: % of a cohort that ever placed a 2nd order on a later day,
-- plus the 90-day repeat rate (fair across cohorts that have >= 90 days of history)
WITH purchases AS (
    SELECT customer_unique_id, order_id, purchased_at, purchase_month
    FROM v_order_fact
    WHERE order_status NOT IN ('canceled', 'unavailable')
),
seq AS (
    SELECT customer_unique_id,
           purchased_at,
           purchase_month,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchased_at) AS n,
           MIN(purchased_at) OVER (PARTITION BY customer_unique_id)                 AS first_at
    FROM purchases
),
per_customer AS (
    SELECT customer_unique_id,
           MIN(purchase_month)                                   AS cohort_month,
           MIN(first_at)                                         AS first_at,
           -- first order on a LATER calendar day (same-day split baskets are not "returning")
           MIN(CASE WHEN date(purchased_at) > date(first_at) THEN purchased_at END) AS second_at
    FROM seq
    GROUP BY customer_unique_id
)
SELECT cohort_month,
       COUNT(*)                                                                  AS customers,
       SUM(second_at IS NOT NULL)                                                AS repeat_customers,
       ROUND(100.0 * AVG(second_at IS NOT NULL), 2)                              AS repeat_rate_ever,
       ROUND(100.0 * AVG(second_at IS NOT NULL
                         AND julianday(second_at) - julianday(first_at) <= 90), 2) AS repeat_rate_90d,
       ROUND(AVG(CASE WHEN second_at IS NOT NULL
                      THEN julianday(second_at) - julianday(first_at) END), 1)  AS avg_days_to_2nd
FROM per_customer
WHERE cohort_month BETWEEN '2017-01' AND '2018-05'   -- every cohort has >= 90 days of follow-up
GROUP BY cohort_month
ORDER BY cohort_month;

-- name: repeat_purchase_overall
WITH purchases AS (
    SELECT customer_unique_id, purchased_at
    FROM v_order_fact
    WHERE order_status NOT IN ('canceled', 'unavailable')
),
per_customer AS (
    SELECT customer_unique_id,
           COUNT(*)                         AS orders,
           COUNT(DISTINCT date(purchased_at)) AS purchase_days
    FROM purchases
    GROUP BY customer_unique_id
)
SELECT COUNT(*)                                        AS customers,
       ROUND(100.0 * AVG(orders >= 2), 2)              AS pct_2plus_orders,
       ROUND(100.0 * AVG(purchase_days >= 2), 2)       AS pct_2plus_purchase_days,
       ROUND(100.0 * AVG(purchase_days >= 3), 2)       AS pct_3plus_purchase_days,
       ROUND(AVG(orders), 3)                           AS avg_orders_per_customer
FROM per_customer;

-- name: repeat_by_first_review
-- Does the FIRST experience predict coming back?
WITH purchases AS (
    SELECT customer_unique_id, purchased_at, review_score, on_time,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchased_at) AS n
    FROM v_order_fact
    WHERE order_status NOT IN ('canceled', 'unavailable')
),
firsts AS (
    SELECT p.customer_unique_id, p.purchased_at AS first_at, p.review_score, p.on_time
    FROM purchases p WHERE n = 1
),
returned AS (
    SELECT f.customer_unique_id,
           MAX(CASE WHEN date(p.purchased_at) > date(f.first_at) THEN 1 ELSE 0 END) AS came_back
    FROM firsts f JOIN purchases p USING (customer_unique_id)
    GROUP BY f.customer_unique_id
)
SELECT f.review_score                              AS first_order_review,
       COUNT(*)                                    AS customers,
       ROUND(100.0 * AVG(r.came_back), 2)          AS repeat_rate
FROM firsts f JOIN returned r USING (customer_unique_id)
WHERE f.review_score IS NOT NULL
  AND f.first_at < '2018-06-01'
GROUP BY f.review_score
ORDER BY f.review_score;

-- name: repeat_by_first_category
-- Which first-purchase categories bring customers back? (first orders before 2018-06)
WITH f AS (
    SELECT customer_unique_id, category, purchased_at,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchased_at) AS n
    FROM v_order_fact
    WHERE order_status NOT IN ('canceled', 'unavailable')
),
firsts AS (SELECT * FROM f WHERE n = 1 AND purchased_at < '2018-06-01'),
r AS (
    SELECT fi.customer_unique_id, fi.category,
           MAX(date(f.purchased_at) > date(fi.purchased_at)) AS came_back
    FROM firsts fi JOIN f USING (customer_unique_id)
    GROUP BY fi.customer_unique_id, fi.category
)
SELECT category, COUNT(*) AS customers, ROUND(100.0 * AVG(came_back), 2) AS repeat_rate
FROM r GROUP BY category HAVING COUNT(*) >= 1000
ORDER BY repeat_rate DESC;
