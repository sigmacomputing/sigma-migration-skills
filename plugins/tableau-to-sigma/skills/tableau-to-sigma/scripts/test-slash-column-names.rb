#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test: a data-model / master column whose NAME contains "/" (or "[" "]")
# must be renamed to a referenceable name, and every reference follows.
#
# THE BUG (seen live): a Tableau calc captioned "Region - East/West" became a data-model
# calc column NAMED "Region - East/West". Sigma reads "/" inside a bracketed reference as a
# path separator, so the workbook master's `[Order Fact View/Region - East/West]` exported
# as 'Unknown column', the column compiled to type="error", and a list control over it
# POSTed as "Invalid value source for list control" (which breaks the workbook POST). The
# pre-POST ref gate passed because it compared names only. A customer workbook with a
# "Branch - North/South" quick filter hit the same wall (the filter became an unknown
# filter). #685-B only desensitized the FORMULA of a warehouse passthrough and kept the raw
# caption as the NAME, so the name stayed unreferenceable.
#
# THE FIX: MechanicalSpecs.sanitize_slash_column_names! (run by fixup_dm_spec) renames every
# column and metric whose name holds "/" "[" "]" to Sigma's friendly form (the character
# becomes a space, space runs squeeze: "Area - East/West" -> "Area - East West"), rewrites
# every DM-internal reference, and returns the caption -> safe-name map.
# derive_master(caption_aliases:) names the master column the safe name and keeps the
# Tableau caption as a second master-map key, so every chart / control / filter ref lands on
# the safe name while the axis title and control label still show the caption.
#
# Part A: DM rename + internal references (hand-built derived-view model).
# Part B: derive_master — master names, master-map caption keys, collision suffix.
# Part C: end to end on fixtures/slash-column-names.twb through the real converter,
#         fixup_dm_spec, derive_master, parse-twb-layout and build-charts.
# Part D: assert-wb-refs-resolve.rb refuses a slash-named column (the gate that passed it).
#
# Usage:  ruby scripts/test-slash-column-names.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'mechanical-specs'

DIR     = __dir__
SKILL   = File.expand_path('..', DIR)
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
GATE    = File.join(DIR, 'assert-wb-refs-resolve.rb')
FIXTURE = File.join(DIR, 'fixtures', 'slash-column-names.twb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

SPECIAL = %r{[/\[\]]}.freeze

# Tolerate the pre-fix API (no :renamed / :rename_map, no caption_aliases:) so a run against
# unfixed code reports each failed check below instead of dying on the first nil.
def renamed_of(result)
  Array(result[:renamed])
end

def map_of(result)
  result[:rename_map] || {}
end

def derive(fact_el, model, aliases)
  base = MechanicalSpecs.base_of(model, fact_el)
  MechanicalSpecs.derive_master(fact_el, fact_el['name'], base, nil, model, caption_aliases: aliases || {})
rescue ArgumentError
  MechanicalSpecs.derive_master(fact_el, fact_el['name'], base, nil, model)
end

# ---------------------------------------------------------------------------
puts 'Part A - sanitize_slash_column_names!: names, internal refs, warnings'
def dm_model
  {
    'name' => 'Orders', 'schemaVersion' => 1,
    'pages' => [{ 'id' => 'p1', 'name' => 'Page 1', 'elements' => [
      { 'id' => 'el-base', 'kind' => 'table', 'name' => 'Order Fact',
        'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1', 'path' => %w[SALESDB SALES ORDER_FACT] },
        'columns' => [
          { 'id' => 'inode-1/REGION', 'formula' => '[ORDER_FACT/Region]' },
          { 'id' => 'inode-2/COUNTRY_REGION', 'formula' => '[ORDER_FACT/Country/Region]' },
          { 'id' => 'inode-3/NET_REVENUE', 'formula' => '[ORDER_FACT/Net Revenue]' },
          { 'id' => 'c-area', 'name' => 'Area - East/West', 'formula' => 'If([Region] = "East", "East", "West")' },
          { 'id' => 'c-tag', 'name' => 'Area Tag', 'formula' => '[Area - East/West] & " zone"' },
          { 'id' => 'c-brk', 'name' => 'Pct [Net]', 'formula' => '[Net Revenue] / 100' },
          # collides with the safe form of "Area - East/West"? no: this is the safe form of "West/East"
          { 'id' => 'c-we', 'name' => 'West East', 'formula' => '"we"' },
          { 'id' => 'c-we2', 'name' => 'West/East', 'formula' => '"we2"' }
        ],
        'order' => %w[inode-1/REGION inode-2/COUNTRY_REGION inode-3/NET_REVENUE c-area c-tag c-brk c-we c-we2],
        'metrics' => [
          { 'id' => 'm-share', 'name' => 'Share E/W', 'formula' => 'CountIf([Area - East/West] = "East")' }
        ],
        'relationships' => [] },
      { 'id' => 'el-view', 'kind' => 'table', 'name' => 'Order Fact View',
        'source' => { 'kind' => 'table', 'elementId' => 'el-base' },
        'columns' => [
          { 'id' => 'v-area', 'formula' => '[Order Fact/Area - East/West]' },
          { 'id' => 'v-tag', 'formula' => '[Order Fact/Area Tag]' },
          { 'id' => 'v-cty', 'formula' => '[Order Fact/Country/Region]' },
          { 'id' => 'v-flag', 'name' => 'East Flag', 'formula' => 'If([Area - East/West] = "East", 1, 0)' }
        ],
        'order' => %w[v-area v-tag v-cty v-flag] }
    ] }]
  }
end

model = dm_model
fx = MechanicalSpecs.fixup_dm_spec(model)
els = MechanicalSpecs.all_elements(model)
cols = els.flat_map { |e| (e['columns'] || []) + (e['metrics'] || []) }
base = els.find { |e| e['id'] == 'el-base' }
view = els.find { |e| e['id'] == 'el-view' }
named = ->(el, id) { (el['columns'] + (el['metrics'] || [])).find { |c| c['id'] == id } }

check(cols.none? { |c| c['name'].to_s =~ SPECIAL },
      "no column or metric name holds '/' '[' ']' after fixup_dm_spec (bad: #{cols.map { |c| c['name'] }.compact.grep(SPECIAL).inspect})", fails)
check(named.call(base, 'c-area')['name'] == 'Area - East West',
      "calc 'Area - East/West' -> 'Area - East West' (hyphen kept, slash -> space; got #{named.call(base, 'c-area')['name'].inspect})", fails)
check(named.call(base, 'inode-2/COUNTRY_REGION')['name'] == 'Country Region',
      "warehouse passthrough 'Country/Region' -> 'Country Region' (got #{named.call(base, 'inode-2/COUNTRY_REGION')['name'].inspect})", fails)
check(named.call(base, 'c-brk')['name'] == 'Pct Net', "brackets in a name fold to spaces and squeeze ('Pct [Net]' -> 'Pct Net')", fails)
check(named.call(base, 'm-share')['name'] == 'Share E W', "a METRIC name is renamed too ('Share E/W' -> 'Share E W')", fails)
check(named.call(base, 'c-we2')['name'] == 'West East 2',
      "a rename that collides with an existing name takes a numeric suffix (got #{named.call(base, 'c-we2')['name'].inspect})", fails)
check(named.call(base, 'c-we')['name'] == 'West East' && named.call(base, 'c-we2')['name'] == 'West East 2',
      'the pre-existing colliding name is untouched and the renamed one does not take it', fails)

check(named.call(base, 'c-tag')['formula'] == '[Area - East West] & " zone"',
      "same-element ref in another calc is rewritten (got #{named.call(base, 'c-tag')['formula']})", fails)
check(named.call(base, 'm-share')['formula'] == 'CountIf([Area - East West] = "East")',
      "metric formula ref is rewritten (got #{named.call(base, 'm-share')['formula']})", fails)
check(named.call(view, 'v-area')['formula'] == '[Order Fact/Area - East West]',
      "derived-view passthrough [Base/<name>] is rewritten (got #{named.call(view, 'v-area')['formula']})", fails)
check(named.call(view, 'v-flag')['formula'] == 'If([Area - East West] = "East", 1, 0)',
      "derived-view calc's own-element ref is rewritten (got #{named.call(view, 'v-flag')['formula']})", fails)
check(named.call(view, 'v-tag')['formula'] == '[Order Fact/Area Tag]', 'an unaffected ref is byte-identical', fails)
check(MechanicalSpecs.col_display(named.call(view, 'v-area')) == 'Area - East West',
      'the unnamed derived column now displays the safe name (col_display no longer truncates at the slash)', fails)
check(JSON.generate(model) !~ %r{\[[^\]]*/Area - East/West\]|\[Area - East/West\]},
      'no reference to the old name is left anywhere in the model', fails)

check(renamed_of(fx).size == 5,
      "one rename record per renamed column/metric: 5 (got #{renamed_of(fx).size}: #{renamed_of(fx).map { |r| r['from'] }.inspect})", fails)
check(!renamed_of(fx).empty? && renamed_of(fx).all? { |r| r['warning'].to_s.include?("renamed for Sigma: '/' cannot appear in a referenced column name") &&
                              r['warning'].include?("'#{r['from']}'") && r['warning'].include?("'#{r['to']}'") },
      'each record carries a NAMED warning that names the old and the new name', fails)
check(map_of(fx) == { 'Area - East/West' => 'Area - East West', 'Country/Region' => 'Country Region',
                           'Pct [Net]' => 'Pct Net', 'Share E/W' => 'Share E W', 'West/East' => 'West East 2' },
      "the caption -> safe-name map comes back (got #{map_of(fx).inspect})", fails)
again = MechanicalSpecs.fixup_dm_spec(model)
check(!renamed_of(fx).empty? && renamed_of(again).empty? && map_of(again).empty?, 'a second fixup pass renames nothing (idempotent)', fails)

# GUARD: a model with no special names is untouched (holds with or without the fix).
puts '  (guard — a model with no special names is byte-identical)'
plain = { 'pages' => [{ 'elements' => [{ 'id' => 'e', 'kind' => 'table',
  'columns' => [{ 'id' => 'c', 'name' => 'Net Revenue', 'formula' => '[T/Net Revenue]' }], 'order' => ['c'] }] }] }
before = JSON.generate(plain)
r = MechanicalSpecs.fixup_dm_spec(plain)
check(JSON.generate(plain) == before && renamed_of(r).empty?, 'guard: nothing renamed, nothing rewritten', fails)

# ---------------------------------------------------------------------------
puts
puts 'Part B - derive_master: safe master names, caption kept as a lookup key'
fact = MechanicalSpecs.pick_fact(model)
derived = derive(fact, model, map_of(fx))
mnames = derived['master_columns'].map { |c| c['name'] }
check(mnames.none? { |n| n =~ SPECIAL }, "no master column name holds '/' '[' ']' (got #{mnames.grep(SPECIAL).inspect})", fails)
bad_f = derived['master_columns'].select { |c| c['formula'].to_s.sub(%r{\A\[[^/\]]+/(.*)\]\z}, '\\1') =~ SPECIAL }.map { |c| c['formula'] }
check(bad_f.empty?, "no master column formula references a name with a special character (got #{bad_f.inspect})", fails)
area = derived['master_columns'].find { |c| c['name'] == 'Area - East West' }
check(area && area['formula'] == "[#{fact['name']}/Area - East West]",
      "master column 'Area - East West' reads [#{fact['name']}/Area - East West] (got #{area && area['formula']})", fails)
hit = lambda do |cap|
  derived['mmap'].each { |pat, info| return info if Regexp.new(pat).match?(cap) }
  nil
end
check(hit.call('Area - East/West') && hit.call('Area - East/West')['name'] == 'Area - East West',
      'the Tableau caption "Area - East/West" still resolves (to the safe master column)', fails)
check(hit.call('Area - East West') && hit.call('Area - East West')['name'] == 'Area - East West',
      'the safe name resolves too', fails)
check(hit.call('Country/Region') && hit.call('Country/Region')['name'] == 'Country Region',
      'the warehouse caption "Country/Region" resolves to the safe master column', fails)
check(hit.call('Area - East/West')['caption'] == 'Area - East/West',
      'the entry records the Tableau caption (display label for the builder)', fails)
check(derived['mmap'].values.none? { |e| e['name'].to_s =~ SPECIAL },
      'no master-map entry name holds a special character', fails)
# Without the aliases the master is still referenceable, only the caption key is missing.
plain_derived = MechanicalSpecs.derive_master(fact, fact['name'], MechanicalSpecs.base_of(model, fact), nil, model)
check(plain_derived['master_columns'].map { |c| c['name'] }.none? { |n| n =~ SPECIAL },
      'master names are safe even when no aliases are passed (the DM names are already safe)', fails)
check(MechanicalSpecs.respond_to?(:slash_captions_from_twb) && MechanicalSpecs.slash_captions_from_twb("<column caption='Branch - North/South' name='[C1]'/><column caption='Plain' name='[C2]'/>") ==
      { 'Branch - North/South' => 'Branch - North South' },
      'slash_captions_from_twb recovers caption aliases for a REUSED data model', fails)

# ---------------------------------------------------------------------------
puts
puts 'Part C - end to end: converter -> fixup -> derive_master -> build-charts on slash-column-names.twb'
node_ok = begin
  _o, st = Open3.capture2e('node', '--version')
  st.success?
rescue Errno::ENOENT
  false
end
unless node_ok
  puts '  SKIP  node not on PATH — Part C needs the vendored converter (parts A, B, D still ran)'
else
  Dir.mktmpdir do |d|
    conv = MechanicalSpecs.run_converter(twb_path: FIXTURE, conn: 'conn-1', db: 'SALESDB', schema: 'SALES',
                                         mcp_build: File.join(SKILL, 'converter', 'tableau.mjs'), workdir: d)
    m = conv['model']
    efx = MechanicalSpecs.fixup_dm_spec(m)
    names = MechanicalSpecs.all_elements(m).flat_map { |e| (e['columns'] || []).map { |c| MechanicalSpecs.col_display(c) } }.compact
    check(names.none? { |n| n =~ SPECIAL }, "converter DM has no '/' in any column name after fixup (got #{names.grep(SPECIAL).inspect})", fails)
    check(renamed_of(efx).map { |r| r['from'] }.sort == ['Area - East/West', 'Country/Region'],
          "exactly one warning record per renamed column (got #{renamed_of(efx).map { |r| r['from'] }.inspect})", fails)
    calc_tag = MechanicalSpecs.all_elements(m).flat_map { |e| e['columns'] }.find { |c| c['name'] == 'Area Tag' }
    check(calc_tag && calc_tag['formula'].include?('[Area - East West]') && !calc_tag['formula'].include?('East/West'),
          "converter's 'Area Tag' calc reads the renamed column (got #{calc_tag && calc_tag['formula']})", fails)
    cf = MechanicalSpecs.pick_fact(m)
    dm = derive(cf, m, map_of(efx))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(dm['mmap']))
    lay = File.join(d, 'dashboard-layout.json')
    Open3.capture2e(RUBY, PARSER, FIXTURE, lay)
    Dir.mkdir(File.join(d, 'views'))
    File.write(File.join(d, 'views', 'v0.csv'), "Area - East/West,Net Revenue\nEast,10\nWest,25\n")
    File.write(File.join(d, 'views', 'v1.csv'), "Country/Region,Net Revenue\nUS,10\nCA,25\n")
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'SL', 'hasExtracts' => false },
                         'views' => { 'view' => [{ 'id' => 'v0', 'name' => 'Revenue by Area' },
                                                 { 'id' => 'v1', 'name' => 'Revenue by Country' }] }))
    out = File.join(d, 'chart-specs.json')
    # Test harness: runs the build script under test against a temp-dir fixture; every argument is a literal or a temp path.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay, '--meta', File.join(d, 'dashboard-layout-meta.json'),
                              '--master-map', File.join(d, 'master-columns.json'), '--master-element-id', 'master',
                              '--auto-controls', '--skip-dashboard-read', 'offline test fixture', '--out', out)
    check(st.success? && File.exist?(out), "build-charts exits 0 (got: #{log.lines.grep(/rror/).first(2).inspect})", fails)
    specs = File.exist?(out) ? JSON.parse(File.read(out)) : []
    mids = dm['master_columns'].to_h { |c| [c['id'], c['name']] }
    charts = specs.select { |e| e['kind'] == 'bar-chart' }
    ctls = specs.select { |e| e['kind'] == 'control' }
    area_chart = charts.find { |e| e['id'] == 'el-revenue-by-area' } || {}
    country_chart = charts.find { |e| e['id'] == 'el-revenue-by-country' } || {}
    formulas = specs.flat_map { |e| Array(e['columns']).map { |c| c['formula'].to_s } }
    check(formulas.none? { |f| f =~ %r{\[Master/[^\]]*/} },
          "no emitted formula has a '/' inside a [Master/<name>] column segment (got #{formulas.grep(%r{\[Master/[^\]]*/}).inspect})", fails)
    check(Array(area_chart['columns']).any? { |c| c['formula'] == '[Master/Area - East West]' },
          "the Area chart's dimension is [Master/Area - East West] (columns: #{Array(area_chart['columns']).map { |c| c['formula'] }.inspect})", fails)
    check(Array(country_chart['columns']).any? { |c| c['formula'] == '[Master/Country Region]' },
          'the Country chart\'s dimension is [Master/Country Region]', fails)
    area_ctl = ctls.find { |c| c['controlId'] == 'ctl-area-east-west' } || {}
    country_ctl = ctls.find { |c| c['controlId'] == 'ctl-country-region' } || {}
    check(mids[area_ctl.dig('source', 'columnId')] == 'Area - East West' &&
            Array(area_ctl['filters']).all? { |f| mids[f['columnId']] == 'Area - East West' } && Array(area_ctl['filters']).any?,
          "the Area quick filter's value source AND filter target are the safe master column (source #{area_ctl.dig('source', 'columnId').inspect})", fails)
    check(mids[country_ctl.dig('source', 'columnId')] == 'Country Region' &&
            Array(country_ctl['filters']).all? { |f| mids[f['columnId']] == 'Country Region' } && Array(country_ctl['filters']).any?,
          'the Country/Region quick filter binds the safe master column', fails)
    check(area_ctl['name'] == 'Area - East/West' && country_ctl['name'] == 'Country/Region' &&
            mids[area_ctl.dig('source', 'columnId')] == 'Area - East West',
          'control labels still show the Tableau caption while the control reads the safe master column', fails)
    check(area_chart.dig('xAxis', 'format', 'title', 'text') == 'Area - East/West' &&
            country_chart.dig('xAxis', 'format', 'title', 'text') == 'Country/Region' &&
            Array(area_chart['columns']).any? { |c| c['formula'] == '[Master/Area - East West]' },
          'chart axis titles still show the Tableau caption while the axis reads the safe master column', fails)
    check(Array(area_chart['columns']).none? { |c| c['name'].to_s =~ SPECIAL } && Array(country_chart['columns']).none? { |c| c['name'].to_s =~ SPECIAL },
          "no chart column is NAMED with a special character (got #{(Array(area_chart['columns']) + Array(country_chart['columns'])).map { |c| c['name'] }.grep(SPECIAL).inspect})", fails)
    # The master element the workbook builder would emit, plus the whole spec, through the ref gate.
    wb = { 'pages' => [{ 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
                                                           'columns' => dm['master_columns'] }] },
                       { 'name' => 'Main', 'elements' => specs }] }
    dm_ids = { 'dataModelId' => 'dm1', 'pages' => [{ 'elements' => [{ 'id' => 'e1', 'name' => cf['name'],
                                                                      'columnLabels' => dm['master_columns'].map { |c| c['name'] } }] }] }
    File.write(File.join(d, 'wb.json'), JSON.generate(wb))
    File.write(File.join(d, 'dm.json'), JSON.generate(dm_ids))
    gate_out, gate_st = Open3.capture2e(RUBY, GATE, '--wb-spec', File.join(d, 'wb.json'), '--dm-ids', File.join(d, 'dm.json'))
    check(gate_st.success?, "the whole built spec passes the pre-POST ref gate (got: #{gate_out.lines.first(3).join.strip})", fails)
  end
end

# ---------------------------------------------------------------------------
puts
puts 'Part E - build-charts safety net: a raw Tableau caption spliced into a formula is rewritten'
# A few build-charts paths (pcto / rtot shelf tokens, hidden helper-element columns) splice the
# RAW caption into a formula instead of resolving it through map_column. rewrite_slash_caption_refs!
# rewrites those at write time. The block is lifted out of the script (it has no CLI-free entry point).
src = File.read(BUILD, encoding: 'utf-8')
net = src[/^def slash_renamed_caption.*?^end\n\n\$slash_caption_map = .*?^end\n\ndef rewrite_slash_caption_refs!.*?^end\n/m]
check(!net.nil?, 'build-charts-from-signals.rb defines rewrite_slash_caption_refs! and $slash_caption_map', fails)
if net
  mmap = { '(?i)^Area\ \-\ East\ West$' => { 'id' => 'm-area', 'name' => 'Area - East West', 'caption' => 'Area - East/West' },
           '(?i)^Net\ Revenue$' => { 'id' => 'm-rev', 'name' => 'Net Revenue' },
           # A caption that differs from the name for any OTHER reason is not a slash rename.
           '(?i)^Order\ Region$' => { 'id' => 'm-reg', 'name' => 'ORDER_REGION', 'caption' => 'Order Region' } }
  # Test harness: evaluates a block read from the script under test (no external input).
  # nosemgrep: ruby.lang.security.no-eval.ruby-eval
  eval(net)
  tree = { 'pages' => [{ 'name' => 'P', 'elements' => [
    { 'id' => 'c1', 'kind' => 'bar-chart', 'name' => 'Sales by Area',
      'columns' => [{ 'id' => 'a', 'name' => 'Area - East/West', 'formula' => '[Master/Area - East/West]' },
                    { 'id' => 'b', 'name' => 'Share', 'formula' => 'PercentOfTotal(Sum([Master/Area - East/West]), "column")' },
                    { 'id' => 'c', 'name' => 'Net Revenue', 'formula' => 'Sum([Master/Net Revenue])' },
                    { 'id' => 'd', 'name' => 'Order Region', 'formula' => '[Master/Order Region]' }] },
    { 'id' => 'ctl', 'kind' => 'control', 'name' => 'Area - East/West', 'controlId' => 'ctl-area' }
  ] }], 'data_elements' => [{ 'id' => 'h1', 'columns' => [{ 'id' => 'k', 'name' => 'Area - East/West', 'formula' => '[Master/Area - East/West]' },
                                                       { 'id' => 'l', 'name' => 'Cnt', 'formula' => 'Count([Area - East/West])' }] }] }
  rewrite_slash_caption_refs!(tree)
  chart = tree['pages'][0]['elements'][0]
  helper = tree['data_elements'][0]
  check(chart['columns'].map { |c| c['formula'] }.first(3) ==
          ['[Master/Area - East West]', 'PercentOfTotal(Sum([Master/Area - East West]), "column")', 'Sum([Master/Net Revenue])'],
        "chart formulas that carried the raw caption now carry the safe name (got #{chart['columns'].map { |c| c['formula'] }.inspect})", fails)
  check(chart['columns'][0]['name'] == 'Area - East West', 'a calc column NAMED with the raw caption is renamed with its refs', fails)
  check(helper['columns'][0]['formula'] == '[Master/Area - East West]' && helper['columns'][1]['formula'] == 'Count([Area - East West])',
        'hidden helper-element columns (path and bare refs) are rewritten too', fails)
  check(tree['pages'][0]['elements'][1]['name'] == 'Area - East/West' && chart['name'] == 'Sales by Area',
        'a control label / element title (no formula) keeps the Tableau caption', fails)
  check(chart['columns'][2]['name'] == 'Net Revenue' && chart['columns'][2]['formula'] == 'Sum([Master/Net Revenue])',
        'an ordinary column is byte-identical', fails)
  check(!$slash_caption_map.key?('Order Region') && chart['columns'][3]['name'] == 'Order Region' &&
          chart['columns'][3]['formula'] == '[Master/Order Region]',
        'a caption/name difference that is not a slash rename is left alone', fails)
  check(slash_renamed_caption('name' => 'Area - East West 2', 'caption' => 'Area - East/West') == 'Area - East/West' &&
          slash_renamed_caption('name' => 'Area East', 'caption' => 'Area - East/West').nil?,
        'a collision-suffixed safe name still qualifies; an unrelated name does not', fails)
end

# ---------------------------------------------------------------------------
puts
puts 'Part D - the ref gate refuses a slash-named column (it used to pass one by name)'
Dir.mktmpdir do |d|
  wb = { 'pages' => [{ 'name' => 'Main', 'elements' => [{ 'id' => 'c', 'kind' => 'bar-chart', 'name' => 'C',
                                                           'columns' => [{ 'id' => 'x', 'name' => 'Region - East/West',
                                                                           'formula' => '[Order Fact View/Region - East/West]' }] }] }] }
  dm = { 'dataModelId' => 'dm1', 'pages' => [{ 'elements' => [{ 'id' => 'e1', 'name' => 'Order Fact View',
                                                                'columnLabels' => ['Region - East/West'] }] }] }
  File.write(File.join(d, 'wb.json'), JSON.generate(wb))
  File.write(File.join(d, 'dm.json'), JSON.generate(dm))
  gate_out, gate_st = Open3.capture2e(RUBY, GATE, '--wb-spec', File.join(d, 'wb.json'), '--dm-ids', File.join(d, 'dm.json'))
  check(!gate_st.success? && gate_out.include?("contains '/'") && gate_out.include?('Region - East/West'),
        'a DM column NAMED "Region - East/West" fails the gate with the slash reason', fails)
end

puts
if fails.empty?
  puts 'test-slash-column-names: ALL PASS'
else
  puts "test-slash-column-names: #{fails.size} FAIL"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
