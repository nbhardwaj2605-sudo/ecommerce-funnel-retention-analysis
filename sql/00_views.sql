-- =====================================================================
-- 00_views.sql  —  analysis-ready views built on the raw Olist tables
-- Grain of v_order_fact: ONE ROW PER ORDER
-- =====================================================================

DROP VIEW IF EXISTS v_review_latest;
CREATE VIEW v_review_latest AS
-- Some orders have more than one review row; keep the most recent answer
WITH ranked AS (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp DESC,
                                       review_creation_date DESC) AS rn
    FROM reviews r
)
SELECT order_id,
       CAST(review_score AS INTEGER)       AS review_score,
       review_creation_date,
       review_answer_timestamp,
       review_comment_message
FROM ranked
WHERE rn = 1;

DROP VIEW IF EXISTS v_order_items_agg;
CREATE VIEW v_order_items_agg AS
WITH items AS (
    SELECT oi.order_id,
           CAST(oi.order_item_id AS INTEGER)  AS item_no,
           oi.seller_id,
           oi.product_id,
           CAST(oi.price AS REAL)             AS price,
           CAST(oi.freight_value AS REAL)     AS freight,
           COALESCE(ct.product_category_name_english,
                    p.product_category_name, 'unknown') AS category
    FROM order_items oi
    LEFT JOIN products p              ON p.product_id = oi.product_id
    LEFT JOIN category_translation ct ON ct.product_category_name = p.product_category_name
)
SELECT order_id,
       COUNT(*)                         AS n_items,
       COUNT(DISTINCT seller_id)        AS n_sellers,
       SUM(price)                       AS items_value,
       SUM(freight)                     AS freight_value,
       -- "primary" seller / category = the first item in the basket
       MAX(CASE WHEN item_no = 1 THEN seller_id END) AS seller_id,
       MAX(CASE WHEN item_no = 1 THEN category  END) AS category
FROM items
GROUP BY order_id;

DROP VIEW IF EXISTS v_payments_agg;
CREATE VIEW v_payments_agg AS
SELECT order_id,
       SUM(CAST(payment_value AS REAL))                AS payment_value,
       MAX(CAST(payment_installments AS INTEGER))      AS installments,
       -- payment type with the largest share of the order
       (SELECT p2.payment_type FROM payments p2
         WHERE p2.order_id = p.order_id
         ORDER BY CAST(p2.payment_value AS REAL) DESC LIMIT 1) AS payment_type
FROM payments p
GROUP BY order_id;

DROP VIEW IF EXISTS v_order_fact;
CREATE VIEW v_order_fact AS
SELECT o.order_id,
       o.customer_id,
       c.customer_unique_id,                       -- the REAL person id
       c.customer_state,
       c.customer_city,
       o.order_status,
       o.order_purchase_timestamp                  AS purchased_at,
       o.order_approved_at                         AS approved_at,
       o.order_delivered_carrier_date              AS shipped_at,
       o.order_delivered_customer_date             AS delivered_at,
       o.order_estimated_delivery_date             AS estimated_at,
       strftime('%Y-%m', o.order_purchase_timestamp) AS purchase_month,
       i.n_items, i.n_sellers, i.items_value, i.freight_value,
       i.seller_id, i.category,
       s.seller_state,
       pay.payment_value, pay.installments, pay.payment_type,
       r.review_score,
       r.review_creation_date                      AS review_sent_at,
       r.review_answer_timestamp                   AS reviewed_at,
       -- delivery metrics (days)
       julianday(o.order_delivered_customer_date)
         - julianday(o.order_purchase_timestamp)   AS delivery_days,
       julianday(date(o.order_delivered_customer_date))
         - julianday(date(o.order_estimated_delivery_date)) AS delay_days,
       julianday(date(o.order_estimated_delivery_date))
         - julianday(date(o.order_purchase_timestamp))      AS promised_days,
       CASE WHEN o.order_delivered_customer_date IS NULL THEN NULL
            WHEN date(o.order_delivered_customer_date)
                 <= date(o.order_estimated_delivery_date) THEN 1 ELSE 0
       END                                         AS on_time
FROM orders o
JOIN customers c           ON c.customer_id = o.customer_id
LEFT JOIN v_order_items_agg i ON i.order_id = o.order_id
LEFT JOIN sellers s        ON s.seller_id   = i.seller_id
LEFT JOIN v_payments_agg pay  ON pay.order_id = o.order_id
LEFT JOIN v_review_latest r   ON r.order_id   = o.order_id;
