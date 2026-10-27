# frozen_string_literal: true
# Omni field SQL, timeframes, groups, bins, and measure definitions → Sigma formulas:
#   - ${view.field}, ${view.field[timeframe]}, and intra-view ${field} refs
#   - aggregate_type (sum, count, count_distinct, average, min, max, median, list, percentile)
#   - Filtered measures (filters: block → SumIf, CountIf, CountDistinctIf, AvgIf, MinIf, MaxIf)
#   - Inline SQL aggregates (SUM/AVG/MIN/MAX/COUNT/MEDIAN) and ratio measures
#   - Dimension groups:, bin_boundaries:, CASE WHEN, casts (::string, ::number, ::date), and SQL functions
# Mustache attributes, omni_dimensionalize, and DO NOT PARSE fail closed (nil + reason).

module OmniFormula
  AGG = {
    'sum' => 'Sum',
    'count' => 'Count',
    'count_distinct' => 'CountDistinct',
    'average' => 'Avg',
    'avg' => 'Avg',
    'min' => 'Min',
    'max' => 'Max',
    'median' => 'Median',
    'list' => 'ListAgg',
    'sum_distinct_on' => 'Sum',
    'average_distinct_on' => 'Avg',
    'median_distinct_on' => 'Median'
  }.freeze

  COND_AGG = {
    'Sum' => 'SumIf',
    'Count' => 'CountIf',
    'CountDistinct' => 'CountDistinctIf',
    'Avg' => 'AvgIf',
    'Min' => 'MinIf',
    'Max' => 'MaxIf'
  }.freeze

  DATE_TRUNC_UNITS = {
    'date' => 'day',
    'day' => 'day',
    'week' => 'week',
    'month' => 'month',
    'quarter' => 'quarter',
    'fiscal_quarter' => 'quarter',
    'year' => 'year',
    'fiscal_year' => 'year',
    'hour' => 'hour',
    'minute' => 'minute',
    'second' => 'second'
  }.freeze

  module_function

  def display_name(field, label = nil)
    text = label.to_s.strip
    return text unless text.empty?
    field.to_s.split('_').reject(&:empty?).map { |w| w[0].upcase + w[1..].to_s }.join(' ')
  end

  def untranslatable?(sql)
    s = sql.to_s
    return 'omni_dimensionalize has no Sigma equivalent' if s =~ /omni_dimensionalize/i
    return 'Mustache user-attribute SQL is not translated' if s.include?('{{') || s =~ /omni_attributes/i
    return 'DO NOT PARSE dialect escape is not translated' if s =~ /DO NOT PARSE/
    nil
  end

  def warehouse_sql?(sql, field_name)
    s = sql.to_s.strip
    return true if s.empty?
    return true if s =~ /\A"[A-Za-z0-9_ ]+"\z/
    return true if s =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/ && s.casecmp(field_name.to_s).zero?
    return true if s =~ /\A\$\{[A-Za-z0-9_]+\.#{Regexp.escape(field_name.to_s)}\}\z/
    false
  end

  def sigma_format(fmt)
    f = fmt.to_s.downcase.strip
    return nil if f.empty?
    if f.include?('eur')
      decimals = f =~ /_0\b/ ? '0' : '2'
      return { 'kind' => 'number', 'formatString' => "€,.#{decimals}f", 'currencySymbol' => '€' }
    end
    if f.include?('gbp')
      decimals = f =~ /_0\b/ ? '0' : '2'
      return { 'kind' => 'number', 'formatString' => "£,.#{decimals}f", 'currencySymbol' => '£' }
    end
    if f.include?('usd') || f.include?('currency')
      decimals = f =~ /_0\b/ ? '0' : '2'
      return { 'kind' => 'number', 'formatString' => "$,.#{decimals}f", 'currencySymbol' => '$' }
    end
    if f.include?('percent')
      decimals = f[/percent_(\d+)/, 1] || '0'
      return { 'kind' => 'number', 'formatString' => ".#{decimals}%" }
    end
    if f =~ /\A(decimal|number)_(\d+)\z/
      return { 'kind' => 'number', 'formatString' => ",.#{$2}f" }
    end
    nil
  end

  def timeframe_formula(frame, col_ref)
    f = frame.to_s.downcase.strip
    return col_ref if f.empty? || f == 'raw'
    if DATE_TRUNC_UNITS.key?(f)
      return %[DateTrunc("#{DATE_TRUNC_UNITS[f]}", #{col_ref})]
    end
    case f
    when 'day_of_month'
      "Day(#{col_ref})"
    when 'day_of_week_num'
      "Weekday(#{col_ref})"
    when 'day_of_week_name'
      %[DateFormat(#{col_ref}, "%A")]
    when 'day_of_year'
      "DayOfYear(#{col_ref})"
    when 'hour_of_day'
      "Hour(#{col_ref})"
    when 'month_num'
      "Month(#{col_ref})"
    when 'month_name'
      %[DateFormat(#{col_ref}, "%B")]
    when 'quarter_of_year'
      "Quarter(#{col_ref})"
    else
      %[DateTrunc("#{f}", #{col_ref})]
    end
  end

  def sigma_literal(val)
    case val
    when Numeric
      val.to_s
    when true
      'True'
    when false
      'False'
    when nil
      'Null'
    else
      s = val.to_s
      if s =~ /\A-?\d+(\.\d+)?\z/
        s
      else
        %("#{s.gsub('"', '\"')}")
      end
    end
  end

  # Compile Omni dimension `groups:` parameter into a Sigma `If(...)` expression.
  def groups_formula(spec, base_ref)
    groups = spec.is_a?(Hash) ? spec['groups'] : nil
    return nil unless groups.is_a?(Array) && !groups.empty?

    args = []
    groups.each do |grp|
      next unless grp.is_a?(Hash)
      name = grp['name'].to_s
      flt = grp['filter'].is_a?(Hash) ? grp['filter'] : {}
      vals = Array(flt['is'])
      next if vals.empty? || name.empty?
      cond = if vals.length == 1
               "#{base_ref} = #{sigma_literal(vals.first)}"
             else
               "In(#{base_ref}, #{vals.map { |v| sigma_literal(v) }.join(', ')})"
             end
      args << cond
      args << sigma_literal(name)
    end
    return nil if args.empty?

    fallback = if spec['else_raw_value'] == true
                 base_ref
               elsif !spec['else'].to_s.empty?
                 sigma_literal(spec['else'].to_s)
               else
                 sigma_literal('Other')
               end
    args << fallback
    "If(#{args.join(', ')})"
  end

  # Compile Omni dimension `bin_boundaries:` parameter into a Sigma `If(...)` expression.
  def bins_formula(spec, base_ref)
    bounds = spec.is_a?(Hash) ? spec['bin_boundaries'] : nil
    return nil unless bounds.is_a?(Array) && !bounds.empty?
    nums = bounds.map { |b| b.is_a?(Numeric) ? b : Float(b.to_s) rescue nil }.compact.sort
    return nil if nums.empty?

    args = []
    nums.each_with_index do |b, idx|
      label = if idx.zero?
                "< #{b}"
              else
                ">= #{nums[idx - 1]} and < #{b}"
              end
      args << "#{base_ref} < #{b}"
      args << sigma_literal(label)
    end
    args << sigma_literal("#{nums.last} and above")
    "If(#{args.join(', ')})"
  end

  # resolver.call(view, field) => Sigma ref string including brackets, or nil.
  def translate_expr(sql, resolver, default_view: nil)
    reason = untranslatable?(sql)
    return [nil, reason] if reason
    out = sql.to_s.strip
    return [nil, 'empty sql expression'] if out.empty?

    # Resolve ${view.field[timeframe]} and ${view.field}
    out = out.gsub(/\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)(?:\[([A-Za-z0-9_]+)\])?\}/) do
      v = $1
      f = $2
      frame = $3
      ref = resolver.call(v, f)
      return [nil, "unresolved field ${#{v}.#{f}}"] if ref.nil?
      frame ? timeframe_formula(frame, ref) : ref
    end

    # Resolve intra-view ${field[timeframe]} or ${field} when default_view is known
    if default_view
      out = out.gsub(/\$\{([A-Za-z0-9_]+)(?:\[([A-Za-z0-9_]+)\])?\}/) do
        f = $1
        frame = $2
        ref = resolver.call(default_view, f)
        return [nil, "unresolved field ${#{f}}"] if ref.nil?
        frame ? timeframe_formula(frame, ref) : ref
      end
    end

    # Postgres / Snowflake ::type cast syntax on bracketed refs or expressions
    out = strip_sql_casts(out)

    # Translate SQL CASE WHEN ... THEN ... ELSE ... END
    if out =~ /\A\s*CASE\b/im && out =~ /\bEND\s*\z/im
      translated_case = translate_case_when(out)
      out = translated_case if translated_case
    end

    out = translate_sql_functions(out)

    # IS NOT NULL / IS NULL on bracketed refs
    out = out.gsub(/(\[[^\]]+\])\s+IS\s+NOT\s+NULL\b/i, 'IsNotNull(\1)')
    out = out.gsub(/(\[[^\]]+\])\s+IS\s+NULL\b/i, 'IsNull(\1)')

    out = out.gsub(/'([^']*)'/, '"\1"')
    [out, nil]
  end

  def strip_sql_casts(sql)
    out = sql.to_s.dup
    out.gsub!(/(\[[^\]]+\])::(string|varchar|text)\b/i, 'Text(\1)')
    out.gsub!(/(\[[^\]]+\])::(number|numeric|decimal|float|int|integer|bigint)\b/i, 'Number(\1)')
    out.gsub!(/(\[[^\]]+\])::(date|timestamp|datetime)\b/i, 'Date(\1)')
    out.gsub!(/(\[[^\]]+\])::(bool|boolean)\b/i, 'Logical(\1)')
    out.gsub!(/::(float|numeric|decimal|int|integer|bigint|varchar|text|string|date|timestamp)\b/i, '')
    out
  end

  def translate_sql_functions(sql)
    out = sql.to_s.dup
    out.gsub!(/\bCONCAT\s*\(/i, 'Concat(')
    out.gsub!(/\bCOALESCE\s*\(/i, 'Coalesce(')
    out.gsub!(/\bnullif\s*\(/i, 'NullIf(')
    out.gsub!(/\bLOWER\s*\(/i, 'Lower(')
    out.gsub!(/\bUPPER\s*\(/i, 'Upper(')
    out.gsub!(/\bTRIM\s*\(/i, 'Trim(')
    out.gsub!(/\bROUND\s*\(/i, 'Round(')
    out.gsub!(/\bFLOOR\s*\(/i, 'Floor(')
    out.gsub!(/\bCEIL(?:ING)?\s*\(/i, 'Ceil(')
    out.gsub!(/\bABS\s*\(/i, 'Abs(')
    out.gsub!(/\bLEN(?:GTH)?\s*\(/i, 'Len(')
    out.gsub!(/\bSUBSTR(?:ING)?\s*\(/i, 'Substring(')
    out.gsub!(/\bDATE_?DIFF\s*\(/i, 'DateDiff(')
    out.gsub!(/\bDATE_TRUNC\s*\(/i, 'DateTrunc(')
    out
  end

  def translate_case_when(sql)
    body = sql.strip.sub(/\A\s*CASE\s+/im, '').sub(/\s+END\s*\z/im, '').strip
    else_part = 'Null'
    if body =~ /\s+ELSE\s+(.+)\z/im
      else_part = $1.strip
      body = body[0...$~.begin(0)].strip
    end
    clauses = body.split(/\bWHEN\b/i).map(&:strip).reject(&:empty?)
    return nil if clauses.empty?

    args = []
    clauses.each do |clause|
      m = clause.match(/\A(.+?)\s+THEN\s+(.+)\z/im)
      return nil unless m
      cond = normalize_sql_condition(m[1].strip)
      val = m[2].strip
      args << cond
      args << val
    end
    args << else_part
    "If(#{args.join(', ')})"
  end

  def normalize_sql_condition(cond)
    c = cond.dup
    c.gsub!(/\s+AND\s+/i, ' and ')
    c.gsub!(/\s+OR\s+/i, ' or ')
    c.gsub!(/<>/) { '!=' }
    c
  end

  # Translate Omni measure `filters:` hash into a Sigma predicate string.
  def filter_predicate(filters, view_name, local_display)
    return [nil, nil] unless filters.is_a?(Hash) && !filters.empty?

    clauses = []
    filters.each do |raw_field, cond_spec|
      field_str = raw_field.to_s
      v, f = if field_str.include?('.')
               field_str.split('.', 2)
             else
               [view_name, field_str]
             end
      disp = local_display.arity == 2 ? local_display.call(v, f) : local_display.call(f)
      return [nil, "unresolved filter field #{field_str}"] if disp.nil?
      col_ref = "[#{disp}]"

      unless cond_spec.is_a?(Hash)
        clauses << "#{col_ref} = #{sigma_literal(cond_spec)}"
        next
      end

      cond_spec.each do |op, val|
        next if op.to_s == 'case_insensitive'
        case op.to_s
        when 'is'
          if val.is_a?(Array)
            return [nil, "empty is: array on #{field_str}"] if val.empty?
            clauses << if val.length == 1
                         "#{col_ref} = #{sigma_literal(val.first)}"
                       else
                         "In(#{col_ref}, #{val.map { |x| sigma_literal(x) }.join(', ')})"
                       end
          elsif val.nil?
            clauses << "IsNull(#{col_ref})"
          else
            clauses << "#{col_ref} = #{sigma_literal(val)}"
          end
        when 'not', 'is_not'
          if val.is_a?(Array)
            return [nil, "empty not: array on #{field_str}"] if val.empty?
            clauses << if val.length == 1
                         "#{col_ref} != #{sigma_literal(val.first)}"
                       else
                         "not In(#{col_ref}, #{val.map { |x| sigma_literal(x) }.join(', ')})"
                       end
          elsif val.nil?
            clauses << "IsNotNull(#{col_ref})"
          else
            clauses << "#{col_ref} != #{sigma_literal(val)}"
          end
        when 'greater_than'
          clauses << "#{col_ref} > #{sigma_literal(val)}"
        when 'greater_than_or_equal_to'
          clauses << "#{col_ref} >= #{sigma_literal(val)}"
        when 'less_than'
          clauses << "#{col_ref} < #{sigma_literal(val)}"
        when 'less_than_or_equal_to'
          clauses << "#{col_ref} <= #{sigma_literal(val)}"
        when 'between'
          arr = Array(val)
          return [nil, "between filter on #{field_str} needs 2 bounds"] unless arr.length == 2
          clauses << "Between(#{col_ref}, #{sigma_literal(arr[0])}, #{sigma_literal(arr[1])})"
        when 'contains'
          clauses << "Contains(#{col_ref}, #{sigma_literal(val)})"
        when 'not_contains'
          clauses << "not Contains(#{col_ref}, #{sigma_literal(val)})"
        when 'starts_with'
          clauses << "StartsWith(#{col_ref}, #{sigma_literal(val)})"
        when 'not_starts_with'
          clauses << "not StartsWith(#{col_ref}, #{sigma_literal(val)})"
        when 'ends_with'
          clauses << "EndsWith(#{col_ref}, #{sigma_literal(val)})"
        when 'not_ends_with'
          clauses << "not EndsWith(#{col_ref}, #{sigma_literal(val)})"
        when 'is_empty'
          clauses << "(IsNull(#{col_ref}) or #{col_ref} = \"\")"
        when 'not_is_empty'
          clauses << "(IsNotNull(#{col_ref}) and #{col_ref} != \"\")"
        when 'null', 'is_null'
          clauses << (val == false ? "IsNotNull(#{col_ref})" : "IsNull(#{col_ref})")
        when 'not_null', 'is_not_null'
          clauses << (val == false ? "IsNull(#{col_ref})" : "IsNotNull(#{col_ref})")
        else
          return [nil, "unsupported measure filter operator #{op}"]
        end
      end
    end
    [clauses.join(' and '), nil]
  end

  def aggregate_formula(measure, _view_name, local_display)
    agg = measure['aggregate_type'].to_s.downcase.strip
    sql = measure['sql'].to_s.strip
    reason = untranslatable?(sql)
    return [nil, reason] if reason

    # Support inline SQL aggregates when aggregate_type is omitted, e.g. AVG(${orders.sale_price})
    if agg.empty? && sql =~ /\A(SUM|AVG|AVERAGE|MIN|MAX|MEDIAN|COUNT)\s*\(\s*(DISTINCT\s+)?\$\{(?:[A-Za-z0-9_]+\.)?([A-Za-z0-9_]+)\}\s*\)\z/i
      sql_fn = $1.downcase
      is_distinct = !$2.nil?
      agg = is_distinct && sql_fn == 'count' ? 'count_distinct' : sql_fn
      sql = "${#{$3}}"
    end

    if agg == 'percentile' || agg == 'percentile_distinct_on'
      pct = measure['percentile']
      return [nil, 'percentile measure missing percentile parameter'] if pct.nil?
      p_val = (Float(pct.to_s) / 100.0).round(4)
      ref = extract_field_ref(sql)
      disp = local_display.call(ref || sql)
      return [nil, "measure sql #{sql.inspect} is not a single field ref"] if disp.nil?
      if measure['filters'].is_a?(Hash) && !measure['filters'].empty?
        pred, ferr = filter_predicate(measure['filters'], _view_name, local_display)
        return [nil, ferr] if ferr
        return ["PercentileCont(If(#{pred}, [#{disp}]), #{p_val})", nil]
      end
      return ["PercentileCont([#{disp}], #{p_val})", nil]
    end

    fn = AGG[agg]
    return [nil, "aggregate_type #{agg.inspect} is not mapped"] if !agg.empty? && fn.nil?
    return [nil, 'measure has no aggregate_type'] if agg.empty?

    has_filters = measure['filters'].is_a?(Hash) && !measure['filters'].empty?
    pred = nil
    if has_filters
      pred, ferr = filter_predicate(measure['filters'], _view_name, local_display)
      return [nil, ferr] if ferr
    end

    if agg == 'count' && (sql.empty? || sql =~ /\Acount\s*\(\s*\*\s*\)\z/i)
      return ["CountIf(#{pred})", nil] if pred
      return ['Count()', nil]
    end

    if fn && !sql.empty?
      ref = extract_field_ref(sql)
      disp = local_display.call(ref || sql)
      return [nil, "measure sql #{sql.inspect} is not a single field ref"] if disp.nil?
      if pred
        cond_fn = COND_AGG[fn]
        if cond_fn == 'CountIf'
          return ["CountIf(IsNotNull([#{disp}]) and (#{pred}))", nil]
        elsif cond_fn
          return ["#{cond_fn}([#{disp}], #{pred})", nil]
        else
          return ["#{fn}(If(#{pred}, [#{disp}]))", nil]
        end
      end
      return ["#{fn}([#{disp}])", nil]
    end

    if fn && sql.empty?
      return ["CountIf(#{pred})", nil] if pred && fn == 'Count'
      return ["#{fn}()", nil]
    end

    [nil, 'measure has no aggregate_type']
  end

  def extract_field_ref(sql)
    sql[/\$\{(?:[A-Za-z0-9_]+\.)?([A-Za-z0-9_]+)\}/, 1]
  end
end
