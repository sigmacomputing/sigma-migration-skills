# frozen_string_literal: true
#
# PbiDirectMap -- the master-map of the opt-in `--model-shape pbi` mode (spec: "Workbook", "No Data page").
#
# The existing master-map describes the hidden Data-page tables a workbook reads. Here every "master" is a
# data model ELEMENT that the charts read directly, so the map keeps its shape (`masters`, `fields`,
# `page_fields`) and each master carries `direct: true` and `element_name`:
#
#   master  {id: "master-<x>", element_id (the readback id), data_model, direct: true, element_name,
#            columns: [{id, name, formula}], metrics: [{name, formula}]}
#     columns  the element's own columns (formula "[<Element>/<Col>]") plus the columns it reaches along
#              many-to-one relationship paths of up to `max_hops`, named "<Col> (<Rel>)" or
#              "<Col> (<Rel1>/<Rel2>)" with formula "[<Element>/<Rel1>/<Rel2>/<Col>]" (probe P1).
#   field   "<PBI table>.<PBI column or measure>" => {master, ref: "[<master id>/<column>]", agg, formula?, alts}
#     * a column is keyed on the master of the element that owns it; every master that reaches it through
#       relationships carries an alt, so the builder's visual_master picks the fact master for a visual that
#       mixes dimension fields with that fact's measures.
#     * class A/B measure: the master of the element holding the metric, ref "[Metrics/<metric>]".
#     * class C measure: the time-intelligence element's master column, formula "<consumer_agg>([<id>/<col>])".
#       Its date-level columns (DateTrunc of the date) are alts of the date table's fields.
#     * class D measure: not mapped (integrate's page_fields covers it); listed in `class_d_fields`.
#   page_fields  USERELATIONSHIP routing (R45): on a page whose visual reads a measure that activates an
#                inactive relationship next to fields of that relationship's target table, those fields read
#                "<Col> (<Target> (<fromColumn>))" on the fact's master. A page that also reads the field
#                through the active relationship is not routed; its userel visuals are listed in `conflicts`.
require 'digest'
require 'set'
require_relative 'pbi_shaped_model'
require_relative 'pbi_master_key'
require_relative 'pbi_element_match'
require_relative 'pbi_date_fields'

module PbiDirectMap
  module_function

  S = PbiShapedModel

  Hop = Struct.new(:rels, :target)
  PATH_SEPARATOR = " \u2215 " # U+2215 DIVISION SLASH: reads like a path but is not a ref separator

  # Build the direct master-map.
  #   dm_model    the shaped data model (after PbiShapedModel.apply!)
  #   dm_readback the readback of the posted data model ({'dataModelId', 'pages' => [{'elements'}]})
  #   classes     apply!'s log['classes'] ({"Table.Measure" => class entry})
  #   time_intel  apply!'s log['time_intel'] (records of the class C forms)
  #   signals     the report signals (pages, visuals, bindings); only the USERELATIONSHIP routing reads them
  #   flattened   {fact name => flattened element name} (apply!'s log['flattened']): the fact's master reads the
  #               flattened element instead (see swap_flattened!)
  # Returns {'masters','fields','page_fields','conflicts','class_d_fields','unresolved'}.
  def build(dm_model, dm_readback, tmsl, classes, max_hops: 4, time_intel: [], signals: nil, flattened: {})
    classes ||= {}
    elements = S.elements_of(dm_model)
    by_id = S.by_id_map(dm_model)
    split_bases = S.split_pairs(dm_model).map { |_child, base| base }
    masters_els = elements.reject { |e| split_bases.any? { |b| b.equal?(e) } }
    rb_elements = S.elements_of(dm_readback || {})
    paired = PbiElementMatch.pair(elements, rb_elements)
    rb_for = {}.compare_by_identity
    elements.each_with_index { |e, i| rb_for[e] = paired[i] }
    dm_id = (dm_readback || {})['dataModelId']

    keys = {}.compare_by_identity
    taken_keys = Set.new
    masters_els.each_with_index do |el, i|
      keys[el] = S.unique_name(el['name'] || "Custom SQL #{i + 1}", taken_keys)
    end
    # unique_name downcases into the set; the key itself keeps the element's spelling
    masters = {}
    columns_of = {}.compare_by_identity
    masters_els.each do |el|
      mkey = keys[el]
      mid = PbiMasterKey.master_id(mkey)
      cols = master_columns(el, mkey, by_id, max_hops)
      columns_of[el] = cols
      rb = rb_for[el]
      metrics = Array(el['metrics']).map { |m| { 'name' => m['name'], 'formula' => m['formula'] } }
      if rb && rb.key?('metrics')
        confirmed = Array(rb['metrics']).map { |m| m['name'] }
        metrics = metrics.select { |m| confirmed.include?(m['name']) }
      end
      masters[mkey] = { 'id' => mid, 'element_id' => (rb && rb['id']) || el['id'], 'data_model' => dm_id, 'direct' => true,
                        'element_name' => el['name'], 'columns' => cols.map { |c| c.reject { |k, _| k.start_with?('_') } },
                        'metrics' => metrics }
    end

    # a rolling-window summary has no column of the date table's fields; the shape pass wires a date slicer to it through a
    # filter column over its day column (the builder reads these two keys to say so instead of NOT wired)
    Array(time_intel).select { |r| r['form'] == 'rolling_sql' }.each do |rec|
      el = elements.find { |e| e['name'] == rec['element'] }
      next unless el && keys[el]
      day = rolling_day_column(el)
      masters[keys[el]]['day_column'] = S.display_name(day)
      masters[keys[el]]['date_tables'] = date_tables(classes, tmsl)
    end

    fields = {}
    unresolved = []
    aliases = pbi_column_aliases(tmsl)
    # 1. own columns, keyed on the owning element's master
    masters_els.each do |el|
      mkey = keys[el]
      mid = masters[mkey]['id']
      columns_of[el].each do |c|
        next unless c['_own']
        fields["#{el['name']}.#{c['name']}"] ||= { 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil }
      end
    end
    # 2. related columns: an alt on every master that reaches them
    masters_els.each do |el|
      mkey = keys[el]
      mid = masters[mkey]['id']
      columns_of[el].each do |c|
        next unless c['_target']
        fs = fields["#{c['_target']['name']}.#{c['_column']}"]
        next unless fs
        add_alt(fs, 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil)
      end
    end
    # 3. Power BI names that differ from the Sigma column name only by the bracket swap
    aliases.each do |(table, pbi), display|
      fs = fields["#{table}.#{display}"]
      fields["#{table}.#{pbi}"] ||= deep_copy(fs) if fs
    end

    # 4. measures
    class_d = []
    classes.each do |key, c|
      table, measure = key.split('.', 2)
      case c['class']
      when 'D' then class_d << key
      when 'A', 'B' then bind_metric(fields, masters, keys, elements, key, table, measure, c, unresolved)
      when 'C' then bind_time_intel(fields, masters, keys, elements, key, time_intel, unresolved)
      end
    end
    dts = date_tables(classes, tmsl)
    infos = PbiDateFields.infos(tmsl, dts)
    date_alts!(fields, masters, keys, elements, tmsl, classes, time_intel, infos)
    measure_alts!(fields, masters, keys, elements, time_intel)
    date_columns!(masters, keys, elements, columns_of, dts)

    page_fields = {}
    conflicts = []
    userel_routes!(page_fields, conflicts, masters, keys, elements, classes, signals) if signals
    swap_flattened!(flattened, masters, fields, page_fields, conflicts, keys, elements, by_id, rb_for, max_hops, signals)
    asof = asof_plan(signals, classes, time_intel, dts)
    held = whole_form_visuals(signals, classes, time_intel, dts, infos) +
           nonadditive_visuals(signals, classes, time_intel, dts, elements, infos) +
           asof['held'] + date_field_visuals(signals, classes, time_intel, dts, infos) + calc_override_visuals(signals, classes)
    { 'masters' => masters, 'fields' => fields, 'page_fields' => page_fields, 'conflicts' => conflicts,
      'class_d_fields' => class_d, 'unresolved' => unresolved, 'date_tables' => dts, 'asof_ignore_date' => asof['ignore'],
      'class_d_visuals' => class_d_visuals(signals, classes, conflicts, held: held) }
  end

  # ---------------------------------------------------------------------------------------
  # Flattened facts (Task 17)
  # ---------------------------------------------------------------------------------------

  # The fact's master keeps its id, its fields and its measure refs, but reads the flattened element: element
  # id/name, columns and metrics come from it. Fields reaching related columns through the fact's relationships
  # now read the Lookup column of the flattened element that carries the same value (found by its formula);
  # a related field no Lookup column carries loses its alt on this master (another master may still hold it).
  # The flattened element's own master and fields are dropped. The flattened element has no relationship path to
  # an inactive Date, so a USERELATIONSHIP route on the swapped master becomes a conflict (class D) instead.
  def swap_flattened!(flattened, masters, fields, page_fields, conflicts, keys, elements, by_id, rb_for, max_hops, signals = nil)
    read = Set.new
    Array((signals || {})['pages']).each do |pg|
      Array(pg['visuals']).each { |v| (v['bindings'] || {}).each_value { |refs| Array(refs).each { |r| read << r.to_s } } }
      Array(pg['filters']).each { |f| read << f['target'].to_s if f.is_a?(Hash) }
    end
    Array((signals || {})['filters']).each { |f| read << f['target'].to_s if f.is_a?(Hash) }
    (flattened || {}).each do |fact_name, flat_name|
      fact_el = elements.find { |e| e['name'].to_s.casecmp(fact_name.to_s).zero? }
      flat_el = elements.find { |e| e['name'] == flat_name }
      next unless fact_el && flat_el && keys[fact_el] && keys[flat_el]
      fk = keys[fact_el]
      flk = keys[flat_el]
      mid = masters[fk]['id']
      cols = master_columns(flat_el, fk, by_id, max_hops)
      rb = rb_for[flat_el]
      masters[fk] = masters[fk].merge('element_id' => (rb && rb['id']) || flat_el['id'], 'element_name' => flat_el['name'],
                                      'columns' => cols.map { |c| c.reject { |k, _| k.start_with?('_') } },
                                      'metrics' => masters[flk]['metrics'])
      masters.delete(flk)
      fields.delete_if { |k, _| k.start_with?("#{flat_el['name']}.") }
      lost = fields.select { |_k, fs| Array(fs['alts']).any? { |a| a['master'] == fk } }.keys
      fields.each_value { |fs| (fs['alts'] || []).delete_if { |a| a['master'] == fk || a['master'] == flk } }
      fields.each_value { |fs| fs.delete('alts') if fs['alts'] && fs['alts'].empty? }
      fields.each_value { |fs| fs['master'] = fk if fs['master'] == flk }
      cols.each do |c|
        next unless c['_own']
        el_col = Array(flat_el['columns']).find { |x| S.display_name(x) == c['name'] }
        lt = el_col && S.lookup_target_table(el_col['formula'])
        value = el_col && el_col['formula'].to_s[%r{\ALookup\(\[[^\]/]+/([^\]]+)\]}, 1]
        next unless lt && value
        fs = fields["#{lt}.#{value}"]
        add_alt(fs, 'master' => fk, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil) if fs
      end
      # a related field no Lookup column carries must not vanish silently (a slicer on it would stop filtering)
      lost.each do |field|
        next if signals && !read.include?(field)
        next if Array(fields[field]['alts']).any? { |a| a['master'] == fk }
        conflicts << { 'page' => nil, 'field' => field, 'class' => 'D',
                       'reason' => "#{flat_el['name']} has no Lookup column for #{field}: a slicer or visual on it cannot filter the flattened #{fact_name}" }
      end
      page_fields.each do |title, routes|
        routes.delete_if do |field, route|
          next false unless route['master'] == fk
          conflicts << { 'page' => title, 'field' => field, 'class' => 'D',
                         'reason' => "#{flat_el['name']} has no inactive-relationship path for #{field}" }
          true
        end
      end
      page_fields.delete_if { |_t, routes| routes.empty? }
    end
  end

  # ---------------------------------------------------------------------------------------
  # Columns
  # ---------------------------------------------------------------------------------------

  def column_id(mkey, name)
    "mc-#{Digest::SHA1.hexdigest("#{mkey}/#{name}")[0, 10]}"
  end

  # Own columns plus the columns reached along relationship paths. Private keys (`_own`, `_target`,
  # `_column`, `_path`) tell build() what each column is; they are stripped from the master.
  def master_columns(el, mkey, by_id, max_hops)
    taken = Set.new
    cols = []
    Array(el['columns']).each do |c|
      name = S.unique_name(S.ref_safe(S.display_name(c)), taken)
      cols << { 'id' => column_id(mkey, name), 'name' => name, 'formula' => "[#{el['name']}/#{name}]", '_own' => true }
    end
    paths_from(el, by_id, max_hops).each do |hop|
      tgt = hop.target
      real = hop.rels.map { |r| r['name'].to_s }
      Array(tgt['columns']).each do |c|
        base = S.display_name(c).to_s
        # R47: a "/" never appears in a name. The column is "<Col> (<last Rel>)"; only a collision uses the
        # whole path, joined with U+2215 (division slash), so the formula keeps the real path.
        short = S.ref_safe("#{base} (#{real.last})")
        name = if taken.include?(short.downcase) && real.length > 1
                 S.ref_safe("#{base} (#{real.join(PATH_SEPARATOR)})")
               else
                 short
               end
        name = S.unique_name(name.tr('/', PATH_SEPARATOR.strip), taken)
        cols << { 'id' => column_id(mkey, name), 'name' => name,
                  'formula' => "[#{el['name']}/#{real.join('/')}/#{base}]",
                  '_target' => tgt, '_column' => base, '_path' => real }
      end
    end
    cols
  end

  # Every many-to-one path of 1..max_hops relationships from `el` (never revisiting an element), in
  # breadth-first order with a relationship named after its target before an activated inactive one.
  def paths_from(el, by_id, max_hops)
    out = []
    queue = [[el, [], [el['id']]]]
    until queue.empty?
      cur, rels, seen = queue.shift
      next if rels.length >= max_hops
      ordered = Array(cur['relationships']).sort_by do |r|
        t = by_id[r['targetElementId']]
        t && r['name'].to_s.casecmp(t['name'].to_s).zero? ? 0 : 1
      end
      ordered.each do |r|
        t = by_id[r['targetElementId']]
        next unless t && !seen.include?(t['id'])
        path = rels + [r]
        out << Hop.new(path, t)
        queue << [t, path, seen + [t['id']]]
      end
    end
    out
  end

  # [[table, Power BI column name], ...] => Sigma display name, for the columns whose name changed
  # (a bracket in a Power BI name becomes a parenthesis).
  def pbi_column_aliases(tmsl)
    out = {}
    S.tables_of(tmsl).each do |t|
      Array(t['columns']).each do |c|
        next if c['type'] == 'rowNumber'
        safe = S.ref_safe(c['name'])
        out[[t['name'], c['name']]] = safe if safe != c['name']
      end
    end
    out
  end

  def deep_copy(h)
    Marshal.load(Marshal.dump(h))
  end

  def add_alt(fs, alt)
    alts = (fs['alts'] ||= [])
    return if alts.any? { |a| a['master'] == alt['master'] } || fs['master'] == alt['master']
    alts << alt
  end

  # ---------------------------------------------------------------------------------------
  # Measures
  # ---------------------------------------------------------------------------------------

  # The element holding the metric called `name` (or its "(measure)" rename), the home element first.
  def metric_holder(elements, name, home)
    wanted = [name, "#{name} (measure)"]
    holders = elements.select { |e| Array(e['metrics']).any? { |m| wanted.include?(m['name']) } }
    holders.find { |e| e['name'].to_s.casecmp(home.to_s).zero? } || holders.find { |e| e['groupings'].nil? } || holders.first
  end

  def bind_metric(fields, masters, keys, elements, key, table, measure, entry, unresolved)
    home = (entry['home'] || table).to_s
    el = metric_holder(elements, measure, home)
    unless el && keys[el]
      unresolved << { 'key' => key, 'reason' => "no element holds a metric named #{measure}" }
      return
    end
    metric = Array(el['metrics']).find { |m| [measure, "#{measure} (measure)"].include?(m['name']) }
    ref = "[Metrics/#{metric['name']}]"
    fs = { 'master' => keys[el], 'ref' => ref, 'agg' => nil, 'formula' => ref }
    fields[key] = fs
    fields["#{home}.#{measure}"] ||= fs if home.casecmp(table) != 0
  end

  def bind_time_intel(fields, masters, keys, elements, key, time_intel, unresolved)
    rec = Array(time_intel).find { |r| r['measure'] == key }
    unless rec
      unresolved << { 'key' => key, 'reason' => 'class C measure has no generated time-intelligence form' }
      return
    end
    el = elements.find { |e| e['name'] == rec['element'] }
    unless el && keys[el]
      unresolved << { 'key' => key, 'reason' => "time-intelligence element #{rec['element']} is not a master" }
      return
    end
    if rec['form'] == 'metric'
      ref = "[Metrics/#{rec['column']}]"
      fields[key] = { 'master' => keys[el], 'ref' => ref, 'agg' => nil, 'formula' => ref }
    else
      mid = masters[keys[el]]['id']
      col = "[#{mid}/#{rec['column']}]"
      day = rec['form'] == 'rolling_sql' ? rolling_day_column(el) : nil
      fields[key] = { 'master' => keys[el], 'ref' => col, 'agg' => nil,
                      'formula' => consumer_formula(rec, mid, col, day && S.display_name(day)) }
    end
  end

  # The chart formula of a class C field: what Power BI shows at the chart's filter context, read over the rows of the
  # time-intelligence element that are in scope (a chart axis, a Year slicer, or no date axis at all, as in a KPI).
  #
  #   YTD/QTD/MTD  TOTALYTD is the running total AS OF the last date in the context, so the field keeps the value on the latest
  #                period in scope: Sum(If([Period] = Max([Period]), [col], Null)). Per period it is that period's own row; with
  #                no axis it is the latest period's; a Year pick narrows the rows and Max([Period]) follows. Max alone would
  #                return the largest running total of any period (a past year's full-year total).
  #   PY / PP      SAMEPERIODLASTYEAR/DATEADD shift the whole filter-context date set, so over several periods the value is
  #                the prior total of the whole range: Sum of the prior column over the rows in scope (one row per period).
  #   YoY %        a ratio of totals: (Sum(base) - Sum(prior)) / Sum(prior). When a slicer field is carried above the date
  #                levels the element carries numerator and denominator columns instead (R19), read with Sum.
  #   rolling      the window ENDING at the context's last day, so the value on the latest day in scope: per day that day's
  #                value, per month or carried field the last day's, with no date axis (a KPI) the latest day's, which Max (the
  #                largest window ever) and Sum (every day added) both get wrong.
  #
  # A record without a `kind` (an older map) keeps the previous read: consumer_agg (Max, or Sum with a carried slicer field,
  # probe P15) over the column, a carried ratio divided after summing.
  # m7: a rolling element's day column is the one named Day (PbiTimeIntelGen writes it first). It is never guessed as
  # "the first column that is not the measure", and a missing one raises instead of reading the window with Max.
  def rolling_day_column(el)
    day = Array(el['columns']).find { |c| S.display_name(c).to_s == 'Day' }
    raise ArgumentError, "rolling element #{el['name']} has no Day column" unless day
    day
  end

  def consumer_formula(rec, mid, col, day_col = nil)
    agg = rec['consumer_agg'] || 'Max'
    return "Sum(If([#{mid}/#{day_col}] = Max([#{mid}/#{day_col}]), #{col}, Null))" if day_col && rec['form'] == 'rolling_sql'
    ratio = rec['ratio']
    if ratio.is_a?(Hash) && ratio['numerator'] && ratio['denominator']
      return "#{agg}([#{mid}/#{ratio['numerator']}]) / NullIf(#{agg}([#{mid}/#{ratio['denominator']}]), 0)"
    end
    case rec['kind']
    when 'ytd', 'qtd', 'mtd'
      period = rec['period']
      return "Sum(If([#{mid}/#{period}] = Max([#{mid}/#{period}]), #{col}, Null))" if period
    when 'py', 'pp'
      return "Sum(#{col})"
    when 'yoy'
      y = rec['yoy']
      if y.is_a?(Hash) && y['base'] && y['prior']
        b = "Sum([#{mid}/#{y['base']}])"
        p = "Sum([#{mid}/#{y['prior']}])"
        return "(#{b} - #{p}) / NullIf(#{p}, 0)"
      end
    end
    "#{agg}(#{col})"
  end

  # A grouped time-intelligence element reads its fact's base measure (and any A metric the chart also
  # shows) as a column "[Metrics/<name>]": that column is an alt of the measure's field. A metric that is a single Sum or
  # Count is additive, so it is read with Sum (the total over the periods in scope, which is the value of the one row at a
  # chart axis at the element's grain); another metric (a ratio, an average) is not, and keeps the per-row Max read.
  def measure_alts!(fields, masters, keys, elements, time_intel)
    names = Array(time_intel).select { |r| r['form'] == 'grouped' }.map { |r| r['element'] }.uniq
    names.each do |name|
      el = elements.find { |e| e['name'] == name }
      next unless el && keys[el]
      mid = masters[keys[el]]['id']
      agg = (Array(time_intel).find { |r| r['element'] == name && r['consumer_agg'] } || {})['consumer_agg'] || 'Max'
      fact = elements.find { |e| e['id'] == (el['source'] || {})['elementId'] }
      Array(el['columns']).each do |c|
        metric = c['formula'].to_s[%r{\A\[Metrics/(.+)\]\z}, 1]
        next unless metric
        read = agg == 'Max' && additive_metric?(fact, metric) ? 'Sum' : agg
        fields.each do |k, fs|
          next unless fs['formula'] == "[Metrics/#{metric}]" && fs['master'] != keys[el]
          col = "[#{mid}/#{S.display_name(c)}]"
          add_alt(fs, 'master' => keys[el], 'ref' => col, 'agg' => nil, 'formula' => "#{read}(#{col})")
        end
      end
    end
  end

  def additive_metric?(fact, name)
    m = fact && Array(fact['metrics']).find { |x| x['name'] == name }
    agg = m && S.single_aggregate(m['formula'])
    !agg.nil? && %w[Sum Count].include?(agg[0])
  end

  # ---------------------------------------------------------------------------------------
  # Date levels of the time-intelligence elements
  # ---------------------------------------------------------------------------------------

  def date_unit(name)
    n = name.to_s
    return 'day' if n =~ /\A(date|day)\z/i
    return 'quarter' if n =~ /quarter/i
    return 'month' if n =~ /month/i && n !~ /(number|name|num|no)\b/i
    return 'year' if n =~ /\byear\b/i
    nil
  end

  def date_tables(classes, tmsl)
    named = classes.values.map { |c| c.dig('ti', 'date_table') }.compact.uniq
    return named unless named.empty?
    marked = S.tables_of(tmsl).select { |t| t['dataCategory'].to_s.casecmp('Time').zero? }.map { |t| t['name'] }
    marked.empty? ? ['Date'] : marked
  end

  # The unit of a date-table field when its values provably equal that calendar level (PbiDateFields), else nil. With no
  # `infos` (an older caller) the name decides, as before.
  def field_unit(infos, table, column)
    return date_unit(column) if infos.nil?
    i = infos[[table.to_s.downcase, column.to_s.downcase]]
    i && i['unit']
  end

  def field_info(infos, table, column)
    infos && infos[[table.to_s.downcase, column.to_s.downcase]]
  end

  # The date table's fields (Month Start, Year, Date, ...) are alts on the time-intelligence elements'
  # matching date-level columns. I2: only a field whose values PROVABLY equal the column is bound to it. A date field
  # (the Date column, a calculated Month Start) reads the DateTrunc("<unit>", ...) column; an integer Year / Quarter /
  # Month Number reads the element's own Year()/Quarter()/Month() column ("<Unit> Number"); a Fiscal or unknown field
  # gets no alt. A rolling element has its Day column only. Only a column of the element's own grain or coarser exists.
  def date_alts!(fields, masters, keys, elements, tmsl, classes, time_intel, infos = nil)
    tables = date_tables(classes, tmsl)
    infos ||= PbiDateFields.infos(tmsl, tables)
    units = {}
    S.tables_of(tmsl).each do |t|
      next unless tables.include?(t['name'])
      Array(t['columns']).each do |c|
        i = field_info(infos, t['name'], c['name'])
        units[[t['name'], c['name']]] = [i['unit'], i['form']] if i
      end
    end
    return if units.empty?
    Array(time_intel).each do |rec|
      el = elements.find { |e| e['name'] == rec['element'] }
      next unless el && keys[el] && rec['form'] != 'metric'
      mid = masters[keys[el]]['id']
      level_cols = {}
      Array(el['columns']).each do |c|
        unit = c['formula'].to_s[/\ADateTrunc\("(year|quarter|month|week|day)"/, 1]
        level_cols[[unit, 'date']] = S.display_name(c) if unit
        int = c['formula'].to_s[/\A(Year|Quarter|Month)\(\[/, 1]
        level_cols[[int.downcase, 'int']] = S.display_name(c) if int
      end
      level_cols[['day', 'date']] = S.display_name(rolling_day_column(el)) if rec['form'] == 'rolling_sql'
      units.each do |(table, column), (unit, form)|
        target = level_cols[[unit, form]]
        fs = fields["#{table}.#{column}"]
        next unless target && fs
        add_alt(fs, 'master' => keys[el], 'ref' => "[#{mid}/#{target}]", 'agg' => nil)
      end
    end
  end

  # master['date_columns']: the names of the master's columns that read the date table (its own columns when the master is
  # the date table, a related column reached through the date table otherwise). The workbook pass uses them to keep date
  # controls off an element whose measures Power BI ignores them for (as-of metrics, C1).
  def date_columns!(masters, keys, elements, columns_of, tables)
    wanted = Array(tables).map { |t| t.to_s.downcase }
    elements.each do |el|
      next unless keys[el] && columns_of[el]
      names = columns_of[el].select do |c|
        (c['_own'] && wanted.include?(el['name'].to_s.downcase)) || (c['_target'] && wanted.include?(c['_target']['name'].to_s.downcase))
      end.map { |c| c['name'] }
      masters[keys[el]]['date_columns'] = names unless names.empty?
    end
  end

  # ---------------------------------------------------------------------------------------
  # USERELATIONSHIP routing (R45)
  # ---------------------------------------------------------------------------------------

  def userel_target(userel)
    userel.to_s.sub(/ \(.*\)\z/, '')
  end

  def measure_key(classes, ref)
    return ref.to_s if classes.key?(ref.to_s)
    hits = classes.keys.select { |k| k.split('.', 2)[1] == ref.to_s }
    hits.length == 1 ? hits[0] : nil
  end

  def control_visual?(v)
    v['sigma_kind'].to_s == 'control' || v['visual_type'].to_s == 'slicer'
  end

  def filter_targets(list)
    Array(list).select { |f| f.is_a?(Hash) && f['target'] }.map { |f| f['target'].to_s }
  end

  # I3: a date-table control (slicer or page filter) on a page that reads a USERELATIONSHIP measure is routed through the
  # activated path, like the fields bound on the visuals themselves: a Year slicer next to a ship-date chart filters by
  # ship year, as Power BI does. When the control would also reach a visual that reads the active path, or when a
  # report-level filter on the table reaches it, the USERELATIONSHIP visuals are held back (class D) like any other conflict.
  def userel_routes!(page_fields, conflicts, masters, keys, elements, classes, signals)
    report_fields = filter_targets((signals || {})['filters'])
    Array(signals['pages']).each do |page|
      next if page['hidden']
      title = page['page_title'].to_s
      visuals = Array(page['visuals']).reject { |v| v['hidden'] }
      info = visuals.map do |v|
        refs = (v['bindings'] || {}).values.flatten.compact.map(&:to_s)
        measure_keys = refs.map { |r| measure_key(classes, r) }.compact
        dims = refs.reject { |r| measure_key(classes, r) }
        userels = measure_keys.map { |k| classes[k]['userel'] }.compact.uniq
        { v: v, dims: dims, keys: measure_keys, userels: userels, control: control_visual?(v) }
      end
      userel_visuals = info.select { |i| !i[:userels].empty? && !i[:control] }
      next if userel_visuals.empty?
      control_fields = (info.select { |i| i[:control] }.flat_map { |i| i[:dims] } + filter_targets(page['filters'])).uniq
      targets = userel_visuals.flat_map { |i| i[:userels].map { |u| userel_target(u) } }.uniq
      targets.each do |target|
        uv_t = userel_visuals.select { |i| i[:userels].any? { |u| userel_target(u) == target } }
        ctl_fields = control_fields.select { |f| f.split('.', 2)[0] == target }
        rep_fields = report_fields.select { |f| f.split('.', 2)[0] == target }.uniq
        unless rep_fields.empty?
          uv_t.each do |i|
            conflicts << { 'page' => title, 'visual' => i[:v]['title'] || i[:v]['visual_id'], 'visual_id' => i[:v]['visual_id'],
                           'field' => rep_fields[0], 'class' => 'D',
                           'reason' => "a report-level filter on #{rep_fields[0]} reaches this visual through the active relationship" }
          end
          next
        end
        active_visuals = info.select { |i| !i[:control] && !i[:keys].empty? && !uv_t.include?(i) }
        fields_here = (uv_t.flat_map { |i| i[:dims] }.select { |d| d.split('.', 2)[0] == target } + ctl_fields).uniq
        fields_here.each do |field|
          is_ctl = ctl_fields.include?(field)
          readers = info.select { |i| i[:dims].include?(field) && !i[:control] }
          uv = readers.select { |i| i[:userels].any? { |u| userel_target(u) == target } }
          uv = uv_t if uv.empty? && is_ctl
          others = readers - uv
          others |= active_visuals if is_ctl
          mixed = uv.select { |i| i[:keys].any? { |k| classes[k]['userel'].nil? || userel_target(classes[k]['userel']) != target } ||
                                  i[:userels].length > 1 }
          rels = uv.flat_map { |i| i[:userels] }.uniq
          if !others.empty? || !mixed.empty? || rels.length != 1
            reason = if !others.empty?
                       is_ctl ? "page #{title} has a control on #{field} that also reaches visuals through the active relationship" :
                                "page #{title} also reads #{field} through the active relationship"
                     elsif !mixed.empty?
                       "a visual mixes #{field} through the inactive and the active relationship"
                     else
                       "page #{title} reads #{field} through more than one inactive relationship"
                     end
            uv.each do |i|
              conflicts << { 'page' => title, 'visual' => i[:v]['title'] || i[:v]['visual_id'], 'visual_id' => i[:v]['visual_id'],
                             'field' => field, 'class' => 'D', 'reason' => reason }
            end
            next
          end
          route = routed_field(masters, keys, elements, classes, uv, field, rels[0])
          (page_fields[title] ||= {})[field] = route if route
        end
      end
    end
  end

  HELD_SUFFIX = 'Sigma reads one path per element'

  # Visual-level class D (Task 21x): the visible visuals whose measures need two relationship paths to one table (an
  # order-date measure and a ship-date USERELATIONSHIP measure on one Date axis), or that userel_routes!/swap_flattened!
  # recorded as a conflict. A visual bound to a class D MEASURE is not listed: it has no field entry, so the builder
  # already holds it back. Returns [{'page','visual','visual_id','reason','table'}].
  def class_d_visuals(signals, classes, conflicts, held: [])
    out = []
    Array((signals || {})['pages']).each do |page|
      next if page['hidden']
      title = page['page_title'].to_s
      Array(page['visuals']).each do |v|
        next if v['hidden'] || v['sigma_kind'].to_s == 'control' || v['visual_type'].to_s == 'slicer'
        entries = (v['bindings'] || {}).values.flatten.compact.map { |r| PbiMeasureClass.class_for_ref(r, classes) }.compact
        next if entries.empty? || entries.any? { |e| e['class'] == 'D' }
        next unless PbiMeasureClass.classify_visual(v, classes) == 'D'
        table, labels = visual_paths(entries)
        reason = labels.length > 1 ? "needs two relationship paths to #{table}: #{labels.join(', ')}; #{HELD_SUFFIX}" :
                                      "reads measures that share no relationship path; #{HELD_SUFFIX}"
        out << { 'page' => title, 'visual' => v['title'] || v['visual_id'], 'visual_id' => v['visual_id'], 'table' => table, 'reason' => reason }
      end
    end
    Array(held).each do |h|
      out << h unless out.any? { |o| o['page'] == h['page'] && o['visual_id'] == h['visual_id'] }
    end
    Array(conflicts).each do |c|
      next if out.any? { |o| o['page'] == c['page'] && (o['visual_id'] == c['visual_id'] || o['visual'] == c['visual']) }
      table = c['field'].to_s.split('.', 2)[0]
      out << { 'page' => c['page'], 'visual' => c['visual'], 'visual_id' => c['visual_id'], 'table' => table,
               'reason' => "needs two relationship paths to #{table}: #{c['reason']}; #{HELD_SUFFIX}" }
    end
    out
  end

  # Visuals that read a PREVIOUSYEAR/PREVIOUSQUARTER/PREVIOUSMONTH measure (a record's `whole`) with no date field at the
  # element's grain. Those functions return the one previous period of an anchor date of the context, so a read over several
  # periods (a KPI, a table with no date column, a coarser axis) has no exact form in a grouped element, while one row per
  # period (an axis at the grain) is exact. Held back like any class D visual (the page summary path still serves them).
  # Returns [{'page','visual','visual_id','table','reason'}].
  def whole_form_visuals(signals, classes, time_intel, date_tables, infos = nil)
    whole = {}
    Array(time_intel).each { |r| whole[r['measure']] = r if r['whole'] }
    return [] if whole.empty?
    tables = Array(date_tables).map { |t| t.to_s.downcase }
    out = []
    Array((signals || {})['pages']).each do |page|
      next if page['hidden']
      Array(page['visuals']).each do |v|
        next if v['hidden'] || v['sigma_kind'].to_s == 'control' || v['visual_type'].to_s == 'slicer'
        refs = (v['bindings'] || {}).values.flatten.compact.map(&:to_s)
        recs = refs.map { |r| whole[measure_key(classes || {}, r)] }.compact.uniq
        next if recs.empty?
        units = refs.map do |r|
          t, c = r.split('.', 2)
          tables.include?(t.to_s.downcase) ? field_unit(infos, t, c) : nil
        end.compact
        bad = recs.reject { |r| units.include?(r['grain'].to_s) }
        next if bad.empty?
        r = bad[0]
        out << { 'page' => page['page_title'].to_s, 'visual' => v['title'] || v['visual_id'], 'visual_id' => v['visual_id'],
                 'table' => r['measure'].split('.', 2)[0],
                 'reason' => "#{r['measure'].split('.', 2)[1]} (#{r['whole']}) is the one previous #{r['unit']} of an anchor date, exact only with a " \
                             "#{r['grain']} date axis, and this visual has none; #{HELD_SUFFIX}" }
      end
    end
    out
  end

  # Visuals that read a NON-ADDITIVE metric (an average, a ratio, a distinct count: not a single Sum/Count) through a grouped
  # time-intelligence element whose grain the visual has no date field at. The element holds one value per period, so a read
  # over several periods (a KPI, a table with no date column, a coarser axis) has no exact aggregate for it: Sum adds averages,
  # Max reads one period's. An additive metric reads Sum (measure_alts!). A direct read of the parent metric is not possible
  # either: a workbook visual reads ONE master, and the same visual's class C measure lives only on the grouped element. So
  # the visual is held back like any class D visual (the page summary path still serves it).
  # Returns [{'page','visual','visual_id','table','reason'}].
  def nonadditive_visuals(signals, classes, time_intel, date_tables, elements, infos = nil)
    grouped = {}
    Array(time_intel).each { |r| grouped[r['measure']] = r if r['form'] == 'grouped' && r['period'] }
    return [] if grouped.empty?
    tables = Array(date_tables).map { |t| t.to_s.downcase }
    out = []
    Array((signals || {})['pages']).each do |page|
      next if page['hidden']
      Array(page['visuals']).each do |v|
        next if v['hidden'] || v['sigma_kind'].to_s == 'control' || v['visual_type'].to_s == 'slicer'
        refs = (v['bindings'] || {}).values.flatten.compact.map(&:to_s)
        recs = refs.map { |r| grouped[measure_key(classes || {}, r)] }.compact.uniq
        next if recs.empty?
        units = refs.map do |r|
          t, c = r.split('.', 2)
          tables.include?(t.to_s.downcase) ? field_unit(infos, t, c) : nil
        end.compact
        recs.each do |rec|
          next if units.include?(rec['period'].to_s.downcase)
          el = Array(elements).find { |e| e['name'] == rec['element'] }
          fact = el && Array(elements).find { |e| e['id'] == (el['source'] || {})['elementId'] }
          bad = refs.map { |r| measure_key(classes || {}, r) }.compact.uniq.find do |k|
            c = classes[k]
            next false unless c && fact && %w[A B].include?(c['class']) && c['home'].to_s == fact['name'].to_s
            name = k.split('.', 2)[1]
            Array(el['columns']).any? { |col| col['formula'].to_s == "[Metrics/#{name}]" } && !additive_metric?(fact, name)
          end
          next unless bad
          out << { 'page' => page['page_title'].to_s, 'visual' => v['title'] || v['visual_id'], 'visual_id' => v['visual_id'],
                   'table' => bad.split('.', 2)[0],
                   'reason' => "#{bad.split('.', 2)[1]} is not additive (not a single Sum or Count), so it cannot be read over several #{rec['period'].to_s.downcase}s " \
                               "of #{rec['element']}, and this visual has no #{rec['period'].to_s.downcase} date axis; #{HELD_SUFFIX}" }
          break
        end
      end
    end
    out
  end

  # Every visible, non-control visual of the report: [page, visual].
  def data_visuals(signals)
    out = []
    Array((signals || {})['pages']).each do |page|
      next if page['hidden']
      Array(page['visuals']).each do |v|
        next if v['hidden'] || control_visual?(v)
        out << [page, v]
      end
    end
    out
  end

  def held_entry(page, v, table, reason)
    { 'page' => page['page_title'].to_s, 'visual' => v['title'] || v['visual_id'], 'visual_id' => v['visual_id'], 'table' => table, 'reason' => reason }
  end

  # C1: an as-of time-intelligence measure (CALCULATE([X], DATESBETWEEN('Date'[Date], ..., asof)), form `metric`) ignores every
  # Date-table filter in Power BI: the CALCULATE filter on the marked date column replaces them. The Sigma metric is
  # evaluated per group and filtered by date controls, so
  #   * a visual that binds an as-of metric with a date-table field is held back (Power BI plots one flat value);
  #   * a visual that mixes as-of with other measures under a date control (a page slicer, a page, report or visual filter on the
  #     date table) is held back;
  #   * a visual whose measures are ALL as-of and that has a page date slicer or page filter keeps its element, but the
  #     control is not targeted at it (`ignore`: [{page, visual_id}], the workbook pass skips those picks);
  #   * a report-level or visual-level date filter cannot be kept off the element: the visual is held back.
  # A no-axis KPI on a page with no date control is exact and stays as it is.
  # Returns {'held' => [...], 'ignore' => [{'page','visual','visual_id'}]}.
  def asof_plan(signals, classes, time_intel, tables)
    asof = {}
    Array(time_intel).each { |r| asof[r['measure']] = r if r['form'] == 'metric' }
    return { 'held' => [], 'ignore' => [] } if asof.empty?
    tabs = Array(tables).map { |t| t.to_s.downcase }
    date_field = ->(ref) { tabs.include?(ref.to_s.split('.', 2)[0].to_s.downcase) }
    report_date = filter_targets((signals || {})['filters']).any?(&date_field)
    held = []
    ignore = []
    data_visuals(signals).each do |page, v|
      refs = (v['bindings'] || {}).values.flatten.compact.map(&:to_s)
      keys = refs.map { |r| measure_key(classes, r) }.compact.uniq
      mine = keys.select { |k| asof.key?(k) }
      next if mine.empty?
      name = mine[0].split('.', 2)[1]
      dims = refs.reject { |r| measure_key(classes, r) }
      date_dims = dims.select(&date_field)
      page_date = Array(page['visuals']).any? { |x| !x['hidden'] && control_visual?(x) && (x['bindings'] || {}).values.flatten.compact.any?(&date_field) } ||
                  filter_targets(page['filters']).any?(&date_field)
      visual_date = filter_targets(v['filters']).any?(&date_field)
      mixed = keys.any? { |k| !asof.key?(k) }
      table = mine[0].split('.', 2)[0]
      reason = if !date_dims.empty?
                 "#{name} is an as-of measure, which Power BI holds flat across the Date table (its CALCULATE filter replaces the Date filter), " \
                   "and this visual binds #{date_dims.join(', ')}; Sigma would plot one value per group; held back (class D)"
               elsif mixed && (page_date || report_date || visual_date)
                 "#{name} (as-of) ignores date filters in Power BI while the other measures of this visual respond to them; one Sigma element " \
                   "cannot do both under a date control; held back (class D)"
               elsif report_date || visual_date
                 "a report- or visual-level filter on the date table reaches #{name} (as-of) in Sigma, but Power BI ignores it for an as-of measure; held back (class D)"
               end
      if reason
        held << held_entry(page, v, table, reason)
      elsif page_date
        ignore << { 'page' => page['page_title'].to_s, 'visual' => v['title'] || v['visual_id'], 'visual_id' => v['visual_id'] }
      end
    end
    { 'held' => held, 'ignore' => ignore }
  end

  # I2: a visual that reads a grouped or rolling time-intelligence measure and binds a date-table field with no provable
  # calendar column (a Fiscal Year, a Month Name, a physical Month Start, a key), or an integer Quarter / Month Number with no
  # integer Year beside it (the element's rows are year-quarters, not quarters of any year), has no exact element: held back.
  def date_field_visuals(signals, classes, time_intel, tables, infos)
    ti = {}
    Array(time_intel).each { |r| ti[r['measure']] = r if %w[grouped rolling_sql].include?(r['form']) }
    return [] if ti.empty? || infos.nil?
    tabs = Array(tables).map { |t| t.to_s.downcase }
    out = []
    data_visuals(signals).each do |page, v|
      refs = (v['bindings'] || {}).values.flatten.compact.map(&:to_s)
      recs = refs.map { |r| ti[measure_key(classes || {}, r)] }.compact
      next if recs.empty?
      dates = refs.select { |r| tabs.include?(r.split('.', 2)[0].to_s.downcase) && !measure_key(classes || {}, r) }
      next if dates.empty?
      infs = dates.map { |r| [r, field_info(infos, *r.split('.', 2))] }
      bad = infs.find { |_r, i| i.nil? }
      if bad
        out << held_entry(page, v, dates[0].split('.', 2)[0],
                          "#{bad[0]} is not provably a calendar #{recs[0]['form'] == 'rolling_sql' ? 'day' : 'level'} of the Date column (a fiscal, key, name or unproven column), " \
                          "so the time-intelligence element's levels are not its partitions; held back (class D)")
        next
      end
      ints = infs.select { |_r, i| i['form'] == 'int' }
      next if ints.empty? || ints.any? { |_r, i| i['unit'] == 'year' }
      out << held_entry(page, v, dates[0].split('.', 2)[0],
                        "#{ints[0][0]} is a quarter or month NUMBER with no Year beside it, so Power BI groups the same period of every year while the " \
                        "time-intelligence element has one row per year-period; held back (class D)")
    end
    out
  end

  # I4 (R38): a CALCULATE filter argument sets its column, so Power BI shows the measure's value on EVERY member of that
  # column and ignores a pick on it, where Sigma's SumIf shows it on the matching member only and a control still filters
  # the rows. A visual that binds a filtered column (axis, legend, rows), or sits where a slicer, page, report or visual filter
  # picks on it, is held back. The columns are recorded in the class entry (`filter_columns`).
  def calc_override_visuals(signals, classes)
    over = {}
    (classes || {}).each { |k, c| over[k] = Array(c['filter_columns']) if c['class'] != 'D' && !Array(c['filter_columns']).empty? }
    return [] if over.empty?
    report_fields = filter_targets((signals || {})['filters']).map(&:downcase)
    out = []
    data_visuals(signals).each do |page, v|
      refs = (v['bindings'] || {}).values.flatten.compact.map(&:to_s)
      keys = refs.map { |r| measure_key(classes, r) }.compact.uniq
      mine = keys.select { |k| over.key?(k) }
      next if mine.empty?
      dims = refs.reject { |r| measure_key(classes, r) }.map(&:downcase)
      picks = (Array(page['visuals']).select { |x| !x['hidden'] && control_visual?(x) }.flat_map { |x| (x['bindings'] || {}).values.flatten.compact.map(&:to_s) } +
               filter_targets(page['filters']) + filter_targets(v['filters'])).map(&:downcase) + report_fields
      mine.each do |k|
        measure = k.split('.', 2)[1]
        hit = over[k].find { |t, c| dims.include?("#{t}.#{c}".downcase) }
        if hit
          out << held_entry(page, v, k.split('.', 2)[0],
                            "#{measure} sets #{hit[0]}[#{hit[1]}] in its CALCULATE filter, so Power BI repeats its value on every #{hit[1]} member of this visual " \
                            "while Sigma shows it on the matching member only; held back (class D)")
          break
        end
        hit = over[k].find { |t, c| picks.include?("#{t}.#{c}".downcase) }
        next unless hit
        out << held_entry(page, v, k.split('.', 2)[0],
                          "#{measure} sets #{hit[0]}[#{hit[1]}] in its CALCULATE filter, so Power BI ignores a slicer or filter on that column for it " \
                          "while Sigma applies the pick to the rows; held back (class D)")
        break
      end
    end
    out
  end

  # C2: a PAGE filter reaches a rolling-window element only through a column that element carries (an alt of the filter's
  # field on its master). A filter on a field it does not carry would leave the window unfiltered, and a filter on the date
  # table is replaced inside the window by Power BI but would be applied to the Day column here: either way the page's
  # visuals that read the rolling element are held back. Run after the carried alts are added (PbiShapeRun.direct_master_map).
  # Returns [{'page','visual','visual_id','table','reason'}].
  def rolling_filter_visuals(signals, classes, time_intel, map)
    rolling = {}
    Array(time_intel).each { |r| rolling[r['measure']] = r if r['form'] == 'rolling_sql' }
    return [] if rolling.empty?
    tabs = Array(map['date_tables']).map { |t| t.to_s.downcase }
    out = []
    data_visuals(signals).each do |page, v|
      flt = filter_targets(page['filters'])
      next if flt.empty?
      refs = (v['bindings'] || {}).values.flatten.compact.map(&:to_s)
      recs = refs.map { |r| rolling[measure_key(classes || {}, r)] }.compact.uniq
      next if recs.empty?
      reason = nil
      flt.each do |field|
        if tabs.include?(field.split('.', 2)[0].to_s.downcase)
          reason = "the page filter on #{field} is replaced by the rolling window's own dates in Power BI, and Sigma would apply it to the window's Day column"
          break
        end
        fs = (map['fields'] || {})[field]
        recs.each do |rec|
          mkey = (map['masters'] || {}).find { |_k, m| m['element_name'] == rec['element'] }&.first
          reach = fs && mkey && ([fs['master']] + Array(fs['alts']).map { |a| a['master'] }).include?(mkey)
          reason ||= "the page filter on #{field} reaches no column of #{rec['element']}, so its windows would stay unfiltered" unless reach
        end
        break if reason
      end
      out << held_entry(page, v, recs[0]['element'], "#{reason}; held back (class D)") if reason
    end
    out
  end

  # [table, [path labels]] the measures of one visual reach one table through: the active relationship and each
  # USERELATIONSHIP, or the differing related-column paths.
  def visual_paths(entries)
    userels = entries.map { |e| e['userel'] }.compact.uniq
    unless userels.empty?
      labels = []
      labels << 'the active relationship' if entries.any? { |e| e['userel'].nil? }
      labels.concat(userels)
      return [userel_target(userels[0]), labels]
    end
    paths = Hash.new { |h, k| h[k] = [] }
    entries.each { |e| Array(e['related']).each { |r| paths[r['table']] |= [Array(r['path']).join(' > ')] } }
    table, set = paths.find { |_t, ps| ps.length > 1 }
    table ? [table, set] : [nil, []]
  end

  # {master, ref, agg} reading the field on the home fact's master through the inactive relationship.
  def routed_field(masters, keys, elements, classes, uvs, field, userel)
    table, column = field.split('.', 2)
    key = uvs.flat_map { |i| i[:keys] }.find { |k| classes[k]['userel'] == userel }
    home = classes[key]['home'] || key.split('.', 2)[0]
    holder = metric_holder(elements, key.split('.', 2)[1], home) || elements.find { |e| e['name'].to_s.casecmp(home.to_s).zero? }
    return nil unless holder && keys[holder]
    master = masters[keys[holder]]
    name = "#{column} (#{userel})"
    want = "[#{holder['name']}/#{userel}/#{column}]"
    col = master['columns'].find { |c| c['formula'] == want } ||
          master['columns'].find { |c| c['name'].casecmp(name).zero? }
    return nil unless col && table
    { 'master' => keys[holder], 'ref' => "[#{master['id']}/#{col['name']}]", 'agg' => nil }
  end
end
