<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 1 — discover the Tableau datasource + views/images/calcs -->

## Phase 1 — Discover the Tableau datasource structure

### 1a. Resolve the name the customer gave you

The customer's name may be a **datasource**, a **workbook**, or a **dashboard view inside a workbook**. Tableau Cloud's search and list endpoints partition by content type, so you have to try each before declaring no match.

```
# Workbook by name
mcp__tableau__search-content   terms="<name>"   filter.contentTypes=["workbook"]

# Dashboard view by name — falls back to workbook owner via the view's response
mcp__tableau__list-views       filter="name:eq:<name>"

# Datasource by name
mcp__tableau__search-content   terms="<name>"   filter.contentTypes=["datasource"]
mcp__tableau__list-datasources
```

If the workbook search returns nothing, **try `list-views` next** — the customer almost certainly named a dashboard sheet (e.g. "Orders Overview") that lives inside a differently-named workbook ("Orders Conversion Test"). The view response includes the parent workbook's LUID.

### 1b. Find workbooks sourced from a datasource

```
mcp__tableau__search-content   terms="<datasource name>"   filter.contentTypes=["workbook"]
```

> **Check `hasExtracts` on the search result.** When `hasExtracts: true` on a workbook
> (and especially on its datasource), the Tableau view CSVs reflect a **frozen snapshot**
> of the warehouse — not its current state. Sigma always reads the live warehouse, so the
> absolute counts in Tableau views will diverge from Sigma values, even when the chart
> *structure* (dimensions, aggregations, breakdowns) is identical.

### 1c. Get workbook views

```
mcp__tableau__get-workbook   workbookId="<luid>"
```

Returns the list of views (sheets) with their `id` and `name`. Record all view IDs.

### 1d-cache. Reuse prior conversion artifacts when present (PHASE -1)

Before re-running tableau-discover / fetch-view-data / parse-twb-layout, check
for cached artifacts from a previous run. A prior conversion of the same
workbook typically left views CSVs, view PNGs, the signature, dm-spec,
wb-spec, and the dashboard layout meta under its workdir — re-running
discovery costs ~3 minutes that could be zero.

```bash
ruby scripts/find-prior-cache.rb --name <workbook-slug> --out <WORK>/prior-cache.json
```

The script searches the workdir convention `~/tableau-migration/<name>/` plus
the legacy /tmp cache locations older runs used (audit-run-*, converter-test,
and the bare slug) for: views CSVs, views PNGs, `workbook-content.twb`,
gaps-report, dashboard-layout JSON, get-workbook.json, dm-spec.json /
wb-spec.json (and their ID maps), and the workbook signature. Output is a
JSON map of artifact name → absolute path (or null).

**Use the cached artifacts as-is** when they exist and the workbook hasn't
changed — copy them into your working directory (or symlink) and skip the
corresponding fetch step. The DM/wb specs become your reference for ID
mapping after a re-POST (see `scripts/remap-wb-spec-to-dm-ids.rb`).

### 1d. Retrieve view data and images

Two different fetches with very different cost profiles. **Don't conflate them.**

- **`get-view-data` (CSVs)** — cheap, no VizQL session contention. **Fire all view CSVs in parallel** in a single batch.
- **`get-view-image` (PNGs)** — expensive, hits VizQL session contention. Most 401s come from firing multiple image requests simultaneously (or alongside other view calls).

**What to actually fetch:**

| Need | Source | How |
|---|---|---|
| Dashboard layout (grid, chart positions, title, filter shelf) | The dashboard view's PNG | 1 `get-view-image` call |
| Each chart's dimensions, measures, aggregation | Each sheet's CSV | All sheets in parallel via `get-view-data` |
| Distinct values + date min/max for Phase 2.5 filter detection | Each sheet's CSV | Same parallel batch |
| What an individual sheet looks like in isolation | Sheet PNG | **Skip by default** — fetch one only if you need to disambiguate a tile whose dashboard title is misleading or truncated |

Save each fetched CSV to `<WORK>/views/<viewId>.csv` and parse them with:

```bash
ruby scripts/fetch-view-data.rb <WORK>/views <WORK>/signals.json
```

The output (`signals.json`) contains, per view, a `columns` map with `kind`
(dimension / numeric / date), `distinct_count`, sampled `distinct` values,
numeric ranges, and `aggregation_hints` parsed from CSV headers like
"Sum of Gross Revenue" or "Distinct count of Order Id".

**The reliable fetch pattern:**

1. Fire `get-view-data` calls in parallel batches, but **cap each batch at ~4 concurrent calls**. CSVs survive concurrency far better than image fetches, but 7-way batches have produced 6×401 from VizQL contention in the wild (verified 2026-05-22). For >4 views, split into back-to-back batches of 4 (e.g., 7 views → batch of 4, then batch of 3 in the next message).

   > **This is the single biggest perf win in the whole conversion.** Measured 2026-05-22: 7 view-CSVs sequentially = ~200s (~28s per call, range 19–40s). Same 7 calls fired in two batches of 4+3 = ~60-70s (vs. ~45s for an unrestricted batch when no contention hits — but unrestricted goes catastrophically slow once it does, because every 401 retry happens solo). Skipping parallelization entirely is responsible for ~2.5 min of the historical ~9-min conversion runtime. Send each batch as a single message with N `mcp__tableau__get-view-data` tool-call blocks side-by-side; do NOT send them in separate messages.
2. Fetch **only the dashboard view's PNG** with `get-view-image`. Solo — no other view calls in flight.
3. If a specific tile's dashboard title looks wrong or truncated, fetch that one sheet's PNG solo to disambiguate.

If `get-view-data` returns 401 for a view, retry that view solo (the contention almost always clears within a second or two); if it 401s on the solo retry, skip it.

> **Do not parallel-fire `get-view-image` calls.** Even if the CSVs succeeded in parallel, concurrent image requests still 401 due to VizQL session contention. Images are always solo.

> **🚧 GATE — read the dashboard image AND record what you saw in `png-read.json` before Phase 5.** The CSV headers tell you a chart's dimensions and measures; they do NOT tell you (a) the chart's *kind* (a `Category, Count` CSV could back a bar OR a pie OR a donut), (b) any text annotations (titles, section headers, footnotes), or (c) the filter shelf. Skipping the image read is the most common Phase 5 mistake — you ship a workbook that has the right numbers but is missing tiles the source dashboard actually rendered.
>
> **The orchestrator seeds a DRAFT for you.** `migrate-tableau.rb` auto-generates `png-read.json` from the `.twb` zone tree (chart kinds, titles, text zones, filter shelf) marked `"verified": false`. That draft does **not** satisfy the gate — the `.twb` can't tell bar-vs-pie for `automatic` marks, what text actually rendered, or the real filter shelf. So you **edit** the draft against the image rather than writing from scratch: Read the dashboard PNG, correct the tiles/text/filters, and set `"verified": true`.
>
> This step was prose-only, so it got skipped under load. It is now gated: after Reading the dashboard PNG, write (or verify+correct the seeded) `<workdir>/png-read.json`, then confirm the gate:
>
> ```bash
> ruby scripts/assert-dashboard-read.rb --workdir <WORK>
> ```
>
> `png-read.json` schema (enumerate EVERY zone — chart AND non-chart):
>
> ```json
> {
>   "verified": true,
>   "source_png": "views/<dashboardViewId>.png",
>   "tiles": [
>     { "title": "Revenue by Region", "kind": "bar-chart", "orientation": "horizontal",
>       "measure": "Gross Revenue" },
>     { "title": "Filters", "kind": "control" }
>   ],
>   "text_elements": ["Orders Dashboard"],
>   "filter_shelf": [
>     { "label": "Region", "control_type": "list",
>       "target_tiles": ["Revenue by Region"], "highlight_tiles": [] }
>   ],
>   "point_in_time": { "year_column": "Year", "entity_discriminator": null, "latest_year": 2015 }
> }
> ```
>
> **When a control HIGHLIGHTS tiles** (`highlight_tiles` non-empty → the multi-metric recipe): every highlighted tile MUST carry `measure` = the real metric column it plots (e.g. `"Revenue (current US$)"`, not `"REV"`), and a `point_in_time` block is REQUIRED — `year_column`, `entity_discriminator` (a column null on rollup/aggregate rows so Top-N shows real entities; `null` if none), and `latest_year` (a scalar, or a per-metric map `{"<metric col>": <year>}` when metrics end in different years). The seed pre-fills what the `.twb` can supply and leaves the data-dependent fields for you to confirm; the gate blocks until they're set. Skipping them silently ships 0-value bars / all-year-sum Top-N.
>
> **`point_in_time` extensions (run-2 hardening):**
> - **`rollup_flag`** (optional) — when the rollup marker is a FLAG column (rollup rows marked by VALUE, not NULL: e.g. `'Y'` on rollup rows, `'N'` on entity rows, sometimes NULL on neither — every row non-null, so the IsNull discriminator semantics cannot express it):
>   ```json
>   "rollup_flag": { "column": "<flag col>", "rollup_values": ["Y"], "entity_values": ["N"] }
>   ```
>   `entity_values` non-empty → the measures/SQL keep ONLY those values (strict); otherwise `rollup_values` are excluded and NULL-flag rows are KEPT. Applied in BOTH the snapshot measures (`Sum(If([Year]=<y> And ([flag] = "N"), m, null))`) and the world-by-year / YoY helper SQL (`WHERE "<FLAG>" IN ('N')` / `NOT IN (...) OR IS NULL`). Falls back to `entity_discriminator` IsNull semantics when absent. Malformed blocks fail the Phase 1d gate loudly.
> - **`measure: { "manual_residue": "<calc caption>" }`** — a tile whose measure is a `requires_custom_sql` window/table-calc residue (the STAYS-MANUAL family) declares it this way instead of naming a base column. The build then lists it in `<workdir>/manual-residues.json` (formula + Custom SQL `OVER()` skeleton, `status: "unbuilt"`) and pass 1 BLOCKS (exit 16) until you build the Custom SQL DM element, repoint the tile measure, and set `status: "built"` — never a silent magnitude proxy.
> - **Caption-variant tolerance:** every `point_in_time` field name resolves against the master/landed columns with normalization (upcase + strip non-alphanumerics), so the Tableau UI caption, the extract caption, and the landed physical column name all match. A name that STILL resolves to nothing is dropped LOUDLY with the candidate column list printed — fix the name and re-run; never assume a silently-applied filter.
>
> **`tiles[].kind` PROPAGATES (PR-10):** once `verified: true`, each tile's `kind` **overrides** the builder's shelf inference for every kind (not just bar orientation), and final **gate 21** (exit 28) re-checks the LIVE readback: a built element in a different chart family than the verified kind FAILS, naming the tile + expected/actual family. A **deliberate** substitution (e.g. a Sigma capability gap — non-US region map → bar) is recorded at read time in `"kind_waivers": [{ "tile": "<title>", "reason": "<why>" }]` — ledger-named like `coverage_waivers`, not budget-counted; the builder then keeps the shelf-side kind for that tile.
>
> `"verified": true` is REQUIRED to pass the gate when the file was seeded as a draft (`verified: false`); a hand-written file may omit the field. `kind` must be a valid Sigma element kind (see the "Sigma spec supports:" list below). Set `text_elements` / `filter_shelf` to `[]` only after confirming from the image that the dashboard genuinely has none. Both build paths enforce this file: `build-charts-from-signals.rb` (Phase 5a) **refuses to build without it**, and the orchestrator (`migrate-tableau.rb`) hard-stops **before posting the data model** if it's missing. The Phase 6 gate sequence re-runs `assert-dashboard-read.rb` as a final belt. Genuinely can't read the PNG? Pass `--skip-dashboard-read "<reason>"` and name the waiver in your report.
>
> **Two fields are load-bearing and gate-enforced** (they encode the two most-expensive late-caught fidelity bugs):
> - `tiles[].orientation` — **required** on every `bar-chart`/`combo-chart` (`"horizontal"` | `"vertical"`). A Tableau bar with the **dimension on the Rows shelf** renders **horizontal** (categories down the y-axis); the build defaults to *vertical* when this is unstated. The seed pre-fills it from the shelf roles — confirm it against the image.
> - `filter_shelf[].target_tiles` / `highlight_tiles` — **required**: enumerate the tiles each control **filters** (`target_tiles`) and, separately, the tiles a parameter only **re-colors** (`highlight_tiles`, must NOT be filtered). A control left unscoped silently filters *every* tile on the page — the collapse-to-one-selection bug. A genuinely page-wide filter is fine; it just has to list every tile explicitly. See `refs/control-parity.md`.

**Phase 1d checklist — confirm before moving on:**

- [ ] Opened the dashboard PNG and listed every tile, including non-chart tiles (text, filter shelves, legends, image placeholders)
- [ ] Decided the chart kind of each tile from the image, not just the CSV header (bar / line / pie / donut / kpi / map / **pivot-table** / table)
- [ ] **For any text-mark / crosstab-looking tile, confirmed pivot vs flat:** Tableau dims on BOTH the Rows AND Cols shelves ⇒ Sigma `pivot-table` (with `rowsBy` / `columnsBy` / `values`). Dims on Rows only ⇒ Sigma `table`. `parse-twb-layout.rb` sets `is_crosstab: true` and `chart_kind: pivot-table` automatically when shelves carry dims on both sides — trust that signal over the visual `Square`/`Text` mark which is the same for both.
- [ ] Noted every text element on the dashboard surface (page title, section headers, free-text annotations)
- [ ] Noted every dashboard-level filter or parameter control (date range, list, segmented buttons)

Use the dashboard image to understand:
- How many KPIs are in the header row and what they measure
- Which chart types are used (bar, line, scatter, map, small multiples, **pie / donut**)
- The rough grid layout of each page (columns × rows) — count the rows; this is what your layout XML needs to match
- **Page titles, section headers, and any free-text annotations on the dashboard surface** — these are real content (not metadata) and need to be recreated as `text` elements in the Sigma spec. The page tab name (`page['name']`) is *not* a substitute; it only appears in the tab bar, not on the canvas. If the Tableau dashboard shows a heading like "Orders Dashboard" at the top of the page, add a `text` element with `body: "## Orders Dashboard"` and reserve a row for it in the layout.
- **The filter shelf.** Tableau dashboards usually have visible filter controls (a date range slider, a region list, a state list). These appear as `control` elements in the Sigma workbook — never just as Phase 2.5 element-level filters, because that strips the user-facing control surface.

> **⚠️ INVISIBLE data-source filters (the PNG read CANNOT catch these — #483).** A Tableau **data-source filter** row-scopes an entire datasource and renders **nothing** on any dashboard surface: no quick-filter control, no indicator, nothing a screenshot could ever show. So a workbook can pass every visual-comparison gate and still silently omit a filter that changes every KPI — the field signature is a *suspiciously uniform* discrepancy across multiple unrelated aggregates (distinct counts of companies, offices, agents, websites all reading ~20-25% high at once), not an isolated single-metric miss. Two homes: a `<filter>` on a top-level `<datasource>`/`<extract>` (parsed into `datasource_filters` and auto-applied to every sourcing element), OR — for a virtual connection / published datasource — a database-domain `<filter>` inside a `<shared-view>` (the classic `company_active = true` "active flag"). `parse-twb-layout.rb` tags the shared-view kind in the `-meta.json` `shared_filters` with:
>   - `is_datasource_filter: true` — set when the inner groupfilter carries `user:ui-domain="database"` OR the shared-view is named after a datasource.
>   - `ui_domain: "database"` and `is_active_flag: true` (a single-member boolean like `true`/`false`).
>
> These are **always-on scoping**, not user toggles: apply each as a **workbook-wide default filter on the master element** (not an open `values:[]` control, which widens it back to everything). The **datasource-filter gate** (`scripts/assert-datasource-filters.rb`, run at `migrate-tableau.rb --finalize` and standalone) blocks GREEN until each tagged filter is applied (an `is_active_flag` filter MUST be applied, not merely surfaced as a control). Escape hatch: `--skip-datasource-filters "<reason>"`. Because this class is invisible and consequential, **hand-inspect the `.twb`'s `<shared-views>` / `<datasource>` `<filter>` elements** whenever migrated aggregates read uniformly high.

**Alternative / supplement: parse the `.twb` zone tree.** If you have `workbook-content.twb` from PAT-mode Phase 1, run:

```bash
ruby scripts/parse-twb-layout.rb <WORK>/workbook-content.twb <WORK>/dashboard-layout.json
```

It emits a per-dashboard zone list with `caption`, `view_ref`, `x/y/w/h` in percent, **and `chart_kind` extracted from each worksheet's `<mark>` element + Rows/Cols shelves** (`bar` / `line` / `pie` / `scatter` / `map-region` / `map-point` / `pivot-table` / `table` / `automatic` / `other`). For text-mark worksheets, the parser disambiguates `pivot-table` (dims on both shelves — Tableau crosstab) from flat `table` (dims on one shelf — detail list) via the `rows_shelf` / `cols_shelf` summary; `build-charts-from-signals.rb` honors this and emits `rowsBy` / `columnsBy` / `values` for crosstabs. This is more reliable than inferring chart type from the view CSV — the CSV headers can't distinguish bar-vs-pie or pivot-vs-flat-table. Map every zone in the output to a Sigma element using the tables in `refs/twb-zone-mapping.md` (split from workbook-layout.md).

> **Maps:** if `parse-twb-layout.rb` emits `chart_kind: map-region` or `chart_kind: map-point` for any zone, do NOT build a bar chart. Use Sigma's `region-map` / `point-map` element kinds. The Tableau geographic role (`semantic-role` on the column) translates to Sigma's `regionType` via the table in `refs/chart-patterns.md`. Sigma's region types are US-only except for `country` — non-US state/county/ZIP data falls back to a sorted bar chart or, if lat/long is available, a `point-map`.

> **`chart_kind: automatic`:** Tableau's "Automatic" mark picks a default for the encodings. It usually renders as a bar but is not deterministic. When you see `automatic`, fetch the dashboard PNG and look at that specific tile to decide the Sigma kind.

Sigma spec supports: `bar-chart`, `line-chart`, `area-chart`, `combo-chart`, `scatter-chart`, `kpi-chart`, `pie-chart`, `donut-chart`, `region-map`, `point-map`, `table`, `pivot-table`, `control`, `text`, `image`, `container`.

> **Common kind mistakes — all three are rejected by the API:**
> - `"kpi"` → must be `"kpi-chart"`
> - `"pie"` → must be `"pie-chart"`
> - `"donut"` → must be `"donut-chart"`
>
> The official Sigma example library shows `kpi`, `pie`, and `donut` — all three are wrong. The validator (`scripts/validate-spec.rb`) flags them, but do not rely on it: write the correct kind from the start.

Does **not** support via the spec API: bullet chart, gantt.

**Maps are fully spec-supported.** Use `region-map` for choropleths (US state / county / ZIP / CBSA / country fills) and `point-map` for lat/long bubble or symbol maps. See `refs/chart-patterns.md` "Map elements" for the field shape, the exact set of valid `regionType` values, and the color-channel rules.

**Trellis (small multiples) is supported in Sigma but configured UI-only.** Build the chart with the right dimensions via spec, then trellis it manually post-publish.

> **Log-scale axes round-trip through the spec.** `parse-twb-layout.rb` extracts
> `axis_formats[].scale: "log"` from each worksheet's `<axes>` block, and
> `build-charts-from-signals.rb` emits it as
> `element.yAxis.format.scale = { type: "log", domain: {min, max} }` whenever
> `range_type == "fixed"`. **If you hand-write the workbook spec instead of
> running build-charts-from-signals.rb, you MUST copy this manually** —
> otherwise the chart silently degrades to linear scale (OCT lost the Monthly
> Trend log axis this way on 2026-05-24). Always grep
> `dashboard-layout-meta.json` for `"scale": "log"` before declaring Phase 5
> done.

Control types supported: `list`, `date-range`, `text`, `text-area`, `segmented`, `number`, `number-range`, `slider`, `range-slider`, `top-n`.
See `refs/element-kinds.md` for full control element spec patterns.

### 1e. Discover calculated fields (Metadata API + .twb fallback)

Calculated field formulas are required to translate calc cols into Sigma DM
formula columns. The converter pulls them via the **Tableau Metadata API
(GraphQL)** as the primary path. Metadata API is independent of VDS — it
works even when VDS is disabled on the customer's site. **VDS is NOT used for
calc discovery anymore.**

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/extract-calc-fields.rb \
  --workbook-luid <luid> \
  --out <WORK>/calc-fields.json \
  [--twb <WORK>/workbook-content.twb]   # used if metadata-api fails
```

The script caches its result to `--out` and reuses it (< 1h old) on subsequent
runs unless you pass `--refresh`. Downstream phases read from the cache.

**Fallback order (`--source auto` is the default):**
1. **Metadata API** (`POST /api/metadata/graphql`) — returns formula +
   dependency graph + role + datatype + aggregation + isHidden.
2. **`.twb` XML parse** — returns formula only (no resolved field-name
   dependency graph; `depends_on` is `[]` on this path). LOD formulas are
   still captured because they live in the `<calculation formula='...'/>`
   attribute verbatim.

Both produce the same JSON shape so downstream phases don't care which path
fired. Force a specific source with `--source metadata` or `--source twb`.

Output schema (`calc-fields.json`):

```json
{
  "workbook_luid": "...",
  "workbook_name": "...",
  "source": "metadata-api" | "twb-xml-fallback",
  "generated_at": "2026-05-26T...",
  "n_calcs": 1391,
  "n_lods": 162,
  "n_requires_custom_sql": 174,
  "calcs": [
    {
      "name": "Profit Ratio",
      "datasource": "Orders+",
      "formula": "SUM([Profit]) / SUM([Sales])",
      "role": "MEASURE",
      "data_type": "REAL",
      "aggregation": null,
      "is_hidden": false,
      "is_lod": false,
      "depends_on": ["Profit", "Sales"],
      "requires_custom_sql": false,
      "translation_notes": []
    }
  ]
}
```

Each calc record carries:
- `name`, `formula`, `role`, `data_type`, `aggregation`, `is_hidden` — direct from Tableau
- `is_lod` — `true` for `{FIXED/INCLUDE/EXCLUDE}` expressions
- `depends_on` — referenced field names (metadata-api path only)
- `requires_custom_sql` — `true` ONLY for the **manual window residues**
  (`WINDOW_MEDIAN/PERCENTILE/CORR/COVAR(P)/VAR(P)/STDEVP`, `PREVIOUS_VALUE`,
  `SIZE`, `FIRST`, `LAST`, `RANK_UNIQUE/MODIFIED`) and `{INCLUDE/EXCLUDE}`
  LODs. The mainstream window/table-calc family (`WINDOW_SUM/AVG/MIN/MAX/
  COUNT/STDEV`, `RUNNING_*`, `RANK`/`RANK_DENSE`/`RANK_PERCENTILE`, `INDEX`,
  `LOOKUP`, `TOTAL`) is **AUTO-TRANSLATED** by `build-charts-from-signals.rb`
  into Sigma-NATIVE window math emitted as CHART-element viz formulas on the
  yAxis — single DM base element, zero Custom SQL (WINPROBE-validated
  930/930 cells; full mapping table in `refs/window-functions.md`). The
  functions still CANNOT be Sigma DM calc columns (silent `error` type) and
  the `*Over` family is `Unknown function` everywhere — the chart yAxis is
  the only valid placement.
- `translation_notes` — common Tableau→Sigma gotchas to apply during the
  Phase 3 DM build: `IIF`→`If`, `COUNTD`→`CountDistinct`, IF/ELSEIF chains
  ending in literal need `Coalesce` wraps on nullable inputs (Tableau
  collapses NULL into ELSE; Sigma `If(NULL >= …, …)` returns NULL), the
  per-function window mapping (`refs/window-functions.md`), and the
  Custom-SQL escalation for the manual window residues only.

If the workbook has > 1000 calcs on a single page or the GraphQL response
exceeds ~5 MB, the API may truncate. In that case re-run with
`--source twb`, which parses the cached `.twb` directly and is bounded only
by file size.

Translate the calc fields into the DM (Phase 3) using the original Tableau
formula as the source of truth, NOT the warehouse column the calc happens
to reference. Example: a Tableau "Customer Value Tier" calc that buckets
`Lifetime Revenue` must be re-derived in Sigma from `LIFETIME_REVENUE`, not
pulled from a same-named `LOYALTY_TIER` warehouse column.

### 1e.1. Warehouse-table source rejected? Fall back to Custom SQL

> **Verified 2026-05-24** against a live Sigma org during audit-run-1.
> Two agents (Superstore, NASA) hit `Source not found: warehouse table
> 'DEMO_DB.PUBLIC.XXX' on connection 'YYY'` POSTing a DM element whose
> `source.kind: "warehouse-table"` pointed at a table that physically existed
> in the warehouse and was queryable via `mcp__sigma-mcp-v2__query`. This is
> a **Sigma static-catalog visibility** issue: the `warehouse-table` source
> path requires the table to be indexed in Sigma's internal catalog, which
> does NOT auto-refresh after every warehouse-side landing (VDS write, dbt
> run, manual CREATE TABLE).
>
> **Force a catalog refresh via the API first** — this works (verified
> 2026-07-07: 48/48 freshly-landed tables became visible immediately, no UI
> touch needed):
>
> ```bash
> curl -sX POST -H "Authorization: Bearer $SIGMA_API_TOKEN" \
>   -H "Content-Type: application/json" \
>   "$SIGMA_BASE_URL/v2/connections/<connectionId>/sync" \
>   -d '{"path": ["DB", "SCHEMA", "TABLE"]}'
> ```
>
> One call per table (`path` is the 3-part `[db, schema, table]` array).
> After the sync, retry `discover-columns.rb` / the `warehouse-table` POST.
> Only fall back to Custom SQL (below) when the sync-then-retry still 404s.
> (Older versions of this skill claimed no public API could refresh the
> catalog — that claim is stale; do not route to the UI's "Refresh schema"
> button or straight to Custom SQL without trying the sync endpoint.)

The fallback is to source the same table via Custom SQL:

```json
{
  "id": "el-orders",
  "kind": "table",
  "name": "Orders",
  "source": {
    "kind": "sql",
    "connectionId": "<connection-id>",
    "statement": "SELECT * FROM DEMO_DB.PUBLIC.NASA_GISS_LOTI"
  },
  "columns": [
    { "id": "c-year", "name": "Year", "formula": "[Custom SQL/YEAR]" },
    { "id": "c-temp", "name": "Temp Anomaly", "formula": "[Custom SQL/TEMP_ANOMALY]" }
  ]
}
```

This works because Custom SQL bypasses the catalog entirely — the connection
just executes the statement and Sigma reads whatever columns come back. The
trade-offs vs `warehouse-table` are:

> **Don't guess column names.** Sigma's spec API does not expose the columns
> of a SQL element until you've already declared them in the spec, which is a
> chicken-and-egg problem during the fallback. Run
> `scripts/probe-custom-sql-columns.rb` to resolve real column names + types
> via an INFORMATION_SCHEMA query through a one-shot probe workbook (auto-
> created, exported as CSV, deleted; ~6s end-to-end):
>
> ```bash
> ruby scripts/probe-custom-sql-columns.rb \
>   --connection-id <id> \
>   --table-path DB.SCHEMA.TABLE \
>   [--dialect snowflake|postgres|bigquery|redshift|sqlserver] \
>   --out <WORK>/probe-columns.json
> ```
>
> Validated 2026-05-24 against DEMO_DB.PUBLIC.SUPERSTORE_ORDERS — 19 columns
> resolved in 7s. **Saves ~120s on every Custom SQL fallback** vs.
> POST-fail-cleanup-retrying on column-name permutations (CUSTOMER_ID vs
> CUST_ID vs ID vs RECORD_ID…). Don't skip this step.


- column-level lineage is hidden (Sigma sees one opaque SQL statement)
- per-column governance / CLS doesn't auto-apply
- the warehouse-side query optimizer treats it as a sub-select

For a customer-facing conversion these trade-offs are acceptable; for a
"production" DM build, run `POST /v2/connections/{id}/sync` for the table
(shape above) and retry with `warehouse-table`.

### 1f. Extract Custom SQL (PAT mode)

If the source workbook uses Custom SQL — either as the entire datasource or
mixed alongside warehouse tables — run:

```bash
ruby scripts/extract-custom-sql.rb \
  --workbook-luid <wb-luid> \
  --twb <WORK>/workbook-content.twb \
  --out <WORK>/custom-sql.json
```

The script tries two paths:
1. **Metadata GraphQL API** for `CustomSQLTable` nodes downstream of the workbook (works for both published-datasource Custom SQL and embedded Custom SQL).
2. **`.twb` XML fallback** for embedded `<relation type='text'>` blocks (covers cases the Metadata API hasn't crawled yet).

Output is a JSON array, one entry per Custom SQL block, with `query` (the raw
SQL text), `connectionType`, and downstream workbook/datasource pointers. Treat
a non-empty result as an inventory to analyze, not a mandate to copy opaque SQL.
In Phase 3, prefer warehouse-table elements plus relationships, filters, and
calc columns when they reproduce every query semantic and the resulting grain;
record a passing equivalence probe in `semantic-edits.json`. Preserve the query
as `kind: "sql"` when decomposition would change semantics or equivalence cannot
be proved. Never drop joins, predicates, aggregation, unions, CTEs, or window
logic merely to obtain a tables-only model.

> **MCP-mode caveat.** This script needs PAT-mode env vars (`TABLEAU_AUTH_TOKEN`, etc.). If you only have MCP available, you cannot pull custom SQL — that's a real gap; switch to PAT mode for any workbook the customer says uses custom SQL.

---


---

## Phase 1a — numeric-URL resolver gate (relocated from SKILL.md — PR-15 diet)

**🚧 GATE — Phase 1a: ANY numeric Tableau URL (project *or* workbook) MUST go
through the resolver.** When the user hands you a Tableau URL like
`.../#/site/<site>/projects/1234567` **or**
`.../#/site/<site>/workbooks/4242001/views`, that number is a **vizportal URL
id** the REST API cannot resolve (no REST endpoint carries it). Run
`ruby scripts/resolve-project.rb --url "<url>"` **before anything else**.
Exit 0 → migrate exactly the workbook(s) it lists (a workbook URL resolves
straight to `{workbook_luid, name, project_luid, project_name}` — no
hand-searching). **Exit 2 → STOP and ask the user, presenting the printed
candidate list — do not proceed.** Guessing from name or recency is a **gate
violation**: a wrong guess silently points the ENTIRE run (discovery, DM,
workbook, parity) at the wrong content — one real field session burned 6
hours migrating the wrong project, another burned 20 minutes hand-hunting a
workbook it had a DIRECT link to. Query shape + why REST can't do it:
`refs/tableau-rest.md`.

**`/views/<slug>/<view>` share links (the MOST COMMON shape) are handled by the
orchestrator directly** — paste the whole URL as `--workbook "<url>"` and
`migrate-tableau.rb` resolves the workbook via the REST `contentUrl:eq:` filter
(`Tableau.find_workbook_by_content_url`). Do NOT hand the slug to
`--workbook <name>`: a workbook's display Name routinely diverges from its
contentUrl slug ("High Risk Bets" vs `HighRiskBets`), so the name lookup
misses (three independent field runs each rediscovered this the hard way).
