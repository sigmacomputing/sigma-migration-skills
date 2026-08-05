#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression tests for assert-phase6-ran.rb's evidence-ledger substrate
# (PLAN-v4 E3.1), the #7 dedup slices inside the gate run, and E5.11's
# kind-parity ledger/census wiring:
#
#   * every terminating verdict lands in <workdir>/evidence-ledger.jsonl —
#     waived gates (record_waiver hook), failing gates (exit-code contract →
#     EXIT_GATE_MAP), and the terminal run-summary entry with the PR-14
#     verdict;
#   * gate 21 divergences land in the ledger AND stamp a kind_parity census
#     summary into parity-final.json;
#   * ONE live spec GET serves gates 4/6/7/7b (the #7 in-run dedup);
#   * gate 7b accepts fresh recorded RAW probe evidence — age-, version-, and
#     sha-checked — and RECOMPUTES the verdict from the raw rows (both
#     directions: recorded PASS rows accept, recorded FAIL rows still fail);
#     tampered bytes or a stale version key are refused and the live probe
#     re-runs (the #7 red line: recorded verdicts are never consumed); the
#     freshness window anchors on the ORIGINAL collection entry — an
#     acceptance run's recorded_reuse re-append never resets the age bound
#     (anti-chaining), and a fresh original still accepts when reuse entries
#     exist (no false stop).
#
# Live gates are served by a tiny in-process TCP HTTP stub (no network).
# Usage:  ruby scripts/test-evidence-gates.rb
require 'json'
require 'socket'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'digest'
require_relative 'lib/blind_fixture'
require_relative 'lib/evidence_ledger'

SCRIPT = File.join(__dir__, 'assert-phase6-ran.rb')

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def base_workdir(dir, per_tile: BlindFixture::DEFAULT_TILES)
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => ['KPI', 'Trend'], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass',
             'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass',
                                    'composition_match' => 'pass', 'chart_shapes_match' => 'pass',
                                    'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
             'agent_vision' => true }
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  BlindFixture.install(dir, per_tile: per_tile)
end

def run_gate(dir, *args, env: {})
  out, err, st = Open3.capture3({ 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }.merge(env),
                                RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
  # capture3 strings inherit the parent locale; force UTF-8 so assertions over
  # the gate's em-dash prose never raise Encoding::CompatibilityError.
  [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), st]
end

def ledger(dir)
  p = File.join(dir, 'evidence-ledger.jsonl')
  File.exist?(p) ? File.readlines(p).map { |l| JSON.parse(l) rescue nil }.compact : []
end

# ---- A. offline: terminal summary + waive + fail entries ---------------------
puts '-- ledger: success summary / waived gate / failing gate --'
Dir.mktmpdir do |dir|
  base_workdir(dir)
  _o, _e, st = run_gate(dir)
  check(st.success?, "clean offline run exits 0 (got #{st.exitstatus})")
  entries = ledger(dir)
  summary = entries.find { |e| e['gate'] == 'phase6-gates' }
  check(!summary.nil?, 'terminal run-summary entry appended')
  check(summary && summary['verdict'] == 'GREEN' && summary['evidence_kind'] == 'gate-summary',
        "summary carries the PR-14 verdict (got #{summary && summary['verdict']})")
  check(summary && summary['evidence_key'] =~ /\Awb:.*@v/ && summary['at'] =~ /Z\z/,
        'summary is version-keyed and timestamped')
  check(entries.none? { |e| e['verdict'] == 'fail' }, 'no fail entries on a clean run')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  _o, _e, st = run_gate(dir, '--skip-orphan-check', 'fixture reason')
  check(st.success?, "waived run still exits 0 (got #{st.exitstatus})")
  w = ledger(dir).find { |e| e['verdict'] == 'waived' }
  check(w && w['gate'] == '2' && w['evidence_kind'] == 'waiver' && w['evidence_path'] == 'waivers.json',
        'waived gate 2 lands in the ledger with the waiver pointer')
  check(w && w['detail'] && w['detail']['reason'] == 'fixture reason', 'waiver reason recorded')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  Dir.mkdir(File.join(dir, 'views'))
  File.binwrite(File.join(dir, 'views', 'dash.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 100))
  _o, _e, st = run_gate(dir) # source PNG + no source-anchors.json → gate 13
  check(st.exitstatus == 18, "anchors gate fails (got #{st.exitstatus})")
  f = ledger(dir).find { |e| e['verdict'] == 'fail' }
  check(f && f['gate'] == '13' && f['evidence_kind'] == 'gate-exit' && f['detail']['exit'] == 18,
        'failing exit maps to its gate in the ledger (13 ← exit 18)')
  check(ledger(dir).none? { |e| e['gate'] == 'phase6-gates' }, 'no run-summary entry on a failed run')
end

# ---- B. gate 21: divergence → ledger + kind_parity census stamp --------------
puts '-- gate 21: kind-parity divergences land in ledger + census --'
KP_READBACK_BAR = { 'workbookId' => 'wb-kp', 'latestDocumentVersion' => '3',
                    'pages' => [{ 'id' => 'pg1', 'elements' => [
                      { 'id' => 'el-1', 'name' => 'Trend', 'kind' => 'bar-chart' }
                    ] }] }.freeze
Dir.mktmpdir do |dir|
  base_workdir(dir, per_tile: [{ 'position' => 'r1c1', 'source_family' => 'line', 'target_family' => 'bar' }])
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(KP_READBACK_BAR))
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(
               'verified' => true, 'tiles' => [{ 'title' => 'Trend', 'kind' => 'line-chart' }]))
  _o, err, st = run_gate(dir)
  check(st.exitstatus == 28, "png-read line vs built bar → exit 28 (got #{st.exitstatus})")
  check(err.include?("expected family 'line'") && err.include?("built 'bar'"), 'failure names the divergence')
  div = ledger(dir).find { |e| e['gate'] == '21' && e['verdict'] == 'diverged' }
  check(div && div['evidence_kind'] == 'kind-parity' && div['detail']['tile'] == 'Trend' &&
        div['detail']['expected_family'] == 'line' && div['detail']['built_family'] == ['bar'],
        'per-tile divergence entry lands in the evidence ledger')
  check(div && div['evidence_key'] == 'wb:wb-kp@v3', 'divergence entry is version-keyed off the readback')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['kind_parity'] && pf['kind_parity']['verdict'] == 'fail' &&
        pf['kind_parity']['mismatched'] == [{ 'tile' => 'Trend', 'expected_family' => 'line',
                                              'built_family' => ['bar'], 'readback_kinds' => ['bar-chart'] }],
        'kind_parity census summary stamped into parity-final.json')
end

Dir.mktmpdir do |dir|
  base_workdir(dir, per_tile: [{ 'position' => 'r1c1', 'source_family' => 'line', 'target_family' => 'line' }])
  rb = JSON.parse(JSON.generate(KP_READBACK_BAR))
  rb['pages'][0]['elements'][0]['kind'] = 'line-chart'
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(rb))
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(
               'verified' => true, 'tiles' => [{ 'title' => 'Trend', 'kind' => 'line-chart' }]))
  out, _e, st = run_gate(dir)
  check(st.success?, "matching kinds pass (got #{st.exitstatus})")
  check(out.include?('gate 21') && out.include?('1 matched'), 'gate 21 reports the match')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['kind_parity'] && pf['kind_parity']['verdict'] == 'pass' && pf['kind_parity']['matched'] == 1,
        'kind_parity census stamped pass')
  ok21 = ledger(dir).find { |e| e['gate'] == '21' && e['verdict'] == 'pass' }
  check(!ok21.nil?, 'gate 21 pass entry appended')
end

# ---- C. live: one spec GET + gate 7b recorded-RAW acceptance ----------------
LIVE_SPEC = {
  'workbookId' => 'wb-7b', 'latestDocumentVersion' => '7',
  'layout' => '<Layout><Page id="pg1"><LayoutElement elementId="el-chart" gridColumn="1 / 13"/>' \
              '<LayoutElement elementId="el-ctl" gridColumn="13 / 25"/></Page></Layout>',
  'pages' => [{ 'id' => 'pg1', 'name' => 'Overview', 'elements' => [
    { 'id' => 'el-chart', 'kind' => 'bar-chart', 'name' => 'Region Chart',
      'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v', 'name' => 'Revenue' }] },
    { 'id' => 'el-ctl', 'kind' => 'control', 'controlId' => 'ctl-1', 'name' => 'Region Filter',
      'controlType' => 'list-values',
      'filters' => [{ 'source' => { 'elementId' => 'el-chart' }, 'columnId' => 'c-r' }] }
  ] }]
}.freeze

def start_stub(counters)
  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  thr = Thread.new do
    loop do
      client = begin
        server.accept
      rescue StandardError
        break
      end
      Thread.new(client) do |c|
        begin
          # Refuse-fast contract (CI 120s-cap hang, 2026-07). The refusal-path
          # tests below force a live re-probe: the gate spawns
          # probe-controls.rb, whose Sigma.request (lib/sigma_rest.rb)
          # hardcodes use_ssl: true — so that child speaks TLS at this
          # plaintext stub. A line-oriented gets/drain over the binary
          # ClientHello happens to terminate on macOS/LibreSSL layouts (a
          # structural "\x0a\x00\x0a" yields a blank-stripping "line" → 404 →
          # instant client SSLError) but under Linux/OpenSSL 3 layouts no such
          # line exists (~0.1% of hellos, random bytes only), so the stub
          # blocked in gets while the client sat in its handshake until
          # Net::HTTP's 60 s open_timeout — three refusal tests
          # (tampered / stale-version / chaining) × 60 s blew the 120 s
          # per-file CI cap. An HTTP request line always starts with an
          # uppercase ASCII method byte; anything else (TLS records start
          # 0x16) is closed on byte one, failing the child's handshake
          # instantly on every platform — same probe failure, same exit-21
          # path, no timing dependence.
          first = c.getbyte
          next unless first && first.between?(0x41, 0x5A)
          req = first.chr + c.gets.to_s
          # Match on the query-stripped path: the gate's columns audit is
          # paginated (limit=1000 + nextPage), so the request line arrives as
          # `/columns?limit=1000` — the query string must not defeat the match
          # and misclassify the read as an unexpected live call.
          path = req.split(' ')[1].to_s.split('?').first.to_s
          while (h = c.gets) && h.strip != ''; end # drain headers
          body =
            if path.end_with?('/spec')
              counters[:spec] += 1
              JSON.generate(LIVE_SPEC)
            elsif path.end_with?('/columns')
              JSON.generate('entries' => [])
            end
          if body
            c.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                    "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          else
            counters[:other] += 1
            c.write("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
          end
        rescue StandardError
          nil
        ensure
          begin
            c.close
          rescue StandardError
            nil
          end
        end
      end
    end
  end
  [server, thr, port]
end

def live_workdir(dir, probe_rows, probe_rc, key_version: '7', recorded_at: Time.now)
  base_workdir(dir, per_tile: [{ 'position' => 'r1c1', 'source_family' => 'bar', 'target_family' => 'bar' }])
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('workbookId' => 'wb-7b'))
  File.write(File.join(dir, 'migrate-state.json'),
             JSON.generate('run_id' => 'r1', 'control_flip_required' => true))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(LIVE_SPEC))
  Dir.mkdir(File.join(dir, 'probe-controls'))
  results_path = File.join(dir, 'probe-controls', 'probe-results.json')
  File.write(results_path, JSON.pretty_generate(probe_rows))
  # A6 (wave-1 review): probe_rc in the ledger detail is AUDIT metadata only —
  # the acceptance path derives rc from the sha-verified rows. probe_rc: nil
  # here means "no recorded rc at all" (must still accept).
  detail = { 'check_leaks' => false }
  detail['probe_rc'] = probe_rc unless probe_rc.nil?
  EvidenceLedger.append(dir, gate: '7b', verdict: 'recorded-fixture',
                        evidence_kind: 'probe-results',
                        evidence_path: 'probe-controls/probe-results.json',
                        evidence_key: "wb:wb-7b@v#{key_version}",
                        evidence_sha256: EvidenceLedger.sha256_file(results_path),
                        detail: detail,
                        at: recorded_at)
  results_path
end

# A prior ACCEPTANCE run's re-append: same raw pointer, recomputed verdict,
# detail.recorded_reuse=true, at:=its own (later) run time.
def append_reuse_entry(dir, results_path, at:)
  EvidenceLedger.append(dir, gate: '7b', verdict: 'ok',
                        evidence_kind: 'probe-results',
                        evidence_path: 'probe-controls/probe-results.json',
                        evidence_key: 'wb:wb-7b@v7',
                        evidence_sha256: EvidenceLedger.sha256_file(results_path),
                        detail: { 'probe_rc' => 0, 'check_leaks' => false, 'recorded_reuse' => true },
                        at: at)
end

def run_live(dir, port)
  run_gate(dir, '--skip-layout-lint', 'fixture spec (gate 6 out of scope here)',
           env: { 'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}", 'SIGMA_API_TOKEN' => 'stub-token' })
end

puts '-- gate 7b: fresh recorded FAIL rows → verdict recomputed → still fails --'
Dir.mktmpdir do |dir|
  counters = { spec: 0, other: 0 }
  server, thr, port = start_stub(counters)
  begin
    live_workdir(dir, [{ 'control' => 'ctl-1', 'result' => 'FAIL', 'note' => 'inert on flip' }], 1)
    out, err, st = run_live(dir, port)
    check(st.exitstatus == 21, "recorded FAIL rows → recomputed :fail → exit 21 (got #{st.exitstatus})")
    check(out.include?('recorded RAW probe evidence accepted'), 'acceptance NOTE printed (age/version/sha checked)')
    check(out.include?('verdict recomputed — not reused'), 'the NOTE states the recompute contract')
    check(err.include?('INERT'), 'the recomputed failure names the inert control')
    e7b = ledger(dir).reverse.find { |e| e['gate'] == '7b' && e['evidence_kind'] == 'probe-results' }
    check(e7b && e7b['verdict'] == 'fail' && e7b['detail']['recorded_reuse'] == true,
          'ledger records the recomputed verdict with recorded_reuse=true')
    check(counters[:spec] == 1, "ONE live spec GET served gates 4/7/7b (got #{counters[:spec]})")
    check(counters[:other].zero?, 'no probe subprocess ran (no unexpected live calls)')
  ensure
    server.close
    thr.kill
  end
end

puts '-- gate 7b: fresh recorded PASS rows → accepted, run continues to GREEN --'
Dir.mktmpdir do |dir|
  counters = { spec: 0, other: 0 }
  server, thr, port = start_stub(counters)
  begin
    live_workdir(dir, [{ 'control' => 'ctl-1', 'result' => 'PASS', 'note' => 'export changed' }], 0)
    out, err, st = run_live(dir, port)
    check(st.success?, "recorded PASS rows → recomputed :ok → run completes (got #{st.exitstatus}: #{err.lines.first(3).join(' ').strip[0, 160]})")
    check(out.include?('recorded RAW probe evidence accepted'), 'acceptance NOTE printed')
    check(out.include?('1 control(s) proven live'), 'the OK line comes from the recomputed decision')
    e7b = ledger(dir).reverse.find { |e| e['gate'] == '7b' && e['evidence_kind'] == 'probe-results' && e['verdict'] == 'ok' }
    check(e7b && e7b['detail']['recorded_reuse'] == true, 'ledger 7b entry: verdict ok, recorded_reuse=true')
    check(counters[:spec] == 1, "still exactly ONE live spec GET for the whole gate run (got #{counters[:spec]})")
    check(counters[:other].zero?, 'zero export/flip calls — the recorded raw evidence replaced the re-probe')
    summary = ledger(dir).find { |e| e['gate'] == 'phase6-gates' }
    check(summary && %w[GREEN YELLOW].include?(summary['verdict']),
          "run-summary appended on the live path (got #{summary && summary['verdict']})")
  ensure
    server.close
    thr.kill
  end
end

# A6 (wave-1 review): the ledger's recorded probe_rc was the ONE datum in the
# recorded-evidence path not covered by the probe-results.json sha. rc is now
# DERIVED from the sha-verified rows (FlipGate.derive_rc) — a missing or even
# LYING recorded rc changes nothing.
puts '-- gate 7b (A6): recorded rc absent → rows alone accept (rc derived, not consumed) --'
Dir.mktmpdir do |dir|
  counters = { spec: 0, other: 0 }
  server, thr, port = start_stub(counters)
  begin
    live_workdir(dir, [{ 'control' => 'ctl-1', 'result' => 'PASS', 'note' => 'export changed' }], nil)
    out, err, st = run_live(dir, port)
    check(st.success?, "no recorded probe_rc → rows still accepted → run completes (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip[0, 120]})")
    check(out.include?('recorded RAW probe evidence accepted'), 'acceptance NOTE printed without any recorded rc')
    check(out.include?('1 control(s) proven live'), 'verdict recomputed from the sha-bound rows alone')
    check(counters[:other].zero?, 'zero export/flip calls — no needless re-probe')
  ensure
    server.close
    thr.kill
  end
end

puts '-- gate 7b (A6): recorded rc LIES (says 2/advisory) → sha-bound FAIL rows still fail --'
Dir.mktmpdir do |dir|
  counters = { spec: 0, other: 0 }
  server, thr, port = start_stub(counters)
  begin
    # A forged/buggy detail rc claiming "nothing probed" must not soften the
    # verdict: the FAIL rows are sha-verified — the derived rc (1) wins.
    live_workdir(dir, [{ 'control' => 'ctl-1', 'result' => 'FAIL', 'note' => 'inert on flip' }], 2)
    out, err, st = run_live(dir, port)
    check(st.exitstatus == 21, "derived rc from FAIL rows → exit 21 despite recorded rc=2 (got #{st.exitstatus})")
    check(out.include?('recorded RAW probe evidence accepted'), 'evidence accepted (sha/version/age all valid)')
    check(err.include?('INERT'), 'the recomputed failure names the inert control')
  ensure
    server.close
    thr.kill
  end
end

# FlipGate.derive_rc unit contract — mirrors probe-controls.rb's exit logic.
puts '-- FlipGate.derive_rc: rows → rc mapping mirrors the probe exit codes --'
require_relative 'lib/flip_gate'
check(FlipGate.derive_rc([{ 'control' => 'c', 'result' => 'PASS' }]) == 0, 'PASS rows → 0')
check(FlipGate.derive_rc([{ 'control' => 'c', 'result' => 'PASS' },
                          { 'control' => 'd', 'result' => 'FAIL' }]) == 1, 'any FAIL row → 1')
check(FlipGate.derive_rc([{ 'control' => 'c', 'result' => 'SKIP' }]) == 2, 'all-SKIP → 2 (nothing probed)')
check(FlipGate.derive_rc([]) == 2 && FlipGate.derive_rc(nil) == 2, 'empty/nil rows → 2 (ambiguous → advisory → live re-probe)')
check(FlipGate.decide(FlipGate.derive_rc([{ 'result' => 'SKIP' }]), [{ 'result' => 'SKIP' }]).first == :advisory,
      'derived rc keeps FlipGate.decide semantics (all-SKIP → :advisory, never a silent pass)')

puts '-- gate 7b: tampered raw evidence → REFUSED (sha) → live re-probe attempted --'
Dir.mktmpdir do |dir|
  counters = { spec: 0, other: 0 }
  server, thr, port = start_stub(counters)
  begin
    results_path = live_workdir(dir, [{ 'control' => 'ctl-1', 'result' => 'PASS', 'note' => 'export changed' }], 0)
    # Tamper AFTER the ledger recorded the sha — bytes no longer match.
    File.write(results_path, JSON.pretty_generate(
                 [{ 'control' => 'ctl-1', 'result' => 'PASS', 'note' => 'export changed' },
                  { 'control' => 'ctl-2', 'result' => 'PASS', 'note' => 'planted' }]))
    out, err, st = run_live(dir, port)
    check(st.exitstatus == 21, "tampered evidence is never accepted (got #{st.exitstatus})")
    check(!out.include?('recorded RAW probe evidence accepted'), 'no acceptance NOTE on sha mismatch')
    check(err.include?('could not verify the wiring'), 'the gate demanded a real re-probe (which failed against the stub)')
  ensure
    server.close
    thr.kill
  end
end

puts '-- gate 7b: stale version key → REFUSED → live re-probe attempted --'
Dir.mktmpdir do |dir|
  counters = { spec: 0, other: 0 }
  server, thr, port = start_stub(counters)
  begin
    live_workdir(dir, [{ 'control' => 'ctl-1', 'result' => 'PASS', 'note' => 'export changed' }], 0,
                 key_version: '6') # live is v7 — the workbook changed since
    out, err, st = run_live(dir, port)
    check(st.exitstatus == 21, "stale-version evidence is never accepted (got #{st.exitstatus})")
    check(!out.include?('recorded RAW probe evidence accepted'), 'no acceptance NOTE on version mismatch')
    check(err.include?('could not verify the wiring'), 'the gate demanded a real re-probe')
  ensure
    server.close
    thr.kill
  end
end

# The #7d anti-chaining rule (fix-pass trip test): every acceptance run
# re-appends its recomputed verdict with recorded_reuse=true and at:=now. The
# freshness window must anchor on the ORIGINAL collection entry — otherwise
# re-runs <30 min apart each reset the B4 age bound and one probe's evidence
# extends indefinitely under an unchanged doc version (live-warehouse drift).
puts '-- gate 7b: CHAINING refused — a fresh reuse re-append never resets the age anchor --'
Dir.mktmpdir do |dir|
  counters = { spec: 0, other: 0 }
  server, thr, port = start_stub(counters)
  begin
    results_path = live_workdir(dir, [{ 'control' => 'ctl-1', 'result' => 'PASS', 'note' => 'export changed' }], 0,
                                recorded_at: Time.now - (40 * 60)) # original probe: 40 min old (> 30-min bound)
    append_reuse_entry(dir, results_path, at: Time.now - (15 * 60)) # prior acceptance run: 15 min old
    out, err, st = run_live(dir, port)
    check(st.exitstatus == 21, "40-min-old original + 15-min-old reuse entry → REFUSED, re-probe demanded (got #{st.exitstatus})")
    check(!out.include?('recorded RAW probe evidence accepted'),
          'no acceptance NOTE — the reuse re-append is never the age anchor')
    check(err.include?('could not verify the wiring'), 'the gate demanded a real re-probe')
  ensure
    server.close
    thr.kill
  end
end

# No-false-trip half (≤5% false-stop budget): reuse entries in the ledger must
# not make a GENUINELY fresh original refusable — acceptance still happens.
puts '-- gate 7b: fresh original + reuse re-append → still accepted (no false stop) --'
Dir.mktmpdir do |dir|
  counters = { spec: 0, other: 0 }
  server, thr, port = start_stub(counters)
  begin
    results_path = live_workdir(dir, [{ 'control' => 'ctl-1', 'result' => 'PASS', 'note' => 'export changed' }], 0,
                                recorded_at: Time.now - (5 * 60)) # original probe: 5 min old (fresh)
    append_reuse_entry(dir, results_path, at: Time.now - (2 * 60))
    out, _err, st = run_live(dir, port)
    check(st.success?, "fresh original + reuse audit entry → accepted, run completes (got #{st.exitstatus})")
    check(out.include?('recorded RAW probe evidence accepted'),
          'acceptance anchored on the fresh ORIGINAL — reuse entries stay audit-only')
    check(counters[:other].zero?, 'zero export/flip calls — no needless re-probe (false-stop budget held)')
  ensure
    server.close
    thr.kill
  end
end

puts
if $fails.empty?
  puts 'ALL PASS — evidence ledger gates (E3.1 substrate + #7 recorded-raw acceptance + E5.11 wiring)'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
