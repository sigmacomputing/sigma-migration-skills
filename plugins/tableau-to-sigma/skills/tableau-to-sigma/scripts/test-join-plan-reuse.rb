#!/usr/bin/env ruby
# frozen_string_literal: true
# test-join-plan-reuse.rb — the --reuse-dm path must derive the join-plan
# ledger too (gate 16, exit 23).
#
# Live-e2e defect: the ledger derivation lived entirely inside migrate-tableau's
# `unless reuse_dm_id` build block, so a --reuse-dm run never wrote
# join-plan.json — and gate 16's belt-and-braces only greps dm-spec.json for
# `Lookup(` (a file the reuse path never writes), so a reused DM over a
# federated source silently bypassed the join-cardinality gate.
#
# Two layers, mirroring the test-reuse-* convention (behavioral proof is the
# live E2E; source assertions guard the wiring against silent regression):
#   1. wiring — the derivation runs on BOTH paths, scans the LIVE DM readback
#      (dm_spec_rb) on reuse, and lands in the same <workdir>/join-plan.json;
#   2. behavior — a readback-shaped spec (what GET /v2/dataModels/<id>/spec
#      returns) run through the same JoinPlan.derive + write produces a ledger
#      whose Lookup entry the gate can see.
#
# Usage: ruby scripts/test-join-plan-reuse.rb
require 'json'
require 'tmpdir'
require_relative 'lib/join_plan'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

puts '== wiring: migrate-tableau derives the ledger on the reuse path too =='
src = File.read(File.join(__dir__, 'migrate-tableau.rb'))
derive_at = src.index('JoinPlan.derive')
gate_off  = src.index("\nunless reuse_dm_id") # the statement form opening the build-only block
check(!derive_at.nil?, 'ledger derivation present', fails)
check(src.scan('JoinPlan.derive').size == 1, 'ONE shared derivation call (no build-only twin to drift)', fails)
check(src.include?('_jp_spec = reuse_dm_id ? dm_spec_rb : dm'),
      'reuse path scans the LIVE DM readback spec (dm_spec_rb) for Lookup( synthesis', fails)
check(src.match?(/JoinPlan\.derive\(_jp_spec,\s*_jp_twb,\s*\n?\s*db:\s*db \|\| opts\[:db\],\s*schema:\s*schema \|\| opts\[:schema\]\)/),
      'derivation receives the resolved --db/--schema with a flag fallback (nil on the FAST PATH)', fails)
# Twin-B live defect (2026-07-19): have_twb is only assigned inside the
# full-pipeline block, so the FAST PATH derived from a nil .twb — the source
# LEFT JOIN never landed and gate 16 passed on an EMPTY ledger. The .twb must
# come from the workdir on every route.
check(src.include?("_jp_twb = have_twb ? File.read(twb, encoding: 'UTF-8') : JoinPlan.workdir_twb(WORK)"),
      'the .twb is read from the workdir on EVERY route (FAST PATH included) — never gated on have_twb alone', fails)
check(src.include?("JoinPlan.write(File.join(WORK, 'join-plan.json')"),
      'ledger lands in <workdir>/join-plan.json (the exact path gate 16 inspects)', fails)
check(!gate_off.nil? && derive_at < gate_off,
      'derivation sits BEFORE the `unless reuse_dm_id` build-only block (runs on reuse)', fails)

puts "\n== behavior: a readback-shaped spec yields the same ledger file =="
# Shape of GET /v2/dataModels/<id>/spec: pages/elements/columns with formulas —
# including the synthesized Coalesce/Lookup a previously-built DM carries.
readback = {
  'name' => 'Reused DM', 'schemaVersion' => 1,
  'pages' => [{ 'id' => 'p1', 'name' => 'p1', 'elements' => [
    { 'id' => 'el-fact', 'name' => 'Rev Primary', 'kind' => 'table',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC REV_PRIMARY] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Unified Region',
          'formula' => 'Coalesce([Region], Lookup([Rev Offset/Region], [Entity Id], [Rev Offset/Entity Id]))' }
      ] },
    { 'id' => 'el-tgt', 'name' => 'Rev Offset', 'kind' => 'table',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC REV_OFFSET] },
      'columns' => [
        { 'id' => 't1', 'name' => 'Entity Id', 'formula' => '[REV_OFFSET/Entity Id]' },
        { 'id' => 't2', 'name' => 'Region', 'formula' => '[REV_OFFSET/Region]' }
      ] }
  ] }]
}
twb = File.read(File.join(__dir__, 'test-fixtures', 'join-coalesce.twb'), encoding: 'UTF-8')
Dir.mktmpdir do |work|
  # Exactly what the orchestrator now does on reuse: readback spec + .twb.
  entries = JoinPlan.derive(readback, twb, db: 'ANALYTICS', schema: 'PUBLIC')
  path = JoinPlan.write(File.join(work, 'join-plan.json'), entries)
  check(File.exist?(File.join(work, 'join-plan.json')), 'join-plan.json written on the reuse path', fails)
  doc = JSON.parse(File.read(path))
  kinds = (doc['entries'] || []).map { |e| e['kind'] }
  check(kinds == %w[federated-join lookup-synthesis],
        "ledger carries the .twb federated join AND the readback Lookup (got #{kinds.inspect})", fails)
  lk = doc['entries'].find { |e| e['kind'] == 'lookup-synthesis' } || {}
  check(lk['left'] == 'Rev Primary' && lk['right'] == 'Rev Offset',
        'Lookup entry derived from the READBACK formulas (not a local dm-spec.json)', fails)
  check(doc['entries'].all? { |e| e['status'] == 'unprobed' },
        'entries start unprobed — gate 16 blocks until probe-join-keys.rb proves them', fails)
end

puts
if fails.empty?
  puts 'test-join-plan-reuse: ALL PASS'
else
  puts "test-join-plan-reuse: #{fails.size} FAILURE(S)"; fails.each { |f| puts "  - #{f}" }; exit 1
end
