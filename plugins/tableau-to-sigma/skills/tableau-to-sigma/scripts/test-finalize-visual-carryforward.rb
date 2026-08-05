#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test: phase6-parity.rb --finalize must carry EVERY key that
# record-visual-check.rb stamps onto parity-final.json forward across re-runs.
# Field failure (round 6): a finalize re-run preserved visual_verdict but
# WIPED style_checklist, so gate 8b ("visual PASS requires a complete clean
# six-dimension checklist") flipped from pass to exit 13 and the finalize loop
# could never satisfy the gate again. The whitelist must stay in lockstep with
# record-visual-check.rb's stamped keys.
# Usage: ruby scripts/test-finalize-visual-carryforward.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPTS = __dir__
PHASE6  = File.join(SCRIPTS, 'phase6-parity.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# The stamped-key contract lives in record-visual-check.rb (s['<key>'] = ...).
# Read it from the source so this test fails when a NEW stamped key is added
# without extending the finalize carry-forward whitelist.
rvc_src = File.read(File.join(SCRIPTS, 'record-visual-check.rb'))
stamped_keys = rvc_src.scan(/^s\['([a-z_]+)'\]\s*=/).flatten.uniq
check(stamped_keys.include?('style_checklist'),
      "contract scan finds style_checklist among record-visual-check stamped keys (got #{stamped_keys})", fails)

Dir.mktmpdir do |dir|
  plan = { 'charts' => [
    { 'chart' => 'Healthy', 'expected' => [['East', 100]], 'sigma_columns' => %w[c-r c-v] }
  ] }
  File.write(File.join(dir, 'parity-plan.json'), JSON.pretty_generate(plan))
  actuals_path = File.join(dir, 'parity-actuals.json')
  File.write(actuals_path, JSON.pretty_generate('Healthy' => [['East', 100]]))

  env = { 'SIGMA_BASE_URL' => 'https://stub.invalid', 'SIGMA_API_TOKEN' => 'stub' }
  run_finalize = lambda do
    Open3.capture3(env, RbConfig.ruby, PHASE6, '--tableau', dir, '--finalize',
                   '--actuals', actuals_path)
  end

  _out, err, st = run_finalize.call
  check(st.success?, "first finalize exits 0 (got #{st.exitstatus}: #{err.lines.first})", fails)
  final_path = File.join(dir, 'parity-final.json')
  check(File.exist?(final_path), 'first finalize writes parity-final.json', fails)

  # Simulate record-visual-check.rb stamping a pass verdict + full checklist.
  checklist = {
    'element_titles_hidden' => 'pass', 'palette_match' => 'pass',
    'composition_match' => 'pass', 'chart_shapes_match' => 'pass',
    'labels_legible' => 'pass', 'numbers_formatted' => 'pass'
  }
  s = JSON.parse(File.read(final_path))
  s['visual_verdict']  = 'pass'
  s['visual_notes']    = 'six-dimension check recorded'
  s['visual_checked']  = true
  s['screenshot_path'] = '/tmp/shot.png'
  s['style_checklist'] = checklist
  s['agent_vision']    = true
  # PR-9 stamps (mutually exclusive in real runs; both set here so the
  # carry-forward whitelist is exercised for each)
  s['blind_grade'] = { 'path' => 'blind-grade.json', 'source_sha256' => 'a' * 64,
                       'target_sha256' => 'b' * 64, 'verdict' => 'pass' }
  s['blind_grade_waiver'] = { 'kind' => 'no-vision-grader', 'reason' => 'carry test' }
  File.write(final_path, JSON.pretty_generate(s))

  _out, err, st = run_finalize.call
  check(st.success?, "finalize re-run exits 0 (got #{st.exitstatus}: #{err.lines.first})", fails)
  final = JSON.parse(File.read(final_path))
  check(final['visual_verdict'] == 'pass', 're-run keeps visual_verdict', fails)
  check(final['style_checklist'] == checklist,
        "re-run keeps the full style_checklist (got #{final['style_checklist'].inspect})", fails)
  stamped_keys.each do |k|
    check(final.key?(k), "re-run carries stamped key '#{k}' forward", fails)
  end

  # The whitelist in phase6-parity.rb must be a superset of the stamped keys —
  # source-level lockstep so the next stamped key can't silently regress.
  p6_src = File.read(PHASE6)
  carry = p6_src[/# Idempotent finalize.*?File\.write\(summary_path/m].to_s
  missing = stamped_keys.reject { |k| carry.include?(k) }
  check(missing.empty?,
        "finalize carry-forward whitelist covers every stamped key (missing: #{missing})", fails)
end

if fails.empty?
  puts 'test-finalize-visual-carryforward: ALL PASS'
else
  puts "test-finalize-visual-carryforward: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
