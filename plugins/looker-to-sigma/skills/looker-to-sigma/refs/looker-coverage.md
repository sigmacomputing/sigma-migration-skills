# Looker → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-looker-coverage-matrix.py --catalogs refs/catalogs --skill looker --out refs/looker-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing ([bead]).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 52 documented constructs across 5 dimensions; 9 live-verified.

## Visualization / chart kind

_Looker dashboard element visualization `type` -> Sigma workbook element kind. The single source of truth for build_workbook.py's tile classifier. Unmapped vis types warn+skip (a merged-results tile with no vis type is the one documented exception, defaulted in code with a warning)._

Authoritative source: <https://cloud.google.com/looker/docs/reference/param-lookml-dashboard>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `single_value` | [doc](https://cloud.google.com/looker/docs/single-value) | `kpi-chart` | ✅ y · 2026-07-13 | warn+skip |
| | | | | _Looker single_value tile -> Sigma KPI._ |
| `looker_column` | [doc](https://cloud.google.com/looker/docs/column-chart-options) | `bar-chart` | ✅ y · 2026-07-13 | warn+skip |
| | | | | _Vertical bars. Sigma bar-chart with NO orientation key = vertical._ |
| `looker_bar` | [doc](https://cloud.google.com/looker/docs/bar-chart-options) | `bar-chart` | 🟡 n | warn+skip |
| | | | | _Horizontal bars. build_workbook adds orientation:horizontal downstream (see test_grid_fidelity.py)._ |
| `looker_area` | [doc](https://cloud.google.com/looker/docs/area-chart-options) | `area-chart` | 🟡 n | warn+skip |
| `looker_line` | [doc](https://cloud.google.com/looker/docs/line-chart-options) | `line-chart` | 🟡 n | warn+skip |
| `looker_pie` | [doc](https://cloud.google.com/looker/docs/pie-chart-and-donut-chart-options) | `pie-chart` | ✅ y · 2026-07-13 | warn+skip |
| `looker_donut_multiples` | [doc](https://cloud.google.com/looker/docs/pie-chart-and-donut-chart-options) | `donut-chart` | 🟡 n | warn+skip |
| | | | | _Looker donut small-multiples has no Sigma equivalent -> single donut-chart; build_workbook warns about the lost small-multiples facet._ |
| `table` | [doc](https://cloud.google.com/looker/docs/table-chart-options) | `table` | ✅ y · 2026-07-13 | warn+skip |
| `looker_grid` | [doc](https://cloud.google.com/looker/docs/table-chart-options) | `table` | 🟡 n | warn+skip |
| | | | | _Looker grid (data table) -> Sigma table._ |
| `looker_scatter` | [doc](https://cloud.google.com/looker/docs/scatterplot-options) | `scatter-chart` | 🟡 n | warn+skip |
| `looker_waterfall` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard-waterfall-chart) | `waterfall-chart` | 🟡 n | warn+skip |
| | | | | _Native only for the documented dimension + measure form. Measure-only waterfalls remain a loud converter gap._ |
| `looker_boxplot` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard-boxplot-chart) | — (no Sigma equivalent) | 🟡 n | warn+skip |
| | | | | _Do not emit box-chart until it is published in the released workbook schema and round-trip verified._ |

## Number format

_LookML `value_format_name` (built-in named format) -> Sigma column number format (D3 format string in {kind:number, formatString}). Custom `value_format` Excel/TO_CHAR masks are NOT in this table — they are parsed by cited predicates custom_value_format_to_d3() / snowflake_mask_to_format(). An unrecognized named format falls through to the custom-mask parser, then to a loud warn (never a name-substring currency guess)._

Authoritative source: <https://cloud.google.com/looker/docs/reference/param-field-value-format-name>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `usd` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `$,.2f` | ✅ y · 2026-07-13 | warn+keep-value |
| | | | | _USD, 2 decimals, thousands sep._ |
| `usd_0` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `$,.0f` | 🟡 n | warn+keep-value |
| | | | | _USD, 0 decimals._ |
| `gbp` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `£,.2f` | 🟡 n | warn+keep-value |
| `gbp_0` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `£,.0f` | 🟡 n | warn+keep-value |
| `eur` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `€,.2f` | 🟡 n | warn+keep-value |
| `eur_0` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `€,.0f` | 🟡 n | warn+keep-value |
| `percent_0` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.0%` | 🟡 n | warn+keep-value |
| | | | | _LookML percent_N assumes the value is a ratio (0-1); Sigma % format multiplies by 100 the same way._ |
| `percent_1` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.1%` | 🟡 n | warn+keep-value |
| `percent_2` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.2%` | 🟡 n | warn+keep-value |
| `percent_3` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.3%` | 🟡 n | warn+keep-value |
| `percent_4` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.4%` | 🟡 n | warn+keep-value |
| `decimal_0` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.0f` | 🟡 n | warn+keep-value |
| `decimal_1` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.1f` | 🟡 n | warn+keep-value |
| `decimal_2` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.2f` | 🟡 n | warn+keep-value |
| `decimal_3` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.3f` | 🟡 n | warn+keep-value |
| `decimal_4` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `,.4f` | 🟡 n | warn+keep-value |
| `id` | [doc](https://cloud.google.com/looker/docs/reference/param-field-value-format-name#default_value_formats) | `d` | 🟡 n | warn+keep-value |
| | | | | _Plain integer, no thousands separator (D3 'd')._ |

## Aggregation

_LookML measure `type` -> Sigma aggregate function. `sigma` is the plain aggregate; `sigma_if` is the filtered variant used when the measure carries a `filters:` sub-block (Looker filtered measures). Compositional measure types (yesno, number/expression, running/period-over-period, percentile, list) are NOT flat-mappable and stay as cited predicates in formula_for(); an unmapped scalar type warns+skips. count / count_distinct are resolved compositionally in formula_for (a plain count on a JOINED view becomes CountDistinct on that view's PK), so their plain `sigma` here documents the canonical target rather than driving the fallback branch._

Authoritative source: <https://cloud.google.com/looker/docs/reference/param-measure-types>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `sum` | [doc](https://cloud.google.com/looker/docs/reference/param-measure-types#sum) | `Sum` if→`SumIf` | ✅ y · 2026-07-13 | warn+skip |
| `average` | [doc](https://cloud.google.com/looker/docs/reference/param-measure-types#average) | `Avg` if→`AvgIf` | 🟡 n | warn+skip |
| `min` | [doc](https://cloud.google.com/looker/docs/reference/param-measure-types#min) | `Min` if→`MinIf` | 🟡 n | warn+skip |
| `max` | [doc](https://cloud.google.com/looker/docs/reference/param-measure-types#max) | `Max` if→`MaxIf` | 🟡 n | warn+skip |
| `median` | [doc](https://cloud.google.com/looker/docs/reference/param-measure-types#median) | `Median` | 🟡 n | warn+skip |
| | | | | _Sigma has no MedianIf; a filtered median warns (filter dropped)._ |
| `count` | [doc](https://cloud.google.com/looker/docs/reference/param-measure-types#count) | `Count()` if→`CountIf` | 🟡 n | warn+skip |
| | | | | _Resolved in formula_for: a plain count on a JOINED view -> CountDistinct on that view's primary_key (counts entities, not fact rows). Plain `sigma` here is the canonical fact-grain target._ |
| `count_distinct` | [doc](https://cloud.google.com/looker/docs/reference/param-measure-types#count_distinct) | `CountDistinct` if→`CountDistinctIf` | ✅ y · 2026-07-13 | warn+skip |

## Control / filter

_Looker dashboard filter `type` -> Sigma control kind. Only the date case is special (a Sigma `list` control bound to a datetime column is silently dropped on POST, so a date filter MUST become a date-range control). Everything else is a categorical `list` control — the DOCUMENTED default, not a silent guess. An override applies in code: a filter bound to a date/time dimension_group becomes date-range regardless of the Looker filter `type` (compositional, cited)._

Authoritative source: <https://cloud.google.com/looker/docs/reference/param-lookml-dashboard#filters>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `date_filter` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard#type_for_filters) | `date-range` | ✅ y · 2026-07-13 | n/a |
| | | | | _A datetime-bound list control comes back with empty filters (dead control) — must be a date control._ |
| `field_filter` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard#type_for_filters) | `list` | ✅ y · 2026-07-13 | n/a |
| | | | | _Categorical list control (documented default). A field_filter bound to a date dimension_group is overridden to date-range in code._ |
| `string_filter` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard#type_for_filters) | `list` | 🟡 n | n/a |

## Workbook-as-code release feature

_Audit of released Sigma workbook-as-code features against documented Looker dashboard semantics. The builder emits a feature only when the normalized dashboard contract carries equivalent source intent; unrelated release capabilities stay explicit gaps._

Authoritative source: <https://cloud.google.com/looker/docs/reference/param-lookml-dashboard>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `looker-waterfall` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard-waterfall-chart) | `waterfall-chart` | 🟡 n | warn+skip |
| | | | | _A one-dimension, one-or-more-measure Looker waterfall maps to native x/y axes, cumulative sum shape, a hidden zero start, and visible connector lines. The documented measure-only form remains a loud gap because it has no row category field._ |
| `chart-legend-formatting` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard-line-chart) | `element.legend` | 🟡 n | preserve Sigma default |
| | | | | _hide_legend and left/right legend_position map directly. Looker's center alignment is retained as a warning because it is not a Sigma legend position._ |
| `standalone-legend-control` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard-line-chart) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Looker legend options are chart display encoding, not a standalone filter artifact. Preserve element.legend and do not invent a controlType:legend element._ |
| `single-value-progress-comparison` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard-single-value-chart) | `progress` | 🟡 n | warn+retain-kpi |
| | | | | _comparison_type progress/progress_percentage maps to native progress only when the query contains both a value and comparison measure; otherwise the KPI remains and the missing target is loud._ |
| `dashboard-tabs` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard#tabs) | `metadata pages + navigation:auto` | 🟡 n | warn+single-page |
| | | | | _Looker 26.4 tabs and element tab_name become metadata-only pages with authoritative Page layout blocks. Each content page gets native auto navigation and workbook page tabs are shown._ |
| `field-drill-fields` | [doc](https://cloud.google.com/looker/docs/reference/param-field-drill-fields) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Looker drill_fields define field-level drill destinations. The released Sigma drill control has no documented authorable source/category/target binding, so the converter does not emit dead drill UI._ |
| `tab-navigation-button` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard-button) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Looker rich_content_json buttons may navigate to a tab or external URL. Until the parser resolves and validates that destination, native navigation:auto covers tabs and button intent is flagged rather than guessed._ |
| `dashboard-filter-sidebar` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard#filters_location_top) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _filters_location_top:false is source application chrome. The document panels collection is preserved on read/modify/write, but no panel object is fabricated without a published equivalent binding for the converted controls._ |
| `page-break` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _LookML dashboards have no documented print-pagination marker. Emitting page-break would invent source intent._ |
| `repeated-container` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Looker dashboard rows and tiles are layout, not a data-bound repeating region. Ordinary rows must not become repeated-container elements._ |
| `dashboard-tabs-as-tabbed-container` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard#tabs) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Looker tabs are top-level dashboard pages, not alternate views sharing one canvas region. Mapping them to tabbed-container would change navigation semantics._ |
| `literal-dashboard-and-tile-background` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard) | `style.backgroundColor + settings.theme.overrides.colorOverrides.backgroundCanvas` | 🟡 n | warn+preserve-default |
| | | | | _Literal background_color values map to released element style and workbook canvas theme fields. Liquid/dynamic values are warned and omitted._ |
| `looker-boxplot` | [doc](https://cloud.google.com/looker/docs/reference/param-lookml-dashboard-boxplot-chart) | — (no Sigma equivalent) | 🟡 n | warn+skip |
| | | | | _Looker documents looker_boxplot, but box-chart is not published in the released workbook schema. Never emit it until that gate is removed and a round-trip test exists._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
