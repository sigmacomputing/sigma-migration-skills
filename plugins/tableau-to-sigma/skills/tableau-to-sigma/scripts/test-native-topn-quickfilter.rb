#!/usr/bin/env ruby
# Regression test for NATIVE Top-tab quick filters (V5.6 audit D6 / P0.5).
#
# A Tableau "Top" tab filter serializes as `groupfilter function='end'
# end='top' count='N' units='records'` nesting `function='order'
# direction='DESC' expression='SUM([X])'`. normalize_filter used to drop
# end/count/direction entirely (N and DESC gone; the order expression leaked
# into condition_expressions) and the builder had no arm — silent full lists.
#
# The fix:
#   - parse-twb-layout → `topn: {n | count_param, end, direction, units,
#     order_expr}` on the normalized filter (order expr no longer a condition)
#   - build-charts, literal N → the SAME native emission as the RANK-calc path
#     (kind:top-n element filter on a hidden ranked-measure column + sort)
#   - parameter-driven N → RANK-helper + number-control idiom (Rank() column +
#     keep formula referencing the param's control; the top-n control is
#     docs-only and rowCount rejects control refs — live-probed product facts)
#   - untranslatable order expression → named STAYS-MANUAL warning quoting it
#   - shared-path top-N → loud warning naming N + direction + expression
#
# Deterministic + offline + creds-free; neutral fixture names only.
#
# Usage:  ruby scripts/test-native-topn-quickfilter.rb

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

def ws_topn(name, filter_xml)
  <<~XML
    <worksheet name='#{name}'>
      <table>
        <view>
          <datasource-dependencies datasource='federated.x' />
          #{filter_xml}
        </view>
        <rows>[federated.x].[sum:TOTALREV:qk]</rows>
        <cols>[federated.x].[none:REGION:nk]</cols>
        <pane><mark class='Bar' /></pane>
      </table>
    </worksheet>
  XML
end

LITERAL_FILTER = <<~XML
  <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
    <groupfilter function='end' end='top' count='10' units='records'>
      <groupfilter function='order' direction='DESC' expression='SUM([TOTALREV])'>
        <groupfilter function='level-members' level='[none:REGION:nk]' />
      </groupfilter>
    </groupfilter>
  </filter>
XML

PARAM_FILTER = <<~XML
  <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
    <groupfilter function='end' end='top' count='[Parameters].[Parameter 7]' units='records'>
      <groupfilter function='order' direction='DESC' expression='SUM([TOTALREV])'>
        <groupfilter function='level-members' level='[none:REGION:nk]' />
      </groupfilter>
    </groupfilter>
  </filter>
XML

LOD_FILTER = <<~XML
  <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
    <groupfilter function='end' end='top' count='5' units='records'>
      <groupfilter function='order' direction='DESC' expression='SUM({exclude [SEGMENT]: SUM([TOTALREV])})'>
        <groupfilter function='level-members' level='[none:REGION:nk]' />
      </groupfilter>
    </groupfilter>
  </filter>
XML

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Params' name='Parameters'>
        <column param-domain-type='any' caption='Top Region Count' name='[Parameter 7]' datatype='integer' value='5' />
      </datasource>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Entity Group' name='[SEGMENT]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      #{ws_topn('Top Regions', LITERAL_FILTER)}
      #{ws_topn('Top Regions Param', PARAM_FILTER)}
      #{ws_topn('Top Regions LOD', LOD_FILTER)}
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Top Regions' x='0' y='0' w='33000' h='100000' />
          <zone id='2' name='Top Regions Param' x='33000' y='0' w='33000' h='100000' />
          <zone id='3' name='Top Regions LOD' x='66000' y='0' w='34000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
    <shared-view name='sv1'>
      #{LITERAL_FILTER}
    </shared-view>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Region$'        => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Entity Group$'  => { 'id' => 'm-seg',    'name' => 'Entity Group' },
  '(?i)^TOTALREV$|^Total Revenue$' => { 'id' => 'm-rev', 'name' => 'Total Revenue' }
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
               { 'id' => 'v1', 'name' => 'Top Regions' },
               { 'id' => 'v2', 'name' => 'Top Regions Param' },
               { 'id' => 'v3', 'name' => 'Top Regions LOD' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  %w[v1 v2 v3].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
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

# ---- Parser: topn facts captured, order expr NOT a condition ----------------
tf = (meta.dig('worksheets', 'Top Regions', 'filters') || []).first
check(tf && tf['topn'] == { 'end' => 'top', 'units' => 'records', 'n' => 10,
                            'direction' => 'DESC', 'order_expr' => 'SUM([TOTALREV])' },
      "parser captures topn {n:10, end:top, DESC, order_expr} (got #{tf && tf['topn'].inspect})", fails)
check(tf && tf['condition_expressions'].nil?,
      'the ORDER expression no longer leaks into condition_expressions', fails)
pf = (meta.dig('worksheets', 'Top Regions Param', 'filters') || []).first
check(pf && pf.dig('topn', 'count_param') == '[Parameters].[Parameter 7]' && pf.dig('topn', 'n').nil?,
      "param-driven count captured as count_param (got #{pf && pf['topn'].inspect})", fails)

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []

# ---- Literal N → native Sigma top-n element filter --------------------------
lit = els.find { |e| e['name'].to_s.casecmp?('Top Regions') }
tn = lit && (lit['filters'] || []).find { |f| f['kind'] == 'top-n' }
check(tn && tn['rowCount'] == 10 && tn['rankingFunction'] == 'rank' && tn['mode'] == 'top-n',
      "literal top-10 → kind:top-n rowCount:10 rankingFunction:rank (got #{tn.inspect})", fails)
rc = lit && (lit['columns'] || []).find { |c| c['id'] == (tn && tn['columnId']) }
check(rc && rc['formula'].to_s =~ /Sum\(\[Master\/Total Revenue\]\)/i,
      "top-n filter keyed on the translated ranked measure (got #{rc && rc['formula'].inspect})", fails)
srt = lit && lit.dig('xAxis', 'sort')
check(srt && srt['by'] == (tn && tn['columnId']) && srt['direction'] == 'descending',
      "tile sorted descending by the ranked measure (got #{srt.inspect})", fails)

# ---- Param-driven N → Rank helper + number-control wiring -------------------
par = els.find { |e| e['name'].to_s.casecmp?('Top Regions Param') }
rank_col = par && (par['columns'] || []).find { |c| c['formula'].to_s =~ /\ARank\(Sum\(\[Master\/Total Revenue\]\), "desc"\)\z/i }
check(!rank_col.nil?,
      "Rank() helper column added (got #{par && (par['columns'] || []).map { |c| c['formula'] }.inspect[0..200]})", fails)
keep_col = par && (par['columns'] || []).find { |c| c['formula'].to_s.include?('[ctl-param-top-region-count]') }
check(!keep_col.nil?, 'keep column references the parameter number control [ctl-param-top-region-count]', fails)
kf = par && (par['filters'] || []).find { |f| f['columnId'] == (keep_col && keep_col['id']) }
check(kf && kf['values'] == ['keep'],
      "keep filter values:['keep'] wired on the keep column (got #{kf.inspect})", fails)
pctl = els.find { |e| e['kind'] == 'control' && e['controlId'] == 'ctl-param-top-region-count' }
check(pctl && pctl['controlType'] == 'number' && pctl['value'] == 5,
      "parameter emitted as a number control w/ default 5 (got #{pctl && [pctl['controlType'], pctl['value']].inspect})", fails)

# ---- Untranslatable order expr → named STAYS-MANUAL, no filter --------------
lod = els.find { |e| e['name'].to_s.casecmp?('Top Regions LOD') }
lodf = lod ? (lod['filters'] || []).reject { |f| f['columnId'].to_s.start_with?('nn-') } : []
check(lodf.none? { |f| f['kind'] == 'top-n' },
      "LOD order expression → no top-n filter emitted (got #{lodf.inspect})", fails)
check(build_log =~ /Top Regions LOD.*STAYS-MANUAL.*order expression\s+did not translate.*\{exclude \[SEGMENT\]/m,
      'untranslatable order expr → STAYS-MANUAL warning naming the expression', fails)

# ---- Shared top-N → loud warning w/ N + direction + expression --------------
check(build_log =~ /shared quick filter 'Region' is a native Tableau top-N \(N=10, direction=DESC.*ranked by: SUM\(\[TOTALREV\]\)/,
      'shared-path warning names N, direction, and the ranking expression', fails)
check(build_log !~ /Top Regions.*Tableau 'All'/,
      "no top-N tile is mislabeled as Tableau 'All'", fails)

puts
if fails.empty?
  puts 'ALL PASS — native top-N quick filters: literal N → top-n filter; param N → Rank helper + number control; LOD → STAYS-MANUAL'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(30).join
  exit 1
end
