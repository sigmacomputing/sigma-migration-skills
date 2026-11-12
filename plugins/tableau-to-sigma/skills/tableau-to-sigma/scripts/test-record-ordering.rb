#!/usr/bin/env ruby
# frozen_string_literal: true
# record-visual-check.rb ordering trap (both 2026-11-09 regression runs): the
# agent recorded the visual verdict BEFORE the first finalize (no
# parity-final.json yet), or omitted --screenshot while a fidelity ledger
# existed, and was refused without a usable next step. Now:
#   * no parity-final.json → refused FIRST (before any other check), exit 1,
#     nothing written, with ONE exact next command — the finalize command from
#     <workdir>/finalize-command.json (migrate-tableau.rb pass 1 writes it) —
#     and this record command to re-run (its --screenshot filled from the ledger);
#   * --screenshot omitted with a ledger → inferred from the ledger's latest
#     budgeted render (the only value it may take), stamped, and recorded.
#
# Usage:  ruby scripts/test-record-ordering.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'shellwords'
require_relative 'lib/blind_fixture'

SCRIPT = File.join(__dir__, 'record-visual-check.rb')
CATALOG = File.expand_path('../refs/sigma-platform-differences.json', __dir__)

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def ledger(dir)
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(
    'workbook_id' => 'wb', 'page_id' => 'p', 'pass' => 2, 'max_passes' => 5,
    'renders' => [{ 'pass' => 1, 'path' => 'rcf-pass-1.png' }, { 'pass' => 2, 'path' => 'sigma-render.png' }], 'entries' => []
  ))
end

def run(dir, *args)
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
end

FINALIZE = ['ruby', 'scripts/migrate-tableau.rb', '--workbook', 'Complex Pivot', '--out', '/tmp/w x',
            '--finalize', '--actuals', '/tmp/w x/parity-actuals.json'].freeze

puts '== record before the first finalize =='
Dir.mktmpdir('rvc-order') do |dir|
  BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 90)
  ledger(dir)
  File.write(File.join(dir, 'finalize-command.json'), JSON.generate('schema' => 'finalize-command/v1', 'argv' => FINALIZE))
  grade = File.join(dir, 'blind-grade.json')
  out, err, st = run(dir, '--agent-vision', 'true', '--blind-grade', grade, '--notes', 'pivot matches')
  check(st.exitstatus == 1, "refused exit 1 (got #{st.exitstatus})")
  check(err.include?('parity-final.json does not exist yet') && err.include?('AFTER the first finalize'),
        'refusal says why: record runs after the first finalize')
  check(err.include?("Next command (finalize first):\n    #{Shellwords.join(FINALIZE)}\n"),
        'refusal prints the EXACT finalize command from finalize-command.json (shell-quoted)')
  rerun = ['ruby', 'scripts/record-visual-check.rb', '--workdir', dir, '--agent-vision', 'true', '--blind-grade', grade,
           '--notes', 'pivot matches', '--screenshot', 'sigma-render.png']
  check(err.include?("Then re-run this record command:\n    #{Shellwords.join(rerun)}"),
        're-run command is this command verbatim plus --screenshot from the ledger\'s latest render')
  check(!File.exist?(File.join(dir, 'parity-final.json')) && !File.exist?(File.join(dir, 'visual-residuals.json')) && out.empty?,
        'nothing was written')
end

Dir.mktmpdir('rvc-order') do |dir|
  out, err, st = run(dir, '--agent-vision', 'true', '--blind-grade', File.join(dir, 'no-such-grade.json'))
  check(st.exitstatus == 1 && err.include?('does not exist yet') && !err.include?('not found: ') && out.empty?,
        'ordering refusal comes BEFORE any other check (a missing grade file is not reported first)')
  check(err.include?('ruby scripts/phase6-parity.rb --finalize') && err.include?(dir),
        'no finalize-command.json: names this plugin\'s shipped finalize script and the workdir')
  check(!err.include?('--screenshot'), 'no ledger: no --screenshot is invented for the re-run')
end

Dir.mktmpdir('rvc-order') do |dir|
  _o, err, st = run(dir, '--verdict', 'pass', '--agent-vision', 'true', '--checklist', 'palette_match=pass',
                    '--no-vision-waiver', 'subagents lack image input')
  check(st.exitstatus == 1 && err.include?("--no-vision-waiver #{Shellwords.escape('subagents lack image input')}"),
        're-run echoes the command as typed, including the --no-vision-waiver reason (quoted)')
end

Dir.mktmpdir('rvc-order') do |dir|
  BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 90)
  ledger(dir)
  out, err, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, File.join(__dir__, 'record-blind-grade.rb'),
                                '--workdir', dir, '--notes', 'pivot matches')
  all = out + err # the wrapper re-prints the recorder's combined output on stdout
  check(st.exitstatus == 1 && all.include?('does not exist yet') && !all.include?('archived') &&
        File.file?(File.join(dir, 'blind-grade.json')) && Dir[File.join(dir, 'blind-grade.refused-*.json')].empty?,
        'record-blind-grade.rb before finalize: the GOOD grade is not archived as refused (only the order was wrong)')
end

puts '== --screenshot inferred from the fidelity ledger =='
Dir.mktmpdir('rvc-order') do |dir|
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
  BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 90)
  ledger(dir)
  out, err, st = run(dir, '--agent-vision', 'true', '--blind-grade', File.join(dir, 'blind-grade.json'))
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(st.success? && pf['visual_verdict'] == 'pass', "v2 grade records without --screenshot (exit #{st.exitstatus}) #{err.lines.first}")
  check(out.include?('--screenshot not given') && out.include?('(pass 2): sigma-render.png'),
        'output says which render was used (the latest budgeted pass)')
  check(pf['screenshot_path'] == 'sigma-render.png' && pf.dig('blind_grade', 'fidelity_render', 'pass') == 2,
        'the inferred screenshot is stamped and bound to the latest render')
end
Dir.mktmpdir('rvc-order') do |dir|
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
  BlindFixture.install(dir, stamp: false) # v1 grade
  ledger(dir)
  cl = BlindFixture::KEYS.map { |k| "#{k}=pass" }.join(',')
  _o, _e, st = run(dir, '--verdict', 'pass', '--agent-vision', 'true', '--checklist', cl,
                   '--blind-grade', File.join(dir, 'blind-grade.json'))
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(st.success? && pf['screenshot_path'] == 'sigma-render.png', 'v1 grade: --screenshot inferred the same way')
end
Dir.mktmpdir('rvc-order') do |dir|
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
  BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 90)
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(
    'renders' => [{ 'pass' => 1, 'path' => 'sigma-render.png' }, { 'pass' => 2, 'path' => 'rcf-pass-2.png' }], 'entries' => []
  ))
  File.binwrite(File.join(dir, 'rcf-pass-2.png'), BlindFixture.png_bytes('L'))
  _o, err, st = run(dir, '--agent-vision', 'true', '--blind-grade', File.join(dir, 'blind-grade.json'))
  check(!st.success? && err.include?('do not identify the same pixels') &&
        !JSON.parse(File.read(File.join(dir, 'parity-final.json'))).key?('visual_verdict'),
        'inference never weakens the binding: a grade of an older render is still refused')
end

puts($fails.empty? ? 'ALL PASS — record-visual-check ordering' : "#{$fails.size} FAILURE(S)")
exit($fails.empty? ? 0 : 1)
