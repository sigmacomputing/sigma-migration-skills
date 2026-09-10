#!/usr/bin/env ruby
# frozen_string_literal: true

# Source-image-confirmed one-worksheet trellis regression. Tableau can render a
# pane per facet value without repeating N worksheet zones; the source PNG is
# the only reliable discriminator between that and an implicit color grouping.

require_relative 'lib/trellis_emit'
# Ruby 2.6 floor: this test READS a sibling script and eval()s a method out
# of it, so that script's own require_relative lines never run -- the test
# must supply the polyfill itself. See shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

source = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
method = source.match(/^def apply_verified_trellis!.*?\n^end$/m) or abort('could not extract apply_verified_trellis!')
eval(method[0]) # rubocop:disable Security/Eval -- test-only extraction of first-party code

fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

element = {
  'id' => 'chart', 'kind' => 'bar-chart', 'name' => 'Employee Count by Department and Role',
  '_worksheet' => 'Sheet 2',
  'columns' => [
    { 'id' => 'role', 'name' => 'Role', 'formula' => '[Master/Role]' },
    { 'id' => 'department', 'name' => 'Department', 'formula' => '[Master/Department]' },
    { 'id' => 'count', 'name' => 'Employee Count', 'formula' => 'Count([Master/Employee Id])' }
  ],
  'color' => { 'by' => 'category', 'column' => 'department' }
}
warnings = []
apply_verified_trellis!(
  [element],
  { 'sheet 2' => { 'field' => 'Department', 'orientation' => 'cols' } },
  warnings
)
check(element['trellis'] == { 'columnsBy' => [{ 'columnId' => 'department' }] },
      "verified pane field becomes native trellis (got #{element['trellis'].inspect})", fails)
check(!element.key?('color'), 'facet field is removed from redundant color encoding', fails)
check(warnings.any? { |warning| warning.include?('png-read trellis') && warning.include?('Department') },
      'trellis emission is announced', fails)

ambiguous = {
  'id' => 'amb', 'kind' => 'bar-chart', '_worksheet' => 'Sheet 3',
  'columns' => [
    { 'id' => 'a', 'name' => 'Department' },
    { 'id' => 'b', 'name' => 'department' }
  ]
}
ambiguous_warnings = []
apply_verified_trellis!(
  [ambiguous],
  { 'sheet 3' => { 'field' => 'Department', 'orientation' => 'cols' } },
  ambiguous_warnings
)
check(!ambiguous.key?('trellis') && ambiguous_warnings.any? { |warning| warning.include?('matched 2') },
      'ambiguous facet columns refuse rather than guess', fails)

if fails.empty?
  puts 'OK — source-image trellis emission'
  exit 0
end

warn "#{fails.size} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
