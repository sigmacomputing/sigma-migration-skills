<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 2 — warehouse columns + Phase 2.5 view filters + aggregation semantics (PR-7 lint) -->

## Phase 2 — Discover actual warehouse column names

> **This step is mandatory. Do not skip it or infer column names from Tableau.**
> **Skip Phase 2 entirely if Phase 1.5 recommended a DM you reused.**

Tableau display names ("Sub-Category", "Country/Region") are NOT the same as
warehouse column names ("SUB_CATEGORY", "COUNTRY_REGION" in Snowflake;
`sub_category` / `country_region` in lowercase-by-default Postgres / Databricks;
`subCategory` / `countryRegion` in case-preserved BigQuery). Using the
display name as the warehouse name produces "dependency not found" errors at
publish time.

**Warehouse-agnostic discovery — use Sigma's REST API or MCP**, NOT the
warehouse-specific CLI (`snow sql DESCRIBE TABLE`, `bq show`, `databricks
catalogs`, etc.):

```bash
# 1. Find the connection ID (any warehouse — Snowflake / BigQuery / Databricks / etc.)
curl -sH "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections" | jq '.entries[] | {id, name, type}'

# 2. Find the table inodeId (Sigma indexes warehouse tables in its catalog)
curl -sH "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/<connectionId>/tables" | jq '.entries[] | {inodeId, path}'

# 3. List columns — PER feedback_sigma_columns_api_endpoint, the endpoint is
#    /v2/connections/tables/<inodeId>/columns (no connectionId in the path).
curl -sH "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/tables/<inodeId>/columns" | jq '.entries[] | {name, type}'
```

Or the equivalent MCP tools (preferred when available):
- `mcp__sigma-mcp-v2__describe` on a connection table → returns column names + types
- `mcp__sigma-mcp-v2__search` with `entityTypes=["table"]` to find inodeIds by name

The provided helper script wraps the REST call with parallel fan-out and the
"response key is `entries`, not `columns`" gotcha pre-handled. It works
against any Sigma connection regardless of underlying warehouse:

```bash
eval "$(scripts/get-token.sh)" && \
ruby scripts/discover-warehouse-columns.rb <WORK>/columns \
  <inodeId1> <inodeId2> ...
```

Convenience: for a single table by `<db>.<schema>.<table>` path (instead of
inodeId), use `discover-columns.rb` — it does the inode lookup automatically
and emits a JSON column list:

```bash
ruby scripts/discover-columns.rb --connection-id <id> \
  --table-path DEMO_DB.PUBLIC.ORDERS --out <WORK>/orders-cols.json
# (or any warehouse path: my_project.my_dataset.orders, main.public.orders, etc.)
```

If `discover-columns.rb` returns 404 — meaning the table physically exists in
the warehouse but is not in Sigma's static catalog — **sync the catalog via
the API, then retry** (verified 2026-07-07, 48/48 tables):

```bash
curl -sX POST -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  "$SIGMA_BASE_URL/v2/connections/<connectionId>/sync" \
  -d '{"path": ["DB", "SCHEMA", "TABLE"]}'
```

One call per table; `path` is the 3-part `[db, schema, table]` array. If the
retry still 404s, fall back to sourcing via Custom SQL (see Phase 1e.1
"Warehouse-table source rejected? Fall back to Custom SQL"). Do not skip
straight to Custom SQL — the sync endpoint works and preserves
`warehouse-table` lineage/governance.

The script:
- runs all column-fetches in parallel,
- handles the "response key is `entries`, not `columns`" gotcha,
- writes one `<inodeId>.json` per table into the output dir.

The friendly names returned are the **exact** values to use in DM element formulas: `[TABLE_NAME/Column Name]`.

Find table inodeIds via Sigma search:

```
mcp__sigma-mcp-v2__search   query="<table name>"   entityTypes=["table"]
```

---

## Phase 2.5 — Detect view-level filters (mandatory)

> **Two sources, in order of authority:**
> 1. **`parse-twb-layout.rb`'s `*-meta.json`** — `shared_filters` (workbook-level filter shelf) and per-chart `zone.filters` (worksheet-level) carry resolved column captions, member-value lists, and an `is_action` flag distinguishing value filters from cross-chart action filters. `build-charts-from-signals.rb --auto-controls` translates list / relative-date / number-range shared filters into Sigma controls per page automatically.
> 2. **View CSV ↔ warehouse diff** (legacy fallback) — for `.twbx`-less workbooks or when the agent suspects the parser missed a filter, compare distinct values in the view CSV against the warehouse.

The diff method is still mandatory for any workbook where you don't have the `.twb` content. When you DO have it, trust the parser's filter output first — it carries member values that the CSV can't reveal.

For every dimension column on every view, compare:

| Source                         | Query                                              |
|--------------------------------|----------------------------------------------------|
| **View CSV signals** (Phase 1d) | Read `signals.json` — `columns.<col>.distinct`, `numeric_range`, `kind` |
| **Warehouse** (after Phase 2)  | `SELECT DISTINCT <col>` / `SELECT MIN, MAX <date>` via `mcp__sigma-mcp-v2__query` (`type: "connection"` with the table inodeId) |

Any value present in the warehouse but missing from the CSV implies a filter on that column.

```sql
SELECT MIN("DATE") AS min_date, MAX("DATE") AS max_date,
       COUNT(DISTINCT DATE_TRUNC('quarter', "DATE")) AS qtr_count
FROM "connection"."<table-inodeId>"
```

### Common patterns

| View CSV symptom | Likely Tableau filter | Sigma translation |
|---|---|---|
| Only some values of a categorical column appear | "Keep only" / dimension filter | `list` control with `mode: "include"`, or element-level filter |
| Date min/max is narrower than warehouse | Date / relative-date filter | `date-range` control — `mode: "current"` + `unit: "year"\|"quarter"\|...` for relative; `mode: "between"` with explicit `startDate`/`endDate` for fixed |
| Numeric column is bounded | Range filter | `number-range` or `range-slider` control, or element-level filter |
| Only top N items by some measure | Top-N filter | `top-n` control or element-level `top-n` filter (see `refs/element-kinds.md`) |

### Where to apply the filter

Prefer a **workbook-level control filtering the master table** — every chart that sources from master inherits the filter, matching how a Tableau dashboard filter works. Use **element-level filters** only when the filter is fixed and shouldn't be user-adjustable (a hard-coded slice).

```json
"filters": [{"source": {"kind": "table", "elementId": "master"}, "columnId": "<master-col-id>"}]
```

> **A relative-date filter that "rolls forward" in Tableau** ("this year", "last 30 days", "year to date") must be translated as a relative `date-range` control (`mode: "current"`, `unit: ...`) — not a fixed start/end date. Hard-coding `startDate`/`endDate` freezes the filter to today's date and breaks tomorrow.

> **Phase 6 will not catch a missed filter on its own.** Data parity in Phase 6 compares Sigma rows to Tableau rows for the dimensions you query — if your Sigma chart includes extra rows the CSV never had, the comparison only flags missing rows from Tableau, not extra rows in Sigma. Always sanity-check distinct values and date ranges side-by-side before declaring parity.

> **Element-level filters DO work on viz elements — verify them the right way.** A boolean
> `filters: [{id, columnId, kind:"list", mode:"include", values:[true]}]` (`id` required — the API 400s without it) on a `bar-chart` /
> `kpi-chart` is enforced in the render AND round-trips intact on `GET /v2/workbooks/{id}/spec`
> (live-verified 2026-06-29 on a live Sigma org: a not-null filter cut 731→397 on both kinds,
> confirmed via element CSV export and rendered PNG). So if a filter *looks* like it "doesn't
> work," do NOT assume the API silently dropped it — the cause is almost always a `columnId`
> that doesn't resolve to a real column on that element, which `validate-spec.rb` / `control_lint.rb`
> catch on the gated path. **Validate filter behavior via the element's CSV export or a rendered
> PNG — NOT via a base-grain `mcp__sigma-mcp-v2__query` against the connection**, which reads the
> underlying table and is blind to element-level `filters`, `groupings`, and sort (use MCP only
> for raw-data spot-checks and explicit-`GROUP BY` aggregation checks). A helper-table element
> carrying the filter (chart sources the helper) also works, but is NOT required for simple
> boolean/not-null slices — reserve it for the LOD/grain cases above.

---

## Aggregation semantics — pre-aggregated columns (mandatory lint, gate 19)

**Additive aggregation over a pre-aggregated column compiles clean and ships
wrong-looking-right numbers.** The live twin: a KPI printed **103.3%**
"% entities with value" because `SUM()` was applied to a `{FIXED day:
COUNTD(...)}` column at a coarser grain — every entity appearing on more than
one day is double-counted. The formula validates, the spec POSTs, parity
buckets can pass; three live runs proved nothing flagged it. Corpus twin:
`corpus/tableau/preagg-kpi`.

The build seam runs `scripts/lib/agg_semantics_lint.rb` (standalone:
`ruby scripts/audit-agg-semantics.rb --workdir <W>`) right after the LOD
audit, writing `<W>/agg-semantics.json` — an EMPTY ledger is still written as
gate evidence. One entry per hit:

| Class | Fires when |
|---|---|
| `additive-over-preagg` | `Sum()`/`Avg()` over a column that is itself an LOD pre-aggregate (`{FIXED…}` output, cross-referenced against the LOD census) — in a source calc OR an emitted dm-spec/wb-spec formula; also when a `landing-manifest.json` entry declares a `grain` and a tile additively aggregates that table while grouping OUTSIDE the grain |
| `countd-as-sum` | `COUNTD` translated to / consumed via `Sum()` anywhere — a distinct count is not additive |
| `preagg-ratio` | a ratio formula (KPI numerator/denominator) consuming a pre-aggregate-NAMED column (`DISTINCT_*`, `*_PCT`, `*_RATE`, `AVG_*`, `*_COUNT` — word-token match, so "Daily Distinct Buyers" counts) |

Severity is **WARN-with-required-resolution**: every hit blocks GREEN
(`assert-phase6-ran.rb` gate 19, exit 26 — no skip flag) until the run records
ONE of:

- `--how reaggregated` — the consumer was rebuilt at the correct grain
  (grouped helper re-aggregation, `Max()` of the pre-aggregate at its own
  grain, `CountDistinct` over the base column). Name the element/column.
- `--how n/a` — the hit does not apply (e.g. the tile's group-by IS the
  pre-aggregate's grain, so the sum is exact). **First-class path — never
  fabricate metadata to satisfy the lint.**
- `--how faithful-to-source` — the SOURCE workbook itself mixes grains and the
  migration reproduces it faithfully; the reason documents the hazard for the
  migration report (the 103.3%-KPI twin case).

```bash
ruby scripts/audit-agg-semantics.rb --workdir <W> \
  --resolve <i> --how <reaggregated|n/a|faithful-to-source> --reason "<evidence>"
```

Re-derivation preserves recorded resolutions. Belt-and-braces in the gate: a
missing `agg-semantics.json` on a workdir with pre-aggregate evidence (a
non-empty `lod-audit.json`, or a `COUNTD` calc in `calc-fields.json`) fails —
pre-aggregates exist and nothing linted their consumption.

---


---

## Shared relative-date filters → native ROLLING modes (relocated from SKILL.md — PR-15 diet)

- **Shared relative-date filters** — `build-charts-from-signals.rb` now maps
  these to Sigma's native ROLLING date-range modes directly:
  `this <period>` → `mode:current`, `last N <period>` → `mode:last`
  (`value:N`, `unit`, `includeToday`), `next N` → `mode:next`. They roll with the
  clock — no frozen dates and no manual master-boolean workaround. Only a
  shifted/spanning window (one that doesn't anchor to now) falls back to a frozen
  `mode:between`, flagged `FROZEN — re-run to refresh`. If a shared relative-date
  filter still shows a uniform parity DIVERGE (every Sigma value too big),
  confirm the date key survived into the DM and the control's `filters` target
  wiring reached the chart's source. (Rolling emission verified 2026-07-01;
  shapes per `sigma-authoring` controls.md, live 2026-06-15.)
