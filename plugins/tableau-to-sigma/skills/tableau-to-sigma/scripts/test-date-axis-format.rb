#!/usr/bin/env ruby
# frozen_string_literal: true

# Plan C8: date axis label format follows the grain / source format, and the
# time scale + tick spacing come only from source facts (explicit Tableau
# major-tick settings). Drives the real builder offline.

require 'json'
require_relative 'lib/builder_test_harness'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

H = BuilderTestHarness
def date_zone(cap, deriv, extra = {})
  H.chart_zone(id: cap, caption: cap, chart_kind: 'line', mark_class: 'Line', dim: 'Order Date',
               extra: { 'aggregations' => { '[Order Date]' => deriv, '[Net Revenue]' => 'Sum' } }.merge(extra))
end

dec23 = 1_701_388_800_000 # 2023-12-01 UTC
zones = [
  date_zone('Month Line', 'Month-Trunc'),
  date_zone('Custom Line', 'Month-Trunc',
            'formats' => { '[ds].[tmn:Order Date:qk]' => 'mm/yyyy' }),
  date_zone('Quarter Line', 'Quarter-Trunc',
            'formats' => { '[ds].[tqr:Order Date:qk]' => 'mmm yyyy' }),
  date_zone('Week Line', 'Week-Trunc'),
  date_zone('Year Line', 'Year-Trunc'),
  date_zone('Ticked Line', 'Month-Trunc',
            'axis_formats' => [{ 'scope' => 'cols', 'class' => '0', 'major_origin' => '#2023-12-01#',
                                 'major_spacing' => '3', 'major_units' => 'months' }]),
  date_zone('Quarter Ticked', 'Month-Trunc',
            'axis_formats' => [{ 'scope' => 'cols', 'class' => '0', 'major_origin' => '#2023-12-15 00:00:00#',
                                 'major_spacing' => '1', 'major_units' => 'quarters' }]),
  date_zone('Range Only Line', 'Month-Trunc',
            'axis_formats' => [{ 'scope' => 'cols', 'class' => '0', 'range_type' => 'fixed',
                                 'min' => 0.0, 'max' => 0.0, 'min_raw' => '#2024-01-01#',
                                 'major_spacing' => '1', 'major_units' => 'months' }]),
  date_zone('No Origin Line', 'Month-Trunc',
            'axis_formats' => [{ 'scope' => 'cols', 'class' => '0', 'major_spacing' => '3',
                                 'major_units' => 'months' }]),
  date_zone('Y Fixed Line', 'Month-Trunc',
            'axis_formats' => [{ 'scope' => 'rows', 'class' => '0', 'range_type' => 'fixed', 'min' => 0.0,
                                 'max' => 24_000.0, 'major_spacing' => '2000' }]),
  date_zone('Y Auto Line', 'Month-Trunc',
            'axis_formats' => [{ 'scope' => 'rows', 'class' => '0', 'range_type' => 'fixed', 'min' => 0.0,
                                 'max' => 24_000.0 }])
]
res = H.run(zones)
ok(res[:status].success?, 'builder exits 0')
by = ->(re) { H.find_chart(res, re) }
fmt = lambda do |re|
  el = by.call(re)
  xc = el && el['columns'].find { |c| c['id'] == el.dig('xAxis', 'columnId') }
  xc && xc['format']
end
fs = ->(re) { (f = fmt.call(re)) && f['formatString'] }

ok(fs.call(/Month Line/) == '%b %Y', "month grain -> %b %Y (got #{fs.call(/Month Line/).inspect})")
ok(fs.call(/Custom Line/) == '%m/%Y', "source custom format honoured (got #{fs.call(/Custom Line/).inspect})")
ok(fmt.call(/Quarter Line/).nil?, "quarter grain ignores a source month format (got #{fmt.call(/Quarter Line/).inspect})")
ok(fs.call(/Week Line/) == '%b %d, %Y', 'week grain -> %b %d, %Y')
ok(fs.call(/Year Line/) == '%Y', 'year grain -> %Y')

ml = by.call(/Month Line/)
ok(ml.dig('xAxis', 'format', 'scale') == { 'type' => 'time' }, 'datetime x axis gets scale time')
ok(!ml.dig('xAxis', 'format').key?('tickSpacing'), 'no source tick facts -> no tickSpacing (auto)')
ok(ml.dig('xAxis', 'format', 'title', 'text') == 'Order Date', 'C3 axis title kept alongside scale')
ok(ml.dig('xAxis', 'format', 'labels'), 'tick label format kept alongside scale')

tl = by.call(/Ticked Line/)
ok(tl.dig('xAxis', 'format', 'tickSpacing') ==
   { 'type' => 'interval', 'scale' => 'time', 'unit' => 'month', 'step' => 3, 'anchor' => dec23 },
   "tickSpacing from major-origin/spacing/units (got #{tl.dig('xAxis', 'format', 'tickSpacing').inspect})")
ok(tl.dig('xAxis', 'format', 'scale') == { 'type' => 'time' }, 'scale stays time with ticks (no domain on a date axis)')

qt = by.call(/Quarter Ticked/)
ok(qt.dig('xAxis', 'format', 'tickSpacing') ==
   { 'type' => 'interval', 'scale' => 'time', 'unit' => 'month', 'step' => 3, 'anchor' => dec23 },
   'quarters unit -> month x3; anchor snaps to the 1st of the origin month')

rl = by.call(/Range Only Line/)
ok(rl.dig('xAxis', 'format', 'tickSpacing', 'anchor') == 1_704_067_200_000,
   'anchor falls back to the fixed axis start')
ok(rl.dig('xAxis', 'format', 'scale') == { 'type' => 'time' }, 'date range never becomes a numeric domain')

ok(!by.call(/No Origin Line/).dig('xAxis', 'format').key?('tickSpacing'), 'step without any anchor fact -> omitted')

yf = by.call(/Y Fixed Line/)
ok(yf.dig('yAxis', 'format', 'scale') == { 'type' => 'linear', 'domain' => { 'min' => 0.0, 'max' => 24_000.0 } },
   "y fixed domain + linear type (got #{yf.dig('yAxis', 'format', 'scale').inspect})")
ok(yf.dig('yAxis', 'format', 'tickSpacing') == { 'type' => 'interval', 'scale' => 'linear', 'step' => 2000, 'anchor' => 0 },
   "y tickSpacing from explicit step, anchor = fixed min (got #{yf.dig('yAxis', 'format', 'tickSpacing').inspect})")
ya = by.call(/Y Auto Line/)
ok(!ya.dig('yAxis', 'format').key?('tickSpacing'), 'y without explicit step -> no tickSpacing')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
