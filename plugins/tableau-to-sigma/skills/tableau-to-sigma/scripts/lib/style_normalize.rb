# frozen_string_literal: true
#
# style_normalize.rb — STYLE-NORMALIZE pass over a workbook spec (v5.1, round-4
# forensics: scratchpad v51-spec-chrome.md §5, v51-spec-pivotrank.md §4.3).
#
# WHY: the exit-4 hand-authoring path (how every round-4 spec actually shipped)
# has no gate for Sigma's silent chrome defaults. Live-confirmed failure modes:
#   - a pivot-table with NO `totals` key renders grand-total row AND column
#     (Tableau crosstabs show none unless declared — consensus defect 2);
#   - `formatString` is d3-format grammar; Excel/Tableau-style "0.0%" is
#     silently unparseable → integer rendering (consensus defect 5, leg B);
#   - RCF agents fall back to Sigma's default royal accent (#1a70f1/#1f73f1)
#     for dataBars/backgroundScale schemes instead of the source's brand hue
#     (pivotRank defect 4).
#
# CONTRACT (do not change the shape without updating post-and-readback wiring):
#
#   changes = StyleNormalize.normalize!(spec, layout: <dashboard-layout.json
#                                             parsed array, or nil>)
#
#   - Mutates `spec` in place. Returns an Array of change records:
#       { 'element_id' => ..., 'field' => ..., 'from' => ..., 'to' => ...,
#         'rule' => 'SN-…' }
#   - Non-rewrites (unknown format grammars, malformed theme hues) are LOGGED,
#     not touched: StyleNormalize.warnings holds the current run's warning
#     strings (reset on every normalize! call) — callers print/persist them.
#   - Idempotent: normalize!(normalize!(spec)) records zero further changes.
#   - Conservative: NEVER overrides a valid deliberate choice — an existing
#     `totals` key, a grammar-valid d3 formatString, an explicit 2-decimal
#     percent, or a non-default conditionalFormats scheme are never touched.
#
# RULES
#   SN-2 pivot-totals      pivot-table with no `totals` key gains
#                          {showGrandTotals: 'hidden'} (Sigma default = shown;
#                          Tableau crosstab default = none). Honors a future
#                          layout `has_grand_totals` zone signal when present.
#   SN-3 format-grammar    number formatStrings that are Excel/Tableau digit
#                          masks, not d3, are translated ('0.0%'→',.1%',
#                          '#,##0'→',.0f', '#,##0.0'→',.1f', '0%'→',.0%').
#                          Valid-d3 (conservative grammar check) untouched;
#                          unknown grammars warned + untouched.
#   SN-4 percent-precision a column whose formula calls PercentOfTotal( and
#                          whose format is missing or integer-percent
#                          (',.0%'/'.0%') gets ',.1%' (the corpus sources print
#                          1 decimal — Tableau percent class p0.0%). An
#                          explicit 2-decimal (or any other) choice stays.
#   SN-5 scheme-default    dataBars/backgroundScale conditionalFormats whose
#                          scheme carries the Sigma default royal literals
#                          (#1a70f1/#1f73f1) while the spec declares a theme
#                          categoricalScheme are rewritten to the pivotRank
#                          derivation: [mix(dominant, white, 88%), dominant]
#                          where dominant = first categoricalScheme entry.
#                          No theme declared → untouched (nothing to derive).
#
# NOT here: SN-1 title-hide ships separately via put-layout — the live API
# rejects name:{text, visibility:'hidden'} (probed 2026-07-11: 400 "cannot mix
# visibility:'hidden' with title content").
require_relative 'workbook_code'

module StyleNormalize
  RULE_TOTALS  = 'SN-2-pivot-totals'
  RULE_GRAMMAR = 'SN-3-format-grammar'
  RULE_PERCENT = 'SN-4-percent-precision'
  RULE_SCHEME  = 'SN-5-scheme-default-guard'

  # Sigma's default accent family — the exact literals RCF agents reach for
  # when no source ramp is threaded (v51-spec-pivotrank.md: "that constant is
  # the defect"). Matched case-insensitively but only as exact 6-digit hex.
  ROYAL_DEFAULT_LITERALS = %w[#1a70f1 #1f73f1].freeze

  # pivotRank derivation: tint fraction toward white for the low stop.
  SCHEME_TINT_TOWARD_WHITE = 0.88

  # conditionalFormats types that carry a color `scheme` (workbook-layout.md
  # "conditionalFormats" — type 'single' takes flat colors, never a scheme).
  SCHEME_CF_TYPES = %w[dataBars backgroundScale].freeze

  # Integer-percent strings SN-4 upgrades (and nothing else — ',.2%' etc. are
  # deliberate choices and stay).
  INTEGER_PERCENT_STRINGS = [',.0%', '.0%'].freeze

  # Conservative d3-format acceptor: [sign(], symbol $, grouping comma,
  # .precision, ~, type] — the subset Sigma documents (sigma-workbooks
  # formatting.md) plus the paren-negative sign. DELIBERATELY excludes d3's
  # fill/align/zero/width syntax so Excel-style digit masks ('0.0%', '#,##0')
  # are NOT accepted: Sigma's parser rejects them even where stock d3 might
  # not (live: sonnet's "0.0%" rendered integer). Anything this accepts is
  # left untouched.
  D3_NUMBER_FORMAT_RE = /\A[(+\-]?\$?,?(?:\.\d+)?~?[fdeEgGrs%]?\z/

  module_function

  # Warning strings from the most recent normalize! run (unknown format
  # grammars, malformed theme hues). Reset on every call.
  def warnings
    @warnings ||= []
  end

  # Display text for any name shape (string or the {text:, visibility:} hash
  # form) — v51-spec-chrome.md §5.4. '' when absent; callers fall back to id.
  def el_name(el)
    n = el && el['name']
    n.is_a?(Hash) ? n['text'].to_s : n.to_s
  end

  # Mutates spec in place; returns the changes array (see CONTRACT above).
  def normalize!(spec, layout: nil)
    @warnings = []
    changes = []
    return changes unless spec.is_a?(Hash)
    document = WorkbookCode.document(spec)
    zones = chart_zones_by_key(layout)
    WorkbookCode.elements(document).each do |el|
      next unless el.is_a?(Hash)
      normalize_pivot_totals!(el, zones, changes)
      normalize_scheme_defaults!(document, el, changes)
      columns = el['columns']
      next unless columns.is_a?(Array)
      columns.each_with_index do |col, i|
        next unless col.is_a?(Hash)
        repair_format_grammar!(el, col, i, changes)
        normalize_percent_precision!(el, col, i, changes)
      end
    end
    changes
  end

  # -- SN-2 ------------------------------------------------------------------

  # Tableau crosstabs default to NO totals; Sigma pivots default to grand
  # totals SHOWN (live: sonnet/opus round-4 pivots, no `totals` key, grew
  # "Grand total" rows and columns). The source grand-total signal isn't
  # parsed yet, so no-key = hide — matching the corpus and the consensus
  # verdicts. An existing `totals` key (any value) is NEVER touched: it is a
  # deliberate choice (escape hatch: totals: {showGrandTotals: 'shown'}).
  def normalize_pivot_totals!(el, zones, changes)
    return unless el['kind'] == 'pivot-table'
    return if el.key?('totals')
    zone = zones[normalize_key(el_name(el))]
    show = (zone && zone['has_grand_totals'] == true) ? 'shown' : 'hidden'
    el['totals'] = { 'showGrandTotals' => show }
    record(changes, el, 'totals', nil, el['totals'].dup, RULE_TOTALS)
  end

  # -- SN-3 ------------------------------------------------------------------

  # Repair Excel/Tableau-style number formatStrings into d3 grammar. Grammar-
  # valid strings pass untouched; untranslatable ones are warned + untouched
  # (the scale+suffix class '#,##0,,,B' has its own exact-path recipe).
  def repair_format_grammar!(el, col, idx, changes)
    fmt = col['format']
    return unless fmt.is_a?(Hash) && fmt['kind'] == 'number'
    fs = fmt['formatString']
    return unless fs.is_a?(String) && !fs.empty?
    return if valid_d3_number_format?(fs)
    repaired = digit_mask_to_d3(fs)
    if repaired.nil?
      warnings << "#{RULE_GRAMMAR} #{element_label(el)} #{column_label(col, idx)}: " \
                  "formatString #{fs.inspect} is neither valid d3 nor a translatable " \
                  'Tableau/Excel digit mask — left untouched'
      return
    end
    return if repaired == fs
    record(changes, el, "#{column_label(col, idx)}.format.formatString", fs, repaired, RULE_GRAMMAR)
    fmt['formatString'] = repaired
  end

  def valid_d3_number_format?(fs)
    !(fs =~ D3_NUMBER_FORMAT_RE).nil?
  end

  # The general digit-mask → d3 mapping (v51-spec-chrome.md SN-3). Mirrors
  # tableau_format_to_sigma in build-charts-from-signals.rb (which always
  # emits the comma-grouped form — so '0.0%' → ',.1%', not '.1%'); kept
  # self-contained here so the normalize gate has no builder dependency.
  # Returns the d3 string, or nil when the grammar is unknown.
  #   p0.0%      → ,.1%     (Tableau percent class)
  #   0.0%  / 0% → ,.1% / ,.0%
  #   #,##0(.0…) → ,.0f / ,.1f …
  #   $#,##0.00  → $,.2f
  # Excel section syntax 'pos;neg' is honored: a parenthesized negative
  # section contributes d3's '(' sign.
  def digit_mask_to_d3(s)
    segments = s.split(';')
    pos = segments[0].to_s.strip
    neg = segments[1]
    prefix = (neg && neg.include?('(') && neg.include?(')')) ? '(' : ''
    if (m = pos.match(/\Ap\d*(?:\.(\d+))?%\z/i)) # Tableau percent class p0.0%
      return "#{prefix},.#{(m[1] || '').length}%"
    end
    if (m = pos.match(/\A\$\s?[#,0]+(?:\.(0+))?\z/)) # currency digit mask
      return "#{prefix}$,.#{(m[1] || '').length}f"
    end
    if (m = pos.match(/\A[#,0]+(?:\.(0+))?\s?(%)?\z/)) # plain mask, opt. percent
      return "#{prefix},.#{(m[1] || '').length}#{m[2] ? '%' : 'f'}"
    end
    nil
  end

  # -- SN-4 ------------------------------------------------------------------

  # PercentOfTotal( values print 1 decimal in the corpus sources (Tableau's
  # percent class defaults to p0.0%). Upgrade ONLY a missing format or an
  # integer-percent one — an explicit ',.2%' (or any other string) is a
  # deliberate choice and stays. Runs after SN-3, so an Excel-style '0%'
  # arrives here already repaired to ',.0%' and is then upgraded.
  def normalize_percent_precision!(el, col, idx, changes)
    return unless col['formula'].to_s =~ /\bPercentOfTotal\s*\(/i
    fmt = col['format']
    if fmt.nil?
      col['format'] = { 'kind' => 'number', 'formatString' => ',.1%' }
      record(changes, el, "#{column_label(col, idx)}.format", nil, col['format'].dup, RULE_PERCENT)
      return
    end
    return unless fmt.is_a?(Hash)
    return if fmt['kind'] && fmt['kind'] != 'number' # datetime etc. — not ours
    fs = fmt['formatString']
    # v5.3: only FILL a missing format — never coerce a VALID integer-percent
    # one. Sources legitimately print integer percents ("25%"); forcing ,.1%
    # made a round-5 run waive the whole normalizer to keep source fidelity.
    # (The builder derives precision from the source pill's own text-format,
    # so a set value is trusted.)
    return unless fs.to_s.empty?
    fmt['kind'] ||= 'number'
    fmt['formatString'] = ',.1%'
    record(changes, el, "#{column_label(col, idx)}.format.formatString",
           nil, ',.1%', RULE_PERCENT)
  end

  # -- SN-5 ------------------------------------------------------------------

  # Sigma-default royal schemes on dataBars/backgroundScale are the pivotRank
  # defect 4 constant. When the spec declares a source-derived theme
  # categoricalScheme, replace with the derivation rule:
  #   dominant = categoricalScheme.first (frequency-ranked brand hue)
  #   scheme   = [mix(dominant, white, 88%), dominant]
  # Without a theme there is nothing faithful to derive → untouched. A scheme
  # with no royal literal is a deliberate choice → untouched.
  def normalize_scheme_defaults!(spec, el, changes)
    cfs = el['conditionalFormats']
    return unless cfs.is_a?(Array)
    theme = spec.dig('settings', 'theme', 'overrides', 'categoricalScheme')
    return unless theme.is_a?(Array) && !theme.empty?
    dominant = theme.first.to_s.strip.downcase
    cfs.each_with_index do |cf, i|
      next unless cf.is_a?(Hash) && SCHEME_CF_TYPES.include?(cf['type'])
      scheme = cf['scheme']
      next unless scheme.is_a?(Array)
      next unless scheme.any? { |c| ROYAL_DEFAULT_LITERALS.include?(c.to_s.strip.downcase) }
      unless dominant =~ /\A#\h{6}\z/
        warnings << "#{RULE_SCHEME} #{element_label(el)}: conditionalFormats[#{i}] carries the " \
                    "Sigma default royal scheme but settings.theme.overrides.categoricalScheme[0] " \
                    "(#{theme.first.inspect}) is not #rrggbb hex — left untouched"
        next
      end
      replacement = [tint_toward_white(dominant, SCHEME_TINT_TOWARD_WHITE), dominant]
      next if scheme == replacement # dominant is itself royal — already derived
      record(changes, el, "conditionalFormats[#{i}].scheme", scheme.dup, replacement.dup, RULE_SCHEME)
      cf['scheme'] = replacement
    end
  end

  # mix(hex, white, amount): lighten each channel toward 255 by `amount`.
  # tint_toward_white('#52baee', 0.88) → '#eaf7fd'.
  def tint_toward_white(hex, amount)
    r = hex[1, 2].to_i(16)
    g = hex[3, 2].to_i(16)
    b = hex[5, 2].to_i(16)
    format('#%02x%02x%02x',
           (r + (255 - r) * amount).round,
           (g + (255 - g) * amount).round,
           (b + (255 - b) * amount).round)
  end

  # -- shared helpers --------------------------------------------------------

  def record(changes, el, field, from, to, rule)
    changes << { 'element_id' => element_id(el), 'field' => field,
                 'from' => from, 'to' => to, 'rule' => rule }
  end

  def element_id(el)
    id = el['id'] || el['elementId']
    return id unless id.to_s.empty?
    name = el_name(el)
    name.empty? ? '(unnamed)' : name
  end

  def element_label(el)
    "element '#{element_id(el)}'"
  end

  def column_label(col, idx)
    key = col['id'] || col['name']
    key.to_s.empty? ? "columns[#{idx}]" : "columns[#{key}]"
  end

  # dashboard-layout.json → { normalized caption/view_ref => chart zone }.
  # Used only to honor the (future) has_grand_totals zone signal; absent
  # layout degrades to spec-only behavior (v51-spec-chrome.md §5.1).
  def chart_zones_by_key(layout)
    out = {}
    return out unless layout.is_a?(Array)
    layout.each do |dash|
      next unless dash.is_a?(Hash)
      zones = dash['zones']
      next unless zones.is_a?(Array)
      zones.each do |z|
        next unless z.is_a?(Hash) && z['kind'] == 'chart'
        [z['caption'], z['view_ref'], z['display_title']].each do |k|
          key = normalize_key(k)
          out[key] ||= z unless key.empty?
        end
      end
    end
    out
  end

  def normalize_key(s)
    s.to_s.downcase.gsub(/\s+/, ' ').strip
  end
end
