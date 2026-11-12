#!/usr/bin/env ruby
# Offline contract tests for the FILE-DRIVEN gates of assert-phase6-ran.rb — the
# shared (synced-from-canonical) Phase-6 GREEN gate — exercised END-TO-END
# through the actual script (not by calling libs directly; scripts/lib/{control_lint,
# layout_lint}.rb already have their own direct-lib contract tests in
# test-green-gates.rb).
#
# Scope, from reading the CURRENT script (2026-07, ~31 gates; header comments
# lag the code and are NOT trusted):
#   - Gates 3 (live /columns) and 4 (live workbook layout) hit the network and
#     FAIL CLOSED (exit 5 / exit 6) when SIGMA_BASE_URL/SIGMA_API_TOKEN are
#     unset and a workbook id resolves — they do not silently pass. This
#     fail-closed behavior itself is file+env driven and IS tested below;
#     their escape hatches are --skip-column-check / --skip-layout-check.
#   - Gates 6 (layout lint) and 7 (control lint) ALSO fetch the live spec, but
#     — unlike 3/4 — do NOT fail closed without creds: they print a [SKIP]
#     WARN and continue. Already covered (against the libs directly) by
#     test-green-gates.rb; this harness only relies on their offline no-op.
#   - Gate 14 (visual-similarity) needs scripts/visual-similarity.py plus a
#     real python3 + image pair; no scenario below ever supplies BOTH a
#     source dashboard PNG AND reaches this gate without exiting earlier
#     (the one scenario with a source PNG, gate 13, always exits first), so
#     gate 14 stays an inert [SKIP] N/A here whether or not the delegate
#     script is vendored — left untested (see bottom-of-file NOTE) rather
#     than faked.
#   - Gate 7b (runtime control flip) and gate 4b (layout-phase sentinel) are
#     opt-in / tool-gated respectively; both have genuine offline-triggerable
#     paths (a file-driven enforced-fallback for 7b, a tool-registry check for
#     4b) and are exercised below, with the tool-gating boundary documented at
#     the call site.
#   - lib/degradation_ledger.rb and lib/flip_gate.rb are not vendored in this
#     plugin (grep confirms), so DEG_LEDGER_LOADED is false and the final
#     verdict line is always the legacy "no PR-14 verdict derived" print —
#     exit code is unaffected either way.
#
# Isolation: SIGMA_BASE_URL / SIGMA_API_TOKEN are forced empty in the gate's
# subprocess env on every invocation (belt-and-braces against a dev shell that
# happens to have live Sigma creds exported — this suite must never reach the
# network even by accident). With no base URL the shared client asks its token
# provider for one (a signed-in Sigma CLI profile would answer), so the
# provider is pinned to one that always reports "no credentials" as well.
#
#   ruby test/test-assert-phase6.rb
require 'digest'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'

GATE = File.expand_path('../scripts/assert-phase6-ran.rb', __dir__)
# Self-identifies the adopting converter from this file's own path (e.g. a
# synced copy living under plugins/<tool>/skills/<tool>/test/ resolves to
# <tool>); falls back to a neutral label when run from the shared canonical
# location (shared/scripts/), which is not itself a `*-to-sigma` plugin dir.
TOOL = (__dir__[%r{(\w+-to-sigma)}, 1] || 'assert-phase6')
OFFLINE_PROVIDER_DIR = Dir.mktmpdir('p6-offline-provider')
at_exit { FileUtils.rm_rf(OFFLINE_PROVIDER_DIR) }
OFFLINE_PROVIDER = File.join(OFFLINE_PROVIDER_DIR, 'provider.py')
File.write(OFFLINE_PROVIDER, "raise SystemExit('offline test: no Sigma credentials')\n")
OFFLINE_ENV = { 'SIGMA_BASE_URL' => '', 'SIGMA_API_TOKEN' => '',
                'SIGMA_TOKEN_PROVIDER' => OFFLINE_PROVIDER }.freeze
$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

# Run the gate as a subprocess against `dir`, with SIGMA creds forced empty
# (offline, and immune to whatever the invoking shell happens to export).
def run_gate(dir, *extra_args)
  cmd = ['ruby', GATE, '--workdir', dir] + extra_args
  env = OFFLINE_ENV
  system(env, *cmd, out: File::NULL, err: File::NULL)
  $?.exitstatus
end

def write_json(dir, name, obj)
  File.write(File.join(dir, name), JSON.generate(obj))
end

# Like run_gate, but also captures stdout AND stderr — needed where a
# scenario must assert on the exact PRINTED success/failure message, not just
# the exit code (a crash before the print, or the wrong branch's message,
# could still coincidentally produce the same exit code without this). Every
# `warn` call in the gate (all of its diagnostic/remediation text, including
# FAIL-branch hints) goes to stderr, not stdout — callers that only need
# stdout can still destructure just `code, out = run_gate_capture(...)` and
# the captured stderr string is simply dropped.
def run_gate_capture(dir, *extra_args)
  cmd = ['ruby', GATE, '--workdir', dir] + extra_args
  env = OFFLINE_ENV
  out, err, status = Open3.capture3(env, *cmd)
  [status.exitstatus, out, err]
end

# A workdir with valid, minimal fixtures for every FILE-DRIVEN gate this
# script checks, plus a resolvable workbook id (wb-ids.json) for the two
# live-endpoint gates' fail-closed check. Every gate NOT mentioned here is
# left absent-on-disk on purpose — each one's own code treats "file absent" as
# a stated SKIP/OK (back-compat / N-A), which is itself part of what the happy
# path proves.
def write_good_fixtures(dir)
  # Gate 1 (parity) + gate 5 (tile census, folded into the same file).
  write_json(dir, 'parity-final.json',
              'charts_total' => 3, 'charts_pass' => 3, 'status' => 'PASS', 'mode' => 'live',
              'tile_census' => { 'zones_total' => 3, 'charts_built' => 3,
                                  'zones_unmatched' => 0, 'unmatched_zone_names' => [] })
  # Gate 2 (orphan workbooks) — exactly one workbook POSTed, nothing to clean.
  File.write(File.join(dir, 'posted-workbooks.jsonl'), JSON.generate('id' => 'wb-happy-1') + "\n")
  # Resolvable workbook id for gates 3/4/6/7/7b's wb-ids.json fallback.
  write_json(dir, 'wb-ids.json', 'workbookId' => 'wb-happy-1')
  # Gate 8c (layout fill) — every zone placed, grid comfortably filled.
  write_json(dir, 'layout-census.json',
              'pages' => [{ 'page' => 'Overview', 'zones' => 3, 'placed' => 3,
                            'grid_fill_pct' => 0.9, 'unplaced_elements' => [] }])
  # Gate 8 (visual render) — real PNG magic bytes, comfortably over the 5,000
  # byte floor (valid_png only checks magic + size, never decodes the image).
  File.open(File.join(dir, 'sigma-render.png'), 'wb') do |f|
    f.write("\x89PNG\r\n\x1a\n".b)
    f.write("\x00".b * 6_000)
  end
end

# Every offline scenario needs gates 3 (--skip-column-check) and 4
# (--skip-layout-check) waived — no live Sigma creds exist in this harness —
# and gate 8b (visual comparison) waived under the sanctioned
# builder->verifier split, whose reason matches /verifier/i and is therefore a
# POLICY exclusion from the 2-waiver budget (exit 19), leaving the two
# genuinely-live-endpoint skips as the only budget-counted waivers (exactly at
# the cap of 2, never over it).
HAPPY_FLAGS = [
  '--skip-column-check', 'offline harness: no live Sigma creds (gate 3 needs GET /v2/workbooks/{id}/columns)',
  '--skip-layout-check', 'offline harness: no live Sigma creds (gate 4 needs GET /v2/workbooks/{id}?includeContents=true)',
  '--skip-visual-comparison', 'verifier: render pre-verified by a prior session (policy-excluded from the waiver budget)'
].freeze

# Conditions (a)+(c)+(d) of the anchors-oracle substitution (charts_total<=0
# branch) satisfied — every scenario below is only exercising condition (b)
# (the visual-verify-tile confirmation), so the other three are held constant
# and passing here.
PASSING_ANCHORS_ORACLE = {
  'pass' => true, 'checked' => 5, 'matched' => 5, 'anchors_matched_in_displayed' => 5,
  'tiles_all_nonempty' => true,
  'anchor_coverage' => { 'covered' => 3, 'displayed' => 3, 'uncovered' => [] }
}.freeze

# Build a fresh good workdir, let the block corrupt/add exactly one thing,
# run the gate with `flags`, and assert the EXACT exit code.
def scenario(name, expect_exit, flags = HAPPY_FLAGS)
  Dir.mktmpdir('domo-p6') do |dir|
    write_good_fixtures(dir)
    yield dir if block_given?
    got = run_gate(dir, *flags)
    eq(got, expect_exit, name)
  end
end

puts '== happy path: every file-driven gate satisfied, both live-endpoint gates waived =='
scenario('all fixtures valid, live gates skipped -> exit 0', 0)

puts '== pre-POST render-integrity gate (local-spec conditional, exit 32) =='
scenario('local wb-spec.json has a blank chart -> exit 32', 32) do |dir|
  write_json(dir, 'wb-spec.json',
             'pages' => [{ 'id' => 'overview',
                           'elements' => [{ 'id' => 'blank-chart', 'name' => 'Blank Chart',
                                           'kind' => 'bar-chart' }] }])
end
Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  write_json(dir, 'wb-spec.json',
             'elements' => [{ 'id' => 'healthy-table', 'kind' => 'table',
                              'source' => { 'elementId' => 'source-table' } }])
  write_json(dir, 'workbook-spec.json',
             'elements' => [{ 'id' => 'lower-priority-blank', 'kind' => 'chart' }])
  code = run_gate(dir, *HAPPY_FLAGS)
  evidence = JSON.parse(File.read(File.join(dir, 'blank-risk-elements.json')))
  eq(code, 0, 'wb-spec.json takes priority over workbook-spec.json')
  eq(File.basename(evidence['spec']), 'wb-spec.json', 'evidence records the selected spec candidate')
end

puts '== gate 1 (Phase 6 parity) =='
scenario('no parity-final.json at all -> exit 1 (Phase 6 never ran)', 1) { |dir| File.delete(File.join(dir, 'parity-final.json')) }
scenario('parity-final.json is malformed JSON -> exit 3', 3) { |dir| File.write(File.join(dir, 'parity-final.json'), '{not valid json') }
scenario('parity-final.json status=FAIL -> exit 2', 2) do |dir|
  write_json(dir, 'parity-final.json', 'charts_total' => 3, 'charts_pass' => 2, 'status' => 'FAIL', 'mode' => 'live')
end

puts '== gate 2 (orphan workbooks, [bead]) =='
scenario('2 workbooks POSTed, no cleanup-marker.json -> exit 4', 4) do |dir|
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             [{ 'id' => 'wb-1' }, { 'id' => 'wb-2' }].map { |h| JSON.generate(h) }.join("\n") + "\n")
end
scenario('malformed workbook ledger entry -> exit 4', 4) do |dir|
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             JSON.generate('id' => 'wb-happy-1') + "\nnot-json\n")
end
scenario('complete user-confirmed cleanup marker -> exit 0', 0) do |dir|
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             [{ 'id' => 'wb-old' }, { 'id' => 'wb-happy-1' }].map { |h| JSON.generate(h) }.join("\n") + "\n")
  write_json(dir, 'cleanup-marker.json',
             'kept' => 'wb-happy-1', 'deleted' => [{ 'id' => 'wb-old', 'status' => 200 }],
             'failed' => [], 'skipped' => [], 'dry_run' => false)
end
scenario('cleanup marker with a user-declined candidate -> exit 4', 4) do |dir|
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             [{ 'id' => 'wb-old' }, { 'id' => 'wb-happy-1' }].map { |h| JSON.generate(h) }.join("\n") + "\n")
  write_json(dir, 'cleanup-marker.json',
             'kept' => 'wb-happy-1', 'deleted' => [],
             'failed' => [], 'skipped' => [{ 'id' => 'wb-old' }], 'dry_run' => false)
end
scenario('stale cleanup marker missing a ledger deletion -> exit 4', 4) do |dir|
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             [{ 'id' => 'wb-old-1' }, { 'id' => 'wb-old-2' }, { 'id' => 'wb-happy-1' }].
               map { |h| JSON.generate(h) }.join("\n") + "\n")
  write_json(dir, 'cleanup-marker.json',
             'kept' => 'wb-happy-1', 'deleted' => [{ 'id' => 'wb-old-1', 'status' => 200 }],
             'failed' => [], 'skipped' => [], 'dry_run' => false)
end
scenario('cleanup marker kept id disagrees with wb-ids.json -> exit 4', 4) do |dir|
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             [{ 'id' => 'wb-old' }, { 'id' => 'wb-happy-1' }].map { |h| JSON.generate(h) }.join("\n") + "\n")
  write_json(dir, 'cleanup-marker.json',
             'kept' => 'wb-old', 'deleted' => [{ 'id' => 'wb-happy-1', 'status' => 200 }],
             'failed' => [], 'skipped' => [], 'dry_run' => false)
end

puts '== gate 3 (live /columns, fail-closed without creds) =='
# No --skip-column-check passed: wb-ids.json resolves a workbook id and
# SIGMA_BASE_URL/TOKEN are forced empty by run_gate, so the gate must FAIL
# CLOSED rather than silently pass — proves a credential-less run cannot ship.
scenario('workbook id resolvable, no creds, no waiver -> exit 5', 5, [])

puts '== gate 4 (live workbook layout, fail-closed without creds) =='
scenario('gate 3 waived, gate 4 not waived, no creds -> exit 6', 6,
         ['--skip-column-check', 'reach gate 4'])

puts '== gate 5 (tile census, bead gjhe) =='
scenario('2 dashboard zones unmatched, no visual-verify oracle -> exit 7', 7,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r']) do |dir|
  write_json(dir, 'parity-final.json',
             'charts_total' => 3, 'charts_pass' => 3, 'status' => 'PASS', 'mode' => 'live',
             'tile_census' => { 'zones_total' => 5, 'charts_built' => 3, 'zones_unmatched' => 2,
                                 'unmatched_zone_names' => %w[TileX TileY] })
end

puts '== gate 7c (source-vs-built controls census, PLAN-v3 PR-13) =='
scenario('census signal never built/declared/waived -> exit 31', 31,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r']) do |dir|
  write_json(dir, 'domo-controls-coverage.json',
             'detail' => [{ 'kind' => 'filter', 'name' => 'Region', 'status' => 'declared_not_built' }])
end

puts '== gate 7b (runtime control flip; DEFAULT-ON via migrate-state control_flip_required) =='
# opt-in path: migrate-state.json auto-enables enforcement (the same mechanism
# tableau-to-sigma pass 1 stamps); no live creds and no recorded evidence
# (no probe-results.json / control-flip-unverified.json / empty controls
# census) means the ENFORCED gate must fail closed, entirely file/env-driven.
# BOUNDARY: an adopting converter's workdir never carries migrate-state.json
# in real usage (that's tableau-to-sigma's stamp) — this proves the SHARED
# script's fallback mechanics, not a tool-specific code path.
scenario('flip enforced, no creds, no recorded evidence -> exit 21', 21,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r']) do |dir|
  write_json(dir, 'migrate-state.json', 'control_flip_required' => true)
end

puts '== gate 8 (Phase 6f visual render present) =='
scenario('no sigma-render.png and no fallback render found -> exit 10', 10,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r']) do |dir|
  File.delete(File.join(dir, 'sigma-render.png'))
end

puts '== gate 8b (source-vs-target visual comparison recorded) =='
scenario('valid render present but no visual verdict recorded, not waived -> exit 13', 13,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r'])

puts '== gate 8c (layout fill / grid coverage, #259 item 1) =='
scenario('a page dropped a tile (placed < zones) -> exit 14', 14,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r', '--skip-visual-comparison', 'verifier: r']) do |dir|
  write_json(dir, 'layout-census.json',
             'pages' => [{ 'page' => 'Overview', 'zones' => 3, 'placed' => 1,
                           'grid_fill_pct' => 0.9, 'unplaced_elements' => [] }])
end

puts '== gate 8d (RCF fidelity ledger — data-class residuals always block) =='
scenario('unresolved data-class RCF delta -> exit 15', 15) do |dir|
  write_json(dir, 'fidelity-ledger.json',
             'pass' => 1, 'entries' => [{ 'id' => 'd1', 'cls' => 'data', 'dimension' => 'value',
                                           'delta' => 'KPI off by 10%', 'resolved' => false }])
end

puts '== gate 8e (layout-arrangement parity, opt-in via --require-arrangement) =='
scenario('--require-arrangement set, report carries a violation -> exit 29', 29,
         HAPPY_FLAGS + ['--require-arrangement']) do |dir|
  write_json(dir, 'layout-arrangement.json',
             'pages' => [{ 'page' => 'Overview', 'violations' => ['stacking order inverted vs source'] }])
end

puts '== gate 4b (layout-phase SENTINEL, PLAN-v3 PR-11) =='
# BOUNDARY: LAYOUT_PHASE_BY_TOOL only registers 'tableau-to-sigma' — an
# adopting converter's own genuine run-state.json (tool=<its own value>)
# always hits the "no registered layout-phase key" SKIP, never this FAIL.
# Spoofing `tool` here contract-tests the SHARED script's sentinel mechanism
# directly (same script, same code path any adopting converter would hit),
# not tool-specific behavior.
scenario('run-state.json tracked, layout phase key never stamped -> exit 30', 30) do |dir|
  write_json(dir, 'run-state.json', 'tool' => 'tableau-to-sigma', 'phases' => {})
end

puts '== gate 9 (build-from-signals tile image-verification) =='
scenario('sidecar present, no visual-verify manifest -> exit 11', 11) do |dir|
  write_json(dir, 'visual-verify-tiles.json', ['Tile A'])
end

puts '== gate 11 (post-publish interactivity guide) =='
scenario('source has a dashboard action, no POSTPUBLISH_GUIDE.md -> exit 16', 16) do |dir|
  write_json(dir, 'dashboard-layout-meta.json',
             'worksheets' => { 'Sheet1' => { 'filters' => [{ 'is_action' => true }] } })
end

puts '== gate 12 (deferred/quarantined DM elements) =='
scenario('deferred-elements.json non-empty -> exit 17', 17) do |dir|
  write_json(dir, 'deferred-elements.json', 'deferred' => [{ 'element' => { 'name' => 'Broken Calc' } }])
end

puts '== gate 13 (source-anchor value verification, the measured value bar) =='
scenario('source PNG present, source-anchors.json under the 5-anchor floor -> exit 18', 18) do |dir|
  FileUtils.mkdir_p(File.join(dir, 'views'))
  File.write(File.join(dir, 'views', 'source.png'), 'not a real png, just needs to exist')
  write_json(dir, 'source-anchors.json', 'anchors' => [{ 'id' => 'a1', 'label' => 'Total Sales', 'raw' => '$1,234' }])
end

puts '== gate 15 (manual custom-SQL residues, G6) =='
scenario('an unbuilt residue, not accepted -> exit 22', 22) do |dir|
  write_json(dir, 'manual-residues.json',
             'residues' => [{ 'calc' => 'RunningSum', 'tile' => 'Trend', 'status' => 'unbuilt' }])
end

puts '== gate 16 (join-cardinality ledger, PR-4) =='
scenario('a non-unique Lookup target, no resolution -> exit 23', 23) do |dir|
  write_json(dir, 'join-plan.json',
             'entries' => [{ 'kind' => 'lookup', 'left' => 'Orders', 'right' => 'Customers',
                             'keys' => ['customer_id'], 'status' => 'non-unique' }])
end

puts '== gate 17 (LOD translation ledger, #423) =='
scenario('a suspect-alias LOD calc, no resolution -> exit 24', 24) do |dir|
  write_json(dir, 'lod-audit.json',
             'entries' => [{ 'calc' => '[FIXED Region: SUM(Sales)]', 'class' => 'suspect-alias',
                             'lod_kind' => 'FIXED', 'evidence' => { 'formula' => '[Sales_Raw]' },
                             'suspect_refs' => ['Sales_Raw'] }])
end

puts '== gate 18 (ground-truth numeric coverage, PR-6) =='
scenario('plan exists, numeric comparison never ran -> exit 25', 25) do |dir|
  write_json(dir, 'ground-truth-plan.json',
             'generated_at' => '2026-01-01T00:00:00Z', 'entries' => [{ 'chart' => 'Revenue KPI' }])
end

puts '== gate 19 (aggregation-semantics ledger, PR-7) =='
scenario('an additive-over-preagg hit, no resolution -> exit 26', 26) do |dir|
  write_json(dir, 'agg-semantics.json',
             'entries' => [{ 'consumer' => 'Total Entities KPI', 'context' => 'Sum over FIXED pre-agg',
                             'class' => 'additive-over-preagg', 'preagg' => '[FIXED day: COUNTD(Entity)]' }])
end

puts '== gate 20 (semantic-edit equivalence ledger, PR-8) =='
scenario('a declared edit with no proof block -> exit 27', 27) do |dir|
  write_json(dir, 'semantic-edits.json',
             'entries' => [{ 'edit_description' => 'Dropped LEFT JOIN to Promotions',
                             'claim' => 'no-op, promotions unused', 'grain' => ['order_id'] }])
end

puts '== gate 21 (chart-kind parity, PR-10) =='
scenario('verified source kind (line) disagrees with the live readback (bar) -> exit 28', 28) do |dir|
  write_json(dir, 'png-read.json', 'verified' => true, 'tiles' => [{ 'title' => 'Sales by Region', 'kind' => 'line' }])
  write_json(dir, 'wb-readback.json',
             'pages' => [{ 'id' => 'overview', 'name' => 'Overview' }],
             'elements' => [{ 'id' => 'sales-region', 'name' => 'Sales by Region',
                              'kind' => 'bar-chart', 'visibleAsSource' => true,
                              'xAxis' => { 'columnId' => 'region' },
                              'yAxis' => { 'columnIds' => ['sales'] } }],
             'layout' => '<Page id="overview"><Element elementId="sales-region"/></Page>')
end

puts '== waiver budget (exit 19; checked LAST, after every other gate passes) =='
scenario('3 budget-counted waivers (column+layout+orphan), 1 policy-excluded (visual-comparison) -> exit 19', 19,
         HAPPY_FLAGS + ['--skip-orphan-check', 'budget test: deliberately exceed the cap of 2'])

puts
puts '== gate 3 (ruzs: silent SKIP paths are RECORDED, never a free pass) =='
# A [SKIP] in gate 3/7 that leaves no artifact lets a workbook whose live
# columns were never audited reach GREEN ("gates => all-pass" survives).
# Ratified remedy: the skip is recorded to column-scan.json, which the
# degradation ledger derives into a quality-waiver — capping the verdict at
# YELLOW — rather than a hard exit (a transient outage must not hard-block).
Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  File.delete(File.join(dir, 'wb-ids.json')) # no workbook id resolvable at all
  run_gate(dir, '--skip-layout-check', 'no wb id for gate 4 either',
           '--skip-visual-comparison', 'verifier: pre-verified')
  scan = (JSON.parse(File.read(File.join(dir, 'column-scan.json'))) rescue nil)
  eq(scan.is_a?(Hash), true, 'no-wb-id skip writes column-scan.json')
  eq(scan && scan['status'], 'skipped-no-workbook-id',
     'column-scan.json records status=skipped-no-workbook-id')
  ledger = (JSON.parse(File.read(File.join(dir, 'degradation-ledger.json'))) rescue nil)
  entry = ledger && Array(ledger['entries']).find { |e| e['item'] == 'gate-3-column-scan' }
  eq(!entry.nil?, true, 'the skip lands in the degradation ledger as gate-3-column-scan')
  eq(entry && entry['class'], 'quality-waiver', 'ledger entry class is quality-waiver (caps at YELLOW)')
end

require 'socket'
Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  # Stub Sigma: first /columns page promises a nextPage, then the server 500s
  # every later request — the mid-scan transient the ruzs bead describes.
  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  th = Thread.new do
    first = true
    loop do
      client = server.accept
      while (l = client.gets) && l != "\r\n"; end
      if first
        first = false
        body = JSON.generate('entries' => [{ 'columnId' => 'c1', 'label' => 'A',
                                             'type' => { 'type' => 'number' } }],
                             'nextPage' => 'p2')
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      else
        client.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      end
      client.close
    end
  rescue StandardError
    nil
  end
  env = { 'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}", 'SIGMA_API_TOKEN' => 'stub-token' }
  system(env, 'ruby', GATE, '--workdir', dir,
         '--skip-layout-check', 'stub server serves only gate 3',
         '--skip-visual-comparison', 'verifier: pre-verified',
         out: File::NULL, err: File::NULL)
  server.close rescue nil
  th.kill
  scan = (JSON.parse(File.read(File.join(dir, 'column-scan.json'))) rescue nil)
  eq(scan.is_a?(Hash), true, 'incomplete scan writes column-scan.json')
  eq(scan && scan['status'], 'skipped-incomplete', 'column-scan.json records status=skipped-incomplete')
  eq(scan && scan['columns_read'], 1, 'the partial read count is recorded (1 column seen)')
end

# The clean COMPLETE scan must stay a free pass: complete-clean is recorded as
# positive evidence and derives NO ledger entry (GREEN stays reachable).
Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  th = Thread.new do
    loop do
      client = server.accept
      while (l = client.gets) && l != "\r\n"; end
      body = JSON.generate('entries' => [{ 'columnId' => 'c1', 'label' => 'A',
                                           'type' => { 'type' => 'number' } }])
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
  rescue StandardError
    nil
  end
  env = { 'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}", 'SIGMA_API_TOKEN' => 'stub-token' }
  system(env, 'ruby', GATE, '--workdir', dir,
         '--skip-layout-check', 'stub server serves only gate 3',
         '--skip-visual-comparison', 'verifier: pre-verified',
         out: File::NULL, err: File::NULL)
  server.close rescue nil
  th.kill
  scan = (JSON.parse(File.read(File.join(dir, 'column-scan.json'))) rescue nil)
  eq(scan && scan['status'], 'complete-clean', 'a full clean scan records complete-clean')
  ledger = (JSON.parse(File.read(File.join(dir, 'degradation-ledger.json'))) rescue nil)
  entry = ledger && Array(ledger['entries']).find { |e| e['item'] == 'gate-3-column-scan' }
  eq(entry, nil, 'complete-clean derives NO ledger entry (GREEN stays reachable)')
end

puts
puts '== anchors-oracle SUBSTITUTION (charts_total<=0) fallback: page-level visual verdict when =='
puts '== no visual-verify/manifest.json exists (Tableau-only artifact; 7 other converters share this file) =='
# The manifest-only condition (b) capped every non-Tableau converter sharing
# this canonical file below GREEN whenever they hit the charts_total<=0 path
# (their NORMAL case for a fully dashboard-embedded workbook) — only
# Tableau's own skill emits visual-verify/manifest.json. These scenarios
# exercise the fallback to the page-level record-visual-check.rb verdict
# already stamped into parity-final.json.

scenario('anchors-oracle: no manifest, no recorded visual verdict -> condition (b) incomplete, gate still fails', 2) do |dir|
  write_json(dir, 'anchors-verdict.json', PASSING_ANCHORS_ORACLE)
  write_json(dir, 'parity-final.json',
             'charts_total' => 0, 'charts_pass' => 0, 'status' => 'PASS', 'mode' => 'live')
end

scenario('anchors-oracle: no manifest, agent_vision:false recorded -> condition (b) still incomplete (blind attestation rejected)', 2) do |dir|
  write_json(dir, 'anchors-verdict.json', PASSING_ANCHORS_ORACLE)
  write_json(dir, 'parity-final.json',
             'charts_total' => 0, 'charts_pass' => 0, 'status' => 'PASS', 'mode' => 'live',
             'visual_checked' => true, 'visual_verdict' => 'pass', 'agent_vision' => false)
end

# scenarios 2 and 5 assert on the exact PRINTED success line (not just the
# exit code) — a crash before the print, or the wrong branch's wording, could
# otherwise coincidentally still exit 0.
Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  write_json(dir, 'anchors-verdict.json', PASSING_ANCHORS_ORACLE)
  write_json(dir, 'parity-final.json',
             'charts_total' => 0, 'charts_pass' => 0, 'status' => 'PASS', 'mode' => 'live',
             'visual_checked' => true, 'visual_verdict' => 'pass', 'agent_vision' => true)
  code, out = run_gate_capture(dir, *HAPPY_FLAGS)
  eq(code, 0, 'anchors-oracle: no manifest, page-level visual_verdict=pass recorded -> gate 2 passes via anchors oracle')
  eq(out.include?('page-level visual verdict recorded (pass)'), true,
     'success line names the page-level fallback wording — proves the print path executed, not a coincidental exit 0')
  eq(out.include?('tile(s) image-verified'), false,
     'success line does NOT use the manifest-path wording ("all N tile(s) image-verified") when no manifest exists')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  av_sha = Digest::SHA256.file(File.join(dir, 'anchors-verdict.json')).hexdigest
  eq(pf.dig('parity_oracle', 'kind') == 'anchors' && pf.dig('parity_oracle', 'anchors_verdict_sha256') == av_sha, true,
     'anchors-oracle pass stamps parity_oracle (bound to the anchors-verdict.json sha) for the migration report')
end

# A failed substitution clears any stamp an earlier passing run left behind.
Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  write_json(dir, 'anchors-verdict.json', PASSING_ANCHORS_ORACLE.merge('matched' => 0))
  write_json(dir, 'parity-final.json',
             'charts_total' => 0, 'charts_pass' => 0, 'status' => 'FAIL', 'mode' => 'live',
             'visual_checked' => true, 'visual_verdict' => 'pass', 'agent_vision' => true,
             'parity_oracle' => { 'kind' => 'anchors', 'anchors_verdict_sha256' => 'stale' })
  code = run_gate(dir, *HAPPY_FLAGS)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  eq(code, 2, 'anchors-oracle: unmatched anchors -> gate 2 fails')
  eq(pf.key?('parity_oracle'), false, 'a failed anchors-oracle substitution removes a stale parity_oracle stamp')
end

Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  File.delete(File.join(dir, 'wb-ids.json')) # gates 3/4 take the free no-workbook-id SKIP (zero waiver-budget
                                              # cost) so this scenario's waiver-budget math isolates the
                                              # (formerly visual-divergent census entry; budget is 2; --skip-visual-comparison
                                              # here is the policy-excluded /verifier/i reason, never budget-counted).
  write_json(dir, 'anchors-verdict.json', PASSING_ANCHORS_ORACLE)
  write_json(dir, 'parity-final.json',
             'charts_total' => 0, 'charts_pass' => 0, 'status' => 'PASS', 'mode' => 'live',
             'visual_checked' => true, 'visual_verdict' => 'divergent', 'agent_vision' => true)
  code = run_gate(dir, '--skip-visual-comparison', 'verifier: pre-verified by a prior session')
  eq(code, 0, 'anchors-oracle: no manifest, page-level visual_verdict=divergent recorded -> still satisfies condition (b)')
  pf = (JSON.parse(File.read(File.join(dir, 'parity-final.json'))) rescue nil)
  eq(pf.is_a?(Hash) && Array(pf['waivers']).include?('visual-divergent'), false,
     "waiver census no longer counts 'visual-divergent' (blind-grade v2: divergent is a fidelity-residual, not a waiver)")
end

Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  write_json(dir, 'anchors-verdict.json', PASSING_ANCHORS_ORACLE)
  write_json(dir, 'parity-final.json',
             'charts_total' => 0, 'charts_pass' => 0, 'status' => 'PASS', 'mode' => 'live')
  FileUtils.mkdir_p(File.join(dir, 'visual-verify'))
  write_json(dir, File.join('visual-verify', 'manifest.json'),
             [{ 'worksheet' => 'Tile A', 'visual_verified' => true },
              { 'worksheet' => 'Tile B', 'visual_verified' => true }])
  code, out = run_gate_capture(dir, *HAPPY_FLAGS)
  eq(code, 0, 'anchors-oracle: manifest PRESENT and fully verified -> unchanged existing behavior (regression guard)')
  eq(out.include?('all 2 tile(s) image-verified'), true,
     'success line keeps the ORIGINAL manifest-path wording ("all N tile(s) image-verified") — proves the manifest path is untouched by the fallback')
end

# Regression guard for the misdirection this fix corrects: a REAL manifest
# that exists but has a failing tile must never be reported with the
# no-manifest-at-all remediation hint ("no manifest.json + no recorded
# page-level visual verdict... run scripts/record-visual-check.rb") — that
# hint is only correct when NO manifest exists at all (_vv_source ==
# :page_verdict); here a manifest genuinely exists and one tile failed real
# per-tile verification, so the fix is verify-visual-tiles.rb, not
# record-visual-check.rb. Without this guard, a future edit could reintroduce
# the exact misdirection two prior whole-branch reviews missed.
Dir.mktmpdir('domo-p6') do |dir|
  write_good_fixtures(dir)
  write_json(dir, 'anchors-verdict.json', PASSING_ANCHORS_ORACLE)
  write_json(dir, 'parity-final.json',
             'charts_total' => 0, 'charts_pass' => 0, 'status' => 'PASS', 'mode' => 'live')
  FileUtils.mkdir_p(File.join(dir, 'visual-verify'))
  write_json(dir, File.join('visual-verify', 'manifest.json'),
             [{ 'worksheet' => 'Tile A', 'visual_verified' => true },
              { 'worksheet' => 'Tile B', 'visual_verified' => false }])
  code, _out, err = run_gate_capture(dir, *HAPPY_FLAGS)
  eq(code, 2, 'anchors-oracle: manifest PRESENT with a failing tile -> condition (b) incomplete, gate fails')
  eq(err.include?('every visual-verify tile confirmed (incomplete)'), true,
     'stderr reports condition (b) as incomplete (the real, manifest-driven failure)')
  eq(err.include?('no manifest.json'), false,
     'stderr does NOT print the no-manifest remediation hint when a manifest genuinely exists — the Fix-2 regression guard')
  eq(err.include?('record-visual-check.rb'), false,
     'stderr does NOT recommend record-visual-check.rb (the wrong remediation for a manifest-present failure) — re-running verify-visual-tiles.rb is the real fix')
end


# =============================================================================
# B1.4 — gate 8b re-verifies blind-grade/v2, `visual-divergent` leaves the
# waiver budget, gate 8d finishes YELLOW once the RCF fix budget is spent, and
# gate 21's census no longer counts Sigma button elements as charts.
# =============================================================================
require 'time'
require_relative '../lib/blind_grade'
require_relative '../lib/degradation_ledger'

CATALOG_SRC = File.expand_path('../refs/sigma-platform-differences.json', __dir__)
V2_KEYS = %w[element_titles_hidden palette_match composition_match chart_shapes_match labels_legible numbers_formatted].freeze
V2_FLAGS = ['--skip-column-check', 'offline harness: no live Sigma creds',
            '--skip-layout-check', 'offline harness: no live Sigma creds'].freeze

# A workdir carrying a REAL-hash blind-grade/v2 grade(s) + stamp + visual-residuals.json,
# exactly as record-visual-check.rb would write them. verdict: the RECORDED verdict.
# second_score: also write blind-grade-2.json (a different file with different bytes).
# catalog_override: a self-authored catalog the grades + stamp are (wrongly) bound to.
def v2_workdir(dir, score: 85, verdict: 'pass', per_tile: nil, per_tile_2: nil, catalog_override: nil, second_score: nil,
               gaps: [], residuals: true, images: nil, graded_sha: nil)
  write_good_fixtures(dir)
  src = File.join(dir, 'source-dashboard.png')
  tgt = File.join(dir, 'sigma-render.png')
  File.binwrite(src, "\x89PNG\r\n\x1a\n".b + ('S'.b * 6000))
  images&.call(src, tgt) # real PNGs, written before the grade binds their sha256
  cat_path = CATALOG_SRC
  if catalog_override
    cat_path = File.join(dir, 'catalog.json')
    File.write(cat_path, JSON.pretty_generate(catalog_override))
  end
  cat_sha = graded_sha || Digest::SHA256.file(cat_path).hexdigest
  per_tile ||= [{ 'position' => 'r1c1', 'source_family' => 'kpi', 'target_family' => 'kpi' },
                { 'position' => 'r2c1', 'source_family' => 'line', 'target_family' => 'line' }]
  mk = lambda do |sc, pt = per_tile|
    { 'schema' => 'blind-grade/v2', 'source_png' => src, 'target_png' => tgt,
      'source_sha256' => Digest::SHA256.file(src).hexdigest, 'target_sha256' => Digest::SHA256.file(tgt).hexdigest,
      'catalog_sha256' => cat_sha,
      'dimensions' => V2_KEYS.map { |k| [k, { 'verdict' => 'pass', 'evidence' => 'fixture' }] }.to_h,
      'scores' => V2_KEYS.map { |k| [k, 8] }.to_h, 'overall_score' => sc, 'gaps' => gaps, 'per_tile' => pt }
  end
  grade = mk.call(score)
  gpath = File.join(dir, 'blind-grade.json')
  File.write(gpath, JSON.pretty_generate(grade))
  stamps = [{ 'path' => 'blind-grade.json', 'sha256' => Digest::SHA256.file(gpath).hexdigest, 'overall_score' => score }]
  docs = [grade]
  if second_score
    g2 = mk.call(second_score, per_tile_2 || per_tile)
    File.write(File.join(dir, 'blind-grade-2.json'), JSON.pretty_generate(g2))
    stamps << { 'path' => 'blind-grade-2.json', 'sha256' => Digest::SHA256.file(File.join(dir, 'blind-grade-2.json')).hexdigest,
                'overall_score' => second_score }
    docs << g2
  end
  shipped = BlindGrade.load_catalog(CATALOG_SRC)
  dec = BlindGrade.faithful(docs, shipped)
  faithful = dec['faithful']
  if residuals
    write_json(dir, 'visual-residuals.json', 'schema' => 'visual-residuals/v1', 'catalog_sha256' => graded_sha || shipped['sha256'],
               'grades' => stamps, 'score' => dec['score'], 'faithful' => faithful,
               'platform_differences' => dec['platform_differences'], 'residuals' => dec['residuals'],
               'fixable_major' => dec['fixable_major'], 'reasons' => dec['reasons'])
  end
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  pf.merge!('visual_verdict' => verdict, 'visual_checked' => (verdict == 'pass'), 'agent_vision' => true,
            'style_checklist' => V2_KEYS.map { |k| [k, 'pass'] }.to_h,
            'blind_grade' => { 'schema' => 'blind-grade/v2', 'path' => 'blind-grade.json',
                               'source_sha256' => grade['source_sha256'], 'target_sha256' => grade['target_sha256'],
                               'verdict' => faithful ? 'pass' : 'fail', 'score' => dec['score'], 'faithful' => faithful,
                               'dimensions' => V2_KEYS.map { |k| [k, 'pass'] }.to_h, 'per_tile_count' => per_tile.length,
                               'cross_check' => { 'target' => 'skipped', 'source' => 'skipped' },
                               'catalog_sha256' => cat_sha, 'catalog_path' => catalog_override ? 'catalog.json' : cat_path,
                               'grades' => stamps, 'recorded_at' => '2026-11-05T00:00:00Z' })
  write_json(dir, 'parity-final.json', pf)
  grade
end

puts '== B1.4 gate 8b: blind-grade/v2 re-verification =='
Dir.mktmpdir('b14') do |dir|
  v2_workdir(dir)
  code, out, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 0, 'v2 pass re-verified: both grade sha + catalog sha checked -> exit 0')
  eq(out.include?('blind-grade/v2: catalog + 1 grade file(s) re-hashed'), true, 'gate 8b names the v2 re-verification') if code == 0
  warn err if code != 0 && ENV['DBG']
end
Dir.mktmpdir('b14') do |dir|
  # C2: a self-authored catalog (invented entry) the grades + stamp are bound to — never the shipped one.
  own = JSON.parse(File.read(CATALOG_SRC))
  own['entries'] << { 'id' => 'missing-tile', 'dimension' => 'composition_match', 'description' => 'a tile is absent',
                      'evidence' => 'self-written', 'last_verified' => '2026-11-05' }
  v2_workdir(dir, catalog_override: own)
  code, _out, err = run_gate_capture(dir, *V2_FLAGS)
  shipped_sha = Digest::SHA256.file(CATALOG_SRC).hexdigest
  eq(code, 13, 'C2: v2 pass bound to a self-authored catalog fails 8b (exit 13)')
  eq(err.include?('catalog sha256 mismatch') && err.include?(shipped_sha) &&
     err.include?(Digest::SHA256.file(File.join(dir, 'catalog.json')).hexdigest), true,
     'C2: failure names the stamped sha and the shipped catalog sha')
end
# Catalog history (ancestor rule): a grade + stamp made against an EARLIER
# shipped catalog whose entries all survive unchanged re-verifies at 8b; one
# whose catalog has since lost or reworded an entry, or an unknown sha, fails.
# Ancestors are picked from the SHIPPED history so this tracks the real catalog.
_shipped_cat = BlindGrade.load_catalog(CATALOG_SRC)
_hist_ok = _shipped_cat['history'].keys.reverse.find do |sha|
  sha != _shipped_cat['sha256'] && BlindGrade.catalog_compat(sha, _shipped_cat)['ok']
end
_hist_bad = _shipped_cat['history'].keys.find { |sha| !BlindGrade.catalog_compat(sha, _shipped_cat)['ok'] }
if _hist_ok
  Dir.mktmpdir('b14') do |dir|
    v2_workdir(dir, graded_sha: _hist_ok)
    code, _out, err = run_gate_capture(dir, *V2_FLAGS)
    eq(code, 0, "catalog history: grade + stamp on an unchanged ancestor catalog (#{_hist_ok[0, 12]}…) re-verify at 8b -> exit 0")
    warn err if code != 0
  end
  _anc_ids = BlindGrade.catalog_compat(_hist_ok, _shipped_cat)['graded_ids']
  _surv = _shipped_cat['entries'].find { |e| _anc_ids.include?(e['id']) }
  _late = _shipped_cat['entries'].find { |e| !_anc_ids.include?(e['id']) }
  if _surv
    Dir.mktmpdir('b14') do |dir|
      v2_workdir(dir, graded_sha: _hist_ok, gaps: [{ 'tile' => 'r1c1', 'dimension' => _surv['dimension'], 'description' => 'platform',
                                                     'severity' => 'minor', 'class' => _surv['id'] }])
      code, _out, err = run_gate_capture(dir, *V2_FLAGS)
      eq(code, 0, "catalog history: ancestor grade citing a surviving id (#{_surv['id']}) re-verifies at 8b -> exit 0")
      warn err if code != 0
    end
  end
  if _late
    Dir.mktmpdir('b14') do |dir|
      v2_workdir(dir, graded_sha: _hist_ok, gaps: [{ 'tile' => 'r1c1', 'dimension' => _late['dimension'], 'description' => 'platform',
                                                     'severity' => 'minor', 'class' => _late['id'] }])
      code, _out, err = run_gate_capture(dir, *V2_FLAGS)
      eq(code, 13, "catalog history: ancestor grade citing an id added later (#{_late['id']}) fails 8b (exit 13)")
      eq(err.include?('added AFTER'), true, 'catalog history: failure says the id was added after the graded catalog')
    end
  end
else
  puts '  SKIP  catalog history: the shipped history has no unchanged ancestor of the shipped catalog yet'
end
if _hist_bad
  Dir.mktmpdir('b14') do |dir|
    v2_workdir(dir, graded_sha: _hist_bad)
    code, _out, err = run_gate_capture(dir, *V2_FLAGS)
    eq(code, 13, 'catalog history: stamp on an ancestor whose entries were since removed/changed fails 8b (exit 13)')
    eq(err.include?('catalog sha256 mismatch') && (err.include?('REMOVED') || err.include?('CHANGED')), true,
       'catalog history: failure names the removed/changed entries')
  end
end
Dir.mktmpdir('b14') do |dir|
  v2_workdir(dir, graded_sha: 'e' * 64)
  code, _out, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'catalog history: unknown catalog sha fails 8b (exit 13)')
  eq(err.include?('unknown catalog'), true, 'catalog history: failure says unknown catalog')
end
Dir.mktmpdir('b14') do |dir|
  g = v2_workdir(dir)
  g['overall_score'] = 99 # edited after recording
  File.write(File.join(dir, 'blind-grade.json'), JSON.pretty_generate(g))
  code, _out, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'v2 grade file edited after recording fails 8b (exit 13)')
  eq(err.include?('blind-grade.json') && err.include?('sha256 drift'), true, 'failure names the grade file + sha drift')
end
Dir.mktmpdir('b14') do |dir|
  v2_workdir(dir, score: 60, verdict: 'pass') # recorded PASS but the grade computes DIVERGENT
  forged = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  forged['blind_grade']['verdict'] = 'pass'; forged['blind_grade']['faithful'] = true # a hand-forged stamp
  write_json(dir, 'parity-final.json', forged)
  code, _out, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'recorded pass contradicting the re-computed v2 verdict fails 8b (exit 13)')
  eq(err.include?('contradicts the re-computed'), true, 'failure explains the verdict contradiction')
end
Dir.mktmpdir('b14') do |dir|
  v2_workdir(dir, score: 60, verdict: 'divergent')
  code, out, _err = run_gate_capture(dir, *V2_FLAGS)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  eq(code, 0, 'divergent no longer counts toward the waiver budget: divergent + 2 other waivers -> exit 0 (not 19)')
  eq(!Array(pf['waivers']).include?('visual-divergent'), true, "parity-final waiver census omits 'visual-divergent'")
  eq(Array(pf['waivers']).length, 2, 'census lists exactly the two real waivers')
  led = (JSON.parse(File.read(File.join(dir, 'degradation-ledger.json'))) rescue {})
  eq(Array(led['entries']).any? { |e| e['class'].to_s == 'fidelity-residual' && e['item'].to_s.include?('divergent') } ||
     out.include?('visual verdict: divergent'), true, 'divergent still forfeits GREEN (fidelity-residual in the degradation ledger)')
  succ = (JSON.parse(File.read(File.join(dir, 'phase6-success.json'))) rescue {})
  eq(succ['verdict'].to_s.include?('YELLOW'), true, 'divergent still forfeits GREEN: verdict YELLOW')
end
Dir.mktmpdir('b14') do |dir|
  v2_workdir(dir, score: 60, verdict: 'divergent')
  File.write(File.join(dir, 'blind-grade.json'), File.read(File.join(dir, 'blind-grade.json')).sub('"overall_score": 60', '"overall_score": 61'))
  code, _out, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'a recorded DIVERGENT v2 stamp is re-verified too (edited grade -> exit 13)')
  eq(err.include?('DIVERGENT verdict carries a blind-grade/v2 stamp'), true, 'divergent re-verification failure is named')
end

puts '== final review gate 8b: second-grade rule, census on both grades, bound visual-residuals.json =='
def restamp_grades(dir)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  pf['blind_grade']['grades'].each do |g|
    g['sha256'] = Digest::SHA256.file(File.join(dir, g['path'])).hexdigest if File.file?(File.join(dir, g['path']))
  end
  write_json(dir, 'parity-final.json', pf)
  pf
end
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 78, second_score: 80)
  code, out, = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 0, 'control: a borderline first grade + an independent second grade re-verifies')
  eq(out.include?('2 grade file(s)'), true, 'control: gate names both grade files')
end
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 78, second_score: 80)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  pf['blind_grade']['grades'][1] = pf['blind_grade']['grades'][0].dup
  write_json(dir, 'parity-final.json', pf)
  code, _o, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'C1: both stamped grades are the same file -> exit 13')
  eq(err.include?('same grade'), true, 'C1: failure says the grades are the same')
end
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 78, second_score: 80)
  FileUtils.cp(File.join(dir, 'blind-grade.json'), File.join(dir, 'blind-grade-2.json'))
  restamp_grades(dir)
  code, _o, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'C1: a byte-identical copy as the second grade -> exit 13')
  eq(err.include?('same grade') && err.include?('identical bytes'), true, 'C1: failure names identical bytes')
end
[[60, 95], [50, 100]].each do |g1, g2|
  Dir.mktmpdir('fr') do |dir|
    v2_workdir(dir, score: g1, second_score: g2, verdict: 'pass') # a rescued/sunk grade the recorder must have refused
    code, _o, err = run_gate_capture(dir, *V2_FLAGS)
    eq(code, 13, "C1: #{g1}+#{g2} second grade over a non-borderline first grade -> exit 13")
    eq(err.include?('not borderline'), true, "C1: failure says grade 1 alone is not borderline (#{g1}+#{g2})")
  end
end
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 90)
  FileUtils.cp(File.join(dir, 'blind-grade.json'), File.join(dir, 'other.json'))
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  pf['blind_grade']['path'] = 'other.json'
  write_json(dir, 'parity-final.json', pf)
  code, _o, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'C1: blind_grade.path not equal to grades[0].path -> exit 13')
  eq(err.include?('grades[0]'), true, 'C1: failure names grades[0]')
end
CENSUS_EL = [{ 'id' => 'sales', 'name' => 'Sales', 'kind' => 'bar-chart', 'visibleAsSource' => true },
             { 'id' => 'trend', 'name' => 'Trend', 'kind' => 'line-chart', 'visibleAsSource' => true }].freeze
def census_wb(dir)
  write_json(dir, 'wb-readback.json', 'pages' => [{ 'id' => 'overview', 'name' => 'Overview' }], 'elements' => CENSUS_EL,
             'layout' => '<Page id="overview"></Page>')
end
GOOD_TILES = [{ 'position' => 'r1c1', 'source_family' => 'bar', 'target_family' => 'bar' },
              { 'position' => 'r2c1', 'source_family' => 'line', 'target_family' => 'line' }].freeze
BAD_TILES = [{ 'position' => 'r1c1', 'source_family' => 'bar', 'target_family' => 'pie' },
             { 'position' => 'r2c1', 'source_family' => 'line', 'target_family' => 'pie' }].freeze
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 78, second_score: 80, per_tile: GOOD_TILES, per_tile_2: GOOD_TILES)
  census_wb(dir)
  eq(run_gate_capture(dir, *V2_FLAGS)[0], 0, 'control: both grades consistent with the census -> exit 0')
end
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 78, second_score: 80, per_tile: GOOD_TILES, per_tile_2: BAD_TILES)
  census_wb(dir)
  code, _o, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'C1: the SECOND grade contradicting the kind census -> exit 13')
  eq(err.include?('INCONSISTENT') && err.include?('blind-grade-2.json'), true, 'C1: failure names the second grade file')
end
# KPI band (live RCC regression): grade 1 lists the KPI strip as 3 tiles, grade 2 as one band;
# record accepted both, so 8b must not refuse what record accepted.
RCC_FAMS = %w[kpi kpi kpi line table bar bar table bar map].freeze
RCC_TILES1 = (%w[text navigation control kpi kpi kpi line table bar bar table bar map]).each_with_index.map { |f, i| { 'position' => "t#{i}", 'source_family' => f, 'target_family' => f } }
RCC_TILES2 = (%w[text navigation control kpi line table bar bar table bar map]).each_with_index.map { |f, i| { 'position' => "t#{i}", 'source_family' => f, 'target_family' => f } }
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 77, second_score: 80, per_tile: RCC_TILES1, per_tile_2: RCC_TILES2)
  els = RCC_FAMS.each_with_index.map { |f, i| { 'id' => "e#{i}", 'name' => "E#{i}", 'kind' => (%w[table map].include?(f) ? f : "#{f}-chart"), 'visibleAsSource' => true } }
  write_json(dir, 'wb-readback.json', 'pages' => [{ 'id' => 'overview', 'name' => 'Overview' }], 'elements' => els,
             'layout' => '<Page id="overview"></Page>')
  write_json(dir, 'png-read.json', 'tiles' => RCC_FAMS.map { |f| { 'kind' => f } })
  code, _o, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 0, 'KPI band: RCC grades 77+80 (strip as 3 tiles / 1 band) re-verify at 8b -> exit 0')
  warn err if code != 0
end
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 90, residuals: false)
  code, _o, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'I1: a v2 stamp with NO visual-residuals.json -> exit 13')
  eq(err.include?('visual-residuals.json missing/stale'), true, 'I1: failure says missing/stale')
end
MAJOR = { 'tile' => 'r1c1', 'dimension' => 'composition_match', 'description' => 'KPI row missing', 'severity' => 'major',
          'class' => 'fixable' }.freeze
{ 'score' => 99.0, 'faithful' => false, 'residuals' => [MAJOR], 'platform_differences' => [MAJOR],
  'catalog_sha256' => 'f' * 64 }.each do |key, forged|
  Dir.mktmpdir('fr') do |dir|
    v2_workdir(dir, score: 90)
    vr = JSON.parse(File.read(File.join(dir, 'visual-residuals.json')))
    vr[key] = forged
    write_json(dir, 'visual-residuals.json', vr)
    code, _o, err = run_gate_capture(dir, *V2_FLAGS)
    eq(code, 13, "I1: stale visual-residuals.json (#{key} edited) -> exit 13")
    eq(err.include?('visual-residuals.json missing/stale'), true, "I1: failure names the stale file (#{key})")
  end
end
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 90, verdict: 'divergent', gaps: [MAJOR])
  code, _o, = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 0, 'control: divergent run with a named major fixable gap and its residuals file -> exit 0')
  vr = JSON.parse(File.read(File.join(dir, 'visual-residuals.json')))
  eq(vr['fixable_major'].map { |g| g['description'] }, ['KPI row missing'], 'I2: visual-residuals.json names the major gap')
  led = JSON.parse(File.read(File.join(dir, 'degradation-ledger.json')))
  eq(Array(led['entries']).any? { |e| e['item'] == 'visual residual (major): r1c1: KPI row missing' }, true,
     'I2: the degradation ledger names the major fixable gap')
  vr['fixable_major'] = []
  write_json(dir, 'visual-residuals.json', vr)
  code, = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'I1: a divergent run whose residuals file hides the major gap -> exit 13')
end
Dir.mktmpdir('fr') do |dir|
  v2_workdir(dir, score: 90, gaps: [{ 'tile' => 'r1c1', 'dimension' => 'composition_match', 'description' => 'x',
                                     'severity' => 'minor', 'class' => 'missing-tile' }])
  code, _o, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 13, 'C2: a grade citing an id outside the shipped catalog no longer validates -> exit 13')
  eq(err.include?('unknown catalog id'), true, 'C2: failure names the unknown id')
end

puts '== minor = notes (TJ 2026-11-09): minor gaps on a PASSING v2 grade are polish notes, not degradations =='
MINOR_A = { 'tile' => 'r3c1', 'dimension' => 'palette_match', 'description' => 'Trend line stroke is thinner',
            'severity' => 'minor', 'class' => 'fixable' }.freeze
MINOR_B = { 'tile' => 'r2c1', 'dimension' => 'composition_match', 'description' => 'KPI cards are boxed',
            'severity' => 'minor', 'class' => 'fixable' }.freeze
minor_items = ['visual residual (minor): r3c1: Trend line stroke is thinner',
               'visual residual (minor): r2c1: KPI cards are boxed']
Dir.mktmpdir('polish') do |dir|
  v2_workdir(dir, score: 85, gaps: [MINOR_A, MINOR_B])
  code, out, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 0, 'pass grade + 2 minor gaps re-verifies at 8b -> exit 0')
  warn err if code != 0 && ENV['DBG']
  led = JSON.parse(File.read(File.join(dir, 'degradation-ledger.json')))
  eq(Array(led['entries']).none? { |e| minor_items.include?(e['item']) }, true,
     'pass grade: minor gaps are NOT degradation-ledger entries')
  eq(out.include?('visual residual (minor)'), false, 'pass grade: the gate does not list minors as degradations')
  eq(DegradationLedger.polish_notes(dir).map { |n| n['item'] },
     ['r3c1: Trend line stroke is thinner', 'r2c1: KPI cards are boxed'], 'pass grade: both minors are polish notes')
end
Dir.mktmpdir('polish') do |dir|
  v2_workdir(dir, score: 85, verdict: 'divergent', gaps: [MAJOR, MINOR_A])
  code, = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 0, 'divergent grade (major + minor) records -> exit 0')
  led = JSON.parse(File.read(File.join(dir, 'degradation-ledger.json')))
  items = Array(led['entries']).map { |e| e['item'] }
  eq(items.include?('visual residual (major): r1c1: KPI row missing') && items.include?(minor_items[0]), true,
     'divergent grade: the major AND the minor stay fidelity-residuals')
  eq(DegradationLedger.polish_notes(dir), [], 'divergent grade: no polish notes')
end
Dir.mktmpdir('polish') do |dir|
  v2_workdir(dir, score: 60, verdict: 'divergent', gaps: [MINOR_A])
  run_gate_capture(dir, *V2_FLAGS)
  led = JSON.parse(File.read(File.join(dir, 'degradation-ledger.json')))
  eq(Array(led['entries']).any? { |e| e['item'] == minor_items[0] }, true,
     'low-score divergent grade with only a minor gap: the minor stays a fidelity-residual')
  eq(DegradationLedger.polish_notes(dir), [], 'low-score divergent grade: no polish notes')
end

puts '== B1.4 gate 21 / 8b: Sigma button elements are not charts =='
Dir.mktmpdir('b14') do |dir|
  v2_workdir(dir)
  write_json(dir, 'png-read.json', 'verified' => true,
             'tiles' => [{ 'title' => 'Sales by Region', 'kind' => 'bar' }, { 'title' => 'Trend', 'kind' => 'line' }])
  els = [{ 'id' => 'sales', 'name' => 'Sales by Region', 'kind' => 'bar-chart', 'visibleAsSource' => true },
         { 'id' => 'trend', 'name' => 'Trend', 'kind' => 'line-chart', 'visibleAsSource' => true }] +
        (1..9).map { |i| { 'id' => "nav#{i}", 'name' => "Nav #{i}", 'kind' => 'button', 'visibleAsSource' => true } }
  write_json(dir, 'wb-readback.json', 'pages' => [{ 'id' => 'overview', 'name' => 'Overview' }], 'elements' => els,
             'layout' => '<Page id="overview"></Page>')
  code, out, err = run_gate_capture(dir, *V2_FLAGS)
  eq(code, 0, '2 charts + 9 button elements vs 2 source tiles: gate 21 does not flag, gate 8b passes the v2 grade')
  eq(out.include?('gate 21') && !err.include?('gate 21'), true, 'gate 21 reports OK, no family/count mismatch')
  warn err if code != 0 && ENV['DBG']
end

puts '== B1.4 gate 8d: spec-fixable blocks only while RCF budget remains =='
def rcf_ledger(dir, entries, pass: 1, max_passes: 5, started: nil, max_seconds: 1800)
  l = { 'workbook_id' => 'wb', 'page_id' => 'p', 'pass' => pass, 'max_passes' => max_passes,
        'max_seconds' => max_seconds, 'started_at' => (started || Time.now.utc).utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'renders' => [], 'entries' => entries }
  write_json(dir, 'fidelity-ledger.json', l)
end
def rcf_entry(id, cls, extra = {})
  { 'id' => id, 'cls' => cls, 'dimension' => 'palette_match', 'delta' => "delta #{id}", 'resolved' => false }.merge(extra)
end
def gate8d(dir, spent: false, entries:, **kw)
  write_good_fixtures(dir)
  rcf_ledger(dir, entries, **kw)
  File.write(File.join(dir, 'rcf-exhausted.json'), '{"status":"exhausted"}') if spent
  run_gate_capture(dir, *HAPPY_FLAGS, '--require-fidelity-ledger')
end

Dir.mktmpdir('b14') { |d| eq(gate8d(d, entries: [rcf_entry('d1', 'spec-fixable')])[0], 15, '8d: unresolved spec-fixable with budget remaining still exits 15') }
Dir.mktmpdir('b14') do |d|
  code, out, = gate8d(d, entries: [rcf_entry('d1', 'spec-fixable')], pass: 5, max_passes: 5)
  eq(code, 0, '8d: unresolved spec-fixable after pass budget spent exits 0')
  led = JSON.parse(File.read(File.join(d, 'degradation-ledger.json')))
  eq(Array(led['entries']).any? { |e| e['item'].to_s.start_with?('RCF residual d1') }, true, 'the spent-budget residual is a degradation-ledger item starting "RCF residual"')
  eq(out.include?('fix budget SPENT'), true, '8d prints the spent-budget NOTE naming the residual')
  eq(JSON.parse(File.read(File.join(d, 'phase6-success.json')))['verdict'].to_s.include?('YELLOW'), true, 'spent-budget residual finishes YELLOW')
end
Dir.mktmpdir('b14') { |d| eq(gate8d(d, spent: true, entries: [rcf_entry('d1', 'spec-fixable')])[0], 0, '8d: rcf-exhausted.json marks the budget spent -> exit 0') }
Dir.mktmpdir('b14') { |d| eq(gate8d(d, entries: [rcf_entry('d1', 'spec-fixable')], started: Time.now.utc - 7200, max_seconds: 1800)[0], 0, '8d: wall-clock budget elapsed -> spent -> exit 0') }
Dir.mktmpdir('b14') { |d| eq(gate8d(d, entries: [rcf_entry('d1', 'spec-fixable')], started: Time.now.utc - 60, max_seconds: 1800)[0], 15, '8d: wall-clock budget remaining -> still blocks (15)') }
Dir.mktmpdir('b14') { |d| eq(gate8d(d, entries: [{ 'id' => 'd1', 'cls' => 'spec-fixable', 'dimension' => 'x', 'delta' => 'y' }].tap { |_| }, pass: 5, max_passes: nil)[0], 15, '8d: missing max_passes -> not spent (conservative, keeps blocking)') }
Dir.mktmpdir('b14') { |d| eq(gate8d(d, spent: true, entries: [rcf_entry('v1', 'data')])[0], 15, '8d: data-class residual still blocks after budget spent') }
Dir.mktmpdir('b14') { |d| eq(gate8d(d, entries: [rcf_entry('c1', 'sigma-capability')])[0], 15, '8d: sigma-capability without catalog_id is treated as spec-fixable (blocks with budget left)') }
Dir.mktmpdir('b14') { |d| eq(gate8d(d, entries: [rcf_entry('c1', 'sigma-capability', 'catalog_id' => 'not-in-catalog')])[0], 15, '8d: sigma-capability with a catalog_id absent from the catalog still blocks') }
Dir.mktmpdir('b14') { |d| eq(gate8d(d, entries: [rcf_entry('u1', 'ui-only')])[0], 15, '8d: ui-only without catalog_id folds into sigma-capability (blocks with budget left)') }
Dir.mktmpdir('b14') { |d| eq(gate8d(d, pass: 5, entries: [rcf_entry('c1', 'sigma-capability')])[0], 0, '8d: uncatalogued sigma-capability after budget spent -> exit 0, residual') }
# A VALID catalog_id never blocks: stage a private copy of the gate whose shipped catalog has one entry.
Dir.mktmpdir('b14') do |d|
  tree = File.join(d, 'tree')
  %w[scripts lib refs].each { |sub| FileUtils.mkdir_p(File.join(tree, sub)); FileUtils.cp_r(Dir.glob(File.join(__dir__, '..', sub, '*')), File.join(tree, sub)) }
  File.write(File.join(tree, 'refs', 'sigma-platform-differences.json'), JSON.pretty_generate(
    'version' => 1, 'entries' => [{ 'id' => 'fixture-diff', 'dimension' => 'palette_match', 'description' => 'd', 'evidence' => 'e', 'last_verified' => '2026-11-05' }]))
  wd = File.join(d, 'wd'); FileUtils.mkdir_p(wd)
  write_good_fixtures(wd)
  rcf_ledger(wd, [rcf_entry('c1', 'sigma-capability', 'catalog_id' => 'fixture-diff')])
  _o, _e, st = Open3.capture3(OFFLINE_ENV, 'ruby', File.join(tree, 'scripts', 'assert-phase6-ran.rb'),
                              '--workdir', wd, *HAPPY_FLAGS, '--require-fidelity-ledger')
  eq(st.exitstatus, 0, '8d: sigma-capability WITH a valid catalog_id never blocks (budget remaining)')
end

puts '== final review gate 8d: forged rcf-exhausted.json, recorded-residual count =='
Dir.mktmpdir('fr') do |d|
  write_good_fixtures(d)
  rcf_ledger(d, [rcf_entry('d1', 'spec-fixable')])
  File.write(File.join(d, 'rcf-exhausted.json'), '')
  eq(run_gate_capture(d, *HAPPY_FLAGS, '--require-fidelity-ledger')[0], 15, 'M1: an empty rcf-exhausted.json does not spend the budget')
  File.write(File.join(d, 'rcf-exhausted.json'), '{"status":"nope"}')
  eq(run_gate_capture(d, *HAPPY_FLAGS, '--require-fidelity-ledger')[0], 15, 'M1: rcf-exhausted.json without status=exhausted does not spend the budget')
  File.write(File.join(d, 'rcf-exhausted.json'), '{nope')
  eq(run_gate_capture(d, *HAPPY_FLAGS, '--require-fidelity-ledger')[0], 15, 'M1: an unparseable rcf-exhausted.json does not spend the budget')
  File.write(File.join(d, 'rcf-exhausted.json'), JSON.generate('status' => 'exhausted', 'pass' => 5, 'max_passes' => 5))
  eq(run_gate_capture(d, *HAPPY_FLAGS, '--require-fidelity-ledger')[0], 0, 'M1: a real exhaustion record spends the budget')
end
Dir.mktmpdir('fr') do |d|
  code, out, = gate8d(d, pass: 5, entries: [rcf_entry('c1', 'sigma-capability'), rcf_entry('u1', 'ui-only', 'catalog_id' => 'font-family')])
  eq(code, 0, 'M5: spent budget, one uncatalogued + one catalogued entry -> exit 0')
  eq(out.include?('(1 recorded residual(s)'), true, 'M5: only the catalogued platform difference counts as a recorded residual')
end

puts '== gate 14: a catalogued platform difference explains a floor component (Complex Pivot, 2026-11-09) =='
# A stub visual-similarity.py (VISUAL_SIMILARITY_SCRIPT) writes the measured JSON
# the real script would; the gate's own exemption logic is what is under test.
VSIM_STUB = <<~PYSTUB
  import json, os, shutil, sys
  out = sys.argv[sys.argv.index("--json-out") + 1]
  if os.environ.get("VSIM_ARGV_COPY"):
      json.dump(sys.argv[1:], open(os.environ["VSIM_ARGV_COPY"], "w"))
  if "--tiles" in sys.argv and os.environ.get("VSIM_TILES_COPY"):
      shutil.copy(sys.argv[sys.argv.index("--tiles") + 1], os.environ["VSIM_TILES_COPY"])
  json.dump(json.loads(os.environ["VSIM_STUB_JSON"]), open(out, "w"))
  sys.exit(0 if json.loads(os.environ["VSIM_STUB_JSON"])["pass"] else 1)
PYSTUB
def vsim_doc(overall: 0.464, band: 0.0, cov: 0.62, health: 'PASS', blank: [], measured: 4)
  { 'score_overall' => overall, 'threshold' => 0.45, 'pass' => false, 'notes' => [],
    'source_health' => { 'status' => health }, 'render_health' => { 'status' => 'PASS' },
    'components' => { 'coverage' => cov, 'band_balance' => band, 'pattern_corr' => 0.5, 'profile_corr' => 0.5, 'aspect_factor' => 1.0 },
    'tiles_measured' => measured, 'tiles_blank' => blank }
end
def gate14(dir, doc, catalog_id: 'pivot-row-height-fixed', record: true, render_extra: {}, env_extra: {}, extra_args: [])
  stub = File.join(dir, 'vsim-stub.py')
  File.write(stub, VSIM_STUB)
  begin
    rcf_ledger(dir, record ? [rcf_entry('e0', 'sigma-capability', 'catalog_id' => catalog_id, 'dimension' => 'composition_match',
                                        'delta' => 'pivot rows fixed height', 'resolved' => true)] : [])
    # gate 8b attributes the grade to the RCF loop's latest budgeted render
    led = JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
    tgt = File.join(dir, 'sigma-render.png')
    led['renders'] = [{ 'pass' => 1, 'path' => tgt }.merge(render_extra)]
    led['source_image'] = File.join(dir, 'source-dashboard.png')
    # gate 13 runs once a source PNG is present: verified anchors let it pass
    write_json(dir, 'source-anchors.json', 'anchors' => (1..5).map { |i| { 'value' => "#{i}00", 'tile' => "t#{i}" } })
    write_json(dir, 'anchors-verdict.json', 'pass' => true, 'checked' => 5, 'matched' => 5, 'tiles_all_nonempty' => true)
    write_json(dir, 'fidelity-ledger.json', led)
    pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
    pf['screenshot_path'] = tgt
    pf['blind_grade']['fidelity_render'] = { 'pass' => 1, 'sha256' => Digest::SHA256.file(tgt).hexdigest }
    write_json(dir, 'parity-final.json', pf)
  end
  env = OFFLINE_ENV.merge('VISUAL_SIMILARITY_SCRIPT' => stub,
                          'VSIM_STUB_JSON' => JSON.generate(doc)).merge(env_extra)
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, err, st = Open3.capture3(env, 'ruby', GATE, '--workdir', dir, *V2_FLAGS, *extra_args)
  [st.exitstatus, out, err]
end
Dir.mktmpdir('g14') do |dir|
  v2_workdir(dir)
  code, out, err = gate14(dir, vsim_doc)
  eq(code, 0, "band_balance 0.00 explained by a recorded pivot-row-height-fixed -> exit 0 (#{err.lines.grep(/gate 14/).first.to_s.strip})")
  eq(out.include?('gate 14: visual-similarity floor passed with a platform-difference exemption'), true, 'gate 14 names the exemption')
  ex = (JSON.parse(File.read(File.join(dir, 'visual-similarity-exemptions.json'))) rescue {})
  eq(Array(ex['exemptions']).map { |x| [x['component'], x['catalog_id'], x['rcf_id']] },
     [['band_balance', 'pivot-row-height-fixed', 'e0']], 'exemption recorded for band_balance only')
  pd = DegradationLedger.platform_differences(dir)
  eq(pd.any? { |p| p['source_artifact'] == 'visual-similarity-exemptions.json' && p['catalog_id'] == 'pivot-row-height-fixed' },
     true, 'the exemption is listed as a platform difference')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  eq(Array(pf['waivers']).include?('--skip-visual-similarity'), false, 'the exemption is not a waiver')
end
Dir.mktmpdir('g14') do |dir|
  v2_workdir(dir)
  eq(gate14(dir, vsim_doc, record: false)[0], 20, 'no recorded platform difference -> gate 14 still fails (exit 20)')
  eq(File.exist?(File.join(dir, 'visual-similarity-exemptions.json')), false, 'no exemption file without one')
end
Dir.mktmpdir('g14') do |dir|
  v2_workdir(dir)
  eq(gate14(dir, vsim_doc(overall: 0.40))[0], 20, 'overall below the threshold is never exempted (exit 20)')
end
Dir.mktmpdir('g14') do |dir|
  v2_workdir(dir)
  eq(gate14(dir, vsim_doc, catalog_id: 'list-control-all-placeholder')[0], 20,
     'a composition_match difference that is not a floor explainer (list-control placeholder) -> exit 20')
end
Dir.mktmpdir('g14') do |dir|
  v2_workdir(dir)
  eq(gate14(dir, vsim_doc(blank: %w[t1 t2 t3]))[0], 20, 'a majority-blank render is never exempted (exit 20)')
  eq(gate14(dir, vsim_doc(health: 'FAIL'))[0], 20, 'failed image health is never exempted (exit 20)')
end

puts '== gate 14: a 2-page --all-pages composite gets its tiles in composite page order (Stress 4, 2026-11-10) =='
# parse-twb-layout writes a LIST of dashboards; the composite follows the
# workbook's page order (here Detail first) and never rendered "Appendix".
def two_page_layout
  zone = ->(cap) { { 'id' => cap, 'kind' => 'chart', 'caption' => cap, 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 50, 'h_pct' => 50 } }
  [{ 'dashboard' => 'Overview', 'zones' => [zone.call('Rev')] },
   { 'dashboard' => 'Detail', 'zones' => [zone.call('Orders')] },
   { 'dashboard' => 'Appendix', 'zones' => [zone.call('Notes')] }]
end
Dir.mktmpdir('g14') do |dir|
  v2_workdir(dir)
  write_json(dir, 'dashboard-layout.json', two_page_layout)
  wb = (JSON.parse(File.read(File.join(dir, 'wb-ids.json'))) rescue {})
  wb = {} unless wb.is_a?(Hash)
  wb['pages'] = [{ 'id' => 'pg-o', 'name' => 'Overview' }, { 'id' => 'pg-d', 'name' => 'Detail' },
                 { 'id' => 'pg-a', 'name' => 'Appendix' }]
  write_json(dir, 'wb-ids.json', wb)
  seen = File.join(dir, 'tiles-seen.json')
  argv = File.join(dir, 'argv-seen.json')
  # fidelity-loop's per-page renders beside the composite: exact band geometry
  png_hdr = ->(w, h) { "\x89PNG\r\n\x1a\n".b + [13].pack('N') + 'IHDR' + [w, h].pack('NN') + ("\0" * 5000) }
  File.binwrite(File.join(dir, 'rcf-pass-1-p1-pg-d.png'), png_hdr.call(1200, 900))
  File.binwrite(File.join(dir, 'rcf-pass-1-p2-pg-o.png'), png_hdr.call(1000, 700))
  doc = vsim_doc(overall: 0.7, band: 0.5, measured: 2).merge('pass' => true)
  code, out, err = gate14(dir, doc, render_extra: { 'composite' => true, 'pages' => %w[pg-d pg-o] },
                                    env_extra: { 'VSIM_TILES_COPY' => seen, 'VSIM_ARGV_COPY' => argv })
  eq(code, 0, "composite run passes gate 14 (#{(out + err).lines.grep(/gate 14|FAIL/).first.to_s.strip})")
  got = (JSON.parse(File.read(seen)) rescue nil)
  eq(Array(got).map { |d| d['dashboard'] }, %w[Detail Overview],
     '--tiles carries the rendered dashboards in composite page order, unrendered ones dropped')
  args = (JSON.parse(File.read(argv)) rescue [])
  eq(args[(args.index('--composite-pages') || -2) + 1], '1200x900,1000x700',
     '--composite-pages carries the per-page render sizes in stack order')
  eq(out.include?('2 tile(s) measured'), true, 'the OK line reports the measured tiles')
  eq(err.include?('per-tile blank detector NOT armed'), false, 'no NOT-armed warning when tiles were measured')
  # agent_vision = the builder's own capability; WHO graded is a separate field
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  eq(pf['visual_graded_by'], 'blind-grader', 'success stamps visual_graded_by=blind-grader for a recorded blind grade')
  eq(out.include?('visual_graded_by=blind-grader'), true, 'gate 8b line names who graded the visuals')
end
Dir.mktmpdir('g14') do |dir|
  v2_workdir(dir)
  write_json(dir, 'dashboard-layout.json', two_page_layout)
  doc = vsim_doc(measured: 0).merge('tiles_unmapped' => 3)
  code, out, err = gate14(dir, doc)
  eq(code, 0, 'a zero-tile platform-difference exemption still passes gate 14')
  eq(out.include?('passed with a platform-difference exemption'), true, 'the floor shortfall is exempted')
  eq(err.include?('[WARN] gate 14: per-tile blank detector NOT armed — 3 tile box(es) could not be placed'), true,
     '0 tiles measured is warned on the exemption success path')
end
Dir.mktmpdir('g14') do |dir|
  v2_workdir(dir)
  write_json(dir, 'dashboard-layout.json', two_page_layout)
  seen = File.join(dir, 'tiles-seen.json')
  doc = vsim_doc(overall: 0.7, band: 0.5, measured: 0).merge('pass' => true, 'tiles_unmapped' => 3)
  code, _out, err = gate14(dir, doc, env_extra: { 'VSIM_TILES_COPY' => seen })
  eq(code, 0, 'a passing floor with 0 tiles still passes gate 14')
  eq(Array((JSON.parse(File.read(seen)) rescue nil)).map { |d| d['dashboard'] }, %w[Overview Detail Appendix],
     'a non-composite render gets the layout as-is')
  eq(err.include?('[WARN] gate 14: per-tile blank detector NOT armed — 3 tile box(es) could not be placed'), true,
     '0 tiles measured is stated as a WARN, never a silent OK')
end
Dir.mktmpdir('g14') do |dir|
  # a single-page RCF pass of a 2-dashboard workbook gets ONLY its own
  # dashboard; a composite whose per-page PNGs are gone still says how many
  # pages it stacks
  v2_workdir(dir)
  lay = two_page_layout
  lay << { 'dashboard' => 'Params', 'emit_page' => false, 'zones' => [] }
  write_json(dir, 'dashboard-layout.json', lay)
  wb = (JSON.parse(File.read(File.join(dir, 'wb-ids.json'))) rescue {})
  wb = {} unless wb.is_a?(Hash)
  wb['pages'] = [{ 'id' => 'pg-o', 'name' => 'Overview' }, { 'id' => 'pg-d', 'name' => 'Detail' }]
  write_json(dir, 'wb-ids.json', wb)
  seen = File.join(dir, 'tiles-seen.json')
  argv = File.join(dir, 'argv-seen.json')
  doc = vsim_doc(overall: 0.7, band: 0.5, measured: 1).merge('pass' => true)
  gate14(dir, doc, render_extra: { 'pages' => %w[pg-d] }, env_extra: { 'VSIM_TILES_COPY' => seen, 'VSIM_ARGV_COPY' => argv })
  eq(Array((JSON.parse(File.read(seen)) rescue nil)).map { |d| d['dashboard'] }, %w[Detail],
     'a single-page pass measures only the rendered dashboard')
  eq((JSON.parse(File.read(argv)) rescue []).include?('--composite-pages'), false, 'a single-page pass is not a composite')
  gate14(dir, doc, render_extra: { 'composite' => true, 'pages' => %w[pg-d pg-x] },
                   env_extra: { 'VSIM_TILES_COPY' => seen, 'VSIM_ARGV_COPY' => argv })
  args = (JSON.parse(File.read(argv)) rescue [])
  eq(args[(args.index('--composite-pages') || -2) + 1], '2',
     'a composite without its per-page PNGs still passes its page count')
  eq(Array((JSON.parse(File.read(seen)) rescue nil)).map { |d| d['dashboard'] }, %w[Overview Detail Appendix Params],
     'an unresolvable page name sends the layout as-is (visual-similarity drops emit_page:false)')
end

puts '== gate 14: exact composite geometry fails LOUD, never "0 tiles" (2026-11-10, after 2204574b) =='
def two_page_wb(dir)
  wb = (JSON.parse(File.read(File.join(dir, 'wb-ids.json'))) rescue {})
  wb = {} unless wb.is_a?(Hash)
  wb['pages'] = [{ 'id' => 'pg-o', 'name' => 'Overview' }, { 'id' => 'pg-d', 'name' => 'Detail' }]
  write_json(dir, 'wb-ids.json', wb)
end
Dir.mktmpdir('g14') do |dir|
  # the ledger says the render is a 2-page composite, but its per-page renders
  # are gone: visual-similarity can only report the tiles unmapped
  v2_workdir(dir)
  write_json(dir, 'dashboard-layout.json', two_page_layout)
  two_page_wb(dir)
  doc = vsim_doc(overall: 0.7, band: 0.5, measured: 0).merge('pass' => true, 'tiles_unmapped' => 2,
                                                              'notes' => ['per-tile blank detector NOT armed: exact page sizes were not given'])
  code, _out, err = gate14(dir, doc, render_extra: { 'composite' => true, 'pages' => %w[pg-d pg-o] })
  eq(code, 20, 'a known composite whose tiles cannot be placed FAILS gate 14 (exit 20), even on a passing floor')
  eq(err.include?('[FAIL] gate 14:') && err.include?('2-page composite but 2 tile box(es) could not be placed'), true,
     'the failure names the composite and the unplaced tiles')
  eq(err.include?('exact page sizes were not given'), true, 'the failure quotes visual-similarity\'s reason')
end
Dir.mktmpdir('g14') do |dir|
  # gate 8 picked one of the per-page renders kept beside the composite
  v2_workdir(dir)
  write_json(dir, 'dashboard-layout.json', two_page_layout)
  two_page_wb(dir)
  per_page = File.join(dir, 'rcf-pass-1-p2-pg-o.png')
  FileUtils.cp(File.join(dir, 'sigma-render.png'), per_page)
  seen = File.join(dir, 'tiles-seen.json')
  argv = File.join(dir, 'argv-seen.json')
  doc = vsim_doc(overall: 0.7, band: 0.5, measured: 1).merge('pass' => true)
  code, out, err = gate14(dir, doc, render_extra: { 'composite' => true, 'pages' => %w[pg-d pg-o] },
                                    env_extra: { 'VSIM_TILES_COPY' => seen, 'VSIM_ARGV_COPY' => argv },
                                    extra_args: ['--sigma-render', per_page])
  eq(code, 0, "a per-page render passes gate 14 (#{(out + err).lines.grep(/gate 14|FAIL/).first.to_s.strip})")
  eq(Array((JSON.parse(File.read(seen)) rescue nil)).map { |d| d['dashboard'] }, %w[Overview],
     'rcf-pass-1-p2-<page>.png is measured as page 2 (Overview) alone')
  eq((JSON.parse(File.read(argv)) rescue []).include?('--composite-pages'), false, 'a per-page render is not a composite')
end

puts '== gate 14 end-to-end: the REAL visual-similarity.py measures a 2-page workbook (tiles > 0) =='
# Synthetic Stress 4: 2-page layout + PngStack composite + the per-page renders
# fidelity-loop keeps. Page 2 renders blank, so the detector must see it.
VSIM_REAL = File.join(__dir__, 'visual-similarity.py')
E2E_PY = <<~PY
  import importlib.util, sys
  spec = importlib.util.spec_from_file_location("t", sys.argv[1]); t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
  src, tgt, d = sys.argv[2], sys.argv[3], sys.argv[4]
  healthy, blank = t.make_tiled_dashboard(), t.make_tiled_dashboard(blank=t.ALL_TILES)
  t.stack_pages([t.make_tiled_dashboard(), t.make_tiled_dashboard()]).save(src)
  t.stack_pages([healthy, blank]).save(tgt)
  healthy.save(d + "/rcf-pass-1-p1-pg-o.png"); blank.save(d + "/rcf-pass-1-p2-pg-d.png")
PY
vsim_ok = system('python3', '-c', 'import PIL, numpy', out: File::NULL, err: File::NULL)
if !vsim_ok
  puts '  skip: Pillow/numpy not importable (CI installs them for the Python job)'
else
  Dir.mktmpdir('g14e2e') do |dir|
    py = File.join(dir, 'mk.py')
    File.write(py, E2E_PY)
    v2_workdir(dir, images: lambda { |src, tgt|
      raise 'fixture images failed' unless system('python3', py, File.join(__dir__, 'test_visual_similarity_tiles.py'), src, tgt, dir)
    })
    # Test harness: the only interpolated value is this test file's own directory.
    # nosemgrep: ruby.lang.security.dangerous-subshell.dangerous-subshell
    write_json(dir, 'dashboard-layout.json', JSON.parse(`python3 -c "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('t','#{File.join(__dir__, 'test_visual_similarity_tiles.py')}');t=importlib.util.module_from_spec(s);s.loader.exec_module(t);print(json.dumps(t.layout_array('Overview','Detail')))"`))
    two_page_wb(dir)
    code, out, err = gate14(dir, vsim_doc, render_extra: { 'composite' => true, 'pages' => %w[pg-o pg-d] },
                                           env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => VSIM_REAL })
    vs = (JSON.parse(File.read(File.join(dir, 'visual-similarity.json'))) rescue {})
    eq(vs['tiles_measured'].to_i, 18, "2 pages x 9 chart tiles measured (gate exit #{code}; #{(out + err).lines.grep(/gate 14/).first.to_s.strip})")
    eq(Array(vs['tiles_blank']).length, 9, 'the blank second page is seen tile by tile')
    eq(Array(vs['tiles_blank']).all? { |n| n.start_with?('Detail: ') }, true, 'every blank tile is on page 2 (Detail)')
    eq(vs.key?('tiles_unmapped'), false, 'nothing unmapped with exact page geometry')
  end
end

if $failures.zero? then puts 'ALL PASS'; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end

# NOTE on coverage boundaries NOT tested above (documented, not faked):
#   - Gates 6/7 (layout lint / control lint): fetch the live spec; already
#     contract-tested against the libs directly in test-green-gates.rb. This
#     harness only relies on their credential-less no-op (implicit in every
#     scenario above, since SIGMA_BASE_URL/TOKEN are always forced empty and
#     none of the scenarios ever fail at gate 6 or 7).
#   - Gate 14 (visual-similarity floor): only the platform-difference exemption is
#     exercised (stub script, "gate 14" block above). Otherwise it stays an inert [SKIP] N/A in every
#     scenario above regardless of whether scripts/visual-similarity.py is
#     vendored in this copy, because no scenario supplies both a source
#     dashboard PNG and reaches this gate without exiting earlier (gate 13's
#     scenario is the only one with a source PNG, and it always exits before
#     gate 14 runs). Actually exercising a measured pass/fail would require
#     vendoring a stub script, a real python3 subprocess, and entangles with
#     gate 13's source-PNG discovery. Left untested rather than faked.
#   - Gate 9's sub-checks (attested-empty-tile cross-check, gate 9b
#     shape_match) share gate 9's exit code (11); only the base
#     "no manifest at all" path is exercised above.
