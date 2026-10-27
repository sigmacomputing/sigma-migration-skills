#!/usr/bin/env ruby
# E2E-of-the-build-path regression for LEARNED-RULE PLACEMENT. Drives the
# ACTUAL build-charts-from-signals.rb with a customer learned-rules file and
# asserts a matched rule's Sigma formula LANDS on the chart column that carries
# the calc — the field defect: the rule matched, a "learned-rule applied" line
# was logged, and the tile still pointed at the unresolvable [Master/<calc>]
# passthrough (formula generated, never placed). Deterministic + offline.
#
# Covers:
#   A. DIMENSION calc on the rows shelf → the grouping passthrough is rewritten
#      to the learned formula; nested [Master/X] refs become materialized
#      sibling passthroughs (the param-switch sibling rule).
#   B. MEASURE calc on the cols shelf → the shelf aggregate wraps the learned
#      formula: Sum(<learned>).
#   C. Calc keyed by an internal Calculation_<id> name whose chart column is
#      named by CAPTION → still placed.
#   D. A matched rule with NO bound column → loud WARN (degraded severity, lands
#      in coverage.json) instead of a success-sounding NOTE.
#
# Usage:  ruby scripts/test-learned-rule-placement.rb

require 'json'
require 'tmpdir'
require 'yaml'

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

MASTER = {
  '(?i)^Email$'   => { 'id' => 'm-email', 'name' => 'Email' },
  '(?i)^Points$'  => { 'id' => 'm-pts',   'name' => 'Points' },
  '(?i)^Region$'  => { 'id' => 'm-reg',   'name' => 'Region' }
}.freeze

RULES = {
  'rules' => [
    { 'feature' => 'FINDNTH_DOT2', 'description' => 'second dotted segment',
      'tableau_pattern' => '\bFINDNTH\s*\(\s*\[([^\]]+)\]\s*,\s*"\."\s*,\s*2\s*\)',
      'sigma_template' => 'SplitPart([Master/\1], ".", 2)', 'confidence' => 'validated' },
    { 'feature' => 'ZNX', 'description' => 'customer null-to-zero wrapper',
      'tableau_pattern' => '\bZNX\s*\(\s*\[([^\]]+)\]\s*\)',
      'sigma_template' => 'Coalesce([Master/\1], 0)', 'confidence' => 'validated' }
  ]
}.freeze

def build(zone, csv_header)
  layout = [{ 'dashboard' => 'Dash', 'is_story' => false, 'zones' => [zone] }]
  meta = { 'worksheets' => { zone['caption'] => zone }, 'parameters' => [],
           'column_aliases' => {}, 'columns_by_guid' => {}, 'shared_filters' => [], 'stories' => [] }
  out = nil
  log = nil
  Dir.mktmpdir do |d|
    home = File.join(d, 'home')
    Dir.mkdir(home)
    File.write(File.join(home, 'learned-rules.yaml'), RULES.to_yaml)
    File.write("#{d}/layout.json", JSON.dump(layout))
    File.write("#{d}/meta.json", JSON.dump(meta))
    File.write("#{d}/mm.json", JSON.dump(MASTER))
    File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => zone['caption'] }] }))
    Dir.mkdir("#{d}/views"); File.write("#{d}/views/v1.csv", "#{csv_header}\nWest,1\n")
    o = "#{d}/specs.json"
    log = IO.popen({ 'TABLEAU_TO_SIGMA_HOME' => home },
                   ['ruby', BUILD, '--tableau-dir', d, '--layout', "#{d}/layout.json",
                    '--meta', "#{d}/meta.json", '--master-map', "#{d}/mm.json",
                    '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                    '--title', 'Dash', '--out', o],
                   err: %i[child out], &:read)
    out = JSON.parse(File.read(o)) if File.exist?(o)
  end
  [out, log]
end

def zone(rows:, cols:, aggs:, measures:, calc:)
  { 'id' => '1', 'kind' => 'chart', 'caption' => 'Tile', 'chart_kind' => 'bar',
    'mark_class' => 'Bar', 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100,
    'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
    'ref_marks' => [], 'rows_shelf' => rows, 'cols_shelf' => cols,
    'aggregations' => aggs, 'measures' => measures, 'calculations' => [calc] }
end

def cols_of(spec)
  els = spec.is_a?(Array) ? spec : (spec['elements'] || (spec['pages'] || []).flat_map { |p| p['elements'] || [] })
  els.reject { |e| e['kind'] == 'control' }.flat_map { |e| e['columns'] || [] }
end

puts 'A — dimension calc on the rows shelf is rewritten to the learned formula'
specA, logA = build(zone(rows: '[Email Domain]', cols: '[Points]',
                         aggs: { '[Email Domain]' => 'None', '[Points]' => 'Sum' },
                         measures: [{ 'column' => '[Points]', 'derivation' => 'Sum' }],
                         calc: { 'name' => '[Email Domain]', 'caption' => 'Email Domain', 'datatype' => 'string',
                                 'role' => 'dimension', 'class' => 'tableau',
                                 'formula' => 'FINDNTH([Email], ".", 2)' }), 'Email Domain,Points')
abort "build A produced no spec:\n#{logA}" unless specA
colsA = cols_of(specA)
placed = colsA.find { |c| c['formula'] == 'SplitPart([Email], ".", 2)' }
check(!placed.nil?, "grouping column carries the learned formula (sibling form) — got #{colsA.map { |c| c['formula'] }.inspect}", fails)
check(colsA.none? { |c| c['formula'] == '[Master/Email Domain]' },
      'no column left on the unresolvable [Master/Email Domain] passthrough', fails)
sib = colsA.find { |c| c['name'] == 'Email' && c['formula'] == '[Master/Email]' }
check(!sib.nil?, 'nested [Master/Email] materialized as a sibling passthrough column', fails)
check(logA =~ /NOTE .*learned-rule PLACED on .*Email Domain/,
      'success logged as a NOTE naming the placement', fails)

puts 'B — measure calc keeps the shelf aggregate around the learned formula'
specB, logB = build(zone(rows: '[Region]', cols: '[Score]',
                         aggs: { '[Region]' => 'None', '[Score]' => 'Sum' },
                         measures: [{ 'column' => '[Score]', 'derivation' => 'Sum' }],
                         calc: { 'name' => '[Score]', 'caption' => 'Score', 'datatype' => 'real',
                                 'role' => 'measure', 'class' => 'tableau', 'formula' => 'ZNX([Points])' }), 'Region,Score')
abort "build B produced no spec:\n#{logB}" unless specB
colsB = cols_of(specB)
check(colsB.any? { |c| c['formula'] == 'Sum(Coalesce([Points], 0))' },
      "measure column is Sum(<learned>) — got #{colsB.map { |c| c['formula'] }.inspect}", fails)
check(colsB.none? { |c| c['formula'].to_s.include?('[Master/Score]') },
      'no column left on [Master/Score]', fails)

puts 'C — Calculation_<id> internal name, chart column named by caption'
specC, logC = build(zone(rows: '[Region]', cols: '[Calculation_42]',
                         aggs: { '[Region]' => 'None', '[Calculation_42]' => 'Sum' },
                         measures: [{ 'column' => '[Calculation_42]', 'derivation' => 'Sum' }],
                         calc: { 'name' => '[Calculation_42]', 'caption' => 'Score', 'datatype' => 'real',
                                 'role' => 'measure', 'class' => 'tableau', 'formula' => 'ZNX([Points])' }), 'Region,Score')
abort "build C produced no spec:\n#{logC}" unless specC
colsC = cols_of(specC)
check(colsC.any? { |c| c['formula'] == 'Sum(Coalesce([Points], 0))' },
      "caption-named measure column placed — got #{colsC.map { |c| c['formula'] }.inspect}", fails)

puts 'D — matched rule with no bound column is a loud WARN, not a success NOTE'
specD, logD = build(zone(rows: '[Region]', cols: '[Points]',
                         aggs: { '[Region]' => 'None', '[Points]' => 'Sum' },
                         measures: [{ 'column' => '[Points]', 'derivation' => 'Sum' }],
                         calc: { 'name' => '[Tooltip Only]', 'caption' => 'Tooltip Only', 'datatype' => 'real',
                                 'role' => 'measure', 'class' => 'tableau', 'formula' => 'ZNX([Points])' }), 'Region,Points')
abort "build D produced no spec:\n#{logD}" unless specD
check(logD =~ /WARN .*learned-rule matched .*Tooltip Only.*NOT placed/,
      'unplaced learned rule surfaces as a WARN', fails)
check(logD !~ /NOTE .*learned-rule (applied|PLACED) .*Tooltip Only/,
      'no success-sounding NOTE for the unplaced rule', fails)

puts
if fails.empty?
  puts 'ALL PASS — learned-rule translations are placed on the bound chart column (or WARNed)'
  exit 0
else
  puts "#{fails.size} FAILED:"; fails.each { |m| puts "  - #{m}" }; exit 1
end
