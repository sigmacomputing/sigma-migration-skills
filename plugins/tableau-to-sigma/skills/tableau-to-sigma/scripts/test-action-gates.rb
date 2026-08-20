#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression test for scripts/assert-action-gates.rb — the Tableau-only hard
# gate for the workbook actions layer (moved out of the SHARED
# assert-phase6-ran.rb on 2026-08-07; see that script's own header for why).
# Locks THREE independent checks:
#
#   G1 (never waivable): every actions[] entry in --spec is schema-valid
#     (ActionLedger.validate_action) and every action id is unique across the
#     WHOLE workbook. Three planted defects MUST turn it red: a missing `id`
#     (the real shipping bug), a workbook-duplicate id (a real live 400), and
#     an open-url effect with no url (schema-valid upstream, silent no-op).
#
#   Ledger/spec mismatch check (final-review Important-1 fix): when --spec is
#     given, action_count(spec) must equal ledger['emitted'].size. Planted
#     defect: a built spec that demonstrably contains 1 real action, paired
#     with a ledger claiming emitted: [] (exactly what build-postpublish-
#     guide.rb produces when run without --emitted-manifest), MUST turn the
#     WHOLE gate red — even though G1 (correctly) validates the spec's action
#     on its own terms and the guide-residue check (below) has nothing of
#     its own to complain about. Before the fix, both checks printed [OK] in
#     the SAME run: a spec-vs-ledger contradiction, gate green.
#
#   Guide-residue check (waivable ONLY via --skip-postpublish-guide, which has
#     ZERO effect on G1 or the mismatch check above): <workdir>/action-
#     ledger.json must exist with its conservation invariant holding,
#     <workdir>/POSTPUBLISH_GUIDE.md must exist, and the guide must not render
#     any of the ledger's `emitted` entries as still-open work. Matched
#     STRUCTURALLY (by the invisible `<!-- ledger-key: [...] -->` marker
#     build-postpublish-guide.rb's render_guide stamps per rendered entry —
#     the SAME ActionLedger.key_of identity ActionLedger.join uses), never by
#     scanning the guide's visible prose for a caption substring. Two planted
#     defects: (1) a guide that genuinely re-renders the SAME action identity
#     the ledger says was already emitted MUST turn it red (final-review
#     Important-2's "must not go blind to a real leak" requirement); (2) an
#     UNRELATED residue entry's prose that happens to name the same dashboard
#     an auto-emitted, uncaptioned nav-button falls back to as its caption
#     (build-charts-from-signals.rb's `label = caption || tooltip ||
#     nav_target`, and build-postpublish-guide.rb's "any sheet on dashboard
#     '<name>'" source prose) must NOT turn it red — the exact false-FAIL the
#     old bare `guide_text.include?(cap)` substring scan produced.
#
# Usage: ruby scripts/test-action-gates.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'assert-action-gates.rb')
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_ledger'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

VALID_SPEC = { 'pages' => [{ 'id' => 'p1', 'elements' => [
  { 'id' => 'btn-1', 'kind' => 'button', 'actions' => [
    { 'id' => 'act-btn-1-1', 'trigger' => 'on-click',
      'effects' => [{ 'effect' => 'navigate',
                      'target' => { 'type' => 'page', 'page' => 'p2' } }] }] }] }] }.freeze

EMPTY_LEDGER = { 'schemaVersion' => 1, 'detectedCount' => 0, 'emitted' => [], 'residue' => [] }.freeze
EMPTY_GUIDE  = "# Post-publish interactivity guide\n\nNo interactive actions detected.\n"

# A workdir that satisfies the guide-residue check by default (zero detected
# actions, conservation holds, nothing to leak) — individual tests below
# overwrite these two files to exercise real behavior.
def base_workdir(dir)
  File.write(File.join(dir, 'action-ledger.json'), JSON.pretty_generate(EMPTY_LEDGER))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'), EMPTY_GUIDE)
end

def run_gate(dir, *args)
  Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
end

def write_spec(dir, spec, name: 'wb-spec.json')
  path = File.join(dir, name)
  File.write(path, JSON.generate(spec))
  path
end

# The SAME invisible marker build-postpublish-guide.rb's render_guide stamps
# on every rendered residue entry (scripts/build-postpublish-guide.rb's own
# `ledger_marker`) — derived from the SAME ActionLedger.key_of the production
# gate (scripts/lib/action_gates.rb#guide_residue_violations) parses back out.
# Deliberately NOT a hand-typed/duplicated string format: both sides call the
# one real identity function, so this test exercises the actual structural
# match, not a re-implementation of it that could silently drift.
def ledger_marker(entry)
  key = ActionLedger.key_of(entry)
  return '' if key.nil?
  "<!-- ledger-key: #{JSON.generate(key)} -->\n"
end

# ==============================================================================
# G1 — action schema validation
# ==============================================================================
puts 'G1 — action schema'

# ---- no --spec given → stated SKIP, never silent, exit 0 --------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success?, 'no --spec → exit 0 (nothing to validate)', fails)
  check(out.include?('SKIP') && out.include?('G1'), 'no --spec is a stated SKIP, not silent', fails)
end

# ---- --spec path that does not exist → hard FAIL, not a skip ----------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  _out, err, st = run_gate(dir, '--spec', File.join(dir, 'nope.json'))
  check(!st.success?, 'a --spec path that does not exist is a hard FAIL, not a skip', fails)
  check(err.include?('not found'), 'failure names the missing --spec path', fails)
end

# ---- valid spec → PASS -------------------------------------------------------
# --skip-postpublish-guide isolates G1 from the ledger/spec mismatch check
# below (base_workdir's fixture ledger claims 0 emitted; this test is about
# G1's OWN pass/fail on a schema-valid action, not the cross-check — that
# gets its own dedicated section further down).
Dir.mktmpdir do |dir|
  base_workdir(dir)
  spec = write_spec(dir, VALID_SPEC)
  out, _err, st = run_gate(dir, '--spec', spec, '--skip-postpublish-guide', 'G1-only test')
  check(st.success?, 'G1 PASSES on a valid action', fails)
  check(out.include?('[OK] G1') && out.include?('1 action'), 'G1 OK line names the validated count', fails)
end

# ---- PLANTED DEFECT 1 — the shipping bug: no id ------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  no_id = Marshal.load(Marshal.dump(VALID_SPEC))
  no_id['pages'][0]['elements'][0]['actions'][0].delete('id')
  spec = write_spec(dir, no_id)
  _out, err, st = run_gate(dir, '--spec', spec)
  check(!st.success?, 'G1 FAILS on a missing action id (the shipping bug)', fails)
  check(err.include?('missing required key `id`'), 'failure names the missing id', fails)
  check(err.include?('NOT waivable'), 'failure states G1 is not waivable', fails)
end

# ---- PLANTED DEFECT 2 — duplicate id across two elements (a real live 400) --
Dir.mktmpdir do |dir|
  base_workdir(dir)
  dup = Marshal.load(Marshal.dump(VALID_SPEC))
  second = Marshal.load(Marshal.dump(dup['pages'][0]['elements'][0]))
  second['id'] = 'btn-2'
  dup['pages'][0]['elements'] << second
  spec = write_spec(dir, dup)
  _out, err, st = run_gate(dir, '--spec', spec)
  check(!st.success?, 'G1 FAILS on a workbook-duplicate action id', fails)
  check(err.include?('duplicate action id') && err.include?('act-btn-1-1'),
        'failure names the duplicate id', fails)
end

# ---- PLANTED DEFECT 3 — open-url with no url (schema-valid, silent no-op) ---
Dir.mktmpdir do |dir|
  base_workdir(dir)
  nourl = Marshal.load(Marshal.dump(VALID_SPEC))
  nourl['pages'][0]['elements'][0]['actions'][0]['effects'] =
    [{ 'effect' => 'open-url', 'openTarget' => '_blank' }]
  spec = write_spec(dir, nourl)
  _out, err, st = run_gate(dir, '--spec', spec)
  check(!st.success?, 'G1 FAILS on open-url with no url', fails)
  check(err.include?('open-url') && err.include?('url'), 'failure names the missing url', fails)
end

# ==============================================================================
# Guide-residue check
# ==============================================================================
puts 'guide-residue check'

# ---- no action-ledger.json → FAIL --------------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'action-ledger.json'))
  _out, err, st = run_gate(dir)
  check(!st.success?, 'no action-ledger.json → FAIL', fails)
  check(err.include?('action-ledger.json') && err.include?('missing'),
        'failure names the missing ledger file', fails)
  check(err.include?('build-postpublish-guide.rb') && err.include?('--json-out'),
        'failure points at the generator script and the --json-out flag', fails)
end

# ---- ledger conservation broken → FAIL ---------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 3, 'emitted' => [], 'residue' => []))
  _out, err, st = run_gate(dir)
  check(!st.success?, 'ledger conservation broken → FAIL', fails)
  check(err.include?('conservation broken') && err.include?('detected=3') && err.include?('emitted=0') && err.include?('residue=0'),
        'failure names the conservation break with the actual counts', fails)
end

# ---- ledger valid, guide missing → FAIL --------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'POSTPUBLISH_GUIDE.md'))
  _out, err, st = run_gate(dir)
  check(!st.success?, 'ledger present, guide missing → FAIL', fails)
  check(err.include?('POSTPUBLISH_GUIDE.md') && err.include?('missing'),
        'failure names the missing guide', fails)
end

EMITTED_NAV_BUTTON = { 'actionId' => 'act-btn-1-1', 'hostElementId' => 'btn-1', 'trigger' => 'on-click',
                       'effects' => [{ 'effect' => 'navigate', 'target' => { 'type' => 'page', 'page' => 'p2' } }],
                       'targetPageName' => 'Page 2',
                       'source' => { 'kind' => 'nav-button', 'caption' => 'Go to Details',
                                     'sourceSheet' => nil, 'actionName' => 'Dashboard::zone-3' } }.freeze

# ---- PLANTED DEFECT 4 — guide re-renders an emitted action's OWN identity ---
# The exact regression this gate exists to catch: previously (as gate 11
# inside the shared script) a guide instructing the customer to hand-wire
# something the converter had ALREADY built passed green, because the old
# check only verified file-existence, never content. The guide text below
# carries the REAL `ledger_marker` (same ActionLedger.key_of identity
# build-postpublish-guide.rb's render_guide stamps) for the SAME
# actionName the ledger's `emitted` entry carries — simulating a stale/
# hand-edited guide, or a future ActionLedger.join regression, that renders
# residue prose for an action that is not actually residue. Matching
# STRUCTURALLY (by this marker) rather than by caption substring must still
# catch this — final-review Important-2 requires the fix not go blind to a
# genuine leak.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 1,
                                   'emitted' => [EMITTED_NAV_BUTTON], 'residue' => []))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'),
             "# Post-publish wiring\n\n### Go to Details\n\n" +
             ledger_marker(EMITTED_NAV_BUTTON['source']) +
             "Add a button 'Go to Details' navigating to page 2.\n")
  _out, err, st = run_gate(dir)
  check(!st.success?, 'guide re-renders the SAME emitted action identity → FAIL', fails)
  check(err.include?('Go to Details') && err.include?('already emitted'),
        'failure names the leaked caption and states it was already auto-wired', fails)
end

# ---- guide correctly omits emitted captions → PASS ---------------------------
# The residue entry's marker carries its OWN identity (['highlight-action',
# 'Region Highlight']) — distinct from the emitted nav-button's
# (['nav-button', 'Dashboard::zone-3']) — so the structural match correctly
# finds no overlap.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  residue_entry = { 'kind' => 'highlight-action', 'caption' => 'Region Highlight' }
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 2,
                                   'emitted' => [EMITTED_NAV_BUTTON], 'residue' => [residue_entry]))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'),
             "# Post-publish wiring\n\n### Region Highlight\n\n" +
             ledger_marker(residue_entry) +
             "No Sigma equivalent; closest pattern: ...\n")
  out, _err, st = run_gate(dir)
  check(st.success?, 'guide matches residue, omits the emitted caption → PASS', fails)
  check(out.include?('guide matches ledger residue') && out.include?('1 auto-emitted') && out.include?('1 manual'),
        'OK line names the auto-emitted/manual split', fails)
end

# ---- PLANTED DEFECT 5 — marker-less guide leaks an emitted caption → FAIL ---
# Live reviewer repro: a guide that carries NO `<!-- ledger-key -->` markers
# AT ALL — a stale pre-fix file, a hand-edited guide, or output from any path
# that isn't the current render_guide — while `emitted` is non-empty and the
# guide's prose plainly instructs hand-wiring the SAME button the ledger says
# was already emitted. Structural matching (rendered_keys.include?(key)) is
# silently vacuous when rendered_keys is empty: every emitted entry fails to
# match (there is nothing to match against), so the per-entry loop alone
# reports zero violations — a false OK. The marker-ABSENCE check must catch
# this on its own, independent of the per-entry loop.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 1,
                                   'emitted' => [EMITTED_NAV_BUTTON], 'residue' => []))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'),
             "# Post-publish wiring\n\n### Go to Details\n\n" \
             "Add a button 'Go to Details' navigating to page 2.\n") # zero ledger-key markers anywhere
  _out, err, st = run_gate(dir)
  check(!st.success?, 'marker-less guide leaking an emitted caption → FAIL (fail closed, not a silent OK)', fails)
  check(err.include?('zero') && err.include?('ledger-key') && err.include?('render_guide') &&
        err.include?('build-postpublish-guide.rb'),
        'failure names the marker absence and points at build-postpublish-guide.rb to regenerate', fails)
end

# ---- marker-less guide, nothing emitted → still PASS (over-failing guard) ---
# The legitimate zero case: a marker-less guide is FINE when `emitted` is
# empty — nothing was auto-wired, so open-work prose with no markers cannot
# possibly be mis-describing already-done work as still open. The marker-
# absence check above must NOT fire here, or every guide on a fully-manual
# run (nothing auto-wired) would false-FAIL.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  home_residue = { 'kind' => 'nav-button', 'caption' => 'Home' }
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 1,
                                   'emitted' => [], 'residue' => [home_residue]))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'),
             "# Post-publish wiring\n\n### Home\n\n" \
             "Add a button 'Home' navigating to the home page (no Sigma equivalent wiring today).\n") # no marker
  out, _err, st = run_gate(dir)
  check(st.success?, 'marker-less guide with emitted: [] → still PASS (nothing to leak)', fails)
  check(out.include?('guide matches ledger residue') && out.include?('0 auto-emitted') && out.include?('1 manual'),
        'OK line still names the 0 auto-emitted / 1 manual split', fails)
end

# ==============================================================================
# Ledger/spec mismatch — final-review Important-1
# ==============================================================================
puts 'ledger/spec mismatch (reviewer-demonstrated contradiction)'

# Exact reviewer reproduction: a built spec containing ONE real, valid
# navigate action on btn-10; a ledger claiming NOTHING was emitted
# (emitted: []) alongside one genuine manual-residue entry ('Home'); a guide
# correctly instructing hand-wiring for that residue entry. Before this fix:
# G1 validates the spec's action fine (nothing wrong with IT in isolation),
# and guide_residue_violations had nothing of ITS own to complain about
# (it only ever inspected `ledger['emitted']`, which is empty) — so
# "[OK] G1: 1 action(s) validated" and "[OK] ... (0 auto-emitted, 1 manual)"
# printed in the SAME run, exit 0, even though the spec demonstrably
# contains an emitted action the ledger lies about. Reachable in practice
# whenever build-postpublish-guide.rb runs without --emitted-manifest
# (ActionLedger.read_manifest(nil) == []) — exactly the shape migrate-
# tableau.rb's PRINTED (not executed) advisory invocation yields if run
# as printed rather than with --emitted-manifest wired in.
Dir.mktmpdir do |dir|
  spec_one_action = { 'pages' => [{ 'id' => 'p1', 'elements' => [
    { 'id' => 'btn-10', 'kind' => 'button', 'actions' => [
      { 'id' => 'act-btn-10-1', 'trigger' => 'on-click',
        'effects' => [{ 'effect' => 'navigate',
                        'target' => { 'type' => 'page', 'page' => 'p2' } }] }] }] }] }
  spec = write_spec(dir, spec_one_action)
  home_residue = { 'kind' => 'nav-button', 'caption' => 'Home' }
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 1,
                                   'emitted' => [], 'residue' => [home_residue]))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'),
             "# Post-publish wiring\n\n### Home\n\n" +
             ledger_marker(home_residue) +
             "Add a button 'Home' navigating to the home page (no Sigma equivalent wiring today).\n")
  out, err, st = run_gate(dir, '--spec', spec)
  check(out.include?('[OK] G1') && out.include?('1 action'),
        "G1 (correctly) validates the spec's action on its own terms", fails)
  check(!st.success?,
        'the OVERALL gate FAILS — spec has 1 action but the ledger claims 0 emitted', fails)
  check(err.include?('ledger/spec mismatch') && err.include?('1 action') && err.include?('0 emitted'),
        'failure names BOTH numbers so the operator sees the exact contradiction', fails)
end

# ==============================================================================
# Caption-substring false-FAIL — final-review Important-2
# ==============================================================================
puts 'caption collision does not false-FAIL (structural match, not substring)'

# Exact reviewer reproduction: an UNCAPTIONED nav button whose displayed
# caption falls back to its target DASHBOARD NAME (build-charts-from-
# signals.rb:6736-6738: `label = button_caption || tooltip || nav_target`),
# auto-emitted with caption 'Sales Detail'; a genuinely DIFFERENT residue
# entry (an unrelated filter action) whose Tableau source happens to be "any
# sheet on dashboard 'Sales Detail'" (build-postpublish-guide.rb's
# parse_source — a correct, honest rendering of THAT action, unrelated to
# the emitted button). Before this fix, `guide_text.include?("Sales
# Detail")` matched the dashboard name wherever it appeared, including in
# this unrelated prose, and FAILED a run that was actually fine — the
# operator's only recovery was a spurious --skip-postpublish-guide waiver.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  emitted_nav = { 'actionId' => 'act-btn-9-1',
                  'source' => { 'kind' => 'nav-button', 'caption' => 'Sales Detail',
                                'actionName' => 'Overview::zone-9' } }
  filter_residue = { 'kind' => 'filter-action', 'caption' => 'Filter clicks',
                     'source' => { 'dashboard' => 'Sales Detail',
                                   'description' => "any sheet on dashboard 'Sales Detail'" } }
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 2,
                                   'emitted' => [emitted_nav], 'residue' => [filter_residue]))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'),
             "# Post-publish wiring\n\n### Filter clicks\n\n" +
             ledger_marker(filter_residue) +
             "- **Tableau:** any sheet on dashboard 'Sales Detail' — trigger: on select\n" \
             "- **Steps:** Open the workbook in edit mode → select the source chart...\n")
  out, err, st = run_gate(dir)
  check(st.success?,
        "an unrelated residue entry's prose naming the SAME dashboard an emitted button falls back to " \
        "as its caption does NOT false-FAIL (got exit #{st.exitstatus}, err: #{err})", fails)
end

# ---- --skip-postpublish-guide waives the guide check → PASS -----------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'action-ledger.json')) # would FAIL outright without the waiver
  spec = write_spec(dir, VALID_SPEC)
  out, _err, st = run_gate(dir, '--spec', spec, '--skip-postpublish-guide', 'customer declined the handoff doc')
  check(st.success?, "missing ledger + --skip-postpublish-guide → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('WAIVED'), 'guide-check waiver is stated loudly', fails)
  check(out.include?('[OK] G1'), 'G1 still ran and passed alongside the waived guide check', fails)
  offramps = File.readlines(File.join(dir, 'offramps.jsonl')).map { |l| JSON.parse(l) } rescue []
  check(offramps.any? { |o| o['reason'] == 'customer declined the handoff doc' },
        'the waiver lands in offramps.jsonl with its reason', fails)
end

# ==============================================================================
# Waiver independence — --skip-postpublish-guide must NOT waive G1
# ==============================================================================
puts '--skip-postpublish-guide independence'

Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'action-ledger.json')) # would ALSO fail the guide check, if G1 didn't fail first
  no_id = Marshal.load(Marshal.dump(VALID_SPEC))
  no_id['pages'][0]['elements'][0]['actions'][0].delete('id')
  spec = write_spec(dir, no_id)
  _out, err, st = run_gate(dir, '--spec', spec, '--skip-postpublish-guide', 'no handoff doc needed')
  check(!st.success?, "--skip-postpublish-guide does NOT waive G1 (got #{st.exitstatus})", fails)
  check(err.include?('[FAIL] G1') && err.include?('missing required key `id`'),
        'the failure is G1 itself, unmasked by the guide-check waiver', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — assert-action-gates.rb: G1 action-schema validation (3 planted defects) + ' \
       'the guide-residue check (ledger existence/conservation, guide existence, no leaked ' \
       'emitted caption — 1 planted defect) + --skip-postpublish-guide waives the guide check ' \
       'only, never G1'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
