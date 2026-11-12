#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression test: CROSS-TABLE visuals route to the converter's joined "<FACT> View"
# master instead of dropping the measure.
#
# Found live on a Fabric-published model (fact table imported under a FRIENDLY Power BI
# name, "PointOfSale", over the warehouse table F_POINT_OF_SALE; a dim "Product" over
# D_PRODUCT). Every visual binding a dim column AND a fact measure lost its measure:
#
#   [build-workbook] WARN visual ... has no measure on its yAxis
#
# Two defects, both in the master-map migrate-powerbi.rb writes:
#   1. The View re-route compared FRIENDLY master keys ("PointOfSale", "Product")
#      against PHYSICAL names (the View is "F_POINT_OF_SALE View"; its dim columns are
#      suffixed "(D_PRODUCT)"), so no field got a View alt.
#   2. A classic "Sum(PointOfSale.Sales Amount)" binding was synthesized BEFORE the
#      friendly-entity alias pass, so its base ("PointOfSale.Sales Amount") did not
#      exist yet and it was never synthesized at all.
#
# Deterministic + offline: builds the field map through the SAME lib functions
# migrate-powerbi.rb calls (PbiViewRoute / PbiFieldAlts), then runs the ACTUAL
# build-workbook-from-pbir.rb and asserts each bar chart sources the View master and
# carries a measure on its yAxis.
#
# Run: ruby scripts/test-cross-table-view-route.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/pbi_master_key'
require_relative 'lib/pbi_field_alts'
require_relative 'lib/pbi_view_route'

BUILDER = File.join(__dir__, 'build-workbook-from-pbir.rb')
$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def m_expr(physical)
  "let Source = Sql.Database(\"h\", \"DB\"), T = Source{[Name=\"#{physical}\",Kind=\"Table\"]}[Data] in T"
end

# A two-table star as migrate-powerbi.rb sees it after the master loop: the converter
# names elements after the PHYSICAL table, masters are keyed on the PBI table name.
def scenario(fact_pbi, dim_pbi)
  fact_phys = 'F_POINT_OF_SALE'
  dim_phys = 'D_PRODUCT'
  view = "#{fact_phys} View"
  tables = [
    { 'name' => fact_pbi, 'partitions' => [{ 'source' => { 'type' => 'm', 'expression' => m_expr(fact_phys) } }],
      'columns' => [{ 'name' => 'Sales Amount' }, { 'name' => 'Product Key' }] },
    { 'name' => dim_pbi, 'partitions' => [{ 'source' => { 'type' => 'm', 'expression' => m_expr(dim_phys) } }],
      'columns' => [{ 'name' => 'Category' }, { 'name' => 'Product Key' }] }
  ]
  conv_elements = [{ 'name' => fact_phys }, { 'name' => dim_phys }, { 'name' => view }]
  fid = PbiMasterKey.master_id(fact_pbi)
  did = PbiMasterKey.master_id(dim_pbi)
  vid = PbiMasterKey.master_id(view)
  col = ->(n) { { 'id' => "mc-#{n.downcase.gsub(/\W/, '')}", 'name' => n, 'formula' => "[X/#{n}]" } }
  masters = {
    fact_pbi => { 'id' => fid, 'element_id' => 'el-f', 'data_model' => 'dm-x',
                  'columns' => [col['Sales Amount'], col['Product Key']],
                  'metrics' => [{ 'name' => 'Total Sales', 'formula' => 'Sum([Sales Amount])' }] },
    dim_pbi => { 'id' => did, 'element_id' => 'el-d', 'data_model' => 'dm-x',
                 'columns' => [col['Category'], col['Product Key']], 'metrics' => [] },
    view => { 'id' => vid, 'element_id' => 'el-v', 'data_model' => 'dm-x',
              'columns' => [col['Sales Amount'], col['Product Key'],
                            col["Category (#{dim_phys})"], col["Product Key (#{dim_phys})"]],
              'metrics' => [] }
  }
  field_map = {
    "#{fact_phys}.Sales Amount" => { 'master' => fact_pbi, 'ref' => "[#{fid}/Sales Amount]", 'agg' => nil },
    "#{fact_phys}.Product Key" => { 'master' => fact_pbi, 'ref' => "[#{fid}/Product Key]", 'agg' => nil },
    "#{fact_phys}.Total Sales" => { 'master' => fact_pbi, 'ref' => "Sum([#{fid}/Sales Amount])", 'agg' => nil },
    "#{dim_phys}.Category" => { 'master' => dim_pbi, 'ref' => "[#{did}/Category]", 'agg' => nil },
    "#{dim_phys}.Product Key" => { 'master' => dim_pbi, 'ref' => "[#{did}/Product Key]", 'agg' => nil }
  }
  # the same sequence migrate-powerbi.rb runs
  PbiViewRoute.add_view_alts!(field_map, masters, conv_elements, tables)
  PbiViewRoute.add_friendly_aliases!(field_map, PbiMasterKey.physical_to_pbi(tables))
  refs = ["#{dim_pbi}.Category", "#{fact_pbi}.Total Sales", "Sum(#{fact_pbi}.Sales Amount)"]
  PbiFieldAlts.normalize_classic_refs!(field_map, refs)
  { 'masters' => masters, 'fields' => field_map, 'view' => view, 'vid' => vid, 'fid' => fid }
end

def bar(id, title, cat, y)
  { 'visual_id' => id, 'visual_type' => 'barChart', 'sigma_kind' => 'bar', 'title' => title,
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => { 'Category' => [cat], 'Y' => [y] }, 'sort' => nil, 'formats' => {} }
end

def build(sc, fact_pbi, dim_pbi)
  signals = {
    'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
    'pages' => [{ 'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720,
                  'interactions' => [], 'visuals' => [
                    bar('v1', 'Measure by Category', "#{dim_pbi}.Category", "#{fact_pbi}.Total Sales"),
                    bar('v2', 'Sum by Category', "#{dim_pbi}.Category", "Sum(#{fact_pbi}.Sales Amount)")
                  ] }]
  }
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'mmap.json'), JSON.generate(sc.slice('masters', 'fields')))
    File.write(File.join(d, 'sig.json'), JSON.generate(signals))
    wb = File.join(d, 'wb.json')
    _o, err, st = Open3.capture3(RbConfig.ruby, BUILDER, '--signals', File.join(d, 'sig.json'),
                                 '--master-map', File.join(d, 'mmap.json'),
                                 '--data-model', 'dm-x', '--name', 'T',
                                 '--out', wb, '--layout-out', File.join(d, 'l.xml'),
                                 '--coverage-out', File.join(d, 'cov.json'))
    return [nil, err] unless st.success?
    [JSON.parse(File.read(wb)), err]
  end
end

[%w[PointOfSale Product], %w[F_POINT_OF_SALE D_PRODUCT]].each do |fact_pbi, dim_pbi|
  puts "scenario: fact #{fact_pbi} / dim #{dim_pbi}"
  sc = scenario(fact_pbi, dim_pbi)
  view = sc['view']
  %W[#{dim_pbi}.Category #{fact_pbi}.Total\sSales Sum(#{fact_pbi}.Sales\sAmount)].each do |qr|
    fs = sc['fields'][qr]
    check(fs && Array(fs['alts']).any? { |a| a['master'] == view }, "#{qr} has a View alt")
  end
  sum_alt = Array((sc['fields']["Sum(#{fact_pbi}.Sales Amount)"] || {})['alts']).find { |a| a['master'] == view }
  check(sum_alt && sum_alt['ref'] == "Sum([#{sc['vid']}/Sales Amount])",
        "Sum(...) View alt keeps its aggregation (got #{sum_alt && sum_alt['ref'].inspect})")

  spec, err = build(sc, fact_pbi, dim_pbi)
  check(!spec.nil?, "builder succeeds#{spec ? '' : ": #{err.lines.last(3).join}"}")
  next unless spec

  check(!err.include?('has no measure on its yAxis'), 'no "no measure on its yAxis" warning')
  els = spec.dig('document', 'elements') || []
  view_table = els.find { |e| e['kind'] == 'table' && e.dig('source', 'elementId') == 'el-v' }
  ['Measure by Category', 'Sum by Category'].each do |title|
    chart = els.find { |e| e['name'].to_s == title }
    check(chart && chart['kind'] == 'bar-chart', "#{title}: bar chart built")
    next unless chart

    src = chart.dig('source', 'elementId')
    check(view_table && src == view_table['id'], "#{title}: sources the View master (got #{src.inspect})")
    ys = Array(chart.dig('yAxis', 'columnIds') || chart['yAxis'])
    check(!ys.empty?, "#{title}: yAxis carries a measure")
    ycol = (chart['columns'] || []).find { |c| ys.include?(c['id']) }
    check(ycol && ycol['formula'].to_s.include?('Sum('),
          "#{title}: yAxis column is an aggregate (got #{ycol && ycol['formula'].inspect})")
  end
end

puts "scenario: G28 - a field's own parenthetical routes to the View column that keeps it"
%w[DimDate DIM_DATE].each do |dim_phys|
  fact_pbi = 'Sales'
  fact_phys = 'F_SALES'
  view = "#{fact_phys} View"
  tables = [
    { 'name' => fact_pbi, 'partitions' => [{ 'source' => { 'type' => 'm', 'expression' => m_expr(fact_phys) } }],
      'columns' => [{ 'name' => 'Amount' }] },
    { 'name' => 'DimDate', 'partitions' => [{ 'source' => { 'type' => 'm', 'expression' => m_expr(dim_phys) } }],
      'columns' => [{ 'name' => 'Date' }, { 'name' => 'Date (Fiscal Month)' }] }
  ]
  fid = PbiMasterKey.master_id(fact_pbi)
  did = PbiMasterKey.master_id('DimDate')
  vid = PbiMasterKey.master_id(view)
  col = ->(n) { { 'id' => "mc-#{n.downcase.gsub(/\W/, '')}", 'name' => n, 'formula' => "[X/#{n}]" } }
  masters = {
    fact_pbi => { 'id' => fid, 'columns' => [col['Amount']], 'metrics' => [] },
    'DimDate' => { 'id' => did, 'columns' => [col['Date'], col['Date (Fiscal Month)']], 'metrics' => [] },
    view => { 'id' => vid, 'columns' => [col['Amount'], col["Date (#{dim_phys})"], col["Date (Fiscal Month) (#{dim_phys})"]], 'metrics' => [] }
  }
  field_map = {
    'DimDate.Date' => { 'master' => 'DimDate', 'ref' => "[#{did}/Date]", 'agg' => nil },
    'DimDate.Date (Fiscal Month)' => { 'master' => 'DimDate', 'ref' => "[#{did}/Date (Fiscal Month)]", 'agg' => nil }
  }
  PbiViewRoute.add_view_alts!(field_map, masters, [{ 'name' => fact_phys }, { 'name' => dim_phys }, { 'name' => view }], tables)
  alt = ->(qr) { Array(field_map[qr]['alts']).find { |a| a['master'] == view } }
  check(alt.call('DimDate.Date (Fiscal Month)') && alt.call('DimDate.Date (Fiscal Month)')['ref'] == "[#{vid}/Date (Fiscal Month) (#{dim_phys})]",
        "#{dim_phys}: 'Date (Fiscal Month)' routes to its own View column (got #{alt.call('DimDate.Date (Fiscal Month)').inspect})")
  check(alt.call('DimDate.Date') && alt.call('DimDate.Date')['ref'] == "[#{vid}/Date (#{dim_phys})]",
        "#{dim_phys}: plain 'Date' still routes to 'Date (#{dim_phys})'")
end

if $fails.empty?
  puts 'ALL PASS — cross-table visuals route to the joined View master with their measure'
  exit 0
end
puts "FAILURES:\n  - #{$fails.join("\n  - ")}"
exit 1
