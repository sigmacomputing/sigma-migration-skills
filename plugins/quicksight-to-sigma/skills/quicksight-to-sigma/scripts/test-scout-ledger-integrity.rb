#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-scout-ledger-integrity.rb — the gap-scan gate's ScoutGate ledger must not
# trust a bare "validated" status (issue #458).
#
# Field failure: an agent blocked from the sanctioned --force path hand-wrote a
# {"status":"validated"} line into scout-ledger.jsonl for a gap it had only
# reasoned about — never probed against the live Sigma API. ScoutGate.classify
# accepted it and let the run proceed past the gate as if real verification had
# happened. This test proves the integrity fix, mirroring the resolution-EVIDENCE
# (join/lod/agg ledgers) + anchor-immutability-lock (verify-anchors W1.3) patterns:
#   (i)   a genuine scout record (live-probe evidence + signature) → :validated;
#   (ii)  a hand-written bare "validated" line (no evidence, no signature)
#         → NOT :validated (falls to :escalated → the gate still blocks);
#   (iii) an escalated row whose status is flipped to "validated" out of band
#         (signature no longer matches) → NOT :validated;
#   (iv)  a hand-written "validated" line with FORGED evidence but no valid
#         signature → NOT :validated;
#   (v)   a gap with no ledger row at all → :unscouted (unchanged);
#   (vi)  the genuine record round-trips through a JSON read → still :validated.
# Deterministic + offline (no Sigma creds / network).
#
# Usage: ruby scripts/test-scout-ledger-integrity.rb

require 'json'
require 'tmpdir'
require_relative 'lib/scout_gate'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# The evidence shape the genuine live probe records (scout-validate-and-persist.rb
# probe_evidence): the real workbook id the POST created + a hash of the API
# readback + a probe timestamp. Neutral, invented ids — no field/session data.
def genuine_evidence
  { 'workbook_id' => 'wb-abc123', 'response_sha256' => 'a' * 64,
    'phase' => 'columns', 'probed_at' => Time.now.utc.iso8601 }
end

puts 'test-scout-ledger-integrity:'

# (i) genuine scout record → validated -----------------------------------------
Dir.mktmpdir do |d|
  ScoutGate.record(d, gap_id: 'WINDOW_AVG', feature: 'WINDOW_AVG',
                      status: 'validated', evidence: genuine_evidence)
  b = ScoutGate.classify(d, ['WINDOW_AVG'])
  check(b[:validated] == ['WINDOW_AVG'] && b[:escalated].empty? && b[:unscouted].empty?,
        '(i) genuine scout record (evidence + signature) classifies as :validated')
  check(File.exist?(ScoutGate.key_path(d)), '(i) sanctioned record stamped the per-conversion signing key')
end

# (ii) hand-written bare "validated" line — no evidence, no signature -----------
Dir.mktmpdir do |d|
  File.open(ScoutGate.ledger_path(d), 'a') do |f|
    f.puts(JSON.generate('gap_id' => 'LOD_FIXED', 'feature' => 'LOD_FIXED',
                         'status' => 'validated', 'at' => Time.now.utc.iso8601))
  end
  b = ScoutGate.classify(d, ['LOD_FIXED'])
  check(b[:validated].empty? && b[:escalated] == ['LOD_FIXED'],
        '(ii) hand-written bare "validated" is NOT trusted → falls to :escalated (gate blocks)')
end

# (iii) an escalated row's status flipped to "validated" out of band -----------
Dir.mktmpdir do |d|
  ScoutGate.record(d, gap_id: 'RANK_PCT', feature: 'RANK_PCT', status: 'escalated')
  raw = File.read(ScoutGate.ledger_path(d))
  # Flip the SIGNED escalated row to validated (and bolt on plausible evidence);
  # the signature was computed over status 'escalated', so it no longer matches.
  row = JSON.parse(raw.lines.first)
  row['status'] = 'validated'
  row['evidence'] = genuine_evidence
  File.write(ScoutGate.ledger_path(d), JSON.generate(row) + "\n")
  b = ScoutGate.classify(d, ['RANK_PCT'])
  check(b[:validated].empty? && b[:escalated] == ['RANK_PCT'],
        '(iii) escalated→validated status flip breaks the signature → NOT :validated')
end

# (iv) forged evidence but no valid signature ----------------------------------
Dir.mktmpdir do |d|
  # A genuine record for a DIFFERENT gap creates the key file, so the tamperer
  # even has a key present — but cannot produce a matching signature for a row it
  # invents (Digest over the secret it does not sign with).
  ScoutGate.record(d, gap_id: 'OTHER', feature: 'OTHER',
                      status: 'validated', evidence: genuine_evidence)
  File.open(ScoutGate.ledger_path(d), 'a') do |f|
    f.puts(JSON.generate('gap_id' => 'FORGED', 'feature' => 'FORGED', 'status' => 'validated',
                         'at' => Time.now.utc.iso8601, 'evidence' => genuine_evidence,
                         'sig' => 'deadbeef' * 8))
  end
  b = ScoutGate.classify(d, %w[OTHER FORGED])
  check(b[:validated] == ['OTHER'] && b[:escalated] == ['FORGED'],
        '(iv) "validated" with forged evidence + bogus signature → NOT :validated')
end

# (v) no ledger row at all → unscouted (unchanged) -----------------------------
Dir.mktmpdir do |d|
  b = ScoutGate.classify(d, ['NEVER_RAN'])
  check(b[:unscouted] == ['NEVER_RAN'] && b[:validated].empty?,
        '(v) a gap the scout never ran for stays :unscouted')
end

# (vi) genuine record survives a JSON write→read round trip --------------------
Dir.mktmpdir do |d|
  ScoutGate.record(d, gap_id: 'PCT_TOTAL', feature: 'PCT_TOTAL',
                      status: 'validated', evidence: genuine_evidence)
  # Re-read + re-serialize with the keys in a DIFFERENT order (JSON-lines: one
  # compact object per line) as any tool might — an HONEST round trip of the SAME
  # row (signature signs semantic content, not byte order) must still verify.
  rows = File.readlines(ScoutGate.ledger_path(d)).map { |l| JSON.parse(l) }
  reordered = rows.map { |r| r.keys.sort.each_with_object({}) { |k, h| h[k] = r[k] } }
  File.write(ScoutGate.ledger_path(d), reordered.map { |r| JSON.generate(r) }.join("\n") + "\n")
  b = ScoutGate.classify(d, ['PCT_TOTAL'])
  check(b[:validated] == ['PCT_TOTAL'],
        '(vi) genuine validated row survives an honest JSON re-serialization')
end

puts
if FAILS.empty?
  puts 'ALL PASS — a hand-written/forged "validated" cannot defeat the gap-scan gate'
  exit 0
else
  puts "#{FAILS.length} FAILED"
  exit 1
end
