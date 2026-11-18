# Limits of this migration

## Bidirectional and many-to-many relationships

None in this model.

## CALCULATE-override measures

- Sales.Private Label Sales: Power BI's CALCULATE filter on Private Label overrides slicers on that column; in Sigma a slicer on Private Label still applies. Power BI display folder: Product. In Power BI that filter overrides slicers on the column; in Sigma a slicer still applies.

## Report filters

- Category filter Category Name exclude ["Discontinued"] applies to fact visuals; slicer value lists and dimension-only visuals on Category still show the excluded members (a Lookup() into a filtered element returns NULL for the excluded keys instead of dropping the fact rows, so the filter stays on the facts).

## Optional customer step: Custom SQL as views

Where a customer wants a Custom SQL source to be a warehouse view instead, create it once and point the data model element at it. Replace `<TARGET_SCHEMA>` with the schema to create the views in.

```sql
CREATE OR REPLACE VIEW <TARGET_SCHEMA>.SHIPPING_SUMMARY AS
-- page fact for page 'Shipping' (scaffold-page-fact.py). Edit freely; keep each @slicers hook comment inside its WHERE clause.
-- grain: Date[Month Start], Store[Store Region], Store[Channel]
-- SUMX_QUANTITY_UNIT_PRICE_DISCOUNT = SUM(((Sales.Quantity * Sales.Unit Price) * (1 - Sales.Discount))) on Sales [USERELATIONSHIP]
-- SUMX_QUANTITY_UNIT_PRICE_DISCOUNT_2 = SUM(((Sales.Quantity * Sales.Unit Price) * (1 - Sales.Discount))) on Sales
-- SUM_QUANTITY = SUM(Sales.Quantity) on Sales
-- Date[Month Start] = DATE(YEAR([Date]), MONTH([Date]), 1) = DATE_TRUNC('MONTH', DIM_DATE.CAL_DATE), read from the join each measure's own relationship path uses
-- (ship path joins DIM_DATE on SHIP_DATE_KEY, order path on ORDER_DATE_KEY); the UNION ALL + outer GROUP BY keeps a month that has sales on one path only.
WITH
pfs_sales AS (
  SELECT * FROM <redacted>.FACT_SALES
),
pfs_category AS (
  SELECT * FROM <redacted>.DIM_CATEGORY
),
pfs_date AS (
  SELECT * FROM <redacted>.DIM_DATE
),
pfs_product AS (
  SELECT * FROM <redacted>.DIM_PRODUCT
),
pfs_sku AS (
  SELECT * FROM <redacted>.DIM_SKU
),
pfs_store AS (
  SELECT * FROM <redacted>.DIM_STORE
),
agg_sales_ur1 AS (
  SELECT
    DATE_TRUNC('MONTH', j1."CAL_DATE") AS "G_MONTH_START",
    j2."STORE_REGION" AS "G_STORE_REGION",
    j2."CHANNEL" AS "G_CHANNEL",
    SUM(((f."QUANTITY" * f."UNIT_PRICE") * (1 - f."DISCOUNT"))) AS "SUMX_QUANTITY_UNIT_PRICE_DISCOUNT"
  FROM pfs_sales f
  LEFT JOIN pfs_date j1 ON j1."DATE_KEY" = f."SHIP_DATE_KEY"
  LEFT JOIN pfs_store j2 ON j2."STORE_KEY" = f."STORE_KEY"
  WHERE 1 = 1
    AND NOT COALESCE(f."SKU_KEY" IN (SELECT sj1."SKU_KEY" FROM pfs_sku sj1 WHERE sj1."PRODUCT_KEY" IN (SELECT sj2."PRODUCT_KEY" FROM pfs_product sj2 WHERE sj2."CATEGORY_KEY" IN (SELECT sj3."CATEGORY_KEY" FROM pfs_category sj3 WHERE COALESCE(CAST(sj3."CATEGORY_NAME" AS VARCHAR), '(Blank)') IN ('Discontinued')))), FALSE)
    /*@slicers fact="Sales" alias="f" userelationship="'Sales'[ShipDateKey]|'Date'[DateKey]" sources="Category=pfs_category;Date=pfs_date;Product=pfs_product;SKU=pfs_sku;Store=pfs_store"*/
  GROUP BY DATE_TRUNC('MONTH', j1."CAL_DATE"), j2."STORE_REGION", j2."CHANNEL"
),
agg_sales AS (
  SELECT
    DATE_TRUNC('MONTH', j1."CAL_DATE") AS "G_MONTH_START",
    j2."STORE_REGION" AS "G_STORE_REGION",
    j2."CHANNEL" AS "G_CHANNEL",
    SUM(((f."QUANTITY" * f."UNIT_PRICE") * (1 - f."DISCOUNT"))) AS "SUMX_QUANTITY_UNIT_PRICE_DISCOUNT_2",
    SUM(f."QUANTITY") AS "SUM_QUANTITY"
  FROM pfs_sales f
  LEFT JOIN pfs_date j1 ON j1."DATE_KEY" = f."ORDER_DATE_KEY"
  LEFT JOIN pfs_store j2 ON j2."STORE_KEY" = f."STORE_KEY"
  WHERE 1 = 1
    AND NOT COALESCE(f."SKU_KEY" IN (SELECT sj1."SKU_KEY" FROM pfs_sku sj1 WHERE sj1."PRODUCT_KEY" IN (SELECT sj2."PRODUCT_KEY" FROM pfs_product sj2 WHERE sj2."CATEGORY_KEY" IN (SELECT sj3."CATEGORY_KEY" FROM pfs_category sj3 WHERE COALESCE(CAST(sj3."CATEGORY_NAME" AS VARCHAR), '(Blank)') IN ('Discontinued')))), FALSE)
    /*@slicers fact="Sales" alias="f" sources="Category=pfs_category;Date=pfs_date;Product=pfs_product;SKU=pfs_sku;Store=pfs_store"*/
  GROUP BY DATE_TRUNC('MONTH', j1."CAL_DATE"), j2."STORE_REGION", j2."CHANNEL"
)
SELECT
  "G_MONTH_START",
  "G_STORE_REGION",
  "G_CHANNEL",
  SUM("SUMX_QUANTITY_UNIT_PRICE_DISCOUNT") AS "SUMX_QUANTITY_UNIT_PRICE_DISCOUNT",
  SUM("SUMX_QUANTITY_UNIT_PRICE_DISCOUNT_2") AS "SUMX_QUANTITY_UNIT_PRICE_DISCOUNT_2",
  SUM("SUM_QUANTITY") AS "SUM_QUANTITY"
FROM (
  SELECT "G_MONTH_START", "G_STORE_REGION", "G_CHANNEL", "SUMX_QUANTITY_UNIT_PRICE_DISCOUNT", NULL AS "SUMX_QUANTITY_UNIT_PRICE_DISCOUNT_2", NULL AS "SUM_QUANTITY" FROM agg_sales_ur1
  UNION ALL
  SELECT "G_MONTH_START", "G_STORE_REGION", "G_CHANNEL", NULL AS "SUMX_QUANTITY_UNIT_PRICE_DISCOUNT", "SUMX_QUANTITY_UNIT_PRICE_DISCOUNT_2", "SUM_QUANTITY" FROM agg_sales
) u
GROUP BY "G_MONTH_START", "G_STORE_REGION", "G_CHANNEL";
```
