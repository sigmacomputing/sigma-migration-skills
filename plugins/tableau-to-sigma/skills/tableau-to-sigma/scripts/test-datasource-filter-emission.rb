#!/usr/bin/env ruby
# Regression test for DATASOURCE-LEVEL + EXTRACT filters (V5.6 audit D2 / P0.2).
#
# Tableau row-scopes a whole datasource with <filter> children of <datasource>
# (Data Source Filters) and of its <extract> (rows dropped at extract time).
# NO code path walked either — the worksheet walk is worksheet-scoped and
# shared filters live in <shared-view> — so every migrated sheet silently
# showed globally excluded rows.
#
# The fix: parse-twb-layout normalizes them (same shapes as worksheet filters,
# incl. the bare `[none:COL:nk]` column refs ds filters use) into a
# `datasource_filters` meta array with datasource + scope provenance;
# build-charts applies each as an element filter on every element sourcing
# that datasource and prints a LOUD summary of what was applied (extract
# filters carry a provenance note).
#
# Deterministic + offline + creds-free; neutral fixture names only.
#
# Usage:  ruby scripts/test-datasource-filter-emission.rb

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
        <column caption='Entity Group' name='[SEGMENT]' datatype='string' role='dimension' />
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
        <filter class='categorical' column='[none:SEGMENT:nk]'>
          <groupfilter function='union'>
            <groupfilter function='member' level='[none:SEGMENT:nk]' member='&quot;Entity Group A&quot;' />
            <groupfilter function='member' level='[none:SEGMENT:nk]' member='&quot;Entity Group B&quot;' />
          </groupfilter>
        </filter>
        <extract count='-1' enabled='true'>
          <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
            <groupfilter function='member' level='[none:REGION:nk]' member='&quot;Region A&quot;' />
          </filter>
        </extract>
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Rev by Region'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:REGION:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
      <worksheet name='Rev by Group'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:SEGMENT:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Rev by Region' x='0' y='0' w='50000' h='100000' />
          <zone id='2' name='Rev by Group' x='50000' y='0' w='50000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Entity Group$'  => { 'id' => 'm-seg',    'name' => 'Entity Group' },
  '(?i)^Region$'        => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Total Revenue$' => { 'id' => 'm-rev',    'name' => 'Total Revenue' }
}

meta = nil
build_out = nil
build_log = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [
               { 'id' => 'v1', 'name' => 'Rev by Region' },
               { 'id' => 'v2', 'name' => 'Rev by Group' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '') # empty → build from .twb signals
  File.write(File.join(d, 'views', 'v2.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  meta = JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
                        '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                        '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                        '--title', 'Dash', '--out', out], err: %i[child out], &:read)
  build_log = build_log.to_s.force_encoding('UTF-8')
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

# ---- Parser: datasource_filters meta section --------------------------------
dsf = meta['datasource_filters'] || []
check(dsf.length == 2, "parser found 2 datasource-level filters (got #{dsf.length})", fails)
seg = dsf.find { |f| f['filter_scope'] == 'datasource' }
check(seg && seg['column_caption'] == 'Entity Group' && seg['members'] == ['Entity Group A', 'Entity Group B'],
      "ds-level categorical filter normalized w/ bare column ref → caption 'Entity Group' + members (got #{seg.inspect})", fails)
check(seg && seg['datasource'] == 'Sales' && seg['datasource_name'] == 'federated.x',
      'ds filter carries datasource provenance (caption + internal name)', fails)
ext = dsf.find { |f| f['filter_scope'] == 'extract' }
check(ext && ext['column_caption'] == 'Region' && ext['members'] == ['Region A'],
      "extract filter normalized → caption 'Region' + members ['Region A'] (got #{ext.inspect})", fails)

# ---- Builder: EVERY built element carries the ds filters --------------------
els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []
charts = els.select { |e| ['Rev by Region', 'Rev by Group'].include?(e['name'].to_s) }
check(charts.length == 2, "both charts built (got #{charts.map { |e| e['name'] }.inspect})", fails)
charts.each do |el|
  flt = el['filters'] || []
  seg_f = flt.find { |f| f['kind'] == 'list' && f['values'] == ['Entity Group A', 'Entity Group B'] }
  check(seg_f && seg_f['mode'] == 'include',
        "'#{el['name']}' carries the ds-level Entity Group include filter (got #{flt.inspect[0..160]})", fails)
  reg_f = flt.find { |f| f['kind'] == 'list' && f['values'] == ['Region A'] }
  check(!reg_f.nil?, "'#{el['name']}' carries the extract-level Region filter", fails)
end

# ---- Loud WARN listing what was applied (+ extract provenance note) ---------
check(build_log =~ /DATASOURCE filter on 'Entity Group'.*applied as an element filter on 2 element/,
      'build log announces the ds filter application with element count', fails)
check(build_log =~ /EXTRACT filter on 'Region'.*applied as an element filter on 2 element/,
      'build log announces the extract filter application', fails)
check(build_log =~ /provenance: Tableau EXTRACT filter/,
      'extract application carries the provenance note', fails)

puts
if fails.empty?
  puts 'ALL PASS — datasource + extract filters parsed into meta and applied to every sourcing element, loudly'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(30).join
  exit 1
end
