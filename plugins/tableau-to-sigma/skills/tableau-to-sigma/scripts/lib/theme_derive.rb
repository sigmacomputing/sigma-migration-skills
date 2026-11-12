# frozen_string_literal: true
#
# theme_derive.rb — derive Sigma themeOverrides from a parse-twb-layout dump.
#
# ONE shared pure function so the orchestrated mechanical path
# (build-charts-from-signals → mechanical-specs build_wb_spec) and the
# standalone path (build-workbook-spec.rb) cannot diverge — the v5.0 field
# finding was that only the standalone path emitted a theme, so every
# orchestrated run shipped themeless even when the source declared fonts,
# a fixed canvas width, and a brand palette.
#
# Inputs per dashboard (parse-twb-layout): 'style_rules' ({'workbook'=>
# {element=>{attr=>value}}, 'dashboard'=>{...}}), 'canvas_px' ({w,h,
# sizing_mode}), 'zone_tree' (container fill tints), 'brand_palette'
# (frequency-ranked encoded colors, categorical palettes only).
#
# Sigma surface (styling.md, live-verified 2026-06-26): themeOverrides
# {fonts.{textFont,dataFont}, pageWidth+maxPageWidth, colorOverrides.
# backgroundCanvas, categoricalScheme}. sequentialScheme/divergingScheme take
# NAMED schemes only — Tableau custom ramps can never ride the theme.
#
# Contract: returns {} only when there is no dashboard. Plan C13: fonts are
# always emitted (source family mapped to a Sigma-rendered font; an undeclared
# font is Tableau's default Tableau Book -> Lato).
require_relative 'series_colors'

module ThemeDerive
  module_function

  # Plan C13 (verdict font-family): Sigma renders only its own font set; any
  # other name is accepted (200) but silently falls back to the default. These
  # families were live-probed to render; everything else (Tableau Book/Regular/
  # Light/Medium/Semibold/Bold, unknown names) maps to Lato. A TWB with no font
  # rule uses Tableau's documented default (Tableau Book) -> Lato as well.
  SIGMA_FONTS = %w[Lato Arial Georgia Merriweather Roboto\ Mono Roboto].freeze
  DEFAULT_FONT = 'Lato'
  SCHEME_CAP = 20 # Tableau 10/20 hues; beyond that map-to noise, not a palette

  def derive(layout)
    dashes = layout.is_a?(Array) ? layout : []
    return {} if dashes.empty?
    d = dashes.first # first-in-scope dashboard wins every slot (deterministic)
    theme = {}
    theme['fonts'] = derive_fonts(d['style_rules'] || {})
    pw = derive_page_width(d['canvas_px'])
    theme.merge!(pw) if pw
    canvas = derive_canvas(d)
    theme['backgroundCanvas'] = canvas if canvas
    scheme = derive_scheme(d)
    theme['categoricalScheme'] = scheme if scheme && scheme.size >= 2
    # Workbook-wide: only when EVERY dashboard is flush (the container wrap is per dashboard).
    theme['space'] = FLUSH_SPACE.dup if dashes.all? { |x| flush_tiles?(x) }
    theme
  end

  # Plan C15 (verdict grid-gutters): theme.overrides.space for flush tiles.
  FLUSH_SPACE = { 'showElementPadding' => 'hidden', 'unit' => 'small' }.freeze

  # TWB fact: a tiled sheet zone's <zone-style> carries `margin` (Tableau's
  # "outer padding", the gap between tiles; default 4, serialized) and
  # `padding` (inner padding, default 0). The source is "tiled with no inner
  # padding" (tiles butt together) only when there are >=2 chart tiles and EVERY
  # chart tile explicitly declares margin 0 (any side set must be 0) with no
  # non-zero padding. Undeclared margins = Tableau's default 4 -> NOT flush.
  # Shared by derive (theme space) and build-dashboard-layout (container wrap).
  def flush_tiles?(d)
    return false unless d.is_a?(Hash)
    tiles = []
    walk = lambda do |nodes|
      Array(nodes).each do |n|
        kids = n['children']
        if kids.is_a?(Array) && !kids.empty?
          walk.call(kids)
        elsif n['kind'] == 'chart'
          tiles << n
        end
      end
    end
    walk.call(d['zone_tree'])
    return false if tiles.size < 2
    tiles.all? do |t|
      m = t['margins']
      p = t['paddings']
      # all-sides `margin` = 0, or all four per-side margins = 0 (undeclared sides default to 4)
      m.is_a?(Hash) && (m.key?('all') || %w[top right bottom left].all? { |k| m.key?(k) }) &&
        m.values.all? { |v| v.to_i.zero? } &&
        (p.nil? || p.values.all? { |v| v.to_i.zero? })
    end
  end

  # F1-F4: font-family slots. dataFont = table/chart data; textFont = titles
  # and text. Sigma's titleFont has no family field, so a dash-title family
  # can only land in textFont (by design, not a loss).
  def derive_fonts(style_rules)
    wb = style_rules['workbook'] || {}
    db = style_rules['dashboard'] || {}
    fam = lambda do |scope, element|
      v = scope.dig(element, 'font-family').to_s.strip.gsub(/\A['"]|['"]\z/, '')
      v.empty? ? nil : v
    end
    base = fam.call(wb, 'all')
    data = fam.call(wb, 'worksheet') || base
    text = fam.call(db, 'dash-title') || fam.call(db, 'dash-text') ||
           fam.call(wb, 'dash-title') || fam.call(wb, 'title') ||
           fam.call(wb, 'dash-text') || base
    { 'textFont' => map_font(text), 'dataFont' => map_font(data) }
  end

  # Source family -> a family Sigma renders (see SIGMA_FONTS); nil/undeclared
  # and unsupported names -> Lato.
  def map_font(name)
    n = name.to_s.strip
    SIGMA_FONTS.find { |f| f.casecmp(n).zero? } || DEFAULT_FONT
  end

  # P1: a fixed-width dashboard is an authored canvas — carry it. Range /
  # automatic sizing and phone-narrow (<600, also Sigma's minimum) are omitted.
  def derive_page_width(canvas_px)
    return nil unless canvas_px.is_a?(Hash)
    w = canvas_px['w'].to_i
    fixed = canvas_px['sizing_mode'] == 'fixed'
    return nil unless fixed && w >= 600
    { 'pageWidth' => 'custom', 'maxPageWidth' => w }
  end

  # C1 (outermost zone fill) then C2 (dashboard Format▸Shading, stored as a
  # dashboard-scope style-rule element='table' background-color — the
  # "transparent sheets on a shaded dashboard" idiom). Declared #ffffff is
  # emitted (a declaration beats guessing the default); transparent = absent.
  def derive_canvas(d)
    roots = d['zone_tree'] || []
    c = roots.first && roots.first['fill_color']
    c = nil if c.to_s.downcase == '#00000000'
    c ||= begin
      v = (d['style_rules'] || {}).dig('dashboard', 'table', 'background-color')
      v.to_s.downcase == '#00000000' ? nil : v
    end
    # Tableau's undeclared fixed-dashboard canvas defaults to white. Sigma's
    # undeclared page canvas is gray, which creates visible gutters/card chrome
    # around an otherwise faithful white dashboard.
    c ||= '#ffffff' if d.dig('canvas_px', 'sizing_mode') == 'fixed'
    return nil unless c.is_a?(String) && c =~ /\A#[0-9a-fA-F]{6}/
    c[0, 7].downcase
  end

  # S0 (PR-12): EXPLICIT member→color assignments beat frequency ranking —
  # themeOverrides.categoricalScheme applies POSITIONALLY in category-sort
  # order, so when the .twb binds members to colors the scheme must be ordered
  # ascending by member (the only slice-color path for pie/donut, and the fix
  # for the series-inversion class). Conservative: only when every assigned
  # zone colors by the same field (else nil → S1 frequency order unchanged).
  # Then S1/S2 (brand palette from color encodings + categorical palettes,
  # frequency-ranked — parse-twb-layout) then S3 (container-tint fallback for
  # the region-card idiom), capped at SCHEME_CAP.
  def derive_scheme(d)
    explicit = SeriesColors.explicit_scheme_for_dashboard(d, SCHEME_CAP)
    return explicit if explicit
    brand = d['brand_palette']
    return brand.first(SCHEME_CAP) if brand.is_a?(Array) && brand.size >= 2
    palette = []
    seen = {}
    walk = lambda do |nodes|
      (nodes || []).each do |n|
        fc = n['fill_color']
        if n['kind'] == 'container' && fc.is_a?(String) && fc =~ /\A#[0-9a-fA-F]{8}\z/
          base = fc[0, 7].downcase # strip alpha → the saturated mark color
          unless seen[base]
            seen[base] = true
            palette << base
          end
        end
        walk.call(n['children'])
      end
    end
    walk.call(d['zone_tree'])
    palette.first(SCHEME_CAP)
  end

  # Shared emission: mutate a workbook-spec hash in place. `theme` is
  # derive()'s output. No-op on {} (the never-worse contract).
  def apply!(spec, theme)
    return spec if theme.nil? || theme.empty?
    overrides = {}
    if theme['fonts'] && !theme['fonts'].empty?
      overrides['fonts'] = theme['fonts']
    end
    if theme['pageWidth']
      overrides['pageWidth'] = theme['pageWidth']
      overrides['maxPageWidth'] = theme['maxPageWidth'] if theme['maxPageWidth']
    end
    overrides['space'] = theme['space'] if theme['space']
    overrides['colorOverrides'] = [{ 'name' => 'backgroundCanvas', 'color' => theme['backgroundCanvas'] }] if theme['backgroundCanvas']
    overrides['categoricalScheme'] = theme['categoricalScheme'] if theme['categoricalScheme']
    unless overrides.empty?
      # Live since 2026-08: themeName/themeOverrides moved to
      # document.settings.theme.{name,overrides} (see shared/lib/code_rep.rb
      # DOC_KEYS). A flat top-level themeName/themeOverrides is invalid on
      # write and gets silently dropped by the code-rep wrapper.
      # Merge into any existing settings.theme (name, palette overrides) and
      # sibling settings keys (e.g. navigation) — never replace them.
      settings = spec['settings'] = (spec['settings'] || {})
      existing = settings['theme'].is_a?(Hash) ? settings['theme'] : {}
      existing_ov = existing['overrides'].is_a?(Hash) ? existing['overrides'] : {}
      settings['theme'] = existing.merge('name' => existing['name'] || 'Light',
                                         'overrides' => existing_ov.merge(overrides))
    end
    spec
  end
end
