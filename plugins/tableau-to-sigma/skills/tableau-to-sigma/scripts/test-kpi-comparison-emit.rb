#!/usr/bin/env ruby
# End-to-end test for Task 5 KPI-comparison EMIT (build-charts-from-signals.rb).
# test-kpi-comparison-wiring.rb already unit-tests KpiComparisonDetect.detect
# and KpiCard.build directly (require'd in isolation), and the live-verified
# recipe proves the shape works in a real Sigma workbook. But NOTHING drives
# the ACTUAL Tableau build pipeline end-to-end on a multi-measure KPI tile —
# parse-twb-layout.rb's `kpi_tile_measures` enumeration (which reads
# z['measures'], resolves captions via columns_by_guid, and maps them through
# the master-map) is exercised only by hand-built Hashes in the unit test,
# never by real .twb XML. This test closes that gap: an inline .twb with a
# KPI worksheet carrying TWO measures (a value + a prior-year sibling) must
# come out of build_kpi_element with a real `comparisonColumn` — proving the
# detector is actually WIRED to the real Tableau signal path, not just
# reachable in isolation.
#
# Positive case: 'Revenue KPI Multi' — Revenue (value) + "Revenue vs Prior
#   Year" (sibling whose name matches KpiComparisonDetect::COMPARISON_NAME_RE)
#   on the SAME worksheet tile (both column-instances in the view's
#   datasource-dependencies, per how kpi_tile_measures/pick_kpi_measure read
#   z['measures'] — see build-charts-from-signals.rb).
# Negative case: 'Orders KPI Single' — one measure only, on the same
#   dashboard/build run (cheap: no comparisonColumn should be emitted).
#
# Runs the ACTUAL parse-twb-layout.rb + build-charts-from-signals.rb (same
# harness shape as test-kpi-composite-emit.rb — build_kpi_element has many
# internal helper deps, so this drives the whole script rather than
# eval-extracting one def). Deterministic + offline (empty view CSVs; both
# elements are built from .twb signals, not CSV data).
#
# Usage:  ruby scripts/test-kpi-comparison-emit.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='snow'><connection class='snowflake' dbname='DEMO_DB' schema='DEMO' /></named-connection>
          </named-connections>
          <relation connection='snow' name='SALES_FACT' table='[DEMO].[SALES_FACT]' type='table' />
        </connection>
        <column caption='Revenue' name='[REVENUE]' datatype='real' role='measure' type='quantitative' />
        <column caption='Revenue vs Prior Year' name='[REV_PY]' datatype='real' role='measure' type='quantitative' />
        <column caption='Orders' name='[ORDERS]' datatype='real' role='measure' type='quantitative' />
        <!-- Superstore YTD-vs-PYTD pattern: tile shelf carries a TOTAL + two
             sign-split delta ratios; the PRIOR VALUE (PYTD) is a DM column,
             NOT on the tile shelf. -->
        <column caption='TOTAL YTD Sales' name='[TOTAL_YTD_SALES]' datatype='real' role='measure' type='quantitative' />
        <column caption='Sales Change Pos' name='[SALES_CHANGE_POS]' datatype='real' role='measure' type='quantitative' />
        <column caption='Sales Change Neg' name='[SALES_CHANGE_NEG]' datatype='real' role='measure' type='quantitative' />
        <column caption='YTD Sales' name='[YTD_SALES]' datatype='real' role='measure' type='quantitative' />
        <column caption='PYTD Sales' name='[PYTD_SALES]' datatype='real' role='measure' type='quantitative' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Revenue KPI Multi'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='Revenue' name='[REVENUE]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[REVENUE]' derivation='Sum' name='[sum:REVENUE:qk]' pivot='key' type='quantitative' />
            <column caption='Revenue vs Prior Year' name='[REV_PY]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[REV_PY]' derivation='Sum' name='[sum:REV_PY:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <pane>
            <mark class='Text' />
          </pane>
        </table>
      </worksheet>
      <worksheet name='Orders KPI Single'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='Orders' name='[ORDERS]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[ORDERS]' derivation='Sum' name='[sum:ORDERS:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <pane>
            <mark class='Text' />
          </pane>
        </table>
      </worksheet>
      <worksheet name='Sales YTD KPI'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='TOTAL YTD Sales' name='[TOTAL_YTD_SALES]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[TOTAL_YTD_SALES]' derivation='Sum' name='[sum:TOTAL_YTD_SALES:qk]' pivot='key' type='quantitative' />
            <column caption='Sales Change Pos' name='[SALES_CHANGE_POS]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[SALES_CHANGE_POS]' derivation='Sum' name='[sum:SALES_CHANGE_POS:qk]' pivot='key' type='quantitative' />
            <column caption='Sales Change Neg' name='[SALES_CHANGE_NEG]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[SALES_CHANGE_NEG]' derivation='Sum' name='[sum:SALES_CHANGE_NEG:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <pane>
            <mark class='Text' />
          </pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='D'>
        <zones>
          <zone id='1' name='Revenue KPI Multi' x='0' y='0' w='33000' h='100000' />
          <zone id='2' name='Orders KPI Single' x='33000' y='0' w='33000' h='100000' />
          <zone id='3' name='Sales YTD KPI' x='66000' y='0' w='34000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Revenue$'                => { 'id' => 'm-revenue',            'name' => 'Revenue' },
  '(?i)^Revenue vs Prior Year$'  => { 'id' => 'm-revenue-prior-year', 'name' => 'Revenue vs Prior Year' },
  '(?i)^Orders$'                 => { 'id' => 'm-orders',             'name' => 'Orders' },
  # Superstore YTD-vs-PYTD: the tile shelf measure `TOTAL YTD Sales` resolves
  # to the current-period master column `YTD Sales`; the prior VALUE `PYTD
  # Sales` is a master column NOT on any tile shelf (the detector's pool #2).
  '(?i)^TOTAL YTD Sales$'        => { 'id' => 'm-ytd-sales',   'name' => 'YTD Sales' },
  '(?i)^YTD Sales$'              => { 'id' => 'm-ytd-sales',   'name' => 'YTD Sales' },
  '(?i)^PYTD Sales$'             => { 'id' => 'm-pytd-sales',  'name' => 'PYTD Sales' },
  '(?i)^Sales Change Pos$'       => { 'id' => 'm-sales-chg-p', 'name' => 'Sales Change Pos' },
  '(?i)^Sales Change Neg$'       => { 'id' => 'm-sales-chg-n', 'name' => 'Sales Change Neg' }
}

build_out = nil
build_log = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Revenue KPI Multi' },
                                                { 'id' => 'v2', 'name' => 'Orders KPI Single' },
                                                { 'id' => 'v3', 'name' => 'Sales YTD KPI' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  File.write(File.join(d, 'views', 'v2.csv'), '')
  File.write(File.join(d, 'views', 'v3.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
                        '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                        '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                        '--title', 'D', '--out', out], err: %i[child out], &:read)
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []
kpis = els.select { |e| e['kind'] == 'kpi-chart' }
# Internal bookkeeping keys (_worksheet/_dashboard) are stripped before the
# spec is written, so match tiles by their element name instead.
multi  = kpis.find { |e| e.dig('name', 'text') == 'Revenue KPI Multi' }
single = kpis.find { |e| e.dig('name', 'text') == 'Orders KPI Single' }
sales  = kpis.find { |e| e.dig('name', 'text') == 'Sales YTD KPI' }

check(kpis.length == 3, "all three worksheets emitted as kpi-chart elements (got #{kpis.length})", fails)

# --- Positive case: multi-measure tile must wire a REAL comparisonColumn ---
check(!multi.nil?, "'Revenue KPI Multi' emitted as a kpi-chart", fails)
check(multi && multi.dig('value', 'columnId') == 'k-el-kpi-revenue-kpi-multi',
      "value.columnId resolves to the Revenue measure column (got #{multi && multi.dig('value', 'columnId').inspect})", fails)
check(multi && multi['comparisonColumn'].is_a?(Hash),
      'multi-measure KPI carries a comparisonColumn (Task 5 wiring proven end-to-end)', fails)
# The comparison must be a DERIVED, AGGREGATED, source-prefixed column built
# the SAME way as the value column (Sum([Master/…])) — NOT the bare master id.
# Binding a raw row-level prior column against an aggregated current value made
# the delta render blank/wrong; this locks it so a regression can't reintroduce
# the bare id.
cmp_col = multi && (multi['columns'] || []).find { |c| c['id'] == 'kc-el-kpi-revenue-kpi-multi' }
val_col = multi && (multi['columns'] || []).find { |c| c['id'] == 'k-el-kpi-revenue-kpi-multi' }
check(multi && multi.dig('comparisonColumn', 'columnId') == 'kc-el-kpi-revenue-kpi-multi',
      'comparisonColumn.columnId points at the DERIVED aggregated comparison column (kc-…), not the bare master id ' \
      "(got #{multi && multi.dig('comparisonColumn', 'columnId').inspect})", fails)
check(multi && multi.dig('comparisonColumn', 'columnId') != 'm-revenue-prior-year',
      'comparisonColumn.columnId is NOT the bare master id m-revenue-prior-year (the fixed bug)', fails)
check(!cmp_col.nil?, 'the derived comparison column kc-el-kpi-revenue-kpi-multi is present in columns[]', fails)
check(cmp_col && cmp_col['formula'] == 'Sum([Master/Revenue vs Prior Year])',
      "the comparison column carries an aggregated Sum([Master/…]) formula (got #{cmp_col && cmp_col['formula'].inspect})", fails)
check(val_col && val_col['formula'] == 'Sum([Master/Revenue])',
      "the value column carries the parallel Sum([Master/…]) formula (got #{val_col && val_col['formula'].inspect})", fails)
check(cmp_col && val_col && (cmp_col['formula'] =~ /\ASum\(\[Master\/.+\]\)\z/) && (val_col['formula'] =~ /\ASum\(\[Master\/.+\]\)\z/),
      'value and comparison columns share the SAME aggregated shape (delta is Sum(current) - Sum(prior) by construction)', fails)
check(multi && (multi['columns'] || []).none? { |c| c['id'] == 'm-revenue-prior-year' },
      'no bare master-id comparison column leaks into columns[] (regression guard)', fails)
check(multi && multi.dig('comparison', 'display') == 'delta',
      "comparison.display == 'delta' (got #{multi && multi.dig('comparison', 'display').inspect})", fails)

# --- Superstore YTD-vs-PYTD case: value=TOTAL YTD, comparison=PYTD (master) ---
# The tile shelf carries TOTAL YTD Sales + Sales Change Pos + Sales Change Neg.
# The value picker MUST headline the TOTAL YTD (current) measure — never a
# sign-split CHANGE ratio (the cold-migration value-fidelity bug). The prior
# VALUE (PYTD Sales) is NOT on the shelf; it must be auto-wired from the MASTER
# columns, as an aggregated Sum([Master/PYTD …]) built the SAME way as the value.
check(!sales.nil?, "'Sales YTD KPI' emitted as a kpi-chart", fails)
sales_val = sales && (sales['columns'] || []).find { |c| c['id'] == sales.dig('value', 'columnId') }
sales_cmp = sales && (sales['columns'] || []).find { |c| c['id'] == sales.dig('comparisonColumn', 'columnId') }
check(sales_val && sales_val['formula'] == 'Sum([Master/YTD Sales])',
      "value is the current-period TOTAL: Sum([Master/YTD Sales]) (got #{sales_val && sales_val['formula'].inspect})", fails)
check(sales_val && sales_val['formula'] !~ /change/i,
      'the KPI value is NOT a CHANGE/delta ratio (value-picker fix)', fails)
check(sales && sales['comparisonColumn'].is_a?(Hash),
      'Superstore KPI auto-wires a comparisonColumn from the MASTER PYTD column (Fix #1b, pool 2)', fails)
check(sales_cmp && sales_cmp['formula'] == 'Sum([Master/PYTD Sales])',
      "comparison is the prior VALUE, aggregated like the value: Sum([Master/PYTD Sales]) (got #{sales_cmp && sales_cmp['formula'].inspect})", fails)
check(sales && sales.dig('comparisonColumn', 'columnId').to_s.start_with?('kc-'),
      'comparisonColumn points at the DERIVED aggregated column (kc-…), not a bare master id', fails)
check(sales && sales.dig('comparison', 'display') == 'delta',
      "comparison.display == 'delta' (got #{sales && sales.dig('comparison', 'display').inspect})", fails)
check(sales && (sales['columns'] || []).none? { |c| c['formula'].to_s =~ /change/i },
      'no CHANGE/delta measure leaks into the Sales KPI columns[]', fails)

# --- Negative case: single-measure tile must stay single-value ---
check(!single.nil?, "'Orders KPI Single' emitted as a kpi-chart", fails)
check(single && !single.key?('comparisonColumn'),
      'single-measure KPI has NO comparisonColumn (no sibling measure to detect)', fails)
check(single && !single.key?('comparison'),
      'single-measure KPI has NO comparison block either', fails)

puts
if fails.empty?
  puts 'ALL PASS — Task 5 KPI comparison emit proven end-to-end (real .twb → real parser → real builder → comparisonColumn)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- emitted kpi-chart elements ---\n#{JSON.pretty_generate(kpis)}"
  puts "\n--- build log (tail) ---\n#{build_log.to_s.lines.last(20).join}"
  exit 1
end
