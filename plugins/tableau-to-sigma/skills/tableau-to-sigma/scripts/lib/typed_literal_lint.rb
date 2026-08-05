# frozen_string_literal: true
#
# typed_literal_lint.rb — typed-literal calc lint (v5.5 handoff item W2.2).
#
# FIELD FAILURE (2026-07-13 run, never diagnosed in-flight): converter-generated
# Sigma formulas compared a NUMBER column to a STRING literal —
#   If([Year] = "2014", [Unit Value])
# where the landed warehouse column YEAR is NUMBER. The formula COMPILES CLEAN
# and renders NULL for every measure (blanked 6 of 9 charts). Same class: a
# date-part filter emitted as a string list (values: ["2015"]) against a
# TIMESTAMP column. Tableau's YEAR()/DATEPART() produce integers; a converter
# that renders that comparison as a quoted string is the bug class.
#
# ANTI-OVERFIT RULE — the caller-supplied COLUMN TYPE MAP is the sole
# authority; NEVER the column name. A TEXT column literally named "Year"
# compared to "2014" is legitimate and must never be flagged. A ref that
# cannot be resolved through the map (or resolves ambiguously — same
# normalized name, conflicting types across tables) is SKIPPED silently: no
# guessing. False negatives are acceptable; false positives are NOT (corpus
# risk — this lint runs across every migrated workbook).
#
# The lint REPORTS and suggests a provably type-safe rewrite; it does NOT
# rewrite (auto-coercion is a later, separately-gated step).
#
# Pure, IO-free core. Ruby 2.6 floor (macOS system Ruby) — no filter_map,
# no pattern matching, no endless methods.
#
# API:
#   findings = TypedLiteralLint.lint(spec, types)
#
#   spec  — dm-spec / workbook-spec-shaped Hash. Walked surface:
#           pages[].elements[].columns[].formula, .metrics[].formula, and
#           elements[].filters[] entries carrying a literal `values` array
#           (top-level spec['elements'] is accepted as a page-less fallback).
#   types — { 'ELEMENT_OR_TABLE' => { 'COLUMN_NAME' => 'number'|'text'|
#           'datetime'|... } } supplied by the caller from the landing
#           manifest, a warehouse DESCRIBE, or live /columns. Keys are matched
#           by NORMALIZED name (upcase, strip non-alphanumerics) so the
#           caption 'Revenue (current US$)' resolves against REVENUE_CURRENT_US, and
#           a dotted table path DB.SCHEMA.T also matches by its last segment.
#
#   Each finding (string keys, JSON-ready):
#     { 'formula_owner'    => element/column id owning the formula or filter,
#       'formula_fragment' => the offending comparison site,
#       'column'           => resolved 'TABLE.COLUMN' from the type map,
#       'column_type'      => the raw type string from the map,
#       'literal'          => the quoted literal's content,
#       'suggestion'       => the type-safe rewrite }
#
# DETECTION (deliberately conservative — a tokenizer, not a parser; when in
# doubt it skips):
#   - [Ref] <op> "literal" (either operand order), op ∈ = == != <> < > <= >=
#   - In([Ref], ...literals...) / IsIn([Ref], ...) — only when the first
#     argument is a single bracketed ref
#   - element filters[] with a literal `values` array, resolved via columnId
#     to a bare-ref formula or a formula-less column's name
#   Flags: NUMERIC column vs quoted numeric string ("2014" → drop the quotes);
#   TEMPORAL column vs quoted BARE YEAR 1000–2999 ("2015" →
#   DatePart("year", [Date]) = 2015). Everything else — date strings vs
#   temporal, function-wrapped comparisons (DatePart(...) = "2015"), TEXT or
#   unknown-typed columns, unresolvable refs — is skipped by design.
require 'strscan'

module TypedLiteralLint
  COMPARE_OPS = %w[<= >= != <> == = < >].freeze
  IN_FUNCTIONS = %w[in isin].freeze
  # displayed operator in suggestions (== and <> are converter-isms, not Sigma)
  OP_CANON = { '==' => '=', '<>' => '!=' }.freeze
  FRAGMENT_CAP = 160

  module_function

  # ---------------------------------------------------------------- type map

  # 'NUMBER(38,0)' / 'VARCHAR(16)' → category symbol; nil = unknown (skip).
  def type_category(raw)
    t = raw.to_s.downcase.sub(/\(.*\z/, '').strip
    case t
    when 'number', 'int', 'integer', 'bigint', 'smallint', 'tinyint',
         'byteint', 'float', 'float4', 'float8', 'double', 'double precision',
         'decimal', 'numeric', 'real', 'fixed'
      :numeric
    when 'date', 'datetime', 'timestamp', 'timestamp_ntz', 'timestamp_ltz',
         'timestamp_tz', 'timestamptz', 'time'
      :temporal
    when 'text', 'string', 'varchar', 'char', 'character', 'character varying'
      :text
    end
  end

  # 'Revenue (current US$)' → 'REVENUECURRENTUS'; 'REVENUE_CURRENT_US' → 'REVENUECURRENTUS'.
  def norm_name(s)
    s.to_s.upcase.gsub(/[^A-Z0-9]/, '')
  end

  # Two-level lookup index:
  #   { tables: { NORMTABLE => { NORMCOL => entry|:conflict } },
  #     global: { NORMCOL => entry|:conflict } }
  # entry = { cat:, raw:, table:, column: }. A dotted table path indexes under
  # both its full path and its last segment. Same normalized column name with
  # DIFFERENT type categories → :conflict → resolution skips (no guessing).
  def build_index(types)
    tables = {}
    global = {}
    (types || {}).each do |tbl, cols|
      next unless cols.is_a?(Hash)
      tkeys = [tbl.to_s]
      last = tbl.to_s.split('.').last
      tkeys << last if last && last != tbl.to_s
      cols.each do |col, raw|
        nc = norm_name(col)
        next if nc.empty?
        entry = { cat: type_category(raw), raw: raw.to_s,
                  table: tbl.to_s, column: col.to_s }
        tkeys.each do |tk|
          nt = norm_name(tk)
          next if nt.empty?
          bucket = (tables[nt] ||= {})
          bucket[nc] = merge_entry(bucket[nc], entry)
        end
        global[nc] = merge_entry(global[nc], entry)
      end
    end
    { tables: tables, global: global }
  end

  def merge_entry(existing, entry)
    return entry if existing.nil?
    return existing if existing == :conflict
    existing[:cat] == entry[:cat] ? existing : :conflict
  end

  # -------------------------------------------------------------- resolution

  # Owner keys a ref on this element may resolve against: the element's own
  # id/name, its source table (full dotted path + last segment), and the same
  # for upstream elements reached through source.elementId chains (depth 5).
  def owner_keys(el, elements_by_id)
    keys = []
    seen = {}
    cur = el
    5.times do
      break unless cur.is_a?(Hash)
      id = cur['id'] || cur['elementId']
      break if id && seen[id]
      seen[id] = true if id
      keys << id if id
      keys << cur['name'] if cur['name']
      nxt = nil
      src = cur['source']
      if src.is_a?(Hash)
        inner = src['kind'] == 'source' && src['source'].is_a?(Hash) ? src['source'] : src
        t = inner['table'] || inner['name']
        if t.is_a?(String)
          keys << t
          keys << t.split('.').last
        end
        nxt = elements_by_id[inner['elementId']] if inner['elementId']
      elsif src.is_a?(String)
        keys << src
        keys << src.split('.').last
      end
      cur = nxt
    end
    keys.compact.uniq
  end

  # Resolve a ref's CONTENT (text between the brackets) to a type-map entry.
  # Order: qualified 'Table/Column' split → owner-scoped → global-unique.
  # Returns the entry Hash, or nil (unresolvable / ambiguous / unknown type).
  def resolve(ref_content, owner_ks, index)
    candidates = []
    col_names = [ref_content]
    if ref_content.include?('/')
      pre, _sep, post = ref_content.rpartition('/')
      candidates << [norm_name(pre), norm_name(post)]
      col_names << post
    end
    owner_ks.each do |k|
      col_names.each { |c| candidates << [norm_name(k), norm_name(c)] }
    end
    candidates.each do |nt, nc|
      next if nt.empty? || nc.empty?
      e = index[:tables][nt] && index[:tables][nt][nc]
      next if e.nil?
      return nil if e == :conflict # ambiguous inside a scoped table — skip
      return checked(e)
    end
    col_names.each do |c|
      g = index[:global][norm_name(c)]
      next if g.nil?
      return nil if g == :conflict # same name, conflicting types — skip
      return checked(g)
    end
    nil
  end

  def checked(entry)
    entry[:cat].nil? ? nil : entry # unknown/unclassifiable raw type — skip
  end

  # ---------------------------------------------------------------- literals

  def numeric_string?(s)
    !!(s =~ /\A[+-]?\d+(\.\d+)?\z/)
  end

  def bare_year?(s)
    !!(s =~ /\A[12]\d{3}\z/) # 1000–2999, exactly 4 digits, no sign
  end

  # "2014" / '2014' → 2014 content, backslash escapes unwound.
  def unquote(tok)
    tok[1..-2].to_s.gsub(/\\(.)/, '\1')
  end

  def coerce_num(lit)
    lit.include?('.') ? lit.to_f : lit.to_i
  end

  # --------------------------------------------------------------- tokenizer
  #
  # Bracketed refs and quoted strings (escapes honored) are consumed as single
  # tokens FIRST, so nothing inside them can look like a comparison site —
  # same discipline as formula_normalize.rb. Anything unrecognized falls
  # through as :other and can never participate in a match.
  def tokenize(formula)
    s = StringScanner.new(formula)
    toks = []
    until s.eos?
      if s.scan(/\s+/)
        next
      elsif (t = s.scan(/\[[^\]]*\]/))
        toks << [:ref, t]
      elsif (t = s.scan(/"(?:\\.|[^"\\])*"/))
        toks << [:str, t]
      elsif (t = s.scan(/'(?:\\.|[^'\\])*'/))
        toks << [:str, t]
      elsif (t = s.scan(/<=|>=|!=|<>|==|=|<|>/))
        toks << [:op, t]
      elsif (t = s.scan(/[A-Za-z_][A-Za-z0-9_]*/))
        toks << [:ident, t]
      elsif (t = s.scan(/\d+(?:\.\d+)?/))
        toks << [:num, t]
      elsif (t = s.scan(/\(/))
        toks << [:lparen, t]
      elsif (t = s.scan(/\)/))
        toks << [:rparen, t]
      elsif (t = s.scan(/,/))
        toks << [:comma, t]
      else
        toks << [:other, s.getch]
      end
    end
    toks
  end

  def join_tokens(toks)
    out = +''
    toks.each_with_index do |(k, t), i|
      if out.empty?
        out << t
      elsif k == :comma || k == :rparen ||
            (toks[i - 1] && toks[i - 1][0] == :lparen) ||
            (k == :lparen && toks[i - 1] && toks[i - 1][0] == :ident)
        out << t
      else
        out << ' ' << t
      end
    end
    out
  end

  def cap(s)
    s.length > FRAGMENT_CAP ? "#{s[0, FRAGMENT_CAP - 1]}…" : s
  end

  # ----------------------------------------------------------- formula scan

  # Scans one formula string; appends findings. owner = 'elId/colId' label.
  def scan_formula(formula, owner, owner_ks, index, findings)
    return unless formula.is_a?(String) && !formula.empty?
    toks = tokenize(formula)
    scan_binary_comparisons(toks, owner, owner_ks, index, findings)
    scan_in_lists(toks, owner, owner_ks, index, findings)
  end

  def scan_binary_comparisons(toks, owner, owner_ks, index, findings)
    toks.each_with_index do |(kind, op), i|
      next unless kind == :op && COMPARE_OPS.include?(op)
      next if i.zero? || toks[i + 1].nil?
      lk, lt = toks[i - 1]
      rk, rt = toks[i + 1]
      if lk == :ref && rk == :str
        emit_comparison(lt, op, rt, false, owner, owner_ks, index, findings)
      elsif lk == :str && rk == :ref
        emit_comparison(rt, op, lt, true, owner, owner_ks, index, findings)
      end
    end
  end

  # ref_tok = '[Year]', str_tok = '"2014"'; reversed = literal on the left.
  # Operand order is PRESERVED in the suggestion (mirroring < / > would flip
  # semantics), so no operator surgery beyond ==/<> canonicalization.
  def emit_comparison(ref_tok, op, str_tok, reversed, owner, owner_ks, index, findings)
    entry = resolve(ref_tok[1..-2].to_s, owner_ks, index)
    return unless entry
    lit = unquote(str_tok)
    opc = OP_CANON.fetch(op, op)
    case entry[:cat]
    when :numeric
      return unless numeric_string?(lit)
      suggestion = reversed ? "#{lit} #{opc} #{ref_tok}" : "#{ref_tok} #{opc} #{lit}"
    when :temporal
      return unless bare_year?(lit)
      dp = "DatePart(\"year\", #{ref_tok})"
      suggestion = reversed ? "#{lit.to_i} #{opc} #{dp}" : "#{dp} #{opc} #{lit.to_i}"
    else
      return # :text (or anything else) never triggers — the type map rules
    end
    fragment = reversed ? "#{str_tok} #{op} #{ref_tok}" : "#{ref_tok} #{op} #{str_tok}"
    findings << finding(owner, cap(fragment), entry, lit, suggestion)
  end

  # In([Ref], "2014", ...) / IsIn([Ref], ...). Only fires when the first
  # argument is a single bracketed ref followed by a comma and the call's
  # closing paren is found; string literals are collected at the call's own
  # paren depth only (nested calls' strings are ignored).
  def scan_in_lists(toks, owner, owner_ks, index, findings)
    i = 0
    while i < toks.length
      kind, text = toks[i]
      unless kind == :ident && IN_FUNCTIONS.include?(text.downcase) &&
             toks[i + 1] && toks[i + 1][0] == :lparen &&
             toks[i + 2] && toks[i + 2][0] == :ref &&
             toks[i + 3] && toks[i + 3][0] == :comma
        i += 1
        next
      end
      ref_tok = toks[i + 2][1]
      call_toks = toks[i, 3]
      list_strs = []
      depth = 1
      closed = false
      j = i + 3
      while j < toks.length
        kj, tj = toks[j]
        call_toks << toks[j]
        if kj == :lparen
          depth += 1
        elsif kj == :rparen
          depth -= 1
          if depth.zero?
            closed = true
            break
          end
        elsif kj == :str && depth == 1
          list_strs << tj
        end
        j += 1
      end
      if closed && !list_strs.empty?
        emit_in_list(text, ref_tok, list_strs, call_toks, owner, owner_ks, index, findings)
      end
      i = closed ? j + 1 : i + 1
    end
  end

  def emit_in_list(fn, ref_tok, list_strs, call_toks, owner, owner_ks, index, findings)
    entry = resolve(ref_tok[1..-2].to_s, owner_ks, index)
    return unless entry
    fragment = cap(join_tokens(call_toks))
    list_strs.each do |str_tok|
      lit = unquote(str_tok)
      case entry[:cat]
      when :numeric
        next unless numeric_string?(lit)
        suggestion = "#{fn}(#{ref_tok}, #{lit}, …)"
      when :temporal
        next unless bare_year?(lit)
        suggestion = "#{fn}(DatePart(\"year\", #{ref_tok}), #{lit.to_i}, …)"
      else
        next
      end
      findings << finding(owner, fragment, entry, lit, suggestion)
    end
  end

  # ------------------------------------------------------------ filter scan

  # Element filters[] carrying a literal `values` array (the builder's list
  # filters: {id, columnId, kind:'list', mode, values:[...]}). The filter's
  # columnId resolves within its target element (source.elementId when
  # present, else the owning element); the column's type comes from its
  # bare-ref formula, or its NAME when it has no formula (a base dm column).
  # A column with a computed (non-bare-ref) formula is skipped — its output
  # type is not knowable from the map.
  def scan_element_filters(el, elements_by_id, index, findings)
    filters = el['filters']
    return unless filters.is_a?(Array)
    el_id = el['id'] || el['elementId'] || el['name'] || '(unnamed element)'
    filters.each_with_index do |flt, fi|
      next unless flt.is_a?(Hash)
      vals = flt['values']
      next unless vals.is_a?(Array) && !vals.empty?

      target = el
      if flt['source'].is_a?(Hash) && flt['source']['elementId']
        target = elements_by_id[flt['source']['elementId']]
        next unless target # cross-element target missing — skip, no guessing
      end
      col = find_column(target, flt['columnId'])
      next unless col

      f = col['formula'].to_s
      if f =~ /\A\s*(\[[^\]]+\])\s*\z/
        ref_tok = Regexp.last_match(1)
      elsif f.strip.empty? && col['name']
        ref_tok = "[#{col['name']}]"
      else
        next # computed column — output type unknown, skip
      end
      owner_ks = owner_keys(target, elements_by_id)
      entry = resolve(ref_tok[1..-2].to_s, owner_ks, index)
      next unless entry

      owner = "#{el_id}/filters[#{flt['id'] || fi}]"
      str_vals = vals.select { |v| v.is_a?(String) }
      case entry[:cat]
      when :numeric
        hits = str_vals.select { |v| numeric_string?(v) }
        next if hits.empty?
        coerced = vals.map { |v| v.is_a?(String) && numeric_string?(v) ? coerce_num(v) : v }
        hits.each do |lit|
          findings << finding(owner, cap("filter values: #{vals.inspect} on #{ref_tok}"),
                              entry, lit, "values: #{coerced.inspect}")
        end
      when :temporal
        hits = str_vals.select { |v| bare_year?(v) }
        next if hits.empty?
        hits.each do |lit|
          findings << finding(owner, cap("filter values: #{vals.inspect} on #{ref_tok}"),
                              entry, lit,
                              "DatePart(\"year\", #{ref_tok}) = #{lit.to_i}")
        end
      end
    end
  end

  def find_column(el, column_id)
    return nil if el.nil? || column_id.nil?
    (Array(el['columns']) + Array(el['metrics'])).find do |c|
      c.is_a?(Hash) && c['id'] == column_id
    end
  end

  def finding(owner, fragment, entry, literal, suggestion)
    { 'formula_owner' => owner,
      'formula_fragment' => fragment,
      'column' => "#{entry[:table]}.#{entry[:column]}",
      'column_type' => entry[:raw],
      'literal' => literal,
      'suggestion' => suggestion }
  end

  # ----------------------------------------------------------------- driver

  def all_elements(spec)
    els = []
    (spec['pages'] || []).each { |pg| els.concat(pg['elements'] || []) if pg.is_a?(Hash) }
    els.concat(spec['elements']) if spec['elements'].is_a?(Array) # page-less dm-spec
    els.select { |e| e.is_a?(Hash) }
  end

  def lint(spec, types)
    findings = []
    return findings unless spec.is_a?(Hash)
    index = build_index(types)
    els = all_elements(spec)
    by_id = {}
    els.each do |el|
      id = el['id'] || el['elementId']
      by_id[id] = el if id
    end
    els.each do |el|
      el_id = el['id'] || el['elementId'] || el['name'] || '(unnamed element)'
      owner_ks = owner_keys(el, by_id)
      (Array(el['columns'])).each_with_index do |c, ci|
        next unless c.is_a?(Hash)
        scan_formula(c['formula'], "#{el_id}/#{c['id'] || c['name'] || "columns[#{ci}]"}",
                     owner_ks, index, findings)
      end
      (Array(el['metrics'])).each_with_index do |m, mi|
        next unless m.is_a?(Hash)
        scan_formula(m['formula'], "#{el_id}/metrics[#{m['id'] || m['name'] || mi}]",
                     owner_ks, index, findings)
      end
      scan_element_filters(el, by_id, index, findings)
    end
    findings
  end
end
