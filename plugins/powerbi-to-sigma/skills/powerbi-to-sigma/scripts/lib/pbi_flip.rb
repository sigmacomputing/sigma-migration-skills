# frozen_string_literal: true
#
# PbiFlip — PURE decision glue for migrate-powerbi.rb's Phase 6b (runtime
# control-flip proof). Plugin-local (NOT a shared/manifest file): it adapts the
# shared FlipGate verdict vocabulary to the powerbi orchestrator's inline
# Phase 6, and adds the offline "recorded-evidence" path the shared
# assert-phase6-ran.rb gate 7b has but the one-shot orchestrator needs its own
# copy of. No I/O here so every branch is unit-testable without a live workbook
# (see scripts/test-pbi-flip-gate.rb).
#
# Decision vocabulary (superset of FlipGate's :ok/:fail/:advisory/:error):
#   :ok       — >=1 control proven to filter its targets live → Phase 6b passes
#   :fail     — >=1 control wired but INERT → block (exit 21)
#   :advisory — no control auto-probeable (date/slider/unlabeled) → WARN, marker
#   :error    — probe could not run / no verdict → fail-closed (exit 21)
#   :none     — workbook has 0 controls → nothing to flip-test (pass)
#   :offline  — no live creds and no recorded evidence → UNVERIFIED (do NOT
#               hard-fail a run that never reached the live API)
module PbiFlip
  # Map a decision + info hash to the Phase 6b outcome.
  # Returns [status, summary_line, exit_code_or_nil].
  #   exit_code_or_nil: 21 blocks the migration (inert / could-not-verify);
  #                     nil continues.
  def self.outcome(decision, info = nil)
    info ||= { passes: [], fails: [], skips: [] }
    np = Array(info[:passes]).length
    nf = Array(info[:fails]).length
    ns = Array(info[:skips]).length
    case decision
    when :ok       then [:ok,       "OK — #{np} control(s) proven live", nil]
    when :fail     then [:fail,     "FAIL — #{nf} inert control(s)", 21]
    when :advisory then [:advisory, "UNVERIFIED — #{ns} un-probeable control(s)", nil]
    when :error    then [:error,    'FAIL — probe could not verify control wiring', 21]
    when :none     then [:none,     'OK — no controls to flip-test', nil]
    when :offline  then [:offline,  'UNVERIFIED — offline (no SIGMA creds), no recorded flip evidence', nil]
    else                [:unknown,  'UNVERIFIED', nil]
    end
  end

  # Decision from a RECORDED probe-results.json array (offline / no-creds path).
  # Same shape FlipGate returns: [decision, info]. FAIL beats PASS (a recorded
  # inert control is a real defect); empty/absent → :offline (UNVERIFIED).
  def self.recorded(results)
    rows   = results.is_a?(Array) ? results : []
    fails  = rows.select { |r| r.is_a?(Hash) && r['result'].to_s == 'FAIL' }
    passes = rows.select { |r| r.is_a?(Hash) && r['result'].to_s == 'PASS' }
    info = {
      passes: passes.map { |r| r['control'] },
      fails:  fails.map  { |r| [r['control'], r['note']] },
      skips:  []
    }
    decision =
      if rows.empty?    then :offline
      elsif fails.any?  then :fail
      elsif passes.any? then :ok
      else :offline
      end
    [decision, info]
  end
end
