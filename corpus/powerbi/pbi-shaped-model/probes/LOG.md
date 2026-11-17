# Probe log: Power BI-shaped model mode

Evidence for the rules the mode relies on. Each row: the rule, result, the form that worked, and any fallback.
Truth comes from read-only Snowflake SELECTs (independent of Sigma); workbook values come from CSV exports of the
chart elements. Raw evidence: `results/p_core.json`.

## Task 3: core probes (`p_core.py`), 2026-11-16

Data model: Category, Product, SKU, Store, Customer, Date (one warehouse-table element each, relationships on the
many-side element), plus `Sales (source)` (FACT_SALES, 5 relationships) and a child `Sales` (`source: {kind: table,
elementId: <Sales (source)>}`) that re-exposes the columns as `[Sales (source)/<Col>]`, adds a `Revenue` calc column
and declares its own copy of the 5 relationships (`SKU`, `Store`, `Customer`, `Date`, `Date (Ship Date Key)`).
Workbook charts read the child directly with `source: {kind: data-model, dataModelId, elementId}`; no Data page.

| Check | Rule | Result | Form that worked / fallback |
|---|---|---|---|
| P1 | A chart reading a DM element directly can group by a column three relationship hops away | PASS (13/13 rows match SQL, including the NULL category) | `[Sales/SKU/Product/Category/Category Name]`; measure `Sum([Sales/Revenue])`. No `(SOURCE)` suffix was needed. |
| P2 | A list control on a column no axis shows filters two charts; with and without a pick | PASS (no pick, West on chart 1 (13/13), West on chart 2 (42/42) all match SQL) | The column sits in each chart's `columns[]` but on no axis (it does not split the groups). Control: `controlType: list`, `selectionMode: multiple`, `mode: include`, `values: []`, `filters: [{source:{kind:table,elementId:<chart>}, columnId:<that column>}]` x2. Export `parameters: {"<controlId>": "West"}`: the value is a STRING (an array is a 400). Multi-pick: `"West,East"` works (13/13); a JSON-array string returns 0 rows. |
| P2b | Single-select default is `value` (singular) | PASS (readback keeps `value: "West"`; an export with no pick applies it, 32/32 match SQL) | `selectionMode: single`, `value: "West"` |
| P3 | A value list sourced directly from a DM element | FAIL as predicted when no workbook data element reads that element: dry run `Dependency not found: '<dmId>/<elementId>'`. PASS once some workbook data element reads it. | Direct form: `source: {kind: source, source: {kind: data-model, dataModelId, elementId: <Customer>}, columnId: <DM column id>}`. Needs a workbook element with `source: {kind: data-model, ...<Customer>}` (a table reading `[Customer/Customer Region]`) or the dry run rejects it. Fallback (always valid): `source: {kind: source, source: {kind: table, elementId: <chart>}, columnId: <chart's [Sales/Customer/Customer Region] column>}`. Both full workbook runs pass all other checks. |
| P5 | Related columns picked from the child resolve (child declares its own relationships) | PASS (32/32 rows, Store Region x Brand under the West default) | `[Sales/Store/Store Region]`, `[Sales/SKU/Product/Brand]` read from the child `Sales`; relationships are the child's own copies |
| P6 | Second (non-first) Sales-to-Date relationship works for month grouping | PASS (42/42 months match SQL on SHIP_DATE_KEY) | `[Sales/Date (Ship Date Key)/Month]` (Month = `DateTrunc("month", [Cal Date])` on the Date element). The export shows the month as `YYYY-MM`. |
| P12 | Boolean slicer through a text filter column; picks True, False, blank | PASS (all three match SQL, NULL loyalty rows in the blank pick) | Column `If(IsNull([Sales/Customer/Loyalty Member]), Null, If([Sales/Customer/Loyalty Member], "True", "False"))`; list control on it, export params `"True"` / `"False"` / none |

Shape facts learned while building (all live):
- DM POST `/v2/dataModels/spec` kept my element, column and relationship ids; readback names and relationship names
  were identical to the authored ones, including the parentheses in `Date (Ship Date Key)`.
- A warehouse table must be in Sigma's catalog first: the test schema was created after the last sync and the DM POST
  failed `Source not found` until `connections sync` ran for the schema path.
- Workbook `contents` needs `kind: "workbook"`, a `layout` XML string, and `color` on bar charts is `{by: category, column}`.

### Fix round 1 (tightened checks, re-run live 2026-11-16; all still PASS)

- `verdict()` now fails an empty comparison (needs non-empty truth and actual).
- P6: ship-month truth differs from order-month truth in 42 of 42 months, so a chart that wrongly used the active
  (order) relationship could not pass. Recorded as `ship_vs_order_truth_months_differing`.
- P2: West-filtered truth differs from unfiltered in 13/13 categories and 42/42 ship months (asserted > 0).
  P2b/P5: West vs unfiltered differs in 32 store-region x brand rows (asserted). P12: True and False each differ
  from the unfiltered truth in 5/5 segments (asserted).
- P12 "blank" means no selection (the unfiltered state: every row, NULL loyalty included), not a null pick.
- P3 value lists: the control element itself cannot be exported (400), so the listed values are read from the column
  the control lists from and compared with SQL DISTINCT.
  - Direct form (accepted only with a reader element): `DIM_CUSTOMER` region values via the reader table = SQL
    DISTINCT (5 regions, no NULL).
  - Fallback form: the chart-domain over the Sales formula `[Sales/Customer/Customer Region]` lists 6 values = SQL
    (5 regions plus a NULL group from the 3% of sales rows with no customer). Hence the fact-side list carries a
    NULL member, the dimension-side list does not.
  - Limit: the rendered control dropdown is not API-readable; this verifies the source column's domain, and the
    control's `source` readback points at it.

### Fix round 2 (P3 evidence, re-run live; all still PASS)

- Controls API checked: `sigma api workbooks --help` lists a `controls` command (`controls list`, i.e.
  `GET /v2/workbooks/{workbookId}/controls`); `sigma api list-prefixes` shows `/v2/workbooks` (62 operations) and
  `/v2.1/workbooks`. The live response for the P3 workbook is only
  `{"entries":[{"name":"Loyalty","valueType":"text-list"},{"name":"Region","valueType":"text-list"},{"name":"RegionOne","valueType":"text"}]}`:
  control names and value types, no available values. Also checked: `POST /v2/workbooks/{id}/export` with the
  control's element id returns 400. So no endpoint exposes a control's offered values; the source-domain proxy
  (previous section) stands as the documented evidence. The controls listing is recorded in `results/p_core.json`.
- `control_source_readback` is now asserted per variant (`control_source_matches_intended`, part of the P3 verdict):
  - direct form: `{kind: source, source: {kind: data-model, dataModelId, elementId: <Customer>}, columnId: e-cust/CUSTOMER_REGION}`;
  - fallback: `{kind: source, source: {kind: table, elementId: <chart>}, columnId: <chart column>}` and that chart
    column's formula reads back as `[Sales/Customer/Customer Region]`.
- Design input: the fallback value list (the Sales-side related-path column) has a NULL member (6 values), because
  3% of sales rows have no customer; the direct Customer-element list has no NULL (5 values). A Power BI slicer on
  the dimension column shows "(Blank)" only when the dimension itself holds blanks, so the direct list matches that
  while the fallback adds a NULL item. To avoid a spurious blank item with the fallback, filter it out or use the
  direct form.

## Task 4: metric and naming probes (`p_metrics.py`), 2026-11-16

Each probe posts its own small data model (dimension elements, `Sales (source)` base and, where relevant, a child
`Sales`) and a workbook whose charts read the DM element directly; chart exports are compared with read-only
Snowflake truth. Raw evidence: `results/p_metrics.json`. The shared spec helpers moved to `probe_shapes.py` (p_core.py
imports them; its data model and workbook JSON were checked offline to be byte-identical before and after).
Metrics are referenced from a workbook as `[Metrics/<name>]` on a chart sourced from the element that owns the metric.

| Check | Rule | Result | Form that worked / fallback |
|---|---|---|---|
| P4 | Metric `List Value` = `Sum([Quantity] * [List Price])` needing `List Price` from a related table | Base form FAIL at query time; child `Lookup` form PASS (13/13 categories equal `SUM(QUANTITY * LIST_PRICE)` by category, NULL category included) | Base: calc column on `Sales (source)` `[Sales (source)/SKU/Product/List Price]` (also tried `[SKU/Product/List Price]`) POSTs and reads back unchanged, then both the metric and an inline `Sum(... [List Price])` return `Reference to errored column "[Metrics/List Value]"` / `"[Sales (source)/List Price]"` in every row of the export. Child `Sales`: `Product Key = Lookup([SKU/Product Key], [Sku Key], [SKU/Sku Key])`, `List Price = Lookup([Product/List Price], [Product Key], [Product/Product Key])`, metric `List Value` = `Sum([Quantity] * [List Price])` on the child; `[Metrics/List Value]` and the inline `Sum([Sales/Quantity] * [Sales/List Price])` both equal SQL. Lookup arg order: `(value from other element, local key, other element's key)`, per `reference/calc-columns.md`. |
| P7 | Same metric name on two elements | No error: POST accepted, readback keeps both | `Row Count` on `Category` and on `Store`, each `Count([<key>])`; each element's readback lists its own `Row Count` unchanged (no rename, no drop). `[Metrics/Row Count]` resolves per source element (a chart on `Category` gave 12 groups, one on `Store` 40, each count 1). Same name on different elements is safe; a base and its child holding the same name was not exercised. |
| P13 | Report-wide filter `IsNull([Category Name]) or [Category Name] != "Discontinued"` keeps NULL-category rows | PASS (3 forms; 12/12 category groups incl. NULL group match SQL; filtered total 408,730,662.71 differs from unfiltered 433,081,226.62; Discontinued group absent, NULL group present) | `Category Name` reaches the child as a Lookup chain (`Product Key`, `Category Key`, `Category Name`, each `Lookup(other/col, local key, other/key)`), NOT as the relationship-path column. There is no formula filter kind in a DM element's `filters`, so the formula becomes a column plus a filter on it, all three kept on readback and equal to truth: (1) `Keep` = the formula, `{kind: list, mode: include, values: [true]}`; (2) `Keep` = `If(<formula>, "keep", "drop")` with `values: ["keep"]`; (3) no helper column, `{kind: text-match, mode: does-not-equal, value: "Discontinued", case: sensitive, includeNulls: "always"}` on `Category Name`. Relationship-path `[SKU/Product/Category/Category Name]` as a child calc column with the text-match filter POSTs and reads back but the export fails (`Export failed ... with errors`), so a DM child calc column cannot use the relationship path (same defect as P4 base). |
| P14 | Metric folders | FAIL: `folders[].items` cannot hold metric ids | POST rejects `folders: [{items: ["m-n", "m-r"]}]` (with or without the folder in `order`) with `pages[0].elements[0].folders[0].items[0]: Column or folder not found: 'm-n'` (one error per metric). The API has no metric folders. Survives readback: a column folder (`items` of column ids; the folder id goes into `order`), and metric `name`/`description` (e.g. name `Counts / Store Count`, description `Folder: Counts`; kept verbatim). Fallback for the mode: prefix metric names with `<Folder> / ` and set `description`; use real folders only for columns. The UI-facing describe was not available to check. |
| P17 | Columns renamed to Power BI names with every reference rewritten | PASS (region 6/6, segment via `[Metrics/Revenue Total]` 5/5, order-month 42/42 all equal SQL) | Display name is the column's `name`; the warehouse-column `formula` keeps pointing at the physical column: `{id: "<el>/ORDER_DATE_KEY", name: "OrderDateKey", formula: "[FACT_SALES/Order Date Key]"}` (token = the Sigma auto display name, i.e. title-cased physical name). The physical name `[FACT_SALES/ORDER_DATE_KEY]` is also accepted and read back normalized to `[FACT_SALES/Order Date Key]`. The Power BI name as the token `[FACT_SALES/OrderDateKey]` is REJECTED (28 `dependency not found` errors). Relationships use column ids (`<el>/ORDER_DATE_KEY`), so they need no rewrite; calc columns, metrics, child re-exposure (`[Sales (source)/OrderDateKey]`) and workbook formulas (`[Sales/UnitPrice]`, `[Sales/Customer/Customer Segment]`) use the new name. |

Decision for Task 11 (P4, Step 1): only the child `Lookup` form works, so split the fact as the spec says
(`Sales (source)` base plus a child under the Power BI name). Metrics that need a related column live on the child and
reach it through a `Lookup()` calc column; a relationship-path calc column in a DM element does not work at query time
(the child's relationship paths are fine inside workbook formulas, as P1 to P6 showed).

## Task 5: time-intelligence and summary probes (`p_time.py`), 2026-11-16

One data model per probe (dimensions, `Sales (source)`, child `Sales`, plus the element under test) and a workbook whose
charts read the DM element directly; chart exports are compared with read-only Snowflake truth. Raw evidence:
`results/p_time.json` (16 objects created, all verified `isArchived: true`). The child `Sales` carries `Revenue`
(`[Quantity] * [Unit Price] * (1 - [Discount])`), `Order Date` (`Lookup([Date/Cal Date], [Order Date Key], [Date/Date Key])`)
and `Store Region` (`Lookup([Store/Store Region], [Store Key], [Store/Store Key])`), because the fact has only date keys
and a relationship-path calc column does not work in a DM element (P4).

| Check | Rule | Result | Form that worked / fallback |
|---|---|---|---|
| P8a | Fixed-anchor YTD/QTD/MTD metrics with the as-of date reaching the child via a constant-key `Lookup` | PASS (4/4 store regions match SQL for each of YTD, QTD, MTD; YTD, QTD and MTD differ from each other in 4/4 regions, so a wrong anchor could not pass) | Calc column `One = 1` on `As Of` (warehouse table `AS_OF`, one row) and on the child; child calc `As Of Date = Lookup([As Of/As Of Date], [One], [As Of/One])`; metrics on the child, e.g. `SumIf([Revenue], [Order Date] >= DateTrunc("year", [As Of Date]) and [Order Date] <= [As Of Date])` (`"quarter"`, `"month"` for QTD, MTD). Consumed as `[Metrics/Sales YTD AsOf]` in a chart grouped by `[Sales/Store Region]`. Works both with a relationship `As Of` (source `e-sales/one`, target `e-asof/one`) and with NO relationship declared (the Lookup alone resolves), so the relationship on `One` is optional. |
| P8b | Grouped child: Year outer level, Month inner, `CumulativeSum`, `DateLookback` | PASS (42/42 months equal SQL for Sales, YTD and PY; Jan YTD = Jan Sales in all 4 Januaries; PY null for the 12 months of the first year, 30 non-null months match) | `groupings: [{id, groupBy:[year]}, {id, groupBy:[month], calculations:[sales, ytd, py]}]` on an element with `source: {kind: table, elementId: <Sales child>}`; columns `Year = DateTrunc("year", [Sales/Order Date])`, `Month = DateTrunc("month", [Sales/Order Date])`, `Sales = Sum([Sales/Revenue])`, `Sales YTD = CumulativeSum(Sum([Sales/Revenue]))`, `Sales PY = DateLookback([Sales], [Month], 1, "year")`. Groupings and formulas read back unchanged. The chart groups by `[Sales Monthly/Month]` and aggregates `Max([..Sales YTD])`. `Sum()` of the same column also matched here (42/42) because the chart's grouping equals the element's inner grouping (one row per month); `Max()` stays the safe form. A chart column that is on no axis is NOT exported (CSV header lacks it), so every compared column must be on `yAxis.columnIds`. |
| P8c | Rolling 28 days: `MovingSum` over present rows vs Custom SQL over a dense spine | Custom SQL PASS: 546/546 days from 2025-01-01 equal calendar truth, and 1277/1277 over the full history. `MovingSum` FAILS as predicted (numbers below) | Custom SQL form: DM element `source: {kind: sql, connectionId, statement}` with `WITH d AS (SELECT od.CAL_DATE AS DAY, SUM(<rev>) AS S ... GROUP BY 1) SELECT dd.CAL_DATE AS DAY, COALESCE(d.S, 0) AS DAY_SALES, SUM(COALESCE(d.S, 0)) OVER (ORDER BY dd.CAL_DATE ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS ROLLING_28 FROM DIM_DATE dd LEFT JOIN d ON d.DAY = dd.CAL_DATE`; columns `[Custom SQL/DAY]` etc. (uppercase output names); chart `Max([Rolling SQL/Rolling 28])` by day. MovingSum form: day-grouped element `Day = DateTrunc("day", [Sales/Order Date])`, `Day Sales = Sum([Sales/Revenue])`, `Moving 28 = MovingSum([Day Sales], 27, 0)`: POSTs, reads back unchanged, queries, but is not a calendar window. |
| P15 | Slicer pick on a grouped element with `Store Region` carried | PASS for Region as the OUTERMOST grouping; FAIL for Region as the innermost level | Working: `groupings: [Region] -> [Year] -> [Month(calcs)]`, i.e. `groupBy [region]`, then `[year]`, then `[month]` with the calcs on the month level, so `CumulativeSum` and `DateLookback` run per region and per year. Chart by month with `Sum([..Sales])`, `Sum([..Sales YTD])`, `Sum([..Sales PY])` and `Store Region` as a no-axis column; list control `filters` -> that chart column. No pick: all 42 months equal all-region truth (Sum over the region rows = total, YTD and PY included). Pick `West` (export parameter string): 42/42 equal West-only truth (sales and YTD), pick changes the numbers (42/42 months differ); `"West,East"`: 42/42 equal truth. Failing form: `[Year] -> [Month(calcs)] -> [Region]` (Region at detail): the calcs stay at month level over all regions, so `Sum` over the region rows multiplies the total by 4 (no pick: 0/42 match), and a pick leaves every number at the all-region value (West pick equals all-region truth 42/42, West truth 0/42); the slicer does nothing to the precomputed numbers. Consumers of the working form must also expect that with a pick, `Max` is a region value and with no pick, `Max` is the largest region, so the consumer formula is `Sum`, not `Max`. |
| P16 | Parent metric read in the grouped element | PASS: POST accepted, equals `Sum(Revenue)` at month grain (42/42) | A column `[Metrics/Sales Amount]` on the grouped element, with the metric `Sales Amount = Sum([Revenue])` defined on the Sales child. `[Sales Amount]` alone POSTs and reads back, but every export row is `Reference to errored column`. `[Sales/Sales Amount]` is rejected on POST (`dependency not found: formula reference 'sales/sales amount'`). Only `[Metrics/<name>]` works. |

Decisions for Task 12:
- Fixed-anchor YTD/QTD/MTD: the conditional-sum metric on the child with the constant-key `Lookup` works exactly.
- Axis-following YTD and prior period: the generated grouped element works exactly with Year as its own outer level; add `Store Region`
  (or any slicer dimension) as a grouping ABOVE Year when a slicer must filter the precomputed values, never below Month.
- Rolling N days: use the Custom SQL summary over `DIM_DATE`; `MovingSum` must not be emitted (row-based, wrong after gaps).

`MovingSum` over present rows, 2025-01-01 onward (546 calendar days, 17 with no sales at all so absent from the element):
344 of 529 present days (65%) differ from the calendar window truth, by up to 1,142,288 (13.5% relative, mean 4.9%); the
185 days whose 28-day calendar window holds no gap day all match. Example: 2025-01-25 gives 9,727,629 vs truth 9,376,914.
Missing store-days alone do not break it (it sums per-day totals); only whole days without sales shift the window.

## Task 6: physical-layer probes (`p_physical.py`), 2026-11-16

Raw evidence: `results/p_physical.json` (3 data models and 6 workbooks, plus the scratch workbooks `run_sql` posts and archives itself, all
verified `isArchived: true`; 4 materialization schedules deleted and verified gone from the schedule listing). Truth is read-only
Snowflake SQL as before; the key check runs through `probe_lib.run_sql` (the Sigma connection). The run script was edited
after the live run only to drop two unused variables and to add `annotate_timing` (query-history evidence), which was applied
to the stored results with `p_physical.py ANNOTATE` (it creates nothing live).

| Check | Rule | Result | Form that worked / fallback |
|---|---|---|---|
| P9 | A data model with three pages (Sales, Inventory, Shared) and relationships across pages; a workbook chart picks a field from a dimension on another page | PASS (5/5 charts equal SQL) | Pages: Sales = `Sales (source)`, `Sales`, SKU, Product, Category; Inventory = `Inventory` (FACT_INVENTORY); Shared = Store, Date, Customer. Relationships declared on the many-side element with `targetElementId` naming an element on ANOTHER page are accepted (the spec doc's "both elements must be on the same page" is not enforced): `Sales (source)`/`Sales` to Store, Customer, Date, Date (Ship Date Key) on Shared; `Inventory` to Store (Shared) and to SKU (Sales page). Chart over the Sales child: `[Sales/Store/Store Region]` 4/4, `[Sales/Customer/Customer Region]` 6/6 (incl. NULL), `[Sales/SKU/Product/Category/Category Name]` 13/13; over Inventory: `[Inventory/Store/Store Region]` 4/4 and `[Inventory/SKU/Product/Brand]` 8/8 (path crosses Inventory -> SKU on Sales page -> Product). Relationship paths therefore work across pages. Readback keeps page names, page order, which element sits on which page and every relationship (names and targets). It does NOT keep the authored element order inside a page: the Sales page came back `Category, Product, SKU, Sales (source), Sales` (dependency order, dimensions first), so a consumer must not rely on element order within a page. |
| P10 | Materialization schedules on a `warehouse-table` element and on a child element; run once; chart over the child equals SQL | PASS | See the endpoint list below. Schedules on `Sales (source)` (warehouse-table) and on child `Sales` both accepted and read back; the 409 on the manual trigger cleared after 36 to 50 s (first run done), the child build took 17 s (`building` to `ready`); chart over the materialized child equals SQL (4/4 regions, 13/13 categories). |
| P11 | A flattened child with the related columns as calc columns in folders `Store` and `Product`; compare with the unflattened child | PASS (live and materialized) | Element `Sales (flattened)`, `source: {kind: table, elementId: <Sales (source)>}`, no relationships. Calc columns by the Lookup chain: `Product Key = Lookup([SKU/Product Key], [Sku Key], [SKU/Sku Key])`, `Category Key = Lookup([Product/Category Key], [Product Key], [Product/Product Key])`, `Brand = Lookup([Product/Brand], [Product Key], [Product/Product Key])`, `Category Name = Lookup([Category/Category Name], [Category Key], [Category/Category Key])`, `Store Region = Lookup([Store/Store Region], [Store Key], [Store/Store Key])`, `Channel = Lookup([Store/Channel], [Store Key], [Store/Store Key])`, plus a `Revenue` column. Folders `{id: f-store, name: "Store", items: [Store Region, Channel]}` and `{id: f-product, name: "Product", items: [Product Key, Category Key, Brand, Category Name]}` with the folder ids at the end of `order`; both folders, their names and items read back unchanged before materialization; after materialization only the folder names were re-read (`Store`, `Product`; items checked only before). Charts over it equal SQL: by Category 13/13 (incl. NULL), by Channel 3/3, `Sum([Sales (flattened)/Revenue])` 13/13, and the rows are identical to the unflattened child's `[Sales/SKU/Product/Category/Category Name]` chart. After materialization the flattened chart still equals SQL (13/13). |
| Key check | `SELECT COUNT(*) - COUNT(DISTINCT key) AS dup FROM <target>` through the Sigma connection | PASS | `DIM_PRODUCT.PRODUCT_KEY` gives `dup = 0`; `DIM_PRODUCT_DUPKEY.PRODUCT_KEY` gives `dup = 1`. Each call takes 4 to 5 s because `probe_lib.run_sql` posts and exports a scratch workbook (which is then archived). |

### P10 materialization: exact endpoints and fields

- Create: `POST /v2/dataModels/{dataModelId}/elements/{elementId}/materializationSchedules`, body
  `{"schedule": {"cronSpec": "0 6 * * *", "timezone": "America/New_York"}}` (the form `materialization_schedules.rb`
  uses). Response: `{sheetId, elementId, elementName, configuredAt, schedule: {cronSpec, timezone}, paused}`. Works on a
  `warehouse-table` element and on a child element (`source: {kind: table, elementId}`) alike. Quirk seen once: the very first POST
  response had `elementId: ""` and `elementName: ""`; the listing and later POSTs carried them.
- List/readback: `GET /v2/dataModels/{dataModelId}/materializationSchedules` returns `entries[]` with `sheetId, elementId,
  elementName, schedule, paused`. The schedules read back exactly as posted.
- Run now: `POST /v2/dataModels/{dataModelId}:materialize` (CLI: `sigma api data-models materialize`) with body
  `{"sheetId": "<sheetId from the schedule>"}`; `elementId` is rejected (`Expecting string at sheetId but instead got: undefined`).
  Response `{"materializationId": "<uuid>"}`.
- Poll: `GET /v2/dataModels/{dataModelId}/materializations/{materializationId}` (CLI: `data-models materializations get`).
  States seen: `pending`, `building` (adds `startedAt`), `ready` (adds `readyAt`), and `skipped` (on the warehouse-table element, 13 s
  after `pending`). Child elements: `pending` -> `building` -> `ready`, build 15 to 17 s for 2,974,371 rows.
- Creating a schedule starts a first run of its own: right after the POST every manual trigger answers 409
  `Materialization already in progress` (`conflict_request`) until that run ends (3 to 4 rounds of 10 s here). Its materializationId
  is not returned, so the first run cannot be polled by id; the manual run is the one that can be polled. A script should treat a
  409 on `:materialize` as "a run is in flight, retry".
- There is no list-runs endpoint: `GET /v2/dataModels/{id}/materializations` fails (empty error); only get-by-id exists.
- One slow case: the earlier exploratory run (one schedule on `Sales (source)`, nothing else) held the 409 for about 707 s before the
  manual trigger was accepted, and that run then showed `skipped` for the rest of the 20 minute poll. The formal run (four schedules
  at once) finished in 82 s. Cause not identified (queueing in Sigma or the warehouse is the likely reason); a consumer needs a
  20 minute cap, not a fixed wait.
- Materialized tables are real warehouse tables in the connection's write schema (`writebacks[0]` of `GET /v2/connections/{id}`),
  named `t_mat_<32 hex>_0` (masked here and in the JSON as `<mat-table-N>`; the exact names are in the gitignored task-6 report for cleanup), `BASE TABLE`, 2,974,371 rows each. The formal run made 7 (4 first runs from the schedule POSTs, 3 manual
  runs that built; the warehouse-table element's manual run was `skipped`).
- Delete: `DELETE /v2/dataModels/{dataModelId}/elements/{elementId}/materializationSchedules` (CLI
  `data-models elements materialization-schedules delete_data_model_materialization_schedule`); the listing no longer shows the
  element afterwards (verified for all 4). Archiving the data model (`DELETE /v2/files/{id}`) is accepted too.
- What Sigma does with materialized tables on delete: NOTHING. After the schedules were deleted and the data models archived, all 7
  `t_mat_*` tables were still in the write schema with their rows (the results file lists them before and after). The API exposes no
  call to drop them, so a probe or a migration cannot clean them up; earlier exploratory runs left more in the same schema (count not recorded in the results). They must be dropped with warehouse SQL by someone with that privilege (not done here: the probes only read).
- Is the chart served from the materialization? Yes, per Snowflake query history (see timing): for the 6 materialized timing samples
  the SQL reads a `t_mat_` table and for the 6 live timing samples it does not. Not checked in query history: the P10 correctness charts
  and the P11 `fm-cat` chart (they equal SQL, which does not show which table served them).

### Timing baseline (Sales by Category, three-hop path vs flattened; live vs materialized)

What was measurable: only the export round trip (`POST /v2/workbooks/{id}/export` plus polling `GET /v2/query/{id}/download`),
timed with wall-clock time. The API has no page-load time. Each sample is one chart with a distinct cache-busting predicate inside
the measure, `Sum(If([<el>/Quantity] > -k, Quantity * Unit Price * (1 - Discount), 0))`, where `k` differs per sample and per
live/materialized group (11, 12, 13 live; 21, 22, 23 materialized), so the SQL text is new each time (no result-cache hit; the
query history shows 36 MB to 85 MB scanned on every sample). Variants are interleaved. Warehouse-side numbers come from Snowflake
`INFORMATION_SCHEMA.QUERY_HISTORY`: Sigma tags each query with the workbook and the exported chart id, which identifies every sample.

| Variant | Export round trip, seconds (start UTC, 2026-11-16) | Median export s | Warehouse total / execution ms | Median warehouse total / execution ms | Reads `t_mat_` |
|---|---|---|---|---|---|
| child, three hops, live | 5.04 (16:51:45), 2.89 (16:51:53), 3.10 (16:51:59) | 3.10 | 339/101, 257/76, 309/95 | 309 / 95 | no |
| flattened, live | 2.85 (16:51:50), 2.88 (16:51:56), 5.06 (16:52:02) | 2.88 | 307/90, 163/67, 408/101 | 307 / 90 | no |
| child, three hops, materialized | 5.12 (16:54:07), 5.12 (16:54:17), 2.92 (16:54:28) | 5.12 | 951/584, 400/97, 289/94 | 400 / 97 | yes |
| flattened, materialized | 5.12 (16:54:12), 5.18 (16:54:23), 5.08 (16:54:31) | 5.12 | 137/26, 162/28, 104/30 | 137 / 28 | yes |

n = 3 per group, so medians are indicative only. All 12 exports matched the SQL category totals. Reading: the export round trip is dominated by a fixed 3 s or 5 s overhead
(two modes: values cluster at 2.9 and 5.1), so it cannot rank the variants; it does not show materialization as faster (the
materialized medians are higher, by one 2 s polling step). The warehouse side does: materializing only the child leaves the
three dimension joins in the query (the SQL still joins SKU, Product, Category on top of `t_mat_`, scanning 85 MB because the
materialized table carries every column), so it is no faster than live (400 vs 309 ms median); the materialized flattened child
has the related columns precomputed, runs with no dimension joins, and is about 2.2 times faster than live (137 vs 307 ms
median total, 28 vs 90 ms execution). Note that the live flattened child costs the same as the live child: its Lookup columns
compile to the same joins. That is the case for the flattened child: it only pays when it is materialized.

### Summary: probe results by rule (P1 to P17 and the key check)

Gate note for the controller (Step 2 is not done here): no core probe has an unmitigated failure. The fallbacks taken are P3
(chart-column value list), P4 (split the fact and use `Lookup`), P8c (Custom SQL), P12 (text column), P13 (Lookup chain), P14
(metric name prefix) and P15 (Region outermost). Open item: materialized tables outlive their data model and cannot be dropped by API.

| Rule | Pass/fail | Form used | Fallback taken |
|---|---|---|---|
| P1 chart groups by a column three relationship hops away | PASS | `[Sales/SKU/Product/Category/Category Name]` on a chart reading the child directly | none |
| P2 list control on a no-axis column filters two charts | PASS | column in `columns[]` on no axis; control `filters` to each chart column; export parameter is a string | none |
| P2b single-select default | PASS | `selectionMode: single`, `value: "West"` (singular) | none |
| P3 value list from a DM element | PASS | Condition: direct `source: {kind: source, source: {kind: data-model, ...}, columnId}` only when some workbook element reads that DM element | fallback (always valid): list source is the chart's own column, which adds a NULL member |
| P4 metric needing a related column | PASS | Base form FAILS; child form: `Lookup()` chain calc columns on the child `Sales`, metric on the child | split the fact: `Sales (source)` plus child under the Power BI name |
| P5 related columns from the child | PASS | child declares its own relationship copies | none |
| P6 second Sales-to-Date relationship | PASS | `[Sales/Date (Ship Date Key)/Month]` | none |
| P7 same metric name on two elements | PASS | Accepted and kept: one `Row Count` per element, `[Metrics/Row Count]` resolves per source element | none |
| P8a fixed-anchor YTD/QTD/MTD | PASS | constant-key `Lookup` of the as-of date to the child; `SumIf` metrics | none |
| P8b axis-following YTD and prior year | PASS | grouped element, Year then Month levels, `CumulativeSum`, `DateLookback`; `Max` in the chart | none |
| P8c rolling 28 days | PASS | `MovingSum` FAILS; Custom SQL form: Custom SQL over a dense `DIM_DATE` spine with `ROWS BETWEEN 27 PRECEDING AND CURRENT ROW` | Custom SQL element; never emit `MovingSum` |
| P9 three pages with cross-page relationships | PASS | relationships with `targetElementId` on another page; paths work across pages | none (element order within a page is re-sorted on readback) |
| P10 materialization schedules and run | PASS | `POST .../elements/{id}/materializationSchedules`, `POST ...:materialize {sheetId}`, `GET .../materializations/{id}` | none; tables are not dropped on delete (see above) |
| P11 flattened child with folders `Store` and `Product` | PASS | Lookup-chain calc columns, `folders` on the element, materialized | none |
| P12 boolean slicer | PASS | text column `If(IsNull(...), Null, If(..., "True", "False"))` plus a list control | text column instead of a boolean control |
| P13 report filter keeping NULL category | PASS | child Lookup chain column plus a `text-match` filter with `includeNulls: always` (or a helper column plus list filter) | the relationship-path column fails at query time; use the Lookup chain |
| P14 metric folders | FAIL | none: `folders[].items` cannot hold metric ids | metric name prefix `<Folder> / ` plus `description`; real folders only for columns |
| P15 slicer pick on a grouped element | PASS | Outermost grouping only: `Store Region` grouped above Year and Month | Region as the innermost level FAILS; never emit it |
| P16 parent metric read in the grouped element | PASS | `[Metrics/<name>]` column on the grouped element | `[Sales Amount]` alone and `[Sales/Sales Amount]` both fail |
| P17 columns renamed to Power BI names | PASS | display `name` set; warehouse-column formula keeps the physical/auto token; all other references use the new name | the Power BI name as the physical token is rejected |
| Key check (uniqueness SQL through the Sigma connection) | PASS | `SELECT COUNT(*) - COUNT(DISTINCT key) AS dup FROM <target>` via `probe_lib.run_sql` | none |

## Task 7: Power BI test items, 2026-11-16

Four models and three reports published to the `Test` workspace and bound to an existing Snowflake data
source. Every model refreshed to Completed. Per `live/pbi-verify.json`: all measures non-blank
(17, 17, 22 and 2), all visuals return rows with non-blank measures (28, 21 and 7), and Sales Amount,
Units, Sales by Ship Date (42 of 42 months), Sales YTD (As Of) (as of 2026-06-15) and Open PO Units equal
warehouse SQL. Finding: Power BI refuses duplicate measure names within one model, so the `Units` collision
is a Sales measure against an Inventory column. Rendering was not possible (export API off, browser blocked).
