-- Seeded retail sample data for the Power BI-shaped model mode.
-- Template variables (snow CLI): <% db %> target database, <% role %> read role,
-- <% pbi_role %> Power BI reader role (same as role when PBI_READ_ROLE is unset).
-- Deterministic: every value derives from ROW_NUMBER() and HASH(seq, salt),
-- never from row order, so a rerun reproduces identical data.
-- All names are invented.

CREATE SCHEMA IF NOT EXISTS <% db %>.ZZ_CLAUDE_PBI_SHAPED;
USE SCHEMA <% db %>.ZZ_CLAUDE_PBI_SHAPED;

-- ---------------------------------------------------------------- DIM_DATE
-- Dense: 1277 days, 2023-01-01 .. 2026-06-30.
CREATE OR REPLACE TABLE DIM_DATE AS
SELECT
  TO_NUMBER(TO_CHAR(d, 'YYYYMMDD'))  AS DATE_KEY,
  d                                  AS CAL_DATE,
  YEAR(d)                            AS YEAR_NUM,
  QUARTER(d)                         AS QUARTER_NUM,
  MONTH(d)                           AS MONTH_NUM,
  MONTHNAME(d)                       AS MONTH_NAME
FROM (
  SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, DATE '2023-01-01') AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 1277))
);

-- AS_OF is 2026-06-15 on purpose: the data runs to 2026-06-30, so an as-of anchor differs from a max-date anchor.
CREATE OR REPLACE TABLE AS_OF AS SELECT DATE '2026-06-15' AS AS_OF_DATE;

-- ------------------------------------------------------------ DIM_CATEGORY
CREATE OR REPLACE TABLE DIM_CATEGORY AS
SELECT
  n AS CATEGORY_KEY,
  GET(ARRAY_CONSTRUCT('Beverages','Snacks','Dairy','Bakery','Produce','Frozen',
                      'Household','Personal Care','Pet Supplies','Stationery',
                      'Seasonal','Discontinued'), n - 1)::STRING AS CATEGORY_NAME
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 12)));

-- -------------------------------------------------------------- DIM_VENDOR
CREATE OR REPLACE TABLE DIM_VENDOR AS
SELECT
  n AS VENDOR_KEY,
  'Vendor ' || LPAD(n::STRING, 3, '0') || ' ' ||
    GET(ARRAY_CONSTRUCT('Supply','Foods','Trading','Goods','Wholesale'), MOD(n, 5))::STRING AS VENDOR_NAME,
  GET(ARRAY_CONSTRUCT('USA','Canada','Mexico','Germany','Japan','Brazil'), MOD(n, 6))::STRING AS COUNTRY
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 25)));

-- ------------------------------------------------------------- DIM_PRODUCT
-- CATEGORY_KEY is NULL for exactly 5% of products (every 20th key).
CREATE OR REPLACE TABLE DIM_PRODUCT AS
SELECT
  n AS PRODUCT_KEY,
  GET(ARRAY_CONSTRUCT('Aurora','Brightway','Cedarline','Dunmere','Everfield',
                      'Fernhill','Goldcrest','Harbor and Pine'), MOD(n, 8))::STRING || ' ' ||
    GET(ARRAY_CONSTRUCT('Classic','Select','Premium','Value','Organic','Reserve'),
        ABS(MOD(HASH(n, 11), 6)))::STRING || ' Item ' || LPAD(n::STRING, 4, '0') AS PRODUCT_NAME,
  GET(ARRAY_CONSTRUCT('Aurora','Brightway','Cedarline','Dunmere','Everfield',
                      'Fernhill','Goldcrest','Harbor and Pine'), MOD(n, 8))::STRING AS BRAND,
  IFF(MOD(n, 20) = 0, NULL, ABS(MOD(HASH(n, 12), 12)) + 1) AS CATEGORY_KEY,
  ABS(MOD(HASH(n, 13), 25)) + 1                            AS VENDOR_KEY,
  ROUND(2 + ABS(MOD(HASH(n, 14), 9800)) / 100.0, 2)        AS LIST_PRICE,
  (ABS(MOD(HASH(n, 15), 100)) < 25)                        AS IS_PRIVATE_LABEL
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 400)));

-- ----------------------------------------------------------------- DIM_SKU
-- 4 SKUs per product: Sales -> SKU -> Product -> Category is three hops.
CREATE OR REPLACE TABLE DIM_SKU AS
SELECT
  n AS SKU_KEY,
  MOD(n - 1, 400) + 1 AS PRODUCT_KEY,
  GET(ARRAY_CONSTRUCT('Small','Medium','Large','Family'), FLOOR((n - 1) / 400))::STRING AS SIZE
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 1600)));

-- ------------------------------------------------------------ DIM_CUSTOMER
-- LOYALTY_MEMBER is NULL for exactly 10% of customers (every 10th key).
CREATE OR REPLACE TABLE DIM_CUSTOMER AS
SELECT
  n AS CUSTOMER_KEY,
  GET(ARRAY_CONSTRUCT('Consumer','Small Business','Corporate','Student'), ABS(MOD(HASH(n, 21), 4)))::STRING AS SEGMENT,
  GET(ARRAY_CONSTRUCT('North','South','East','West','Central'), ABS(MOD(HASH(n, 22), 5)))::STRING AS CUSTOMER_REGION,
  IFF(MOD(n, 10) = 0, NULL, ABS(MOD(HASH(n, 23), 2)) = 0) AS LOYALTY_MEMBER
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 20000)));

-- --------------------------------------------------------------- DIM_STORE
CREATE OR REPLACE TABLE DIM_STORE AS
SELECT
  n AS STORE_KEY,
  'Store ' || LPAD(n::STRING, 2, '0') AS STORE_NAME,
  GET(ARRAY_CONSTRUCT('North','South','East','West'), MOD(n, 4))::STRING AS STORE_REGION,
  GET(ARRAY_CONSTRUCT('Retail','Retail','Outlet','Online'), MOD(n, 4))::STRING AS CHANNEL
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 40)));

-- -------------------------------------------------------------- FACT_SALES
-- Sparse on purpose: ~2.5% of calendar days have no sales anywhere, and each
-- store skips ~15% of the remaining days, so a rolling 28-day window over
-- present rows differs from one over calendar days.
CREATE OR REPLACE TEMPORARY TABLE ACTIVE_DAYS AS
SELECT ROW_NUMBER() OVER (ORDER BY DATE_KEY) AS DAY_RN, DATE_KEY, CAL_DATE
FROM DIM_DATE
WHERE ABS(MOD(HASH(DATE_KEY, 31), 1000)) >= 25;

CREATE OR REPLACE TABLE FACT_SALES AS
WITH nd AS (SELECT COUNT(*) AS c FROM ACTIVE_DAYS),
lines AS (
  SELECT n, FLOOR((n - 1) / 3) AS g
  FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 3500000)))
),
ord AS (
  SELECT l.n, l.g,
    ABS(MOD(HASH(l.g, 1), nd.c)) + 1 AS day_rn,
    ABS(MOD(HASH(l.g, 2), 40)) + 1   AS store_key,
    IFF(MOD(l.g, 100) < 3, NULL, ABS(MOD(HASH(l.g, 3), 20000)) + 1) AS customer_key,
    ABS(MOD(HASH(l.n, 4), 1600)) + 1 AS sku_key,
    ABS(MOD(HASH(l.n, 5), 6)) + 1    AS quantity,
    ABS(MOD(HASH(l.n, 6), 7)) * 5 / 100.0 AS discount,
    ABS(MOD(HASH(l.n, 7), 21)) AS price_jitter,
    ABS(MOD(HASH(l.n, 8), 25)) AS cost_pct,
    ABS(MOD(HASH(l.g, 9), 10)) AS ship_days
  FROM lines l CROSS JOIN nd
),
kept AS (
  SELECT o.*, a.DATE_KEY AS order_date_key, a.CAL_DATE AS order_date
  FROM ord o JOIN ACTIVE_DAYS a ON a.DAY_RN = o.day_rn
  WHERE ABS(MOD(HASH(a.DATE_KEY, o.store_key, 7), 100)) < 85
)
SELECT
  ROW_NUMBER() OVER (ORDER BY k.n)           AS SALES_LINE_KEY,
  'SO-' || LPAD(k.g::STRING, 8, '0')         AS ORDER_NUMBER,
  k.order_date_key                           AS ORDER_DATE_KEY,
  TO_NUMBER(TO_CHAR(LEAST(DATEADD(day, k.ship_days, k.order_date), DATE '2026-06-30'), 'YYYYMMDD')) AS SHIP_DATE_KEY,
  k.sku_key                                  AS SKU_KEY,
  k.customer_key                             AS CUSTOMER_KEY,
  k.store_key                                AS STORE_KEY,
  k.quantity                                 AS QUANTITY,
  ROUND(p.LIST_PRICE * (90 + k.price_jitter) / 100.0, 2)                      AS UNIT_PRICE,
  k.discount::NUMBER(5, 2)                   AS DISCOUNT,
  ROUND(p.LIST_PRICE * (90 + k.price_jitter) / 100.0 * (45 + k.cost_pct) / 100.0, 2) AS UNIT_COST
FROM kept k
JOIN DIM_SKU s     ON s.SKU_KEY = k.sku_key
JOIN DIM_PRODUCT p ON p.PRODUCT_KEY = s.PRODUCT_KEY;

DROP TABLE IF EXISTS ACTIVE_DAYS;

-- ---------------------------------------------------------- FACT_INVENTORY
-- Daily from 2025-07-01 over a fixed ~6.4% subset of (SKU, store) pairs.
CREATE OR REPLACE TABLE FACT_INVENTORY AS
WITH pairs AS (
  SELECT s.SKU_KEY, st.STORE_KEY
  FROM DIM_SKU s CROSS JOIN DIM_STORE st
  WHERE ABS(MOD(HASH(s.SKU_KEY, st.STORE_KEY, 41), 1000)) < 64
)
SELECT
  d.DATE_KEY,
  p.SKU_KEY,
  p.STORE_KEY,
  ABS(MOD(HASH(d.DATE_KEY, p.SKU_KEY, p.STORE_KEY, 42), 200)) AS ON_HAND_UNITS
FROM DIM_DATE d CROSS JOIN pairs p
WHERE d.CAL_DATE >= DATE '2025-07-01';

-- ------------------------------------------------------ FACT_PURCHASE_ORDER
CREATE OR REPLACE TABLE FACT_PURCHASE_ORDER AS
WITH base AS (
  SELECT n,
    ABS(MOD(HASH(n, 51), 1600)) + 1 AS sku_key,
    DATEADD(day, ABS(MOD(HASH(n, 52), 1277)), DATE '2023-01-01') AS order_date,
    7 + ABS(MOD(HASH(n, 53), 39)) AS lead_days,
    10 + ABS(MOD(HASH(n, 54), 491)) AS ordered_units,
    ABS(MOD(HASH(n, 55), 100)) < 15 AS is_open,
    ABS(MOD(HASH(n, 56), 71)) AS open_pct
  FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 60000)))
)
SELECT
  'PO-' || LPAD(b.n::STRING, 6, '0') AS PO_NUMBER,
  p.VENDOR_KEY                        AS VENDOR_KEY,
  b.sku_key                           AS SKU_KEY,
  TO_NUMBER(TO_CHAR(b.order_date, 'YYYYMMDD')) AS ORDER_DATE_KEY,
  TO_NUMBER(TO_CHAR(LEAST(DATEADD(day, b.lead_days, b.order_date), DATE '2026-06-30'), 'YYYYMMDD')) AS EXPECTED_DATE_KEY,
  b.ordered_units                     AS ORDERED_UNITS,
  IFF(b.is_open, FLOOR(b.ordered_units * b.open_pct / 100.0), b.ordered_units) AS RECEIVED_UNITS,
  IFF(b.is_open, 'Open', 'Closed')    AS STATUS
FROM base b
JOIN DIM_SKU s     ON s.SKU_KEY = b.sku_key
JOIN DIM_PRODUCT p ON p.PRODUCT_KEY = s.PRODUCT_KEY;

-- -------------------------------------------------------- DIM_PRODUCT_DUPKEY
-- DIM_PRODUCT plus one extra row repeating PRODUCT_KEY 17. Probes only.
CREATE OR REPLACE TABLE DIM_PRODUCT_DUPKEY AS
SELECT * FROM DIM_PRODUCT
UNION ALL
SELECT PRODUCT_KEY, PRODUCT_NAME || ' (dup)', BRAND, CATEGORY_KEY, VENDOR_KEY, LIST_PRICE, IS_PRIVATE_LABEL
FROM DIM_PRODUCT WHERE PRODUCT_KEY = 17;

-- ------------------------------------------------------------------- grants
GRANT USAGE ON SCHEMA <% db %>.ZZ_CLAUDE_PBI_SHAPED TO ROLE <% role %>;
GRANT SELECT ON ALL TABLES IN SCHEMA <% db %>.ZZ_CLAUDE_PBI_SHAPED TO ROLE <% role %>;
GRANT USAGE ON SCHEMA <% db %>.ZZ_CLAUDE_PBI_SHAPED TO ROLE <% pbi_role %>;
GRANT SELECT ON ALL TABLES IN SCHEMA <% db %>.ZZ_CLAUDE_PBI_SHAPED TO ROLE <% pbi_role %>;
