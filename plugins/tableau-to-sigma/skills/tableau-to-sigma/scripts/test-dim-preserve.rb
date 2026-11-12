#!/usr/bin/env ruby
# frozen_string_literal: true

# A+B regression: a dimension member with NO fact rows (Phoenix Outlet / AZ,
# 0 orders) vanished from tiles keyed by a related dimension table, because
# the master is fact-rooted. lib/dim_preserve.rb re-bases such a tile on the
# dimension LEFT-JOINed to the fact, gated on the tile's Tableau view CSV.

require 'json'
require 'tmpdir'
require 'fileutils'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'workbook_code'
require 'dim_preserve'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

FIX = File.expand_path('../../../../../corpus/tableau/dim-unmatched-members', __dir__)

def csv(dir, name, body)
  p = File.join(dir, name)
  File.write(p, body)
  p
end

puts 'CSV evidence'
Dir.mktmpdir do |d|
  ok(DimPreserve.unmatched_member?(csv(d, 'a.csv', "State,Measure Names,Measure Values\nCA,Net Revenue,10\nCA,Orders,1\nAZ,Net Revenue,\nAZ,Orders,0\n")),
     'long Measure Names/Values: a member with every measure blank/0 is unmatched')
  ok(!DimPreserve.unmatched_member?(csv(d, 'b.csv', "State,Measure Names,Measure Values\nCA,Net Revenue,10\nAZ,Net Revenue,0\nAZ,Orders,3\n")),
     'long: one measure 0 but another valued is a matched member')
  ok(DimPreserve.unmatched_member?(csv(d, 'c.csv', "Store Name,Net Revenue,Orders\nAustin,900,9\nPhoenix Outlet,,0\n")),
     'wide: a blank/0 row is unmatched')
  ok(!DimPreserve.unmatched_member?(csv(d, 'd.csv', "Store Name,Net Revenue,Orders\nAustin,900,9\nBoston,100,1\n")),
     'wide: every member valued → nothing to keep')
  ok(DimPreserve.unmatched_member?(csv(d, 'e.csv', "State,Latitude (generated),Longitude (generated),Net Revenue\nAZ,34.2,-111.6,\nCA,36.1,-119.6,5\n")),
     'generated geo columns are not measures (AZ lat/long do not make it matched)')
  ok(DimPreserve.csv_dimensions(File.join(d, 'e.csv')) == ['State'], 'csv_dimensions skips generated and numeric columns')
end

puts 'field / header mapping'
rels = { 'STORE_DIM' => {} }
ok(DimPreserve.dim_field('[Order Fact View/State (STORE_DIM)]', rels) == %w[STORE_DIM State], 'relationship-suffixed master column → [table, field]')
ok(DimPreserve.dim_field('[Order Fact View/Ship Method]', rels).nil?, 'a fact column is not a related-dimension field')
mcols = { 'State (STORE_DIM)' => { 'name' => 'State (STORE_DIM)' } }
ok(DimPreserve.master_column_for('State (STORE_DIM (DB.STORE_DIM))', mcols)&.fetch('name') == 'State (STORE_DIM)',
   'Tableau CSV qualifiers are stripped to find the master column')

puts 'apply! on the corpus fixture'
Dir.mktmpdir do |wd|
  FileUtils.cp_r(File.join(FIX, '.'), wd)
  dm_path = File.join(wd, 'dm-readback.json')
  dm = JSON.parse(File.read(dm_path))
  dm_els = dm['pages'].flat_map { |p| p['elements'] }
  dm_els.find { |e| e['id'] == 'store-tbl' }['columns'] << {
    'id' => 'sd-date', 'name' => 'Store Date', 'formula' => '[STORE_DIM/Store Date]'
  }
  dm_els.find { |e| e['id'] == 'fact-tbl' }['columns'] << {
    'id' => 'fc-store-date', 'name' => 'Order Store Date', 'formula' => '[ORDER_FACT/Store Date]'
  }
  dm_els.find { |e| e['id'] == 'fact-tbl' }['relationships'][0]['keys'] << {
    'sourceColumnId' => 'fc-store-date', 'targetColumnId' => 'sd-date'
  }
  dm_els.find { |e| e['id'] == 'fact-view' }['columns'] << {
    'id' => 'v-date', 'formula' => '[Order Fact/Order Store Date]'
  }
  File.write(dm_path, JSON.pretty_generate(dm))
  load_spec = -> { WorkbookCode.legacy_view(WorkbookCode.canonicalize(JSON.parse(File.read(File.join(wd, 'wb-spec.pre.json'))))) }
  spec = load_spec.call
  res = DimPreserve.apply!(spec, DimPreserve.context(wd))
  ok(res[:built].size == 1 && res[:built][0]['tiles'].sort == %w[el-store-scorecard el-store-state-map],
     "one clone, re-basing exactly the two unmatched-member tiles (#{res[:built].inspect})")
  els = spec['pages'].flat_map { |p| p['elements'] }
  by = els.each_with_object({}) { |e, h| h[e['id']] = e }
  ok(by['el-ship-method-bar'].dig('source', 'elementId') == 'master-stores', 'fact-table dimension tile untouched')
  ok(by['el-store-type-bar'].dig('source', 'elementId') == 'master-stores', 'all-matched related-dimension tile untouched')
  data = spec['pages'].find { |p| p['id'] == 'page-data' }['elements'].map { |e| e['id'] }
  ok(data == %w[master-stores master-stores-keep-store-dim], "clone sits right after its master (#{data})")
  join_keys = by['master-stores-keep-store-dim'].dig('source', 'joins', 0, 'columns')
  ok(join_keys == [{ 'left' => '[Store Key]', 'right' => '[Order Store Key]' },
                   { 'left' => '[Store Date]', 'right' => '[Order Store Date]' }],
     "clone preserves every relationship key (#{join_keys.inspect})")
  ok(by['el-ctl-store-type']['filters'].any? { |f| f.dig('source', 'elementId') == 'master-stores-keep-store-dim' },
     'the master-filtering control also filters the clone')
  ok(by['el-store-state-map']['columns'].none? { |c| c['formula'].include?('[Metrics/') }, 'DM metrics inlined on the re-based tile')

  # A relationship cannot be recreated against the view unless every key is
  # projected by that view.
  dm_els.find { |e| e['id'] == 'fact-view' }['columns'].reject! { |c| c['id'] == 'v-date' }
  File.write(dm_path, JSON.pretty_generate(dm))
  ok(DimPreserve.apply!(load_spec.call, DimPreserve.context(wd))[:built].empty?,
     'no clone when the view does not project every relationship key')

  # all-matched evidence → no clone
  File.write(File.join(wd, 'views', 'v-state-map.csv'), "State,Net Revenue\nCA,10\n")
  File.write(File.join(wd, 'views', 'v-scorecard.csv'), "Store Name,Net Revenue,Orders\nAustin,9,1\n")
  spec2 = load_spec.call
  ok(DimPreserve.apply!(spec2, DimPreserve.context(wd))[:built].empty?, 'no unmatched member in any CSV → spec unchanged')
  # no CSV → no clone (evidence-gated)
  FileUtils.rm_rf(File.join(wd, 'views'))
  ok(DimPreserve.apply!(load_spec.call, DimPreserve.context(wd))[:built].empty?, 'no view CSV → no re-base')
  FileUtils.rm(File.join(wd, 'dm-readback.json'))
  ok(DimPreserve.context(wd).nil?, 'no DM readback → the pass is skipped')
end

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
