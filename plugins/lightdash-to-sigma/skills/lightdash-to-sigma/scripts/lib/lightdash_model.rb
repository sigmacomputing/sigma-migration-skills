# frozen_string_literal: true
# Load a Lightdash semantic layer from an offline source directory and return a
# normalized Hash (see refs/lightdash-source-contract.md):
#
#   dbt project   <root>/dbt/models/**/*.yml  (`models:` + Lightdash `meta:`;
#                 dbt >= 1.10 `config.meta` wins over legacy `meta`)
#   YAML-only     `type: model` files + lightdash.config.yml (no dbt)
#
# Unknown keys are ignored silently (Lightdash ships daily). Relation and
# dialect resolution follow the contract exactly; an unresolvable dialect or
# relation raises LightdashModel::Error -- never a guess.
#
# Returned shape:
#   { 'dialect' =>, 'dialect_source' =>, 'project_name' =>, 'warnings' => [],
#     'models' => { name => {
#        'name','label','description','hidden','relation' => [db, schema, table],
#        'relation_source' => 'manifest'|'config'|'default'|'sql_from',
#        'sql_filter','required_attributes','any_attributes','joins' => [..],
#        'dimensions' => [ { 'name','kind' => 'dimension'|'interval','label','type','sql',
#                            'column','plain','exposed','format','round','hidden',
#                            'required_attributes','urls','additional',
#                            'base','interval' } ],
#        'metrics' => [ { 'name','type','sql','label','format','round','filters','percentile',
#                         'hidden','column','level','sql_defaulted' } ] } } }
#
# Ruby 2.6-compatible, stdlib only.

require 'yaml'
require 'json'
require 'date'

module LightdashModel
  class Error < StandardError; end

  DEFAULT_INTERVALS = %w[DAY WEEK MONTH QUARTER YEAR].freeze
  DIALECTS = %w[bigquery snowflake databricks redshift postgres mysql athena duckdb trino clickhouse].freeze

  module_function

  def load(source_dir, dialect: nil, default_database: nil, default_schema: nil, explore: nil)
    root = File.expand_path(source_dir.to_s)
    raise Error, "source dir not found: #{source_dir}" unless File.directory?(root)
    warnings = []
    manifest = read_manifest(root)
    config = read_config(root)
    dial, dial_src = resolve_dialect(manifest, config, dialect, warnings)
    models = {}
    docs = {}
    each_model_doc(root) do |doc, kind, file|
      m = kind == :yaml_only ? normalize_yaml_model(doc, file) : normalize_dbt_model(doc, file)
      next unless m
      warnings << "model #{m['name']} defined twice (#{file}); later definition wins" if models.key?(m['name'])
      models[m['name']] = m
      docs[m['name']] = doc
    end
    raise Error, "no Lightdash models found under #{root}" if models.empty?
    scoped = explore.to_s.empty? ? models : scoped_models(models, explore)
    scoped.each do |name, m|
      m['relation'], m['relation_source'] = resolve_relation(m, docs[name], manifest, default_database, default_schema)
    end
    require_three_part_paths!(scoped, dial)
    {
      'dialect' => dial,
      'dialect_source' => dial_src,
      'project_name' => manifest.is_a?(Hash) ? manifest.dig('metadata', 'project_name') : nil,
      'models' => models,
      'warnings' => warnings
    }
  end

  THREE_PART_DIALECTS = %w[bigquery snowflake databricks].freeze

  def scoped_models(models, explore)
    base = models[explore.to_s]
    return {} unless base
    names = [explore.to_s] + base['joins'].map { |j| j['join'] }
    models.select { |name, _| names.include?(name) }
  end

  # Sigma warehouse-table paths on these warehouses are <database/project/catalog>.<schema/dataset>.<table>;
  # a 2-part relation (dbt target without a database, no --default-database) would POST a broken path.
  def require_three_part_paths!(models, dial)
    return unless THREE_PART_DIALECTS.include?(dial.to_s)
    bad = models.values.reject { |m| m['relation'].length == 3 }
    return if bad.empty?
    list = bad.map { |m| "#{m['name']} (#{m['relation'].join('.')})" }.join(', ')
    raise Error, "#{dial} needs a 3-part table path (database.schema.table) but could not resolve one for: #{list}; " \
                 'pass --default-database <database/project/catalog> (and --default-schema if the schema is missing too)'
  end

  # ---------------------------------------------------------------- inputs ---

  def read_yaml(path)
    YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [Date, Time], aliases: true)
  rescue Psych::SyntaxError => e
    raise Error, "#{path}: invalid YAML (#{e.message})"
  end

  def read_manifest(root)
    path = [File.join(root, 'dbt', 'target', 'manifest.json'), File.join(root, 'target', 'manifest.json')]
           .find { |p| File.file?(p) }
    return nil unless path
    JSON.parse(File.read(path, encoding: 'UTF-8'))
  rescue JSON::ParserError => e
    raise Error, "#{path}: invalid JSON (#{e.message})"
  end

  def read_config(root)
    path = [File.join(root, 'lightdash.config.yml'), File.join(root, 'dbt', 'lightdash.config.yml')]
           .find { |p| File.file?(p) }
    return {} unless path
    doc = read_yaml(path)
    doc.is_a?(Hash) ? doc : {}
  end

  def resolve_dialect(manifest, config, flag, warnings)
    from_manifest = manifest.is_a?(Hash) ? manifest.dig('metadata', 'adapter_type') : nil
    from_config = config.is_a?(Hash) && config['warehouse'].is_a?(Hash) ? config['warehouse']['type'] : nil
    found = [[from_manifest, 'manifest'], [from_config, 'lightdash.config.yml'], [flag, '--dialect']]
            .find { |v, _| !v.to_s.strip.empty? }
    raise Error, 'warehouse dialect unknown: no manifest adapter_type, no lightdash.config.yml warehouse.type, ' \
                 'and no --dialect flag -- pass --dialect <bigquery|snowflake|...>' unless found
    dial = found[0].to_s.strip.downcase
    if !flag.to_s.strip.empty? && flag.to_s.strip.downcase != dial
      warnings << "--dialect #{flag} ignored: #{found[1]} says #{dial} (resolution order: manifest, lightdash.config.yml, --dialect)"
    end
    warnings << "dialect #{dial.inspect} is not a known warehouse (#{DIALECTS.join(', ')}); identifiers are kept as written" unless DIALECTS.include?(dial)
    [dial, found[1]]
  end

  # Yields [doc, :dbt | :yaml_only, relative_file] for each model definition.
  def each_model_doc(root)
    dbt_root = [File.join(root, 'dbt'), root].find { |d| File.file?(File.join(d, 'dbt_project.yml')) }
    model_dirs = nil
    if dbt_root
      proj = read_yaml(File.join(dbt_root, 'dbt_project.yml'))
      paths = proj.is_a?(Hash) ? (proj['model-paths'] || proj['source-paths']) : nil
      model_dirs = Array(paths || ['models']).map { |p| File.expand_path(p.to_s, dbt_root) }
    end
    files = Dir.glob(File.join(root, '**', '*.{yml,yaml}')).sort.reject do |f|
      rel = f.sub(%r{\A#{Regexp.escape(root)}/?}, '')
      rel =~ %r{\Alightdash/} || rel =~ %r{(\A|/)(target|node_modules|dbt_packages)/} || %w[dbt_project.yml lightdash.config.yml packages.yml profiles.yml].include?(File.basename(f))
    end
    files.each do |f|
      doc = read_yaml(f)
      next unless doc.is_a?(Hash)
      rel = f.sub(%r{\A#{Regexp.escape(root)}/?}, '')
      if doc['type'].to_s == 'model' && doc['name']
        yield doc, :yaml_only, rel
      elsif doc['models'].is_a?(Array)
        next if model_dirs && model_dirs.none? { |d| f.start_with?(d + '/') }
        doc['models'].each do |m|
          yield m, :dbt, rel if m.is_a?(Hash) && m['name']
        end
      end
    end
  end

  # config.meta (dbt >= 1.10) wins over legacy meta, key by key.
  def meta_of(node)
    return {} unless node.is_a?(Hash)
    legacy = node['meta'].is_a?(Hash) ? node['meta'] : {}
    cfg = node['config'].is_a?(Hash) && node['config']['meta'].is_a?(Hash) ? node['config']['meta'] : {}
    legacy.merge(cfg)
  end

  # ------------------------------------------------------------- relations ---

  def split_relation(name)
    name.to_s.split('.').map { |p| p.strip.gsub(/\A[`"\[]|[`"\]]\z/, '') }.reject(&:empty?)
  end

  def resolve_relation(model, doc, manifest, default_database, default_schema)
    return [split_relation(model['sql_from']), 'sql_from'] if model['sql_from']
    node = manifest_node(manifest, model['name'])
    if node && !node['relation_name'].to_s.strip.empty?
      parts = split_relation(node['relation_name'])
      return [parts, 'manifest'] unless parts.empty?
    end
    cfg = doc['config'].is_a?(Hash) ? doc['config'] : {}
    db = cfg['database'] || (node && node['database'])
    schema = cfg['schema'] || (node && node['schema'])
    table = cfg['alias'] || (node && node['alias']) || model['name']
    if schema
      parts = [db, schema, table].compact.map(&:to_s)
      return [parts, 'config']
    end
    if default_schema.to_s.strip.empty? && default_database.to_s.strip.empty?
      raise Error, "cannot resolve the physical table for model #{model['name']}: no manifest relation_name, no " \
                   'database/schema/alias config, and no --default-database/--default-schema'
    end
    [[default_database, default_schema, model['name']].reject { |p| p.to_s.strip.empty? }.map(&:to_s), 'default']
  end

  def manifest_node(manifest, name)
    return nil unless manifest.is_a?(Hash) && manifest['nodes'].is_a?(Hash)
    manifest['nodes'].each_value do |n|
      return n if n.is_a?(Hash) && n['resource_type'] == 'model' && n['name'] == name
    end
    nil
  end

  # ------------------------------------------------------------ normalizers --

  def normalize_joins(raw)
    Array(raw).map do |j|
      next unless j.is_a?(Hash) && j['join']
      {
        'join' => j['join'].to_s,
        'type' => (j['type'] || 'left').to_s,
        'sql_on' => j['sql_on'].to_s,
        'relationship' => j['relationship'],
        'fields' => j['fields'].is_a?(Array) ? j['fields'].map(&:to_s) : nil,
        'exclusions' => j['exclusions'].is_a?(Array) ? j['exclusions'].map(&:to_s) : nil,
        'hidden' => j['hidden'] == true,
        'alias' => j['alias'],
        'label' => j['label']
      }
    end.compact
  end

  def model_header(name, meta, desc)
    {
      'name' => name.to_s,
      'label' => meta['label'].to_s.empty? ? nil : meta['label'].to_s,
      'description' => desc,
      'hidden' => meta['hidden'] == true,
      'sql_filter' => meta['sql_filter'],
      'required_attributes' => meta['required_attributes'].is_a?(Hash) ? meta['required_attributes'] : nil,
      'any_attributes' => meta['any_attributes'].is_a?(Hash) ? meta['any_attributes'] : nil,
      'joins' => normalize_joins(meta['joins']),
      'dimensions' => [],
      'metrics' => []
    }
  end

  def normalize_dbt_model(doc, file)
    meta = meta_of(doc)
    m = model_header(doc['name'], meta, doc['description'])
    m['_file'] = file
    (doc['columns'] || []).each do |col|
      next unless col.is_a?(Hash) && col['name']
      cname = col['name'].to_s
      cm = meta_of(col)
      dim_meta = cm['dimension'].is_a?(Hash) ? cm['dimension'] : {}
      add_dimension(m, cname, dim_meta, column: cname, data_type: col['data_type'], description: col['description'])
      (cm['additional_dimensions'] || {}).each do |aname, spec|
        add_dimension(m, aname.to_s, spec.is_a?(Hash) ? spec : {}, column: cname, additional: true)
      end
      (cm['metrics'] || {}).each do |mname, spec|
        add_metric(m, mname, spec, column: cname, level: 'column')
      end
    end
    (meta['metrics'] || {}).each { |mname, spec| add_metric(m, mname, spec, column: nil, level: 'model') }
    m
  end

  def normalize_yaml_model(doc, file)
    m = model_header(doc['name'], doc, doc['description'])
    m['_file'] = file
    m['sql_from'] = doc['sql_from'].to_s unless doc['sql_from'].to_s.empty?
    dims = doc['dimensions']
    dims = dims.map { |n, s| (s.is_a?(Hash) ? s : {}).merge('name' => n) } if dims.is_a?(Hash)
    Array(dims).each do |d|
      next unless d.is_a?(Hash) && d['name']
      add_dimension(m, d['name'].to_s, d, column: d['name'].to_s)
    end
    (doc['metrics'] || {}).each { |mname, spec| add_metric(m, mname, spec, column: nil, level: 'model') }
    m
  end

  def guess_type(data_type)
    t = data_type.to_s.downcase
    return 'timestamp' if t =~ /timestamp|datetime/
    return 'date' if t =~ /\Adate/
    return 'boolean' if t =~ /bool/
    return 'number' if t =~ /int|numeric|decimal|float|double|number|real/
    'string'
  end

  def only_column_ref(sql)
    sql.to_s.strip[/\A\$\{TABLE\}\.`?"?([A-Za-z_][A-Za-z0-9_]*)`?"?\z/, 1]
  end

  def add_dimension(model, name, spec, column:, data_type: nil, description: nil, additional: false)
    type = (spec['type'] || guess_type(data_type)).to_s.downcase
    sql = spec['sql'].to_s.strip
    sql = nil if sql.empty?
    plain = !additional && (sql.nil? || only_column_ref(sql) == column)
    base = {
      'name' => name,
      'kind' => 'dimension',
      'label' => spec['label'].to_s.empty? ? nil : spec['label'].to_s,
      'type' => type,
      'sql' => sql,
      'column' => column,
      'plain' => plain,
      'exposed' => true,
      'format' => spec['format'],
      'round' => spec['round'],
      'hidden' => spec['hidden'] == true,
      'enabled' => spec['enabled'] != false,
      'required_attributes' => spec['required_attributes'].is_a?(Hash) ? spec['required_attributes'] : nil,
      'any_attributes' => spec['any_attributes'].is_a?(Hash) ? spec['any_attributes'] : nil,
      'urls' => spec['urls'],
      'additional' => additional,
      'description' => description || spec['description']
    }
    intervals = type_intervals(type, spec['time_intervals'])
    base['exposed'] = false unless intervals.empty?
    model['dimensions'] << base
    intervals.each do |iv|
      model['dimensions'] << {
        'name' => "#{name}_#{iv.downcase}",
        'kind' => 'interval',
        'base' => name,
        'interval' => iv,
        'label' => nil,
        'type' => interval_type(iv, type),
        'sql' => nil,
        'column' => nil,
        'plain' => false,
        'exposed' => true,
        'format' => nil,
        'round' => nil,
        'hidden' => base['hidden'],
        'enabled' => base['enabled'],
        'required_attributes' => base['required_attributes'],
        'any_attributes' => base['any_attributes'],
        'urls' => nil,
        'additional' => additional,
        'description' => nil
      }
    end
  end

  def type_intervals(type, raw)
    return [] unless %w[date timestamp].include?(type)
    list = raw.nil? ? DEFAULT_INTERVALS : Array(raw).map { |x| x.to_s.strip.upcase }
    return [] if list.include?('OFF')
    list = DEFAULT_INTERVALS if list == ['DEFAULT']
    list.uniq
  end

  def interval_type(iv, base_type)
    return 'number' if iv.end_with?('_NUM')
    return 'string' if iv.end_with?('_NAME')
    base_type
  end

  def add_metric(model, name, spec, column:, level:)
    spec = {} unless spec.is_a?(Hash)
    sql = spec['sql'].to_s.strip
    defaulted = false
    if sql.empty? && column
      sql = "${TABLE}.#{column}"
      defaulted = true
    end
    model['metrics'] << {
      'name' => name.to_s,
      'type' => spec['type'].to_s.downcase,
      'sql' => sql.empty? ? nil : sql,
      'sql_defaulted' => defaulted,
      'label' => spec['label'].to_s.empty? ? nil : spec['label'].to_s,
      'format' => spec['format'],
      'round' => spec['round'],
      'filters' => spec['filters'],
      'percentile' => spec['percentile'],
      'hidden' => spec['hidden'] == true,
      'column' => column,
      'level' => level
    }
  end

  # ------------------------------------------------- compiled explore path ---
  # Live runs: build the same normalized hash from `GET .../explores/{id}` JSON
  # (saved by lightdash-discover.rb as <dir>/*.json), so no dbt checkout is needed.
  # UNVALIDATED against a real instance; keys are read defensively and a missing
  # or unrecognised key falls back with a warning, never a guess.
  #
  #   explore = { name, baseTable, joinedTables: [{table, sqlOn, type, relationship, fields..}],
  #               warehouse | targetDatabase,
  #               tables: { <name> => { label, sqlTable | (database, schema), sqlWhere,
  #                         requiredAttributes, anyAttributes,
  #                         dimensions: { <n> => {type, sql | compiledSql, label, hidden, format,
  #                                       timeInterval, timeIntervalBaseDimensionName, ..} },
  #                         metrics:    { <n> => {type, sql | compiledSql, filters: [rule], ..} } } } }

  def load_explores(dir, dialect: nil, default_database: nil, default_schema: nil)
    root = File.expand_path(dir.to_s)
    raise Error, "explores dir not found: #{dir}" unless File.directory?(root)
    warnings = []
    models = {}
    dialects = []
    Dir.glob(File.join(root, '**', '*.json')).sort.each do |f|
      doc = begin
        JSON.parse(File.read(f, encoding: 'UTF-8'))
      rescue JSON::ParserError => e
        raise Error, "#{f}: invalid JSON (#{e.message})"
      end
      explore = doc.is_a?(Hash) && doc['results'].is_a?(Hash) ? doc['results'] : doc
      next unless explore.is_a?(Hash) && explore['tables'].is_a?(Hash)
      dialects << (explore['warehouse'] || explore['targetDatabase'])
      base = (explore['baseTable'] || explore['name']).to_s
      explore['tables'].each do |tname, t|
        next unless t.is_a?(Hash)
        m = explore_model(tname.to_s, t, warnings)
        m['relation'], m['relation_source'] = explore_relation(m['name'], t, default_database, default_schema)
        prior = models[m['name']]
        m['joins'] = prior['joins'] if prior && tname.to_s != base
        m['joins'] = normalize_joins(Array(explore['joinedTables']).map { |j| explore_join(j, warnings) }) if tname.to_s == base
        models[m['name']] = m
      end
    end
    raise Error, "no compiled explores found under #{root}" if models.empty?
    found = dialects.compact.map { |d| d.to_s.strip.downcase }.reject(&:empty?).uniq
    warnings << "explores disagree on the warehouse (#{found.join(', ')}); using #{found.first}" if found.length > 1
    dial, dial_src = resolve_dialect({ 'metadata' => { 'adapter_type' => found.first } }, {}, dialect, warnings)
    require_three_part_paths!(models, dial)
    { 'dialect' => dial, 'dialect_source' => dial_src == 'manifest' ? 'explore' : dial_src,
      'project_name' => nil, 'models' => models, 'warnings' => warnings }
  end

  def explore_relation(name, t, default_database, default_schema)
    parts = split_relation(t['sqlTable'])
    return [parts, 'explore'] unless parts.empty?
    table = (t['originalName'] || t['tableName'] || name).to_s
    if t['schema'].to_s.strip.empty?
      if default_schema.to_s.strip.empty? && default_database.to_s.strip.empty?
        raise Error, "cannot resolve the physical table for explore table #{name}: no sqlTable, no schema, " \
                     'and no --default-database/--default-schema'
      end
      return [[default_database, default_schema, table].reject { |p| p.to_s.strip.empty? }.map(&:to_s), 'default']
    end
    [[t['database'], t['schema'], table].reject { |p| p.to_s.strip.empty? }.map(&:to_s), 'explore']
  end

  def explore_join(j, warnings)
    j = {} unless j.is_a?(Hash)
    on = j['sqlOn'] || j['sql_on']
    if on.to_s.strip.empty? && j['compiledSqlOn']
      warnings << "join #{j['table']}: only compiledSqlOn is present; qualified join keys were inferred from compiled SQL (verify the relationship)"
      on = j['compiledSqlOn']
    end
    { 'join' => j['table'] || j['alias'], 'type' => j['type'], 'sql_on' => on, 'relationship' => j['relationship'],
      'fields' => j['fields'], 'exclusions' => j['exclusions'], 'hidden' => j['hidden'], 'alias' => nil,
      'label' => j['label'] }
  end

  def explore_model(tname, t, warnings)
    attrs = lambda do |h, k|
      v = h[k] || h[k.sub(/_(\w)/) { Regexp.last_match(1).upcase }]
      v.is_a?(Hash) ? v : nil
    end
    m = model_header(tname, {
                       'label' => t['label'] == tname ? nil : t['label'], 'hidden' => t['hidden'],
                       'sql_filter' => t['sqlWhere'] || t['sqlFilter'],
                       'required_attributes' => attrs.call(t, 'required_attributes'),
                       'any_attributes' => attrs.call(t, 'any_attributes')
                     }, t['description'])
    dims = t['dimensions'].is_a?(Hash) ? t['dimensions'] : {}
    by_base = {}
    dims.each do |n, d|
      d = {} unless d.is_a?(Hash)
      iv = d['timeInterval'].to_s.strip
      base = d['timeIntervalBaseDimensionName'].to_s.strip
      (by_base[base] ||= []) << [n.to_s, d] unless iv.empty? || base.empty?
    end
    dims.each do |n, d|
      d = {} unless d.is_a?(Hash)
      next if !d['timeInterval'].to_s.empty? && !d['timeIntervalBaseDimensionName'].to_s.empty?
      ivs = by_base.delete(n.to_s)
      explore_add_dim(m, n.to_s, d, ivs, tname, warnings)
    end
    by_base.each do |base, ivs| # base dimension absent from the explore: synthesise it
      explore_add_dim(m, base, { 'type' => ivs[0][1]['type'], 'hidden' => ivs[0][1]['hidden'] }, ivs, tname, warnings)
    end
    (t['metrics'].is_a?(Hash) ? t['metrics'] : {}).each do |n, mt|
      mt = {} unless mt.is_a?(Hash)
      sql = explore_sql(mt, tname, "#{tname}.#{n}", warnings)
      column = only_column_ref(sql)
      spec = { 'type' => mt['type'], 'sql' => sql, 'label' => mt['label'], 'format' => mt['format'],
               'round' => mt['round'], 'filters' => explore_metric_filters(mt['filters'], "#{tname}.#{n}", warnings),
               'percentile' => mt['percentile'], 'hidden' => mt['hidden'] }
      add_metric(m, n.to_s, spec, column: column, level: column ? 'column' : 'model')
    end
    m
  end

  def explore_add_dim(model, name, d, ivs, tname, warnings)
    sql = explore_sql(d, tname, "#{tname}.#{name}", warnings)
    if sql.nil? && ivs # base dimension absent from the explore: take its column from an interval's sql
      isql = explore_sql(ivs[0][1], tname, "#{tname}.#{name}", warnings)
      column = isql.to_s[/\$\{TABLE\}\.`?"?([A-Za-z_][A-Za-z0-9_]*)/, 1]
    end
    column ||= only_column_ref(sql) || sql.to_s[/\$\{TABLE\}\.`?"?([A-Za-z_][A-Za-z0-9_]*)/, 1] || name
    sql = nil if sql && only_column_ref(sql) == column
    spec = { 'type' => d['type'], 'sql' => sql, 'label' => d['label'], 'format' => d['format'], 'round' => d['round'],
             'hidden' => d['hidden'], 'description' => d['description'],
             'required_attributes' => d['requiredAttributes'], 'any_attributes' => d['anyAttributes'] }
    spec['time_intervals'] = ivs.map { |_, x| x['timeInterval'].to_s.upcase } if ivs
    spec['time_intervals'] = ['OFF'] if ivs.nil? && %w[date timestamp].include?(d['type'].to_s)
    add_dimension(model, name, spec, column: column, data_type: d['type'])
  end

  # Prefer the uncompiled `sql` (keeps ${TABLE}/${field} refs the formula engine reads).
  # A compiledSql-only field has its table alias turned back into ${TABLE} (warned).
  def explore_sql(f, tname, label, warnings)
    sql = f['sql'].to_s.strip
    return sql unless sql.empty?
    compiled = f['compiledSql'].to_s.strip
    return nil if compiled.empty?
    warnings << "#{label}: only compiledSql is available; table alias #{tname} rewritten to ${TABLE} (verify the translation)"
    compiled.gsub(/[`"\[]?#{Regexp.escape(tname)}[`"\]]?\./, '${TABLE}.')
  end

  OPERATOR_SHORTHAND = {
    'equals' => ->(v) { v.length == 1 ? v[0] : v },
    'notEquals' => ->(v) { v.length == 1 ? "!#{v[0]}" : nil },
    'isNull' => ->(_) { 'null' },
    'notNull' => ->(_) { '!null' },
    'greaterThan' => ->(v) { "> #{v[0]}" },
    'greaterThanOrEqual' => ->(v) { ">= #{v[0]}" },
    'lessThan' => ->(v) { "< #{v[0]}" },
    'lessThanOrEqual' => ->(v) { "<= #{v[0]}" },
    'startsWith' => ->(v) { "startsWith #{v[0]}" },
    'endsWith' => ->(v) { "endsWith #{v[0]}" },
    'include' => ->(v) { "include #{v[0]}" },
    'doesNotInclude' => ->(v) { "doesNotInclude #{v[0]}" }
  }.freeze

  # Compiled explores carry metric filters as rules ({target:{fieldRef}, operator, values});
  # the dbt YAML carries {field: value} shorthand. Normalize to the shorthand; anything that
  # cannot be expressed is passed through as a date-range-style string so the formula engine
  # records a gap (never a silent equality).
  def explore_metric_filters(raw, label, warnings)
    return nil unless raw.is_a?(Array) && !raw.empty?
    raw.map do |r|
      next r unless r.is_a?(Hash) && r['operator']
      field = (r.dig('target', 'fieldRef') || r['fieldRef']).to_s
      vals = Array(r['values'])
      fn = OPERATOR_SHORTHAND[r['operator'].to_s]
      v = fn ? fn.call(vals) : nil
      if v.nil? || (vals.empty? && !%w[isNull notNull].include?(r['operator'].to_s))
        warnings << "#{label}: metric filter operator #{r['operator'].inspect} on #{field} has no shorthand; recorded as a gap"
        v = "unsupportedOperator #{r['operator']} #{vals.join(',')}"
      end
      { field => v }
    end
  end
end
