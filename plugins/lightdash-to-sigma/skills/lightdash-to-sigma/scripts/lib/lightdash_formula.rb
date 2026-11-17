# frozen_string_literal: true
# Lightdash field SQL, metric definitions, metric filters, time intervals,
# join `sql_on`, and spreadsheet-style formats -> Sigma formulas.
#
#   - `${TABLE}.col`, `${dim}`, `${model.dim}`, `${metric}` references
#   - dimension / metric SQL through a small recursive-descent parser
#     (CASE, COALESCE, NULLIF, CAST / ::, EXTRACT, DATE_TRUNC, string + math
#     functions, `||`, IS NULL, IN, BETWEEN) -- anything it cannot parse or map
#     fails closed: [nil, reason], never a guessed formula
#   - metric type -> aggregate (sum, count, count_distinct, average, min, max,
#     median, percentile) and metric `filters:` -> SumIf / CountIf / ... predicates
#   - time intervals (DAY..YEAR, RAW, *_NUM, *_NAME)
#   - spreadsheet-style `format` -> Sigma format
#
# Pure functions, stdlib only, Ruby 2.6-compatible (no endless defs, no
# pattern matching).
#
# Resolver context (a Hash of lambdas) used by translate_expr:
#   :dialect       => 'bigquery' | 'snowflake' | ...   (double-quote meaning)
#   :table_column  => ->(col) { "[El/Col Name]" or nil | [nil, reason] }
#   :field         => ->(table_or_nil, name) { "[Display]" / "(metric formula)" or nil | [nil, reason] }

module LightdashFormula
  class TranslateError < StandardError; end

  AGG = {
    'sum' => 'Sum',
    'count' => 'Count',
    'count_distinct' => 'CountDistinct',
    'average' => 'Avg',
    'min' => 'Min',
    'max' => 'Max',
    'median' => 'Median'
  }.freeze

  COND_AGG = {
    'Sum' => 'SumIf',
    'Count' => 'CountIf',
    'CountDistinct' => 'CountDistinctIf',
    'Avg' => 'AvgIf',
    'Min' => 'MinIf',
    'Max' => 'MaxIf'
  }.freeze

  GAP_METRIC_TYPES = %w[sum_distinct average_distinct percent_of_total percent_of_previous running_total].freeze

  INTERVAL_TRUNC = {
    'SECOND' => 'second', 'MINUTE' => 'minute', 'HOUR' => 'hour', 'DAY' => 'day',
    'WEEK' => 'week', 'MONTH' => 'month', 'QUARTER' => 'quarter', 'YEAR' => 'year'
  }.freeze

  DATE_PARTS = %w[year quarter month week day hour minute second].freeze
  EXTRACT_FN = {
    'year' => 'Year', 'quarter' => 'Quarter', 'month' => 'Month', 'day' => 'Day',
    'hour' => 'Hour', 'minute' => 'Minute', 'second' => 'Second'
  }.freeze

  # Plain 1:1 function renames (arity unchecked: Sigma validates at POST).
  SIMPLE_FN = {
    'COALESCE' => 'Coalesce', 'IFNULL' => 'Coalesce', 'NVL' => 'Coalesce', 'NULLIF' => 'NullIf',
    'LOWER' => 'Lower', 'UPPER' => 'Upper', 'TRIM' => 'Trim', 'ROUND' => 'Round',
    'FLOOR' => 'Floor', 'CEIL' => 'Ceiling', 'CEILING' => 'Ceiling', 'ABS' => 'Abs',
    'SQRT' => 'Sqrt', 'LENGTH' => 'Len', 'LEN' => 'Len', 'CHAR_LENGTH' => 'Len',
    'SUBSTR' => 'Mid', 'SUBSTRING' => 'Mid', 'REPLACE' => 'Replace', 'LEFT' => 'Left',
    'RIGHT' => 'Right', 'GREATEST' => 'Greatest', 'LEAST' => 'Least', 'IF' => 'If',
    'IFF' => 'If', 'SPLIT_PART' => 'SplitPart', 'DATE' => 'Date'
  }.freeze

  AGG_FN = {
    'SUM' => 'Sum', 'AVG' => 'Avg', 'AVERAGE' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
    'MEDIAN' => 'Median'
  }.freeze

  CAST_TYPES = {
    'string' => 'Text', 'varchar' => 'Text', 'text' => 'Text', 'char' => 'Text',
    'int' => 'Number', 'int64' => 'Number', 'integer' => 'Number', 'bigint' => 'Number',
    'smallint' => 'Number', 'numeric' => 'Number', 'decimal' => 'Number', 'bignumeric' => 'Number',
    'float' => 'Number', 'float64' => 'Number', 'double' => 'Number', 'number' => 'Number',
    'real' => 'Number',
    'bool' => 'Logical', 'boolean' => 'Logical',
    'date' => 'Date', 'timestamp' => 'Date', 'datetime' => 'Date', 'timestamp_ntz' => 'Date',
    'timestamp_ltz' => 'Date', 'timestamp_tz' => 'Date'
  }.freeze

  module_function

  # ---------------------------------------------------------------- names ----

  # order_date / ORDER_DATE -> "Order Date"; mixed-case names are kept as-is
  # (Sigma resolves mixed-case identifiers verbatim); `/` and `-` become spaces.
  def titleize(name)
    s = name.to_s.strip.tr('/-', '  ')
    return s if s =~ /[a-z]/ && s =~ /[A-Z]/ && s !~ /_/
    s.split(/[_\s]+/).reject(&:empty?).map { |w| w[0].upcase + w[1..-1].to_s.downcase }.join(' ')
  end

  def display_name(field, label = nil)
    text = label.to_s.strip
    text.empty? ? titleize(field) : text
  end

  # ------------------------------------------------------------- formats ----

  CURRENCY_BY_CODE = { 'USD' => '$', 'EUR' => '€', 'GBP' => '£', 'JPY' => '¥', 'INR' => '₹' }.freeze

  # Lightdash `format` -> Sigma format hash, or nil (unset / not parseable).
  # fmt may be a spreadsheet-style string ('[$$]#,##0.00', '0.0%', '#,##0') or
  # the newer object form ({type: percent|currency|number, round:, currency:}).
  # round: is the legacy numeric `round` key; type: the dimension type.
  def sigma_format(fmt, type: nil, round: nil)
    if fmt.is_a?(Hash)
      return object_format(fmt)
    end
    f = fmt.to_s.strip
    if f.empty?
      return nil if round.nil?
      return { 'kind' => 'number', 'formatString' => ".#{Integer(round)}f" }
    end
    return datetime_format(f) if %w[date timestamp].include?(type.to_s) && f =~ /[ymd]/i && f !~ /[#0]/

    cur = nil
    if (m = f.match(/\[\$([^\]\-]*)(?:-[^\]]*)?\]/))
      cur = m[1]
      f = f.sub(m[0], '')
    elsif (m = f.match(/\A([$€£¥₹])/))
      cur = m[1]
      f = f.sub(m[1], '')
    end
    return nil unless f =~ /\A[#0,]+(\.[#0]+)?%?\z/
    decimals = f[/\.([#0]+)/, 1].to_s.length
    comma = f.include?(',')
    pct = f.end_with?('%')
    out = { 'kind' => 'number',
            'formatString' => "#{cur}#{comma ? ',' : ''}.#{decimals}#{pct ? '%' : 'f'}" }
    out['currencySymbol'] = cur if cur && !cur.empty?
    out
  end

  def object_format(h)
    t = h['type'].to_s
    r = h['round'].nil? ? nil : Integer(h['round']) rescue nil
    case t
    when 'percent'
      { 'kind' => 'number', 'formatString' => ".#{r || 0}%" }
    when 'currency'
      sym = CURRENCY_BY_CODE[h['currency'].to_s.upcase]
      return nil unless sym
      { 'kind' => 'number', 'formatString' => "#{sym},.#{r || 2}f", 'currencySymbol' => sym }
    when 'number'
      { 'kind' => 'number', 'formatString' => ",.#{r || 0}f" }
    end
  end

  def datetime_format(f)
    return nil if f =~ /[hs]/i
    out = f.gsub(/yyyy|yy|mmmm|mmm|mm|dddd|ddd|dd|m|d/i) do |tok|
      case tok.downcase
      when 'yyyy' then '%Y'
      when 'yy' then '%y'
      when 'mmmm' then '%B'
      when 'mmm' then '%b'
      when 'mm', 'm' then '%m'
      when 'dddd' then '%A'
      when 'ddd' then '%a'
      else '%d'
      end
    end
    { 'kind' => 'datetime', 'formatString' => out }
  end

  # ------------------------------------------------------------ intervals ----

  # -> [formula, nil] | [nil, reason]; col_ref includes brackets.
  def interval_formula(interval, col_ref)
    iv = interval.to_s.upcase
    return [col_ref, nil] if iv == 'RAW'
    return [%[DateTrunc("#{INTERVAL_TRUNC[iv]}", #{col_ref})], nil] if INTERVAL_TRUNC.key?(iv)
    case iv
    when 'YEAR_NUM' then ["Year(#{col_ref})", nil]
    when 'QUARTER_NUM' then ["Quarter(#{col_ref})", nil]
    when 'MONTH_NUM' then ["Month(#{col_ref})", nil]
    when 'DAY_OF_MONTH_NUM' then ["Day(#{col_ref})", nil]
    when 'DAY_OF_YEAR_NUM' then ["DayOfYear(#{col_ref})", nil]
    when 'HOUR_OF_DAY_NUM' then ["Hour(#{col_ref})", nil]
    when 'MINUTE_OF_HOUR_NUM' then ["Minute(#{col_ref})", nil]
    when 'MONTH_NAME' then [%[DateFormat(#{col_ref}, "%B")], nil]
    when 'DAY_OF_WEEK_NAME' then [%[DateFormat(#{col_ref}, "%A")], nil]
    else [nil, "time interval #{iv} has no Sigma translation"]
    end
  end

  # ------------------------------------------------------------ relations ----

  def relationship_type(raw)
    case raw.to_s.tr('_', '-')
    when 'one-to-one' then '1:1'
    when 'one-to-many' then '1:N'
    when 'many-to-many' then 'N:N'
    else 'N:1'
    end
  end

  JOIN_REF = /(?:\$\{[A-Za-z0-9_]+\.[A-Za-z0-9_]+\}|(?:(?:`[^`]+`|"[^"]+"|\[[^\]]+\]|[A-Za-z_][A-Za-z0-9_$-]*)\s*\.\s*)+(?:`[^`]+`|"[^"]+"|\[[^\]]+\]|[A-Za-z_][A-Za-z0-9_$-]*))/.freeze

  # "${a.x} = ${b.y} [AND ${a.z} = ${b.w}]" or compiled qualified-column
  # equivalents -> [{left_table,left_field,right_table,right_field}] | nil
  def parse_sql_on(sql)
    text = strip_join_parens(sql.to_s.strip)
    return nil if text.empty?
    pairs = text.split(/\s+AND\s+/i).map do |clause|
      m = strip_join_parens(clause.strip).match(/\A(#{JOIN_REF})\s*=\s*(#{JOIN_REF})\z/)
      return nil unless m
      left = join_ref_parts(m[1])
      right = join_ref_parts(m[2])
      return nil unless left && right
      { 'left_table' => left[0], 'left_field' => left[1], 'right_table' => right[0], 'right_field' => right[1] }
    end
    pairs.empty? ? nil : pairs
  end

  def strip_join_parens(text)
    out = text
    loop do
      break unless out.start_with?('(') && out.end_with?(')')
      depth = 0
      closes_at_end = out.each_char.with_index.all? do |char, i|
        depth += 1 if char == '('
        depth -= 1 if char == ')'
        depth.positive? || i == out.length - 1
      end
      break unless closes_at_end && depth.zero?
      out = out[1...-1].strip
    end
    out
  end

  def join_ref_parts(ref)
    if (m = ref.match(/\A\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\}\z/))
      return [m[1], m[2]]
    end
    parts = ref.scan(/`([^`]+)`|"([^"]+)"|\[([^\]]+)\]|([A-Za-z_][A-Za-z0-9_$-]*)/).map { |p| p.compact.first }
    parts.length >= 2 ? parts.last(2) : nil
  end

  # ------------------------------------------------------------ aggregates ---

  # type: Lightdash metric type; expr: Sigma formula of the aggregated value
  # (already translated); pred: Sigma predicate or nil; percentile: 0..100.
  # -> [formula, nil] | [nil, reason]
  def aggregate_formula(type, expr, pred: nil, percentile: nil)
    t = type.to_s.downcase
    return [nil, "metric type #{t} has no Sigma translation"] if GAP_METRIC_TYPES.include?(t)
    if t == 'percentile'
      return [nil, 'percentile metric is missing the percentile value'] if percentile.nil?
      p_val = (Float(percentile.to_s) / 100.0).round(4)
      p_val = p_val.to_i if p_val == p_val.to_i
      val = pred ? "If(#{pred}, #{expr})" : expr
      return ["PercentileCont(#{val}, #{p_val})", nil]
    end
    fn = AGG[t]
    return [nil, "metric type #{t.inspect} is not mapped"] unless fn
    return ["#{fn}(#{expr})", nil] unless pred
    case fn
    when 'Count' then ["CountIf(IsNotNull(#{expr}) and (#{pred}))", nil]
    when 'Median' then ["Median(If(#{pred}, #{expr}))", nil]
    else ["#{COND_AGG[fn]}(#{expr}, #{pred})", nil]
    end
  end

  # ------------------------------------------------------- metric filters ----

  # filters: [{ "dim" => value }, ...] (all combined with AND).
  # resolve: ->(name) { "[Display]" | nil | [nil, reason] }; types: { name => dim type }
  def filter_predicate(filters, resolve, types: {})
    return [nil, nil] if filters.nil? || (filters.respond_to?(:empty?) && filters.empty?)
    clauses = []
    list = filters.is_a?(Hash) ? [filters] : Array(filters)
    list.each do |entry|
      return [nil, "unsupported metric filter shape #{entry.inspect}"] unless entry.is_a?(Hash)
      entry.each do |key, value|
        name = key.to_s
        ref, why = unwrap(resolve.call(name), nil)
        return [nil, why || "unresolved metric filter field #{name}"] unless ref
        clause, err = filter_clause(ref, value, types[name])
        return [nil, "#{err} (filter on #{name})"] unless clause
        clauses << clause
      end
    end
    [clauses.join(' and '), nil]
  end

  def filter_clause(ref, value, type)
    case value
    when Array
      return [nil, 'empty filter list'] if value.empty?
      return ["In(#{ref}, #{value.map { |v| literal(v, type) }.join(', ')})", nil]
    when nil then return ["IsNull(#{ref})", nil]
    when true, false, Numeric then return ["#{ref} = #{literal(value, type)}", nil]
    end
    s = value.to_s.strip
    case s
    when /\Anull\z/i then ["IsNull(#{ref})", nil]
    when /\A!\s*null\z/i then ["IsNotNull(#{ref})", nil]
    when /\AunsupportedOperator\s+(\S+)/
      [nil, "filter operator #{Regexp.last_match(1)} has no Sigma translation"]
    when /\A(inThePast|inTheNext|inTheCurrent|notInThePast|notInTheNext|inBetween|notInBetween)\b/
      [nil, "#{Regexp.last_match(1)} date-range filter has no Sigma translation"]
    when /\A(>=|<=|>|<)\s*(.+)\z/
      ["#{ref} #{Regexp.last_match(1)} #{literal(Regexp.last_match(2).strip, type)}", nil]
    when /\AstartsWith\s+(.+)\z/ then ["StartsWith(#{ref}, #{literal(Regexp.last_match(1), nil)})", nil]
    when /\AendsWith\s+(.+)\z/ then ["EndsWith(#{ref}, #{literal(Regexp.last_match(1), nil)})", nil]
    when /\Ainclude\s+(.+)\z/ then ["Contains(#{ref}, #{literal(Regexp.last_match(1), nil)})", nil]
    when /\AdoesNotInclude\s+(.+)\z/ then ["not Contains(#{ref}, #{literal(Regexp.last_match(1), nil)})", nil]
    when /\A!\s*(.+)\z/ then ["#{ref} != #{literal(Regexp.last_match(1).strip, type)}", nil]
    else ["#{ref} = #{literal(s, type)}", nil]
    end
  end

  def literal(val, type = nil)
    case val
    when true then 'True'
    when false then 'False'
    when nil then 'Null'
    when Numeric then val.to_s
    else
      s = val.to_s
      return (s.casecmp('true').zero? ? 'True' : 'False') if type.to_s == 'boolean' && s =~ /\A(true|false)\z/i
      return s if s =~ /\A-?\d+(\.\d+)?\z/ && type.to_s != 'string'
      # date/timestamp comparisons need a date value, not text (a text literal compares as a string)
      return "Date(#{quote(s)})" if %w[date timestamp].include?(type.to_s)
      quote(s)
    end
  end

  def quote(s)
    %("#{s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}")
  end

  # [val | nil | [val, reason]] -> [val, reason]
  def unwrap(res, default_reason)
    return [res[0], res[1]] if res.is_a?(Array)
    [res, res.nil? ? default_reason : nil]
  end

  # ----------------------------------------------------- expression engine ---

  # Raw-SQL detection that happens before parsing.
  def gap_reason(sql)
    s = sql.to_s
    return 'Lightdash parameters (${lightdash.parameters.*}) have no Sigma equivalent' if s =~ /\$\{\s*(lightdash|ld)\.parameters\./i
    return 'Lightdash user attributes (${lightdash.attributes.*}) are not translated into field SQL' if s =~ /\$\{\s*(lightdash|ld)\.(attributes|attr)\./i
    return 'Liquid templating ({{ }}) is not translated' if s.include?('{{') || s.include?('{%')
    nil
  end

  # sql -> [sigma_formula, nil] | [nil, reason]. aggregates: true allows
  # SUM/AVG/COUNT/... (number-type metric SQL); false (dimensions) rejects them.
  def translate_expr(sql, ctx, aggregates: false)
    text = sql.to_s.strip
    return [nil, 'empty sql expression'] if text.empty?
    reason = gap_reason(text)
    return [nil, reason] if reason
    refs = []
    substituted = substitute_refs(text, ctx, refs)
    tokens = tokenize(substituted, refs, ctx[:dialect].to_s)
    parser = Parser.new(tokens, aggregates)
    ast = parser.parse
    [Emitter.new.emit(ast), nil]
  rescue TranslateError => e
    [nil, e.message]
  end

  # Replaces every ${...} with a \u0001N\u0002 placeholder; resolved Sigma
  # refs are stashed in refs[N] so raw SQL `[` never collides with them.
  def substitute_refs(text, ctx, refs)
    out = text.gsub(/\$\{TABLE\}\.(?:`([^`]+)`|"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*))/) do
      col = Regexp.last_match(1) || Regexp.last_match(2) || Regexp.last_match(3)
      ref, why = unwrap(ctx[:table_column].call(col), "unresolved ${TABLE}.#{col}")
      raise TranslateError, why unless ref
      refs << ref
      "\u0001#{refs.length - 1}\u0002"
    end
    out.gsub(/\$\{([^}]*)\}/) do
      inner = Regexp.last_match(1).strip
      raise TranslateError, 'bare ${TABLE} without a column' if inner == 'TABLE'
      parts = inner.split('.')
      table, name = parts.length == 1 ? [nil, parts[0]] : [parts[0], parts[1..-1].join('.')]
      raise TranslateError, "unsupported reference ${#{inner}}" if parts.length > 2
      ref, why = unwrap(ctx[:field].call(table, name), "unresolved reference ${#{inner}}")
      raise TranslateError, why unless ref
      refs << ref
      "\u0001#{refs.length - 1}\u0002"
    end
  end

  Token = Struct.new(:type, :value)

  def tokenize(s, refs, dialect)
    tokens = []
    i = 0
    while i < s.length
      c = s[i]
      if c =~ /\s/
        i += 1
      elsif c == "\u0001"
        j = s.index("\u0002", i)
        tokens << Token.new(:ref, refs[s[(i + 1)...j].to_i])
        i = j + 1
      elsif c == "'"
        str, i = read_quoted(s, i, "'")
        tokens << Token.new(:str, str)
      elsif c == '"'
        raise TranslateError, 'double-quoted identifier is a warehouse column reference, not translated' unless %w[bigquery mysql].include?(dialect)
        str, i = read_quoted(s, i, '"')
        tokens << Token.new(:str, str)
      elsif c == '`'
        raise TranslateError, 'backtick-quoted identifier is a raw warehouse column reference, not translated'
      elsif c =~ /\d/ || (c == '.' && s[i + 1].to_s =~ /\d/)
        m = s[i..-1].match(/\A\d*\.?\d+(?:[eE][+-]?\d+)?/)
        tokens << Token.new(:num, m[0])
        i += m[0].length
      elsif c =~ /[A-Za-z_]/
        m = s[i..-1].match(/\A[A-Za-z_][A-Za-z0-9_$]*/)
        tokens << Token.new(:id, m[0])
        i += m[0].length
      else
        op = %w[|| <> != >= <= == ::].find { |o| s[i, 2] == o } || c
        raise TranslateError, "unsupported character #{c.inspect} in SQL" unless op =~ /\A(\|\||<>|!=|>=|<=|==|::|[-+*\/%(),=<>^])\z/
        tokens << Token.new(:op, op)
        i += op.length
      end
    end
    tokens
  end

  def read_quoted(s, i, q)
    out = +''
    i += 1
    while i < s.length
      c = s[i]
      if c == '\\' && i + 1 < s.length
        out << s[i + 1]
        i += 2
      elsif c == q && s[i + 1] == q
        out << q
        i += 2
      elsif c == q
        return [out, i + 1]
      else
        out << c
        i += 1
      end
    end
    raise TranslateError, 'unterminated string literal'
  end

  # Pratt parser -> AST of arrays: [:num, v] [:str, v] [:ref, v] [:const, 'True'] [:id, name]
  # [:paren, n] [:neg, n] [:not, n] [:bin, op, l, r] [:isnull, n, negate]
  # [:in, n, list, negate] [:between, n, lo, hi, negate] [:call, name, args, distinct]
  # [:case, operand, whens, else] [:cast, n, type]
  class Parser
    COMPARE = %w[= == != <> < > <= >=].freeze

    def initialize(tokens, aggregates)
      @t = tokens
      @i = 0
      @aggregates = aggregates
    end

    def parse
      node = expr(0)
      raise TranslateError, "unexpected #{@t[@i].value.inspect} in SQL" if @i < @t.length
      node
    end

    private

    def peek(off = 0)
      @t[@i + off]
    end

    def kw?(tok, word)
      tok && tok.type == :id && tok.value.upcase == word
    end

    def op?(tok, o)
      tok && tok.type == :op && tok.value == o
    end

    def take
      tok = @t[@i]
      raise TranslateError, 'unexpected end of SQL expression' unless tok
      @i += 1
      tok
    end

    def expect_op(o)
      tok = take
      raise TranslateError, "expected #{o.inspect} but found #{tok.value.inspect}" unless op?(tok, o)
    end

    def expect_kw(word)
      tok = take
      raise TranslateError, "expected #{word} but found #{tok.value.inspect}" unless kw?(tok, word)
    end

    def expr(min)
      left = prefix
      loop do
        tok = peek
        break unless tok
        if kw?(tok, 'OR') && min <= 1
          take
          left = [:bin, 'or', left, expr(2)]
        elsif kw?(tok, 'AND') && min <= 2
          take
          left = [:bin, 'and', left, expr(3)]
        elsif min <= 4 && (comparison?(tok) || kw?(tok, 'IS') || kw?(tok, 'IN') || kw?(tok, 'BETWEEN') ||
                          kw?(tok, 'LIKE') || kw?(tok, 'ILIKE') || (kw?(tok, 'NOT') && postfix_not?))
          left = comparison(left)
        elsif op?(tok, '||') && min <= 5
          take
          left = [:bin, '&', left, expr(6)]
        elsif (op?(tok, '+') || op?(tok, '-')) && min <= 6
          take
          left = [:bin, tok.value, left, expr(7)]
        elsif (op?(tok, '*') || op?(tok, '/') || op?(tok, '%')) && min <= 7
          take
          left = [:bin, tok.value, left, expr(8)]
        elsif op?(tok, '^') && min <= 8
          take
          left = [:bin, '^', left, expr(9)]
        elsif op?(tok, '::')
          take
          left = [:cast, left, read_type]
        else
          break
        end
      end
      left
    end

    def comparison?(tok)
      tok.type == :op && COMPARE.include?(tok.value)
    end

    def postfix_not?
      nxt = peek(1)
      kw?(nxt, 'IN') || kw?(nxt, 'BETWEEN') || kw?(nxt, 'LIKE') || kw?(nxt, 'ILIKE')
    end

    def comparison(left)
      tok = take
      if tok.type == :op
        op = { '==' => '=', '<>' => '!=' }[tok.value] || tok.value
        return [:bin, op, left, expr(5)]
      end
      word = tok.value.upcase
      negate = false
      if word == 'NOT'
        negate = true
        word = take.value.upcase
      end
      case word
      when 'IS'
        if kw?(peek, 'NOT')
          take
          negate = true
        end
        expect_kw('NULL')
        [:isnull, left, negate]
      when 'IN'
        expect_op('(')
        raise TranslateError, 'subquery in SQL is not translated' if kw?(peek, 'SELECT')
        list = [expr(0)]
        list << (take_comma && expr(0)) while op?(peek, ',')
        expect_op(')')
        [:in, left, list, negate]
      when 'BETWEEN'
        lo = expr(5)
        expect_kw('AND')
        hi = expr(5)
        [:between, left, lo, hi, negate]
      else
        raise TranslateError, "#{word} has no Sigma translation"
      end
    end

    def take_comma
      expect_op(',')
      true
    end

    def prefix
      tok = take
      case tok.type
      when :num then [:num, tok.value]
      when :str then [:str, tok.value]
      when :ref then [:ref, tok.value]
      when :op then prefix_op(tok)
      else prefix_word(tok)
      end
    end

    def prefix_op(tok)
      if tok.value == '('
        raise TranslateError, 'subquery in SQL is not translated' if kw?(peek, 'SELECT')
        inner = expr(0)
        expect_op(')')
        [:paren, inner]
      elsif tok.value == '-'
        [:neg, expr(8)]
      elsif tok.value == '+'
        expr(8)
      else
        raise TranslateError, "unexpected #{tok.value.inspect} in SQL"
      end
    end

    def prefix_word(tok)
      word = tok.value.upcase
      case word
      when 'TRUE' then [:const, 'True']
      when 'FALSE' then [:const, 'False']
      when 'NULL' then [:const, 'Null']
      when 'NOT' then [:not, expr(3)]
      when 'CASE' then parse_case
      when 'INTERVAL' then raise TranslateError, 'INTERVAL literal has no Sigma translation'
      when 'SELECT' then raise TranslateError, 'subquery in SQL is not translated'
      when 'CURRENT_DATE', 'CURRENT_TIMESTAMP'
        return call_node(tok.value) if op?(peek, '(')
        [:call, word, [], false]
      else
        return call_node(tok.value) if op?(peek, '(')
        [:id, tok.value]
      end
    end

    def parse_case
      operand = nil
      operand = expr(0) unless kw?(peek, 'WHEN')
      whens = []
      while kw?(peek, 'WHEN')
        take
        cond = expr(0)
        expect_kw('THEN')
        whens << [cond, expr(0)]
      end
      raise TranslateError, 'CASE without WHEN' if whens.empty?
      els = nil
      if kw?(peek, 'ELSE')
        take
        els = expr(0)
      end
      expect_kw('END')
      [:case, operand, whens, els]
    end

    def read_type
      tok = take
      raise TranslateError, 'expected a type name' unless tok.type == :id
      name = tok.value
      if op?(peek, '(')
        depth = 0
        loop do
          t = take
          depth += 1 if op?(t, '(')
          depth -= 1 if op?(t, ')')
          break if depth.zero?
        end
      end
      name
    end

    def call_node(name)
      expect_op('(')
      upper = name.upcase
      if %w[CAST SAFE_CAST TRY_CAST].include?(upper)
        inner = expr(0)
        expect_kw('AS')
        type = read_type
        expect_op(')')
        return [:cast, inner, type]
      elsif upper == 'EXTRACT'
        part = take
        expect_kw('FROM')
        inner = expr(0)
        expect_op(')')
        return [:call, 'EXTRACT', [[:id, part.value], inner], false]
      end
      distinct = false
      args = []
      if kw?(peek, 'DISTINCT')
        take
        distinct = true
      end
      if op?(peek, '*')
        take
        args << [:star]
      elsif !op?(peek, ')')
        args << expr(0)
        args << (take_comma && expr(0)) while op?(peek, ',')
      end
      expect_op(')')
      raise TranslateError, 'window function (OVER) has no Sigma translation in field SQL' if kw?(peek, 'OVER')
      check_aggregate(upper, distinct)
      [:call, upper, args, distinct]
    end

    def check_aggregate(upper, distinct)
      return unless AGG_FN.key?(upper) || upper == 'COUNT'
      return if @aggregates
      raise TranslateError, "aggregate function #{upper} is not allowed in dimension SQL"
    end
  end

  class Emitter
    def emit(n)
      case n[0]
      when :num, :str_raw then n[1]
      when :str then LightdashFormula.quote(n[1])
      when :ref, :const then n[1]
      when :id then raise TranslateError, "unresolved identifier #{n[1]} (raw warehouse column or keyword)"
      when :star then raise TranslateError, '* is only valid inside COUNT(*)'
      when :paren then "(#{emit(n[1])})"
      when :neg then "-#{emit(n[1])}"
      when :not then "not #{wrap(n[1])}"
      when :bin then bin(n)
      when :isnull then "#{n[2] ? 'IsNotNull' : 'IsNull'}(#{emit(n[1])})"
      when :in then "#{n[3] ? 'not ' : ''}In(#{([n[1]] + n[2]).map { |x| emit(x) }.join(', ')})"
      when :between then "#{n[4] ? 'not ' : ''}Between(#{emit(n[1])}, #{emit(n[2])}, #{emit(n[3])})"
      when :case then emit_case(n)
      when :cast then emit_cast(n)
      when :call then emit_call(n)
      else raise TranslateError, "internal: unknown node #{n[0]}"
      end
    end

    private

    def wrap(n)
      s = emit(n)
      %i[bin isnull in between].include?(n[0]) ? "(#{s})" : s
    end

    def bin(n)
      op = n[1]
      if op == '&'
        parts = flatten_concat(n)
        return "(#{parts.map { |p| emit(p) }.join(' & ')})"
      end
      "#{emit(n[2])} #{op} #{emit(n[3])}"
    end

    def flatten_concat(n)
      return [n] unless n[0] == :bin && n[1] == '&'
      flatten_concat(n[2]) + flatten_concat(n[3])
    end

    def emit_case(n)
      operand, whens, els = n[1], n[2], n[3]
      args = []
      whens.each do |cond, val|
        args << (operand ? "#{emit(operand)} = #{emit(cond)}" : emit(cond))
        args << emit(val)
      end
      args << (els ? emit(els) : 'Null')
      "If(#{args.join(', ')})"
    end

    def emit_cast(n)
      fn = CAST_TYPES[n[2].to_s.downcase]
      raise TranslateError, "CAST to #{n[2]} has no Sigma translation" unless fn
      "#{fn}(#{emit(n[1])})"
    end

    CAST_TYPES = LightdashFormula::CAST_TYPES

    def date_part(node)
      return nil unless node[0] == :id
      part = node[1].downcase
      LightdashFormula::DATE_PARTS.include?(part) ? part : nil
    end

    def emit_call(n)
      name, args = n[1], n[2]
      return emit_aggregate(n) if LightdashFormula::AGG_FN.key?(name) || name == 'COUNT'
      return "Today()" if name == 'CURRENT_DATE'
      return "Now()" if name == 'CURRENT_TIMESTAMP'
      case name
      when 'CONCAT'
        return "(#{args.map { |a| emit(a) }.join(' & ')})"
      when 'POWER', 'POW'
        raise TranslateError, 'POWER needs two arguments' unless args.length == 2
        return "(#{emit(args[0])} ^ #{emit(args[1])})"
      when 'MOD'
        raise TranslateError, 'MOD needs two arguments' unless args.length == 2
        return "(#{emit(args[0])} % #{emit(args[1])})"
      when 'SAFE_DIVIDE'
        raise TranslateError, 'SAFE_DIVIDE needs two arguments' unless args.length == 2
        return "(#{emit(args[0])} / NullIf(#{emit(args[1])}, 0))"
      when 'EXTRACT'
        part = date_part(args[0])
        fn = part && LightdashFormula::EXTRACT_FN[part]
        raise TranslateError, "EXTRACT(#{args[0][1]}) has no Sigma translation" unless fn
        return "#{fn}(#{emit(args[1])})"
      when 'DATE_TRUNC', 'TIMESTAMP_TRUNC', 'DATETIME_TRUNC'
        return emit_date_trunc(name, args)
      when 'DATEDIFF'
        part = args.length == 3 ? date_part(args[0]) : nil
        raise TranslateError, 'DATEDIFF form has no unambiguous Sigma translation' unless part
        return %[DateDiff("#{part}", #{emit(args[1])}, #{emit(args[2])})]
      end
      fn = LightdashFormula::SIMPLE_FN[name]
      raise TranslateError, "SQL function #{name} has no Sigma translation" unless fn
      "#{fn}(#{args.map { |a| emit(a) }.join(', ')})"
    end

    def emit_date_trunc(name, args)
      raise TranslateError, "#{name} needs two arguments" unless args.length == 2
      if args[0][0] == :str && LightdashFormula::DATE_PARTS.include?(args[0][1].downcase)
        return %[DateTrunc("#{args[0][1].downcase}", #{emit(args[1])})]
      end
      part = date_part(args[1])
      raise TranslateError, "#{name} unit is not a recognised date part" unless part
      %[DateTrunc("#{part}", #{emit(args[0])})]
    end

    def emit_aggregate(n)
      name, args, distinct = n[1], n[2], n[3]
      if name == 'COUNT'
        return 'Count()' if args.length == 1 && args[0][0] == :star
        raise TranslateError, 'COUNT needs one argument' unless args.length == 1
        return "#{distinct ? 'CountDistinct' : 'Count'}(#{emit(args[0])})"
      end
      raise TranslateError, "#{name} needs one argument" unless args.length == 1
      raise TranslateError, "#{name}(DISTINCT ...) has no Sigma translation" if distinct
      "#{LightdashFormula::AGG_FN[name]}(#{emit(args[0])})"
    end
  end
end
