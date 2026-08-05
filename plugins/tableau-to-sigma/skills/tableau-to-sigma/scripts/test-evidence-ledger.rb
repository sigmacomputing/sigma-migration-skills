#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit tests for lib/evidence_ledger.rb (PLAN-v4 E3.1) — the append-only
# evidence substrate + the #7 recorded-RAW-evidence acceptance rules:
#
#   * append/read round-trip, append-only ordering, malformed-line tolerance;
#   * strict version-keyed identity (.key) — unknown versions render "v?";
#   * fresh? (the ONLY reuse question the lib answers):
#       - same strict key + young + sha-bound          → true
#       - version mismatch / unknown version ("v?")    → false (fail-closed)
#       - stale (past max_age_s) / future-dated        → false
#       - raw artifact bytes changed since recording   → false (sha binding)
#       - VERDICT-BLIND: freshness never depends on the recorded verdict —
#         the red line is enforced by giving callers no verdict answer at all.
#
# Usage:  ruby scripts/test-evidence-ledger.rb
require 'json'
require 'tmpdir'
require 'time'
require_relative 'lib/evidence_ledger'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '-- append / read round-trip + append-only --'
Dir.mktmpdir do |dir|
  e1 = EvidenceLedger.append(dir, gate: '13', verdict: 'fail',
                             evidence_kind: 'anchors-verdict',
                             evidence_path: 'anchors-verdict.json',
                             evidence_key: EvidenceLedger.key(workbook_id: 'wb1', doc_version: 3),
                             detail: { 'missing' => %w[a1 a2] })
  e2 = EvidenceLedger.append(dir, gate: '13', verdict: 'pass',
                             evidence_kind: 'anchors-verdict',
                             evidence_path: 'anchors-verdict.json',
                             evidence_key: EvidenceLedger.key(workbook_id: 'wb1', doc_version: 4))
  check(e1 && e2, 'append returns the entry', fails)
  entries = EvidenceLedger.read(dir)
  check(entries.length == 2, "both entries read back (got #{entries.length})", fails)
  check(entries[0]['verdict'] == 'fail' && entries[1]['verdict'] == 'pass',
        'order preserved (append-only, oldest first)', fails)
  check(entries[0]['evidence_key'] == 'wb:wb1@v3' && entries[1]['evidence_key'] == 'wb:wb1@v4',
        'strict version keys recorded', fails)
  check(entries[0]['detail'] == { 'missing' => %w[a1 a2] }, 'detail round-trips', fails)
  check(entries.all? { |e| e['at'] =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/ },
        'every entry carries an ISO8601 UTC at', fails)
  latest = EvidenceLedger.latest(dir, gate: '13')
  check(latest && latest['verdict'] == 'pass', 'latest() returns the newest entry for the gate', fails)

  # Malformed-line tolerance: a torn write must not brick the substrate.
  File.open(EvidenceLedger.path(dir), 'a') { |f| f.puts('{"gate": "13", TORN') }
  EvidenceLedger.append(dir, gate: '21', verdict: 'pass')
  entries, skipped = EvidenceLedger.read_with_skips(dir)
  check(entries.length == 3 && skipped == 1,
        "malformed line skipped + counted, later lines still read (#{entries.length} entries, #{skipped} skipped)", fails)
end

puts '-- key: strict version identity --'
check(EvidenceLedger.key(workbook_id: 'wbX', doc_version: 12) == 'wb:wbX@v12', 'wb-level key', fails)
check(EvidenceLedger.key(workbook_id: 'wbX', doc_version: 12, element_id: 'el-1') == 'wb:wbX@v12/el:el-1',
      'element-scoped key', fails)
check(EvidenceLedger.key(workbook_id: 'wbX', doc_version: nil) == 'wb:wbX@v?',
      'unknown version renders v? (which fresh? refuses)', fails)

puts '-- fresh?: the recorded-RAW-evidence acceptance rules (#7d) --'
Dir.mktmpdir do |dir|
  raw = File.join(dir, 'probe-controls')
  Dir.mkdir(raw)
  raw_path = File.join(raw, 'probe-results.json')
  File.write(raw_path, JSON.pretty_generate([{ 'control' => 'c1', 'result' => 'PASS' }]))
  k7 = EvidenceLedger.key(workbook_id: 'wb1', doc_version: 7)
  entry = EvidenceLedger.append(dir, gate: '7b', verdict: 'ok',
                                evidence_kind: 'probe-results',
                                evidence_path: 'probe-controls/probe-results.json',
                                evidence_key: k7,
                                evidence_sha256: EvidenceLedger.sha256_file(raw_path))
  check(EvidenceLedger.fresh?(entry, evidence_key: k7, workdir: dir),
        'same key + young + sha-bound → fresh', fails)
  check(!EvidenceLedger.fresh?(entry, evidence_key: EvidenceLedger.key(workbook_id: 'wb1', doc_version: 8), workdir: dir),
        'version bumped (any new POST/PUT) → NOT fresh', fails)
  check(!EvidenceLedger.fresh?(entry, evidence_key: EvidenceLedger.key(workbook_id: 'wb2', doc_version: 7), workdir: dir),
        'different workbook → NOT fresh', fails)
  check(!EvidenceLedger.fresh?(entry, evidence_key: EvidenceLedger.key(workbook_id: 'wb1', doc_version: nil), workdir: dir),
        'caller-side unknown version (v?) → NOT fresh (fail-closed)', fails)
  unkeyed = entry.merge('evidence_key' => 'wb:wb1@v?')
  check(!EvidenceLedger.fresh?(unkeyed, evidence_key: 'wb:wb1@v?', workdir: dir),
        'recorded-side unknown version (v?) → NOT fresh even on literal match', fails)
  check(!EvidenceLedger.fresh?(entry, evidence_key: k7, workdir: dir,
                               now: Time.now + EvidenceLedger::DEFAULT_MAX_AGE_S + 60),
        'older than max_age_s → NOT fresh (re-collect, never trust stale)', fails)
  check(!EvidenceLedger.fresh?(entry.merge('at' => (Time.now + 3600).utc.strftime('%Y-%m-%dT%H:%M:%SZ')),
                               evidence_key: k7, workdir: dir),
        'future-dated entry → NOT fresh (clock tampering fails closed)', fails)

  # sha binding: change the RAW artifact after recording → refuse.
  File.write(raw_path, JSON.pretty_generate([{ 'control' => 'c1', 'result' => 'FAIL' }]))
  check(!EvidenceLedger.fresh?(entry, evidence_key: k7, workdir: dir),
        'raw artifact bytes changed since recording → NOT fresh (sha binding)', fails)
  File.write(raw_path, JSON.pretty_generate([{ 'control' => 'c1', 'result' => 'PASS' }]))

  # VERDICT-BLINDNESS (the red line): freshness is identical for a recorded
  # fail — the lib vouches for raw-artifact identity only; it exposes NO API
  # that answers "did this gate pass?" so a verdict can never be reused.
  fail_entry = entry.merge('verdict' => 'fail')
  check(EvidenceLedger.fresh?(fail_entry, evidence_key: k7, workdir: dir) ==
        EvidenceLedger.fresh?(entry, evidence_key: k7, workdir: dir),
        'fresh? is verdict-blind (raw identity only — verdicts recomputed by callers)', fails)
  check(!EvidenceLedger.respond_to?(:verdict) && !EvidenceLedger.respond_to?(:passed?),
        'no verdict-reuse API exists on the module', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — evidence ledger (append-only substrate + raw-evidence acceptance rules)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
