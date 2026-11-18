# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'pbi_report_clock'

# Materialization freshness: is a materialized Sigma data-model element older
# than the warehouse tables it was built from?
#
# Why this exists: parity compares Sigma against a LIVE warehouse oracle. When a
# data-model element is materialized, Sigma serves the stored copy
# (<writeback db>.<schema>."t_mat_<32 hex>_<n>"), so an upstream table that
# changed after the last refresh makes parity "fail" (or pass against an equally
# stale oracle). The materialization job API cannot be trusted for freshness
# (it keeps reporting the first run's startedAt/readyAt), so the truth is read
# from the warehouse: INFORMATION_SCHEMA.TABLES.LAST_ALTERED of the t_mat table
# versus LAST_ALTERED of every upstream BASE TABLE.
#
# This module is pure: every network/warehouse/clock interaction is injected.
# Ruby 2.6+ compatible (no endless defs, no filter_map, no numbered params).
#
# SQL scanner limits (table_refs): a careful hand-written tokenizer, NOT a
# parser. It handles comments (-- // /* */), string literals ('..', $$..$$),
# quoted identifiers, 1/2/3-part names, comma-joined FROM lists, JOINs, CTE
# names (WITH x AS (...)), subquery aliases, table functions (TABLE(...),
# FLATTEN(...), GENERATOR(...), LATERAL, UNNEST, VALUES) and the FROM inside
# EXTRACT/SUBSTRING/TRIM/OVERLAY and IS [NOT] DISTINCT FROM. It does NOT
# understand: IDENTIFIER('db.s.t') (reported as nothing), time-travel clauses
# (AT/BEFORE), PIVOT/MATCH_RECOGNIZE bodies, CTE names shadowing real tables in
# an inner scope (CTE names are matched statement-wide), or dialects other than
# Snowflake-style quoting. Anything it cannot resolve to a full DB.SCHEMA.TABLE
# is returned with a nil part so the caller records it as unresolved (verdict
# UNKNOWN), never silently dropped.
module MaterializationFreshness
  module_function

  T_MAT_RE = /\At_mat_[0-9a-f]{32}_\d+\z/.freeze

  STOP_WORDS = %w[
    WHERE GROUP ORDER HAVING QUALIFY LIMIT UNION INTERSECT EXCEPT MINUS JOIN INNER LEFT RIGHT FULL
    CROSS NATURAL ON USING LATERAL SAMPLE TABLESAMPLE PIVOT UNPIVOT AT BEFORE CHANGES WINDOW FETCH
    OFFSET OUTER ASOF MATCH_CONDITION FROM SELECT SET WHEN WITH CONNECT START
  ].freeze
  CLAUSE_END = %w[WHERE GROUP ORDER HAVING QUALIFY LIMIT UNION INTERSECT EXCEPT MINUS SELECT WINDOW FETCH OFFSET].freeze
  FROM_FUNCS = %w[EXTRACT SUBSTRING SUBSTR TRIM OVERLAY POSITION].freeze

  # ------------------------------------------------------------------ tokenizer

  # Tokens: [:id, text, quoted_bool] | [:p, char] | [:o, nil]
  def tokenize(sql)
    s = sql.to_s
    toks = []
    i = 0
    n = s.length
    while i < n
      c = s[i]
      if c =~ /\s/
        i += 1
      elsif c == '-' && s[i + 1] == '-' || c == '/' && s[i + 1] == '/'
        i += 1 while i < n && s[i] != "\n"
      elsif c == '/' && s[i + 1] == '*'
        e = s.index('*/', i + 2)
        i = e ? e + 2 : n
      elsif c == "'"
        i += 1
        while i < n
          if s[i] == "\\"
            i += 2
          elsif s[i] == "'" && s[i + 1] == "'"
            i += 2
          elsif s[i] == "'"
            i += 1
            break
          else
            i += 1
          end
        end
        toks << [:o, nil]
      elsif c == '$' && s[i + 1] == '$'
        e = s.index('$$', i + 2)
        i = e ? e + 2 : n
        toks << [:o, nil]
      elsif c == '"'
        j = i + 1
        buf = +''
        while j < n
          if s[j] == '"' && s[j + 1] == '"'
            buf << '"'
            j += 2
          elsif s[j] == '"'
            j += 1
            break
          else
            buf << s[j]
            j += 1
          end
        end
        toks << [:id, buf, true]
        i = j
      elsif c =~ /[A-Za-z_]/
        j = i
        j += 1 while j < n && s[j] =~ /[A-Za-z0-9_$]/
        toks << [:id, s[i...j], false]
        i = j
      elsif c =~ /[0-9]/
        j = i
        j += 1 while j < n && s[j] =~ /[0-9A-Za-z_.]/
        toks << [:o, nil]
        i = j
      else
        toks << [:p, c]
        i += 1
      end
    end
    toks
  end

  def kw?(tok, *words)
    tok && tok[0] == :id && !tok[2] && words.include?(tok[1].upcase)
  end

  def punct?(tok, ch)
    tok && tok[0] == :p && tok[1] == ch
  end

  def norm(tok)
    tok[2] ? tok[1] : tok[1].upcase
  end

  # CTE names: `WITH [RECURSIVE] a [(cols)] AS (` and `, b [(cols)] AS (` after one.
  def cte_names(toks)
    names = {}
    toks.each_with_index do |t, i|
      next unless t[0] == :id
      j = i + 1
      if punct?(toks[j], '(') # optional column list
        depth = 0
        while toks[j]
          depth += 1 if punct?(toks[j], '(')
          depth -= 1 if punct?(toks[j], ')')
          j += 1
          break if depth.zero?
        end
      end
      next unless kw?(toks[j], 'AS') && punct?(toks[j + 1], '(')
      prev = toks[i - 1] if i > 0
      next unless prev && (kw?(prev, 'WITH', 'RECURSIVE') || punct?(prev, ','))
      names[norm(t)] = true
    end
    names
  end

  # Parse a dotted name at toks[i]; returns [parts(array of [text, quoted]), next_index].
  def parse_name(toks, i)
    parts = []
    while toks[i] && toks[i][0] == :id
      parts << [toks[i][1], toks[i][2]]
      if punct?(toks[i + 1], '.') && toks[i + 2] && toks[i + 2][0] == :id
        i += 2
      else
        i += 1
        break
      end
    end
    [parts, i]
  end

  # Every table read in FROM / JOIN clauses as [DB, SCHEMA, TABLE]. Unquoted
  # parts are upper-cased; quoted parts keep their exact case. Missing leading
  # parts are filled from the defaults, else left nil.
  def table_refs(sql, default_db: nil, default_schema: nil)
    toks = tokenize(sql)
    ctes = cte_names(toks)
    refs = []
    active = {}          # paren depth => inside a FROM list (comma continues it)
    opener = []          # stack: previous token text of each open paren (for EXTRACT(... FROM ...))
    depth = 0
    i = 0
    take = lambda do |start|
      t = toks[start]
      return start unless t
      if kw?(t, 'LATERAL') || kw?(t, 'VALUES') || kw?(t, 'TABLE') && punct?(toks[start + 1], '(')
        return start + 1
      end
      return start unless t[0] == :id
      parts, nxt = parse_name(toks, start)
      return start + 1 if punct?(toks[nxt], '(') # table function call
      return nxt if parts.empty? || parts.length > 3
      first = parts[0]
      if parts.length == 1 && ctes[first[1] ? first[0] : first[0].upcase]
        return skip_alias(toks, nxt)
      end
      full = parts.map { |text, quoted| quoted ? text : text.upcase }
      full = [default_schema] + full if full.length == 1
      full = [default_db] + full if full.length == 2
      refs << full
      skip_alias(toks, nxt)
    end
    while i < toks.length
      t = toks[i]
      if punct?(t, '(')
        opener.push(toks[i - 1] && i > 0 ? toks[i - 1] : nil)
        depth += 1
      elsif punct?(t, ')')
        active.delete(depth)
        opener.pop
        depth -= 1 if depth > 0
      elsif punct?(t, ';')
        active.clear
      elsif kw?(t, 'FROM')
        enclosing = opener.last
        prev = i > 0 ? toks[i - 1] : nil
        skip = (enclosing && kw?(enclosing, *FROM_FUNCS)) || kw?(prev, 'DISTINCT')
        unless skip
          active[depth] = true
          i = take.call(i + 1) - 1
        end
      elsif kw?(t, 'JOIN')
        i = take.call(i + 1) - 1
      elsif punct?(t, ',') && active[depth]
        i = take.call(i + 1) - 1
      elsif t[0] == :id && !t[2] && CLAUSE_END.include?(t[1].upcase)
        active.delete(depth)
      end
      i += 1
    end
    refs
  end

  def skip_alias(toks, i)
    if kw?(toks[i], 'AS') && toks[i + 1] && toks[i + 1][0] == :id
      i += 2
    elsif toks[i] && toks[i][0] == :id && (toks[i][2] || !STOP_WORDS.include?(toks[i][1].upcase))
      i += 1
    end
    if punct?(toks[i], '(') # alias column list: a (c1, c2)
      d = 0
      while toks[i]
        d += 1 if punct?(toks[i], '(')
        d -= 1 if punct?(toks[i], ')')
        i += 1
        break if d.zero?
      end
    end
    i
  end

  # [DB, SCHEMA, "t_mat_<hex>_<n>"] when the compiled query reads a materialized table, else nil.
  def materialized_table_in(sql)
    table_refs(sql).find { |r| r.length == 3 && r[2].is_a?(String) && r[2] =~ T_MAT_RE }
  end

  def table_key(ref)
    ref.join('.')
  end

  # ------------------------------------------------------------------ DM spec

  def spec_elements(dm_spec)
    out = {}
    ((dm_spec || {})['pages'] || []).each do |page|
      (page['elements'] || []).each { |el| out[el['id']] = el if el.is_a?(Hash) && el['id'] }
    end
    out
  end

  # Collect warehouse tables / element ids from a source (or relationship) tree.
  def collect_source(node, tables, elem_ids, unresolved, dflt)
    case node
    when Array
      node.each { |x| collect_source(x, tables, elem_ids, unresolved, dflt) }
    when Hash
      kind = node['kind']
      case kind
      when 'warehouse-table'
        path = Array(node['path']).map(&:to_s)
        full = path.dup
        full = [dflt[:schema]] + full if full.length == 1
        full = [dflt[:db]] + full if full.length == 2
        add_table(tables, unresolved, full, path.join('.'))
      when 'sql'
        stmt = node['statement'].to_s
        refs = table_refs(stmt, default_db: dflt[:db], default_schema: dflt[:schema])
        # No table at all (a GENERATOR calendar, SELECT CURRENT_DATE): nothing upstream can
        # change, so it is not UNKNOWN. Dynamic references (IDENTIFIER('..'), @stages) are.
        unresolved << 'sql source reads no recognizable table' if refs.empty? && stmt.match?(/\bIDENTIFIER\s*\(|@[A-Za-z_]/i)
        refs.each { |r| add_table(tables, unresolved, r, r.map(&:to_s).join('.')) }
      when 'data-model'
        unresolved << "source reads another data model (#{node['dataModelId']}); its freshness is not checked"
      end
      elem_ids << node['elementId'] if node['elementId'].is_a?(String)
      node.each do |k, v|
        next if %w[kind path statement elementId dataModelId].include?(k)
        collect_source(v, tables, elem_ids, unresolved, dflt) if v.is_a?(Hash) || v.is_a?(Array)
      end
    end
  end

  def add_table(tables, unresolved, full, label)
    if full.length == 3 && full.none? { |p| p.nil? || p.to_s.empty? }
      tables << full
    else
      unresolved << "table #{label} is not fully qualified (no default database/schema known)"
    end
  end

  # Transitively resolve an element to the warehouse tables it reads.
  # => { tables: [[DB, SCHEMA, TABLE], ...], unresolved: [reason, ...] }
  def upstream_tables(dm_spec, element_id, default_db: nil, default_schema: nil)
    elements = spec_elements(dm_spec)
    dflt = { db: default_db, schema: default_schema }
    tables = []
    unresolved = []
    seen = {}
    queue = [element_id]
    until queue.empty?
      id = queue.shift
      next if seen[id]
      seen[id] = true
      el = elements[id]
      if el.nil?
        unresolved << "element #{id} not found in the data-model spec"
        next
      end
      ids = []
      src = el['source']
      if src.nil?
        unresolved << "element #{el['name'] || id} has no source"
      else
        before = unresolved.length
        collect_source(src, tables, ids, unresolved, dflt)
        known = %w[warehouse-table sql table data-model join union]
        kind = src['kind'] if src.is_a?(Hash)
        if kind && !known.include?(kind) && unresolved.length == before && ids.empty?
          unresolved << "element #{el['name'] || id} has unsupported source kind #{kind.inspect}"
        end
      end
      collect_source(el['relationships'], tables, ids, unresolved, dflt) if el['relationships']
      queue.concat(ids)
    end
    { tables: tables.uniq, unresolved: unresolved.uniq }
  end

  # Does the element (or any element it reads) evaluate "today"/"now"? Such an
  # element is frozen at its materialization run, so it goes stale at every
  # report-timezone midnight even when no upstream table changes.
  def reads_clock?(dm_spec, element_id)
    elements = spec_elements(dm_spec)
    seen = {}
    queue = [element_id]
    until queue.empty?
      id = queue.shift
      next if seen[id] || elements[id].nil?

      seen[id] = true
      el = elements[id]
      hit = false
      PbiReportClock.walk_formulas(el, '') { |h, k, _| hit ||= PbiReportClock.today_relative_formula?(h[k]) }
      stmt = el.dig('source', 'statement')
      hit ||= stmt.is_a?(String) && (PbiReportClock.session_clock_refs(stmt).any? || PbiReportClock.sql_pinned?(stmt))
      return true if hit

      ids = []
      collect_source(el['source'], [], ids, [], {}) if el['source']
      queue.concat(ids)
    end
    false
  end

  # Ages FRESH clock-reading elements by the report day (lib/pbi_report_clock.rb).
  def apply_report_day!(result, dm_spec:, timezone:, now:)
    return result unless timezone

    today = PbiReportClock.local_date(now, timezone)
    Array(result['elements']).each do |rec|
      # FRESH or UNKNOWN alike: a clock-reading element frozen on an earlier report day is stale
      next unless %w[FRESH UNKNOWN].include?(rec['status']) && rec['materialized_last_altered']
      next unless reads_clock?(dm_spec, rec['elementId'])

      ran = PbiReportClock.local_date(rec['materialized_last_altered'], timezone)
      next unless ran < today

      rec['status'] = 'STALE'
      rec['report_day_stale'] = true
      rec['reasons'] << "reads the report clock and was materialized on report day #{ran}; today is #{today} in " \
                        "#{timezone} — re-materialize after each report-timezone midnight"
    end
    statuses = Array(result['elements']).map { |r| r['status'] }
    result['counts'] = statuses.each_with_object(Hash.new(0)) { |st, h| h[st] += 1 }
    result['status'] = if statuses.include?('STALE') then 'STALE'
                       elsif statuses.include?('UNKNOWN') then 'UNKNOWN'
                       elsif statuses.empty? then result['status']
                       else 'FRESH'
                       end
    result
  end

  # ------------------------------------------------------------------ evaluate

  def parse_time(value)
    return nil if value.nil? || value.to_s.strip.empty?
    return value if value.is_a?(Time)
    begin
      Time.iso8601(value.to_s)
    rescue ArgumentError
      begin
        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end

  def lookup_time(table_times, ref)
    key = table_key(ref)
    return table_times[key] if table_times.key?(key)
    hit = table_times.keys.find { |k| k.to_s.casecmp(key).zero? }
    hit ? table_times[hit] : nil
  end

  def iso(time)
    time && time.utc.iso8601
  end

  def evaluate_element(el, table_times)
    rec = {
      'elementId' => el['elementId'],
      'elementName' => el['elementName'],
      'sheetId' => el['sheetId'],
      'materialized_table' => el['materialized_table'] && table_key(el['materialized_table']),
      'materialized_last_altered' => nil,
      'upstream' => [],
      'stale_upstream' => [],
      'reasons' => []
    }
    if el['compiled_query_found'] == false
      rec['status'] = 'UNKNOWN'
      rec['reasons'] << 'scratch probe returned no compiled query; materialization state cannot be determined'
      return rec
    end
    unless el['materialized_table']
      rec['status'] = 'NOT_MATERIALIZED'
      rec['reasons'] << 'compiled query reads the source directly (no t_mat table), Sigma serves live data'
      return rec
    end
    mat_info = lookup_time(table_times, el['materialized_table'])
    mat_time = mat_info && parse_time(mat_info['last_altered'])
    rec['materialized_last_altered'] = iso(mat_time)
    unknown = []
    unknown << "materialized table #{rec['materialized_table']} not found or has no LAST_ALTERED" unless mat_time
    Array(el['unresolved']).each { |u| unknown << "unresolved upstream: #{u}" }
    upstream = Array(el['upstream'])
    rec['reasons'] << 'reads no warehouse table: no upstream change can make it stale' if upstream.empty? && Array(el['unresolved']).empty?
    upstream.each do |ref|
      key = table_key(ref)
      info = lookup_time(table_times, ref)
      entry = { 'table' => key, 'type' => info && info['type'], 'last_altered' => nil, 'newer' => false }
      if info.nil?
        unknown << "upstream #{key} not found in INFORMATION_SCHEMA"
      elsif info['type'].to_s =~ /VIEW/i
        entry['last_altered'] = info['last_altered']
        unknown << "upstream #{key} is a #{info['type']}: LAST_ALTERED is DDL time, data freshness unknown"
      else
        up_time = parse_time(info['last_altered'])
        entry['last_altered'] = iso(up_time)
        if up_time.nil?
          unknown << "upstream #{key} has no LAST_ALTERED"
        elsif mat_time && up_time > mat_time
          entry['newer'] = true
          rec['stale_upstream'] << entry
        end
      end
      rec['upstream'] << entry
    end
    if rec['stale_upstream'].any?
      rec['status'] = 'STALE'
      rec['stale_upstream'].each do |e|
        rec['reasons'] << "upstream #{e['table']} altered #{e['last_altered']} after materialization #{rec['materialized_last_altered']}"
      end
    elsif unknown.any?
      rec['status'] = 'UNKNOWN'
      rec['reasons'].concat(unknown)
    else
      rec['status'] = 'FRESH'
    end
    rec
  end

  # elements: [{elementId, elementName, sheetId, materialized_table, upstream, unresolved}]
  # table_times: {"DB.SCHEMA.TABLE" => {"last_altered" => iso8601, "type" => "BASE TABLE"|"VIEW"}}
  # => {'status' => FRESH|STALE|UNKNOWN|NONE, 'elements' => [...]}
  def evaluate(elements:, table_times:)
    recs = elements.map { |el| evaluate_element(stringify(el), table_times || {}) }
    statuses = recs.map { |r| r['status'] }
    overall =
      if recs.empty? then 'NONE'
      elsif statuses.include?('STALE') then 'STALE'
      elsif statuses.include?('UNKNOWN') then 'UNKNOWN'
      else 'FRESH'
      end
    counts = {}
    statuses.each { |s| counts[s] = (counts[s] || 0) + 1 }
    { 'status' => overall, 'counts' => counts, 'elements' => recs }
  end

  def stringify(el)
    el.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
  end

  # ------------------------------------------------------------------ wait

  # Poll until FRESH/NONE or the WALL-CLOCK deadline passes. The deadline is
  # re-checked against the realtime clock on every iteration: a sleeping host
  # stretches `sleep`, and the monotonic clock pauses during host sleep on
  # macOS, so neither a sleep count nor a monotonic clock can be trusted.
  # After an oversleep one final evaluation still runs, then it times out.
  def wait_until_fresh(evaluate_once:, deadline_s:, poll_s:,
                       clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) },
                       sleeper: ->(s) { sleep s },
                       done: ->(r) { %w[FRESH NONE].include?(r['status']) })
    started = clock.call
    deadline = started + deadline_s.to_f
    polls = 0
    loop do
      result = evaluate_once.call
      polls += 1
      now = clock.call
      return { 'result' => result, 'waited_s' => now - started, 'timed_out' => false, 'polls' => polls } if done.call(result)
      if now >= deadline
        return { 'result' => result, 'waited_s' => now - started, 'timed_out' => true, 'polls' => polls }
      end
      sleeper.call([poll_s.to_f, deadline - now].min)
    end
  end

  # Worth waiting for: an upstream-stale element or one whose t_mat table is not
  # visible yet. Report-day staleness is waitable only after requesting a new run.
  def waitable?(result, report_day_stale: false)
    Array(result['elements']).any? do |e|
      (e['status'] == 'STALE' && (report_day_stale || !e['report_day_stale'])) ||
        (e['status'] == 'UNKNOWN' && e['materialized_table'] && e['materialized_last_altered'].nil?)
    end
  end

  # ------------------------------------------------------------------ SQL

  def sql_literal(value)
    "'" + value.to_s.gsub("'", "''") + "'"
  end

  def sql_ident(name)
    name =~ /\A[A-Z_][A-Z0-9_$]*\z/ ? name : '"' + name.to_s.gsub('"', '""') + '"'
  end

  # One INFORMATION_SCHEMA statement per database. LAST_ALTERED is returned as
  # an ISO-8601 UTC string so the result is independent of the session timezone.
  def information_schema_sql(tables)
    by_db = {}
    tables.each do |db, schema, name|
      by_db[db] ||= {}
      (by_db[db][schema] ||= []) << name
    end
    by_db.each_with_object({}) do |(db, schemas), out|
      clauses = schemas.map do |schema, names|
        list = names.uniq.map { |n| sql_literal(n) }.join(', ')
        "(TABLE_SCHEMA = #{sql_literal(schema)} AND TABLE_NAME IN (#{list}))"
      end
      out[db] = "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, " \
                "TO_VARCHAR(CONVERT_TIMEZONE('UTC', LAST_ALTERED), 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"') AS LAST_ALTERED " \
                "FROM #{sql_ident(db)}.INFORMATION_SCHEMA.TABLES WHERE #{clauses.join(' OR ')}"
    end
  end

  # rows from the probe -> {"DB.SCHEMA.TABLE" => {"last_altered", "type"}}
  def table_times_from_rows(rows)
    Array(rows).each_with_object({}) do |row, memo|
      next unless row.is_a?(Hash)
      r = row.each_with_object({}) { |(k, v), h| h[k.to_s.upcase] = v }
      next unless r['TABLE_NAME']
      key = [r['TABLE_CATALOG'], r['TABLE_SCHEMA'], r['TABLE_NAME']].join('.')
      memo[key] = { 'last_altered' => r['LAST_ALTERED'], 'type' => r['TABLE_TYPE'] }
    end
  end

  # ------------------------------------------------------------------ assembly

  # schedules: GET materializationSchedules entries; queries: GET workbook /queries body;
  # probe_ids: {probe element id => DM element id} (optional).
  def build_elements(schedules:, dm_spec:, queries:, probe_ids: {}, default_db: nil, default_schema: nil)
    by_elem = {}
    Array(schedules).each { |s| by_elem[s['elementId']] ||= s }
    spec = spec_elements(dm_spec)
    name_to_id = {}
    by_elem.each { |id, s| name_to_id[s['elementName'] || (spec[id] && spec[id]['name'])] = id }
    sql_for = {}
    entries = queries.is_a?(Hash) ? Array(queries['entries']) : Array(queries)
    entries.each do |e|
      id = probe_ids[e['elementId']] || (by_elem.key?(e['elementId']) ? e['elementId'] : nil) || name_to_id[e['name']]
      sql_for[id] = e['sql'] if id
    end
    by_elem.map do |id, s|
      up = upstream_tables(dm_spec, id, default_db: default_db, default_schema: default_schema)
      {
        'elementId' => id,
        'elementName' => s['elementName'] || (spec[id] && spec[id]['name']),
        'sheetId' => s['sheetId'],
        'compiled_query_found' => sql_for[id].is_a?(String) && !sql_for[id].strip.empty?,
        'materialized_table' => sql_for[id] && materialized_table_in(sql_for[id]),
        'upstream' => up[:tables],
        'unresolved' => up[:unresolved]
      }
    end
  end

  # Every table whose LAST_ALTERED must be fetched.
  def tables_to_fetch(elements)
    out = []
    elements.each do |el|
      out << el['materialized_table'] if el['materialized_table']
      out.concat(Array(el['upstream']))
    end
    out.uniq
  end
end
