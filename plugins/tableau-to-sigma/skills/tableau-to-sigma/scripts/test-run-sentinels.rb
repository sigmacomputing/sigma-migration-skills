#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for RUN-SCOPED completion sentinels (v4.2, P0.2).
#
# The sentinel pair (parity-pending.json / phase6-success.json, upstream #324)
# is run-scoped in v4.2: the orchestrator mints a run_id at each PASS-1 start
# (migrate-state.json / run-state.json), the markers carry it, and
# assert-phase6-ran.rb:
#   * on exit 0 stamps phase6-success.json with {run_id, waivers, …} and
#     deletes parity-pending.json;
#   * on ANY failure deletes a success marker left by a PREVIOUS run_id (a
#     stale DONE can never vouch for the current run) while keeping a
#     same-run-id success (a green run re-checked with a failing extra flag is
#     not unminted).
# parity-final.json additionally carries the off-ramp telemetry fields
# {route, manual_path_authorized, success_sentinel} (P2).
#
# Offline: drives the real assert-phase6-ran.rb in scratch workdirs against a
# LOOPBACK Sigma API stub (the live gates 3/4 FAIL CLOSED without credentials
# — field fix: a credential-less gate run must never read as passing — so the
# test serves a minimal clean workbook over 127.0.0.1 and the live gates run
# for real), plus source-level pins on the orchestrator's sentinel writes (a
# full pass-1 needs live Tableau/Sigma).
#
# Usage: ruby scripts/test-run-sentinels.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'webrick'
require_relative 'lib/blind_fixture'

DIR    = __dir__
GATE   = File.join(DIR, 'assert-phase6-ran.rb')
VC     = File.join(DIR, 'verify-complete.rb')
fails  = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# Minimal workdir that passes every default gate (mirrors test-anchors-waiver-gates).
def green_workdir(dir)
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => ['KPI', 'Trend'], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass', 'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass', 'composition_match' => 'pass', 'chart_shapes_match' => 'pass', 'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
             'agent_vision' => true }
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  BlindFixture.install(dir) # PR-9: gate 8b refuses a self-attested visual pass
end

# Loopback Sigma stub: /spec returns a one-band workbook whose layout lints
# clean; /columns returns one clean (non-error) column.
STUB_SPEC = {
  'workbookId' => 'wb-test',
  'latestDocumentVersion' => '1',
  'document' => {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [
      { 'id' => 'p0', 'name' => 'Data' },
      { 'id' => 'p1', 'name' => 'Dash' }
    ],
    'elements' => [
      { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
        'columns' => [{ 'id' => 'c0', 'name' => 'Sales', 'formula' => '[T/Sales]' }] },
      { 'id' => 'el1', 'kind' => 'bar-chart', 'name' => 'Sales by Region',
        'columns' => [{ 'id' => 'c1', 'name' => 'Sales', 'formula' => 'Sum([Master/Sales])' }] }
    ],
    'layout' => '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p0">' \
                '<Element elementId="master" gridColumn="1 / 25" gridRow="1 / 21"/></Page>' \
                '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">' \
                '<Container elementId="band1" type="grid" gridColumn="1 / 25" gridRow="1 / 10" ' \
                'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">' \
                '<Element elementId="el1" gridColumn="1 / 25" gridRow="1 / 9"/></Container></Page>'
  }
}.freeze
STUB_COLS = { 'entries' => [{ 'elementId' => 'el1', 'columnId' => 'c1', 'label' => 'Sales',
                              'type' => { 'type' => 'number' } }] }.freeze
stub = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                               Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
stub.mount_proc('/') do |req, res|
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate(req.path.end_with?('/columns') ? STUB_COLS : STUB_SPEC)
end
Thread.new { stub.start }
STUB_URL = "http://127.0.0.1:#{stub.config[:Port]}"
at_exit { stub.shutdown }

def run_gate(dir, *args)
  Open3.capture3({ 'SIGMA_BASE_URL' => STUB_URL, 'SIGMA_API_TOKEN' => 'stub-token' },
                 RbConfig.ruby, GATE, '--workdir', dir, '--workbook-id', 'wb-test', *args)
end

# ---- 1. GREEN run: success stamped with run_id + waivers; pending cleared ----
Dir.mktmpdir do |dir|
  green_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'),
             JSON.generate('workbook_id' => 'wb-test', 'run_id' => 'run-NEW', 'route' => 'orchestrated'))
  File.write(File.join(dir, 'parity-pending.json'),
             JSON.generate('workbookId' => 'wb-test', 'run_id' => 'run-NEW', 'stage' => 'pass1'))
  _out, err, st = run_gate(dir)
  check(st.success?, "green workdir → exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})", fails)
  succ = JSON.parse(File.read(File.join(dir, 'phase6-success.json')))
  check(succ['run_id'] == 'run-NEW', 'phase6-success.json carries the CURRENT run_id', fails)
  check(succ['workbookId'] == 'wb-test' && succ['gates'] == 'all-pass', 'success marker carries workbook + gates', fails)
  check(succ['waivers'] == [], 'zero-waiver green run stamps waivers=[] in the marker', fails)
  check(!File.exist?(File.join(dir, 'parity-pending.json')), 'pending marker cleared on GREEN', fails)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['route'] == 'orchestrated', 'parity-final stamped with route (P2)', fails)
  check(pf['manual_path_authorized'] == false, 'parity-final stamped with manual_path_authorized=false (P2)', fails)
  check(pf['success_sentinel'] == true, 'parity-final success_sentinel flipped true at the green exit (P2)', fails)

  # verify-complete quotes the run id under DONE
  out_vc, vc_st = Open3.capture2e(RbConfig.ruby, VC, '--workdir', dir, '--workbook-id', 'wb-test')
  check(vc_st.success? && out_vc.include?('run-NEW'), 'verify-complete DONE readout quotes the run id', fails)
  check(out_vc.include?('Quote this marker'), 'verify-complete tells the agent to quote the marker in the report', fails)
end

# ---- 2. FAILURE deletes a stale success from a PREVIOUS run_id ----------------
Dir.mktmpdir do |dir|
  # Empty workdir => gate fails early (no parity-final.json). A success marker
  # from an OLD run + a state that shows a NEW run id => the marker is stale.
  File.write(File.join(dir, 'migrate-state.json'),
             JSON.generate('workbook_id' => 'wb-test', 'run_id' => 'run-NEW'))
  File.write(File.join(dir, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-test', 'run_id' => 'run-OLD', 'gates' => 'all-pass'))
  _out, err, st = run_gate(dir)
  check(!st.success?, "gate fails on the empty workdir (got #{st.exitstatus})", fails)
  check(!File.exist?(File.join(dir, 'phase6-success.json')),
        'stale success (previous run_id) DELETED on failure', fails)
  check(err.include?('stale phase6-success.json'), 'the deletion is announced, never silent', fails)
  _out_vc, vc_st = Open3.capture2e(RbConfig.ruby, VC, '--workdir', dir)
  check(!vc_st.success?, 'verify-complete reports NOT DONE after the stale marker is gone', fails)
end

# ---- 3. FAILURE keeps a SAME-run_id success ------------------------------------
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'migrate-state.json'),
             JSON.generate('workbook_id' => 'wb-test', 'run_id' => 'run-SAME'))
  File.write(File.join(dir, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-test', 'run_id' => 'run-SAME', 'gates' => 'all-pass'))
  _out, _err, st = run_gate(dir)
  check(!st.success?, 'gate still fails on the empty workdir', fails)
  check(File.exist?(File.join(dir, 'phase6-success.json')),
        'same-run_id success KEPT on failure (a green run re-checked is not unminted)', fails)
end

# ---- 4. run-id-less converters: any failure deletes the marker (fail-closed) --
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-test', 'gates' => 'all-pass'))
  _out, _err, st = run_gate(dir)
  check(!st.success? && !File.exist?(File.join(dir, 'phase6-success.json')),
        'no run_id anywhere → failure deletes the success marker (fail-closed)', fails)
end

# ---- 5. source-level pins on the orchestrator's run-scoped writes -------------
mig = File.read(File.join(DIR, 'migrate-tableau.rb'))
check(mig.include?("RunState.new_run_id!(WORK)"), 'pass 1 mints a fresh run_id via the run-state ledger', fails)
check(mig.match?(/'run_id' => RUN_ID, 'route' => CURRENT_ROUTE/), 'migrate-state.json records run_id + route', fails)
check(mig.match?(/parity-pending\.json.*\n.*workbookId.*\n\s*'run_id' => RUN_ID/), 'parity-pending.json is run-scoped', fails)
check(mig.include?("File.delete(_succ) if File.exist?(_succ)"), 'pass 1 clears a stale success marker', fails)
check(mig.include?('verify-complete.rb --workdir'), 'pass 1 points at verify-complete as the only done-check', fails)
rs = File.read(File.join(DIR, 'lib', 'run_state.rb'))
check(rs.include?('def self.new_run_id!'), 'run_state.rb carries the run_id notion', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
