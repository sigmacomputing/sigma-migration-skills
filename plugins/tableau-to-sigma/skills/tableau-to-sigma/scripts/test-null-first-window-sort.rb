#!/usr/bin/env ruby
# frozen_string_literal: true

# Defect 1b: Tableau sorts NULL dimension members FIRST, Sigma LAST. A running
# sum over a nullable dimension therefore changes value. The builder adds a
# hidden null-first sort key (If(IsNull(dim), "", dim), min, ascending) on the
# axis entry of any element carrying a cumulative/moving/Lag/Lead calc.

require 'json'
require 'rbconfig'
require 'tmpdir'

DIR = __dir__
RUBY = RbConfig.ruby
$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def twb(calc_formula)
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        <datasource caption='Fact' name='federated.ds'>
          <column caption='Region' datatype='string' name='[Region]' role='dimension' type='nominal' />
          <column caption='Segment' datatype='string' name='[Segment]' role='dimension' type='nominal' />
          <column caption='Sales' datatype='real' name='[Sales]' role='measure' type='quantitative' />
          <column caption='Running' datatype='real' name='[Calculation_1]' role='measure' type='quantitative'><calculation class='tableau' formula='#{calc_formula}' /></column>
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='Running Matrix'>
          <table>
            <view>
              <datasource-dependencies datasource='federated.ds'>
                <column caption='Region' datatype='string' name='[Region]' role='dimension' type='nominal' />
                <column caption='Segment' datatype='string' name='[Segment]' role='dimension' type='nominal' />
                <column caption='Sales' datatype='real' name='[Sales]' role='measure' type='quantitative' />
                <column caption='Running' datatype='real' name='[Calculation_1]' role='measure' type='quantitative'><calculation class='tableau' formula='#{calc_formula}' /></column>
                <column-instance column='[Region]' derivation='None' name='[none:Region:nk]' pivot='key' type='nominal' />
                <column-instance column='[Segment]' derivation='None' name='[none:Segment:nk]' pivot='key' type='nominal' />
                <column-instance column='[Calculation_1]' derivation='User' name='[usr:Calculation_1:qk]' pivot='key' type='quantitative'><table-calc ordering-field='[federated.ds].[none:Region:nk]' ordering-type='Field' /></column-instance>
              </datasource-dependencies>
            </view>
            <rows>[federated.ds].[none:Segment:nk]</rows>
            <cols>[federated.ds].[none:Region:nk]</cols>
            <panes><pane><mark class='Square' /><encodings><text column='[federated.ds].[usr:Calculation_1:qk]' /></encodings></pane></panes>
          </table>
        </worksheet>
      </worksheets>
      <dashboards><dashboard name='D'><zones><zone h='100000' id='1' name='Running Matrix' w='100000' x='0' y='0' /></zones></dashboard></dashboards>
    </workbook>
  XML
end

def run(formula)
  out = nil
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'workbook-content.twb'), twb(formula))
    lp = File.join(dir, 'dashboard-layout.json')
    mp = File.join(dir, 'master-columns.json')
    op = File.join(dir, 'chart-specs.json')
    File.write(mp, JSON.generate('(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' },
                                 '(?i)^Segment$' => { 'id' => 'm-segment', 'name' => 'Segment' },
                                 '(?i)^Sales$' => { 'id' => 'm-sales', 'name' => 'Sales' }))
    File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))
    system(RUBY, File.join(DIR, 'parse-twb-layout.rb'), File.join(dir, 'workbook-content.twb'), lp, out: File::NULL, err: File::NULL)
    system(RUBY, File.join(DIR, 'build-charts-from-signals.rb'), '--tableau-dir', dir, '--layout', lp,
           '--meta', lp.sub(/\.json\z/, '-meta.json'), '--master-map', mp, '--master-element-id', 'master',
           '--skip-dashboard-read', 'unit-test', '--title', 'T', '--out', op, out: File::NULL, err: File::NULL)
    out = JSON.parse(File.read(op)) if File.exist?(op)
  end
  els = out.is_a?(Array) ? out : Array(out && out['elements']) + Array(out && out['pages']).flat_map { |p| p['elements'] || [] }
  els.find { |e| e['kind'] == 'pivot-table' }
end

puts 'running sum over Region (columns)'
pv = run('RUNNING_SUM(SUM([Sales]))')
ok(!pv.nil?, 'pivot emitted')
vc = pv && Array(pv['columns']).find { |c| Array(pv['values']).include?(c['id']) }
ok(vc && vc['formula'].to_s.include?('CumulativeSum'), "value is CumulativeSum (got #{vc && vc['formula'].inspect})")
key = pv && Array(pv['columns']).find { |c| c['id'].to_s.end_with?('-nullfirst') }
ok(key && key['formula'] == 'If(IsNull([Master/Region]), "", [Master/Region])', "hidden null-first key emitted (got #{key && key['formula'].inspect})")
reg = pv && Array(pv['columnsBy']).first
ok(reg && reg['sort'] == { 'direction' => 'ascending', 'by' => key && key['id'], 'aggregation' => 'min' },
   "Region axis sorted by the key, ascending, min (got #{reg && reg['sort'].inspect})")
ok(pv && !Array(pv['values']).include?(key && key['id']) && !Array(pv['rowsBy']).any? { |r| r['columnId'] == (key && key['id']) },
   'key is hidden: not a value and not an axis entry')
seg = pv && Array(pv['rowsBy']).first
ok(seg && seg['sort'].nil?, "Segment (rows) untouched (got #{seg && seg['sort'].inspect})")

puts 'directional share: Region headers keep Tableau\'s NULL-first order (live proof)'
pv2 = run('SUM([Sales]) / TOTAL(SUM([Sales]))')
v2 = pv2 && Array(pv2['columns']).find { |c| Array(pv2['values']).include?(c['id']) }
k2 = pv2 && Array(pv2['columns']).find { |c| c['id'].to_s.end_with?('-nullfirst') }
ok(v2 && v2['formula'].to_s =~ /"(row|column)"\)\z/ && k2 && Array(pv2['columnsBy']).first&.dig('sort', 'by') == k2['id'],
   "row-scoped share sorts its Region headers by the null-first key (got #{v2 && v2['formula'].inspect})")

puts 'plain aggregate (no window, no directional share) is left alone'
pv3 = run('SUM([Sales])')
ok(pv3 && Array(pv3['columns']).none? { |c| c['id'].to_s.end_with?('-nullfirst') }, 'no null-first key for a non-order-dependent calc')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
