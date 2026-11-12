#!/usr/bin/env ruby
# frozen_string_literal: true

# Plan C11: a list control that maps a Tableau quick filter left at (All) carries
# placeholder:"All" (empty-state text) with values:[] so nothing is filtered. A
# quick filter with a specific saved selection keeps Sigma's default placeholder.
require_relative 'lib/builder_test_harness'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

H = BuilderTestHarness
filter = lambda do |caption, members, extra = {}|
  { 'raw_class' => 'categorical', 'column_caption' => caption, 'column_guid' => caption,
    'datatype' => 'string', 'is_action' => false, 'kind' => 'list', 'members' => members }.merge(extra)
end
meta = { 'shared_filters' => [
  filter.call('Region', []),
  filter.call('Segment', %w[Consumer])
] }
res = H.run([H.chart_zone(id: 'a', caption: 'Rev by Region')], meta: meta)
ok(res[:status].success?, 'builder exits 0')
ctl = ->(re) { res[:elements].find { |e| e['kind'] == 'control' && e['name'].to_s =~ re } }

c = ctl.call(/Region/)
ok(c && c['controlType'] == 'list', 'Region quick filter emitted as a list control')
ok(c && c['placeholder'] == 'All', 'placeholder All when the source filter is at (All)')
ok(c && c['values'] == [], 'values stays empty (nothing selected, nothing filtered)')
ok(c && !c.key?('allOption'), 'allOption left at its default')
c2 = ctl.call(/Segment/)
ok(c2 && c2['values'] == ['Consumer'] && !c2.key?('placeholder'), 'specific selection keeps the default placeholder')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
