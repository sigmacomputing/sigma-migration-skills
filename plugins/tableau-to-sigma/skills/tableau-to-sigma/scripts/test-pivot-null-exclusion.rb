#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof: the "Customers by Cohort Year and Loyalty Tier" pivot export
# carried an extra {Cohort Year: null, Loyalty Tier: null, Customer Id: 0}
# row the Tableau view does not have. Not a grand total (totals were already
# hidden): the master LEFT-joins the customer dimension, so order rows with no
# customer form an all-null pivot group. Round 1 (a hand not-null filter on
# the row dim) exported exactly the 5 source rows. The builder now adds a
# hidden Text(IsNotNull(dim)) include-"true" filter for each pivot axis whose
# Tableau CSV has no null member, and leaves an axis Tableau shows with a Null
# member alone.

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

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Fact' name='federated.f'>
        <column caption='Cohort' datatype='string' name='[Cohort]' role='dimension' type='nominal' />
        <column caption='Tier' datatype='string' name='[Tier]' role='dimension' type='nominal' />
        <column caption='Customer Id' datatype='string' name='[Customer Id]' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Cohorts'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.f'>
              <column caption='Cohort' datatype='string' name='[Cohort]' role='dimension' type='nominal' />
              <column caption='Tier' datatype='string' name='[Tier]' role='dimension' type='nominal' />
              <column caption='Customer Id' datatype='string' name='[Customer Id]' role='dimension' type='nominal' />
              <column-instance column='[Cohort]' derivation='None' name='[none:Cohort:nk]' pivot='key' type='nominal' />
              <column-instance column='[Tier]' derivation='None' name='[none:Tier:nk]' pivot='key' type='nominal' />
              <column-instance column='[Customer Id]' derivation='CountD' name='[ctd:Customer Id:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
            <aggregation value='true' />
          </view>
          <panes><pane><mark class='Text' /><encodings><text column='[federated.f].[ctd:Customer Id:qk]' /></encodings></pane></panes>
          <rows>[federated.f].[none:Cohort:nk]</rows>
          <cols>[federated.f].[none:Tier:nk]</cols>
        </table>
      </worksheet>
    </worksheets>
    <dashboards><dashboard name='D'><zones><zone h='100000' id='1' name='Cohorts' w='100000' x='0' y='0' /></zones></dashboard></dashboards>
  </workbook>
XML

def build(csv)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'workbook-content.twb'), TWB)
    Dir.mkdir(File.join(dir, 'views'))
    File.write(File.join(dir, 'views', 'v1.csv'), csv)
    File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Cohorts' }] }))
    File.write(File.join(dir, 'master-columns.json'), JSON.generate(
      '(?i)^Cohort$' => { 'id' => 'm-c', 'name' => 'Cohort' }, '(?i)^Tier$' => { 'id' => 'm-t', 'name' => 'Tier' },
      '(?i)^Customer Id$' => { 'id' => 'm-id', 'name' => 'Customer Id' }
    ))
    lp = File.join(dir, 'dashboard-layout.json')
    system(RUBY, File.join(DIR, 'parse-twb-layout.rb'), File.join(dir, 'workbook-content.twb'), lp, out: File::NULL, err: File::NULL)
    IO.popen([RUBY, File.join(DIR, 'build-charts-from-signals.rb'), '--tableau-dir', dir, '--layout', lp,
              '--meta', lp.sub(/\.json\z/, '-meta.json'), '--master-map', File.join(dir, 'master-columns.json'),
              '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test', '--page-per-dashboard',
              '--title', 'T', '--out', File.join(dir, 'cs.json')], err: %i[child out], &:read)
    out = JSON.parse(File.read(File.join(dir, 'cs.json')))
    (out['pages'] || []).flat_map { |p| p['elements'] || [] }.find { |e| e['kind'] == 'pivot-table' }
  end
end

def nn_cols(pv)
  Array(pv && pv['filters']).map { |f| Array(pv['columns']).find { |c| c['id'] == f['columnId'] } }.compact
end

puts 'source view has no null member on either axis (the cohort shape)'
pv = build("Cohort,Tier,Distinct count of Customer Id\n2024,Gold,7\n2024,Silver,7\n2025,Gold,1\n")
cols = nn_cols(pv)
ok(cols.map { |c| c['formula'] }.sort == ['Text(IsNotNull([Master/Cohort]))', 'Text(IsNotNull([Master/Tier]))'],
   "one not-null exclusion per axis (#{cols.map { |c| c['formula'] }.inspect})")
ok(Array(pv['filters']).all? { |f| f['kind'] == 'list' && f['values'] == ['true'] && f['mode'] == 'include' }, 'include ["true"] list filters')
ids = cols.map { |c| c['id'] }
ok((ids & (Array(pv['rowsBy']) + Array(pv['columnsBy'])).map { |e| e['columnId'] } & Array(pv['values'])).empty? &&
   (ids & Array(pv['values'])).empty?, 'exclusion columns are hidden (not rows/columns/values)')
ok(pv['totals'] == { 'showGrandTotals' => 'hidden', 'showSubtotals' => 'when-collapsed' }, 'totals stay hidden')

puts 'Tableau shows a Null member on one axis (the Category x Region shape)'
pv = build("Cohort,Tier,Distinct count of Customer Id\n2024,,3\n2024,Gold,7\n")
cols = nn_cols(pv)
ok(cols.map { |c| c['formula'] } == ['Text(IsNotNull([Master/Cohort]))'], "only the axis with no null member is excluded (#{cols.map { |c| c['formula'] }.inspect})")

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
