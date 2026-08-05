# frozen_string_literal: true
#
# series_colors.rb — ordered per-series color emission (PR-12).
#
# Tableau serializes EXPLICIT member→color assignments on the categorical
# color encoding (worksheet style-rules):
#
#   <encoding attr='color' field='[fed].[none:Value Tier:nk]' type='palette'>
#     <map to='#f2c037'><bucket>&quot;Top 500&quot;</bucket></map>
#     <map to='#c9d1d3'><bucket>&quot;Bottom 500&quot;</bucket></map>
#   </encoding>
#
# parse-twb-layout surfaces those as zone 'series_colors'
# ([{member, color}, …] in .twb document order) + 'series_color_field' (the
# encoded column's caption). The pre-PR-12 palette derivation was
# frequency-ranked (extract_brand_palette) — the member→color BINDING was
# lost, and on a two-series chart the scheme landed positionally, i.e. a
# coin-flip: the field failure was Top/Bottom-500 colors INVERTED on a key
# chart while "palette colors present" still read true.
#
# The fix is ordering, not colors: Sigma applies a categorical `scheme` (and
# `themeOverrides.categoricalScheme`) POSITIONALLY in category-SORT order —
# ascending by member value, which is Sigma's default legend/category order.
# So an ordered scheme = members sorted ascending, each slot carrying that
# member's .twb color. "Bottom 500" < "Top 500" ⇒ scheme[0] is Bottom's
# color — the member→color mapping survives whatever the palette order was.
#
# Where the .twb has NO explicit assignment the caller keeps the current
# frequency-ranked palette derivation unchanged (never worse).
#
# Pure: no I/O. Unit-tested by test-format-map.rb + the extraction/emission
# tests; consumed by build-charts-from-signals.rb and lib/theme_derive.rb.
module SeriesColors
  module_function

  HEX = /\A#[0-9a-f]{6}\z/.freeze

  # Ordered scheme for one chart: members ascending (case-insensitive), one
  # color per slot. nil unless there are ≥2 well-formed assignments.
  def ordered_scheme(pairs)
    good = Array(pairs).select do |p|
      p.is_a?(Hash) && !p['member'].to_s.empty? && p['color'].to_s.downcase =~ HEX
    end
    return nil if good.size < 2
    good.sort_by { |p| p['member'].to_s.downcase }.map { |p| p['color'].to_s.downcase }
  end

  # Does the .twb color-encoding field bind to THIS chart's color column?
  # A blank field (encoding present but caption unresolved) matches — the map
  # still came from this worksheet's only color encoding.
  def field_matches?(field_caption, column_name)
    f = norm(field_caption)
    return true if f.empty?
    c = norm(column_name)
    !c.empty? && (f == c || f.include?(c) || c.include?(f))
  end

  # D2 (PR-13): dashboard-wide member→color dict for ONE color field, merged
  # across every sibling zone that carries explicit .twb assignments on a
  # MATCHING field. A chart that colors by the same category but has no
  # explicit map of its own (Tableau only serializes the map on worksheets
  # where the author touched the legend) would otherwise fall to the
  # frequency-ranked theme palette — positional, so "West" can be teal on one
  # chart and orange on the next. This pins one category→color everywhere:
  # ordering contract identical to ordered_scheme (ascending member = Sigma's
  # positional category-sort application), first assignment wins on conflict.
  # Zones with a BLANK series_color_field are excluded — without a resolved
  # caption there is no evidence the sibling colors by the same category, and
  # gluing unrelated fields together would be worse than the theme palette.
  # nil unless >=2 members merged (a 1-color scheme recolors the whole chart).
  def scheme_for_field(zones, column_name)
    return nil if norm(column_name).empty?
    members = {}
    Array(zones).each do |z|
      next unless z.is_a?(Hash) && z['series_colors'].is_a?(Array)
      next if norm(z['series_color_field']).empty?
      next unless field_matches?(z['series_color_field'], column_name)
      z['series_colors'].each do |p|
        next unless p.is_a?(Hash)
        m = p['member'].to_s
        c = p['color'].to_s.downcase
        members[m] = c if !m.empty? && c =~ HEX && !members.key?(m)
      end
    end
    return nil if members.size < 2
    members.keys.sort_by(&:downcase).map { |k| members[k] }
  end

  # Dashboard-level ordered scheme for themeOverrides.categoricalScheme — the
  # ONLY color path for pie/donut slices (per-element color.scheme is silently
  # dropped there). Conservative: only when every explicitly-assigned zone
  # colors by the SAME field (else positional theme matching is ill-defined →
  # nil, caller falls back to the frequency-ranked palette). Member colors
  # merge across zones, first assignment wins; order is ascending by member.
  def explicit_scheme_for_dashboard(dash, cap = 20)
    zones = dash.is_a?(Hash) ? dash['zones'] : nil
    return nil unless zones.is_a?(Array)
    assigned = zones.select do |z|
      z.is_a?(Hash) && z['series_colors'].is_a?(Array) && z['series_colors'].size >= 2
    end
    return nil if assigned.empty?
    fields = assigned.map { |z| norm(z['series_color_field']) }.uniq
    return nil if fields.size > 1
    members = {}
    assigned.each do |z|
      z['series_colors'].each do |p|
        next unless p.is_a?(Hash)
        m = p['member'].to_s
        c = p['color'].to_s.downcase
        members[m] = c if !m.empty? && c =~ HEX && !members.key?(m)
      end
    end
    return nil if members.size < 2
    members.keys.sort_by(&:downcase).map { |k| members[k] }.first(cap)
  end

  # Per-tile ledger rows for formats-emitted.json ('series_color_maps') — the
  # mechanical counterpart for the blind grader's `palette_match` dimension:
  # source member→color assignments vs the scheme the element actually
  # carries. status: 'pinned' (ordered scheme emitted) | 'theme' (pie/donut —
  # rides themeOverrides positionally) | 'unpinned'.
  def records(elements, worksheets_meta)
    Array(elements).map do |el|
      next unless el.is_a?(Hash) && !el['_worksheet'].to_s.empty?
      ws = (worksheets_meta || {})[el['_worksheet'].to_s] || {}
      sc = ws['series_colors']
      next unless sc.is_a?(Array) && sc.any?
      scheme = el['color'].is_a?(Hash) ? el['color']['scheme'] : nil
      status =
        if scheme then 'pinned'
        elsif %w[pie-chart donut-chart].include?(el['kind'].to_s) then 'theme'
        else 'unpinned'
        end
      { 'element_id' => el['id'], 'worksheet' => el['_worksheet'],
        'dashboard' => el['_dashboard'], 'field' => ws['series_color_field'],
        'source_assignments' => sc, 'emitted_scheme' => scheme,
        'status' => status }
    end.compact
  end

  def norm(s)
    s.to_s.downcase.gsub(/\W+/, '')
  end
end
