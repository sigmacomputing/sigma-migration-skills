# Sisense → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill sisense --out refs/sisense-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing ([bead]).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 50 documented constructs across 5 dimensions; 0 live-verified.

## Visualization / chart kind

_Sisense widget `type` -> Sigma workbook element. The single source of truth for convert.py's two widget classifiers: (1) `sigma` is the Sigma workbook element KIND the builder emits (convert_dashboard.SIGMA_KIND) — null means there is no native Sigma element and convert_dashboard FLAGS the widget (loud, no element); (2) `coverage_element` + `tag` reproduce the assessment coverage map (classify_dashboard.WIDGET_MAP), where the coarse element name and AUTO/HINT/MANUAL tag drive the coverage report only. Both dicts are derived from these rows. Widget type strings must be confirmed against live widget `type` values (see refs/widget-type-mapping.md); the trial has 0 dashboards so these are documentation-grounded, not yet query-verified. Unmapped/unknown widget types warn+flag._

Authoritative source: <https://docs.sisense.com/main/SisenseLinux/widget-designer.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `indicator` | [doc](https://docs.sisense.com/main/SisenseLinux/indicator.htm) | `kpi-chart` | 🟡 n | warn+flag |
| | | | | _Single numeric value -> Sigma KPI. A gauge with explicit min/max maps conditionally to native progress; an incomplete gauge range remains a KPI with a loud gap._ |
| `chart/column` | [doc](https://docs.sisense.com/main/SisenseLinux/column-chart.htm) | `bar-chart` | 🟡 n | warn+flag |
| | | | | _Vertical columns -> Sigma bar-chart (no orientation key = vertical)._ |
| `chart/bar` | [doc](https://docs.sisense.com/main/SisenseLinux/bar-chart.htm) | `bar-chart` | 🟡 n | warn+flag |
| | | | | _Horizontal bars -> Sigma bar-chart; orientation from sub-type is applied downstream._ |
| `chart/line` | [doc](https://docs.sisense.com/main/SisenseLinux/line-chart.htm) | `line-chart` | 🟡 n | warn+flag |
| `chart/area` | [doc](https://docs.sisense.com/main/SisenseLinux/area-chart.htm) | `area-chart` | 🟡 n | warn+flag |
| `chart/waterfall` | [doc](https://docs.sisense.com/main/SisenseLinux/waterfall-chart.htm) | `waterfall-chart` | 🟡 n | warn+flag |
| | | | | _Category and value panels map to native waterfall axes with cumulative sum and connector lines._ |
| `chart/pie` | [doc](https://docs.sisense.com/main/SisenseLinux/pie-chart.htm) | `pie-chart` | 🟡 n | warn+flag |
| `pivot2` | [doc](https://docs.sisense.com/main/SisenseLinux/pivot.htm) | `pivot-table` | 🟡 n | warn+flag |
| | | | | _`pivot2` is the current Sisense pivot widget type; rows/columns/values panels -> Sigma grouped table._ |
| `pivot` | [doc](https://docs.sisense.com/main/SisenseLinux/pivot.htm) | `pivot-table` | 🟡 n | warn+flag |
| | | | | _Legacy pivot widget type alias._ |
| `tablewidget` | [doc](https://docs.sisense.com/main/SisenseLinux/widget-designer.htm) | `table` | 🟡 n | warn+flag |
| `chart/scatter` | [doc](https://docs.sisense.com/main/SisenseLinux/scatter-chart.htm) | `scatter-chart` | 🟡 n | warn+flag |
| | | | | _Verify axis/size mapping (Sisense scatter has X/Y + size + color)._ |
| `chart/polar` | [doc](https://docs.sisense.com/main/SisenseLinux/polar-chart.htm) | `bar-chart` | 🟡 n | warn+flag |
| | | | | _Sigma has no polar/radar element; the builder emits a bar-chart while the coverage report labels the closest match 'radar' (HINT — verify)._ |
| `chart/funnel` | [doc](https://docs.sisense.com/main/SisenseLinux/widget-designer.htm) | `bar-chart` | 🟡 n | warn+flag |
| | | | | _No native Sigma funnel; emitted as a bar-chart + flag note (HINT)._ |
| `treemap` | [doc](https://docs.sisense.com/main/SisenseLinux/treemap.htm) | — (no Sigma equivalent) | 🟡 n | warn+flag |
| | | | | _No native Sigma equivalent -> convert_dashboard flags the widget (no element). Coverage report marks it MANUAL._ |
| `sunburst` | [doc](https://docs.sisense.com/main/SisenseLinux/sunburst-widget.htm) | — (no Sigma equivalent) | 🟡 n | warn+flag |
| | | | | _No native Sigma equivalent -> flagged (no element), MANUAL in the coverage report._ |
| `chart/boxplot` | [doc](https://docs.sisense.com/main/SisenseLinux/box-and-whisker-plot.htm) | — (no Sigma equivalent) | 🟡 n | warn+flag |
| | | | | _Sigma box-chart is workspace-gated; skip loudly until entitlement and readback are verified._ |
| `boxplot` | [doc](https://docs.sisense.com/main/SisenseLinux/box-and-whisker-plot.htm) | — (no Sigma equivalent) | 🟡 n | warn+flag |
| | | | | _Legacy/internal alias retained as a gated manual mapping; never emit box-chart optimistically._ |
| `map/area` | [doc](https://docs.sisense.com/main/SisenseLinux/area-map.htm) | — (no Sigma equivalent) | 🟡 n | warn+flag |
| | | | | _The coverage report suggests a Sigma geography-region map (HINT), but the builder has no SIGMA_KIND entry -> the widget is flagged (no element emitted) and the geo mapping is done manually. VERIFY geo level._ |
| `map/scatter` | [doc](https://docs.sisense.com/win/SisenseWin/scatter-map.htm) | — (no Sigma equivalent) | 🟡 n | warn+flag |
| | | | | _Coverage report suggests a Sigma geography-point map (HINT); builder flags it (no element) — recreate the point map manually._ |

## Number format

_Sisense widget JAQL number-format signal -> Sigma column `format` object. The ONLY documentation-grounded numeric-format signal convert.py ports is the currency mask (JAQL `format.mask.currency: true`), which maps to a Sigma currency number format. IMPORTANT ([bead]): the previous `_money_fmt` ALSO returned a $ format when the widget TITLE contained the substring 'Revenue' or 'Cost' — a name-guessing heuristic that mis-formatted any non-currency measure with those words in its title. That title-substring guess has been REMOVED. A JAQL `format.mask` that is present but is NOT a currency signal (e.g. a percent/number mask) is a formatting intent this converter does not yet port -> it now LOUDLY warns and ships the column unformatted, rather than silently dropping it or wrong-guessing. Sisense's default currency symbol is USD '$' per the cited doc._

Authoritative source: <https://docs.sisense.com/main/SisenseLinux/formatting-numbers-in-widgets.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `mask.currency` | [doc](https://docs.sisense.com/main/SisenseLinux/formatting-numbers-in-widgets.htm) | `$,.0f` | 🟡 n | warn+ship-unformatted |
| | | | | _JAQL `format.mask.currency: true` -> Sigma format {kind:number, formatString:'$,.0f', currencySymbol:'$'} (the MONEY object). This is the sole signal that yields a currency format; the removed title-substring heuristic is documented in the dimension description above._ |

## Aggregation

_Sisense JAQL `agg` value -> Sigma aggregate function. Extracted verbatim from jaql_expr.AGG; jaql_expr.translate_agg() derives this dict from these rows and raises Unsupported (which the converter turns into a FLAG) on any agg not listed here. The full JAQL aggregation-type enumeration is documented at the cited Sisense reference. Compositional surfaces stay as cited CODE, not this flat table: the JAQL formula function translator (jaql_expr.SAFE_FUNC / FLAG_FUNC — arithmetic + scalar/agg function-name rewriting, with PREV/PAST/RSUM/GROWTH/QUARTILE/CONTRIBUTION etc. flagged) and the date-level DateTrunc map (jaql_expr.LEVEL). See refs/jaql-mapping.md._

Authoritative source: <https://developer.sisense.com/reference/jaql/>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `sum` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Sum` | 🟡 n | raise Unsupported->flag |
| `count` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Count` | 🟡 n | raise Unsupported->flag |
| `countdistinct` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `CountDistinct` | 🟡 n | raise Unsupported->flag |
| | | | | _JAQL agg value is `countDistinct`; keys are normalized to lowercase (jaql lowercases before lookup)._ |
| `avg` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Avg` | 🟡 n | raise Unsupported->flag |
| `average` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Avg` | 🟡 n | raise Unsupported->flag |
| | | | | _Alias of `avg` (some JAQL emits the long form)._ |
| `min` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Min` | 🟡 n | raise Unsupported->flag |
| `max` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Max` | 🟡 n | raise Unsupported->flag |
| `median` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Median` | 🟡 n | raise Unsupported->flag |
| `stdev` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Stdev` | 🟡 n | raise Unsupported->flag |
| | | | | _Sigma Stdev = sample standard deviation; verify vs Sisense stdev semantics on live data._ |
| `var` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-data/variables/variable.AggregationTypes.html) | `Var` | 🟡 n | raise Unsupported->flag |
| | | | | _Sigma Var = sample variance; verify vs Sisense var semantics on live data._ |

## Control / filter

_Sisense dashboard-filter shape/datatype -> Sigma control kind (from convert.py._emit_control). A member/explicit selection or a text (descriptive) field -> `list`; a date/datetime field OR a JAQL date-`level` grouping -> `date-range`; a numeric field -> `number-range`. The DEFAULT for an unrecognized datatype is a categorical `list` control — a DOCUMENTED default (Sisense filters default to a List filter on descriptive fields per the cited doc), NOT a silent wrong guess. `_emit_control` resolves the control-kind vocabulary from these rows; its compound branching (filter-shape + datatype + date-level) stays as cited code because it is not a flat 1:1 lookup. A filter whose `dim` cannot be parsed returns None and is LOUDLY flagged for manual recreation (never faked)._

Authoritative source: <https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `members` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `list` | 🟡 n | n/a |
| | | | | _Member-list filter (JAQL filter.members) — the most common categorical filter -> Sigma list control seeded with the selected members._ |
| `explicit` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `list` | 🟡 n | n/a |
| | | | | _Explicit member-set filter (JAQL filter.explicit.members) -> Sigma list control._ |
| `text` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `list` | 🟡 n | n/a |
| | | | | _Descriptive/text datatype (datatype/dimType 'text' or unset with no date level) -> Sigma list control._ |
| `datetime` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `date-range` | 🟡 n | n/a |
| | | | | _Date/datetime field -> Sigma date-range control (a list control bound to a datetime column comes back empty on POST)._ |
| `date` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `date-range` | 🟡 n | n/a |
| `level` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `date-range` | 🟡 n | n/a |
| | | | | _A JAQL date-`level` grouping (years/quarters/months/...) on the filtered dim forces a date-range control regardless of the declared datatype (compositional signal)._ |
| `numeric` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `number-range` | 🟡 n | n/a |
| | | | | _Numeric field -> Sigma number-range (between) control._ |
| `number` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `number-range` | 🟡 n | n/a |
| | | | | _Alias of `numeric`._ |
| `*` | [doc](https://docs.sisense.com/main/SisenseLinux/configuring-how-filters-affect-the-dashboard-and-widgets.htm) | `list` | 🟡 n | n/a |
| | | | | _DOCUMENTED DEFAULT: an unrecognized filter datatype becomes a categorical list control (Sisense's own default filter kind for descriptive fields). Not a silent wrong-default — the fallback is the documented categorical control._ |

## workbook-feature

_Audit of released Sigma workbook-as-code features against documented Sisense dashboard and widget semantics. The converter emits only fields present in the discovered dashboard JSON with an equivalent published meaning; add-on payloads and unrelated Sigma capabilities remain explicit gaps._

Authoritative source: <https://docs.sisense.com/main/SisenseLinux/widget-designer.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `chart/waterfall` | [doc](https://docs.sisense.com/main/SisenseLinux/waterfall-chart.htm) | `waterfall-chart` | 🟡 n | warn+skip |
| | | | | _A Sisense waterfall category and measures map to released x/y axes plus cumulative sum and visible connector lines._ |
| `widget-style-legend` | [doc](https://developer.sisense.com/guides/sdk/modules/sdk-ui/type-aliases/type-alias.LegendOptions.html) | `element.legend` | 🟡 n | warn+preserve-default |
| | | | | _Explicit enabled and top/bottom/left/right position values map to Sigma visibility and position. Other placement or styling values are warned and omitted._ |
| `widget-drilldown-options` | [doc](https://docs.sisense.com/main/SisenseLinux/drilling-down-in-a-widget.htm) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Sisense can persist drill categories, but the released Sigma drill control publishes no hierarchy source/category/target binding. Explicit drill intent is flagged; dead drill UI is never emitted._ |
| `jump-to-dashboard` | [doc](https://docs.sisense.com/main/SisenseLinux/jump-to-dashboard.htm) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _The certified JTD add-on can carry a destination dashboard and filter behavior. Discovery does not normalize that add-on payload into a validated destination, so navigation is flagged rather than guessed._ |
| `tabber-widget` | [doc](https://docs.sisense.com/main/SisenseLinux/tabber.htm) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Tabber is a certified add-on whose payload assigns widgets to regional tabs. Until discovery normalizes its tab labels and membership, neither metadata pages nor tabbed-container is emitted._ |
| `print-page-break` | [doc](https://docs.sisense.com/main/SisenseLinux/exporting-dashboards.htm) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Discovered Sisense dashboard layout has no persisted print-pagination marker. Emitting page-break would invent source intent._ |
| `indicator/gauge-with-explicit-range` | [doc](https://docs.sisense.com/main/SisenseLinux/indicator.htm) | `progress` | 🟡 n | warn+retain-kpi |
| | | | | _A gauge maps to a ring-shaped value-mode progress element only when value, minimum, and maximum formulas or literal bounds are all available. A gauge without a complete range remains a KPI with a loud gap._ |
| `dashboard-filter-panel` | [doc](https://docs.sisense.com/main/SisenseLinux/creating-dashboard-filters.htm) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Sisense dashboard filters become in-canvas Sigma controls. No document panel object is fabricated because the discovered panel chrome has no published page/header/sidebar binding equivalent._ |
| `literal-widget-background` | [doc](https://docs.sisense.com/main/SisenseLinux/setting-widget-style.htm) | `element.style.backgroundColor` | 🟡 n | warn+preserve-default |
| | | | | _A literal hex style.backgroundColor maps to released element styling. Scripts, theme tokens, and unknown style fields are omitted loudly._ |
| `repeated-container` | [doc](https://docs.sisense.com/main/SisenseLinux/widget-designer.htm) | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Native Sisense dashboard widgets and columnar layout do not encode a data-bound repeating card region. Ordinary cells must not become repeated-container elements._ |
| `box-and-whisker` | [doc](https://docs.sisense.com/main/SisenseLinux/box-and-whisker-plot.htm) | — (no Sigma equivalent) | 🟡 n | warn+skip |
| | | | | _Sisense documents box plots, but Sigma box-chart is workspace-gated. Never emit one until entitlement and create/readback behavior are verified._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
