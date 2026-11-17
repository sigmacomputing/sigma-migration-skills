# frozen_string_literal: true
#
# PbiTimeIntelGen -- builds the Sigma form of each class C (time-intelligence) Power BI measure for the
# opt-in `--model-shape pbi` mode (spec: "Time intelligence (class C), built automatically").
#
# Three forms, all probe-proven (corpus/powerbi/pbi-shaped-model/probes/LOG.md):
#   metric       P8a   as-of anchored YTD/QTD/MTD: a SumIf/CountIf metric on the fact element. The fact
#                      gets the date through a Lookup chain on its active date relationship and the as-of
#                      date through a constant-key Lookup (`One = 1` on both elements, no relationship).
#   grouped      P8b/  axis anchored YTD/QTD/MTD/PY/PP: a grouped child of the fact, one per
#                P15/  (fact, grain, reset period). Outer level = the reset period (Year for YTD), inner
#                P16   level = the grain, calculations at the inner level. The base value is read from the
#                      parent metric as [Metrics/<measure>] (a bare [<measure>] errors at query time).
#   rolling_sql  P8c   rolling N days: Custom SQL over a DENSE day spine (the date table), LEFT JOIN the
#                      fact's daily aggregate, SUM(...) OVER (ROWS BETWEEN N-1 PRECEDING AND CURRENT ROW).
#                      MovingSum counts rows, not days, and is never emitted.
#
# Only Sum or Count of a row expression is a buildable base. Everything else, and every window the probes
# did not prove exact, is reclassified D (`reclassified`, reason "C form not buildable: <why>").
# Reuses PbiShapedModel (lookup_chain!, path_to_table, the DAX row parser); duplicates none of it.
require 'set'
require_relative 'pbi_shaped_model'

module PbiTimeIntelGen
  module_function

  S = PbiShapedModel

  class Unbuildable < StandardError; end
  # The slicer fields cannot be carried on a grouped element: its measures go to class D and the page gets the
  # live element (R54). The message is the whole reason (no "C form not buildable" prefix).
  class NeedsLive < Unbuildable; end
  NEEDS_LIVE = 'slicer fields exceed carry size; needs a live summary'
  # The Date table has periods (trailing, or gaps) with no fact rows: Power BI shows them on a chart (TOTALYTD stays flat, a
  # prior-year read shows months whose prior-year month had sales) and a grouped element, which has rows only for periods
  # with fact rows, cannot. The probe result is {fact => {grain => {'sparse','expected','present'}}} (PbiShapeRun.density_plan).
  class SparseTime < NeedsLive; end
  def sparse_time_reason(fact, grain, density)
    missing = density['expected'].to_i - density['present'].to_i
    "the Date table has #{grain} periods with no #{fact} rows (#{missing} of #{density['expected']}; trailing or gaps); " \
      'a grouped element cannot show them - needs a page summary over the Date table'
  end
  # m12: DateLookback at day grain was never probed in Sigma (the Feb 29 check compared DAX with warehouse DATEADD only)
  DAY_PRIOR = 'day-grain prior period not probed'
  SPARSE = 'slicer fields are not dense over the periods (a carried value lacks some periods); needs a live summary'

  # Array of {'measure' => "Table.Measure", 'form' => 'metric'|'grouped'|'rolling_sql', 'element', 'column'}
  # (grouped entries add 'consumer_agg' => 'Max'), plus `reclassified` ([{'key','reason'}]).
  class GenResult < Array
    attr_reader :reclassified

    def initialize
      super()
      @reclassified = []
    end
  end

  DIALECTS = %w[snowflake databricks bigquery sqlite].freeze
  GRAIN_UNITS = %w[day month quarter year].freeze
  UNIT_RANK = { 'day' => 0, 'week' => 1, 'month' => 2, 'quarter' => 3, 'year' => 4 }.freeze
  RESET_UNIT = { 'ytd' => 'year', 'qtd' => 'quarter', 'mtd' => 'month' }.freeze
  RESET_ORDER = ['year', nil, 'quarter', 'month'].freeze # sort order of the groups
  INT_LEVELS = [%w[year Year], %w[quarter Quarter], %w[month Month]].freeze
  AS_OF_PATTERNS = %w[ytd qtd mtd].freeze
  TI_FUNCTION = /\b(?:TOTAL(?:YTD|QTD|MTD)|DATES(?:YTD|QTD|MTD|INPERIOD|BETWEEN)|SAMEPERIODLASTYEAR|DATEADD|
                  PARALLELPERIOD|PREVIOUS(?:YEAR|QUARTER|MONTH))\s*\(/xi.freeze

  # ---------------------------------------------------------------------------------------
  # Rolling SQL
  # ---------------------------------------------------------------------------------------

  # The Custom SQL for a rolling N-day window over a dense day spine.
  #   fact_sql / date_sql  SELECT statements (the fact's and the date table's own SQL)
  #   measure_sql          one aggregate over the fact (alias `f`), e.g. SUM(f."QTY"), or {alias => aggregate}
  #   fact_key / date_key  the join columns (fact -> date table); date_col is the calendar day column
  # The spine is the whole date table, so the window starts at the beginning of its history, and a day with
  # no fact rows contributes 0 (COALESCE) instead of being skipped (which is what MovingSum would do).
  #   carry     optional [{'name' =>, 'expr' => SQL over the fact alias f, 'join' => {'sql','alias','on'}}]: slicer
  #             fields carried as columns. They go through GROUP BY and PARTITION BY, over the dense day spine
  #             CROSS JOINed with the distinct carried combinations, so every (combination, day) has a row (the
  #             consumer reads them with Sum; a missing row would drop a carry-forward). Nulls compare equal.
  #   hook      optional fact name: adds `WHERE 1 = 1 /*@slicers fact="<hook>" alias="f"*/` to the daily scan, where
  #             PbiSlicerCarry.live_sql injects the live element's predicates (on fact rows, before the window).
  #   filters   optional SQL predicates on the fact alias f (report filters, C2): `AND <predicate>` lines of the daily scan's
  #             WHERE, before the hook, so the window sums only the rows Power BI's filter context keeps.
  def rolling_sql(fact_sql:, date_sql:, measure_sql:, days:, dialect:, fact_key: 'DATE_KEY', date_key: 'DATE_KEY',
                  date_col: 'CAL_DATE', carry: [], hook: nil, filters: [])
    dialect = dialect.to_s.downcase
    raise ArgumentError, "unsupported dialect #{dialect}" unless DIALECTS.include?(dialect)
    raise ArgumentError, 'days must be a positive integer' unless days.is_a?(Integer) && days >= 1
    measures = measure_sql.is_a?(Hash) ? measure_sql : { 'VALUE' => measure_sql }
    carry = Array(carry)
    q = ->(name) { S.quote_ident(name, dialect) }
    strip = ->(sql) { sql.to_s.strip.sub(/;+\s*\z/, '').rstrip }
    daily = measures.map { |a, sql| "#{sql} AS #{q.call(a)}" }.join(', ')
    part = carry.empty? ? '' : "PARTITION BY #{carry.map { |c| "spine.#{q.call(c['name'])}" }.join(', ')} "
    # m5: a window with no rows at all (no day with a value) is blank in DAX, not 0: COUNT of the day values is 0 there
    windows = measures.keys.map do |a|
      over = "OVER (#{part}ORDER BY spine.#{q.call(date_col)} ROWS BETWEEN #{days - 1} PRECEDING AND CURRENT ROW)"
      "CASE WHEN COUNT(daily.#{q.call(a)}) #{over} = 0 THEN NULL ELSE SUM(COALESCE(daily.#{q.call(a)}, 0)) #{over} END AS #{q.call(a)}"
    end
    joins = carry.map { |c| c['join'] }.compact.uniq.map { |j| " LEFT JOIN (\n#{strip.call(j['sql'])}\n) #{j['alias']} ON #{j['on']}" }.join
    preds = Array(filters).map { |f| "\n    AND #{f}" }.join
    where = hook ? ["  WHERE 1 = 1#{preds} /*@slicers fact=\"#{hook.to_s.delete('"')}\" alias=\"f\"*/"] : (preds.empty? ? [] : ["  WHERE 1 = 1#{preds}"])
    lines = ['WITH pbi_fact AS (', strip.call(fact_sql), '), pbi_dates AS (', strip.call(date_sql)]
    unless carry.empty?
      lines += ['), pbi_combos AS (',
                "  SELECT DISTINCT #{carry.map { |c| "#{c['expr']} AS #{q.call(c['name'])}" }.join(', ')}",
                "  FROM pbi_fact f#{joins}"]
    end
    gcols = ["dd.#{q.call(date_col)}"] + carry.map { |c| c['expr'] }
    sel = ["dd.#{q.call(date_col)} AS #{q.call('DAY')}"] + carry.map { |c| "#{c['expr']} AS #{q.call(c['name'])}" } + [daily]
    lines += ['), pbi_daily AS (', "  SELECT #{sel.join(', ')}",
              "  FROM pbi_fact f JOIN pbi_dates dd ON dd.#{q.call(date_key)} = f.#{q.call(fact_key)}#{joins}"]
    lines += where
    lines += ["  GROUP BY #{gcols.join(', ')}", ')']
    if carry.empty?
      lines += ["SELECT spine.#{q.call(date_col)} AS #{q.call('DAY')}, #{windows.join(', ')}",
                "FROM pbi_dates spine LEFT JOIN pbi_daily daily ON daily.#{q.call('DAY')} = spine.#{q.call(date_col)}"]
    else
      on = carry.map { |c| n = q.call(c['name']); "(daily.#{n} = spine.#{n} OR (daily.#{n} IS NULL AND spine.#{n} IS NULL))" }
      lines += ["SELECT spine.#{q.call(date_col)} AS #{q.call('DAY')}, #{carry.map { |c| "spine.#{q.call(c['name'])} AS #{q.call(c['name'])}" }.join(', ')}, #{windows.join(', ')}",
                "FROM (SELECT d.#{q.call(date_col)}, #{carry.map { |c| "c.#{q.call(c['name'])}" }.join(', ')} FROM pbi_dates d CROSS JOIN pbi_combos c) spine",
                "LEFT JOIN pbi_daily daily ON daily.#{q.call('DAY')} = spine.#{q.call(date_col)} AND #{on.join(' AND ')}"]
    end
    lines.join("\n")
  end

  # ---------------------------------------------------------------------------------------
  # generate!
  # ---------------------------------------------------------------------------------------

  # Build the Sigma form of every class C measure in `ti_measures` (an Array of class entries, each with a
  # 'key' => "Table.Measure", or the classes Hash {key => entry}; entries need 'ti' and 'home'). Mutates
  # `dm_model`. Entries that cannot be built exactly are set to class D in place and listed in
  # `reclassified`.
  #   date_element  the date table's element name, or {'element' =>, 'column' =>}
  #   grains        {"Table.Measure" => 'day'|'month'|'quarter'|'year'}, default 'month' (axis forms only)
  #   as_of_element the "data as of" element (default "As Of") and its date column (default: first date)
  #   tmsl          optional; supplies each measure's DAX so wrappers like YoY % and PREVIOUSYEAR (whole
  #                 period, exact only at the matching grain) are recognised. An entry's own 'expression' wins.
  #   extra_measures {"<fact>" => {"<grain>" => ["A metric name", ...]}}: A metrics a chart at that grain also
  #                 shows, read into the grouped element from the parent metric (P16).
  #   slicer_carry  {"<fact element name>" => {'columns' => [{'name' =>, 'formula' => "[<fact>/<path>/<col>]" (grouped),
  #                 'sql' => {'name','expr','join'} (rolling)}], 'live' => bool, 'dense' => bool|nil}}: the carry
  #                 decision for a fact (PbiSlicerCarry.decide), applied here (R19, R55):
  #       grouped   the carried columns become OUTER grouping levels before the reset level (probe P15: only the
  #                 outermost position filters the precomputed values) and records read with consumer_agg 'Sum';
  #                 only additive columns are summed, so YoY % is carried as numerator and denominator columns
  #                 and divided in the consumer. `live` or `dense == false` (a gap in carried value x period drops a
  #                 carry-forward under Sum) means it cannot carry: the measures are reclassified D.
  #       rolling   the carried columns go through GROUP BY and PARTITION BY over a dense spine x the distinct
  #                 combinations; a `live` decision still carries the subset it lists (the live element covers the rest)
  #   report_filters PbiShapedModel.report_filters! `applied` entries: a rolling window carries the same filters as the fact (C2).
  #   time_density  {"<fact element name>" => {"<grain>" => {'sparse' => bool, 'expected' =>, 'present' =>}}}: the time-axis
  #                 density probe (PbiShapeRun.density_plan). A sparse (fact, grain) cannot be a grouped element (SparseTime):
  #                 its grouped measures are reclassified D with the reason, for the page-summary route.
  def generate!(dm_model, ti_measures, date_element:, dialect:, grains: {}, as_of_element: 'As Of',
                as_of_column: nil, tmsl: nil, extra_measures: {}, slicer_carry: {}, time_density: {}, report_filters: [])
    raise ArgumentError, "unsupported dialect #{dialect}" unless DIALECTS.include?(dialect.to_s.downcase)
    out = GenResult.new
    ctxs = normalize(ti_measures, tmsl, grains)
    return out if ctxs.empty?
    date = date_config(dm_model, date_element)
    results = {}
    fail_ctx = lambda do |ctx, e|
      reason = e.is_a?(NeedsLive) ? e.message : "C form not buildable: #{e.message}"
      ctx[:entry]['class'] = 'D'
      ctx[:entry]['reason'] = reason
      out.reclassified << { 'key' => ctx[:key], 'reason' => reason }
    end

    plans = []
    ctxs.each do |ctx|
      begin
        plans << plan(dm_model, ctx, ctxs, date)
      rescue Unbuildable => e
        fail_ctx.call(ctx, e)
      end
    end

    plans.select { |p| p[:type] == :metric }.each do |p|
      begin
        results[p[:ctx][:index]] = [build_metric(dm_model, p, date, as_of_element, as_of_column)]
      rescue Unbuildable => e
        fail_ctx.call(p[:ctx], e)
      end
    end

    grouped_groups(plans).each do |(_fact_id, grain, reset), members|
      begin
        build_grouped(dm_model, members, grain, reset, date, extra_measures, results, slicer_carry || {}, time_density || {})
      rescue Unbuildable => e
        members.each { |p| fail_ctx.call(p[:ctx], e) }
      end
    end

    plans.select { |p| p[:type] == :rolling }.group_by { |p| [p[:fact]['id'], p[:days]] }.each_value do |members|
      begin
        build_rolling(dm_model, members, date, dialect.to_s.downcase, results, slicer_carry || {}, report_filters || [])
      rescue Unbuildable => e
        members.each { |p| fail_ctx.call(p[:ctx], e) }
      end
    end

    results.keys.sort.each { |i| results[i].each { |r| out << r } }
    out
  end

  # ---------------------------------------------------------------------------------------
  # Inputs
  # ---------------------------------------------------------------------------------------

  def normalize(ti_measures, tmsl, grains)
    pairs = if ti_measures.is_a?(Hash)
              ti_measures.to_a
            else
              Array(ti_measures).map { |e| [e['key'] || "#{e['table']}.#{e['measure']}", e] }
            end
    out = []
    pairs.each do |key, entry|
      next unless entry['ti'] && (entry['class'].nil? || entry['class'] == 'C')
      table, measure = key.split('.', 2)
      expr = entry['expression'] || measure_expression(tmsl, table, measure)
      out << { key: key, table: table, measure: measure, entry: entry, ti: entry['ti'], home: (entry['home'] || table).to_s,
               expr: expr, grain: (grains || {})[key] || 'month', index: out.length }
    end
    out
  end

  def measure_expression(tmsl, table, measure)
    return nil unless tmsl
    tm = S.tables_of(tmsl).find { |t| t['name'] == table }
    m = tm && Array(tm['measures']).find { |x| x['name'] == measure }
    return nil unless m
    expr = m['expression']
    (expr.is_a?(Array) ? expr.join("\n") : expr).to_s
  end

  def date_config(dm_model, date_element)
    name, col = if date_element.is_a?(Hash)
                  [date_element['element'] || date_element[:element], date_element['column'] || date_element[:column]]
                else
                  [date_element, nil]
                end
    el = S.elements_of(dm_model).find { |e| e['name'].to_s.casecmp(name.to_s).zero? }
    raise ArgumentError, "date element #{name.inspect} not found" unless el
    column = if col
               S.column_named(el, col)
             else
               S.column_named(el, 'Date') ||
                 Array(el['columns']).find { |c| S.display_name(c).to_s =~ /date/i && S.display_name(c).to_s !~ /key/i }
             end
    raise ArgumentError, "date column of #{el['name']} not found" unless column
    { el: el, col: S.display_name(column) }
  end

  def find_fact(dm_model, home)
    S.elements_of(dm_model).find { |e| e['name'].to_s.casecmp(home.to_s).zero? }
  end

  # ---------------------------------------------------------------------------------------
  # Planning: validate one measure and decide its form
  # ---------------------------------------------------------------------------------------

  def plan(dm_model, ctx, ctxs, date)
    ti = ctx[:ti]
    fact = find_fact(dm_model, ctx[:home])
    raise Unbuildable, "fact element #{ctx[:home]} not found" unless fact
    if ti['date_table'] && !ti['date_table'].to_s.casecmp(date[:el]['name'].to_s).zero?
      raise Unbuildable, "the measure uses date table #{ti['date_table']}, not #{date[:el]['name']}"
    end
    pattern = ti['pattern']
    if ctx[:expr]
      bad = year_end_or_filter_arg(ctx[:expr])
      raise Unbuildable, "#{bad} carries a year-end or filter argument, which changes the window" if bad
    elsif %w[py pp].include?(pattern) && ti['anchor'] != 'as_of'
      raise Unbuildable, 'needs the DAX expression to tell PY from a derived ratio'
    end
    agg, row = base_aggregate(dm_model, fact, ti, ctx[:home])
    base = { ctx: ctx, fact: fact, agg: agg, row: row, pattern: pattern }
    derived = ctx[:expr] && ctx[:expr] !~ TI_FUNCTION
    if derived
      raise Unbuildable, 'a derived time-intelligence measure is only built for YoY %' unless pattern == 'py'
      raise Unbuildable, 'a derived YoY % needs the axis anchor' unless ti['anchor'] == 'axis'
      yoy_grain = axis_grain!(ctx, 'py', ti)
      raise Unbuildable, DAY_PRIOR if yoy_grain == 'day'
      return base.merge(type: :grouped, kind: 'yoy', yoy_of: yoy_partner(ctx, ctxs), grain: yoy_grain, reset: nil)
    end
    if ti['anchor'] == 'as_of'
      unless AS_OF_PATTERNS.include?(pattern)
        raise Unbuildable, "an as-of #{pattern} has no probe-proven form (only YTD, QTD and MTD)"
      end
      return base.merge(type: :metric, unit: RESET_UNIT[pattern])
    end
    case pattern
    when 'rolling'
      days = ti['days']
      raise Unbuildable, 'rolling window has no day count' unless days.is_a?(Integer) && days >= 1
      base.merge(type: :rolling, days: days)
    when 'ytd', 'qtd', 'mtd'
      grain = axis_grain!(ctx, pattern, ti)
      if UNIT_RANK[RESET_UNIT[pattern]] < UNIT_RANK[grain]
        raise Unbuildable, "#{pattern.upcase} at #{grain} grain is the value at the end of the #{RESET_UNIT[pattern]} " \
                           "reset period, which a grouped element does not express"
      end
      base.merge(type: :grouped, kind: pattern, grain: grain, reset: RESET_UNIT[pattern])
    when 'py', 'pp'
      grain = axis_grain!(ctx, pattern, ti)
      raise Unbuildable, DAY_PRIOR if grain == 'day'
      unit = pattern == 'py' ? 'year' : ti['unit']
      raise Unbuildable, 'prior period has no unit' unless %w[year quarter month].include?(unit)
      if UNIT_RANK[unit] < UNIT_RANK[grain]
        raise Unbuildable, "a #{unit} shift at #{grain} grain is not a whole-period lookback"
      end
      whole = ctx[:expr].to_s[/\b(PREVIOUS(?:YEAR|QUARTER|MONTH)|PARALLELPERIOD)\s*\(/i, 1]
      if whole && grain != unit
        raise Unbuildable, "#{whole.upcase} returns the whole previous #{unit}, which equals a lookback only at #{unit} grain"
      end
      base.merge(type: :grouped, kind: pattern, unit: unit, grain: grain, reset: nil)
    else
      raise Unbuildable, "pattern #{pattern.inspect} is not built"
    end
  end

  # Name of the first TOTALYTD/QTD/MTD (more than 2 arguments) or DATESYTD/QTD/MTD (more than 1) call in
  # `expr`, else nil. A year-end or a filter argument changes the window, so the plain form is not exact.
  def year_end_or_filter_arg(expr)
    expr.to_s.scan(/\b(TOTAL(?:YTD|QTD|MTD)|DATES(?:YTD|QTD|MTD))\s*\(/i) do
      fn = Regexp.last_match(1).upcase
      rest = Regexp.last_match.post_match
      depth = 1
      quote = nil
      inner = +''
      rest.each_char do |ch|
        if quote
          quote = nil if ch == quote
        elsif ch == '"' || ch == "'" then quote = ch
        elsif ch == '(' then depth += 1
        elsif ch == ')'
          depth -= 1
          break if depth.zero?
        end
        inner << ch
      end
      max = fn.start_with?('TOTAL') ? 2 : 1
      return fn if S.split_top_level(inner).length > max
    end
    nil
  end

  def axis_grain!(ctx, _pattern, _ti)
    grain = ctx[:grain].to_s
    unless GRAIN_UNITS.include?(grain)
      raise Unbuildable, "grain #{grain} is not supported (weeks do not nest in months or years)" if grain == 'week'
      raise Unbuildable, "unknown grain #{grain}"
    end
    grain
  end

  # `DIVIDE([X] - [Y], [Y])` or `([X] - [Y]) / [Y]` where [Y] is a py measure of the same base.
  def yoy_partner(ctx, ctxs)
    expr = ctx[:expr].to_s.strip
    names = nil
    if (call = S.whole_call(expr)) && call[0] == 'DIVIDE'
      args = S.split_top_level(call[1])
      raise Unbuildable, 'YoY % with an alternate result is not built' unless args.length == 2
      names = yoy_names(args[0], args[1])
    elsif (m = expr.match(/\A\(?\s*(.+?)\s*\)?\s*\/\s*(\[[^\]]+\])\z/m))
      names = yoy_names(m[1], m[2])
    end
    raise Unbuildable, 'derived measure is not a recognised YoY % (([base] - [PY]) / [PY])' unless names
    base_name, py_name = names
    unless ctx[:ti]['base'] && ctx[:ti]['base'].casecmp(base_name).zero?
      raise Unbuildable, "YoY % numerator [#{base_name}] is not the time-intelligence base"
    end
    other = ctxs.find { |c| c[:table] == ctx[:table] && c[:measure].casecmp(py_name).zero? }
    unless other && other[:ti]['pattern'] == 'py' && other[:ti]['anchor'] == 'axis' && other[:ti]['base'] == ctx[:ti]['base']
      raise Unbuildable, "[#{py_name}] is not a prior-year measure of [#{base_name}]"
    end
    other
  end

  def yoy_names(num, den)
    n = num.strip.sub(/\A\((.*)\)\z/m, '\1').strip.match(/\A\[([^\]]+)\]\s*-\s*\[([^\]]+)\]\z/)
    d = den.strip.sub(/\A\((.*)\)\z/m, '\1').strip.match(/\A\[([^\]]+)\]\z/)
    return nil unless n && d && n[2].casecmp(d[1]).zero?
    [n[1], n[2]]
  end

  # [aggregate ('Sum'|'Count'), Sigma row expression over the fact's own columns] for the measure's base.
  def base_aggregate(dm_model, fact, ti, home)
    by_id = S.by_id_map(dm_model)
    begin
      if ti['base']
        metric = Array(fact['metrics']).find { |m| m['name'] == ti['base'] }
        raise Unbuildable, "base measure [#{ti['base']}] has no Sigma metric on #{fact['name']}" unless metric
        agg = S.single_aggregate(metric['formula'])
        unless agg && %w[Sum Count].include?(agg[0])
          raise Unbuildable, "base [#{ti['base']}] is not a Sum or Count of a row expression"
        end
      else
        top = S.whole_call(ti['base_expr'].to_s.strip)
        raise Unbuildable, 'the base is not a single aggregate' unless top
        fn, inner = top
        if S::ITERATOR_AGG.key?(fn)
          args = S.split_top_level(inner)
          raise Unbuildable, "#{fn} does not iterate #{home}" unless args.length == 2 && args[0].delete("'").strip.casecmp(home).zero?
          agg = [S::ITERATOR_AGG[fn], S.translate_row(args[1], fact, home, by_id, [])]
        elsif S::PLAIN_AGG.key?(fn)
          agg = [S::PLAIN_AGG[fn], S.translate_row(inner, fact, home, by_id, [])]
        else
          raise Unbuildable, "#{fn} is not a Sum or Count of a row expression"
        end
        raise Unbuildable, "inline #{agg[0]} is not a Sum or Count of a row expression" unless %w[Sum Count].include?(agg[0])
      end
    rescue S::NotTranslatable => e
      raise Unbuildable, e.message
    end
    row = agg[1].to_s.strip.gsub(/Coalesce\((\[[^\]]*\]),\s*0\)/, '\1') # R51: the pbi-mode metric is coalesced; the forms re-apply the rule
    raise Unbuildable, 'blank arithmetic with division' if S.division_arith?(row)
    if agg[0] == 'Count' && S.binary_arith?(row) && row.scan(/\[[^\]]*\]/).length >= 2
      raise Unbuildable, 'blank arithmetic in a non-sum iterator'
    end
    names = row.scan(/\[([^\]]*)\]/).flatten
    residue = row.gsub(/\[[^\]]*\]/, '')
    unless !names.empty? && residue =~ %r{\A[\d\s.+\-*/()]*\z} && names.none? { |n| n.include?('/') }
      raise Unbuildable, "the base row expression (#{row[0, 40]}) is not arithmetic over the fact's own columns"
    end
    names.each { |n| raise Unbuildable, "column [#{n}] is not on #{fact['name']}" unless S.column_named(fact, n) }
    [agg[0], row]
  end

  def base_format(fact, ti)
    m = ti['base'] && Array(fact['metrics']).find { |x| x['name'] == ti['base'] }
    m && m['format']
  end

  # ---------------------------------------------------------------------------------------
  # Shared builders
  # ---------------------------------------------------------------------------------------

  def date_column!(dm_model, fact, date)
    path = S.path_to_table(dm_model, fact, date[:el]['name'])
    raise Unbuildable, "#{fact['name']} has no relationship path to #{date[:el]['name']}" unless path
    name, why = S.lookup_chain!(dm_model, fact, path, date[:col])
    raise Unbuildable, "date lookup failed: #{why}" unless name
    name
  end

  # A calc column with this formula on `el` (reused when one exists); returns its display name.
  def ensure_calc(dm_model, el, wanted, formula)
    existing = Array(el['columns']).find { |c| c['formula'] == formula }
    return S.display_name(existing) if existing
    name = S.unique_name(wanted, S.taken_names(el))
    col = { 'id' => S.next_id(dm_model, "#{el['id']}t"), 'name' => name, 'formula' => formula }
    el['columns'] = Array(el['columns']) + [col]
    el['order'] = Array(el['order']) + [col['id']] if el['order']
    name
  end

  def pbi_ref(ctx)
    "#{ctx[:table]}[#{ctx[:measure]}]"
  end

  def insert_after(dm_model, anchor, element)
    page = Array(dm_model['pages']).find { |pg| Array(pg['elements']).any? { |e| e.equal?(anchor) } }
    raise Unbuildable, "#{anchor['name']} is on no page" unless page
    page['elements'].insert(page['elements'].index { |e| e.equal?(anchor) } + 1, element)
  end

  # ---------------------------------------------------------------------------------------
  # (a) as-of metric
  # ---------------------------------------------------------------------------------------

  def build_metric(dm_model, p, date, as_of_name, as_of_column)
    ctx = p[:ctx]
    fact = p[:fact]
    as_of = S.elements_of(dm_model).find { |e| e['name'].to_s.casecmp(as_of_name.to_s).zero? }
    raise Unbuildable, "as-of element #{as_of_name} not found" unless as_of
    acol = as_of_column ? S.column_named(as_of, as_of_column) : Array(as_of['columns']).find { |c| S.display_name(c).to_s =~ /date/i }
    raise Unbuildable, "date column of #{as_of['name']} not found" unless acol
    dcol = date_column!(dm_model, fact, date)
    one_a = ensure_calc(dm_model, as_of, 'One', '1')
    one_f = ensure_calc(dm_model, fact, 'One', '1')
    as_of_date = ensure_calc(dm_model, fact, 'As Of Date',
                             "Lookup([#{as_of['name']}/#{S.display_name(acol)}], [#{one_f}], [#{as_of['name']}/#{one_a}])")
    cond = "[#{dcol}] >= DateTrunc(\"#{p[:unit]}\", [#{as_of_date}]) and [#{dcol}] <= [#{as_of_date}]"
    formula = p[:agg] == 'Count' ? "CountIf(#{cond} and Not(IsNull(#{p[:row]})))" : "SumIf(#{S.blank_safe_row(p[:row])}, #{cond})"
    existing = Array(fact['metrics']).find { |m| m['name'] == ctx[:measure] }
    if existing
      raise Unbuildable, "a metric named #{ctx[:measure]} already exists on #{fact['name']} with a different formula" unless existing['formula'] == formula
    else
      metric = { 'id' => S.next_id(dm_model, "#{fact['id']}m"), 'name' => ctx[:measure], 'formula' => formula,
                 'description' => "Reproduces Power BI measure #{pbi_ref(ctx)}: #{p[:pattern].upcase} anchored on " \
                                  "#{as_of['name']}[#{S.display_name(acol)}]." }
      fmt = base_format(fact, ctx[:ti])
      metric['format'] = fmt if fmt
      fact['metrics'] = Array(fact['metrics']) + [metric]
    end
    { 'measure' => ctx[:key], 'form' => 'metric', 'element' => fact['name'], 'column' => ctx[:measure] }
  end

  # ---------------------------------------------------------------------------------------
  # (b) grouped element
  # ---------------------------------------------------------------------------------------

  # {[fact id, grain, reset] => [plans]}. YTD/QTD/MTD need their own reset level; PY/PP/YoY ride on the first
  # group at that (fact, grain) in RESET_ORDER, or open a reset-free group.
  def grouped_groups(plans)
    groups = {}
    plans.select { |p| p[:type] == :grouped }.each do |p|
      key = [p[:fact]['id'], p[:grain], p[:reset]]
      (groups[key] ||= []) << p if p[:reset]
    end
    plans.select { |p| p[:type] == :grouped && p[:reset].nil? }.each do |p|
      # PY/PP/YoY ride on the year-reset group (the plain-named element) or open a reset-free one with the same name
      key = groups.key?([p[:fact]['id'], p[:grain], 'year']) ? [p[:fact]['id'], p[:grain], 'year'] : [p[:fact]['id'], p[:grain], nil]
      (groups[key] ||= []) << p
    end
    groups.sort_by { |(fid, grain, reset), _| [fid.to_s, grain, RESET_ORDER.index(reset)] }
  end

  # The name of the PREVIOUSYEAR/QUARTER/MONTH call in a DAX expression, else nil.
  def whole_previous?(expr)
    expr.to_s[/\b(PREVIOUS(?:YEAR|QUARTER|MONTH))\s*\(/i, 1]
  end

  def titlecase(unit)
    unit.capitalize
  end

  def build_grouped(dm_model, members, grain, reset, date, extra_measures, results, slicer_carry = {}, time_density = {})
    fact = members[0][:fact]
    dens = (time_density[fact['name']] || {})[grain]
    raise SparseTime, sparse_time_reason(fact['name'], grain, dens) if dens && dens['sparse']
    carry_cfg = slicer_carry[fact['name']] || {}
    carry_cols = Array(carry_cfg['columns'])
    if carry_cfg['live'] || (!carry_cols.empty? && carry_cfg['dense'] == false)
      raise NeedsLive, carry_cfg['live'] ? NEEDS_LIVE : SPARSE
    end
    carry_cols = [] if carry_cols.empty?
    carried = !carry_cols.empty?
    dcol = date_column!(dm_model, fact, date)
    fname = fact['name']
    date_ref = "[#{fname}/#{dcol}]"
    # named by reset unit, whichever measures are present: year (and reset-free) = plain, quarter/month suffixed
    name = %w[quarter month].include?(reset) ? "#{fname} by #{grain} (#{reset} reset)" : "#{fname} by #{grain}"

    el_id = S.next_id(dm_model, "#{fact['id']}g")
    cols = []
    add = lambda do |cname, formula, desc = nil, fmt = nil|
      c = { 'id' => "#{el_id}c#{cols.length}", 'name' => cname, 'formula' => formula }
      c['description'] = desc if desc
      c['format'] = fmt if fmt
      cols << c
      c['id']
    end
    carry_ids = carry_cols.map { |cc| add.call(cc['name'], cc['formula'], "Slicer field carried so a pick filters the pre-computed numbers (outermost level).") }
    reset_id = nil
    reset_id = add.call(titlecase(reset), "DateTrunc(\"#{reset}\", #{date_ref})") if reset && reset != grain
    grain_id = add.call(titlecase(grain), "DateTrunc(\"#{grain}\", #{date_ref})")
    grain_name = titlecase(grain)
    # I2: the integer Year / Quarter / Month Number fields of the date table equal Year()/Quarter()/Month() of the level
    # date; each is its own column here, a CALCULATION of the grain level (never a groupBy key: an extra key beside the
    # grain makes DateLookback(..., "year") find no prior-year row, so every PY reads NULL, live on Snowflake), and a
    # control on that field targets it. Only a unit at the grain or coarser exists.
    int_ids = INT_LEVELS.select { |unit, _| UNIT_RANK[unit] >= UNIT_RANK[grain] }.map do |unit, fn|
      add.call("#{titlecase(unit)} Number", "#{fn}([#{grain_name}])", "#{fn}() of #{grain_name}: the integer #{titlecase(unit)} number of the date table.")
    end
    calc_ids = []

    # base value columns (one per distinct base)
    base_cols = {}
    members.each do |p|
      ti = p[:ctx][:ti]
      bkey = ti['base'] || ti['base_expr']
      next if base_cols.key?(bkey)
      if ti['base']
        cname = ti['base']
        cid = add.call(cname, "[Metrics/#{ti['base']}]", "Power BI measure #{p[:ctx][:table]}[#{ti['base']}], read from the parent metric.",
                       base_format(fact, ti))
      else
        cname = "#{p[:ctx][:measure]} (base)"
        formula = "#{p[:agg]}(#{p[:row].gsub(/\[([^\]]+)\]/) { "[#{fname}/#{$1}]" }})"
        cid = add.call(cname, formula, "Inline aggregate under Power BI measure #{pbi_ref(p[:ctx])}.")
      end
      base_cols[bkey] = [cname, cid]
      calc_ids << cid
    end
    Array(extra_measures.dig(fname, grain)).each do |mname|
      raise Unbuildable, "A metric #{mname} not found on #{fname}" unless Array(fact['metrics']).any? { |m| m['name'] == mname }
      next if cols.any? { |c| c['name'] == mname }
      calc_ids << add.call(mname, "[Metrics/#{mname}]", "Power BI measure #{members[0][:ctx][:table]}[#{mname}], read from the parent metric.")
    end

    made = {}
    ratios = {}
    yoy_prior = {}
    py_formula = lambda do |p|
      bname = base_cols[p[:ctx][:ti]['base'] || p[:ctx][:ti]['base_expr']][0]
      unit = p[:unit] || 'year'
      "DateLookback([#{bname}], [#{grain_name}], 1, \"#{unit}\")"
    end
    members.reject { |p| p[:kind] == 'yoy' }.each do |p|
      ctx = p[:ctx]
      bname = base_cols[ctx[:ti]['base'] || ctx[:ti]['base_expr']][0]
      desc = "Power BI measure #{pbi_ref(ctx)}."
      if %w[ytd qtd mtd].include?(p[:kind]) && reset == grain
        # the period resets on every row, so the running total is the base itself (R42)
        formula = "[#{bname}]"
        desc += " Equals #{bname} at #{grain} grain (the period resets every row)."
      elsif %w[ytd qtd mtd].include?(p[:kind])
        formula = "CumulativeSum([#{bname}])"
      else
        formula = py_formula.call(p)
      end
      fmt = base_format(fact, ctx[:ti])
      cid = add.call(ctx[:measure], formula, desc, fmt)
      calc_ids << cid
      made[ctx[:key]] = ctx[:measure]
    end
    members.select { |p| p[:kind] == 'yoy' }.each do |p|
      ctx = p[:ctx]
      partner = p[:yoy_of]
      pyname = made[partner[:key]]
      unless pyname
        pyname = partner[:measure]
        pp_plan = members.find { |x| x[:ctx].equal?(partner) } || p.merge(ctx: partner, unit: 'year', kind: 'py')
        calc_ids << add.call(pyname, py_formula.call(pp_plan), "Power BI measure #{pbi_ref(partner)}, read by #{pbi_ref(ctx)}.",
                             base_format(fact, ctx[:ti]))
      end
      bname = base_cols[ctx[:ti]['base']][0]
      yoy_prior[ctx[:key]] = pyname
      if carried
        # a ratio cannot be summed over the carried values: carry numerator and denominator, divide in the consumer (R19)
        num = "#{ctx[:measure]} (numerator)"
        den = "#{ctx[:measure]} (denominator)"
        # R56: a region with no PY has a NULL [py]; [b] - NULL would drop its current value from the Sum, but Power BI's
        # total subtracts only the PY that exists, so the numerator coalesces the PY to 0. The denominator stays [py].
        calc_ids << add.call(num, "[#{bname}] - Coalesce([#{pyname}], 0)", "Numerator of Power BI measure #{pbi_ref(ctx)} (a missing prior year counts as 0); the chart sums it and divides by the denominator.")
        calc_ids << add.call(den, "[#{pyname}]", "Denominator of Power BI measure #{pbi_ref(ctx)}.")
        ratios[ctx[:key]] = { 'numerator' => num, 'denominator' => den }
        made[ctx[:key]] = num
      else
        calc_ids << add.call(ctx[:measure], "([#{bname}] - [#{pyname}]) / NullIf([#{pyname}], 0)", "Power BI measure #{pbi_ref(ctx)}.")
        made[ctx[:key]] = ctx[:measure]
      end
    end

    groupings = []
    carry_ids.each { |cid| groupings << { 'id' => "#{el_id}q#{groupings.length}", 'groupBy' => [cid] } }
    groupings << { 'id' => "#{el_id}q#{groupings.length}", 'groupBy' => [reset_id] } if reset_id
    groupings << { 'id' => "#{el_id}q#{groupings.length}", 'groupBy' => [grain_id], 'calculations' => calc_ids + int_ids }
    carry_note = carried ? " #{carry_cols.map { |cc| cc['name'] }.join(', ')} #{carry_cols.length == 1 ? 'is' : 'are'} carried as the outermost level#{carry_cols.length == 1 ? '' : 's'}, so a slicer pick filters the pre-computed values." : ''
    reset_note = reset && reset != grain ? " The #{reset} is its own outer level, so cumulative sums restart each #{reset}." : ''
    el = { 'id' => el_id, 'kind' => 'table', 'name' => name,
           'description' => "Generated for Power BI time-intelligence measures: #{members.map { |p| pbi_ref(p[:ctx]) }.join(', ')}. " \
                            "One row per #{grain} of #{fname}.#{reset_note}#{carry_note} Read YTD/QTD/MTD at the latest " \
                            "period in scope (Sum(If([#{grain_name}] = Max([#{grain_name}]), [col], Null))), prior-period columns and the base with Sum().",
           'source' => { 'kind' => 'table', 'elementId' => fact['id'] },
           'columns' => cols, 'order' => cols.map { |c| c['id'] }, 'groupings' => groupings }
    if (dup = S.elements_of(dm_model).find { |e| e['name'] == name })
      # reuse an existing column only when its formula is the one built here
      members.each do |p|
        want = cols.find { |c| c['name'] == made[p[:ctx][:key]] }
        have = Array(dup['columns']).find { |c| S.display_name(c) == want['name'] }
        unless have && have['formula'] == want['formula']
          raise Unbuildable, "element #{name} already exists without a matching column for #{want['name']}"
        end
      end
    else
      insert_after(dm_model, fact, el)
    end
    members.each do |p|
      rec = { 'measure' => p[:ctx][:key], 'form' => 'grouped', 'element' => name,
              'column' => made[p[:ctx][:key]], 'consumer_agg' => carried ? 'Sum' : 'Max',
              'kind' => p[:kind], 'period' => grain_name }
      # PREVIOUSYEAR/QUARTER/MONTH return the one previous period of an anchor date, which no read over several periods mirrors
      whole = whole_previous?(p[:kind] == 'yoy' ? p[:yoy_of][:expr] : p[:ctx][:expr])
      if whole
        rec['whole'] = whole
        rec['grain'] = grain
        rec['unit'] = p[:kind] == 'yoy' ? 'year' : (p[:unit] || 'year')
      end
      rec['ratio'] = ratios[p[:ctx][:key]] if ratios[p[:ctx][:key]]
      # a ratio that is not carried as numerator and denominator is rebuilt from its base and prior columns, each summed
      rec['yoy'] = { 'base' => base_cols[p[:ctx][:ti]['base']][0], 'prior' => yoy_prior[p[:ctx][:key]] } if p[:kind] == 'yoy' && !carried
      rec['carried'] = carry_cols.map { |cc| cc['name'] } if carried
      results[p[:ctx][:index]] = [rec]
    end
  end

  # ---------------------------------------------------------------------------------------
  # (c) rolling N days
  # ---------------------------------------------------------------------------------------

  # The element behind a split fact (its "<Fact> (source)" base), else the fact itself.
  def underlying(dm_model, fact)
    pair = S.split_pairs(dm_model).find { |child, _base| child.equal?(fact) }
    pair ? pair[1] : fact
  end

  # Warehouse token of a column of `fact` (a child of a split fact reads its base's column).
  def physical_token(dm_model, fact, display)
    col = S.column_named(fact, display)
    raise Unbuildable, "column #{display} not found on #{fact['name']}" unless col
    owner = fact
    base = underlying(dm_model, fact)
    unless base.equal?(fact)
      leaf = col['formula'].to_s[/\A\[[^\]\/]*\/([^\]]+)\]\z/, 1]
      col = leaf && S.column_named(base, leaf)
      owner = base
    end
    tok = col && S.physical_column?(col) ? S.key_column_token(owner, col) : nil
    raise Unbuildable, "column #{display} is not a physical warehouse column of #{owner['name']}" unless tok
    tok
  end

  def element_sql(el, dialect)
    src = el['source'] || {}
    case src['kind']
    when 'warehouse-table' then "SELECT * FROM #{Array(src['path']).map { |part| S.quote_ident(part, dialect) }.join('.')}"
    when 'sql' then src['statement'].to_s
    else raise Unbuildable, "#{el['name']} is not a warehouse table or Custom SQL element"
    end
  end

  # C2: the SQL predicates (and their labels) for the report filters applied to `fact`. PBI keeps a report filter in
  # every visual's filter context and DATESINPERIOD replaces only the Date filter, so a filter on the date table adds
  # nothing. Raises Unbuildable for a filter that cannot be written exactly.
  def report_filter_predicates(dm_model, fact, date, report_filters, dialect)
    preds = []
    labels = []
    Array(report_filters).each do |f|
      next unless f['element'].to_s.casecmp(fact['name'].to_s).zero?
      next if f['table'].to_s.casecmp(date[:el]['name'].to_s).zero?
      preds << report_filter_sql(dm_model, fact, f, dialect)
      labels << "#{f['table']}.#{f['source_column']} #{f['mode']} #{JSON.generate(Array(f['values']))}"
    end
    [preds, labels]
  end

  def sql_value_literal(v)
    case v
    when String
      raise Unbuildable, "report filter value #{v.inspect} has a character the SQL literal cannot carry exactly" if v =~ /[\\\x00-\x1f]/
      "'#{v.gsub("'", "''")}'"
    when true then 'TRUE'
    when false then 'FALSE'
    when Numeric then v.to_s
    else raise Unbuildable, "report filter value #{v.inspect} is not a text, number or boolean"
    end
  end

  # `f.<key> IN (SELECT k1.<key> FROM (<dim sql>) k1 WHERE k1.<key2> IN (SELECT ...)))` along the filter's relationship
  # path: a semi-join, so a duplicate dimension key never multiplies fact rows. An include list keeps the matching rows;
  # an exclude keeps NULL keys, unmatched keys and NULL attributes (NOT COALESCE(match, FALSE)), like the fact filter.
  # Text compares case-insensitively (LOWER on both sides). A blank in the list is not written (Unbuildable).
  def report_filter_sql(dm_model, fact, f, dialect)
    label = "#{f['table']}[#{f['source_column']}]"
    values = Array(f['values'])
    raise Unbuildable, "the report filter on #{label} lists a blank value; the rolling SQL does not write blank members" if values.any?(&:nil?)
    raise Unbuildable, "the report filter on #{label} has no path to the fact" unless f['path'].is_a?(Array)
    q = ->(n) { S.quote_ident(n, dialect) }
    by_id = S.by_id_map(dm_model)
    hops = []
    owner = fact
    f['path'].each do |rn|
      rel = S.find_relationship(owner, rn, by_id)
      raise Unbuildable, "relationship #{rn} of #{owner['name']} not found for the report filter on #{label}" unless rel
      raise Unbuildable, "relationship #{rn} has a composite key" unless Array(rel['keys']).length == 1
      target = by_id[rel['targetElementId']]
      okey = S.column_by_id(owner, rel['keys'][0]['sourceColumnId'])
      tkey = S.column_by_id(target, rel['keys'][0]['targetColumnId']) if target
      raise Unbuildable, "key columns of relationship #{rn} not found" unless target && okey && tkey
      otok = owner.equal?(fact) ? physical_token(dm_model, fact, S.display_name(okey)) : (S.physical_column?(okey) ? S.key_column_token(owner, okey) : nil)
      ttok = S.physical_column?(tkey) ? S.key_column_token(target, tkey) : nil
      raise Unbuildable, "a key of relationship #{rn} is not a physical warehouse column" unless otok && ttok
      hops << [target, otok, ttok]
      owner = target
    end
    acol = S.column_named(owner, f['source_column'].to_s)
    raise Unbuildable, "column #{f['source_column']} not found on #{owner['name']}" unless acol
    atok = if hops.empty?
             physical_token(dm_model, fact, S.display_name(acol))
           elsif S.physical_column?(acol)
             S.key_column_token(owner, acol)
           end
    raise Unbuildable, "column #{f['source_column']} of #{owner['name']} is not a physical warehouse column" unless atok
    text = values.all? { |v| v.is_a?(String) }
    lits = values.map { |v| sql_value_literal(text ? v.downcase : v) }.join(', ')
    last = hops.empty? ? 'f' : "k#{hops.length}"
    attr = "#{last}.#{q.call(atok)}"
    cond = "#{text ? "LOWER(#{attr})" : attr} IN (#{lits})"
    hops.each_with_index.to_a.reverse.each do |(target, otok, ttok), i|
      owner_alias = i.zero? ? 'f' : "k#{i}"
      cond = "#{owner_alias}.#{q.call(otok)} IN (SELECT k#{i + 1}.#{q.call(ttok)} FROM (\n#{element_sql(target, dialect).to_s.strip.sub(/;+\s*\z/, '').rstrip}\n) k#{i + 1} WHERE #{cond})"
    end
    f['mode'].to_s == 'exclude' ? "NOT COALESCE(#{cond}, FALSE)" : cond
  end

  def build_rolling(dm_model, members, date, dialect, results, slicer_carry = {}, report_filters = [])
    fact = members[0][:fact]
    carry = Array((slicer_carry[fact['name']] || {})['columns']).map { |cc| cc['sql'] }.compact
    carried = !carry.empty?
    # Notes: (1) with a live decision and a carried subset, pbi_combos is NOT filtered by the live predicates; the
    # extra all-zero rows are harmless under Sum. (2) the carry join assumes a unique dimension key (a duplicate
    # key would multiply the daily totals). (3) the live element needs the `/*@slicers*/` hook this SQL always
    # carries; a carried build that lacks it cannot be given a live element afterwards.
    filter_preds, filter_labels = report_filter_predicates(dm_model, fact, date, report_filters, dialect)
    agg_rec = lambda do |p, name|
      rec = { 'measure' => p[:ctx][:key], 'form' => 'rolling_sql', 'element' => name, 'column' => p[:ctx][:measure] }
      rec['report_filters'] = filter_labels unless filter_labels.empty?
      if carried
        rec['consumer_agg'] = 'Sum'
        rec['carried'] = carry.map { |c| c['name'] }
      end
      rec
    end
    days = members[0][:days]
    base = underlying(dm_model, fact)
    fname = fact['name']
    path = S.path_to_table(dm_model, fact, date[:el]['name'])
    raise Unbuildable, "#{fname} has no relationship path to #{date[:el]['name']}" unless path
    raise Unbuildable, "the date table is #{path.length} relationships away from #{fname}; the SQL form needs one" unless path.length == 1
    by_id = S.by_id_map(dm_model)
    rel = S.find_relationship(fact, path[0], by_id)
    raise Unbuildable, "relationship #{path[0]} has a composite key" unless rel && Array(rel['keys']).length == 1
    fkey_col = S.column_by_id(fact, rel['keys'][0]['sourceColumnId'])
    dkey_col = S.column_by_id(date[:el], rel['keys'][0]['targetColumnId'])
    raise Unbuildable, 'relationship key columns not found' unless fkey_col && dkey_col
    fact_key = physical_token(dm_model, fact, S.display_name(fkey_col))
    date_key = S.key_column_token(date[:el], dkey_col) || raise(Unbuildable, 'the date table key is not a physical column')
    dcol = S.column_named(date[:el], date[:col])
    date_tok = dcol && S.physical_column?(dcol) ? S.key_column_token(date[:el], dcol) : nil
    raise Unbuildable, "date column #{date[:col]} is not a physical column of #{date[:el]['name']}" unless date_tok

    used = Set.new(['DAY'])
    aliases = {}
    measure_sql = {}
    members.each do |p|
      wrap = p[:agg] != 'Count' && S.binary_arith?(p[:row]) # R50: DAX reads a blank as 0 in + and -
      sql_row = p[:row].gsub(/\[([^\]]+)\]/) do
        tok = "f.#{S.quote_ident(physical_token(dm_model, fact, $1), dialect)}"
        wrap ? "COALESCE(#{tok}, 0)" : tok
      end
      a = p[:ctx][:measure].upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
      a = "M#{p[:ctx][:index]}" if a.empty?
      a = "#{a}_#{p[:ctx][:index]}" while used.include?(a)
      used << a
      aliases[p[:ctx][:key]] = a
      measure_sql[a] = p[:agg] == 'Count' ? "NULLIF(COUNT(#{sql_row}), 0)" : "SUM(#{sql_row})" # m5: a day with no counted rows is blank
    end
    statement = rolling_sql(fact_sql: element_sql(base, dialect), date_sql: element_sql(date[:el], dialect), measure_sql: measure_sql,
                            days: days, dialect: dialect, fact_key: fact_key, date_key: date_key, date_col: date_tok,
                            carry: carry, hook: fname, filters: filter_preds)
    conn = base.dig('source', 'connectionId')
    name = "#{fname} – rolling #{days} days by day"
    if (dup = S.elements_of(dm_model).find { |e| e['name'] == name })
      members.each do |p|
        col = Array(dup['columns']).find { |c| S.display_name(c) == p[:ctx][:measure] }
        unless col && col['formula'] == "[Custom SQL/#{aliases[p[:ctx][:key]]}]" && dup.dig('source', 'statement') == statement
          raise Unbuildable, "element #{name} already exists without a matching column for #{p[:ctx][:measure]}"
        end
        results[p[:ctx][:index]] = [agg_rec.call(p, name)]
      end
      return
    end
    el_id = S.next_id(dm_model, "#{fact['id']}r")
    cols = [{ 'id' => "#{el_id}c0", 'name' => 'Day', 'formula' => '[Custom SQL/DAY]' }]
    carry.each_with_index do |cc, i|
      cols << { 'id' => "#{el_id}k#{i}", 'name' => cc['name'], 'formula' => "[Custom SQL/#{cc['name']}]",
                'description' => 'Slicer field carried so a pick filters the pre-computed windows (one window per value).' }
    end
    members.each_with_index do |p, i|
      c = { 'id' => "#{el_id}c#{i + 1}", 'name' => p[:ctx][:measure], 'formula' => "[Custom SQL/#{aliases[p[:ctx][:key]]}]",
            'description' => "Power BI measure #{pbi_ref(p[:ctx])}: trailing #{days} calendar days ending on this day." }
      fmt = base_format(fact, p[:ctx][:ti])
      c['format'] = fmt if fmt
      cols << c
    end
    el = { 'id' => el_id, 'kind' => 'table', 'name' => name,
           'description' => "Generated for Power BI measures: #{members.map { |p| pbi_ref(p[:ctx]) }.join(', ')}. One row per calendar day " \
                            "of #{date[:el]['name']} (a dense spine), each window summing the trailing #{days} days from the start of the " \
                            "history. Sigma's MovingSum counts rows, not days, so it is not used. " \
                            "#{carried ? "#{carry.map { |c| c['name'] }.join(', ')} carried: one window per value." : ''} Read a window at the latest day in scope (Sum(If([Day] = Max([Day]), [col], Null))).",
           'source' => { 'kind' => 'sql', 'connectionId' => conn, 'statement' => statement },
           'columns' => cols, 'order' => cols.map { |c| c['id'] } }
    insert_after(dm_model, fact, el)
    members.each do |p|
      results[p[:ctx][:index]] = [agg_rec.call(p, name)]
    end
  end
end
