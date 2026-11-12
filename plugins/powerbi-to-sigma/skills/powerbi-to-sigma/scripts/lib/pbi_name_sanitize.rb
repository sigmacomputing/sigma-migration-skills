# frozen_string_literal: true

# F13 — names containing "/" cannot be referenced from a Sigma formula.
#
# Sigma addresses a column through a path ([Element/Column],
# [Element/Relationship/Column]), so a column or measure literally named
# "Growth A/B" is unreachable: [Growth A/B] reports "Dependency not
# found" (verified against the live API), and quoting does not help. Real Power
# BI models are full of such names ("YoY %/Index", "A/B Test").
#
# The fix has to happen BEFORE conversion, because the converter copies names
# straight into formulas. This module renames the "/" to U+2215 DIVISION SLASH
# (it renders the same, so display intent is kept) consistently in:
#
#   * the TMSL: column / measure names, DAX text (measures, calculated columns,
#     calculated-table partitions, calculation items, RLS filters, KPI and
#     format expressions), relationships, sortByColumn, hierarchy levels and
#     perspective members;
#   * the report signals (visual bindings, filter targets, sort refs, ... every
#     "Table.Column" string and every {entity, property} pair).
#
# Not renamed, on purpose, and RECORDED instead:
#   * `sourceColumn` and Power Query (M) partition text: those name PHYSICAL
#     warehouse columns. When a renamed column has no explicit `sourceColumn`
#     one is written (the old name) so the physical binding does not move.
#   * Table names containing "/": the converter derives warehouse paths from
#     them; they are listed in report['unsanitized_tables'].
#
# The pass is idempotent (a second run finds no "/" names). `sanitize`
# deep-copies, `sanitize!` mutates.
#
# Ruby 2.6 floor: no filter_map / tally / except.
require 'json'
require 'set'

module PbiNameSanitize
  module_function

  SLASH = "∕"

  def model_of(tmsl)
    tmsl['model'] || tmsl
  end

  # -> [new_tmsl, new_signals_or_nil, report]; inputs are not mutated.
  def sanitize(tmsl, signals = nil)
    t = JSON.parse(JSON.generate(tmsl))
    s = signals.nil? ? nil : JSON.parse(JSON.generate(signals))
    report = sanitize!(t, s)
    [t, s, report]
  end

  # Mutates tmsl (and signals when given). Returns the report.
  def sanitize!(tmsl, signals = nil)
    model = model_of(tmsl)
    tables = model['tables'] || []
    renamed = {} # table => { old => new }
    renames = []
    tables.each do |table|
      tname = table['name'].to_s
      %w[columns measures].each do |kind|
        (table[kind] || []).each do |item|
          old = item['name']
          next unless old.is_a?(String) && old.include?('/')

          new_name = old.tr('/', SLASH)
          (renamed[tname] ||= {})[old] = new_name
          renames << { 'table' => tname, 'kind' => kind == 'columns' ? 'column' : 'measure',
                       'from' => old, 'to' => new_name }
        end
      end
    end
    report = {
      'renames' => renames,
      'dax_rewrites' => 0,
      'relationship_rewrites' => 0,
      'source_columns_pinned' => [],
      'signals_rewrites' => 0,
      'unsanitized_tables' => tables.map { |t| t['name'].to_s }.select { |n| n.include?('/') }
    }
    return report if renames.empty?

    all_old = Set.new
    renamed.each_value { |h| all_old.merge(h.keys) }

    tables.each do |table|
      tname = table['name'].to_s
      map = renamed[tname] || {}
      (table['columns'] || []).each do |col|
        old = col['name']
        if map.key?(old)
          physical_backed = col['type'] != 'calculated' && !col.key?('expression')
          if physical_backed && !col.key?('sourceColumn')
            col['sourceColumn'] = old
            report['source_columns_pinned'] << "#{tname}.#{old}"
          end
          col['name'] = map[old]
        end
        sbc = col['sortByColumn']
        col['sortByColumn'] = map[sbc] if sbc.is_a?(String) && map.key?(sbc)
      end
      (table['measures'] || []).each do |m|
        m['name'] = map[m['name']] if map.key?(m['name'])
      end
      (table['hierarchies'] || []).each do |h|
        (h['levels'] || []).each do |lv|
          lv['column'] = map[lv['column']] if lv['column'].is_a?(String) && map.key?(lv['column'])
        end
      end
    end

    # DAX text everywhere except Power Query partitions (physical names).
    report['dax_rewrites'] += rewrite_dax_tree!(model, all_old)

    (model['relationships'] || []).each do |rel|
      [%w[fromTable fromColumn], %w[toTable toColumn]].each do |tk, ck|
        map = renamed[rel[tk].to_s]
        next unless map && map.key?(rel[ck])

        rel[ck] = map[rel[ck]]
        report['relationship_rewrites'] += 1
      end
    end

    (model['perspectives'] || []).each do |p|
      (p['tables'] || []).each do |pt|
        map = renamed[pt['name'].to_s]
        next unless map

        %w[columns measures].each do |k|
          (pt[k] || []).each { |m| m['name'] = map[m['name']] if map.key?(m['name']) }
        end
      end
    end

    report['signals_rewrites'] = rename_signals!(signals, renames) if signals
    report
  end

  # ---- DAX text -----------------------------------------------------------

  # Replace "/" with U+2215 inside [bracket] references whose name is in
  # `names`, leaving string literals, 'quoted table names' and comments alone.
  def rename_dax_text(text, names)
    return text unless text.is_a?(String) && text.include?('/')

    out = +''
    i = 0
    n = text.length
    while i < n
      ch = text[i]
      two = text[i, 2]
      if ch == '"' || ch == "'"
        j = i + 1
        while j < n
          if text[j] == ch
            break unless text[j + 1] == ch

            j += 2
          else
            j += 1
          end
        end
        out << text[i..j].to_s
        i = j + 1
      elsif two == '//' || two == '--'
        j = text.index("\n", i) || n
        out << text[i...j]
        i = j
      elsif two == '/*'
        j = text.index('*/', i + 2)
        j = j ? j + 2 : n
        out << text[i...j]
        i = j
      elsif ch == '['
        j = i + 1
        while j < n
          if text[j] == ']'
            break unless text[j + 1] == ']'

            j += 2
          else
            j += 1
          end
        end
        ref = text[i..j].to_s
        inner = ref[1...-1].to_s
        out << (names.include?(inner) ? "[#{inner.tr('/', SLASH)}]" : ref)
        i = j + 1
      else
        out << ch
        i += 1
      end
    end
    out
  end

  def rewrite_dax_value(value, names)
    case value
    when String
      rename_dax_text(value, names)
    when Array
      return value unless value.all? { |v| v.is_a?(String) }

      rename_dax_text(value.join("\n"), names).split("\n", -1)
    else
      value
    end
  end

  # Walk the TMSL; any key ending in "expression" holds DAX, except under a
  # partition whose source is not a calculated table (M / query text).
  def rewrite_dax_tree!(node, names)
    count = 0
    case node
    when Hash
      node.keys.each do |k|
        v = node[k]
        if k.to_s =~ /expression\z/i && (v.is_a?(String) || v.is_a?(Array))
          nv = rewrite_dax_value(v, names)
          if nv != v
            node[k] = nv
            count += 1
          end
        elsif k.to_s == 'partitions' && v.is_a?(Array)
          v.each do |part|
            src = part['source'] if part.is_a?(Hash)
            next unless src.is_a?(Hash) && src['type'].to_s == 'calculated'

            count += rewrite_dax_tree!(src, names)
          end
        elsif v.is_a?(Hash) || v.is_a?(Array)
          count += rewrite_dax_tree!(v, names)
        end
      end
    when Array
      node.each { |v| count += rewrite_dax_tree!(v, names) if v.is_a?(Hash) || v.is_a?(Array) }
    end
    count
  end

  # ---- signals ------------------------------------------------------------

  ENTITY_KEYS = %w[entity Entity table Table].freeze
  PROPERTY_KEYS = %w[property Property column Column measure Measure field Field name].freeze

  def rename_signals!(signals, renames)
    ordered = renames.sort_by { |r| -r['from'].length }
    by_table = Hash.new { |h, k| h[k] = {} }
    renames.each { |r| by_table[r['table']][r['from']] = r['to'] }
    count = [0]
    rewrite_signal_node!(signals, ordered, by_table, count)
    count[0]
  end

  def rename_signal_string(str, ordered)
    return str unless str.include?('/')

    out = str
    ordered.each do |r|
      needle = "#{r['table']}.#{r['from']}"
      out = out.gsub(needle, "#{r['table']}.#{r['to']}") if out.include?(needle)
    end
    out
  end

  def rewrite_signal_node!(node, ordered, by_table, count)
    case node
    when Hash
      entity = nil
      ENTITY_KEYS.each { |k| entity ||= node[k] if node[k].is_a?(String) }
      map = entity ? by_table[entity] : nil
      node.keys.each do |k|
        v = node[k]
        nk = k.is_a?(String) ? rename_signal_string(k, ordered) : k
        if nk != k
          node.delete(k)
          node[nk] = v
          count[0] += 1
        end
        if v.is_a?(String)
          nv = rename_signal_string(v, ordered)
          nv = map[nv] if nv == v && map && PROPERTY_KEYS.include?(nk.to_s) && map.key?(nv)
          if nv != v
            node[nk] = nv
            count[0] += 1
          end
        else
          rewrite_signal_node!(v, ordered, by_table, count)
        end
      end
    when Array
      node.each_with_index do |v, idx|
        if v.is_a?(String)
          nv = rename_signal_string(v, ordered)
          if nv != v
            node[idx] = nv
            count[0] += 1
          end
        else
          rewrite_signal_node!(v, ordered, by_table, count)
        end
      end
    end
  end
end
