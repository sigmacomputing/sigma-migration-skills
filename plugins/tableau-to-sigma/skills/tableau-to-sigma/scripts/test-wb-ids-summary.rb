#!/usr/bin/env ruby
# frozen_string_literal: true
# Plan C live regression R5 (review): the wb-ids workbook summary post-and-readback.rb writes must
# keep a control's controlType and colorAssignment, or the layout builder cannot tell a legend
# control from a filter and sweeps it into a control band. Also checks the script uses the module.
require_relative 'lib/wb_ids_summary'
$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end
ca = { 'customColors' => [{ 'value' => 'A', 'color' => '#111111' }, { 'value' => 'B', 'color' => '#222222' }] }
lg = WbIdsSummary.element({ 'id' => 'legend-1', 'kind' => 'control', 'name' => nil, 'controlType' => 'legend',
                            'colorAssignment' => ca, 'values' => [], 'targets' => [{}] })
check(lg['controlType'] == 'legend', 'legend control keeps controlType')
check(lg['colorAssignment'] == ca, 'legend control keeps colorAssignment.customColors')
check(lg.keys.sort == %w[colorAssignment controlType id kind name], "no other element keys leak (#{lg.keys.inspect})")
flt = WbIdsSummary.element({ 'id' => 'c', 'kind' => 'control', 'name' => 'Days', 'controlType' => 'slider' })
check(flt['controlType'] == 'slider' && !flt.key?('colorAssignment'), 'filter control keeps controlType, no colorAssignment')
ch = WbIdsSummary.element({ 'id' => 'e', 'kind' => 'bar-chart', 'name' => 'X', 'controlType' => 'legend', 'colorAssignment' => ca }, %w[l])
check(ch == { 'id' => 'e', 'kind' => 'bar-chart', 'name' => 'X', 'columnLabels' => %w[l] }, 'non-control element: id/kind/name (+ labels) only')
src = File.read(File.join(__dir__, 'post-and-readback.rb'), encoding: 'UTF-8')
check(src.include?('WbIdsSummary.element('), 'post-and-readback.rb builds the workbook summary through WbIdsSummary')
puts
if $fails.empty?
  puts 'ALL PASS'
else
  puts "FAILED (#{$fails.length})"
  exit 1
end
