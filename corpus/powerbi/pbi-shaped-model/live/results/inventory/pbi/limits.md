# Limits of this migration

## Class D measures

- Inventory.On Hand (Latest) (uses ALL, which removes filters (snapshot or share-of-total logic)): lands in summary 'Cover – summary'
- Inventory.Days of Cover (depends on class D measure [On Hand (Latest)]: uses ALL, which removes filters (snapshot or share-of-total logic)): lands in summary 'Cover – summary'
- Inventory.Products by Cover Bucket (uses FILTER, which iterates over entities (per-entity bucketing)): lands in summary 'Cover – summary'

## Bidirectional and many-to-many relationships

None in this model.

## CALCULATE-override measures

- Purchase Orders.Open PO Units: Power BI's CALCULATE filter on Status overrides slicers on that column; in Sigma a slicer on Status still applies. Power BI display folder: Inventory. In Power BI that filter overrides slicers on the column; in Sigma a slicer still applies.

## Slicers not applied, and unreached slicers

- Not applied: Cover – summary on page 'Cover' (Store.Store Region): no control on the page (not built or held back)

## Optional customer step: Custom SQL as views

Where a customer wants a Custom SQL source to be a warehouse view instead, create it once and point the data model element at it. Replace `<TARGET_SCHEMA>` with the schema to create the views in.

```sql
CREATE OR REPLACE VIEW <TARGET_SCHEMA>.SALES_ROLLING_28_DAYS_BY_DAY AS
WITH pbi_fact AS (
SELECT * FROM <redacted>."FACT_SALES"
), pbi_dates AS (
SELECT * FROM <redacted>."DIM_DATE"
), pbi_combos AS (
  SELECT DISTINCT cd0."STORE_REGION" AS "Store Region"
  FROM pbi_fact f LEFT JOIN (
SELECT * FROM <redacted>."DIM_STORE"
) cd0 ON cd0."STORE_KEY" = f."STORE_KEY"
), pbi_daily AS (
  SELECT dd."CAL_DATE" AS "DAY", cd0."STORE_REGION" AS "Store Region", SUM(f."QUANTITY") AS "SALES_R28_UNITS"
  FROM pbi_fact f JOIN pbi_dates dd ON dd."DATE_KEY" = f."ORDER_DATE_KEY" LEFT JOIN (
SELECT * FROM <redacted>."DIM_STORE"
) cd0 ON cd0."STORE_KEY" = f."STORE_KEY"
  WHERE 1 = 1 /*@slicers fact="Sales" alias="f"*/
  GROUP BY dd."CAL_DATE", cd0."STORE_REGION"
)
SELECT spine."CAL_DATE" AS "DAY", spine."Store Region" AS "Store Region", SUM(COALESCE(daily."SALES_R28_UNITS", 0)) OVER (PARTITION BY spine."Store Region" ORDER BY spine."CAL_DATE" ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS "SALES_R28_UNITS"
FROM (SELECT d."CAL_DATE", c."Store Region" FROM pbi_dates d CROSS JOIN pbi_combos c) spine
LEFT JOIN pbi_daily daily ON daily."DAY" = spine."CAL_DATE" AND (daily."Store Region" = spine."Store Region" OR (daily."Store Region" IS NULL AND spine."Store Region" IS NULL));
```

```sql
CREATE OR REPLACE VIEW <TARGET_SCHEMA>.COVER_SUMMARY AS
-- page fact for page 'Cover' (scaffold-page-fact.py, completed by hand against the Power BI DAX oracle).
-- grain: Vendor[Vendor Name], Product[Product Name], Cover Bucket[Bucket], Vendor[Vendor Country], Product[Brand]
--   (one row per product: a product sits in exactly one bucket and has one brand and one vendor country, so the Vendor Country and Brand
--   slicers filter the summary's own columns; the Store Region slicer cannot (it changes On Hand and R28 per product, not PO) and is not carried)
-- On Hand (Latest): units on the latest snapshot date in scope (DAX d = MAX(Inventory[DateKey]) under ALL(Inventory): dimension filters still apply).
--   The latest date is taken over the slicer-filtered inventory rows (a window over the whole result, not per product); every product shares
--   the latest snapshot in this data (1 distinct per-product maximum), so per-product and global agree.
-- Open PO Units: SUMX over Purchase Orders of Ordered - Received where Status = "Open"; DAX treats BLANK as 0 in the subtraction, so both sides are COALESCEd.
-- Sales R28 Units: sales units for the 28 days ending on MAX of the whole Date table (no Date filter on this page).
-- Days of Cover = DIVIDE(On Hand, DIVIDE(R28, 28)); Products by Cover Bucket: the product's Days of Cover falls in [Min Days, Max Days) of the Cover Bucket table.
WITH
pfs_cover_bucket AS (
  SELECT 'Under 7 days' AS "Bucket", 0 AS "Min Days", 7 AS "Max Days", 1 AS "Sort" UNION ALL SELECT '7 to 14 days', 7, 14, 2 UNION ALL SELECT '14 to 28 days', 14, 28, 3 UNION ALL SELECT '28 days or more', 28, 100000, 4
),
pfs_date AS (
  SELECT * FROM <redacted>.DIM_DATE
),
pfs_inventory AS (
  SELECT * FROM <redacted>.FACT_INVENTORY
),
pfs_product AS (
  SELECT * FROM <redacted>.DIM_PRODUCT
),
pfs_purchase_orders AS (
  SELECT * FROM <redacted>.FACT_PURCHASE_ORDER
),
pfs_sales AS (
  SELECT * FROM <redacted>.FACT_SALES
),
pfs_sku AS (
  SELECT * FROM <redacted>.DIM_SKU
),
pfs_store AS (
  SELECT * FROM <redacted>.DIM_STORE
),
pfs_vendor AS (
  SELECT * FROM <redacted>.DIM_VENDOR
),
inv_rows AS (
  SELECT f."DATE_KEY" AS "DATE_KEY", f."SKU_KEY" AS "SKU_KEY", f."ON_HAND_UNITS" AS "ON_HAND_UNITS"
  FROM pfs_inventory f
  WHERE 1 = 1
    /*@slicers fact="Inventory" alias="f" sources="Cover Bucket=pfs_cover_bucket;Product=pfs_product;SKU=pfs_sku;Store=pfs_store;Vendor=pfs_vendor"*/
),
agg_inventory AS (
  SELECT j1."PRODUCT_KEY" AS "PK",
    SUM(CASE WHEN r."DATE_KEY" = m."MAXD" THEN r."ON_HAND_UNITS" END) AS "ON_HAND_UNITS"
  FROM inv_rows r
  CROSS JOIN (SELECT MAX("DATE_KEY") AS "MAXD" FROM inv_rows) m
  LEFT JOIN pfs_sku j1 ON j1."SKU_KEY" = r."SKU_KEY"
  GROUP BY j1."PRODUCT_KEY"
),
agg_purchase_orders AS (
  SELECT j1."PRODUCT_KEY" AS "PK",
    SUM(CASE WHEN UPPER(COALESCE(CAST(f."STATUS" AS VARCHAR), '')) = UPPER('Open') THEN (COALESCE(f."ORDERED_UNITS", 0) - COALESCE(f."RECEIVED_UNITS", 0)) END) AS "OPEN_PO_UNITS"
  FROM pfs_purchase_orders f
  LEFT JOIN pfs_sku j1 ON j1."SKU_KEY" = f."SKU_KEY"
  WHERE 1 = 1
    /*@slicers fact="Purchase Orders" alias="f" sources="Cover Bucket=pfs_cover_bucket;Product=pfs_product;SKU=pfs_sku;Store=pfs_store;Vendor=pfs_vendor"*/
  GROUP BY j1."PRODUCT_KEY"
),
agg_sales AS (
  SELECT j1."PRODUCT_KEY" AS "PK",
    SUM(f."QUANTITY") AS "SALES_R28_UNITS"
  FROM pfs_sales f
  JOIN pfs_date dd ON dd."DATE_KEY" = f."ORDER_DATE_KEY"
  LEFT JOIN pfs_sku j1 ON j1."SKU_KEY" = f."SKU_KEY"
  WHERE dd."CAL_DATE" BETWEEN DATEADD(DAY, -27, (SELECT MAX("CAL_DATE") FROM pfs_date)) AND (SELECT MAX("CAL_DATE") FROM pfs_date)
    /*@slicers fact="Sales" alias="f" sources="Cover Bucket=pfs_cover_bucket;Date=pfs_date;Product=pfs_product;SKU=pfs_sku;Store=pfs_store;Vendor=pfs_vendor"*/
  GROUP BY j1."PRODUCT_KEY"
),
per_product AS (
  SELECT "PK", SUM("ON_HAND_UNITS") AS "ON_HAND_UNITS", SUM("OPEN_PO_UNITS") AS "OPEN_PO_UNITS", SUM("SALES_R28_UNITS") AS "SALES_R28_UNITS"
  FROM (
    SELECT "PK", "ON_HAND_UNITS", NULL AS "OPEN_PO_UNITS", NULL AS "SALES_R28_UNITS" FROM agg_inventory
    UNION ALL
    SELECT "PK", NULL, "OPEN_PO_UNITS", NULL FROM agg_purchase_orders
    UNION ALL
    SELECT "PK", NULL, NULL, "SALES_R28_UNITS" FROM agg_sales
  ) u
  GROUP BY "PK"
),
cover AS (
  SELECT pp.*,
    CASE WHEN pp."ON_HAND_UNITS" IS NULL OR COALESCE(pp."SALES_R28_UNITS", 0) = 0 THEN NULL
         ELSE pp."ON_HAND_UNITS" / (pp."SALES_R28_UNITS" / 28) END AS "DAYS_OF_COVER"
  FROM per_product pp
)
SELECT
  v."VENDOR_NAME" AS "G_VENDOR_NAME",
  p."PRODUCT_NAME" AS "G_PRODUCT_NAME",
  cb."Bucket" AS "G_BUCKET",
  v."COUNTRY" AS "G_VENDOR_COUNTRY",
  p."BRAND" AS "G_BRAND",
  c."ON_HAND_UNITS" AS "ON_HAND_UNITS",
  c."OPEN_PO_UNITS" AS "OPEN_PO_UNITS",
  c."SALES_R28_UNITS" AS "SALES_R28_UNITS",
  CASE WHEN cb."Bucket" IS NULL THEN NULL ELSE 1 END AS "PRODUCTS_IN_BUCKET"
FROM cover c
LEFT JOIN pfs_product p ON p."PRODUCT_KEY" = c."PK"
LEFT JOIN pfs_vendor v ON v."VENDOR_KEY" = p."VENDOR_KEY"
LEFT JOIN pfs_cover_bucket cb ON c."DAYS_OF_COVER" >= cb."Min Days" AND c."DAYS_OF_COVER" < cb."Max Days"
WHERE c."ON_HAND_UNITS" IS NOT NULL OR c."OPEN_PO_UNITS" IS NOT NULL OR c."SALES_R28_UNITS" IS NOT NULL;
```

```sql
CREATE OR REPLACE VIEW <TARGET_SCHEMA>.COVER_BUCKET AS
SELECT 'Under 7 days' AS "Bucket", 0 AS "Min Days", 7 AS "Max Days", 1 AS "Sort" UNION ALL SELECT '7 to 14 days', 7, 14, 2 UNION ALL SELECT '14 to 28 days', 14, 28, 3 UNION ALL SELECT '28 days or more', 28, 100000, 4;
```
