#!/usr/bin/env ruby
# build-oracle-sql.rb — transpile aggregate Power BI DAX measures into warehouse
# SQL so Phase 6 parity can use the SOURCE WAREHOUSE as the oracle instead of the
# live Power BI service (executeQueries). The warehouse is what BOTH Power BI and
# Sigma read, so for warehouse-backed models the aggregate computed directly in
# SQL is a valid, independent "expected" value — no api.powerbi.com, no Entra
# app, no workspace/dataset id required.
#
# The agent runs each emitted SQL via `mcp__sigma-mcp-v2__query` (type:connection,
# the SAME connectionId the data model uses) to produce parity-expected.json, then
# feeds it to `phase6-parity-pbi.rb --local-sql --expected ...`.
#
# SCOPE: the common aggregate grammar — SUM / AVERAGE / MIN / MAX / COUNT /
# DISTINCTCOUNT / COUNTROWS over Table[Col], and DIVIDE(<agg>,<agg>) — with an
# optional single GROUP BY dimension. Anything outside it (RANKX, CALCULATE with
# filter context, time-intelligence, iterators) is marked supported:false so the
# caller falls back to the online DAX path (--emit-dax) or the waiver. We FLAG,
# never silently approximate.
#
# Usage:
#   ruby build-oracle-sql.rb --in <oracle-input.json> --out <chart-oracle-sql.json>
#
# oracle-input.json:
#   {
#     "connectionId": "<sigma connection uuid>",      # echoed for the agent's MCP call
#     "column_map": { "Order Id": "ORDER_ID", ... },   # OPTIONAL display->warehouse col.
#                                                       # REQUIRED for PromoteHeaders /
#                                                       # renamed columns (see --dm-spec).
#     "charts": {
#       "Total Sales":     { "fqn": "DB.SCH.TBL", "dax": "SUM(Orders[Sales])" },
#       "Sales by Region": { "fqn": "DB.SCH.TBL", "dax": "SUM(Orders[Sales])", "dim": "Region" }
#     }
#   }
#
# Optionally pass --dm-spec <dm-spec.json> to auto-derive a default fqn from the
# data model's warehouse-table element(s).

#
# TODAY-RELATIVE MEASURES (one clock for "today"). With a report clock —
# `report_timezone` (+ optional `dialect`, `as_of`) in the input, or
# `--report-clock <WORK>/report-clock.json` — the oracle also covers
# CALCULATE(<agg>, DATESINPERIOD(D[Date], TODAY(), ±N, DAY|MONTH|QUARTER|YEAR)),
# CALCULATE(<agg>, DATESBETWEEN(D[Date], <start>, <end>)) with start/end TODAY(),
# TODAY()±N, DATE(YEAR(TODAY()),MONTH(TODAY()),1) / (QUARTER-1)*3+1 / 1,1 or a
# DATE(y,m,d) literal, CALCULATE(<agg>, T[c] <op> <that date>), DATEDIFF(<agg>,
# TODAY(), DAY) and a bare TODAY(). "today" is the timezone-explicit
# PbiReportClock.today_sql — never the warehouse session's CURRENT_DATE — the
# same report day the migrated Sigma formulas use. Without a report clock these
# stay supported:false. Map the calendar's date column to the fact's date column
# in column_map ("Date" => "ORDER_DATE"; per-chart column_map overrides).
# `measures` ({name: DAX}) lets a [Measure] reference expand. Each descriptor
# carries today_relative + clock so phase6-parity-pbi.rb can prove one clock.

require 'json'
require_relative 'lib/pbi_report_clock'

module OracleSql
  AGG = { 'SUM' => 'SUM', 'AVERAGE' => 'AVG', 'MIN' => 'MIN', 'MAX' => 'MAX',
          'COUNT' => 'COUNT', 'DISTINCTCOUNT' => 'COUNT', 'COUNTROWS' => 'COUNT' }.freeze
  UNITS = { 'DAY' => 'day', 'MONTH' => 'month', 'QUARTER' => 'quarter', 'YEAR' => 'year' }.freeze

  def self.clock_value(clock, key)
    return nil unless clock

    clock[key.to_s] || clock[key.to_sym]
  end

  def self.dialect_of(clock)
    (clock_value(clock, :dialect) || 'snowflake').to_s.downcase
  end

  def self.today_expr(clock, utc: false)
    tz = utc ? 'UTC' : clock_value(clock, :timezone)
    PbiReportClock.today_sql(tz, dialect_of(clock), as_of: clock_value(clock, :as_of))
  end

  def self.now_expr(clock, utc: false)
    tz = utc ? 'UTC' : clock_value(clock, :timezone)
    PbiReportClock.now_sql(tz, dialect_of(clock), as_of: clock_value(clock, :as_of))
  end

  def self.dateadd(unit, n, expr, clock)
    case dialect_of(clock)
    when 'bigquery' then "DATE_ADD(#{expr}, INTERVAL #{n} #{unit.upcase})"
    when 'databricks'
      months = { 'month' => 1, 'quarter' => 3, 'year' => 12 }[unit]
      months ? "add_months(#{expr}, #{n * months})" : "date_add(#{expr}, #{n})"
    else "DATEADD('#{unit}', #{n}, #{expr})"
    end
  end

  def self.trunc(unit, expr, clock)
    case dialect_of(clock)
    when 'bigquery' then "DATE_TRUNC(#{expr}, #{unit.upcase})"
    when 'databricks' then "CAST(date_trunc('#{unit.upcase}', #{expr}) AS DATE)"
    else "DATE_TRUNC('#{unit}', #{expr})"
    end
  end

  def self.datediff(unit, a, b, clock)
    case dialect_of(clock)
    when 'bigquery' then "DATE_DIFF(#{b}, #{a}, #{unit.upcase})"
    when 'databricks' then unit == 'day' ? "datediff(#{b}, #{a})" : nil
    else "DATEDIFF('#{unit}', #{a}, #{b})"
    end
  end

  # Top-level comma split that respects (), [], '…' and "…".
  def self.split_args(s)
    args = []
    depth = 0
    cur = +''
    quote = nil
    s.each_char do |ch|
      if quote
        cur << ch
        quote = nil if ch == quote
        next
      end
      case ch
      when "'", '"' then quote = ch
      when '[' then quote = ']'
      when '(' then depth += 1
      when ')' then depth -= 1
      when ','
        if depth.zero?
          args << cur.strip
          cur = +''
          next
        end
      end
      cur << ch
    end
    args << cur.strip unless cur.strip.empty?
    args
  end

  # "FN( a, b )" -> ["FN", [a, b]] when the outer parens enclose the whole tail.
  def self.call_parts(d)
    m = d.match(/\A([A-Za-z]+)\s*\((.*)\)\z/m)
    return nil unless m

    inner = m[2]
    depth = 0
    inner.each_char do |ch|
      depth += 1 if ch == '('
      depth -= 1 if ch == ')'
      return nil if depth.negative?
    end
    depth.zero? ? [m[1].upcase, split_args(inner)] : nil
  end

  def self.expand_measure(d, measures)
    m = d.strip.match(/\A\[([^\]]+)\]\z/)
    m && measures.key?(m[1]) ? measures[m[1]].to_s.strip : d.strip
  end

  # Recursive through [Measure] references (visited set guards cycles).
  def self.today_relative?(dax, measures = {}, seen = {})
    return true if PbiReportClock.today_relative_dax?(dax)

    dax.to_s.scan(/((?:'[^']+'|[A-Za-z_][A-Za-z0-9_]*)\s*)?\[([^\]]+)\]/).any? do |qualifier, n|
      next false if qualifier
      next false if seen[n] || !measures.key?(n)

      seen[n] = true
      today_relative?(measures[n], measures, seen)
    end
  end

  # Report-clock date expression for a DAX date argument, or nil.
  def self.date_expr(x, clock)
    k = x.to_s.gsub(/\s+/, '').upcase
    return today_expr(clock) if k == 'TODAY()'
    return today_expr(clock, utc: true) if k == 'UTCTODAY()'
    return trunc('month', today_expr(clock), clock) if k == 'DATE(YEAR(TODAY()),MONTH(TODAY()),1)'
    return trunc('year', today_expr(clock), clock) if k == 'DATE(YEAR(TODAY()),1,1)'
    return trunc('quarter', today_expr(clock), clock) if k == 'DATE(YEAR(TODAY()),(QUARTER(TODAY())-1)*3+1,1)'
    if (m = k.match(/\ATODAY\(\)([+-])(\d+)\z/))
      return dateadd('day', (m[1] == '-' ? -1 : 1) * m[2].to_i, today_expr(clock), clock)
    end
    if (m = k.match(/\ADATE\((\d{4}),(\d{1,2}),(\d{1,2})\)\z/))
      return format("DATE '%04d-%02d-%02d'", m[1].to_i, m[2].to_i, m[3].to_i)
    end

    nil
  end

  def self.column_of(arg, col_map, fallback)
    m = arg.to_s.strip.match(/\A'?[^'\[]*'?\s*\[\s*([^\]]+?)\s*\]\z/)
    m ? wh_col(m[1], col_map, fallback) : nil
  end

  # A CALCULATE filter on the report clock -> SQL predicate, or nil.
  def self.filter_cond(f, col_map, fallback, clock)
    if (cp = call_parts(f.strip))
      fn, args = cp
      if fn == 'DATESINPERIOD' && args.size == 4
        col = column_of(args[0], col_map, fallback)
        start = date_expr(args[1], clock)
        n = args[2].strip.match?(/\A-?\d+\z/) ? args[2].strip.to_i : nil
        unit = UNITS[args[3].strip.upcase]
        return nil unless col && start && n && unit && !n.zero?

        edge = dateadd(unit, n, start, clock)
        return n.negative? ? "#{col} > #{edge} AND #{col} <= #{start}" : "#{col} >= #{start} AND #{col} < #{edge}"
      end
      if fn == 'DATESBETWEEN' && args.size == 3
        col = column_of(args[0], col_map, fallback)
        a = date_expr(args[1], clock)
        b = date_expr(args[2], clock)
        return col && a && b ? "#{col} BETWEEN #{a} AND #{b}" : nil
      end
      return nil
    end
    m = f.strip.match(/\A('?[^'\[]*'?\s*\[[^\]]+\])\s*(<=|>=|<>|=|<|>)\s*(.+)\z/m)
    return nil unless m

    col = column_of(m[1], col_map, fallback)
    rhs = date_expr(m[3], clock)
    col && rhs ? "#{col} #{m[2] == '<>' ? '<>' : m[2]} #{rhs}" : nil
  end

  # {fn, col} for COUNTROWS / AGG(T[c]); nil otherwise.
  def self.agg_parts(d, col_map, fallback)
    return { fn: 'COUNT', col: nil } if d =~ /\ACOUNTROWS\s*\(\s*'?[^'\[\)]+'?\s*\)\z/i

    m = d.match(/\A([A-Za-z]+)\s*\(\s*'?[^'\[]+'?\s*\[\s*([^\]]+?)\s*\]\s*\)\z/)
    return nil unless m && AGG.key?(m[1].upcase)

    { fn: m[1].upcase, col: wh_col(m[2], col_map, fallback) }
  end

  def self.render_agg(parts, cond = nil)
    fn = parts[:fn]
    col = parts[:col]
    if cond
      return "COUNT(CASE WHEN #{cond} THEN 1 END)" if col.nil?
      return "COUNT(DISTINCT CASE WHEN #{cond} THEN #{col} END)" if fn == 'DISTINCTCOUNT'

      return "#{AGG[fn]}(CASE WHEN #{cond} THEN #{col} END)"
    end
    return 'COUNT(*)' if col.nil?
    return "COUNT(DISTINCT #{col})" if fn == 'DISTINCTCOUNT'

    "#{AGG[fn]}(#{col})"
  end

  # display name -> warehouse column. Explicit map wins; else Sigma's normal
  # transform inverse: "Order Id" -> ORDER_ID. NOT safe for PromoteHeaders /
  # renamed columns — those MUST be supplied via column_map (caller warns).
  def self.normalize_col(display)
    display.to_s.strip.gsub(/[^A-Za-z0-9]+/, '_').upcase.gsub(/^_+|_+$/, '')
  end

  def self.wh_col(display, col_map, fallback)
    return col_map[display] if col_map.key?(display)
    fallback << display
    normalize_col(display)
  end

  # Transpile a DAX measure body to a SQL select-expression, or nil if unsupported.
  # `fallback` (optional array) collects display names that used the heuristic.
  # clock: {timezone, dialect, as_of} — the report clock (required for any
  # TODAY()/NOW() expression; nil keeps those unsupported).
  def self.transpile(dax, col_map = {}, fallback = [], clock: nil, measures: {}, depth: 0)
    return nil if depth > 8

    d = expand_measure(dax.to_s, measures)
    return transpile(d, col_map, fallback, clock: clock, measures: measures, depth: depth + 1) if d != dax.to_s.strip
    return nil if clock.nil? && PbiReportClock.today_relative_dax?(d)

    sub = ->(x) { transpile(x, col_map, fallback, clock: clock, measures: measures, depth: depth + 1) }
    if (m = d.match(/\ADIVIDE\s*\(\s*(.+?)\s*,\s*(.+?)\s*\)\z/i)) && !clock
      a = sub.call(m[1])
      b = sub.call(m[2])
      return (a && b) ? "#{a} / NULLIF(#{b},0)" : nil
    end
    if clock
      k = d.gsub(/\s+/, '').upcase
      return today_expr(clock) if k == 'TODAY()'
      return now_expr(clock) if k == 'NOW()'
      return today_expr(clock, utc: true) if k == 'UTCTODAY()'
      return now_expr(clock, utc: true) if k == 'UTCNOW()'

      fn, args = call_parts(d)
      if fn == 'DIVIDE' && args.size == 2
        a = sub.call(args[0])
        b = sub.call(args[1])
        return (a && b) ? "#{a} / NULLIF(#{b},0)" : nil
      end
      if fn == 'DATEDIFF' && args.size == 3
        unit = UNITS[args[2].strip.upcase]
        a = date_expr(args[0], clock) || sub.call(args[0])
        b = date_expr(args[1], clock) || sub.call(args[1])
        return (unit && a && b) ? datediff(unit, a, b, clock) : nil
      end
      if fn == 'CALCULATE' && args.size >= 2
        inner = expand_measure(args[0], measures)
        parts = agg_parts(inner, col_map, fallback)
        conds = args[1..].map { |f| filter_cond(f, col_map, fallback, clock) }
        return nil if parts.nil? || conds.any?(&:nil?)

        return render_agg(parts, conds.join(' AND '))
      end
    end
    parts = agg_parts(d, col_map, fallback)
    parts ? render_agg(parts) : nil
  end

  # Build the per-chart oracle descriptor. Returns a hash with supported:true +
  # sql/dim_col/val_col (+ today_relative, clock), or supported:false + reason.
  def self.chart_sql(name, dax, fqn, dim: nil, col_map: {}, fallback: [], clock: nil, measures: {})
    return { 'supported' => false, 'reason' => 'no fqn (pass per-chart fqn or --dm-spec)' } unless fqn

    today_rel = today_relative?(dax, measures)
    expr = transpile(dax, col_map, fallback, clock: clock, measures: measures)
    if expr.nil?
      reason = if today_rel && clock.nil?
                 'today-relative DAX needs the report clock: set report_timezone in oracle-input.json (or pass ' \
                 "--report-clock <WORK>/report-clock.json) so the oracle and Sigma name the same day: #{dax}"
               else
                 "unsupported DAX (outside aggregate grammar): #{dax}"
               end
      return { 'supported' => false, 'today_relative' => today_rel, 'reason' => reason }
    end
    out = if dim
            dcol = wh_col(dim, col_map, fallback)
            # Power BI drops a row whose measure is BLANK: a windowed (CASE WHEN) aggregate over a
            # group with no rows in the window is NULL (SUM/AVG/MIN/MAX) or 0 (COUNT) here.
            having = if expr.include?('CASE WHEN')
                       expr.start_with?('COUNT(') ? " HAVING #{expr} > 0" : " HAVING #{expr} IS NOT NULL"
                     else
                       ''
                     end
            sql = %(SELECT #{dcol} AS "#{dim}", #{expr} AS "#{name}" FROM #{fqn} GROUP BY #{dcol}#{having} ORDER BY 2 DESC)
            { 'supported' => true, 'sql' => sql, 'dim_col' => dim, 'val_col' => name }
          else
            { 'supported' => true, 'sql' => %(SELECT #{expr} AS "#{name}" FROM #{fqn}), 'dim_col' => nil, 'val_col' => name }
          end
    out['today_relative'] = today_rel
    out['clock'] = clock_descriptor(clock) if today_rel
    out
  end

  def self.clock_descriptor(clock)
    return nil unless clock

    { 'kind' => 'report-clock', 'timezone' => clock_value(clock, :timezone), 'dialect' => dialect_of(clock),
      'as_of' => clock_value(clock, :as_of), 'today_sql' => today_expr(clock) }
  end
end

# --------------------------------------------------------------------------- CLI
if __FILE__ == $PROGRAM_NAME
  require 'optparse'
  opts = {}
  OptionParser.new do |p|
    p.on('--in PATH')  { |v| opts[:in] = v }
    p.on('--out PATH') { |v| opts[:out] = v }
    p.on('--dm-spec PATH', 'optional DM spec — derive a default fqn from warehouse-table elements') { |v| opts[:dm] = v }
    p.on('--report-clock PATH', '<WORK>/report-clock.json from migrate-powerbi.rb (report timezone + dialect)') { |v| opts[:clock] = v }
    p.on('--as-of ISO', 'pin "today" to an instant, e.g. 2026-11-17T03:00:00Z (reproducible oracle)') { |v| opts[:as_of] = v }
  end.parse!
  %i[in out].each { |k| abort("missing --#{k}") unless opts[k] }

  input = JSON.parse(File.read(opts[:in]))
  col_map = input['column_map'] || {}
  measures = input['measures'] || {}
  rec = opts[:clock] ? JSON.parse(File.read(opts[:clock])) : {}
  tz = input['report_timezone'] || rec['report_timezone']
  clock = nil
  if tz
    begin
      PbiReportClock.validate_timezone!(tz)
      clock = { 'timezone' => tz, 'dialect' => input['dialect'] || rec['dialect'] || 'snowflake',
                'as_of' => opts[:as_of] || input['as_of'] }
      PbiReportClock.today_sql(tz, clock['dialect'], as_of: clock['as_of'])
    rescue ArgumentError => e
      abort("[build-oracle-sql] #{e.message}")
    end
  end

  default_fqn = nil
  if opts[:dm]
    dm = JSON.parse(File.read(opts[:dm]))
    (dm['pages'] || []).each do |pg|
      (pg['elements'] || []).each do |el|
        src = el['source'] || {}
        default_fqn ||= src['path'].join('.') if src['kind'] == 'warehouse-table' && src['path']
      end
    end
  end

  fallback = []
  charts = {}
  input.fetch('charts', {}).each do |name, c|
    charts[name] = OracleSql.chart_sql(name, c['dax'], c['fqn'] || default_fqn,
                                       dim: c['dim'], col_map: col_map.merge(c['column_map'] || {}),
                                       fallback: fallback, clock: clock, measures: measures)
  end
  out = { '_connectionId' => input['connectionId'], '_charts' => charts }
  out['_clock'] = OracleSql.clock_descriptor(clock) if clock
  today_n = charts.values.count { |v| v['today_relative'] }
  if today_n.positive?
    warn "[build-oracle-sql] #{today_n} today-relative chart(s) " +
         (clock ? "on the report clock #{clock['timezone']}#{clock['as_of'] ? " (as of #{clock['as_of']})" : ''} — pass this " \
                  'file to phase6-parity-pbi.rb --local-sql --oracle-sql so parity proves one clock' :
                  'left UNSUPPORTED: no report_timezone / --report-clock')
  end
  File.write(opts[:out], JSON.pretty_generate(out))

  supported = charts.values.count { |v| v['supported'] }
  unsupported = charts.reject { |_, v| v['supported'] }
  warn "[build-oracle-sql] #{supported}/#{charts.size} chart(s) -> warehouse SQL; " \
       "#{unsupported.size} need the online DAX fallback."
  unsupported.each { |n, v| warn "  [fallback] #{n}: #{v['reason']}" }
  unless fallback.uniq.empty?
    warn "[build-oracle-sql] WARNING: no explicit column_map for #{fallback.uniq.size} column(s) " \
         "(#{fallback.uniq.join(', ')}) — used the NAME->UPPER_SNAKE heuristic. If the warehouse " \
         "columns are renamed/auto-named (Table.PromoteHeaders -> C1/C2, see pbi-dm-signature.py), pass " \
         'an explicit column_map or the oracle SQL will reference columns that do not exist.'
  end
  warn "[build-oracle-sql] wrote #{opts[:out]} — run each `sql` via mcp__sigma-mcp-v2__query " \
       "{type:connection, connectionId:#{input['connectionId'].inspect}}, save rows to parity-expected.json, " \
       'then: phase6-parity-pbi.rb --local-sql --expected parity-expected.json --workbook-id <id> --out plan.json'
end
