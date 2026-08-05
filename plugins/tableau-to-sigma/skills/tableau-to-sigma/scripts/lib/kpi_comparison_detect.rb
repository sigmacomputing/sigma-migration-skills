# frozen_string_literal: true
#
# kpi_comparison_detect.rb — conservative detector for a Tableau KPI tile's
# prior-period comparison VALUE (the migration payoff: feed KpiCard.build's
# comparison_column_id with a REAL prior-period value so the tile renders a Δ
# badge instead of always going single-value).
#
# The canonical Tableau YTD-vs-PYTD KPI pattern (Superstore "Key Performance
# Indicators" and its clones) does NOT put the prior value on the tile shelf.
# Each tile shelf carries the TOTAL (`TOTAL YTD Sales`) plus two sign-split
# DELTA ratios (`Sales Change Pos`, `Sales Change Neg`) — those are pre-computed
# deltas, NOT prior values, and wiring a delta as the comparisonColumn is wrong
# (Sigma computes value − comparison itself). The PRIOR VALUE (`PYTD Sales`)
# lives in the DM / MASTER columns. So the detector looks in TWO pools:
#
#   1. tile shelf siblings — a sibling whose NAME reads as a prior-period VALUE
#      (`… vs Prior Year`, `Prior Year Sales`, `PY Revenue`); NOT a delta.
#   2. MASTER/DM columns — when no shelf sibling qualifies, pair the value's
#      BASE metric (strip `TOTAL `/`YTD `/`CY `/`CYTD ` → `Sales`) against a
#      prior-VALUE master column for the SAME base (`PYTD Sales`, `Prior YTD
#      Sales`, `PY Sales`).
#
# Conservative by design: any ambiguity (zero matches, or two-or-more) returns
# nil and the caller keeps the single-value + "comparison is UI-only" warning —
# a partially-detected delta is worse than a named gap. A DELTA / CHANGE
# measure is NEVER treated as the comparison (that was the cold-migration bug).
#
#   require_relative 'lib/kpi_comparison_detect'
#   KpiComparisonDetect.detect(measures, value_col_id,
#                              master_columns: mmap.values, value_name: 'TOTAL YTD Sales')
#   # => comparison column id, or nil
#
# `measures` and `master_columns` are arrays of Hashes each carrying an
# 'id'/:id and a 'name'/:name (or 'label'/:label — see NAME_KEYS).
# `value_col_id` is the id of the tile's already-picked headline value measure,
# excluded from candidacy so a KPI never targets its own value.
#
# Stdlib only; Ruby 2.6-compatible.

module KpiComparisonDetect
  # A name that denotes a prior-period VALUE (the thing we CAN wire as a
  # comparison): PYTD / prior YTD / prior year|period|quarter|month / PY / LY /
  # last year. Deliberately does NOT include bare "yoy"/"y/y" — those name a
  # delta far more often than a prior value, and CHANGE_DELTA_RE would have to
  # rescue it anyway.
  PRIOR_VALUE_RE = /
      \bpytd\b
    | prior[-\s]?ytd
    | prior\s+(?:year|period|quarter|month)
    | \bpy\b
    | last\s+year
    | \bly\b
  /xi

  # A name that denotes a DELTA / CHANGE (never a prior VALUE): "% Change",
  # "YoY Change", "… CHANGE POS/NEG", variance, diff, an up/down arrow. If a
  # name matches this it is disqualified as a comparison VALUE even when it also
  # contains a prior-period word ("YoY Change" contains yoy). NOTE: `vs …` is
  # intentionally absent — "Revenue vs Prior Year" is a legitimate prior-value
  # phrasing in the corpus and PRIOR_VALUE_RE already gates it.
  CHANGE_DELTA_RE = /\bchange\b|%\s*change|\bpct\s*change\b|\bdelta\b|\bvariance\b|\bdiff\b|\bpos\b|\bneg\b|\byoy\b|y\/y|(?:up|down)\s*arrow/i

  # Leading period-qualifier tokens stripped (repeatedly) to reduce a measure
  # name to its BASE metric for cross-pool pairing. "TOTAL YTD SALES" → "sales";
  # "PYTD Sales" → "sales"; "Prior Year Profit" → "profit".
  PERIOD_QUALIFIER_RE = /\A(?:total|ytd|cy(?:td)?|current|pytd|prior[-\s]?ytd|prior|py|ly|last|year|quarter|period|month|week|day)\b[\s:_\-]*/i

  # Keys checked (in order) to read a measure's id/name off a Hash that may
  # use string or symbol keys, and 'name' or 'label'.
  ID_KEYS   = %w[id].freeze
  NAME_KEYS = %w[name label].freeze

  # Returns the comparison column id (String) or nil. See detect_measure for the
  # two-pool resolution; this returns just the id (or the id off the resolved
  # measure Hash) for callers that only need the target column.
  def self.detect(measures, value_col_id, master_columns: nil, value_name: nil)
    m = detect_measure(measures, value_col_id, master_columns: master_columns, value_name: value_name)
    m && field(m, ID_KEYS)
  end

  # Same contract as .detect but yields the whole matched measure Hash (or nil).
  # The builder needs the measure's NAME (or 'master_name') — not only its id —
  # so it can construct a PARALLEL aggregated comparison column
  # (Sum([Master/<prior>])) mirroring the value column, making the delta correct
  # by construction (Sum(current) − Sum(prior)).
  def self.detect_measure(measures, value_col_id, master_columns: nil, value_name: nil)
    # Pool 1 — a prior-VALUE sibling on the tile shelf.
    sib = (measures || []).select do |m|
      next false unless m.is_a?(Hash)
      id = field(m, ID_KEYS)
      id.to_s != value_col_id.to_s && prior_value_name?(field(m, NAME_KEYS))
    end
    return sib.first if sib.size == 1
    return nil if sib.size > 1 # ambiguous on the shelf — stay single-value

    # Pool 2 — pair the value's base metric against a prior-VALUE master column.
    return nil if master_columns.nil?
    vbase = base_metric(value_name)
    return nil if vbase.empty?
    cands = uniq_by_id(master_columns).select do |m|
      next false unless m.is_a?(Hash)
      id   = field(m, ID_KEYS)
      name = field(m, NAME_KEYS)
      next false if id.to_s == value_col_id.to_s
      prior_value_name?(name) && base_metric(name) == vbase
    end
    cands.size == 1 ? cands.first : nil
  end

  # A name reads as a prior-period VALUE: matches PRIOR_VALUE_RE and is NOT a
  # delta/change measure.
  def self.prior_value_name?(name)
    n = name.to_s
    return false if n =~ CHANGE_DELTA_RE
    !(n =~ PRIOR_VALUE_RE).nil?
  end

  # Reduce a measure name to its base metric by stripping leading period
  # qualifiers, then normalizing to lowercase alnum-separated tokens.
  def self.base_metric(name)
    s = name.to_s.strip
    loop do
      ns = s.sub(PERIOD_QUALIFIER_RE, '').strip
      break if ns == s

      s = ns
    end
    s.downcase.gsub(/[^a-z0-9]+/, ' ').strip
  end

  def self.uniq_by_id(cols)
    seen = {}
    (cols || []).each_with_object([]) do |c, out|
      next unless c.is_a?(Hash)

      id = field(c, ID_KEYS).to_s
      next if id.empty? || seen[id]

      seen[id] = true
      out << c
    end
  end
  private_class_method :uniq_by_id

  def self.field(hash, keys)
    keys.each do |k|
      v = hash[k] || hash[k.to_sym]
      return v unless v.nil?
    end
    nil
  end
  private_class_method :field
end
