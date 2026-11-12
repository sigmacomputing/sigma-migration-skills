#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof: record-visual-check refused the blind grade because
# --screenshot was not passed (required when fidelity-ledger.json exists), and
# by the time that surfaced the repeated --finalize had tripped the loop
# breaker. The finalize PREFLIGHT (exit 29, never a loop-log attempt) now
# checks up front: an unrecorded blind grade stops with the exact command,
# --screenshot set to the ledger's latest render.

require 'json'
require 'digest'
require 'tmpdir'
require 'rbconfig'
require 'open3'
require_relative 'lib/finalize_preflight'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |wd|
  png = File.join(wd, 'rcf-pass-3.png')
  File.binwrite(png, "\x89PNG fake pixels".b)
  sha = Digest::SHA256.file(png).hexdigest
  File.write(File.join(wd, 'fidelity-ledger.json'), JSON.generate('renders' => [{ 'pass' => 3, 'path' => png }]))
  File.write(File.join(wd, 'blind-grade.json'), JSON.generate('verdict' => 'FAIL', 'target_sha256' => sha))

  ok(FinalizePreflight.check_visual_record(wd).nil?, 'before the first finalize (no parity-final.json) nothing to record onto → no stop')
  File.write(File.join(wd, 'parity-final.json'), JSON.generate('status' => 'FAIL'))
  it = FinalizePreflight.check_visual_record(wd)
  ok(it && it[:id] == 'visual-record' && it[:auto] == false, 'unrecorded grade → manual preflight item (finalize stops exit 29, no loop-log)')
  cmd = Array(it && it[:cmd])
  ok(cmd.each_cons(2).include?(['--screenshot', png]), "the command names --screenshot <latest render> (#{cmd.join(' ')})")
  ok(cmd.each_cons(2).include?(['--verdict', 'divergent']) && cmd.include?('--notes'), 'a FAIL grade records as divergent (with --notes)')
  ok(FinalizePreflight.analyze(wd).any? { |i| i[:id] == 'visual-record' }, 'part of the finalize preflight analysis')

  File.write(File.join(wd, 'parity-final.json'), JSON.generate('blind_grade' => { 'target_sha256' => sha }))
  ok(FinalizePreflight.check_visual_record(wd).nil?, 'recorded grade → no stop')

  File.write(File.join(wd, 'parity-final.json'), JSON.generate('status' => 'FAIL'))
  File.write(File.join(wd, 'blind-grade.json'), JSON.generate('verdict' => 'PASS', 'target_sha256' => 'f' * 64))
  it = FinalizePreflight.check_visual_record(wd)
  ok(it && it[:why].include?('different pixels') && it[:cmd].include?(png) &&
     it[:cmd].none? { |part| part == 'render' },
     'grade of other pixels → re-grade the existing latest render without spending another pass')
end

puts 'round 8: first finalize, supersede, refused-grade archive'
Dir.mktmpdir do |wd|
  png = File.join(wd, 'rcf-pass-3.png')
  File.binwrite(png, "\x89PNG fake pixels".b)
  File.write(File.join(wd, 'fidelity-ledger.json'), JSON.generate('renders' => [{ 'pass' => 3, 'path' => png }]))
  File.write(File.join(wd, 'parity-final.json'), JSON.generate('status' => 'PASS'))
  ok(FinalizePreflight.check_visual_record(wd).nil?, 'up-front (pre-Phase-6) with no grade: no stop (Phase 6 has not written the verdict slot)')
  it = FinalizePreflight.check_visual_record(wd, post_phase6: true)
  ok(it && it[:cmd].each_cons(2).include?(['--screenshot', png]) && it[:cmd].include?('scripts/record-blind-grade.rb'),
     "right after Phase 6 (first finalize): no verdict recorded → stop with the FULL command incl. --screenshot (#{it && it[:cmd].join(' ')})")
  ok(it[:cmd].each_cons(2).include?(['--verdict', 'pass']) && it[:cmd].include?('--checklist'),
     'the first-finalize command records a subsequent passing grade as pass')
  File.write(File.join(wd, 'blind-grade.json'), JSON.generate('verdict' => 'FAIL', 'target_sha256' => '0' * 64))
  File.write(File.join(wd, 'parity-final.json'), JSON.generate('visual_verdict' => 'divergent'))
  ok(FinalizePreflight.check_visual_record(wd).nil? && FinalizePreflight.check_visual_record(wd, post_phase6: true).nil?,
     'a FAILING grade left on disk after a recorded divergent verdict no longer blocks (the r7 deadlock)')
  File.write(File.join(wd, 'blind-grade.json'), JSON.generate('verdict' => 'PASS', 'target_sha256' => Digest::SHA256.file(png).hexdigest))
  ok(FinalizePreflight.check_visual_record(wd), 'a NEW passing grade over a recorded divergent verdict still asks to be recorded')

  # The wrapper: the shared recorder REFUSES (pixels do not match) → the grade is archived.
  File.write(File.join(wd, 'blind-grade.json'), JSON.generate('verdict' => 'PASS', 'target_sha256' => 'e' * 64,
                                                               'source_sha256' => 'e' * 64, 'dimensions' => {}))
  out, st = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'record-blind-grade.rb'), '--workdir', wd, '--verdict', 'divergent',
                            '--notes', 'gap')
  arch = File.join(wd, 'blind-grade.refused-1.json')
  ok(!st.success? && File.file?(arch) && !File.exist?(File.join(wd, 'blind-grade.json')),
     "refused grade archived as blind-grade.refused-1.json (#{out.lines.grep(/REFUSED|archived/).first.to_s.strip})")
  log = File.readlines(File.join(wd, 'blind-grade-refusals.jsonl')).map { |l| JSON.parse(l) }
  ok(log.size == 1 && !log[0]['reason'].to_s.empty?, 'the refusal reason is kept in blind-grade-refusals.jsonl')
  ok(out.include?('--screenshot') && out.include?('verdict divergent'), 'prints the next step (re-grade, or record divergent without a grade)')
  ok(FinalizePreflight.check_visual_record(wd).nil?, 'after archiving, the preflight is no longer blocked by it')

  File.write(File.join(wd, 'blind-grade.json'), JSON.generate('verdict' => 'PASS', 'target_sha256' => 'a' * 64))
  out, st = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'record-blind-grade.rb'), '--workdir', wd, '--verdict', 'pass',
                            '--checklist', '<k=pass|fail|na,...>')
  ok(!st.success? && out.include?('FATAL: --checklist') && File.file?(File.join(wd, 'blind-grade.json')) &&
     !File.file?(File.join(wd, 'blind-grade.refused-2.json')),
     'a fatal usage error leaves blind-grade.json in place for retry')
end

puts 'v2 record command: verdict: nil omits --verdict/--checklist'
Dir.mktmpdir do |wd|
  png = File.join(wd, 'rcf-pass-2.png')
  File.binwrite(png, "\x89PNG fake pixels".b)
  File.write(File.join(wd, 'fidelity-ledger.json'), JSON.generate('renders' => [{ 'pass' => 2, 'path' => png }]))
  File.write(File.join(wd, 'blind-grade.json'), JSON.generate('verdict' => 'FAIL'))
  v2 = FinalizePreflight.record_command(wd, verdict: nil)
  ok(v2.include?('scripts/record-blind-grade.rb') && v2.none? { |a| a == '--verdict' || a == '--checklist' },
     "verdict: nil omits --verdict and --checklist (#{v2.join(' ')})")
  ok(v2.each_cons(2).include?(['--screenshot', png]) &&
     v2.each_cons(2).include?(['--blind-grade', File.join(wd, 'blind-grade.json')]),
     'verdict: nil still carries --screenshot and --blind-grade')
  legacy = FinalizePreflight.record_command(wd)
  ok(legacy.each_cons(2).include?(['--verdict', 'divergent']) && legacy.none? { |a| a == '--blind-grade' },
     'omitting verdict: still derives the legacy v1 verdict from the grade on disk')
  ok(FinalizePreflight.record_command(wd, verdict: 'pass').include?('--checklist'), 'explicit pass keeps --verdict pass + --checklist')
  # A v2 grade on disk (regression 2026-11-09, RCC): the derived hint must be
  # the v2 shape, never "--verdict divergent" for a faithful 77/80 grade.
  File.write(File.join(wd, 'blind-grade.json'),
             JSON.generate('schema' => 'blind-grade/v2', 'overall_score' => 78, 'verdict' => 'Same dashboard'))
  derived = FinalizePreflight.record_command(wd)
  ok(derived.none? { |a| a == '--verdict' || a == '--checklist' } &&
     derived.each_cons(2).include?(['--blind-grade', File.join(wd, 'blind-grade.json')]),
     "a v2 grade on disk derives the v2 command (#{derived.join(' ')})")
end

src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
ok(src.include?('check_visual_record(WORK, post_phase6: true)') && src.include?('if p6st.success? &&'),
   'the orchestrator re-checks right after Phase 6 (parity passed) and stops before the gate battery')
ok(src.scan('FinalizePreflight.record_command(WORK').size >= 2, 'both VISUAL STOP blocks print the full command')

Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'blind-grade.json'), JSON.generate('verdict' => 'PASS', 'target_sha256' => 'a' * 64))
  File.write(File.join(wd, 'parity-final.json'), '{}')
  ok(FinalizePreflight.check_visual_record(wd).nil?, 'no RCF ledger → the recorder needs no --screenshot; no stop')
end

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
