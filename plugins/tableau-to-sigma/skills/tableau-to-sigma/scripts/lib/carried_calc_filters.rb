# frozen_string_literal: true

require 'json'

# Reader for <tableau-dir>/carried-calc-filters.json — the ledger
# build-charts-from-signals.rb writes for every worksheet calc-filter it CARRIED
# onto a Sigma element (search box, boolean calc, calc column, ...). The Phase 6
# hidden-calc-filter gate (auto-parity-plan.rb, and phase6-parity.rb on a reused
# plan) uses it to mark a hidden filter `translated` without a human edit — but
# only when the ledger's definition (filter_type/members/min/max) is the SAME as
# the layout's current one. A missing/unreadable ledger resolves nothing. The
# Python twin lives inline in auto-parity-plan.py.
module CarriedCalcFilters
  FILE = 'carried-calc-filters.json'
  NOTE = 'carried by build-charts-from-signals.rb'

  module_function

  def load(tableau_dir)
    path = File.join(tableau_dir.to_s, FILE)
    return [] unless File.file?(path)
    data = JSON.parse(File.read(path, encoding: 'UTF-8'))
    entries = data.is_a?(Hash) ? data['entries'] : nil
    entries.is_a?(Array) ? entries.select { |e| e.is_a?(Hash) } : []
  rescue JSON::ParserError, SystemCallError, EncodingError
    []
  end

  # The same fingerprint the gate's carry-forward uses — a changed definition
  # (members/type/range) must never inherit a resolution.
  def same_definition?(a, b)
    a['filter_type'].to_s == b['filter_type'].to_s &&
      Array(a['members']).map(&:to_s).sort == Array(b['members']).map(&:to_s).sort &&
      a['min'].to_s == b['min'].to_s && a['max'].to_s == b['max'].to_s
  end

  # The ledger entry that carried this hidden-filter entry ({tile, calc_ref,
  # caption, filter_type, members, min, max}), or nil. Tile must match exactly
  # (caption whitespace is part of the key); then calc_ref, or the calc caption
  # when either side has no calc_ref. A ledger entry for another dashboard
  # (when both name one) does not count. same_def: false finds a carry of the
  # same filter whose definition has since changed (diagnostics only).
  def match(entry, ledger, dashboard: nil, same_def: true)
    ledger.find do |l|
      next false unless l['worksheet'].to_s == entry['tile'].to_s
      next false if dashboard && l['dashboard'] && l['dashboard'] != dashboard
      ref_ok = entry['calc_ref'] && l['calc_ref'] ? entry['calc_ref'] == l['calc_ref'] : nil
      cap_ok = entry['caption'] && l['calc_caption'] ? entry['caption'] == l['calc_caption'] : nil
      (ref_ok.nil? ? cap_ok : ref_ok) && (!same_def || same_definition?(entry, l))
    end
  end

  # Mark an unresolved hidden-filter entry `translated` when the ledger carried
  # it. Returns the ledger entry used (nil = untouched).
  def resolve!(entry, ledger, dashboard: nil)
    return nil if %w[translated waived].include?(entry['status'])
    hit = match(entry, ledger, dashboard: dashboard)
    return nil unless hit
    entry['status'] = 'translated'
    entry['translated_to'] = (hit['sigma_formula'] || hit['sigma_column'] || hit['mode']).to_s
    entry['note'] = NOTE
    hit
  end

  # A REUSED parity plan (phase6-parity.rb) predates the chart rebuild, so its
  # hidden filters may still read `unresolved`: resolve them in place against the
  # ledger (operator waives/translations untouched) and clear `needs_review`
  # (set only by open hidden filters) once none remain. Returns how many resolved.
  def resolve_plan!(plan, ledger)
    return 0 if ledger.empty? || !plan.is_a?(Hash)
    resolved = (plan['hidden_filters'] || []).count { |hf| hf.is_a?(Hash) && resolve!(hf, ledger) }
    if resolved.positive? && plan['plan_status'] == 'needs_review' &&
       plan['hidden_filters'].all? { |hf| %w[translated waived].include?(hf['status']) }
      plan['plan_status'] = 'green'
    end
    resolved
  end
end
