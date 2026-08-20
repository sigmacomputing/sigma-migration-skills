#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave2-verdict-gates.rb — wave-2 lane B: verdict + gate changes in
# assert-phase6-ran.rb (and their verify-complete.rb reconciliation).
#
#   A. Tolerant gate 16 (W2.18 pre-land): the ledger's SECOND shape — real
#      emitted joins (status "emitted", evidence-bound to a `"kind": "join"`
#      dm-spec) — is accepted; a hand-stamped "emitted" without the spec
#      evidence still fails; the widened belt-and-braces catches emitted joins
#      with no ledger at all; the shipped shape stays byte-for-byte accepted
#      (no-false-trip).
#
# Later sections (same lane) extend this file for the gate-18 tier-S
# valued-anchors acceptance, tier-scaled waiver budgets, and the W2.3
# factory-verdict labeling.
#
# Runs the real script per scenario in a scratch workdir with no SIGMA_* env,
# so live gates SKIP and the file-based gates are exercised (the
# test-assert-phase6-gates.rb harness pattern). EXCEPTION (ruzs): the W2.3
# verdict-labeling scenarios run AUDITED via run_gate_audited — a local stub
# serves gate 3/7 a complete clean /columns page, because GREEN is only
# mintable over a finished live column audit now.
#
# Usage:  ruby scripts/test-wave2-verdict-gates.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/blind_fixture'

SCRIPT = File.join(__dir__, 'assert-phase6-ran.rb')
VERIFY = File.join(__dir__, 'verify-complete.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A workdir that satisfies every default gate (mirrors
# test-assert-phase6-gates.rb#base_workdir).
def base_workdir(dir, parity_extra: {})
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => ['KPI', 'Trend'], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass',
             'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass',
                                    'composition_match' => 'pass', 'chart_shapes_match' => 'pass',
                                    'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
             'agent_vision' => true }.merge(parity_extra)
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  BlindFixture.install(dir)
end

def run_gate(dir, *args)
  env = { 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }
  out, err, st = Open3.capture3(env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
  [out, err, st]
end

JOIN_ENTRY_UNIQUE = { 'kind' => 'federated-join', 'join_type' => 'left',
                      'left' => 'FACT', 'right' => 'DIM', 'keys' => ['ORDER_KEY'],
                      'status' => 'unique' }.freeze
JOIN_ENTRY_EMITTED = { 'kind' => 'emitted-join', 'join_type' => 'inner',
                       'left' => 'FACT', 'right' => 'DIM', 'keys' => ['ORDER_KEY'],
                       'status' => 'emitted' }.freeze
DM_WITH_JOIN   = { 'name' => 'dm', 'sources' => [{ 'kind' => 'join', 'joinType' => 'inner' }] }.freeze
DM_WITH_LOOKUP = { 'name' => 'dm', 'columns' => [{ 'name' => 'x', 'formula' => 'Lookup([a],[b])' }] }.freeze

puts 'A. tolerant gate 16 — both ledger shapes'

# A1 no-false-trip: the shipped shape (unique entries) still exits 0 with the OK line.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'join-plan.json'), JSON.generate('entries' => [JOIN_ENTRY_UNIQUE]))
  out, err, st = run_gate(dir)
  check(st.success?, "shape 1 (unique) → exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})", fails)
  check(out.include?('gate 16: join-cardinality ledger resolved — 1 unique'),
        'shape-1 OK line preserved (no-false-trip)', fails)
end

# A2 shape 2 accepted: emitted entry + dm-spec carrying "kind": "join" → exit 0.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_JOIN))
  File.write(File.join(dir, 'join-plan.json'),
             JSON.generate('entries' => [JOIN_ENTRY_UNIQUE, JOIN_ENTRY_EMITTED]))
  out, _err, st = run_gate(dir)
  check(st.success?, "shape 2 (emitted + spec evidence) → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('1 emitted as real join(s)'), 'OK line counts emitted entries', fails)
end

# A3 trip: "emitted" status WITHOUT the dm-spec join evidence → still UNPROVEN, exit 23.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_LOOKUP))
  File.write(File.join(dir, 'join-plan.json'), JSON.generate('entries' => [JOIN_ENTRY_EMITTED]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "hand-stamped emitted without spec evidence → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('evidence-bound'), 'failure names the evidence binding', fails)
end

# A4 widened belt-and-braces: dm-spec emits a join, NO ledger → exit 23.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_JOIN))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "emitted join with no join-plan.json → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('"kind": "join"'), 'failure names the emitted-join evidence', fails)
end

# A5 old belt-and-braces preserved: Lookup( in dm-spec, no ledger → exit 23.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_LOOKUP))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "Lookup( with no ledger → exit 23 preserved (got #{st.exitstatus})", fails)
  check(err.include?('Lookup()'), 'Lookup belt-and-braces message preserved', fails)
end

# A6 clean: no dm-spec, no ledger → exit 0 (stated N/A, never silent).
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success?, "no join surface → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('no join grain assumptions (or emitted join surface)'), 'gate 16 states the N/A', fails)
end

# A7 per-entry binding (fix-pass): ONE genuine emitted join in the spec must
# never make "emitted" a skip token for OTHER entries — a lookup-synthesis
# entry hand-stamped "emitted" beside a real emitted-join stays UNPROVEN.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(
               DM_WITH_JOIN.merge('columns' => [{ 'name' => 'x', 'formula' => 'Lookup([a],[b])' }])))
  File.write(File.join(dir, 'join-plan.json'), JSON.generate('entries' => [
               JOIN_ENTRY_EMITTED,
               { 'kind' => 'lookup-synthesis', 'left' => 'FACT', 'right' => 'DIM2',
                 'keys' => ['K'], 'status' => 'emitted' }
             ]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "hand-stamped emitted on a non-emitted-join entry → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('non-emitted entry') && err.include?('emitted-join'),
        'failure names the per-entry kind binding', fails)
end

# A8 count bound (fix-pass): more "emitted" entries than the spec has
# `"kind": "join"` occurrences → the claims exceed the evidence, exit 23.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_JOIN))
  File.write(File.join(dir, 'join-plan.json'), JSON.generate('entries' => [
               JOIN_ENTRY_EMITTED, JOIN_ENTRY_EMITTED.merge('right' => 'DIM2')
             ]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "2 emitted entries over a 1-join spec → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('more "emitted" entries'), 'failure names the count bound', fails)
end

# ---------------------------------------------------------------------------
# B. Tier-scaled waiver budgets (W2.1 gate half). The tier is READ from
# migrate-state.json (lane A writes it — the strings come from the shared
# cross-lane fixture, contract 4). Tier-S shrinks the budget 2 → 1; M/full and
# tierless workdirs keep the shipped 2 (pinned no-false-trip).
# ---------------------------------------------------------------------------
puts 'B. tier-scaled waiver budgets'

TIER_FIXTURE = File.expand_path('../../../../../shared/lib/testdata/wave2-tier-state.json', __dir__)
TIER_S_STATE = JSON.parse(File.read(TIER_FIXTURE)).reject { |k, _| k.start_with?('_') }
raise 'fixture drift: wave2-tier-state.json must carry tier=S' unless TIER_S_STATE['tier'] == 'S'

# Two budget-counted QUALITY waivers (policy exclusions never count).
def two_quality_waivers
  ['--skip-layout-lint', '--skip-control-lint']
end

# B1 trip: Tier-S + 2 quality waivers → budget 1 exceeded, exit 19.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate(TIER_S_STATE))
  out, err, st = run_gate(dir, *two_quality_waivers)
  check(st.exitstatus == 19, "Tier-S + 2 quality waivers → exit 19 (got #{st.exitstatus})", fails)
  check(err.include?('budget 1') && err.include?('Tier-S scaled from 2'),
        'failure names the shrunk Tier-S budget', fails)
  check(out.include?('[TIER] S (auto-predicate)'), 'gate log announces the tier + basis', fails)
  check(out.include?('all 25 gates execute'), 'tier banner states the frozen catalog doctrine', fails)
end

# B2 no-false-trip: tierless workdir + the same 2 waivers → budget 2 holds, exit 0.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  _out, err, st = run_gate(dir, *two_quality_waivers)
  check(st.success?, "no tier + 2 quality waivers → exit 0, shipped budget 2 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})", fails)
end

# B3 no-false-trip: Tier-M keeps the shipped budget.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'),
             JSON.generate('tier' => 'M', 'tier_basis' => 'auto-predicate'))
  out, _err, st = run_gate(dir, *two_quality_waivers)
  check(st.success?, "Tier-M + 2 quality waivers → exit 0 (budget stays 2) (got #{st.exitstatus})", fails)
  check(out.include?('[TIER] M'), 'Tier-M still announced in the gate log', fails)
end

# B4 fail-closed: junk tier string → ignored (full battery, budget 2).
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate('tier' => 'turbo'))
  out, _err, st = run_gate(dir, *two_quality_waivers)
  check(st.success?, "unknown tier string → fail-closed to shipped behavior (got #{st.exitstatus})", fails)
  check(!out.include?('[TIER]'), 'unknown tier is never announced as a tier', fails)
end

# B5 closed-vocabulary read (fix-pass): a junk tier_basis string is BLANKED,
# never printed raw into the [TIER] banner (Offramp::TIER_BASIS on read).
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'),
             JSON.generate('tier' => 'S', 'tier_basis' => 'INJECTED-junk-basis'))
  out, _err, st = run_gate(dir)
  check(st.success?, "valid tier + junk basis → tier still honored (got #{st.exitstatus})", fails)
  check(out.include?('[TIER] S — ') && !out.include?('INJECTED-junk-basis'),
        'junk tier_basis blanked from the banner (closed vocabulary on read)', fails)
end

# ---------------------------------------------------------------------------
# C. Gate-18 Tier-S GT-trio skip (W2.1 gate half). On Tier-S the trio may not
# run; the gate itself evaluates the VALUED-anchors oracle (gate 18's own
# oracle set — NOT the charts_total==0 doctrine) and still fails when any
# displayed tile lacks a valued anchor matched in it.
# ---------------------------------------------------------------------------
puts 'C. gate-18 Tier-S GT-trio skip (valued-anchors oracle)'

def gt18_fixture(dir, tier: true, uncover: nil, av_extra: {})
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate(TIER_S_STATE)) if tier
  File.write(File.join(dir, 'source.twb'), '<workbook/>')
  File.write(File.join(dir, 'parity-plan.json'),
             JSON.generate('charts' => [{ 'chart' => 'KPI' }, { 'chart' => 'Trend' }]))
  detail = [
    { 'anchor' => 'a1', 'matched_in' => 'KPI',   'valued' => true,  'provenance' => 'view-csv', 'kind' => 'numeric' },
    { 'anchor' => 'a2', 'matched_in' => 'Trend', 'valued' => true,  'provenance' => 'vds',      'kind' => 'numeric' },
    { 'anchor' => 'a3', 'matched_in' => 'KPI',   'valued' => true,  'provenance' => 'view-csv', 'kind' => 'numeric' },
    { 'anchor' => 'a4', 'matched_in' => 'Trend', 'valued' => true,  'provenance' => 'vds',      'kind' => 'numeric' },
    { 'anchor' => 'a5', 'matched_in' => 'KPI',   'valued' => true,  'provenance' => 'view-csv', 'kind' => 'numeric' }
  ]
  detail = detail.map { |d| d['matched_in'] == uncover ? d.merge('valued' => false, 'provenance' => 'png-eyeball') : d } if uncover
  av = { 'pass' => true, 'checked' => 5, 'matched' => 5, 'tiles_all_nonempty' => true,
         'valued_matched' => detail.count { |d| d['valued'] }, 'detail' => detail,
         'anchor_coverage' => { 'covered' => 2, 'displayed' => 2, 'uncovered' => [] } }.merge(av_extra)
  File.write(File.join(dir, 'anchors-verdict.json'), JSON.pretty_generate(av))
end

# C1 accept: Tier-S + every displayed tile valued-covered → exit 0, skip stated.
Dir.mktmpdir do |dir|
  gt18_fixture(dir)
  out, err, st = run_gate(dir)
  check(st.success?, "Tier-S valued-covered → exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})", fails)
  check(out.include?('Tier-S GT-trio skip') && out.include?('100% of displayed tiles'),
        'OK line states the skip + full valued coverage', fails)
  check(out.include?('view-csv|vds'), 'OK line names the valued-provenance oracle', fails)
end

# C2 trip: one tile loses its valued coverage → exit 25 naming it.
Dir.mktmpdir do |dir|
  gt18_fixture(dir, uncover: 'Trend')
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25, "Tier-S with an unvouched tile → exit 25 (got #{st.exitstatus})", fails)
  check(err.include?('UNCOVERED: "trend"') || err.include?('UNCOVERED: "Trend"'),
        'failure names the uncovered tile', fails)
  check(err.include?('run the full trio') || err.include?('derive-ground-truth'),
        'failure routes to the trio as the remedy', fails)
end

# C3 no-false-trip: NO tier → today's belt-and-braces failure, unchanged.
Dir.mktmpdir do |dir|
  gt18_fixture(dir, tier: false)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25, "tierless .twb+parity-plan → exit 25 unchanged (got #{st.exitstatus})", fails)
  check(err.include?('no ground-truth-plan.json'), 'tierless failure keeps the shipped message', fails)
end

# C4 fail-closed: Tier-S but anchors-verdict is stale (no tiles_all_nonempty) → exit 25.
Dir.mktmpdir do |dir|
  gt18_fixture(dir, av_extra: { 'tiles_all_nonempty' => nil })
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25, "stale anchors-verdict (fail-closed) → exit 25 (got #{st.exitstatus})", fails)
  check(err.include?('re-run scripts/verify-anchors.rb'), 'stale-verdict failure routes to verify-anchors', fails)
end

# ---------------------------------------------------------------------------
# D. W2.3 — verifier optional-and-labeled. A Tier-S factory GREEN with no
# countersignature is REAL but LABELED ('GREEN (factory, self-attested)',
# verdict_by 'builder-self-attested'); the bare string GREEN is unmintable on
# that path, verify-complete.rb enforces the label offline in both
# directions, and countersigned / Tier-M+ / tierless runs keep today's
# strings (no-false-trip).
# ---------------------------------------------------------------------------
puts 'D. W2.3 factory verdict labeling + verify-complete reconciliation'

FACTORY_LABEL = 'GREEN (factory, self-attested)'

def run_verify(dir, *args)
  out, err, st = Open3.capture3({}, RbConfig.ruby, VERIFY, '--workdir', dir, *args)
  [out, err, st]
end

# ruzs: GREEN now requires gate 3/7's live column audit to have COMPLETED —
# the silent-skip free pass is gone, so the verdict scenarios below need an
# honestly AUDITED clean run. One local stub Sigma serves /columns a complete
# clean page; every other path (the shared live-spec fetch for gates 4/6/7/7b)
# gets 404 and keeps those gates' existing no-spec behavior. verify-complete
# needs no stub: it re-derives offline from the recorded column-scan.json.
require 'socket'
AUDIT_STUB = TCPServer.new('127.0.0.1', 0)
AUDIT_PORT = AUDIT_STUB.addr[1]
Thread.new do
  loop do
    c = AUDIT_STUB.accept
    req = c.gets.to_s
    while (l = c.gets) && l != "\r\n"; end
    if req.include?('/columns')
      body = JSON.generate('entries' => [{ 'columnId' => 'c1', 'label' => 'A',
                                           'type' => { 'type' => 'number' } }])
      c.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
              "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    else
      c.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    end
    c.close
  end
rescue StandardError
  nil
end

def run_gate_audited(dir, *args)
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('workbookId' => 'wb-audited'))
  env = { 'SIGMA_BASE_URL' => "http://127.0.0.1:#{AUDIT_PORT}", 'SIGMA_API_TOKEN' => 'stub' }
  out, err, st = Open3.capture3(env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
  [out, err, st]
end

# D1+D2: Tier-S self-attested GREEN → labeled everywhere; verify-complete DONE.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate(TIER_S_STATE))
  out, _err, st = run_gate_audited(dir)
  check(st.success?, "Tier-S factory green → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?("VERDICT: #{FACTORY_LABEL}"), 'RESULT line carries the labeled verdict', fails)
  check(!out.match?(/VERDICT: GREEN \(degradation ledger empty/), 'bare-GREEN result line is unmintable on the factory path', fails)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  sj = JSON.parse(File.read(File.join(dir, 'phase6-success.json')))
  check(pf['verdict'] == FACTORY_LABEL && sj['verdict'] == FACTORY_LABEL,
        'parity-final + phase6-success stamp the labeled verdict', fails)
  check(pf['verdict_by'] == 'builder-self-attested' && sj['verdict_by'] == 'builder-self-attested',
        "verdict_by stamped 'builder-self-attested' in both markers", fails)
  vout, _verr, vst = run_verify(dir)
  check(vst.success?, "verify-complete on the labeled workdir → exit 0 (got #{vst.exitstatus})", fails)
  check(vout.include?("VERDICT: #{FACTORY_LABEL}") && vout.include?('builder-self-attested'),
        'verify-complete prints the labeled verdict + attestation', fails)

  # D3 trip: stripping the label after the fact is a ledger contradiction (exit 6).
  pf['verdict'] = 'GREEN'
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(pf))
  _vout2, verr2, vst2 = run_verify(dir)
  check(vst2.exitstatus == 6, "label stripped to bare GREEN → verify-complete exit 6 (got #{vst2.exitstatus})", fails)
  check(verr2.include?('labeled verdict') && verr2.include?('never launder the label off'),
        'contradiction names the mandatory label', fails)
end

# D4 no-false-trip: Tier-M self-attested keeps the bare GREEN string (the O3
# countersignature MUST is doctrine there — near-miss trajectory).
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'),
             JSON.generate('tier' => 'M', 'tier_basis' => 'auto-predicate'))
  out, _err, st = run_gate_audited(dir)
  check(st.success? && out.include?('VERDICT: GREEN (degradation ledger empty'),
        'Tier-M self-attested keeps the bare GREEN line (no label)', fails)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['verdict'] == 'GREEN' && pf['verdict_by'] == 'builder-self-attested',
        'Tier-M stamps bare verdict + self-attested provenance', fails)
end

# D5 no-false-trip: Tier-S COUNTERSIGNED run keeps the bare GREEN + verifier provenance.
Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'visual_notes' => 'VERIFIER: source vs render compared tile-by-tile' })
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate(TIER_S_STATE))
  out, _err, st = run_gate_audited(dir)
  check(st.success? && out.include?('VERDICT: GREEN (degradation ledger empty'),
        'Tier-S countersigned run keeps the bare GREEN', fails)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['verdict'] == 'GREEN' && pf['verdict_by'] == 'verifier',
        "countersigned run stamps verdict_by 'verifier'", fails)
end

# D6 no-false-trip: tierless workdir → shipped strings byte-identical.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate_audited(dir)
  check(st.success? && out.include?('VERDICT: GREEN (degradation ledger empty'),
        'tierless run keeps the shipped GREEN line', fails)
  vout, _verr, vst = run_verify(dir)
  check(vst.success? && vout.include?('VERDICT: GREEN'),
        'verify-complete on a tierless workdir unchanged', fails)
end

# D7 anti-fabrication: the label WITHOUT a factory basis is equally exit 6.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  run_gate_audited(dir) # stamps bare GREEN (tierless)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  pf['verdict'] = FACTORY_LABEL
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(pf))
  _vout, verr, vst = run_verify(dir)
  check(vst.exitstatus == 6, "fabricated factory label → verify-complete exit 6 (got #{vst.exitstatus})", fails)
  check(verr.include?('without a Tier-S self-attested basis'), 'contradiction names the missing basis', fails)
end

# D9 fix-pass: countersignature is CONTENT, not existence — a `touch`ed or
# malformed verification-result.json must NOT flip verdict_by to 'verifier'
# (the bare GREEN stays unmintable); the verifier-brief deliverable (a JSON
# hash with verdict GREEN/YELLOW/RED) still countersigns.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate(TIER_S_STATE))
  File.write(File.join(dir, 'verification-result.json'), '') # zero-byte touch
  out, _err, st = run_gate_audited(dir)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(st.success? && pf['verdict'] == FACTORY_LABEL && pf['verdict_by'] == 'builder-self-attested',
        'zero-byte verification-result.json is not countersignature evidence (label + self-attested kept)', fails)
  check(out.include?("VERDICT: #{FACTORY_LABEL}"), 'touch-file run still prints the labeled verdict', fails)
  File.write(File.join(dir, 'verification-result.json'), JSON.generate('note' => 'no verdict field'))
  _out2, _err2, st2 = run_gate_audited(dir)
  pf2 = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(st2.success? && pf2['verdict_by'] == 'builder-self-attested',
        'verdict-less verification-result.json is not evidence either', fails)
  File.write(File.join(dir, 'verification-result.json'),
             JSON.generate('verdict' => 'GREEN', 'notes' => 'VERIFIER: tile-by-tile'))
  _out3, _err3, st3 = run_gate_audited(dir)
  pf3 = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(st3.success? && pf3['verdict'] == 'GREEN' && pf3['verdict_by'] == 'verifier',
        'a valid verifier deliverable still countersigns (bare GREEN + verifier)', fails)
end

# D10 fix-pass: the TWO-field launder (verdict → bare GREEN AND verdict_by →
# 'verifier', no countersignature evidence on disk) is exit 6 — verdict_by is
# re-derived from evidence, never trusted from the markers.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate(TIER_S_STATE))
  run_gate_audited(dir) # stamps the labeled factory verdict
  %w[parity-final.json phase6-success.json].each do |f|
    j = JSON.parse(File.read(File.join(dir, f)))
    j['verdict'] = 'GREEN'
    j['verdict_by'] = 'verifier'
    File.write(File.join(dir, f), JSON.pretty_generate(j))
  end
  _vout, verr, vst = run_verify(dir)
  check(vst.exitstatus == 6, "two-field attestation launder → verify-complete exit 6 (got #{vst.exitstatus})", fails)
  check(verr.include?('no') && verr.include?('countersignature evidence') && verr.include?('laundering'),
        'contradiction names the missing countersignature evidence', fails)
end

# D8 vocabulary pin: the gate's literals (it cannot require offramp — the domo
# twin has no offramp vendoring) match the shared constants verbatim.
require_relative 'lib/offramp'
gate_src = File.read(SCRIPT, encoding: 'UTF-8')
check(gate_src.include?("'GREEN (factory, self-attested)'") &&
      "GREEN#{Offramp::FACTORY_VERDICT_SUFFIX}" == FACTORY_LABEL,
      'gate label literal == Offramp::FACTORY_VERDICT_SUFFIX (single vocabulary point)', fails)
check(gate_src.include?("'builder-self-attested'") && gate_src.include?("'verifier'") &&
      Offramp::VERDICT_BY == %w[builder-self-attested verifier],
      'gate verdict_by literals == Offramp::VERDICT_BY', fails)
check(gate_src.include?("%w[S M full]") && Offramp::TIER_VALUES == %w[S M full],
      'gate tier literals == Offramp::TIER_VALUES', fails)

puts
if fails.empty?
  puts 'test-wave2-verdict-gates: ALL PASS'
else
  puts "test-wave2-verdict-gates: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
