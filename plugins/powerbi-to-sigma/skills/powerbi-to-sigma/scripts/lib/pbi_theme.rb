# pbi_theme.rb — Power BI report theme -> Sigma settings.theme.overrides.
#
# The single biggest style-fidelity gap in PBI->Sigma migration was that we
# reproduced data + layout but NOT the visual theme: no categorical palette, no
# card chrome, no borders. Everything a Sigma workbook needs to look like its
# PBI source is derivable from the report's base theme name + the built-in PBI
# palettes below. See refs/style-fidelity.md.
#
# Order matters: Sigma assigns categoricalScheme[i] to the i-th category/series,
# exactly as PBI colors by legend order — so the palette sequence must match the
# PBI theme's data-color sequence for donut/pie slices and multi-series charts
# to line up.
module PbiTheme
  # Built-in PBI report-theme data-color sequences. 'CY24SU10' is the 2024+
  # default ("Power BI"); the classic sequence covers pre-2023 reports.
  PALETTES = {
    'CY24SU10' => %w[#118DFF #12239E #E66C37 #6B007B #E044A7 #744EC2 #D9B300 #D64550],
    'CY23SU08' => %w[#118DFF #12239E #E66C37 #6B007B #E044A7 #744EC2 #D9B300 #D64550],
    'classic'  => %w[#01B8AA #374649 #FD625E #F2C80F #5F6B6D #8AD4EB #FE9666 #A66999],
    # Legacy built-in theme still stamped on older reports; its base-theme JSON ships
    # no dataColors, so the classic ten-color sequence lives here.
    'CY18SU07' => %w[#01B8AA #374649 #FD625E #F2C80F #5F6B6D #8AD4EB #FE9666 #A66999 #3599B8 #DFBFBF]
  }.freeze
  # PBI's current default when the report names no explicit theme.
  FALLBACK = PALETTES['CY24SU10']

  HEX = /\A#[0-9A-Fa-f]{6}\z/

  # True when the theme name has a built-in palette here.
  def self.known?(theme_name)
    PALETTES.key?(theme_name.to_s)
  end

  # The data-color sequence. The theme's OWN dataColors (extract-pbir signals
  # `theme_data_colors`: custom theme over base theme) win when present and valid;
  # otherwise the built-in palette for the name; otherwise the 2024 default.
  def self.palette(theme_name, data_colors = nil)
    if data_colors.is_a?(Array) && !data_colors.empty? && data_colors.all? { |c| c.to_s =~ HEX }
      return data_colors.map { |c| c.to_s.upcase }
    end
    PALETTES[theme_name.to_s] || FALLBACK
  end

  # scheme[0] — PBI colors single-series charts AND card values with it.
  def self.accent(theme_name, data_colors = nil)
    palette(theme_name, data_colors).first
  end

  # Classic-palette base themes render card callout values in dark gray, not the accent.
  CLASSIC_THEMES = %w[CY18SU07 classic].freeze
  CLASSIC_CARD_VALUE = '#333333'

  # Default KPI card value color when the visual sets none: dark gray on the classic
  # themes (sampled from a rendered report), the palette accent everywhere else.
  def self.card_value_color(theme_name, data_colors = nil)
    return CLASSIC_CARD_VALUE if CLASSIC_THEMES.include?(theme_name.to_s)
    accent(theme_name, data_colors)
  end

  # Default value color for ONE tile of a multi-row card when the visual sets none: the classic dark gray on
  # the classic themes, else nil (Sigma's default dark value text). Power BI multi-row cards do not paint their
  # values in the accent, so the single-card accent default is not used here.
  def self.multi_row_card_value_color(theme_name)
    CLASSIC_THEMES.include?(theme_name.to_s) ? CLASSIC_CARD_VALUE : nil
  end

  # PBI ThemeDataColor -> '#RRGGBB'. ColorId 0 = theme background (white), 1 =
  # foreground (black), n >= 2 = palette[n-2] (out of range -> nil). Percent p > 0 blends toward white
  # (c + (255-c)*p); p < 0 toward black (c*(1+p)). Verified against rendered PBI.
  def self.theme_color(color_id, percent, pal)
    id = color_id.to_i
    base =
      case id
      when 0 then '#FFFFFF'
      when 1 then '#000000'
      else Array(pal)[id - 2]
      end
    return nil unless base.to_s =~ HEX
    p = percent.to_f
    rgb = base[1, 6].scan(/../).map { |h| h.to_i(16) }
    rgb = rgb.map do |c|
      v = p >= 0 ? c + (255 - c) * p : c * (1 + p)
      [[v.round, 0].max, 255].min
    end
    format('#%02X%02X%02X', *rgb)
  end

  # A visual's explicit colour signal -> '#RRGGBB' | nil. Accepts a hex String (passed through)
  # or the extractor's {'theme' => id, 'percent' => p} Hash (resolved against the palette).
  def self.resolve_color_signal(value, pal)
    case value
    when String then value.strip.empty? ? nil : value
    when Hash then value['theme'].nil? ? nil : theme_color(value['theme'], value['percent'], pal)
    end
  end

  # The Sigma settings.theme.overrides that reproduce a PBI report's look: card chrome,
  # subtle 1px borders, rounded corners, and the source palette (which drives
  # donut/pie + multi-series colors). Stacked on the built-in `Light` theme.
  def self.overrides(theme_name, data_colors = nil)
    pal = palette(theme_name, data_colors)
    {
      'hasCards'          => 'shown',
      'borderRadius'      => 'round',
      'elementBorder'     => { 'color' => '#E2E8F0', 'width' => 1 },
      'categoricalScheme' => pal,
      'colors'            => { 'highlight' => pal.first }
    }
  end
end
