#!/usr/bin/env ruby
# frozen_string_literal: true

# The Ruby gap scan must write the standalone <out-dir>/formula-audit.json that
# scan-workbook-gaps.py writes (SKILL.md Phase 0a; assert-phase6-ran.py and
# build-source-object-census read that fixed basename), and it must equal the
# `formula_audit` object embedded in the gaps JSON. Before this fix the Ruby
# scanner only embedded the audit, so a Ruby-scanned run failed the Python gate.
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

SCRIPTS = __dir__
RB_SCAN = File.join(SCRIPTS, 'scan-workbook-gaps.rb')
PY_SCAN = File.join(SCRIPTS, 'scan-workbook-gaps.py')

$failures = []
def check(description, condition)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{description}"
  $failures << description unless condition
end

WORKBOOK = <<~XML
  <?xml version='1.0' encoding='utf-8'?>
  <workbook>
    <datasources>
      <datasource name='orders' caption='Orders'>
        <connection class='snowflake' server='warehouse-a' dbname='ANALYTICS'>
          <relation name='orders' type='table' table='[ORDERS]' />
        </connection>
        <column name='[Sales]' caption='Sales' />
        <column name='[Calculation_Total]' caption='Total Sales'>
          <calculation class='tableau' formula='SUM([Sales])' />
        </column>
        <column name='[Calculation_Script]' caption='Scripted Risk'>
          <calculation class='tableau' formula='SCRIPT_REAL([Sales])' />
        </column>
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Sheet 1'>
        <table><view>
          <datasources><datasource name='orders' /></datasources>
          <datasource-dependencies datasource='orders'>
            <column name='[Calculation_Total]' />
          </datasource-dependencies>
        </view></table>
        <mark class='Bar' />
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Overview'><zones><zone name='Sheet 1' /></zones></dashboard>
    </dashboards>
  </workbook>
XML

def scan(cmd, dir, twb_text, report)
  File.write(File.join(dir, 'workbook-content.twb'), twb_text)
  # Test harness: cmd is this file's interpreter + gap-scan script pair; the paths are its temp dirs.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture3(*cmd, File.join(dir, 'workbook-content.twb'), File.join(dir, report))
end

Dir.mktmpdir('gap-audit-') do |tmp|
  rb = File.join(tmp, 'rb')
  py = File.join(tmp, 'py')
  FileUtils.mkdir_p([rb, py])

  puts 'Ruby scan writes a standalone formula-audit.json'
  _, err, st = scan([RbConfig.ruby, RB_SCAN], rb, WORKBOOK, 'gaps.md')
  check('ruby scan exits 0', st.success?)
  audit_path = File.join(rb, 'formula-audit.json')
  check('formula-audit.json exists next to the report', File.file?(audit_path))
  check('stderr announces the file', err.include?('formula-audit.json'))
  gaps = JSON.parse(File.read(File.join(rb, 'gaps.json')))
  audit = File.file?(audit_path) ? JSON.parse(File.read(audit_path)) : nil
  check('embedded formula_audit equals the standalone file', !audit.nil? && gaps['formula_audit'] == audit)
  check('audit is a real converter result (not ERROR)', audit && audit['status'] != 'ERROR' && audit['formulas'].is_a?(Array) && !audit['formulas'].empty?)
  check('file ends with a newline like the Python writer', File.file?(audit_path) && File.read(audit_path).end_with?("\n"))

  puts 'Default out name: formula-audit.json lands beside <stem>-gaps-report.*'
  default_dir = File.join(tmp, 'default')
  FileUtils.mkdir_p(default_dir)
  File.write(File.join(default_dir, 'wb.twb'), WORKBOOK)
  _, _, st = Open3.capture3(RbConfig.ruby, RB_SCAN, File.join(default_dir, 'wb.twb'))
  check('default-out scan exits 0', st.success?)
  check('wb-gaps-report.json written', File.file?(File.join(default_dir, 'wb-gaps-report.json')))
  check('formula-audit.json written beside it',
        File.file?(File.join(default_dir, 'formula-audit.json')) &&
        JSON.parse(File.read(File.join(default_dir, 'wb-gaps-report.json')))['formula_audit'] ==
        JSON.parse(File.read(File.join(default_dir, 'formula-audit.json'))))

  puts 'Top-level keys match the Python scanner'
  py_bin = ENV['PYTHON3'] || 'python3'
  pout, perr, pst = begin
    scan([py_bin, PY_SCAN], py, WORKBOOK, 'gaps.md')
  rescue Errno::ENOENT
    [nil, nil, nil]
  end
  if pst.nil?
    puts '  SKIP  python3 not available'
  else
    check("python scan exits 0 (#{perr.to_s.lines.last.to_s.strip})", pst.success?)
    py_audit = JSON.parse(File.read(File.join(py, 'formula-audit.json')))
    check('same top-level keys', audit && audit.keys.sort == py_audit.keys.sort)
    check('same status vocabulary in counts', audit && audit['counts'].keys == py_audit['counts'].keys)
    check('same formula statuses', audit && audit['formulas'].map { |f| [f['internal_name'], f['status']] } ==
                                    py_audit['formulas'].map { |f| [f['internal_name'], f['status']] })
  end

  puts 'Unparseable workbook still yields a fail-closed standalone audit'
  bad = File.join(tmp, 'bad')
  FileUtils.mkdir_p(bad)
  _, _, st = scan([RbConfig.ruby, RB_SCAN], bad, "<workbook><datasources>\n", 'gaps.md')
  check('scan of broken XML exits 0', st.success?)
  bad_audit_path = File.join(bad, 'formula-audit.json')
  check('standalone ERROR audit written', File.file?(bad_audit_path) && JSON.parse(File.read(bad_audit_path))['status'] == 'ERROR')
  check('embedded copy matches',
        File.file?(bad_audit_path) && JSON.parse(File.read(File.join(bad, 'gaps.json')))['formula_audit'] == JSON.parse(File.read(bad_audit_path)))
end

if $failures.empty?
  puts "\nOK: gap-scan formula-audit"
  exit 0
end
puts "\nFAIL: #{$failures.size} check(s)"
exit 1
