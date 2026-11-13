-- =====================================================================
-- 01_funnel.sql  —  placed → approved → shipped → delivered → reviewed
-- Window: purchases 2017-01-01 .. 2018-08-31 (drops the thin 2016 start
-- and the last weeks of 2018 where orders had not finished their journey)
-- Each stage requires the previous one (strict funnel).
-- Each "-- name:" block is saved as outputs/tables/<name>.csv
-- =====================================================================

-- name: funnel_stages
WITH base AS (
    SELECT *
    FROM v_order_fact
    WHERE purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
),
flags AS (
    SELECT order_id,
           1                                                     AS placed,
           CASE WHEN approved_at IS NOT NULL THEN 1 ELSE 0 END  AS approved,
           CASE WHEN approved_at IS NOT NULL
                 AND shipped_at  IS NOT NULL THEN 1 ELSE 0 END  AS shipped,
           CASE WHEN approved_at IS NOT NULL
                 AND shipped_at  IS NOT NULL
                 AND delivered_at IS NOT NULL
                 AND order_status = 'delivered' THEN 1 ELSE 0 END AS delivered,
           CASE WHEN approved_at IS NOT NULL
                 AND shipped_at  IS NOT NULL
                 AND delivered_at IS NOT NULL
                 AND order_status = 'delivered'
                 AND review_score IS NOT NULL THEN 1 ELSE 0 END AS reviewed
    FROM base
),
totals AS (
    SELECT 1 AS step, 'placed'    AS stage, SUM(placed)    AS orders FROM flags UNION ALL
    SELECT 2,         'approved',           SUM(approved)            FROM flags UNION ALL
    SELECT 3,         'shipped',            SUM(shipped)             FROM flags UNION ALL
    SELECT 4,         'delivered',          SUM(delivered)           FROM flags UNION ALL
    SELECT 5,         'reviewed',           SUM(reviewed)            FROM flags
)
SELECT step,
       stage,
       orders,
       LAG(orders) OVER (ORDER BY step) - orders                       AS dropped_vs_prev,
       ROUND(100.0 * orders / LAG(orders) OVER (ORDER BY step), 2)     AS pct_of_prev,
       ROUND(100.0 * orders / FIRST_VALUE(orders) OVER (ORDER BY step), 2) AS pct_of_placed
FROM totals
ORDER BY step;

-- name: funnel_stage_times
-- Time between stages, in days (avg, median, 90th percentile)
WITH base AS (
    SELECT *
    FROM v_order_fact
    WHERE purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
      AND order_status = 'delivered'
),
gaps AS (
    SELECT 'placed → approved'    AS transition, 1 AS step,
           julianday(approved_at)  - julianday(purchased_at) AS days FROM base WHERE approved_at IS NOT NULL
    UNION ALL
    SELECT 'approved → shipped',  2,
           julianday(shipped_at)   - julianday(approved_at)          FROM base WHERE shipped_at IS NOT NULL AND approved_at IS NOT NULL
    UNION ALL
    SELECT 'shipped → delivered', 3,
           julianday(delivered_at) - julianday(shipped_at)           FROM base WHERE delivered_at IS NOT NULL AND shipped_at IS NOT NULL
    UNION ALL
    SELECT 'delivered → review answered', 4,
           julianday(reviewed_at)  - julianday(delivered_at)   FROM base WHERE reviewed_at IS NOT NULL AND delivered_at IS NOT NULL
    UNION ALL
    SELECT 'placed → delivered (total)', 5,
           julianday(delivered_at) - julianday(purchased_at)         FROM base WHERE delivered_at IS NOT NULL
),
ranked AS (
    SELECT transition, step, days,
           ROW_NUMBER() OVER (PARTITION BY transition ORDER BY days) AS rn,
           COUNT(*)     OVER (PARTITION BY transition)               AS n
    FROM gaps
    WHERE days >= 0               -- drop a handful of bad timestamps
)
SELECT transition,
       n                                                         AS orders,
       ROUND(AVG(days), 2)                                       AS avg_days,
       ROUND(MAX(CASE WHEN rn = CAST(0.5 * n AS INT) THEN days END), 2) AS median_days,
       ROUND(MAX(CASE WHEN rn = CAST(0.9 * n AS INT) THEN days END), 2) AS p90_days
FROM ranked
GROUP BY transition, step, n
ORDER BY step;

-- name: funnel_lost_orders
-- Where do orders that never reach "delivered" end up?
SELECT order_status,
       COUNT(*)                                              AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)    AS pct_of_lost
FROM v_order_fact
WHERE purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
  AND order_status <> 'delivered'
GROUP BY order_status
ORDER BY orders DESC;

-- name: funnel_monthly
-- Monthly view of the funnel: volume and conversion to delivered/reviewed
SELECT purchase_month,
       COUNT(*)                                                       AS placed,
       ROUND(100.0 * AVG(order_status = 'delivered'), 2)              AS pct_delivered,
       ROUND(100.0 * AVG(order_status = 'delivered'
                         AND review_score IS NOT NULL), 2)            AS pct_reviewed,
       ROUND(100.0 * AVG(on_time), 2)                                 AS on_time_rate,
       ROUND(AVG(review_score), 3)                                    AS avg_review
FROM v_order_fact
WHERE purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
GROUP BY purchase_month
ORDER BY purchase_month;
