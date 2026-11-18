#!/usr/bin/env ruby
# frozen_string_literal: true
# RLS/CLS gate. Reads the `security` block of the convert-dm.rb envelope (Lightdash `sql_filter`,
# `required_attributes`, `any_attributes`) and writes a Sigma security plan. Read-only.
#
#   ruby scripts/detect-rls.rb --envelope dm.json --out rls-plan.json [--ack] [--ack-complex REASON] [--no-gate]
#
# Translation (row level):
#   sql_filter `${TABLE}.col IN (${lightdash.attributes.X})` / `col = ${ld.attr.X}` (either attribute
#   alias, optional quotes/parens/${model.col} refs) -> Sigma user attribute X + a row filter on the
#   data-model element of that model: `[<Column>] in user attribute X`. Lightdash fails CLOSED when a
#   user has no value for the attribute; the plan carries that note.
#   required_attributes / any_attributes (model or dimension) -> column_security entries (model-level
#   gating becomes whole-element access; dimension gating becomes column-level security).
#   Any other sql_filter shape (several conditions, functions, no attribute) is NOT translated: it
#   becomes a degradation-ledger gap (class scope-cut) and fails the gate. A human must decide.
#
# Gate (exit code):
#   0  no row/column security, or the plan was acknowledged with --ack (and nothing untranslatable)
#   2  security exists and --ack was not given
#   3  an untranslatable sql_filter exists (--ack does not cover it; --ack-complex REASON records a waiver)
#   --no-gate always exits 0 (report only; used by --dry-run)

require 'json'
require 'optparse'
require_relative 'lib/degradation_ledger'

module LightdashRls
  module_function

  ATTR = /\$\{\s*(?:lightdash\.attributes|ld\.attr)\.([A-Za-z_][A-Za-z0-9_]*)\s*\}/.freeze
  Q = %q('?"?)

  # -> { column:, attribute:, operator: 'in'|'equals' } or nil when not a simple `col IN/= attribute`.
  def parse_sql_filter(sql)
    s = sql.to_s.strip.sub(/;\z/, '')
    attr = "#{Q}#{ATTR.source}#{Q}"
    col = '(\$\{TABLE\}\.|\$\{[A-Za-z_]\w*\.|\$\{)?`?"?([A-Za-z_]\w*)`?"?\}?'
    if (m = /\A\(?\s*#{col}\s+IN\s*\(\s*#{attr}\s*\)\s*\)?\z/i.match(s))
      return { 'column' => m[2], 'attribute' => m[3], 'operator' => 'in' }
    end
    if (m = /\A\(?\s*#{col}\s*=\s*#{attr}\s*\)?\z/i.match(s))
      return { 'column' => m[2], 'attribute' => m[3], 'operator' => 'equals' }
    end
    if (m = /\A\(?\s*#{attr}\s*=\s*#{col}\s*\)?\z/i.match(s))
      return { 'column' => m[3], 'attribute' => m[1], 'operator' => 'equals' }
    end
    nil
  end

  def element_column(spec, model, column)
    els = spec.dig('pages', 0, 'elements') || spec['elements'] || []
    el = els.find { |e| e['id'] == "el-#{model}" }
    col = el && (el['columns'] || []).find { |c| c['id'] == "col-#{model}-#{column}" }
    [el, col]
  end

  def plan(envelope)
    sec = envelope['security'].is_a?(Hash) ? envelope['security'] : {}
    spec = envelope['sigmaDataModel'] || {}
    attrs = {}
    row_filters = []
    column_security = []
    gaps = []
    (sec['models'] || {}).each do |model, e|
      if e['sql_filter']
        parsed = parse_sql_filter(e['sql_filter'])
        el, col = parsed ? element_column(spec, model, parsed['column']) : [nil, nil]
        if parsed && col
          attrs[parsed['attribute']] ||= { 'name' => parsed['attribute'], 'source' => "sql_filter on #{model}" }
          row_filters << {
            'model' => model, 'element_id' => el['id'], 'column_id' => col['id'], 'column' => col['name'],
            'attribute' => parsed['attribute'], 'operator' => parsed['operator'], 'source_sql' => e['sql_filter'],
            'sigma' => "data-model row filter on #{el['name']}: [#{col['name']}] #{parsed['operator']} user attribute #{parsed['attribute']}",
            'fail_closed' => 'Lightdash denies a user who has no value for the attribute; the Sigma filter must also return ' \
                             'no rows when the user attribute is unset (verify with a user that has no value)'
          }
        else
          why = parsed ? "column #{parsed['column']} of model #{model} is not a column of the data model" : 'not a simple `column IN/= attribute` filter'
          gaps << DegradationLedger.entry('scope-cut', "sql_filter on #{model}",
                                          "#{why}; row-level security was NOT translated (#{e['sql_filter']}); a human must decide", 'detect-rls')
        end
      end
      %w[required_attributes any_attributes].each do |k|
        next unless e[k]
        column_security << { 'scope' => 'model', 'model' => model, 'element_id' => "el-#{model}", k => e[k],
                             'sigma' => "restrict element el-#{model} (and its explore columns) to users with #{k.tr('_', ' ')} #{e[k].to_json}" }
      end
    end
    Array(sec['column_required_attributes']).each do |c|
      k = c['required_attributes'] ? 'required_attributes' : 'any_attributes'
      column_security << { 'scope' => 'column', 'model' => c['model'], 'field' => c['field'], 'element_id' => c['element_id'],
                           'column_id' => c['column_id'], k => c[k],
                           'sigma' => "column-level security on #{c['column_id'] || c['field']}: only users with #{k.tr('_', ' ')} #{c[k].to_json}" }
    end
    { 'mode' => 'plan', 'explore' => sec['explore'], 'user_attributes' => attrs.values, 'row_filters' => row_filters,
      'column_security' => column_security, 'gaps' => gaps, 'acknowledged' => false }
  end

  # Returns [exit_code, message].
  def gate(plan, ack:, no_gate:, ack_complex:)
    has_security = !(plan['row_filters'].empty? && plan['column_security'].empty? && plan['gaps'].empty?)
    return [0, 'no row/column security found'] unless has_security
    return [0, 'report only (--no-gate)'] if no_gate
    unless plan['gaps'].empty?
      return [0, "untranslatable sql_filter waived: #{ack_complex}"] if ack_complex && !ack_complex.empty? && ack
      return [3, "#{plan['gaps'].length} sql_filter(s) cannot be translated; fix the Lightdash filter or record a waiver with --ack --ack-complex REASON"]
    end
    return [0, 'security plan acknowledged'] if ack
    [2, 'row/column security exists; review the plan and re-run with --ack once applied/accepted']
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--envelope PATH') { |v| opts[:envelope] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--ack') { opts[:ack] = true }
    o.on('--ack-complex REASON') { |v| opts[:ack_complex] = v }
    o.on('--no-gate') { opts[:no_gate] = true }
  end.parse!(ARGV)
  abort 'missing --envelope' if opts[:envelope].to_s.empty?
  abort 'missing --out' if opts[:out].to_s.empty?
  envelope = JSON.parse(File.read(opts[:envelope], encoding: 'UTF-8'))
  plan = LightdashRls.plan(envelope)
  code, msg = LightdashRls.gate(plan, ack: opts[:ack], no_gate: opts[:no_gate], ack_complex: opts[:ack_complex])
  plan['acknowledged'] = true if code.zero? && opts[:ack]
  plan['ack_complex'] = opts[:ack_complex] if opts[:ack_complex]
  File.write(opts[:out], JSON.pretty_generate(plan) + "\n")
  warn "detect-rls: #{plan['row_filters'].length} row filter(s), #{plan['column_security'].length} column rule(s), " \
       "#{plan['gaps'].length} untranslatable; #{msg}"
  plan['gaps'].each { |g| warn "  GAP #{g['item']}: #{g['reason']}" }
  exit code
end
