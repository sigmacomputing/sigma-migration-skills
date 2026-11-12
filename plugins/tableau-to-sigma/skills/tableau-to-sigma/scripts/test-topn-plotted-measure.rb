#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof regression (PR #940, three rounds): "Top 10 Customers" — a
# horizontal bar of SUM(Net Revenue) by Customer Id with a native Tableau
# top-10 quick filter ranked by that same SUM — first-built as 25 bars at
# ~52% of the source values. With the DM's "Total Net Revenue" metric bound,
# the plotted y column became [Metrics/Total Net Revenue] and no longer
# matched the rank formula Sum([Master/Net Revenue]) textually, so the
# top-n filter landed on a hidden, unplotted helper column; Sigma evaluates
# that below the chart's Customer grouping and trimmed ORDER ROWS instead of
# customers. Retargeting the filter to the plotted y column reproduced the
# source exactly ($10,098 … $8,191). The ranked column must be the plotted
# measure whenever the order expression IS that measure.

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

G_CUST = '0b1c2d3e-0000-4000-8000-00000000c101'
G_REV = '0b1c2d3e-0000-4000-8000-00000000c102'
G_QTY = '0b1c2d3e-0000-4000-8000-00000000c103'
DS = 'federated.vc0000000000000000000002'

def twb(order_field: G_REV, order_dir: 'DESC', end_: 'top')
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
      <datasources>
        <datasource caption='FACT (DB.FACT)+ (New Virtual Connection)' name='#{DS}'>
          <column caption='Customer Id' datatype='string' name='[#{G_CUST}]' role='dimension' type='nominal' />
          <column caption='Net Revenue' datatype='real' name='[#{G_REV}]' role='measure' type='quantitative' />
          <column caption='Quantity' datatype='real' name='[#{G_QTY}]' role='measure' type='quantitative' />
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='Top 10 Customers'>
          <table>
            <view>
              <datasource-dependencies datasource='#{DS}'>
                <column caption='Customer Id' datatype='string' name='[#{G_CUST}]' role='dimension' type='nominal' />
                <column caption='Net Revenue' datatype='real' name='[#{G_REV}]' role='measure' type='quantitative' />
                <column caption='Quantity' datatype='real' name='[#{G_QTY}]' role='measure' type='quantitative' />
                <column-instance column='[#{G_CUST}]' derivation='None' name='[none:#{G_CUST}:nk]' pivot='key' type='nominal' />
                <column-instance column='[#{G_REV}]' derivation='Sum' name='[sum:#{G_REV}:qk]' pivot='key' type='quantitative' />
              </datasource-dependencies>
              <filter class='categorical' column='[#{DS}].[none:#{G_CUST}:nk]'>
                <groupfilter count='10' end='#{end_}' function='end' units='records' user:ui-marker='end' user:ui-top-by-field='true'>
                  <groupfilter direction='#{order_dir}' expression='SUM([#{order_field}])' function='order' user:ui-marker='order'>
                    <groupfilter function='level-members' level='[none:#{G_CUST}:nk]' user:ui-enumeration='all' user:ui-marker='enumerate' />
                  </groupfilter>
                </groupfilter>
              </filter>
              <computed-sort column='[#{DS}].[none:#{G_CUST}:nk]' direction='DESC' using='[#{DS}].[sum:#{G_REV}:qk]' />
              <aggregation value='true' />
            </view>
            <panes><pane><mark class='Bar' /></pane></panes>
            <rows>[#{DS}].[none:#{G_CUST}:nk]</rows>
            <cols>[#{DS}].[sum:#{G_REV}:qk]</cols>
          </table>
        </worksheet>
      </worksheets>
      <dashboards><dashboard name='Customers'><zones><zone h='100000' id='1' name='Top 10 Customers' w='100000' x='0' y='0' /></zones></dashboard></dashboards>
    </workbook>
  XML
end

MASTER_MAP = {
  '(?i)^Customer Id$' => { 'id' => 'm-cust', 'name' => 'Customer Id' },
  '(?i)^Net Revenue$' => { 'id' => 'm-rev', 'name' => 'Net Revenue' },
  '(?i)^Quantity$' => { 'id' => 'm-qty', 'name' => 'Quantity' }
}.freeze
METRICS = [{ 'name' => 'Total Net Revenue', 'formula' => 'Sum([Net Revenue])' },
           { 'name' => 'Total Quantity', 'formula' => 'Sum([Quantity])' }].freeze

def build(xml, metrics: true)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'workbook-content.twb'), xml)
    lp = File.join(dir, 'dashboard-layout.json')
    File.write(File.join(dir, 'master-columns.json'), JSON.generate(MASTER_MAP))
    File.write(File.join(dir, 'metrics.json'), JSON.generate(METRICS))
    File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))
    return nil unless system(RUBY, File.join(DIR, 'parse-twb-layout.rb'), File.join(dir, 'workbook-content.twb'), lp, out: File::NULL, err: File::NULL)

    args = ['--tableau-dir', dir, '--layout', lp, '--meta', lp.sub(/\.json\z/, '-meta.json'),
            '--master-map', File.join(dir, 'master-columns.json'), '--master-element-id', 'master',
            '--skip-dashboard-read', 'unit-test', '--page-per-dashboard', '--title', 'T',
            '--out', File.join(dir, 'chart-specs.json')]
    args += ['--metrics', File.join(dir, 'metrics.json')] if metrics
    log = IO.popen([RUBY, File.join(DIR, 'build-charts-from-signals.rb'), *args], err: %i[child out], &:read)
    warn log.lines.last(3).join unless File.exist?(File.join(dir, 'chart-specs.json'))
    out = JSON.parse(File.read(File.join(dir, 'chart-specs.json')))
    els = out.is_a?(Array) ? out : Array(out['elements']) + Array(out['pages']).flat_map { |p| p['elements'] || [] }
    els.find { |e| e['name'].to_s.include?('Top 10') || e['id'].to_s.include?('top-10') }
  end
end

def topn(el)
  Array(el && el['filters']).find { |f| f['kind'] == 'top-n' }
end

puts 'live-proof shape: SUM(Net Revenue) bar, top 10 by SUM(Net Revenue), DM metric bound'
el = build(twb)
y = el && Array(el.dig('yAxis', 'columnIds')).first
ok(el && el['columns'].find { |c| c['id'] == y }&.dig('formula') == '[Metrics/Total Net Revenue]',
   "plotted measure is the DM metric (#{el && el['columns'].map { |c| c['formula'] }.inspect})")
ok(topn(el) && topn(el)['columnId'] == y, "top-n filter ranks the PLOTTED y column (got #{topn(el)&.dig('columnId').inspect}, y=#{y.inspect})")
ok(el && el['columns'].none? { |c| c['id'].to_s.start_with?('topnq-') },
   'no hidden unplotted rank helper (it trimmed rows: 25 bars at ~52%)')
ok(topn(el) && topn(el)['rowCount'] == 10, 'rowCount 10')

puts 'same shape without DM metrics'
el = build(twb, metrics: false)
y = el && Array(el.dig('yAxis', 'columnIds')).first
ok(topn(el) && topn(el)['columnId'] == y, 'top-n still on y')

puts 'top-N ranked by a DIFFERENT measure keeps its helper (not plotted)'
el = build(twb(order_field: G_QTY))
y = el && Array(el.dig('yAxis', 'columnIds')).first
f = topn(el)
ok(f && f['columnId'] != y, "rank by Quantity is not retargeted to the Net Revenue axis (got #{f&.dig('columnId').inspect})")

puts 'bottom-N keeps the sign-inverted helper'
el = build(twb(end_: 'bottom'))
f = topn(el)
rc = f && el['columns'].find { |c| c['id'] == f['columnId'] }
ok(rc && rc['formula'].to_s.start_with?('-('), "bottom-N ranks -(measure) (got #{rc && rc['formula'].inspect})")

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
