#!/usr/bin/env ruby
# frozen_string_literal: true

# Defect 8: never emit xAxis/yAxis format.title without non-empty text (Sigma
# dry-run 400 "requires non-empty text"). sanitize_axis_titles! is the final
# pass over the whole output; extracted from the builder source and exercised
# directly (the builder is a run-on-load script).

require 'json'

src = File.read(File.join(__dir__, 'build-charts-from-signals.rb'), encoding: 'UTF-8')
m = src.match(/^def sanitize_axis_titles!.*?^end\n/m)
abort 'FAIL sanitize_axis_titles! not found' unless m
eval(m[0]) # rubocop:disable Security/Eval

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

tree = {
  'pages' => [{ 'elements' => [
    { 'id' => 'a', 'xAxis' => { 'format' => { 'title' => { 'fontSize' => 10 }, 'labels' => { 'fontSize' => 11 } } },
      'yAxis' => { 'format' => { 'title' => { 'text' => 'Sales', 'fontSize' => 10 } } } },
    { 'id' => 'b', 'xAxis' => { 'format' => { 'title' => { 'text' => '  ', 'fontSize' => 10 } } },
      'yAxis' => { 'format' => { 'title' => { 'text' => nil, 'fontSize' => 10 } } } },
    { 'id' => 'c', 'xAxis' => { 'format' => { 'title' => 'bare' } } }
  ] }]
}
n = sanitize_axis_titles!(tree)
els = tree['pages'][0]['elements']
ok(!els[0]['xAxis']['format'].key?('title'), 'fontSize-only xAxis title removed')
ok(els[0]['xAxis']['format']['labels'] == { 'fontSize' => 11 }, 'sibling label format untouched')
ok(els[0]['yAxis']['format']['title']['text'] == 'Sales', 'valid yAxis title kept')
ok(!els[1]['xAxis']['format'].key?('title') && !els[1]['yAxis']['format'].key?('title'), 'blank / nil text titles removed')
ok(!els[2]['xAxis']['format'].key?('title'), 'non-object title removed')
ok(n == 4, "removal count (got #{n})")
ok(src.scan('sanitize_axis_titles!(').size >= 5, 'builder runs the pass at every output write site')
ok(src.include?("unless dim_title.strip.empty?"), 'xAxis emitter guards empty text')

# --- Plan C3: category-axis title follows the source -------------------------
require_relative 'lib/builder_test_harness'
H = BuilderTestHarness
zone = lambda do |id, cap, extra = {}, **kw|
  H.chart_zone(id: id, caption: cap, extra: extra, **kw)
end
zones = [
  zone.call('s', 'Shown Line', {}, chart_kind: 'line', mark_class: 'Line', dim: 'Order Date'),
  zone.call('c', 'Cleared Bar', { 'axis_titles' => [{ 'scope' => 'cols', 'class' => '0', 'text' => '' }] }),
  zone.call('d', 'Display Off Bar', { 'axis_titles' => [{ 'scope' => 'cols', 'class' => '0', 'hidden' => true }] }),
  zone.call('f', 'Field Labels Off', { 'field_labels_hidden' => ['cols'] }),
  zone.call('h', 'Cleared Horizontal', { 'axis_titles' => [{ 'scope' => 'rows', 'class' => '0', 'text' => '' }] },
            dim_on_rows: true),
  zone.call('m', 'Custom Bar', { 'axis_titles' => [{ 'scope' => 'cols', 'class' => '0', 'text' => 'Sales Region' }] }),
  zone.call('v', 'Measure Cleared Bar', { 'axis_titles' => [{ 'scope' => 'rows', 'class' => '0', 'text' => '' }] })
]
res = H.run(zones)
ok(res[:status].success?, 'builder exits 0')
by = ->(re) { H.find_chart(res, re) }
el2 = by.call(/Shown Line/)
ok(el2 && el2.dig('xAxis', 'format', 'title', 'text') == 'Order Date', 'shown source title kept with source text')
el = by.call(/Cleared Bar/)
ok(el && !el.dig('xAxis', 'format').key?('title'), 'hidden source axis title -> no title emitted')
ok(el && el.dig('xAxis', 'format', 'labels'), 'tick labels untouched when the title is dropped')
ok(el && !el['xAxis']['format'].key?('visibility'), 'never format.visibility hidden')
ok(!by.call(/Display Off Bar/).dig('xAxis', 'format').key?('title'), 'axis header off -> no title')
ok(!by.call(/Field Labels Off/).dig('xAxis', 'format').key?('title'), 'field labels off -> no title (unchanged)')
ok(!by.call(/Cleared Horizontal/).dig('xAxis', 'format').key?('title'), 'horizontal bar: rows-scope clear drops the category title')
ok(by.call(/Custom Bar/).dig('xAxis', 'format', 'title', 'text') == 'Sales Region', 'z[axis_titles] custom text overrides the dimension name')
vb = by.call(/Measure Cleared Bar/)
ok(vb.dig('xAxis', 'format', 'title', 'text') == 'Region' && !vb.dig('yAxis', 'format').to_h.key?('title'),
   'clearing the measure axis leaves the category title and drops the measure one')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
