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

  # Tableau's default categorical palette ("Tableau 10"), in assignment order.
  TABLEAU10 = %w[#4e79a7 #f28e2b #e15759 #76b7b2 #59a14f
                 #edc948 #b07aa1 #ff9da7 #9c755f #bab0ac].freeze

  # C5: members in Tableau's order — the source's manual sort first (only the
  # members actually present), then the rest ascending alphabetical (Tableau's
  # default). Pure.
  def tableau_member_order(members, manual_order = nil)
    ms = Array(members).map { |m| m.to_s.strip }.reject(&:empty?).uniq
    manual = Array(manual_order).map { |m| m.to_s.strip }
    lead = manual.select { |m| ms.include?(m) }.uniq
    lead + (ms - lead).sort_by { |m| [m.downcase, m] }
  end

  # C5 (and the interface for the legend task): the resolved, ORDERED member →
  # hex map for one colour dimension. With no explicit assignment Tableau hands
  # TABLEAU10 out in member order (cycling past 10); an explicit per-member
  # colour (case-insensitive lookup in `explicit`) always wins for that member.
  # Hash order = Tableau's member order. Pure.
  def resolved_member_map(members, explicit = {}, manual_order = nil)
    lookup = (explicit.is_a?(Hash) ? explicit : {}).each_with_object({}) do |(k, v), h|
      h[k.to_s.downcase] = v.to_s.downcase if v.to_s.downcase =~ HEX
    end
    tableau_member_order(members, manual_order).each_with_index.each_with_object({}) do |(m, i), h|
      h[m] = lookup[m.downcase] || TABLEAU10[i % TABLEAU10.size]
    end
  end

  # Sigma binds a categorical scheme positionally in ASCENDING member order, so
  # the scheme is the resolved map's colours re-sorted to that order (a manual
  # Tableau order is carried by each member's colour, not by slot position).
  def scheme_from_map(map)
    return nil unless map.is_a?(Hash) && map.size >= 2
    map.keys.sort_by { |m| m.to_s.downcase }.map { |m| map[m] }
  end

  # Ordered scheme for one chart: members ascending (case-insensitive), one
  # color per slot. nil unless there are ≥2 well-formed assignments.
  def ordered_scheme(pairs)
    good = Array(pairs).select do |p|
      p.is_a?(Hash) && !p['member'].to_s.empty? && p['color'].to_s.downcase =~ HEX
    end
    return nil if good.size < 2
    good.sort_by { |p| p['member'].to_s.downcase }.map { |p| p['color'].to_s.downcase }
  end

  # Chart-membership scheme. Sigma applies a categorical scheme positionally
  # over the members PRESENT in the chart (ascending), so a map that names five
  # members pinned as a five-slot scheme shifts every color when the chart shows
  # only four of them (a Top-N chart colored by Category, a filtered view):
  # slot 2 lands on the wrong member. Re-derive the scheme over the chart's own
  # members — each member's mapped color, ascending member order. A member the
  # map does not name takes the next palette color the map has not used (nil
  # when none is left, so the caller keeps its fallback). Pure.
  #   map:      { 'Apparel' => '#4e79a7', … } (member → hex)
  #   members:  the chart's category members (CSV rows)
  #   fallback: ordered palette for unmapped members
  def scheme_for_members(map, members, fallback = [])
    ms = Array(members).map { |m| m.to_s.strip }.reject(&:empty?).uniq
    return nil if ms.size < 2 || !map.is_a?(Hash)
    lookup = map.each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v.to_s.downcase }
    return nil unless ms.any? { |m| lookup.key?(m.downcase) }
    spare = Array(fallback).map { |c| c.to_s.downcase }.select { |c| c =~ HEX } - lookup.values
    scheme = ms.sort_by(&:downcase).map { |m| lookup[m.downcase] || spare.shift }
    scheme.any?(&:nil?) ? nil : scheme
  end

  # member → color dict for ONE worksheet's explicit pairs (first wins).
  def member_map(pairs)
    Array(pairs).each_with_object({}) do |p, h|
      next unless p.is_a?(Hash) && !p['member'].to_s.empty? && p['color'].to_s.downcase =~ HEX
      h[p['member'].to_s] ||= p['color'].to_s.downcase
    end
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
    members = member_map_for_field(zones, column_name)
    return nil if members.size < 2
    members.keys.sort_by(&:downcase).map { |k| members[k] }
  end

  # The merged member → color dict behind scheme_for_field (empty when no
  # sibling carries an assignment on a matching, resolved field).
  def member_map_for_field(zones, column_name)
    return {} if norm(column_name).empty?
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
    members
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
