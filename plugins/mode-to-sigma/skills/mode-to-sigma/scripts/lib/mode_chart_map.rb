# Maps Mode's view.selectedChart to a Sigma chart-element `kind`.
# Confirmed Sigma kinds: sigma-workbooks reference/specification/{charts,tables}.md.
module ModeChartMap
  class UnknownChartType < StandardError; end

  SIGMA_KIND = {
    'Bar'           => 'bar-chart',
    'Line'          => 'line-chart',
    'Area'          => 'area-chart',
    'Scatter'       => 'scatter-chart',
    'Pie'           => 'pie-chart',
    'Line Plus Bar' => 'combo-chart',
    'Pivot Table'   => 'pivot-table',
    # Never downgrade a single-value chart to a table — same rule the
    # domo-to-sigma converter learned the hard way for Summary Number cards.
    'Big Number'    => 'kpi-chart'
  }.freeze

  module_function

  def sigma_kind_for(mode_chart_type)
    SIGMA_KIND.fetch(mode_chart_type) do
      raise UnknownChartType, "no Sigma mapping for Mode chart type #{mode_chart_type.inspect} " \
                               "(known types: #{SIGMA_KIND.keys.join(', ')})"
    end
  end
end
