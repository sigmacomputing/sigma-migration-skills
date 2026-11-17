# Limits of this migration

## Class D measures and visuals

- Visual 'Sales by ship month and order month' on page 'Shipping': needs two relationship paths to Date: the active relationship, Date (ShipDateKey); Sigma reads one path per element. Held back (no chart built) unless a page summary carries it (--scaffold-page-facts, then --page-facts).
- Visual 'Sales YTD and YTD (As Of) by month' on page 'Trends': Sales YTD (As Of) is an as-of measure, which Power BI holds flat across the Date table (its CALCULATE filter replaces the Date filter), and this visual binds Date.Month Start; Sigma would plot one value per group; held back (class D). Held back (no chart built) unless a page summary carries it (--scaffold-page-facts, then --page-facts).

## Bidirectional and many-to-many relationships

None in this model.

## CALCULATE-override measures

- Sales.Private Label Sales: Power BI's CALCULATE filter on Private Label overrides slicers on that column; in Sigma a slicer on Private Label still applies. Power BI display folder: Product. In Power BI that filter overrides slicers on the column; in Sigma a slicer still applies, so a visual that binds the filtered column on an axis, or sits under a slicer, page, report or visual filter on it, is class D (held back).

## Slicers not applied, and unreached slicers

- Unreached: Year (slicer Year (TrYear) column Date.Year); not applied to: Sales YTD (As Of): its measures are all as-of metrics: Power BI ignores a pick on the Date table for them

## Report filters

- Category filter Category Name exclude ["Discontinued"] applies to fact visuals; slicer value lists and dimension-only visuals on Category still show the excluded members (a Lookup() into a filtered element returns NULL for the excluded keys instead of dropping the fact rows, so the filter stays on the facts).

## As-of measures

- Sales.Sales YTD (As Of): as-of measure(s). Power BI holds an as-of measure flat across the Date table (its CALCULATE filter replaces the Date filter), so a visual that binds one with a Date-table field, mixes it under a date control, or sits under a report or visual Date filter is class D (held back).
- Visual 'Sales YTD (As Of)' on page 'Trends': every measure is as-of, so a page Date slicer or page filter pick is not applied to it, as in Power BI (listed as excluded in the control scope).

## Rolling windows and report filters

- Sales – rolling 28 days by day: report filter(s) applied inside the window SQL: Category.Category Name exclude ["Discontinued"].
- A list report filter on a non-date table is written into the rolling SQL; a Date-table report filter is replaced inside the window by Power BI and not applied. A filter that cannot be written exactly (a blank member, a backslash or control character in a value, a composite or non-physical key) sends the fact's rolling measures to class D. A page filter reaches a rolling element only on a field the element carries, else its readers are class D. An empty window reads blank, as in DAX.

## Date fields

- Only provable calendar fields bind to a time-intelligence element: the Date or Day column, a calculated column that is DATE(YEAR(...), MONTH(...), 1) or STARTOF*(...) of it, and integer Year, Quarter and Month Number columns (carried as Year Number, Quarter Number and Month Number on the grouped elements). A fiscal, week, name, key or physical Month Start field gets no binding: a visual that binds one beside a time-intelligence measure is class D, and so is an integer Quarter or Month Number with no Year beside it.

## USERELATIONSHIP measures

- Sales.Sales by Ship Date: the role-playing Date path is activated per visual. Slicers, page filters and report filters on the Date table follow that path; a control that also reaches an active-path visual on the page, or any report-level Date filter, holds the USERELATIONSHIP visuals back (class D).

## Blank-as-zero arithmetic

- Sales.Gross Margin: a top-level + or - between metrics is rewritten to read a blank side as 0, as DAX does. Only a top-level binary + or - is rewritten; a + or - inside a function argument, or between aggregates inside another call, is not.

## DISTINCTCOUNT counts BLANK

- Sales.Orders: DAX DISTINCTCOUNT counts BLANK as a value, while the Sigma CountDistinct ignores NULL. The two differ by one when the column holds NULL (nullability is not probed).

## Mixed-summary dropped fields

- Quarter: sales, QTD, YoY reads 'Sales by quarter (quarter reset)' only; dropped: Sales.Sales YoY %. one element reads one data model element; the dropped field lives on another summary or table
- Store Region: R28 and sales reads 'Sales' only; dropped: Sales.Sales R28. one element reads one data model element; the dropped field lives on another summary or table

## Optional customer step: Custom SQL as views

Where a customer wants a Custom SQL source to be a warehouse view instead, create it once and point the data model element at it. Replace `<TARGET_SCHEMA>` with the schema to create the views in.

```sql
CREATE OR REPLACE VIEW <TARGET_SCHEMA>.SALES_ROLLING_28_DAYS_BY_DAY AS
WITH pbi_fact AS (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."FACT_SALES"
), pbi_dates AS (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_DATE"
), pbi_combos AS (
  SELECT DISTINCT cd0."SEGMENT" AS "Segment", cd1."STORE_REGION" AS "Store Region", cd0."CUSTOMER_REGION" AS "Customer Region"
  FROM pbi_fact f LEFT JOIN (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_CUSTOMER"
) cd0 ON cd0."CUSTOMER_KEY" = f."CUSTOMER_KEY" LEFT JOIN (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_STORE"
) cd1 ON cd1."STORE_KEY" = f."STORE_KEY"
), pbi_daily AS (
  SELECT dd."CAL_DATE" AS "DAY", cd0."SEGMENT" AS "Segment", cd1."STORE_REGION" AS "Store Region", cd0."CUSTOMER_REGION" AS "Customer Region", SUM(COALESCE(f."QUANTITY", 0) * COALESCE(f."UNIT_PRICE", 0) * (1 - COALESCE(f."DISCOUNT", 0))) AS "SALES_R28"
  FROM pbi_fact f JOIN pbi_dates dd ON dd."DATE_KEY" = f."ORDER_DATE_KEY" LEFT JOIN (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_CUSTOMER"
) cd0 ON cd0."CUSTOMER_KEY" = f."CUSTOMER_KEY" LEFT JOIN (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_STORE"
) cd1 ON cd1."STORE_KEY" = f."STORE_KEY"
  WHERE 1 = 1
    AND NOT COALESCE(f."SKU_KEY" IN (SELECT k1."SKU_KEY" FROM (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_SKU"
) k1 WHERE k1."PRODUCT_KEY" IN (SELECT k2."PRODUCT_KEY" FROM (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_PRODUCT"
) k2 WHERE k2."CATEGORY_KEY" IN (SELECT k3."CATEGORY_KEY" FROM (
SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_CATEGORY"
) k3 WHERE LOWER(k3."CATEGORY_NAME") IN ('discontinued')))), FALSE) /*@slicers fact="Sales" alias="f"*/
  GROUP BY dd."CAL_DATE", cd0."SEGMENT", cd1."STORE_REGION", cd0."CUSTOMER_REGION"
)
SELECT spine."CAL_DATE" AS "DAY", spine."Segment" AS "Segment", spine."Store Region" AS "Store Region", spine."Customer Region" AS "Customer Region", CASE WHEN COUNT(daily."SALES_R28") OVER (PARTITION BY spine."Segment", spine."Store Region", spine."Customer Region" ORDER BY spine."CAL_DATE" ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) = 0 THEN NULL ELSE SUM(COALESCE(daily."SALES_R28", 0)) OVER (PARTITION BY spine."Segment", spine."Store Region", spine."Customer Region" ORDER BY spine."CAL_DATE" ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) END AS "SALES_R28"
FROM (SELECT d."CAL_DATE", c."Segment", c."Store Region", c."Customer Region" FROM pbi_dates d CROSS JOIN pbi_combos c) spine
LEFT JOIN pbi_daily daily ON daily."DAY" = spine."CAL_DATE" AND (daily."Segment" = spine."Segment" OR (daily."Segment" IS NULL AND spine."Segment" IS NULL)) AND (daily."Store Region" = spine."Store Region" OR (daily."Store Region" IS NULL AND spine."Store Region" IS NULL)) AND (daily."Customer Region" = spine."Customer Region" OR (daily."Customer Region" IS NULL AND spine."Customer Region" IS NULL));
```
