#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof: the parameter-driven metric switch "Select Metric" was posted
# with filters: [] (it filters no element — the trend reads it through
# Switch([ctl-…], …)) and the readback omits the empty array. The census
# reported "posted field(s) absent from readback: filters" as if the API had
# dropped a binding. An omitted EMPTY value is not a drop; a real target
# binding that vanishes still is.

require_relative 'lib/control_field_census'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def wb(*els)
  { 'pages' => [{ 'id' => 'p', 'name' => 'Overview', 'elements' => els }] }
end

switch_posted = { 'id' => 'el-param-select-metric', 'kind' => 'control', 'controlId' => 'ctl-param-select-metric',
                  'name' => 'Select Metric', 'controlType' => 'list', 'value' => 'Net Revenue',
                  'source' => { 'kind' => 'manual', 'valueType' => 'text', 'values' => ['Net Revenue', 'Net Profit'] },
                  'filters' => [] }
switch_live = switch_posted.reject { |k, _| k == 'filters' }.merge('mode' => 'include')
trend = { 'id' => 'el-trend', 'kind' => 'line-chart', 'name' => 'Trend',
          'columns' => [{ 'id' => 'y', 'formula' => 'Switch([ctl-param-select-metric], "Net Revenue", Sum([Net Revenue]), "Net Profit", Sum([Net Profit]))' }] }

probs = ControlFieldCensus.census(wb(switch_posted, trend), wb(switch_live, trend))
ok(probs.empty?, "metric switch: omitted filters: [] is not a dropped field (#{probs.inspect})")
ok(trend['columns'][0]['formula'].include?('[ctl-param-select-metric]'), 'the switch still drives the trend through its formula')

bound = switch_posted.merge('filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-metric' }])
probs = ControlFieldCensus.census(wb(bound), wb(switch_live))
ok(probs.any? { |p| Array(p['dropped']).any? { |d| d.start_with?('filters') } }, 'a REAL bound target that vanishes is still reported')

flag = switch_posted.merge('showSearchBox' => true)
probs = ControlFieldCensus.census(wb(flag), wb(switch_live))
ok(probs.any? { |p| p['dropped'].include?('showSearchBox') }, 'a non-empty dropped field is still reported')
off = switch_posted.merge('showSearchBox' => false)
probs = ControlFieldCensus.census(wb(off), wb(switch_live))
ok(probs.any? { |p| p['dropped'].include?('showSearchBox') }, 'false is a value, not empty — still reported')

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
