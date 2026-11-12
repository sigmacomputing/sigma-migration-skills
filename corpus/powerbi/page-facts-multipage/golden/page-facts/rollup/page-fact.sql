-- page fact for page 'Rollup' (scaffold-page-fact.py). Edit freely; keep each @slicers hook comment inside its WHERE clause.
-- grain: Product[Category]
-- SUM_AMOUNT = SUM(Sales.Amount) on Sales [USERELATIONSHIP]
-- SUM_QTY = SUM(Sales.Qty) on Sales [USERELATIONSHIP]
-- TODO Orders: DAX function DISTINCTCOUNT is not decomposed into additive components
--     DISTINCTCOUNT(Sales[Sale Id])
WITH
pfs_sales AS (
  SELECT SALE_ID, DATE_KEY, STORE_KEY, PRODUCT_KEY, QTY, AMOUNT, COST FROM SALES
),
pfs_product AS (
  SELECT PRODUCT_KEY, PRODUCT_NAME, CATEGORY, SUPPLIER_KEY FROM PRODUCT
),
pfs_rollup AS (
  SELECT CHILD_PRODUCT_KEY, PARENT_PRODUCT_KEY FROM ROLLUP_MAP
),
pfs_supplier AS (
  SELECT SUPPLIER_KEY, SUPPLIER_NAME FROM SUPPLIER
),
agg_sales_ur1 AS (
  SELECT
    j2."CATEGORY" AS "G_CATEGORY",
    SUM(f."AMOUNT") AS "SUM_AMOUNT",
    SUM(f."QTY") AS "SUM_QTY"
  FROM pfs_sales f
  LEFT JOIN pfs_rollup j1 ON j1."CHILD_PRODUCT_KEY" = f."PRODUCT_KEY"
  LEFT JOIN pfs_product j2 ON j2."PRODUCT_KEY" = j1."PARENT_PRODUCT_KEY"
  WHERE 1 = 1
    /*@slicers fact="Sales" alias="f" userelationship="'Rollup'[Child Product Key]|'Sales'[Product Key]" sources="Product=pfs_product;Rollup=pfs_rollup;Supplier=pfs_supplier"*/
  GROUP BY j2."CATEGORY"
)
SELECT
  "G_CATEGORY",
  "SUM_AMOUNT",
  "SUM_QTY",
  CAST(NULL AS DOUBLE) AS "TODO_ORDERS"
FROM agg_sales_ur1
