#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract tests for strict Power BI parity versus stale Import snapshots.
# Shape-safe stale deltas are diagnostic STALE, never PASS; dimension/type
# mismatches stay DIVERGENT even when refresh is old.

require 'json'
require 'open3'
require 'tmpdir'

SCRIPT = File.join(__dir__, 'phase6-parity-pbi.rb')
fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

def run_case(expected:, actual:, freshness: nil)
  Dir.mktmpdir do |dir|
    plan = {
      'source' => 'powerbi-executequeries',
      'extract' => false,
      'charts' => [{ 'chart' => 'Chart A', 'expected' => expected, 'workbook_id' => 'wb-1' }]
    }
    plan_path = File.join(dir, 'plan.json')
    actuals_path = File.join(dir, 'actuals.json')
    File.write(plan_path, JSON.generate(plan))
    File.write(actuals_path, JSON.generate('Chart A' => actual))
    args = ['ruby', SCRIPT, '--finalize', '--plan', plan_path,
            '--actuals', actuals_path, '--out-dir', dir]
    if freshness
      freshness_path = File.join(dir, 'freshness.json')
      File.write(freshness_path, JSON.generate(freshness))
      args += ['--freshness', freshness_path]
    end
    out, err, status = Open3.capture3(*args)
    summary = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
    [status.exitstatus, summary, out + err]
  end
end

puts 'strict match'
code, summary, = run_case(expected: [['East', 10]], actual: [['East', 10]])
check(code.zero? && summary['status'] == 'PASS' && summary['charts_pass'] == 1,
      '1/1 strict match is the only PASS path', fails)

puts 'shape-safe stale value delta'
stale = { 'staleDays' => 82, 'credsSuspect' => true, 'failures' => [{ 'errorCode' => 'refresh' }] }
code, summary, output = run_case(expected: [['East', 10]], actual: [['East', 12]], freshness: stale)
check(code == 2 && summary['status'] == 'STALE' &&
      summary['charts_stale_explained'] == 1 && summary['charts_fail'].zero?,
      'same dimension shape + stale values reports STALE, not PASS', fails)
check(output.include?('refresh PBI before claiming exact parity'),
      'stale result prints the remediation instead of a green claim', fails)

puts 'additional live bucket on stale source'
code, summary, = run_case(
  expected: [['East', 10]],
  actual: [['East', 12], ['West', 3]],
  freshness: stale
)
check(code == 2 && summary['status'] == 'STALE' &&
      summary['classifications']['Chart A'] == 'STALE-EXPLAINED',
      'Sigma-only bucket extension remains shape-safe STALE', fails)

puts 'dimension type/grain mismatch on stale source'
code, summary, = run_case(
  expected: [[2024, 10]],
  actual: [['2024-01-01T00:00:00.000Z', 12]],
  freshness: stale
)
check(code == 2 && summary['status'] == 'FAIL' &&
      summary['charts_stale_explained'].zero? && summary['charts_fail'] == 1,
      'integer Year versus ISO date is DIVERGENT, never stale-explained', fails)
check(summary['fail_names'] == ['Chart A'],
      'shape-divergent chart is named in fail_names', fails)

if fails.empty?
  puts 'ALL PASS'
  exit 0
end

warn "#{fails.size} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
