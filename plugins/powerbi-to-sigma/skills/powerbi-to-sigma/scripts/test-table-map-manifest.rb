#!/usr/bin/env ruby
# frozen_string_literal: true
# test-table-map-manifest.rb — offline unit test for lib/table_map.rb (the
# --table-map loader/applier behind the non-warehouse-source land-then-repoint
# handoff). NO API, NO creds. Covers: manifest.json auto-detection, plain-map
# back-compat, normalized name↔physical-name matching, full-path repoint from a
# dotted sf_table, and the base-column-formula rewrite.
require 'json'
require 'tmpdir'
require_relative 'lib/table_map'

$fail = 0
def ok(name, cond)
  puts((cond ? "  ok  " : "FAIL  ") + name)
  $fail += 1 unless cond
end

# A converted DM with placeholder warehouse paths (as the converter emits for
# non-warehouse sources): tail = physical-name of the entity, db/schema = defaults.
def dm_fixture
  {
    'pages' => [{
      'elements' => [
        { 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DATABASE SCHEMA SALES_FLOW] },
          'columns' => [{ 'formula' => '[SALES_FLOW/NetAmount]' }, { 'formula' => '[SALES_FLOW/SaleID]' }] },
        { 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DATABASE SCHEMA STORE_LAKE] },
          'columns' => [{ 'formula' => '[STORE_LAKE/StoreName]' }] },
        # an unrelated real warehouse element that must be left untouched
        { 'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC ORDER_FACT] },
          'columns' => [{ 'formula' => '[ORDER_FACT/Amount]' }] },
      ]
    }]
  }
end

def write_json(dir, name, obj)
  p = File.join(dir, name)
  File.write(p, JSON.generate(obj))
  p
end

Dir.mktmpdir do |dir|
  # ── 1. manifest.json shape auto-detected; full-path repoint + formula rewrite ──
  manifest = {
    'dataset' => 'x', 'workspace' => 'y', 'target' => 'DEMO_DB.PBI',
    'tables' => [
      { 'pbi_table' => 'SalesFlow', 'sf_table' => 'DEMO_DB.PBI.SALES_FLOW',
        'columns' => [{ 'pbi' => 'SaleID', 'sf' => 'SALE_ID' }] },
      { 'pbi_table' => 'StoreLake', 'sf_table' => 'DEMO_DB.PBI.STORE_LAKE', 'columns' => [] },
    ]
  }
  mpath = write_json(dir, 'manifest.json', manifest)
  loaded = TableMap.load(mpath)
  ok('manifest shape auto-detected', loaded[:from_manifest] == true)
  ok('manifest -> {name => sf_table} map', loaded[:tmap] == { 'SalesFlow' => 'DEMO_DB.PBI.SALES_FLOW', 'StoreLake' => 'DEMO_DB.PBI.STORE_LAKE' })

  dm = dm_fixture
  applied = TableMap.apply!(dm, loaded[:tmap])
  els = dm['pages'][0]['elements']
  ok('two elements repointed', applied.size == 2)
  ok('normalized match: SalesFlow(name) -> SALES_FLOW(tail)', els[0]['source']['path'] == %w[DEMO_DB PBI SALES_FLOW])
  ok('dotted sf_table repoints WHOLE path (db+schema+table)', els[1]['source']['path'] == %w[DEMO_DB PBI STORE_LAKE])
  ok('base column formula tail rewritten', els[0]['columns'][0]['formula'] == '[SALES_FLOW/NetAmount]')
  ok('unrelated warehouse element untouched', els[2]['source']['path'] == %w[ANALYTICS PUBLIC ORDER_FACT])

  # ── 2. plain map back-compat: bare value swaps only the tail ──
  plain = { 'STORE_LAKE' => 'RETAIL_STORE' }
  ppath = write_json(dir, 'plain.json', plain)
  pl = TableMap.load(ppath)
  ok('plain map NOT flagged as manifest', pl[:from_manifest] == false)
  dm2 = dm_fixture
  ap2 = TableMap.apply!(dm2, pl[:tmap])
  ok('plain map swaps only the tail', dm2['pages'][0]['elements'][1]['source']['path'] == %w[DATABASE SCHEMA RETAIL_STORE])
  ok('plain map: single element remapped', ap2.size == 1)
  ok('plain map: formula rewritten to new tail', dm2['pages'][0]['elements'][1]['columns'][0]['formula'] == '[RETAIL_STORE/StoreName]')

  # ── 3. no-op guard: plain map mapping a tail to itself does nothing ──
  dm3 = dm_fixture
  ap3 = TableMap.apply!(dm3, { 'SALES_FLOW' => 'SALES_FLOW' })
  ok('tail->itself is a no-op', ap3.empty? && dm3['pages'][0]['elements'][0]['source']['path'] == %w[DATABASE SCHEMA SALES_FLOW])
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
