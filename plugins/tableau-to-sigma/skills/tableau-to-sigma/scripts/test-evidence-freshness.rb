#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof finding 5: the finalize preflight accepted a numeric-parity.json
# whose inputs had changed (anchors added, workbook patched) because freshness
# was keyed on the ground-truth plan timestamp alone. verify-ground-truth.rb
# now stamps the digest of its inputs; any change makes it stale. The anchors
# verdict is stale once source-anchors.json or the live spec is newer.

require 'json'
require 'tmpdir'
require_relative 'lib/finalize_preflight'
require_relative 'lib/evidence_inputs'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def w(d, f, obj)
  File.write(File.join(d, f), obj.is_a?(String) ? obj : JSON.generate(obj))
end

Dir.mktmpdir do |d|
  w(d, 'x.twb', '<workbook/>')
  w(d, 'parity-plan.json', { 'charts' => [] })
  w(d, 'ground-truth-plan.json', { 'generated_at' => 'T0', 'entries' => [] })
  w(d, 'ground-truth-actuals.json', { 'plan_generated_at' => 'T0' })
  w(d, 'source-anchors.json', { 'anchors' => [{ 'id' => 'a1', 'raw' => '1' }] })
  w(d, 'wb-spec.json', { 'document' => { 'documentVersion' => 3 } })
  sleep 1.1
  w(d, 'anchors-verdict.json', { 'pass' => true, 'checked' => 1, 'export_cache' => { 'doc_version' => '3' } })
  w(d, 'parity-actuals.json', { 'A' => [[1]] })
  w(d, 'numeric-parity.json', { 'plan_generated_at' => 'T0', 'tiles' => {}, 'inputs' => EvidenceInputs.gt_fingerprint(d) })
  gt = ->(items) { items.find { |i| i[:id] == 'gt-verify' } }
  ok(gt.call(FinalizePreflight.check_ground_truth(d, 'c1', nil, nil)).nil?, 'unchanged inputs → numeric-parity.json is fresh')
  ok(FinalizePreflight.check_anchors(d, 'wb').nil?, 'unchanged anchors + spec → anchors verdict fresh')

  w(d, 'anchors-verdict.json', { 'pass' => true, 'checked' => 1, 'export_cache' => { 'doc_version' => '4' } })
  it = gt.call(FinalizePreflight.check_ground_truth(d, 'c1', nil, nil))
  ok(it && it[:auto] && it[:why].include?('anchors-verdict.json'), "anchors re-verified (new doc version) → numeric parity stale, names the input (#{it && it[:why]})")

  w(d, 'numeric-parity.json', { 'plan_generated_at' => 'T0', 'tiles' => {}, 'inputs' => EvidenceInputs.gt_fingerprint(d) })
  sleep 1.1
  w(d, 'wb-spec.json', { 'document' => { 'documentVersion' => 5 } })
  ok(FinalizePreflight.check_anchors(d, 'wb')&.dig(:id) == 'anchors-verdict', 'the workbook changed (live spec newer) → anchors verdict stale')
  it = gt.call(FinalizePreflight.check_ground_truth(d, 'c1', nil, nil))
  ok(it && it[:why].include?('wb-spec.json'), 'and numeric parity stale (wb-spec.json changed)')

  w(d, 'numeric-parity.json', { 'plan_generated_at' => 'T0', 'tiles' => {} })
  it = gt.call(FinalizePreflight.check_ground_truth(d, 'c1', nil, nil))
  ok(it && it[:why].include?('no input stamp'), 'an unstamped (pre-fix) numeric-parity.json is never trusted')
end

src = File.read(File.join(__dir__, 'verify-ground-truth.rb'), encoding: 'UTF-8')
ok(src.include?("'inputs' => EvidenceInputs.gt_fingerprint(dir, sigma_actuals: sigma_path)"), 'verify-ground-truth stamps its inputs')

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
