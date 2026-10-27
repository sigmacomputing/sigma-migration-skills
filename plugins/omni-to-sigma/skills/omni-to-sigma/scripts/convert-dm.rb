#!/usr/bin/env ruby
# frozen_string_literal: true
# Topic-scoped Omni YAML → Sigma data-model spec (v0).
#
#   ruby scripts/convert-dm.rb --model-dir <dir> --topic <name> --out dm.json
#
# Plain views + relationships only. Query views, omni_dimensionalize, and
# Mustache attribute SQL are skipped with warnings (not guessed).
#
# Creds-free. Writes an envelope {sigmaDataModel, stats, warnings} plus an
# optional reuse signature for scripts/find-or-pick-dm.rb.

require 'json'
require 'optparse'
require_relative 'lib/omni_model'
require_relative 'lib/omni_formula'

def col_id(view, field)
  "col-#{view}-#{field}"
end

def metric_hash(view, field, label, formula, spec)
  metric = { 'id' => "met-#{view}-#{field}", 'name' => label, 'formula' => formula }
  fmt = OmniFormula.sigma_format(spec['format'])
  metric['format'] = fmt if fmt
  metric
end

def parse_on_sql_keys(sql)
  text = sql.to_s.strip
  return nil if text.empty?
  clauses = text.split(/\s+AND\s+/i)
  return nil if clauses.empty?
  pairs = clauses.map do |clause|
    m = clause.strip.match(/\A\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\}\s*=\s*\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\}\z/)
    return nil unless m
    { 'left_view' => m[1], 'left_field' => m[2], 'right_view' => m[3], 'right_field' => m[4] }
  end
  pairs
end

def rel_type(raw, inverted: false)
  t = raw.to_s
  if inverted
    t = case t
        when 'many_to_one', 'assumed_many_to_one', '' then 'one_to_many'
        when 'one_to_many' then 'many_to_one'
        else t
        end
  end
  case t
  when 'one_to_one' then '1:1'
  when 'one_to_many' then '1:N'
  when 'many_to_many' then 'N:N'
  else 'N:1' # many_to_one, assumed_many_to_one, default
  end
end

def build(model, topic_name, connection_id, folder_id)
  warnings = []
  topic = OmniModel.find_topic(model, topic_name)
  abort "topic not found: #{topic_name}" unless topic
  base_name = topic['base_view'].to_s
  abort "topic #{topic['_key']} has no base_view" if base_name.empty?
  base = model['views'][base_name]
  abort "base view #{base_name} not in model" unless base

  model['query_views'].each do |rel|
    warnings << "query view #{rel} skipped — query views are not converted in v0"
  end
  if topic['access_filters'] || (model['model'].is_a?(Hash) && model['model']['default_topic_access_filters'])
    warnings << "access_filters on topic #{topic['_key']} — run detect-rls.rb; not applied on the DM"
  end
  if connection_id == '<CONNECTION_ID>'
    warnings << 'connection id placeholder <CONNECTION_ID> — pass --connection-id before POST'
  end

  scope = [base_name] + OmniModel.joined_views(topic)
  scope.uniq!
  missing = scope.reject { |n| model['views'][n] }
  missing.each { |n| warnings << "joined view #{n} missing from model — skipped" }
  scope -= missing

  displays = {} # [view, field] => display name
  dim_meta = {} # [view, field] => spec
  elements = {}

  # Pre-register display names across all scoped views so cross-view or
  # out-of-order dimension formulas resolve deterministically.
  scope.each do |view_name|
    view = model['views'][view_name]
    next if view['table_name'].to_s.empty? && view['sql_table_name'].to_s.empty?
    (view['dimensions'] || {}).each do |field, spec|
      spec = {} unless spec.is_a?(Hash)
      next if spec['ignored']
      label = OmniFormula.display_name(field, spec['label'])
      displays[[view_name, field.to_s]] = label
      dim_meta[[view_name, field.to_s]] = spec
      Array(spec['aliases']).each do |al|
        displays[[view_name, al.to_s]] ||= label
      end
    end
  end

  scope.each do |view_name|
    view = model['views'][view_name]
    schema = view['schema'].to_s
    table = (view['table_name'] || view['sql_table_name']).to_s
    if table.empty?
      warnings << "view #{view_name} has no table_name — skipped"
      next
    end
    el_name = table.upcase
    columns = []
    dim_specs = []
    (view['dimensions'] || {}).each do |field, spec|
      spec = {} unless spec.is_a?(Hash)
      next if spec['ignored']
      label = displays[[view_name, field.to_s]]
      dim_specs << [field.to_s, spec, label]
    end
    resolve_ref = lambda do |v, f|
      rv, rf = OmniModel.resolve_alias(model, v, f)
      d = displays[[rv, rf]] || displays[[v, f]]
      d ? "[#{d}]" : nil
    end
    dim_specs.each do |field, spec, label|
      sql = (spec['sql'] || spec['expr']).to_s
      reason = OmniFormula.untranslatable?(sql)
      if reason
        warnings << "#{view_name}.#{field} skipped — #{reason}"
        displays.delete([view_name, field])
        next
      end
      if spec['groups'].is_a?(Array) && !spec['groups'].empty?
        target_col = if OmniFormula.warehouse_sql?(sql, field)
                       "[#{el_name}/#{label}]"
                     else
                       t_expr, t_err = OmniFormula.translate_expr(sql, resolve_ref, default_view: view_name)
                       if t_err
                         warnings << "#{view_name}.#{field} skipped — #{t_err}"
                         displays.delete([view_name, field])
                         next
                       end
                       t_expr
                     end
        formula = OmniFormula.groups_formula(spec, target_col)
        unless formula
          warnings << "#{view_name}.#{field} skipped — invalid groups specification"
          displays.delete([view_name, field])
          next
        end
      elsif spec['bin_boundaries'].is_a?(Array) && !spec['bin_boundaries'].empty?
        target_col = if OmniFormula.warehouse_sql?(sql, field)
                       "[#{el_name}/#{label}]"
                     else
                       t_expr, t_err = OmniFormula.translate_expr(sql, resolve_ref, default_view: view_name)
                       if t_err
                         warnings << "#{view_name}.#{field} skipped — #{t_err}"
                         displays.delete([view_name, field])
                         next
                       end
                       t_expr
                     end
        formula = OmniFormula.bins_formula(spec, target_col)
        unless formula
          warnings << "#{view_name}.#{field} skipped — invalid bin_boundaries specification"
          displays.delete([view_name, field])
          next
        end
      elsif OmniFormula.warehouse_sql?(sql, field)
        formula = "[#{el_name}/#{label}]"
      else
        formula, err = OmniFormula.translate_expr(sql, resolve_ref, default_view: view_name)
        if err
          warnings << "#{view_name}.#{field} skipped — #{err}"
          displays.delete([view_name, field])
          next
        end
      end
      columns << { 'id' => col_id(view_name, field), 'name' => label, 'formula' => formula }
    end
    elements[view_name] = {
      'id' => "el-#{view_name}",
      'kind' => 'table',
      'name' => el_name,
      'source' => {
        'kind' => 'warehouse-table',
        'connectionId' => connection_id,
        'path' => schema.empty? ? [table] : [schema, table]
      },
      'columns' => columns
    }
  end

  # Measures on the base view (topic grain).
  metrics = []
  metric_fields = {} # metric['id'] => [view_name, field_name, spec]
  base_view = model['views'][base_name]
  local_display = lambda do |field|
    return nil if field.nil?
    f_str = field.to_s
    if f_str.include?('.')
      vp, fp = f_str.split('.', 2)
      rv, rf = OmniModel.resolve_alias(model, vp, fp)
      displays[[rv, rf]] || displays[[vp, fp]]
    else
      rv, rf = OmniModel.resolve_alias(model, base_name, f_str)
      displays[[rv, rf]] || displays[[base_name, f_str]]
    end
  end
  measure_formulas = {}
  pending_ratios = []
  (base_view['measures'] || {}).each do |field, spec|
    spec = {} unless spec.is_a?(Hash)
    next if spec['ignored']
    label = OmniFormula.display_name(field, spec['label'])
    formula, err = OmniFormula.aggregate_formula(spec, base_name, local_display)
    if formula.nil? && err == 'measure has no aggregate_type'
      pending_ratios << [field.to_s, spec, label]
      next
    end
    if formula.nil?
      warnings << "#{base_name}.#{field} skipped — #{err}"
      next
    end
    measure_formulas[field.to_s] = formula
    m = metric_hash(base_name, field, label, formula, spec)
    metrics << m
    metric_fields[m['id']] = [base_name, field.to_s, spec]
  end

  # Multi-pass resolution for derived/ratio measures that depend on other measures.
  3.times do
    break if pending_ratios.empty?
    still_pending = []
    progressed = false
    pending_ratios.each do |field, spec, label|
      raw_sql = (spec['sql'] || spec['display_sql'] || spec['expr']).to_s
      formula, err = expand_ratio(raw_sql, base_name, measure_formulas, displays, model)
      if formula.nil?
        still_pending << [field, spec, label, err]
      else
        measure_formulas[field] = formula
        m = metric_hash(base_name, field, label, formula, spec)
        metrics << m
        metric_fields[m['id']] = [base_name, field, spec]
        progressed = true
      end
    end
    if !progressed
      still_pending.each do |field, _spec, _label, err|
        warnings << "#{base_name}.#{field} skipped — #{err}"
      end
      break
    end
    pending_ratios = still_pending.map { |f, s, l, _| [f, s, l] }
  end

  base_el = elements[base_name]
  abort "base view #{base_name} produced no element" unless base_el

  rels_by_source = Hash.new { |h, k| h[k] = [] }
  all_rels = []
  Array(model['relationships']).each do |rel|
    next unless rel.is_a?(Hash)
    from = rel['join_from_view'].to_s
    to = rel['join_to_view'].to_s
    next unless scope.include?(from) && scope.include?(to)
    next unless elements[from] && elements[to]
    inverted = false
    if to == base_name && from != base_name && rel['reversible'] != false
      from, to = to, from
      inverted = true
    end
    parsed_keys = parse_on_sql_keys(rel['on_sql'])
    unless parsed_keys
      warnings << "relationship #{from} → #{to} skipped — on_sql is not a single equality"
      next
    end
    sigma_keys = []
    missing_key = false
    parsed_keys.each do |pk|
      src_field = pk['left_view'] == from ? pk['left_field'] : pk['right_field']
      tgt_field = pk['left_view'] == to ? pk['left_field'] : pk['right_field']
      unless displays[[from, src_field]] && displays[[to, tgt_field]]
        missing_key = true
        break
      end
      sigma_keys << {
        'sourceColumnId' => col_id(from, src_field),
        'targetColumnId' => col_id(to, tgt_field)
      }
    end
    if missing_key
      warnings << "relationship #{from} → #{to} skipped — join keys are not converted columns"
      next
    end
    rel_obj = {
      'id' => "rel-#{from}-#{to}",
      'name' => (inverted ? to : (rel['join_to_view_as'] || to)).to_s,
      'targetElementId' => elements[to]['id'],
      'relationshipType' => rel_type(rel['relationship_type'], inverted: inverted),
      'keys' => sigma_keys
    }
    rels_by_source[from] << rel_obj
    all_rels << [from, to, rel_obj]
    if rel['reversible'] == false
      warnings << "relationship #{from} → #{to} is not reversible — Sigma relationship is one-directional"
    end
  end
  rels_by_source.each do |src_view, rel_list|
    elements[src_view]['relationships'] = rel_list unless rel_list.empty?
  end

  curation_active = topic['fields'].is_a?(Array) && !topic['fields'].empty?
  explore_cols = []
  base_el['columns'].each do |col|
    field_key = col['id'].sub(/\Acol-#{Regexp.escape(base_name)}-/, '')
    spec = dim_meta[[base_name, field_key]] || {}
    next if curation_active && !OmniModel.field_allowed?(topic, base_name, field_key, spec['tags'])
    explore_cols << {
      'id' => "ex-#{col['id']}",
      'name' => col['name'],
      'formula' => "[#{base_el['name']}/#{col['name']}]"
    }
  end
  all_rels.each do |_from, to_view, rel|
    target = elements[to_view]
    next unless target
    target['columns'].each do |col|
      field_key = col['id'].sub(/\Acol-#{Regexp.escape(to_view)}-/, '')
      spec = dim_meta[[to_view, field_key]] || {}
      next if curation_active && !OmniModel.field_allowed?(topic, to_view, field_key, spec['tags'])
      explore_cols << {
        'id' => "ex-#{rel['name']}-#{col['id']}",
        'name' => col['name'],
        'formula' => "[#{base_el['name']}/#{rel['name']}/#{col['name']}]"
      }
    end
  end
  explore_metrics = []
  metrics.each do |m|
    v_name, f_key, m_spec = metric_fields[m['id']] || [base_name, '', {}]
    next if curation_active && !OmniModel.field_allowed?(topic, v_name, f_key, m_spec['tags'])
    copy = { 'id' => "ex-#{m['id']}", 'name' => m['name'], 'formula' => m['formula'] }
    copy['format'] = m['format'] if m['format']
    explore_metrics << copy
  end
  if curation_active
    warnings << "topic #{topic['_key']} fields: curation applied to topic explore element (#{explore_cols.length} columns, #{explore_metrics.length} metrics)"
  end
  topic_label = topic['label'].to_s.empty? ? base_name : topic['label'].to_s
  explore = {
    'id' => "el-topic-#{topic['_key']}",
    'kind' => 'table',
    'name' => topic_label,
    'source' => { 'kind' => 'table', 'elementId' => base_el['id'] },
    'columns' => explore_cols,
    'metrics' => explore_metrics
  }

  ordered = scope.map { |n| elements[n] }.compact
  spec = {
    'name' => "#{topic_label} (Omni)",
    'schemaVersion' => 1,
    'pages' => [{
      'id' => 'page-data',
      'name' => 'Data',
      'elements' => ordered + [explore]
    }]
  }
  spec['folderId'] = folder_id if folder_id && !folder_id.empty?

  stats = {
    'views' => ordered.length,
    'topics' => 1,
    'elements' => ordered.length + 1,
    'columns' => (ordered + [explore]).sum { |el| (el['columns'] || []).length },
    'metrics' => (ordered + [explore]).sum { |el| (el['metrics'] || []).length },
    'relationships' => all_rels.length,
    'query_views_skipped' => model['query_views'].length
  }
  signature = {
    'tableau_workbook' => topic_label,
    'warehouse_tables' => ordered.map { |el| el['source']['path'].join('.') },
    'referenced_columns' => ordered.flat_map { |el| el['columns'].map { |c| c['name'] } }.uniq,
    'measures' => explore_metrics.map { |m| m['name'] }
  }
  [{ 'sigmaDataModel' => spec, 'stats' => stats, 'warnings' => warnings }, signature, explore]
end

def expand_ratio(sql, view_name, measure_formulas, displays, model = nil)
  reason = OmniFormula.untranslatable?(sql)
  return [nil, reason] if reason
  return [nil, 'empty ratio sql'] if sql.strip.empty?
  out = OmniFormula.strip_sql_casts(sql.dup)
  out.gsub!(/\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\}/) do
    v, f = $1, $2
    rv, rf = model ? OmniModel.resolve_alias(model, v, f) : [v, f]
    if (rv == view_name || v == view_name) && (measure_formulas[rf] || measure_formulas[f])
      "(#{measure_formulas[rf] || measure_formulas[f]})"
    elsif displays[[rv, rf]] || displays[[v, f]]
      "[#{displays[[rv, rf]] || displays[[v, f]]}]"
    else
      return [nil, "unresolved ${#{v}.#{f}} in measure sql"]
    end
  end
  if out =~ /\bCASE\b/i
    case_res = OmniFormula.translate_case_when(out)
    return [nil, 'untranslatable CASE WHEN expression'] unless case_res
    out = case_res
  end
  out = OmniFormula.translate_sql_functions(out)
  [out, nil]
end

if __FILE__ == $PROGRAM_NAME
  opts = { connection_id: '<CONNECTION_ID>' }
  OptionParser.new do |o|
    o.on('--model-dir DIR') { |v| opts[:model_dir] = v }
    o.on('--topic NAME') { |v| opts[:topic] = v }
    o.on('--export PATH') { |v| opts[:export] = v }
    o.on('--connection-id ID') { |v| opts[:connection_id] = v }
    o.on('--folder-id ID') { |v| opts[:folder_id] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--signature-out PATH') { |v| opts[:signature_out] = v }
  end.parse!(ARGV)
  { model_dir: '--model-dir', topic: '--topic', out: '--out' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end
  model = OmniModel.load(opts[:model_dir])
  if opts[:export] && File.file?(opts[:export])
    export_doc = JSON.parse(File.read(opts[:export], encoding: 'UTF-8'))
    OmniModel.merge_workbook_model!(model, export_doc['workbookModel']) if export_doc.is_a?(Hash)
  end
  envelope, signature, = build(model, opts[:topic], opts[:connection_id], opts[:folder_id])
  File.write(opts[:out], JSON.pretty_generate(envelope) + "\n")
  sig_path = opts[:signature_out] || File.join(File.dirname(opts[:out]), 'omni-signature.json')
  File.write(sig_path, JSON.pretty_generate(signature) + "\n")
  warn "wrote #{opts[:out]} (#{envelope['stats']['elements']} elements, #{envelope['warnings'].length} warnings)"
end
