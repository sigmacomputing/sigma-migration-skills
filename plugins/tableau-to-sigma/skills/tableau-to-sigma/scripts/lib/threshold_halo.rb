# frozen_string_literal: true
#
# threshold_halo.rb — C2 "threshold halo" detection (gap ubr5.11, P0).
#
# Tableau's "threshold halo" is a mark colored by a THRESHOLD ON THE MEASURE:
# a computed boolean/2-band field on the Color shelf that flips a bar/BAN's
# color above vs below a constant (the reference "> 100K" yellow halo, and the
# general red-below/green-above scorecard idiom). The .twb serializes it as a
# categorical color encoding whose FIELD is a calc:
#
#   <column caption='Over 100K' name='[Calculation_770]'>
#     <calculation class='tableau' formula='SUM([Sales]) &gt; 100000' /></column>
#   ...
#   <encoding attr='color' field='[fed].[none:Calculation_770:nk]' type='palette'>
#     <map to='#f2c037'><bucket>true</bucket></map>
#     <map to='#c9d1d3'><bucket>false</bucket></map>
#   </encoding>
#
# parse-twb-layout already surfaces the pieces: the color channel column
# (`channels.color.column`), the member→color map (`series_colors`), the encoded
# field caption (`series_color_field`), and the calc formula (in
# `columns_by_guid`). Before C2 the builder DROPPED this — a threshold-calc color
# dim isn't a CSV column, so `color_col_obj` stayed nil and the halo vanished
# behind a "single-series fan-out" NOTE. This module is the shared, pure detector
# both the parser (meta signal + sidecar) and the builder (emission) delegate to,
# so the two can't drift.
#
# SCOPE (deliberately tight — the common case; see docs/…-HANDOFF.md §6 C2):
#   MAPPABLE  : a 2-band color driven by `AGG?([m]) <op> <const>` (optionally
#               wrapped in IIF/IF…THEN). Category charts get the verified
#               computed-boolean + 2-color `color.scheme` halo. KPIs/BANs have
#               NO spec path for a conditional value color (kpi-chart `value.color`
#               is a STATIC hex; conditional formatting is UI-only) → routed to
#               POSTPUBLISH_GUIDE, never silently dropped.
#   UNMAPPABLE: continuous value ramps (heat_scheme), >2 bands, and second
#               marks-layer (`element='map-layer'`) overlays — recorded to
#               coverage, deferred (out of the tight increment).
#
# Pure: no I/O. Unit-tested by test-threshold-halo.rb.
module ThresholdHalo
  module_function

  HEX = /\A#[0-9a-f]{6}\z/i.freeze
  OPS = %w[>= <= > <].freeze
  AGGS = %w[SUM AVG AVERAGE MIN MAX COUNT COUNTD MEDIAN TOTAL ATTR].freeze
  # Members Tableau serializes for the TRUE / "above the threshold" bucket of a
  # boolean color calc (and common 2-label idioms). Everything else is "below".
  TRUTHY = %w[true t yes y 1 above high over pass ok good].freeze

  # Parse a color-encoding calc formula into {agg, measure_ref, op, constant}.
  # nil unless it is a single `AGG?(<measure>) <op> <numeric const>` comparison
  # (optionally the condition of an IIF()/IF…THEN). Compound predicates (AND/OR),
  # column-vs-column, and non-numeric RHS return nil → routed unmappable.
  def parse_threshold(formula)
    return nil if formula.nil?
    f = formula.to_s.strip
    # Unwrap a boolean-returning IIF()/IF…THEN to its condition.
    if (m = f.match(/\AIIF\s*\(\s*(.+?)\s*,/im))
      f = m[1].strip
    elsif (m = f.match(/\AIF\s+(.+?)\s+THEN\b/im))
      f = m[1].strip
    end
    # No compound predicate in the tight scope.
    return nil if f =~ /\b(AND|OR)\b/i
    m = f.match(
      /\A\(?\s*
        (?:(#{AGGS.join('|')})\s*\(\s*)?   # optional aggregate wrapper
        (\[[^\]]+\]|[A-Za-z_][\w ]*?)        # measure ref (bracketed or bare)
        \s*\)?\s*
        (>=|<=|>|<)\s*                       # comparison op
        (-?[\d,]+(?:\.\d+)?)                  # numeric constant
        \s*\)?\z/imx
    )
    return nil unless m
    { 'agg'         => m[1] && m[1].upcase,
      'measure_ref' => m[2].strip,
      'op'          => m[3],
      'constant'    => m[4].delete(',').include?('.') ? m[4].delete(',').to_f : m[4].delete(',').to_i }
  end

  # Split a 2-entry series_colors map into {below, above} hexes.
  # Boolean members (true/false) map by truthiness; other 2-label pairs map the
  # non-neutral (more saturated) color to "above" (the halo). nil unless exactly
  # two well-formed color entries.
  def band_colors(series_colors, neutral_fn = nil)
    pairs = Array(series_colors).select do |p|
      p.is_a?(Hash) && p['color'].to_s =~ HEX && !p['member'].to_s.strip.empty?
    end
    return nil unless pairs.size == 2
    tp = pairs.find { |p| TRUTHY.include?(p['member'].to_s.strip.downcase) }
    if tp
      fp = (pairs - [tp]).first
      return { 'above' => tp['color'].downcase, 'below' => fp['color'].downcase, 'basis' => 'boolean' }
    end
    # Non-boolean labels: halo = the non-neutral color when exactly one is neutral.
    if neutral_fn
      neutral = pairs.select { |p| neutral_fn.call(p['color'].downcase) }
      if neutral.size == 1
        base = neutral.first
        halo = (pairs - [base]).first
        return { 'above' => halo['color'].downcase, 'below' => base['color'].downcase, 'basis' => 'saturation' }
      end
    end
    nil
  end

  # Full plan for one zone. Returns:
  #   {mappable:true,  op, constant, measure_ref, agg, above, below, field, formula, basis}
  #   {mappable:false, reason, field, formula}   — a threshold-ish color we won't map
  #   nil                                          — no threshold color on this zone
  # `columns_by_guid`/`guid_of` resolve the color field's calc formula; `neutral_fn`
  # is the caller's color-neutral? predicate (parser/builder share one).
  def plan_for_zone(zone, columns_by_guid, guid_of, neutral_fn = nil)
    return nil unless zone.is_a?(Hash)
    cc = zone.dig('channels', 'color', 'column')
    sc = zone['series_colors']
    return nil if cc.to_s.empty?
    # Only a categorical member→color map is a candidate (heat_scheme ramps are
    # continuous — a different, unmappable class already surfaced by the parser).
    return nil unless sc.is_a?(Array) && sc.any?
    guid = guid_of.call(cc.to_s)
    info = guid && columns_by_guid[guid]
    formula = info.is_a?(Hash) ? info['formula'] : nil
    field = zone['series_color_field']
    return nil if formula.to_s.strip.empty? # a plain categorical dim, not a threshold
    thr = parse_threshold(formula)
    unless thr
      return { 'mappable' => false, 'reason' => 'color calc is not a single AGG(measure) <op> constant threshold',
               'field' => field, 'formula' => formula }
    end
    colors = band_colors(sc, neutral_fn)
    unless colors
      return { 'mappable' => false, 'reason' => "threshold color is not a 2-band map (got #{Array(sc).size} band(s))",
               'field' => field, 'formula' => formula }
    end
    thr.merge('mappable' => true, 'above' => colors['above'], 'below' => colors['below'],
              'basis' => colors['basis'], 'field' => field, 'formula' => formula)
  end
end
