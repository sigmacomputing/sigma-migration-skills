# frozen_string_literal: true

# finalize_remedy.rb — "what to change" for a finalize LOOP STOP.
#
# WHY: two identical --finalize retries (live re-proof: gate 13, visual
# verdict) correctly tripped the breaker, but the stop only said "re-running
# will not converge" — not WHICH input has to change. This maps the failing
# check (and the final gate's exit code, refs/gates.md) to the artifact or
# command that must change before the next attempt can differ.
module FinalizeRemedy
  module_function

  # assert-phase6-ran exit code → what to change (mirrors refs/gates.md).
  GATE = {
    1 => 'parity-final.json is missing: run phase6-parity.rb (collect actuals) before --finalize',
    2 => 'parity FAILs: fix the failing charts (parity-final.json lists them) or regenerate the plan, then re-collect actuals',
    4 => 'orphan workbooks: run cleanup-orphan-workbooks.rb',
    5 => 'a live column is type=error: fix its formula in the DM/workbook spec and re-PUT',
    6 => 'no layout applied: run put-layout.rb (or re-enter so Phase 5 applies it)',
    7 => 'tile census: build or explain the missing zones (zone list in the gate output)',
    8 => 'layout lint: fix the named layout issues (lib/layout_lint.rb) and re-apply the layout',
    9 => 'control lint: wire/remove the named controls or annotate control-scope.json, then re-PUT',
    10 => 'no current render: run fidelity-loop.rb render (or record --skip-visual-gate with a reason)',
    13 => 'visual verdict: record a sha-bound blind grade of the LATEST render with record-visual-check.rb ' \
          '(re-render first if the workbook changed), or record a reasoned --no-vision-waiver — re-running ' \
          '--finalize does not change the verdict',
    14 => 'layout fill: place the dropped tile / enlarge rows (layout-census.json), then re-apply the layout',
    15 => 'RCF ledger: resolve the spec-fixable entries (fidelity-loop.rb apply-patch / resolve) or accept named residuals',
    18 => 'anchors: fix the failing anchors (anchors-verdict.json) and re-run verify-anchors.rb',
    19 => 'waiver budget: remove waivers (fix the underlying gates) — no flag lifts the cap',
    20 => 'visual similarity: fix the composition deltas and re-render',
    21 => 'control flip: make the control filter live (probe-controls.rb) or record the reasoned skip',
    22 => 'manual residues: build the unbuilt calcs (manual-residues.json) or accept them by name',
    23 => 'join cardinality: probe join-plan.json (probe-join-keys.rb) or resolve each entry with a reason',
    24 => 'LOD ledger: resolve lod-audit.json entries (audit-lod-calcs.rb --how ...)',
    25 => 'ground truth: match or waive each displayed tile (numeric_parity / coverage_waivers)',
    26 => 'agg semantics: resolve agg-semantics.json entries (audit-agg-semantics.rb --how ...)',
    27 => 'semantic edits: prove (probe-equivalence.rb) or revert the declared edits',
    28 => 'chart-kind parity: rebuild the element as the verified kind, or record a kind_waiver at read time',
    29 => 'layout arrangement: fix the arrangement violations (layout-arrangement.json)',
    30 => 'layout never ran: re-enter so Phase 5 runs',
    31 => 'controls census: build, declare (control-scope.json) or waive (controls-waivers.json) the named controls'
  }.freeze

  CHECK = {
    phase6: 'phase6-parity.rb: fix the parity failures it printed',
    relationships: 'relationship coverage: wire the missing source relationships in the DM',
    dashboards: 'dashboard coverage: build the missing dashboard pages',
    sql_provenance: 'SQL provenance: attribute each SQL element (sql-provenance.rb)',
    cleanup: 'cleanup-orphan-workbooks.rb',
    reconstruction: 'reconstruction integrity: finish (or waive by name) the unfinished controls/kinds it listed',
    dsfilters: 'datasource filters: apply the source data-source filters it listed',
    actiongates: 'action gates: fix the invalid actions / regenerate POSTPUBLISH_GUIDE.md',
    census: 'source-object census: account for the objects it listed',
    report: 'migration report: clear the RED items (punch list) it printed'
  }.freeze

  ORDER = %i[phase6 relationships dashboards sql_provenance gate cleanup reconstruction dsfilters actiongates census report].freeze

  # statuses: { phase6: 0, gate: 13, ... } (exit codes). Returns remedy lines.
  def lines(statuses, error_line: nil)
    failing = ORDER.select { |k| statuses[k].to_i != 0 }
    out = failing.map do |k|
      if k == :gate
        code = statuses[:gate].to_i
        "final gate (assert-phase6-ran exit #{code}): #{GATE[code] || 'fix the gate named in the output above'}"
      else
        CHECK[k]
      end
    end
    out << "first error: #{error_line.to_s.strip[0, 160]}" unless error_line.to_s.strip.empty?
    out
  end
end
