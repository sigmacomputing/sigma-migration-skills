# frozen_string_literal: true
#
# PbiSlicerCarry -- slicers on pages whose charts read a summary table, for the opt-in
# `--model-shape pbi` mode (spec: "Summary tables", bullet "Slicers a summary table does not carry").
#
# A summary table is pre-aggregated, so a slicer on a field it does not carry would silently do nothing.
# Two ways out:
#   carry  carry the slicer's field as a column when the table stays within `factor` (10) times its size
#          (grouped elements: outer grouping levels, read with Sum -- probe P15; rolling summaries: GROUP BY /
#          PARTITION BY over a dense spine cross-joined with the distinct carried combinations)
#   live   otherwise the page gets ONE plainly named workbook Custom SQL element (PbiDirectSources.live_element!)
#          whose SQL is the summary's own SQL with one predicate per uncarried slicer
#
# This file holds the pure parts: the counts SQL (`size_queries`), the carry decision (`decide`), the live
# element's SQL (`live_sql`), and the decision log (`log_entry`, `write_log`). No I/O except `write_log`.
# The Custom SQL template forms are the live-verified ones of refs/large-pbix.md ("Slicers on dimensions a
# page fact does not carry"); the semi-join and (Blank) handling is a port of semi_join / attr_match in
# lib/pbi_page_closure.py (wire-slicer-gate.py is unchanged and still owns the views-mode union recipe).
# Pure Ruby 2.6.
require 'json'
require_relative 'pbi_shaped_model'

module PbiSlicerCarry
  module_function

  S = PbiShapedModel

  FACTOR = 10
  DIALECTS = %w[snowflake databricks bigquery sqlite].freeze
  TEXT_TYPE = { 'snowflake' => 'VARCHAR', 'databricks' => 'STRING', 'bigquery' => 'STRING', 'sqlite' => 'VARCHAR' }.freeze
  # keys of a counts Hash that are not slicer columns
  META_KEYS = %w[base density combined].freeze
  NEEDS_LIVE = 'slicer fields exceed carry size; needs a live summary'
  SPARSE = 'slicer fields are not dense over the periods (a carried value lacks some periods); needs a live summary'
  LIVE_SUFFIX = ' – live, filtered by your slicer picks'

  class NoHook < StandardError; end

  def dialect!(dialect)
    d = dialect.to_s.downcase
    raise ArgumentError, "unsupported dialect #{dialect}" unless DIALECTS.include?(d)
    d
  end

  def strip(sql)
    sql.to_s.strip.sub(/;+\s*\z/, '').rstrip
  end

  # ---------------------------------------------------------------------------------------
  # Counts
  # ---------------------------------------------------------------------------------------

  class MissingCount < ArgumentError; end

  # Slicer columns in carry order: ascending single-column cardinality, ties by name (R56).
  def carry_order(counts)
    cols = counts.keys.reject { |k| META_KEYS.include?(k) }
    cols.sort_by { |c| [counts[c], c] }
  end

  # SQL for the counts `decide` takes, each returning one number N (density queries return PRESENT, EXPECTED).
  # Carrying several columns MULTIPLIES rows, so a combined size is always measured, never estimated (R56).
  # Two rounds, because the prefix order depends on the single-column counts:
  #   round 1  size_queries(sql, cols)               -> 'base' and one count per single column (ordering only)
  #   round 2  size_queries(sql, cols, order: o)     -> the same plus, for the greedy prefixes of `o`
  #            (o = carry_order(counts) from round 1):
  #              "prefix:a|b"   COUNT(*) of DISTINCT (grain columns + prefix columns), the rows the summary would
  #                             have with that prefix carried (prefixes of 2 or more; a single is the column count)
  #              "density:a|b"  only with `period:` (an SQL expression over the summary columns, e.g. a month):
  #                             PRESENT = distinct (prefix columns, period) rows, EXPECTED = distinct prefix
  #                             combinations * distinct periods (every prefix, a single included). A grouped
  #                             element may carry a prefix only when PRESENT = EXPECTED (probe P15: the Sum
  #                             consumer assumes every carried value has every period).
  # `grain` lists the summary's own grain columns (e.g. ['MONTH']; none = count its rows).
  # Task 18 runs the queries and assembles counts: {'base', <col> => n, 'combined' => {"a|b" => n},
  # 'density' => {"a|b" => {'present' =>, 'expected' =>}}}.
  def size_queries(summary_sql, slicer_columns, dialect: 'snowflake', grain: [], period: nil, order: nil)
    d = dialect!(dialect)
    q = ->(n) { S.quote_ident(n, d) }
    inner = strip(summary_sql)
    cols = Array(slicer_columns).map(&:to_s)
    distinct = lambda do |names|
      list = (Array(grain) + names).map { |c| q.call(c) }
      list.empty? ? 'SELECT 1 AS pbi_one FROM pbi_summary' : "SELECT DISTINCT #{list.join(', ')} FROM pbi_summary"
    end
    wrap = ->(body) { "WITH pbi_summary AS (\n#{inner}\n)\nSELECT COUNT(*) AS N FROM (#{body}) pbi_n" }
    out = { 'base' => wrap.call(distinct.call([])) }
    cols.each { |c| out[c] = wrap.call(distinct.call([c])) }
    return out unless order
    order = Array(order).map(&:to_s)
    raise ArgumentError, "order must list the slicer columns: #{order.inspect}" unless order.sort == cols.sort
    (1..order.length).each do |k|
      pre = order[0, k]
      out["prefix:#{pre.join('|')}"] = wrap.call(distinct.call(pre)) if k >= 2
      next unless period
      list = pre.map { |c| q.call(c) }.join(', ')
      out["density:#{pre.join('|')}"] = [
        "WITH pbi_summary AS (\n#{inner}\n)",
        "SELECT (SELECT COUNT(*) FROM (SELECT DISTINCT #{list}, #{period} AS pbi_period FROM pbi_summary) pbi_p) AS PRESENT,",
        "       (SELECT COUNT(*) FROM (SELECT DISTINCT #{list} FROM pbi_summary) pbi_c) *",
        "       (SELECT COUNT(*) FROM (SELECT DISTINCT #{period} AS pbi_period FROM pbi_summary) pbi_t) AS EXPECTED"
      ].join("\n")
    end
    out
  end

  # counts: {'base' => N, <col> => rows with <col> carried, 'combined' => {"a|b" => rows} for every prefix of
  # carry_order of 2+ columns, 'density' => {"a|b" => {'present' => n, 'expected' => m}}} (R56).
  # Carries the LONGEST prefix (ascending single-column cardinality, ties by name) whose measured row count is
  # within `factor` x base. A needed count that is missing raises MissingCount: nothing is estimated.
  # `grouped: true` (a grouped C element) makes density REQUIRED: the chosen prefix must be dense, else decide
  # steps back to the longest dense prefix within the bound; missing density counts raise.
  # Returns {'carry' => [cols] (prefix order), 'live' => bool (a slicer was left over), 'counts' => counts,
  #          'factor' => factor, 'order' => [cols], 'sizes' => {col => rows}, 'combined_rows' => N of the carry,
  #          'dense' => bool|nil (of the chosen prefix; nil when density was not needed), 'stepped_back' => bool}
  def decide(counts, factor: FACTOR, grouped: false)
    base = counts['base']
    raise ArgumentError, 'counts need a positive base row count' unless base.is_a?(Numeric) && base > 0
    order = carry_order(counts)
    limit = factor * base
    sizes = {}
    order.each_index do |i|
      pre = order[0, i + 1]
      size = if pre.length == 1
               counts[pre[0]]
             else
               (counts['combined'] || {})[pre.join('|')] ||
                 raise(MissingCount, "no measured row count for the prefix #{pre.join('|')} (size_queries order: round 2)")
             end
      break if size > limit
      sizes[pre] = size
    end
    longest = sizes.keys.length
    chosen = longest
    dense = nil
    stepped = false
    if grouped && longest.positive?
      chosen = longest
      while chosen.positive?
        key = order[0, chosen].join('|')
        dens = (counts['density'] || {})[key] ||
               raise(MissingCount, "no density count for the prefix #{key}: a grouped element needs it")
        dense = dens['present'].to_i >= dens['expected'].to_i
        break if dense
        stepped = true
        chosen -= 1
      end
      dense = nil if chosen.zero?
    end
    carry = order[0, chosen]
    { 'carry' => carry, 'live' => carry.length < order.length, 'counts' => counts, 'factor' => factor, 'order' => order,
      'sizes' => order.map { |c| [c, counts[c]] }.to_h, 'combined_rows' => carry.empty? ? base : sizes[carry],
      'dense' => dense, 'stepped_back' => stepped }
  end

  # ---------------------------------------------------------------------------------------
  # Live element SQL
  # ---------------------------------------------------------------------------------------

  # The summary's SQL with one predicate per uncarried slicer, injected after every
  # `/*@slicers fact="T" alias="f"*/` marker (a hook sits inside the WHERE of each fact scan, so the predicate
  # filters fact rows BEFORE any window or ratio). One template per control, no union, no closed branch.
  #   slicers  [{'control_id' =>, 'column' => attribute column of the slicer table (of the fact when `path` is
  #              empty), 'path' => [hop], 'typed' => false, 'blank' => true, 'facts' => optional [fact names]}]
  #   hop      {'from_source' => SQL for the slicer-side table (a quoted path or "(SELECT ...)"),
  #             'from_col' =>, 'to_col' => (the key on the fact side of the hop), 'type' => '1:M' | 'M:1' | '1:1'}
  #            hops run slicer table -> ... -> fact
  # Raises NoHook when the SQL has no marker (the caller leaves the page as built).
  def live_sql(summary_sql, slicers, dialect: 'snowflake')
    d = dialect!(dialect)
    sql = summary_sql.to_s
    hooks = hooks_of(sql)
    raise NoHook, 'the summary SQL has no /*@slicers fact="..." alias="..."*/ hook' if hooks.empty?
    out = +''
    last = 0
    hooks.each do |h|
      preds = Array(slicers).select { |s| s['facts'].nil? || Array(s['facts']).include?(h[:fact]) }
                            .map { |s| "\n    AND #{guarded(s, h[:alias], d)}" }
      out << sql[last...h[:range].end] << preds.join
      last = h[:range].end
    end
    out << sql[last..-1]
    out
  end

  def hooks_of(sql)
    out = []
    sql.scan(%r{/\*@slicers\s+(.*?)\*/}m) do
      m = Regexp.last_match
      attrs = m[1].scan(/(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"/).to_h
      out << { range: (m.begin(0)...m.end(0)), fact: attrs['fact'], alias: attrs['alias'] || 'f' }
    end
    out
  end

  def length_tpl(ctl)
    "{{#formula ArrayLength([#{ctl}])}}"
  end

  def values_tpl(ctl)
    "{{#{ctl}}}"
  end

  # (CASE WHEN {{#formula ArrayLength([Ctl])}} = 0 THEN TRUE ELSE <semi-join> END)
  def guarded(slicer, target_alias, dialect)
    ctl = slicer['control_id']
    cond = semi_join(slicer, target_alias, dialect)
    "(CASE WHEN #{length_tpl(ctl)} = 0 THEN TRUE ELSE #{cond} END)"
  end

  def attr_match(alias_col, values, blank, typed, dialect)
    return "#{alias_col} IN #{values}" if typed
    cast = "CAST(#{alias_col} AS #{TEXT_TYPE[dialect]})"
    blank ? "COALESCE(#{cast}, '(Blank)') IN #{values}" : "#{cast} IN #{values}"
  end

  # Port of semi_join (lib/pbi_page_closure.py): each hop is `x.col IN (SELECT k.col FROM <src> k WHERE <cond>)`,
  # so a duplicate key on the one side never multiplies fact rows; while every hop so far is one-to-many the
  # fact rows whose key is NULL or unmatched reach the (Blank) member too.
  def semi_join(slicer, target_alias, dialect)
    q = ->(n) { S.quote_ident(n, dialect) }
    values = values_tpl(slicer['control_id'])
    typed = slicer['typed'] == true
    blank = slicer.key?('blank') ? slicer['blank'] != false : !typed
    blank = false if typed
    path = Array(slicer['path'])
    col = q.call(slicer['column'])
    return attr_match("#{target_alias}.#{col}", values, blank, typed, dialect) if path.empty?
    n = path.length
    k_alias = "sj#{n}"
    cond = attr_match("#{k_alias}.#{col}", values, blank, typed, dialect)
    all_many = true
    path.each_with_index do |hop, i|
      all_many &&= %w[1:M 1:1].include?(hop['type'].to_s)
      from_ident = q.call(hop['from_col'])
      to_ident = q.call(hop['to_col'])
      x_alias = i == n - 1 ? target_alias : "sj#{n - i - 1}"
      c = "#{x_alias}.#{to_ident} IN (SELECT #{k_alias}.#{from_ident} FROM #{hop['from_source']} #{k_alias} WHERE #{cond})"
      if blank && all_many
        c = "(#{c} OR ('(Blank)' IN #{values} AND (#{x_alias}.#{to_ident} IS NULL OR #{x_alias}.#{to_ident} NOT IN " \
            "(SELECT sjb.#{from_ident} FROM #{hop['from_source']} sjb WHERE sjb.#{from_ident} IS NOT NULL))))"
      end
      cond = c
      k_alias = x_alias
    end
    cond
  end

  # ---------------------------------------------------------------------------------------
  # Decision log (slicer-carry.json)
  # ---------------------------------------------------------------------------------------

  # One record of the log. `form` is 'grouped' | 'rolling_sql' | 'summary' (a class D summary: the decision only
  # goes to the agent's brief, its SQL is not touched).
  def log_entry(page:, summary:, decision:, form:, live_element: nil)
    counts = decision['counts'] || {}
    carry = decision['carry']
    reason = log_reason(decision, form)
    {
      'page' => page, 'summary' => summary, 'form' => form,
      'base' => counts['base'], 'counts' => decision['sizes'] || counts.reject { |k, _| META_KEYS.include?(k) },
      'combined_rows' => decision['combined_rows'], 'stepped_back' => decision['stepped_back'],
      'density' => counts['density'], 'dense' => decision['dense'],
      'carry' => carry, 'live' => decision['live'] ? true : false, 'live_element' => live_element,
      'reason' => reason, 'tradeoff' => tradeoff(decision, form, summary, live_element)
    }
  end

  def log_reason(decision, form)
    return 'no slicer needs carrying' if decision['carry'].empty? && !decision['live'] && (decision['sizes'] || {}).empty?
    if decision['live']
      if form == 'grouped' && decision['stepped_back']
        SPARSE
      else
        NEEDS_LIVE
      end
    else
      "every slicer column fits within #{decision['factor']}x the summary's size"
    end
  end

  def tradeoff(decision, form, summary, live_element)
    carried = decision['carry']
    parts = []
    unless carried.empty?
      base = decision['counts']['base']
      growth = base.to_f.positive? ? format('%.1f', decision['combined_rows'].to_f / base) : '?'
      parts << "#{summary} carries #{carried.join(', ')} as extra columns, about #{growth}x its row count" \
               "; the chart sums them, so a pick filters the pre-computed numbers."
    end
    if decision['live']
      parts << "#{live_element || summary + LIVE_SUFFIX} runs the summary's SQL with the picks applied to the fact rows, " \
               'so the numbers are exact but it runs on every pick instead of reading the pre-computed table.'
    end
    parts << "#{summary} is left unchanged." if form == 'summary'
    parts.join(' ')
  end

  def write_log(path, entries)
    File.write(path, JSON.pretty_generate('generated_by' => 'pbi_slicer_carry', 'summaries' => entries) + "\n")
    path
  end
end
