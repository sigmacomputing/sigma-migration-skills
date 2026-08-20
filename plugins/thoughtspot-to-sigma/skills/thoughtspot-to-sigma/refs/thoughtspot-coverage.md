# Thoughtspot → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-thoughtspot-coverage.py --catalogs refs/catalogs --skill thoughtspot --out refs/thoughtspot-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing ([bead]).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 63 documented constructs across 5 dimensions; 4 live-verified.

## Visualization / chart kind

_ThoughtSpot visualization `chart_type` -> Sigma workbook element kind. The single source of truth for ts_common.py's tile classifier. Two row classes: (1) a DIRECT-mapped type carries `sigma` = the Sigma element kind and drives the `KIND` dict; (2) a `no_sigma_equiv:true` row is a KNOWN-unsupported ThoughtSpot chart (Sigma has no faithful treemap/gauge/funnel/sankey/histogram/candlestick/radar/pareto/spider/box plot) that DEGRADES to a flagged `table` — these rows drive the `_NO_SIGMA_EQUIV` set. Both sets are DERIVED from these rows (no inline literal). WATERFALL now maps to Sigma's published native `waterfall-chart`. A chart string that is NEITHER (a genuinely UNKNOWN ThoughtSpot type not listed here) must WARN loudly and degrade to a flagged table too — never a silent bar-chart ([bead]). KPI/PIE/DONUT/PIVOT/TABLE/GEO/SCATTER/BUBBLE/combo have dedicated builder branches; direct axis-chart rows feed the generic branch._

Authoritative source: <https://docs.thoughtspot.com/cloud/latest/chart-types>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `KPI` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `kpi-chart` | ✅ y · 2026-07-13 | warn+degrade-to-flagged-table |
| | | | | _ThoughtSpot KPI/headline -> Sigma KPI chart (dedicated builder branch)._ |
| `COLUMN` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `bar-chart` | ✅ y · 2026-07-13 | warn+degrade-to-flagged-table |
| | | | | _Vertical bars. Sigma bar-chart with NO orientation key = vertical._ |
| `BAR` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `bar-chart` | 🟡 n | warn+degrade-to-flagged-table |
| | | | | _Horizontal bars in ThoughtSpot; Sigma bar-chart kind._ |
| `LINE` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `line-chart` | ✅ y · 2026-07-13 | warn+degrade-to-flagged-table |
| `STACKED_COLUMN` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `bar-chart` | 🟡 n | warn+degrade-to-flagged-table |
| | | | | _Stacking is set on the Sigma bar-chart element downstream._ |
| `STACKED_BAR` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `bar-chart` | 🟡 n | warn+degrade-to-flagged-table |
| `AREA` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `area-chart` | 🟡 n | warn+degrade-to-flagged-table |
| `STACKED_AREA` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `area-chart` | 🟡 n | warn+degrade-to-flagged-table |
| `ADVANCED_COLUMN` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | warn+degrade-to-flagged-table |
| | | | | _ThoughtSpot advanced/tabular column view -> Sigma table (dedicated builder branch)._ |
| `TABLE` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-table) | `table` | 🟡 n | warn+degrade-to-flagged-table |
| `WATERFALL` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `waterfall-chart` | 🟡 n | warn+degrade-to-flagged-table |
| | | | | _Native Sigma waterfall-chart using the shared x/y chart skeleton. Advanced subtotal/end-total options remain omitted unless the source provides the required split/multi-series semantics._ |
| `FUNNEL` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `TREEMAP` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `HEATMAP` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `HISTOGRAM` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `GAUGE` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `SANKEY` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `PARETO` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `CANDLESTICK` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `SPIDER_WEB` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _Radar/spider; no faithful Sigma chart; FLAGGED table._ |
| `RADAR` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _No faithful Sigma chart; FLAGGED table._ |
| `WHISKER_SCATTER` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-answers) | `table` | 🟡 n | flag-degrade-to-table |
| | | | | _ThoughtSpot box-and-whisker chart. Sigma's published workbook schema has no box-chart kind; preserve data as an explicitly FLAGGED table._ |

## Number format

_ThoughtSpot number formatting is PATTERN-DRIVEN and honors the source: a column's `format_pattern` (Java DecimalFormat, e.g. '#,##0.00', '0.0%') sets decimals/grouping/percent, and a separate `currency_type.iso_code` sets the currency — the pattern NEVER carries a currency symbol (ThoughtSpot docs: 'currency symbols are not supported in number format patterns'). The compositional pattern->Sigma-format translation stays as cited code in ts_format_to_sigma(); this catalog captures the one enumerable map that WAS an inline literal: the currency ISO-4217 code -> Unicode symbol table (drives the `_CUR` dict, derived from these rows). An ISO code NOT in this table falls back to the literal ISO code + space as the prefix (explicit, source-faithful) — never a name-substring guess. When neither pattern nor currency is set, _fmt() ships a neutral grouped number (',.0f') and invents NO currency (benign, cited in code)._

Authoritative source: <https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `USD` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `$` | 🟡 n | explicit-iso-prefix |
| | | | | _US dollar._ |
| `CAD` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `$` | 🟡 n | explicit-iso-prefix |
| | | | | _Canadian dollar (dollar glyph)._ |
| `AUD` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `$` | 🟡 n | explicit-iso-prefix |
| `NZD` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `$` | 🟡 n | explicit-iso-prefix |
| `EUR` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `€` | 🟡 n | explicit-iso-prefix |
| | | | | _Euro._ |
| `GBP` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `£` | 🟡 n | explicit-iso-prefix |
| | | | | _Pound sterling._ |
| `JPY` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `¥` | 🟡 n | explicit-iso-prefix |
| | | | | _Japanese yen._ |
| `CNY` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `¥` | 🟡 n | explicit-iso-prefix |
| | | | | _Chinese yuan (yen/yuan glyph)._ |
| `INR` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `₹` | 🟡 n | explicit-iso-prefix |
| | | | | _Indian rupee._ |
| `KRW` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `₩` | 🟡 n | explicit-iso-prefix |
| | | | | _Korean won._ |
| `BRL` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-patterns) | `R$` | 🟡 n | explicit-iso-prefix |
| | | | | _Brazilian real._ |

## Aggregation

_ThoughtSpot column/measure aggregation type -> Sigma aggregate function. Drives the `TS_AGG_TO_SIGMA` dict (derived from these rows, no inline literal). ThoughtSpot's documented measure aggregations are sum, average, count, count_distinct, min, max, std_deviation, variance (median is available on formulas). An UNSPECIFIED aggregation on a measure defaults to the ThoughtSpot documented default SUM as the SOURCE token before lookup (per the aggregation doc: 'If the column type is measure, the default is sum') — that is documentation-grounded, not a guess. But a token that is PRESENT yet NOT in this catalog now WARNS loudly and falls back to Sum EXPLICITLY (never a silent wrong Sum default; [bead]). Compositional aggregate-formula translation (count_distinct/unique_count/std_deviation/median inside a formula expr) stays as cited code in ts_expr_to_sigma()._

Authoritative source: <https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `SUM` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `Sum` | ✅ y · 2026-07-13 | warn |
| | | | | _ThoughtSpot documented default aggregation for a measure column._ |
| `AVERAGE` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `Avg` | 🟡 n | warn |
| `AVG` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `Avg` | 🟡 n | warn |
| | | | | _Synonym token for AVERAGE._ |
| `MIN` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `Min` | 🟡 n | warn |
| `MAX` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `Max` | 🟡 n | warn |
| `COUNT` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `Count` | 🟡 n | warn |
| `COUNT_DISTINCT` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `CountDistinct` | 🟡 n | warn |
| `MEDIAN` | [doc](https://docs.thoughtspot.com/cloud/latest/formula-reference) | `Median` | 🟡 n | warn |
| | | | | _ThoughtSpot median via formula; Sigma Median aggregate._ |
| `STD_DEVIATION` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `StdDev` | 🟡 n | warn |
| `VARIANCE` | [doc](https://docs.thoughtspot.com/cloud/latest/data-modeling-aggreg-additive) | `Variance` | 🟡 n | warn |

## Control / filter

_ThoughtSpot Liveboard filter operator -> Sigma control filter MODE (include/exclude). Drives the `_TS_FILTER_OP` dict (derived from these rows, no inline literal). An operator PRESENT but NOT in this table now WARNS loudly and falls back to `include` EXPLICITLY (never a silent wrong include default; [bead]). Separately, the CONTROL KIND is a compositional, cited decision in liveboard_controls(): a filter bound to a date/time column becomes a Sigma `date-range` control (a Sigma list control on a datetime target comes back empty — dead control — per help.sigmacomputing.com/docs/data-element-filters: 'For a Date column, the default is a date range filter'), and every other (categorical) filter becomes a `list` control (the documented default control kind, not a guess). That date-vs-list binary stays as code because it is driven by the target column's data type, not by an enumerable operator token._

Authoritative source: <https://docs.thoughtspot.com/cloud/latest/filters>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `IN` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `include` | 🟡 n | warn+include |
| | | | | _Membership include -> Sigma list control include mode._ |
| `EQ` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `include` | 🟡 n | warn+include |
| `=` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `include` | 🟡 n | warn+include |
| `EQUALS` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `include` | 🟡 n | warn+include |
| `NOT_IN` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `exclude` | 🟡 n | warn+include |
| | | | | _Membership exclude -> Sigma list control exclude mode._ |
| `NE` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `exclude` | 🟡 n | warn+include |
| `!=` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `exclude` | 🟡 n | warn+include |
| `NOT_EQUALS` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `exclude` | 🟡 n | warn+include |

## Workbook-as-code release features

_Audit of released Sigma workbook-as-code features against documented ThoughtSpot TML semantics. A target is emitted only where the source artifact carries equivalent intent; unrelated Sigma capabilities remain explicit gaps rather than invented dashboard behavior._

Authoritative source: <https://docs.thoughtspot.com/cloud/latest/tml-liveboards>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `liveboard-layout-tabs` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-liveboards) | `pages + navigation:auto` | 🟡 n | single content page |
| | | | | _Each ThoughtSpot tab becomes metadata-only page metadata and one authoritative layout Page block. Multi-tab workbooks receive an in-canvas auto navigation element on every content page._ |
| `chart-legend-formatting` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `element.legend` | 🟡 n | preserve Sigma default |
| | | | | _Known client-state visibility, title visibility, and placement values map to published Sigma legend fields; unknown settings are not guessed._ |
| `multi-level-axis-drill` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-answers) | — (explicit converter gap) | 🟡 n | flag-retain-first-x-axis-level |
| | | | | _Answer TML documents axis_configs only as axis column assignment, not as a persisted drill hierarchy. Sigma's released drill control exposes only id/kind/controlId/controlType and no authorable source, category, or target binding. Retain the first x-axis level, preserve deeper columns, and flag the missing interaction rather than inventing wiring._ |
| `standalone-legend-control` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-answers) | — (no source semantic to map) | 🟡 n | explicit-gap |
| | | | | _ThoughtSpot Answer TML carries per-chart advanced configuration through client_state but has no standalone legend-control artifact. Map recognized chart legend settings to element.legend; do not invent a separate controlType:legend element._ |
| `chart-series-styling` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `color + dataLabel + orientation + stacking` | 🟡 n | preserve Sigma default |
| | | | | _Existing series colors and labels are retained; bar orientation and stacked variants now preserve their source semantics._ |
| `control-formula-references` | [doc](https://docs.thoughtspot.com/cloud/latest/filters) | `controlId` | 🟡 n | record control gap |
| | | | | _Filter controls use controlId as the formula handle and double-nested value sources; element ids remain layout identity only._ |
| `grouped-scatter-source` | [doc](https://docs.thoughtspot.com/cloud/latest/chart-types) | `table groupingId` | 🟡 n | flag scatter parity |
| | | | | _Scatter/bubble charts retain their grouped hidden source and groupingId. Source-model joins remain data-model specs and are intentionally unchanged._ |
| `liveboard-tabs-as-tabbed-container` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-liveboards) | — (no source semantic to map) | 🟡 n | explicit-gap |
| | | | | _ThoughtSpot tabs are top-level dashboard pages, not alternate views sharing one region; mapping them to tabbed-container would change navigation semantics._ |
| `repeated-container` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-liveboards) | — (no source semantic to map) | 🟡 n | explicit-gap |
| | | | | _Liveboard TML has no documented row-repeating card construct. Do not invent a repeated-container from ordinary tiles._ |
| `page-break` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-liveboards) | — (no source semantic to map) | 🟡 n | explicit-gap |
| | | | | _Liveboard TML has no print-pagination marker. Emitting a Sigma page-break would invent source intent._ |
| `gauge-as-progress` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-answers) | — (explicit converter gap) | 🟡 n | flag-degrade-to-table |
| | | | | _Native progress requires trustworthy min/max/value formulas. Current ThoughtSpot TML extraction does not expose a stable gauge range, so GAUGE remains an explicit flagged fallback instead of a misleading progress bar._ |
| `workbook-panels` | [doc](https://docs.thoughtspot.com/cloud/latest/tml-liveboards) | — (no source semantic to map) | 🟡 n | explicit-gap |
| | | | | _ThoughtSpot Liveboard filters are in-canvas controls in this converter; no documented TML header/sidebar panel metadata is available to map. Existing Sigma panel metadata is nevertheless preserved on full-document PUT._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
