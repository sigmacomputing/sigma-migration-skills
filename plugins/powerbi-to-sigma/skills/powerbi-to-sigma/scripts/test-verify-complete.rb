#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the Power BI completion sentinel (2026-07-10).
#
# "Done" is a fact on disk: migrate-powerbi.rb stamps phase6-success.json
# (workbookId + chartCount + parity-pass) only on a real, non-empty, parity-
# passing build; verify-complete.rb greens ONLY on that. Guards the exact PBI
# failure where a blocked agent ships empty placeholder pages and calls it done.
#
# Usage: ruby scripts/test-verify-complete.rb

require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

DIR = __dir__
VC  = File.join(DIR, 'verify-complete.rb')
ADOPT = File.join(DIR, 'adopt-workbook.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end
def run_vc(vc, wd, wb: nil)
  cmd = ['ruby', vc, '--workdir', wd]; cmd += ['--workbook-id', wb] if wb
  out = IO.popen(cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
end

Dir.mktmpdir do |wd|
  # 1) nothing → NOT DONE (2)
  code, out = run_vc(VC, wd)
  check(code == 2, "no marker => exit 2 (got #{code})", fails)
  check(out.include?('NOT DONE') && out.include?('adopt-workbook.rb'),
        'empty-workdir message gives the supported existing-workbook adoption path', fails)

  # 2) resolution marker alone is not value parity → NOT DONE (5)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'resolution-pass',
                           'generatedAt' => '2026-07-10T00:00:00Z'))
  code, out = run_vc(VC, wd)
  check(code == 5, "success marker without value parity => exit 5 (got #{code})", fails)
  check(out.include?('value parity was not run'), 'missing parity message names the required gate', fails)

  # 3) strict parity for every chart → DONE (0)
  File.write(File.join(wd, 'parity-final.json'),
             JSON.generate('status' => 'PASS', 'charts_total' => 9,
                           'charts_pass' => 9, 'charts_fail' => 0))
  code, out = run_vc(VC, wd)
  check(code == 0, "success + charts => exit 0 (got #{code})", fails)
  check(out.include?('DONE') && out.include?('wb-1') && out.include?('9/9 strict matches'),
        'done message names workbook + strict parity evidence', fails)

  # 4) stale-only parity never claims DONE, even if its writer says PASS.
  File.write(File.join(wd, 'parity-final.json'),
             JSON.generate('status' => 'PASS', 'charts_total' => 4,
                           'charts_pass' => 0, 'charts_fail' => 0,
                           'charts_stale_explained' => 4))
  code, out = run_vc(VC, wd)
  check(code == 5 && out.include?('stale-explained'),
        'status PASS with 0 strict matches is rejected as stale/inconsistent', fails)

  # 5) marker present but 0 charts → NOT DONE (3) (empty workbook)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 0))
  code, = run_vc(VC, wd)
  check(code == 3, "0-chart marker => exit 3 empty (got #{code})", fails)

  # 6) workbook mismatch → exit 4
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9))
  code, = run_vc(VC, wd, wb: 'wb-OTHER')
  check(code == 4, "workbook mismatch => exit 4 (got #{code})", fails)

  # 7) a repaired/hand-authored workbook has a supported route through the
  # real gate contract. The test substitutes only the expensive gate process;
  # the adoption wrapper must pass its inputs, accept the gate-minted marker,
  # and run verify-complete successfully.
  File.write(File.join(wd, 'wb-spec.json'), JSON.generate('document' => { 'elements' => [] }))
  File.write(File.join(wd, 'parity-final.json'),
             JSON.generate('status' => 'PASS', 'charts_total' => 2,
                           'charts_pass' => 2, 'charts_fail' => 0))
  fake_gate = File.join(wd, 'fake-gate.rb')
  File.write(fake_gate, <<~'RUBY')
    require 'json'
    wd = ARGV[ARGV.index('--tableau') + 1]
    wb = ARGV[ARGV.index('--workbook-id') + 1]
    File.write(File.join(wd, 'phase6-success.json'),
               JSON.generate('workbookId' => wb, 'chartCount' => 2,
                             'gates' => 'all-pass', 'generatedAt' => '2026-10-26T00:00:00Z'))
  RUBY
  env = { 'PBI_ASSERT_PHASE6' => fake_gate, 'PBI_VERIFY_COMPLETE' => VC }
  out, st = Open3.capture2e(env, RbConfig.ruby, ADOPT,
                           '--workdir', wd, '--workbook-id', 'wb-adopted')
  check(st.success? && out.include?('DONE') && out.include?('wb-adopted'),
        'adoption path runs the standard gate then verify-complete', fails)
end

# 8) the orchestrator wires the empty-workbook guard + success stamp.
mt = File.read(File.join(DIR, 'migrate-powerbi.rb'))
check(mt.include?('built_ok = parity_ok && chart_els.size.positive?'),
      'orchestrator requires real elements for a green (no vacuous empty pass)', fails)
check(mt.include?('phase6-success.json'), 'orchestrator stamps the success sentinel', fails)
check(mt.match?(/preflight_lint\.rb.*validate-spec\.rb.*post-and-readback\.rb/m),
      'orchestrator runs mandatory workbook preflight before POST', fails)
# 9) missing-input aborts point at the device-code connect, not a bare "missing".
check(mt.include?('fabric-extract.py') && mt.include?('microsoft.com/devicelogin'),
      'missing --tmsl/--pbir abort prompts device-code Power BI connect', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
