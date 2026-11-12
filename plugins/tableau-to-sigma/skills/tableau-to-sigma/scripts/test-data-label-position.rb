#!/usr/bin/env ruby
# frozen_string_literal: true

# Plan C2: unstacked bar/column data labels default to dataLabel.anchor =
# "outside-end" (Sigma's schema field is `anchor`, not `position`; "end" would
# render white labels INSIDE the bar). An explicit source label alignment maps
# to the nearest anchor; stacked bars and non-bar kinds are left unchanged.
require_relative 'lib/builder_test_harness'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

H = BuilderTestHarness
z = lambda do |id, cap, **kw|
  extra = { 'mark_labels_show' => true }.merge(kw.delete(:extra) || {})
  H.chart_zone(id: id, caption: cap, extra: extra, **kw)
end
zones = [
  z.call('a', 'Bar Default'),
  z.call('b', 'Bar Horizontal', dim_on_rows: true),
  z.call('c', 'Bar Inside', extra: { 'mark_label_align' => 'inside' }),
  z.call('d', 'Bar Center', extra: { 'mark_label_align' => 'center' }),
  z.call('e', 'Bar Base', extra: { 'mark_label_align' => 'base' }),
  z.call('f', 'Line Labels', chart_kind: 'line', mark_class: 'Line', dim: 'Order Date'),
  z.call('g', 'Bar Stacked', extra: { 'channels' => { 'color' => { 'column' => '[Segment]' } } }),
  z.call('h', 'Bar NoLabels', extra: { 'mark_labels_show' => false })
]
res = H.run(zones)
ok(res[:status].success?, 'builder exits 0')
by = ->(re) { H.find_chart(res, re) }

el = by.call(/Bar Default/)
ok(el && el['dataLabel'] && el['dataLabel']['anchor'] == 'outside-end', 'bar labels outside-end by default')
ok(el && el['dataLabel']['labels'] == 'shown', 'labels still shown')
ok(by.call(/Bar Horizontal/)&.dig('dataLabel', 'anchor') == 'outside-end', 'horizontal bar labels outside-end')
el2 = by.call(/Bar Inside/)
ok(el2 && el2['dataLabel']['anchor'] == 'end', 'signal-level: explicit inside alignment maps to end')
ok(by.call(/Bar Center/)&.dig('dataLabel', 'anchor') == 'middle', 'signal-level: explicit centre alignment maps to middle')
ok(by.call(/Bar Base/)&.dig('dataLabel', 'anchor') == 'start', 'signal-level: explicit base alignment maps to start')
el3 = by.call(/Line Labels/)
ok(el3 && !el3['dataLabel'].to_h.key?('anchor'), 'line labels unchanged')
el4 = by.call(/Bar Stacked/)
ok(el4 && el4['dataLabel'] && !el4['dataLabel'].key?('anchor'), 'stacked bars unchanged (no anchor)')
ok(by.call(/Bar NoLabels/) && !by.call(/Bar NoLabels/).key?('dataLabel'), 'no labels when the source shows none')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
