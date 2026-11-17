# Live runbook: Power BI-shaped mode against the test org

Shared by every live run. Placeholders: `<connection id>`, `<folder id>`, `<workspace id>`, `<dataset id>`, `$SP` (an
untracked scratch directory holding ids, work dirs and logs). No ids, hosts, orgs or emails are tracked.

## Environment

- Sigma: `source "$SP/probe-env.sh"` in every shell (unsets every `SIGMA_*` override, pins the test-org CLI profile,
  exports the connection, folder, sample database and schema). Never set `SIGMA_BASE_URL` or tokens by hand.
- Power BI: the cached token only (never interactive). Python with msal/requests/truststore: `$SP/venv/bin/python`.
- `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` before Ruby.

## 1. Migrate (from `plugins/powerbi-to-sigma/skills/powerbi-to-sigma`)

```
ruby scripts/migrate-powerbi.rb \
  --tmsl "$SP/real-out/<model>/model.bim" --pbir "$SP/real-out/<report>/report-bundle.json" \
  --connection <connection id> --folder <folder id> \
  --workspace <workspace id> --dataset <dataset id> \
  --python "$SP/venv/bin/python" --probe-sources --yes --no-reuse \
  --name "zz Claude pbi-shape test – <Report> (<shape>)" --out "$SP/live/<report>-<shape>"
# pbi shape adds:  --model-shape pbi --materialization-cron "0 6 * * *"
# optional:        --scaffold-page-facts <Page> | --page-facts <dir>   (see 1b)
```

Run in the background (about 75 s each); never two orchestrator runs at once. The orchestrator exits 0 only after
Phase 6 resolution; it does NOT run value parity (see 2).

## 1b. Page summaries for a held-back class D visual (Retail Sales, Shipping page)

A visual that needs two relationship paths to one table (order-date and `USERELATIONSHIP` ship-date measures on one Date
axis) is held back by the pbi shape and listed in `coverage.json` (dropped), `limits.md` ("Class D measures and visuals") and
`pbi-map.*`. The field-loss gate then exits 10 after posting, so a base run without page facts needs `--allow-field-loss`.

1. Base run (above, plus `--allow-field-loss`): the visual is held back; every other chart passes parity.
2. Draft: the same command plus `--scaffold-page-facts Shipping --stop-before-post` (writes nothing to Sigma) -> `<work dir>/page-facts-draft/shipping/`
   (`closure.md` has "Relationship paths", `page-fact.sql`, `page-fact.json`, `check-queries.json`, `oracle-queries.json`).
3. Complete the SQL (copy the draft to `$SP/live/<report>-page-facts/<page>/`): replace the `NULL AS "G_MONTH_START"` grain
   with `DATE_TRUNC('MONTH', j1."CAL_DATE")` (and add it to both `GROUP BY` lists); the report filter and each path's join stay
   as drafted; keep the `@slicers` hooks. Mind DAX semantics: each measure joins Date on its own key, months come from the Date
   table so a month with sales on one path only still appears (UNION ALL + outer `GROUP BY`), the report filter applies.
   Optional: rename the `{C:...}` components in `page-fact.json` to readable names. The completed SQL is in
   `results/retail-sales/pbi/page-fact-shipping.sql`.
4. Verify before integrating: swap the new SQL into `check-queries.json`, run it with `scripts/sigma-sql-probe.py`, then
   `scripts/parity-from-oracle.py --spec <plan>` against the Power BI DAX oracle (`executeQueries`; the scaffold's SQL oracle
   cannot compile SUMX or a calculated-column grain). Expect every chart of the page MATCH (84/84 month cells here).
5. Final run: the base command plus `--page-facts $SP/live/<report>-page-facts` (no `--allow-field-loss`). The visual is built
   on `<Page> - summary`, `limits.md` no longer lists it, Phase 6b runs the control flip, parity is 18/18.

## 1c. Time intelligence (Sales Trends)

The Trends and Rolling pages are class C (YTD/QTD/MTD, prior year, rolling 28 days, an as-of YTD). What the shape builds itself, and
what needs a page summary:

- Rolling N days: a Custom SQL element over a dense day spine, materialized (`--materialization-cron`), read as
  `Sum(If([Day] = Max([Day]), [window], 0))` (the window ending at the context's last day; fixed: a KPI used to add every day).
- As-of metric: a metric on the fact (here 56.0M for 2026-01-01..2026-06-15).
- Axis-following YTD/QTD/MTD/PY on a page whose slicers cannot be carried (4x/84x row growth): class D, `slicer fields exceed carry size`.
  Same steps as 1b (draft with `--scaffold-page-facts --stop-before-post`, complete, rerun with `--page-facts <dir>`), plus
  `--allow-field-loss` because `Sales R28 by Customer Region` is held back and `Store Region: R28 and sales` loses its R28 field (they
  read different summaries). The completed Trends summary is `results/sales-trends/pbi/page-fact-trends.{sql,json}`: one row per month,
  columns for the running value per month / per year end / per quarter end / on the latest month, and per-measure formulas in
  `page-fact.json` `fields` that pick the column for the visual's grain with `CountDistinct(Month Start)` / `CountDistinct(Year)` /
  `CountDistinct(Year Quarter)`. Prior year comes from the UNFILTERED fact by month (probed: Feb 2025 PY is all of Feb 2024,
  Feb 29 included; a Year pick does not remove last year's sales); the as-of YTD is a constant column.
- DAX oracle for the page: `scripts` outside the repo run `executeQueries` with `SUMMARIZECOLUMNS` per visual and `ROW` per KPI
  (queries in `results/sales-trends/*/oracle.md`).
- Phase 6b leaves a slicer on a page summary (Custom SQL) UNVERIFIED by design; flip it with
  `ruby scripts/probe-controls.rb --workbook-id <id> --out <work dir>/probe-controls --value <ControlId>=<value> ...` for every control
  (explicit values for all of them: the probe's `--out` is rewritten).
- Freshness: `check-materialization-freshness.rb` needs `--default-db` / `--default-schema` when run by hand; it has no `--python` flag.

## 1d. Cross-fact report (Inventory and Purchasing)

Commands as section 1 (views: base; pbi: `--model-shape pbi --materialization-cron "0 6 * * *"`), plus:
- A DAX `DATATABLE` calculated table (the `Cover Bucket` lookup) is now converted to one Custom SQL row per DATATABLE row (it used to stop at the calculated-table gate in both shapes),
  and a literal-rows element is not scheduled for materialization.
- pbi: base run with `--allow-field-loss` (class D visuals held back), then the scaffold (`--scaffold-page-facts --stop-before-post --allow-field-loss`), the completed
  summary (`results/inventory/pbi/page-fact-cover.{sql,json}`: one row per product; grain includes Vendor Country and Brand so those two slicers filter its columns), DAX parity of the
  SQL over every row before integration, then the final run `--page-facts <dir> --allow-field-loss` (Store Region cannot be carried: its control is dropped).
- Phase 6b skips controls whose column is a summary-grain column the export does not show; flip them with
  `ruby scripts/probe-controls.rb --workbook-id <id> --out <work dir>/probe-controls --value VendorCountryFilter=<value> --value BrandFilter=<value>`.
- Pivot exports blank repeated row labels (forward-fill before `parity-from-oracle.py`) and include per-group "Total" rows and a grand total row; the DAX oracle needs the matching
  `SUMMARIZECOLUMNS` subtotal and `ROW` queries.

## 2. Value parity (Retail Sales; scripts kept outside the repo)

1. Export every chart element as CSV: `POST /v2/workbooks/<workbook id>/export` with
   `{"elementId": ..., "format": {"type": "csv"}}`, poll `GET /v2/query/<queryId>/download` (shared `sigma_rest` client).
2. Oracle: Power BI `executeQueries` (DAX) with the report-wide filter and the Slicers page's saved slicer selection
   written as `FILTER(ALL(col), ...)` arguments to `SUMMARIZECOLUMNS` / `CALCULATE`; a pivot's Total row is a separate
   `ROW(CALCULATE(...))` query. Warehouse SQL (`scripts/sigma-sql-probe.py`) is used to localize a divergence.
3. Compare: `python3 scripts/parity-from-oracle.py --spec <spec.json> --out-dir <dir>` (exit 2 on any divergence).
   `parity-final.json` is the sentinel.
4. Timing: three samples per chart through the same export call; medians per element. Repeats may be served from
   Sigma's result cache; no cache-bust is applied.

## 3. Report files

`ruby scripts/pbi-shaped-report.rb --tmsl <model.bim> --signals signals.json --dm-spec dm-spec.json --wb-spec
workbook-spec.json --out-dir <work dir>` (the orchestrator runs it itself in the pbi shape).

## Notes from the first live runs

- views shape on a snowflake model: the mechanical path exits 4 at validate-spec (a pivot whose row field is a
  two-hop dimension is dropped to no `rowsBy`); the data model is already posted. Results in `results/retail-sales/views`
  come from a workbook posted from that spec with the invalid pivot removed (hand repair, recorded).
- pbi shape, Retail Sales after the class D work: base run exit 10 (field-loss gate, visual held back) then exit 0 with
  `--allow-field-loss` (17/17 charts built PASS); final run with `--page-facts`: exit 0, parity 18/18, control flip 10/10 verified.
  The flip value for a control comes from the warehouse through the fact (`lib/pbi_flip_values.rb`); relationship-path helper
  columns and boolean wrappers needed their own resolution (fixed).
- Power BI `ExportToFile` is unavailable on the trial capacity, so the Power BI half of the screenshot gates is waived.

## 4. Regression rerun, RLS refusal, cleanup

- Reruns: Sales Trends pbi as 1c and Inventory pbi as 1d, each into a new work dir (`--page-facts <saved dir> --allow-field-loss`); then the exports and the DAX compare of section 2, and
  `probe-controls.rb` with explicit `--value` for every control (keep the automatic Phase 6b result first: `--out` is rewritten).
- RLS refusal: the pbi command with `--tmsl` of a model that has a role with a table filter exits 10 at once ("model_shape_security"), nothing posted (`results/rls-refusal.md`).
- Comparison: `ruby scripts/pbi-shaped-report.rb --tmsl <model-scoped.bim> --signals signals.json --dm-spec <pbi>/dm-spec.json --wb-spec <pbi>/workbook-spec.json --classes <pbi>/measure-classes.json --shaped-log <pbi>/pbi-shaped-model.json --slicer-carry <pbi>/slicer-carry.json --out-dir <copy of the pbi work dir's small files> --compare-dir <views work dir>`.
  It reads `parity-final.json` and `timings.json` from the directory root, so copy `parity/parity-final.json` up. See `COMPARISON.md`.
- Cleanup: delete every object in the run log by id through the test-org profile (`DELETE /v2/files/<id>`; workbooks first), then GET each and check `isArchived`. Materialized `t_mat_*` tables stay in the connection's write schema.
