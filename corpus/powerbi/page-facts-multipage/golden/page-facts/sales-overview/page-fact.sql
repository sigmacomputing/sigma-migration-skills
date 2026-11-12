-- page fact for page 'Sales Overview' (scaffold-page-fact.py). Edit freely; keep each @slicers hook comment inside its WHERE clause.
-- grain: Store[Region], Calendar[Month]
-- SUM_AMOUNT = SUM(Sales.Amount) on Sales
-- SUM_COST = SUM(Sales.Cost) on Sales
-- SUM_QTY = SUM(Sales.Qty) on Sales
-- TODO West Sales: CALCULATE replaces the filter on Store[Region], a grouping column of this page: the page fact applies that filter to every component, so this measure needs its own handling (add KEEPFILTERS in the source if an intersection is meant, or model it by hand)
--     CALCULATE([Sales Amount], Store[Region] = "West")
WITH
pfs_sales AS (
  SELECT SALE_ID, DATE_KEY, STORE_KEY, PRODUCT_KEY, QTY, AMOUNT, COST FROM SALES
),
pfs_calendar AS (
  SELECT DATE_KEY, CAL_DATE, CAL_YEAR, CAL_MONTH FROM CAL
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
agg_sales AS (
  SELECT
    j2."REGION" AS "G_REGION",
    j1."CAL_MONTH" AS "G_MONTH",
    SUM(f."AMOUNT") AS "SUM_AMOUNT",
    SUM(f."COST") AS "SUM_COST",
    SUM(f."QTY") AS "SUM_QTY"
  FROM pfs_sales f
  LEFT JOIN pfs_calendar j1 ON j1."DATE_KEY" = f."DATE_KEY"
  LEFT JOIN pfs_store j2 ON j2."STORE_KEY" = f."STORE_KEY"
  WHERE 1 = 1
    /*@slicers fact="Sales" alias="f" sources="Calendar=pfs_calendar;Manager=pfs_manager;Product=pfs_product;Store=pfs_store;Supplier=pfs_supplier"*/
  GROUP BY j2."REGION", j1."CAL_MONTH"
)
SELECT
  "G_REGION",
  "G_MONTH",
  "SUM_AMOUNT",
  "SUM_COST",
  "SUM_QTY",
  CAST(NULL AS DOUBLE) AS "TODO_WEST_SALES"
FROM agg_sales
