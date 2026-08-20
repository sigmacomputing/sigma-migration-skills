#!/usr/bin/env ruby
#   ruby test/test-mode-chart-map.rb
require_relative '../scripts/lib/mode_chart_map'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== ModeChartMap.sigma_kind_for =="
eq(ModeChartMap.sigma_kind_for('Bar'),           'bar-chart',   'Bar -> bar-chart')
eq(ModeChartMap.sigma_kind_for('Line'),          'line-chart',  'Line -> line-chart')
eq(ModeChartMap.sigma_kind_for('Area'),          'area-chart',  'Area -> area-chart')
eq(ModeChartMap.sigma_kind_for('Scatter'),       'scatter-chart', 'Scatter -> scatter-chart')
eq(ModeChartMap.sigma_kind_for('Pie'),           'pie-chart',   'Pie -> pie-chart')
eq(ModeChartMap.sigma_kind_for('Line Plus Bar'), 'combo-chart', 'Line Plus Bar -> combo-chart')
eq(ModeChartMap.sigma_kind_for('Pivot Table'),   'pivot-table', 'Pivot Table -> pivot-table')
# The one Domo-style rule: never downgrade a single-value chart to a table.
eq(ModeChartMap.sigma_kind_for('Big Number'),    'kpi-chart',   'Big Number -> kpi-chart (never a table)')

begin
  ModeChartMap.sigma_kind_for('Something New')
  $failures += 1; puts "  FAIL: unknown chart type should raise, not silently default"
rescue ModeChartMap::UnknownChartType => e
  eq(e.message.include?('Something New'), true, 'unknown chart type raises naming the type')
end

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
