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
WHERE c."ON_HAND_UNITS" IS NOT NULL OR c."OPEN_PO_UNITS" IS NOT NULL OR c."SALES_R28_UNITS" IS NOT NULL
