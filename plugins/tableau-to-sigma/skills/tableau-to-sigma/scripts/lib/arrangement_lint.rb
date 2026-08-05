# frozen_string_literal: true
#
# arrangement_lint.rb — layout-ARRANGEMENT parity lint (PLAN-v3 PR-11).
#
# Tableau-plugin sibling of the shared layout_lint.rb: layout_lint polices the
# built grid's INTERNAL quality (raw-id titles, dead zones, band fill);
# nothing policed whether the built grid ARRANGES tiles the way the SOURCE
# dashboard does. Two field failures motivated this: a migration shipped its
# controls in a right sidebar where the source had a full-width top shelf, and
# another shipped two charts with their vertical stacking inverted — every
# data/structural gate passed both times.
#
# The lint compares NORMALIZED source zone bboxes (parse-twb-layout output:
# x/y/w/h % of the dashboard canvas) against the BUILT grid positions
# (build-dashboard-layout.rb's emitted page XML, containers flattened to
# page-absolute coordinates). Deliberately NO pixel IoU — grid quantization,
# row scaling, header offsets and gap-closing all shift absolute geometry
# legitimately. Only ORDERING and CLASS survive quantization, so only those
# are checked:
#
#   (a) row-band ordering — cluster each side's tiles into horizontal bands
#       (y-interval overlap, same rule as SigmaLayout.cluster_bands); a tile
#       pair in DIFFERENT bands on both sides must keep its top-to-bottom
#       order. Tiles that merge into one band on either side are never
#       flagged (that's quantization, not inversion).
#   (b) within-band left-right ordering — a tile pair sharing a band on BOTH
#       sides must keep its left-to-right order; centers closer than X_JITTER
#       (normalized) are never compared.
#   (c) quadrant agreement — a tile whose center sits confidently (outside
#       the QUADRANT_DEADBAND around the midline) in a source half/quadrant
#       must land in the same one; ambiguous axes (near the midline on either
#       side) are skipped.
#   (d) controls-shelf placement class — the source's control zones
#       (kind filter/parameter) are classified as `top-shelf` (a wide band in
#       the top region), `sidebar` (a narrow tall column hugging the left or
#       right edge), `scattered`, or `none`; the built control elements are
#       classified the same way from their grid positions. top-shelf built as
#       sidebar (or vice versa) is a violation; scattered/none never is.
#
# All coordinates are normalized to each side's own CONTENT EXTENT (the union
# bbox of the compared items), so a header band prepended by the builder or a
# canvas margin in the source cannot skew the comparison.
#
# WARN-level first release: build-dashboard-layout.rb emits
# <workdir>/layout-arrangement.json + WARN lines; assert-phase6-ran.rb gate 8e
# reads the report (advisory by default, blocking under --require-arrangement).
#
# API (pure, no I/O):
#   rects = ArrangementLint.absolute_rects(page_xml)     # eid => [x0,x1,y0,y1]
#   rec   = ArrangementLint.compare_page(name, source_items, built_items)
#     items: [{ name:, role: 'tile'|'control', rect: [x0,x1,y0,y1] }, ...]
#     (source rects in canvas % units, built rects in grid units — each side
#      is normalized independently, so the units never mix)
#     -> { 'page'=>, 'tiles_compared'=>, 'checks'=>{...}, 'violations'=>[...] }
module ArrangementLint
  X_JITTER          = 0.05 # normalized center-x deltas below this are quantization noise
  QUADRANT_DEADBAND = 0.08 # half/quadrant classified only outside 0.5 +/- this
  TOP_SHELF_MAX_Y   = 0.35 # controls union must end above this to read as a top shelf
  TOP_SHELF_MIN_W   = 0.50 # ... and span at least half the content width
  SIDEBAR_MAX_W     = 0.30 # controls union narrower than this reads as a rail column
  SIDEBAR_MIN_H     = 0.25 # ... when it spans real height (or holds >= 3 controls)
  EDGE_TOL          = 0.05 # a rail must hug the left or right content edge

  GRID_COLS_DEFAULT = 24

  module_function

  # Internal column count of a GridContainer tag (children's gridColumn refs
  # are LOCAL to this) — same resolution rule as LayoutLint.grid_col_count.
  def container_cols(attrs)
    tmpl = attrs.to_s[/gridTemplateColumns="([^"]*)"/, 1]
    return GRID_COLS_DEFAULT if tmpl.nil? || tmpl.strip.empty?
    if (rep = tmpl[/repeat\(\s*(\d+)/, 1])
      return [[rep.to_i, 1].max, GRID_COLS_DEFAULT * 4].min
    end
    n = tmpl.strip.split(/\s+/).reject(&:empty?).length
    n.positive? ? n : GRID_COLS_DEFAULT
  end

  # Flatten a built page's layout XML to PAGE-ABSOLUTE float rects
  # { elementId => [x0, x1, y0, y1] } (grid-line units, exclusive end).
  # A container child's gridColumn is local to the container's
  # gridTemplateColumns (mapped proportionally into the container's absolute
  # column span); child rows are container-relative and track page rows 1:1
  # (the matched-inner-span convention the builder emits).
  def absolute_rects(page_xml, page_cols: GRID_COLS_DEFAULT)
    out = {}
    stack = []
    root = { c0: 1.0, w: page_cols.to_f, cols: page_cols, r0: 1.0 }
    abs = lambda do |tag, frame|
      c0 = tag[/gridColumn="\s*(\d+)/, 1].to_f
      c1 = tag[/gridColumn="\s*\d+\s*\/\s*(\d+)/, 1].to_f
      r0 = tag[/gridRow="\s*(\d+)/, 1].to_f
      r1 = tag[/gridRow="\s*\d+\s*\/\s*(\d+)/, 1].to_f
      c1 = c0 + 1 if c1 <= c0
      r1 = r0 + 1 if r1 <= r0
      unit = frame[:w] / [frame[:cols], 1].max
      [frame[:c0] + (c0 - 1) * unit, frame[:c0] + (c1 - 1) * unit,
       frame[:r0] + (r0 - 1), frame[:r0] + (r1 - 1)]
    end
    page_xml.to_s.scan(%r{</GridContainer>|<GridContainer\b[^>]*?/?>|<LayoutElement\b[^>]*?/?>}m) do
      tag = Regexp.last_match(0)
      if tag.start_with?('</GridContainer')
        stack.pop
      elsif tag.start_with?('<GridContainer')
        frame = stack.last || root
        rect = abs.call(tag, frame)
        eid = tag[/elementId="([^"]*)"/, 1]
        out[eid] ||= rect if eid && !eid.empty?
        unless tag.end_with?('/>')
          stack << { c0: rect[0], w: [rect[1] - rect[0], 1e-6].max,
                     cols: container_cols(tag), r0: rect[2] }
        end
      else
        frame = stack.last || root
        eid = tag[/elementId="([^"]*)"/, 1]
        next unless eid && !eid.empty?
        out[eid] ||= abs.call(tag, frame)
      end
    end
    out
  end

  # Normalize a side's items to its own content extent: each item gains
  # :nx0/:nx1/:ny0/:ny1 (0..1) and :cx/:cy (normalized centers).
  def normalize(items)
    return [] if items.empty?
    x0 = items.map { |i| i[:rect][0].to_f }.min
    x1 = items.map { |i| i[:rect][1].to_f }.max
    y0 = items.map { |i| i[:rect][2].to_f }.min
    y1 = items.map { |i| i[:rect][3].to_f }.max
    w = [x1 - x0, 1e-6].max
    h = [y1 - y0, 1e-6].max
    items.map do |i|
      r = i[:rect].map(&:to_f)
      i.merge(nx0: (r[0] - x0) / w, nx1: (r[1] - x0) / w,
              ny0: (r[2] - y0) / h, ny1: (r[3] - y0) / h,
              cx: ((r[0] + r[1]) / 2.0 - x0) / w,
              cy: ((r[2] + r[3]) / 2.0 - y0) / h)
    end
  end

  # Horizontal band index per tile (same greedy y-overlap rule as
  # SigmaLayout.cluster_bands). Returns an array aligned with the input.
  def band_indexes(tiles)
    idx = Array.new(tiles.length)
    order = tiles.each_index.sort_by { |i| [tiles[i][:ny0], tiles[i][:nx0], i] }
    band = -1
    bottom = -1.0
    order.each do |i|
      t = tiles[i]
      if band.negative? || t[:ny0] >= bottom
        band += 1
        bottom = t[:ny1]
      else
        bottom = [bottom, t[:ny1]].max
      end
      idx[i] = band
    end
    idx
  end

  # 'left'/'right' (or 'top'/'bottom') when the center sits confidently on one
  # side of the midline; nil in the dead-band (never compared).
  def axis_side(center, neg, pos)
    return neg if center < 0.5 - QUADRANT_DEADBAND
    return pos if center > 0.5 + QUADRANT_DEADBAND
    nil
  end

  def quad_label(vert, horiz)
    [vert, horiz].compact.join('-')
  end

  # Shelf class of a side's CONTROLS (normalized items): 'top-shelf' |
  # 'sidebar' | 'scattered' | 'none'. Derived from the union bbox — a wide
  # strip near the top vs a narrow tall column hugging an edge.
  def shelf_class(controls)
    return 'none' if controls.empty?
    x0 = controls.map { |c| c[:nx0] }.min
    x1 = controls.map { |c| c[:nx1] }.max
    y0 = controls.map { |c| c[:ny0] }.min
    y1 = controls.map { |c| c[:ny1] }.max
    if y1 <= TOP_SHELF_MAX_Y && (x1 - x0) >= TOP_SHELF_MIN_W
      'top-shelf'
    elsif (x1 - x0) <= SIDEBAR_MAX_W &&
          (x0 <= EDGE_TOL || x1 >= 1.0 - EDGE_TOL) &&
          ((y1 - y0) >= SIDEBAR_MIN_H || controls.length >= 3)
      'sidebar'
    else
      'scattered'
    end
  end

  # Compare one page. source_items / built_items: [{ name:, role:, rect: }].
  # Tiles are joined by :name (source zone caption == built element's zone
  # match); controls are compared as a CLASS, never per-name.
  def compare_page(page_name, source_items, built_items)
    src = normalize(source_items)
    blt = normalize(built_items)
    blt_by_name = blt.select { |i| i[:role] == 'tile' }
                     .each_with_object({}) { |i, h| h[i[:name]] ||= i }
    pairs = src.select { |i| i[:role] == 'tile' && blt_by_name[i[:name]] }
               .map { |s| [s, blt_by_name[s[:name]]] }
    s_tiles = pairs.map(&:first)
    b_tiles = pairs.map(&:last)
    s_band = band_indexes(s_tiles)
    b_band = band_indexes(b_tiles)

    violations = []
    row_inv = []
    lr_inv = []
    cross_pairs = 0
    in_pairs = 0
    (0...pairs.length).to_a.combination(2).each do |i, j|
      s_cmp = s_band[i] <=> s_band[j]
      b_cmp = b_band[i] <=> b_band[j]
      if !s_cmp.zero? && !b_cmp.zero?
        cross_pairs += 1
        next unless s_cmp == -b_cmp
        top, bot = s_cmp.negative? ? [i, j] : [j, i]
        row_inv << [s_tiles[top][:name], s_tiles[bot][:name]]
        violations << "stacking inverted: #{s_tiles[top][:name].inspect} is ABOVE " \
                      "#{s_tiles[bot][:name].inspect} in the source but lands BELOW it in the built grid"
      elsif s_cmp.zero? && b_cmp.zero?
        in_pairs += 1
        next if (s_tiles[i][:cx] - s_tiles[j][:cx]).abs <= X_JITTER
        l, r = s_tiles[i][:cx] < s_tiles[j][:cx] ? [i, j] : [j, i]
        next unless b_tiles[l][:cx] > b_tiles[r][:cx] + X_JITTER
        lr_inv << [s_tiles[l][:name], s_tiles[r][:name]]
        violations << "left-right order inverted: #{s_tiles[l][:name].inspect} is LEFT of " \
                      "#{s_tiles[r][:name].inspect} in the source row but lands RIGHT of it in the built grid"
      end
      # one side merged the pair into a band the other keeps separate —
      # quantization, never flagged
    end

    q_flips = []
    q_compared = 0
    pairs.each do |s, b|
      sh = axis_side(s[:cx], 'left', 'right')
      sv = axis_side(s[:cy], 'top', 'bottom')
      bh = axis_side(b[:cx], 'left', 'right')
      bv = axis_side(b[:cy], 'top', 'bottom')
      cmp_h = sh && bh
      cmp_v = sv && bv
      next unless cmp_h || cmp_v
      q_compared += 1
      next unless (cmp_h && sh != bh) || (cmp_v && sv != bv)
      q_flips << s[:name]
      violations << "quadrant flip: #{s[:name].inspect} sits #{quad_label(sv, sh)} in the source " \
                    "but lands #{quad_label(bv, bh)} in the built grid"
    end

    s_shelf = shelf_class(src.select { |i| i[:role] == 'control' })
    b_shelf = shelf_class(blt.select { |i| i[:role] == 'control' })
    shelf_mismatch = (s_shelf == 'top-shelf' && b_shelf == 'sidebar') ||
                     (s_shelf == 'sidebar' && b_shelf == 'top-shelf')
    if shelf_mismatch
      describe = { 'top-shelf' => 'a full-width TOP SHELF', 'sidebar' => 'a SIDEBAR rail' }
      violations << "controls-shelf class mismatch: the source places its controls as #{describe[s_shelf]} " \
                    "but the built grid ships them as #{describe[b_shelf]} — mirror the source shelf"
    end

    { 'page' => page_name,
      'tiles_compared' => pairs.length,
      'checks' => {
        'row_band_order' => { 'pairs' => cross_pairs, 'inversions' => row_inv },
        'in_band_order'  => { 'pairs' => in_pairs, 'inversions' => lr_inv },
        'quadrant'       => { 'compared' => q_compared, 'flips' => q_flips },
        'controls_shelf' => { 'source' => s_shelf, 'built' => b_shelf,
                              'mismatch' => shelf_mismatch }
      },
      'violations' => violations }
  end
end
