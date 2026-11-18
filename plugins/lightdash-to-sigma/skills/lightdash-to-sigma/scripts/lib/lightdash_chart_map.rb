# frozen_string_literal: true
# Lightdash chartConfig -> Sigma element kind (+ the per-kind chart options).
#
# THE MAPPING (refs/chart-map.md is written from this table):
#
#   Lightdash                                        Sigma
#   -----------------------------------------------  -------------------------------------------
#   cartesian, every series bar                      bar-chart (stacking: stacked when any series has `stack`)
#   cartesian, layout.flipAxes: true (bar)           bar-chart orientation: horizontal
#   cartesian, every series line                     line-chart
#   cartesian, line series with `areaStyle`          area-chart (stacking as for bar)
#   cartesian, every series scatter                  scatter-chart (x must be a dimension; a measure on x is a gap)
#   cartesian, mixed series types                    combo-chart (yAxis.columnIds entries carry {columnId, type};
#                                                    yAxisIndex 1 series are also listed on yAxis2)
#   big_number                                       kpi-chart
#   table                                            table (grouped by the dimensions); with pivotDimensions -> pivot-table
#   pie (isDonut: true)                              donut-chart (otherwise pie-chart)
#   funnel                                           funnel-chart (stage = first dimension, series = the measure)
#   treemap, gauge, map, sankey, custom (Vega),      NOT migrated: ledger gap + placeholder text element
#   data_app_viz, sql_chart, unknown types           naming the original chart
#
#   cartesian pivotDimensions                        the first pivot dimension becomes the `color` (category) channel
#   ECharts styling (colors, axis titles, labels,    ignored; one quality-waiver ledger note per workbook
#   legends, smoothing, ...)
#
# Notes that describe a lossy-but-built mapping are returned in 'notes' (strings);
# the builder turns each into a quality-waiver ledger entry. A mapping that cannot
# be built returns {'kind' => nil, 'gap' => reason}.
#
# Ruby 2.6-compatible, stdlib only.

module LightdashChartMap
  GAP_TYPES = {
    'treemap' => 'treemap', 'gauge' => 'gauge', 'map' => 'map', 'sankey' => 'sankey',
    'custom' => 'custom (Vega-Lite)', 'data_app_viz' => 'data app visualization'
  }.freeze

  SERIES_KIND = { 'bar' => 'bar', 'line' => 'line', 'area' => 'area', 'scatter' => 'scatter' }.freeze

  SIGMA_CARTESIAN = {
    'bar' => 'bar-chart', 'line' => 'line-chart', 'area' => 'area-chart', 'scatter' => 'scatter-chart'
  }.freeze

  module_function

  def gap(reason)
    { 'kind' => nil, 'gap' => reason }
  end

  def metric_query(chart)
    mq = chart['metricQuery']
    mq.is_a?(Hash) ? mq : {}
  end

  def pivot_dimensions(chart)
    pd = Array(metric_query(chart)['pivotDimensions'])
    pd = Array(chart.dig('pivotConfig', 'columns')) if pd.empty? && chart['pivotConfig'].is_a?(Hash)
    pd.map(&:to_s)
  end

  # Classify a parsed chart YAML. Returns a Hash:
  #   'kind'      Sigma element kind (nil => gap)
  #   'type'      the Lightdash chartConfig.type
  #   'notes'     [String] lossy-but-built mapping notes
  #   plus per-kind keys (see the *_info helpers)
  def classify(chart)
    return gap('chart is not a mapping') unless chart.is_a?(Hash)
    return gap('SQL Runner chart (contentType sql_chart) has no semantic-layer query to rebuild') if chart['contentType'].to_s == 'sql_chart' || (chart['sql'] && chart['metricQuery'].nil?)
    cfg = chart['chartConfig']
    return gap('chart has no chartConfig') unless cfg.is_a?(Hash)
    type = cfg['type'].to_s
    return gap("#{GAP_TYPES[type]} charts have no Sigma conversion in this skill") if GAP_TYPES.key?(type)

    case type
    when 'cartesian' then cartesian(chart, cfg)
    when 'big_number' then { 'kind' => 'kpi-chart', 'type' => type, 'notes' => [] }
    when 'table'
      pivot = pivot_dimensions(chart)
      notes = []
      notes << 'metricsAsRows is not carried to the Sigma pivot' if pivot.any? && cfg.dig('config', 'metricsAsRows') == true
      { 'kind' => pivot.empty? ? 'table' : 'pivot-table', 'type' => type, 'pivot' => pivot, 'notes' => notes }
    when 'pie'
      donut = cfg.dig('config', 'isDonut') == true
      { 'kind' => donut ? 'donut-chart' : 'pie-chart', 'type' => type, 'notes' => [] }
    when 'funnel' then { 'kind' => 'funnel-chart', 'type' => type, 'notes' => [] }
    else gap("unrecognized chart type #{type.inspect}")
    end
  end

  # series entry -> 'bar' | 'line' | 'area' | 'scatter' (nil when unknown)
  def series_kind(series)
    t = series['type'].to_s
    return 'area' if t == 'line' && series.key?('areaStyle') && !series['areaStyle'].nil?
    SERIES_KIND[t]
  end

  def cartesian(chart, cfg)
    config = cfg['config'].is_a?(Hash) ? cfg['config'] : {}
    layout = config['layout'].is_a?(Hash) ? config['layout'] : {}
    series = Array(config.dig('eChartsConfig', 'series')).select { |s| s.is_a?(Hash) }
    notes = []

    by_field = {}   # y fieldId -> 'bar'|'line'|'area'|'scatter'
    secondary = []
    series.each do |s|
      field = s.dig('encode', 'yRef', 'field').to_s
      next if field.empty?
      kind = series_kind(s)
      if kind.nil?
        notes << "series type #{s['type'].inspect} is not a Sigma cartesian shape; drawn as bars"
        kind = 'bar'
      end
      by_field[field] ||= kind
      secondary << field if s['yAxisIndex'].to_i == 1 && !secondary.include?(field)
    end

    kinds = by_field.values.uniq
    kinds = ['bar'] if kinds.empty?
    flip = layout['flipAxes'] == true
    stacked = series.any? { |s| !s['stack'].nil? && s['stack'].to_s != '' && s['stack'] != false }

    kind =
      if kinds.length > 1 then 'combo-chart'
      else SIGMA_CARTESIAN[kinds.first]
      end

    orientation = nil
    if flip
      if kind == 'bar-chart' then orientation = 'horizontal'
      else notes << "flipAxes is only mapped for bar charts; #{kind} drawn with the default orientation"
      end
    end

    stacking = nil
    if stacked
      if %w[bar-chart area-chart].include?(kind) then stacking = 'stacked'
      else notes << "series stacking is not mapped for #{kind}; drawn unstacked"
      end
    end

    notes << 'secondary y-axis series are listed on yAxis2 only for combo charts' if secondary.any? && kind != 'combo-chart'

    {
      'kind' => kind, 'type' => 'cartesian', 'notes' => notes,
      'orientation' => orientation, 'stacking' => stacking,
      'x_field' => layout['xField'].to_s.empty? ? nil : layout['xField'].to_s,
      'y_fields' => Array(layout['yField']).map(&:to_s),
      'series_types' => by_field,
      'secondary' => kind == 'combo-chart' ? secondary : [],
      'pivot' => pivot_dimensions(chart)
    }
  end
end
