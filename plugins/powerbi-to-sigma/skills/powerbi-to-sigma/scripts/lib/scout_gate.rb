# frozen_string_literal: true
#
# Shared "run-each-time gap-scout gate" ().
#
# The guarantee: a migration may NOT proceed past its unhandled-feature gaps
# unless the gap-scout actually ran for EVERY one — either it validated a Sigma
# translation (`validated`) or it tried and could not (`escalated`). A blanket
# --force must NOT skip the scout; it may only accept gaps the scout escalated.
#
# This module is the reusable core, identical across every migration plugin:
#   - ScoutGate.record  — scout-validate-and-persist.rb appends one ledger row
#   - ScoutGate.classify — the orchestrator reads the ledger and splits the
#                          unhandled gaps into unscouted / escalated / validated
# Each plugin maps its own gap representation to a list of stable gap-id strings
# and calls classify; the gap-id naming is the plugin's business, the gate is not.
#
# INTEGRITY (issue #458). A `validated` status is the ONLY status that lets a
# feature migrate (the gap is treated as solved and its learned rule applied);
# `escalated`/`accepted` only degrade (the feature ships MISSING/flagged). So a
# `validated` row is the one an under-pressure caller is tempted to forge: the
# field case was an agent, blocked from the sanctioned --force path, hand-writing
# a bare {"status":"validated"} line for a gap it had only reasoned about, never
# probed. classify accepted it at face value. To close that hole we mirror the
# established evidence + tamper-evidence patterns already in this repo:
#   * resolution-EVIDENCE (join-plan / lod-audit / agg-semantics ledgers): a
#     resolved/validated status must carry a RECORDED evidence object, not just a
#     status string.
#   * anchor-immutability lock (verify-anchors.rb W1.3): the sanctioned writer
#     stamps a signature only it can produce, so an out-of-band edit is tamper-
#     EVIDENT (missing / mismatched signature) rather than silently trusted.
# Concretely: a `validated` row must carry (a) live-probe evidence — the real
# Sigma workbook id the probe POST created + a hash of the API readback response
# + a probe timestamp — and (b) a `sig` keyed with the per-conversion signing
# secret (scripts/lib .scout-ledger.key, created 0600 by the first sanctioned
# record). classify RE-VERIFIES the signature offline and requires the evidence;
# a `validated` row lacking either — a hand-written line, or an `escalated` row
# whose status was flipped to `validated` (its signature no longer matches) — is
# NOT counted as validated. It falls through to the `escalated` bucket, so the
# gap-scan gate still blocks / requires genuine scouting. The genuine scout path
# records the evidence + signature, so it passes unchanged. There is NO skip flag
# that reintroduces the hole.
#
# Kept dependency-free (stdlib json/time/digest/securerandom only) so it can be
# vendored into any plugin's scripts/lib/ unchanged.
require 'json'
require 'time'
require 'digest'
require 'securerandom'

module ScoutGate
  LEDGER  = 'scout-ledger.jsonl'
  # Per-conversion signing secret, written ONCE by the first sanctioned record
  # (scout-validate-and-persist.rb) and read back to verify row signatures. A
  # hand-written ledger line — one that never went through ScoutGate.record —
  # carries no signature this secret produced, so it cannot pass as `validated`.
  KEYFILE = '.scout-ledger.key'

  def self.ledger_path(workdir)
    File.join(workdir.to_s, LEDGER)
  end

  def self.key_path(workdir)
    File.join(workdir.to_s, KEYFILE)
  end

  # The sanctioned signing secret for this conversion. Created on first use with
  # owner-only perms; a concurrent creator wins the race harmlessly (we re-read).
  # nil only if the workdir is unwritable — then no row can be signed OR verified
  # as validated, which fails safe (an unsignable `validated` claim is rejected).
  def self.load_or_create_key(workdir)
    p = key_path(workdir)
    return File.read(p).strip if File.exist?(p)
    secret = SecureRandom.hex(32)
    File.open(p, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(secret) }
    secret
  rescue Errno::EEXIST
    (File.read(p).strip rescue nil)
  rescue StandardError
    nil
  end

  # Read-only key accessor for classify — NEVER creates one. If no sanctioned
  # writer ever ran (no key file), a `validated` row cannot verify → rejected.
  def self.load_key(workdir)
    p = key_path(workdir)
    return nil unless File.exist?(p)
    File.read(p).strip
  rescue StandardError
    nil
  end

  # Evidence is stored key-sorted so the signature is stable across JSON round
  # trips (write → read). We keep it a flat string→scalar map (workbook id, a
  # response hash, a probe timestamp) — exactly what the live probe can vouch for.
  def self.canonical_evidence(ev)
    return nil unless ev.is_a?(Hash) && !ev.empty?
    ev.keys.map(&:to_s).sort.each_with_object({}) { |k, h| h[k] = ev[k.to_sym] || ev[k] }
  end

  # Deterministic serialization of the row's SEMANTIC content — everything a
  # tamperer would have to change (gap_id, feature, status, timestamp, evidence).
  # `sig` itself is excluded, so the same call verifies a row that already carries
  # one.
  def self.canonical_row(row)
    JSON.generate(
      'gap_id'   => row['gap_id'].to_s,
      'feature'  => row['feature'].to_s,
      'status'   => row['status'].to_s,
      'at'       => row['at'].to_s,
      'evidence' => canonical_evidence(row['evidence'])
    )
  end

  def self.sign(secret, row)
    Digest::SHA256.hexdigest("#{secret}\n#{canonical_row(row)}")
  end

  # Does this evidence object actually reference a live probe? The sanctioned
  # writer records the real Sigma workbook id the validation POST created plus a
  # hash of the columns-readback response — suggestion #1 on #458 ("a reference
  # to an actual logged request id / response hash from the live POST"). A bare
  # or fabricated-but-empty evidence blob does not qualify.
  def self.probe_evidence?(ev)
    ev.is_a?(Hash) &&
      !ev['workbook_id'].to_s.strip.empty? &&
      !ev['response_sha256'].to_s.strip.empty?
  end

  # A ledger row counts as a genuinely VALIDATED scout result only when it is
  # marked validated, carries live-probe evidence, AND its signature verifies
  # against the per-conversion secret. This is the whole integrity check (#458).
  def self.validated_evidence?(row, secret)
    return false unless row.is_a?(Hash) && row['status'].to_s == 'validated'
    return false unless probe_evidence?(row['evidence'])
    sig = row['sig'].to_s
    return false if sig.empty? || secret.to_s.empty?
    sig == sign(secret, row)
  end

  # Append one scout result to the per-conversion ledger. Non-fatal on error —
  # a failed ledger write must never crash a scout that otherwise succeeded.
  # `evidence:` (required in practice for status 'validated') is the live-probe
  # record; every row is signed with the sanctioned per-conversion secret so an
  # out-of-band edit is tamper-evident.
  def self.record(workdir, gap_id:, feature:, status:, evidence: nil)
    return false unless workdir && Dir.exist?(workdir)
    row = { 'gap_id' => (gap_id || feature).to_s, 'feature' => feature.to_s,
            'status' => status.to_s, 'at' => Time.now.utc.iso8601 }
    ev = canonical_evidence(evidence)
    row['evidence'] = ev if ev
    secret = load_or_create_key(workdir)
    row['sig'] = sign(secret, row) if secret
    File.open(ledger_path(workdir), 'a') { |f| f.puts(JSON.generate(row)) }
    true
  rescue StandardError => e
    warn "scout-ledger write failed (non-fatal): #{e.message}"
    false
  end

  def self.read_ledger(workdir)
    p = ledger_path(workdir)
    return [] unless File.exist?(p)
    File.readlines(p).map { |l| JSON.parse(l) rescue nil }.compact
  end

  # gap_ids: Array<String> — the unhandled gaps the scout was supposed to cover.
  # Returns a Hash with three disjoint buckets of gap-ids:
  #   :unscouted — no ledger row at all (the scout never ran) → hard STOP
  #   :escalated — scouted, but no row carries VERIFIED validated evidence
  #                (tried-and-escalated, or a forged/unsigned `validated`) → --force
  #   :validated — has at least one signed, evidence-backed `validated` row
  # A `validated` row is only honored when its live-probe evidence + signature
  # verify (#458); an unverifiable one is treated as unvalidated, never trusted.
  def self.classify(workdir, gap_ids)
    secret = load_key(workdir)
    by = read_ledger(workdir).group_by { |e| e['gap_id'].to_s }
    unscouted = gap_ids.reject { |id| by[id.to_s] }
    rest      = gap_ids.select { |id| by[id.to_s] }
    validated = rest.select { |id| by[id.to_s].any? { |x| validated_evidence?(x, secret) } }
    escalated = rest - validated
    { unscouted: unscouted, escalated: escalated, validated: validated }
  end
end
