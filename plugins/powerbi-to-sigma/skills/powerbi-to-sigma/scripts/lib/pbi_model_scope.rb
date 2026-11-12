# frozen_string_literal: true
#
# PbiModelScope -- scope a Power BI TMSL model to the tables a report uses.
#
# Pure functions, no I/O. The orchestrator (migrate-powerbi.rb) calls `scope`
# with the TMSL, the report definition documents and the names of the measures
# the report binds; the result carries a pruned TMSL plus an audit trail of
# everything dropped. Design: docs/superpowers/specs/2026-11-09-powerbi-model-scoping-design.md
#
# Bias: over-include. A false positive keeps a table (harmless); a false
# negative breaks a visual or loses row-level security (a bug). Every regex
# here is deliberately loose.
require 'json'
require 'set'
require_relative 'ruby_compat'
require_relative 'pbi_master_key'

module PbiModelScope
  module_function

  DATE_TABLE_RE = /\A(?:LocalDateTable|DateTableTemplate)_/.freeze

  def date_table?(name)
    !!(name.to_s =~ DATE_TABLE_RE)
  end

  # ---- report scan -------------------------------------------------------

  # docs: Array of parsed JSON values or raw JSON strings. Returns the Set of
  # model table names the report references anywhere (including inside JSON
  # that is itself embedded in string fields, as classic report.json does).
  def report_entities(docs, table_names)
    names = table_names.to_a
    found = Set.new
    Array(docs).each { |d| walk(d, names, found, nil) }
    found & Set.new(names)
  end

  # Measure names the raw report references through
  # {"Measure": {"Expression": {...}, "Property": "<name>"}} nodes (filters,
  # sorts, conditional formatting -- places the signals bindings never list).
  def report_measures(docs, measure_names)
    mset = Set.new(measure_names.to_a)
    found = Set.new
    Array(docs).each { |d| walk(d, [], Set.new, found) }
    found & mset
  end

  # Qualified column names the raw report references through Column nodes
  # (sorts, drill fields, conditional formatting, and similar metadata).
  def report_columns(docs, table_names)
    names = table_names.to_a
    found = Set.new
    Array(docs).each { |d| walk(d, names, Set.new, nil, found) }
    found
  end

  # entities: Set collecting table names; measures / columns: Sets (or nil)
  # collecting Measure.Property names / qualified Column.Property names.
  def walk(node, names, found, measures = nil, columns = nil)
    case node
    when Hash
      node.each do |k, v|
        if k.to_s == 'Entity' && v.is_a?(String)
          found << v
        elsif k.to_s == 'Measure' && v.is_a?(Hash) && v['Property'].is_a?(String)
          measures << v['Property'] if measures
        elsif k.to_s == 'Column' && v.is_a?(Hash) && v['Property'].is_a?(String) && columns
          entity = nested_entity(v)
          columns << "#{entity}.#{v['Property']}" if names.include?(entity)
        elsif k.is_a?(String)
          field_ref(k, names, found)
        end
        walk(v, names, found, measures, columns)
      end
    when Array
      node.each { |v| walk(v, names, found, measures, columns) }
    when String
      walk_string(node, names, found, measures, columns)
    end
  end

  def nested_entity(node)
    return unless node.is_a?(Hash)
    return node['Entity'] if node['Entity'].is_a?(String)
    node.each_value do |value|
      entity = nested_entity(value)
      return entity if entity
    end
    nil
  end

  def walk_string(s, names, found, measures = nil, columns = nil)
    t = s.sub(/\A﻿/, '').lstrip
    if t.start_with?('{', '[')
      begin
        walk(JSON.parse(t), names, found, measures, columns)
        return
      rescue JSON::ParserError, EncodingError
        # Not valid JSON (truncated / hand-edited part): scrape what we can so
        # a bad part cannot silently drop a table.
        t.scan(/"Entity"\s*:\s*"([^"]+)"/) { |m| found << m[0] }
        t.scan(/"Measure"\s*:\s*\{.*?"Property"\s*:\s*"([^"]+)"/m) { |m| measures << m[0] } if measures
        if columns
          t.scan(/"Column"\s*:\s*\{.*?"Entity"\s*:\s*"([^"]+)".*?"Property"\s*:\s*"([^"]+)"/m) do |entity, property|
            columns << "#{entity}.#{property}" if names.include?(entity)
          end
        end
      end
    end
    field_ref(s, names, found)
  end

  # "Entity.Field" binding (possibly wrapped, e.g. "Sum(Entity.Field)" or
  # nested "CountNonNull(Min(Entity.Field))") -> [entity, field], or nil.
  # Splits on the FIRST '.': entity names never contain one, field names may.
  # Used only where the entity set is unknown; prefer resolve_binding.
  def binding_entity_field(ref)
    return nil unless ref.is_a?(String)
    t = ref.strip
    while (m = t.match(/\A[A-Za-z_]\w*\((.*)\)\z/m))
      t = m[1].strip
    end
    i = t.index('.')
    return nil if i.nil? || i.zero? || i == t.length - 1
    [t[0...i], t[(i + 1)..-1]]
  end

  # The ONE binding resolver: unwrap nested aggregate wrappers and match the
  # LONGEST table name followed by '.'. Returns [table, field] or nil.
  def resolve_binding(ref, table_names)
    return nil unless ref.is_a?(String)
    names = table_names.to_a
    t = ref.strip
    loop do
      best = nil
      names.each do |n|
        next unless t.start_with?("#{n}.") && t.length > n.length + 1
        best = n if best.nil? || n.length > best.length
      end
      return [best, t[(best.length + 1)..-1]] if best
      m = t.match(/\A[A-Za-z_]\w*\((.*)\)\z/m)
      return nil unless m
      t = m[1].strip
    end
  end

  # "<Table>.<Field>" and aggregate-wrapped "Sum(<Table>.<Field>)" queryRefs.
  def field_ref(s, names, found)
    return unless s.include?('.')
    r = resolve_binding(s, names)
    found << r[0] if r
  end

  # Every field reference the signals carry: visual bindings, visual / page /
  # report filter targets. Returns [[page_index or nil, ref], ...] grouped as
  # { pages: [[refs...]], ... } -- see signal_page_refs.
  def signal_page_refs(signals)
    report = Array(signals && signals['filters']).map { |f| f.is_a?(Hash) ? f['target'] : nil }.compact
    Array(signals && signals['pages']).map do |pg|
      refs = report.dup
      Array(pg['filters']).each { |f| refs << f['target'] if f.is_a?(Hash) && f['target'] }
      Array(pg['visuals']).each do |v|
        (v['bindings'] || {}).each_value { |rs| refs.concat(Array(rs)) }
        Array(v['filters']).each { |f| refs << f['target'] if f.is_a?(Hash) && f['target'] }
      end
      refs.select { |r| r.is_a?(String) }
    end
  end

  # ---- DAX scanning ------------------------------------------------------

  def expr_text(e)
    e.is_a?(Array) ? e.join("\n") : e.to_s
  end

  # Tables a DAX expression mentions: 'Quoted Name' (with '' escapes),
  # Bare[col], and bare table tokens (RELATEDTABLE(Sales), FILTER(Sales, ...)).
  # Per-names-object memo (identity keyed, so callers that reuse one names
  # collection in a loop pay the Set build / regex compile once, not per
  # expression -- this was quadratic in tables x measures: tens of seconds on a large
  # model).
  def names_memo(names)
    @names_memo ||= {}.compare_by_identity
    @names_memo[names] ||= begin
      list = names.to_a
      simple = list.select { |n| n =~ /\A[\p{L}_][\p{L}\p{N}_]*\z/ }.sort_by { |n| -n.length }
      re = simple.empty? ? nil : /(?<![\p{L}\p{N}_])(#{simple.map { |n| Regexp.escape(n) }.join('|')})(?![\p{L}\p{N}_])/
      { set: Set.new(list), bare_re: re }
    end
  end

  def dax_table_refs(expr, table_names)
    text = expr_text(expr)
    memo = names_memo(table_names)
    out = Set.new
    # Blank string literals and comments first (in order of occurrence, so
    # "http://x" is a string, not a comment) so apostrophes inside them cannot
    # open a bogus quoted name.
    clean = text.gsub(%r{"(?:[^"]|"")*"|/\*.*?\*/|//[^\n]*|--[^\n]*}m, ' ')
    clean.scan(/([\p{L}_][\p{L}\p{N}_]*)\s*\[/) { |m| out << m[0] }
    unbracketed = clean.gsub(/\[[^\]]*\]/, ' ')
    unbracketed.scan(/'((?:[^']|'')+)'/) { |m| out << m[0].gsub("''", "'") }
    bare = unbracketed.gsub(/'(?:[^']|'')+'/, ' ')
    bare.scan(memo[:bare_re]) { |m| out << m[0] } if memo[:bare_re]
    out & memo[:set]
  end

  # Measures a DAX expression mentions: any [Name] whose Name is a measure
  # (qualified Table[Name] included -- a column sharing a measure's name is a
  # tolerated false positive).
  def dax_measure_refs(expr, measure_names)
    text = expr_text(expr)
    out = Set.new
    text.scan(/\[([^\]]+)\]/) { |m| out << m[0] }
    out & names_memo(measure_names)[:set]
  end

  # Calculated columns referenced by DAX, qualified or as a same-table [Column].
  def dax_calc_column_refs(expr, columns_by_table, home)
    text = expr_text(expr)
    out = Set.new
    clean = text.gsub(%r{"(?:[^"]|"")*"|/\*.*?\*/|//[^\n]*|--[^\n]*}m, ' ')
    clean.scan(/(?:'((?:[^']|'')+)'|([\p{L}_][\p{L}\p{N}_]*))\s*\[([^\]]+)\]/) do |quoted, bare, column|
      table = quoted ? quoted.gsub("''", "'") : bare
      out << "#{table}.#{column}" if columns_by_table.fetch(table, Set.new).include?(column)
    end
    clean.scan(/(?<![\p{L}\p{N}_'\]])\[([^\]]+)\]/) do |column|
      out << "#{home}.#{column[0]}" if columns_by_table.fetch(home, Set.new).include?(column[0])
    end
    out
  end

  # ---- model views -------------------------------------------------------

  def model_of(tmsl)
    tmsl.is_a?(Hash) && tmsl['model'].is_a?(Hash) ? tmsl['model'] : tmsl
  end

  def tables_of(model)
    Array(model['tables'])
  end

  def calc_columns(table)
    Array(table['columns']).select do |c|
      c['type'].to_s == 'calculated' || (c['expression'] && c['type'].to_s != 'data')
    end
  end

  def calc_table_expr(table)
    return expr_text(table['expression']) if table['expression']
    Array(table['partitions']).map do |p|
      src = p['source'] || {}
      src['type'].to_s == 'calculated' ? expr_text(src['expression']) : nil
    end.compact.join("\n")
  end

  def calc_item_exprs(table)
    Array(table.dig('calculationGroup', 'calculationItems')).map { |i| expr_text(i['expression']) }
  end

  # measure name -> [home table, expression]
  def measure_index(model)
    idx = {}
    tables_of(model).each do |t|
      Array(t['measures']).each { |m| idx[m['name']] = [t['name'], expr_text(m['expression'])] }
    end
    idx
  end

  # Undirected adjacency over every relationship, date tables excluded.
  def adjacency(model, names, active_only = false)
    adj = Hash.new { |h, k| h[k] = Set.new }
    Array(model['relationships']).each do |r|
      next if active_only && r['isActive'] == false
      a = r['fromTable']
      b = r['toTable']
      next unless names.include?(a) && names.include?(b) && a != b
      adj[a] << b
      adj[b] << a
    end
    adj
  end

  # BFS from src; returns parent map of reachable nodes.
  def bfs(adj, src)
    parent = { src => nil }
    queue = [src]
    until queue.empty?
      cur = queue.shift
      adj[cur].each do |nx|
        next if parent.key?(nx)
        parent[nx] = cur
        queue << nx
      end
    end
    parent
  end

  # Hop distances from src over adj.
  def distances(adj, src)
    dist = { src => 0 }
    queue = [src]
    until queue.empty?
      cur = queue.shift
      adj[cur].each do |nx|
        next if dist.key?(nx)
        dist[nx] = dist[cur] + 1
        queue << nx
      end
    end
    dist
  end

  # Tables lying on ANY shortest path between a and b (endpoints excluded).
  def shortest_path_nodes(adj, a, b, da = nil, db = nil)
    da ||= distances(adj, a)
    return [] unless da.key?(b)
    db ||= distances(adj, b)
    da.keys.select { |v| v != a && v != b && db.key?(v) && da[v] + db[v] == da[b] }
  end

  # Measures reachable from `used` through measure-to-measure refs, plus the
  # measures referenced by calculated columns/tables on the kept tables.
  def used_measure_closure(model, used, kept)
    idx = measure_index(model)
    mnames = idx.keys
    set = Set.new(Array(used).select { |m| idx.key?(m) })
    tables_of(model).each do |t|
      next unless kept.include?(t['name'])
      texts = calc_columns(t).map { |c| expr_text(c['expression']) }
      texts << calc_table_expr(t)
      texts.concat(calc_item_exprs(t))
      texts.each { |x| set.merge(dax_measure_refs(x, mnames)) }
    end
    queue = set.to_a
    until queue.empty?
      m = queue.shift
      dax_measure_refs(idx[m][1], mnames).each { |r| queue << r if set.add?(r) }
    end
    set
  end

  # ---- keep set ----------------------------------------------------------

  # model: the TMSL `model` hash. seeds: table names the report uses.
  # used_measures: measure names the report binds. Returns table => [reason tags].
  def keep_set(model, seeds, used_measures = [])
    all = tables_of(model).map { |t| t['name'] }.reject { |n| date_table?(n) }
    names = Set.new(all)
    by_name = {}
    tables_of(model).each { |t| by_name[t['name']] = t }
    idx = measure_index(model)
    mnames = idx.keys
    keep = {}
    all.each { |n| keep[n] = ['report'] if Set.new(seeds.to_a).include?(n) }
    adj = adjacency(model, names)
    active_adj = adjacency(model, names, true)

    add = lambda do |tbl, reason|
      next false unless names.include?(tbl) && !keep.key?(tbl)
      keep[tbl] = [reason]
      true
    end

    loop do
      changed = false

      # measures: home table + every table the DAX touches
      used = used_measure_closure(model, used_measures, keep.keys)
      used.each do |m|
        home, expr = idx[m]
        changed |= add.call(home, "measure:#{m}")
        dax_table_refs(expr, names).each { |t| changed |= add.call(t, "measure:#{m}") }
      end

      # calculated columns / calculated tables on kept tables
      keep.keys.each do |tn|
        t = by_name[tn]
        calc_columns(t).each do |c|
          dax_table_refs(c['expression'], names).each do |r|
            changed |= add.call(r, "calc:#{tn}.#{c['name']}")
          end
        end
        dax_table_refs(calc_table_expr(t), names).each { |r| changed |= add.call(r, "calc-table:#{tn}") }
        calc_item_exprs(t).each do |x|
          dax_table_refs(x, names).each { |r| changed |= add.call(r, "calc-group:#{tn}") }
        end
      end

      # row-level security: filters on tables connected to the keep set, and
      # the tables those filters reference
      comp = Set.new
      keep.keys.each { |k| comp.merge(bfs(adj, k).keys) }
      Array(model['roles']).each do |role|
        Array(role['tablePermissions']).each do |tp|
          tn = tp['name']
          next unless names.include?(tn)
          has_rule = tp['filterExpression'] || !Array(tp['columnPermissions']).empty?
          next unless has_rule
          next unless keep.key?(tn) || comp.include?(tn)
          changed |= add.call(tn, "rls:#{role['name']}")
          dax_table_refs(tp['filterExpression'], names).each do |r|
            changed |= add.call(r, "rls:#{role['name']}")
          end
        end
      end

      # join paths between every pair of kept tables: every table on ANY
      # shortest path over ACTIVE relationships, then (over-include) every
      # table on any shortest path over ALL relationships.
      kept_now = keep.keys
      [active_adj, adj].each do |g|
        dists = {}
        kept_now.each { |k| dists[k] = distances(g, k) }
        kept_now.each do |a|
          kept_now.each do |b|
            next if a >= b || !dists[a].key?(b)
            shortest_path_nodes(g, a, b, dists[a], dists[b]).each { |n| changed |= add.call(n, 'join-path') }
          end
        end
      end

      break unless changed
    end
    keep
  end

  # ---- pruning -----------------------------------------------------------

  def deep_copy(obj)
    JSON.parse(JSON.generate(obj))
  end

  # tmsl: {'model'=>{...}} or a bare model hash. keep: table => reasons (or any
  # Hash/Set/Array of kept names). used_measures / used_columns: report-bound
  # field names (columns are qualified as "Table.Column").
  def prune_model(tmsl, keep, used_measures = [], used_columns = [])
    out = deep_copy(tmsl)
    model = model_of(out)
    kept = Set.new(keep.is_a?(Hash) ? keep.keys : keep.to_a)
    all = tables_of(model).map { |t| t['name'] }
    dropped_tables = all.reject { |n| kept.include?(n) }
    dropped_set = Set.new(dropped_tables)

    used = used_measure_closure(model, used_measures, kept)
    # home table of every measure in the ORIGINAL model (dropped tables too)
    orig_home = {}
    tables_of(model).each { |t| Array(t['measures']).each { |m| orig_home[m['name']] = t['name'] } }

    model['tables'] = tables_of(model).select { |t| kept.include?(t['name']) }
    if model['relationships']
      model['relationships'] = model['relationships'].reject do |r|
        dropped_set.include?(r['fromTable']) || dropped_set.include?(r['toTable'])
      end
    end
    Array(model['roles']).each do |role|
      next unless role['tablePermissions']
      role['tablePermissions'] = role['tablePermissions'].reject { |tp| dropped_set.include?(tp['name']) }
    end
    Array(model['perspectives']).each do |p|
      next unless p['tables']
      p['tables'] = p['tables'].reject { |t| dropped_set.include?(t['name']) }
    end

    all_mnames = orig_home.keys
    calc_by_table = {}
    calc_idx = {}
    tables_of(model).each do |t|
      calc_by_table[t['name']] = Set.new(calc_columns(t).map { |c| c['name'] })
      calc_columns(t).each { |c| calc_idx["#{t['name']}.#{c['name']}"] = [t['name'], expr_text(c['expression'])] }
    end
    dropped_m = Set.new
    dropped_c = Set.new
    used_c = Set.new(used_columns)
    tables_of(model).each do |t|
      Array(t['columns']).each do |c|
        used_c << "#{t['name']}.#{c['sortByColumn']}" if c['sortByColumn']
      end
    end
    midx = measure_index(model)
    used.each do |name|
      home, expr = midx[name]
      used_c.merge(dax_calc_column_refs(expr, calc_by_table, home))
    end
    queue = used_c.to_a
    until queue.empty?
      home, expr = calc_idx[queue.shift]
      next unless expr
      dax_calc_column_refs(expr, calc_by_table, home).each { |ref| queue << ref if used_c.add?(ref) }
    end
    live_names = Set.new(all)

    loop do
      changed = false
      tables_of(model).each do |t|
        tn = t['name']
        Array(t['measures']).dup.each do |m|
          next if used.include?(m['name']) || dropped_m.include?("#{tn}.#{m['name']}")
          expr = expr_text(m['expression'])
          bad = !(dax_table_refs(expr, live_names) & dropped_set).empty?
          unless bad
            dax_measure_refs(expr, all_mnames).each do |r|
              home = orig_home[r]
              if dropped_set.include?(home) || dropped_m.include?("#{home}.#{r}")
                bad = true
                break
              end
            end
          end
          bad ||= !(dax_calc_column_refs(expr, calc_by_table, tn) & dropped_c).empty?
          next unless bad
          dropped_m << "#{tn}.#{m['name']}"
          changed = true
        end
        calc_columns(t).each do |c|
          key = "#{tn}.#{c['name']}"
          next if used_c.include?(key) || dropped_c.include?(key)
          expr = expr_text(c['expression'])
          bad = !(dax_table_refs(expr, live_names) & dropped_set).empty?
          unless bad
            bad = dax_measure_refs(expr, all_mnames).any? do |r|
              home = orig_home[r]
              dropped_set.include?(home) || dropped_m.include?("#{home}.#{r}")
            end
          end
          bad ||= !(dax_calc_column_refs(expr, calc_by_table, tn) & dropped_c).empty?
          if bad
            dropped_c << key
            changed = true
          end
        end
      end
      break unless changed
    end

    tables_of(model).each do |t|
      t['measures'] = Array(t['measures']).reject { |m| dropped_m.include?("#{t['name']}.#{m['name']}") } if t['measures']
      t['columns'] = Array(t['columns']).reject { |c| dropped_c.include?("#{t['name']}.#{c['name']}") } if t['columns']
    end

    { 'tmsl' => out,
      'dropped_tables' => dropped_tables.reject { |n| date_table?(n) },
      'dropped_measures' => dropped_m.to_a,
      'dropped_calc_columns' => dropped_c.to_a }
  end

  # ---- orchestrator entry ------------------------------------------------

  # extra_seeds: table names known from elsewhere (e.g. the signals bindings).
  def scope(tmsl, docs, used_measure_names = [], extra_seeds = [], used_column_names = [])
    model = model_of(tmsl)
    names = tables_of(model).map { |t| t['name'] }.reject { |n| date_table?(n) }
    seeds = report_entities(docs, names) | (Set.new(extra_seeds.to_a) & Set.new(names))
    if seeds.empty?
      return { 'enabled' => true, 'fallback_reason' => 'no report entities found',
               'kept' => names.map { |n| { 'table' => n, 'reasons' => ['full-model'] } },
               'tmsl' => tmsl, 'dropped_tables' => [], 'dropped_measures' => [],
               'dropped_calc_columns' => [] }
    end
    keep = keep_set(model, seeds, used_measure_names)
    pruned = prune_model(tmsl, keep, used_measure_names, used_column_names)
    ordered = names.select { |n| keep.key?(n) }
    pruned.merge('enabled' => true, 'fallback_reason' => nil,
                 'kept' => ordered.map { |n| { 'table' => n, 'reasons' => keep[n] } })
  end

  # ---- converter View filter ---------------------------------------------

  # Tables a measure needs: its home plus every table its DAX references,
  # transitively through measure-to-measure refs.
  def measure_tables(mname, idx, names)
    mnames = idx.keys
    seen = Set.new([mname])
    queue = [mname]
    out = Set.new
    until queue.empty?
      m = queue.shift
      home, expr = idx[m]
      out << home
      out.merge(dax_table_refs(expr, names))
      dax_measure_refs(expr, mnames).each { |r| queue << r if seen.add?(r) }
    end
    out
  end

  # Drop the converter's "<X> View" elements that nothing needs. dm_model:
  # the converter's data-model hash (pages[].elements[]); signals: the report
  # signals (pages[].visuals[].bindings + filters); model: TMSL model hash.
  # Mutates dm_model; returns the dropped View names. Over-include: a View that
  # cannot be mapped to a TMSL table is kept.
  #
  # Rule (a) is PER PAGE: the builder picks one base master per page across all
  # the page's visuals (slicers included), so the page's entity set is the union
  # of every bound entity plus page / report / visual filter targets (a measure
  # contributes its home table and every table its DAX touches).
  def filter_views!(dm_model, signals, model)
    model = model_of(model)
    tables = tables_of(model)
    names = Set.new(tables.map { |t| t['name'] })
    idx = measure_index(model)
    # A View carries columns only from tables reachable along fromTable ->
    # toTable (many -> one), so reach is directed, not undirected.
    adj = Hash.new { |h, k| h[k] = Set.new }
    Array(model['relationships']).each do |r|
      next unless names.include?(r['fromTable']) && names.include?(r['toTable'])
      adj[r['fromTable']] << r['toTable']
    end
    norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }

    # normalized name (friendly or physical tail) -> [friendly table names]
    by_norm = Hash.new { |h, k| h[k] = [] }
    tables.each do |t|
      by_norm[norm.call(t['name'])] << t['name']
      tail = PbiMasterKey.physical_tail(t)
      by_norm[norm.call(tail)] << t['name'] if tail
    end

    measures_only = Set.new(tables.select { |t| !Array(t['measures']).empty? && Array(t['columns']).empty? }.map { |t| t['name'] })

    page_sets = []
    unresolved = false
    signal_page_refs(signals).each do |refs|
      set = Set.new
      refs.each do |r|
        res = resolve_binding(r, names)
        if res.nil?
          entity_field = binding_entity_field(r)
          unresolved = true unless entity_field && date_table?(entity_field[0])
          next
        end
        ent, field = res
        if idx.key?(field) && idx[field][0] == ent
          set.merge(measure_tables(field, idx, names))
        else
          set << ent
        end
      end
      page_sets << set
    end

    # Over-include: a bound entity we cannot map to a table means we cannot
    # prove any View unneeded.
    return [] if unresolved

    # tables the DAX of EVERY measure on a measures-only table touches
    mo_dax = {}
    measures_only.each do |t|
      acc = Set.new
      Array(tables.find { |x| x['name'] == t }['measures']).each { |m| acc.merge(measure_tables(m['name'], idx, names)) }
      mo_dax[t] = acc
    end

    elements = Array(dm_model['pages']).flat_map { |p| Array(p['elements']) }
    dropped = []
    elements.select { |e| e['name'].to_s.end_with?(' View') }.each do |view|
      next if view_needed?(view, elements, by_norm, adj, page_sets, norm, mo_dax)
      dropped << view['name']
    end
    Array(dm_model['pages']).each do |p|
      next unless p['elements']
      p['elements'] = p['elements'].reject { |e| dropped.include?(e['name']) && e['name'].to_s.end_with?(' View') }
    end
    dropped
  end

  def view_needed?(view, elements, by_norm, adj, page_sets, norm, mo_dax = {})
    base = view['name'].to_s.sub(/ View\z/, '')
    # (c) metrics, calculated columns, or anything beyond the unnamed base
    # pass-throughs and hidden relationship copies generated for every View
    return true unless Array(view['metrics']).empty?
    pass = /\A\[#{Regexp.escape(base)}\/[^\]\/]+(?:\/[^\]\/]+)?\]\z/
    return true if Array(view['columns']).any? do |c|
      c['formula'] && (c['formula'] !~ pass || (c['name'] && c['hidden'] != true))
    end
    # (b) sourced by another element
    vid = view['id']
    if vid
      needle = "\"#{vid}\""
      return true if elements.any? { |e| !e.equal?(view) && JSON.generate(e).include?(needle) }
    end
    # (a) some page touches two or more tables covered by this View
    matched = by_norm[norm.call(base)].uniq
    return true if matched.empty?
    matched.any? do |x|
      reach = bfs(adj, x).keys - [x]
      page_sets.any? do |set|
        (set & Set.new([x] + reach)).size >= 2 ||
          set.any? { |t| mo_dax[t] && mo_dax[t].include?(x) && reach.any? { |r| set.include?(r) } }
      end
    end
  end

  # ---- Data-page master pruning -----------------------------------------

  # Ids of `master-` data elements no content element (nor any non-master data
  # element, e.g. helpers) reaches. Reach edges: source.elementId,
  # source.source.elementId, source.joins[*].{left,right}.elementId, control
  # filters[*].source(.source).elementId, and column formulas naming a master
  # by id or by its short name (`[master-x/Col]` / `[NAME/Col]`).
  def prune_masters(data_elements, content_elements)
    masters = {}
    Array(data_elements).each { |e| masters[e['id']] = e if e['id'].to_s.start_with?('master-') }
    return [] if masters.empty?
    by_name = {}
    masters.each { |id, e| (by_name[e['name']] ||= []) << id if e['name'] }
    reached = Set.new
    queue = Array(content_elements).dup
    Array(data_elements).each { |e| queue << e unless masters.key?(e['id']) }
    until queue.empty?
      el = queue.shift
      master_refs(el, masters.keys, by_name).each do |mid|
        next unless reached.add?(mid)
        queue << masters[mid]
      end
    end
    masters.keys.reject { |id| reached.include?(id) }
  end

  def master_refs(el, master_ids, by_name)
    out = Set.new
    collect_element_ids(el['source'], out)
    Array(el['filters']).each { |f| collect_element_ids(f.is_a?(Hash) ? f['source'] : nil, out) }
    Array(el['columns']).each do |c|
      next unless c.is_a?(Hash) && c['formula'].is_a?(String)
      f = c['formula']
      master_ids.each { |id| out << id if f.include?("[#{id}/") }
      by_name.each { |nm, ids| ids.each { |id| out << id } if f.include?("[#{nm}/") }
    end
    out.select { |id| master_ids.include?(id) }
  end

  # Phase 2.9 guard: an auto-picked reuse candidate may be at most 2 elements
  # larger than THIS run's converted element count (baseline, after View filtering), so a stale full-model DM is not adopted.
  def auto_pick_allowed?(candidate, baseline_count)
    n = candidate.is_a?(Hash) ? candidate['raw_element_count'] : nil
    return true if n.nil?
    n.to_i <= baseline_count.to_i + 2
  end

  def collect_element_ids(src, out)
    return unless src.is_a?(Hash)
    out << src['elementId'] if src['elementId']
    collect_element_ids(src['source'], out)
    Array(src['joins']).each do |j|
      next unless j.is_a?(Hash)
      %w[left right].each { |side| collect_element_ids(j[side], out) }
    end
  end

end
