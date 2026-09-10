#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the Qlik completion contract.
#
# "Done" is a fact on disk: only shared assert-phase6-ran.rb may stamp an
# all-pass marker, and the verifier additionally requires strict parity and the
# census/report/PNG/ledger contract. The fixture-heavy successful path lives in
# tests/test_completion_contract.py; this file pins early-exit and wiring rules.
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
  check(out.include?('NOT DONE') && out.include?('shared Phase 6 gate'),
        'empty-workdir message names the missing shared hard gate', fails)

  # 2) a legacy marker with charts but no all-pass gate record is insufficient.
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'parity-pass',
                           'generatedAt' => '2026-07-10T00:00:00Z'))
  code, out = run_vc(VC, wd)
  check(code == 3, "legacy marker without all-pass => exit 3 (got #{code})", fails)
  check(out.include?('all-gates'), 'legacy marker failure names the all-gates requirement', fails)

  # 3) marker present but 0 charts → NOT DONE (3) (empty workbook)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 0))
  code, = run_vc(VC, wd)
  check(code == 3, "0-chart marker => exit 3 empty (got #{code})", fails)

  # 4) workbook mismatch → exit 4
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'all-pass'))
  code, = run_vc(VC, wd, wb: 'wb-OTHER')
  check(code == 4, "workbook mismatch => exit 4 (got #{code})", fails)
end

# 5) the orchestrator wires the empty-workbook guard + shared gate.
mt = File.read(File.join(DIR, 'migrate-qlik.rb'))
check(mt.include?('mechanical_ok = parity_ok && layout_ok && control_ok && flip_ok') &&
      mt.include?("wb_res['unbuiltSourceVisuals'].to_a.empty?") &&
      mt.include?('built_ok = mechanical_ok && cleanup_ok && pre_finalizer_ok && assert_ok'),
      'orchestrator requires queryable elements and complete source coverage for a green', fails)
check(mt.include?("require 'flip_gate'") && mt.include?('FlipGate.decide'),
      'orchestrator runs gate 7b (runtime control-flip proof) before a green', fails)
check(mt.include?("'assert-phase6-ran.rb'") &&
      !mt.match?(/File\.write\([^)]*phase6-success\.json/),
      'orchestrator delegates the success sentinel exclusively to the shared gate', fails)
# 6) SKILL carries THE ONE PATH / no-hand-drive directive.
sk = File.read(File.join(DIR, '..', 'SKILL.md'))
check(sk.include?('THE ONE PATH') && sk.downcase.include?('never hand-drive'),
      'SKILL carries THE ONE PATH / no-hand-drive directive', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
