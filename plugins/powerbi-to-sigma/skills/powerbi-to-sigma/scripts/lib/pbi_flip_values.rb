# frozen_string_literal: true
#
# PbiFlipValues -- Phase 6b flip values for the pbi shape (opt-in --model-shape pbi). Plugin-local, pure Ruby 2.6, no I/O
# (the warehouse lookup is a callable the orchestrator passes in).
#
# WHY (Task 21x root cause). probe-controls.rb picks a list control's flip value by exporting the control's SOURCE
# element and reading the source column out of that export. In the pbi shape a control's source is a helper (lookup)
# column of its first target chart -- a KPI, bar chart, table -- and a chart export carries only the DISPLAYED columns
# (a KPI exports its value alone), so the column is never in the export: "column X not in export of <chart> - pass
# --value", and every list control is SKIPped. The views shape sources a control on a Data-page master table, whose
# export carries every column, so it is unaffected and probe-controls.rb stays as it is (it is a shared script).
#
# FIX. Resolve each list control's column to its warehouse table and column through the shaped data model (workbook
# column -> data model element column -> Lookup / child chain -> the "(source)" base or dimension element), read a few
# distinct values from the warehouse with the probe the shape run already uses, and pass the first value that is not
# in the control's saved selection as probe-controls.rb `--value <controlId>=<value>`. A control that cannot be resolved
# (a computed column, a Custom SQL column, no warehouse result) is left to the probe and reported UNVERIFIED with the
# reason (limits.md), never silently.
require 'json'
require_relative 'pbi_shaped_model'

module PbiFlipValues
  module_function

  LIST_TYPES = %w[list segmented].freeze
  LIMIT = 50
  REF = /\A\[([^\]\/]+)\/([^\]]+)\]\z/.freeze
  # Boolean slicers target a text helper column: If(IsNull([x]), Null, If([x], "True", "False")). The wrapped column is the one
  # to list; its warehouse booleans become the wrapper's "True"/"False" text.
  BOOL_WRAP = /\AIf\(\s*IsNull\(\s*(\[[^\]]+\])\s*\)\s*,\s*Null\s*,\s*If\(\s*\1\s*,\s*"True"\s*,\s*"False"\s*\)\s*\)\z/.freeze
  LOOKUP = /\ALookup\(\s*\[([^\]\/]+)\/([^\]]+)\]/.freeze

  def doc_of(spec)
    spec.is_a?(Hash) && spec['document'].is_a?(Hash) ? spec['document'] : (spec || {})
  end

  def elements_of(spec)
    d = doc_of(spec)
    list = d['elements'].is_a?(Array) ? d['elements'] : Array(d['pages']).flat_map { |p| Array(p['elements']) }
    list.select { |e| e.is_a?(Hash) }
  end

  # [{'control_id','name','defaults','path','column'}] for each list-type control, or with 'skip' => reason when its
  # column does not resolve to a plain warehouse column.
  def targets(wb_spec, dm_spec)
    wb = elements_of(wb_spec)
    dm = elements_of(dm_spec)
    by_id = {}
    wb.each { |e| by_id[e['id']] = e }
    out = []
    wb.each do |c|
      next unless c['kind'] == 'control' && LIST_TYPES.include?(c['controlType'].to_s)
      row = { 'control_id' => c['controlId'].to_s, 'name' => c['name'].to_s,
              'defaults' => Array(c.key?('values') ? c['values'] : c['value']).compact.map(&:to_s) }
      src = c['source']
      src = src['source'].merge('columnId' => src['columnId']) if src.is_a?(Hash) && src['kind'] == 'source' && src['source'].is_a?(Hash)
      host = src.is_a?(Hash) ? by_id[src['elementId']] : nil
      col = host && Array(host['columns']).find { |x| x['id'] == src['columnId'] }
      unless col
        out << row.merge('skip' => 'the control reads no resolvable workbook column')
        next
      end
      formula = col['formula'].to_s.strip
      if (bm = formula.match(BOOL_WRAP))
        formula = bm[1]
        row['bool'] = true
      end
      m = formula.match(REF)
      unless m
        out << row.merge('skip' => "column #{col['name'].inspect} is not a plain column reference (#{col['formula'].to_s[0, 60]})")
        next
      end
      sql = sql_target(dm, m[1], m[2])
      if sql
        out << (sql.is_a?(String) ? row.merge('skip' => sql) : row.merge(sql))
        next
      end
      ctx = { 'joins' => [], 'fact' => nil }
      expr = fact_expr(dm, m[1], m[2], ctx)
      out << (expr.is_a?(String) ? row.merge('skip' => expr) : row.merge('fact' => ctx['fact'], 'expr' => expr, 'joins' => ctx['joins']))
    end
    out
  end

  # A column of a Custom SQL element (a page summary, a rolling-window summary) is listed from the statement itself:
  # {'sql' => the statement, 'sql_column' => its output column} when `el_name`.`col_name` is `[Custom SQL/<column>]` over a read-only
  # SELECT/WITH statement, a String reason for any other statement, nil when the element is not a Custom SQL one.
  def sql_target(dm, el_name, col_name)
    el = dm.find { |e| e['name'].to_s == el_name }
    return nil unless el && (el['source'] || {})['kind'] == 'sql'
    col = Array(el['columns']).find { |c| c['name'].to_s == col_name }
    name = col && col['formula'].to_s.strip[%r{\A\[Custom SQL/([^\]]+)\]\z}, 1]
    return "#{el_name}.#{col_name} is not a plain Custom SQL column" unless name
    stmt = el['source']['statement'].to_s.strip.sub(/[;\s]+\z/, '')
    return "#{el_name} has a Custom SQL statement that is not a single read-only SELECT" unless stmt =~ /\A(?:\s|--[^\n]*\n|\/\*.*?\*\/)*(?:select|with)\b/im && !stmt.include?(';')
    { 'sql' => stmt, 'sql_column' => name }
  end

  # {'path','column'} of a data model element column, or a String reason.
  def resolve(dm, el_name, col_name, depth)
    return 'column reference chain too deep' if depth > 8
    el = dm.find { |e| e['name'].to_s == el_name }
    return "no data model element #{el_name.inspect}" unless el
    col = Array(el['columns']).find { |c| c['name'].to_s == col_name }
    return "no column #{col_name.inspect} on #{el_name.inspect}" unless col
    src = el['source'] || {}
    return "#{el_name}.#{col_name} reads a Custom SQL element (no warehouse table to list values from)" if src['kind'] == 'sql' || col['formula'].to_s.include?('[Custom SQL/')
    f = col['formula'].to_s.strip
    if (m = f.match(LOOKUP))
      return resolve(dm, m[1], m[2], depth + 1)
    end
    m = f.match(REF)
    return "#{el_name}.#{col_name} is not a plain column (#{f[0, 60]})" unless m
    path = Array(src['path'])
    if src['kind'] == 'warehouse-table' && !path.empty? && path.last.to_s.casecmp(m[1]).zero?
      phys = col['id'].to_s.include?('/') ? col['id'].to_s.split('/', 2)[1] : nil
      return "#{el_name}.#{col_name} has no physical column name" if phys.nil? || phys.empty?
      return { 'path' => path, 'column' => phys }
    end
    resolve(dm, m[1], m[2], depth + 1)
  end

  FULL_LOOKUP = /\ALookup\(\s*\[([^\]\/]+)\/([^\]]+)\]\s*,\s*\[([^\]]+)\]\s*,\s*\[([^\]\/]+)\/([^\]]+)\]\s*\)\z/.freeze

  # The column as an expression over the FACT the control filters: {'fact' => path, 'expr' => node, 'joins' => [...]} or a
  # String reason. A node is [alias, physical column]; the fact is alias "f", each Lookup adds a join j<N> to the dimension on
  # the Lookup's own key columns (the relationships the data model already holds). Listing the values THROUGH the fact means
  # a member with no fact rows is never offered as a flip value.
  def fact_expr(dm, el_name, col_name, ctx, depth = 0)
    return 'column reference chain too deep' if depth > 10
    el = dm.find { |e| e['name'].to_s == el_name }
    return path_expr(dm, el, col_name, ctx, depth) if el && col_name.include?('/')
    col = el && Array(el['columns']).find { |c| c['name'].to_s == col_name }
    return "no column #{col_name.inspect} on #{el_name.inspect}" unless col
    src = el['source'] || {}
    return "#{el_name}.#{col_name} reads a Custom SQL element" if src['kind'] == 'sql' || col['formula'].to_s.include?('[Custom SQL/')
    f = col['formula'].to_s.strip
    if (m = f.match(FULL_LOOKUP))
      key = fact_expr(dm, el_name, m[3], ctx, depth + 1)
      return key if key.is_a?(String)
      val = resolve(dm, m[1], m[2], 0)
      mat = resolve(dm, m[4], m[5], 0)
      return val if val.is_a?(String)
      return mat if mat.is_a?(String)
      return "Lookup #{m[1]}.#{m[2]} / #{m[4]}.#{m[5]} spans two tables" unless val['path'] == mat['path']
      ctx['joins'] << { 'alias' => "j#{ctx['joins'].length + 1}", 'path' => val['path'], 'match' => mat['column'], 'key' => key }
      return [ctx['joins'].last['alias'], val['column']]
    end
    return "#{el_name}.#{col_name} is not a plain column (#{f[0, 60]})" if f.match(LOOKUP)
    m = f.match(REF)
    return "#{el_name}.#{col_name} is not a plain column (#{f[0, 60]})" unless m
    path = Array(src['path'])
    if src['kind'] == 'warehouse-table' && !path.empty? && path.last.to_s.casecmp(m[1]).zero?
      phys = col['id'].to_s.include?('/') ? col['id'].to_s.split('/', 2)[1] : nil
      return "#{el_name}.#{col_name} has no physical column name" if phys.nil? || phys.empty?
      ctx['fact'] ||= path
      return ctx['fact'] == path ? ['f', phys] : "#{el_name}.#{col_name} reads a second table"
    end
    fact_expr(dm, m[1], m[2], ctx, depth + 1)
  end

  def physical(column_id)
    phys = column_id.to_s.include?('/') ? column_id.to_s.split('/', 2)[1] : nil
    phys.nil? || phys.empty? ? nil : phys
  end

  # A relationship-path reference ([Sales/SKU/Product/Brand]): each segment but the last names a relationship (on the element
  # the previous hop reached); the last is a column of the final table. The first hop's key is the child's own column (resolved
  # to the fact like any other); later hops key on the previous join's alias. Joins use the relationship's own key columns.
  def path_expr(dm, el, col_name, ctx, depth)
    segs = col_name.split('/')
    final = segs.pop
    cur = el
    prev = nil
    segs.each_with_index do |rn, i|
      rel = Array(cur['relationships']).find { |r| r['name'].to_s == rn }
      return "no relationship #{rn.inspect} on #{cur['name'].inspect}" unless rel
      tgt = dm.find { |e| e['id'] == rel['targetElementId'] }
      tsrc = tgt && tgt['source'] || {}
      return "relationship #{rn.inspect} targets no warehouse table" unless tsrc['kind'] == 'warehouse-table' && !Array(tsrc['path']).empty?
      keys = Array(rel['keys'])
      return "relationship #{rn.inspect} has a composite key" unless keys.length == 1
      match = physical(keys[0]['targetColumnId'])
      return "relationship #{rn.inspect} has no physical target key" unless match
      if i.zero?
        scol = Array(cur['columns']).find { |c| c['id'] == keys[0]['sourceColumnId'] }
        return "relationship #{rn.inspect} reads no column of #{cur['name'].inspect}" unless scol
        key = fact_expr(dm, cur['name'], scol['name'], ctx, depth + 1)
        return key if key.is_a?(String)
      else
        sphys = physical(keys[0]['sourceColumnId'])
        return "relationship #{rn.inspect} has no physical source key" unless sphys
        key = [prev, sphys]
      end
      ctx['joins'] << { 'alias' => "j#{ctx['joins'].length + 1}", 'path' => tsrc['path'], 'match' => match, 'key' => key }
      prev = ctx['joins'].last['alias']
      cur = tgt
    end
    return "path #{col_name.inspect} ends on no relationship" unless prev
    col = Array(cur['columns']).find { |c| c['name'].to_s == final }
    return "no column #{final.inspect} on #{cur['name'].inspect}" unless col
    return "#{cur['name']}.#{final} is not a plain column (#{col['formula'].to_s[0, 60]})" unless col['formula'].to_s.strip.match(REF)
    phys = physical(col['id'])
    return "#{cur['name']}.#{final} has no physical column name" unless phys
    [prev, phys]
  end

  def queries(tgts, dialect)
    q = PbiShapedModel
    r = lambda { |n| q.quote_ident(n, dialect) }
    node = ->(n) { "#{n[0]}.#{r.call(n[1])}" }
    tgts.each_with_object({}) do |t, h|
      next if t['skip']
      if t['sql']
        c = r.call(t['sql_column'])
        h["flip:#{t['control_id']}"] = "SELECT #{c} AS #{r.call('V')} FROM (\n#{t['sql']}\n) t WHERE #{c} IS NOT NULL GROUP BY #{c} " \
                                       "ORDER BY COUNT(*) DESC, 1 LIMIT #{LIMIT}"
        next
      end
      joins = t['joins'].map do |j|
        "LEFT JOIN #{j['path'].map { |p| r.call(p) }.join('.')} #{j['alias']} ON #{j['alias']}.#{r.call(j['match'])} = #{node.call(j['key'])}"
      end
      expr = node.call(t['expr'])
      h["flip:#{t['control_id']}"] = "SELECT #{expr} AS #{r.call('V')} FROM #{t['fact'].map { |p| r.call(p) }.join('.')} f " \
                                     "#{joins.join(' ')}#{joins.empty? ? '' : ' '}WHERE #{expr} IS NOT NULL GROUP BY #{expr} " \
                                     "ORDER BY COUNT(*) DESC, 1 LIMIT #{LIMIT}"
    end
  end

  # [{controlId => value}, [[controlId, reason]]] from the warehouse results keyed "flip:<controlId>".
  def values(tgts, results)
    vals = {}
    skipped = []
    tgts.each do |t|
      if t['skip']
        skipped << [t['control_id'], t['skip']]
        next
      end
      r = (results || {})["flip:#{t['control_id']}"]
      if r.is_a?(Hash) && r['ok'] == false
        skipped << [t['control_id'], "the warehouse value lookup failed: #{r['error'].to_s[0, 120]}"]
        next
      end
      if r.nil?
        skipped << [t['control_id'], 'no value lookup result (no warehouse probe: pass --probe-sources with --connection and --folder)']
        next
      end
      rows = r.is_a?(Hash) ? r['rows'] : nil
      distinct = Array(rows).map { |row| row.is_a?(Hash) ? row.values.first : row }.compact.map(&:to_s).reject(&:empty?).uniq
      distinct = distinct.map { |v| bool_text(v) }.uniq if t['bool']
      pick = distinct.find { |v| !t['defaults'].include?(v) }
      if pick
        vals[t['control_id']] = pick
      else
        skipped << [t['control_id'], 'no value found in the warehouse that differs from the saved selection']
      end
    end
    [vals, skipped]
  end

  def bool_text(v)
    case v.to_s.strip.downcase
    when 'true', 't', '1' then 'True'
    when 'false', 'f', '0' then 'False'
    else v.to_s
    end
  end

  def args(vals)
    vals.flat_map { |cid, v| ['--value', "#{cid}=#{v}"] }
  end
end
