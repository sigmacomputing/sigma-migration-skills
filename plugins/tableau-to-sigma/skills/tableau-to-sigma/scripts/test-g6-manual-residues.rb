#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-g6-manual-residues.rb — G6 regression (run-2 postmortem): requires_custom_sql
# residues (STAYS-MANUAL window/table-calc chains) were routed correctly at
# Phase 1e, but NOTHING bound the routed measure to the tile that plots it — the
# build silently shipped a magnitude proxy and the divergence surfaced only at
# Phase 6 (~2h later; the single gap that kept run 2 YELLOW). Now:
#   A — build-charts-from-signals.rb writes <workdir>/manual-residues.json
#       naming every requires_custom_sql calc a png-read tile (measure string,
#       {"manual_residue": ...} hash, or its worksheet's measure shelf) plots,
#       with formula + OVER() SQL skeleton + status:'unbuilt'; statuses MERGE
#       across re-builds (a 'built' entry never resets).
#   B — assert-phase6-ran gate 15 (exit 22) refuses GREEN on 'unbuilt' entries;
#       --accept-manual-residues waives ONLY named calcs (budget-counted);
#       no ledger file → gate unchanged (back-compat).
#
# Offline + deterministic. Usage: ruby scripts/test-g6-manual-residues.rb

require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/blind_fixture'

# Locale robustness (the gate scripts emit UTF-8 em-dashes).
Encoding.default_external = Encoding::UTF_8

HERE   = __dir__
PARSER = File.join(HERE, 'parse-twb-layout.rb')
BUILD  = File.join(HERE, 'build-charts-from-signals.rb')
GATE   = File.join(HERE, 'assert-phase6-ran.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Minimal .twb (same shape as test-empty-csv-build-from-signals.rb).
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='ORDER_FACT' name='federated.fact'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='snow'><connection class='snowflake' dbname='DEMO_DB' schema='DEMO' /></named-connection>
          </named-connections>
          <relation connection='snow' name='ORDER_FACT' table='[DEMO].[ORDER_FACT]' type='table' />
        </connection>
        <column caption='Gross Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
        <column caption='Order Date ' name='[c2ec6b07-897e-39ab-9422-aa895d35a627]' datatype='date' role='dimension' type='ordinal' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Monthly Revenue Trend'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Gross Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Order Date ' name='[c2ec6b07-897e-39ab-9422-aa895d35a627]' datatype='date' role='dimension' type='ordinal' />
              <column-instance column='[c2ec6b07-897e-39ab-9422-aa895d35a627]' derivation='Month-Trunc' name='[tmn:c2ec6b07-897e-39ab-9422-aa895d35a627:qk]' pivot='key' type='quantitative' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[tmn:c2ec6b07-897e-39ab-9422-aa895d35a627:qk]</cols>
          <pane><mark class='Line' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones><zone id='1' name='Monthly Revenue Trend' x='0' y='0' w='100000' h='100000' /></zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Gross Revenue$' => { 'id' => 'm-gr', 'name' => 'Gross Revenue' },
  '(?i)^Order Date $'   => { 'id' => 'm-od', 'name' => 'Order Date ' },
  '(?i)^Order Date$'    => { 'id' => 'm-od', 'name' => 'Order Date ' }
}.freeze

# The field-class residue: a window/table-calc chain with a STAYS-MANUAL fn.
RESIDUE_FORMULA = '1+(ZN(SUM([Gross Revenue]))-LOOKUP(ZN(SUM([Gross Revenue])),FIRST()))' \
                  '/ABS(LOOKUP(ZN(SUM([Gross Revenue])),FIRST()))'

def stage_workdir(d, png_measure:)
  File.write(File.join(d, 'wb.twb'), TWB)
  File.write(File.join(d, 'master-map.json'), JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Monthly Revenue Trend' }] }))
  Dir.mkdir(File.join(d, 'views')) unless Dir.exist?(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  File.write(File.join(d, 'png-read.json'),
             JSON.dump('source_png' => 'views/v1.png',
                       'tiles' => [{ 'title' => 'Monthly Revenue Trend', 'kind' => 'line-chart',
                                     'measure' => png_measure }],
                       'text_elements' => [], 'filter_shelf' => []))
  # Phase 1e artifact: one MANUAL residue + one auto-translated calc (control).
  File.write(File.join(d, 'calc-fields.json'), JSON.dump(
    'calcs' => [
      { 'name' => 'Growth Index', 'formula' => RESIDUE_FORMULA, 'requires_custom_sql' => true },
      { 'name' => 'Plain Ratio', 'formula' => 'SUM([Gross Revenue])/2', 'requires_custom_sql' => false }
    ]))
end

def run_build(d)
  lay = File.join(d, 'layout.json')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, File.join(d, 'wb.twb'), lay, out: File::NULL, err: File::NULL)
  out = File.join(d, 'specs.json')
  log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
                  '--meta', lay.sub(/\.json$/, '-meta.json'),
                  '--master-map', File.join(d, 'master-map.json'),
                  '--master-element-id', 'master', '--out', out],
                 err: %i[child out], &:read)
  [log, File.join(d, 'manual-residues.json')]
end

puts 'Part A — build-time ledger (manual-residues.json)'
Dir.mktmpdir do |d|
  stage_workdir(d, png_measure: { 'manual_residue' => 'Growth Index' })
  log, ledger = run_build(d)
  check(File.exist?(ledger), 'manual-residues.json written when a tile declares a residue measure', fails)
  doc = File.exist?(ledger) ? JSON.parse(File.read(ledger)) : {}
  res = Array(doc['residues'])
  check(res.length == 1, "exactly the plotted residue is listed (got #{res.length})", fails)
  e = res.first || {}
  check(e['calc'] == 'Growth Index' && e['tile'] == 'Monthly Revenue Trend' && e['status'] == 'unbuilt',
        'entry carries {calc, tile, status:unbuilt}', fails)
  check(e['formula'] == RESIDUE_FORMULA, 'entry carries the Tableau formula verbatim', fails)
  check(e['suggested_sql'].to_s.include?('OVER (PARTITION BY') && e['suggested_sql'].to_s.include?('FIRST_VALUE'),
        'suggested_sql is an OVER() skeleton naming the ANSI mapping for FIRST', fails)
  check(log.include?('manual-residues:') && log.include?('unbuilt'),
        'build log announces the unbuilt residue count', fails)

  # status MERGE: mark built, re-run the build, status must survive.
  doc['residues'][0]['status'] = 'built'
  File.write(ledger, JSON.pretty_generate(doc))
  run_build(d)
  doc2 = JSON.parse(File.read(ledger))
  check(doc2['residues'][0]['status'] == 'built', "re-build preserves status:'built' (got #{doc2['residues'][0]['status']})", fails)
end

Dir.mktmpdir do |d|
  # string measure form + worksheet-declared residue (measure shelf carries the
  # calc under its internal Calculation_ name; the caption resolves via the
  # worksheet calculations list).
  stage_workdir(d, png_measure: 'Growth Index')
  lay = File.join(d, 'layout.json')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, File.join(d, 'wb.twb'), lay, out: File::NULL, err: File::NULL)
  meta_path = lay.sub(/\.json$/, '-meta.json')
  meta = JSON.parse(File.read(meta_path))
  ws = (meta['worksheets'] ||= {})['Monthly Revenue Trend'] ||= {}
  ws['calculations'] = [{ 'name' => '[Calculation_543]', 'caption' => 'Growth Index', 'formula' => RESIDUE_FORMULA }]
  ws['measures'] = [{ 'column' => '[Calculation_543]', 'derivation' => 'User' }]
  File.write(meta_path, JSON.pretty_generate(meta))
  # png tile now declares NO measure — only the worksheet shelf names the residue.
  pr = JSON.parse(File.read(File.join(d, 'png-read.json')))
  pr['tiles'][0].delete('measure')
  File.write(File.join(d, 'png-read.json'), JSON.pretty_generate(pr))
  out = File.join(d, 'specs.json')
  IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', meta_path,
            '--master-map', File.join(d, 'master-map.json'),
            '--master-element-id', 'master', '--out', out], err: %i[child out], &:read)
  doc = (JSON.parse(File.read(File.join(d, 'manual-residues.json'))) rescue {})
  res = Array(doc['residues'])
  check(res.any? { |e| e['calc'] == 'Growth Index' && e['tile'] == 'Monthly Revenue Trend' },
        'worksheet measure-shelf declaration (Calculation_ name -> caption) is picked up', fails)
end

Dir.mktmpdir do |d|
  # No residue plotted anywhere -> no ledger file (back-compat default).
  stage_workdir(d, png_measure: 'Gross Revenue')
  _log, ledger = run_build(d)
  check(!File.exist?(ledger), 'no plotted residue -> no manual-residues.json written', fails)
end

puts
puts 'Part B — assert-phase6-ran gate 15 (exit 22) + --accept-manual-residues'
def base_workdir(dir)
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => %w[KPI Trend], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass',
             'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass',
                                    'composition_match' => 'pass', 'chart_shapes_match' => 'pass',
                                    'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
             'agent_vision' => true }
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  BlindFixture.install(dir) # PR-9: gate 8b refuses a self-attested visual pass
end

def run_gate(dir, *args)
  env = { 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }
  Open3.capture3(env, RbConfig.ruby, GATE, '--workdir', dir, *args)
end

def write_ledger(dir, entries)
  File.write(File.join(dir, 'manual-residues.json'),
             JSON.pretty_generate('version' => 1, 'residues' => entries))
end

UNBUILT = { 'calc' => 'Growth Index', 'formula' => RESIDUE_FORMULA,
            'tile' => 'Monthly Revenue Trend', 'suggested_sql' => '-- ...', 'status' => 'unbuilt' }.freeze

Dir.mktmpdir do |d|
  base_workdir(d)
  out, _err, st = run_gate(d)
  check(st.success?, "no ledger file -> gate unchanged, exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('gate 15') && out.include?('no manual-residues.json'),
        'gate 15 states its OK (never silent)', fails)
end

Dir.mktmpdir do |d|
  base_workdir(d)
  write_ledger(d, [UNBUILT.dup])
  _out, err, st = run_gate(d)
  check(st.exitstatus == 22, "unbuilt residue -> exit 22 (got #{st.exitstatus})", fails)
  check(err.include?('Growth Index') && err.include?('Monthly Revenue Trend'),
        'failure names the residue calc AND its tile', fails)
  check(err.include?('MAGNITUDE PROXY'), 'failure says what is wrong with the shipped tile', fails)
  check(err.include?('--accept-manual-residues'), 'failure names the escape hatch', fails)
end

Dir.mktmpdir do |d|
  base_workdir(d)
  write_ledger(d, [UNBUILT.merge('status' => 'built')])
  out, _err, st = run_gate(d)
  check(st.success?, "built residue -> exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('gate 15') && out.include?('1 built'), 'gate 15 OK line counts built residues', fails)
end

Dir.mktmpdir do |d|
  base_workdir(d)
  write_ledger(d, [UNBUILT.dup])
  out, _err, st = run_gate(d, '--accept-manual-residues', 'Growth Index')
  check(st.success?, "--accept-manual-residues names the calc -> exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('WAIVED'), 'accepted residue is stated loudly (record_waiver pattern)', fails)
  waivers = JSON.parse(File.read(File.join(d, 'waivers.json'))) rescue []
  check(waivers.any? { |w| w['flag'] == '--accept-manual-residues' && w['reason'].to_s.include?('Growth Index') },
        'waiver lands in waivers.json naming the accepted calc', fails)
  pf = JSON.parse(File.read(File.join(d, 'parity-final.json')))
  check(pf['waivers'].include?('--accept-manual-residues') && pf['waiver_count'] == 1,
        'waiver counted + stamped into parity-final.json (budget-counted)', fails)
end

Dir.mktmpdir do |d|
  base_workdir(d)
  write_ledger(d, [UNBUILT.dup])
  _out, err, st = run_gate(d, '--accept-manual-residues', 'Some Other Calc')
  check(st.exitstatus == 22, "accept list naming a DIFFERENT calc does not waive -> exit 22 (got #{st.exitstatus})", fails)
  check(err.include?('Growth Index'), 'the unwaived residue is still named', fails)
end

Dir.mktmpdir do |d|
  base_workdir(d)
  File.write(File.join(d, 'manual-residues.json'), '{"residues": "nope"}')
  _out, err, st = run_gate(d)
  check(st.exitstatus == 22 && err.include?('malformed'), 'malformed ledger fails closed (exit 22)', fails)
end

Dir.mktmpdir do |d|
  # budget: the accept flag is a QUALITY waiver — 2 more tips the run to exit 19.
  base_workdir(d)
  write_ledger(d, [UNBUILT.dup])
  _out, err, st = run_gate(d, '--accept-manual-residues', 'Growth Index',
                           '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2')
  check(st.exitstatus == 19, "accept-manual-residues + 2 waivers -> budget exceeded, exit 19 (got #{st.exitstatus})", fails)
  check(err.include?('--accept-manual-residues') && err.include?('magnitude proxy'),
        'cap message names the flag and what it hid', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — manual-residues ledger + gate 15 build-it gate'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
