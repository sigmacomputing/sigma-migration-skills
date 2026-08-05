# frozen_string_literal: true
#
# format_map.rb — the ONE Tableau→Sigma format-string translator (PR-12).
#
# Before this lib the translator lived twice (parse-twb-layout.rb
# translate_format + build-charts-from-signals.rb tableau_format_to_sigma) and
# the copies had already drifted on date handling. Both now delegate here.
#
# Number formats → Sigma { kind: 'number', formatString: <d3-format>, ... }:
#   p0.0%        → ,.1%          (Tableau percent shorthand)
#   #,##0.0%     → ,.1%          (Excel-style percent mask)
#   $#,##0.00    → $,.2f + currencySymbol '$'   (€/£ carried as the symbol)
#   C1033        → $,.0f + currencySymbol '$'   (Tableau locale-currency code)
#   #,##0        → ,.0f
#   pos;(neg)    → leading '(' d3 sign modifier (parens-on-negative)
#   pos;;;"—"    → displayNullAs '—' (4th segment, QUOTED literal only —
#                  Sigma number formats support displayNullAs; live-verified)
#   #,##0,,,B    → nil (scale-comma + literal suffix is NOT d3-expressible —
#                  the builder's exact-format scaled-column recipe owns it;
#                  a trailing scale-comma with no suffix is nil too, so it
#                  routes to the same recipe instead of silently dropping /1e3)
#
# Date-time formats → Sigma { kind: 'datetime', formatString: <d3-time> }:
#   CRITICAL (live-run knowledge, 2026-07): Sigma spec date-time formats are
#   d3-time/strftime strings ('%B %-d, %Y'). Moment-style token strings
#   ("MMM D, YYYY") are NOT a format language to Sigma — every non-% char
#   prints LITERALLY, so the tile renders the text "MMM D, YYYY" instead of a
#   date. This translator therefore:
#     - maps Tableau/moment tokens (case-tolerant: yyyy/YYYY, d/D/dd/DD,
#       MMM/mmm, ddd weekday, h/hh/H/HH, am/pm) to %-directives, and
#     - REFUSES (returns nil) any string with an unmappable letter token —
#       an unmapped format is recorded in formats-emitted.json, never guessed
#       and never emitted as a literal-printing string.
#
# Pure: no I/O. Unit-tested by test-format-map.rb; consumed by
# parse-twb-layout.rb, build-charts-from-signals.rb, and the formats-emitted
# artifact writer.
require 'strscan'

module FormatMap
  module_function

  # ---- entry point ----------------------------------------------------------
  # Tableau format strings carry up to 4 ';'-segments: positive;negative;zero;
  # text. Returns a Sigma format hash or nil (= not confidently mappable).
  def translate(tableau_fmt)
    s = tableau_fmt.to_s
    return nil if s.strip.empty?
    segments = s.split(';', -1)
    pos = segments[0].to_s.empty? ? s : segments[0]
    neg = segments[1]
    prefix = neg && neg.include?('(') && neg.include?(')') ? '(' : ''
    out = number_format(pos, prefix) || datetime_format(s)
    return nil unless out
    if out['kind'] == 'number' && (nul = quoted_literal(segments[3]))
      out['displayNullAs'] = nul
    end
    out
  end

  # ---- numbers --------------------------------------------------------------
  CURRENCY_SYMBOLS = %w[$ € £].freeze

  def number_format(pos, prefix = '')
    p = pos.to_s.strip
    return nil if p.empty?
    # Tableau percent shorthand — p<int>[.<decimals>]%
    if (m = p.match(/\A[n]?p\d*(?:\.(\d+))?%\z/i))
      return { 'kind' => 'number', 'formatString' => "#{prefix},.#{m[1].to_s.length}%" }
    end
    # Tableau locale-currency code — C<locale>[.<decimals>] (C1033 = $#,##0)
    if (m = p.match(/\AC\d+(?:\.(\d+))?%?\z/))
      return { 'kind' => 'number', 'formatString' => "#{prefix}$,.#{m[1].to_s.length}f",
               'currencySymbol' => '$' }
    end
    # Currency — leading $/€/£, optionally c"$"-quoted ('c' = Tableau currency class)
    if (m = p.match(/\A[nc]?["\\']*([$€£])/))
      sym = m[1]
      decimals = (p.match(/\.(0+)/) || [])[1].to_s.length
      return { 'kind' => 'number', 'formatString' => "#{prefix}$,.#{decimals}f",
               'currencySymbol' => sym }
    end
    # Excel-style percent mask — #,##0.0%
    if (m = p.match(/\A[n]?[#,0]+(?:\.(0+))?%\z/))
      return { 'kind' => 'number', 'formatString' => "#{prefix},.#{m[1].to_s.length}%" }
    end
    # Plain number mask — #,##0[.00]. A TRAILING scale-comma ('#,##0,,') is a
    # /1000-per-comma display scale d3 can't express — refuse it (nil) so the
    # scaled-suffix exact-format recipe owns it instead of a silently-unscaled
    # ',.0f' (the pre-PR-12 behavior was off by 1e3 per comma).
    if (m = p.match(/\A[n]?([#,0]+)(?:\.(0+))?\z/)) && !m[1].end_with?(',')
      return { 'kind' => 'number', 'formatString' => "#{prefix},.#{m[2].to_s.length}f" }
    end
    nil
  end

  # ---- date-times -----------------------------------------------------------
  # Letter-run tokenizer over the whole string; quoted chunks pass through as
  # literals; ANY unmappable letter run → nil (never emit literal-printing
  # pseudo-tokens). 'm'/'mm' is month before an hour token, minute after (the
  # Tableau/Excel rule); 'M' is always month.
  def datetime_format(s)
    str = s.to_s
    return nil unless str =~ /[A-Za-z]/
    sc = StringScanner.new(str)
    out = +''
    hour_seen = false
    mapped = false
    until sc.eos?
      if (q = sc.scan(/"[^"]*"|'[^']*'/))
        lit = q[1..-2]
        return nil if lit.include?('%') # a literal % would read as a directive
        out << lit
      elsif sc.scan(%r{AM/PM|am/pm|A/P|a/p})
        out << '%p'
        mapped = true
      elsif (t = sc.scan(/[A-Za-z]+/))
        d = date_token(t, hour_seen)
        return nil unless d
        hour_seen = true if %w[%H %-H %I %-I].include?(d)
        mapped = true
        out << d
      else
        ch = sc.getch
        return nil if ch == '%'
        out << ch
      end
    end
    return nil unless mapped && out.include?('%')
    { 'kind' => 'datetime', 'formatString' => out }
  end

  def date_token(t, hour_seen)
    case t
    when /\A[yY]{3,4}\z/    then '%Y'
    when /\A[yY]{1,2}\z/    then '%y'
    when 'MMMM', 'mmmm'     then '%B'
    when 'MMM', 'mmm'       then '%b'
    when 'MM'               then '%m'
    when 'M'                then '%-m'
    when 'mm'               then hour_seen ? '%M' : '%m'
    when 'm'                then hour_seen ? '%-M' : '%-m'
    when /\A[dD]{4}\z/      then '%A' # weekday name (dddd)
    when /\A[dD]{3}\z/      then '%a'
    when /\A[dD]{2}\z/      then '%d'
    when /\A[dD]\z/         then '%-d'
    when 'HH'               then '%H'
    when 'H'                then '%-H'
    when 'hh'               then '%I'
    when 'h'                then '%-I'
    when 'ss', 'SS'         then '%S'
    when 's', 'S'           then '%-S'
    when 'AM', 'PM', 'am', 'pm', 'tt', 'TT' then '%p'
    end
  end

  def quoted_literal(seg)
    m = seg.to_s.strip.match(/\A"([^"]*)"\z/)
    m && m[1]
  end

  # ---- formats-emitted artifact (PR-12 mechanical check) --------------------
  # Per-tile ledger giving the blind grader's `numbers_formatted` dimension a
  # mechanical counterpart: for every source format string that applies to a
  # built element, record the emitted Sigma format and whether the mapping is
  # mechanical ('mapped') or the source string is beyond the translator
  # ('unmapped' — recorded, never guessed; heuristic defaults may still ship
  # but are NOT claimed as source-derived). Consumed by the RCF loop and
  # future gates; written next to --out as formats-emitted.json.
  #
  # elements: built element hashes still carrying '_worksheet'/'_dashboard'.
  # worksheets_meta: parse-twb-layout meta['worksheets'] (string keys).
  # column_formats: meta['column_formats'] (caption → raw default-format).
  # columns_by_guid: meta['columns_by_guid'] — bridges a format key's INTERNAL
  #   id (`Calculation_AvgBal`) to the CAPTION its column is named by, so the
  #   ledger stops false-reporting caption-named KPI/measure columns as
  #   'unmapped' (mirrors build-charts pick_tableau_format's id→caption bridge).
  def emitted_records(elements, worksheets_meta, column_formats = {}, columns_by_guid = {})
    id2cap = {}
    (columns_by_guid || {}).each do |gid, ci|
      cap = ci.is_a?(Hash) ? ci['caption'].to_s : ''
      id2cap[gid.to_s] = cap unless cap.empty?
    end
    recs = []
    Array(elements).each do |el|
      next unless el.is_a?(Hash) && !el['_worksheet'].to_s.empty?
      ws = (worksheets_meta || {})[el['_worksheet'].to_s] || {}
      cols = Array(el['columns']).select { |c| c.is_a?(Hash) }
      sources = {}
      (ws['formats'] || {}).each do |field, raw|
        f = friendly_from_field_ref(field)
        sources[f] = raw unless f.to_s.empty?
      end
      (column_formats || {}).each do |capn, raw|
        next if sources.keys.any? { |k| keys_match?(k, capn) }
        next unless cols.any? { |c| keys_match?(c['name'], capn) }
        sources[capn] = raw
      end
      sources.each do |fname, raw|
        # match the column by the format-key's internal id OR the caption it
        # resolves to through columns_by_guid.
        names = [fname, id2cap[fname.to_s]].compact
        col = cols.find { |c| names.any? { |nm| keys_match?(c['name'], nm) } }
        emitted = col && col['format']
        status = translate(raw) && emitted ? 'mapped' : 'unmapped'
        recs << { 'element_id' => el['id'], 'worksheet' => el['_worksheet'],
                  'dashboard' => el['_dashboard'], 'field' => fname,
                  'source_format' => raw, 'emitted_format' => emitted,
                  'status' => status }
      end
    end
    recs
  end

  # Format-key ref (`[usr:Return Rate:qk]` / a bare caption) → friendly name.
  def friendly_from_field_ref(field)
    inner = field.to_s.scan(/\[([^\]]+)\]/).flatten.last || field.to_s
    parts = inner.split(':')
    parts.length >= 3 ? parts[1].to_s : inner
  end

  # Same fuzzy match pick_tableau_format uses (normalized equality/containment).
  def keys_match?(a, b)
    ka = norm_key(a)
    kb = norm_key(b)
    !ka.empty? && !kb.empty? && (ka == kb || ka.include?(kb) || kb.include?(ka))
  end

  def norm_key(s)
    s.to_s.downcase.gsub(/\W+/, '')
  end
end
