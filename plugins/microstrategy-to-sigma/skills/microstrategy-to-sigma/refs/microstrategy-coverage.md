# Microstrategy → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill microstrategy --out refs/microstrategy-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing ([bead]).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 39 documented constructs across 5 dimensions; 12 live-verified.

## Visualization / chart kind

_WIRED into scripts/convert.py. Each dossier visualizationType resolves through this catalog. Live-validated bar/line and released waterfall emit with a dimension + measure; area uses the same mechanically wired axes but remains unverified. `grid`/`compound_grid`/`heat_map` map to a Sigma table. Gauge emits native progress only from explicit value/min/max semantics. Box plot stays capability-gated and defaults to a loud table because no generally released native box element is established. Every other unresolved type falls to a table with a LOUD warning (data preserved, never silently wrong)._

Authoritative source: <https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `grid` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/webhelp/lang_1033/Content/Displaying_a_visual_representation_of_your_data__V.htm) | `table` | ✅ y · 2026-07-13 | flagged-table |
| | | | | _Validated grouped-table path. Pivot/crossTab remains a separate roadmap item._ |
| `kpi` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/intro_kpi_viz.htm) | `kpi-chart` | 🟡 n | flagged-table |
| | | | | _Highest-volume unbuilt type in the demo sweep; currently collapses to a table._ |
| `bar_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `bar-chart` | ✅ y · 2026-07-13 | flagged-table |
| `line_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/AdvancedReportingGuide/WebHelp/Lang_1033/Content/Line.htm) | `line-chart` | ✅ y · 2026-07-13 | flagged-table |
| `area_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `area-chart` | 🟡 n | flagged-table |
| | | | | _Mechanically emits the shared cartesian xAxis/yAxis shape, but has not passed a live MicroStrategy-to-Sigma render/parity run._ |
| `pie_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MCG-Workstation/en-us/Content/Creating_a_graph_with_pies_or_rings.htm) | `pie-chart` | 🟡 n | flagged-table |
| `ring_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MCG-Workstation/en-us/Content/Creating_a_graph_with_pies_or_rings.htm) | `donut-chart` | 🟡 n | flagged-table |
| | | | | _MSTR ring = pie/donut variant._ |
| `combo_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `combo-chart` | 🟡 n | flagged-table |
| `bubble_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `scatter-chart` | 🟡 n | flagged-table |
| | | | | _Size slot -> Sigma scatter._ |
| `multi_metric_kpi` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/intro_kpi_viz.htm) | `kpi-chart` | 🟡 n | flagged-table |
| | | | | _One Sigma KPI per metric._ |
| `compound_grid` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/webhelp/lang_1033/Content/Displaying_a_visual_representation_of_your_data__V.htm) | `table` | 🟡 n | flagged-table |
| `heat_map` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `table` | 🟡 n | flagged-table |
| | | | | _Size+color tile grid has no Sigma analog -> flagged table._ |
| `waterfall` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `waterfall-chart` | ✅ y · 2026-08-04 | flagged-table |
| | | | | _Uses the released source/columns/xAxis/yAxis waterfall skeleton; subtotal/end-total options are omitted unless their prerequisites are grounded._ |
| `gauge` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `progress` | ✅ y · 2026-08-03 | flagged-table |
| | | | | _Requires explicit value/min/max semantics in the extracted visualization. Shallow type-only definitions remain loud table fallbacks._ |
| `box_plot` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `box-plot` | 🟡 n | flagged-table |
| | | | | _Not emitted by default. Requires --enable-box-plot and a workspace capability verified by the operator; otherwise data is preserved in a loud table fallback._ |

## Number format

_MicroStrategy metric number-format CATEGORY (Fixed / Currency / Percent / Number / Scientific — the documented Number-format categories) -> Sigma column number format (D3 formatString in {kind:number, formatString}). convert.py.metric_display_format() reads the metric's EXPLICIT MicroStrategy format (metricFormatType / format.values property block) via _mstr_format_category() and resolves the category here. A 'reserved'/'general'/empty format block means 'inherit default' = NO explicit format: the metric ships UNFORMATTED with a LOUD note. This REPLACES the [bead] disease — the old code guessed a $/%/integer format from the metric NAME (pct|percent|margin|ratio|rate) or fact-column NAME (REVENUE|PROFIT|COST|AMOUNT|PRICE, QUANTITY|UNITS|COUNT) with a silent None fallback; that name/column-substring guessing is GONE. Custom (user format-string) masks are not in this flat table — they would be parsed by a cited predicate if MicroStrategy supplied one (the modeling-API bundles seen so far carry empty format blocks)._

Authoritative source: <https://www2.microstrategy.com/producthelp/current/MSTRWeb/webhelp/lang_1033/content/Formatting_numeric_values_in_a_visualization.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `currency` | [doc](https://www2.microstrategy.com/producthelp/current/reportdesigner/webhelp/lang_1033/content/formatting_metrics_on_a_report.htm) | `$,.2f` | 🟡 n | warn+unformatted |
| | | | | _MSTR Currency category default: currency symbol, thousands separator, 2 decimals._ |
| `percent` | [doc](https://www2.microstrategy.com/producthelp/current/reportdesigner/webhelp/lang_1033/content/formatting_metrics_on_a_report.htm) | `,.2%` | 🟡 n | warn+unformatted |
| | | | | _MSTR Percent: a stored ratio (0.275) renders as 27.50%; Sigma % format multiplies by 100 the same way._ |
| `fixed` | [doc](https://www2.microstrategy.com/producthelp/current/reportdesigner/webhelp/lang_1033/content/formatting_metrics_on_a_report.htm) | `,.2f` | 🟡 n | warn+unformatted |
| | | | | _MSTR Fixed category default: thousands separator, 2 decimal places._ |
| `number` | [doc](https://www2.microstrategy.com/producthelp/current/mstrio-py/mstrio.modeling.metric.metric_format.html) | `,.0f` | 🟡 n | warn+unformatted |
| | | | | _Plain integer with thousands separator._ |
| `scientific` | [doc](https://www2.microstrategy.com/producthelp/current/mstrio-py/mstrio.modeling.metric.metric_format.html) | `.2e` | 🟡 n | warn+unformatted |
| | | | | _MSTR Scientific -> D3 exponential._ |

## Aggregation

_MicroStrategy metric group-value function (metric expression token) -> Sigma aggregate function (`sigma`, used verbatim by metric_formula) and warehouse SQL aggregate (`sql`, the FN dict used by metric_sql when it emits AE-emulation SQL). The FN dict {source->sql} in convert.py.metric_sql is DERIVED from these rows; an unmapped function no longer silently passes through as fname.upper() — it WARNS loudly first, then emits UPPER() as a documented degraded fallback. Count with a `<Distinct=True>` parameter is COMPOSITIONAL (Count -> CountDistinct) and is resolved in metric_formula() with a cited comment, not as a separate flat row._

Authoritative source: <https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Using_group_value_functions.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `Sum` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Sum_.htm) | `Sum` | 🟡 n | warn+upper |
| `Count` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Count_.htm) | `Count` | 🟡 n | warn+upper |
| | | | | _Count<Distinct=True> is compositional -> Sigma CountDistinct (handled in metric_formula, not this flat map)._ |
| `Avg` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Avg_.htm) | `Avg` | 🟡 n | warn+upper |
| `Max` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Max_.htm) | `Max` | 🟡 n | warn+upper |
| `Min` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Min_.htm) | `Min` | 🟡 n | warn+upper |

## Control / filter

_Bound-column data type of a MicroStrategy dossier selector / chapter filter (Bundle.attribute_ctl_type: 'date' | 'number' | 'text', derived from the rendered DESC form's dataType) -> Sigma control kind. convert.py.emit_controls() resolves the control kind through this catalog. Only the date case is special: a Sigma `list` control whose filter target is a DATETIME *or NUMERIC* column posts 200 but Sigma SILENTLY STRIPS the target (reads back filters:null — live-verified on this converter 2026-06-12; datetime is a cross-plugin gotcha, see refs/control-parity.md). Dates become date-range controls; numbers stay `list` but bind through a hidden Text() cast; text is a plain `list`. Unresolvable source attributes / metric-qualification selectors are already recorded LOUDLY in control-scope.json (status: unbound / manual)._

Authoritative source: <https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/intro_add_filters.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `date` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/getting_started_selector.htm) | `date-range` | 🟡 n | n/a |
| | | | | _A datetime-bound list control reads back filters:null (dead control) — must be a date-range control with a flat `mode`._ |
| `number` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/getting_started_selector.htm) | `list` | 🟡 n | n/a |
| | | | | _A list-control filter target on a NUMERIC column is silently stripped by Sigma (200 on POST/PUT, filters:null on readback) — numeric selectors bind through a hidden Text() cast column._ |
| `text` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/getting_started_selector.htm) | `list` | 🟡 n | n/a |
| | | | | _Categorical list control (documented default)._ |

## workbook-feature

_Released workbook-as-code surfaces emitted only from equivalent MicroStrategy dossier semantics. Chapters ground page navigation; fully populated panelStacks ground tabbed containers; explicit print markers ground page-breaks; explicit gauge value/min/max ground progress; explicit row-card repeat metadata grounds repeated containers; literal style and chart-legend metadata are allowlisted. A selectorType label alone does not ground Sigma legend/drill controls, and report pageBy is not print pagination. Incomplete or unknown payloads are recorded loudly in feature-gaps.json._

Authoritative source: <https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/intro_dossiers.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `chapter-tabs` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/intro_dossiers.htm) | `navigation` | ✅ y · 2026-08-03 | warn+manual |
| | | | | _A multi-chapter dossier is a tabbed source experience; emit an auto navigation element using chapter names as page labels._ |
| `panel-stack` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/creating_panel_stacks.htm) | `tabbed-container` | ✅ y · 2026-08-05 | warn+manual |
| | | | | _Panel labels become tabs and concrete panel visualizations become positional layout children. If any panel lacks a buildable visualization, the entire tabbed container is suppressed and recorded as a loud gap._ |
| `print-page-break` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/intro_dossiers.htm) | `page-break` | ✅ y · 2026-08-05 | warn+manual |
| | | | | _Only an explicit pageBreakAfter/printPageBreakAfter extractor marker emits the id/kind-only element at exactly one layout row. Dossier page count alone does not prove print intent._ |
| `report-page-by` | [doc](https://www2.microstrategy.com/producthelp/Current/BasicReporting/WebHelp/Lang_1033/Content/Page-by.htm) | — (no Sigma equivalent) | 🟡 n | warn+preserve-table |
| | | | | _MicroStrategy report pageBy is a paging/filter axis, not a print/PDF break. It remains a loud interaction gap and never fabricates page-break._ |
| `gauge-progress` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `progress` | ✅ y · 2026-08-03 | warn+table |
| | | | | _Emit only when the source carries explicit value/min/max semantics; otherwise preserve data in a table and record the missing gauge semantics._ |
| `legend` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/Formatting_a_graph_legend.htm) | `chart.legend` | ✅ y · 2026-08-03 | warn+omit |
| | | | | _Allowlisted visibility and position fields only; unknown legend properties are gaps._ |
| `legend-selector` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/getting_started_selector.htm) | — (no Sigma equivalent) | 🟡 n | warn+suppress-control |
| | | | | _A selectorType string and one source attribute do not provide Sigma legend's categorical master source plus chart color target. Emit no dead control until extraction captures both bindings._ |
| `drill-selector` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/drilling_in_a_visualization.htm) | — (no Sigma equivalent) | 🟡 n | warn+suppress-control |
| | | | | _The released drill control requires ordered categories plus source and target column bindings. A selectorType string does not carry that contract, so unresolved selectors remain loud gaps._ |
| `repeater` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/intro_dossiers.htm) | `repeated-container` | ✅ y · 2026-08-05 | warn+table |
| | | | | _Requires explicit repeater metadata and at least one bound display field._ |
| `visual-style` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/Formatting_a_visualization.htm) | `style/settings.theme` | ✅ y · 2026-06-26 | warn+omit |
| | | | | _Only current Sigma style keys are copied; arbitrary MicroStrategy formatting is never passed through._ |
| `workbook-panels` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/creating_panel_stacks.htm) | — (no Sigma equivalent) | 🟡 n | emit-empty-collection |
| | | | | _MicroStrategy panel stacks are in-canvas alternates mapped to tabbed-container, not Sigma document panel chrome. The builder emits document.panels:[] and never fabricates panel metadata._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
