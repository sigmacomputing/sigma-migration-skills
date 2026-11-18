# Limits of this migration

## Class D measures

- Sales.Sales YTD (slicer fields exceed carry size; needs a live summary): lands in summary 'Trends – summary'
- Sales.Sales QTD (slicer fields exceed carry size; needs a live summary): lands in summary 'Trends – summary'
- Sales.Sales MTD (slicer fields exceed carry size; needs a live summary): lands in summary 'Trends – summary'
- Sales.Sales PY (slicer fields exceed carry size; needs a live summary): lands in summary 'Trends – summary'
- Sales.Sales YoY % (slicer fields exceed carry size; needs a live summary): lands in summary 'Trends – summary'

## Bidirectional and many-to-many relationships

None in this model.

## Live pages

- Element 'Sales – rolling 28 days by day – live, filtered by your slicer picks' on page 'Rolling', controls: Customer.Customer Region, Customer.Segment. Trade-off: computed in the warehouse on every slicer change instead of read from a summary.

## Mixed-summary dropped fields

- Store Region: R28 and sales reads 'Sales' only; dropped: Sales.Sales R28. one element reads one data model element; the dropped field lives on another summary or table
- Sales R28 by Customer Region reads 'Customer' only; dropped: Sales.Sales R28. one element reads one data model element; the dropped field lives on another summary or table

## Optional customer step: Custom SQL as views

Where a customer wants a Custom SQL source to be a warehouse view instead, create it once and point the data model element at it. Replace `<TARGET_SCHEMA>` with the schema to create the views in.

```sql
CREATE OR REPLACE VIEW <TARGET_SCHEMA>.SALES_ROLLING_28_DAYS_BY_DAY AS
WITH pbi_fact AS (
SELECT * FROM <redacted>."FACT_SALES"
), pbi_dates AS (
SELECT * FROM <redacted>."DIM_DATE"
), pbi_combos AS (
  SELECT DISTINCT cd1."STORE_REGION" AS "Store Region"
  FROM pbi_fact f LEFT JOIN (
SELECT * FROM <redacted>."DIM_STORE"
) cd1 ON cd1."STORE_KEY" = f."STORE_KEY"
), pbi_daily AS (
  SELECT dd."CAL_DATE" AS "DAY", cd1."STORE_REGION" AS "Store Region", SUM(COALESCE(f."QUANTITY", 0) * COALESCE(f."UNIT_PRICE", 0) * (1 - COALESCE(f."DISCOUNT", 0))) AS "SALES_R28"
  FROM pbi_fact f JOIN pbi_dates dd ON dd."DATE_KEY" = f."ORDER_DATE_KEY" LEFT JOIN (
SELECT * FROM <redacted>."DIM_STORE"
) cd1 ON cd1."STORE_KEY" = f."STORE_KEY"
  WHERE 1 = 1 /*@slicers fact="Sales" alias="f"*/
  GROUP BY dd."CAL_DATE", cd1."STORE_REGION"
)
SELECT spine."CAL_DATE" AS "DAY", spine."Store Region" AS "Store Region", SUM(COALESCE(daily."SALES_R28", 0)) OVER (PARTITION BY spine."Store Region" ORDER BY spine."CAL_DATE" ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS "SALES_R28"
FROM (SELECT d."CAL_DATE", c."Store Region" FROM pbi_dates d CROSS JOIN pbi_combos c) spine
LEFT JOIN pbi_daily daily ON daily."DAY" = spine."CAL_DATE" AND (daily."Store Region" = spine."Store Region" OR (daily."Store Region" IS NULL AND spine."Store Region" IS NULL));
```

```sql
CREATE OR REPLACE VIEW <TARGET_SCHEMA>.TRENDS_SUMMARY AS
-- page fact for page 'Trends': time-intelligence summary at Month Start grain, one row per month (completed from the scaffold).
-- Sales Amount (SUMX over the fact) is additive; the other measures are columns whose chart formulas (page-fact.json "fields") pick
-- the column that matches the visual's grain, as Power BI evaluates the measure in that filter context:
--   Sales PY            = sales of the same month one year earlier (SAMEPERIODLASTYEAR shifts the whole period; probed live: Feb 2025 = all of Feb 2024),
--                         from the UNFILTERED fact (a Year pick does not remove last year's sales, probed live), NULL when the Date table has no earlier year
--   Sales YTD/QTD/MTD   = running within the year / quarter, read at the group's last month: per month the running value, per year or quarter the
--                         value on its last month, otherwise (no date axis) the value on the latest month (the context's MAX date)
--   Sales YTD (As Of)   = sales from Jan 1 of the As Of year through the As Of date, constant on every row (CALCULATE replaces the Date filter)
WITH
pfs_sales AS (
  SELECT * FROM <redacted>.FACT_SALES
),
pfs_date AS (
  SELECT * FROM <redacted>.DIM_DATE
),
pfs_asof AS (
  SELECT * FROM <redacted>.AS_OF
),
agg_sales AS (
  SELECT
    DATE_TRUNC('MONTH', j1."CAL_DATE") AS "G_MONTH_START",
    MIN(j1."YEAR_NUM") AS "G_YEAR",
    MIN(j1."QUARTER_NUM") AS "G_QUARTER",
    SUM(((f."QUANTITY" * f."UNIT_PRICE") * (1 - f."DISCOUNT"))) AS "SALES"
  FROM pfs_sales f
  LEFT JOIN pfs_date j1 ON j1."DATE_KEY" = f."ORDER_DATE_KEY"
  WHERE 1 = 1
    /*@slicers fact="Sales" alias="f" sources="Date=pfs_date"*/
  GROUP BY DATE_TRUNC('MONTH', j1."CAL_DATE")
),
all_months AS (
  SELECT
    DATE_TRUNC('MONTH', d."CAL_DATE") AS "M",
    SUM(((f."QUANTITY" * f."UNIT_PRICE") * (1 - f."DISCOUNT"))) AS "S"
  FROM pfs_sales f
  JOIN pfs_date d ON d."DATE_KEY" = f."ORDER_DATE_KEY"
  GROUP BY DATE_TRUNC('MONTH', d."CAL_DATE")
),
as_of AS (
  SELECT SUM(((f."QUANTITY" * f."UNIT_PRICE") * (1 - f."DISCOUNT"))) AS "S"
  FROM pfs_sales f
  JOIN pfs_date d ON d."DATE_KEY" = f."ORDER_DATE_KEY"
  WHERE d."CAL_DATE" BETWEEN DATE_TRUNC('YEAR', (SELECT MAX("AS_OF_DATE") FROM pfs_asof)) AND (SELECT MAX("AS_OF_DATE") FROM pfs_asof)
),
running AS (
  SELECT
    a."G_MONTH_START", a."G_YEAR", a."G_QUARTER", a."SALES",
    SUM(a."SALES") OVER (PARTITION BY a."G_YEAR" ORDER BY a."G_MONTH_START") AS "YTD_M",
    SUM(a."SALES") OVER (PARTITION BY a."G_YEAR", a."G_QUARTER" ORDER BY a."G_MONTH_START") AS "QTD_M",
    p."S" AS "SALES_PY",
    MAX(a."G_MONTH_START") OVER () AS "LAST_M",
    MAX(a."G_MONTH_START") OVER (PARTITION BY a."G_YEAR") AS "YEAR_LAST_M",
    MAX(a."G_MONTH_START") OVER (PARTITION BY a."G_YEAR", a."G_QUARTER") AS "QTR_LAST_M"
  FROM agg_sales a
  LEFT JOIN all_months p ON p."M" = DATEADD(YEAR, -1, a."G_MONTH_START")
)
SELECT
  r."G_MONTH_START",
  r."G_YEAR",
  r."G_QUARTER",
  r."G_YEAR" * 10 + r."G_QUARTER" AS "YEAR_QUARTER",
  r."SALES" AS "SALES",
  r."SALES_PY" AS "SALES_PY",
  r."YTD_M" AS "YTD_M",
  IFF(r."G_MONTH_START" = r."YEAR_LAST_M", r."YTD_M", NULL) AS "YTD_YEAR_END",
  IFF(r."G_MONTH_START" = r."LAST_M", r."YTD_M", NULL) AS "YTD_LATEST",
  r."QTD_M" AS "QTD_M",
  IFF(r."G_MONTH_START" = r."QTR_LAST_M", r."QTD_M", NULL) AS "QTD_QUARTER_END",
  IFF(r."G_MONTH_START" = r."LAST_M", r."QTD_M", NULL) AS "QTD_LATEST",
  IFF(r."G_MONTH_START" = r."LAST_M", r."SALES", NULL) AS "MTD_LATEST",
  (SELECT "S" FROM as_of) AS "AS_OF_YTD"
FROM running r;
```
