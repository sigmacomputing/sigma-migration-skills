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
FROM running r
