# Omni chartType → Sigma kind

`scripts/lib/omni_chart_map.rb` and `scripts/lib/omni_export.rb`. When
`visConfig.chartType` is `null` (common on Cartesian charts authored with a
Vega-Lite `visConfig.spec`), `omni_export.rb` infers the chart type from
`visConfig.visType`, `prefersChart`, `visConfig.spec.mark`, and
`visConfig.spec.series`. A missing or unsupported kind skips the tile into
`chart-gaps.json` (never guessed).

| Omni `chartType` / mark | Sigma `kind` |
|---|---|
| `line`, `lineColor` | `line-chart` |
| `area`, `areaStacked`, `areaPercent` | `area-chart` |
| `bar`, `column`, `columnStacked`, `columnPercent`, `barStacked`, `barPercent`, `groupedBar`, `groupedColumn` | `bar-chart` |
| `barLine`, `combo` | `combo-chart` |
| `scatter`, `point`, `circle`, `pointSize`, `pointSizeColor` | `scatter-chart` |
| `pie`, `donut`, `arc` | `pie-chart` |
| `kpi`, `omni-kpi` | `kpi-chart` |
| `table`, `omni-table` | `table` |
| `pivot`, `pivotTable` | `pivot-table` |
| `heatmap`, `rect` | `heatmap-chart` |
| `funnel` | `funnel-chart` |
| `sankey` | `sankey-chart` |
| `map` | `point-map` |
| `regionMap` | `region-map` |
| `boxplot` | `box-chart` |
| `markdown`, `omni-markdown`, `omni-ai-summary-markdown`, `singleRecord`, `vega`, `custom`, `iframe`, `embed`, `divider` | skip |

Date frames in `query.fields` (`orders.created_at[month]`,
`orders.created_at[day_of_week_name]`, etc.) compile through
`OmniFormula.timeframe_formula` on the hidden data element.
