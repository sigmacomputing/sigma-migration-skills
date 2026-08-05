<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Split from refs/workbook-layout.md (E9.3 phase-scoped refs, 2026-07-27): this file owns the .twb zone/chart-kind mapping tables. Siblings: layout-grid.md (grid + layout XML), chart-patterns.md (multi-series + maps), element-kinds.md (element/control field requirements). -->

# Reading the .twb dashboard layout — zone → Sigma element mapping

> **Read at Phase 1/1d** (dashboard read + `png-read.json`). This is the mapping
> half of the old `workbook-layout.md`; the grid/XML build half is
> `refs/layout-grid.md` (read at Phase 5d).

## Reading the .twb dashboard layout

Run `scripts/parse-twb-layout.rb` on `workbook-content.twb` (from PAT-mode Phase 1)
to get a per-zone JSON. Each chart zone surfaces:

| Field | Source | Use for |
|---|---|---|
| `caption` | zone `name` attr | element name in the Sigma spec |
| `x_pct` / `y_pct` / `w_pct` / `h_pct` | zone position | layout XML `gridColumn` / `gridRow` |
| `chart_kind` | worksheet `<mark class="…">` + Rows/Cols shelves | Sigma element `kind` (bar / line / pie / region-map / point-map / scatter / **pivot-table** / **table** / automatic). Text/Square mark with dims on BOTH shelves ⇒ `pivot-table`; one shelf only ⇒ `table` |
| `rows_shelf` / `cols_shelf` | worksheet `<rows>` / `<cols>` | Structured shelf summary: `{ fields: [...], dim_count, measure_count, has_measure_names }`. Drives the pivot-table vs flat-table decision. `fields[].role` ∈ `dim` / `measure` / `measure-names`; `fields[].guid` resolves to a column caption via `columns_by_guid` in `<dashboard-layout-meta>.json` |
| `is_crosstab` | derived | Convenience boolean — true when `chart_kind` came out as `pivot-table` |
| `sort` | worksheet `<sort>` element | bar/line `xAxis.sort` — **only set the Sigma sort when this is non-null**; if Tableau has no explicit sort, leave the xAxis unsorted so Sigma uses natural order (alphabetical / chronological) |
| `filters` | worksheet `<filter>` elements | Phase 2.5 candidates. Note: `[Action (Foo)]` filters are dashboard cross-filter actions, not value filters — usually skip these |
| `aggregations` | `<column-instance derivation="…">` per column | the agent's truth source for measure aggregation. `Sum` is default for measures; `Avg` / `Min` / `Max` / `Median` / `CountD` are explicit overrides → use the matching Sigma aggregator. `Month-Trunc` / `Year-Trunc` / `Day-Trunc` → wrap the column with `DateTrunc("month", …)` etc. in the chart formula |
| `channels` | worksheet `<encodings>` block | color/size/detail/label channel assignments. A `color` channel with a categorical column = multi-series — use the `If([…] = "Foo", …, Null)` pattern per category. Without this, single-dim bar/line charts get built where Tableau actually had stacked or color-broken-out series |
| `mark_class` | raw `<mark class="…">` | fallback context when `chart_kind: automatic` — agent reads the PNG to decide |
| `geo_role` | column `semantic-role` attr | `regionType` mapping for `region-map` (see "Tableau geographic role → Sigma regionType" in `refs/chart-patterns.md`) |

This is more reliable than inferring chart type from the view CSV.

### Zone `kind` values (zone-level type-v2)

| Zone `kind` | Tableau type-v2 | Map to Sigma element |
|---|---|---|
| `chart` | (no type-v2, has worksheet name) | A chart element — use `chart_kind` field for kind |
| `title` | `title` | `text` element with `body: "## <Dashboard name>"` |
| `text` | `text` | `text` element (free annotation) |
| `filter` | `filter` | `control` element on the master table (list / date-range / etc.) |
| `parameter` | `paramctrl` | `control` of `controlType: "segmented"` or `number` / `slider` |
| `legend` | `color` | Usually automatic in Sigma — drop unless explicitly free-floating |
| `spacer` | `empty` | Leave the grid range empty (no Sigma element) |
| `container` | `layout-basic` / `layout-flow` | Pure layout — only affects grid spans, no Sigma element |
| `dashboard-object` | `dashboard-object` | Generic — usually an `image` element |

### `chart_kind` values (chart-tile level, from `<mark class="...">`)

| `chart_kind` | Tableau mark | Sigma element `kind` |
|---|---|---|
| `bar` | `Bar` | `bar-chart` |
| `line` | `Line` | `line-chart` |
| `area` | `Area` | `area-chart` |
| `pie` | `Pie` | `pie-chart` |
| `scatter` | `Circle` / `Shape` | `scatter-chart` |
| `pivot-table` | `Square` / `Text` **with dims on BOTH Rows AND Cols shelves** (or Measure-Names crosstab) | `pivot-table` (emit `rowsBy` / `columnsBy` / `values`) |
| `table` | `Square` / `Text` with dims on ONE shelf only (flat detail list) | `table` |
| `map-region` | `Multipolygon` / `Polygon` / `Filled` / `Map` / has `<geometry>` | `region-map` |
| `map-point` | (has `Latitude` + `Longitude` columns) | `point-map` |
| `automatic` | `Automatic` | **Verify visually** — Tableau picks the default for the encodings; usually bar but not deterministic |
| `other` | unknown / unhandled | Open the dashboard PNG and decide manually |

> **`automatic` is not a Sigma kind.** When the parser emits `chart_kind: automatic`, fetch the dashboard view image, look at the tile, and pick the right Sigma kind. Tableau's "Automatic" mark adapts to whatever the worksheet's encodings imply — there's no deterministic mapping.

> **Pivot tables vs flat tables — don't downgrade a crosstab.** A Tableau crosstab (mark `Text` or `Square` with dimensions on BOTH Rows AND Cols shelves) MUST become a Sigma `pivot-table`, not a `table`. The parser decides via `dim_count` on each shelf: ≥1 real dim on both ⇒ `chart_kind: pivot-table`. The Measure-Names pattern (one dim shelf + Measure Names placeholder on the other + ≥2 measures on the worksheet) also resolves to `pivot-table`. A flat Text-mark detail list (dims on Rows only, nothing on Cols) stays as `chart_kind: table`. If you see a Tableau crosstab landing in Sigma as a plain table, the regression is upstream — inspect `rows_shelf` / `cols_shelf` on the zone JSON; the `is_crosstab` flag is the canonical signal.

### Percent (Tableau .twb) → Sigma 24-col grid

The parser emits `x_pct`, `y_pct`, `w_pct`, `h_pct` in percent of dashboard.
Convert to Sigma grid spans:

| Tableau % range | Sigma cols (24-col grid) |
|---|---|
| 0 – 25% | `1 / 7` |
| 25 – 50% | `7 / 13` |
| 50 – 75% | `13 / 19` |
| 75 – 100% | `19 / 25` |
| 0 – 33% (thirds) | `1 / 9` |
| 33 – 67% | `9 / 17` |
| 67 – 100% | `17 / 25` |
| 0 – 50% (halves) | `1 / 13` |
| 50 – 100% | `13 / 25` |
| 0 – 100% (full) | `1 / 25` |

For arbitrary percents, the conversion is `c0 = round(x_pct/100 * 24) + 1`,
`c1 = round((x_pct + w_pct)/100 * 24) + 1`. Snap to the table values above when
within ~3% to keep the layout aligned to common grid breakpoints.

Rows: Sigma rows are relative — use the row-sizing guide in
`refs/layout-grid.md` §Row sizing guide
(KPI 8–9 rows, bar chart 12–13 rows, hero line/area 13+ rows). A Tableau
dashboard at 100% height with two stacked rows of charts maps to ~12 Sigma
rows per chart row.

### Tableau dashboard object → Sigma element

| Tableau dashboard object | Sigma equivalent |
|---|---|
| Horizontal / Vertical Container | Use grid spans directly — no Sigma object |
| Blank (spacer) | Leave the grid range empty |
| Image | `image` element with `url` |
| Web Page | `image` with screenshot URL — no live-embed spec equivalent |
| Text annotation | `text` element (markdown `body`) |
| Filter shelf (single filter) | `control` element (`list` / `date-range` / `number-range` etc.) on the master table |
| Parameter control | `control` of `controlType: "segmented"` (radio buttons) or `number` / `slider` |
| Color legend (chart-internal) | Automatic in Sigma — don't recreate |
| Color legend (free-floating) | Optional `text` element + `color` channel on the chart |
| Dashboard title | `text` element with `body: "## <Title>"` |

