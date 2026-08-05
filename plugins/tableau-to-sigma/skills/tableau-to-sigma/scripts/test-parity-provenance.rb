#!/usr/bin/env ruby
# Regression test for PROVENANCE-first parity matching (v5.5, field-verified
# defect on a 29-chart multi-dashboard workbook): auto-parity-plan.rb used to
# back-match Sigma charts → Tableau views by DISPLAY NAME, but display titles
# are NOT unique across dashboards — 5 views got mapped TWICE, 5 views dropped
# (gate-5 FAIL on a correct migration), and worse, tiles were value-checked
# against the WRONG same-titled view (silent wrong-numbers risk).
#
# The fix: build-charts-from-signals.rb emits <tab>/chart-provenance.json
# (element id → Tableau WORKSHEET name, unique per workbook); auto-parity-plan
# consumes it FIRST and only falls back to display-name matching (with a WARN
# + a COLLISION guard) for elements absent from the map.
#
# Fixture (the tester's exact shape, generic names): 2 dashboards; worksheets
# 'A KPI Revenue' (display title "Net Revenue") and 'Net Revenue' (distinct
# worksheets whose charts SHARE a display title), with DIFFERENT values in
# their view CSVs. 'A KPI Revenue' is also reused on the second dashboard to
# exercise namespaced-copy provenance (page-per-dashboard emitter).
#
# Deterministic + offline: runs the ACTUAL parse-twb-layout.rb +
# build-charts-from-signals.rb + auto-parity-plan.rb.
#
# Usage:  ruby scripts/test-parity-provenance.rb

require 'json'
require 'tmpdir'
require_relative 'lib/zone_census'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')
PLAN   = File.join(DIR, 'auto-parity-plan.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

WS_A = 'A KPI Revenue'   # display title "Net Revenue" (a renamed tile)
WS_B = 'Net Revenue'     # a DIFFERENT worksheet literally named "Net Revenue"

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
        <column caption='Region' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='A KPI Revenue'>
        <layout-options>
          <title><formatted-text><run>Net Revenue</run></formatted-text></title>
        </layout-options>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Gross Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Region' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
              <column-instance column='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' derivation='None' name='[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]' pivot='key' type='nominal' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]</cols>
          <pane><mark class='Line' /></pane>
        </table>
      </worksheet>
      <worksheet name='Net Revenue'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Gross Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Region' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
              <column-instance column='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' derivation='None' name='[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]' pivot='key' type='nominal' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]</cols>
          <pane><mark class='Line' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Alpha Overview'>
        <zones><zone id='1' name='A KPI Revenue' x='0' y='0' w='100000' h='100000' /></zones>
      </dashboard>
      <dashboard name='Beta Detail'>
        <zones>
          <zone id='2' name='Net Revenue' x='0' y='0' w='100000' h='50000' />
          <zone id='3' name='A KPI Revenue' x='0' y='50000' w='100000' h='50000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Gross Revenue$' => { 'id' => 'm-gr',  'name' => 'Gross Revenue' },
  '(?i)^Region$'        => { 'id' => 'm-reg', 'name' => 'Region' }
}

# The wrong-view risk case: the two same-titled views have DIFFERENT values.
CSV_A = "Region,Gross Revenue\nEast,100\nWest,150\n"
CSV_B = "Region,Gross Revenue\nEast,200\nWest,250\n"

prov = nil
layout = nil
plan_ok = plan_noprov = plan_miss = nil
log_ok = log_noprov = log_miss = ''
build_log = ''

Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'dashboard-layout.json')   # auto-parity-plan's default lookup path
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => WS_A },
                                               { 'id' => 'v2', 'name' => WS_B }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), CSV_A)
  File.write(File.join(d, 'views', 'v2.csv'), CSV_B)
  File.write(File.join(d, 'png-read.json'),
             JSON.dump('source_png' => 'views/dash.png',
                       'tiles' => [{ 'title' => WS_A, 'kind' => 'line-chart' },
                                   { 'title' => WS_B, 'kind' => 'line-chart' }],
                       'text_elements' => [], 'filter_shelf' => []))

  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  layout = JSON.parse(File.read(lay))

  specs = File.join(d, 'chart-specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
                        '--meta', lay.sub(/\.json$/, '-meta.json'),
                        '--master-map', mm, '--master-element-id', 'master',
                        '--page-per-dashboard', '--out', specs],
                       err: %i[child out], &:read)
  abort "build-charts failed:\n#{build_log}" unless File.exist?(specs)

  pv_path = File.join(d, 'chart-provenance.json')
  prov = File.exist?(pv_path) ? JSON.parse(File.read(pv_path)) : nil

  run_plan = lambda do |out|
    log = IO.popen(['ruby', PLAN, '--tableau', d, '--workbook-spec', specs,
                    '--master-id', 'master', '--out', out],
                   err: %i[child out], &:read)
    [File.exist?(out) ? JSON.parse(File.read(out)) : nil, log]
  end

  # Run 1 — provenance present (the fix).
  plan_ok, log_ok = run_plan.call(File.join(d, 'plan-prov.json'))

  # Run 2 — provenance MISSING one element (hand-added chart): keep the file
  # but drop the WS_B element's entry; it must fall back WITH a warning.
  full = JSON.parse(File.read(pv_path))
  miss_el = (full['elements'] || {}).keys.find { |k| full['elements'][k]['worksheet'] == WS_B }
  partial = { 'version' => 1, 'elements' => full['elements'].reject { |k, _| k == miss_el } }
  File.write(pv_path, JSON.pretty_generate(partial))
  plan_miss, log_miss = run_plan.call(File.join(d, 'plan-miss.json'))

  # Run 3 — provenance ABSENT (pre-fix behavior + the collision warning).
  File.delete(pv_path)
  plan_noprov, log_noprov = run_plan.call(File.join(d, 'plan-noprov.json'))
end

abort 'no provenance-run plan produced' unless plan_ok

puts 'Part A — builder emits chart-provenance.json (element id → worksheet, 1:1)'
els = (prov && prov['elements']) || {}
check(prov.is_a?(Hash) && prov['version'] == 1 && els.is_a?(Hash),
      "chart-provenance.json written with {version, elements} (got #{prov.class})", fails)
ws_by_el = els.transform_values { |v| v['worksheet'] }
check(ws_by_el.values.count(WS_A) == 2 && ws_by_el.values.count(WS_B) == 1,
      "provenance covers both worksheets incl. the namespaced page copy (got #{ws_by_el.inspect})", fails)
check(ws_by_el.keys.uniq.length == ws_by_el.keys.length && !ws_by_el.value?(nil),
      'provenance is keyed by unique element ids, every entry carries a worksheet', fails)
ns_ids = ws_by_el.keys.select { |k| k =~ /beta-detail/ }
check(ns_ids.length == 1 && ws_by_el[ns_ids.first] == WS_A,
      "namespaced duplicate id carries the SAME worksheet (got #{ns_ids.inspect})", fails)

puts 'Part B — plan with provenance: 1:1 chart→own worksheet, zero drops'
charts = plan_ok['charts']
check(charts.length == 3, "all 3 chart elements planned, zero drops (got #{charts.length})", fails)
by_view = charts.group_by { |c| c['tableau_view'] }
check(by_view.keys.sort == [WS_A, WS_B].sort,
      "both distinct views present in the plan (got #{by_view.keys.inspect})", fails)
check(charts.all? { |c| c['matched_via'] == 'provenance' },
      'every chart matched via provenance (no name fallback)', fails)
a_vals = (by_view[WS_A] || []).flat_map { |c| c['expected'] }.map { |r| r[1] }.uniq.sort
b_vals = (by_view[WS_B] || []).flat_map { |c| c['expected'] }.map { |r| r[1] }.uniq.sort
check(a_vals == [100.0, 150.0] && b_vals == [200.0, 250.0],
      "each chart pairs with its OWN view CSV — same-titled views with different values " \
      "validate against their own source (A=#{a_vals.inspect} B=#{b_vals.inspect})", fails)
check(!log_ok.include?('COLLISION'),
      'no COLLISION warning on the provenance path (dup view = legit multi-dashboard copy)', fails)

puts 'Part C — census: 0 unmatched on full-workbook scope=[]'
census = ZoneCensus.tile_census(layout, charts, [])
check(census['zones_unmatched'].zero?,
      "tile census reports 0 unmatched zones (got #{census['zones_unmatched']}: #{census['unmatched_zone_names'].inspect})", fails)
check(census['zones_total'] == 2, "census denominator = 2 unique worksheets (got #{census['zones_total']})", fails)

puts 'Part D — provenance MISS (hand-added chart): warned fallback, others unaffected'
check(log_miss.include?('provenance MISS'),
      'a chart absent from the provenance map triggers the fallback WARNING', fails)
miss_charts = (plan_miss || {})['charts'] || []
check(miss_charts.count { |c| c['matched_via'] == 'provenance' } == 2 &&
      miss_charts.count { |c| c['matched_via'] == 'name-fallback' } == 1,
      'only the missing element falls back; provenance-covered charts stay exact', fails)

puts 'Part E — provenance ABSENT: pre-fix double-map reproduced + COLLISION fires'
np_charts = (plan_noprov || {})['charts'] || []
np_views  = np_charts.map { |c| c['tableau_view'] }.uniq
check(np_views == [WS_A],
      "display-name matching double-maps every chart onto ONE view and DROPS the other " \
      "(the pre-fix defect; got #{np_views.inspect})", fails)
np_b_vals = np_charts.flat_map { |c| c['expected'] }.map { |r| r[1] }.uniq.sort
check(np_b_vals == [100.0, 150.0],
      'the wrong-view risk: without provenance, the Net Revenue chart validates against ' \
      "the OTHER view's values (got #{np_b_vals.inspect})", fails)
check(log_noprov.include?('COLLISION') && log_noprov.include?(WS_B),
      'COLLISION warning fires on the fallback path, naming the other same-titled view', fails)
check(log_noprov.include?('no chart provenance'),
      'absent provenance file is announced loudly (rebuild hint)', fails)

puts
if fails.empty?
  puts 'ALL PASS — provenance-first parity: exact worksheet joins, warned fallback, loud collisions'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(25).join
  puts "\n--- plan log (prov) ---"
  puts log_ok.to_s.lines.last(15).join
  puts "\n--- plan log (noprov) ---"
  puts log_noprov.to_s.lines.last(15).join
  exit 1
end
