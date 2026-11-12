-- page fact for page 'Stock Cover' (scaffold-page-fact.py). Edit freely; keep each @slicers hook comment inside its WHERE clause.
-- grain: Product[Category], Store[Store Name]
-- SUM_ON_HAND = SUM(Stock.On Hand) on Stock
-- SUM_QTY = SUM(Sales.Qty) on Sales
-- SUM_ON_HAND_2 = SUM(Stock.On Hand) WHERE Store.Manager Key IS NULL on Stock
WITH
pfs_sales AS (
  SELECT SALE_ID, DATE_KEY, STORE_KEY, PRODUCT_KEY, QTY, AMOUNT, COST FROM SALES
),
pfs_stock AS (
  SELECT SNAPSHOT_DATE_KEY, STORE_KEY, PRODUCT_KEY, ON_HAND FROM STOCK
),
pfs_manager AS (
  SELECT MANAGER_KEY, MANAGER_NAME FROM MGR
),
pfs_product AS (
  SELECT PRODUCT_KEY, PRODUCT_NAME, CATEGORY, SUPPLIER_KEY FROM PRODUCT
),
pfs_store AS (
  SELECT STORE_KEY, STORE_NAME, REGION, MANAGER_KEY FROM STORE
),
pfs_supplier AS (
  SELECT SUPPLIER_KEY, SUPPLIER_NAME FROM SUPPLIER
),
agg_stock AS (
  SELECT
    j1."CATEGORY" AS "G_CATEGORY",
    j2."STORE_NAME" AS "G_STORE_NAME",
    SUM(f."ON_HAND") AS "SUM_ON_HAND",
    SUM(CASE WHEN j2."MANAGER_KEY" IS NULL THEN f."ON_HAND" END) AS "SUM_ON_HAND_2"
  FROM pfs_stock f
  LEFT JOIN pfs_product j1 ON j1."PRODUCT_KEY" = f."PRODUCT_KEY"
  LEFT JOIN pfs_store j2 ON j2."STORE_KEY" = f."STORE_KEY"
  WHERE 1 = 1
    AND f."PRODUCT_KEY" IN (SELECT sj1."PRODUCT_KEY" FROM pfs_product sj1 WHERE sj1."SUPPLIER_KEY" IN (SELECT sj2."SUPPLIER_KEY" FROM pfs_supplier sj2 WHERE COALESCE(CAST(sj2."SUPPLIER_NAME" AS VARCHAR), '(Blank)') IN ('Acme', 'Globex')))
    /*@slicers fact="Stock" alias="f" sources="Manager=pfs_manager;Product=pfs_product;Sales=pfs_sales;Store=pfs_store;Supplier=pfs_supplier"*/
  GROUP BY j1."CATEGORY", j2."STORE_NAME"
),
agg_sales AS (
  SELECT
    j1."CATEGORY" AS "G_CATEGORY",
    j2."STORE_NAME" AS "G_STORE_NAME",
    SUM(f."QTY") AS "SUM_QTY"
  FROM pfs_sales f
  LEFT JOIN pfs_product j1 ON j1."PRODUCT_KEY" = f."PRODUCT_KEY"
  LEFT JOIN pfs_store j2 ON j2."STORE_KEY" = f."STORE_KEY"
  WHERE 1 = 1
    AND f."PRODUCT_KEY" IN (SELECT sj1."PRODUCT_KEY" FROM pfs_product sj1 WHERE sj1."SUPPLIER_KEY" IN (SELECT sj2."SUPPLIER_KEY" FROM pfs_supplier sj2 WHERE COALESCE(CAST(sj2."SUPPLIER_NAME" AS VARCHAR), '(Blank)') IN ('Acme', 'Globex')))
    /*@slicers fact="Sales" alias="f" sources="Manager=pfs_manager;Product=pfs_product;Stock=pfs_stock;Store=pfs_store;Supplier=pfs_supplier"*/
  GROUP BY j1."CATEGORY", j2."STORE_NAME"
)
SELECT
  "G_CATEGORY",
  "G_STORE_NAME",
  SUM("SUM_ON_HAND") AS "SUM_ON_HAND",
  SUM("SUM_QTY") AS "SUM_QTY",
  SUM("SUM_ON_HAND_2") AS "SUM_ON_HAND_2"
FROM (
  SELECT "G_CATEGORY", "G_STORE_NAME", "SUM_ON_HAND", NULL AS "SUM_QTY", "SUM_ON_HAND_2" FROM agg_stock
  UNION ALL
  SELECT "G_CATEGORY", "G_STORE_NAME", NULL AS "SUM_ON_HAND", "SUM_QTY", NULL AS "SUM_ON_HAND_2" FROM agg_sales
) u
GROUP BY "G_CATEGORY", "G_STORE_NAME"
