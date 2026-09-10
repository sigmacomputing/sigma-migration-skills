#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression for Tableau dynamic display columns. Parameter controls and their
# CASE field switches belong to the Sigma workbook, not the data model.
require 'json'
require 'tmpdir'
require_relative 'mechanical-specs'
# Ruby 2.6 floor: this test READS a sibling script and eval()s a method out
# of it, so that script's own require_relative lines never run -- the test
# must supply the polyfill itself. See shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

HERE = __dir__
VENDORED = File.expand_path('../converter/tableau.mjs', HERE)
FIXTURE = File.join(HERE, 'test-fixtures', 'param-display-column.twb')

fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

result = nil
persisted = nil
Dir.mktmpdir do |dir|
  result = MechanicalSpecs.run_converter(
    twb_path: FIXTURE, conn: 'conn-test', db: 'TEST_DB', schema: 'TEST_SCHEMA',
    mcp_build: VENDORED, workdir: dir
  )
  persisted = JSON.parse(File.read(File.join(dir, 'conv-meta.json')))
end

elements = result.dig('model', 'pages').flat_map { |page| page['elements'] || [] }
fields = elements.flat_map { |element| Array(element['columns']) + Array(element['metrics']) }
pattern = Array(result['workbookPatterns']).find { |item| item['name'] == 'Display Column' }

check(elements.none? { |element| element['kind'] == 'control' },
      'unreferenced Tableau parameter control is absent from the migration DM', fails)
check(fields.none? { |field| field['name'] == 'Display Column' },
      'parameter-dependent display column is absent from DM columns and metrics', fails)
check(result.dig('stats', 'controls') == 0,
      'normalized converter stats report zero DM controls', fails)
check(Array(result['parameters']).any? { |parameter| parameter['name'] == 'Choose Display Column' },
      'parameter metadata remains available to the workbook builder', fails)
check(pattern && pattern['kind'] == 'param-switch',
      'bare-integer CASE is promoted from param-filter to workbook param-switch', fails)
check(pattern && pattern['cases'] == [
        { 'when' => '1', 'then' => '[Region]' },
        { 'when' => '2', 'then' => '[Customer Name]' }
      ], 'workbook switch preserves both display-column branches', fails)
check(persisted == result, 'conv-meta.json persists the normalized workbook-layer handoff', fails)

# Exercise the existing workbook-pattern consumer against the recovered pattern.
builder_source = File.read(File.join(HERE, 'build-charts-from-signals.rb'))
%w[map_column coerce_case_literal remap_param_branch load_param_switches
   param_switch_for param_switch_inline].each do |method_name|
  method_source = builder_source.match(/^def #{method_name}\b.*?\n^end$/m)
  abort "test bug: could not extract #{method_name}" unless method_source
  eval(method_source[0]) # rubocop:disable Security/Eval - first-party helper test
end
$param_switches = []
$param_switch_by_key = {}
$param_switch_used = []
Dir.mktmpdir do |dir|
  path = File.join(dir, 'conv-meta.json')
  File.write(path, JSON.generate(result))
  load_param_switches(path, 'columns_by_guid' => {
                        'Calculation_Display' => { 'caption' => 'Display Column', 'datatype' => 'string' }
                      })
end
master_map = {
  '(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Customer Name$' => { 'id' => 'm-customer', 'name' => 'Customer Name' }
}
plan = param_switch_inline(param_switch_for('Calculation_Display'), master_map, {})
check(plan && plan['sibling_form'] == 'Switch([ctl-parameter-1], "1", [Region], "2", [Customer Name])',
      'workbook builder materializes the dynamic display column as a control-driven Switch', fails)
check(plan && plan['branch_refs'] == ['Region', 'Customer Name'],
      'workbook switch requests both source columns as sibling passthroughs', fails)

# Preserve the deliberate exception: a control referenced by a DM formula is
# still required at that layer (for example, the converter's Top-N helper).
synthetic = {
  'model' => {
    'pages' => [{ 'elements' => [
      { 'kind' => 'control', 'controlId' => 'top-n', 'id' => 'ctl-top' },
      { 'kind' => 'control', 'controlId' => 'unused', 'id' => 'ctl-unused' },
      { 'kind' => 'table', 'id' => 'table', 'columns' => [
        { 'id' => 'keep', 'formula' => '[Rank] <= [top-n]', 'name' => 'Keep' }
      ] }
    ] }]
  },
  'stats' => { 'controls' => 2 }
}
MechanicalSpecs.normalize_converter_parameters!(synthetic)
synthetic_controls = synthetic.dig('model', 'pages', 0, 'elements').select { |element| element['kind'] == 'control' }
check(synthetic_controls.map { |control| control['controlId'] } == ['top-n'],
      'DM-referenced parameter control is preserved while an unused sibling is removed', fails)

puts
if fails.empty?
  puts 'ALL PASS - parameter display columns stay in the workbook layer'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |failure| puts "  - #{failure}" }
  exit 1
end
