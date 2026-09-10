#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the ledger-complete Looker completion sentinel.
#
# Usage: ruby scripts/test-verify-complete.rb

require 'json'
require 'tmpdir'

DIR = __dir__
VC  = File.join(DIR, 'verify-complete.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end
def run_vc(vc, wd, wb: nil)
  cmd = ['ruby', vc, '--workdir', wd]; cmd += ['--workbook-id', wb] if wb
  out = IO.popen(cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
end

def write_json(path, value)
  File.write(path, JSON.pretty_generate(value))
end

def success_marker(wd, extra = {})
  write_json(File.join(wd, 'phase6-success.json'),
             { 'workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'all-pass',
               'verdict' => 'GREEN' }.merge(extra))
end

def write_contract(wd, status: 'migrated', verdict: 'GREEN', complete: true,
                   report_status: nil, report_id: 'dash-1', census_id: 'dash-1',
                   degradations: [])
  census_row = { 'type' => 'dashboard', 'id' => census_id, 'name' => 'Sales',
                 'status' => status }
  report_row = { 'type' => 'dashboard', 'id' => report_id, 'name' => 'Sales',
                 'status' => (report_status || status), 'status_sources' => [] }
  write_json(File.join(wd, 'source-object-census.json'),
             'verdict' => verdict, 'summary' => { 'complete' => complete, 'total' => 1 },
             'objects' => [census_row])
  write_json(File.join(wd, 'migration-result.json'),
             'verdict' => verdict,
             'summary' => { 'complete' => complete, 'total' => 1,
                            'accounted' => (complete ? 1 : 0) },
             'source_objects' => [report_row], 'degradations' => degradations,
             'waivers' => [])
  write_json(File.join(wd, 'parity-final.json'),
             'status' => 'PASS', 'verdict' => 'GREEN', 'waivers' => [], 'waiver_count' => 0)
  write_json(File.join(wd, 'degradation-ledger.json'),
             'version' => 1, 'counts' => {}, 'entries' => degradations)
end

Dir.mktmpdir do |wd|
  code, out = run_vc(VC, wd)
  check(code == 2, "no marker => exit 2 (got #{code})", fails)
  check(out.include?('never hand-author'), 'empty-workdir message warns against hand-authoring', fails)

  success_marker(wd)
  write_contract(wd)
  code, out = run_vc(VC, wd)
  check(code == 0, "gated stamp + reconciled report => exit 0 (got #{code})", fails)
  check(out.include?('DONE') && out.include?('wb-1'), 'done message names the workbook', fails)
  check(out.include?('1/1 exactly reconciled'), 'done message names exact object reconciliation', fails)

  success_marker(wd, 'chartCount' => nil)
  code, = run_vc(VC, wd)
  check(code == 0, "gated stamp w/o chartCount => exit 0 tolerant (got #{code})", fails)

  write_json(File.join(wd, 'phase6-success.json'), 'workbookId' => 'wb-1', 'chartCount' => 0)
  code, = run_vc(VC, wd)
  check(code == 3, "0-chart + no-gates => exit 3 empty (got #{code})", fails)

  success_marker(wd)
  code, = run_vc(VC, wd, wb: 'wb-OTHER')
  check(code == 4, "workbook mismatch => exit 4 (got #{code})", fails)
end

# Missing report contract is distinct from legacy marker failures.
Dir.mktmpdir do |wd|
  success_marker(wd)
  code, out = run_vc(VC, wd)
  check(code == 5, "missing report/census => exit 5 (got #{code})", fails)
  check(out.include?('missing completion contract'), 'missing contract is named', fails)
end

# RED and omitted accounting cannot be complete.
Dir.mktmpdir do |wd|
  success_marker(wd)
  write_contract(wd, verdict: 'RED', complete: false)
  code, = run_vc(VC, wd)
  check(code == 6, "RED/incomplete report => exit 6 (got #{code})", fails)
end

Dir.mktmpdir do |wd|
  success_marker(wd)
  write_contract(wd)
  report = JSON.parse(File.read(File.join(wd, 'migration-result.json')))
  report['source_objects'] = []
  report['summary'] = { 'complete' => false, 'total' => 1, 'accounted' => 0 }
  write_json(File.join(wd, 'migration-result.json'), report)
  code, = run_vc(VC, wd)
  check(code == 6, "omitted source object => exit 6 (got #{code})", fails)
end

# Complete-looking contracts with different identity/status sets are drift.
Dir.mktmpdir do |wd|
  success_marker(wd)
  write_contract(wd, report_status: 'skipped')
  code, out = run_vc(VC, wd)
  check(code == 7, "report/census status mismatch => exit 7 (got #{code})", fails)
  check(out.include?('does not exactly match'), 'identity/status drift is named', fails)
end

# An honestly-accounted approximation is complete but caps the report at YELLOW.
Dir.mktmpdir do |wd|
  success_marker(wd)
  write_contract(wd, status: 'approximated', verdict: 'YELLOW')
  code, out = run_vc(VC, wd)
  check(code == 0, "complete approximated accounting => exit 0 (got #{code})", fails)
  check(out.include?('VERDICT: YELLOW'), 'accounting-derived YELLOW is surfaced', fails)
end

# Re-derivation catches a report and stored ledger that hide a scope cut.
Dir.mktmpdir do |wd|
  success_marker(wd)
  write_contract(wd)
  write_json(File.join(wd, 'coverage.json'),
             'unresolved' => [{ 'visual' => 'Map', 'severity' => 'dropped',
                                'detail' => 'unsupported map' }])
  code, out = run_vc(VC, wd)
  check(code == 8, "report/stored ledger contradiction => exit 8 (got #{code})", fails)
  check(out.include?('REPORT CONTRADICTION'), 'ledger contradiction is named', fails)
end

# Phase-6 verdict and waiver claims are part of the same reconciliation.
Dir.mktmpdir do |wd|
  success_marker(wd)
  write_contract(wd)
  parity = JSON.parse(File.read(File.join(wd, 'parity-final.json')))
  parity['verdict'] = 'YELLOW'
  parity['waiver_count'] = 1
  write_json(File.join(wd, 'parity-final.json'), parity)
  code, out = run_vc(VC, wd)
  check(code == 8, "contradictory phase6 verdict/waiver count => exit 8 (got #{code})", fails)
  check(out.include?('claims verdict') && out.include?('waiver_count'),
        'phase6 verdict and waiver contradictions are named', fails)
end

# Orchestrator invokes all completion contracts; shared gate stamps chartCount.
mt = File.read(File.join(DIR, 'migrate-looker.py'))
check(mt.include?('assert-phase6-ran.rb'), 'orchestrator invokes the assert-phase6-ran hard gate', fails)
check(mt.include?('build-migration-report.rb'), 'orchestrator invokes the final migration report', fails)
check(mt.include?('build-looker-accounting.py'), 'orchestrator invokes Looker source accounting', fails)
asrt = File.read(File.join(DIR, 'assert-phase6-ran.rb'))
check(asrt.include?('phase6-success.json') && asrt.include?("'chartCount'"),
      'shared gate stamps phase6-success.json with chartCount', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
