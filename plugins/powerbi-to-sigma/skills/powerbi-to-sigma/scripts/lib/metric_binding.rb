# frozen_string_literal: true
#
# metric_binding.rb — bind a workbook measure to a governed DM metric.
#
# Every converter builds a Sigma data model whose elements carry reusable metrics
# (name + formula), but the workbook builder tends to re-derive each measure inline
# (Sum([Master/Net Revenue]), CountDistinct(...), ...), bypassing the governed
# metric: the aggregation logic is duplicated (and can drift) and the analyst never
# gets the metric object. This is the thin, converter-agnostic binder that lets a
# builder prefer a governed [Metrics/<name>] reference when it is provably the same
# aggregation — and fall back to the inline formula otherwise.
#
# Pure functions:
#
# - available_metrics(element_id, elements_by_id) — the metrics REFERENCEABLE on an
#   element: its own metrics plus those inherited through the source.elementId chain
#   (a denorm "<X> View" element carries 0 own metrics but inherits its base fact's;
#   Sigma exposes them and they resolve as [Metrics/<name>] on the denorm — verified
#   live). Deduped by name, nearest element wins. Each metric is {"name","formula"};
#   entries missing either field are skipped. A COLLISION-SHAPED element (below)
#   contributes NO metrics — none of them are provably referenceable.
#
# - column_metric_collisions(element) — the names carried by BOTH a column and a
#   governed metric of the SAME element (exact string equality — Sigma element
#   namespaces are exact; no name/content heuristics). [] for a clean element.
#
# - collision_exclusions(element_id, elements_by_id) — the audit half of the same
#   chain walk: one {"element_id","element_name","collisions","excluded_metrics"}
#   record per collision-shaped element whose metrics available_metrics withheld,
#   so callers surface the inline fallback (run note + decision ledger) instead of
#   silently changing emission. element_name falls back to the element ID when
#   the element is unnamed (converter-model BASE elements carry no 'name' key —
#   field-caught: the run note otherwise renders "DM element ''", identifying
#   nothing), so the label is always render-safe.
#
# - metric_ref_or_inline(inline, master_name, metrics) — returns "[Metrics/<name>]"
#   when `inline` matches a metric by FORMULA EQUIVALENCE (strip the master prefix so
#   Sum([Data/Net Revenue]) equals a metric's Sum([Net Revenue]), then compare
#   ignoring whitespace), else returns `inline` unchanged. Naming-independent and
#   SAFE: ratios / filtered / custom / no-match / empty-metrics all fall through to
#   inline, so passing no metrics is byte-identical to the pre-binding behavior.
#   Whether a column is even a measure (worth binding) is the caller's decision.
#
# COLLISION SHAPE (wave-2 measurement finding F4, field-caught live): a DM element
# that POSTs a governed metric NAMED IDENTICALLY to one of its own columns is
# accepted by the API without error, but the live readback then returns the
# element with its metrics OMITTED WHOLESALE — including same-element metrics
# whose names do not collide (field evidence: a fact element with same-named
# column/metric pairs came back as columns only; every metric name backed solely
# by a metric was gone). Any [Metrics/<name>] ref bound to one of those metrics
# then fails the post-readback workbook ref gate (exit 4, "Dependency not
# found" class) — deterministically, on every cold run of the shape. The remedy
# validated live is to re-derive the affected measures INLINE. So: when the
# shape is present, the binder withholds ALL of that element's metrics
# (available_metrics) and reports the withholding (collision_exclusions); the
# ref gate itself stays fail-closed — emission just stops producing refs the
# readback cannot confirm. Detection is purely structural: same element, one
# column + one metric, same exact name.
#
# The reference form is the literal namespace [Metrics/<Metric Name>] — NOT
# [Element/Name] (that errors). Extracted from the looker reference implementation
# (PR #484); see [bead]. Mirror: shared/lib/metric_binding.py — keep the
# two in lockstep.

module MetricBinding
  module_function

  # Whitespace-insensitive canonical form of a Sigma formula (or empty).
  def canon(formula)
    (formula || '').gsub(/\s+/, '')
  end

  # Names carried by BOTH a column and a governed metric of `element` — the
  # structural F4 collision shape. Exact string equality, column order, deduped;
  # [] for a clean element or non-Hash input. Every NAMED entry counts, even a
  # formula-less metric: the POSTed shape is what live Sigma drops on readback.
  def column_metric_collisions(element)
    return [] unless element.is_a?(Hash)

    met_names = {}
    (element['metrics'] || []).each do |m|
      met_names[m['name']] = true if m.is_a?(Hash) && m['name']
    end
    return [] if met_names.empty?

    seen = {}
    out = []
    (element['columns'] || []).each do |c|
      name = c.is_a?(Hash) ? c['name'] : nil
      next unless name && met_names[name] && !seen[name]

      seen[name] = true
      out << name
    end
    out
  end

  # Metrics referenceable on element_id = own + inherited via source.elementId,
  # deduped by name (nearest element wins). elements_by_id maps id => element hash
  # (string keys, as JSON.parse produces). Returns an array of
  # {"name"=>, "formula"=>}; metrics missing a name or formula are dropped, and a
  # collision-shaped element (column_metric_collisions) contributes NO metrics —
  # its measures must stay inline (F4; see the header). Cycle-safe.
  def available_metrics(element_id, elements_by_id)
    walk_chain(element_id, elements_by_id)['metrics']
  end

  # Audit companion to available_metrics — the SAME walk's exclusion records:
  # one {"element_id"=>, "element_name"=>, "collisions"=>, "excluded_metrics"=>}
  # hash per collision-shaped chain element whose metrics were withheld ([]
  # when the chain is clean). Callers surface these (run note + decision
  # ledger) so the inline fallback is never silent. element_name is always a
  # non-empty label: the element's name, or its ID when it has none (converter
  # models leave base elements unnamed).
  def collision_exclusions(element_id, elements_by_id)
    walk_chain(element_id, elements_by_id)['exclusions']
  end

  # The one chain walk behind available_metrics / collision_exclusions:
  # {"metrics"=>[{"name","formula"},...], "exclusions"=>[...]}. Cycle-safe.
  def walk_chain(element_id, elements_by_id)
    seen = {}
    chain = []
    exclusions = []
    eid = element_id
    while eid && !seen[eid]
      seen[eid] = true
      el = elements_by_id[eid]
      break unless el

      harvest = []
      (el['metrics'] || []).each do |m|
        next unless m.is_a?(Hash) && m['name'] && m['formula']

        harvest << { 'name' => m['name'], 'formula' => m['formula'] }
      end
      collisions = column_metric_collisions(el)
      if collisions.empty?
        chain.concat(harvest)
      else
        # Converter-model BASE elements carry no 'name' key — fall back to the
        # element ID so the audit label never renders as '' (field-caught).
        el_name = el['name']
        el_name = eid if el_name.nil? || el_name == ''
        exclusions << { 'element_id' => eid, 'element_name' => el_name,
                        'collisions' => collisions,
                        'excluded_metrics' => harvest.map { |m| m['name'] } }
      end
      eid = (el['source'] || {})['elementId']
    end
    { 'metrics' => dedup_by_name(chain), 'exclusions' => exclusions }
  end

  def dedup_by_name(metrics)
    seen = {}
    metrics.each_with_object([]) do |m, out|
      next if seen[m['name']]

      seen[m['name']] = true
      out << m
    end
  end

  # Prefer "[Metrics/<name>]" when `inline` matches a metric by formula equivalence
  # (master prefix stripped, whitespace ignored); otherwise return `inline`
  # unchanged. Safe no-op when `metrics` is empty/nil or `inline` is not a String.
  def metric_ref_or_inline(inline, master_name, metrics)
    return inline unless inline.is_a?(String) && metrics && !metrics.empty?

    # gsub with a String pattern strips EVERY master prefix literally (matches the
    # Python mirror's str.replace); Sum([M/a])/Sum([M/b]) → Sum([a])/Sum([b]).
    want = canon(inline.gsub("[#{master_name}/", '['))
    metrics.each do |m|
      name = m['name']
      formula = m['formula']
      return "[Metrics/#{name}]" if name && formula && canon(formula) == want
    end
    inline
  end
end
