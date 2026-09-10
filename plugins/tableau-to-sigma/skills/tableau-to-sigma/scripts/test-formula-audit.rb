#!/usr/bin/env ruby
# frozen_string_literal: true

# Focused offline coverage for formula-audit.mjs and its scanner integration.
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

HELPER = File.join(__dir__, 'formula-audit.mjs')
SCANNER = File.join(__dir__, 'scan-workbook-gaps.rb')
STATUSES = %w[spec verify chart_only rls not_converted unmapped].freeze

$failures = []
def check(description, condition)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{description}"
  $failures << description unless condition
end

def run_helper(payload, *args)
  Open3.capture3('node', HELPER, *args, stdin_data: payload)
end

puts 'formula-audit.mjs: real converter classifications and cleanup'
batch = [
  { 'id' => 'simple', 'formula' => 'SUM([SALES])' },
  { 'id' => 'verify', 'formula' => "DATEPARSE('yyyy-MM-dd', [DATE_TEXT])" },
  { 'id' => 'chart', 'formula' => 'RUNNING_SUM(SUM([SALES]))' },
  { 'id' => 'rls', 'formula' => 'USERNAME()' },
  { 'id' => 'refused', 'formula' => 'WINDOW_MEDIAN(SUM([SALES]), -3, 0)' },
  { 'id' => 'unsupported', 'formula' => 'SCRIPT_REAL([SALES])' }
]
temp_before = Dir.glob(File.join(Dir.tmpdir, 'tableau-formula-audit-*')).sort
stdout, stderr, status = run_helper(JSON.generate(batch))
temp_after = Dir.glob(File.join(Dir.tmpdir, 'tableau-formula-audit-*')).sort
check('stdin batch exits 0', status.success?)
check('stdin batch writes no stderr', stderr.empty?)
parsed = status.success? ? JSON.parse(stdout) : {}
rows = (parsed['formulas'] || []).each_with_object({}) { |row, h| h[row['id']] = row }
expected = {
  'simple' => 'spec',
  'verify' => 'verify',
  'chart' => 'chart_only',
  'rls' => 'rls',
  'refused' => 'not_converted',
  'unsupported' => 'unmapped'
}
check('all translation-table statuses come from the real converter',
      expected.all? { |id, wanted| rows[id] && rows[id]['status'] == wanted })
check('result includes Sigma formula, warnings, and both function-name lists',
      rows.values.all? do |row|
        row.key?('sigma_formula') && row['warnings'].is_a?(Array) &&
          row['function_names'].is_a?(Array) &&
          row['tableau_functions'].is_a?(Array) && row['sigma_functions'].is_a?(Array)
      end)
check('status counts use the closed deterministic vocabulary',
      parsed.fetch('counts', {}).keys == STATUSES)
check('temporary shim directory is always removed', temp_after == temp_before)

Dir.mktmpdir('formula-audit-input') do |dir|
  input = File.join(dir, 'formulas.json')
  File.write(input, JSON.generate('formulas' => [batch.first]))
  file_out, file_err, file_status = Open3.capture3('node', HELPER, '--input', input)
  file_json = file_status.success? ? JSON.parse(file_out) : {}
  check('--input batch exits 0', file_status.success? && file_err.empty?)
  check('--input accepts the object-with-formulas shape',
        file_json.dig('formulas', 0, 'id') == 'simple')
end

_bad_out, bad_err, bad_status = run_helper('{broken')
check('invalid JSON exits 2 with a useful error',
      bad_status.exitstatus == 2 && bad_err.include?('invalid JSON'))
_arg_out, arg_err, arg_status = Open3.capture3('node', HELPER, '--input')
check('invalid arguments exit 2 with a useful error',
      arg_status.exitstatus == 2 && arg_err.include?('--input requires'))

synthetic_twb = <<~XML
  <?xml version='1.0' encoding='utf-8'?>
  <workbook>
    <datasources>
      <datasource name='ds_one' caption='Primary'>
        <column name='[Sales]' caption='Sales' datatype='real' role='measure' type='quantitative' />
        <column name='[OrderDateText]' caption='Order Date Text' datatype='string' role='dimension' type='nominal' />
        <column name='[NormalPhysical]' caption='Normal Physical Caption' datatype='real' role='measure' type='quantitative' />
        <column name='[Calculation_Simple]' caption='Simple' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='SUM([Sales])' />
        </column>
        <column name='[Calculation_Unsupported]' caption='Unsupported' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='SCRIPT_REAL([Sales])' />
        </column>
        <column name='[Calculation_Verify]' caption='Verify Date' datatype='date' role='dimension' type='ordinal'>
          <calculation class='tableau' formula='DATEPARSE(&apos;yyyy-MM-dd&apos;, [OrderDateText])' />
        </column>
        <column name='[Calculation_CycleA]' caption='Cycle A' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='[Calculation_CycleB] + 1' />
        </column>
        <column name='[Calculation_CycleB]' caption='Cycle B' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='[Calculation_CycleA] + 1' />
        </column>
        <column name='[Calculation_Missing]' caption='Missing Dependency' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='[Calculation_Gone] + [Sales]' />
        </column>
        <column name='[Calculation_Unused]' caption='Unused' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='[Sales] + 1' />
        </column>
        <column name='[Calculation_Physical]' caption='Physical Caption Ref' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='[Normal Physical Caption] + 1' />
        </column>
      </datasource>
      <datasource name='ds_two' caption='Secondary'>
        <column name='[Amount]' caption='Amount' datatype='real' role='measure' type='quantitative' />
        <column name='[Calculation_Chart]' caption='Running Amount' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='RUNNING_SUM(SUM([Amount]))' />
        </column>
        <column name='[Calculation_Rls]' caption='Current User' datatype='string' role='dimension' type='nominal'>
          <calculation class='tableau' formula='USERNAME()' />
        </column>
        <column name='[Calculation_Refused]' caption='Window Median' datatype='real' role='measure' type='quantitative'>
          <calculation class='tableau' formula='WINDOW_MEDIAN(SUM([Amount]), -3, 0)' />
        </column>
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Primary Sheet'>
        <table><view>
          <datasources><datasource name='ds_one' /></datasources>
          <datasource-dependencies datasource='ds_one'>
            <column name='[Calculation_Simple]' />
            <column name='[Calculation_Unsupported]' />
            <column name='[Calculation_Verify]' />
            <column name='[Calculation_CycleA]' />
            <column name='[Calculation_Missing]' />
            <column name='[Calculation_Physical]' />
          </datasource-dependencies>
        </view></table>
      </worksheet>
      <worksheet name='Secondary Sheet'>
        <table><view>
          <datasources><datasource name='ds_two' /></datasources>
          <datasource-dependencies datasource='ds_two'>
            <column name='[Calculation_Chart]' />
            <column name='[Calculation_Rls]' />
            <column name='[Calculation_Refused]' />
          </datasource-dependencies>
        </view></table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Overview'><zones>
        <zone name='Primary Sheet' /><zone name='Secondary Sheet' />
      </zones></dashboard>
    </dashboards>
  </workbook>
XML

puts
puts 'scan-workbook-gaps.rb: per-datasource audit and dependency graph'
Dir.mktmpdir('formula-audit-scanner') do |dir|
  twb = File.join(dir, 'synthetic.twb')
  report = File.join(dir, 'report.md')
  File.write(twb, synthetic_twb)
  _scan_out, scan_err, scan_status = Open3.capture3(
    RbConfig.ruby, SCANNER, twb, report
  )
  json_path = File.join(dir, 'report.json')
  result = File.exist?(json_path) ? JSON.parse(File.read(json_path)) : {}
  audit = result['formula_audit'] || {}
  fields = result['field_statistics'] || {}
  by_ds = Array(audit['datasources']).each_with_object({}) { |ds, h| h[ds['name']] = ds }

  check('scanner exits 0 and emits formula_audit', scan_status.success? && !audit.empty?)
  check('scanner did not skip formula audit', !scan_err.include?('formula audit skipped'))
  check('all 11 calculations across both datasources were audited', audit['formulas']&.length == 11)
  check('Primary has 8 calculations and converter-derived status counts',
        by_ds.dig('ds_one', 'total') == 8 &&
          by_ds.dig('ds_one', 'counts', 'spec') == 6 &&
          by_ds.dig('ds_one', 'counts', 'verify') == 1 &&
          by_ds.dig('ds_one', 'counts', 'unmapped') == 1)
  check('Secondary has chart-only, RLS, and refused calculations',
        by_ds.dig('ds_two', 'total') == 3 &&
          by_ds.dig('ds_two', 'counts', 'chart_only') == 1 &&
          by_ds.dig('ds_two', 'counts', 'rls') == 1 &&
          by_ds.dig('ds_two', 'counts', 'not_converted') == 1)
  check('cycle is detected inside its datasource',
        audit['calculation_cycles'] == [
          { 'datasource' => 'ds_one', 'calculations' => ['Cycle A', 'Cycle B'] }
        ])
  check('missing internal calculation dependency is named',
        audit['orphan_internal_calculation_references']&.map { |r| r['reference'] } == ['[Calculation_Gone]'])
  check('normal physical field caption is not false-flagged as an orphan',
        audit['orphan_internal_calculation_references']&.none? do |ref|
          ref['reference'] == '[Normal Physical Caption]'
        end)
  check('unused calculation is detected without marking its used dependencies unused',
        audit['unused_calculations']&.map { |r| r['calculation'] } == ['Unused'])
  check('graph findings and converter readiness are mirrored into field_statistics',
        fields['calculation_cycles'] == audit['calculation_cycles'] &&
          fields['orphan_internal_calculation_references'] ==
            audit['orphan_internal_calculation_references'] &&
          fields['unused_calculations'] == audit['unused_calculations'] &&
          fields['formula_status_counts'] == audit['counts'] &&
          fields['formula_coverage_pct'] == audit['coverage_pct'])
  findings = Array(result['detected_features'])
  check('converter-refused formulas become a gap-gate blocker',
        findings.any? do |row|
          row['name'] == 'Converter-refused or unmapped calculated fields' &&
            row['status'] == 'unhandled' && row['count'] == 2
        end)
  check('cycles and missing internal dependencies become gap-gate blockers',
        findings.any? { |row| row['name'].to_s.start_with?('Circular calculated-field dependency') } &&
          findings.any? { |row| row['name'] == 'Missing internal calculated-field dependencies' })
  check('context-sensitive converter translations remain explicit review hints',
        findings.any? do |row|
          row['name'] == 'Converter-translated formulas requiring contextual verification' &&
            row['status'] == 'hint'
        end)
  check('legacy gap-report keys remain present',
        result.key?('workbook') && result['detected_features'].is_a?(Array) &&
          fields.key?('total_fields') && fields.key?('function_census'))

  failed_report = File.join(dir, 'audit-unavailable.md')
  _fail_out, fail_err, fail_status = Open3.capture3(
    { 'NODE_BIN' => File.join(dir, 'missing-node') },
    RbConfig.ruby, SCANNER, twb, failed_report
  )
  failed_json = JSON.parse(File.read(File.join(dir, 'audit-unavailable.json')))
  check('unavailable converter audit fails closed into the gap gate',
        fail_status.success? &&
          failed_json.dig('formula_audit', 'status') == 'ERROR' &&
          failed_json['detected_features'].any? do |row|
            row['name'] == 'Converter-backed formula audit unavailable' && row['status'] == 'unhandled'
          end &&
          fail_err.include?('formula audit FAILED CLOSED'))
end

puts
if $failures.empty?
  puts 'test-formula-audit: ALL PASS'
else
  puts "test-formula-audit: #{$failures.length} FAILURE(S)"
  $failures.each { |failure| puts "  - #{failure}" }
  exit 1
end
