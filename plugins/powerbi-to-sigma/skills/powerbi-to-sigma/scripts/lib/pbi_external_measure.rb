# frozen_string_literal: true
#
# PbiExternalMeasure — remote measures in a composite Power BI model.
#
# A composite report that uses DirectQuery to a published Power BI semantic
# model stores each remote measure as a POINTER, not as DAX:
#
#   EXTERNALMEASURE("Net Revenue", DOUBLE, "DirectQuery to AS - Sales Model")
#
# The measure's real DAX lives in the remote model, so nothing here can be
# translated. The model's shared expressions map each connection name to the
# remote model:
#
#   "DirectQuery to AS - Sales Model" =
#     AnalysisServices.Database("powerbi://api.powerbi.com/v1.0/myorg/<ws>", "Sales Model")
#
# migrate-powerbi.rb uses this module to STOP (exit 10) before conversion and
# name the remote models, or, under --allow-incomplete-model, to turn the
# pointers and every measure built on them into Null metrics reported as gaps
# instead of shipping the pointer as a raw formula (issue #97). convert-model.rb
# refuses a converter output that still carries a pointer (the run.sh route).
#
# The same composite model also holds remote PROXY TABLES: each table of the
# remote model the report uses is a DirectQuery table whose partition is an
# 'entity' partition (entityName = the remote table, expressionSource = the
# "DirectQuery to AS - <model>" shared expression). There is no warehouse table
# behind it, so the converter's fallback (--database/--schema + the table name)
# is a guess. scan() reports them with the pointers (same stop, same record);
# under --allow-incomplete-model placeholder_partitions! turns each into a
# zero-row typed Custom SQL element (a gap, columns still bound), never a
# guessed warehouse path.
#
# Pure and offline; Ruby 2.6-compatible (test: scripts/test-external-measure.rb).
require_relative 'pbi_composite'

module PbiExternalMeasure
  module_function

  POINTER = /\bEXTERNALMEASURE\s*\(/i.freeze
  AS_DATABASE = /AnalysisServices\.Database\s*\(\s*"((?:[^"]|"")*)"\s*,\s*"((?:[^"]|"")*)"/i.freeze
  CONNECTION_PREFIX = /\ADirectQuery to AS\s*-\s*/i.freeze
  POWERBI_WORKSPACE = %r{\Apowerbi://[^/]+/v[\d.]+/[^/]+/(.+?)/*\z}i.freeze
  # An optional 'Quoted Table' or BareTable qualifier, then [Name].
  REF = /(?:'((?:[^']|'')+)'|([A-Za-z_][A-Za-z0-9_]*))?\[((?:[^\]]|\]\])+)\]/.freeze

  def text(expression)
    expression.is_a?(Array) ? expression.join("\n") : expression.to_s
  end

  # EXTERNALMEASURE( as code, not inside a comment or a string literal.
  def pointer?(expression)
    mask(text(expression)).match?(POINTER)
  end

  # EXTERNALMEASURE("<measure>", <type>, "<connection>") ->
  # { 'measure' => ..., 'type' => ..., 'connection' => ... } ('' for a missing
  # argument), or nil when the expression is not a pointer.
  def parse(expression)
    s = text(expression)
    m = POINTER.match(mask(s))
    return nil unless m

    args = split_args(mask(s, keep_strings: true), m.end(0))
    return nil if args.empty?

    { 'measure' => unquote(args[0]), 'type' => args[1].to_s.strip, 'connection' => unquote(args[2]) }
  end

  # Shared expressions that connect to a remote model:
  # { connection name (downcased) => { 'connection', 'server', 'model', 'workspace' } }.
  def connections(expressions)
    Array(expressions).each_with_object({}) do |expr, acc|
      next unless expr.is_a?(Hash) && expr['name']

      m = AS_DATABASE.match(text(expr['expression']))
      next unless m

      server = m[1].gsub('""', '"')
      acc[expr['name'].to_s.downcase] = { 'connection' => expr['name'].to_s, 'server' => server,
                                          'model' => m[2].gsub('""', '"'), 'workspace' => workspace_of(server) }
    end
  end

  # The last path segment of a powerbi:// server, as written (not percent-decoded:
  # a workspace name may itself contain "%").
  def workspace_of(server)
    m = POWERBI_WORKSPACE.match(server.to_s)
    m && m[1]
  end

  UNRECORDED_MODEL = '(remote model not recorded in the file)'

  # model: a TMSL model (the `model` object). expressions: the shared
  # expressions to name the remote models from (default: the model's own; pass
  # the full model's when `model` is a scoped copy). proxy_model: the model whose
  # proxy tables count (default: `model`; the orchestrator passes the scoped model
  # when `model` is the full one). Returns
  #   'pointers'      => [{ 'table', 'measure', 'remote_measure', 'type',
  #                         'connection', 'model', 'workspace', 'server' }]
  #   'proxy_tables'  => [{ 'table', 'remote_table', 'connection', 'model',
  #                         'workspace', 'server', ['candidates'] }]
  #   'dependents'    => [{ 'table', 'measure', 'depends_on' => [measure names],
  #                         'remote_tables' => [proxy table names] }]
  #                      (measures built on a pointer or over a proxy table,
  #                      transitively, in an order where each comes after the
  #                      measures it is built on)
  #   'remote_models' => [{ 'model', 'workspace', 'server', 'connection',
  #                         'pointers' => [measure names], 'tables' => [table names] }]
  def scan(model, expressions: nil, proxy_model: nil)
    exprs = expressions || model['expressions']
    index = connections(exprs)
    columns_of = {}
    measures = []
    (model['tables'] || []).each do |t|
      columns_of[t['name'].to_s.downcase] = Array(t['columns']).map { |c| c['name'].to_s.downcase }
      (t['measures'] || []).each { |m| measures << [t['name'].to_s, m['name'].to_s, text(m['expression'])] }
    end

    pointers = []
    measures.each do |table, name, expr|
      p = parse(expr)
      next unless p

      conn = p['connection']
      info = index[conn.downcase] || {}
      model_name = info['model'] || conn.sub(CONNECTION_PREFIX, '')
      model_name = '(unnamed remote model)' if model_name.strip.empty?
      pointers << { 'table' => table, 'measure' => name, 'remote_measure' => p['measure'], 'type' => p['type'],
                    'connection' => conn, 'model' => model_name, 'workspace' => info['workspace'],
                    'server' => info['server'] }
    end
    proxies = proxy_tables(proxy_model || model, index, exprs)
    dependents = dependents_of(measures, columns_of, pointers, proxies)

    remote = []
    group = lambda do |x|
      r = remote.find { |y| y['model'] == x['model'] && y['connection'] == x['connection'] }
      unless r
        r = { 'model' => x['model'], 'workspace' => x['workspace'], 'server' => x['server'],
              'connection' => x['connection'], 'pointers' => [], 'tables' => [] }
        r['candidates'] = x['candidates'] if x['candidates']
        remote << r
      end
      r
    end
    pointers.each { |p| group.call(p)['pointers'] << p['measure'] }
    proxies.each { |p| group.call(p)['tables'] << p['table'] }
    { 'pointers' => pointers, 'proxy_tables' => proxies, 'dependents' => dependents, 'remote_models' => remote }
  end

  # DirectQuery-to-AS proxy tables: tables whose partition is an 'entity'
  # partition over a remote Power BI / AS semantic model. An entity partition
  # whose expressionSource is a warehouse endpoint (Direct Lake: Sql.Database
  # over a lakehouse) is not one. With no expressionSource (the .pbix did not
  # record it), the model's only remote connection is assumed; with several, the
  # candidates are listed and none is guessed.
  def proxy_tables(model, index, expressions)
    shared = {}
    Array(expressions).each { |e| shared[e['name'].to_s.downcase] = e['expression'] if e.is_a?(Hash) && e['name'] }
    remotes = index.values
    out = []
    (model['tables'] || []).each do |t|
      part = Array(t['partitions']).find { |p| p.is_a?(Hash) && p.dig('source', 'type').to_s.casecmp('entity').zero? }
      next unless part

      src = part['source']
      conn = src['expressionSource'].to_s
      info = index[conn.downcase]
      candidates = nil
      if conn.empty?
        if remotes.size == 1
          info = remotes.first
          conn = info['connection']
        else
          candidates = remotes.map { |r| model_label(r) }
        end
      elsif info.nil?
        next unless conn.match?(CONNECTION_PREFIX) || PbiComposite.remote?(shared[conn.downcase])
      end
      model_name = info ? info['model'] : conn.sub(CONNECTION_PREFIX, '')
      model_name = UNRECORDED_MODEL if model_name.to_s.strip.empty?
      entry = { 'table' => t['name'].to_s, 'remote_table' => (src['entityName'] || t['name']).to_s,
                'connection' => conn, 'model' => model_name, 'workspace' => info && info['workspace'],
                'server' => info && info['server'] }
      entry['candidates'] = candidates if candidates && !candidates.empty?
      out << entry
    end
    out
  end

  # Measures built on a pointer, or over a proxy table, transitively; each listed
  # after the measures it is built on.
  def dependents_of(measures, columns_of, pointers, proxies)
    proxy_names = {}
    proxies.each { |p| proxy_names[p['table'].downcase] = p['table'] }
    refs = {}
    trefs = {}
    measures.each do |_table, name, expr|
      refs[name.downcase] = measure_refs(expr, columns_of)
      trefs[name.downcase] = table_refs(expr, proxy_names)
    end
    tainted = {}
    pointers.each { |p| tainted[p['measure'].downcase] = p['measure'] }
    loop do
      added = false
      measures.each do |_table, name, _expr|
        k = name.downcase
        next if tainted.key?(k)
        next if trefs[k].empty? && refs[k].none? { |r| tainted.key?(r) }

        tainted[k] = name
        added = true
      end
      break unless added
    end

    done = {}
    pointers.each { |p| done[p['measure'].downcase] = true }
    pending = measures.reject { |_t, name, _e| done.key?(name.downcase) || !tainted.key?(name.downcase) }
    dependents = []
    until pending.empty?
      ready = pending.select { |_t, name, _e| refs[name.downcase].all? { |r| !tainted.key?(r) || done.key?(r) } }
      ready = [pending.first] if ready.empty? # a reference cycle: emit in model order
      ready.each do |table, name, _e|
        k = name.downcase
        dependents << { 'table' => table, 'measure' => name,
                        'depends_on' => refs[k].select { |r| tainted.key?(r) && r != k }.map { |r| tainted[r] },
                        'remote_tables' => trefs[k] }
        done[k] = true
      end
      pending -= ready
    end
    dependents
  end

  def any?(scan)
    !Array(scan && scan['pointers']).empty? || !Array(scan && scan['proxy_tables']).empty?
  end

  # "Sales Model" (workspace "WS"); for a proxy table whose model the file does
  # not record, the candidates.
  def model_label(remote)
    if remote['candidates']
      return "#{UNRECORDED_MODEL}; one of: #{remote['candidates'].join(', ')}"
    end
    return UNRECORDED_MODEL if remote['model'] == UNRECORDED_MODEL

    ws = remote['workspace'].to_s.empty? ? '' : %( (workspace "#{remote['workspace']}"))
    %("#{remote['model']}"#{ws})
  end

  # Harbor Sales (remote table "Sales")
  def table_label(proxy)
    %(#{proxy['table']} (remote table "#{proxy['remote_table']}"))
  end

  def short_list(names, max = 8)
    more = names.size > max ? ", … (#{names.size - max} more)" : ''
    names.first(max).join(', ') + more
  end

  # The OPEN QUESTION box printed before stopping (exit 10). dm_hits: pointers
  # found only in the converter output ({ 'element', 'name' }), listed when the
  # TMSL scan has nothing to name.
  def stop_lines(scan, dm_hits: [])
    pointers = Array(scan['pointers'])
    proxies = Array(scan['proxy_tables'])
    deps = Array(scan['dependents'])
    count = pointers.empty? ? dm_hits.size : pointers.size
    lines = ['╭─ OPEN QUESTION — remote semantic model content in a composite model ─']
    unless count.zero?
      lines << "│  #{count} measure(s) are EXTERNALMEASURE pointers into a published Power BI semantic model."
      lines << '│  Their DAX lives in that remote model, not in this file, so they cannot be translated here.'
    end
    unless proxies.empty?
      lines << "│  #{proxies.size} table(s) are DirectQuery proxies of tables in a published Power BI semantic"
      lines << '│  model. Their rows live in that remote model, not in a warehouse table this file names,'
      lines << '│  so no --database/--schema path can be derived for them.'
    end
    by_table = proxies.each_with_object({}) { |p, h| h[p['table']] = p }
    Array(scan['remote_models']).each do |r|
      tables = Array(r['tables'])
      what = []
      what << "#{r['pointers'].size} pointer(s)" unless r['pointers'].empty?
      what << "#{tables.size} table(s)" unless tables.empty?
      conn = r['connection'].to_s.empty? ? '' : %(, connection "#{r['connection']}")
      lines << "│    • #{model_label(r)}#{conn}: #{what.join(', ')}"
      lines << "│        measures: #{short_list(r['pointers'])}" unless r['pointers'].empty?
      lines << "│        tables: #{short_list(tables.map { |t| table_label(by_table[t] || { 'table' => t, 'remote_table' => t }) })}" unless tables.empty?
    end
    if pointers.empty? && !dm_hits.empty?
      lines << "│    • in the converter output: #{short_list(dm_hits.map { |h| "#{h['name']} (#{h['element']})" })}"
    end
    lines << "│  #{deps.size} more measure(s) are built on them: #{short_list(deps.map { |d| d['measure'] })}" unless deps.empty?
    lines.concat(['│',
                  '│  Choose one:',
                  '│    1. Migrate each remote semantic model first (it is published in the workspace',
                  '│       shown; fetch it through the Fabric route), then rerun this report with',
                  '│       --allow-incomplete-model and re-point its Null metrics and placeholder tables',
                  '│       at the migrated model.',
                  '│    2. Continue knowingly: rerun with --allow-incomplete-model. The pointers and every',
                  '│       measure built on them or on a remote table become Null metrics; each remote',
                  '│       table becomes a zero-row Custom SQL placeholder (no warehouse path is guessed).',
                  '│       All are reported as gaps in external-measures.json (and as an escape in the',
                  '│       degradation ledger).',
                  '╰──────────────────────────────────────────────────────────────────────────────'])
  end

  # Turn the pointer metrics, the metrics built on them, and any formula that
  # still carries EXTERNALMEASURE into Null in a converted Sigma data model
  # (mutated in place). A metric is matched by its measure name (Power BI measure
  # names are model-unique); a column only by a pointer in its own formula, so a
  # warehouse column or local metric that merely shares a pointer's name is left
  # alone. Returns the gaps:
  #   [{ 'table', 'element', 'name', 'kind' => 'metric'|'column', 'reason' }]
  # Idempotent: a formula that is already Null is not reported again.
  def neutralize!(dm_model, scan)
    by_pointer = {}
    Array(scan['pointers']).each { |p| by_pointer[p['measure'].downcase] = p }
    by_dependent = {}
    Array(scan['dependents']).each { |d| by_dependent[d['measure'].downcase] = d }
    gaps = []
    elements_of(dm_model).each do |el|
      %w[metrics columns].each do |key|
        kind = key == 'metrics' ? 'metric' : 'column'
        (el[key] || []).each do |item|
          formula = item['formula'].to_s
          next if formula.strip == 'Null'

          name = item['name'].to_s.downcase
          pointer = kind == 'metric' ? by_pointer[name] : nil
          dependent = kind == 'metric' ? by_dependent[name] : nil
          if pointer || pointer?(formula)
            p = pointer || pointer_for_formula(formula, scan)
            item['formula'] = 'Null'
            item['description'] = pointer_description(p, kind)
            gaps << gap(p['table'], el, item, kind, pointer_reason(p))
          elsif dependent
            item['formula'] = 'Null'
            item['description'] = dependent_description(dependent)
            gaps << gap(dependent['table'], el, item, kind, dependent_reason(dependent))
          end
        end
      end
    end
    gaps
  end

  # Add a Null metric for every pointer or dependent the converted data model
  # does not carry (the vendored converter drops a metric that references another
  # element's metric, which is how a local measure built on a remote one usually
  # looks). Without it the report's visuals lose the field, and the coverage and
  # field-loss gates ask for a rebuild that the missing DAX makes impossible.
  # home: { downcased Power BI table name => its DM element }. A measure with no
  # home element goes on the element of the measure it is built on.
  # Returns gaps in the neutralize! shape. Idempotent.
  def place_missing!(dm_model, scan, home: {})
    elements = elements_of(dm_model)
    return [] if elements.empty?

    holder = lambda do |name|
      elements.find { |e| Array(e['metrics']).any? { |m| m['name'].to_s.casecmp(name.to_s).zero? } }
    end
    gaps = []
    todo = Array(scan['pointers']).map { |p| [p, nil] } + Array(scan['dependents']).map { |d| [nil, d] }
    todo.each do |p, d|
      x = p || d
      next if holder.call(x['measure'])

      el = home[x['table'].to_s.downcase] ||
           Array(d && d['depends_on']).map { |n| holder.call(n) }.compact.first ||
           Array(scan['pointers']).map { |q| holder.call(q['measure']) }.compact.first ||
           elements.first
      metric = { 'id' => next_id(dm_model, "#{el['id']}x"), 'name' => x['measure'], 'formula' => 'Null',
                 'description' => p ? pointer_description(p, 'metric') : dependent_description(d) }
      el['metrics'] = Array(el['metrics']) + [metric]
      reason = p ? pointer_reason(p) : dependent_reason(d)
      gaps << gap(x['table'], el, metric, 'metric', "#{reason}; the converter dropped it, added back as a Null metric")
    end
    gaps
  end

  # The tables the vendored converter emits an element for, in order: it skips
  # calculation groups, auto date tables, and measures-only tables (their
  # measures move onto another element).
  def emitted_tables(tables)
    Array(tables).reject do |t|
      data_cols = Array(t['columns']).reject { |c| c['type'] == 'rowNumber' || c['isGenerated'] }
      t['calculationGroup'] ||
        t['name'].to_s.start_with?('LocalDateTable_', 'DateTableTemplate_') ||
        (data_cols.empty? && !Array(t['measures']).empty?)
    end
  end

  # { downcased Power BI table name => DM element } for place_missing!.
  # by_path: { element index => table name } from the warehouse-path match
  # (PbiMasterKey.table_names). A table with no warehouse path (a proxy or
  # calculated table) falls back to table ORDER over the emitted tables, but
  # only when the converter's base elements (Views excluded) line up one to one
  # with them and the element is not already some other table's: otherwise order
  # says nothing, and the measure goes on the element of the measure it is built on.
  def home_elements(elements, tables, by_path = {})
    home = {}
    by_path.each { |i, t| home[t.to_s.downcase] ||= elements[i] if t && elements[i] }
    base = Array(elements).reject { |e| e.dig('source', 'kind') == 'table' }
    tables = emitted_tables(tables)
    return home unless base.size == tables.size

    tables.each_with_index do |t, i|
      key = t['name'].to_s.downcase
      next if home.key?(key) || home.values.any? { |el| el.equal?(base[i]) }

      home[key] = base[i]
    end
    home
  end

  # Every metric or column whose formula is still an EXTERNALMEASURE pointer:
  # [{ 'element', 'name' }]. Checked on the converter output itself, so a pointer
  # the TMSL scan did not see (a --converter-out from the full model) is caught.
  def dm_pointers(dm_model)
    elements_of(dm_model).flat_map do |el|
      (Array(el['metrics']) + Array(el['columns'])).select { |x| pointer?(x['formula'].to_s) }
                                                   .map { |x| { 'element' => el['name'].to_s, 'name' => (x['name'] || x['id']).to_s } }
    end
  end

  # Converter warnings (⚠ restructure / ⛔ no translation) about a pointer or a
  # measure built on one become informational (ℹ): no restructure can recover a
  # measure whose DAX is in another model, so the DAX gate must not send the user
  # to the gap-scout for it. The converter's text is replaced, not prefixed: its
  # "cross-table" wording is what the coverage gate keys a rebuild prompt on.
  def relabel_warnings(warnings, scan)
    kinds = {}
    Array(scan['dependents']).each do |d|
      kinds[d['measure'].downcase] = Array(d['depends_on']).empty? ? 'is built on a remote table' : 'is built on a remote measure'
    end
    Array(scan['pointers']).each { |p| kinds[p['measure'].downcase] = 'is a remote measure' }
    tables = {}
    Array(scan['proxy_tables']).each { |p| tables[p['table'].downcase] = p }
    Array(warnings).map do |w|
      ws = w.to_s
      name = (ws[/"([^"]+)"/, 1] || '').strip
      proxy = ws.match?(/\A\s*[⚠⛔]\s*Table\s+"/) ? tables[name.downcase] : nil
      if proxy
        next "ℹ Table \"#{name}\" is a DirectQuery proxy of remote table \"#{proxy['remote_table']}\" in semantic model " \
             "#{model_label(proxy)}: a zero-row placeholder under --allow-incomplete-model (external-measures.json); " \
             'the converter note about its source path no longer applies'
      end
      kind = kinds[name.downcase]
      next w unless kind && ws.match?(/\A\s*[⚠⛔]/)

      whose = kind.end_with?('table') ? 'whose rows live' : 'whose DAX lives'
      "ℹ \"#{name}\" #{kind} #{whose} in another semantic model: a Null metric under " \
        '--allow-incomplete-model (external-measures.json); the converter note about it no longer applies'
    end
  end

  # The audit record written to <work>/external-measures.json.
  def record(scan, status:, gaps: nil, dm_hits: nil)
    rec = { 'status' => status, 'remote_models' => scan['remote_models'], 'pointers' => scan['pointers'],
            'proxy_tables' => scan['proxy_tables'] || [], 'dependents' => scan['dependents'] }
    rec['converter_output_pointers'] = dm_hits if dm_hits && !dm_hits.empty?
    rec['gaps'] = gaps if gaps
    rec
  end

  # --- proxy tables under --allow-incomplete-model ----------------------------

  PLACEHOLDER_TYPES = {
    'snowflake' => { 'string' => 'VARCHAR', 'int64' => 'BIGINT', 'double' => 'DOUBLE', 'decimal' => 'DOUBLE',
                     'dateTime' => 'TIMESTAMP', 'boolean' => 'BOOLEAN' },
    'databricks' => { 'string' => 'STRING', 'int64' => 'BIGINT', 'double' => 'DOUBLE', 'decimal' => 'DOUBLE',
                      'dateTime' => 'TIMESTAMP', 'boolean' => 'BOOLEAN' },
    'bigquery' => { 'string' => 'STRING', 'int64' => 'INT64', 'double' => 'FLOAT64', 'decimal' => 'FLOAT64',
                    'dateTime' => 'TIMESTAMP', 'boolean' => 'BOOL' },
    'ansi' => { 'string' => 'VARCHAR', 'int64' => 'BIGINT', 'double' => 'DOUBLE PRECISION',
                'decimal' => 'DOUBLE PRECISION', 'dateTime' => 'TIMESTAMP', 'boolean' => 'BOOLEAN' }
  }.freeze

  # The --warehouse-type -> a PLACEHOLDER_TYPES key, or nil (no reliable cast
  # syntax known: untyped NULLs). Same split as PbiProbeGate.extract_dialect_for.
  def placeholder_dialect(wh_type)
    t = wh_type.to_s.downcase.strip
    return 'snowflake' if t.empty? || t.include?('snowflake')
    return 'databricks' if t.include?('databricks') || t.include?('spark')
    return 'bigquery' if t.include?('bigquery')
    return 'ansi' if t.include?('postgres') || t.include?('redshift')

    nil
  end

  def placeholder_quote(name, wh_type)
    t = wh_type.to_s.downcase
    if %w[bigquery databricks spark mysql].any? { |d| t.include?(d) }
      "`#{name.to_s.gsub('`', '``')}`"
    else
      %("#{name.to_s.gsub('"', '""')}")
    end
  end

  # The SQL output columns the converter binds for a table (same filter as
  # PbiNativeQuery.apply!): [[output name, TMSL dataType]].
  def placeholder_columns(table)
    Array(table['columns']).reject do |c|
      c['type'] == 'rowNumber' || c['isGenerated'] || c['type'] == 'calculated' ||
        c['type'] == 'calculatedTableColumn' || c['dataType'] == 'binary'
    end.map { |c| [(c['sourceColumn'] || c['name']).to_s.sub(/\A\[/, '').sub(/\]\z/, ''), c['dataType'].to_s] }
  end

  # A zero-row SELECT with one typed NULL per bound column, so the element posts,
  # its fields bind, and it reads as empty instead of pointing at a warehouse
  # table that does not exist. No table is referenced (FROM a one-row subquery,
  # WHERE 1 = 0: valid with or without a FROM requirement). A leading block
  # comment says what it stands in for.
  def placeholder_sql(table, proxy, wh_type)
    types = PLACEHOLDER_TYPES[placeholder_dialect(wh_type)]
    cells = placeholder_columns(table).map do |name, dtype|
      value = types ? "CAST(NULL AS #{types[dtype] || types['string']})" : 'NULL'
      "#{value} AS #{placeholder_quote(name, wh_type)}"
    end
    cells = ["NULL AS #{placeholder_quote('placeholder', wh_type)}"] if cells.empty?
    about = "Not migrated: Power BI remote table \"#{proxy['remote_table'] || table['name']}\" in semantic model " \
            "#{model_label(proxy.merge('model' => proxy['model'] || UNRECORDED_MODEL))}. Zero-row placeholder; " \
            'migrate that model, then re-point this element.'
    "/* #{about.gsub('*/', '* /')} */\nSELECT #{cells.join(', ')} FROM (SELECT 1 AS one) AS no_rows WHERE 1 = 0"
  end

  # Rewrite each proxy table's partition in `model` (a TMSL model, mutated) into
  # the placeholder SELECT as a Value.NativeQuery M partition, which the NativeQuery
  # restore (PbiNativeQuery.apply!) turns into the element's Custom SQL source.
  # Returns the table gaps, in the neutralize! shape (element = the table name,
  # which the restore names the element).
  def placeholder_partitions!(model, scan, wh_type)
    gaps = []
    Array(scan['proxy_tables']).each do |p|
      table = (model['tables'] || []).find { |t| t['name'].to_s == p['table'] }
      next unless table

      part = Array(table['partitions']).first || {}
      sql = placeholder_sql(table, p, wh_type)
      m = "let\n    Source = Value.NativeQuery(null, \"#{m_string(sql)}\", null, [EnableFolding=true])\nin\n    Source"
      table['partitions'] = [{ 'name' => part['name'] || table['name'], 'mode' => part['mode'] || 'directQuery',
                               'source' => { 'type' => 'm', 'expression' => m } }]
      gaps << { 'table' => p['table'], 'element' => p['table'], 'name' => p['table'], 'kind' => 'table',
                'reason' => table_reason(p) }
    end
    gaps
  end

  # The proxy tables a failed data-model POST names. Reached when a proxy table
  # still went out with the converter's fallback path <database>.<schema>.<TABLE>
  # (no placeholder: e.g. a --converter-out made from the full model), so the
  # warehouse rejects it as unreadable. That is not a missing GRANT: no
  # warehouse table holds its rows. A name in the error (the warehouse table, an
  # element id, or the element of a formula reference) matches a proxy table by
  # name, case and punctuation ignored. elements: the posted spec's elements.
  def failure_proxies(post_output, elements, scan)
    proxies = Array(scan && scan['proxy_tables'])
    return [] if proxies.empty?

    by_id = {}
    Array(elements).each { |e| by_id[e['id'].to_s] = e if e.is_a?(Hash) && e['id'] }
    out = post_output.to_s
    names = []
    out.scan(/warehouse table '([^']+)'/i) { |m| names << m[0].split('.').last }
    out.scan(/table '([^']+)'/i) do |m|
      el = by_id[m[0]]
      names.push(el['name'], Array(el.dig('source', 'path')).last) if el
    end
    out.scan(%r{formula reference '([^'/]+)/}i) { |m| names << m[0] }
    keys = names.compact.map { |n| name_key(n) }
    proxies.select { |p| keys.include?(name_key(p['table'])) }
  end

  # The box printed before the GRANT advice when a POST failed on proxy tables.
  def failure_lines(proxies)
    lines = ['   ┌─ REMOTE TABLE(S), not a missing GRANT: the data-model POST failed on table(s) that are',
             '   │  DirectQuery proxies of a published Power BI semantic model. No warehouse table holds',
             '   │  their rows, so the --database/--schema path they fell back to does not exist:']
    proxies.first(8).each { |p| lines << "   │    • #{table_label(p)} in semantic model #{model_label(p)}" }
    lines << "   │    … #{proxies.size - 8} more" if proxies.size > 8
    lines.concat(['   │  Migrate that semantic model first, or rerun with --allow-incomplete-model: each remote',
                  '   │  table the run converts then ships as a zero-row Custom SQL placeholder. A --converter-out',
                  '   │  must come from the model the run converts (model-scoped.bim) for that to apply.',
                  '   └─ (refs/local-pbix.md, "Composite / live-connected reports")'])
  end

  # A table name with case and punctuation ignored: "Harbor Sales" == "HARBOR_SALES".
  def name_key(name)
    name.to_s.downcase.gsub(/[^[:alnum:]]+/, '_').gsub(/\A_+|_+\z/, '')
  end

  def table_reason(p)
    "remote table \"#{p['remote_table']}\" in semantic model #{model_label(p)}; shipped as a zero-row " \
      'Custom SQL placeholder (no warehouse path guessed)'
  end

  # SQL text -> the body of an M string literal (decoded by PbiNativeQuery.decode_m_string).
  def m_string(sql)
    sql.gsub('"', '""').gsub('#', '#(0023)').gsub("\r", '#(cr)').gsub("\n", '#(lf)').gsub("\t", '#(tab)')
  end

  # --- helpers ---------------------------------------------------------------

  def elements_of(dm_model)
    ((dm_model && dm_model['pages']) || []).flat_map { |pg| pg['elements'] || [] }
  end

  # A nameless element (the converter's calculated-table SQL, which pbi_calc_table_sql.rb
  # later names after its table) is reported under its Power BI table name.
  def gap(table, el, item, kind, reason)
    element = el['name'].to_s.empty? ? table.to_s : el['name'].to_s
    g = { 'table' => table, 'element' => element, 'name' => (item['name'] || item['id']).to_s,
          'kind' => kind, 'reason' => reason }
    g['element_id'] = el['id'] if el['id']
    g
  end

  # Re-read each gap's element name from the data model: the NativeQuery restore
  # renames a placeholder table's element (and binds the table gaps to an id).
  # A still-nameless element keeps the Power BI table name gap() gave it.
  # converted: PbiNativeQuery.apply!'s 'converted' entries ({ 'table', 'elementId' }).
  def refresh_elements!(gaps, dm_model, converted = [])
    by_id = {}
    elements_of(dm_model).each { |e| by_id[e['id']] = e if e['id'] }
    restored = {}
    Array(converted).each { |c| restored[c['table']] = c['elementId'] }
    gaps.each do |g|
      g['element_id'] ||= restored[g['table']] if g['kind'] == 'table'
      el = g['element_id'] && by_id[g['element_id']]
      g['element'] = el['name'].to_s if el && !el['name'].to_s.empty?
    end
    gaps
  end

  def pointer_reason(p)
    "remote measure \"#{p['remote_measure']}\" in semantic model #{model_label(p)}"
  end

  def pointer_description(p, kind)
    "Not migrated: Power BI remote measure \"#{p['remote_measure']}\" lives in semantic model " \
      "#{model_label(p)}. Migrate that model, then re-point this #{kind}."
  end

  def dependent_reason(d)
    parts = []
    parts << "remote measure(s): #{d['depends_on'].join(', ')}" unless Array(d['depends_on']).empty?
    parts << "remote table(s): #{d['remote_tables'].join(', ')}" unless Array(d['remote_tables']).empty?
    "built on #{parts.join('; ')}"
  end

  def dependent_description(d)
    parts = []
    parts << "Power BI remote measure(s) #{d['depends_on'].join(', ')}" unless Array(d['depends_on']).empty?
    parts << "remote table(s) #{d['remote_tables'].join(', ')}" unless Array(d['remote_tables']).empty?
    "Not migrated: built on #{parts.join(' and ')}, whose DAX or rows live in a remote semantic model."
  end

  def next_id(dm_model, prefix)
    used = {}
    elements_of(dm_model).each do |e|
      used[e['id']] = true
      (Array(e['columns']) + Array(e['metrics'])).each { |h| used[h['id']] = true }
    end
    n = 0
    n += 1 while used["#{prefix}#{n}"]
    "#{prefix}#{n}"
  end

  def pointer_for_formula(formula, scan)
    parsed = parse(formula) || {}
    conn = parsed['connection'].to_s
    known = Array(scan['pointers']).find { |p| p['connection'].casecmp(conn).zero? } || {}
    { 'remote_measure' => parsed['measure'].to_s, 'table' => known['table'],
      'model' => known['model'] || conn.sub(CONNECTION_PREFIX, ''),
      'workspace' => known['workspace'] }
  end

  # The MEASURE references in a DAX expression, downcased. 'Table'[X] or Table[X]
  # is a column when that table has a column X (else a table-qualified measure);
  # an unqualified [X] is a measure reference, as DAX convention has it. Comments
  # and string literals are skipped.
  def measure_refs(expression, columns_of = {})
    out = []
    mask(text(expression)).scan(REF) do |quoted, bare, name|
      table = quoted ? quoted.gsub("''", "'") : bare
      n = name.gsub(']]', ']').strip.downcase
      next if table && Array(columns_of[table.downcase]).include?(n)

      out << n
    end
    out.uniq
  end

  # The tables of `names` ({ downcased name => name }) a DAX expression refers
  # to, as 'Quoted Table' or a bare Table identifier (Table[Col], COUNTROWS(Table)),
  # in first-seen order. Comments, string literals and [Column] / [Measure] names
  # are skipped, and so is a function call: a bare name, dotted ones included
  # (RANK.EQ, STDEV.S), followed by "(" is never a table, so a proxy table named
  # Date, Value or Rank does not match DATE(...), VALUE(...) or RANK.EQ(...).
  # The name is matched atomically ((?>...)): without that, the engine backs off
  # ".EQ" and matches RANK alone, which is not followed by "(".
  BARE_NAME = /\b(?>[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)(?!\s*\()/.freeze

  def table_refs(expression, names)
    return [] if names.empty?

    s = mask(text(expression)).gsub(/\[(?:[^\]]|\]\])*\]/) { |m| ' ' * m.length }
    found = []
    s = s.gsub(/'((?:[^']|'')+)'/) do |m|
      found << Regexp.last_match(1).gsub("''", "'")
      ' ' * m.length
    end
    s.scan(BARE_NAME) { |w| found << w }
    found.map { |n| names[n.downcase] }.compact.uniq
  end

  # Same-length copy of a DAX expression with comments (//, --, /* */) blanked
  # and, unless keep_strings, string-literal contents blanked too, so indexes
  # line up with the original. 'Table' names and [Column] names are skipped
  # whole: a quote or "--" inside them is not syntax.
  def mask(s, keep_strings: false)
    out = s.dup
    blank = ->(from, to) { (from...to).each { |k| out[k] = ' ' unless s[k] == "\n" } }
    i = 0
    n = s.length
    while i < n
      c = s[i]
      if c == '"' || c == "'" || c == '['
        close = c == '[' ? ']' : c
        j = i + 1
        while j < n
          break if s[j] == close && s[j + 1] != close

          j += s[j] == close ? 2 : 1
        end
        blank.call(i + 1, [j, n].min) if c == '"' && !keep_strings
        i = j + 1
      elsif (c == '/' && s[i + 1] == '/') || (c == '-' && s[i + 1] == '-')
        j = s.index("\n", i) || n
        blank.call(i, j)
        i = j
      elsif c == '/' && s[i + 1] == '*'
        j = s.index('*/', i + 2)
        j = j ? j + 2 : n
        blank.call(i, j)
        i = j
      else
        i += 1
      end
    end
    out
  end

  # Top-level, comma-separated arguments of a call whose "(" ends at `start`.
  def split_args(s, start)
    args = []
    buf = +''
    depth = 0
    in_str = false
    i = start
    while i < s.length
      ch = s[i]
      if in_str
        buf << ch
        if ch == '"'
          if s[i + 1] == '"'
            buf << '"'
            i += 1
          else
            in_str = false
          end
        end
      elsif ch == '"'
        in_str = true
        buf << ch
      elsif ch == '('
        depth += 1
        buf << ch
      elsif ch == ')'
        break if depth.zero?

        depth -= 1
        buf << ch
      elsif ch == ',' && depth.zero?
        args << buf
        buf = +''
      else
        buf << ch
      end
      i += 1
    end
    args << buf unless buf.strip.empty? && args.empty?
    args
  end

  def unquote(arg)
    a = arg.to_s.strip
    a.length >= 2 && a.start_with?('"') && a.end_with?('"') ? a[1..-2].gsub('""', '"') : a
  end
end
