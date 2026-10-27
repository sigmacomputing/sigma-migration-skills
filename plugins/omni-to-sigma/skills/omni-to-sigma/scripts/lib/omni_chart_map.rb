# frozen_string_literal: true
# Omni visConfig.chartType / Vega-Lite mark → Sigma element kind.
# Grounded in exploreomni/omni-agent-skills omni-content-builder visConfig.md
# and omni_dashboard_builder.py.
# Unknown / custom Vega / markdown tiles return nil so the workbook builder
# can skip them and record a gap instead of guessing a chart.

module OmniChartMap
  KIND = {
    'line' => 'line-chart',
    'lineColor' => 'line-chart',
    'area' => 'area-chart',
    'areaStacked' => 'area-chart',
    'areaPercent' => 'area-chart',
    'bar' => 'bar-chart',
    'column' => 'bar-chart',
    'columnStacked' => 'bar-chart',
    'columnPercent' => 'bar-chart',
    'barStacked' => 'bar-chart',
    'barPercent' => 'bar-chart',
    'groupedBar' => 'bar-chart',
    'groupedColumn' => 'bar-chart',
    'barLine' => 'combo-chart',
    'combo' => 'combo-chart',
    'scatter' => 'scatter-chart',
    'point' => 'scatter-chart',
    'circle' => 'scatter-chart',
    'pointSize' => 'scatter-chart',
    'pointSizeColor' => 'scatter-chart',
    'pie' => 'pie-chart',
    'donut' => 'pie-chart',
    'arc' => 'pie-chart',
    'kpi' => 'kpi-chart',
    'omni-kpi' => 'kpi-chart',
    'table' => 'table',
    'omni-table' => 'table',
    'pivot' => 'pivot-table',
    'pivotTable' => 'pivot-table',
    'heatmap' => 'heatmap-chart',
    'rect' => 'heatmap-chart',
    'funnel' => 'funnel-chart',
    'sankey' => 'sankey-chart',
    'map' => 'point-map',
    'regionMap' => 'region-map',
    'boxplot' => 'box-chart'
  }.freeze

  SKIP = %w[
    markdown
    omni-markdown
    omni-ai-summary-markdown
    singleRecord
    vega
    custom
    iframe
    embed
    divider
  ].freeze

  module_function

  def kind_for(chart_type)
    return nil if chart_type.nil? || chart_type.to_s.empty?
    return nil if SKIP.include?(chart_type.to_s)
    KIND[chart_type.to_s]
  end

  def known?(chart_type)
    !kind_for(chart_type).nil?
  end
end
