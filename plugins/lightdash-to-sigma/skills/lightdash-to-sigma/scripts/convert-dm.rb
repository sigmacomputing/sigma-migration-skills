#!/usr/bin/env ruby
# frozen_string_literal: true
# One Lightdash explore (base dbt model + its joins) -> one Sigma data model.
#
#   ruby scripts/convert-dm.rb --source-dir <dir> --explore <model> \
#       --connection-id <uuid> --out dm.json \
#       [--dialect bigquery] [--default-database D] [--default-schema S] [--folder-id F] \
#       [--signature-out lightdash-signature.json] [--field-map-out field-map.json]
#
# Output: envelope {sigmaDataModel, stats, warnings, gaps, security, dialect, explore}
# plus
#   - lightdash-signature.json  (reuse signature for scripts/find-or-pick-dm.rb)
#   - field-map.json            (Lightdash fieldId -> Sigma element/column/metric;
#                                the interface the workbook builder and RLS steps consume)
#
# DM shape (same pattern as the Omni converter):
#   - one warehouse-table element per model (columns = dimensions + interval columns)
#   - relationships on the base element from meta.joins (sql_on equalities -> key pairs)
#   - one "<Label> (Explore)" element sourced from the base element: every explore
#     column (own + joined, through relationship paths) and every metric. The
#     workbook builder sources charts from this element.
#   - RLS (`sql_filter`, `required_attributes`) is NOT applied here; it is recorded
#     under `security` for the RLS phase.
# Every untranslated construct becomes a gap (degradation-ledger entry shape) AND a
# warning; a skipped field also appears in field-map.json as kind "skipped".
#
# Creds-free. Ruby 2.6-compatible, stdlib only.

require 'json'
require 'optparse'
require_relative 'lib/ruby_compat'
require_relative 'lib/degradation_ledger'
require_relative 'lib/lightdash_ledger'
require_relative 'lib/lightdash_model'
require_relative 'lib/lightdash_formula'

module LightdashDm
  LF = LightdashFormula
  SOURCE = 'convert-dm'

  module_function

  def fold(dialect, ident)
    dialect == 'snowflake' ? ident.to_s.upcase : ident.to_s
  end

  # Mutable accumulation shared by the build phases.
  class Ctx
    attr_accessor :gaps, :warnings, :field_map, :displays, :results, :explore_names, :metric_results, :in_progress,
                  :dim_skips, :explore_id
    def initialize
      @gaps = []
      @warnings = []
      @field_map = {}
      @displays = Hash.new { |h, k| h[k] = {} } # model => { field => unique display }
      @results = {}                              # [model, field] => [formula, err]
      @explore_names = {}                        # [table, field] => explore column name
      @metric_results = {}                       # [table, name] => [formula, err]
      @in_progress = {}
      @dim_skips = {}                            # [model, field] => reason
      @explore_id = nil
    end

    def gap(cls, item, reason)
      @gaps << DegradationLedger.entry(cls, item, reason, SOURCE)
      @warnings << "#{item} -- #{reason}"
    end
  end

  def build(lmodel, explore, connection_id: '<CONNECTION_ID>', folder_id: nil)
    cx = Ctx.new
    cx.explore_id = "el-explore-#{explore}"
    cx.warnings.concat(lmodel['warnings'])
    dialect = lmodel['dialect']
    models = lmodel['models']
    base = models[explore]
    raise LightdashModel::Error, "explore (model) not found: #{explore} (have: #{models.keys.sort.join(', ')})" unless base
    cx.warnings << 'connection id placeholder <CONNECTION_ID> -- pass --connection-id before POST' if connection_id == '<CONNECTION_ID>'

    tables = scope_tables(base, explore, models, cx)
    model_names = tables.map { |t| t[:model] }.uniq
    used_names = {}
    elements = {}
    model_names.each do |mn|
      m = models[mn]
      path = m['relation'].map { |p| fold(dialect, p) }
      if used_names[path.last]
        cx.warnings << "models #{used_names[path.last]} and #{mn} share table name #{path.last}; element names collide"
      end
      used_names[path.last] = mn
      elements[mn] = {
        'id' => "el-#{mn}",
        'kind' => 'table',
        'name' => path.last,
        'source' => { 'kind' => 'warehouse-table', 'connectionId' => connection_id, 'path' => path },
        'columns' => []
      }
      assign_displays(m, cx)
    end
    model_names.each { |mn| build_model_columns(models[mn], elements[mn], dialect, cx) }
    rels = build_relationships(base, tables, models, elements, cx)
    elements[explore]['relationships'] = rels.map { |r| r[:rel] } unless rels.empty?
    explore_el = build_explore(base, explore, tables, rels, models, elements, dialect, cx)

    if cx.field_map.values.any? { |e| e['interval'] == 'WEEK' }
      cx.warnings << 'WEEK intervals use DateTrunc("week"); Lightdash truncates to the project week_start_day -- ' \
                     'verify the first day of week against Sigma before relying on weekly totals'
    end
    ordered = model_names.map { |n| elements[n] }
    label =base['label'] || LF.titleize(explore)
    spec = {
      'name' => "#{label} (Lightdash)",
      'schemaVersion' => 1,
      'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'elements' => ordered + [explore_el] }]
    }
    spec['folderId'] = folder_id if folder_id && !folder_id.to_s.empty?
    all_els = ordered + [explore_el]
    skipped = cx.field_map.values.count { |e| e['kind'] == 'skipped' }
    stats = {
      'models' => ordered.length,
      'elements' => all_els.length,
      'columns' => all_els.sum { |el| el['columns'].length },
      'metrics' => all_els.sum { |el| (el['metrics'] || []).length },
      'relationships' => rels.length,
      'fields_mapped' => cx.field_map.length - skipped,
      'fields_skipped' => skipped,
      'gaps' => cx.gaps.length
    }
    envelope = {
      'sigmaDataModel' => spec,
      'stats' => stats,
      'warnings' => cx.warnings,
      'gaps' => cx.gaps,
      'security' => build_security(tables, models, explore_el, explore, cx),
      'dialect' => dialect,
      'explore' => explore
    }
    [envelope, build_signature(label, ordered, explore_el), cx.field_map]
  end

  # --------------------------------------------------------------- scope -----

  # [{table:, model:, join:, rel_name:}] base first. `table` is the name used in
  # field ids (join alias, else the model name).
  def scope_tables(base, explore, models, cx)
    tables = [{ table: explore, model: explore, join: nil }]
    base['joins'].each do |j|
      table = (j['alias'] || j['join']).to_s
      unless models.key?(j['join'])
        cx.gap('scope-cut', "join #{table}", "joined model #{j['join']} is not defined in the project; its fields are not converted")
        next
      end
      if tables.any? { |t| t[:table] == table }
        cx.gap('scope-cut', "join #{table}", 'duplicate join name; second join skipped')
        next
      end
      tables << { table: table, model: j['join'], join: j }
    end
    tables
  end

  # ------------------------------------------------------- model elements ----

  def assign_displays(model, cx)
    seen = {}
    model['dimensions'].each do |d|
      next unless d['enabled']
      label = if d['kind'] == 'interval'
                base = model['dimensions'].find { |x| x['name'] == d['base'] }
                "#{LF.display_name(base['name'], base['label'])} #{LF.titleize(d['interval'])}"
              else
                LF.display_name(d['name'], d['label'])
              end
      if seen[label.downcase]
        cx.warnings << "model #{model['name']}: display name #{label.inspect} used twice; #{d['name']} renamed"
        label = "#{label} (#{d['name']})"
      end
      seen[label.downcase] = true
      cx.displays[model['name']][d['name']] = label
    end
  end

  def dim_by_name(model, name)
    model['dimensions'].find { |d| d['name'] == name }
  end

  # Memoized [formula, err] for one dimension column of a model element.
  def dim_result(model, dim, el_name, dialect, cx)
    key = [model['name'], dim['name']]
    return cx.results[key] if cx.results.key?(key)
    return [nil, "circular reference through ${#{dim['name']}}"] if cx.in_progress[key]
    cx.in_progress[key] = true
    res = compute_dim(model, dim, el_name, dialect, cx)
    cx.in_progress.delete(key)
    cx.results[key] = res
  end

  def compute_dim(model, dim, el_name, dialect, cx)
    return [nil, 'dimension disabled in source (enabled: false)'] unless dim['enabled']
    if dim['kind'] == 'interval'
      base = dim_by_name(model, dim['base'])
      bf, berr = dim_result(model, base, el_name, dialect, cx)
      return [nil, "base dimension #{base['name']} was skipped: #{berr}"] unless bf
      return LF.interval_formula(dim['interval'], "[#{cx.displays[model['name']][base['name']]}]")
    end
    return ["[#{el_name}/#{LF.titleize(dim['column'])}]", nil] if dim['plain']
    return [nil, 'dimension has no sql and no column'] if dim['sql'].nil?
    ctx = {
      dialect: dialect,
      table_column: ->(col) { "[#{el_name}/#{LF.titleize(col)}]" },
      field: lambda do |t, n|
        if !t.nil? && t != model['name']
          next [nil, "${#{t}.#{n}} references another model; cross-model dimension SQL is not translated"]
        end
        target = dim_by_name(model, n)
        next [nil, "${#{n}} is not a dimension of #{model['name']} (dimension SQL cannot reference metrics)"] unless target
        f, err = dim_result(model, target, el_name, dialect, cx)
        f ? "[#{cx.displays[model['name']][n]}]" : [nil, "depends on ${#{n}}, which was skipped: #{err}"]
      end
    }
    LF.translate_expr(dim['sql'], ctx)
  end

  def build_model_columns(model, element, dialect, cx)
    mn = model['name']
    model['dimensions'].each do |d|
      f, err = dim_result(model, d, element['name'], dialect, cx)
      unless f
        cx.displays[mn].delete(d['name'])
        cx.dim_skips[[mn, d['name']]] = err
        cx.gap('scope-cut', "#{d['kind']} #{mn}.#{d['name']}", err)
        next
      end
      col = { 'id' => "col-#{mn}-#{d['name']}", 'name' => cx.displays[mn][d['name']], 'formula' => f }
      col['description'] = d['description'] if d['description'].is_a?(String) && !d['description'].empty?
      col['hidden'] = true if d['hidden']
      fmt = dim_format(d, mn, cx)
      col['format'] = fmt if fmt
      note_dim_extras(d, mn, cx)
      element['columns'] << col
    end
  end

  def dim_format(d, mn, cx)
    return nil if d['kind'] == 'interval'
    fmt = LF.sigma_format(d['format'], type: d['type'], round: d['round'])
    if fmt.nil? && !d['format'].nil? && d['format'].to_s != ''
      cx.gap('quality-waiver', "format of #{mn}.#{d['name']}", "format #{d['format'].inspect} has no Sigma translation; column left unformatted")
    end
    fmt
  end

  def note_dim_extras(d, mn, cx)
    return if d['urls'].nil? || (d['urls'].respond_to?(:empty?) && d['urls'].empty?)
    cx.gap('quality-waiver', "urls of #{mn}.#{d['name']}", 'dimension urls (Liquid templates) are not converted')
  end

  # ------------------------------------------------------- relationships -----

  def build_relationships(base, tables, models, elements, cx)
    rels = []
    used = {}
    tables.each do |t|
      j = t[:join]
      next unless j
      pairs = LF.parse_sql_on(j['sql_on'])
      unless pairs
        t[:failed] = "join sql_on #{j['sql_on'].inspect} is not a conjunction of ${a.x} = ${b.y} equalities"
        cx.gap('scope-cut', "join #{t[:table]}", "#{t[:failed]}; relationship and joined fields skipped")
        next
      end
      keys = []
      pairs.each do |p|
        if [p['left_table'], p['right_table']] == [t[:table], base['name']] || [p['left_table'], p['right_table']] == [t[:model], base['name']]
          p = { 'left_table' => p['right_table'], 'left_field' => p['right_field'],
                'right_table' => p['left_table'], 'right_field' => p['left_field'] }
        end
        unless p['left_table'] == base['name'] && [t[:table], t[:model]].include?(p['right_table'])
          t[:failed] = "join sql_on references #{p['left_table']}/#{p['right_table']}, expected #{base['name']} and #{t[:table]}"
          break
        end
        src = cx.displays[base['name']][p['left_field']]
        tgt = cx.displays[t[:model]][p['right_field']]
        unless src && tgt
          t[:failed] = "join key #{p['left_field']} / #{p['right_field']} is not a converted dimension"
          break
        end
        keys << { 'sourceColumnId' => "col-#{base['name']}-#{p['left_field']}",
                  'targetColumnId' => "col-#{t[:model]}-#{p['right_field']}" }
      end
      if t[:failed]
        cx.gap('scope-cut', "join #{t[:table]}", "#{t[:failed]}; relationship and joined fields skipped")
        next
      end
      name = (j['label'] || LF.titleize(t[:table])).to_s
      name = "#{name} (#{t[:table]})" if used[name.downcase]
      used[name.downcase] = true
      t[:rel_name] = name
      if %w[inner right full].include?(j['type'].to_s.downcase)
        cx.gap('quality-waiver', "join type of #{t[:table]}", "#{j['type']} join becomes a Sigma relationship (left-join semantics); rows without a match are not dropped")
      end
      rel = {
        'id' => "rel-#{base['name']}-#{t[:table]}",
        'name' => name,
        'targetElementId' => elements[t[:model]]['id'],
        'relationshipType' => LF.relationship_type(j['relationship']),
        'keys' => keys
      }
      rels << { table: t[:table], rel: rel }
    end
    rels
  end

  # ------------------------------------------------------ explore element ----

  def join_allows?(join, name, base_name)
    return true unless join
    if join['fields']
      return join['fields'].include?(name) || join['fields'].include?(base_name)
    end
    return !(join['exclusions'].include?(name) || join['exclusions'].include?(base_name)) if join['exclusions']
    true
  end

  def unique_explore_name(name, t, taken, cx)
    return name unless taken[name.downcase]
    alt = "#{t[:rel_name] || LF.titleize(t[:table])} #{name}"
    n = 2
    cand = alt
    while taken[cand.downcase]
      cand = "#{alt} #{n}"
      n += 1
    end
    cx.warnings << "explore column #{name.inspect} from #{t[:table]} collides with an earlier column; renamed #{cand.inspect}"
    cand
  end

  def build_explore(base, explore, tables, rels, models, elements, dialect, cx)
    base_el = elements[explore]
    live = tables.reject { |t| t[:failed] }
    columns = []
    taken = {}
    # Fields of tables whose join failed are recorded as skipped (never silent).
    tables.select { |t| t[:failed] }.each do |t|
      mark_table_skipped(models[t[:model]], t, "join to #{t[:table]} skipped: #{t[:failed]}", cx)
    end
    live.each do |t|
      m = models[t[:model]]
      join = t[:join]
      path = t[:join] ? "#{base_el['name']}/#{t[:rel_name]}" : base_el['name']
      m['dimensions'].each do |d|
        disp = cx.displays[m['name']][d['name']]
        field_id = "#{t[:table]}_#{d['name']}"
        unless disp
          if d['exposed']
            cx.field_map[field_id] = { 'kind' => 'skipped', 'was' => d['kind'] == 'interval' ? 'interval' : 'dimension',
                                       'model' => m['name'], 'table' => t[:table], 'field' => d['name'],
                                       'reason' => cx.dim_skips[[m['name'], d['name']]] }
          end
          next
        end
        base_name = d['kind'] == 'interval' ? d['base'] : d['name']
        allowed = join_allows?(join, d['name'], base_name)
        name = unique_explore_name(disp, t, taken, cx)
        taken[name.downcase] = true
        cx.explore_names[[t[:table], d['name']]] = name
        col = { 'id' => "ex-#{t[:table]}-#{d['name']}", 'name' => name, 'formula' => "[#{path}/#{disp}]" }
        col['hidden'] = true if d['hidden'] || !allowed || (join && join['hidden'])
        src_col = elements[t[:model]]['columns'].find { |c| c['name'] == disp }
        col['format'] = src_col['format'] if src_col && src_col['format']
        columns << col
        next unless d['exposed']
        if allowed
          cx.field_map[field_id] = dim_entry(d, m, t, cx.explore_id, name, col)
        else
          cx.field_map[field_id] = { 'kind' => 'skipped', 'was' => d['kind'] == 'interval' ? 'interval' : 'dimension',
                                     'model' => m['name'], 'table' => t[:table], 'field' => d['name'],
                                     'reason' => 'excluded by the join fields/exclusions list (kept as a hidden column)' }
        end
      end
    end
    metrics = build_metrics(live, models, base_el, dialect, cx, columns)
    {
      'id' => cx.explore_id,
      'kind' => 'table',
      'name' => "#{base['label'] || LF.titleize(explore)} (Explore)",
      'source' => { 'kind' => 'table', 'elementId' => base_el['id'] },
      'columns' => columns,
      'metrics' => metrics
    }
  end

  def mark_table_skipped(model, t, reason, cx)
    model['dimensions'].each do |d|
      next unless d['exposed']
      cx.field_map["#{t[:table]}_#{d['name']}"] = {
        'kind' => 'skipped', 'was' => d['kind'] == 'interval' ? 'interval' : 'dimension',
        'model' => model['name'], 'table' => t[:table], 'field' => d['name'], 'reason' => reason
      }
    end
    model['metrics'].each do |mt|
      cx.field_map["#{t[:table]}_#{mt['name']}"] = {
        'kind' => 'skipped', 'was' => 'metric', 'model' => model['name'], 'table' => t[:table],
        'field' => mt['name'], 'reason' => reason
      }
    end
  end

  def dim_entry(d, model, t, explore_id, name, col)
    entry = {
      'kind' => d['kind'] == 'interval' ? 'interval' : 'dimension',
      'model' => model['name'],
      'table' => t[:table],
      'field' => d['name'],
      'type' => d['type'],
      'element_id' => explore_id,
      'column_id' => col['id'],
      'name' => name,
      'format' => col['format'],
      'hidden' => col['hidden'] ? true : false,
      'source_element_id' => "el-#{model['name']}",
      'source_column_id' => "col-#{model['name']}-#{d['name']}"
    }
    if d['kind'] == 'interval'
      entry['interval'] = d['interval']
      entry['base_field'] = d['base']
    end
    entry
  end

  # ------------------------------------------------------------- metrics -----

  def build_metrics(live, models, base_el, dialect, cx, columns)
    out = []
    taken = {}
    columns.each { |c| taken[c['name'].downcase] = true }
    explore_id = cx.explore_id
    live.each do |t|
      m = models[t[:model]]
      m['metrics'].each do |mt|
        field_id = "#{t[:table]}_#{mt['name']}"
        unless join_allows?(t[:join], mt['name'], mt['name'])
          cx.gap('scope-cut', "metric #{t[:table]}.#{mt['name']}", 'excluded by the join fields/exclusions list')
          cx.field_map[field_id] = { 'kind' => 'skipped', 'was' => 'metric', 'model' => m['name'], 'table' => t[:table],
                                     'field' => mt['name'], 'reason' => 'excluded by the join fields/exclusions list' }
          next
        end
        formula, err = metric_result(live, models, t, mt, dialect, cx)
        unless formula
          cx.gap('scope-cut', "metric #{t[:table]}.#{mt['name']}", err)
          cx.field_map[field_id] = { 'kind' => 'skipped', 'was' => 'metric', 'model' => m['name'], 'table' => t[:table],
                                     'field' => mt['name'], 'reason' => err }
          next
        end
        name = LF.display_name(mt['name'], mt['label'])
        if taken[name.downcase]
          alt = "#{t[:rel_name] || LF.titleize(t[:table])} #{name}"
          alt = "#{alt} Metric" if taken[alt.downcase]
          cx.warnings << "metric name #{name.inspect} collides with a column or metric in the explore element; renamed #{alt.inspect}"
          name = alt
        end
        taken[name.downcase] = true
        met = { 'id' => "met-#{t[:table]}-#{mt['name']}", 'name' => name, 'formula' => formula }
        fmt = LF.sigma_format(mt['format'], round: mt['round'])
        if fmt.nil? && !mt['format'].nil? && mt['format'].to_s != ''
          cx.gap('quality-waiver', "format of metric #{t[:table]}.#{mt['name']}", "format #{mt['format'].inspect} has no Sigma translation; metric left unformatted")
        end
        met['format'] = fmt if fmt
        if mt['hidden']
          cx.gap('quality-waiver', "hidden flag of metric #{t[:table]}.#{mt['name']}",
                 'Sigma data-model metrics have no hidden flag; metric emitted visible (source hidden: true recorded in field-map)')
        end
        out << met
        cx.field_map[field_id] = {
          'kind' => 'metric', 'model' => m['name'], 'table' => t[:table], 'field' => mt['name'],
          'metric_type' => mt['type'], 'element_id' => explore_id, 'column_id' => met['id'],
          'metric_id' => met['id'], 'name' => name, 'format' => fmt, 'hidden' => mt['hidden'] ? true : false,
          'derivation' => derivation(formula)
        }
      end
    end
    out
  end

  def derivation(formula)
    fn = formula[/\A([A-Za-z]+)\(/, 1]
    %w[Sum Count CountDistinct Avg Min Max Median SumIf CountIf CountDistinctIf AvgIf MinIf MaxIf PercentileCont].include?(fn) ? fn : 'Formula'
  end

  def metric_result(live, models, t, mt, dialect, cx)
    key = [t[:table], mt['name']]
    return cx.metric_results[key] if cx.metric_results.key?(key)
    return [nil, "circular reference through ${#{mt['name']}}"] if cx.in_progress[[:m, key]]
    cx.in_progress[[:m, key]] = true
    res = compute_metric(live, models, t, mt, dialect, cx)
    cx.in_progress.delete([:m, key])
    cx.metric_results[key] = res
  end

  def find_table(live, models, name, own)
    return own if name.nil? || name == own[:table] || name == own[:model]
    live.find { |x| x[:table] == name } || live.find { |x| x[:model] == name }
  end

  def explore_ref(cx, table, field)
    n = cx.explore_names[[table[:table], field]]
    n ? "[#{n}]" : nil
  end

  def compute_metric(live, models, t, mt, dialect, cx)
    model = models[t[:model]]
    type = mt['type']
    unless LF::AGG.key?(type) || type == 'percentile' || %w[number string date timestamp boolean].include?(type) || LF::GAP_METRIC_TYPES.include?(type)
      return [nil, "metric type #{type.inspect} is not supported"]
    end
    if LF::GAP_METRIC_TYPES.include?(type)
      return [nil, "metric type #{type} is a post-calculation (relative to other result rows) with no data-model equivalent; rebuild as a workbook calculation"]
    end
    ctx = {
      dialect: dialect,
      table_column: lambda do |col|
        d = model['dimensions'].find { |x| x['plain'] && x['column'] == col && x['kind'] == 'dimension' }
        next [nil, "metric references raw column #{col}, which is not a plain converted dimension"] unless d
        ref = explore_ref(cx, t, d['name'])
        ref || [nil, "raw column #{col} was skipped as a dimension"]
      end,
      field: lambda do |tn, n|
        tt = find_table(live, models, tn, t)
        next [nil, "${#{tn}.#{n}} references a table outside this explore"] unless tt
        tm = models[tt[:model]]
        if (d = dim_by_name(tm, n))
          ref = explore_ref(cx, tt, d['name'])
          next ref || [nil, "${#{n}} refers to a dimension that was skipped"]
        end
        if (other = tm['metrics'].find { |x| x['name'] == n })
          f, err = metric_result(live, models, tt, other, dialect, cx)
          next f ? "(#{f})" : [nil, "depends on metric ${#{n}}, which was skipped: #{err}"]
        end
        [nil, "unresolved reference ${#{n}}"]
      end
    }
    if %w[number string date timestamp boolean].include?(type)
      return [nil, "#{type} metric has no sql"] if mt['sql'].nil?
      return LF.translate_expr(mt['sql'], ctx, aggregates: true)
    end
    expr = nil
    unless mt['sql'].nil?
      expr, err = LF.translate_expr(mt['sql'], ctx)
      return [nil, err] unless expr
    end
    types = {}
    model['dimensions'].each { |d| types[d['name']] = d['type'] }
    pred, perr = LF.filter_predicate(mt['filters'], lambda { |n|
      n = n.split('.').last
      d = dim_by_name(model, n)
      d ? (explore_ref(cx, t, n) || [nil, "filter dimension #{n} was skipped"]) : nil
    }, types: types)
    return [nil, perr] if perr
    if expr.nil?
      return [nil, "#{type} metric has no sql"] unless type == 'count'
      return [pred ? "CountIf(#{pred})" : 'Count()', nil]
    end
    LF.aggregate_formula(type, expr, pred: pred, percentile: mt['percentile'])
  end

  # ------------------------------------------------------ security/signature -

  def build_security(tables, models, explore_el, explore, cx)
    per_model = {}
    col_attrs = []
    tables.each do |t|
      m = models[t[:model]]
      entry = {}
      entry['sql_filter'] = m['sql_filter'] if m['sql_filter']
      entry['required_attributes'] = m['required_attributes'] if m['required_attributes']
      entry['any_attributes'] = m['any_attributes'] if m['any_attributes']
      per_model[m['name']] = entry unless entry.empty? || per_model.key?(m['name'])
      m['dimensions'].each do |d|
        next unless d['required_attributes'] || d['any_attributes']
        id = cx.explore_names[[t[:table], d['name']]] ? "ex-#{t[:table]}-#{d['name']}" : nil
        entry = { 'model' => m['name'], 'table' => t[:table], 'field' => d['name'], 'column_id' => id,
                  'element_id' => explore_el['id'] }
        entry['required_attributes'] = d['required_attributes'] if d['required_attributes']
        entry['any_attributes'] = d['any_attributes'] if d['any_attributes']
        col_attrs << entry
      end
    end
    unless per_model.empty? && col_attrs.empty?
      cx.warnings << 'row/column security (sql_filter, required_attributes) recorded under `security`; not applied to the data model'
    end
    { 'explore' => explore, 'models' => per_model, 'column_required_attributes' => col_attrs }
  end

  def build_signature(label, model_elements, explore_el)
    {
      'tableau_workbook' => label,
      'source' => 'lightdash',
      'warehouse_tables' => model_elements.map { |el| el['source']['path'].join('.') },
      'referenced_columns' => model_elements.flat_map { |el| el['columns'].map { |c| c['name'] } }.uniq,
      'measures' => (explore_el['metrics'] || []).map { |m| { 'col' => m['name'], 'derivation' => derivation(m['formula']) } }
    }
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = { connection_id: '<CONNECTION_ID>' }
  OptionParser.new do |o|
    o.on('--source-dir DIR') { |v| opts[:source_dir] = v }
    o.on('--explores-dir DIR') { |v| opts[:explores_dir] = v } # compiled explore JSON from lightdash-discover.rb
    o.on('--explore NAME') { |v| opts[:explore] = v }
    o.on('--connection-id ID') { |v| opts[:connection_id] = v }
    o.on('--folder-id ID') { |v| opts[:folder_id] = v }
    o.on('--dialect D') { |v| opts[:dialect] = v }
    o.on('--default-database D') { |v| opts[:default_database] = v }
    o.on('--default-schema S') { |v| opts[:default_schema] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--signature-out PATH') { |v| opts[:signature_out] = v }
    o.on('--field-map-out PATH') { |v| opts[:field_map_out] = v }
  end.parse!(ARGV)
  { explore: '--explore', out: '--out' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end
  abort 'pass --source-dir <dbt/YAML project> or --explores-dir <compiled explore JSON>' if opts[:source_dir].to_s.empty? && opts[:explores_dir].to_s.empty?
  begin
    live = opts[:source_dir].to_s.empty?
    load_opts = { dialect: opts[:dialect], default_database: opts[:default_database], default_schema: opts[:default_schema] }
    load_opts[:explore] = opts[:explore] unless live
    lmodel = LightdashModel.send(live ? :load_explores : :load, live ? opts[:explores_dir] : opts[:source_dir], **load_opts)
    envelope, signature, field_map = LightdashDm.build(lmodel, opts[:explore],
                                                       connection_id: opts[:connection_id], folder_id: opts[:folder_id])
  rescue LightdashModel::Error => e
    abort "error: #{e.message}"
  end
  File.write(opts[:out], JSON.pretty_generate(envelope) + "\n")
  dir = File.dirname(opts[:out])
  File.write(opts[:signature_out] || File.join(dir, 'lightdash-signature.json'), JSON.pretty_generate(signature) + "\n")
  File.write(opts[:field_map_out] || File.join(dir, 'field-map.json'), JSON.pretty_generate(field_map) + "\n")
  # The verdict reads coverage.json / offramps.jsonl, not dm.json: record every DM gap there too.
  LightdashLedger.write(File.dirname(File.expand_path(opts[:out])), envelope['gaps'], origin: 'lightdash-convert-dm')
  s = envelope['stats']
  warn "wrote #{opts[:out]} (#{s['elements']} elements, #{s['columns']} columns, #{s['metrics']} metrics, " \
       "#{s['relationships']} relationships, #{s['gaps']} gaps, #{envelope['warnings'].length} warnings)"
end
