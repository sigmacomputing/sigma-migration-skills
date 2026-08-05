# frozen_string_literal: true
#
# fast_path.rb — routing predicate for migrate-tableau.rb's FAST PATH
# (--reuse-dm <id> + --wb-spec <path>), plus the BOM-tolerant JSON reader for
# agent/tool-authored workdir files.
#
# WHY: the exit-4 handoff tells the agent to author wb-spec.json and re-run with
# `--reuse-dm <dm_id> --wb-spec <path>`. Before this module, that re-run re-paid
# the FULL Tableau discovery pipeline and re-raised the decisions checkpoint
# (exit 10) whose questions the agent had already answered when it authored the
# spec. The fast path skips straight to: DM readback → __DM_ID__/__DM_ELEMENT__
# substitution → validate → preflight → workbook POST/PUT → layout → parity
# plan → exit 12.
#
# decide() is a PURE function — no filesystem, no network; the caller probes
# artifact presence and passes it in — so the routing is unit-testable offline
# (scripts/test-fastpath-flags.rb).

require 'json'

module FastPath
  module_function

  # Read + JSON.parse a workdir file that an AGENT or an external tool may have
  # authored. PowerShell's `Set-Content -Encoding UTF8` prepends a UTF-8 BOM,
  # which plain JSON.parse rejects ("unexpected token") — Ruby's 'bom|utf-8'
  # external-encoding mode strips it natively, so no manual gsub is needed.
  # Use this for agent/tool-authored inputs (wb-spec, dm-spec, plans); files the
  # orchestrator writes itself never carry a BOM and don't need it.
  def read_json_utf8(path)
    JSON.parse(File.read(path, encoding: 'bom|utf-8'))
  end

  # Routing decision for a pass-1 run.
  #
  #   reuse_dm  : nil | :recommended | '<dataModelId>'  (--reuse-dm)
  #   wb_spec   : nil | '<path>'                        (--wb-spec)
  #   dm_spec   : nil | '<path>'                        (--dm-spec)
  #   finalize  : true when --finalize (pass 2 resumes from state; never fast)
  #   yes       : --yes
  #   artifacts : { '<artifact label>' => present?, ... } — the caller's probe
  #               of the discovery artifacts layout/parity reuse.
  #
  # Returns { route: :fast | :full,
  #           degraded: [<missing artifact label>, ...],
  #           reason: '<one-line why>' }.
  #
  # Semantics (mirrored in migrate-tableau.rb --help):
  #   * BOTH --reuse-dm <explicit id> AND --wb-spec       → :fast
  #   * bare --reuse-dm (:recommended)                    → :full (the
  #     recommendation comes from the reuse scan, which needs discovery)
  #   * --dm-spec (fresh DM build)                        → :full
  #   * discovery artifacts missing + --yes               → :fast, degraded
  #     (degrade LOUDLY; never silently re-run discovery under --yes)
  #   * discovery artifacts missing + no --yes            → :full (re-discover)
  def decide(reuse_dm:, wb_spec:, dm_spec: nil, finalize: false, yes: false, artifacts: {})
    missing = artifacts.reject { |_, present| present }.keys
    if finalize
      return { route: :full, degraded: missing, reason: '--finalize resumes from migrate-state.json (pass 2)' }
    end
    unless reuse_dm && wb_spec
      return { route: :full, degraded: missing, reason: 'fast path needs BOTH --reuse-dm <id> and --wb-spec' }
    end
    if dm_spec
      return { route: :full, degraded: missing, reason: '--dm-spec builds a fresh DM (full validate+POST path)' }
    end
    unless reuse_dm.is_a?(String) && !reuse_dm.strip.empty?
      return { route: :full, degraded: missing,
               reason: 'bare --reuse-dm resolves via the reuse scan — pass an explicit --reuse-dm <dataModelId> for the fast path' }
    end
    if missing.any? && !yes
      return { route: :full, degraded: missing,
               reason: "discovery artifact(s) missing (#{missing.join(', ')}) and no --yes — running full discovery" }
    end
    { route: :fast, degraded: missing,
      reason: missing.any? ? "degraded fast path (--yes): missing #{missing.join(', ')} — discovery NOT re-run" : 'workdir complete — straight to the workbook layer' }
  end
end
