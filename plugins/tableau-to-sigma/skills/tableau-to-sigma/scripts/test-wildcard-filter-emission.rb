#!/usr/bin/env ruby
# Regression test for WILDCARD quick filters (V5.6 audit D5 / P0.6).
#
# Tableau compiles the Wildcard tab pattern box into a `groupfilter
# function='filter'` whose expression is a string-match call
# (CONTAINS/STARTSWITH/ENDSWITH, optionally NOT-negated). The parser used to
# emit `members:[]` and the builder then mislabeled the filter as a source
# "All" filter — a silent data-wrong no-op whose log actively lied.
#
# The fix:
#   - parse-twb-layout → `kind:'wildcard'` + `{mode, pattern}` (Sigma text-mode
#     vocabulary), or `wildcard_unparsed` for unrecognized pattern shapes
#   - build-charts, worksheet filter (no card) → hidden Contains/StartsWith/
#     EndsWith match column + keep element filter
#   - build-charts, shared filter (card) → Sigma TEXT control (mode + value)
#   - unparseable pattern → loud STAYS-MANUAL, and NEVER the "(Tableau 'All')"
#     mislabel
#
# Deterministic + offline + creds-free; neutral fixture names only.
#
# Usage:  ruby scripts/test-wildcard-filter-emission.rb

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
        <column caption='Product' name='[PRODUCT]' datatype='string' role='dimension' />
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Widget Products'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
            <filter class='categorical' column='[federated.x].[none:PRODUCT:nk]'>
              <groupfilter function='filter' expression='CONTAINS([none:PRODUCT:nk],&quot;widget&quot;)'>
                <groupfilter function='level-members' level='[none:PRODUCT:nk]' />
              </groupfilter>
            </filter>
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:PRODUCT:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
      <worksheet name='Odd Pattern'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
            <filter class='categorical' column='[federated.x].[none:PRODUCT:nk]'>
              <groupfilter function='filter' expression='CONTAINS(LOWER([none:PRODUCT:nk]),[none:REGION:nk])'>
                <groupfilter function='level-members' level='[none:PRODUCT:nk]' />
              </groupfilter>
            </filter>
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:PRODUCT:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Widget Products' x='0' y='0' w='50000' h='100000' />
          <zone id='2' name='Odd Pattern' x='50000' y='0' w='50000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
    <shared-view name='sv1'>
      <filter class='categorical' column='[federated.x].[none:PRODUCT:nk]'>
        <groupfilter function='filter' expression='NOT STARTSWITH([none:PRODUCT:nk],&quot;test-&quot;)'>
          <groupfilter function='level-members' level='[none:PRODUCT:nk]' />
        </groupfilter>
      </filter>
    </shared-view>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Product$'       => { 'id' => 'm-product', 'name' => 'Product' },
  '(?i)^Region$'        => { 'id' => 'm-region',  'name' => 'Region' },
  '(?i)^Total Revenue$' => { 'id' => 'm-rev',     'name' => 'Total Revenue' }
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
               { 'id' => 'v1', 'name' => 'Widget Products' },
               { 'id' => 'v2', 'name' => 'Odd Pattern' }
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

# ---- Parser: wildcard kind + parsed pattern ---------------------------------
wf = (meta.dig('worksheets', 'Widget Products', 'filters') || []).first
check(wf && wf['kind'] == 'wildcard' && wf['wildcard'] == { 'mode' => 'contains', 'pattern' => 'widget' },
      "parser → kind:'wildcard' {mode:'contains', pattern:'widget'} (got #{wf.inspect})", fails)
of = (meta.dig('worksheets', 'Odd Pattern', 'filters') || []).first
check(of && of['kind'] == 'wildcard' && of['wildcard'].nil? && of['wildcard_unparsed'].to_s.include?('CONTAINS'),
      "unrecognized pattern shape → kind:'wildcard' + wildcard_unparsed (got #{of.inspect})", fails)
sf = (meta['shared_filters'] || []).first
check(sf && sf['kind'] == 'wildcard' && sf['wildcard'] == { 'mode' => 'does-not-start-with', 'pattern' => 'test-' },
      "shared NOT STARTSWITH → {mode:'does-not-start-with', pattern:'test-'} (got #{sf && sf['wildcard'].inspect})", fails)

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []

# ---- Builder: worksheet wildcard → match column + keep filter ---------------
wel = els.find { |e| e['name'].to_s.casecmp?('Widget Products') }
mcol = wel && (wel['columns'] || []).find { |c| c['formula'].to_s =~ /Contains\(\[Product\], "widget"\)/ }
check(!mcol.nil?, "hidden match column If(Contains([Product], \"widget\")…) added (got #{wel && (wel['columns'] || []).map { |c| c['formula'] }.inspect})", fails)
kf = wel && (wel['filters'] || []).find { |f| f['columnId'] == (mcol && mcol['id']) }
check(kf && kf['kind'] == 'list' && kf['values'] == ['match'],
      "keep filter values:['match'] on the match column (got #{kf.inspect})", fails)

# ---- Builder: unparseable pattern → STAYS-MANUAL, never 'All' ---------------
oel = els.find { |e| e['name'].to_s.casecmp?('Odd Pattern') }
ofilters = oel ? (oel['filters'] || []).reject { |f| f['columnId'].to_s.start_with?('nn-') } : []
check(ofilters.empty?, "unparseable pattern emitted NO element filter (got #{ofilters.inspect})", fails)
check(build_log =~ /STAYS-MANUAL.*pattern expression did not\s+parse/m || build_log =~ /pattern expression did not\s+parse/m,
      'unparseable pattern surfaced as a loud STAYS-MANUAL warning', fails)
check(build_log !~ /Odd Pattern.*Tableau 'All'/,
      "the log never mislabels a wildcard filter as Tableau 'All'", fails)

# ---- Builder: shared wildcard → Sigma text control --------------------------
ctl = els.find { |e| e['kind'] == 'control' && e['controlType'] == 'text' && e['name'].to_s.casecmp?('Product') }
check(!ctl.nil?, 'shared wildcard filter emitted a text control', fails)
check(ctl && ctl['mode'] == 'does-not-start-with' && ctl['value'] == 'test-',
      "text control carries mode:'does-not-start-with' value:'test-' (got mode=#{ctl && ctl['mode'].inspect} value=#{ctl && ctl['value'].inspect})", fails)
check(ctl && ctl['filters'].is_a?(Array) && ctl['filters'].any?,
      'text control carries filter targets', fails)

puts
if fails.empty?
  puts 'ALL PASS — wildcard filters: parsed patterns → text control / match-column filter; unparseable → loud STAYS-MANUAL'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(30).join
  exit 1
end
