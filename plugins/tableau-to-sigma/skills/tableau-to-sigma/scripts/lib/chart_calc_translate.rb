# chart_calc_translate.rb — the PURE Tableau-calc → Sigma-formula translators
# that build-charts-from-signals.rb applies at chart/pivot build time (window
# table-calcs, User-aggregated ratios, row-level/dimension calcs, FIXED LOD
# parsing). No I/O and no globals, so scan-workbook-gaps.rb can ask the same
# question the build answers — "will the chart path translate this calc?" —
# instead of re-deriving it with a second set of regexes (a converter refusal
# the chart path translates must not stop the gap gate).
#
# Top-level defs on purpose: build-charts-from-signals.rb has always defined
# these at top level, and the offline tests extract them by `^def <name>`.

# Tableau "User"-aggregated calc fields (derivation=User) are already-aggregated
# expressions like `SUM([Returns]) / COUNT([Order Id])` — wrapping them in
# another Sum() against a master column that doesn't exist emits an
# unresolvable `Sum([Master/X])` (bead k3kk). Decompose the Tableau formula
# directly into a Sigma formula against the master table instead. Returns nil
# when the formula contains anything beyond simple aggregates + arithmetic
# (the caller falls back and warns loudly).
USER_AGG_FN = {
  'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
  'MEDIAN' => 'Median'
}.freeze

def strip_tableau_comments(formula)
  formula.to_s.gsub(%r{/\*.*?\*/}m, '').gsub(%r{//[^\r\n]*}, '')
end

def worksheet_calculation_for(calculations, *candidates)
  normalized = candidates.flatten.compact.map do |candidate|
    candidate.to_s.gsub(/^\[|\]$/, '').strip.downcase
  end.reject(&:empty?)
  Array(calculations).find do |calculation|
    [calculation['name'], calculation['caption']].compact.any? do |candidate|
      normalized.include?(candidate.to_s.gsub(/^\[|\]$/, '').strip.downcase)
    end
  end
end

def translated_calc_reference(name, mmap, columns_by_guid)
  key = name.to_s.gsub(/^\[|\]$/, '').strip
  return nil if key.empty?
  mapped = map_column(key, mmap)
  return "[Master/#{mapped['name']}]" if mapped
  info = (columns_by_guid || {})[key]
  active = strip_tableau_comments(info && info['formula']).strip
  return nil if active.empty?
  translate_dim_calc(active, mmap, columns_by_guid) ||
    translate_row_level_calc(active, mmap, columns_by_guid)
end

def translate_sla_ratio(formula, mmap, columns_by_guid)
  text = strip_tableau_comments(formula).gsub(/\s+/, ' ').strip
  match = text.match(
    %r{\A\(?\s*COUNTD\(\[([^\]]+)\]\)\s*-\s*\[([^\]]+)\]\s*\)?\s*/\s*COUNTD\(\[\1\]\)\z}i
  )
  return nil unless match
  doc_ref = translated_calc_reference(match[1], mmap, columns_by_guid)
  nested = (columns_by_guid[match[2]] || {})['formula'].to_s
  conditional = strip_tableau_comments(nested).match(/\ACOUNTD\s*\(\s*(IF\b.*\bEND)\s*\)\z/i)
  return nil unless doc_ref && conditional
  expanded = conditional[1].gsub(/\[([^\]]+)\]/) do
    translated_calc_reference(Regexp.last_match(1), mmap, columns_by_guid) ||
      "[#{Regexp.last_match(1)}]"
  end
  sigma_if = translate_dim_calc(expanded, mmap, columns_by_guid)
  return nil unless sigma_if
  "(CountDistinct(#{doc_ref}) - CountDistinct(#{sigma_if})) / CountDistinct(#{doc_ref})"
end

def split_top_level_args(text)
  args = []
  buffer = +''
  paren_depth = 0
  bracket_depth = 0
  quote = nil
  text.to_s.each_char do |char|
    if quote
      quote = nil if char == quote
      buffer << char
      next
    end
    if %w[' "].include?(char)
      quote = char
    elsif char == '['
      bracket_depth += 1
    elsif char == ']' && bracket_depth.positive?
      bracket_depth -= 1
    elsif bracket_depth.zero?
      paren_depth += 1 if char == '('
      paren_depth -= 1 if char == ')' && paren_depth.positive?
      if char == ',' && paren_depth.zero?
        args << buffer.strip
        buffer = +''
        next
      end
    end
    buffer << char
  end
  args << buffer.strip unless buffer.strip.empty?
  args
end

def parse_tableau_function_call(text, function_name)
  source = text.to_s.strip
  match = source.match(/\A#{Regexp.escape(function_name)}\s*\(/i)
  return nil unless match
  index = match.end(0)
  start = index
  depth = 1
  bracket_depth = 0
  quote = nil
  while index < source.length
    char = source[index]
    if quote
      quote = nil if char == quote
    elsif %w[' "].include?(char)
      quote = char
    elsif char == '['
      bracket_depth += 1
    elsif char == ']' && bracket_depth.positive?
      bracket_depth -= 1
    elsif bracket_depth.zero?
      depth += 1 if char == '('
      if char == ')'
        depth -= 1
        if depth.zero?
          return [split_top_level_args(source[start...index]), source[(index + 1)..].to_s.strip]
        end
      end
    end
    index += 1
  end
  nil
end

# extra_fns: additional Sigma function names the residue validator should
# accept (the window-calc path passes WINDOW_SIGMA_FNS so Cumulative*/Moving*/
# Rank/Lag/... formulas validate; plain ratio decomposition passes none).
def translate_user_agg_formula(formula, mmap, columns_by_guid = {}, extra_fns: [])
  s = strip_tableau_comments(formula).gsub(/\s+/, ' ').strip
  return nil if s.empty?
  sla = translate_sla_ratio(s, mmap, columns_by_guid)
  return sla if sla
  # Resolve Tableau-internal GUID refs ([d3b60b0e-…]) to their captions first —
  # worksheet calc formulas reference columns by GUID, not caption.
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption']}]" : "[#{Regexp.last_match(1)}]"
  end
  # IIF(c, t, e) → If(c, t, e) so guarded ratios (divide-by-zero protection)
  # survive the decomposition.
  s = s.gsub(/\bIIF\s*\(/i, 'If(')
  if (percentile = parse_tableau_function_call(s, 'PERCENTILE')) && percentile[0].length == 2
    value, raw_arg = percentile[0]
    translated_value =
      if value =~ /\AIF\b.*\bEND\z/i
        translate_dim_calc(value, mmap, columns_by_guid)
      elsif (column = value.match(/\A\[([^\]]+)\]\z/))
        translated_calc_reference(column[1], mmap, columns_by_guid)
      end
    percentile_arg =
      if raw_arg =~ /\A[0-9.]+\z/
        raw_arg
      elsif (parameter = raw_arg.match(/\A\[Parameters?\]\s*\.\s*\[([^\]]+)\]\z/i))
        info = (columns_by_guid || {})[parameter[1]]
        param_control_ref((info && info['caption']) || parameter[1])
      end
    return "PercentileCont(#{translated_value}, #{percentile_arg}) #{percentile[1]}".strip if translated_value && percentile_arg
  end
  if (conditional = s.match(/\A(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*(IF\b.*\bEND)\s*\)\s*(.*)\z/i))
    row_formula = translate_dim_calc(conditional[2], mmap, columns_by_guid)
    if row_formula
      function = {
        'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
        'MEDIAN' => 'Median', 'COUNTD' => 'CountDistinct', 'COUNT' => 'Count'
      }[conditional[1].upcase]
      return "#{function}(#{row_formula}) #{conditional[3]}".strip
    end
  end
  out = s.gsub(/\b(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[([^\]]+)\]\s*\)/i) do
    agg = Regexp.last_match(1).upcase
    col = Regexp.last_match(2)
    m   = map_column(col, mmap)
    ref = if m
            "[Master/#{m['name']}]"
          else
            translated_calc_reference(col, mmap, columns_by_guid) ||
              "[Master/#{col}]"
          end
    case agg
    when 'COUNT'  then "CountIf(IsNotNull(#{ref}))"
    when 'COUNTD' then "CountDistinct(#{ref})"
    else "#{USER_AGG_FN[agg]}(#{ref})"
    end
  end
  # ZN(expr) → Coalesce(expr, 0). One nesting level of parens is enough for
  # ZN(Sum([x]))-style wrappers; loop to handle repeated occurrences.
  while out =~ /\bZN\s*\(((?:[^()]|\([^()]*(?:\([^()]*\)[^()]*)*\))*)\)/i
    out = out.sub(Regexp.last_match(0), "Coalesce(#{Regexp.last_match(1)}, 0)")
  end
  # Validate: after stripping translated calls + refs, only arithmetic glue may
  # remain — otherwise the formula has constructs we can't safely auto-emit.
  residue = out.dup
  residue.gsub!(/"(?:\\.|[^"\\])*"/, '1') # string literals ("desc", "grand_total")
  residue.gsub!(/\[Master\/[^\]]+\]/, '1')
  allowed = %w[Sum Avg Min Max Median CountDistinct CountIf IsNotNull Coalesce If Abs Null NULL] + extra_fns
  residue.gsub!(/\b(#{allowed.map { |f| Regexp.escape(f) }.join('|')})\b/, '')
  residue.gsub!(/\b(?:and|or|not|null)\b/i, '')
  return nil unless residue =~ %r{\A[\s()+\-*/.,\d!=<>]*\z}
  out
end

# Row-level (non-aggregated) Tableau worksheet calc → Sigma formula over master
# columns (bead 3w4d: KPIs like "Avg. Days Since Order" aggregate a row-level
# DATEDIFF calc). Resolves GUID refs to captions, renames the common Tableau
# date/logic functions, rewrites bare refs to [Master/...]. Returns nil when
# the result still contains constructs we can't vouch for.
def translate_row_level_calc(formula, mmap, columns_by_guid = {})
  s = strip_tableau_comments(formula).gsub(/\s+/, ' ').strip
  return nil if s.empty?
  if (wrapped_if = s.match(/\A\(?\s*(IF\b.*\bEND)\s*\)?\s*(.*)\z/i))
    translated_if = translate_dim_calc(wrapped_if[1], mmap, columns_by_guid)
    return "#{translated_if} #{wrapped_if[2]}".strip if translated_if
  end
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end
  return nil if s =~ /\[[0-9a-f\-]{36}\]/i # unresolved GUID ref
  s = s.gsub(/\bDATEDIFF\s*\(\s*'([^']+)'\s*,/i) { "DateDiff(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATEADD\s*\(\s*'([^']+)'\s*,/i)  { "DateAdd(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATETRUNC\s*\(\s*'([^']+)'\s*,/i) { "DateTrunc(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATEPART\s*\(\s*'([^']+)'\s*,/i) { "DatePart(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bTODAY\s*\(\s*\)/i, 'Today()')
  s = s.gsub(/\bNOW\s*\(\s*\)/i, 'Now()')
  s = s.gsub(/\bIIF\s*\(/i, 'If(')
  s = s.gsub(/\bIFNULL\s*\(/i, 'Coalesce(')
  s = s.gsub(/\bABS\s*\(/i, 'Abs(')
  s = s.gsub(/\bSTR\s*\(/i, 'Text(')
  # Date-part extracts — align with the TS TABLEAU_FUNC_MAP so a row-level date
  # calc auto-translates instead of failing the residue check and dropping to a
  # manual warning (bead tt3z.4). WEEK has NO Sigma Week() fn — it maps to
  # DatePart("week", …) exactly like formulas.ts (bead tt3z.2). Run before the
  # single→double-quote pass; "week" is already double-quoted here.
  s = s.gsub(/\bWEEK\s*\(/i, 'DatePart("week", ')
  s = s.gsub(/\bYEAR\s*\(/i, 'Year(').gsub(/\bMONTH\s*\(/i, 'Month(').gsub(/\bDAY\s*\(/i, 'Day(')
  s = s.gsub(/\bQUARTER\s*\(/i, 'Quarter(').gsub(/\bHOUR\s*\(/i, 'Hour(')
  s = s.gsub(/\bMINUTE\s*\(/i, 'Minute(').gsub(/\bSECOND\s*\(/i, 'Second(')
  # 1:1 STRING functions (identical name modulo case + identical signature in
  # both formula languages; every target spelling is in the canonical
  # sigma_functions.rb registry). v5.4: row-level string chains
  # (REPLACE(REPLACE([col], "a", ""), "b", "") derived dims) failed the
  # residue check and dropped to a manual warning without these.
  s = s.gsub(/\bREPLACE\s*\(/i, 'Replace(').gsub(/\bUPPER\s*\(/i, 'Upper(')
       .gsub(/\bLOWER\s*\(/i, 'Lower(').gsub(/\bLTRIM\s*\(/i, 'Ltrim(')
       .gsub(/\bRTRIM\s*\(/i, 'Rtrim(').gsub(/\bTRIM\s*\(/i, 'Trim(')
       .gsub(/\bLEFT\s*\(/i, 'Left(').gsub(/\bRIGHT\s*\(/i, 'Right(')
       .gsub(/\bLEN\s*\(/i, 'Len(').gsub(/\bCONTAINS\s*\(/i, 'Contains(')
       .gsub(/\bSTARTSWITH\s*\(/i, 'StartsWith(').gsub(/\bENDSWITH\s*\(/i, 'EndsWith(')
       .gsub(/\bMID\s*\(/i, 'Mid(')
  s = s.gsub(/'([^']*)'/) { %("#{Regexp.last_match(1)}") } # remaining single-quoted strings
  out = s.gsub(/\[([^\]]+)\]/) do
    cap = Regexp.last_match(1).strip
    next Regexp.last_match(0) if cap.start_with?('Master/') || cap.start_with?('ctl-')
    m = map_column(cap, mmap)
    "[Master/#{m ? m['name'] : cap}]"
  end
  residue = out.dup
  residue.gsub!(/"(?:\\.|[^"\\])*"/, '1')
  residue.gsub!(/\[Master\/[^\]]+\]/, '1')
  residue.gsub!(/\b(DateDiff|DateAdd|DateTrunc|DatePart|Today|Now|If|Coalesce|Abs|Text|Year|Month|Day|Quarter|Hour|Minute|Second|Replace|Upper|Lower|Ltrim|Rtrim|Trim|Left|Right|Len|Contains|StartsWith|EndsWith|Mid)\b/, '')
  return nil unless residue =~ %r{\A[\s()+\-*/.,\d!=<>]*\z}
  out
end

def translate_boolean_filter_calc(formula, mmap, columns_by_guid, parameters)
  source = strip_tableau_comments(formula).gsub(/\s+/, ' ').strip
  return nil if source.empty?
  parameter_names = {}
  Array(parameters).each do |parameter|
    name = parameter['name'].to_s.gsub(/^\[|\]$/, '').strip
    caption = parameter['caption'].to_s.strip
    parameter_names[name] = caption unless name.empty? || caption.empty?
  end
  source = source.gsub(/\[Parameters?\]\s*\.\s*\[([^\]]+)\]/i) do
    token = Regexp.last_match(1)
    param_control_ref(parameter_names[token] || token)
  end
  source = source.gsub(/\[([^\]]+)\]/) do
    token = Regexp.last_match(1).strip
    next Regexp.last_match(0) if token.start_with?('Master/', 'Metrics/', 'ctl-')
    translated_calc_reference(token, mmap, columns_by_guid) ||
      begin
        mapped = map_column(token, mmap)
        "[Master/#{mapped ? mapped['name'] : token}]"
      end
  end
  source = source.gsub(/\bIFNULL\s*\(/i, 'Coalesce(')
                 .gsub(/\bISNULL\s*\(/i, 'IsNull(')
                 .gsub(/\bDATE\s*\(/i, 'Date(')
                 .gsub(/\bUPPER\s*\(/i, 'Upper(')
                 .gsub(/'([^']*)'/) { %("#{Regexp.last_match(1)}") }
  residue = source.dup
  residue.gsub!(/"(?:\\.|[^"\\])*"/, '1')
  residue.gsub!(/\[[^\]]+\]/, '1')
  residue.gsub!(/\b(?:Date|Coalesce|IsNull|Upper|If|Abs)\b/, '')
  residue.gsub!(/\b(?:and|or|not|null|true|false)\b/i, '')
  return nil unless residue =~ %r{\A[\s()+\-*/.,\d!=<>]*\z}
  source
end

# Worksheet-local DIMENSION calc -> Sigma formula over master columns
# (bead z1d0: "Channel Group" CASE / "High Value Flag" IF-chain dims used to
# fall back to an unresolvable raw header). Handles:
#   CASE [col] WHEN "a" THEN "b" ... [ELSE e] END -> Switch([Master/col], ...)
#   IF c THEN r [ELSEIF c2 THEN r2]* [ELSE e] END -> nested If(...)
# Returns nil when the construct isn't recognized.
def translate_dim_calc(formula, mmap, columns_by_guid = {})
  s = strip_tableau_comments(formula).gsub(/\s+/, ' ').strip
  return nil if s.empty?
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end
  return nil if s =~ /\[[0-9a-f\-]{36}\]/i
  s = s.gsub(/'([^']*)'/) { %("#{Regexp.last_match(1)}") }
  master_ref = lambda do |str|
    str.gsub(/\[([^\]]+)\]/) do
      cap = Regexp.last_match(1).strip
      next Regexp.last_match(0) if cap.start_with?('Master/') || cap.start_with?('ctl-')
      m = map_column(cap, mmap)
      "[Master/#{m ? m['name'] : cap}]"
    end
  end
  if (m = s.match(/\ACASE\s+(\[[^\]]+\])\s+(WHEN\b.*?)\s*\bEND\z/i))
    subject = master_ref.call(m[1])
    body = m[2]
    pairs = body.scan(/WHEN\s+(.+?)\s+THEN\s+(.+?)(?=\s+WHEN\b|\s+ELSE\b|\z)/i)
    else_m = body.match(/\bELSE\b\s+(.+)\z/i)
    return nil if pairs.empty?
    parts = [subject]
    pairs.each { |a, b| parts << a.strip << b.strip }
    parts << else_m[1].strip if else_m
    return "Switch(#{parts.join(', ')})"
  end
  if (m = s.match(/\AIF\s+(.+)\s+END\z/i))
    body = m[1]
    segs = body.split(/\s+ELSEIF\s+/i)
    else_expr = nil
    if (em = segs.last.match(/(.*)\s+ELSE\s+(.+)\z/i))
      segs[-1] = em[1]
      else_expr = em[2].strip
    end
    conds = []
    segs.each do |seg|
      cm = seg.match(/\A(.+?)\s+THEN\s+(.+)\z/i)
      return nil unless cm
      conds << [cm[1].strip, cm[2].strip]
    end
    expr = else_expr || 'Null'
    conds.reverse_each { |c, r| expr = "If(#{c}, #{r}, #{expr})" }
    return master_ref.call(expr.gsub(/\bAND\b/, 'and').gsub(/\bOR\b/, 'or').gsub(/\bNOT\b/, 'not'))
  end
  nil
end

# ---- FIXED-LOD / grain-aware two-stage aggregation --------------------------
# Tableau `{FIXED [dims] : AGG([m])}` (and Avg-of-a-dim-table-measure, which
# Tableau evaluates at the dim table's native grain under relationship
# semantics) CANNOT be expressed as a single workbook formula: Sigma evaluates
# chart formulas at the source's base row grain, and window functions silently
# error in master/DM calc columns (feedback_sigma_window_functions). The
# verified translation (LODPROBE2, 2026-06-11) is a HIDDEN TWO-LEVEL GROUPED
# helper element on the Data page (the PR #65 / ry0n machinery):
#   level 2 (inner)  = the FIXED dims, computing the LOD aggregate
#   level 1 (outer)  = the dims the chart plots (or a constant for KPIs),
#                      computing the SECOND-stage aggregate over the inner
#                      group values (Sigma grouping calcs aggregate over child
#                      GROUP values, not base rows — verified)
# The chart sources the helper and references the outer calc via Max(): a
# chart re-aggregates a grouped source at BASE grain (group calcs replicated
# per row, window-style — verified), and Max over replicated identical values
# is exact.
# ⚠ Carried chart dims join the OUTER grouping — exact iff they are
# functionally dependent on (coarser than) the FIXED dims (e.g. Customer
# Segment per Customer Id). The emitted warning documents this assumption.
#
# DISPATCH (single vs nested FIXED — the two paths are disjoint by design):
#   - SINGLE-level {FIXED [dims] : AGG([m])}  → THIS path (parse_fixed_lod /
#     build_two_stage_helper): the regex below is anchored (\A..\z) to exactly
#     one non-nested FIXED, so it returns nil for anything nested. Parity-
#     proven on the fat workbook (40/40 strict incl. the dim-native-grain
#     subtlety).
#   - NESTED {FIXED ... {FIXED ...}}          → decompose_nested_fixed (build-charts-from-signals.rb)
#     (requires ≥2 `{FIXED` occurrences): emits a helper-element CHAIN plan
#     into the -lod-chains.json sidecar for the agent to build. Never reaches
#     this path, and single-level LODs never reach the chain path.
def parse_fixed_lod(formula, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  # The inner aggregate argument is captured greedily (.+) rather than as a bare
  # [col], so a CONDITIONAL / expression inner (e.g. the last-sold-date pattern
  # MAX(IF [Units] > 0 THEN [Date] END)) is ACCEPTED here instead of silently
  # dropping to a generic "translate manually" warning (bead: conditional-inner
  # FIXED LODs missed the auto-helper). The \z anchor forces the trailing ')}',
  # so the greedy body backtracks to the last ')'.
  m = s.match(/\A\{\s*FIXED\s+(\[[^\]]+\](?:\s*,\s*\[[^\]]+\])*)\s*:\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\((.+)\)\s*\}\z/i)
  return nil unless m
  inner = m[3].strip
  # NESTED {FIXED…{FIXED…}} stays DISJOINT from this path (see the dispatch note
  # above): it routes through decompose_nested_fixed (helper-element chain). The
  # loosened inner would otherwise match the outer of a nest — reject it here.
  return nil if inner =~ /\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b/i
  resolve = lambda do |ref|
    if ref =~ /\A[0-9a-f\-]{36}\z/i
      info = columns_by_guid[ref]
      info && info['caption'] && info['caption'].strip
    else
      ref.strip
    end
  end
  dims = m[1].scan(/\[([^\]]+)\]/).flatten.map { |d| resolve.call(d) }
  return nil if dims.empty? || dims.any?(&:nil?)
  out = { 'dims' => dims, 'agg' => m[2].upcase }
  if (bare = inner.match(/\A\[([^\]]+)\]\z/))
    # Bare-column inner — unchanged behaviour: expose 'measure' (+ display label).
    meas = resolve.call(bare[1])
    return nil if meas.nil?
    out['measure'] = meas
    out['label']   = meas
  else
    # Conditional / expression inner — the caller resolves it to a Sigma formula
    # via lod_inner_ref; 'label' is the raw inner for warning messages.
    out['inner_expr'] = inner
    out['label']      = inner
  end
  out
end

# Parse a RELATIVE LOD — {INCLUDE [dims]: AGG([m])} or {EXCLUDE [dims]: AGG([m])}
# — which (unlike FIXED) is evaluated relative to the chart's VIEW grain. Returns
# { 'type'=>'INCLUDE'|'EXCLUDE', 'dims'=>[...], 'agg'=>'SUM'|..., 'measure'=>name }.
# Supports multiple dims and the full agg set (the WOW case is a multi-dim
# EXCLUDE MAX). The caller composes grain from the chart's plotted dims.
def parse_relative_lod(formula, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  m = s.match(/\A\{\s*(INCLUDE|EXCLUDE)\s+(\[[^\]]+\](?:\s*,\s*\[[^\]]+\])*)\s*:\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[([^\]]+)\]\s*\)\s*\}\z/i)
  return nil unless m
  resolve = lambda do |ref|
    if ref =~ /\A[0-9a-f\-]{36}\z/i
      info = columns_by_guid[ref]
      info && info['caption'] && info['caption'].strip
    else
      ref.strip
    end
  end
  dims = m[2].scan(/\[([^\]]+)\]/).flatten.map { |d| resolve.call(d) }
  meas = resolve.call(m[4])
  return nil if dims.empty? || dims.any?(&:nil?) || meas.nil?
  { 'type' => m[1].upcase, 'dims' => dims, 'agg' => m[3].upcase, 'measure' => meas }
end

# Resolve a FIXED LOD's inner aggregate into the Sigma expression the helper's
# inner grouping aggregates over. A bare-column inner ('measure') maps to a
# single [Master/<col>] ref (unchanged). A conditional/expression inner
# ('inner_expr', e.g. IF [Units] > 0 THEN [Date] END) is translated to a Sigma
# formula over master columns via the shared dim/row-level calc translators
# (IF/CASE…END → nested If()/Switch(); arithmetic/date fns via row-level). The
# caller then wraps the result in the LOD aggregate (render_agg). Returns nil
# when the inner uses constructs we can't safely auto-emit — the caller falls
# back to a loud, specific warning (author a DM Custom SQL element) rather than
# building a broken helper.
def lod_inner_ref(lod, mmap, columns_by_guid = {})
  if lod['measure']
    m = map_column(lod['measure'], mmap)
    "[Master/#{m ? m['name'] : lod['measure']}]"
  elsif lod['inner_expr']
    translate_dim_calc(lod['inner_expr'], mmap, columns_by_guid) ||
      translate_row_level_calc(lod['inner_expr'], mmap, columns_by_guid)
  end
end

# Match a CSV header (e.g., "Gross Revenue", "Distinct count of Order Id") to
# a master-table column using regex map.
def map_column(header, mmap)
  # Strip leading/trailing whitespace from the header before matching. Tableau
  # column captions sometimes carry trailing whitespace (e.g., "Order Date ")
  # from the source .twb XML — `(?i)^order date$` won't match it without this.
  h = header.to_s.strip
  mmap.each do |pat, info|
    return info if Regexp.new(pat).match?(h)
  end
  nil
end

# Sigma formulas reference controls by `controlId` in brackets, NOT by display
# name. This helper computes the controlId the auto-controls block will emit
# for a given parameter caption so the translated Switch/If formulas match.
def param_control_ref(caption)
  "[ctl-param-#{caption.downcase.gsub(/\W+/, '-').sub(/-$/, '')}]"
end

# ---- Tableau table-calc translators ---------------------------------------
# Translate Tableau table-calculation functions to their Sigma equivalents.
# Returns the translated formula, plus a placement hint. Sigma window
# functions are FIRST-CLASS as chart-element viz formulas on the yAxis
# (WINPROBE-validated 2026-06-12); they error only in DM-element calc columns
# and grouping-table master calcs — see refs/window-functions.md.
#
# Function mappings (Sigma names):
#   INDEX()                  → RowNumber()
#   LOOKUP(expr, n)          → Lag(expr, n)  (positive n) / Lead(expr, -n) (neg)
#   LOOKUP(expr, 0)          → expr  (zero offset is identity)
#   RANK(expr [, 'desc'])    → Rank(expr [, "desc"])
#   RANK_DENSE(expr)         → RankDense(expr)
#   RANK_UNIQUE(expr)        → RowNumber() within ranked partition
#   RANK_PERCENTILE(expr)    → RankPercentile(expr)
#   TOTAL(SUM(x))            → Sum(x)  (Sigma metric on master without dim group)
#   SIZE()                   → Count(*) OVER ()  — no direct Sigma fn; warn
#   FIRST()                  → RowNumber() - 1   (Tableau FIRST returns 0-indexed)
#   LAST()                   → no direct equiv; needs Count-RowNumber pattern
#   ZN(x)                    → Coalesce(x, 0)
#   COUNTD(x)                → CountDistinct(x)
#   IIF(c, t, e)             → If(c, t, e)
#   IFNULL(x, y)             → Coalesce(x, y)
def translate_tableau_tc(formula)
  return [nil, nil] if formula.nil? || formula.empty?
  s = formula.dup
  hints = []
  changed = false

  # Order matters — apply table-calc translations BEFORE simple renames so the
  # match patterns (LOOKUP / TOTAL(COUNTD()) etc.) see the original Tableau
  # syntax.

  # INDEX() → RowNumber()
  if s.gsub!(/\bINDEX\s*\(\s*\)/, 'RowNumber()')
    hints << 'INDEX()→RowNumber()'; changed = true
  end

  # LOOKUP(expr, 0) — drop the wrapper. Use a balanced-paren match.
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*0\s*\)/
    s = s.sub($~[0], $1)
    hints << 'LOOKUP(x, 0)→x'; changed = true
  end
  # LOOKUP(expr, -n) → Lag(expr, n). Tableau's negative offset looks BACKWARD
  # (LOOKUP(x, -1) = previous row), which is Sigma Lag — the earlier mapping
  # had Lag/Lead reversed (caught by the WINPROBE WoW-delta live validation:
  # Coalesce(Sum(x) - Lag(Sum(x), 1), 0) matches the warehouse, Lead diverges).
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*-(\d+)\s*\)/
    s = s.sub($~[0], "Lag(#{$1}, #{$2})")
    hints << 'LOOKUP(x, -n)→Lag(x, n)'; changed = true
  end
  # LOOKUP(expr, n) where n >= 1 → Lead(expr, n) (forward offset = next rows)
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*(\d+)\s*\)/
    s = s.sub($~[0], "Lead(#{$1}, #{$2})")
    hints << 'LOOKUP(x, n)→Lead(x, n)'; changed = true
  end

  # RUNNING_* → Cumulative* (WINPROBE-validated 930/930: cumulative functions
  # follow the chart's xAxis sort and auto-partition by the chart color/series).
  { 'SUM' => 'CumulativeSum', 'AVG' => 'CumulativeAvg', 'MAX' => 'CumulativeMax',
    'MIN' => 'CumulativeMin', 'COUNT' => 'CumulativeCount' }.each do |tfn, sfn|
    if s.gsub!(/\bRUNNING_#{tfn}\s*\(/, "#{sfn}(")
      hints << "RUNNING_#{tfn}→#{sfn} (follows xAxis sort; valid as a chart viz formula on the yAxis)"
      changed = true
    end
  end
  # WINDOW_*(agg, -n, 0) → Moving*(agg, n); (-n, m) → Moving*(agg, n, m).
  # Tableau bounds are (first, last) offsets; Sigma Moving* takes (back[, fwd])
  # as POSITIVE counts. Forward-only / shifted windows (first > 0 or last < 0)
  # and FIRST()/LAST() bounds have no validated mapping — leave untouched.
  # NOTE: 'STDEV'/'VAR' here are the SAMPLE variants — Tableau WINDOW_STDEV /
  # WINDOW_VAR map to Sigma MovingStdDev / MovingVariance. The population forms
  # WINDOW_STDEVP / WINDOW_VARP stay manual (no `\bWINDOW_VAR\s*\(` match on
  # "WINDOW_VARP(" — the P breaks the word boundary, so they fall through).
  { 'AVG' => 'MovingAvg', 'SUM' => 'MovingSum', 'MAX' => 'MovingMax',
    'MIN' => 'MovingMin', 'COUNT' => 'MovingCount',
    'STDEV' => 'MovingStdDev', 'VAR' => 'MovingVariance' }.each do |tfn, sfn|
    while (m = s.match(/\bWINDOW_#{tfn}\s*\(\s*((?:[^(),]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\)/))
      lo, hi = m[2].to_i, m[3].to_i
      break if lo > 0 || hi < 0 # shifted window — unvalidated, keep Tableau form
      s = s.sub(m[0], hi.zero? ? "#{sfn}(#{m[1]}, #{-lo})" : "#{sfn}(#{m[1]}, #{-lo}, #{hi})")
      hints << "WINDOW_#{tfn}(x, -n, m)→#{sfn}(x, n[, m]) (valid as a chart viz formula on the yAxis)"
      changed = true
    end
  end

  # TOTAL(SUM(x)) → Sum(x); TOTAL(COUNTD(x)) → CountDistinct(x); TOTAL(AVG(x))
  if s.gsub!(/\bTOTAL\s*\(\s*SUM\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'Sum(\1)')
    hints << 'TOTAL(SUM(x))→Sum(x) (non-grouping context)'; changed = true
  end
  if s.gsub!(/\bTOTAL\s*\(\s*COUNTD\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'CountDistinct(\1)')
    hints << 'TOTAL(COUNTD(x))→CountDistinct(x) (non-grouping context)'; changed = true
  end
  if s.gsub!(/\bTOTAL\s*\(\s*AVG\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'Avg(\1)')
    hints << 'TOTAL(AVG(x))→Avg(x) (non-grouping context)'; changed = true
  end

  # RANK_UNIQUE(expr[, 'asc'|'desc']) → RowNumber(). Tableau RANK_UNIQUE assigns
  # a UNIQUE 1..N rank (no ties); Sigma RowNumber() does the same but FOLLOWS the
  # element's sort, so it is exact only when the element is sorted by the ranked
  # expression in the matching direction (mirrors the RUNNING_*/INDEX viz-formula
  # contract). Must precede the bare RANK( rewrite — though `\bRANK\(` can't match
  # `RANK_UNIQUE(` (the underscore), handle it explicitly so it stops falling
  # through to "untranslatable" (the enterprise top-N idiom: RANK_UNIQUE(SUM(x)) <= 25).
  if s.gsub!(/\bRANK_UNIQUE\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*(?:,\s*'(?:asc|desc)'\s*)?\)/, 'RowNumber()')
    hints << 'RANK_UNIQUE(expr)→RowNumber() — unique rank; VERIFY the element is sorted by the ranked expr (RowNumber follows the viz sort). For a top-N filter (RANK_UNIQUE(...)<=N) prefer a Sigma Top-N filter.'
    changed = true
  end

  # RANK([col], 'desc') / RANK([col]) / RANK_DENSE / RANK_PERCENTILE.
  # Tableau's RANK family defaults to DESCENDING; Sigma's defaults ascending —
  # the no-direction form must emit an explicit "desc" (WINPROBE-validated:
  # Rank(Sum(x), "desc") matches Tableau RANK(SUM(x)) exactly).
  if s.gsub!(/\bRANK\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*,\s*'(asc|desc)'\s*\)/, 'Rank(\1, "\2")')
    hints << "RANK→Rank"; changed = true
  end
  if s.gsub!(/\bRANK\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'Rank(\1, "desc")')
    hints << "RANK→Rank (Tableau default direction = desc)"
    changed = true
  end
  if s.gsub!(/\bRANK_DENSE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*,\s*'(asc|desc)'\s*\)/, 'RankDense(\1, "\2")')
    hints << "RANK_DENSE→RankDense"; changed = true
  end
  if s.gsub!(/\bRANK_DENSE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'RankDense(\1, "desc")')
    hints << "RANK_DENSE→RankDense (Tableau default direction = desc)"; changed = true
  end
  if s.gsub!(/\bRANK_PERCENTILE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*,\s*'(asc|desc)'\s*\)/, 'RankPercentile(\1, "\2")')
    hints << "RANK_PERCENTILE→RankPercentile"; changed = true
  end
  if s.gsub!(/\bRANK_PERCENTILE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'RankPercentile(\1, "desc")')
    hints << "RANK_PERCENTILE→RankPercentile (Tableau default direction = desc)"; changed = true
  end

  # Simple renames done AFTER table-calc rewrites so the table-calc patterns
  # match the original Tableau spelling.
  if s.gsub!(/\bZN\s*\(/, 'Coalesce(')
    # ZN takes one arg; pair the matching close-paren and append `, 0`. Walk
    # the string and balance parens to find the right `)`.
    out = String.new
    i = 0
    while i < s.length
      if s[i, 9] == 'Coalesce(' && (i == 0 || s[i - 1] !~ /\w/)
        out << 'Coalesce('
        depth = 1
        j = i + 9
        while j < s.length && depth > 0
          depth += 1 if s[j] == '('
          depth -= 1 if s[j] == ')'
          break if depth == 0
          j += 1
        end
        out << s[i + 9...j] << ', 0)'
        i = j + 1
      else
        out << s[i]
        i += 1
      end
    end
    s = out
    changed = true
  end
  if s.gsub!(/\bIIF\s*\(/, 'If(')
    changed = true
  end
  if s.gsub!(/\bIFNULL\s*\(/, 'Coalesce(')
    changed = true
  end
  if s.gsub!(/\bABS\s*\(/, 'Abs(')
    changed = true
  end
  if s.gsub!(/\bCOUNTD\s*\(/, 'CountDistinct(')
    changed = true
  end

  # SIZE() — no direct Sigma equivalent for partition size at the formula level.
  # Leave as-is and warn so the agent rewrites manually (commonly Count(*)+OVER).
  if s.include?('SIZE()')
    hints << 'SIZE() has no direct Sigma equivalent — rewrite as Count(*) in a non-grouping context or Custom SQL'
  end

  # FIRST() / LAST() — special.
  if s.include?('FIRST()')
    hints << 'FIRST() → RowNumber() - 1 (Tableau FIRST is 0-indexed first row)'
  end
  if s.include?('LAST()')
    hints << 'LAST() → no direct Sigma equivalent — use a Count() - RowNumber() pattern or Custom SQL'
  end

  # DATEPART('iso-year', x) — Sigma DatePart has NO iso-year / iso-week
  # precision (its "weekday" is 1-7 Sunday-start). Verified equivalent
  # (live-checked vs Snowflake YEAROFWEEKISO, 2026-06-11): the ISO year of x is
  # the calendar Year() of the THURSDAY of x's ISO week:
  #   Year(DateAdd("day", 3 - Mod(DatePart("weekday", x) + 5, 7), x))
  # (DatePart("weekday")+5 mod 7 maps Mon→0..Sun→6; 3-that shifts to Thursday.)
  while (m = s.match(/\bDATEPART\s*\(\s*['"]iso-year['"]\s*,\s*((?:[^()]|\([^()]*\))+?)\s*\)/i))
    arg = m[1]
    s = s.sub(m[0], %(Year(DateAdd("day", 3 - Mod(DatePart("weekday", #{arg}) + 5, 7), #{arg}))))
    hints << %(DATEPART('iso-year')→Year(DateAdd("day", 3 - Mod(DatePart("weekday", x) + 5, 7), x)) — Thursday-of-ISO-week; Sigma DatePart has no iso-year precision)
    changed = true
  end
  if s =~ /\bDATEPART\s*\(\s*['"]iso-week(?:number)?['"]/i
    hints << "DATEPART('iso-week') has no verified Sigma formula equivalent — use a Custom SQL DM element (Snowflake WEEKISO(x)) or derive from the iso-year Thursday shift"
  end

  # FINDNTH(s, sub, n) → 1-based index of the nth occurrence of sub in s
  # (0 when there are fewer than n occurrences). Verified Sigma composition
  # (live-checked vs warehouse SQL, 2026-06-11) via the array functions:
  #   If(ArrayLength(SplitToArray(s, sub)) > n,
  #      Len(ArrayJoin(ArraySlice(SplitToArray(s, sub), 0, n), sub)) + 1, 0)
  # i.e. rejoin the first n split-segments and measure the prefix length.
  # NB: Sigma ArraySlice's start index is 0-BASED — ArraySlice(arr, 0, n) is
  # the first n elements; start=1 silently skips the first segment (every
  # result lands past the (n+1)th occurrence; caught live vs SPLIT_PART SQL).
  while (m = s.match(/\bFINDNTH\s*\(\s*([^,()]*(?:\([^()]*\))?[^,()]*)\s*,\s*([^,()]+?)\s*,\s*([^,()]+?)\s*\)/i))
    str_a, sub_a, n_a = m[1].strip, m[2].strip, m[3].strip
    s = s.sub(m[0],
              "If(ArrayLength(SplitToArray(#{str_a}, #{sub_a})) > #{n_a}, " \
              "Len(ArrayJoin(ArraySlice(SplitToArray(#{str_a}, #{sub_a}), 0, #{n_a}), #{sub_a})) + 1, 0)")
    hints << 'FINDNTH→SplitToArray/ArraySlice/ArrayJoin composition (result 1-based; ArraySlice start 0-based; 0 when fewer than n occurrences)'
    changed = true
  end

  # LOD calcs — Tableau's `{FIXED [dim] : AGG([m])}` family.
  # Translation strategy (Sigma):
  #   {FIXED [dims] : AGG([m])}   → AUTO-BUILT when plotted as a chart/KPI
  #                                 measure: hidden two-level grouped helper
  #                                 element (inner = FIXED dims computing the
  #                                 LOD aggregate, outer = chart dims computing
  #                                 the 2nd-stage aggregate) — see
  #                                 parse_fixed_lod/build_two_stage_helper.
  #   {FIXED : SUM([m])}          → unscoped `Sum([m])` (workbook-level scalar)
  #   nested {FIXED…{FIXED…}}     → handled UPSTREAM by decompose_nested_fixed
  #                                 (helper-element chain + -lod-chains.json
  #                                 sidecar); the calc loop `next`s before this
  #                                 translator runs, so no double hint.
  #   {INCLUDE [dim] : SUM([m])}  → add [dim] to chart grouping and just use Sum
  #   {EXCLUDE [dim] : SUM([m])}  → remove [dim] from chart grouping, use Sum
  # INCLUDE/EXCLUDE need the chart's grouping context — surfaced as manual
  # hints, not auto-emitted.
  if s =~ /\{\s*FIXED\s+\[([^\]]+)\]\s*:\s*(SUM|AVG|MIN|MAX|COUNT|COUNTD)\s*\(\[([^\]]+)\]\)\s*\}/i
    dim, agg, m = $1, $2.upcase, $3
    hints << "FIXED LOD → auto-built as a hidden grouped helper element when plotted (inner grain = [#{dim}], " \
             "#{agg}(#{m}); 2nd-stage agg at chart grain) ⚠ carried chart dims must be functionally dependent on the FIXED dims"
    changed = true
  end
  if s =~ /\{\s*FIXED\s*:\s*(SUM|AVG|MIN|MAX|COUNT|COUNTD)\s*\(\[([^\]]+)\]\)\s*\}/i
    agg, m = $1.upcase, $2
    sigma_agg = { 'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
                  'COUNT' => 'Count', 'COUNTD' => 'CountDistinct' }[agg]
    hints << "FIXED-no-dim LOD → workbook scalar metric #{sigma_agg}([Master/#{m}]) (no group by)"
    changed = true
  end
  if (mi = s.match(/\{\s*INCLUDE\s+((?:\[[^\]]+\]\s*,?\s*)+):\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\[([^\]]+)\]\)\s*\}/i))
    dims, agg = mi[1].scan(/\[([^\]]+)\]/).flatten.join(', '), mi[2].upcase
    hints << "INCLUDE LOD on [#{dims}] → AUTO-BUILT as a hidden grouped helper when plotted as a chart measure " \
             "(inner = INCLUDE dims below the view, 2nd-stage agg at view grain); elsewhere add [#{dims}] to the grouping"
    changed = true
  end
  if (me = s.match(/\{\s*EXCLUDE\s+((?:\[[^\]]+\]\s*,?\s*)+):\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\[([^\]]+)\]\)\s*\}/i))
    dims, agg = me[1].scan(/\[([^\]]+)\]/).flatten.join(', '), me[2].upcase
    composable = %w[SUM MAX MIN COUNT].include?(agg)
    hints << if composable
               "EXCLUDE LOD on [#{dims}] (#{agg}) → AUTO-BUILT as a hidden grouped helper when plotted (value at " \
               'view minus the excluded dims, broadcast); composable agg, exact'
             else
               "EXCLUDE LOD on [#{dims}] uses #{agg} (not composable as agg-of-agg) → STAYS MANUAL: re-author at the coarser grain"
             end
    changed = true
  end

  return [nil, nil] unless changed
  hints.uniq!
  # Family rule (corrected 2026-07-15, probe-window-contexts.rb): Sigma-native
  # window functions (Rank/RankDense/RankPercentile/Lag/Lead/RowNumber/
  # Cumulative*/Moving*/PercentOfTotal) resolve to real OVER() as chart-element
  # viz formulas on the yAxis AND in table calc columns (grouped + ungrouped)
  # AND in DM-element calc columns — no Custom SQL needed. Only the *Over family
  # (SumOver/MaxOver/...) is 'Unknown function' in every spec context.
  hints << 'NOTE: emit as a CHART-element viz formula on the yAxis (the default, WINPROBE-verified); table / DM-element calc columns are also valid. Never the *Over functions — see refs/window-functions.md' if hints.any? { |h| h =~ /Rank|Lag|Lead|RowNumber|Cumulative|Moving/ }
  [s, hints.join('; ')]
end

# ---- Tableau window table-calcs → Sigma-native chart formulas --------------
# WINPROBE-validated design (bead 427, 2026-06-12; 930/930 cells exact vs the
# warehouse on ONE DM base element, ZERO Custom SQL):
#
#   RUNNING_SUM/AVG/MAX/MIN/COUNT(agg)        → Cumulative*(agg)
#   WINDOW_AVG/SUM/MAX/MIN/COUNT(agg, -n, 0)  → Moving*(agg, n)
#   WINDOW_*(agg, -n, m)                      → Moving*(agg, n, m)
#   WINDOW_STDEV(agg, -n[, m])                → MovingStdDev(agg, n[, m])
#   agg / WINDOW_SUM(agg)   (unbounded share) → PercentOfTotal(agg, "grand_total")
#   RUNNING_SUM(agg) / TOTAL(agg)   (pareto)  → CumulativeSum(PercentOfTotal(agg, "grand_total"))
#   RANK / RANK_DENSE / RANK_PERCENTILE(agg)  → Rank/RankDense/RankPercentile(agg, "desc")
#   INDEX()                                   → RowNumber()
#   LOOKUP(agg, -n) / LOOKUP(agg, n)          → Lag(agg, n) / Lead(agg, n)
#   unbounded WINDOW_MAX/MIN/SUM, TOTAL(agg)  → TWO-LEVEL grouped helper element
#     (outer grouping = partition dims, inner = addressing dims; the chart
#     consumer re-aggregates Max/Min — NEVER Sum: group calcs broadcast to
#     base-grain rows, so a Sum would multiply by the row count)
#
# Family rule (corrected 2026-07-15): these Sigma-native window functions are
# first-class as chart-element viz formulas on the yAxis (the emitted default)
# AND resolve in table calc columns (grouped + ungrouped) and DM-element calc
# columns — location is not the gate. Cumulative*/rank functions follow the
# chart's xAxis sort and auto-partition by the chart's color/series dim. Only
# the *Over family (SumOver/MaxOver/...) is 'Unknown function' in every spec
# context — never emit those. Re-verify contexts with probe-window-contexts.rb.
#
# STAYS MANUAL (flagged, never guessed): WINDOW_MEDIAN / WINDOW_PERCENTILE /
# WINDOW_CORR / WINDOW_COVAR(P) / WINDOW_VARP (population) / WINDOW_STDEVP,
# PREVIOUS_VALUE, SIZE(), FIRST()/LAST(), RANK_MODIFIED, and any
# compute-using/addressing override beyond the default Table(Across) / simple
# partition ("restart every", pane-relative, compute-along-non-axis-dim).
# NOW MAPPED (2026-06-18): RANK_UNIQUE→RowNumber (sort-following, like INDEX),
# WINDOW_VAR (sample)→MovingVariance — Sigma shipped MovingVariance; the
# population variant WINDOW_VARP has no validated Sigma window fn, stays manual.
WINDOW_SIGMA_FNS = %w[
  CumulativeSum CumulativeAvg CumulativeMax CumulativeMin CumulativeCount
  MovingAvg MovingSum MovingMax MovingMin MovingCount MovingStdDev MovingVariance
  Rank RankDense RankPercentile RowNumber Lag Lead PercentOfTotal
].freeze

WINDOW_MANUAL_RE = /\b(?:WINDOW_(?:MEDIAN|PERCENTILE|CORR|COVARP?|VARP|STDEVP)|PREVIOUS_VALUE|RANK_MODIFIED)\s*\(|\b(?:SIZE|FIRST|LAST)\s*\(\s*\)/i

# Case-SENSITIVE on purpose: .twb formulas carry canonical UPPERCASE Tableau
# function names, and the post-rewrite leftover check must not match the
# translated Sigma names (Rank/Lookup-the-join-fn/...).
WINDOW_TC_RE = /\b(?:RUNNING_[A-Z]+|WINDOW_[A-Z]+|RANK(?:_[A-Z]+)?|INDEX|LOOKUP|TOTAL|PREVIOUS_VALUE)\s*\(|\bSIZE\s*\(\s*\)/

# Classify + translate a Tableau window table-calc into its Sigma-native form.
# Returns nil when the formula has no window construct (caller proceeds on the
# normal paths), otherwise a hash:
#   { 'mode' => 'inline',    'formula' => <Sigma formula over [Master/...]>,
#                            'follows_sort' => bool, 'note' => ... }
#   { 'mode' => 'two-stage', 'stage_agg' => 'Max|Min|Sum', 'retrieve_agg' =>
#                            'Max|Min', 'value_formula' => <inner agg>, 'note' => ... }
#   { 'mode' => 'manual',    'note' => why }

def translate_window_calc(formula, mmap, columns_by_guid = {}, depth: 0)
  s = formula.to_s.gsub(/\s+/, ' ').strip
  # v5.1: a LEADING unary minus on a window-share pill or a bare calc ref is a
  # Tableau DESC-sort trick (`-WINDOW_MAX(share)`, `-[CalcRef]`). Strip it and
  # carry the flag — the minus must NEVER reach a column name/formula (the
  # round-4 `Sum([Master/-WINDOW_MAX(…)])` class died here). SCOPED to those
  # two shapes only: a minus on any other window calc (-RUNNING_SUM(…)) is a
  # genuine negation and keeps its sign through the generic path
  # (review-caught: the blanket strip silently changed those values).
  negated = false
  if s.start_with?('-') && s[1..-1].to_s.strip =~ /\A(?:WINDOW_(?:MAX|MIN|AVG)\s*\(|\[[^\]]+\]\z)/i
    negated = true
    s = s[1..-1].to_s.strip
  end
  # v5.1: one-level calc-ref dereference — a bare `[CalcRef]` whose formula is
  # known resolves to that formula and re-enters. Allowed at depth 0 AND 1
  # (Rule T1 hands the RANK operand in at depth 1 — review-caught: gating on
  # depth.zero? made the T1 ref path dead); depth 2 stops the recursion.
  if depth < 2 && (ref = s[/\A\[([^\]]+)\]\z/, 1])
    info = columns_by_guid[ref] || columns_by_guid.values.find { |v| v.is_a?(Hash) && v['caption'].to_s == ref }
    if info.is_a?(Hash) && info['formula'].to_s =~ WINDOW_TC_RE
      plan = translate_window_calc(info['formula'], mmap, columns_by_guid, depth: depth + 1)
      return plan && plan.merge('negated_for_sort' => (negated || plan['negated_for_sort'] || false))
    end
  end
  # v5.4: EMBEDDED calc-ref inlining (one hop). Tableau authors routinely split
  # a share across two serialized <calculation>s — [Total X] = TOTAL(SUM([X]))
  # and [% X] = SUM([X]) / [Total X] — so the window construct never appears in
  # the referring formula's own text and every classifier below is blind to it
  # (the calc translated as an unresolvable plain ref, or worse, a co-shelf
  # positional calc was picked instead). Substitute each embedded ref whose
  # KNOWN formula carries a window construct: verbatim when that formula is a
  # single closed call (TOTAL(...) — keeps the share regexes matchable), else
  # parenthesized for precedence safety. Gated to formulas that do NOT already
  # match WINDOW_TC_RE, so it strictly ADDS translations (previous nil returns)
  # and never re-routes a formula the classifiers already handled.
  if depth < 2 && s !~ WINDOW_TC_RE
    single_call = lambda do |f|
      return false unless f =~ /\A[A-Za-z_][A-Za-z0-9_]*\s*\(/ && f.end_with?(')')
      d = 0
      f.each_char.with_index do |ch, i|
        d += 1 if ch == '('
        if ch == ')'
          d -= 1
          return false if d.negative?
          return false if d.zero? && i < f.length - 1
        end
      end
      d.zero?
    end
    inlined = false
    s2 = s.gsub(/\[([^\]]+)\]/) do
      ref = Regexp.last_match(1)
      whole = Regexp.last_match(0)
      info = columns_by_guid[ref] ||
             columns_by_guid.values.find { |v| v.is_a?(Hash) && v['caption'].to_s.strip == ref }
      f = info.is_a?(Hash) ? info['formula'].to_s.gsub(/\s+/, ' ').strip : ''
      if !f.empty? && f =~ WINDOW_TC_RE
        inlined = true
        single_call.call(f) ? f : "(#{f})"
      else
        whole
      end
    end
    s = s2 if inlined
  end
  return nil if s.empty? || s !~ WINDOW_TC_RE
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end

  if (mm = s.match(WINDOW_MANUAL_RE))
    return { 'mode' => 'manual',
             'note' => "uses #{mm[0].sub(/\s*\(\s*\)?\z/, '')}() — no validated Sigma chart-formula mapping (stays manual; port via Custom SQL or re-author in Sigma)" }
  end

  agg_src = '(?:SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[[^\]]+\]\s*\)'
  norm = ->(x) { x.to_s.gsub(/\s+/, '').downcase }
  tx_agg = ->(a) { translate_user_agg_formula(a, mmap, {}) }

  # v5.1 Rule W1 — window-wrapped share (the round-4 exit-4 class):
  # WINDOW_MAX|MIN|AVG( agg/TOTAL(agg) | agg/WINDOW_SUM(agg) | agg1/agg2 ).
  # The wrapper flattens to the partition max in Tableau but all three round-4
  # runs (and their anchors) treat it as the per-cell share for DISPLAY —
  # value-identical when the window is a single cell (nested addressing) or
  # shares are uniform. The emit layer picks the PercentOfTotal scope from the
  # pivot axes; the VDS oracle re-checks every emission (window-calcs.json).
  if (w1 = s.match(%r{\A\s*WINDOW_(MAX|MIN|AVG)\s*\(\s*(#{agg_src})\s*/\s*(?:(?:WINDOW_SUM|TOTAL)\s*\(\s*(#{agg_src})\s*\)|(#{agg_src}))\s*\)\s*\z}i))
    num = w1[2]
    if w1[3] && norm.call(num) == norm.call(w1[3]) # same-agg → percent of total
      inner = tx_agg.call(num)
      return { 'mode' => 'manual', 'note' => 'window-wrapped share whose inner aggregate did not translate' } unless inner
      return { 'mode' => 'inline-share', 'share_kind' => 'percent_of_total',
               'inner' => inner, 'wrapper' => "WINDOW_#{w1[1].upcase}",
               'negated_for_sort' => negated,
               'note' => "WINDOW_#{w1[1].upcase}(share) treated as the per-cell share for display; " \
                         'exact when the window is a single cell — VDS oracle verifies' }
    elsif w1[4] # different-agg ratio
      a = tx_agg.call(num)
      b = tx_agg.call(w1[4])
      return { 'mode' => 'manual', 'note' => 'window-wrapped ratio whose aggregates did not translate' } unless a && b
      return { 'mode' => 'inline-share', 'share_kind' => 'ratio',
               'inner' => "#{a} / #{b}", 'wrapper' => "WINDOW_#{w1[1].upcase}",
               'negated_for_sort' => negated,
               'note' => "WINDOW_#{w1[1].upcase}(ratio) treated as the per-cell ratio for display — VDS oracle verifies" }
    end
  end

  # Top-N idiom: RANK(<expr>)<=N or RANK_UNIQUE(<expr>)<=N (bead pnxp).
  # The generic rewrite below collapses RANK_UNIQUE(<expr>) → RowNumber() and
  # DROPS <expr> entirely, which is only correct when the element is sorted by
  # <expr> — and is value-WRONG when <expr> is an untranslatable LOD ({exclude…}
  # /{include…}/{fixed…}). Intercept the top-N filter shape here so the operand
  # is never silently discarded:
  #   (a) <expr> reduces cleanly to a Sigma aggregate → RowNumber()<=N AND record
  #       the ranked measure so the caller can sort the tile by it (RowNumber
  #       follows the viz sort).
  #   (b) <expr> does NOT reduce (LOD operand) → STAY MANUAL: never emit a
  #       sort-dependent RowNumber()<=N with the operand gone.
  if (tn = s.match(/\A\s*RANK(?:_UNIQUE)?\s*\(\s*(.+?)\s*(?:,\s*'(?:asc|desc)'\s*)?\)\s*(<=|>=|<|>)\s*(\d+)\s*\z/i))
    operand, op, n = tn[1], tn[2], tn[3]
    # RANK_UNIQUE assigns 1..N with NO ties (like ROW_NUMBER); RANK ties on equal
    # values. A Sigma top-n filter mirrors this via rankingFunction. Only the
    # `<=N` / `<N` shapes are a FIXED-COUNT top-N (keep the N highest-ranked);
    # `>=N` / `>N` keep "everything ranked N or worse" — NOT a fixed bottom-N
    # count, so they only get the inline/manual note (no top-n filter).
    ranking  = (tn[0] =~ /_UNIQUE/i) ? 'row-number' : 'rank'
    row_count = (op == '<=') ? n.to_i : (op == '<' ? n.to_i - 1 : nil)  # nil ⇒ not a top-n filter
    ranked = translate_user_agg_formula(operand, mmap, {})
    base = { 'top_op' => op, 'ranking' => ranking, 'operand_raw' => operand.to_s.gsub(/\s+/, ' ') }
    base['top_n'] = row_count if row_count
    if ranked
      # Clean aggregate operand: caller emits a real Sigma Top-N FILTER keyed on
      # this measure when top_n is set. Keep the legacy inline RowNumber() form +
      # ranked_measure for the measure-on-yAxis path, which now auto-sorts the
      # tile by the ranked measure (bead pnxp).
      filt = row_count ? "Sigma top-#{row_count} filter ranked by #{ranked[0..70]}" : "RowNumber() #{op} #{n} on a tile sorted by #{ranked[0..70]}"
      return base.merge('mode' => 'inline', 'formula' => "RowNumber() #{op} #{n}",
               'follows_sort' => true, 'ranked_measure' => ranked,
               'note' => "RANK#{tn[0] =~ /_UNIQUE/i ? '_UNIQUE' : ''}(expr) #{op} #{n} top-N → #{filt}")
    end
    # v5.1 Rule T1: a RANK operand that is (a ref to) a WINDOW-WRAPPED SHARE
    # classifies as topn-prefilter — the rank-limited pre-filtered source
    # table all three round-4 runs hand-built, now mechanical.
    if row_count && depth.zero?
      share_plan = translate_window_calc(operand, mmap, columns_by_guid, depth: 1)
      if share_plan && share_plan['mode'] == 'inline-share'
        return base.merge('mode' => 'topn-prefilter', 'top_n' => row_count,
                 'operand_share' => share_plan,
                 'note' => "RANK(<window share>) #{op} #{n}: keep the top #{row_count} entities by their " \
                           'max per-partition share — emit the rank-limited pre-filtered source table ' \
                           '(refs/fidelity-recipes.md §Ranked pivot)')
      end
    end
    # Untranslatable LOD operand: cannot key a filter on a measure we couldn't
    # build. STAY MANUAL, but carry the parsed top-N facts so the caller can
    # surface a precise, actionable instruction (build the LOD helper measure,
    # then a top-n filter ranked by it) — never a sort-dependent RowNumber().
    return base.merge('mode' => 'manual',
             'note' => "top-N over an untranslatable LOD operand (#{operand.to_s.gsub(/\s+/, ' ')[0..80]}) — build the LOD helper as a Sigma measure, then a Sigma #{row_count ? "top-#{row_count}" : 'top-N'} filter ranked by it; never a sort-dependent RowNumber() #{op} #{n} with the operand dropped")
  end

  # Unbounded share-of-total: AGG / WINDOW_SUM(AGG) or AGG / TOTAL(AGG) on the
  # SAME aggregate. Both denominators are the grand total of the partition; the
  # `TOTAL(SUM(x))` form is how Tableau authors most often write share-of-total.
  if (m = s.match(%r{\A\s*(#{agg_src})\s*/\s*(?:WINDOW_SUM|TOTAL)\s*\(\s*(#{agg_src})\s*\)\s*\z}i)) &&
     norm.call(m[1]) == norm.call(m[2])
    inner = tx_agg.call(m[1])
    return { 'mode' => 'manual', 'note' => 'share-of-total whose inner aggregate did not translate' } unless inner
    return { 'mode' => 'inline', 'follows_sort' => false,
             'formula' => %(PercentOfTotal(#{inner}, "grand_total")),
             'note' => 'agg/WINDOW_SUM(agg) or agg/TOTAL(agg) → PercentOfTotal(agg, "grand_total")' }
  end

  # Pareto: RUNNING_SUM(AGG) / TOTAL(AGG) on the SAME aggregate.
  if (m = s.match(%r{\A\s*RUNNING_SUM\s*\(\s*(#{agg_src})\s*\)\s*/\s*TOTAL\s*\(\s*(#{agg_src})\s*\)\s*\z}i)) &&
     norm.call(m[1]) == norm.call(m[2])
    inner = tx_agg.call(m[1])
    return { 'mode' => 'manual', 'note' => 'pareto whose inner aggregate did not translate' } unless inner
    return { 'mode' => 'inline', 'follows_sort' => true,
             'formula' => %(CumulativeSum(PercentOfTotal(#{inner}, "grand_total"))),
             'note' => 'RUNNING_SUM(agg)/TOTAL(agg) pareto → CumulativeSum(PercentOfTotal(agg, "grand_total")) — accumulation follows the xAxis sort' }
  end

  # Standalone unbounded WINDOW_MAX/MIN/SUM or TOTAL → two-level grouped helper.
  if (m = s.match(/\A\s*(?:WINDOW_(MAX|MIN|SUM)|(TOTAL))\s*\(\s*(#{agg_src})\s*\)\s*\z/i))
    inner = tx_agg.call(m[3])
    return { 'mode' => 'manual', 'note' => 'unbounded window aggregate whose inner aggregate did not translate' } unless inner
    stage = (m[1] || 'SUM').upcase
    return { 'mode' => 'two-stage',
             'stage_agg' => { 'MAX' => 'Max', 'MIN' => 'Min', 'SUM' => 'Sum' }[stage],
             'retrieve_agg' => stage == 'MIN' ? 'Min' : 'Max',
             'value_formula' => inner,
             'note' => "unbounded #{m[2] ? 'TOTAL' : "WINDOW_#{stage}"} → two-level grouped helper; consumer re-aggregates #{stage == 'MIN' ? 'Min' : 'Max'} (NEVER Sum — group calcs broadcast to base-grain rows)" }
  end

  # Generic inline path: rewrite the window tokens (translate_tableau_tc now
  # carries the full validated mapping), then translate the inner aggregates.
  rewritten, _hint = translate_tableau_tc(s)
  rewritten ||= s
  if (left = rewritten.match(WINDOW_TC_RE))
    return { 'mode' => 'manual',
             'note' => "window construct #{left[0].sub(/\s*\(\s*\)?\z/, '')}() has no validated mapping in this shape (stays manual)" }
  end
  final = translate_user_agg_formula(rewritten, mmap, {}, extra_fns: WINDOW_SIGMA_FNS)
  return { 'mode' => 'manual', 'note' => 'window formula did not reduce to translated aggregates + arithmetic glue' } unless final
  return nil unless WINDOW_SIGMA_FNS.any? { |f| final =~ /\b#{f}\s*\(/ }
  { 'mode' => 'inline', 'formula' => final,
    'follows_sort' => !!(final =~ /\b(?:Cumulative\w+|Moving\w+|RowNumber|Lag|Lead)\s*\(/),
    'note' => 'window table-calc → Sigma viz formula on the chart yAxis' }
end
