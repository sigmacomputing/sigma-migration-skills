#!/usr/bin/env ruby
# Contract tests for the shared pre-POST blank-render risk gate.

require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lint-render-integrity'

SCRIPT = File.expand_path('lint-render-integrity.rb', __dir__)
$failures = []

def check(condition, message)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  $failures << message unless condition
end

def fixture(element)
  {
    'pages' => [
      {
        'id' => 'overview',
        'elements' => [
          { 'id' => 'band', 'kind' => 'container', 'children' => [element] }
        ]
      }
    ]
  }
end

puts '== blank data elements fail =='
[
  ['chart', { 'id' => 'blank-chart', 'name' => 'Blank Chart', 'kind' => 'bar-chart' }],
  ['source-only chart', { 'id' => 'blank-source-chart', 'name' => 'No measure', 'kind' => 'bar-chart',
                          'source' => { 'kind' => 'table', 'elementId' => 'master' },
                          'columns' => [{ 'id' => 'region', 'formula' => '[Master/Region]' }],
                          'xAxis' => { 'columnId' => 'region' }, 'yAxis' => { 'columnIds' => [] } }],
  ['KPI', { 'id' => 'blank-kpi', 'name' => { 'text' => 'Blank KPI' }, 'kind' => 'kpi-chart',
            'value' => { 'color' => '#ffffff' } }],
  ['table', { 'id' => 'blank-table', 'name' => 'Blank Table', 'kind' => 'table',
              'columns' => [], 'source' => { 'kind' => 'table' } }]
].each do |label, element|
  report = RenderIntegrity.lint(fixture(element), spec_path: "#{label.downcase}.json")
  check(report['status'] == 'FAIL', "blank #{label} reports FAIL")
  check(report['elements_checked'] == 1, "blank #{label} is checked")
  check(report['blank_risk_count'] == 1, "blank #{label} is counted once")
  check(report['elements'].first['id'] == element['id'], "blank #{label} evidence names its id")
  check(report['elements'].first['reasons'] == ['no usable data bindings'],
        "blank #{label} evidence gives a deterministic reason")
end

puts '== healthy wrapped spec passes and non-data elements are ignored =='
healthy = {
  'document' => {
    'pages' => {
      'overview' => {
        'id' => 'overview',
        'elements' => [
          { 'id' => 'chart', 'name' => 'Sales', 'kind' => 'line-chart',
            'xAxis' => { 'columnId' => 'sale-date' },
            'yAxis' => { 'columnIds' => ['revenue'] } },
          { 'id' => 'kpi', 'name' => 'Revenue', 'kind' => 'kpi-chart',
            'value' => { 'columnId' => 'revenue' } },
          { 'id' => 'pivot', 'name' => 'Sales pivot', 'kind' => 'pivot-table',
            'rowAxes' => [{ 'fieldId' => 'region' }], 'values' => ['revenue'] },
          { 'id' => 'table', 'name' => 'Orders', 'kind' => 'table',
            'dataSource' => { 'connectionId' => 'warehouse', 'path' => %w[db schema orders] } },
          { 'id' => 'controls', 'kind' => 'container', 'children' => [
            { 'id' => 'region-control', 'kind' => 'control' },
            { 'id' => 'copy', 'kind' => 'text' },
            { 'id' => 'logo', 'kind' => 'image' }
          ] }
        ]
      }
    }
  }
}
healthy_report = RenderIntegrity.lint(healthy, spec_path: 'healthy.json')
check(healthy_report['status'] == 'PASS', 'healthy wrapper reports PASS')
check(healthy_report['elements_checked'] == 4, 'chart, KPI, pivot, and table are checked')
check(healthy_report['blank_risk_count'].zero?, 'healthy wrapper has no blank risks')
check(healthy_report['elements'].empty?, 'controls/text/images/containers are not reported')

puts '== flat children traversal and deterministic ordering =='
unordered = {
  'children' => [
    { 'id' => 'z', 'name' => 'Zed', 'kind' => 'crosstab' },
    { 'id' => 'a', 'name' => 'Alpha', 'kind' => 'chart' }
  ]
}
ordered_report = RenderIntegrity.lint(unordered, spec_path: 'unordered.json')
check(ordered_report['elements'].map { |entry| entry['id'] } == %w[a z],
      'blank-risk evidence sorts elements deterministically')

puts '== CLI exits and evidence paths =='
Dir.mktmpdir('render-integrity') do |dir|
  healthy_path = File.join(dir, 'wb-spec.json')
  File.write(healthy_path, JSON.generate(healthy))
  _out, _err, status = Open3.capture3('ruby', SCRIPT, '--spec', healthy_path)
  default_evidence = File.join(dir, 'blank-risk-elements.json')
  check(status.exitstatus.zero?, 'CLI exits 0 for healthy spec')
  check(File.exist?(default_evidence), 'CLI writes default sibling evidence')
  parsed = JSON.parse(File.read(default_evidence))
  check(parsed.keys.take(7) == %w[schema_version spec status elements_checked blank_risk_count elements],
        'evidence starts with the stable contract fields')

  blank_path = File.join(dir, 'blank.json')
  custom_out = File.join(dir, 'custom-evidence.json')
  File.write(blank_path, JSON.generate(fixture('id' => 'blank', 'kind' => 'table')))
  _out, _err, status = Open3.capture3('ruby', SCRIPT, '--spec', blank_path, '--out', custom_out)
  check(status.exitstatus == 1, 'CLI exits 1 for blank-risk spec')
  check(JSON.parse(File.read(custom_out))['status'] == 'FAIL', 'CLI --out records failing evidence')

  malformed_path = File.join(dir, 'malformed.json')
  File.write(malformed_path, '{not json')
  _out, _err, status = Open3.capture3('ruby', SCRIPT, '--spec', malformed_path)
  check(status.exitstatus == 2, 'CLI exits 2 for invalid JSON')
  invalid_report = JSON.parse(File.read(default_evidence))
  check(invalid_report['status'] == 'FAIL' && invalid_report['error'].include?('invalid JSON'),
        'invalid input overwrites default evidence with the parse failure')
end

puts
if $failures.empty?
  puts 'ALL PASS — render-integrity linter catches blank data elements'
  exit 0
end

puts "FAILURES (#{$failures.length}):"
$failures.each { |message| puts "  - #{message}" }
exit 1
