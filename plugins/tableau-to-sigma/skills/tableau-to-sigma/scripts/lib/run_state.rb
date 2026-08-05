# frozen_string_literal: true
#
# run_state.rb — the per-run phase LEDGER (Tier 2 sub-item of the gate-hardening).
#
# The artifact gates (png-read.json, parity-final.json, layout census, lints)
# prove the load-bearing OUTPUTS exist. This ledger proves the load-bearing
# PROCESS ran end-to-end: as the orchestrator walks each phase it stamps
# run-state.json, and the final gate (assert-run-state.rb) fails if a phase in
# the always-required chain was never entered — catching a silent shortcut (a
# re-run that reused stale artifacts, an edited orchestration that dropped a
# phase) that the output gates can miss because the output files happen to exist.
#
# Design notes:
#   - Stamps MERGE by phase key (re-stamping a phase updates it) so re-runs and
#     the two-pass PASS1/PASS2 flow accumulate into one ledger in the workdir.
#   - Conditional phases (Phase 2/3 skipped on DM-reuse) record status "skip"
#     with a reason, so the auditor distinguishes a deliberate skip from a
#     silent omission — never silently skip is the whole contract.
#   - The auditor is a NO-OP when run-state.json is absent (the hand-driven
#     manual path that never calls the orchestrator): it reports "not tracked"
#     rather than failing, mirroring the other sidecar-gated checks.
#
# run-state.json shape:
#   { "tool": "tableau-to-sigma",
#     "phases": {
#       "phase-0a": { "status": "done", "note": "gap scan", "ts": "..." },
#       "phase-2":  { "status": "skip", "note": "reused DM abc123", "ts": "..." },
#       ... } }

require 'json'
require 'time'
require 'securerandom'

module RunState
  def self.path(workdir)
    File.join(workdir, 'run-state.json')
  end

  # ── run_id (run-scoped completion sentinels) ──────────────────────────────
  # A uuid minted at each PASS-1 start and persisted in the ledger (and copied
  # into migrate-state.json when pass 1 completes). The completion sentinels
  # (parity-pending.json / phase6-success.json) carry it so "done" is scoped to
  # a specific run: a stale success marker from a PREVIOUS run id can never
  # vouch for the current one (assert-phase6-ran deletes it on failure).
  def self.run_id(workdir)
    load(workdir)['run_id']
  end

  # Mint + persist a FRESH run id (call at pass-1 start). Best-effort like
  # stamp: a ledger write must never crash the conversion. Returns the id
  # (even when persisting failed, so callers always have one).
  def self.new_run_id!(workdir)
    id = SecureRandom.uuid
    begin
      if workdir && File.directory?(workdir)
        doc = load(workdir)
        doc['run_id'] = id
        # run_started_at is stamped ONCE and never overwritten — it is the total
        # wall-clock anchor the handoff nudge measures against. A fresh run id is
        # minted at each PASS-1 start, but the FIRST pass-1 of a workdir sets the
        # clock; resumes/re-passes keep it (that is the point — the nudge tracks
        # TOTAL run age across passes, not per-context age).
        doc['run_started_at'] ||= Time.now.utc.iso8601
        File.write(path(workdir), JSON.pretty_generate(doc) + "\n")
      end
    rescue StandardError
      nil
    end
    id
  end

  def self.load(workdir)
    p = path(workdir)
    return { 'tool' => 'tableau-to-sigma', 'phases' => {} } unless File.exist?(p)
    doc = JSON.parse(File.read(p))
    doc['phases'] ||= {}
    doc
  rescue JSON::ParserError
    { 'tool' => 'tableau-to-sigma', 'phases' => {} }
  end

  # Record a phase. status: 'done' | 'skip'. Best-effort — a ledger write must
  # never crash the conversion, so failures are swallowed (the auditor treats a
  # missing stamp as "not tracked", not as a hard failure).
  def self.stamp(workdir, phase, status: 'done', note: nil)
    return unless workdir && File.directory?(workdir)
    doc = load(workdir)
    now = Time.now.utc.iso8601
    # Preserve the FIRST time this phase was entered (`first_ts`) across re-stamps
    # so a multi-pass run keeps its true earliest timestamps; `ts` tracks the
    # most-recent entry (freshness). The old code overwrote `ts` every pass, which
    # reset min(ts) each re-run and left the total-elapsed handoff nudge DEAD on
    # exactly the multi-pass runaways it exists to catch (2026-07 field failure:
    # a 131-min, ~12-pass run never nudged). run_started_at is the primary anchor;
    # first_ts is the belt-and-suspenders fallback for hand-driven stamps that
    # never minted a run id.
    existing = doc['phases'][phase.to_s]
    first_ts = (existing && existing['first_ts']) || now
    doc['run_started_at'] ||= first_ts
    doc['phases'][phase.to_s] = { 'status' => status, 'note' => note,
                                  'ts' => now, 'first_ts' => first_ts }.compact
    File.write(path(workdir), JSON.pretty_generate(doc) + "\n")
  rescue StandardError
    nil
  end

  # Total run age anchor (UTC ISO8601 string) — run_started_at when present, else
  # the earliest per-phase first_ts, else the earliest ts (legacy ledgers written
  # before first_ts existed). Returns nil when nothing is stamped yet.
  def self.started_at(workdir)
    doc = load(workdir)
    return doc['run_started_at'] if doc['run_started_at']
    phases = doc['phases'].values
    (phases.map { |p| p['first_ts'] }.compact + phases.map { |p| p['ts'] }.compact).min
  end

  def self.skip(workdir, phase, reason)
    stamp(workdir, phase, status: 'skip', note: reason)
  end

  # Record TOP-LEVEL run facts (not phases) into the ledger — e.g. the PLAN-v3
  # PR-3 scope/cost sign-off: record(dir, 'cost_estimate_acknowledged' => true,
  # 'cost_estimate_provenance' => 'auto-yes'|'stated'). Merges by key like
  # stamp; best-effort — a ledger write must never crash the conversion.
  def self.record(workdir, fields)
    return unless workdir && File.directory?(workdir)
    doc = load(workdir)
    fields.each { |k, v| doc[k.to_s] = v }
    File.write(path(workdir), JSON.pretty_generate(doc) + "\n")
  rescue StandardError
    nil
  end

  # Which of the required phase keys have NO entry at all (neither done nor
  # skip). A phase explicitly marked skip is NOT missing — that's a recorded,
  # reasoned decision. Returns [] when everything required is accounted for.
  def self.missing(workdir, required)
    phases = load(workdir)['phases']
    required.reject { |k| phases.key?(k.to_s) }
  end

  def self.tracked?(workdir)
    File.exist?(path(workdir))
  end
end
