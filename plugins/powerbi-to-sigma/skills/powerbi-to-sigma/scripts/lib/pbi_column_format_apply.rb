# frozen_string_literal: true
#
# pbi_column_format_apply.rb — post-build pass for an ALREADY-BUILT workbook spec: re-derive the
# Power BI static per-column fills (signals visual `column_formats`) and the theme palette
# (signals `theme` / `theme_data_colors`) and apply them to the spec in place. Pure + offline
# (no I/O, no globals); scripts/apply-pbi-column-formats.rb is the CLI. Idempotent.
#
# Ruby 2.6 floor (no endless defs, no filter_map).
require_relative 'ruby_compat'
require_relative 'pbi_theme'
require_relative 'pbi_conditional_formats'
require_relative 'polish_layout'

module PbiColumnFormatApply
  module_function

  def doc_of(spec)
    spec['document'].is_a?(Hash) ? spec['document'] : spec
  end

  # {queryRef => column id} for a built table / pivot, reconstructed from the visual's bindings
  # exactly as the builder names its columns (table Values -c<i>; pivot Rows/Category -r<i>,
  # Columns -col<i>, Values -v<i>). A queryRef is only included when that id exists on the element.
  def binding_map(el, bindings)
    return {} unless bindings.is_a?(Hash)
    eid = el['id']
    have = Array(el['columns']).select { |c| c.is_a?(Hash) && c['id'] }.map { |c| c['id'] }
    groups = [[Array(bindings['Values']), 'c'], [Array(bindings['Rows'] || bindings['Category']), 'r'],
              [Array(bindings['Columns']), 'col'], [Array(bindings['Values']), 'v']]
    map = {}
    groups.each do |qrs, pfx|
      qrs.each_with_index do |qr, i|
        cid = "#{eid}-#{pfx}#{i}"
        map[qr.to_s] = cid if qr.is_a?(String) && have.include?(cid)
      end
    end
    map
  end

  # Returns [map, ambiguous_names]. Prefers the binding-derived queryRef map; otherwise falls back to
  # display names, EXCLUDING any name shared by two columns (never guess which one a fill meant).
  def target_map(el, display_names, bindings = nil)
    bm = binding_map(el, bindings)
    return [bm, []] unless bm.empty?
    cols = Array(el['columns']).select { |c| c.is_a?(Hash) && c['id'] }
    cols = if el['kind'] == 'pivot-table'
             ids = (Array(el['values']) + Array(el['rowsBy']).map { |r| r.is_a?(Hash) ? r['columnId'] : r } +
                    Array(el['columnsBy']).map { |r| r.is_a?(Hash) ? r['columnId'] : r }).map(&:to_s)
             cols.select { |c| ids.include?(c['id']) }
           else
             cols.reject { |c| c['hidden'] }
           end
    count = Hash.new(0)
    cols.each { |c| count[c['name'].to_s] += 1 if c['name'] }
    amb = count.select { |_, n| n > 1 }.keys
    map = {}
    cols.each { |c| map[c['name'].to_s] = c['id'] if c['name'] && !amb.include?(c['name'].to_s) }
    (display_names || {}).each do |qr, disp|
      cid = map[disp.to_s]
      map[qr.to_s] = cid if cid
    end
    [map, amb]
  end

  # Mutates spec. Returns { 'palette' =>, 'elements' => [{id, name, added, skipped_existing,
  # coverage}], 'theme_changed' => bool }.
  def apply(spec, signals, theme_only: false)
    doc = doc_of(spec)
    pal = PbiTheme.palette(signals['theme'], signals['theme_data_colors'])
    prev_accent = previous_accent(doc)
    summary = { 'palette' => pal, 'elements' => [], 'theme_changed' => apply_theme!(doc, pal) }
    card = PbiTheme.card_value_color(signals['theme'], signals['theme_data_colors'])
    summary['kpis_recolored'] = recolor_kpis!(doc, signals, prev_accent, card, pal)
    return summary if theme_only

    els = {}
    Array(doc['elements']).each { |e| els[e['id']] = e if e.is_a?(Hash) }
    Array(signals['pages']).each do |pg|
      Array(pg['visuals']).each do |v|
        # Every table / pivot tied to a signals visual is examined, with or without fills: a fill that
        # left the signals (or became header/total-only) must not leave its old value-cell rule behind.
        cfs = v['column_formats'].is_a?(Array) ? v['column_formats'] : []
        el = els[PolishLayout.element_id_for(v['visual_id'])]
        next unless el && %w[table pivot-table].include?(el['kind'])
        name = el['name'].is_a?(String) ? el['name'] : el['id']
        tmap, amb = target_map(el, v['display_names'], v['bindings'])
        ambiguous = []
        use = cfs
        unless amb.empty?
          amb_l = amb.map(&:downcase)
          use = cfs.reject do |cf|
            hit = !tmap.key?(cf['target'].to_s) && amb_l.include?(PbiConditionalFormats.leaf(cf['target']).downcase)
            ambiguous << cf['target'] if hit
            hit
          end
        end
        res = PbiConditionalFormats.column_fill_formats(use, tmap, name, el['kind'], pal)
        ambiguous.uniq.each do |t|
          res['coverage'] << { visual: name, pbi_type: 'column-format', sigma_kind: el['kind'],
                               severity: 'degraded', recoverable: true,
                               detail: "column fill on '#{t}' skipped — column name is ambiguous in the built element; rebuild to apply" }
        end
        existing = Array(el['conditionalFormats'])
        # Converge on the CURRENT signals. The pass owns rules of the exact column-fill shape (single /
        # formula True / one column id; only column fills emit it). Per column, such a rule not in the
        # wanted set is removed and wanted rules that are missing are added (in builder order); a
        # fill-shaped rule on a column with no wanted fill any more is removed. Other shapes stay, so a
        # fresh builder-built spec is a no-op and a palette change swaps the colour instead of stacking.
        wanted = {}
        res['formats'].each { |f| (wanted[f['columnIds'][0]] ||= []) << f }
        fill_shape = lambda do |r, cid|
          r.is_a?(Hash) && r['type'] == 'single' && r['condition'] == 'formula' &&
            r['formula'] == 'True' && r['columnIds'] == [cid]
        end
        added = 0
        skipped = 0
        before = existing.length
        existing.reject! do |r|
          r.is_a?(Hash) && Array(r['columnIds']).length == 1 && !wanted.key?(r['columnIds'][0]) &&
            fill_shape.call(r, r['columnIds'][0])
        end
        removed = before - existing.length
        wanted.each do |cid, fs|
          pool = fs.dup
          existing.reject! do |r|
            next false unless fill_shape.call(r, cid)
            if (i = pool.index(r))
              pool.delete_at(i)
              skipped += 1
              next false
            end
            true
          end
          pool.each do |f|
            existing << f
            added += 1
          end
        end
        if existing.empty?
          el.delete('conditionalFormats')
        else
          el['conditionalFormats'] = existing
        end
        next if cfs.empty? && removed.zero? # nothing to report for an element that never had fills
        summary['elements'] << { 'id' => el['id'], 'name' => name, 'added' => added, 'removed' => removed,
                                 'skipped_existing' => skipped, 'coverage' => res['coverage'] }
      end
    end
    summary
  end

  # The accent the spec was built with (the builder colors KPI values with it when Power BI set none).
  def previous_accent(doc)
    ov = (((doc['settings'] || {})['theme'] || {})['overrides'] || {})
    (ov['colors'] || {})['highlight'] || Array(ov['categoricalScheme']).first
  end

  # KPI cards built from a signals visual with no explicit Power BI value color, whose value is still in the
  # previous accent (or unset), get the theme's card value color. Returns the number changed.
  def recolor_kpis!(doc, signals, prev_accent, card, pal = nil)
    explicit = {}
    Array(signals['pages']).each do |pg|
      Array(pg['visuals']).each do |v|
        explicit[PolishLayout.element_id_for(v['visual_id'])] =
          PbiTheme.resolve_color_signal(v['value_color'], pal)
      end
    end
    tile_default = PbiTheme.multi_row_card_value_color(signals['theme'])
    n = 0
    Array(doc['elements']).each do |el|
      next unless el.is_a?(Hash) && el['kind'] == 'kpi-chart'
      # A multi-row card is built as one tile per measure (<visual eid>-k<i>); map a tile to its visual.
      key = el['id']
      tile = !explicit.key?(key) && explicit.key?(key.to_s.sub(PolishLayout::KPI_SUB, ''))
      key = key.to_s.sub(PolishLayout::KPI_SUB, '') if tile
      next unless explicit.key?(key)
      val = (el['value'] ||= {})
      cur = val['color']
      if (want = explicit[key])
        # An explicit Power BI colour (hex, or a theme colour resolved on the CURRENT palette) is painted.
        next if cur.to_s.casecmp(want.to_s).zero?
        val['color'] = want
        n += 1
        next
      end
      if tile
        # Tiles never carried the accent; only the multi-row default (classic dark gray) is filled in.
        next if tile_default.nil? || !cur.nil?
        val['color'] = tile_default
        n += 1
        next
      end
      next unless cur.nil? || (prev_accent && cur.to_s.casecmp(prev_accent.to_s).zero?)
      next if cur.to_s.casecmp(card.to_s).zero?
      val['color'] = card
      n += 1
    end
    n
  end

  def apply_theme!(doc, pal)
    settings = (doc['settings'] ||= {})
    theme = (settings['theme'] ||= { 'name' => 'Light' })
    ov = (theme['overrides'] ||= {})
    colors = (ov['colors'] ||= {})
    before = [ov['categoricalScheme'], colors['highlight']]
    ov['categoricalScheme'] = pal
    colors['highlight'] = pal.first
    before != [ov['categoricalScheme'], colors['highlight']]
  end
end
