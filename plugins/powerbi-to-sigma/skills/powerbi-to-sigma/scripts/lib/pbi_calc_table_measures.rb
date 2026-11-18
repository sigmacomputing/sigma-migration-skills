# frozen_string_literal: true

# Measures homed on a DAX calculated table, carried onto that table's Sigma element.
#
# The pinned converter (converter/powerbi.mjs) builds a calculated table's element in a
# branch that `continue`s before the per-table measure loop, so every measure homed on a
# DATATABLE / GENERATESERIES / CALENDAR / literal-list / DISTINCT calculated table was
# dropped with no warning naming it. This module runs after PbiCalcTableSql.apply! (the
# element's columns are final by then):
#   1. translate - runs the converter's own exported pbiDaxToSigma on each such measure
#                  (one node call), with every model measure's DAX as context, exactly as
#                  the converter's measure loop calls it;
#   2. apply!    - attaches each translated measure as a metric on its calculated table's
#                  element, rewriting the table's column refs to the element's column names,
#                  and reports (⛔ / ⚠, naming the measure) every measure it cannot attach,
#                  so the DAX gate asks about it. Nothing is invented: a ref that is not a
#                  column or metric of that element drops the measure (and any sibling built
#                  on it), the same rule the converter applies to warehouse-table measures.
# A measure the data model already carries as a metric is left alone, so this stays a
# no-op if the converter starts emitting these measures itself.
require 'json'
require 'open3'
require 'set'
require 'fileutils'
require_relative 'ruby_compat'
require_relative 'pbi_native_query'
require_relative 'pbi_calc_table_sql'

module PbiCalcTableMeasures
  module_function

  # [{ 'table' => name, 'measure' => TMSL measure }] for every named measure on a calculated table.
  def measures(model)
    (model['tables'] || []).select { |t| PbiCalcTableSql.calculated_partition?(t) }.flat_map do |t|
      (t['measures'] || []).reject { |m| m['name'].to_s.strip.empty? }.map { |m| { 'table' => t['name'], 'measure' => m } }
    end
  end

  def dax_of(measure)
    PbiNativeQuery.expression_text(measure['expression'])
  end

  # { measure name => { 'formula' => String|nil, 'warnings' => [..], 'window' => bool, 'modifier' => bool } },
  # {} when the model has no calculated-table measures, nil when there is no converter to translate
  # with (missing module, no pbiDaxToSigma export, node failure); apply! then reports every measure.
  def translate(model, conv_module, dir)
    items = measures(model)
    return {} if items.empty?
    return nil if conv_module.to_s.empty? || !File.file?(conv_module.to_s)

    FileUtils.mkdir_p(dir)
    input = File.join(dir, 'calc-table-measures-in.json')
    output = File.join(dir, 'calc-table-measures-out.json')
    shim = File.join(dir, '_calc_table_measures.mjs')
    measure_dax = {}
    (model['tables'] || []).each { |t| (t['measures'] || []).each { |m| measure_dax[m['name']] = dax_of(m) if m['name'] } }
    File.write(input, JSON.generate({ 'measures' => items.map { |i| { 'name' => i['measure']['name'], 'dax' => dax_of(i['measure']) } },
                                      'measureDax' => measure_dax }))
    FileUtils.rm_f(output)
    File.write(shim, shim_source(File.expand_path(conv_module.to_s), input, output))
    # Runs the shim written just above (fixed source, no user input on the command line).
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    _o, _e, status = Open3.capture3('node', shim)
    return nil unless status.success? && File.exist?(output)

    out = JSON.parse(File.read(output))
    out['translator'] ? out['measures'] : nil
  rescue StandardError
    nil
  end

  # Mirrors the converter's measure loop (strip comments; CROSSFILTER / USERELATIONSHIP are
  # not attempted here; window results are rejected) but calls only exported entry points.
  def shim_source(conv_module, input, output)
    <<~JS
      import { readFileSync, writeFileSync } from 'node:fs';
      import { pathToFileURL } from 'node:url';
      const mod = await import(pathToFileURL(#{conv_module.to_json}).href);
      const input = JSON.parse(readFileSync(#{input.to_json}, 'utf8'));
      const translator = typeof mod.pbiDaxToSigma === 'function';
      const measures = {};
      if (translator) {
        for (const m of input.measures) {
          const warnings = [];
          const dax = typeof mod.stripDaxComments === 'function' ? mod.stripDaxComments(m.dax) : m.dax;
          let formula = null, windowFn = false, modifier = false;
          if (/\\b(?:CROSSFILTER|USERELATIONSHIP)\\s*\\(/i.test(dax)) {
            modifier = true;
          } else {
            formula = mod.pbiDaxToSigma(dax, warnings, m.name, input.measureDax) || null;
            if (formula && typeof mod.hasBareWindowFn === 'function' && mod.hasBareWindowFn(formula)) {
              windowFn = true;
              formula = null;
            }
          }
          measures[m.name] = { formula, warnings, window: windowFn, modifier };
        }
      }
      writeFileSync(#{output.to_json}, JSON.stringify({ translator, measures }));
    JS
  end

  # Mutates dm (converter output) and conv_warnings; returns an audit record:
  #   attached: [{ table, measure, elementId, metricId, formula }]
  #   reported: [{ table, measure, reason }] - one warning naming the measure was added for each.
  def apply!(dm, model, conv_warnings, translations)
    result = { 'attached' => [], 'reported' => [] }
    items = measures(model)
    return result if items.empty?

    all_elements = (dm['pages'] || []).flat_map { |page| page['elements'] || [] }
    present = all_elements.flat_map { |e| (e['metrics'] || []).map { |m| m['name'].to_s.downcase } }.to_set
    items = items.reject { |i| present.include?(i['measure']['name'].to_s.downcase) }
    return result if items.empty?

    taken = all_elements.flat_map do |e|
      [e['id']] + %w[columns metrics relationships].flat_map { |k| (e[k] || []).map { |x| x['id'] } }
    end.compact
    tables = PbiNativeQuery.convertible_tables(model)
    elements = PbiNativeQuery.base_elements(dm)
    report = lambda do |table, name, warning|
      conv_warnings << warning
      result['reported'] << { 'table' => table, 'measure' => name, 'reason' => warning }
    end

    items.group_by { |i| i['table'] }.each do |tname, group|
      table = tables.find { |t| t['name'] == tname }
      idx = table && tables.index(table)
      # Window helpers are appended after the table elements, so the first tables.size base
      # elements are the tables in model order (the pairing PbiCalcTableSql relies on).
      element = idx && elements.size >= tables.size ? elements[idx] : nil
      element = nil unless element && element.dig('source', 'kind') == 'sql'
      names = group.map { |i| i['measure']['name'] }
      if element.nil?
        names.each do |n|
          report.call(tname, n, "⛔ \"#{n}\": measure on calculated table \"#{tname}\" was not carried — its Sigma " \
                                'element could not be located in the converter output. Add the measure manually.')
        end
      elsif element.dig('source', 'statement').to_s.include?(PbiCalcTableSql::PLACEHOLDER)
        names.each do |n|
          report.call(tname, n, "⛔ \"#{n}\": measure on calculated table \"#{tname}\" was not carried — the table is " \
                                'still an unconverted placeholder (see the calculated-table gate). Re-author the measure ' \
                                'together with the table.')
        end
      elsif translations.nil?
        names.each do |n|
          report.call(tname, n, "⛔ \"#{n}\": measure on calculated table \"#{tname}\" was not converted — the " \
                                'converter drops calculated-table measures and no local converter (converter/powerbi.mjs) ' \
                                'was available to translate its DAX. Add the measure manually.')
        end
      else
        attach_group!(table, element, group, translations, conv_warnings, taken, result, report)
      end
    end
    result
  end

  def attach_group!(table, element, group, translations, conv_warnings, taken, result, report)
    tname = table['name']
    columns = column_names(element)
    col_map = table_column_map(table, columns)
    own_metrics = (element['metrics'] || []).map { |m| m['name'].to_s }
    sibling_names = group.map { |i| i['measure']['name'].to_s }
    candidates = {}
    group.each do |i|
      name = i['measure']['name']
      tr = translations[name]
      if tr.nil?
        report.call(tname, name, "⛔ \"#{name}\": DAX measure on calculated table \"#{tname}\" was not translated. Add manually.")
      elsif tr['modifier']
        report.call(tname, name, "⛔ \"#{name}\": measure on calculated table \"#{tname}\" uses CROSSFILTER/USERELATIONSHIP " \
                                 "— not carried. Re-author it in Sigma.")
      elsif tr['window']
        report.call(tname, name, "⛔ \"#{name}\": window-function measure has no Sigma DM-metric equivalent — use a " \
                                 'workbook Rank()/ordered table or a grouped element. Dropped.')
      elsif tr['formula'].to_s.strip.empty?
        own = Array(tr['warnings']).select { |w| w.to_s.include?("\"#{name}\"") }
        if own.empty?
          report.call(tname, name, "⛔ \"#{name}\": DAX measure on calculated table \"#{tname}\" could not be auto-converted. " \
                                   'Add manually.')
        else
          conv_warnings.concat(Array(tr['warnings']))
          result['reported'] << { 'table' => tname, 'measure' => name, 'reason' => own.first }
        end
      else
        candidates[name] = { 'measure' => i['measure'], 'formula' => tr['formula'].to_s, 'warnings' => Array(tr['warnings']) }
      end
    end

    # Rewrite refs, then drop to a fixpoint: a measure whose ref resolves nowhere is dropped,
    # and so is any sibling built on it.
    rewritten = {}
    candidates.each do |name, c|
      formula, bad = rewrite_refs(c['formula'], columns, col_map, own_metrics + candidates.keys)
      rewritten[name] = { 'formula' => formula, 'bad' => bad }
    end
    dropped = {}
    loop do
      changed = false
      rewritten.each do |name, r|
        next if dropped.key?(name)

        bad = r['bad'].first || metric_refs(r['formula'], candidates.keys).find { |ref| dropped.key?(ref) }
        next unless bad

        dropped[name] = bad
        changed = true
      end
      break unless changed
    end

    candidates.each do |name, c|
      if dropped.key?(name)
        ref = dropped[name]
        warning =
          if sibling_names.any? { |sibling| sibling.casecmp?(ref) }
            "⚠ \"#{name}\": references \"[#{ref}]\", a measure on calculated table \"#{tname}\" that was dropped — dropped too. " \
              'Re-author both in Sigma.'
          elsif table_column?(table, ref)
            "⛔ \"#{name}\": references \"[#{ref}]\", a column of calculated table \"#{tname}\" that is not on its Sigma " \
              "element — dropped. Re-author the column, then the measure."
          else
            "⚠ \"#{name}\": references \"[#{ref}]\" which is not a column or metric on this element (cross-table measure) " \
              "— dropped; recreate in a workbook element at the visual's grain. Measure is homed on calculated table \"#{tname}\"."
          end
        report.call(tname, name, warning)
        next
      end
      formula = rewritten[name]['formula']
      id = PbiCalcTableSql.unique_id("metric/#{tname}/#{name}", 10, taken)
      metric = { 'id' => id, 'formula' => formula, 'name' => name }
      desc = c['measure']['description']
      metric['description'] = PbiNativeQuery.expression_text(desc) unless desc.to_s.strip.empty?
      (element['metrics'] ||= []) << metric
      conv_warnings.concat(c['warnings'])
      conv_warnings << "ℹ \"#{name}\": measure on calculated table \"#{tname}\" → metric on its Sigma element " \
                       "(the converter drops calculated-table measures; carried by the orchestrator). Review: #{formula[0, 60]}"
      result['attached'] << { 'table' => tname, 'measure' => name, 'elementId' => element['id'], 'metricId' => id,
                              'formula' => formula }
    end
  end

  # Display name of each element column: its `name`, else the Custom SQL output it reads.
  def column_names(element)
    (element['columns'] || []).filter_map do |c|
      n = c['name'].to_s
      n = Regexp.last_match(1) if n.empty? && c['formula'].to_s =~ %r{\A\[Custom SQL/(.+)\]\z}
      n.empty? ? nil : n
    end
  end

  def norm(text)
    text.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # TMSL column name (downcased) -> the element column it became: same name, else the column
  # whose name matches the TMSL name or its sourceColumn ignoring case and punctuation (the
  # converter renames a GENERATESERIES column to its "[Value]" output). Ambiguous = unmapped.
  def table_column_map(table, columns)
    (table['columns'] || []).each_with_object({}) do |c, h|
      next if c['type'] == 'rowNumber' || c['isGenerated']

      name = c['name'].to_s
      exact = columns.find { |n| n.casecmp?(name) }
      if exact
        h[name.downcase] = exact
        next
      end
      keys = [name, PbiCalcTableSql.bare_name(c['sourceColumn'])].map { |k| norm(k) }.reject(&:empty?)
      hits = columns.select { |n| keys.include?(norm(n)) }
      h[name.downcase] = hits.first if hits.size == 1
    end
  end

  def table_column?(table, ref)
    (table['columns'] || []).any? { |c| c['name'].to_s.casecmp?(ref) }
  end

  REF = %r{\[([^\]/]+)\]}
  SLASH_REF = %r{\[([^\]]*/[^\]]*)\]}
  STRING = /"(?:[^"\\]|\\.|"")*"/

  # Applies the block to each formula segment outside double-quoted string literals.
  def outside_strings(formula)
    out = +''
    pos = 0
    formula.to_enum(:scan, STRING).each do
      m = Regexp.last_match
      out << yield(formula[pos...m.begin(0)]) << m[0]
      pos = m.end(0)
    end
    out << yield(formula[pos..].to_s)
  end

  # -> [rewritten formula, unresolved refs]. A ref resolves to the TMSL column it names (written
  # as the element's column name), an element column, or a metric name (this element's, or a
  # sibling measure being carried with it). A cross-element [A/B] ref never resolves here.
  def rewrite_refs(formula, columns, col_map, metric_names)
    bad = []
    out = outside_strings(formula) do |seg|
      seg.scan(SLASH_REF) { |(r)| bad << r }
      seg.gsub(REF) do
        ref = Regexp.last_match(1)
        col = col_map[ref.downcase] || columns.find { |n| n.casecmp?(ref) }
        met = metric_names.find { |n| n.casecmp?(ref) }
        if col
          "[#{col}]"
        elsif met
          "[#{met}]"
        else
          bad << ref
          "[#{ref}]"
        end
      end
    end
    [out, bad.uniq]
  end

  # Sibling-measure names a (rewritten) formula references.
  def metric_refs(formula, names)
    refs = []
    outside_strings(formula) do |seg|
      seg.scan(REF) { |(r)| refs << r if names.include?(r) }
      seg
    end
    refs.uniq
  end
end
