# Views shape vs pbi shape: three live reports

Each report was migrated twice into the test org: once in the default (Views) shape and once with `--model-shape pbi`. Per-report numbers, parity files and
limits are in `results/<report>/{views,pbi}/`; the generated side-by-side is `results/<report>/comparison.{md,json}`; commands are in `RUNBOOK.md`.
All parity below is against Power BI DAX (`executeQueries`) results fed through the local finalize path (the `source: warehouse-sql-oracle` label in
`parity-final.json` is that script's default; see each `oracle.md`). Sigma values are element CSV exports. Sales Trends and Inventory (pbi) are the regression reruns.

| | Retail Sales | Sales Trends | Inventory and Purchasing |
|---|---|---|---|
| | pbi / views | pbi / views | pbi / views |
| Data model elements (30-40 guidance) | 9 / 10 | 7 / 6 | 11 / 14 |
| of which Custom SQL | 1 / 0 | 2 / 0 | 3 / 1 |
| Workbook elements | 35 / 41 | 27 / 18 | 9 / 10 |
| Hidden or unread (hidden Data page masters) | 0 / 11 | 0 / 4 | 0 / 4 |
| Clicks from a chart to its source table | 2 / 4 | 1 / 4 | 1 / 2 |
| Build time, whole run (s) | 78 / 4 (stopped early) | 227 / 245 | 153 / 82 |
| Chart time, median of per-chart medians (s) | 3.25 / 4.21 | 3.18 / 4.16 | 3.19 / none built |
| Parity, charts PASS of built | 18 of 18 / 1 of 15 | 15 of 15 / 4 of 6 | 4 of 4 / none built |

Notes on the table:
- Every model is below the 30-40 element guidance in both shapes; these test models are small, and the pbi shape does not add elements to reach it.
- Build time: pbi includes the page-summary and materialization runs (schedule run-now 30-80 s each); Retail Sales views stopped at the validate gate (DM only), Inventory pbi adds the live probes.
- Chart time: Retail Sales pbi read live warehouse tables (that run predates the fix that schedules page summaries for materialization, so its summary was not materialized); Sales Trends pbi: Trends charts read the materialized `Trends - summary`, Rolling charts the live element,
  KPIs the warehouse table; Inventory pbi: all charts read the materialized `Cover - summary`. Sigma may serve repeats from its result cache and none was bypassed, so differences of about a second are noise.
- The Retail Sales views workbook was hand-repaired (the invalid pivot removed) so it could be measured: its element counts, timing and parity are of that repaired spec.

## What is not whole
- Retail Sales pbi: nothing (28/28 visuals, 18/18 charts). Views: 15 of 18 built, 14 diverge (the Discontinued report filter has no column to bind to; Category and Brand lose their dimension).
- Sales Trends pbi: `Sales R28 by Customer Region` is held back (no element), and `Store Region: R28 and sales` loses its R28 column (the rolling window and Sales are different summaries). Mixed-summary limit, listed in `limits.md`.
  Views: 6 of 21 visuals built, 2 of those diverge (Year and Quarter keys lost).
- Inventory pbi: the Store Region slicer on the Cover page is dropped (v1 limit: no element on the page reaches it). Power BI's Store Region changes On Hand and R28 but not Open PO Units. Follow-up: a one-column value-list element per such slicer plus the live gate. Views: all 4 data visuals dropped.

## Views blockers (existing default-shape behaviour on origin/main, not changed here)
- A Views join is one hop, so a two-hop dimension (Category, Brand through Product) is lost; the report filter then has nothing to bind to and a pivot over it fails validation (Retail Sales, exit 4).
- No time-intelligence translation (TOTALYTD, SAMEPERIODLASTYEAR, DATESINPERIOD): every such measure is dropped (Sales Trends).
- Year and Quarter keys keep physical names (`Year Num`) that do not match the model column names, so those fields and the Year slicers resolve to no column.

## What the pbi shape still needed by hand (page facts completed by the agent)
- Retail Sales: `Shipping` summary (order-date and ship-date measures on one Date axis): month grain and per-path joins completed; DAX parity checked first.
- Sales Trends: `Trends` summary (YTD, QTD, MTD, prior year, YoY: the scaffold cannot decompose TOTALYTD and friends, so SQL, grain-picking formulas and checks were written by hand). Covers month, quarter, year and no axis only.
- Inventory: `Cover` summary (one row per product, grain includes Vendor Country and Brand). Scaffold left four TODOs.
- All three: `--allow-field-loss` where a visual is held back or a field dropped, and explicit `--value` flips for controls the automatic control flip cannot read (Year; Vendor Country, Brand).

## Live defects found and fixed during these runs
- DM POST failed: converter kept element names as column prefixes. Metric-to-metric refs not qualified `[Metrics/..]`. Report filter applied to the dimension turned excluded keys into NULL.
- Control flip left 9 of 10 controls unverified: relationship-path and boolean helper columns; flip values now read from the warehouse. limits.md listed a built class D visual as held back.
- Class D visual with two relationship paths now held back and listed. Page summaries now get materialization schedules. Freshness probe duplicate element id.
- Rolling-window KPI summed every day (12.0B instead of 9.77M); no-axis grouped reads mirror DAX; density probe moves sparse grouped class C to D; blank latest period stays blank.
- DATATABLE calculated table flattened to one column, typed literals and backslash escaping; literal-rows element not materialized and not probed.
- Map and limits named the wrong home for a summary-fed measure; scaffold drafted SUMX +/- without blank-as-0.
- Found by the final review after these live runs, not re-run live (covered by offline tests and the corpus golden): an as-of metric plotted on a date axis or under a date slicer; rolling windows ignoring report filters; a metric `+`/`-` metric reading blank instead of 0; date fields that are not calendar levels (fiscal, week, name) bound as dates; `USERELATIONSHIP` visuals under date controls; `CALCULATE` filter overrides under a slicer on the filtered column; `DATESBETWEEN` rolling forms. They are fixed or held back as class D.
- Not fixed (documented): grouped time intelligence that cannot carry its slicers needs a hand page summary (design change); a slicer outside the page summary's grain loses its control before the live gate (design change); Phase 6b cannot flip a summary-grain control automatically; pivot sort skipped (pre-existing).

## Regression rerun and RLS
- Rerun after the later fixes: Sales Trends pbi exit 0, 15/15, density probe ran (month 42/42, quarter 14/14, not sparse), materialization FRESH, control flip 5/5. Inventory pbi exit 0, 4/4 (1704 cells), FRESH, flip 2/2.
- RLS: a model with a row-filter role is refused by the pbi shape with exit 10 before anything is posted, naming the role (`results/rls-refusal.md`). Use the default shape for security.
