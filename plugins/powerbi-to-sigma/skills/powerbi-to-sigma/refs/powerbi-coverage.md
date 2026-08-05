# Powerbi → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill powerbi --out refs/powerbi-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing (beads-sigma-kvza).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 43 documented constructs across 5 dimensions; 3 live-verified.

## Visualization / chart kind

_Power BI visual -> Sigma workbook element kind + ROLE CLASS. `source` is the coarse kind token the builder consumes (rec['sigma_kind']); `sigma` is the Sigma element kind; `pbi_visual_types` enumerates the raw PBI visualTypes feeding that token; `role_class` (control|kpi|chart|table|text|image|decoration|unsupported) says what the visual DOES, so the coverage gate can tell a functional loss (a lost slicer = the page lost its filter) from a cosmetic one (a lost decorative shape) from a DIFFERENT cosmetic one that still builds a real element when it can (a logo/banner `image`, which — unlike `decoration` — is never routed to a bare 'nothing built' skip; PbiVizKind.functional? still treats it as non-functional). Both the Ruby builder AND the Python extractors resolve through this one file via lib/pbi_viz_kind.{rb,py} — the previously-duplicated Python VISUAL_KIND dict is gone, so the two maps can no longer drift. Third-party/custom visuals live in custom-visual.json._

Authoritative source: <https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-types-for-reports-and-q-and-a>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `kpi` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-kpi) | `kpi-chart` | ✅ y · 2026-07-13 | n/a |
| | | | | _PBI card / multiRowCard / kpi / gauge -> Sigma kpi-chart. gauge and kpiMatrix have no native Sigma kind (approximated -> approximate_types below); card/multiRowCard/kpi/cardVisual ARE native (approximate:false). A multiRowCard fans out to one kpi-chart per measure in the builder. `cardVisual` is the MODERN card visual type (PBI 2023+); it was absent from the old map and silently became a bar-chart on real customer files._ |
| `bar` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-types-for-reports-and-q-and-a) | `bar-chart` | ✅ y · 2026-07-13 | n/a |
| | | | | _*Bar* families render horizontal (orientation:horizontal), *Column* families vertical (omit orientation). Stacking none\|stacked\|normalized from the type name. hundredPercentStackedBarChart is now mapped explicitly (it previously fell through the Python `VISUAL_KIND.get(vt,'bar')` default). waterfall/funnel/treemap/ribbon/histogram are DATA-PRESERVING bar approximations -> approximate:true, so they are reported as approximated, not as losses._ |
| `line` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-types-for-reports-and-q-and-a) | `line-chart` | 🟡 n | n/a |
| | | | | _Defaults to a SINGLE series unless a Series/Legend role is bound (bead c07)._ |
| `area` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-basic-area-chart) | `area-chart` | 🟡 n | n/a |
| `combo` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-combo-chart) | `combo-chart` | 🟡 n | n/a |
| | | | | _Line + column combo; the line measure(s) go on Sigma's secondary yAxis2._ |
| `scatter` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-types-for-reports-and-q-and-a) | `scatter-chart` | 🟡 n | n/a |
| `pie` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-types-for-reports-and-q-and-a) | `pie-chart` | 🟡 n | n/a |
| `donut` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-doughnut-charts) | `donut-chart` | 🟡 n | n/a |
| `table` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/desktop-tables) | `table` | 🟡 n | n/a |
| `pivot-table` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/desktop-matrix-visual) | `pivot-table` | 🟡 n | n/a |
| | | | | _PBI matrix/tableEx show a bold Grand Total row by default -> Sigma pivot totals block._ |
| `text` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-types-for-reports-and-q-and-a) | `text` | 🟡 n | n/a |
| | | | | _Boxes >= ~60px tall render as an H2 heading; smaller boxes as plain body text._ |
| `control` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-slicers) | `control` | 🟡 n | n/a |
| | | | | _PBI slicer -> Sigma control. list vs date-range is decided in code (tmsl_date_column?); see control.json._ |
| `map` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-filled-maps-choropleths) | `map` | 🟡 n | n/a |
| | | | | _Resolved to a Sigma region-map or point-map by resolve_map_kind using the model.bim geo dataCategory._ |
| `image` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-types-for-reports-and-q-and-a) | `image` | 🟡 n | n/a |
| | | | | _Set directly by extract-report-classic.py for an imageUrl resource (extract-pbir.py has no 'image' visualType). Sigma images are URL-only: needs --image-map {resource: hostedUrl} or the element is skipped with a note. role_class is its OWN 'image', distinct from 'decoration': an image DOES build a real Sigma element (given --image-map) and has its own dedicated coverage entry when it can't (severity:dropped, recoverable — 'Supply --image-map'), unlike a shape/blank which never builds anything and is genuinely cosmetic. Reusing 'decoration' here made every image visual return nil before ever reaching its own build/coverage logic — a regression caught in review._ |
| `decoration` | [doc](https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-shapes-add-report) | — (no Sigma equivalent) | 🟡 n | skip-silently-ok |
| | | | | _Previously coerced to a bar-chart, producing phantom empty charts (5 measured across 2 customer files)._ |
| `unsupported` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-types-for-reports-and-q-and-a) | — (no Sigma equivalent) | 🟡 n | warn+record-unsupported |
| | | | | _These previously became bar charts. A bar chart of a decomposition tree is not an approximation, it is a wrong answer — hence role_class unsupported, reported honestly._ |

## Number format

_Power BI numeric format CATEGORY -> Sigma column format object. VERBATIM extraction of build-workbook-from-pbir.rb's PBI_FMT hash: `source` is the format category and `sigma` is the d3-format string that goes into { kind:'number', formatString:<sigma> } (Sigma rejects raw Excel masks like '#,##0'). The builder's sigma_format(hint) is a COMPOSITIONAL parser over the PBI format-HINT string (from signals 'formats' / master-map field 'format' — NOT the column name), so it stays as cited code; it only ever RETURNS one of these catalog entries, and falls back to nil (unformatted) when no hint matches. There is no silent concrete default to kill here — this dimension is graded 'light' — but PBI_FMT is grounded so the four format strings can never drift from the doc._

Authoritative source: <https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-custom-format-strings>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `currency` | [doc](https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-custom-format-strings) | `$,.0f` | 🟡 n | nil (unformatted) |
| | | | | _Matched by hint =~ /\$\|currency\|USD/i. d3 '$,.0f' = leading $, thousands sep, 0 decimals._ |
| `percent` | [doc](https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-custom-format-strings) | `.1%` | 🟡 n | nil (unformatted) |
| | | | | _Matched by hint =~ /%\|percent/i. d3 '%' multiplies by 100 like PBI._ |
| `comma` | [doc](https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-custom-format-strings) | `,.1f` | 🟡 n | nil (unformatted) |
| | | | | _Matched by hint =~ /#,##0\|,/. Thousands sep, 1 decimal._ |
| `integer` | [doc](https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-custom-format-strings) | `,.0f` | 🟡 n | nil (unformatted) |
| | | | | _Matched by hint =~ /^#,?#?0$\|integer\|whole/i. Thousands sep, no decimals._ |

## Aggregation

_DOCUMENTATION-ONLY. There is no aggregation HASH in build-workbook-from-pbir.rb to ground: measure_formula() reads the aggregator verbatim from the master-map's per-field `agg` string (Sum/Count/CountDistinct/Avg/Min/Max, or a full formula / '?'-placeholder / agg_args form) and explicitly NEVER invents one from a measure name. That upstream decision is a DAX-analysis step (the master-map author / migrate-powerbi.rb translates each DAX measure to a Sigma aggregate). This table documents the canonical DAX-aggregation-function -> Sigma-aggregate-function correspondence those decisions follow so it is reviewable and cited, but the builder does NOT load it (nothing to derive). No silent default exists here to make loud._

Authoritative source: <https://learn.microsoft.com/en-us/dax/aggregation-functions-dax>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `SUM` | [doc](https://learn.microsoft.com/en-us/dax/sum-function-dax) | `Sum` | ✅ y · 2026-07-13 | n/a |
| | | | | _DAX SUM / SUMX aggregate -> Sigma Sum._ |
| `COUNT` | [doc](https://learn.microsoft.com/en-us/dax/count-function-dax) | `Count` | 🟡 n | n/a |
| | | | | _DAX COUNT / COUNTA / COUNTROWS -> Sigma Count._ |
| `DISTINCTCOUNT` | [doc](https://learn.microsoft.com/en-us/dax/distinctcount-function-dax) | `CountDistinct` | 🟡 n | n/a |
| | | | | _DAX DISTINCTCOUNT -> Sigma CountDistinct._ |
| `AVERAGE` | [doc](https://learn.microsoft.com/en-us/dax/average-function-dax) | `Avg` | 🟡 n | n/a |
| | | | | _DAX AVERAGE / AVERAGEX -> Sigma Avg._ |
| `MIN` | [doc](https://learn.microsoft.com/en-us/dax/min-function-dax) | `Min` | 🟡 n | n/a |
| | | | | _DAX MIN / MINX -> Sigma Min._ |
| `MAX` | [doc](https://learn.microsoft.com/en-us/dax/max-function-dax) | `Max` | 🟡 n | n/a |
| | | | | _DAX MAX / MAXX -> Sigma Max._ |

## Control / filter

_Power BI slicer -> Sigma control kind. A PBI slicer is a single visualType; the list-vs-date choice is COMPOSITIONAL (decided in code by tmsl_date_column? against the TMSL model), so this table grounds the two target kinds the builder resolves at its call sites rather than a flat visualType map. `slicer` (categorical column) -> a Sigma `list` control (the documented default). `slicer:date` (the sliced column is date/datetime-typed) -> a `date-range` control: a `list` control bound to a datetime column has its filter targets SILENTLY STRIPPED by Sigma on POST (estate-repair gotcha), so a date slicer MUST become date-range. Both branches were ALREADY loud (unresolvable column -> warn+skip); this pass only grounds the two literal control-kind strings in the catalog._

Authoritative source: <https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-slicers>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `slicer` | [doc](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-slicers) | `list` | 🟡 n | warn+skip |
| | | | | _Categorical list control (documented default): controlType:list + mode:include + selectionMode:multiple + source{kind:source,...} + filters[]. A slicer bound to a date column is overridden to date-range in code._ |
| `slicer:date` | [doc](https://learn.microsoft.com/en-us/power-bi/create-reports/power-bi-slicer-numeric-range) | `date-range` | 🟡 n | warn+skip |
| | | | | _Date/datetime-typed slicer: controlType:date-range + mode:between + includeNulls. Needs NO source (columns come from filters[]) but DOES require the flat mode or the POST 400s 'Invalid kind: control'._ |

## custom-visual

_Third-party / AppSource Power BI custom visuals -> Sigma element or control. A custom visual's `visualType` in the report Layout is the vendor's package id, so it is matched by CASE-INSENSITIVE REGEX on that token (`match`), first row wins, rather than by exact key. This catalog exists because the pipeline previously coerced every unrecognized visualType to a bar chart: on 4 real customer .pbix files that turned 21 third-party DATE-PICKER SLICERS into bar charts, silently removing the date filter from nearly every page. `role_class` control means the visual FILTERS and must become a Sigma control targeting the page's base element -- never a chart. `sigma_target` is the concrete Sigma control/element kind; `sigma` is the coarse builder token (rec['sigma_kind']). Vendor ids drift between releases, so patterns match the STABLE product-name substring, and lib/pbi_viz_kind.{rb,py} applies a generic slicer/filter/picker heuristic after this catalog so an unlisted filtering visual still lands as a control rather than a bogus chart._

Authoritative source: <https://learn.microsoft.com/en-us/power-bi/developer/visuals/power-bi-custom-visuals>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `powerviz-datepicker` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/powerviz1667398390543.datepickerbypowerviz) | `control` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| | | | | _Measured 21 instances across 3 of 4 customer reports (7 + 9 + 5), every one previously emitted as a bar chart. This single row is the highest-impact entry in the catalog._ |
| `chiclet-slicer` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA104380756) | `control` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| | | | | _One of the most common custom visuals in the wild._ |
| `hierarchy-slicer` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA104380820) | `control` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| | | | | _Common with org / geography hierarchies -- exactly the org-hierarchy shape in customer report R1._ |
| `timeline-slicer` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA104380786) | `control` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| `text-filter` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA104381353) | `control` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| `play-axis` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA200001304) | — (no Sigma equivalent) | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| `zebra-bi` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/zebrabi.zebrabicharts) | `pivot-table` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| | | | | _Data and numbers are fully recoverable; only the IBCS styling is lost._ |
| `inforiver` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/inforiver.inforiver) | `pivot-table` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| | | | | _Writeback usage is a scope decision, not a mechanical conversion -- always surface it._ |
| `drill-down-zoomcharts` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/zoomcharts.drilldowncombobar) | `bar` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| `icon-map` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA200001708) | `map` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| | | | | _Measured 1 iconMapPro instance in customer report R1._ |
| `bullet-chart` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA104380750) | `bar` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| `gantt` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA104380765) | `table` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| `sankey-wordcloud-network` | [doc](https://learn.microsoft.com/en-us/power-bi/developer/visuals/power-bi-custom-visuals) | — (no Sigma equivalent) | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| | | | | _Grouped into one row because the guidance and the decision are identical for all of them._ |
| `infographic-cardbrowser` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA104381044) | `kpi` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |
| `calendar-heatmap` | [doc](https://appsource.microsoft.com/en-us/product/power-bi-visuals/WA200001930) | `pivot-table` | 🟡 n | warn+record-unsupported (NEVER coerce a custom visual to a chart) |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
