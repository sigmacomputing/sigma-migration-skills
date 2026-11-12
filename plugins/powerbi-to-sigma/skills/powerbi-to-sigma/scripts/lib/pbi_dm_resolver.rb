# frozen_string_literal: true

# Deterministic fixer for the CONVERTER OUTPUT, run by migrate-powerbi.rb after
# the NativeQuery restore + model-scope view filter and before the
# calculated-table gate / validate-spec.
#
# WHY. On a large model the data model
# only POSTed after ~25 shape gaps had been found one 400 at a time. All of them were
# mechanical, so they are fixed here once, deterministically, and every rewrite
# and every formula that had to be dropped is written to <WORK>/dm-resolver.json
# (nothing is changed silently):
#
#   D1  stale converter element prefixes left by the NativeQuery restore
#       ([PHYSICAL_TABLE View/..]) are remapped to the restored element names
#   D2  refs are rewritten to the EXACT target column name by a case / space /
#       punctuation-insensitive match (Sigma is case-insensitive but NOT
#       punctuation-insensitive, and validate-spec is case-sensitive).
#       Relationship-path aware ([Fact/Rel/Col] resolves Col on Rel's target),
#       columns-only for [El/Col], SQL output names for [Custom SQL/X]
#   D3  leaked DAX: `--` comment lines, DIVIDE, LASTDATE, MEDIAN, VALUE,
#       CONVERT, `x IN {..}`, AND()/OR() function forms (case-sensitive so the
#       `and (` operators survive), `<> null` / `= null`. Functions with no
#       Sigma equivalent (CALCULATE, SUMX, ...) and results that end up
#       unbalanced are nulled and recorded
#   D4  refs that resolve nowhere -> formula Null, to a fixpoint, recorded with
#       the unresolved refs
#   D5  duplicate element ids (the converter truncates derived-element names
#       into ids) are suffixed
#   D7  DateTrunc / DateLookback over integer YYYYMMDD keys -> MakeDate(...)
#   D8  unnamed columns that end up Null are REMOVED (they surface as a column
#       literally named "Null", and a builder reference to it 400s)
#
# Ambiguity is never guessed: a fuzzy match with several candidates is left
# unchanged and listed under `ambiguous`; a path the resolver cannot verify is
# left to the server and listed under `unverified`.
#
# String literals and bracket references are lexed, so DAX-looking text inside
# a "string" or a [Name (with, punctuation)] is never touched.
#
# Ruby 2.6 floor: no filter_map / tally / except / endless defs.
require 'json'
require 'set'

module PbiDmResolver
  SCHEMA = 'dm-resolver/1'
  CUSTOM_SQL = 'Custom SQL'
  METRICS = 'Metrics'

  class Untranslatable < StandardError; end

  # DAX functions that have no Sigma equivalent: the formula is nulled, never
  # approximated. Upper-case only: the converter emits Sigma functions in
  # CamelCase, so an upper-case call is leaked source text.
  UNTRANSLATABLE_FN = /\b(COUNTX|FILTER|LOOKUPVALUE|SUMX|CALCULATE|ALL|ALLEXCEPT|SELECTEDVALUE|EARLIER|RANKX|USERELATIONSHIP|TREATAS)\s*\(/.freeze
  UNTRANSLATABLE_KW = /\bVAR\s+[A-Za-z_]\w*\s*=|\bRETURN\b/.freeze

  # Column names that look like an integer YYYYMMDD key (DateID, Date_Key,
  # SHIP_DATE_ID, yyyymmdd). CamelCase-aware so "Candidate ID" does not match.
  DATE_KEY_NAME = /(?:\A|[^A-Za-z]|(?<=[a-z]))(?:Date|DATE)[\s_]*(?:ID|Id|Key|KEY)\b|(?:\A|[^A-Za-z])date[\s_]*(?:id|key)\b|yyyymmdd/i.freeze
  DATE_KEY_NAME_CS = /(?:\A|[^A-Za-z]|(?<=[a-z]))(?:Date|DATE)[\s_]*(?:ID|Id|Key|KEY)\b|(?:\A|[^A-Za-z])date[\s_]*(?:id|key)\b|yyyymmdd/.freeze

  INTEGER_TYPES = %w[int64 integer int whole number].freeze

  module_function

  # ---- public API ---------------------------------------------------------

  # Mutates `dm` (the bare converter model: {pages: [{elements: [...]}]}) and
  # returns the audit log (plain JSON-able Hash).
  #
  #   sql_names:        { "Element name" => ["SQL output name", ...] } probed from
  #                     the warehouse; authoritative for [Custom SQL/X] refs
  #   overrides:        { "Element|Name" => "<sigma formula>" }
  #   null_list:        ["Element|Name", ...] formulas to null outright
  #   date_key_columns: Set of normalized column names that ARE integer date
  #                     keys; nil = decide by name (DATE_KEY_NAME)
  def resolve!(dm, sql_names: {}, overrides: {}, null_list: [], date_key_columns: nil)
    Run.new(dm, sql_names || {}, overrides || {}, Array(null_list), date_key_columns).run
  end

  # Normalized names of integer-typed, key-shaped columns in a TMSL model, or
  # nil when the TMSL carries no dataType at all (caller falls back to names).
  def date_key_columns_from_tmsl(model)
    model = model['model'] || model
    saw_type = false
    keys = Set.new
    (model['tables'] || []).each do |t|
      (t['columns'] || []).each do |c|
        dt = c['dataType'].to_s.downcase
        saw_type = true unless dt.empty?
        keys << nk(c['name']) if INTEGER_TYPES.include?(dt) && c['name'].to_s =~ DATE_KEY_NAME_CS
      end
    end
    saw_type ? keys : nil
  end

  def summary_line(log)
    s = log['summary']
    parts = []
    parts << "#{s['rewrites']} ref rewrite(s)"
    parts << "#{s['dax_translated']} DAX translation(s)"
    parts << "#{s['date_key_rewrites']} date-key fix(es)"
    parts << "#{s['nulled']} formula(s) nulled (#{s['unresolved_nulled']} unresolved)"
    parts << "#{s['columns_removed']} column(s) removed"
    parts << "#{s['duplicate_ids']} duplicate id(s)"
    parts << "#{s['blockers']} blocker(s)" if s['blockers'].to_i.positive?
    parts << "#{s['ambiguous']} ambiguous" if s['ambiguous'].positive?
    parts << "#{s['unverified']} unverified" if s['unverified'].positive?
    "dm-resolver: #{parts.join(', ')}"
  end

  # Every line the orchestrator should print for the audit log: ALL nulled
  # formulas (never a truncated list) and every blocker.
  def report_lines(log)
    lines = []
    (log['nulled'] || []).each do |n|
      lines << "nulled #{n['element']} / #{n['name']} (#{n['reason']}): #{n['detail']}"
    end
    (log['blockers'] || []).each do |b|
      lines << "BLOCKER #{b['reason']}: #{b['detail']}"
    end
    lines
  end

  # Normalized key: case, whitespace, underscore and hyphen insensitive. Semantic
  # symbols (% # $ & + ...) are KEPT, so `Margin` never matches `Margin %`. U+2215
  # (division slash) is equivalent to '/'.
  def nk(str)
    s = str.to_s
    k = s.downcase.tr("\u2215", '/').gsub(/[[:space:]_\-]/, '')
    k.empty? ? s.downcase : k
  end

  # ---- lexer --------------------------------------------------------------

  # Split a formula into [[:code|:str|:ref, text], ...]. Strings are "..." with
  # "" or \" escapes; refs are [bracketed] and may contain any punctuation.
  def lex(formula)
    toks = []
    buf = +''
    i = 0
    n = formula.length
    while i < n
      ch = formula[i]
      if ch == '"'
        toks << [:code, buf] unless buf.empty?
        buf = +''
        j = i + 1
        while j < n
          c = formula[j]
          if c == '\\' && j + 1 < n
            j += 2
          elsif c == '"'
            break unless formula[j + 1] == '"'

            j += 2
          else
            j += 1
          end
        end
        toks << [:str, formula[i..j].to_s]
        i = j + 1
      elsif ch == '['
        close = formula.index(']', i + 1)
        if close.nil?
          buf << formula[i..-1]
          i = n
        else
          toks << [:code, buf] unless buf.empty?
          buf = +''
          toks << [:ref, formula[i..close]]
          i = close + 1
        end
      else
        buf << ch
        i += 1
      end
    end
    toks << [:code, buf] unless buf.empty?
    toks
  end

  # Replace strings and refs with placeholders so regex / paren scanning only
  # ever sees code. Returns [masked, table].
  def mask(formula)
    table = []
    masked = lex(formula).map do |type, text|
      case type
      when :str
        table << text
        "\u0001#{table.length - 1}\u0001"
      when :ref
        table << text
        "\u0002#{table.length - 1}\u0002"
      else
        text
      end
    end.join
    [masked, table]
  end

  def unmask(text, table)
    text.gsub(/[\u0001\u0002](\d+)[\u0001\u0002]/) { table[Regexp.last_match(1).to_i] }
  end

  # [args, index_of_closing_paren] for a call whose '(' ends at `from`, or nil.
  def parse_args(text, from)
    depth = 1
    brace = 0
    args = []
    start = from
    i = from
    while i < text.length
      case text[i]
      when '(' then depth += 1
      when ')'
        depth -= 1
        if depth.zero?
          args << text[start...i]
          return [args, i]
        end
      when '{' then brace += 1
      when '}' then brace -= 1
      when ','
        if depth == 1 && brace.zero?
          args << text[start...i]
          start = i + 1
        end
      end
      i += 1
    end
    nil
  end

  # Rewrite every call to `fn` in masked text. The block gets the stripped,
  # already-recursed args and returns the replacement text, or nil to keep the
  # call (with its recursed args) as written.
  def rewrite_call(text, fn, ci, &blk)
    re = Regexp.new("\\b#{fn}\\s*\\(", ci ? Regexp::IGNORECASE : 0)
    out = +''
    pos = 0
    while (m = re.match(text, pos))
      parsed = parse_args(text, m.end(0))
      break if parsed.nil?

      raw, close = parsed
      raw = raw.map { |a| rewrite_call(a, fn, ci, &blk) }
      rep = blk.call(raw.map(&:strip))
      out << text[pos...m.begin(0)]
      out << (rep.nil? ? "#{text[m.begin(0)...m.end(0)]}#{raw.join(',')})" : rep)
      pos = close + 1
    end
    out << text[pos..-1].to_s
  end

  def balanced?(masked)
    depth = 0
    masked.each_char do |ch|
      if ch == '('
        depth += 1
      elsif ch == ')'
        depth -= 1
        return false if depth.negative?
      end
    end
    depth.zero?
  end

  # ---- D3: leaked DAX -----------------------------------------------------

  def strip_comments(masked)
    changed = false
    kept = []
    masked.split("\n", -1).each do |line|
      if line.lstrip.start_with?('--')
        changed = true
        next
      end
      idx = line.index(/\s--/)
      if idx
        line = line[0...idx].rstrip
        changed = true
      end
      kept << line
    end
    [kept.join("\n"), changed]
  end

  # -> [new_formula, rules, problem]; problem is nil or [reason, detail].
  def translate_dax(formula)
    masked, table = mask(formula)
    rules = []
    masked, changed = strip_comments(masked)
    rules << 'comment' if changed
    if (m = masked.match(UNTRANSLATABLE_FN))
      return [formula, [], ['untranslatable-dax', "DAX function #{m[1]} has no Sigma equivalent"]]
    end
    return [formula, [], ['untranslatable-dax', 'DAX VAR/RETURN has no Sigma equivalent']] if masked =~ UNTRANSLATABLE_KW

    step = lambda do |name, &blk|
      before = masked
      masked = blk.call(masked)
      rules << name if masked != before
    end
    begin
      step.call('DIVIDE') do |t|
        rewrite_call(t, 'DIVIDE', true) do |g|
          raise Untranslatable, "DIVIDE with #{g.length} argument(s)" unless [2, 3].include?(g.length)

          alt = g[2].nil? || g[2].casecmp('null').zero? ? 'Null' : g[2]
          "If(IsNull(#{g[1]}) or (#{g[1]}) = 0, #{alt}, (#{g[0]}) / (#{g[1]}))"
        end
      end
      step.call('LASTDATE') do |t|
        rewrite_call(t, 'LASTDATE', true) do |g|
          raise Untranslatable, "LASTDATE with #{g.length} argument(s)" unless g.length == 1

          "Max(#{g[0]})"
        end
      end
      step.call('CONVERT') do |t|
        rewrite_call(t, 'CONVERT', true) do |g|
          raise Untranslatable, "CONVERT with #{g.length} argument(s)" unless g.length == 2

          case g[1].upcase
          when 'STRING' then "Text(#{g[0]})"
          when 'DOUBLE', 'CURRENCY' then "Number(#{g[0]})"
          when 'INTEGER' then "Round(#{g[0]}, 0)"
          else raise Untranslatable, "CONVERT to #{g[1]} has no exact Sigma equivalent"
          end
        end
      end
      step.call('MEDIAN') { |t| t.gsub(/\bMEDIAN\s*\(/, 'Median(') }
      step.call('IN') { |t| rewrite_in(t) }
      step.call('AND') do |t|
        rewrite_call(t, 'AND', false) do |g|
          raise Untranslatable, 'AND() with fewer than 2 arguments' if g.length < 2

          '(' + g.map { |x| "(#{x})" }.join(' and ') + ')'
        end
      end
      step.call('OR') do |t|
        rewrite_call(t, 'OR', false) do |g|
          raise Untranslatable, 'OR() with fewer than 2 arguments' if g.length < 2

          '(' + g.map { |x| "(#{x})" }.join(' or ') + ')'
        end
      end
      step.call('<> null') { |t| t.gsub(/(\u0002\d+\u0002)\s*<>\s*null\b(?!\s*\()/i) { "IsNotNull(#{Regexp.last_match(1)})" } }
      step.call('= null') { |t| t.gsub(/(\u0002\d+\u0002)\s*=\s*null\b(?!\s*\()/i) { "IsNull(#{Regexp.last_match(1)})" } }
      step.call('VALUE') { |t| t.gsub(/\bVALUE\s*\(/, 'Number(') }
    rescue Untranslatable => e
      return [formula, [], ['untranslatable-dax', e.message]]
    end
    return [formula, [], ['unbalanced', 'parentheses do not balance (leaked DAX, or a comment swallowed code)']] unless balanced?(masked)

    [rules.empty? ? formula : unmask(masked, table), rules, nil]
  end

  # What may precede the left operand of IN without changing what it binds to:
  # start, an opening paren, a comma, and/or/not/&&/||.
  IN_OPERAND_PREFIX = /(?:\A|[(,]|&&|\|\||\b(?:and|or|not))\s*\z/i.freeze

  # `x IN {a, b}` -> `In(x, a, b)` where x is a bare ref/literal or a complete
  # function call / parenthesised group. A compound left operand (arithmetic or
  # comparison binds differently) raises Untranslatable.
  def rewrite_in(text)
    re = /\s*\bIN\s*\{([^{}]*)\}/
    pos = 0
    while (m = re.match(text, pos))
      left = text[0...m.begin(0)]
      start = in_operand_start(left)
      raise Untranslatable, 'IN with a compound left operand' if start.nil? || left[0...start] !~ IN_OPERAND_PREFIX

      rep = "In(#{left[start..-1]}, #{m[1].strip})"
      text = left[0...start] + rep + text[m.end(0)..-1].to_s
      pos = start + rep.length
    end
    text
  end

  # Index where the operand ending `left` starts, or nil when it is not a single
  # atom / complete call.
  def in_operand_start(left)
    if (m = left.match(/[\u0001\u0002]\d+[\u0001\u0002]\z/))
      return m.begin(0)
    end
    return nil unless left.end_with?(')')

    depth = 0
    i = left.length - 1
    while i >= 0
      if left[i] == ')'
        depth += 1
      elsif left[i] == '('
        depth -= 1
        break if depth.zero?
      end
      i -= 1
    end
    return nil if i.negative?

    ident = left[0...i].match(/[A-Za-z_][A-Za-z0-9_.]*\z/)
    ident ? ident.begin(0) : i
  end

  # ---- D7: integer YYYYMMDD keys -----------------------------------------

  def key_column?(inner, date_keys)
    col = inner.start_with?("#{CUSTOM_SQL}/") ? inner[(CUSTOM_SQL.length + 1)..-1] : inner.split('/').last.to_s
    return date_keys.include?(nk(col)) if date_keys

    col =~ DATE_KEY_NAME ? true : false
  end

  def ymd(ref)
    "MakeDate(Floor(#{ref} / 10000), Floor(Mod(#{ref}, 10000) / 100), Mod(#{ref}, 100))"
  end

  # -> [new_formula, changed]
  def rewrite_date_keys(formula, date_keys)
    return [formula, false] unless formula =~ /DateTrunc|DateLookback/i

    masked, table = mask(formula)
    changed = false
    key_arg = lambda do |arg|
      m = arg.match(/\A\u0002(\d+)\u0002\z/)
      m && key_column?(table[m[1].to_i][1...-1], date_keys)
    end
    masked = rewrite_call(masked, 'DateTrunc', true) do |g|
      next nil unless g.length == 2 && key_arg.call(g[1])

      changed = true
      "DateTrunc(#{g[0]}, #{ymd(g[1])})"
    end
    masked = rewrite_call(masked, 'DateLookback', true) do |g|
      next nil unless g.length >= 2 && key_arg.call(g[1])

      changed = true
      g[1] = ymd(g[1])
      "DateLookback(#{g.join(', ')})"
    end
    changed ? [unmask(masked, table), true] : [formula, false]
  end

  # ---- the run ------------------------------------------------------------

  class Run
    def initialize(dm, sql_names, overrides, null_list, date_keys)
      @dm = dm
      @sql_names = sql_names
      @overrides = overrides
      @null_list = Set.new(null_list)
      @date_keys = date_keys
      @log = {
        'schema' => SCHEMA, 'summary' => {}, 'prefix_remaps' => {}, 'prefix_unresolved' => {},
        'rewrites' => [], 'dax' => [], 'date_keys' => [], 'nulled' => [], 'removed_columns' => [],
        'duplicate_ids' => [], 'ambiguous' => [], 'unverified' => [], 'overrides' => [], 'blockers' => []
      }
      @seen = Set.new
    end

    def els
      (@dm['pages'] || []).flat_map { |p| p['elements'] || [] }
    end

    def run
      dedupe_ids!
      reindex!
      reprefix_warehouse_tables!
      build_prefix_map!
      each_formula { |e, kind, c| pass_a(e, kind, c) }
      fixpoint!
      finish
    end

    private

    def label(c)
      c['name'] || "(#{c['id']})"
    end

    def each_formula
      els.each do |e|
        %w[columns metrics].each do |kind|
          (e[kind] || []).each { |c| yield e, kind, c if c['formula'].is_a?(String) }
        end
      end
    end

    def trim(text)
      text.to_s[0, 1000]
    end

    # ---- D5 ----
    def dedupe_ids!
      seen = Set.new(els.map { |e| e['id'] }.compact)
      first = Set.new
      els.each do |e|
        id = e['id']
        next if id.nil?

        unless first.include?(id)
          first << id
          next
        end
        note_duplicate_id_references(id)
        n = 1
        loop do
          n += 1
          cand = "#{id[0, 14]}#{format('%02d', n)}"
          next if seen.include?(cand)

          seen << cand
          @log['duplicate_ids'] << { 'from' => id, 'to' => cand, 'element' => e['name'] }
          e['id'] = cand
          break
        end
      end
    end

    # A duplicated id that something points at cannot be disambiguated here: every
    # reference binds to the first element. Surface it, once per id.
    def note_duplicate_id_references(id)
      return if @log['blockers'].any? { |b| b['id'] == id }

      refs = []
      els.each do |e|
        refs << "#{e['name']} (source.elementId)" if e.dig('source', 'elementId') == id
        (e['relationships'] || []).each { |r| refs << "#{e['name']}/#{r['name']} (targetElementId)" if r['targetElementId'] == id }
      end
      return if refs.empty?

      @log['blockers'] << { 'reason' => 'duplicate-id-referenced', 'id' => id, 'references' => refs,
                            'detail' => "element id #{id.inspect} is used by several elements and referenced by #{refs.join(', ')}; the reference binds to the first one" }
    end

    # Friendly != physical warehouse-table name: the converter prefixes base
    # columns with the Power BI table name while the element carries the physical
    # name. Mirrors convert-model.rb Fixup 3b: only a base column's exact
    # [Prefix/Leaf] whose prefix matches NO element name is re-prefixed.
    def reprefix_warehouse_tables!
      known = Set.new(@by_name.keys)
      els.each do |e|
        next unless e.dig('source', 'kind') == 'warehouse-table'

        name = e['name'].to_s
        next if name.empty?

        (e['columns'] || []).each do |c|
          m = c['formula'].to_s.match(%r{\A\[([^\]/]+)/([^\]/]+)\]\z})
          next unless m
          next if m[1] == name || known.include?(m[1]) || [CUSTOM_SQL, METRICS].include?(m[1])

          to = "[#{name}/#{m[2]}]"
          add_rewrite(e, 'columns', c, 'D9', c['formula'], to)
          c['formula'] = to
        end
      end
    end

    # ---- indexes (rebuilt per round) ----
    def reindex!
      @by_name = {}
      @by_id = {}
      els.each do |e|
        @by_name[e['name']] ||= e if e['name']
        @by_id[e['id']] ||= e if e['id']
      end
      @element_nk = names_map(@by_name.keys)
      @idx = {}
      @global = Set.new
      [@dm['controls'], @dm['parameters']].each do |list|
        Array(list).each { |x| @global << x['name'] if x.is_a?(Hash) && x['name'] }
      end
    end

    def names_map(names)
      h = {}
      names.each do |n|
        next if n.nil?

        (h[PbiDmResolver.nk(n)] ||= []) << n unless (h[PbiDmResolver.nk(n)] || []).include?(n)
      end
      h
    end

    def derived_name(c)
      return c['name'] if c['name'].is_a?(String) && !c['name'].empty?

      m = c['formula'].to_s.match(/\A\s*\[([^\[\]]+)\]\s*\z/)
      return nil unless m

      inner = m[1]
      return inner[(CUSTOM_SQL.length + 1)..-1] if inner.start_with?("#{CUSTOM_SQL}/")

      inner.split('/').last
    end

    def sql_element?(e)
      e.dig('source', 'kind') == 'sql'
    end

    # { cols: nk=>[exposed names], metrics: [...], sqlx: nk=>[SQL output names], alias: nk=>[exposed names] }
    def index_of(e)
      @idx[e.object_id] ||= begin
        cols = []
        sqlx = []
        alias_names = []
        (e['columns'] || []).each do |c|
          n = derived_name(c)
          cols << n if n
          m = c['formula'].to_s.match(%r{\A\s*\[#{Regexp.escape(CUSTOM_SQL)}/(.+)\]\s*\z})
          next unless m

          sqlx << m[1]
          alias_names << [m[1], c['name']] if c['name']
        end
        mets = (e['metrics'] || []).map { |m| m['name'] }.compact
        col_map = names_map(cols)
        # [El/<SQL output name>] also resolves to the (renamed) exposed column
        alias_names.each do |x, exposed|
          list = (col_map[PbiDmResolver.nk(x)] ||= [])
          list << exposed unless list.include?(exposed)
        end
        bare = names_map(cols + mets + (sql_element?(e) ? Array(@sql_names[e['name']]) + sqlx : []))
        { cols: col_map, bare: bare, sqlx: names_map(sqlx) }
      end
    end

    def rels_of(e, depth = 0)
      own = (e['relationships'] || []).select { |r| r['name'] }
      return own unless e.dig('source', 'kind') == 'table' && depth < 8

      src = @by_id[e.dig('source', 'elementId')]
      src ? own + rels_of(src, depth + 1) : own
    end

    def find_rel(e, name)
      rels = rels_of(e)
      exact = rels.find { |r| r['name'] == name }
      return exact if exact

      cands = rels.select { |r| PbiDmResolver.nk(r['name']) == PbiDmResolver.nk(name) }
      cands.size == 1 ? cands[0] : nil
    end

    # -> [:same] | [:rewrite, name] | [:ambiguous, cands] | [:unresolved]
    def lookup(map, name)
      cands = map[PbiDmResolver.nk(name)]
      return [:unresolved] if cands.nil? || cands.empty?
      return [:same] if cands.include?(name)
      return [:rewrite, cands[0]] if cands.size == 1

      ci = cands.select { |x| x.downcase == name.downcase }
      return [:rewrite, ci[0]] if ci.size == 1

      [:ambiguous, cands]
    end

    def resolve_ref(e, inner)
      return [:unresolved] if inner.strip.empty?

      parts = inner.split('/', -1)
      if parts.size == 1
        return [:same] if @global.include?(inner)

        return lookup(index_of(e)[:bare], inner)
      end
      return [:unverified, 'empty path segment'] if parts.any?(&:empty?)

      head = parts[0]
      return resolve_custom_sql(e, parts[1..-1].join('/')) if head == CUSTOM_SQL
      return [:same] if head == METRICS

      path = [head]
      cur = @by_name[head] || @by_id[head]
      if cur.nil?
        st, v = lookup(@element_nk, head)
        return [:ambiguous, v] if st == :ambiguous

        if st == :rewrite
          cur = @by_name[v]
          path[0] = v
        end
      end
      if cur.nil?
        rel = find_rel(e, head)
        return [:unresolved] unless rel

        cur = @by_id[rel['targetElementId']]
        return [:unverified, "relationship #{head} targets an unknown element"] unless cur

        path[0] = rel['name']
      end
      parts[1..-2].each do |mid|
        rel = find_rel(cur, mid)
        return [:unverified, "no relationship #{mid} on #{cur['name']}"] unless rel

        path << rel['name']
        cur = @by_id[rel['targetElementId']]
        return [:unverified, "relationship #{mid} targets an unknown element"] unless cur
      end
      col = parts.last
      st, v = lookup(index_of(cur)[:cols], col)
      case st
      when :same
        new_inner = (path + [col]).join('/')
        new_inner == inner ? [:same] : [:rewrite, new_inner]
      when :rewrite then [:rewrite, (path + [v]).join('/')]
      else [st, v]
      end
    end

    def resolve_custom_sql(e, col)
      return [:same] unless sql_element?(e)

      authoritative = @sql_names[e['name']]
      map = authoritative ? names_map(authoritative) : index_of(e)[:sqlx]
      st, v = lookup(map, col)
      case st
      when :rewrite then [:rewrite, "#{CUSTOM_SQL}/#{v}"]
      when :unresolved then authoritative ? [:unresolved] : [:same]
      else [st, v]
      end
    end

    # ---- D1 ----
    def build_prefix_map!
      known = Set.new(@by_name.keys + @by_id.keys + [CUSTOM_SQL, METRICS])
      els.each { |e| (e['relationships'] || []).each { |r| known << r['name'] if r['name'] } }
      heads = Set.new
      each_formula do |_e, _k, c|
        PbiDmResolver.lex(c['formula']).each do |type, text|
          next unless type == :ref

          inner = text[1...-1]
          heads << inner.split('/', 2)[0] if inner.include?('/')
        end
      end
      @pmap = {}
      (heads - known).to_a.sort.each do |p|
        view = p.end_with?(' View')
        base = view ? p[0...-5] : p
        by_nk = @by_name.keys.select { |n| PbiDmResolver.nk(n) == PbiDmResolver.nk(p) }
        if by_nk.size == 1
          @pmap[p] = by_nk[0]
          next
        end
        cands = els.select do |e|
          sql_element?(e) && e.dig('source', 'statement').to_s =~ /[.\s"]#{Regexp.escape(base)}\b/i
        end
        exact = cands.select { |e| e['name'].to_s.upcase == base.upcase }
        cands = exact unless exact.empty?
        if cands.size == 1
          tgt = cands[0]['name'].to_s + (view ? ' View' : '')
          if @by_name.key?(tgt)
            @pmap[p] = tgt
          else
            @log['prefix_unresolved'][p] = "UNRESOLVED (restored element #{cands[0]['name']} has no '#{tgt}' sibling)"
          end
        else
          names = cands.map { |c| c['name'] }.first(5)
          @log['prefix_unresolved'][p] = "UNRESOLVED (#{cands.size} candidates: #{names.inspect})"
        end
      end
      @log['prefix_remaps'] = @pmap.dup
    end

    def apply_prefix_map(e, kind, c, formula)
      return formula if @pmap.empty?

      PbiDmResolver.lex(formula).map do |type, text|
        next text unless type == :ref

        inner = text[1...-1]
        head, rest = inner.split('/', 2)
        if rest && @pmap.key?(head)
          new_ref = "[#{@pmap[head]}/#{rest}]"
          add_rewrite(e, kind, c, 'D1', text, new_ref)
          new_ref
        else
          text
        end
      end.join
    end

    def add_rewrite(e, kind, c, rule, from, to)
      @log['rewrites'] << { 'element' => e['name'], 'column' => label(c), 'kind' => kind, 'rule' => rule, 'from' => from, 'to' => to }
    end

    def null_formula(e, kind, c, reason, detail, was, refs = [])
      c['formula'] = 'Null'
      @log['nulled'] << { 'element' => e['name'], 'name' => label(c), 'kind' => kind, 'reason' => reason,
                          'detail' => detail, 'unresolved_refs' => refs, 'was' => trim(was) }
    end

    # ---- pass A: overrides, null list, D1, D3, D7 ----
    def pass_a(e, kind, c)
      key = "#{e['name']}|#{c['name'] || c['id']}"
      original = c['formula']
      if @overrides.key?(key)
        c['formula'] = @overrides[key]
        @log['overrides'] << key
        return
      end
      if @null_list.include?(key)
        null_formula(e, kind, c, 'null-list', 'listed in null_list', original)
        return
      end
      g = apply_prefix_map(e, kind, c, original)
      h, rules, problem = PbiDmResolver.translate_dax(g)
      if problem
        null_formula(e, kind, c, problem[0], problem[1], original)
        return
      end
      unless rules.empty?
        @log['dax'] << { 'element' => e['name'], 'name' => label(c), 'kind' => kind, 'rules' => rules, 'was' => trim(g), 'now' => trim(h) }
        g = h
      end
      k, changed = PbiDmResolver.rewrite_date_keys(g, @date_keys)
      if changed
        @log['date_keys'] << { 'element' => e['name'], 'name' => label(c), 'kind' => kind, 'was' => trim(g), 'now' => trim(k) }
        g = k
      end
      c['formula'] = g unless g == original
    end

    # ---- D2 / D4 / D8 fixpoint ----
    def resolve_formula(e, kind, c)
      unresolved = []
      out = PbiDmResolver.lex(c['formula']).map do |type, text|
        next text unless type == :ref

        inner = text[1...-1]
        st, v = resolve_ref(e, inner)
        case st
        when :same then text
        when :rewrite
          new_ref = "[#{v}]"
          add_rewrite(e, kind, c, 'D2', text, new_ref)
          new_ref
        when :unresolved
          unresolved << inner
          text
        when :ambiguous
          note(@log['ambiguous'], e, c, inner, 'ref' => inner, 'candidates' => v)
          text
        else
          note(@log['unverified'], e, c, inner, 'ref' => inner, 'reason' => v)
          text
        end
      end.join
      [out, unresolved]
    end

    def note(list, e, c, ref, extra)
      key = "#{list.object_id}|#{e['name']}|#{label(c)}|#{ref}"
      return if @seen.include?(key)

      @seen << key
      list << { 'element' => e['name'], 'name' => label(c) }.merge(extra)
    end

    def fixpoint!
      60.times do
        reindex!
        changed = false
        els.each do |e|
          %w[columns metrics].each do |kind|
            (e[kind] || []).each do |c|
              f = c['formula']
              next unless f.is_a?(String) && f.strip != 'Null'

              out, unresolved = resolve_formula(e, kind, c)
              if unresolved.any?
                null_formula(e, kind, c, 'unresolved-ref', "#{unresolved.uniq.length} ref(s) resolve nowhere", f, unresolved.uniq)
                changed = true
              elsif out != f
                c['formula'] = out
                changed = true
              end
            end
          end
        end
        changed = true if remove_null_columns!
        break unless changed
      end
    end

    def remove_null_columns!
      removed_any = false
      els.each do |e|
        gone = (e['columns'] || []).select { |c| c['name'].nil? && c['formula'].to_s.strip == 'Null' }
        next if gone.empty?

        ids = gone.map { |c| c['id'] }
        e['columns'] = e['columns'] - gone
        e['order'] = e['order'].reject { |i| ids.include?(i) } if e['order'].is_a?(Array)
        if e['folders'].is_a?(Array)
          e['folders'].each { |fo| fo['items'] = fo['items'].reject { |i| ids.include?(i) } if fo['items'].is_a?(Array) }
          e['folders'] = e['folders'].reject { |fo| fo['items'].is_a?(Array) && fo['items'].empty? }
        end
        (e['groupings'] || []).each do |g|
          %w[groupBy calculations].each { |k| g[k] = g[k].reject { |i| ids.include?(i) } if g[k].is_a?(Array) }
        end
        affected = []
        # Any key on a removed column drops the WHOLE relationship (a weaker join
        # fans rows out); the fixpoint then nulls the [Rel/..] formulas using it.
        els.each do |holder|
          next unless holder['relationships'].is_a?(Array)

          holder['relationships'] = holder['relationships'].reject do |r|
            hit = (r['keys'] || []).any? do |k|
              (holder.equal?(e) && ids.include?(k['sourceColumnId'])) ||
                ((r['targetElementId'].nil? || r['targetElementId'] == e['id']) && ids.include?(k['targetColumnId']))
            end
            affected << r['name'] if hit
            hit
          end
        end
        @els_by_removed ||= {}
        gone.each do |c|
          prior = @log['nulled'].reverse.find { |n| n['element'] == e['name'] && n['name'] == "(#{c['id']})" }
          @log['removed_columns'] << { 'element' => e['name'], 'id' => c['id'],
                                       'was' => prior ? prior['was'] : 'Null',
                                       'reason' => prior ? prior['reason'] : 'unnamed Null column',
                                       'relationships_affected' => affected }
        end
        removed_any = true
      end
      removed_any
    end

    def finish
      l = @log
      l['summary'] = {
        'prefix_remaps' => l['prefix_remaps'].size,
        'rewrites' => l['rewrites'].size,
        'dax_translated' => l['dax'].size,
        'date_key_rewrites' => l['date_keys'].size,
        'nulled' => l['nulled'].size,
        'unresolved_nulled' => l['nulled'].count { |n| n['reason'] == 'unresolved-ref' },
        'columns_removed' => l['removed_columns'].size,
        'duplicate_ids' => l['duplicate_ids'].size,
        'blockers' => l['blockers'].size,
        'ambiguous' => l['ambiguous'].size,
        'unverified' => l['unverified'].size
      }
      l
    end
  end
end
