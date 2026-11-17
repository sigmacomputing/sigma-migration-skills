# Lightdash chart → Sigma element map

Source of truth: `scripts/lib/lightdash_chart_map.rb` (`LightdashChartMap.classify`).
The builder (`build-lightdash-workbook.rb`) turns each Lightdash `chartConfig`
into one Sigma element. Anything it cannot build becomes a **placeholder text
element** naming the original chart plus a degradation-ledger gap
(`chart-gaps.json`); a placeholder is a parity `SKIP(gap)`, never a pass.

| Lightdash `chartConfig` | Sigma element |
|---|---|
| `cartesian`, every series `bar` | `bar-chart` (`stacking: stacked` when any series has `stack`) |
| `cartesian`, `layout.flipAxes: true` (bar) | `bar-chart`, `orientation: horizontal` |
| `cartesian`, every series `line` | `line-chart` |
| `cartesian`, line series with `areaStyle` | `area-chart` (stacking as for bar) |
| `cartesian`, every series `scatter` | `scatter-chart` (x must be a dimension; a measure on x is a gap) |
| `cartesian`, mixed series types | `combo-chart` (`yAxis.columnIds` carry `{columnId, type}`; `yAxisIndex: 1` series also on `yAxis2`) |
| `big_number` | `kpi-chart` (the DM metric aggregate is inlined: preflight K1 rejects a bare-ref value column) |
| `table` | `table`, grouped by the dimensions; with `pivotDimensions` → `pivot-table` |
| `pie` | `pie-chart`; `isDonut: true` → `donut-chart` |
| `funnel` | `funnel-chart` (stage = first dimension, series = the measure) |
| `treemap`, `gauge`, `map`, `sankey`, `custom` (Vega), `data_app_viz` | not migrated: placeholder + gap |
| `contentType: sql_chart` (no `metricQuery`), unknown types | not migrated: placeholder + gap |

`cartesian pivotDimensions`: the first pivot dimension becomes the `color`
(category) channel. ECharts styling (colors, axis titles, labels, legends,
smoothing) is ignored and recorded once per workbook as a **note** (chart-gaps.json `notes`; it never blocks GREEN).
Markdown tiles become `text` elements. Lossy-but-built mappings return notes
that the builder records as `quality-waiver` ledger entries.

## Workbook shape

- A hidden **Data** page holds the master table `tbl-master` ("Lightdash Data"),
  sourced from the DM explore element, with a passthrough column
  `[<DM element name>/<Column>]` for every field the dashboard uses.
- Charts and KPIs source `{kind: table, elementId: tbl-master}`.
- A control limited by `tileTargets` gets a hidden base table `tbl-base-N`
  (sourced from the master); the targeted charts source through it and the
  control targets only that base table. Sigma rejects control targets that are
  charts or KPIs, so **controls target tables only**.
- Dimension columns are `[<source table>/<Column>]`; DM metrics are
  `[Metrics/<name>]` (resolved through chart → base → master → DM; unverified live).

## Dashboards

- Tabs → pages in tab `order` (no tabs → one page named after the dashboard).
- Grid: Lightdash tiles use a 36-column grid (`LIGHTDASH_GRID_COLS`, one
  constant; unverified upstream) scaled to Sigma's 24 with a single rounding
  function so neighbours share boundaries. Rows 1:1, raised to the layout-lint
  minimum, pushed down past overlaps. Controls strip (≤ 4 per row) on page 1.
  Layout XML is attached **last**.
- Dashboard filters: list (equals / notEquals), `date-range`
  (greaterThan → after, lessThan → before, inBetween → between) and
  `number-range` controls (range shapes unverified live). Disabled filters keep
  an empty default. Metric / table-calc (HAVING) filters, `inThePast…` and text
  operators are ledger gaps.
- `tileTargets` follows Lightdash semantics: tiles not listed are filtered by
  default, `false` excludes a tile, a `{fieldId}` entry targets it. A filter that
  excludes tiles gets a note (semantics not verified on a live instance; not a ledger entry). Express "only these tiles" as `false` for the others.
- Controls live on page 1 only (they are workbook-wide, so page-2 charts are
  still filtered).

## Chart-level query features

- Chart `metricQuery.filters`: equals / in / notEquals / notIn → list;
  greaterThan / lessThan / inBetween → number-range / date-range. OR groups, a
  second filter on one column, isNull / notNull, metric filters → scope-cut gap.
- `limit` → a top-N filter on the first sort column **only** when it is a
  descending metric sort (ascending = `quality-waiver`). Dimension-sorted at the
  Lightdash default 500 is a warning only; below 500 a `quality-waiver`. Top-N on
  bar/line charts is unverified live.
- Table calculations and custom metrics: see `refs/table-calcs.md`.

## Parity interface: `workbook-map.json`

Keyed by chart slug. Per entry: `element_id` (the visible chart),
`source_element_id` (`tbl-master` / `tbl-base-N`), `page_id`, `kind`, `fields`,
`columns` (fieldId → `{id, name}`), `limit`, `sorts`, `placeholder` (when
gapped) and `applied_filters` (`[{fieldId, operator, values}]`: dashboard
filters Sigma applies as **defaulted controls**; the oracle merges these into
the Lightdash query so both sides see the same filtered data).
