# frozen_string_literal: true
#
# PbiShapeRun -- the orchestrator-side driver of the opt-in `--model-shape pbi` data model (Task 18a).
#
# migrate-powerbi.rb calls `run!` once. It
#   1. derives the inputs `PbiShapedModel.apply!` needs from the report (R40 grains, the A/B measures that
#      share a visual with a class C measure),
#   2. runs the warehouse key check (key_check_queries) and the slicer-carry counts through a `probe`
#      callable (live: sigma-sql-probe.py; offline: a replay file), never guessing a count,
#   3. re-runs apply! from a deep copy of the PRE-transform converter output with the key results and the
#      slicer-carry decisions, and
#   4. returns the shaped model plus the four JSON documents the run writes.
#
# `probe` is a callable (stage, {key => sql}) -> {key => result Hash or nil} (nil = no result), or nil when
# no probe is available. A result is the sigma-sql-probe row shape {"ok"=>true,"rows"=>[{"COL"=>v}]}, a bare
# Hash of the values, or a bare number.
# Pure Ruby 2.6 apart from `live_probe` (Open3 + the sigma-sql-probe.py subprocess).
require 'json'
require 'open3'
require 'fileutils'
require 'date'
require_relative 'pbi_shaped_model'
require_relative 'pbi_measure_class'
require_relative 'pbi_time_intel_gen'
require_relative 'pbi_slicer_carry'
require_relative 'pbi_direct_map'
require_relative 'pbi_date_fields'
require_relative 'pbi_direct_sources'
require_relative 'layout'

module PbiShapeRun
  module_function

  S = PbiShapedModel
  G = PbiTimeIntelGen
  C = PbiSlicerCarry

  KEY_SKIPPED = 'key check skipped: no --probe-sources'

  # The key check could not be verified for some relationship and --allow-unverified-keys was not given.
  class ProbeFailure < StandardError; end
  CARRY_SKIPPED = 'slicer carry skipped: no probe results (--probe-sources or --shape-probe-results); ' \
                  'charts on those pages read the uncarried summary'
  GRAIN_RANK = { 'day' => 0, 'month' => 1, 'quarter' => 2, 'year' => 3 }.freeze

  def deep_copy(obj)
    Marshal.load(Marshal.dump(obj))
  end

  # ---------------------------------------------------------------------------------------
  # Inputs derived from the report
  # ---------------------------------------------------------------------------------------

  def visuals_of(signals)
    Array((signals || {})['pages']).flat_map do |pg|
      Array(pg['visuals']).map { |v| [pg, v] }
    end
  end

  def bound_fields(visual)
    (visual['bindings'] || {}).values.flatten.compact.map(&:to_s)
  end

  # Date-axis field -> grain (R40, I2): the unit of a date-table field whose values provably equal that calendar level
  # (PbiDateFields: Date, a calculated Month Start, an integer Year / Quarter / Month Number). A fiscal, key, name or
  # unproven column is not an axis grain (nil; PbiDirectMap.date_field_visuals holds such a visual back).
  def grain_of_field(column, table = nil, infos = nil)
    i = infos ? infos[[table.to_s.downcase, column.to_s.downcase]] : PbiDateFields.info(column)
    i && i['unit']
  end

  # {"Table.Measure" => grain} for each class C measure read on a visible visual: the grain of that visual's
  # date-axis field (a field of the date table); the finest grain wins when a measure sits on several visuals;
  # month when no visual gives one.
  def derive_grains(signals, classes, date_table, tmsl = nil)
    infos = tmsl ? PbiDateFields.infos(tmsl, [date_table]) : nil
    out = {}
    classes.each { |key, c| out[key] = nil if c['class'] == 'C' }
    visuals_of(signals).each do |_pg, v|
      next if v['visual_type'] == 'slicer' || v['sigma_kind'] == 'control'
      fields = bound_fields(v)
      measures = fields.select { |f| out.key?(f) }
      next if measures.empty?
      grain = fields.map do |f|
        tbl, col = f.split('.', 2)
        tbl.to_s.casecmp(date_table.to_s).zero? ? grain_of_field(col, tbl, infos) : nil
      end.compact.min_by { |g| GRAIN_RANK[g] }
      next unless grain
      measures.each { |m| out[m] = grain if out[m].nil? || GRAIN_RANK[grain] < GRAIN_RANK[out[m]] }
    end
    out.each_with_object({}) { |(k, g), h| h[k] = g || 'month' }
  end

  # {"<fact>" => {"<grain>" => ["A metric name", ...]}}: the class A/B measures on a visual with a class C
  # measure of the same fact, at that measure's grain.
  def derive_extra_measures(signals, classes, grains)
    out = {}
    visuals_of(signals).each do |_pg, v|
      next if v['visual_type'] == 'slicer' || v['sigma_kind'] == 'control'
      fields = bound_fields(v)
      cs = fields.select { |f| classes[f] && classes[f]['class'] == 'C' }
      next if cs.empty?
      cs.each do |c|
        fact = classes[c]['home']
        grain = grains[c]
        next if fact.to_s.empty? || grain.nil?
        fields.each do |f|
          cl = classes[f]
          next unless cl && %w[A B].include?(cl['class']) && cl['home'] == fact
          name = f.split('.', 2)[1]
          list = (out[fact] ||= {})[grain] ||= []
          list << name unless list.include?(name)
        end
      end
    end
    out
  end

  # ---------------------------------------------------------------------------------------
  # Probe plumbing
  # ---------------------------------------------------------------------------------------

  # A probe callable that replays a captured results file ({"<key>" => result}); a key it lacks is nil.
  def replay_probe(path)
    data = JSON.parse(File.read(path))
    ->(_stage, queries) { queries.keys.each_with_object({}) { |k, h| h[k] = data[k] } }
  end

  # A probe callable that runs the queries through sigma-sql-probe.py. A warehouse error comes back as an
  # {"ok"=>false} result for that key (the caller treats it as no result).
  def live_probe(py_argv, script, connection:, folder:, dialect:, work:)
    lambda do |stage, queries|
      dir = File.join(work, 'shape-probe')
      FileUtils.mkdir_p(dir)
      qpath = File.join(dir, "#{stage}-queries.json")
      rpath = File.join(dir, "#{stage}-results.json")
      File.write(qpath, JSON.pretty_generate(queries))
      File.chmod(0o600, qpath) # queries embed the model's SQL
      FileUtils.rm_f(rpath)
      # --cleanup deletes the scratch workbook this run created. No --cache: every rerun re-probes the warehouse,
      # so a key check or freshness compare never passes on counts from an earlier run.
      cmd = [*py_argv, script, '--connection-id', connection, '--folder-id', folder, '--in', qpath, '--out', rpath,
             '--dialect', dialect, '--state', File.join(dir, "#{stage}-state.json"), '--cleanup']
      _out, err, st = Open3.capture3(*cmd)
      results = File.exist?(rpath) ? (JSON.parse(File.read(rpath)) rescue {}) : {}
      # a failed probe is never "no result": every key that did not come back ok carries sigma-sql-probe's
      # failure text, so the caller can stop with it (R: probe failures are loud)
      tail = err.lines.map(&:strip).reject(&:empty?).last(5).join(' | ')
      queries.each_key do |k|
        r = results[k]
        next if r.is_a?(Hash) && r['ok'] != false
        results[k] = { 'ok' => false, 'error' => (r.is_a?(Hash) && r['error']) || "sigma-sql-probe.py exit #{st.exitstatus}: #{tail}" }
      end
      results
    end
  end

  # ---------------------------------------------------------------------------------------
  # Phase 6 source-freshness compare (bead fmte), shared by both shapes
  # ---------------------------------------------------------------------------------------

  # MATCH / STALE-EXPLAINED / DIVERGENT for one table: the warehouse (Sigma, live) row count and per-column max dates
  # against the Power BI import snapshot. `wh_maxes` is {pbi date column => the warehouse max}, holding only the
  # columns whose warehouse max is known. Returns [class, table, message].
  def classify_freshness(table, snap, wh_rows, wh_maxes, stale_days:, creds_suspect:, failures:)
    pbi_rows = snap['rows']
    date_note = nil
    newer_dates = false
    (snap['maxDates'] || {}).each do |dcol, pbi_max|
      next if pbi_max.nil?
      wh_max = (wh_maxes || {})[dcol]
      next if wh_max.nil?
      pd = (Date.parse(pbi_max.to_s) rescue nil)
      wd = (Date.parse(wh_max.to_s) rescue nil)
      next unless pd && wd
      if wd > pd
        newer_dates = true
        date_note = "max(#{dcol}) warehouse=#{wd} vs PBI=#{pd}"
      end
    end
    stale_or_failed = (stale_days && stale_days >= 1) || creds_suspect || Array(failures).any?
    if wh_rows == pbi_rows && !newer_dates
      ['MATCH', table, "rows=#{wh_rows} (warehouse == PBI snapshot)"]
    elsif wh_rows >= pbi_rows
      why = stale_or_failed ? 'stale/failed-refresh snapshot explains it' : 'warehouse moved since the refresh'
      delta = wh_rows - pbi_rows
      msg = "Sigma will show more data: warehouse rows=#{wh_rows} vs PBI snapshot=#{pbi_rows}" \
            "#{delta.positive? ? " (+#{delta})" : ''}#{date_note ? "; #{date_note}" : ''} — #{why}"
      ['STALE-EXPLAINED', table, msg]
    else
      ['DIVERGENT', table,
       "warehouse rows=#{wh_rows} < PBI snapshot=#{pbi_rows} — Sigma shows LESS data " \
       'than the source snapshot; check the table/path mapping']
    end
  end

  # pbi shape: one count (+ max of each snapshot date column) query per Power BI table, run at the table's data
  # model source (a pbi workbook has no Data page to export). Returns
  #   {table => {'key' => "fresh:<table>", 'sql' => ..., 'date_cols' => {pbi column => sql alias}}} or {table => {'skip' => reason}}
  def freshness_queries(dm_spec_doc, tmsl, snapshot, dialect)
    doc = dm_spec_doc || {}
    doc = doc['document'] || doc['contents'] || doc
    els = S.elements_of(doc)
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    tmsl_tables = S.tables_of(tmsl)
    out = {}
    (snapshot || {}).each do |table, snap|
      el = els.find { |e| e['name'].to_s.casecmp(table.to_s).zero? }
      unless el
        out[table] = { 'skip' => "no data model element named #{table}" }
        next
      end
      root = el
      seen = []
      while root.dig('source', 'kind') == 'table' && (nxt = by_id[root.dig('source', 'elementId')]) && !seen.include?(nxt['id'])
        seen << root['id']
        root = nxt
      end
      src = root['source'] || {}
      from =
        case src['kind']
        when 'warehouse-table' then Array(src['path']).map { |part| S.quote_ident(part, dialect) }.join('.')
        when 'sql' then "(\n#{src['statement'].to_s.strip.sub(/;+\s*\z/, '').rstrip}\n) AS t" # m1: a trailing -- comment must not swallow the )
        end
      if from.nil? || from.empty?
        out[table] = { 'skip' => "#{root['name']} is not a warehouse table or Custom SQL element" }
        next
      end
      tt = tmsl_tables.find { |t| t['name'].to_s.casecmp(table.to_s).zero? } || {}
      date_cols = {}
      notes = []
      maxes = []
      (snap['maxDates'] || {}).each_key do |dcol|
        col = Array(tt['columns']).find { |c| c['name'].to_s.casecmp(dcol.to_s).zero? }
        sc = col && col['sourceColumn'].to_s
        if sc.nil? || sc.empty?
          notes << "date compare skipped for #{dcol}: #{col ? 'no sourceColumn in the model' : 'no matching model column'}"
          next
        end
        # the warehouse spells the column in its own casing (UPPER on Snowflake): resolve the root element's physical
        # column by a case-insensitive match on sourceColumn, as pbi_column_for does
        pcol = Array(root['columns']).find { |c| S.physical_column?(c) && S.physical_name(c).to_s.casecmp(sc).zero? }
        tok = pcol && S.key_column_token(root, pcol)
        if tok.nil? || tok.empty?
          notes << "date compare skipped for #{dcol}: no physical column #{sc} on #{root['name']}"
          next
        end
        al = "D#{date_cols.size}"
        maxes << "MAX(#{S.quote_ident(tok, dialect)}) AS \"#{al}\""
        date_cols[dcol] = al
      end
      entry = { 'key' => "fresh:#{table}", 'sql' => "SELECT COUNT(*) AS \"N\" FROM #{from}", 'date_cols' => date_cols, 'notes' => notes }
      # a separate query: a bad date column can never cost the row count
      unless maxes.empty?
        entry['date_key'] = "fresh:#{table}:dates"
        entry['date_sql'] = "SELECT #{maxes.join(', ')} FROM #{from}"
      end
      out[table] = entry
    end
    out
  end

  # Runs the freshness_queries through `probe` (stage, {key => sql}) -> {key => result}. Returns
  #   {table => {'rows' => n, 'maxDates' => {pbi column => max}}} or {table => {'skip' => reason}};
  # a failed or missing probe result is a skip with the probe's error text, never a zero.
  def freshness_counts(probe, queries)
    runnable = queries.reject { |_t, q| q['skip'] }
    sql = {}
    runnable.each_value do |q|
      sql[q['key']] = q['sql']
      sql[q['date_key']] = q['date_sql'] if q['date_key']
    end
    raw = sql.empty? ? {} : (probe.call('freshness', sql) || {})
    queries.each_with_object({}) do |(table, q), h|
      if q['skip']
        h[table] = { 'skip' => q['skip'] }
        next
      end
      res = raw[q['key']]
      n = number_of(res, 'n')
      if row_of(res).nil? || n.nil?
        err = res.is_a?(Hash) && res['ok'] == false ? res['error'].to_s : nil
        h[table] = { 'skip' => err && !err.empty? ? "freshness probe failed: #{err[0, 160]}" : 'freshness probe returned no result' }
        next
      end
      notes = Array(q['notes']).dup
      maxes = {}
      if q['date_key']
        dres = raw[q['date_key']]
        drow = row_of(dres)
        if drow.nil?
          derr = dres.is_a?(Hash) && dres['ok'] == false ? dres['error'].to_s[0, 120] : 'no result'
          notes << "date compare skipped: dates query failed (#{derr})"
        else
          q['date_cols'].each { |pcol, al| maxes[pcol] = drow[al.downcase] unless drow[al.downcase].nil? }
        end
      end
      h[table] = { 'rows' => n, 'maxDates' => maxes, 'notes' => notes }
    end
  end

  # The numbers of a probe result: {col(lowercase) => value} of its first row, or nil when it did not succeed.
  def row_of(result)
    return nil if result.nil?
    return { 'n' => result } if result.is_a?(Numeric)
    return nil unless result.is_a?(Hash)
    return nil if result['ok'] == false
    row = result['rows'].is_a?(Array) ? result['rows'][0] : result
    return nil unless row.is_a?(Hash)
    row.each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v }
  end

  def number_of(result, col = nil)
    row = row_of(result)
    return nil unless row
    v = col ? row[col.to_s.downcase] : (row['n'] || row['dup'] || row.values.first)
    v.nil? ? nil : v.to_i
  end

  # {"<from>-><relationship>" => dup} for the keys that returned a number.
  def key_results_from(raw)
    raw.each_with_object({}) do |(k, r), h|
      n = number_of(r, 'dup')
      h[k] = n unless n.nil?
    end
  end

  # ---------------------------------------------------------------------------------------
  # Slicer carry
  # ---------------------------------------------------------------------------------------

  def find_el(dm_model, name)
    S.elements_of(dm_model).find { |e| e['name'].to_s.casecmp(name.to_s).zero? }
  end

  def trunc_sql(unit, expr, dialect)
    case dialect
    when 'bigquery' then "DATE_TRUNC(#{expr}, #{unit.upcase})"
    else "DATE_TRUNC('#{unit}', #{expr})"
    end
  end

  # A slicer field -> a carry column spec, or [nil, reason] when it cannot be carried (the page then needs the
  # live element). Carryable: a physical column of the fact itself or of a table one relationship away.
  #   {'field','name','formula' (grouped), 'sql' => {'name','expr','join'} (rolling), 'sql_probe' => same, 'alias'}
  def slicer_column(dm_model, fact, field, aliases, dialect)
    tbl, col = field.split('.', 2)
    el = find_el(dm_model, tbl)
    return [nil, "table #{tbl} is not a data model element"] unless el
    column = S.column_named(el, col)
    return [nil, "column #{col} not found on #{el['name']}"] unless column
    return [nil, "column #{col} of #{el['name']} is not a physical warehouse column"] unless S.physical_column?(column)
    name = S.display_name(column)
    q = ->(n) { S.quote_ident(n, dialect) }
    tok = S.key_column_token(el, column)
    base = G.underlying(dm_model, fact)
    if el.equal?(fact) || el.equal?(base)
      ftok = G.physical_token(dm_model, fact, name)
      return [{ 'field' => field, 'name' => name, 'formula' => "[#{fact['name']}/#{name}]",
                'sql' => { 'name' => name, 'expr' => "f.#{q.call(ftok)}" } }, nil]
    end
    path = S.path_to_table(dm_model, fact, el['name'])
    return [nil, "no relationship path from #{fact['name']} to #{el['name']}"] unless path
    return [nil, "#{el['name']} is #{path.length} relationships from #{fact['name']}; carry needs one"] unless path.length == 1
    rel = S.find_relationship(fact, path[0], S.by_id_map(dm_model))
    return [nil, "relationship #{path[0]} has a composite key"] unless rel && Array(rel['keys']).length == 1
    fkey = S.column_by_id(fact, rel['keys'][0]['sourceColumnId'])
    dkey = S.column_by_id(el, rel['keys'][0]['targetColumnId'])
    return [nil, 'relationship key columns not found'] unless fkey && dkey
    ftok = G.physical_token(dm_model, fact, S.display_name(fkey))
    dtok = S.key_column_token(el, dkey)
    return [nil, "key of #{el['name']} is not a physical column"] unless dtok && tok
    al = (aliases[el['name']] ||= "cd#{aliases.length}") # one join per dimension table, shared by its slicer fields
    join = { 'sql' => G.element_sql(el, dialect), 'alias' => al, 'on' => "#{al}.#{q.call(dtok)} = f.#{q.call(ftok)}" }
    [{ 'field' => field, 'name' => name, 'formula' => "[#{fact['name']}/#{path[0]}/#{name}]",
       'sql' => { 'name' => name, 'expr' => "#{al}.#{q.call(tok)}", 'join' => join } }, nil]
  end

  # SQL exposing the slicer columns beside the summary's grain, in the form size_queries counts.
  #   rolling  dense day spine x distinct carried combinations (the carried summary's rows, without the windows)
  #   grouped  one row per fact row with its period and the carried columns
  # Returns [sql, grain_columns, period_sql] or [nil, nil, reason].
  def probe_sql(dm_model, fact, summary_el, form, specs, dialect, date)
    q = ->(n) { S.quote_ident(n, dialect) }
    path = S.path_to_table(dm_model, fact, date[:el]['name'])
    return [nil, nil, "#{fact['name']} has no relationship path to #{date[:el]['name']}"] unless path && path.length == 1
    rel = S.find_relationship(fact, path[0], S.by_id_map(dm_model))
    return [nil, nil, 'the date relationship has a composite key'] unless rel && Array(rel['keys']).length == 1
    fkey = S.column_by_id(fact, rel['keys'][0]['sourceColumnId'])
    dkey = S.column_by_id(date[:el], rel['keys'][0]['targetColumnId'])
    dcol = S.column_named(date[:el], date[:col])
    return [nil, nil, 'date key columns not found'] unless fkey && dkey && dcol
    ftok = G.physical_token(dm_model, fact, S.display_name(fkey))
    dtok = S.key_column_token(date[:el], dkey)
    date_tok = S.physical_column?(dcol) ? S.key_column_token(date[:el], dcol) : nil
    return [nil, nil, 'date key or date column is not physical'] unless dtok && date_tok
    base = G.underlying(dm_model, fact)
    fact_sql = G.element_sql(base, dialect)
    sel = specs.map { |s| "#{s['sql']['expr']} AS #{q.call(s['name'])}" }
    joins = specs.map { |s| s['sql']['join'] }.compact.uniq
                 .map { |j| " LEFT JOIN (\n#{C.strip(j['sql'])}\n) #{j['alias']} ON #{j['on']}" }.join
    if form == 'rolling_sql'
      combos = "SELECT DISTINCT #{sel.join(', ')} FROM (\n#{C.strip(fact_sql)}\n) f#{joins}"
      names = specs.map { |s| "c.#{q.call(s['name'])} AS #{q.call(s['name'])}" }
      sql = "SELECT d.#{q.call('DAY')} AS #{q.call('DAY')}, #{names.join(', ')} " \
            "FROM (SELECT DISTINCT dd.#{q.call(date_tok)} AS #{q.call('DAY')} FROM (\n#{C.strip(G.element_sql(date[:el], dialect))}\n) dd) d " \
            "CROSS JOIN (#{combos}) c"
      [sql, ['DAY'], nil]
    else
      units = Array(summary_el['columns']).map { |c| c['formula'].to_s[/\ADateTrunc\("(\w+)"/, 1] }.compact
      return [nil, nil, "grain of #{summary_el['name']} not found"] if units.empty?
      trunc = trunc_sql(units.last, "dd.#{q.call(date_tok)}", dialect)
      sql = "SELECT #{trunc} AS #{q.call('PBI_PERIOD')}#{sel.empty? ? '' : ', ' + sel.join(', ')} " \
            "FROM (\n#{C.strip(fact_sql)}\n) f JOIN (\n#{C.strip(G.element_sql(date[:el], dialect))}\n) dd " \
            "ON dd.#{q.call(dtok)} = f.#{q.call(ftok)}#{joins}"
      [sql, ['PBI_PERIOD'], q.call('PBI_PERIOD')]
    end
  end

  # Measure the summary with the slicer columns carried (two probe rounds) and decide. Returns
  # [decision, nil] or [nil, reason] (no decision without every needed count).
  def measure(probe, key_prefix, sql, grain, period, cols, dialect, grouped)
    q1 = C.size_queries(sql, cols, dialect: dialect, grain: grain, period: period)
    r1 = probe.call('carry-1', q1.map { |k, v| ["#{key_prefix}:#{k}", v] }.to_h)
    counts = {}
    q1.each_key do |k|
      n = number_of(r1["#{key_prefix}:#{k}"])
      return [nil, "no count for #{k}"] if n.nil?
      counts[k] = n
    end
    return [nil, 'the summary has no rows'] unless counts['base'].positive?
    order = C.carry_order(counts)
    q2 = C.size_queries(sql, cols, dialect: dialect, grain: grain, period: period, order: order).reject { |k, _| q1.key?(k) }
    r2 = q2.empty? ? {} : probe.call('carry-2', q2.map { |k, v| ["#{key_prefix}:#{k}", v] }.to_h)
    counts['combined'] = {}
    counts['density'] = {}
    q2.each_key do |k|
      key = "#{key_prefix}:#{k}"
      if k.start_with?('density:')
        row = row_of(r2[key])
        next if row.nil? || row['present'].nil? || row['expected'].nil?
        counts['density'][k.sub('density:', '')] = { 'present' => row['present'].to_i, 'expected' => row['expected'].to_i }
      else
        n = number_of(r2[key])
        counts['combined'][k.sub('prefix:', '')] = n unless n.nil?
      end
    end
    [C.decide(counts, grouped: grouped), nil]
  rescue C::MissingCount => e
    [nil, e.message]
  end

  # ---------------------------------------------------------------------------------------
  # Time-axis density (Task 21z2)
  # ---------------------------------------------------------------------------------------
  # A grouped class C element has rows only for periods that have fact rows. Power BI shows every Date-table period that
  # any measure is non-blank in: TOTALYTD is flat after the last sale (to the end of the Date table's year), a prior-year
  # read shows months whose prior-year month had sales, and a no-axis PY shifts the whole set of Date-table dates in scope.
  # So when the Date table has periods in range with no fact rows, the grouped element misses chart points and a summed
  # no-axis PY undercounts. The probe compares, at the element's grain:
  #   EXPECTED  the Date-table periods from the fact's FIRST period (through the active date relationship) to the Date table's
  #             last date
  #   PRESENT   the distinct fact periods in that range
  # EXPECTED > PRESENT: the fact is sparse on the time axis (trailing periods, a year-end Date table, or gaps).
  DENSITY_NOT_VERIFIED = 'time-axis density not verified'

  # [sql, nil] or [nil, reason]. One row: EXPECTED, PRESENT.
  def density_query(dm_model, fact, grain, dialect, date)
    q = ->(n) { S.quote_ident(n, dialect) }
    path = S.path_to_table(dm_model, fact, date[:el]['name'])
    return [nil, "#{fact['name']} has no relationship path to #{date[:el]['name']}"] unless path && path.length == 1
    rel = S.find_relationship(fact, path[0], S.by_id_map(dm_model))
    return [nil, 'the date relationship has a composite key'] unless rel && Array(rel['keys']).length == 1
    fkey = S.column_by_id(fact, rel['keys'][0]['sourceColumnId'])
    dkey = S.column_by_id(date[:el], rel['keys'][0]['targetColumnId'])
    dcol = S.column_named(date[:el], date[:col])
    return [nil, 'date key columns not found'] unless fkey && dkey && dcol
    begin
      ftok = G.physical_token(dm_model, fact, S.display_name(fkey))
      fact_sql = G.element_sql(G.underlying(dm_model, fact), dialect)
      date_sql = G.element_sql(date[:el], dialect)
    rescue G::Unbuildable => e
      return [nil, e.message]
    end
    dtok = S.key_column_token(date[:el], dkey)
    date_tok = S.physical_column?(dcol) ? S.key_column_token(date[:el], dcol) : nil
    return [nil, 'date key or date column is not physical'] unless dtok && date_tok
    period = q.call('PBI_PERIOD')
    sql = "WITH pbi_fact_periods AS (\n" \
          "SELECT DISTINCT #{trunc_sql(grain, "dd.#{q.call(date_tok)}", dialect)} AS #{period} FROM (\n#{C.strip(fact_sql)}\n) f JOIN (\n" \
          "#{C.strip(date_sql)}\n) dd ON dd.#{q.call(dtok)} = f.#{q.call(ftok)}\n)\n" \
          "SELECT (SELECT COUNT(DISTINCT #{trunc_sql(grain, "d.#{q.call(date_tok)}", dialect)}) FROM (\n#{C.strip(date_sql)}\n) d " \
          "WHERE #{trunc_sql(grain, "d.#{q.call(date_tok)}", dialect)} >= (SELECT MIN(#{period}) FROM pbi_fact_periods)) AS #{q.call('EXPECTED')}, " \
          "(SELECT COUNT(*) FROM pbi_fact_periods) AS #{q.call('PRESENT')}"
    [sql, nil]
  end

  # Probe every (fact, grain) a grouped class C element of the first-pass model uses. Returns
  #   {'time_density' => {fact => {grain => {'sparse','expected','present'}}}   (measured only)
  #    'facts' => {fact => {grain => {'verified' => bool, 'sparse' =>, 'expected' =>, 'present' =>, 'reason' => (unverified)}}}
  #    'queries' => {key => sql}, 'results' => {key => raw}, 'notes' => [...]}
  # No probe, no query (no path to the date table) or no usable result: unverified, said loudly (a note, and limits.md); the
  # grouped element is still built (today's behaviour).
  def density_plan(dm_model, classes, ti_records, tmsl, probe, dialect)
    out = { 'time_density' => {}, 'facts' => {}, 'queries' => {}, 'results' => {}, 'notes' => [] }
    # m13: each record is probed against its OWN date table (its class entry's ti.date_table), not the first one;
    # {fact => {grain => [date table names]}}
    default_date = nil
    wanted = {}
    Array(ti_records).select { |r| r['form'] == 'grouped' && r['period'] }.each do |r|
      fact_name = classes.dig(r['measure'], 'home')
      next unless fact_name
      default_date ||= S.date_element_for(classes.select { |_k, c| c['class'] == 'C' }, tmsl).first
      dt = classes.dig(r['measure'], 'ti', 'date_table') || default_date
      tables = ((wanted[fact_name] ||= {})[r['period'].to_s.downcase] ||= [])
      tables << dt unless tables.include?(dt)
    end
    return out if wanted.empty?
    queries = {}
    skips = {}
    query_keys = {} # [fact, grain] => [probe keys]
    unless probe
      wanted.each { |f, gs| gs.each_key { |g| skips[[f, g]] = 'no probe results (--probe-sources or --shape-probe-results)' } }
    end
    if probe
      wanted.each do |f, gs|
        fact = find_el(dm_model, f)
        gs.each do |g, dts|
          dts.each do |dt|
            # the key stays "density:<fact>:<grain>" when one date table serves the pair (probe-result files use it)
            key = dts.length == 1 ? "density:#{f}:#{g}" : "density:#{f}:#{g}:#{dt}"
            begin
              date = G.date_config(dm_model, dt)
            rescue ArgumentError => e
              skips[[f, g]] ||= e.message
              next
            end
            sql, why = fact ? density_query(dm_model, fact, g, dialect, date) : [nil, "fact element #{f} not found"]
            if sql
              queries[key] = sql
              (query_keys[[f, g]] ||= []) << key
            else
              skips[[f, g]] ||= why
            end
          end
        end
      end
    end
    raw = queries.empty? ? {} : probe.call('density', queries)
    out['queries'] = queries
    wanted.each do |f, gs|
      gs.each_key do |g|
        rec = {}
        if skips.key?([f, g])
          rec = { 'verified' => false, 'reason' => skips[[f, g]] }
        else
          recs = query_keys[[f, g]].map do |key|
            out['results'][key] = raw[key]
            row = row_of(raw[key])
            exp = row && row['expected']
            pres = row && row['present']
            if exp.nil? || pres.nil?
              err = raw[key].is_a?(Hash) && raw[key]['error']
              { 'verified' => false, 'reason' => err || 'the probe returned no result' }
            else
              { 'verified' => true, 'expected' => exp.to_i, 'present' => pres.to_i, 'sparse' => exp.to_i > pres.to_i }
            end
          end
          bad = recs.find { |x| !x['verified'] }
          # several date tables on one (fact, grain): the sparsest one decides (any sparse table moves the pair to D)
          rec = bad || recs.max_by { |x| x['expected'] - x['present'] }
          (out['time_density'][f] ||= {})[g] = rec.reject { |k, _| k == 'verified' } if rec['verified']
        end
        (out['facts'][f] ||= {})[g] = rec
        out['notes'] << "#{f} at #{g} grain: #{DENSITY_NOT_VERIFIED} (#{rec['reason']}); a Date table with #{g} periods that have no #{f} rows would show gaps in the grouped element" unless rec['verified']
        out['notes'] << "#{f} at #{g} grain: sparse time axis (#{rec['present']} of #{rec['expected']} Date-table #{g}s have rows); its grouped class C measures move to class D" if rec['sparse']
      end
    end
    out
  end

  # Plan the slicer carry for the model as the first apply! pass built it. Returns
  #   {'slicer_carry' => {fact => cfg} | {}, 'entries' => [log entries], 'notes' => [strings]}
  def carry_plan(dm_model, signals, classes, ti_records, tmsl, probe, dialect)
    notes = []
    summaries = ti_records.select { |r| %w[grouped rolling_sql].include?(r['form']) }.group_by { |r| r['element'] }
    return { 'slicer_carry' => {}, 'entries' => [], 'notes' => notes } if summaries.empty?
    return { 'slicer_carry' => {}, 'entries' => [], 'notes' => [CARRY_SKIPPED] } unless probe
    queries = {}
    inner = probe
    probe = lambda do |stage, q|
      queries.merge!(q)
      inner.call(stage, q)
    end
    date_name = S.date_element_for(classes.select { |_k, c| c['class'] == 'C' }, tmsl).first
    date = G.date_config(dm_model, date_name)
    by_fact = Hash.new { |h, k| h[k] = [] }
    summaries.each do |el_name, recs|
      fact_name = classes.dig(recs[0]['measure'], 'home')
      by_fact[fact_name] << [el_name, recs] if fact_name
    end
    carry = {}
    fields_by_fact = {}
    entries = []
    by_fact.each do |fact_name, sums|
      fact = find_el(dm_model, fact_name)
      next unless fact
      measures = sums.flat_map { |_n, recs| recs.map { |r| r['measure'] } }
      pages = Array((signals || {})['pages']).select do |pg|
        Array(pg['visuals']).any? { |v| v['visual_type'] != 'slicer' && (bound_fields(v) & measures).any? }
      end
      fields = pages.flat_map do |pg|
        Array(pg['visuals']).select { |v| v['visual_type'] == 'slicer' }.flat_map { |v| bound_fields(v) }
      end.uniq
      fields = fields.reject { |f| f.split('.', 2)[0].to_s.casecmp(date_name.to_s).zero? } # the date axis carries these
      next if fields.empty?
      specs = []
      uncarryable = []
      aliases = {}
      fields.each do |f|
        spec, why = slicer_column(dm_model, fact, f, aliases, dialect)
        spec ? specs << spec : uncarryable << { 'field' => f, 'reason' => why }
      end
      uncarryable.each { |u| notes << "#{fact_name}: slicer field #{u['field']} cannot be carried (#{u['reason']}); needs a live summary" }
      decisions = {}
      sums.each do |el_name, recs|
        form = recs[0]['form']
        el = find_el(dm_model, el_name)
        if specs.empty?
          decisions[el_name] = [nil, 'no carryable slicer field']
          next
        end
        sql, grain, period = probe_sql(dm_model, fact, el, form, specs, dialect, date)
        if sql.nil?
          decisions[el_name] = [nil, period]
          next
        end
        decisions[el_name] = measure(probe, "carry:#{el_name}", sql, grain, period, specs.map { |s| s['name'] }, dialect, form == 'grouped')
      end
      sums.each do |el_name, recs|
        dec, why = decisions[el_name]
        page_titles = pages.map { |p| p['page_title'] }.join(', ')
        if dec
          entries << C.log_entry(page: page_titles, summary: el_name, decision: dec, form: recs[0]['form'] == 'grouped' ? 'grouped' : 'rolling_sql')
        else
          notes << "#{el_name}: slicer carry not decided (#{why}); read uncarried, the page needs a live summary"
        end
      end
      made = decisions.values.map(&:first)
      if made.any?(&:nil?) || made.empty?
        carry[fact_name] = { 'columns' => [], 'live' => true, 'dense' => nil } unless specs.empty?
        next
      end
      first = made[0]['carry']
      common = made.map { |d| d['carry'] }.reduce(first) { |acc, c| acc & c }
      carried = common.map { |n| specs.find { |s| s['name'] == n } }.compact
      live = made.any? { |d| d['live'] } || !uncarryable.empty? || common.length < specs.length
      dense = made.map { |d| d['dense'] }.compact
      carry[fact_name] = { 'columns' => carried.map { |s| s.reject { |k, _| k == 'field' } }, 'live' => live,
                           'dense' => dense.empty? ? nil : dense.all? }
      fields_by_fact[fact_name] = carried.map { |s| { 'field' => s['field'], 'name' => s['name'] } }
    end
    { 'slicer_carry' => carry, 'entries' => entries, 'notes' => notes.uniq, 'queries' => queries, 'fields' => fields_by_fact }
  end

  # ---------------------------------------------------------------------------------------
  # Driver
  # ---------------------------------------------------------------------------------------

  # Runs the shaped transform on `dm_model` (replaced in place by the shaped model).
  #   probe  callable or nil (see the header); `flatten` the --flatten names; `multi_page` as apply!.
  # Returns the documents to write: {'log' =>, 'classes' =>, 'keys' =>, 'carry' =>, 'notes' => [...]}.
  def run!(dm_model, tmsl:, signals:, native_result:, dialect:, flatten: [], probe: nil, multi_page: true,
           allow_unverified_keys: false, skip_reason: nil)
    pre = deep_copy(dm_model)
    waivers = []
    notes = []
    model = (tmsl || {})['model'] || tmsl || {}
    classes0 = PbiMeasureClass.classify_all(signals || {}, tmsl, Array(model['relationships']))
    c0 = classes0.select { |_k, c| c['class'] == 'C' }
    date_table = c0.empty? ? 'Date' : S.date_element_for(c0, tmsl).first
    grains = derive_grains(signals, classes0, date_table, tmsl)
    extra = derive_extra_measures(signals, classes0, grains)
    apply = lambda do |key_results, slicer_carry, time_density = nil|
      m = deep_copy(pre)
      args = { tmsl: deep_copy(tmsl), signals: deep_copy(signals), native_result: deep_copy(native_result), dialect: dialect, flatten: flatten,
               key_results: key_results, grains: grains, multi_page: multi_page }
      args[:extra_measures] = extra
      args[:slicer_carry] = slicer_carry unless slicer_carry.nil? || slicer_carry.empty?
      args[:time_density] = time_density unless time_density.nil? || time_density.empty?
      [m, S.apply!(m, **args)]
    end

    # (d) key check: the queries come from the relationship graph the transform builds
    queries = {}
    key_raw = {}
    key_results = nil
    if probe
      first_pass, = apply.call(nil, nil)
      queries = S.key_check_queries(first_pass, dialect: dialect)
      key_raw = queries.empty? ? {} : probe.call('keys', queries)
      key_results = key_results_from(key_raw)
      missing = queries.keys - key_results.keys
      unless missing.empty?
        detail = missing.map { |k| "  - #{k}: #{(key_raw[k].is_a?(Hash) && key_raw[k]['error']) || 'no result (not in the probe results)'}" }
        unless allow_unverified_keys
          raise ProbeFailure, "the key check could not verify #{missing.size} relationship(s); a duplicated key would fan the data model out:\n" \
                              "#{detail.join("\n")}\nFix the probe, or accept the risk with --allow-unverified-keys."
        end
        notes << "key check: no result for #{missing.join(', ')}; those relationships were kept unverified (--allow-unverified-keys)"
        waivers << { 'flag' => '--allow-unverified-keys', 'relationships' => missing, 'errors' => detail }
      end
    else
      notes << (skip_reason || KEY_SKIPPED)
    end

    # (e) slicer carry on the summaries the first full pass built
    shaped, log = apply.call(key_results, nil)
    # (e0) time-axis density: a sparse (fact, grain) has no exact grouped element, so its grouped C measures go to D before the carry
    density = density_plan(shaped, log['classes'], log['time_intel'], tmsl, probe, dialect)
    notes.concat(density['notes'])
    sparse = density['time_density'].each_with_object({}) do |(f, gs), h|
      s = gs.select { |_g, d| d['sparse'] }
      h[f] = s unless s.empty?
    end
    shaped, log = apply.call(key_results, nil, sparse) unless sparse.empty?
    plan = carry_plan(shaped, signals, log['classes'], log['time_intel'], tmsl, probe, dialect)
    notes.concat(plan['notes'])
    unless plan['slicer_carry'].empty?
      shaped, log = apply.call(key_results, plan['slicer_carry'], sparse)
    end
    dm_model.clear
    dm_model.merge!(shaped)

    log['grains'] = grains
    log['extra_measures'] = extra
    log['time_density'] = { 'facts' => density['facts'], 'sparse' => sparse.each_with_object([]) { |(f, gs), a| gs.each_key { |g| a << { 'fact' => f, 'grain' => g } } } }
    log['notes'] = notes
    log['waivers'] = waivers
    keys_doc = { 'queries' => queries, 'results' => key_raw, 'decisions' => log['key_decisions'],
                 'dangling' => log['dangling_refs'], 'notes' => notes.select { |n| n.start_with?('key check') } }
    carry_doc = { 'generated_by' => 'pbi_slicer_carry', 'summaries' => plan['entries'], 'queries' => (plan['queries'] || {}).merge(density['queries']), 'density_results' => density['results'],
                  'applied' => plan['slicer_carry'].each_with_object({}) { |(f, c), h| h[f] = { 'carried' => c['columns'].map { |x| x['name'] }, 'live' => c['live'], 'dense' => c['dense'],
                                                                                  'fields' => Array((plan['fields'] || {})[f]) } },
                  'notes' => notes.select { |n| n =~ /slicer|carry/ } }
    { 'log' => log, 'classes' => { 'classes' => log['classes'], 'counts' => log['class_counts'] },
      'keys' => keys_doc, 'carry' => carry_doc, 'notes' => notes }
  end

  # Element names the connection grounding (convert-model.rb, non-friendly connections) reset after the shaped
  # transform: [{'from' => shaped name, 'to' => spec name}] by element id.
  def name_resets(shaped_model, spec)
    before = S.elements_of(shaped_model).each_with_object({}) { |e, h| h[e['id']] = e['name'] }
    S.elements_of(spec).each_with_object([]) do |e, out|
      b = before[e['id']]
      out << { 'from' => b, 'to' => e['name'] } if b && b != e['name']
    end
  end
  # Materialization inputs: [spec_elements, pbi_targets]. The pbi shape reads the POSTED data model spec document
  # (what dm_rb pairs with; it holds the page summaries integrate-page-fact.py adds to the file only); the views
  # shape keeps the in-memory dm_model and no targets.
  def materialization_inputs(shape, dm_model, posted_spec, shaped_log)
    if shape == 'pbi'
      [S.elements_of(posted_spec), S.materialize_targets(posted_spec, shaped_log)]
    else
      [S.elements_of(dm_model), nil]
    end
  end

  # ---------------------------------------------------------------------------------------
  # Workbook side (Task 18b)
  # ---------------------------------------------------------------------------------------

  LIVE_TYPED = %w[int64 double decimal].freeze

  # Phase 4 master map: PbiDirectMap.build over the shaped model and the REAL readback, then the alts that route
  # a carried slicer field to the summary table carrying it (so the builder wires the control to those charts).
  def direct_master_map(dm_model, dm_readback, tmsl, shaped_log, signals, carry_doc = nil)
    map = PbiDirectMap.build(dm_model, dm_readback, tmsl, shaped_log['classes'] || {}, time_intel: Array(shaped_log['time_intel']),
                             signals: signals, flattened: shaped_log['flattened'] || {})
    map['carried_alts'] = carried_alts!(map, shaped_log, carry_doc)
    # C2: page filters a rolling element cannot carry are known only now (the carried alts are in)
    PbiDirectMap.rolling_filter_visuals(signals, shaped_log['classes'] || {}, Array(shaped_log['time_intel']), map).each do |h|
      map['class_d_visuals'] << h unless map['class_d_visuals'].any? { |o| o['page'] == h['page'] && o['visual_id'] == h['visual_id'] }
    end
    map
  end

  # What pbi-shaped-model.json records under `direct_map`.
  def direct_map_log(map)
    { 'masters' => map['masters'].size, 'fields' => map['fields'].size, 'conflicts' => map['conflicts'],
      'unresolved' => map['unresolved'], 'class_d_fields' => map['class_d_fields'], 'class_d_visuals' => map['class_d_visuals'] || [],
      'carried_alts' => map['carried_alts'], 'asof_ignore_date' => map['asof_ignore_date'] || [] }
  end

  # Pages (titles) with a class D visual: a visible visual that reads a class D measure, or that needs two relationship
  # paths to one table (PbiMeasureClass.classify_visual), or that PbiDirectMap recorded as a conflict (`conflicts`, the
  # master-map's class_d_visuals/conflicts records). The default pages of --scaffold-page-facts.
  def class_d_pages(signals, classes, conflicts = [])
    d = (classes || {}).select { |_k, c| c['class'] == 'D' }.keys
    pages = Array((signals || {})['pages']).reject { |pg| pg['hidden'] }.select do |pg|
      Array(pg['visuals']).any? do |v|
        next false if v['hidden']
        (d.any? && (bound_fields(v) & d).any?) ||
          (classes && !classes.empty? && PbiMeasureClass.classify_visual(v, classes) == 'D')
      end
    end.map { |pg| pg['page_title'] }
    pages |= Array(conflicts).map { |c| c['page'] }
    pages.compact
  end

  # field "Table.Column" of a carried summary column name, for the summary of `fact`.
  def carried_field(map, carry_doc, fact, name, ti_elements)
    mapped = Array(((carry_doc || {})['applied'] || {}).dig(fact, 'fields')).find { |f| f['name'] == name }
    return mapped['field'] if mapped && map['fields'][mapped['field']]
    hits = map['fields'].keys.select { |k| k.split('.', 2)[1] == name && !ti_elements.include?(k.split('.', 2)[0]) }
    hits.length == 1 ? hits[0] : nil
  end

  # Adds an alt on the slicer field for the summary master that carries it. Returns [{element, column, field}] added
  # (and {element, column, skipped} when no field could be named).
  def carried_alts!(map, shaped_log, carry_doc)
    ti = Array(shaped_log['time_intel'])
    ti_elements = ti.map { |r| r['element'] }.uniq
    out = []
    ti.group_by { |r| r['element'] }.each do |el_name, recs|
      carried = recs.flat_map { |r| Array(r['carried']) }.uniq
      next if carried.empty?
      mkey, m = map['masters'].find { |_k, mm| mm['element_name'] == el_name }
      next unless m
      fact = (shaped_log['classes'] || {}).dig(recs[0]['measure'], 'home')
      carried.each do |col|
        field = carried_field(map, carry_doc, fact, col, ti_elements)
        unless field
          out << { 'element' => el_name, 'column' => col, 'skipped' => 'no slicer field could be named for this carried column' }
          next
        end
        target = map['fields'][field]
        alt = { 'master' => mkey, 'ref' => "[#{m['id']}/#{col}]", 'agg' => nil }
        map['fields'].each_value do |fs|
          PbiDirectMap.add_alt(fs, alt) if fs['master'] == target['master'] && fs['ref'] == target['ref']
        end
        out << { 'element' => el_name, 'column' => col, 'field' => field }
      end
    end
    out
  end

  # ---- layout ----------------------------------------------------------------------------

  LAYOUT_TOKEN = %r{<(/?)(Page|Container|Element)\b([^>]*?)(/?)>}.freeze

  # {page id => [element ids placed on it]} from the authoritative layout XML.
  def page_elements(layout_xml)
    out = {}
    page = nil
    layout_xml.to_s.scan(LAYOUT_TOKEN) do |close, tag, attrs, _self|
      if tag == 'Page'
        page = close.empty? ? attrs[/\bid="([^"]+)"/, 1] : nil
        out[page] ||= [] if page
      elsif page && !close.empty? && tag == 'Container'
        next
      elsif page && (id = attrs[/\belementId="([^"]+)"/, 1])
        out[page] << id
      end
    end
    out
  end

  # Places `element_id` once on page `page_id`: full width, below everything already on it. Returns the new XML, or
  # the same XML when the page is not in it.
  def place_element(layout_xml, page_id, element_id, rows: nil)
    rows ||= [SigmaLayout.min_rows_for('table'), 12].max
    page = nil
    depth = 0
    bottom = 1
    insert_at = nil
    layout_xml.scan(LAYOUT_TOKEN) do
      m = Regexp.last_match
      close, tag, attrs, selfclose = m[1], m[2], m[3], m[4]
      if tag == 'Page'
        if close.empty?
          page = attrs[/\bid="([^"]+)"/, 1]
          depth = 0
          bottom = 1
        else
          insert_at = m.begin(0) if page == page_id
          page = nil
        end
        next
      end
      next unless page == page_id
      if close.empty?
        if depth.zero?
          r = attrs[/\bgridRow="\s*(\d+)\s*\/\s*(\d+)\s*"/, 2]
          bottom = [bottom, r.to_i].max if r
        end
        depth += 1 if tag == 'Container' && selfclose.empty?
      elsif tag == 'Container'
        depth -= 1
      end
    end
    return layout_xml unless insert_at
    leaf = SigmaLayout.le(element_id, 1, 25, bottom, bottom + rows)
    "#{layout_xml[0...insert_at]}#{leaf}\n#{layout_xml[insert_at..-1]}"
  end

  # ---- live elements ----------------------------------------------------------------------

  # TMSL dataType of "Table.Column".
  def tmsl_type(tmsl, table, column)
    model = (tmsl || {})['model'] || tmsl || {}
    t = Array(model['tables']).find { |x| x['name'].to_s.casecmp(table.to_s).zero? }
    c = t && Array(t['columns']).find { |x| x['name'].to_s.casecmp(column.to_s).zero? }
    c && c['dataType'].to_s.downcase
  end

  # The live-element descriptor of one slicer control (PbiSlicerCarry.live_sql input): the slicer's attribute column
  # and the relationship hops from its table to the fact, each with the slicer-side table's SQL.
  # Returns [descriptor, nil] or [nil, reason].
  def live_descriptor(dm_model, fact, field, control_id, tmsl, dialect)
    tbl, col = field.split('.', 2)
    type = tmsl_type(tmsl, tbl, col)
    return [nil, "column type #{type || 'unknown'} is not supported by the live element"] unless type == 'string' || LIVE_TYPED.include?(type)
    el = find_el(dm_model, tbl)
    return [nil, "table #{tbl} is not a data model element"] unless el
    column = S.column_named(el, col)
    return [nil, "column #{col} not found on #{el['name']}"] unless column
    return [nil, "column #{col} of #{el['name']} is not a physical warehouse column"] unless S.physical_column?(column)
    desc = { 'control_id' => control_id, 'typed' => LIVE_TYPED.include?(type), 'blank' => !LIVE_TYPED.include?(type) }
    base = G.underlying(dm_model, fact)
    if el.equal?(fact) || el.equal?(base)
      desc['column'] = G.physical_token(dm_model, fact, S.display_name(column))
      desc['path'] = []
      return [desc, nil]
    end
    path = S.path_to_table(dm_model, fact, el['name'])
    return [nil, "no relationship path from #{fact['name']} to #{el['name']}"] unless path
    by_id = S.by_id_map(dm_model)
    cur = fact
    steps = []
    path.each do |rn|
      rel = S.find_relationship(cur, rn, by_id)
      tgt = rel && by_id[rel['targetElementId']]
      return [nil, "relationship #{rn} not found"] unless tgt
      return [nil, "relationship #{rn} has a composite key"] unless Array(rel['keys']).length == 1
      steps << [cur, rel, tgt]
      cur = tgt
    end
    tok = S.key_column_token(el, column)
    return [nil, "column #{col} has no warehouse token"] unless tok
    hops = steps.reverse.map do |src, rel, tgt|
      skey = S.column_by_id(src, rel['keys'][0]['sourceColumnId'])
      tkey = S.column_by_id(tgt, rel['keys'][0]['targetColumnId'])
      raise G::Unbuildable, "relationship #{rel['name']} key columns not found" unless skey && tkey
      to_col = src.equal?(fact) ? G.physical_token(dm_model, fact, S.display_name(skey)) : S.key_column_token(src, skey)
      from_col = S.key_column_token(tgt, tkey)
      raise G::Unbuildable, "relationship #{rel['name']} key is not a physical column" unless to_col && from_col
      { 'from_source' => "(\n#{G.element_sql(tgt, dialect)}\n)", 'from_col' => from_col, 'to_col' => to_col, 'type' => '1:M' }
    end
    desc['column'] = tok
    desc['path'] = hops
    [desc, nil]
  rescue G::Unbuildable => e
    [nil, e.message]
  end

  def decision_live?(carry_doc, fact, summary)
    doc = carry_doc || {}
    return true if doc.dig('applied', fact, 'live') == true
    Array(doc['summaries']).any? { |s| s['summary'] == summary && s['live'] == true }
  end

  # Applies the carried-slicer wiring (already in the builder's control targets, through carried_alts!), the live
  # elements and the date-slicer chart filters to the built workbook `spec` ({'document' => ...}), in place.
  #   scope           the builder's control-scope.json document (updated in place)
  #   dm_spec_doc     the posted data model spec (the summary's columns and Custom SQL connection)
  #   page_fact_live  nil, or a callable (workbook document) -> [{'page','summary','sql','controls','skipped'}]: the live SQL of
  #                   the class D page summaries (pbi-live-page-fact.py)
  # Live elements carry the NON-date slicers only: a date predicate on the fact rows would cut the rolling window, which
  # Power BI computes over the whole history; a date-table slicer instead filters the plotted days (a chart filter column
  # derived from the summary's day column).
  # Returns the `slicers` record of pbi-shaped-model.json:
  #   {'carried', 'live', 'date_filters', 'not_applied', 'unreached', 'changed'}.
  def apply_slicers!(spec, scope, dm_model, dm_spec_doc, dmap, shaped_log, carry_doc, tmsl, dialect, page_fact_live: nil)
    doc = spec['document'] || spec
    log = { 'carried' => [], 'live' => [], 'date_filters' => [], 'not_applied' => [], 'unreached' => [], 'changed' => false }
    ti = Array(shaped_log['time_intel'])
    ti_elements = ti.map { |r| r['element'] }.uniq
    spec_els = S.elements_of(dm_spec_doc || {})
    ti.group_by { |r| r['element'] }.each do |name, recs|
      carried = recs.flat_map { |r| Array(r['carried']) }.uniq
      log['carried'] << { 'summary' => name, 'columns' => carried } unless carried.empty?
    end
    by_id = doc['elements'].each_with_object({}) { |e, h| h[e['id']] = e }
    pages = page_elements(doc['layout'])
    page_name = doc['pages'].each_with_object({}) { |p, h| h[p['id']] = p['name'] }
    scope_by_cid = {}
    Array((scope || {})['controls']).each { |c| scope_by_cid[c['controlId']] = c if c['controlId'] }
    c_entries = (shaped_log['classes'] || {}).select { |_k, c| c['class'] == 'C' }
    date_table = c_entries.empty? ? nil : S.date_element_for(c_entries, tmsl).first
    page_controls = lambda do |ids|
      ids.map { |i| by_id[i] }.compact.select { |e| e['kind'] == 'control' }
    end
    # the control element that holds a control's filters (a synced copy mirrors its primary, same controlId)
    primary_of = lambda do |ctl|
      next ctl unless ctl['controlType'].to_s == 'synced'
      doc['elements'].find { |e| e['kind'] == 'control' && e['controlId'] == ctl['controlId'] && e['controlType'].to_s != 'synced' }
    end
    field_of = lambda { |ctl| (scope_by_cid[ctl['controlId']] || {})['sourceName'].to_s[/ column (.+)\z/, 1] }
    scope_reach = lambda do |controls, reader_ids|
      controls.each do |cid|
        sc = scope_by_cid[cid] or next
        sc['excluded'] = Array(sc['excluded']).reject { |x| reader_ids.include?(x['element']) }
        sc['scope'] = (Array(sc['scope']) + reader_ids).uniq # reached through the [controlId] reference / the filter column
      end
    end
    place_live = lambda do |live, pid|
      unless by_id.key?(live['id'])
        doc['elements'] << live
        by_id[live['id']] = live
        doc['layout'] = place_element(doc['layout'], pid, live['id'])
      end
    end

    # ---- rolling summaries: live element for uncarried non-date slicers, chart filters for date slicers ----------------
    ti.select { |r| r['form'] == 'rolling_sql' }.group_by { |r| r['element'] }.each do |name, recs|
      mkey, master = dmap['masters'].find { |_k, mm| mm['element_name'] == name }
      next unless master
      fact = (shaped_log['classes'] || {}).dig(recs[0]['measure'], 'home')
      live_wanted = decision_live?(carry_doc, fact, name)
      carried_fields = Array(recs[0]['carried']).map { |c| carried_field(dmap, carry_doc, fact, c, ti_elements) }.compact
      fact_el = find_el(dm_model, fact)
      sp = spec_els.find { |e| e['name'] == name }
      summary = sp && { 'id' => master['element_id'], 'name' => name, 'source' => sp['source'], 'columns' => sp['columns'] }
      day_col = sp && Array(sp['columns']).find { |c| c['name'].to_s =~ /\A(day|date)\z/i }
      pages.each do |pid, ids|
        readers = ids.map { |i| by_id[i] }.compact.reject { |e| e['kind'] == 'control' }.select { |e| summary && PbiDirectSources.reads_summary?(e, summary) }
        next if readers.empty?
        target_ref = name # what the readers' formulas name; becomes the live element's id after a repoint
        date_ctls = []
        descs = []
        page_controls.call(ids).each do |ctl|
          field = field_of.call(ctl)
          unless field
            log['not_applied'] << { 'page' => page_name[pid], 'control' => ctl['controlId'], 'reason' => 'the control names no slicer field' }
            next
          end
          next if carried_fields.include?(field)
          if date_table && field.split('.', 2)[0].to_s.casecmp(date_table.to_s).zero?
            date_ctls << [ctl, field]
            next
          end
          next unless live_wanted
          primary = primary_of.call(ctl)
          unless primary && primary['controlType'].to_s == 'list'
            log['not_applied'] << { 'page' => page_name[pid], 'control' => ctl['controlId'], 'field' => field,
                                    'reason' => "a #{(primary || ctl)['controlType']} control cannot parameterise the live element" }
            next
          end
          d, why = fact_el ? live_descriptor(dm_model, fact_el, field, ctl['controlId'], tmsl, dialect) : [nil, "fact #{fact} is not in the data model"]
          if d
            descs << d.merge('field' => field)
          else
            log['not_applied'] << { 'page' => page_name[pid], 'control' => ctl['controlId'], 'field' => field, 'reason' => why }
          end
        end
        if live_wanted && descs.empty?
          log['not_applied'] << { 'page' => page_name[pid], 'summary' => name, 'reason' => 'live decision, but no non-date slicer on the page needs it; charts read the summary' }
        elsif live_wanted
          page_hash = { 'id' => pid, 'name' => page_name[pid], 'elements' => ids.map { |i| by_id[i] }.compact }
          begin
            live = PbiDirectSources.live_element!(page_hash, summary, descs.map { |d| d.reject { |k, _| k == 'field' } }, dialect: dialect)
          rescue ArgumentError, PbiSlicerCarry::NoHook => e
            log['not_applied'] << { 'page' => page_name[pid], 'summary' => name, 'reason' => e.message }
            live = nil
          end
          if live
            place_live.call(live, pid)
            target_ref = live['id']
            scope_reach.call(descs.map { |d| d['control_id'] }, readers.map { |e| e['id'] })
            log['live'] << { 'page' => page_name[pid], 'summary' => name, 'element' => live['name'], 'element_id' => live['id'],
                             'controls' => descs.map { |d| { 'control' => d['control_id'], 'field' => d['field'] } },
                             'readers' => readers.map { |e| e['name'] } }
            log['changed'] = true
          end
        end
        # date slicers: filter the plotted days; the window values stay computed over the full history
        date_ctls.each do |ctl, field|
          primary = primary_of.call(ctl)
          col = field.split('.', 2)[1]
          ref = day_col && "[#{target_ref}/#{day_col['name']}]"
          formula = ref && date_part_formula(col, ref, field.split('.', 2)[0], tmsl)
          unless primary && formula
            log['not_applied'] << { 'page' => page_name[pid], 'control' => ctl['controlId'], 'field' => field,
                                    'reason' => day_col ? "no day-level expression for the date field #{col}" : "#{name} has no day column" }
            next
          end
          readers.each do |e|
            cid = "#{e['id']}-sl-date-#{ctl['controlId']}"
            e['columns'] = (e['columns'] || []) + [{ 'id' => cid, 'formula' => formula, 'name' => "#{col} (filter)" }] unless Array(e['columns']).any? { |c| c['id'] == cid }
            e['columns'].last['hidden'] = true if e['kind'] == 'table' && e['columns'].last['id'] == cid
            primary['filters'] = Array(primary['filters'])
            tgt = { 'source' => { 'kind' => 'table', 'elementId' => e['id'] }, 'columnId' => cid }
            primary['filters'] << tgt unless primary['filters'].include?(tgt)
          end
          scope_reach.call([ctl['controlId']], readers.map { |e| e['id'] })
          log['date_filters'] << { 'page' => page_name[pid], 'summary' => name, 'control' => ctl['controlId'], 'field' => field,
                                   'formula' => formula, 'readers' => readers.map { |e| e['name'] } }
          log['changed'] = true
        end
      end
    end

    # ---- class D page summaries: one live element per page for the slicers outside the summary's grain -----------------
    if page_fact_live
      page_fact_live.call(doc).each do |res|
        unless res['sql']
          Array(res['skipped']).each { |s| log['not_applied'] << { 'page' => res['page'], 'summary' => res['summary'] }.merge(s.reject { |k, _| k == 'slicer' }).merge('field' => s['field']) }
          next
        end
        mkey, master = dmap['masters'].find { |_k, mm| mm['element_name'] == res['summary'] }
        sp = spec_els.find { |e| e['name'] == res['summary'] }
        unless master && sp
          log['not_applied'] << { 'page' => res['page'], 'summary' => res['summary'], 'reason' => 'the page summary is not in the master map or the data model spec' }
          next
        end
        summary = { 'id' => master['element_id'], 'name' => res['summary'], 'source' => sp['source'], 'columns' => sp['columns'] }
        Array(res['skipped']).each { |s| log['not_applied'] << { 'page' => res['page'], 'summary' => res['summary'], 'field' => s['field'], 'reason' => s['reason'] } }
        pages.each do |pid, ids|
          els = ids.map { |i| by_id[i] }.compact
          readers = els.reject { |e| e['kind'] == 'control' }.select { |e| PbiDirectSources.reads_summary?(e, summary) }
          next if readers.empty?
          page_hash = { 'id' => pid, 'name' => page_name[pid], 'elements' => els }
          begin
            live = PbiDirectSources.live_element!(page_hash, summary, res['controls'], dialect: dialect, statement: res['sql'])
          rescue ArgumentError, PbiSlicerCarry::NoHook => e
            log['not_applied'] << { 'page' => page_name[pid], 'summary' => res['summary'], 'reason' => e.message }
            next
          end
          place_live.call(live, pid)
          scope_reach.call(res['controls'].map { |c| c['control_id'] }, readers.map { |e| e['id'] })
          log['live'] << { 'page' => page_name[pid], 'summary' => res['summary'], 'element' => live['name'], 'element_id' => live['id'],
                           'controls' => res['controls'].map { |c| { 'control' => c['control_id'], 'field' => c['field'] } },
                           'hooks' => res['hooks'], 'readers' => readers.map { |e| e['name'] } }
          log['changed'] = true
        end
      end
    end

    # what is still unreached: controls the builder excluded from a chart that reads a summary
    summary_ids = ti_elements.map { |n| (dmap['masters'].find { |_k, mm| mm['element_name'] == n } || [nil, {}])[1]['element_id'] }.compact
    summary_ids += dmap['masters'].values.select { |mm| mm['page_fact'] }.map { |mm| mm['element_id'] }.compact
    live_ids = log['live'].map { |l| l['element_id'] }
    scope_by_cid.each_value do |sc|
      Array(sc['excluded']).each do |x|
        el = by_id[x['element']]
        # I6: an element the control has no column for (`not_reached`) is listed whatever it reads
        next unless el && (x['not_reached'] || summary_ids.include?(el.dig('source', 'elementId')) || live_ids.include?(el.dig('source', 'elementId')))
        log['unreached'] << { 'control' => sc['controlId'], 'source' => sc['sourceName'], 'element' => el['name'], 'reason' => x['reason'] }
      end
    end
    log
  end

  # The day-level expression of a date-table field, over the summary's day column `ref`, or nil (I2: only a field that provably
  # equals that calendar level has one; Fiscal Year, Month Name and the like have none). `table`/`tmsl` let the model's column
  # decide (a calculated Month Start, an integer Year); without them the name decides, minus every fiscal name.
  def date_part_formula(column, ref, table = nil, tmsl = nil)
    infos = tmsl && table ? PbiDateFields.infos(tmsl, [table]) : nil
    i = infos ? infos[[table.to_s.downcase, column.to_s.downcase]] : PbiDateFields.info(column)
    return nil unless i
    case [i['unit'], i['form']]
    when %w[day date] then ref
    when %w[month date] then "MakeDate(Year(#{ref}), Month(#{ref}), 1)"
    when %w[quarter date] then "MakeDate(Year(#{ref}), (Quarter(#{ref}) - 1) * 3 + 1, 1)"
    when %w[year date] then "MakeDate(Year(#{ref}), 1, 1)"
    when %w[year int] then "Year(#{ref})"
    when %w[quarter int] then "Quarter(#{ref})"
    when %w[month int] then "Month(#{ref})"
    end
  end

  # pbi-shaped-model.json `limits`: visuals that lost a field because one element reads one source (mixed summaries).
  def limits_from_coverage(coverage, classes)
    Array((coverage || {})['unresolved']).map do |u|
      m = u['detail'].to_s.match(/\Afield\(s\) (.+?) not reachable on master '(.+?)'/)
      next unless m
      fields = m[1].split(/,\s*(?=[A-Za-z_ ]+\.)/)
      { 'kind' => 'mixed_summary', 'visual' => u['visual'], 'visual_id' => u['visual_id'], 'source' => m[2], 'dropped' => fields,
        'dropped_measures' => fields.select { |f| (classes || {}).key?(f) },
        'reason' => 'one element reads one data model element; the dropped field lives on another summary or table' }
    end.compact
  end

end
