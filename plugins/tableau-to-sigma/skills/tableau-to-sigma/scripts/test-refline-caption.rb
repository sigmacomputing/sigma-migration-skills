#!/usr/bin/env ruby
# frozen_string_literal: true

# Plan C4: a reference line whose Tableau label is None must carry NO caption in
# Sigma. The refMarks label/annotation visibility enums only allow "shown", so the
# only way to hide the caption is to omit both keys (label hidden / null / empty
# text 400 or fall back to Sigma's default "Avg <measure>" caption).
require_relative 'lib/builder_test_harness'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

H = BuilderTestHarness
line = lambda do |label_type, label = nil|
  { 'kind' => 'line', 'formula' => 'average', 'axis_column' => '[Net Revenue]',
    'value_column' => '[Net Revenue]', 'scope' => 'per-table', 'label_type' => label_type,
    'label' => label }.compact
end
zone = lambda do |id, cap, ref|
  H.chart_zone(id: id, caption: cap, extra: { 'ref_marks' => [ref] })
end
res = H.run([
  zone.call('n', 'RL None', line.call('none')),
  zone.call('c', 'RL Custom', line.call('custom', 'Average')),
  zone.call('v', 'RL Value', line.call('value')),
  zone.call('a', 'RL Computation', line.call('computation'))
])
ok(res[:status].success?, 'builder exits 0')
rm_of = ->(re) { Array(H.find_chart(res, re)&.fetch('refMarks', nil)).first }

rm = rm_of.call(/RL None/)
ok(rm, 'reference line itself still emitted')
ok(rm && !rm.key?('label') && !rm.key?('annotation'), 'source with no label -> no caption')
ok(rm && rm['value']['type'] == 'formula' && rm['value']['formula'].include?('Net Revenue'), 'line value untouched')
rm2 = rm_of.call(/RL Custom/)
ok(rm2 && rm2['label'] && rm2['label']['text'] == 'Average' && rm2['label']['visibility'] == 'shown', 'source with label kept')
rm3 = rm_of.call(/RL Value/)
ok(rm3 && rm3['annotation'] == { 'visibility' => 'shown' } && !rm3.key?('label'), 'value-only label -> annotation shown, no label')
rm4 = rm_of.call(/RL Computation/)
ok(rm4 && rm4['label'] && rm4['label']['text'].to_s =~ /Avg/, 'computation label keeps the default caption')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
