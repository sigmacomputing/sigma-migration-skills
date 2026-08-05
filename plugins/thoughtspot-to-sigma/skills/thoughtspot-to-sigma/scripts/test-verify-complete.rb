#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the ThoughtSpot completion sentinel (2026-07-10).
#
# "Done" is a fact on disk: the shared assert-phase6-ran gate stamps
# phase6-success.json (workbookId + chartCount + gates=all-pass) only on a real
# parity-passing build; verify-complete.rb greens only on that. Tolerant: a stamp
# with gates=all-pass is DONE even if chartCount is 0/absent (the gate already
# enforced charts_total>0); only a 0-chart stamp with NO gate record is "empty".
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
  check(out.include?('never hand-author'), 'empty-workdir message warns against hand-authoring', fails)

  # 2) shared-gate stamp (gates=all-pass, chartCount>0) → DONE (0)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'all-pass'))
  code, out = run_vc(VC, wd)
  check(code == 0, "gated stamp + charts => exit 0 (got #{code})", fails)
  check(out.include?('DONE') && out.include?('wb-1'), 'done message names the workbook', fails)

  # 3) TOLERANCE: chartCount 0/absent but gates=all-pass → still DONE (gate enforced >0)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass'))
  code, = run_vc(VC, wd)
  check(code == 0, "gated stamp w/o chartCount => exit 0 tolerant (got #{code})", fails)

  # 4) 0 charts AND no gate record → NOT DONE empty (3)
  File.write(File.join(wd, 'phase6-success.json'), JSON.generate('workbookId' => 'wb-1', 'chartCount' => 0))
  code, = run_vc(VC, wd)
  check(code == 3, "0-chart + no-gates => exit 3 empty (got #{code})", fails)

  # 5) workbook mismatch → exit 4
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'all-pass'))
  code, = run_vc(VC, wd, wb: 'wb-OTHER')
  check(code == 4, "workbook mismatch => exit 4 (got #{code})", fails)
end

# 6) orchestrator invokes the shared gate; shared gate stamps chartCount; SKILL has THE ONE PATH.
mt = File.read(File.join(DIR, 'migrate-thoughtspot.py'))
check(mt.include?('assert-phase6-ran.rb'), 'orchestrator invokes the assert-phase6-ran hard gate', fails)
asrt = File.read(File.join(DIR, 'assert-phase6-ran.rb'))
check(asrt.include?('phase6-success.json') && asrt.include?("'chartCount'"),
      'shared gate stamps phase6-success.json with chartCount', fails)
sk = File.read(File.join(DIR, '..', 'SKILL.md'))
check(sk.include?('THE ONE PATH') && sk.downcase.include?('never hand-drive'),
      'SKILL carries THE ONE PATH / no-hand-drive directive', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
