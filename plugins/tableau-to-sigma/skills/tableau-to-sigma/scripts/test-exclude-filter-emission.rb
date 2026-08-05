#!/usr/bin/env ruby
# Regression test for EXCLUDE-mode categorical filters (V5.6 audit D1 / P0.1).
#
# Tableau serializes an exclude filter as a `groupfilter function='except'`
# wrapping (level-members, union(members)) and/or tags the tree
# `user:ui-enumeration='exclusive'`. normalize_filter used to collect the
# member descendants with NO check of that wrapper, so the excluded members
# came out as a plain include list — the migrated dashboard showed EXACTLY the
# rows Tableau hides (data-wrong, silent: non-empty output passes every gate).
#
# The fix threads `exclude: true` from the parser through BOTH consumers:
#   - per-tile element filters   → `mode: 'exclude'` (Sigma list filters
#     support it) with the excluded members as values
#   - shared-filter auto-controls → list control `mode: 'exclude'` SEEDED with
#     the excluded members (an empty values array would show the hidden rows)
# Include-mode filters must stay byte-identical (mode:'include', values:[] on
# the control).
#
# Deterministic + offline + creds-free: synthetic .twb through the ACTUAL
# parser + builder. Neutral fixture names only (Region A/B, TOTALREV).
#
# Usage:  ruby scripts/test-exclude-filter-emission.rb

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
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Excl Sheet'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
            <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
              <groupfilter function='except' user:ui-enumeration='exclusive'>
                <groupfilter function='level-members' level='[none:REGION:nk]' />
                <groupfilter function='union'>
                  <groupfilter function='member' level='[none:REGION:nk]' member='&quot;Region B&quot;' />
                </groupfilter>
              </groupfilter>
            </filter>
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:REGION:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
      <worksheet name='Incl Sheet'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
            <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
              <groupfilter function='union' user:ui-enumeration='inclusive'>
                <groupfilter function='member' level='[none:REGION:nk]' member='&quot;Region A&quot;' />
              </groupfilter>
            </filter>
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:REGION:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
      <worksheet name='Excl Attr Sheet'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
            <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
              <groupfilter function='union' user:ui-enumeration='exclusive'>
                <groupfilter function='member' level='[none:REGION:nk]' member='&quot;Region A&quot;' />
              </groupfilter>
            </filter>
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:REGION:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Excl Sheet' x='0' y='0' w='50000' h='100000' />
          <zone id='2' name='Incl Sheet' x='50000' y='0' w='50000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
    <shared-view name='sv1'>
      <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
        <groupfilter function='except'>
          <groupfilter function='level-members' level='[none:REGION:nk]' />
          <groupfilter function='union'>
            <groupfilter function='member' level='[none:REGION:nk]' member='&quot;Region B&quot;' />
          </groupfilter>
        </groupfilter>
      </filter>
    </shared-view>
  </workbook>
XML

MASTER_MAP = {
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
               { 'id' => 'v1', 'name' => 'Excl Sheet' },
               { 'id' => 'v2', 'name' => 'Incl Sheet' }
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
                        '--auto-controls', '--title', 'Dash', '--out', out],
                       err: %i[child out], &:read)
  build_log = build_log.to_s.force_encoding('UTF-8')
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

# ---- Parser: exclude flag on worksheet + shared filters ---------------------
excl_f = (meta.dig('worksheets', 'Excl Sheet', 'filters') || []).first
check(excl_f && excl_f['exclude'] == true && excl_f['members'] == ['Region B'],
      "parser flags the except-wrapped worksheet filter exclude:true w/ members ['Region B'] (got #{excl_f.inspect})", fails)
incl_f = (meta.dig('worksheets', 'Incl Sheet', 'filters') || []).first
check(incl_f && !incl_f.key?('exclude') && incl_f['members'] == ['Region A'],
      'parser leaves the include filter byte-identical (no exclude key)', fails)
sf = (meta['shared_filters'] || []).first
check(sf && sf['exclude'] == true,
      "parser flags the shared-view except filter exclude:true (got #{sf.inspect})", fails)
# The attr-only serialization (`user:ui-enumeration='exclusive'` with NO
# except wrapper) must also flag — either .twb shape means exclude.
attr_f = (meta.dig('worksheets', 'Excl Attr Sheet', 'filters') || []).first
check(attr_f && attr_f['exclude'] == true,
      "ui-enumeration='exclusive' alone flags exclude:true (got #{attr_f.inspect})", fails)

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []

# ---- Builder: element filter mode:'exclude' (never an inverted include) -----
region_filter = lambda do |el|
  el && (el['filters'] || []).find { |f| f['kind'] == 'list' && f['values'].to_a.any? { |v| v.to_s.start_with?('Region') } }
end
excl_el = els.find { |e| e['name'].to_s.casecmp?('Excl Sheet') }
ef = region_filter.call(excl_el)
check(ef && ef['mode'] == 'exclude' && ef['values'] == ['Region B'],
      "exclude tile → element list filter mode:'exclude' values:['Region B'] (got #{ef.inspect})", fails)
incl_el = els.find { |e| e['name'].to_s.casecmp?('Incl Sheet') }
inf = region_filter.call(incl_el)
check(inf && inf['mode'] == 'include' && inf['values'] == ['Region A'],
      "include tile stays mode:'include' values:['Region A'] (got #{inf.inspect})", fails)

# ---- Builder: auto-control mode:'exclude' seeded with the excluded members --
ctl = els.find { |e| e['kind'] == 'control' && e['name'].to_s.casecmp?('Region') }
check(!ctl.nil?, 'shared exclude filter emitted a Region control', fails)
check(ctl && ctl['mode'] == 'exclude' && ctl['values'] == ['Region B'],
      "control is mode:'exclude' seeded with the excluded members (got mode=#{ctl && ctl['mode'].inspect} values=#{ctl && ctl['values'].inspect})", fails)
check(ctl && ctl['controlType'] == 'list',
      "exclude control is a multi-select list (got #{ctl && ctl['controlType'].inspect})", fails)
check(build_log =~ /EXCLUDE/i, 'builder loudly announces the exclude emission', fails)

puts
if fails.empty?
  puts 'ALL PASS — exclude filters emit mode:exclude (element + control), include path unchanged'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(30).join
  exit 1
end
