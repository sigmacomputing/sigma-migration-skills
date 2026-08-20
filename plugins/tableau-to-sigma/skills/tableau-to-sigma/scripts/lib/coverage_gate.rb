# frozen_string_literal: true
#
# CoverageGate — turns a converter's build-step coverage.json into (a) a
# human-readable migration-coverage REPORT and (b) the decision questions for the
# RECOVERABLE drops, so the migrate-* orchestrator can surface ONE consolidated
# readout + an assistance prompt instead of leaving the facts in scattered STDERR
# warnings (customer feedback, 2026-06-25: "silently drops components it cannot
# resolve, rather than prompting the user for assistance").
#
# Converter-agnostic + pure + unit-tested (test-coverage-gate.rb), like DaxGate.
# The builder already warns loudly at each drop site; this module only aggregates
# + classifies. Canonical lives in shared/lib (); edit there,
# run tools/sync-shared.rb.
#
# coverage.json schema (written by each converter's build script):
#   { version, source, summary:{sourceVisuals, builtElements, dropped, degraded,
#     approximated, recoverable, sourceBindings, resolvedBindings},
#     unresolved:[{visual, source_type, sigma_kind, severity, detail,
#                  recoverable, action, role_class,
#                  field_bindings:[{queryRef, status, role_class}]}] }
#   (source_type is the per-tool source kind; some converters still emit the
#    legacy `pbi_type` — both are accepted.)
#   severity: 'dropped' | 'degraded' | 'approximated'
#   field_bindings[].status: 'resolved' | 'dropped' | 'degraded'
#   summary.sourceBindings / resolvedBindings: FIELD-level (binding) totals —
#   see binding_totals/binding_loss/binding_headline/gate! below. A visual can
#   be 'degraded' (still counted as carried over by headline/above) while
#   having lost most of its individual field bindings; that gap is why binding
#   coverage is tracked and gated separately from visual coverage.
require 'json'

module CoverageGate
  module_function

  # Read coverage.json defensively; returns nil when absent/garbage so callers
  # can no-op (an offline / agent-path build may not have written one).
  def load(path)
    return nil unless path && File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  # The headline coverage line. Leads with what CARRIED OVER, not the gaps — an
  # APPROXIMATED visual (treemap→bar) and a DEGRADED one (lost a field) both still
  # land in Sigma with their data; only a DROPPED visual is truly absent. Counting
  # approximations as "not converted" is what fuels the "drops a lot" perception.
  # e.g. "12/12 source visuals carried over (5 approximated, 1 degraded); 0 dropped."
  def headline(coverage)
    s = (coverage && coverage['summary']) || {}
    sv = s['sourceVisuals'].to_i
    dropped_v = distinct_dropped_visuals(coverage)
    carried = [sv - dropped_v, 0].max
    extras = []
    extras << "#{s['approximated'].to_i} approximated" if s['approximated'].to_i.positive?
    extras << "#{s['degraded'].to_i} degraded" if s['degraded'].to_i.positive?
    qual = extras.empty? ? '' : " (#{extras.join(', ')})"
    "#{carried}/#{sv} source visual(s) carried over#{qual}; #{dropped_v} dropped."
  end

  # DISTINCT source visuals that produced NO Sigma element (a 'dropped' entry).
  # Approximated/degraded visuals DID build, so they are NOT counted as dropped.
  def distinct_dropped_visuals(coverage)
    ((coverage && coverage['unresolved']) || [])
      .select { |u| u['severity'] == 'dropped' }.map { |u| u['visual'] }.uniq.size
  end

  # Count of DISTINCT source visuals with at least one gap entry of ANY severity.
  def distinct_visuals_with_gaps(coverage)
    ((coverage && coverage['unresolved']) || []).map { |u| u['visual'] }.uniq.size
  end

  # Full report lines (printed under the headline). Stable ordering: dropped
  # first (most severe), then degraded, then approximated.
  ORDER = { 'dropped' => 0, 'degraded' => 1, 'approximated' => 2 }.freeze
  def report_lines(coverage)
    items = (coverage && coverage['unresolved']) || []
    items.sort_by { |u| [ORDER[u['severity']] || 9, u['visual'].to_s] }.map do |u|
      tag = u['severity'].to_s.upcase
      rec = u['recoverable'] ? ' [recoverable]' : ''
      "  • [#{tag}]#{rec} #{u['visual']}: #{u['detail']}" +
        (u['action'] ? "\n      ↳ #{u['action']}" : '')
    end
  end

  # Decision questions for the RECOVERABLE items only — same shape the migrate-*
  # orchestrators push onto `questions` (id/severity/detail/options/default).
  # Non-recoverable items (genuine Sigma limitations) are reported but never asked.
  def questions(coverage)
    ((coverage && coverage['unresolved']) || []).select { |u| u['recoverable'] }.map do |u|
      { 'id' => "coverage_#{u['severity']}", 'severity' => 'review',
        'visual' => u['visual'], 'source_type' => (u['source_type'] || u['pbi_type']),
        'detail' => u['detail'],
        'options' => [u['action'] || 'recover per the action note (re-run after fixing the source map)',
                      'accept the gap (ship without this component)'],
        'default' => 'accept the gap (ship without this component)' }
    end
  end

  # ── Cause classification (customer feedback 2026-07-17: dim names / measures /
  # filters silently dropped → empty tiles with no "why/what-to-do"). Group drops
  # by WHY and attach ONE concrete action per cause: an empty tile becomes
  # "grant schema X" or "non-translatable DAX (accepted)" instead of a silent gap.
  # The orchestrator alone knows the DM readback + converter warnings, so it
  # gathers the inputs; this stays pure + unit-tested (test-coverage-gate.rb).
  CAUSE_ORDER = { 'ungranted_schema' => 0, 'cross_table_measure' => 1,
                  'nontranslatable_dax' => 2, 'empty_tile' => 3, 'unmapped' => 4 }.freeze

  def norm_ident(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # Stamp each unresolved entry with a `cause` and (for non-translatable DAX)
  # flip recoverable:false so the visual-compare gate isn't blocked by a genuine
  # Sigma/DAX limitation — it is SURFACED, not gated. Mutates + returns coverage.
  #   ungranted        : { "<catalog>.<schema>" => [table, …] } (warehouse elements
  #                      absent from the DM readback = schema the connection can't read)
  #   dax_dropped      : measure names the converter dropped as non-translatable (⛔)
  #   dax_crosstable   : measure names dropped as cross-table (⚠)
  def classify_causes(coverage, ungranted: {}, connection: nil, dax_dropped: [], dax_crosstable: [])
    return coverage unless coverage.is_a?(Hash)
    ung   = ungranted.values.flatten.map { |t| norm_ident(t) }.reject(&:empty?)
    drop  = dax_dropped.map { |m| norm_ident(m) }.reject(&:empty?)
    cross = dax_crosstable.map { |m| norm_ident(m) }.reject(&:empty?)
    (coverage['unresolved'] || []).each do |u|
      en  = norm_ident(u['entity'])
      hay = norm_ident("#{u['detail']} #{u['visual']} #{u['entity']}")
      u['cause'] =
        if !en.empty? && ung.any? { |t| t == en || en.include?(t) || t.include?(en) }
          u['recoverable'] = true
          'ungranted_schema'
        elsif !drop.empty? && drop.any? { |m| hay.include?(m) }
          u['recoverable'] = false
          'nontranslatable_dax'
        elsif !cross.empty? && cross.any? { |m| hay.include?(m) }
          u['recoverable'] = true
          'cross_table_measure'
        elsif u['detail'].to_s =~ /no (resolvable|field|bind)/i
          'empty_tile'
        else
          'unmapped'
        end
    end
    coverage['causes_summary'] = { 'ungranted_schemas' => ungranted, 'connection' => connection } unless ungranted.empty?
    coverage
  end

  # Grouped, actionable report lines: a schema-level GRANT headline first (the
  # highest-leverage action — one grant recovers every column/measure on those
  # tables), then one action line per remaining cause. Falls back to the flat
  # report_lines when nothing has been classified.
  def report_lines_by_cause(coverage)
    return report_lines(coverage) unless coverage.is_a?(Hash)
    classified = (coverage['unresolved'] || []).any? { |u| u['cause'] } || coverage['causes_summary']
    return report_lines(coverage) unless classified
    out = []
    conn = coverage.dig('causes_summary', 'connection')
    (coverage.dig('causes_summary', 'ungranted_schemas') || {}).each do |sch, tbls|
      shown = Array(tbls).uniq
      out << "  • [UNGRANTED SCHEMA] #{sch} — #{shown.size} table(s) the connection can't read: " \
             "#{shown.first(6).join(', ')}#{shown.size > 6 ? ', …' : ''}" \
             "\n      ↳ grant #{sch} to connection #{conn || '<the DM connection>'} and re-run — recovers every column/measure on these tables (e.g. the dimension NAME columns + measures)."
    end
    items = (coverage['unresolved'] || []).reject { |u| u['cause'] == 'ungranted_schema' }
    items.group_by { |u| u['cause'] || 'unmapped' }
         .sort_by { |c, _| CAUSE_ORDER[c] || 9 }.each do |cause, grp|
      names = grp.map { |u| u['visual'] }.compact.uniq
      action =
        case cause
        when 'nontranslatable_dax' then 'non-translatable DAX (no Sigma equivalent) — accepted; recreate as a workbook calc if the visual needs it.'
        when 'cross_table_measure' then 'cross-table measure — recreate at the visual grain in a workbook element.'
        when 'empty_tile'          then 'no resolvable bindings — supply the missing source (grant the schema / map the queryRef) and re-run.'
        else                            'map the PBI queryRef to a master column in master-map.json and re-run.'
        end
      out << "  • [#{cause.tr('_', ' ').upcase}] #{grp.size} item(s): " \
             "#{names.first(6).join(', ')}#{names.size > 6 ? ', …' : ''}\n      ↳ #{action}"
    end
    out
  end

  # ── Binding-level coverage. The visual-level headline was the reason a
  # dashboard that lost 51% of its FIELD bindings reported "12/12 source visuals
  # carried over; 0 dropped": a table shipping 3 of 8 columns is merely
  # 'degraded', and 'degraded' counts as carried over. Fields are what the
  # customer actually sees, so they get their own accounting and their own gate.
  #
  # nil-safe like every other public method here (load() returns nil when
  # coverage.json is absent) — nil/absent coverage means "no bindings
  # recorded", i.e. [0, 0], NOT a crash and NOT a spurious 100% loss.
  #
  # `resolved` is clamped to [0, total] so malformed input (e.g. a converter
  # bug reporting resolvedBindings > sourceBindings) can never push binding_loss
  # outside its documented 0.0..1.0 range or produce a negative "dropped" count
  # in binding_headline — both derive from this single clamp.
  def binding_totals(coverage)
    s = (coverage && coverage['summary']) || {}
    total = s['sourceBindings'].to_i
    if total.zero?   # fall back to summing per-entry field_bindings
      all = ((coverage && coverage['unresolved']) || []).flat_map { |u| u['field_bindings'] || [] }
      total = all.size
      resolved = all.count { |b| b['status'] == 'resolved' }
      return [total, resolved.clamp(0, total)]
    end
    [total, s['resolvedBindings'].to_i.clamp(0, total)]
  end

  def binding_loss(coverage)
    total, resolved = binding_totals(coverage)
    return 0.0 if total.zero?
    1.0 - (resolved.to_f / total)
  end

  def binding_headline(coverage)
    total, resolved = binding_totals(coverage)
    return 'no field-binding data recorded' if total.zero?
    pct = (100.0 * resolved / total).round(1)
    "#{resolved}/#{total} source field binding(s) resolved (#{pct}%); " \
      "#{total - resolved} dropped or degraded."
  end

  # Roles whose loss is FUNCTIONAL (see pbi_viz_kind.rb FUNCTIONAL_ROLES).
  GATE_ROLES = %w[control kpi chart table].freeze

  # [:pass|:fail, reason]. Fails on (a) a dropped functional-role visual, or
  # (b) binding resolution below min_resolved. `allow_override` is the explicit
  # escape hatch for genuinely-degraded sources (USERELATIONSHIP, ISINSCOPE) —
  # it flips :fail to :pass but NEVER hides the reason: both branches build
  # ONE reason string and reuse it verbatim (prefixed "overridden: ") for the
  # override return, so the two can never diverge again.
  # nil-safe: a nil/absent coverage (load() returns nil when coverage.json is
  # missing) has no recorded bindings/drops, so it passes without crashing —
  # it must never spuriously FAIL a run that simply has no coverage data.
  def gate!(coverage, min_resolved: 0.95, allow_override: false)
    lost = ((coverage && coverage['unresolved']) || []).select do |u|
      u['severity'] == 'dropped' && GATE_ROLES.include?(u['role_class'].to_s)
    end
    unless lost.empty?
      names = lost.map { |u| "#{u['visual']} (#{u['role_class']})" }.uniq
      reason = "#{names.size} functional component(s) DROPPED — " \
               "#{names.first(4).join(', ')}. A lost control means the page lost its filter."
      return [:pass, "overridden: #{reason}"] if allow_override
      return [:fail, reason]
    end
    loss = binding_loss(coverage)
    if loss > (1.0 - min_resolved)
      reason = format('field-binding resolution %.1f%% is below the %.1f%% floor — %s',
                      100 * (1 - loss), 100 * min_resolved, binding_headline(coverage))
      return [:pass, "overridden: #{reason}"] if allow_override
      return [:fail, reason]
    end
    [:pass, binding_headline(coverage)]
  end
end
