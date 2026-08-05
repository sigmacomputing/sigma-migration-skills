#!/usr/bin/env ruby
# encoding: utf-8
# 'index-to-first' idiom detector (calc-flex item 4).
#
# LOOKUP(<agg>, FIRST()) — "value at the pane's first row" — stays in the
# requires_custom_sql bucket (FIRST() is STAYS-MANUAL), but its SQL is fully
# mechanical: aggregate to the pane grain, FIRST_VALUE over the axis order.
# extract-calc-fields.rb now classifies it (manual_subclass: 'index-to-first')
# and emits the ready grouped-helper SQL template in suggested_sql; the
# manual-residues (G6) ledger builder prefers that ready SQL over its generic
# OVER() skeleton, so the build-it checklist carries paste-ready SQL.
#
# Part A drives extract-calc-fields.rb END-TO-END (--source twb, offline) on
# test-fixtures/index-to-first.twb, including the calc-cache round trip.
# Part B locks the ledger integration: a calc record carrying suggested_sql
# flows into manual-residues.json verbatim.
#
# Usage:  ruby scripts/test-index-to-first.rb
require 'json'
require 'tmpdir'
require 'open3'

Encoding.default_external = Encoding::UTF_8

HERE    = __dir__
EXTRACT = File.join(HERE, 'extract-calc-fields.rb')
FIX     = File.join(HERE, 'test-fixtures', 'index-to-first.twb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def run_extract(dir, home)
  out = File.join(dir, 'calc-fields.json')
  env = { 'TABLEAU_TO_SIGMA_HOME' => home }
  stdout, stderr, st = Open3.capture3(env, 'ruby', EXTRACT,
                                      '--workbook-luid', 'fixture-luid',
                                      '--source', 'twb', '--twb', FIX,
                                      '--out', out, '--refresh')
  abort "extract-calc-fields failed: #{stderr}" unless st.success?
  [JSON.parse(File.read(out)), stderr]
end

puts 'Part A — extract-calc-fields e2e (twb path) + cache round trip'
Dir.mktmpdir do |d|
  home = File.join(d, 'home')
  doc, = run_extract(d, home)
  by_name = {}
  (doc['calcs'] || []).each { |c| by_name[c['name']] = c }

  pof = by_name['Pct of First Month']
  gi  = by_name['Growth Index']
  check(!pof.nil? && !gi.nil?, 'fixture calcs extracted', fails)
  check(pof && pof['manual_subclass'] == 'index-to-first',
        'plain LOOKUP(SUM(x), FIRST()) classifies as index-to-first', fails)
  check(gi && gi['manual_subclass'] == 'index-to-first',
        'growth-since-baseline chain (nested ZN(SUM(...)) inner) classifies too', fails)
  check(pof && pof['requires_custom_sql'] == true,
        'subclass stays in the requires_custom_sql (STAYS-MANUAL) bucket', fails)

  sql = pof && pof['suggested_sql'].to_s
  check(sql && sql.include?('FIRST_VALUE(SUM(SALES)) OVER (PARTITION BY <pane dims> ORDER BY <axis dim>)'),
        'suggested_sql carries the concrete FIRST_VALUE window over the translated inner agg', fails)
  check(sql && sql.include?('GROUP BY <pane dims>, <axis dim>'),
        'suggested_sql is the grouped-helper template (aggregate first, window second)', fails)
  check(sql && sql.include?('index-to-first'), 'suggested_sql names the subclass', fails)
  check(pof && pof['translation_notes'].any? { |n| n.include?('AUTO-SQL-TEMPLATE (index-to-first)') },
        'translation note routes the builder to suggested_sql', fails)

  check(by_name['Plain Ratio'] && !by_name['Plain Ratio'].key?('manual_subclass'),
        'plain aggregate does NOT classify', fails)
  check(by_name['Prior Month'] && !by_name['Prior Month'].key?('manual_subclass'),
        'LOOKUP(agg, -1) (offset lookup, AUTO family) does NOT classify', fails)

  # Cache round trip: second run must serve HITs and preserve the new fields.
  doc2, log2 = run_extract(d, home)
  pof2 = (doc2['calcs'] || []).find { |c| c['name'] == 'Pct of First Month' }
  check(log2.include?('hit') && log2 =~ /(\d+) hit/ && Regexp.last_match(1).to_i >= 4,
        "second run serves cache hits (log: #{log2[/calc-cache: [^\n]+/]})", fails)
  check(pof2 && pof2['manual_subclass'] == 'index-to-first' && pof2['suggested_sql'].to_s.include?('FIRST_VALUE'),
        'manual_subclass + suggested_sql survive the calc-cache round trip', fails)
end

puts
puts 'Part B — manual-residues (G6) ledger carries the ready SQL verbatim'
PARSER = File.join(HERE, 'parse-twb-layout.rb')
BUILD  = File.join(HERE, 'build-charts-from-signals.rb')
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
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Trend'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Gross Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
            </datasource-dependencies>
          </view>
          <pane><mark class='Line' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones><zone id='1' name='Trend' x='0' y='0' w='100000' h='100000' /></zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

READY_SQL = "-- index-to-first (auto-translatable subclass): LOOKUP(SUM([Gross Revenue]), FIRST())\n" \
            "SELECT <pane dims>, <axis dim>,\n" \
            "       FIRST_VALUE(SUM(GROSS_REVENUE)) OVER (PARTITION BY <pane dims> ORDER BY <axis dim>) AS \"<calc name>\"\n" \
            'GROUP BY <pane dims>, <axis dim>'

Dir.mktmpdir do |d|
  File.write(File.join(d, 'wb.twb'), TWB)
  File.write(File.join(d, 'master-map.json'),
             JSON.dump('(?i)^Gross Revenue$' => { 'id' => 'm-gr', 'name' => 'Gross Revenue' }))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Trend' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  File.write(File.join(d, 'png-read.json'),
             JSON.dump('source_png' => 'views/v1.png',
                       'tiles' => [{ 'title' => 'Trend', 'kind' => 'line-chart',
                                     'measure' => { 'manual_residue' => 'Baseline Value' } }],
                       'text_elements' => [], 'filter_shelf' => []))
  File.write(File.join(d, 'calc-fields.json'), JSON.dump(
    'calcs' => [
      { 'name' => 'Baseline Value', 'formula' => 'LOOKUP(SUM([Gross Revenue]), FIRST())',
        'requires_custom_sql' => true, 'manual_subclass' => 'index-to-first',
        'suggested_sql' => READY_SQL },
      { 'name' => 'Other Residue', 'formula' => 'WINDOW_MEDIAN(SUM([Gross Revenue]))',
        'requires_custom_sql' => true }
    ]))
  lay = File.join(d, 'layout.json')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, File.join(d, 'wb.twb'), lay, out: File::NULL, err: File::NULL)
  IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
            '--meta', lay.sub(/\.json$/, '-meta.json'),
            '--master-map', File.join(d, 'master-map.json'),
            '--master-element-id', 'master',
            '--out', File.join(d, 'specs.json')], err: %i[child out], &:read)
  ledger_path = File.join(d, 'manual-residues.json')
  check(File.exist?(ledger_path), 'manual-residues.json written', fails)
  entries = File.exist?(ledger_path) ? Array(JSON.parse(File.read(ledger_path))['residues']) : []
  mine = entries.find { |e| e['calc'] == 'Baseline Value' }
  check(!mine.nil?, 'index-to-first residue plotted by the tile is in the ledger', fails)
  check(mine && mine['suggested_sql'] == READY_SQL,
        'ledger suggested_sql is the READY SQL from calc-fields, verbatim (not the generic skeleton)', fails)
end

puts
if fails.empty?
  puts 'test-index-to-first: ALL PASS'
else
  puts "test-index-to-first: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
