-- =====================================================================
-- 03_drivers.sql  —  delivery delay vs review score
-- Population: delivered orders with a review, purchased 2017-01 .. 2018-08
-- =====================================================================

-- name: review_by_delay_bucket
WITH d AS (
    SELECT *,
           CASE WHEN delay_days <= -10 THEN '01: 10+ days early'
                WHEN delay_days <= -5  THEN '02: 5-9 days early'
                WHEN delay_days <  0   THEN '03: 1-4 days early'
                WHEN delay_days =  0   THEN '04: on the day'
                WHEN delay_days <= 3   THEN '05: 1-3 days late'
                WHEN delay_days <= 7   THEN '06: 4-7 days late'
                WHEN delay_days <= 14  THEN '07: 8-14 days late'
                ELSE                        '08: 15+ days late' END AS delay_bucket
    FROM v_order_fact
    WHERE order_status = 'delivered' AND review_score IS NOT NULL
      AND delivered_at IS NOT NULL
      AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
)
SELECT delay_bucket,
       COUNT(*)                                         AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_orders,
       ROUND(AVG(review_score), 3)                      AS avg_review,
       ROUND(100.0 * AVG(review_score = 1), 2)          AS one_star_rate,
       ROUND(100.0 * AVG(review_score <= 2), 2)         AS low_review_rate
FROM d
GROUP BY delay_bucket
ORDER BY delay_bucket;

-- name: review_on_time_vs_late
SELECT CASE on_time WHEN 1 THEN 'on time' ELSE 'late' END AS delivery,
       COUNT(*)                                         AS orders,
       ROUND(AVG(review_score), 3)                      AS avg_review,
       ROUND(100.0 * AVG(review_score = 1), 2)          AS one_star_rate,
       ROUND(100.0 * AVG(review_score <= 2), 2)         AS low_review_rate
FROM v_order_fact
WHERE order_status = 'delivered' AND review_score IS NOT NULL AND on_time IS NOT NULL
  AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
GROUP BY on_time;

-- name: low_review_share_from_late
-- How much of the 1-2 star problem is explained by lateness / non-delivery?
WITH r AS (
    SELECT CASE WHEN order_status <> 'delivered' THEN 'not delivered'
                WHEN on_time = 0               THEN 'delivered late'
                ELSE                                'delivered on time' END AS outcome,
           review_score
    FROM v_order_fact
    WHERE review_score IS NOT NULL
      AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
)
SELECT outcome,
       COUNT(*)                                                          AS reviewed_orders,
       SUM(review_score <= 2)                                            AS low_reviews,
       ROUND(100.0 * AVG(review_score <= 2), 2)                          AS low_review_rate,
       ROUND(100.0 * SUM(review_score <= 2) / SUM(SUM(review_score <= 2)) OVER (), 2) AS share_of_all_low_reviews
FROM r
GROUP BY outcome
ORDER BY low_reviews DESC;

-- name: drivers_by_region
-- Customer state: lateness and review. Ranked by number of late orders.
SELECT customer_state,
       COUNT(*)                                     AS delivered_orders,
       ROUND(100.0 * AVG(on_time), 2)               AS on_time_rate,
       SUM(on_time = 0)                             AS late_orders,
       ROUND(AVG(delivery_days), 1)                 AS avg_delivery_days,
       ROUND(AVG(promised_days), 1)                 AS avg_promised_days,
       ROUND(AVG(review_score), 3)                  AS avg_review,
       ROUND(100.0 * AVG(review_score <= 2), 2)     AS low_review_rate
FROM v_order_fact
WHERE order_status = 'delivered' AND on_time IS NOT NULL
  AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
GROUP BY customer_state
ORDER BY late_orders DESC;

-- name: drivers_by_route
-- Seller state -> customer state lanes with the most late orders (min 300 orders)
SELECT seller_state || ' → ' || customer_state     AS route,
       COUNT(*)                                     AS delivered_orders,
       ROUND(100.0 * AVG(on_time), 2)               AS on_time_rate,
       SUM(on_time = 0)                             AS late_orders,
       ROUND(AVG(delivery_days), 1)                 AS avg_delivery_days,
       ROUND(AVG(review_score), 3)                  AS avg_review
FROM v_order_fact
WHERE order_status = 'delivered' AND on_time IS NOT NULL
  AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
GROUP BY seller_state, customer_state
HAVING COUNT(*) >= 300
ORDER BY late_orders DESC
LIMIT 20;

-- name: drivers_by_category
SELECT category,
       COUNT(*)                                     AS delivered_orders,
       ROUND(100.0 * AVG(on_time), 2)               AS on_time_rate,
       SUM(on_time = 0)                             AS late_orders,
       ROUND(AVG(review_score), 3)                  AS avg_review,
       ROUND(100.0 * AVG(review_score <= 2), 2)     AS low_review_rate,
       -- low-review rate when the order was ON TIME: isolates product/quality issues from logistics
       ROUND(100.0 * AVG(CASE WHEN on_time = 1 THEN review_score <= 2 END), 2) AS low_review_rate_on_time
FROM v_order_fact
WHERE order_status = 'delivered' AND on_time IS NOT NULL AND review_score IS NOT NULL
  AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
GROUP BY category
HAVING COUNT(*) >= 500
ORDER BY low_review_rate DESC;

-- name: drivers_by_seller
-- Sellers with >= 50 delivered orders. Ranks sellers by how many late orders they create
-- and computes cumulative share so we can see concentration (Pareto).
WITH s AS (
    SELECT seller_id,
           seller_state,
           COUNT(*)                                 AS delivered_orders,
           SUM(on_time = 0)                         AS late_orders,
           ROUND(100.0 * AVG(on_time), 2)           AS on_time_rate,
           ROUND(AVG(julianday(shipped_at) - julianday(approved_at)), 2) AS avg_days_to_ship,
           ROUND(AVG(review_score), 3)              AS avg_review,
           ROUND(100.0 * AVG(review_score <= 2), 2) AS low_review_rate
    FROM v_order_fact
    WHERE order_status = 'delivered' AND on_time IS NOT NULL
      AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
    GROUP BY seller_id, seller_state
),
total AS (
    SELECT SUM(on_time = 0) AS all_late
    FROM v_order_fact
    WHERE order_status = 'delivered' AND on_time IS NOT NULL
      AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
)
SELECT RANK() OVER (ORDER BY late_orders DESC)               AS late_rank,
       s.*,
       ROUND(100.0 * SUM(late_orders) OVER (ORDER BY late_orders DESC
                                            ROWS UNBOUNDED PRECEDING) / t.all_late, 2) AS cum_pct_of_all_late
FROM s CROSS JOIN total t
WHERE delivered_orders >= 50
ORDER BY late_orders DESC;

-- name: seller_concentration
-- What share of sellers produce half of all late deliveries?
WITH s AS (
    SELECT seller_id, SUM(on_time = 0) AS late_orders, COUNT(*) AS orders
    FROM v_order_fact
    WHERE order_status = 'delivered' AND on_time IS NOT NULL
      AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
    GROUP BY seller_id
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (ORDER BY late_orders DESC)                             AS rn,
           COUNT(*)     OVER ()                                                      AS n_sellers,
           SUM(late_orders) OVER (ORDER BY late_orders DESC ROWS UNBOUNDED PRECEDING) AS cum_late,
           SUM(late_orders) OVER ()                                                  AS all_late,
           SUM(orders) OVER (ORDER BY late_orders DESC ROWS UNBOUNDED PRECEDING)      AS cum_orders,
           SUM(orders) OVER ()                                                       AS all_orders
    FROM s
)
SELECT threshold_pct_of_late,
       MIN(rn)                                          AS sellers_needed,
       MAX(n_sellers)                                   AS total_sellers,
       ROUND(100.0 * MIN(rn) / MAX(n_sellers), 2)       AS pct_of_sellers,
       ROUND(100.0 * MIN(cum_orders) / MAX(all_orders), 2) AS pct_of_orders_they_handle
FROM ranked
JOIN (SELECT 25 AS threshold_pct_of_late UNION ALL SELECT 50 UNION ALL SELECT 80) th
  ON 100.0 * cum_late / all_late >= th.threshold_pct_of_late
GROUP BY threshold_pct_of_late
ORDER BY threshold_pct_of_late;

-- name: late_cause_split
-- Is lateness a seller problem (slow to hand over) or a carrier problem (slow in transit)?
-- Compares late vs on-time orders on each leg.
SELECT CASE on_time WHEN 1 THEN 'on time' ELSE 'late' END       AS delivery,
       COUNT(*)                                                 AS orders,
       ROUND(AVG(julianday(shipped_at) - julianday(approved_at)), 2)  AS avg_seller_handling_days,
       ROUND(AVG(julianday(delivered_at) - julianday(shipped_at)), 2) AS avg_carrier_transit_days,
       ROUND(AVG(promised_days), 2)                             AS avg_promised_days
FROM v_order_fact
WHERE order_status = 'delivered' AND on_time IS NOT NULL
  AND shipped_at IS NOT NULL AND approved_at IS NOT NULL
  AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
GROUP BY on_time;

-- name: problem_sellers
-- Volume alone explains most of the Pareto above. Here we isolate sellers whose
-- late RATE is at least 2x the platform rate (min 30 delivered orders) and ask
-- how much of the late volume and low-review volume they own vs their order share.
WITH base AS (
    SELECT * FROM v_order_fact
    WHERE order_status = 'delivered' AND on_time IS NOT NULL
      AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
),
platform AS (SELECT 1.0 - AVG(on_time) AS late_rate FROM base),
s AS (
    SELECT seller_id,
           COUNT(*)                   AS orders,
           SUM(on_time = 0)           AS late_orders,
           1.0 - AVG(on_time)         AS late_rate,
           SUM(review_score <= 2)     AS low_reviews
    FROM base GROUP BY seller_id
),
flagged AS (
    SELECT s.*,
           CASE WHEN s.orders >= 30 AND s.late_rate >= 2 * p.late_rate
                THEN 'problem seller (late rate >= 2x platform)'
                ELSE 'all other sellers' END AS seller_group
    FROM s CROSS JOIN platform p
)
SELECT seller_group,
       COUNT(*)                                                       AS sellers,
       SUM(orders)                                                    AS orders,
       ROUND(100.0 * SUM(orders)      / SUM(SUM(orders))      OVER (), 2) AS pct_of_orders,
       ROUND(100.0 * SUM(late_orders) / SUM(SUM(late_orders)) OVER (), 2) AS pct_of_late_orders,
       ROUND(100.0 * SUM(low_reviews) / SUM(SUM(low_reviews)) OVER (), 2) AS pct_of_low_reviews,
       ROUND(100.0 * SUM(late_orders) / SUM(orders), 2)               AS late_rate
FROM flagged
GROUP BY seller_group;

-- name: review_by_basket
-- Multi-item / multi-seller baskets (often split into separate shipments) and reviews,
-- shown separately for on-time orders so lateness is not the explanation.
SELECT CASE WHEN n_sellers > 1 THEN '3: multiple sellers'
            WHEN n_items   > 1 THEN '2: 2+ items, one seller'
            ELSE                    '1: single item' END        AS basket,
       COUNT(*)                                                 AS orders,
       ROUND(100.0 * AVG(review_score <= 2), 2)                 AS low_review_rate,
       ROUND(100.0 * AVG(CASE WHEN on_time = 1 THEN review_score <= 2 END), 2) AS low_review_rate_on_time
FROM v_order_fact
WHERE order_status = 'delivered' AND review_score IS NOT NULL AND on_time IS NOT NULL
  AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
GROUP BY 1 ORDER BY 1;
