#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Build warnings in coverage.json name the source object they are about
# (coverage_warning_subject in build-charts-from-signals.rb). Field case
# 2026-10-30: every warning that did not START with a quoted caption was
# written as visual "field/calc", which no census object carries, so the
# migration report flagged all 23 build warnings as unknown objects and the
# verdict went RED. Synthetic, creds-free.
#
# Usage: ruby scripts/test-coverage-warning-subject.rb
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

DIR    = __dir__
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')
CENSUS = File.join(DIR, 'build-source-object-census.rb')
REPORT = File.join(DIR, 'build-migration-report.rb')
RUBY   = RbConfig.ruby

src = File.read(BUILD)[/^def coverage_warning_subject\b.*?\nend\n/m]
abort 'test bug: could not extract coverage_warning_subject' unless src
eval(src) # rubocop:disable Security/Eval

$failures = []
def check(condition, message)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  $failures << message unless condition
end

puts 'coverage_warning_subject'
check(coverage_warning_subject("'Agreement Rate' STAYS MANUAL — window calc") == ['Agreement Rate', 'field/calc'],
      'leading quoted caption is the subject')
check(coverage_warning_subject("ZONE DROPPED: 'Agreement' — view CSV is EMPTY") == %w[Agreement worksheet],
      'ZONE DROPPED names the worksheet')
check(coverage_warning_subject("ZONE DROPPED / STAYS-MANUAL: 'Agreement' uses mark class 'x'") == %w[Agreement worksheet],
      'ZONE DROPPED / STAYS-MANUAL names the worksheet')
check(coverage_warning_subject("dashboard 'Overview' button zone 7 navigates to a sheet") == %w[Overview dashboard],
      'dashboard prefix names the dashboard')
check(coverage_warning_subject("parameter 'Metric' is not read by any worksheet") == %w[Metric parameter],
      'parameter prefix names the parameter')
check(coverage_warning_subject('shared filter #2 has no resolvable column_caption — skipping auto-control') ==
        [nil, 'field/calc'],
      'a warning that names no object gets no visual (never a placeholder)')

puts
puts 'census + report: build warnings never read as unknown objects'
Dir.mktmpdir('coverage-warning-subject') do |dir|
  twb = File.join(dir, 'workbook-content.twb')
  File.write(twb, <<~XML)
    <?xml version='1.0' encoding='utf-8'?>
    <workbook>
      <datasources>
        <datasource caption='Support' name='support'>
          <column caption='Agreement Rate' datatype='real' name='[Calculation_1]' role='measure'>
            <calculation class='tableau' formula='AVG(IIF([Agree], 1, 0))' />
          </column>
        </datasource>
        <datasource name='Parameters'>
          <column caption='Metric' datatype='string' name='[Parameter 1]' param-domain-type='list' value='A' />
        </datasource>
      </datasources>
      <worksheets><worksheet name='Agreement' /></worksheets>
      <dashboards><dashboard name='Overview'><zones><zone id='1' name='Agreement' /></zones></dashboard></dashboards>
    </workbook>
  XML
  warnings = [
    "'Agreement Rate' STAYS MANUAL — window calc",
    "ZONE DROPPED: 'Agreement' — view CSV is EMPTY",
    "dashboard 'Overview' image zone 3 could not be carried",
    'shared filter #2 has no resolvable column_caption — skipping auto-control'
  ]
  unresolved = warnings.map do |w|
    visual, type = coverage_warning_subject(w)
    { 'visual' => visual, 'source_type' => type, 'severity' => 'degraded', 'detail' => w }
  end
  File.write(File.join(dir, 'coverage.json'),
             JSON.pretty_generate('version' => 1, 'source' => 'tableau', 'unresolved' => unresolved))
  _o, err, status = Open3.capture3(RUBY, CENSUS, '--workdir', dir, '--twb', twb,
                                   '--coverage', File.join(dir, 'coverage.json'))
  check(status.success?, "census builds (#{err.lines.first.to_s.strip})")
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture3(RUBY, REPORT, '--workdir', dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  consistency = result['checks'].find { |c| c['name'] == 'status-consistency' }
  check(!consistency['message'].to_s.include?('refers to unknown'),
        "no build warning is reported as an unknown object (#{consistency['message'].to_s[0, 120]})")
  worksheet = result['source_objects'].find { |o| o['type'] == 'worksheet' && o['name'] == 'Agreement' }
  check(worksheet && worksheet['status'] != 'migrated',
        "the dropped zone's worksheet carries the drop instead of reading migrated (#{worksheet && worksheet['status']})")
end

puts
if $failures.empty?
  puts 'ALL PASS'
  exit 0
end
warn "#{$failures.size} FAILURE(S)"
exit 1
