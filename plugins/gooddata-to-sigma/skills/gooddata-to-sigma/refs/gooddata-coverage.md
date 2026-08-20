# Gooddata → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill gooddata --out refs/gooddata-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing ([bead]).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 45 documented constructs across 5 dimensions; 0 live-verified.

## Visualization / chart kind

_GoodData insight `visualizationUrl` (a `local:<type>` token) -> Sigma workbook element kind. The single source of truth for build_workbook.py's insight classifier. `local:headline`, `local:table`, and `local:repeater` are handled structurally. Plain cartesian/pie charts plus released `waterfall-chart` drive the derived CHART dict. Repeater emits a data-bound `repeated-container` only with one Rows attribute and resolvable Columns. Rows with `sigma:null` are loud gaps. `local:boxplot` is separately capability-gated and never emits by default. An unknown visualizationUrl also flags._

Authoritative source: <https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `local:headline` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/headline/) | `kpi-chart` | 🟡 n | flag |
| | | | | _Structural: one (or two, with a secondary measure) measures -> Sigma KPI; matched by name in code, not via CHART._ |
| `local:table` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/table/) | `table` | 🟡 n | flag |
| | | | | _Structural: a flat aggregated `table` (carries groupings); becomes a `pivot-table` (rowsBy/columnsBy/values) when the insight has a columns shelf. Matched by name in code, not via CHART._ |
| `local:column` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/column-chart/) | `bar-chart` | 🟡 n | flag |
| | | | | _Vertical bars. Sigma bar-chart with orientation omitted = vertical._ |
| `local:bar` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/bar-chart/) | `bar-chart` | 🟡 n | flag |
| | | | | _Horizontal bars. build_workbook sets orientation:horizontal downstream._ |
| `local:line` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/line-chart/) | `line-chart` | 🟡 n | flag |
| | | | | _view->x, trend/segment->series._ |
| `local:area` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/stacked-area-chart/) | `area-chart` | 🟡 n | flag |
| `local:pie` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/pie-chart/) | `pie-chart` | 🟡 n | flag |
| `local:donut` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/donut-chart/) | `donut-chart` | 🟡 n | flag |
| | | | | _Distinct hole-value column to avoid the value/color collision bug._ |
| `local:funnel` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/funnel-chart/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _No faithful Sigma equivalent -> flag (migrate as table or skip)._ |
| `local:pyramid` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/pyramid-chart/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _No Sigma equivalent -> flag._ |
| `local:sankey` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/sankey-chart/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _No Sigma equivalent -> flag._ |
| `local:dependencywheel` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/dependency-wheel-chart/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _No Sigma equivalent -> flag._ |
| `local:waterfall` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/) | `waterfall-chart` | 🟡 n | flag |
| | | | | _When the exported insight token is present with a View dimension and measure, emit native x/y axes, cumulative sum, hidden zero start, and connector line. Missing axis prerequisites stay loud._ |
| `local:treemap` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/treemap/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _No clean Sigma equivalent yet -> flag._ |
| `local:repeater` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/repeaters/) | `repeated-container` | 🟡 n | flag |
| | | | | _Exactly one Rows attribute plus resolvable Columns grounds a grouped table source and repeated-container card. View-by inline sparklines are preserved as text/numeric cards with a loud mini-chart gap._ |
| `local:bullet` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _No documented GoodData Cloud bullet/progress visualization contract; never infer native progress from a type token._ |
| `local:boxplot` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _Capability-gated. Never emit a box element until the target workspace and released schema are verified._ |

## Number format

_GoodData metric `content.format` mask -> Sigma column `format` object ({kind:number, formatString:<d3>}). This is a COMPOSITIONAL parser, not a flat lookup: build_workbook.py's gd_fmt() reads the mask directly — decimals from the digits after the '.', currency from a literal '$'/'EUR' symbol IN the mask, percent from a literal '%'. It returns None only when the format string is absent (value ships unformatted). It NEVER name-substring-guesses currency or percent. The rows below document the representative mask shapes and the exact formatString gd_fmt() emits for each; they are the grounding/citation for the parser, not a dict the builder loads. An unrecognized-but-present mask still parses on those literal cues (best-effort) rather than warning._

Authoritative source: <https://www.gooddata.com/docs/cloud/create-metrics/metric-formatting/>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `#,##0` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/metric-formatting/) | `,.0f` | 🟡 n | ship-unformatted |
| | | | | _Integer with thousands separator, 0 decimals._ |
| `#,##0.00` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/metric-formatting/) | `,.2f` | 🟡 n | ship-unformatted |
| | | | | _2 decimals, thousands separator._ |
| `$#,##0` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/metric-formatting/) | `$,.0f` | 🟡 n | ship-unformatted |
| | | | | _Currency prefix read from the literal '$' in the mask, 0 decimals._ |
| `$#,##0.00` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/metric-formatting/) | `$,.2f` | 🟡 n | ship-unformatted |
| | | | | _USD, 2 decimals; currency from the literal '$'._ |
| `EUR#,##0.00` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/metric-formatting/) | `EUR,.2f` | 🟡 n | ship-unformatted |
| | | | | _Euro currency read from a literal EUR sign in the mask (shown here transliterated to keep the catalog ASCII); gd_fmt keys on the actual euro glyph._ |
| `#,##0%` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/metric-formatting/) | `,.0%` | 🟡 n | ship-unformatted |
| | | | | _Percent from the literal '%'; 0 decimals._ |
| `#,##0.0%` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/metric-formatting/) | `,.1%` | 🟡 n | ship-unformatted |
| | | | | _Percent, 1 decimal._ |

## Aggregation

_GoodData MAQL scalar aggregate function -> Sigma aggregate function. The single source of truth for the AGG map that appears in BOTH maql.py (the standalone MAQL->Sigma translator used by convert.py / scan_gaps.py / discover_platform.py) and build_workbook.py (the insight builder's inline resolver); both derive the map from this catalog so the two copies can never drift. `sum/avg/min/max/median` are the flat-mappable scalar aggregates driven by the `(SUM|AVG|MIN|MAX|MEDIAN)(...)` regex. `count` is documented here for coverage but is resolved COMPOSITIONALLY in code: `COUNT({attribute/x})` -> `CountDistinct([x])` (GoodData COUNT of an attribute is a distinct count of that attribute's members), and a `WHERE` clause turns any of these into the Sigma `*If` variant (SumIf/AvgIf/.../CountDistinctIf) in maql.py. The hard MAQL surface — `BY` / `BY ALL` / `WITHIN` context and `FOR PREVIOUS/NEXT` time transforms — is NOT a flat aggregate; it is detected and flagged as CONTEXT / TIME_INTEL in maql.py and build_workbook.py's resolve() (cited code, routed to the workbook layer / gap-scout), never forced into this table. Mirrors refs/maql-mapping.md._

Authoritative source: <https://www.gooddata.com/docs/cloud/create-metrics/maql/aggregation-functions/>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `sum` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/maql/aggregation-functions/sum/) | `Sum` | 🟡 n | flag |
| | | | | _SUM({fact/x}) -> Sum([x]); WHERE -> SumIf._ |
| `avg` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/maql/aggregation-functions/avg/) | `Avg` | 🟡 n | flag |
| | | | | _WHERE -> AvgIf._ |
| `min` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/maql/aggregation-functions/min/) | `Min` | 🟡 n | flag |
| | | | | _WHERE -> MinIf._ |
| `max` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/maql/aggregation-functions/max/) | `Max` | 🟡 n | flag |
| | | | | _WHERE -> MaxIf._ |
| `median` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/maql/aggregation-functions/median/) | `Median` | 🟡 n | flag |
| | | | | _Sigma has no MedianIf; MEDIAN with a WHERE clause is flagged UNHANDLED in maql.py (filter cannot be honored)._ |
| `count` | [doc](https://www.gooddata.com/docs/cloud/create-metrics/maql/aggregation-functions/count/) | `CountDistinct` | 🟡 n | flag |
| | | | | _Resolved compositionally: COUNT({attribute/x}) -> CountDistinct([x]) (GoodData COUNT of an attribute = distinct member count); WHERE -> CountDistinctIf. Documented here for coverage; NOT driven by the (SUM\|AVG\|MIN\|MAX\|MEDIAN) regex._ |

## Control / filter

_GoodData dashboard `filterContext` filter -> Sigma workbook control. This pass emits exactly ONE control shape: a dashboard-wide RELATIVE date filter becomes a single Sigma date-range control bound to the master detail table's parsed date column, which then propagates down the source lineage to every element (mirrors GoodData's one filterContext over all widgets). detect_filter() reads the relative dateFilter directly — granularity -> unit, and the from/to offsets pick the mode (from==to==0 -> current period; from==to==-n -> last n periods). This is compositional parsing (cited code), not a dict the builder loads. Absolute date filters and attribute filters are NOT emitted this pass (documented gap); a relative date filter present but with no YYYYMMDD date key on the fact element is flagged, not dropped silently._

Authoritative source: <https://www.gooddata.com/docs/cloud/create-dashboards/filters/date-filters/>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `relativeDateFilter (current period)` | [doc](https://www.gooddata.com/docs/cloud/create-dashboards/filters/date-filters/) | `date-range` | 🟡 n | flag |
| | | | | _granularity+from==to==0 -> Sigma date-range control, mode 'current' (e.g. 'this month')._ |
| `relativeDateFilter (last N periods)` | [doc](https://www.gooddata.com/docs/cloud/create-dashboards/filters/date-filters/) | `date-range` | 🟡 n | flag |
| | | | | _granularity+from==to==-n -> Sigma date-range control, mode 'last', value n, includeToday false._ |

## Released workbook features

_Audit of released Sigma workbook-as-code surfaces against documented GoodData Cloud semantics. The builder emits only from equivalent source evidence. Dashboard tabs become metadata pages plus auto navigation; chart legend and literal background style are allowlisted; native waterfall and data-bound repeater have prerequisite gates. Drill, page-break, progress, panels, and box stay explicit gaps where GoodData or Sigma does not provide an authorable equivalent._

Authoritative source: <https://www.gooddata.com/docs/cloud/create-dashboards/>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `waterfall` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/) | `waterfall-chart` | 🟡 n | warn+skip |
| | | | | _The exported local:waterfall token maps only with a View dimension and measure; no category or measure is invented._ |
| `repeater` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/repeaters/) | `repeated-container` | 🟡 n | warn+skip |
| | | | | _One Rows attribute and resolvable Columns ground a grouped table source and native repeated cards._ |
| `repeater-inline-chart` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/repeaters/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _GoodData View-by line/bar charts inside repeater cells do not map to one repeated-container child shape; row cards and values are preserved while the mini-chart stays loud._ |
| `legend` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-properties/) | `element.legend` | 🟡 n | warn+preserve-default |
| | | | | _properties.controls.legend enabled and top/bottom/left/right map directly; unknown properties are omitted loudly._ |
| `dashboard-tabs` | [doc](https://www.gooddata.com/docs/cloud/create-dashboards/dashboard-tabs/) | `metadata pages + navigation:auto` | 🟡 n | warn+single-page |
| | | | | _Each GoodData tab is a top-level page. Required layout owns membership; navigation:auto is emitted per tab and page tabs are shown._ |
| `tab-filter` | [doc](https://www.gooddata.com/docs/cloud/create-dashboards/dashboard-tabs/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _Tab-local YAML filters are loud unless the declarative export also provides a resolvable filterContext binding._ |
| `attribute-hierarchy-drill` | [doc](https://www.gooddata.com/docs/cloud/create-dashboards/drilling-in-dashboards/set-drill-down/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _An attribute hierarchy proves drill intent, but the released workbook contract does not publish the source/category/target binding needed to author a working drill control. Inert drill UI is never emitted._ |
| `navigation-interaction` | [doc](https://www.gooddata.com/docs/cloud/create-dashboards/dashboard-tabs/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _Cross-dashboard and drill-to-tab interactions need a converted target document/page id. Auto navigation covers tabs in the current dashboard; unresolved destinations remain loud._ |
| `page-break` | [doc](https://www.gooddata.com/docs/cloud/create-dashboards/export/export-accessible-pdf/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _GoodData dashboard metadata has no documented print page-break marker. Tab and section boundaries are not print intent._ |
| `progress` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _GoodData Cloud has no documented standalone progress/bullet visualization with explicit value/min/max semantics. Repeater cell bars are not promoted to progress._ |
| `panels` | [doc](https://www.gooddata.com/docs/cloud/create-dashboards/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _Dashboard sections and filter bars are in-canvas layout/application chrome, not Sigma document header/sidebar panels. document.panels remains explicit and empty._ |
| `visual-style` | [doc](https://www.gooddata.com/docs/cloud/customize-appearance/create-custom-themes/) | `element.style.backgroundColor` | 🟡 n | warn+preserve-default |
| | | | | _Only a resolved literal backgroundColor in exported insight style metadata is copied. Dynamic or unknown CSS is omitted loudly._ |
| `box-chart` | [doc](https://www.gooddata.com/docs/cloud/create-visualizations/visualization-types/) | — (no Sigma equivalent) | 🟡 n | flag |
| | | | | _Box visualization output is capability-gated until a generally released workbook kind and target-workspace entitlement are verified._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
