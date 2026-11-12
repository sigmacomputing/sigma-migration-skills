#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit test: lib/final_verdict.rb — the run verdict is the worse of the gate's
# degradation-ledger verdict and migration-result.json (2026-11-09 RCC case).
require_relative 'lib/final_verdict'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

F = FinalVerdict
obj = ->(s) { { 'type' => 'calculation', 'name' => 'Cohort Year', 'status' => s } }
clean = { 'verdict' => 'GREEN', 'source_objects' => [obj.call('migrated')] }
rcc = { 'verdict' => 'YELLOW', 'source_objects' => [obj.call('needs-review'), obj.call('needs-review'),
                                                     obj.call('approximated'), obj.call('migrated')] }
check(F.report_level(clean) == 'GREEN', 'clean report stays GREEN', fails)
check(F.report_level(rcc) == 'YELLOW', 'RCC report is YELLOW', fails)
check(F.report_level(clean.merge('source_objects' => [obj.call('skipped')])) == 'YELLOW',
      'a GREEN-claiming report over a skipped object is YELLOW', fails)
check(F.report_level(nil).nil?, 'no report -> nil', fails)
check(F.combine('GREEN', 'YELLOW') == 'YELLOW', 'GREEN ledger + YELLOW report -> YELLOW', fails)
check(F.combine('GREEN', 'GREEN') == 'GREEN' && F.combine('GREEN', nil) == 'GREEN', 'GREEN + GREEN/none -> GREEN', fails)
check(F.combine('GREEN (factory, self-attested)', 'GREEN') == 'GREEN (factory, self-attested)',
      'factory label survives a GREEN report', fails)
check(F.combine('GREEN (factory, self-attested)', 'YELLOW') == 'YELLOW', 'factory GREEN + YELLOW report -> YELLOW', fails)
check(F.combine('PARTIAL', 'YELLOW') == 'PARTIAL+YELLOW', 'PARTIAL + YELLOW -> PARTIAL+YELLOW', fails)
check(F.combine('YELLOW', 'YELLOW') == 'YELLOW' && F.combine('PARTIAL+YELLOW', 'YELLOW') == 'PARTIAL+YELLOW',
      'already-YELLOW verdicts unchanged', fails)
check(F.combine('GREEN', 'RED') == 'RED', 'a RED report wins', fails)
check(F.report_reason(rcc) == 'migration report YELLOW: 2 needs-review, 1 approximated source object(s)',
      "reason names the census counts (#{F.report_reason(rcc)})", fails)
check(F.status_line(false, 'GREEN', clean) == 'NOT GREEN', 'failed battery -> NOT GREEN', fails)
check(F.status_line(true, 'GREEN', clean) == 'GREEN', 'passing battery + GREEN -> GREEN', fails)
check(F.status_line(true, 'YELLOW', rcc).start_with?('YELLOW (all gates pass;'), 'passing battery + YELLOW -> YELLOW', fails)

# finalize-gates.json: a failed finalize gate keeps the report from GREEN
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
Dir.mktmpdir('finalize-gates') do |dir|
  ok_st = Struct.new(:ok, :code) do
    def success?
      ok
    end

    def exitstatus
      code
    end
  end
  rows = F.write_finalize_gates(dir, 'assert-phase6-ran' => ok_st.new(false, 20), 'cleanup' => ok_st.new(true, 0),
                                     'phase6' => [true, 0])
  check(rows == { 'assert-phase6-ran' => { 'status' => 'FAIL', 'exit' => 20 }, 'cleanup' => { 'status' => 'PASS' },
                  'phase6' => { 'status' => 'PASS' } }, "finalize-gates rows (#{rows})", fails)
  File.write(File.join(dir, 'inventory.json'), JSON.generate('objects' => [{ 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }]))
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS', 'charts_pass' => 2, 'charts_total' => 2,
                                                                'visual_checked' => true, 'visual_verdict' => 'pass', 'waivers' => []))
  File.write(File.join(dir, 'dashboard-render-health.json'), JSON.generate('status' => 'healthy', 'failed_count' => 0))
  File.write(File.join(dir, 'dashboard-blank-risk.json'), JSON.generate('risk' => false, 'blank_count' => 0))
  File.write(File.join(dir, 'degradation-ledger.json'), JSON.generate('version' => 1, 'counts' => {}, 'entries' => []))
  Open3.capture3(RbConfig.ruby, File.join(__dir__, 'build-migration-report.rb'), '--workdir', dir)
  res = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  check(res['verdict'] == 'RED', "Complex Pivot shape: gate 14 failed -> report RED, never GREEN (#{res['verdict']})", fails)
  F.write_finalize_gates(dir, 'assert-phase6-ran' => ok_st.new(true, 0), 'cleanup' => ok_st.new(true, 0))
  Open3.capture3(RbConfig.ruby, File.join(__dir__, 'build-migration-report.rb'), '--workdir', dir)
  res = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  check(res['verdict'] == 'GREEN', "every finalize gate PASS -> report GREEN (#{res['verdict']})", fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
