# QuickSight → Sigma: complexity taxonomy + 20-dashboard test slate

Reference for validating the quicksight-to-sigma skill against graduated complexity.
Grounded in the QuickSight `describe-analysis-definition` schema and cross-referenced
against this stack's known coverage + gaps.

## Converter / builder coverage snapshot
- **DM converter** (MCP `convert_quicksight_to_sigma`): handles RelationalTable, CustomSql,
  JoinInstruction, DataTransforms (CreateColumns/Rename/Cast/Filter/Project), calc fields
  (~40 functions; `ifelse`→If, `switch`→nested If). Params → Sigma controls.
- **DM GAPS**: window/table-calc functions (~28+: sumOver, runningSum, rank, lag/lead via
  periodOverPeriod*, percentOfTotal, window*, percentile*Over) → `/* TODO */` placeholder;
  S3Source & SaaSTable → placeholder; analysis-level FilterGroups → skipped;
  ColumnConfigurations (formatting) → skipped; dataset-of-datasets → out of scope.
- **Workbook builder** recreates (native Sigma kind): KPI, bar, line, area, donut/pie,
  combo, scatter, table, pivot, **region-map** (FilledMap + name-based GeospatialMap) and
  **point-map** (GeospatialMap with real lat/long), **progress** (Gauge), and
  **waterfall-chart**. Approximated (no native kind): funnel/treemap→bar; histogram→bar;
  heat-map/box-plot/sankey/word-cloud/radar→grouped table. Box remains release-gated. Dropped
  with a per-visual warning in `<out>.warnings.json` + STDERR: layer-map (multi-layer),
  insight (ML), customcontent, plugin, empty.
  - **Sigma's chart-kind universe used by this converter** (Aug-2026 workbook-code release):
    `kpi-chart`, `bar-chart`, `line-chart`, `area-chart`, `progress`, `waterfall-chart`,
    `pie-chart`, `donut-chart`, `scatter-chart`, `combo-chart`, `table`, `pivot-table`,
    `point-map`, `region-map`, `geography-map` (+ non-chart `control`/`text`/`image`/`embed`/
    `container`/`divider`/`navigation`/`page-break`/`repeated-container`). There is no
    histogram/heat-map/treemap/box-chart/radar/sankey/word-cloud kind in the released union.
    `region-map` persistence + query parity was verified live on the D17 DM.

## Visual catalog (API `Visual` union — 24 nodes) — per-node build status
**BUILT (native Sigma kind):** `KPIVisual`→kpi-chart, `BarChartVisual`→bar-chart,
`LineChartVisual`→line-chart, `PieChartVisual`→pie/donut-chart, `ComboChartVisual`→combo-chart,
`ScatterPlotVisual`→scatter-chart, `TableVisual`→table, `PivotTableVisual`→pivot-table,
`FilledMapVisual`→**region-map**, `GeospatialMapVisual`→**region-map** (name-based) or
**point-map** (lat/long), `GaugeChartVisual`→progress, `WaterfallVisual`→waterfall-chart.
**APPROXIMATED (no exact kind):** `FunnelChartVisual`→bar-chart, `TreeMapVisual`→bar-chart,
`HistogramVisual`→bar-chart, and `HeatMapVisual`/`BoxPlotVisual`/`SankeyDiagramVisual`/
`WordCloudVisual`/`RadarChartVisual`→grouped table. Every approximation warns; native
`box-chart` emission remains release-gated.
**(c)-TAIL — dropped with a per-visual warning:** `LayerMapVisual` (multi-layer),
`InsightVisual` (ML), `CustomContentVisual`, `PluginVisual`, `EmptyVisual` (no-op).

## Complexity axes (easy / medium / hard)
- **A. Data topology**: 1 RelationalTable → CustomSql → multi-table JoinInstruction → dataset-of-datasets(out of scope). S3/SaaS sources = GAP.
- **B. Data prep**: simple calc fields → transforms chain → window/table-calc funcs (GAP) / LAC.
- **C. Visual types**: KPI/bar/line/pie → mid catalog (table/pivot/combo/…) → maps/sankey → insight/custom/plugin (un-migratable).
- **D. Interactivity**: 1 filter control → param controls + relative-date → grounded hierarchy drill → cascading/cross-sheet FilterGroups and visual actions (GAP).
- **E. Layout**: single tiled grid → multi-sheet/fixed grid → free-form (pixel) / section-based (paginated). Grounded section breaks and single-dimension body repeats map to native page-break/repeated-container; other section semantics flatten loudly.
- **F. Governance/advanced**: text/images/themes → conditional formatting (GAP) → RLS/CLS → insight ML (un-migratable).

## The 20-dashboard slate (low → high)
**Tier 1 — trivial smoke (pass clean):**
- D1 Single KPI (total revenue). baseline happy path.
- D2 Bar by Region, simple `sum` calc.
- D3 Line trend + Pie mix (multi-element grid).

**Tier 2 — medium real-world:**
- D4 Exec summary: 4 KPIs + bar + line + 1 filter control (sheet scope).
- D5 CustomSql dataset → bar + **table** (table builder).
- D6 Two-dataset **JoinInstruction** (orders⋈customers) → bar + KPI (cross-element ref form).
- D7 **Parameters** + param controls (slider/dropdown) + what-if calc.
- D8 **Combo** (dual-axis) + **Scatter** (size+color).
- D9 **Gauge** + **Funnel** + **TreeMap**.
- D10 Data-prep **transforms** chain (Create/Rename/Cast/Filter) → bar+KPI on derived cols.

**Tier 3 — hard (hit gaps):**
- D11 **Pivot table** multi-level (2 row dims, 1 col, 2 measures, subtotals) — rowsBy/columnsBy `{id}` arrays.
- D12 **Window/table-calc** funcs (runningSum, percentOfTotal, rank, periodOverPeriod) → verify graceful `/* TODO */` degradation.
- D13 **Cascading + cross-sheet filters** (FilterGroup AllSheets) — FilterGroups GAP.
- D14 **Visual actions**: filter + navigation(+param) + URL — actions GAP (inventory/warn).
- D15 **Free-form layout** w/ overlap + text box + image.
- D16 **Section-based** paginated report (header/footer/page-break) + table.
- D17 **Maps**: geospatial points + filled choropleth. **BUILT (2026-06-06):** both →
  Sigma `region-map` (FilledMap STATE→us-state choropleth; GeospatialMap CITY→us-postal-place,
  since the dataset carries geo NAMES not lat/long — point-map is auto-selected only when real
  latitude+longitude fields are present). Live parity verified: avg-salary-by-state matches
  Snowflake exactly. Was 0 chart elements → now 2.
- D18 **Exotic zoo**: waterfall + sankey + boxplot + histogram + wordcloud + radar.
  Waterfall is native; histogram maps to bar; sankey/boxplot/wordcloud/radar preserve their
  fields in grouped tables with explicit warnings. Box remains gated until `box-chart` is in
  the published workbook element union.

**Tier 4 — very hard / governance + un-migratable:**
- D19 **RLS + CLS** secured + conditional formatting (color rules, data bars) on a table.
- D20 **Kitchen sink**: multi-dataset join + window calcs + cascading params + free-form + **InsightVisual (ML) + CustomContent + Plugin** — verify clean PARTIAL migration + full warning manifest.
- (optional D21: dataset-of-datasets recursion — negative test for the out-of-scope case.)

## Un-migratable → scope as known-(c)-tail, never "failed":
`InsightVisual` ML (forecast/anomaly/narrative); `CustomContentVisual` (iframe/HTML); `PluginVisual`
(Highcharts etc.); `LayerMapVisual`; unsupported SectionBasedLayout header/footer and
multi-dimension repeat semantics; free-form pixel overlap; cascading filter actions; SPICE
ingestion metadata; dataset-of-datasets recursion. Non-native visual fallbacks preserve data
and emit a structured `<out>.warnings.json` + STDERR line rather than silently disappearing.
**NOTE — the map family is NO LONGER (c)-tail:** `FilledMapVisual` and name/lat-long-based
`GeospatialMapVisual` now build natively (Sigma `region-map`/`point-map`); only the multi-layer
`LayerMapVisual` remains a warning.

_Doc sources: QuickSight API_Visual, AnalysisDefinition, FilterGroup/FilterScopeConfiguration,
LayoutConfiguration/GridLayoutConfiguration, custom-actions, table-calculation-functions, RLS/CLS, ML-insights._
