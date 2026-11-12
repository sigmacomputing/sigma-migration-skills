# frozen_string_literal: true
#
# polish_layout.rb — pure functions for the layout POLISH pass (scripts/polish-layout.rb).
#
# WHY. Migrated pages either reproduce the source canvas 1:1 (`--layout pbi`: right arrangement,
# ragged rendering) or reflow into uniform bands (`--layout clean`: tidy, but the arrangement is
# lost). The polish pass keeps the source's ARRANGEMENT (grouping + reading order) and renders it
# to the house design rules (refs/layout-visual-qa.md, "Building clean in the first place").
# It runs AFTER any layout mode: it ignores the existing geometry and re-derives the layout from the
# SOURCE boxes in signals.json.
#
# Pipeline per page (see `polish_page`):
#   1. classify the page's elements: header / visible controls / hidden controls / legend controls /
#      content (kpi, chart, table, pivot, text, image, other)
#   2. XY-cut tree over the content elements' source boxes (`xy_cut`): horizontal cut first (bands
#      top-to-bottom), else vertical cut (columns left-to-right), else rows sorted by (y, x)
#   3. render the tree onto the 24-column grid (`render`)
#   4. stack the page bands: header, control band, content, hidden-controls band
#   5. element tweaks (presentation tables, blank nulls, heading marks)
#
# Pure: no I/O, no globals. Ruby 2.6 floor (no endless defs, no filter_map).
require 'digest'
require 'rexml/document'
require_relative 'ruby_compat'
require_relative 'layout'

module PolishLayout
  module_function

  # An overlap smaller than this (px) between two boxes does not block a cut (sloppy source alignment).
  CUT_TOL = 8
  # Minimum grid columns per element class (clean mode's per-kind minimums).
  MIN_COLS = { chart: 6, table: 8, kpi: 3, text: 4, image: 4, other: 3 }.freeze
  HARD_MIN_COLS = 2 # when the minimums overflow the span they are scaled down, never below this
  KPI_ROWS = 5
  CHART_ROWS = 10
  CHART_TALL_ROWS = 12
  CHART_TALL_PX = 300
  # Presentation-style rows are taller than one grid row (live renders: a 6-row pivot showed 4 rows,
  # a 15-row pivot 10, an 8-row pivot with 3 column-header levels 4), so a table needs ~1.25 grid rows
  # per data row; a pivot also pays 2 rows per column-header level.
  TABLE_BASE_ROWS = 5
  TABLE_ROW_FACTOR = 1.25
  TABLE_MIN_ROWS = 10
  TABLE_MAX_ROWS = 30
  PIVOT_MAX_ROWS = 32
  PIVOT_LEVEL_ROWS = 2
  TABLE_DEFAULT_CARDINALITY = 14
  CAPTION_ROWS = 3
  CAPTION_CHARS_PER_ROW = 180
  LABEL_ROWS = 2
  LABEL_MAX_CHARS = 40
  CAPTION_MIN_CHARS = 120
  CONTROL_ROWS = 3
  CONTROL_COLS = 4
  DATE_RANGE_COLS = 6
  CONTROLS_PER_ROW = 6
  HIDDEN_HDR_ROWS = 2
  HIDDEN_MODES = %w[drawer band].freeze
  DRAWER_ROWS = 3 # grid rows per hidden control inside the drawer page
  BUTTON_COLS = 4
  HIDDEN_HDR_TEXT = '**More filters** (hidden in the source report)'
  # Cell geometry (live-measured; ported from tableau-to-sigma's lib/pivot_widths.rb, which holds the
  # live-verified pivot width rules: both pivot widths are emitted together and always fit the cell,
  # never `columns[]` on a pivot, never `tableStyle.autofitColumns`).
  PAGE_CANVAS_PX = 1536 # 1600px render less 64px page padding
  TILE_GAP_PX = 16
  ELEMENT_PADDING_PX = 32
  PX_PER_CHAR = 7
  PADDING_PX = 16
  HEADER_SHARE = 0.35
  SLACK_PX = 8
  LEGIBLE_BODY_PX = 48
  PIVOT_UNKNOWN_HEADER_CHARS = 20
  TABLE_WIDTH_MIN_COLS = 6 # flat tables with MORE columns than this get explicit column widths
  COL_MIN_PX = 60
  COL_WEIGHT_TEXT = 1.4
  COL_WEIGHT_NUMBER = 1.0
  COL_WEIGHT_PERCENT = 0.7
  KPI_SNAP_MAX = 3 # a KPI-only column moves at most this many grid columns to reach a peer-count multiple
  LEGEND_COLS = 6
  LEGEND_ROWS = 4
  GRID = SigmaLayout::GRID_COLS

  # ---- ids ------------------------------------------------------------------

  # Same id the builder gives a visual's element (build-workbook-from-pbir.rb `short`; the builder
  # defines it at script top level, so it is mirrored here — test-polish-layout.rb keeps them in lockstep).
  def short_id(id)
    clean = id.to_s.gsub(/[^a-zA-Z0-9]/, '').downcase
    # Not a security use: a short deterministic id tag that must stay stable across runs.
    # nosemgrep: ruby.lang.security.weak-hashes-sha1.weak-hashes-sha1
    h = Digest::SHA1.hexdigest(id.to_s)[0, 6]
    "#{clean[-6, 6] || clean}#{h}"
  end

  def element_id_for(visual_id)
    "el-#{short_id(visual_id)}"
  end

  KPI_SUB = /-k\d+\z/.freeze

  # ---- classification -------------------------------------------------------

  def kind_class(el)
    k = el['kind'].to_s
    case k
    when 'control' then :control
    when 'container' then :container
    when 'kpi-chart', 'progress' then :kpi
    when 'table', 'pivot-table', 'input-table' then :table
    when 'text' then :text
    when 'image' then :image
    else
      k.end_with?('-chart') || k.end_with?('-map') ? :chart : :other
    end
  end

  def stretchable_class?(cls)
    cls == :chart || cls == :table
  end

  def legend_control?(el)
    el['kind'].to_s == 'control' && el['controlType'].to_s == 'legend'
  end

  def html_free(body)
    body.to_s.gsub(/<[^>]+>/, '')
  end

  # Visible text lines of a text body (html stripped, blank lines dropped).
  def text_lines(body)
    html_free(body).lines.map(&:strip).reject(&:empty?)
  end

  def strip_heading(line)
    line.sub(/\A#+[ \t]+/, '').strip
  end

  # :label (<= 40 chars, one line), :caption (> 120 chars or multi-line), else :text.
  def text_subclass(body)
    lines = text_lines(body)
    return :caption if lines.empty?
    return :caption if lines.length > 1
    one = strip_heading(lines.first)
    return :caption if one.length > CAPTION_MIN_CHARS
    one.length <= LABEL_MAX_CHARS ? :label : :text
  end

  # ---- leaf heights ---------------------------------------------------------

  # table: clamp(5 + ceil(1.25 n), 10, 30); pivot: clamp(5 + ceil(1.25 n) + 2 L, 10, 32) with
  # L = column-header levels (`columnsBy` entries) and n + 1 when the pivot has a totals row.
  def table_rows(n, pivot: false, levels: 0, totals: false)
    n = TABLE_DEFAULT_CARDINALITY if n.nil? || n.to_i <= 0
    n = n.to_i
    n += 1 if pivot && totals
    rows = TABLE_BASE_ROWS + (TABLE_ROW_FACTOR * n).ceil
    return rows.clamp(TABLE_MIN_ROWS, TABLE_MAX_ROWS) unless pivot
    (rows + PIVOT_LEVEL_ROWS * levels.to_i).clamp(TABLE_MIN_ROWS, PIVOT_MAX_ROWS)
  end

  def pivot_totals?(el)
    t = el['totals']
    t.is_a?(Hash) && t['showGrandTotals'].to_s != 'hidden'
  end

  # Grid rows for a content leaf (never below SigmaLayout::KIND_MIN_ROWS).
  def leaf_rows(leaf)
    el = leaf[:el]
    base =
      case leaf[:cls]
      when :kpi then KPI_ROWS
      when :chart
        leaf[:src_h].to_f >= CHART_TALL_PX ? CHART_TALL_ROWS : CHART_ROWS
      when :table
        if el['kind'] == 'pivot-table'
          table_rows(leaf[:cardinality], pivot: true, levels: Array(el['columnsBy']).length, totals: pivot_totals?(el))
        else
          table_rows(leaf[:cardinality])
        end
      when :text
        if leaf[:sub] == :label
          LABEL_ROWS
        else
          n = strip_heading(text_lines(el['body']).join(' ')).length
          CAPTION_ROWS + (n / CAPTION_CHARS_PER_ROW)
        end
      else 0
      end
    [base, SigmaLayout.min_rows_for(el['kind'])].max
  end

  # ---- XY-cut tree ----------------------------------------------------------
  # leaf = { id:, cls:, el:, x0:, y0:, x1:, y1:, ... }
  # node = { t: :leaf, leaf: } | { t: :rows, kids: } (top-to-bottom) | { t: :cols, kids: } (left-to-right)

  def leaf_node(leaf)
    { t: :leaf, leaf: leaf }
  end

  def axis_keys(axis)
    axis == :y ? %i[y0 y1 x0 x1] : %i[x0 x1 y0 y1]
  end

  # Split `items` into groups along `axis` (:y = bands top-to-bottom, :x = columns left-to-right) at every
  # position no box crosses. An overlap smaller than CUT_TOL is ignored UNLESS the two boxes are disjoint
  # on the other axis (then they sit side by side, and stacking them would break their left/right order).
  def split_axis(items, axis)
    lo, hi, olo, ohi = axis_keys(axis)
    s = items.each_with_index.sort_by { |it, i| [it[lo], it[olo], i] }.map(&:first)
    cuts = []
    (0...(s.length - 1)).each do |i|
      top = s[0..i]
      bot = s[(i + 1)..-1]
      next unless top.map { |t| t[hi] }.max <= bot.map { |b| b[lo] }.min + CUT_TOL
      stacked_ok = top.all? do |a|
        bot.all? do |b|
          a[hi] <= b[lo] || (a[ohi] > b[olo] && b[ohi] > a[olo])
        end
      end
      cuts << i if stacked_ok
    end
    return [s] if cuts.empty?
    groups = []
    from = 0
    cuts.each do |c|
      groups << s[from..c]
      from = c + 1
    end
    groups << s[from..-1]
    groups
  end

  # No cut exists (pinwheel / overlapping boxes): rows sorted by (y, x), each row left-to-right.
  def fallback_rows(items)
    s = items.each_with_index.sort_by { |it, i| [it[:y0], it[:x0], i] }.map(&:first)
    rows = []
    s.each do |it|
      # a row is anchored on its FIRST box (chained overlaps would otherwise fuse a pinwheel into one row)
      if rows.any? && it[:y0] < rows.last[:bottom] - CUT_TOL
        rows.last[:items] << it
      else
        rows << { items: [it], bottom: it[:y1] }
      end
    end
    kids = rows.map do |r|
      its = r[:items].each_with_index.sort_by { |it, i| [it[:x0], i] }.map(&:first)
      its.length == 1 ? leaf_node(its.first) : { t: :cols, kids: its.map { |x| leaf_node(x) } }
    end
    kids.length == 1 ? kids.first : { t: :rows, kids: kids }
  end

  def xy_cut(items)
    return nil if items.empty?
    return leaf_node(items.first) if items.length == 1
    bands = split_axis(items, :y)
    return { t: :rows, kids: bands.map { |b| xy_cut(b) } } if bands.length > 1
    cols = split_axis(items, :x)
    return { t: :cols, kids: cols.map { |c| xy_cut(c) } } if cols.length > 1
    fallback_rows(items)
  end

  def node_leaves(node)
    node[:t] == :leaf ? [node[:leaf]] : node[:kids].flat_map { |k| node_leaves(k) }
  end

  def node_bbox(node)
    ls = node_leaves(node)
    [ls.map { |l| l[:x0] }.min, ls.map { |l| l[:y0] }.min, ls.map { |l| l[:x1] }.max, ls.map { |l| l[:y1] }.max]
  end

  # Compact arrangement string for summaries/tests: `a | b` = columns, `a / b` = bands.
  def shape(node, top = true)
    case node[:t]
    when :leaf then node[:leaf][:cls].to_s
    when :rows
      s = node[:kids].map { |k| shape(k, false) }.join(' / ')
      top ? s : "(#{s})"
    else
      s = node[:kids].map { |k| shape(k, false) }.join(' | ')
      top ? s : "(#{s})"
    end
  end

  # ---- rendering onto the grid ---------------------------------------------

  def natural_rows(node)
    case node[:t]
    when :leaf then node[:leaf][:rows]
    when :rows then node[:kids].sum { |k| natural_rows(k) }
    else node[:kids].map { |k| natural_rows(k) }.max
    end
  end

  def stretchable?(node)
    node_leaves(node).any? { |l| stretchable_class?(l[:cls]) }
  end

  def min_cols(node)
    case node[:t]
    when :leaf then MIN_COLS.fetch(node[:leaf][:cls], 3)
    when :rows then node[:kids].map { |k| min_cols(k) }.max
    else node[:kids].sum { |k| min_cols(k) }
    end
  end

  # Integer widths for sibling columns, summing exactly to `total`: proportional to the source widths,
  # never below each column's minimum (scaled down proportionally when the minimums overflow), and
  # exactly equal (+/- 1 for the remainder) when every sibling is a KPI card (true peers).
  def alloc_widths(kids, total)
    n = kids.length
    if kids.all? { |k| k[:t] == :leaf && k[:leaf][:cls] == :kpi }
      base, rem = total.divmod(n)
      return Array.new(n) { |i| base + (i < rem ? 1 : 0) }
    end
    mins = kids.map { |k| min_cols(k) }
    if mins.sum > total
      sum = mins.sum.to_f
      mins = mins.map { |m| [(m * total / sum).floor, HARD_MIN_COLS].max }
      while mins.sum > total
        i = (0...n).max_by { |j| [mins[j], -j] }
        break if mins[i] <= 1
        mins[i] -= 1
      end
    end
    weights = kids.map do |k|
      b = node_bbox(k)
      [b[2] - b[0], 1.0].max
    end
    widths = Array.new(n)
    free = (0...n).to_a
    remaining = total
    loop do
      sumw = free.sum { |i| weights[i] }.to_f
      clamped = free.select { |i| remaining * weights[i] / sumw < mins[i] }
      break if clamped.empty?
      clamped.each do |i|
        widths[i] = mins[i]
        remaining -= mins[i]
      end
      free -= clamped
      break if free.empty?
    end
    unless free.empty?
      sumw = free.sum { |i| weights[i] }.to_f
      ideal = free.map { |i| remaining * weights[i] / sumw }
      floors = ideal.map(&:floor)
      left = remaining - floors.sum
      order = (0...free.length).sort_by { |j| [-(ideal[j] - floors[j]), j] }
      order.first(left).each { |j| floors[j] += 1 }
      free.each_with_index { |i, j| widths[i] = floors[j] }
    end
    snap_kpi_columns!(kids, widths)
    widths
  end

  def kpi_leaf?(node)
    node[:t] == :leaf && node[:leaf][:cls] == :kpi
  end

  # Peers per row of a column made ONLY of KPI cards: [3, 2] for a row of three over a row of two;
  # nil when anything else is in the column.
  def kpi_peer_counts(node)
    return [1] if kpi_leaf?(node)
    return nil if node[:t] == :leaf
    if node[:t] == :cols
      return node[:kids].all? { |k| kpi_leaf?(k) } ? [node[:kids].length] : nil
    end
    counts = node[:kids].map { |k| kpi_peer_counts(k) }
    counts.any?(&:nil?) ? nil : counts.flatten
  end

  # A KPI-only column is widened/narrowed to the nearest multiple of lcm(peer counts per row) so every
  # card in a row gets the same span (3 + 2 cards in 11 columns -> 12: spans 4/4/4 and 6/6). The
  # difference is lent to / borrowed from an ADJACENT sibling column, within +/- KPI_SNAP_MAX columns
  # and never below the sibling's minimum. Mutates `widths` (the total is unchanged).
  def snap_kpi_columns!(kids, widths)
    return widths if kids.length < 2 || kids.all? { |k| kpi_leaf?(k) }
    lcms = kids.map do |k|
      counts = kpi_peer_counts(k)
      counts ? counts.reduce(1) { |a, b| a.lcm(b) } : 1
    end
    # Pass 1 (strict): a KPI-only sibling may only be lent to / borrowed from when it lands on ITS OWN
    # lcm multiple too, so one snap never undoes another (A=16/B=8 for 3 and 2 peers -> 18/6, not a
    # 15/9 <-> 16/8 ping-pong). Pass 2 (loose) snaps what pass 1 could not, without breaking a sibling
    # that is already snapped.
    [true, false].each do |strict|
      kids.each_index do |i|
        l = lcms[i]
        next if l <= 1 || (widths[i] % l).zero?
        lo = (widths[i] / l) * l
        cands = [lo, lo + l, lo - l, lo + 2 * l].select { |m| m >= l && (m - widths[i]).abs <= KPI_SNAP_MAX }
        cands = cands.uniq.sort_by { |m| [(m - widths[i]).abs, m] }
        sibs = [i + 1, i - 1].select { |j| j >= 0 && j < kids.length }
        cands.each do |m|
          next unless m >= min_cols(kids[i])
          delta = widths[i] - m # > 0: the sibling gains columns
          sib = sibs.find do |j|
            nw = widths[j] + delta
            next false if nw < min_cols(kids[j])
            lj = lcms[j]
            next true if lj <= 1
            strict ? (nw % lj).zero? : (!(widths[j] % lj).zero? || (nw % lj).zero?)
          end
          next unless sib
          widths[sib] += delta
          widths[i] = m
          break
        end
      end
    end
    widths
  end

  # Render `node` into the box starting at (col line `c0`, row line `r0`) of width `w` columns.
  # `target` = rows the node must fill (equalising sibling columns): the LAST stretchable subtree of a
  # band absorbs the surplus; KPIs and text are never stretched.
  # Returns [cells, height]; cell = [leaf, c0, c1, r0, r1] (absolute lines, end-exclusive).
  def render(node, c0, w, r0, target = 0)
    case node[:t]
    when :leaf
      leaf = node[:leaf]
      h = leaf[:rows]
      h = target if target > h && stretchable_class?(leaf[:cls])
      [[[leaf, c0, c0 + w, r0, r0 + h]], h]
    when :rows
      nat = natural_rows(node)
      surplus = [target - nat, 0].max
      sk = node[:kids].each_index.select { |i| stretchable?(node[:kids][i]) }.last
      cells = []
      cursor = r0
      node[:kids].each_with_index do |kid, i|
        kc, kh = render(kid, c0, w, cursor, natural_rows(kid) + (i == sk ? surplus : 0))
        cells.concat(kc)
        cursor += kh
      end
      [cells, cursor - r0]
    else
      kids = node[:kids]
      # more columns than the grid can hold at HARD_MIN_COLS: wrap into rows (reading order kept)
      if kids.length * HARD_MIN_COLS > w
        per = [w / HARD_MIN_COLS, 1].max
        wrapped = { t: :rows, kids: kids.each_slice(per).map { |g| g.length == 1 ? g.first : { t: :cols, kids: g } } }
        return render(wrapped, c0, w, r0, target)
      end
      widths = alloc_widths(kids, w)
      h = [target, natural_rows(node)].max
      cells = []
      edge = c0
      kids.each_with_index do |kid, i|
        kc, = render(kid, edge, widths[i], r0, h)
        cells.concat(kc)
        edge += widths[i]
      end
      [cells, h]
    end
  end

  # ---- control band ---------------------------------------------------------

  # Reading order for controls: cluster into rows by source y (within CUT_TOL of the row's first y), then
  # left to right by x inside each row, so slicers on one visual row with slightly different y keep
  # their left-to-right order. Records without a position sort last, in element order.
  def control_order(ctrls)
    inf = Float::INFINITY
    by_y = ctrls.sort_by { |c| [c[:y] || inf, c[:x] || inf, c[:order]] }
    rows = []
    by_y.each do |c|
      y = c[:y] || inf
      if rows.any? && (rows.last[:y] == y || (y - rows.last[:y]).abs <= CUT_TOL)
        rows.last[:items] << c
      else
        rows << { y: y, items: [c] }
      end
    end
    rows.flat_map { |r| r[:items].sort_by { |c| [c[:x] || inf, c[:order]] } }
  end

  # ctrls = [{ id:, date_range: bool }] in reading order -> { height:, cells: [[id, c0, c1, r0, r1]] }
  # with CONTAINER-RELATIVE lines. 4 columns per control (6 for a date range), at most 6 per row,
  # CONTROL_ROWS rows per control row.
  def pack_controls(ctrls)
    rows = []
    ctrls.each do |c|
      w = c[:date_range] ? DATE_RANGE_COLS : CONTROL_COLS
      if rows.empty? || rows.last[:used] + w > GRID || rows.last[:items].length >= CONTROLS_PER_ROW
        rows << { used: 0, items: [] }
      end
      rows.last[:items] << [c[:id], 1 + rows.last[:used], 1 + rows.last[:used] + w]
      rows.last[:used] += w
    end
    cells = []
    rows.each_with_index do |r, ri|
      r[:items].each { |id, a, b| cells << [id, a, b, ri * CONTROL_ROWS + 1, (ri + 1) * CONTROL_ROWS + 1] }
    end
    { height: rows.length * CONTROL_ROWS, cells: cells }
  end

  # ---- layout XML parsing ---------------------------------------------------

  # { page_id => { leaves: [element ids in document order, nested ones included],
  #                containers: [{ id:, top: bool, leaves: [direct + nested leaf ids] }] } }
  def parse_pages(layout_xml)
    body = layout_xml.to_s.sub(/\A\s*<\?xml[^>]*\?>/, '')
    doc = REXML::Document.new("<Layout>#{body}</Layout>")
    out = {}
    doc.root.elements.each('Page') do |page|
      info = { leaves: [], containers: [] }
      walk = lambda do |node, top, acc|
        node.elements.each do |el|
          next unless %w[Element Container].include?(el.name)
          if el.name == 'Element'
            info[:leaves] << el.attributes['elementId']
            acc << el.attributes['elementId'] if acc
          else
            c = { id: el.attributes['elementId'], top: top, leaves: [] }
            info[:containers] << c
            walk.call(el, false, c[:leaves])
            acc.concat(c[:leaves]) if acc
          end
        end
      end
      walk.call(page, true, nil)
      out[page.attributes['id'].to_s] = info
    end
    out
  end

  # ---- spec access ----------------------------------------------------------

  def doc_of(spec)
    spec['document'].is_a?(Hash) ? spec['document'] : spec
  end

  # All workbook elements (flat `elements`; legacy per-page `elements` read for compatibility).
  def all_elements(doc)
    if doc['elements'].is_a?(Array)
      doc['elements'].select { |e| e.is_a?(Hash) }
    else
      Array(doc['pages']).flat_map { |p| p.is_a?(Hash) ? Array(p['elements']).select { |e| e.is_a?(Hash) } : [] }
    end
  end

  def remove_elements!(doc, ids)
    return if ids.empty?
    if doc['elements'].is_a?(Array)
      doc['elements'] = doc['elements'].reject { |e| e.is_a?(Hash) && ids.include?(e['id']) }
    else
      Array(doc['pages']).each do |p|
        next unless p.is_a?(Hash) && p['elements'].is_a?(Array)
        p['elements'] = p['elements'].reject { |e| e.is_a?(Hash) && ids.include?(e['id']) }
      end
    end
  end

  def add_elements!(doc, els, page_id)
    return if els.empty?
    if doc['elements'].is_a?(Array)
      doc['elements'].concat(els)
    else
      pg = Array(doc['pages']).find { |p| p.is_a?(Hash) && p['id'] == page_id } || Array(doc['pages']).first
      pg['elements'] = Array(pg['elements']) + els
    end
  end

  def header_style?(el)
    st = el && el['style']
    st.is_a?(Hash) && st['backgroundColor'].to_s.casecmp(SigmaLayout::HEADER_STYLE['backgroundColor']).zero?
  end

  # ---- element tweaks -------------------------------------------------------

  # tableStyle presentation (unless set) + displayNullAs "" on every number-formatted column so empty
  # cells render blank instead of "null". (kind: number is the only format kind that carries
  # displayNullAs — sigma-workbooks reference/specification/formatting.md.)
  def tweak_table!(el, source = nil, hide_derived_titles = false)
    el['tableStyle'] = { 'preset' => 'presentation' } unless el['tableStyle']
    wrap_column_headers!(el)
    hide_derived_title!(el, source) if hide_derived_titles
    %w[columns metrics].each do |key|
      Array(el[key]).each do |col|
        next unless col.is_a?(Hash) && col['format'].is_a?(Hash) && col['format']['kind'] == 'number'
        col['format']['displayNullAs'] = '' unless col['format'].key?('displayNullAs')
      end
    end
  end

  # Header text wraps instead of clipping (live: a 13-column table truncated its headers). Existing
  # tableStyle keys, including an explicit textWrap / align, win. The column-title key is
  # `textStyles.header` on a flat table; `columnHeader` / `rowHeader` are pivot-only (styling.md
  # "textStyles"). Pivot column headers right-align over their numeric values (a left-aligned header
  # over right-aligned numbers puts each value under the next column's header). A flat table has no
  # per-column header alignment in the spec, so its headers keep the default alignment.
  def wrap_column_headers!(el)
    ts = el['tableStyle']
    return unless ts.is_a?(Hash)
    styles = (ts['textStyles'] = ts['textStyles'].is_a?(Hash) ? ts['textStyles'] : {})
    key = el['kind'] == 'pivot-table' ? 'columnHeader' : 'header'
    ch = (styles[key] = styles[key].is_a?(Hash) ? styles[key] : {})
    ch['textWrap'] ||= 'wrap'
    ch['align'] ||= 'right' if key == 'columnHeader'
    compact_wide_pivot_font!(el, styles)
  end

  # A table / pivot whose source visual shows no title gets the builder's derived name ("Total Sales
  # by Region") that Power BI never displays. The documented hide is `name: ' '` (a single space;
  # omitting the name re-derives it - styling.md KPI note). Needs a signals `title` key that is null or
  # blank; an older signals file without the key is left alone. Never charts or KPIs.
  def hide_derived_title!(el, source)
    return unless %w[table pivot-table].include?(el['kind'])
    return unless source.is_a?(Hash) && source.key?('title') && source['title'].to_s.strip.empty?
    el['name'] = ' ' if el.key?('name') && !el['name'].to_s.strip.empty?
  end

  LINE_AREA_KINDS = %w[line-chart area-chart].freeze

  # Chart defaults that follow Power BI: a top legend when the chart has a color/series column or 2+
  # y series; line/area value axes auto-fit and do not include zero (bar/column keep zero); data labels
  # when the source visual shows them (bar/combo; the builder already honors this for bar/line).
  # Existing legend / scale / dataLabel win. Shapes: charts.md "Legend controls", "dataLabel".
  def tweak_chart!(el, source = nil)
    kind = el['kind']
    if LINE_AREA_KINDS.include?(kind)
      color = el['color']
      ycols = el.dig('yAxis', 'columnIds')
      multi = (color.is_a?(Hash) && !color.empty?) || (ycols.is_a?(Array) && ycols.length >= 2)
      el['legend'] = { 'position' => 'top' } if multi && !el.key?('legend')
      %w[yAxis yAxis2].each { |k| value_axis_unzero!(el[k]) }
    end
    if %w[bar-chart combo-chart].include?(kind) && source.is_a?(Hash) && source['data_labels'] == true && !el.key?('dataLabel')
      el['dataLabel'] = { 'labels' => 'shown' }
    end
  end

  def value_axis_unzero!(axis)
    return unless axis.is_a?(Hash)
    fmt = axis['format']
    return if fmt && !fmt.is_a?(Hash)
    return if fmt && fmt.key?('scale')
    (axis['format'] ||= {})['scale'] = { 'type' => 'linear', 'zero' => false }
  end

  # A pivot with many value columns gets a 12px cell / row-header font, so wide values (grand totals
  # such as "$4,097,657,275.53") fit the uniform body width (live: a 13-value pivot clipped its totals
  # at the default size). An explicit fontSize wins. Shape: styling.md "textStyles.{cell,rowHeader}".
  WIDE_PIVOT_VALUES = 10
  WIDE_PIVOT_FONT_PX = 12
  def compact_wide_pivot_font!(el, styles)
    return unless el['kind'] == 'pivot-table' && Array(el['values']).length >= WIDE_PIVOT_VALUES
    %w[cell rowHeader].each do |k|
      st = (styles[k] = styles[k].is_a?(Hash) ? styles[k] : {})
      st['fontSize'] ||= WIDE_PIVOT_FONT_PX
    end
  end

  # ---- explicit widths (need the rendered cell width) -----------------------

  # Pixel width of an element cell spanning `span` grid columns with `tiles` tiles side by side in its
  # band row (pivot_widths.rb cell_px, expressed on the 1536px canvas).
  def cell_px(span, tiles)
    (PAGE_CANVAS_PX * span / GRID.to_f - TILE_GAP_PX * (tiles - 1) - ELEMENT_PADDING_PX).floor
  end

  # Tiles sharing a cell's band row: itself plus every distinct column interval that overlaps it
  # vertically but not horizontally (stacked tiles in one column count once).
  def tiles_in_band_row(cells, cell)
    _l, c0, c1, r0, r1 = cell
    others = cells.select do |_l2, a0, a1, b0, b1|
      b0 < r1 && r0 < b1 && (a1 <= c0 || c1 <= a0)
    end
    1 + others.map { |_l2, a0, a1, *| [a0, a1] }.uniq.length
  end

  def col_names(el)
    h = {}
    Array(el['columns']).each { |c| h[c['id']] = c['name'].to_s if c.is_a?(Hash) }
    h
  end

  # Pivots WITHOUT columnsBy get display.headerWidths/bodyWidths.uniformWidth (both, or neither: Sigma
  # discards the width spec unless header + body fit the cell). Needs body >= 48px to be legible.
  # Never columns[] widths (400 with uniformWidth) and never tableStyle.autofitColumns (400 as a boolean).
  def pivot_widths!(el, cell)
    return unless Array(el['columnsBy']).empty?
    n_values = Array(el['values']).length
    return if n_values.zero?
    names = col_names(el)
    lens = Array(el['rowsBy']).map { |r| r.is_a?(Hash) ? names[r['columnId']] : nil }.compact.map(&:length)
    # Member labels (a long category name, a person's full name) are usually longer than the
    # dimension name itself, so never size the row header below the unknown-label default.
    chars = [lens.max || 0, PIVOT_UNKNOWN_HEADER_CHARS].max
    header = [PX_PER_CHAR * chars + PADDING_PX, HEADER_SHARE * cell].min.floor
    body = ((cell - header - SLACK_PX) / n_values.to_f).floor
    return if body < LEGIBLE_BODY_PX
    return if el['display'] && !el['display'].is_a?(Hash)
    drop_cents_to_fit!(el, body)
    display = (el['display'] ||= {})
    { 'headerWidths' => header, 'bodyWidths' => body }.each do |k, px|
      next if display[k] && !display[k].is_a?(Hash)
      (display[k] ||= {})['uniformWidth'] ||= px
    end
  end

  # Two-decimal currency needs ~15 characters for nine-figure values ("$795,751,737.96"), about
  # 7px/char + 16px padding = 121px. When the uniform body width cannot hold that, Sigma truncates
  # the digits; whole dollars (12 characters) stay legible. Percentages and non-currency formats are
  # untouched. A deliberate, recorded deviation from the source's cents.
  CENTS_FIT_PX = 125
  def drop_cents_to_fit!(el, body)
    return if body >= CENTS_FIT_PX
    vals = Array(el['values'])
    Array(el['columns']).each do |c|
      next unless c.is_a?(Hash) && vals.include?(c['id']) && c['format'].is_a?(Hash)
      fs = c['format']['formatString'].to_s
      next unless fs.include?('$') && fs =~ /\.2f\z/
      c['format']['formatString'] = fs.sub(/\.2f\z/, '.0f')
    end
  end

  PERCENT_FMT = /%/.freeze
  NUMERIC_FORMULA = /\A\s*(Sum|Avg|Average|Count|CountDistinct|Min|Max|Median|Round|Abs|Percentile)\s*\(/i.freeze

  def column_weight(col)
    fmt = col['format']
    if fmt.is_a?(Hash)
      return COL_WEIGHT_PERCENT if fmt['formatString'].to_s =~ PERCENT_FMT
      return COL_WEIGHT_NUMBER if fmt['kind'].to_s != 'text'
    end
    col['formula'].to_s =~ NUMERIC_FORMULA ? COL_WEIGHT_NUMBER : COL_WEIGHT_TEXT
  end

  # Flat tables with more than 6 columns get columns[i].style.width so the columns fill the cell:
  # weights text 1.4 / number 1.0 / percentage 0.7, at least 60px each. Existing style keys win.
  def table_column_widths!(el, cell)
    cols = Array(el['columns']).select { |c| c.is_a?(Hash) }
    return unless cols.length > TABLE_WIDTH_MIN_COLS
    weights = cols.map { |c| column_weight(c) }
    sum = weights.sum
    cols.each_with_index do |c, i|
      next if c['style'] && !c['style'].is_a?(Hash)
      st = (c['style'] ||= {})
      st['width'] ||= [(cell * weights[i] / sum).round, COL_MIN_PX].max
    end
  end

  # A chart's color/series column holding a year shows as "2.02k" in the legend without a format.
  YEAR_NAME = /\byear\b/i.freeze
  YEAR_FORMAT = { 'kind' => 'number', 'formatString' => 'd' }.freeze

  def year_column?(col)
    return true if col['name'].to_s =~ YEAR_NAME
    f = col['formula'].to_s
    return true if f =~ /\bYear\s*\(/i
    f.scan(/\[([^\]]+)\]/).flatten.any? { |ref| ref.split('/').last.to_s =~ YEAR_NAME }
  end

  def format_year_legend!(el)
    color = el['color']
    return unless color.is_a?(Hash) && color['column']
    col = Array(el['columns']).find { |c| c.is_a?(Hash) && c['id'] == color['column'] }
    return unless col && !col.key?('format') && year_column?(col)
    col['format'] = YEAR_FORMAT.dup
  end

  # A caption loses leading markdown heading marks; a section label becomes `### <label>`.
  def tweak_text!(el, sub)
    body = el['body'].to_s
    if sub == :label
      label = strip_heading(text_lines(body).first.to_s)
      el['body'] = "### #{label}" unless label.empty?
    else
      el['body'] = body.gsub(/^([ \t]*)#+[ \t]+/, '\1')
    end
  end

  # ---- page polish ----------------------------------------------------------

  # Polishes ONE page. Mutates `doc` (elements) and returns [page_inner_xml, summary].
  # `info` is parse_pages' entry for the page; `sig` the signals page.
  def polish_page(doc, pid, info, sig, spec_name, hidden_mode = 'drawer', hide_derived_titles = false)
    els = {}
    all_elements(doc).each { |e| els[e['id']] = e }
    vis_by_eid = {}
    (sig['visuals'] || []).each { |v| vis_by_eid[element_id_for(v['visual_id'])] = v }
    source_visual = ->(eid) { vis_by_eid[eid] || vis_by_eid[eid.sub(KPI_SUB, '')] }
    page_w = (sig['page_w'] || 1280).to_f
    notes = []

    # -- header band: keep an existing one's text, else create it from the page name
    hdr_id = "band-#{pid}-hdr"
    hdr_txt_id = "band-#{pid}-hdrtext"
    header_kept = false
    info[:containers].each do |c|
      next unless c[:top] && header_style?(els[c[:id]])
      t = c[:leaves].find { |id| els[id] && els[id]['kind'] == 'text' }
      next unless t
      hdr_id = c[:id]
      hdr_txt_id = t
      header_kept = true
      break
    end
    page_meta = Array(doc['pages']).find { |p| p.is_a?(Hash) && p['id'] == pid }
    # The builder's generated header text (`band-<page>-hdrtext`) is regenerated each run with its body
    # kept; a promoted SOURCE text element that already heads the band is left exactly where it is.
    generated_header = hdr_txt_id == "band-#{pid}-hdrtext"
    old_hdr_body = els[hdr_txt_id] && els[hdr_txt_id]['body']
    hctrl_txt_id = "band-#{pid}-hctrl-hdr"
    owned = {} # elements this pass regenerates (container placeholders, generated texts)
    info[:containers].each { |c| owned[c[:id]] = true }
    owned[hctrl_txt_id] = true
    btn_id = "btn-#{pid}-filters"
    drawer_id = "drawer-#{pid}"
    owned[btn_id] = true # the open-drawer button is regenerated (or dropped) every run, in either mode
    owned[hdr_txt_id] = true if generated_header

    # -- classify the page's leaves
    content = []
    visible = []
    hidden = []
    legends = []
    companions = {} # host content element id => [companion control elements] (drill controls etc.)
    content_ids = info[:leaves].select do |id|
      e = els[id]
      e && !%i[control container].include?(kind_class(e)) && id != hdr_txt_id && id != hctrl_txt_id && id != btn_id
    end
    dropped_ids = []
    info[:leaves].each_with_index do |eid, order|
      next if eid == hdr_txt_id || eid == hctrl_txt_id || eid == btn_id
      el = els[eid]
      if el.nil?
        notes << "layout entry #{eid} has no spec element (dropped)"
        next
      end
      cls = kind_class(el)
      next if cls == :container
      if cls == :control
        if legend_control?(el)
          legends << el
          next
        end
        v = source_visual.call(eid)
        # a control the builder derived from a content element (`<chart id>-drill`, ...) was never a
        # source slicer, so it is not hidden-in-source: it rides with its host, like a legend
        host = v.nil? ? content_ids.select { |cid| eid.start_with?("#{cid}-") }.max_by(&:length) : nil
        if host
          (companions[host] ||= []) << el
          next
        end
        src_hidden = v.nil? || v['hidden'] || v['hidden_control']
        rec = { id: eid, date_range: el['controlType'].to_s == 'date-range', order: order,
                x: v ? v['x'].to_f : nil, y: v ? v['y'].to_f : nil }
        (src_hidden ? hidden : visible) << rec
      else
        content << { id: eid, el: el, cls: cls, order: order, v: source_visual.call(eid) }
      end
    end

    # -- legend controls ride with their chart; dropped when the chart has no color/series column
    charts = {}
    content.each { |c| charts[c[:id]] = c if c[:cls] == :chart }
    legend_for = {}
    legends.each do |lg|
      chart_id = lg.dig('targets', 0, 'source', 'elementId') || lg['id'].to_s.sub(/-legend\z/, '')
      chart = charts[chart_id]
      color = chart && chart[:el]['color']
      if chart && color.is_a?(Hash) && !color.empty? && !legend_for.key?(chart_id)
        legend_for[chart_id] = lg
      else
        dropped_ids << lg['id']
        notes << "legend control #{lg['id']} dropped (#{chart ? 'chart has no color/series column' : 'chart not on page'})"
      end
    end

    # -- source boxes for the content leaves (a multi-value card's `-k<i>` KPIs tile their card's box)
    sub_groups = {}
    content.each do |c|
      m = c[:id].match(/\A(.*)-k(\d+)\z/)
      next unless m && c[:v]
      (sub_groups[m[1]] ||= []) << c
    end
    sub_groups.each_value { |g| g.sort_by! { |c| c[:id][/-k(\d+)\z/, 1].to_i } }
    content.each do |c|
      v = c[:v]
      next unless v && !(v['hidden'] || v['hidden_control']) && v['w'].to_f.positive? && v['h'].to_f.positive?
      x = v['x'].to_f
      y = v['y'].to_f
      w = v['w'].to_f
      h = v['h'].to_f
      m = c[:id].match(/\A(.*)-k(\d+)\z/)
      group = m && sub_groups[m[1]]
      if group
        n = group.length
        i = group.index { |cc| cc.equal?(c) }
        ncol = Math.sqrt(n).ceil
        nrow = (n.to_f / ncol).ceil
        cx = i % ncol
        cy = i / ncol
        c[:x0] = x + cx * w / ncol
        c[:x1] = x + (cx + 1) * w / ncol
        c[:y0] = y + cy * h / nrow
        c[:y1] = y + (cy + 1) * h / nrow
      else
        c[:x0] = x
        c[:y0] = y
        c[:x1] = x + w
        c[:y1] = y + h
      end
      c[:src_h] = h
    end
    # no usable source box (synthetic / hidden / zero-size): a full-width band below everything else
    boxed = content.select { |c| c[:x0] }
    base_y = (boxed.map { |c| c[:y1] }.max || 0) + 100
    content.reject { |c| c[:x0] }.sort_by { |c| c[:order] }.each_with_index do |c, i|
      c[:x0] = 0.0
      c[:x1] = page_w
      c[:y0] = base_y + i * 40.0
      c[:y1] = c[:y0] + 20.0
      c[:src_h] = 0
      notes << "#{c[:id]} has no visible source box; placed in a full-width band after the content"
    end

    # -- leaf sizing + tweaks
    content.each do |c|
      el = c[:el]
      c[:sub] = text_subclass(el['body']) if c[:cls] == :text
      c[:cardinality] = c[:v] && c[:v]['row_cardinality']
      c[:rows] = leaf_rows(c) + CONTROL_ROWS * Array(companions[c[:id]]).length
      if c[:cls] == :table
        tweak_table!(el, c[:v], hide_derived_titles) if %w[table pivot-table].include?(el['kind'])
      elsif c[:cls] == :text
        tweak_text!(el, c[:sub])
      elsif c[:cls] == :chart
        format_year_legend!(el)
        tweak_chart!(el, c[:v])
      end
    end

    # -- content tree + render
    items = content.sort_by { |c| c[:order] }
    tree = items.empty? ? nil : xy_cut(items)
    cells, content_rows = tree ? render(tree, 1, GRID, 1) : [[], 0]
    cells.each do |cell|
      leaf = cell[0]
      next unless leaf[:cls] == :table
      px = cell_px(cell[2] - cell[1], tiles_in_band_row(cells, cell))
      case leaf[:el]['kind']
      when 'pivot-table' then pivot_widths!(leaf[:el], px)
      when 'table' then table_column_widths!(leaf[:el], px)
      end
    end

    # -- bands, top to bottom
    new_els = []
    children = []
    cursor = 1
    new_els << SigmaLayout.container_el(hdr_id, SigmaLayout::HEADER_STYLE.dup)
    if generated_header
      title = SigmaLayout.resolve_header_title(page_meta && page_meta['name'], sig['page_title'], spec_name) || 'Dashboard'
      txt = SigmaLayout.header_text_el(hdr_txt_id, title)
      txt['body'] = old_hdr_body if old_hdr_body
      new_els.unshift(txt)
    end
    drawer_mode = hidden_mode == 'drawer' && !hidden.empty?
    # drawer mode: the open button sits at the right end of the visible control band (last row; a new
    # row when that one is full), else on the right side of the header band
    button_cell = nil
    if drawer_mode && visible.empty?
      children << SigmaLayout.gc(hdr_id, 1, 25, 1, 1 + SigmaLayout::HEADER_ROWS,
                                 [SigmaLayout.le(hdr_txt_id, 1, 25 - BUTTON_COLS, 1, 1 + SigmaLayout::HEADER_ROWS),
                                  SigmaLayout.le(btn_id, 25 - BUTTON_COLS, 25, 1, 1 + SigmaLayout::HEADER_ROWS)].join("\n"))
    else
      children << SigmaLayout.header_band_xml(hdr_id, hdr_txt_id)
    end
    cursor += SigmaLayout::HEADER_ROWS

    unless visible.empty?
      band = pack_controls(control_order(visible))
      if drawer_mode
        last_r0 = band[:height] - CONTROL_ROWS + 1
        last = band[:cells].select { |c| c[3] == last_r0 }
        if last.length >= CONTROLS_PER_ROW || last.map { |c| c[2] }.max > GRID + 1 - BUTTON_COLS
          last_r0 = band[:height] + 1
          band[:height] += CONTROL_ROWS
        end
        band[:cells] << [btn_id, GRID + 1 - BUTTON_COLS, GRID + 1, last_r0, last_r0 + CONTROL_ROWS]
      end
      cid = "band-#{pid}-ctrl"
      new_els << SigmaLayout.container_el(cid)
      inner = band[:cells].map { |id, a, b, r0, r1| SigmaLayout.le(id, a, b, r0, r1) }.join("\n")
      children << SigmaLayout.gc(cid, 1, 25, cursor, cursor + band[:height], inner)
      cursor += band[:height]
    end

    cells.sort_by { |leaf, c0, _c1, r0, _r1| [r0, c0, leaf[:order]] }.each do |leaf, c0, c1, r0, r1|
      lg = legend_for[leaf[:id]]
      comps = Array(companions[leaf[:id]])
      if lg || !comps.empty?
        cid = "band-#{pid}-legend-#{leaf[:id]}"
        new_els << SigmaLayout.container_el(cid)
        top = 1 + CONTROL_ROWS * comps.length # companion controls sit in rows above the host element
        nested = comps.each_with_index.map { |ce, i| SigmaLayout.le(ce['id'], 1, 1 + CONTROL_COLS, 1 + i * CONTROL_ROWS, 1 + (i + 1) * CONTROL_ROWS) }
        nested << SigmaLayout.le(leaf[:id], 1, 25, top, 1 + (r1 - r0))
        nested << SigmaLayout.le(lg['id'], 25 - LEGEND_COLS, 25, top, top + LEGEND_ROWS) if lg
        nested = nested.join("\n")
        children << SigmaLayout.gc(cid, c0, c1, cursor + r0 - 1, cursor + r1 - 1, nested)
      else
        children << SigmaLayout.le(leaf[:id], c0, c1, cursor + r0 - 1, cursor + r1 - 1)
      end
    end
    cursor += content_rows

    drawer = nil
    hidden_sorted = control_order(hidden)
    if drawer_mode
      new_els << { 'id' => btn_id, 'kind' => 'button', 'text' => "More filters (#{hidden.length})", 'appearance' => 'filled',
                   'actions' => [{ 'id' => "a-#{pid}-filters", 'trigger' => 'on-click',
                                   'effects' => [{ 'effect' => 'open-overlay', 'overlayId' => drawer_id }] }] }
      cells_xml = hidden_sorted.each_with_index.map { |c, i| SigmaLayout.le(c[:id], 1, 25, i * DRAWER_ROWS + 1, (i + 1) * DRAWER_ROWS + 1) }
      drawer = { overlay: { 'id' => drawer_id, 'type' => 'drawer', 'name' => 'Filters',
                            'drawer' => { 'width' => 'medium', 'showShadow' => 'shown', 'header' => { 'title' => 'Filters' } } },
                 page_xml: SigmaLayout.page_xml(drawer_id, *cells_xml) }
    elsif !hidden.empty?
      band = pack_controls(hidden_sorted)
      hid = "band-#{pid}-hctrl"
      new_els << SigmaLayout.container_el(hid)
      new_els << { 'id' => hctrl_txt_id, 'kind' => 'text', 'body' => HIDDEN_HDR_TEXT }
      inner = ([SigmaLayout.le(hctrl_txt_id, 1, 25, 1, 1 + HIDDEN_HDR_ROWS)] +
               band[:cells].map { |id, a, b, r0, r1| SigmaLayout.le(id, a, b, r0 + HIDDEN_HDR_ROWS, r1 + HIDDEN_HDR_ROWS) }).join("\n")
      rows = HIDDEN_HDR_ROWS + band[:height]
      children << SigmaLayout.gc(hid, 1, 25, cursor, cursor + rows, inner)
      cursor += rows
    end

    # -- spec edits: drop what this pass regenerates, then add the new placeholders/texts
    remove_elements!(doc, owned.keys + dropped_ids)
    add_elements!(doc, new_els, pid)

    summary = {
      'page_id' => pid,
      'page_title' => sig['page_title'],
      'header' => header_kept ? 'kept' : 'created',
      'controls_visible' => visible.length,
      'controls_hidden' => hidden.length,
      'legends_kept' => legend_for.length,
      'legends_dropped' => legends.length - legend_for.length,
      'content' => content.length,
      'shape' => tree ? shape(tree) : '(none)',
      'rows' => cursor - 1,
      'notes' => notes
    }
    summary['hidden_mode'] = drawer_mode ? 'drawer' : 'band'
    [children.join("\n"), summary, drawer]
  end

  # ---- whole spec -----------------------------------------------------------

  # Returns [new_spec, summaries]. `spec` and `signals` are parsed JSON; neither is mutated.
  # Pages without a signals page (e.g. the hidden Data page) are left untouched. Deterministic and
  # idempotent: polishing a polished spec reproduces it byte for byte.
  def polish(spec, signals, hidden_controls: 'drawer', hide_derived_titles: false)
    unless HIDDEN_MODES.include?(hidden_controls.to_s)
      raise ArgumentError, "hidden_controls must be one of #{HIDDEN_MODES.join('|')} (got #{hidden_controls.inspect})"
    end
    spec = Marshal.load(Marshal.dump(spec))
    doc = doc_of(spec)
    layout_xml = doc['layout'].to_s
    raise ArgumentError, 'spec has no layout (top-level `layout` or `document.layout`)' if layout_xml.strip.empty?
    pages = parse_pages(layout_xml)
    sig_pages = Array(signals['pages'])
    summaries = []
    new_inner = {}
    drawers = []
    stale_overlays = []
    pages.each do |pid, info|
      sig = sig_pages.find { |p| "page-#{p['page_id']}" == pid || p['page_id'].to_s == pid }
      next unless sig
      # a previous drawer-mode run moved this page's hidden controls into the overlay page `drawer-<pid>`:
      # they rejoin the page's leaves so both modes start from the same inputs (idempotent across a mode switch)
      did = "drawer-#{pid}"
      stale_overlays << did
      info[:leaves].concat(pages[did][:leaves]) if pages.key?(did)
      inner, summary, drawer = polish_page(doc, pid, info, sig, spec['name'], hidden_controls.to_s, hide_derived_titles)
      new_inner[pid] = inner
      summaries << summary
      drawers << drawer if drawer
    end
    prefix = layout_xml[/\A\s*<\?xml[^>]*\?>/].to_s
    body = layout_xml.sub(/\A\s*<\?xml[^>]*\?>/, '')
    body = body.gsub(%r{(<Page\b[^>]*\bid="([^"]*)"[^>]*>)(.*?)(</Page>)}m) do
      open_tag = Regexp.last_match(1)
      pid = Regexp.last_match(2)
      old_inner = Regexp.last_match(3)
      close_tag = Regexp.last_match(4)
      next '' if stale_overlays.include?(pid) # regenerated below (or gone: no hidden controls / band mode)
      new_inner.key?(pid) ? "#{open_tag}\n#{new_inner[pid]}\n#{close_tag}" : "#{open_tag}#{old_inner}#{close_tag}"
    end
    body = body.gsub(/\n{2,}/, "\n").rstrip
    # overlay pages (drawers) come AFTER the real pages; their ids live in document.overlays, not document.pages
    body = ([body] + drawers.map { |d| d[:page_xml] }).reject(&:empty?).join("\n")
    doc['layout'] = prefix + body
    kept = Array(doc['overlays']).reject { |o| o.is_a?(Hash) && stale_overlays.include?(o['id']) }
    overlays = kept + drawers.map { |d| d[:overlay] }
    if overlays.empty?
      doc.delete('overlays')
    else
      doc['overlays'] = overlays
    end
    [spec, summaries]
  end
end
