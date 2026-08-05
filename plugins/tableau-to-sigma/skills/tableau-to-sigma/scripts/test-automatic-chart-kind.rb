#!/usr/bin/env ruby
# Regression test for "Show Me"-style chart-kind inference on Tableau AUTOMATIC
# worksheets. Before this, any sheet with mark=Automatic was blindly defaulted
# to a bar chart (the #1 first-pass fidelity miss — a time series shipped as
# bars). The parser now infers the kind from the shelf structure:
#   - continuous date dim + measure        → line
#   - measure on BOTH axes (≤1 dim)         → scatter
#   - categorical dim + measure             → bar
# and flags chart_kind_inferred:true so the builder routes it to image
# confirmation (it's a guess, not a declared mark).
#
# Part 2 (PR-10) — KIND PROPAGATION through the ACTUAL builder: a VERIFIED
# per-tile `kind` in png-read.json OVERRIDES the shelf inference for EVERY
# kind (line/area/scatter/pivot — not just bar orientation), with one logged
# line per mismatch; absent png-read (waived read) leaves inference unchanged;
# a tile named in png-read kind_waivers keeps the shelf kind (a recorded
# deliberate substitution). Field failure this closes: corrected kinds in a
# verified png-read.json never reached the built wb-spec — bars shipped where
# the source shows lines.
#
# Deterministic + offline: synthesizes .twb fixtures and runs the ACTUAL
# parse-twb-layout.rb + build-charts-from-signals.rb.
#
# Usage:  ruby scripts/test-automatic-chart-kind.rb

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

def ws(name, rows, cols)
  <<~XML
    <worksheet name='#{name}'>
      <table><view><datasource-dependencies datasource='federated.x' /></view>
        <rows>#{rows}</rows>
        <cols>#{cols}</cols>
        <pane><mark class='Automatic' /></pane>
      </table>
    </worksheet>
  XML
end

GR = '[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' # Gross Revenue (measure)
NP = '[a1111111-0000-0000-0000-000000000001]' # Net Profit (measure)
OD = '[c2ec6b07-897e-39ab-9422-aa895d35a627]' # Order Date (date dim)
RG = '[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' # Region (categorical dim)
CT = '[b2222222-0000-0000-0000-000000000002]' # Category (categorical dim)

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Gross Revenue' name='#{GR}' datatype='real' role='measure' />
        <column caption='Net Profit' name='#{NP}' datatype='real' role='measure' />
        <column caption='Order Date ' name='#{OD}' datatype='date' role='dimension' />
        <column caption='Region' name='#{RG}' datatype='string' role='dimension' />
        <column caption='Category' name='#{CT}' datatype='string' role='dimension' />
      </datasource>
    </datasources>
    <worksheets>
      #{ws('Trend',   "[federated.x].[sum:#{GR[1..-2]}:qk]", "[federated.x].[tmn:#{OD[1..-2]}:qk]")}
      #{ws('ByRegion', "[federated.x].[sum:#{GR[1..-2]}:qk]", "[federated.x].[none:#{RG[1..-2]}:nk]")}
      #{ws('Scatter', "[federated.x].[sum:#{NP[1..-2]}:qk]", "[federated.x].[sum:#{GR[1..-2]}:qk]")}
      #{ws('DetailList', "[federated.x].[none:#{RG[1..-2]}:nk] / [federated.x].[none:#{CT[1..-2]}:nk]", "")}
      #{ws('MultiMeasBar', "[federated.x].[none:#{RG[1..-2]}:nk]", "[Multiple Values]")}
      #{ws('DiscreteMeasTable', "[federated.x].[none:#{RG[1..-2]}:nk] / [federated.x].[sum:#{GR[1..-2]}:nk]", "")}
      #{ws('DiscreteBAN', "[federated.x].[usr:#{GR[1..-2]}:nk:1]", "")}
    </worksheets>
    <dashboards>
      <dashboard name='Dash'><zones>
        <zone id='1' name='Trend' x='0' y='0' w='33000' h='100000' />
        <zone id='2' name='ByRegion' x='33000' y='0' w='33000' h='100000' />
        <zone id='3' name='Scatter' x='66000' y='0' w='34000' h='100000' />
        <zone id='4' name='DetailList' x='0' y='100000' w='50000' h='100000' />
        <zone id='5' name='MultiMeasBar' x='50000' y='100000' w='50000' h='100000' />
        <zone id='6' name='DiscreteMeasTable' x='0' y='200000' w='50000' h='100000' />
        <zone id='7' name='DiscreteBAN' x='50000' y='200000' w='50000' h='100000' />
      </zones></dashboard>
    </dashboards>
  </workbook>
XML

zones = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  zones = JSON.parse(File.read(lay)).flat_map { |dash| dash['zones'] || [] }
end

by_name = (zones || []).each_with_object({}) { |z, h| h[z['caption']] = z if z['caption'] }
def kind(by, name); (by[name] || {})['chart_kind']; end

check(kind(by_name, 'Trend') == 'line',
      "Automatic + date dim + measure → line (got #{kind(by_name, 'Trend').inspect})", fails)
check(kind(by_name, 'ByRegion') == 'bar',
      "Automatic + categorical dim + measure → bar (got #{kind(by_name, 'ByRegion').inspect})", fails)
check(kind(by_name, 'Scatter') == 'scatter',
      "Automatic + measure on both axes → scatter (got #{kind(by_name, 'Scatter').inspect})", fails)
check((by_name['Trend'] || {})['chart_kind_inferred'] == true,
      'inferred-automatic kinds carry chart_kind_inferred:true (→ image confirmation)', fails)
check(kind(by_name, 'DetailList') == 'table',
      "Automatic + dims only, no measure axis → table (got #{kind(by_name, 'DetailList').inspect})", fails)
check(kind(by_name, 'MultiMeasBar') == 'bar',
      "Automatic + dim + [Multiple Values] pill → stays bar, not table (got #{kind(by_name, 'MultiMeasBar').inspect})", fails)
check(kind(by_name, 'DiscreteMeasTable') == 'table',
      "Automatic + dim + DISCRETE measure (nk) on shelf → table, not bar (got #{kind(by_name, 'DiscreteMeasTable').inspect})", fails)
check(kind(by_name, 'DiscreteBAN') == 'kpi',
      "Automatic + zero-dim discrete measure w/ :N instance index → kpi (got #{kind(by_name, 'DiscreteBAN').inspect})", fails)

# ============================================================================
# Part 2 (PR-10) — png-read verified kinds OVERRIDE shelf inference in the
# ACTUAL builder (build-charts-from-signals.rb), for ALL kinds.
# ============================================================================
puts
puts 'Part 2 — builder propagation (png-read verified kind > shelf inference):'

def ws2(name, mark, rows, cols)
  <<~XML
    <worksheet name='#{name}'>
      <table>
        <view>
          <datasource-dependencies datasource='federated.fact'>
            <column caption='Gross Revenue' name='#{GR}' datatype='real' role='measure' type='quantitative' />
            <column caption='Order Date ' name='#{OD}' datatype='date' role='dimension' type='ordinal' />
            <column caption='Region' name='#{RG}' datatype='string' role='dimension' type='nominal' />
            <column caption='Category' name='#{CT}' datatype='string' role='dimension' type='nominal' />
            <column-instance column='#{OD}' derivation='Month-Trunc' name='[tmn:#{OD[1..-2]}:qk]' pivot='key' type='quantitative' />
            <column-instance column='#{GR}' derivation='Sum' name='[sum:#{GR[1..-2]}:qk]' pivot='key' type='quantitative' />
            <column-instance column='#{RG}' derivation='None' name='[none:#{RG[1..-2]}:nk]' pivot='key' type='nominal' />
            <column-instance column='#{CT}' derivation='None' name='[none:#{CT[1..-2]}:nk]' pivot='key' type='nominal' />
          </datasource-dependencies>
        </view>
        <rows>#{rows}</rows>
        <cols>#{cols}</cols>
        <pane><mark class='#{mark}' /></pane>
      </table>
    </worksheet>
  XML
end

# Shelf truth: Rev Trend → line, Region Rev → bar, Cat Rev → bar, Region Pivot → bar.
TWB2 = <<~XML
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
        <column caption='Gross Revenue' name='#{GR}' datatype='real' role='measure' type='quantitative' />
        <column caption='Order Date ' name='#{OD}' datatype='date' role='dimension' type='ordinal' />
        <column caption='Region' name='#{RG}' datatype='string' role='dimension' type='nominal' />
        <column caption='Category' name='#{CT}' datatype='string' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
      #{ws2('Rev Trend', 'Line', "[federated.fact].[sum:#{GR[1..-2]}:qk]", "[federated.fact].[tmn:#{OD[1..-2]}:qk]")}
      #{ws2('Region Rev', 'Bar', "[federated.fact].[sum:#{GR[1..-2]}:qk]", "[federated.fact].[none:#{RG[1..-2]}:nk]")}
      #{ws2('Cat Rev', 'Bar', "[federated.fact].[sum:#{GR[1..-2]}:qk]", "[federated.fact].[none:#{CT[1..-2]}:nk]")}
      #{ws2('Region Pivot', 'Bar', "[federated.fact].[none:#{RG[1..-2]}:nk]", "[federated.fact].[sum:#{GR[1..-2]}:qk]")}
    </worksheets>
    <dashboards>
      <dashboard name='Dash'><zones>
        <zone id='1' name='Rev Trend' x='0' y='0' w='25000' h='100000' />
        <zone id='2' name='Region Rev' x='25000' y='0' w='25000' h='100000' />
        <zone id='3' name='Cat Rev' x='50000' y='0' w='25000' h='100000' />
        <zone id='4' name='Region Pivot' x='75000' y='0' w='25000' h='100000' />
      </zones></dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP2 = {
  '(?i)^Gross Revenue$' => { 'id' => 'm-gr',  'name' => 'Gross Revenue' },
  '(?i)^Order Date $'   => { 'id' => 'm-od',  'name' => 'Order Date ' },
  '(?i)^Order Date$'    => { 'id' => 'm-od',  'name' => 'Order Date ' },
  '(?i)^Region$'        => { 'id' => 'm-reg', 'name' => 'Region' },
  '(?i)^Category$'      => { 'id' => 'm-cat', 'name' => 'Category' }
}.freeze

# One builder run; png_read nil ⇒ delete the file and waive the read gate.
# → [elements(Array), build_log(String)]
def run_build2(png_read)
  els = []
  log = ''
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    lay = File.join(d, 'layout.json')
    mm  = File.join(d, 'master-map.json')
    out = File.join(d, 'specs.json')
    File.write(twb, TWB2)
    File.write(mm, JSON.dump(MASTER_MAP2))
    views = [['v1', 'Rev Trend'], ['v2', 'Region Rev'], ['v3', 'Cat Rev'], ['v4', 'Region Pivot']]
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('views' => { 'view' => views.map { |id, n| { 'id' => id, 'name' => n } } }))
    Dir.mkdir(File.join(d, 'views'))
    views.each { |id, _| File.write(File.join(d, 'views', "#{id}.csv"), '') } # signal-built tiles
    args = []
    if png_read
      File.write(File.join(d, 'png-read.json'), JSON.pretty_generate(png_read))
    else
      args = ['--skip-dashboard-read', 'no PNG available (test)']
    end
    abort 'parse-twb-layout failed (part 2)' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
    log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm, '--master-element-id', 'master', '--out', out, *args], err: %i[child out], &:read)
    if File.exist?(out)
      doc = JSON.parse(File.read(out))
      els = doc.is_a?(Array) ? doc : (doc['elements'] || (doc['pages'] || []).flat_map { |p| p['elements'] || [] })
    end
  end
  [els, log]
end

def el_kind(els, name)
  e = els.find { |x| x['name'].to_s.casecmp?(name) }
  e && e['kind']
end

# --- (a) verified png-read kinds override line/area/scatter/pivot ------------
PNG_OVERRIDE = {
  'verified' => true, 'source_png' => 'views/dash.png',
  'tiles' => [
    { 'title' => 'Rev Trend',    'kind' => 'area-chart' },    # shelf says line
    { 'title' => 'Region Rev',   'kind' => 'line-chart' },    # shelf says bar
    { 'title' => 'Cat Rev',      'kind' => 'scatter-chart' }, # shelf says bar
    { 'title' => 'Region Pivot', 'kind' => 'pivot-table' }    # shelf says bar
  ],
  'text_elements' => [], 'filter_shelf' => []
}.freeze

els_a, log_a = run_build2(PNG_OVERRIDE)
check(el_kind(els_a, 'Rev Trend') == 'area-chart',
      "png-read 'area-chart' overrides shelf-inferred line (got #{el_kind(els_a, 'Rev Trend').inspect})", fails)
check(el_kind(els_a, 'Region Rev') == 'line-chart',
      "png-read 'line-chart' overrides shelf-inferred bar (got #{el_kind(els_a, 'Region Rev').inspect})", fails)
check(el_kind(els_a, 'Cat Rev') == 'scatter-chart',
      "png-read 'scatter-chart' overrides shelf-inferred bar (got #{el_kind(els_a, 'Cat Rev').inspect})", fails)
check(el_kind(els_a, 'Region Pivot') == 'pivot-table',
      "png-read 'pivot-table' overrides shelf-inferred bar → pivot fast path (got #{el_kind(els_a, 'Region Pivot').inspect})", fails)
check(log_a.scan(/\[png-read\].*OVERRIDES shelf-inferred/).length == 4,
      "each override is logged one line (got #{log_a.scan(/\[png-read\]/).length} [png-read] line(s))", fails)

# --- (b) absent png-read (waived read) → shelf inference unchanged -----------
els_b, log_b = run_build2(nil)
check(el_kind(els_b, 'Rev Trend') == 'line-chart',
      "no png-read: shelf-inferred line stands (got #{el_kind(els_b, 'Rev Trend').inspect})", fails)
check(el_kind(els_b, 'Region Rev') == 'bar-chart',
      "no png-read: shelf-inferred bar stands (got #{el_kind(els_b, 'Region Rev').inspect})", fails)
check(el_kind(els_b, 'Region Pivot') == 'bar-chart',
      "no png-read: no phantom pivot promotion (got #{el_kind(els_b, 'Region Pivot').inspect})", fails)
check(!log_b.include?('[png-read]'), 'no png-read: no override lines logged', fails)

# --- (c) kind_waivers: a named tile keeps the shelf kind (recorded substitution)
PNG_WAIVED = {
  'verified' => true, 'source_png' => 'views/dash.png',
  'tiles' => [
    { 'title' => 'Rev Trend',    'kind' => 'area-chart' },
    { 'title' => 'Region Rev',   'kind' => 'line-chart' },
    { 'title' => 'Cat Rev',      'kind' => 'bar-chart', 'orientation' => 'vertical' },
    { 'title' => 'Region Pivot', 'kind' => 'bar-chart', 'orientation' => 'vertical' }
  ],
  'kind_waivers' => [{ 'tile' => 'Region Rev', 'reason' => 'deliberate substitution recorded at read time (test)' }],
  'text_elements' => [], 'filter_shelf' => []
}.freeze

els_c, _log_c = run_build2(PNG_WAIVED)
check(el_kind(els_c, 'Region Rev') == 'bar-chart',
      "kind-waived tile keeps the shelf kind (got #{el_kind(els_c, 'Region Rev').inspect})", fails)
check(el_kind(els_c, 'Rev Trend') == 'area-chart',
      "non-waived tiles still override (got #{el_kind(els_c, 'Rev Trend').inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — Automatic worksheets infer line/bar/scatter from shelves (no blind bar default) + verified png-read kinds propagate through the builder (PR-10)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
