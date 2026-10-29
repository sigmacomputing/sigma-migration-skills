#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the Phase 6 hidden-calc-filter machine handoff. The gate in
# auto-parity-plan.rb only accepted a human `status: translated|waived`, so a worksheet
# calc-filter that build-charts-from-signals.rb ALREADY carried onto a Sigma element (a
# search box -> hidden match column + `true` filter, a boolean calc -> element filter)
# still blocked Phase 6 ("N unresolved hidden calc-filter(s)"). Now:
#
#   1. The builder records every calc-filter it carried in <tableau-dir>/carried-calc-filters.json
#      (worksheet caption, calc caption/ref, definition, element id, the Sigma formula/column,
#      mode) — and never one it only warned about.
#   2. auto-parity-plan.rb (the .py twin is covered by test_auto_parity_plan.py) marks a hidden
#      filter `translated` when a ledger entry has the same tile + calc and the SAME definition
#      (changed members/type -> stays unresolved; no ledger -> today's behaviour). phase6-parity.rb
#      re-resolves a REUSED plan through CarriedCalcFilters.resolve_plan!.
#
# Deterministic + offline: runs the real parse-twb-layout.rb + build-charts-from-signals.rb on
# fixtures/leaderboard-fidelity.twb (synthetic) and the real auto-parity-plan.rb.
#
# Usage:  ruby scripts/test-carried-calc-filters.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/carried_calc_filters'

DIR     = __dir__
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
PLAN    = File.join(DIR, 'auto-parity-plan.rb')
FIXTURE = File.join(DIR, 'fixtures', 'leaderboard-fidelity.twb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---------------------------------------------------------------------------------------------
puts 'Part 1 - the builder writes the ledger (real parser + builder on the leaderboard fixture)'

# The fixture's own calc-filter is the Store Lookup search box. Add two more to 'Store Leaderboard
# Mo': a boolean calc the builder CAN translate, and one it cannot (REGEXP_MATCH) -> warned only.
def with_extra_calc_filters(twb)
  start = twb.index("<worksheet name='Store Leaderboard Mo'>") or raise 'fixture changed: worksheet missing'
  stop = twb.index('</worksheet>', start) + '</worksheet>'.length
  ws = twb[start...stop]
  cols = <<~XML
    <column caption='Big Order' datatype='boolean' name='[Calculation_2001]' role='measure' type='nominal'>
      <calculation class='tableau' formula='[NET_REVENUE] &gt; 100' />
    </column>
    <column caption='Odd Store' datatype='boolean' name='[Calculation_2002]' role='measure' type='nominal'>
      <calculation class='tableau' formula="REGEXP_MATCH([STORE_NAME], 'zz')" />
    </column>
  XML
  filters = [2001, 2002].map do |n|
    <<~XML
      <filter class='categorical' column='[federated.lbfid0001].[usr:Calculation_#{n}:nk]'>
        <groupfilter function='member' level='[usr:Calculation_#{n}:nk]' member='true' user:ui-domain='database' user:ui-enumeration='inclusive' user:ui-marker='enumerate' />
      </filter>
    XML
  end.join
  ws = ws.sub("<column-instance column='[STORE_NAME]'") { "#{cols}<column-instance column='[STORE_NAME]'" } or raise 'anchor 1'
  ws = ws.sub('<computed-sort') { "#{filters}<computed-sort" }
  twb[0...start] + ws + twb[stop..-1]
end

CSVS = {
  'Store Leaderboard Mo' => "Store Name,Rank - Mo,Volume Measure - Mo\nHarbor Flagship,1,\"16,920.69\"\nSummit Outlet,2,\"16,372.62\"\n",
  'Store Lookup' => "Blank Lookup,Store Name (group),Rank - Mo,Volume Measure - Mo\n0,East Team,1,\"64,887.9\"\n0,West Team,2,\"44,859.44\"\n"
}.freeze

MMAP = { 'Store Name' => 'STORE_NAME', 'Quantity Ordered' => 'QUANTITY_ORDERED', 'Net Revenue' => 'NET_REVENUE' }
       .each_with_object({}) do |(name, raw), h|
  entry = { 'id' => "m-#{name.downcase.gsub(/\W+/, '-')}", 'name' => name }
  [name, raw].each { |a| h["(?i)^#{Regexp.escape(a)}$"] = entry }
end

run = Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  File.write(twb, with_extra_calc_filters(File.read(FIXTURE, encoding: 'UTF-8')))
  lay = File.join(d, 'dashboard-layout.json')
  Open3.capture2e(RUBY, PARSER, twb, lay)
  views = CSVS.keys.each_with_index.map { |n, i| { 'id' => "v#{i}", 'name' => n } }
  Dir.mkdir(File.join(d, 'views'))
  CSVS.values.each_with_index { |body, i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('workbook' => { 'name' => 'LB', 'hasExtracts' => false }, 'views' => { 'view' => views }))
  File.write(File.join(d, 'master-columns.json'), JSON.dump(MMAP))
  out = File.join(d, 'chart-specs.json')
  log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                            '--meta', File.join(d, 'dashboard-layout-meta.json'),
                            '--master-map', File.join(d, 'master-columns.json'),
                            '--master-element-id', 'master', '--auto-controls', '--page-per-dashboard',
                            '--skip-dashboard-read', 'offline test fixture', '--out', out)
  rd = ->(n) { f = File.join(d, n); File.exist?(f) ? JSON.parse(File.read(f, encoding: 'UTF-8')) : nil }
  specs = rd.call('chart-specs.json')
  pages = specs.is_a?(Hash) ? specs['pages'] : []
  { ok: st.success?, log: log, ledger: rd.call('carried-calc-filters.json'), layout: rd.call('dashboard-layout.json'),
    elements: pages.flat_map { |p| p['elements'] }, provenance: (rd.call('chart-provenance.json') || {})['elements'] || {} }
end

check(run[:ok], "the builder runs clean on the fixture (#{run[:log].lines.grep(/error|FATAL/i).first})", fails)
ledger = run[:ledger]
entries = ledger.is_a?(Hash) ? Array(ledger['entries']) : []
check(ledger.is_a?(Hash) && ledger['version'] == 1, 'carried-calc-filters.json is written next to the other sidecars (version 1)', fails)

search = entries.select { |e| e['mode'] == 'search-filter' }
check(search.size == 2 && search.all? { |e| e['worksheet'] == 'Store Lookup' && e['calc_caption'] == 'Store Rank Search' },
      "the Store Lookup search box is recorded once per page (got #{search.map { |e| [e['dashboard'], e['element_id']] }.inspect})", fails)
check(search.map { |e| e['element_id'] }.uniq.size == 2 && search.all? { |e| run[:elements].any? { |el| el['id'] == e['element_id'] } },
      'each search entry names the FINAL posted element id of its page copy', fails)
check(!search.empty? && search.all? { |e| run[:provenance].dig(e['element_id'], 'worksheet') == 'Store Lookup' },
      'the recorded element ids agree with chart-provenance.json', fails)
s0 = search.first || {}
check(s0['filter_type'] == 'categorical' && s0['members'] == ['true'] && s0['calc_ref'].to_s.include?('Calculation_1005'),
      "the search entry carries the source definition (type/members/calc_ref): #{s0.values_at('filter_type', 'members', 'calc_ref').inspect}", fails)
check(s0['sigma_column'] == 'Store Lookup Match' && s0['sigma_formula'].to_s.start_with?('Text(Contains(Upper('),
      "it records the Sigma column and formula it became (got #{s0['sigma_column'].inspect} / #{s0['sigma_formula'].inspect})", fails)

lay_hf = run[:layout].flat_map { |dsh| dsh['zones'] }.select { |z| z['caption'] == 'Store Lookup' }
                     .flat_map { |z| z['hidden_filters'] }.find { |h| h['caption'] == 'Store Rank Search' } || {}
check(CarriedCalcFilters.same_definition?(s0, lay_hf),
      "the ledger definition equals the layout's hidden_filters definition (so the gate fingerprint matches)", fails)

boolean = entries.select { |e| e['calc_caption'] == 'Big Order' }
check(boolean.size >= 1 && boolean.all? { |e| e['mode'] == 'boolean-calc' && e['worksheet'] == 'Store Leaderboard Mo' && e['members'] == ['true'] },
      "a translated boolean calc filter is recorded as boolean-calc (got #{boolean.inspect})", fails)
check(!boolean.empty? && boolean.all? { |e| e['sigma_formula'].to_s.include?('Net Revenue') && e['sigma_formula'].to_s.include?('> 100') },
      "its entry carries the translated Sigma formula (got #{boolean.first && boolean.first['sigma_formula'].inspect})", fails)
check(entries.none? { |e| e['calc_caption'] == 'Odd Store' } && run[:log].include?("targets 'Odd Store'"),
      'a calc filter the builder could only WARN about (untranslatable) is not recorded', fails)
check(entries.none? { |e| e['calc_caption'] == 'Region - East/West' || e['calc_caption'] == 'Store Name (group)' },
      'filters that were never carried (quick filters at All) are not recorded', fails)

# ---------------------------------------------------------------------------------------------
puts 'Part 2 - auto-parity-plan.rb resolves hidden filters against the ledger'

WB_SPEC = {
  'document' => {
    'pages' => [{ 'id' => 'p1', 'name' => 'Overview' }],
    'elements' => [
      { 'id' => 'master', 'kind' => 'table', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e' },
        'columns' => [{ 'id' => 'm-region', 'name' => 'Region' }, { 'id' => 'm-rev', 'name' => 'Net Revenue' }] },
      { 'id' => 'el-chart', 'kind' => 'bar-chart', 'name' => 'Chart',
        'source' => { 'kind' => 'table', 'elementId' => 'master' },
        'xAxis' => { 'columnId' => 'm-region' }, 'yAxis' => { 'columnIds' => ['m-rev'] },
        'columns' => [{ 'id' => 'm-region', 'name' => 'Region' }, { 'id' => 'm-rev', 'name' => 'Net Revenue' }] }
    ],
    'layout' => '<Page id="p1"><Element elementId="master"/><Element elementId="el-chart"/></Page>'
  }
}.freeze

SEARCH_HF = { 'calc_ref' => '[ds].[usr:Calculation_7:nk]', 'caption' => 'Store Rank Search',
              'filter_type' => 'categorical', 'kind' => 'list', 'members' => ['true'] }.freeze
BOOL_HF = { 'calc_ref' => '[ds].[usr:Calculation_8:nk]', 'caption' => 'Big Order',
            'filter_type' => 'categorical', 'kind' => 'list', 'members' => ['true'] }.freeze

def ledger_entry(hf, mode:, formula:, **over)
  { 'worksheet' => 'Chart', 'dashboard' => 'Overview', 'calc_caption' => hf['caption'], 'calc_ref' => hf['calc_ref'],
    'filter_type' => hf['filter_type'], 'kind' => hf['kind'], 'members' => hf['members'],
    'element_id' => 'el-chart', 'sigma_column' => "#{hf['caption']} Match", 'sigma_formula' => formula, 'mode' => mode }.merge(over)
end

# Runs the real plan builder over a one-tile layout carrying `hidden`; `ledger` nil = no ledger file.
def plan_for(hidden, ledger)
  Dir.mktmpdir do |d|
    File.write("#{d}/wb.json", JSON.dump(WB_SPEC))
    File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Chart' }] }))
    Dir.mkdir("#{d}/views")
    File.write("#{d}/views/v1.csv", "Region,Net Revenue\nWest,100\n")
    File.write("#{d}/dashboard-layout.json", JSON.dump([{
      'dashboard' => 'Overview',
      'zones' => [{ 'kind' => 'chart', 'caption' => 'Chart', 'measures' => ['Net Revenue'], 'hidden_filters' => hidden }]
    }]))
    File.write("#{d}/carried-calc-filters.json", JSON.dump('version' => 1, 'entries' => ledger)) unless ledger.nil?
    o = "#{d}/plan.json"
    log = IO.popen(['ruby', PLAN, '--tableau', d, '--workbook-spec', "#{d}/wb.json",
                    '--master-id', 'master', '--out', o], err: %i[child out], &:read)
    File.exist?(o) ? JSON.parse(File.read(o)) : { 'log' => log }
  end
end

by_cap = ->(plan, cap) { (plan['hidden_filters'] || []).find { |h| h['caption'] == cap } || {} }
srch_formula = 'Text(Contains(Upper([Store Name]), Upper(Coalesce([ctl-param-store-lookup], ""))))'

plan = plan_for([SEARCH_HF], [ledger_entry(SEARCH_HF, mode: 'search-filter', formula: srch_formula)])
h = by_cap.call(plan, 'Store Rank Search')
check(h['status'] == 'translated' && h['translated_to'] == srch_formula && h['note'] == 'carried by build-charts-from-signals.rb',
      "a carried SEARCH filter auto-resolves: status/translated_to/note (got #{h.values_at('status', 'translated_to', 'note').inspect})", fails)
check(plan['plan_status'] == 'green', "...and the plan is green (got #{plan['plan_status'].inspect})", fails)

plan = plan_for([BOOL_HF], [ledger_entry(BOOL_HF, mode: 'boolean-calc', formula: '[Master/Net Revenue] > 100')])
h = by_cap.call(plan, 'Big Order')
check(h['status'] == 'translated' && h['translated_to'] == '[Master/Net Revenue] > 100' && plan['plan_status'] == 'green',
      "a carried BOOLEAN calc filter auto-resolves (got #{h.values_at('status', 'translated_to').inspect}, plan #{plan['plan_status'].inspect})", fails)

plan = plan_for([SEARCH_HF, BOOL_HF], [ledger_entry(SEARCH_HF, mode: 'search-filter', formula: srch_formula)])
check(by_cap.call(plan, 'Store Rank Search')['status'] == 'translated' && by_cap.call(plan, 'Big Order')['status'] == 'unresolved' &&
      plan['plan_status'] == 'needs_review',
      'an UNCARRIED calc filter beside a carried one stays unresolved and keeps the plan at needs_review', fails)

changed = SEARCH_HF.merge('members' => ['false'])
plan = plan_for([changed], [ledger_entry(SEARCH_HF, mode: 'search-filter', formula: srch_formula)])
check(by_cap.call(plan, 'Store Rank Search')['status'] == 'unresolved' && plan['plan_status'] == 'needs_review',
      'a DEFINITION change (members differ from what the builder carried) does NOT auto-resolve', fails)
plan = plan_for([SEARCH_HF.merge('filter_type' => 'quantitative', 'min' => '1')],
                [ledger_entry(SEARCH_HF, mode: 'search-filter', formula: srch_formula)])
check(by_cap.call(plan, 'Store Rank Search')['status'] == 'unresolved', 'a changed filter_type/range does NOT auto-resolve either', fails)

plan = plan_for([SEARCH_HF], nil)
check(by_cap.call(plan, 'Store Rank Search')['status'] == 'unresolved' && plan['plan_status'] == 'needs_review' &&
      by_cap.call(plan, 'Store Rank Search').keys.sort == %w[calc_ref caption filter_type members status tile],
      'a MISSING ledger leaves the entry exactly as before (unresolved, no extra keys)', fails)
plan = plan_for([SEARCH_HF], [])
check(by_cap.call(plan, 'Store Rank Search')['status'] == 'unresolved', 'an empty ledger changes nothing', fails)

plan = plan_for([SEARCH_HF], [ledger_entry(SEARCH_HF, mode: 'search-filter', formula: srch_formula, 'worksheet' => 'Other Tile')])
check(by_cap.call(plan, 'Store Rank Search')['status'] == 'unresolved', "another tile's carry does not resolve this tile", fails)
plan = plan_for([SEARCH_HF], [ledger_entry(SEARCH_HF, mode: 'search-filter', formula: srch_formula, 'dashboard' => 'Elsewhere')])
check(by_cap.call(plan, 'Store Rank Search')['status'] == 'unresolved', "a carry on another dashboard does not resolve this dashboard's tile", fails)
no_ref = SEARCH_HF.reject { |k, _| k == 'calc_ref' }
plan = plan_for([no_ref], [ledger_entry(SEARCH_HF, mode: 'search-filter', formula: srch_formula)])
check(by_cap.call(plan, 'Store Rank Search')['status'] == 'translated', 'tile + calc caption matches when the layout has no calc_ref', fails)

# ---------------------------------------------------------------------------------------------
puts 'Part 3 - a reused plan (phase6-parity.rb) re-resolves through the same rule'

reused = {
  'plan_status' => 'needs_review',
  'hidden_filters' => [
    { 'tile' => 'Chart', 'calc_ref' => SEARCH_HF['calc_ref'], 'caption' => 'Store Rank Search', 'filter_type' => 'categorical',
      'members' => ['true'], 'status' => 'unresolved' },
    { 'tile' => 'Chart', 'calc_ref' => BOOL_HF['calc_ref'], 'caption' => 'Big Order', 'filter_type' => 'categorical',
      'members' => ['true'], 'status' => 'waived', 'waive_reason' => 'operator call' }
  ]
}
led = [ledger_entry(SEARCH_HF, mode: 'search-filter', formula: srch_formula),
       ledger_entry(BOOL_HF, mode: 'boolean-calc', formula: 'x')]
n = CarriedCalcFilters.resolve_plan!(reused, led)
check(n == 1 && reused['hidden_filters'][0]['status'] == 'translated' && reused['plan_status'] == 'green',
      'resolve_plan! translates the unresolved entry and clears needs_review', fails)
check(reused['hidden_filters'][1]['status'] == 'waived' && reused['hidden_filters'][1]['waive_reason'] == 'operator call',
      "an operator's waive is never overwritten by the ledger", fails)
stale = { 'plan_status' => 'needs_review', 'hidden_filters' => [reused['hidden_filters'][0].merge('status' => 'unresolved', 'members' => ['x'])] }
check(CarriedCalcFilters.resolve_plan!(stale, led).zero? && stale['plan_status'] == 'needs_review',
      'a reused entry whose definition no longer matches the ledger stays unresolved', fails)
check(CarriedCalcFilters.resolve_plan!({ 'hidden_filters' => [{ 'tile' => 'Chart', 'status' => 'unresolved' }] }, []).zero? &&
      CarriedCalcFilters.load(File.join(DIR, 'no-such-dir')) == [],
      'no ledger = nothing resolved', fails)

puts
if fails.empty?
  puts 'ALL PASS - carried calc-filters resolve the Phase 6 gate; changed/uncarried ones still block'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
