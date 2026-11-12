# frozen_string_literal: true
#
# pivot_widths.rb — plan C10 (verdict `pivot-value-column-width`): size a pivot's
# row-header and value columns so labels / values do not truncate. Display-only.
#
# Emits ONLY display.headerWidths.uniformWidth and display.bodyWidths.uniformWidth
# (both schema-verified positive numbers). Never `columns[]` (leaf ids unknown, and
# uniformWidth + columns is a 400), never 0, never tableStyle.autofitColumns (400).
#
# Live-corrected sizing (plan C R4). Sigma does NOT squeeze pivot columns to the frame:
# widths are honored only when header_total + body_total fits the element cell, otherwise
# the whole width spec is discarded (default ~48px columns, clipped). Header-only widths do
# nothing. So both widths are always emitted together and always fit:
#   cell   = live-measured tile cell (see cell_px: canvas - 64 full width, less tile gaps in a row)
#   header = longest row member (~7px/char + 16px), capped so n_hdr x header <= 0.35 x cell
#   body   = floor((cell - n_hdr x header - 8 slack) / value columns)
# body < 16 -> no widths (residual); body < 48 -> widths emitted but not legible (residual).
module PivotWidths
  module_function

  PX_PER_CHAR = 7
  PADDING_PX  = 16

  def text_px(str)
    str.to_s.length * PX_PER_CHAR + PADDING_PX
  end

  # Plan C17 (verdict overflow-hash-vs-ellipsis): a KPI value truncates when its
  # string is wider than the tile. Glyph ~0.6 em, tile padding 16px a side
  # (probe: a ~100px tile shows "$197,676.50" at 10px, truncates at 14px).
  # Returns min(source_size, largest whole px size that fits); the source size
  # unchanged when the tile width or value text is unknown.
  KPI_GLYPH_EM = 0.6
  KPI_TILE_PAD_PX = 32
  KPI_MIN_READABLE_PX = 8 # never shrink a value below a readable size
  # NOTE: the 0.6 glyph ratio and 32px padding are calibrated to the single
  # verdict probe point (~100px tile: 10px fits "$197,676.50", 14px truncates).

  def fit_font_px(text, frame_px, source_size)
    return source_size unless source_size.to_f.positive?
    source_size = source_size.to_f unless source_size.is_a?(Numeric)
    return source_size if text.to_s.empty? || !frame_px.to_f.positive?
    fit = ((frame_px.to_f - KPI_TILE_PAD_PX) / (text.to_s.length * KPI_GLYPH_EM)).floor
    [[fit, KPI_MIN_READABLE_PX].max, source_size].min
  end

  def longest_px(strings)
    Array(strings).map { |s| text_px(s) }.max
  end

  PAGE_PADDING_PX    = 64
  SLACK_PX           = 8
  HEADER_SHARE       = 0.35
  MIN_BODY_PX        = 16
  LEGIBLE_BODY_PX    = 48
  LEGIBLE_COLUMN_PX  = 50

  # The element cell width for a zone, live-measured (1000px viewport, band container padding none):
  # page padding 16px a side, 16px gap between tiles in a row, 32px element padding. A full-width
  # cell is canvas - 64 (936); measured half-width 444 and third-width 280 (tiles in one row).
  # Tile box = f x (canvas - 32) - f x 16 x (tiles - 1); the row's tile count is not known when a
  # pivot is emitted, so assume one more tile than an equal split (ceil(1/f) gaps, f < 1), which
  # stays under every measured cell (436 vs 444, 274 vs 280). The flush layout (hidden gaps and
  # element padding) only widens the cell, so the same figure is safe there.
  TILE_GAP_PX = 16
  ELEMENT_PADDING_PX = 32

  def cell_px(canvas_px, w_pct)
    return nil unless canvas_px.to_f.positive? && w_pct.to_f.positive?
    f = [w_pct.to_f / 100.0, 1.0].min
    gaps = f >= 1.0 ? 0 : (100.0 / w_pct.to_f - 0.01).ceil
    (f * (canvas_px.to_f - PAGE_PADDING_PX / 2) - f * TILE_GAP_PX * gaps - ELEMENT_PADDING_PX).floor
  end

  # Viewport width at which `value_cols` legible (>= ~50px) columns fit beside the row headers
  # in a zone `w_pct` wide.
  def legible_viewport_px(header_px, row_header_cols, value_cols, w_pct = 100)
    needed = row_header_cols.to_i * header_px.to_i + value_cols.to_i * LEGIBLE_COLUMN_PX
    f = w_pct.to_f.positive? ? [w_pct.to_f / 100.0, 1.0].min : 1.0
    (needed / f).ceil + PAGE_PADDING_PX
  end

  # header_texts: row member strings (or captions); frame_px / value_cols: Integer or nil;
  # row_header_cols: number of row-header columns (separate-columns layout) else 1.
  # Returns { 'headerWidths' => {...}, 'bodyWidths' => {...} } (both together, or header
  # only when the frame / value-column count is unknown, or {} when body would be < 16px).
  def display(header_texts:, frame_px:, value_cols:, row_header_cols: 1)
    header = longest_px(header_texts)
    return {} unless header
    n_hdr = [row_header_cols.to_i, 1].max
    unless frame_px.to_i.positive? && value_cols.to_i.positive?
      return { 'headerWidths' => { 'uniformWidth' => header } }
    end
    header = [header, (HEADER_SHARE * frame_px.to_i / n_hdr).floor].min
    body = (frame_px.to_i - n_hdr * header - SLACK_PX) / value_cols.to_i
    return {} if body < MIN_BODY_PX
    { 'headerWidths' => { 'uniformWidth' => header }, 'bodyWidths' => { 'uniformWidth' => body } }
  end

  # Plan C R6 (live probe, body column ~26px): at Sigma's default pivot type the measure / region
  # column headers wrap one or two characters per line. tableStyle.textStyles.columnHeader.fontSize
  # is the lever for those headers (9 -> four lines, 8 -> clean, 7 -> too small); header.fontSize
  # only touches row-header labels; cell 9 keeps 3-digit values readable at 26px. cellSpacing
  # extra-small (20px rows) is the tightest preset (small 23, medium 31 illegible, large 47 broken).
  # `textWrap: clip` does nothing on pivot headers, so it is never emitted. Pivot rows have no
  # height field, so they cannot stretch to fill the source frame (recorded as a residual).
  SQUEEZED_CELL_SPACING    = 'extra-small'
  SQUEEZED_COLUMN_HEADER_PX = 8
  SQUEEZED_CELL_PX         = 9
  SQUEEZED_ROW_HEADER_PX   = 9

  def squeezed?(body_px)
    body_px.is_a?(Numeric) && body_px < LEGIBLE_BODY_PX
  end

  # Returns a new tableStyle with the squeezed recipe filled in; existing keys (and existing
  # values inside textStyles) win, nothing is dropped. Banding / dividers are never added here.
  def merge_squeezed_table_style(existing)
    base = existing.is_a?(Hash) ? Marshal.load(Marshal.dump(existing)) : {}
    base['cellSpacing'] ||= SQUEEZED_CELL_SPACING
    ts = (base['textStyles'] = base['textStyles'].is_a?(Hash) ? base['textStyles'] : {})
    { 'columnHeader' => SQUEEZED_COLUMN_HEADER_PX, 'cell' => SQUEEZED_CELL_PX, 'header' => SQUEEZED_ROW_HEADER_PX }.each do |k, px|
      ts[k] = ts[k].is_a?(Hash) ? ts[k] : {}
      ts[k]['fontSize'] ||= px
    end
    base
  end
end
