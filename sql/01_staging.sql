-- =============================================================================
-- 01_staging.sql: clean the raw Olist CSVs into one trusted data model.
-- Run by src/build_db.py, which replaces {RAW} with the path to data/raw.
-- =============================================================================

-- ---------------------------------------------------------------- raw sources
CREATE OR REPLACE VIEW raw_orders    AS SELECT * FROM read_csv_auto('{RAW}/olist_orders_dataset.csv');
CREATE OR REPLACE VIEW raw_customers AS SELECT * FROM read_csv_auto('{RAW}/olist_customers_dataset.csv');
CREATE OR REPLACE VIEW raw_items     AS SELECT * FROM read_csv_auto('{RAW}/olist_order_items_dataset.csv');
CREATE OR REPLACE VIEW raw_payments  AS SELECT * FROM read_csv_auto('{RAW}/olist_order_payments_dataset.csv');
CREATE OR REPLACE VIEW raw_reviews   AS SELECT * FROM read_csv_auto('{RAW}/olist_order_reviews_dataset.csv');
CREATE OR REPLACE VIEW raw_products  AS SELECT * FROM read_csv_auto('{RAW}/olist_products_dataset.csv');
CREATE OR REPLACE VIEW raw_sellers   AS SELECT * FROM read_csv_auto('{RAW}/olist_sellers_dataset.csv');
CREATE OR REPLACE VIEW raw_geo       AS SELECT * FROM read_csv_auto('{RAW}/olist_geolocation_dataset.csv');
CREATE OR REPLACE VIEW raw_cat_en    AS SELECT * FROM read_csv_auto('{RAW}/product_category_name_translation.csv');

-- ---------------------------------------------------------------- zip -> coordinates
-- The geolocation table has ~1M rows for ~19k zip prefixes (many points per prefix).
-- Use the median point per prefix, which is robust to the occasional mis-geocoded row.
CREATE OR REPLACE TABLE stg_zip AS
SELECT geolocation_zip_code_prefix AS zip,
       median(geolocation_lat)     AS lat,
       median(geolocation_lng)     AS lng
FROM raw_geo
GROUP BY 1;

-- ---------------------------------------------------------------- one review per order
-- Some orders have several reviews and some review_ids cover several orders.
-- Keep the most recent answered review per order.
CREATE OR REPLACE TABLE stg_reviews AS
SELECT order_id, review_score, review_creation_date, review_answer_timestamp,
       review_comment_message IS NOT NULL AS has_comment
FROM (
    SELECT *, ROW_NUMBER() OVER (
                  PARTITION BY order_id
                  ORDER BY review_answer_timestamp DESC, review_creation_date DESC) AS rn
    FROM raw_reviews
)
WHERE rn = 1;

-- ---------------------------------------------------------------- items per order
-- "Main" category and seller = those of the highest-priced item in the order.
CREATE OR REPLACE TABLE stg_order_items AS
SELECT i.order_id,
       count(*)                                                        AS n_items,
       count(DISTINCT i.seller_id)                                     AS n_sellers,
       sum(i.price)                                                    AS items_value,
       sum(i.freight_value)                                            AS freight_value,
       sum(p.product_weight_g) / 1000.0                                AS weight_kg,
       arg_max(coalesce(c.product_category_name_english,
                        p.product_category_name, 'unknown'), i.price)  AS category,
       arg_max(i.seller_id, i.price)                                   AS seller_id,
       max(i.shipping_limit_date)                                      AS shipping_limit_at
FROM raw_items i
LEFT JOIN raw_products p USING (product_id)
LEFT JOIN raw_cat_en   c USING (product_category_name)
GROUP BY 1;

-- ---------------------------------------------------------------- payments per order
CREATE OR REPLACE TABLE stg_payments AS
SELECT order_id,
       sum(payment_value)                       AS payment_value,
       max(payment_installments)                AS installments,
       arg_max(payment_type, payment_value)     AS payment_type
FROM raw_payments
GROUP BY 1;

-- ---------------------------------------------------------------- order fact table
-- One row per order with the customer's real identity (customer_unique_id).
-- NOTE: customer_id is generated per order; only customer_unique_id links repeat buyers.
CREATE OR REPLACE TABLE fct_orders AS
WITH base AS (
    SELECT o.order_id,
           c.customer_unique_id,
           c.customer_state,
           c.customer_zip_code_prefix                         AS customer_zip,
           o.order_status,
           o.order_purchase_timestamp                         AS purchased_at,
           o.order_approved_at                                AS approved_at,
           o.order_delivered_carrier_date                     AS carrier_at,
           o.order_delivered_customer_date                    AS delivered_at,
           o.order_estimated_delivery_date                    AS estimated_at,
           date_trunc('month', o.order_purchase_timestamp)    AS order_month
    FROM raw_orders o
    JOIN raw_customers c USING (customer_id)
)
SELECT b.*,
       i.n_items, i.n_sellers, i.items_value, i.freight_value, i.weight_kg, i.category, i.seller_id,
       s.seller_state,
       p.payment_value, p.installments, p.payment_type,
       r.review_score, r.has_comment,
       -- Delivery experience (days). delay_days > 0 means later than promised.
       date_diff('day', b.purchased_at, b.delivered_at)             AS delivery_days,
       date_diff('day', b.purchased_at, b.estimated_at)             AS promised_days,
       date_diff('day', b.estimated_at::DATE, b.delivered_at::DATE) AS delay_days,
       b.delivered_at::DATE > b.estimated_at::DATE                  AS is_late,
       -- Where the time goes: seller handling vs carrier transit.
       date_diff('hour', b.purchased_at, b.carrier_at) / 24.0       AS seller_days,
       date_diff('hour', b.carrier_at, b.delivered_at) / 24.0       AS carrier_days,
       b.carrier_at > i.shipping_limit_at                           AS seller_missed_handover,
       -- Straight-line customer-seller distance (haversine, km).
       2 * 6371 * asin(sqrt(
             pow(sin(radians(zs.lat - zc.lat) / 2), 2) +
             cos(radians(zc.lat)) * cos(radians(zs.lat)) *
             pow(sin(radians(zs.lng - zc.lng) / 2), 2)))            AS distance_km,
       -- Purchase sequence per real customer (cancelled/unavailable orders excluded).
       CASE WHEN b.order_status NOT IN ('canceled', 'unavailable')
            THEN ROW_NUMBER() OVER (
                     PARTITION BY b.customer_unique_id, b.order_status NOT IN ('canceled', 'unavailable')
                     ORDER BY b.purchased_at)
       END                                                          AS purchase_seq
FROM base b
LEFT JOIN stg_order_items i USING (order_id)
LEFT JOIN raw_sellers     s USING (seller_id)
LEFT JOIN stg_payments    p USING (order_id)
LEFT JOIN stg_reviews     r USING (order_id)
LEFT JOIN stg_zip        zc ON zc.zip = b.customer_zip
LEFT JOIN stg_zip        zs ON zs.zip = s.seller_zip_code_prefix;

-- ---------------------------------------------------------------- analysis window
-- Volumes are tiny before Jan 2017 and the feed stops mid-Sep 2018, so the
-- analysis uses purchases from 2017-01-01 to 2018-08-31.
CREATE OR REPLACE TABLE params AS
SELECT DATE '2017-01-01' AS window_start,
       DATE '2018-08-31' AS window_end;

-- ---------------------------------------------------------------- customer table
-- One row per real customer: first order, and their second order if any.
CREATE OR REPLACE TABLE dim_customers AS
WITH valid AS (
    SELECT f.*
    FROM fct_orders f, params p
    WHERE f.purchase_seq IS NOT NULL
      AND f.purchased_at::DATE BETWEEN p.window_start AND p.window_end
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchased_at) AS seq,
           count(*)     OVER (PARTITION BY customer_unique_id)                       AS n_orders
    FROM valid
),
-- A "return" is a purchase on a LATER day. ~30% of second orders are placed the same day
-- as the first (split baskets), which would otherwise inflate retention.
returns AS (
    SELECT a.customer_unique_id,
           min(date_diff('day', a.purchased_at::DATE, b.purchased_at::DATE)) AS days_to_return
    FROM ranked a
    JOIN ranked b ON b.customer_unique_id = a.customer_unique_id
                 AND b.purchased_at::DATE > a.purchased_at::DATE
    WHERE a.seq = 1
    GROUP BY 1
)
SELECT f.customer_unique_id,
       f.order_id                                  AS first_order_id,
       f.purchased_at                              AS first_purchased_at,
       date_trunc('month', f.purchased_at)         AS cohort_month,
       f.customer_state,
       s.purchased_at                              AS second_purchased_at,
       date_diff('day', f.purchased_at, s.purchased_at) AS days_to_second,
       f.n_orders,
       r.days_to_return,
       date_diff('day', f.purchased_at::DATE, p.window_end)  AS follow_up_days
FROM ranked f
CROSS JOIN params p
LEFT JOIN ranked  s ON s.customer_unique_id = f.customer_unique_id AND s.seq = 2
LEFT JOIN returns r ON r.customer_unique_id = f.customer_unique_id
WHERE f.seq = 1;
