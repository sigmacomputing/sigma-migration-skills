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

DIR = __dir__
VC  = File.join(DIR, 'verify-complete.rb')
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
  check(out.include?('NOT DONE') && out.include?('never hand-author'),
        'empty-workdir message warns against hand-authoring', fails)

  # 2) success marker with real charts → DONE (0)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'parity-pass',
                           'generatedAt' => '2026-07-10T00:00:00Z'))
  code, out = run_vc(VC, wd)
  check(code == 0, "success + charts => exit 0 (got #{code})", fails)
  check(out.include?('DONE') && out.include?('wb-1'), 'done message names the workbook', fails)

  # 3) marker present but 0 charts → NOT DONE (3) (empty workbook)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 0))
  code, = run_vc(VC, wd)
  check(code == 3, "0-chart marker => exit 3 empty (got #{code})", fails)

  # 4) workbook mismatch → exit 4
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9))
  code, = run_vc(VC, wd, wb: 'wb-OTHER')
  check(code == 4, "workbook mismatch => exit 4 (got #{code})", fails)
end

# 5) the orchestrator wires the empty-workbook guard + success stamp.
mt = File.read(File.join(DIR, 'migrate-powerbi.rb'))
check(mt.include?('built_ok = parity_ok && chart_els.size.positive?'),
      'orchestrator requires real elements for a green (no vacuous empty pass)', fails)
check(mt.include?('phase6-success.json'), 'orchestrator stamps the success sentinel', fails)
# 6) missing-input aborts point at the device-code connect, not a bare "missing".
check(mt.include?('fabric-extract.py') && mt.include?('microsoft.com/devicelogin'),
      'missing --tmsl/--pbir abort prompts device-code Power BI connect', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
