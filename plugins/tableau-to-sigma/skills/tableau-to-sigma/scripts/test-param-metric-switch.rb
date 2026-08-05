#!/usr/bin/env ruby
# E2E-of-the-build-path regression for PARAMETER-DRIVEN METRIC/MEASURE SWITCHING
# (bead param-msw). Drives the ACTUAL build-charts-from-signals.rb on a chart
# whose MEASURE is a param-switch calc, and asserts the control actually drives
# the measure — the exact scenario that silently broke ("metric switching
# doesn't work"): the measure fell through to an unbound Sum([Master/<calc>]) and
# an orphan Switch dangled. Deterministic + offline (no Tableau/Sigma calls).
#
# Covers both real shapes:
#   A. numeric-coded param + CASE inside the aggregate: SUM(CASE [P] WHEN 0 THEN [A]…)
#      → Sum(Switch([ctl], "0", [A], …))  (shelf agg wraps a bare-branch Switch)
#   B. string param + per-branch aggregate: IF [P]="Rev" THEN SUM([A]) ELSE SUM([B])
#      → Switch([ctl], "Rev", Sum([A]), Sum([B]))  (no double aggregation)
# Plus: the numeric control's option VALUES equal the Switch keys ("0"/"1"), with
# the display aliases as labels — else the switch matches nothing.
#
# Usage:  ruby scripts/test-param-metric-switch.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

MASTER = {
  '(?i)^Net Revenue$'  => { 'id' => 'm-nr',  'name' => 'Net Revenue' },
  '(?i)^Cost$'         => { 'id' => 'm-cost','name' => 'Cost' },
  '(?i)^Partner Name$' => { 'id' => 'm-pn',  'name' => 'Partner Name' }
}

def build(zone, params, column_aliases)
  layout = [{ 'dashboard' => 'Dash', 'is_story' => false, 'zones' => [zone] }]
  meta = { 'worksheets' => { zone['caption'] => zone }, 'parameters' => params,
           'column_aliases' => column_aliases, 'columns_by_guid' => {}, 'shared_filters' => [], 'stories' => [] }
  out = nil
  Dir.mktmpdir do |d|
    File.write("#{d}/layout.json", JSON.dump(layout))
    File.write("#{d}/meta.json", JSON.dump(meta))
    File.write("#{d}/mm.json", JSON.dump(MASTER))
    File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => zone['caption'] }] }))
    Dir.mkdir("#{d}/views"); File.write("#{d}/views/v1.csv", "Partner Name,#{zone['caption']}\nAcme,1\n")
    o = "#{d}/specs.json"
    IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', "#{d}/layout.json",
              '--meta', "#{d}/meta.json", '--master-map', "#{d}/mm.json",
              '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
              '--title', 'Dash', '--auto-controls', '--out', o],
             err: %i[child out], &:read)
    out = JSON.parse(File.read(o)) if File.exist?(o)
  end
  out
end

def zone_for(formula)
  { 'id' => '1', 'kind' => 'chart', 'caption' => 'Metric by Partner', 'chart_kind' => 'bar',
    'mark_class' => 'Bar', 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100,
    'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
    'ref_marks' => [], 'rows_shelf' => '[Partner Name]', 'cols_shelf' => '[Metric]',
    'aggregations' => { '[Partner Name]' => 'None', '[Metric]' => 'Sum' },
    'measures' => [{ 'column' => '[Metric]', 'derivation' => 'Sum' }],
    'calculations' => [{ 'name' => '[Metric]', 'caption' => 'Metric', 'datatype' => 'real',
                         'role' => 'measure', 'class' => 'tableau', 'formula' => formula }] }
end

def cols_of(spec)
  els = spec.is_a?(Array) ? spec : (spec['elements'] || (spec['pages'] || []).flat_map { |p| p['elements'] || [] })
  [els, els.reject { |e| e['kind'] == 'control' }.flat_map { |e| e['columns'] || [] }]
end

puts 'Pattern A — numeric-coded param, CASE inside the aggregate: SUM(CASE [P] WHEN 0 THEN [A]…)'
# Members are the REAL Tableau float form ("0."/"1.") — the shape that shipped a
# blank switcher (control value "0." vs Switch key "0"). They must canonicalise
# to match the WHEN keys.
specA = build(zone_for('SUM(CASE [Parameters].[Type] WHEN 0 THEN [Net Revenue] WHEN 1 THEN [Cost] END)'),
              [{ 'caption' => 'Type', 'name' => '[Type]', 'param_domain' => 'list', 'datatype' => 'real',
                 'members' => ['0.', '1.'], 'default_value' => '0.' }],
              { 'Type' => [{ 'key' => '0.', 'value' => 'Revenue' }, { 'key' => '1.', 'value' => 'Cost' }] })
abort "build A produced no spec" unless specA
elsA, colsA = cols_of(specA)
measA = colsA.find { |c| c['formula'].to_s.include?('Switch([ctl-param-type]') }
check(!measA.nil?, 'a column carries the control-driven Switch', fails)
check(measA && measA['formula'] == 'Sum(Switch([ctl-param-type], "0", [Net Revenue], "1", [Cost]))',
      "measure BOUND to control-driven Switch, shelf-aggregated — got #{measA && measA['formula'].inspect}", fails)
switch_cols = colsA.select { |c| c['formula'].to_s.include?('Switch([ctl-param-type]') }
check(switch_cols.size == 1, "no orphan Switch column (exactly one carries it) — got #{switch_cols.size}", fails)
ctlA = elsA.find { |e| e['kind'] == 'control' && e['controlId'] == 'ctl-param-type' }
check(!ctlA.nil?, 'Type control emitted', fails)
vals = ctlA && (ctlA.dig('source', 'values') || ctlA['values'])
labs = ctlA && (ctlA.dig('source', 'labels') || ctlA['labels'])
check(vals == %w[0 1], "control option VALUES canonicalised to match Switch keys 0/1 (float members '0.'/'1.') — got #{vals.inspect}", fails)
check(labs == %w[Revenue Cost], "alias LABELS carried through canonicalisation (Revenue/Cost) — got #{labs.inspect}", fails)
# The measure Switch keys and the control values must be identical strings.
switch_keys = measA['formula'].scan(/"(\d+)"/).flatten
check(switch_keys == vals, "Switch keys #{switch_keys.inspect} == control values #{vals.inspect} (the fix)", fails)
# v5.0: single-valuedness contract — a `list` control must PIN
# selectionMode:'single' (Sigma defaults to multiple → array vs scalar Switch
# = type error); `segmented` has NO selectionMode in the schema and is
# inherently single-valued, so nil is the schema-correct emission there.
single_ok = ctlA && (ctlA['controlType'] == 'segmented' ? ctlA['selectionMode'].nil?
                                                        : ctlA['selectionMode'] == 'single')
check(single_ok, "control is single-valued (list pins 'single'; segmented carries none — got " \
                 "#{ctlA && ctlA['controlType']}/#{ctlA && ctlA['selectionMode'].inspect})", fails)

puts 'Pattern B — string param, per-branch aggregate: IF [P]="Revenue" THEN SUM([A]) ELSE SUM([B])'
specB = build(zone_for('IF [Parameters].[Metric] = "Revenue" THEN SUM([Net Revenue]) ELSE SUM([Cost]) END'),
              [{ 'caption' => 'Metric', 'name' => '[Metric]', 'param_domain' => 'list', 'datatype' => 'string',
                 'members' => %w[Revenue Cost], 'default_value' => 'Revenue' }], {})
abort "build B produced no spec" unless specB
_elsB, colsB = cols_of(specB)
# The measure calc here is named 'Metric' too; find the measure carrying the Switch.
measB = colsB.find { |c| c['formula'].to_s.include?('Switch([ctl-param-metric]') }
check(!measB.nil?, 'measure bound to the Switch', fails)
check(measB && measB['formula'] == 'Switch([ctl-param-metric], "Revenue", Sum([Net Revenue]), Sum([Cost]))',
      "pre-aggregated branches → Switch IS the measure (no double Sum) — got #{measB && measB['formula'].inspect}", fails)

puts
if fails.empty?
  puts 'ALL PASS — parameter-driven metric switching binds the control to the measure'
  exit 0
else
  puts "#{fails.size} FAILED:"; fails.each { |m| puts "  - #{m}" }; exit 1
end
