#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the aggregation-semantics lint (PLAN-v3 PR-7) —
# scripts/lib/agg_semantics_lint.rb + scripts/audit-agg-semantics.rb.
#
# The field failure: additive aggregation over pre-aggregated columns compiles
# clean in every gate and ships wrong-looking-right numbers (a live twin
# reproduces a 103.3% ratio KPI from SUM over a {FIXED day: COUNTD} column).
# This test proves:
#   (i)   the preagg-kpi corpus twin fires class additive-over-preagg for its
#         {FIXED day: COUNTD} calcs consumed with SUM(), and class
#         preagg-ratio for its ratio KPIs — source-side AND emitted-side;
#   (ii)  COUNTD translated to Sum fires countd-as-sum (same-name translation
#         degradation and additive consumption of a COUNTD-derived column);
#   (iii) the DISTINCT_*/*_PCT/*_RATE/AVG_*/*_COUNT name heuristics fire only
#         in ratio (KPI numerator/denominator) positions;
#   (iv)  landing-manifest `grain` info flags additive aggs on tiles grouping
#         OUTSIDE the landed grain — and stays silent without grain info
#         (never force fabricated metadata);
#   (v)   the lint script blocks unresolved (exit 2) and passes once every
#         hit records reaggregated / n/a / faithful-to-source — with the n/a
#         and faithful-to-source paths first-class — and resolutions survive
#         re-derivation.
# Deterministic + offline.
#
# Usage: ruby scripts/test-agg-semantics-lint.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/agg_semantics_lint'

SCRIPT = File.join(__dir__, 'audit-agg-semantics.rb')
CORPUS = File.expand_path('../../../../../corpus/tableau/preagg-kpi', __dir__)

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

puts 'Part A — the preagg-kpi corpus twin (the test bed this lint was built for)'
if File.exist?(File.join(CORPUS, 'workbook-content.twb'))
  calcs = AggSemanticsLint.calc_census_from_twb(
    File.read(File.join(CORPUS, 'workbook-content.twb'), encoding: 'UTF-8')
  )
  check(calcs.any? { |c| c['name'] == 'Daily Distinct Buyers' }, 'twb census resolves calc captions', fails)
  dm = JSON.parse(File.read(File.join(CORPUS, 'dm-spec.fixture.json')))
  entries = AggSemanticsLint.derive(calcs, dm_spec: dm)
  a = entries.select { |e| e['class'] == 'additive-over-preagg' }
  r = entries.select { |e| e['class'] == 'preagg-ratio' }
  # (i) every SUM(preagg) KPI fires class (a): AvgAmt/SPA/PctEarn over DDB, SPA over DAS.
  %w[Avg\ Amount\ per\ Buyer Sales\ per\ Active Pct\ Buyers\ with\ Earnings].each do |kpi|
    check(a.any? { |e| e['consumer'] == kpi && e['preagg'] == 'Daily Distinct Buyers' && e['context'] == 'source-calc' },
          "additive-over-preagg fires for #{kpi.inspect} over the {FIXED day: COUNTD} column", fails)
  end
  check(a.any? { |e| e['consumer'] == 'Sales per Active' && e['preagg'] == 'Daily Active Sales' },
        'additive-over-preagg fires for the second pre-aggregate too (Daily Active Sales)', fails)
  # (i) the ratio KPIs fire class (c) via the "Distinct" name token.
  check(r.count { |e| e['context'] == 'source-calc' } == 3,
        "all three ratio KPIs fire preagg-ratio (got #{r.count { |e| e['context'] == 'source-calc' }})", fails)
  # emitted-side: the dm-spec fixture's Sum([Daily Distinct Buyers]) column fires both classes.
  check(a.any? { |e| e['context'] == 'dm-spec' && e['element'] == 'Sales Fact Master' },
        'emitted dm-spec Sum(preagg) column fires additive-over-preagg', fails)
  check(r.any? { |e| e['context'] == 'dm-spec' }, 'emitted dm-spec ratio fires preagg-ratio', fails)
  check(entries.all? { |e| e['status'] == 'unresolved' && !AggSemanticsLint.resolved?(e) },
        'every hit is WARN-with-required-resolution (unresolved until recorded)', fails)
  # the innocent calcs never fire: growth ratio over raw columns, date calcs.
  check(entries.none? { |e| e['consumer'] == 'Pct Growth YY' },
        'a ratio over RAW columns (Pct Growth YY) does not fire', fails)
else
  puts '  SKIP  corpus preagg-kpi not present in this checkout'
end

puts 'Part B — (ii) COUNTD translated to Sum'
CALCS_B = [
  { 'name' => 'Unique Buyers', 'internal_name' => '[Calculation_200]',
    'formula' => 'COUNTD([Buyer Id])' },
  { 'name' => 'Net Value', 'internal_name' => '[Calculation_201]',
    'formula' => 'SUM([Amount])' }
].freeze
DM_B = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-1', 'kind' => 'table', 'name' => 'Fact Master',
    'columns' => [
      # same-name translation degradation: COUNTD emitted as Sum
      { 'id' => 'b1', 'name' => 'Unique Buyers', 'formula' => 'Sum([FACT/BUYER_ID])' },
      # additive consumption of the COUNTD-derived column
      { 'id' => 'b2', 'name' => 'Total Uniques', 'formula' => 'Sum([Unique Buyers])' },
      # the CORRECT translation shape must NOT fire
      { 'id' => 'b3', 'name' => 'Net Value', 'formula' => 'Sum([FACT/AMOUNT])' }
    ] }
] }] }.freeze
eb = AggSemanticsLint.derive(AggSemanticsLint.calc_census(CALCS_B), dm_spec: JSON.parse(JSON.generate(DM_B)))
cb = eb.select { |e| e['class'] == 'countd-as-sum' }
check(cb.any? { |e| e['consumer'] == 'Unique Buyers' && e['evidence']['kind'] == 'translation' },
      'COUNTD calc emitted as Sum() → countd-as-sum (translation degradation)', fails)
check(cb.any? { |e| e['consumer'] == 'Total Uniques' && e['evidence']['kind'] == 'consumption' },
      'Sum() over a COUNTD-derived column → countd-as-sum (additive consumption)', fails)
check(eb.none? { |e| e['consumer'] == 'Net Value' }, 'an additive measure translated additively does not fire', fails)
ok_dm = { 'pages' => [{ 'elements' => [{ 'id' => 'e', 'name' => 'Fact', 'columns' => [
  { 'id' => 'c', 'name' => 'Unique Buyers', 'formula' => 'CountDistinct([FACT/BUYER_ID])' }
] }] }] }
check(AggSemanticsLint.derive(AggSemanticsLint.calc_census(CALCS_B), dm_spec: ok_dm).empty?,
      'COUNTD → CountDistinct (the correct translation) is clean', fails)

puts 'Part C — (iii) name heuristics fire only in ratio positions'
check(AggSemanticsLint.preagg_name?('DISTINCT_ORDERS') && AggSemanticsLint.preagg_name?('Daily Distinct Buyers') &&
      AggSemanticsLint.preagg_name?('MARGIN_PCT') && AggSemanticsLint.preagg_name?('conversionRate') &&
      AggSemanticsLint.preagg_name?('AVG_TICKET') && AggSemanticsLint.preagg_name?('Order Count'),
      'DISTINCT_* / *_PCT / *_RATE / AVG_* / *_COUNT token patterns match', fails)
check(!AggSemanticsLint.preagg_name?('NET_AMOUNT') && !AggSemanticsLint.preagg_name?('Count') &&
      !AggSemanticsLint.preagg_name?('Rate'),
      'raw columns and bare single-token names do not match', fails)
CALCS_C = [
  { 'name' => 'Take Rate', 'formula' => 'SUM([DISTINCT_ORDERS]) / SUM([TOTAL_ORDERS])' },
  { 'name' => 'Distinct Shelf', 'formula' => 'SUM([DISTINCT_ORDERS])' }, # no ratio → heuristic silent
  { 'name' => 'String Trap', 'formula' => "'/ per DISTINCT_ORDERS' + [Label]" }
].freeze
ec = AggSemanticsLint.derive(AggSemanticsLint.calc_census(CALCS_C))
check(ec.any? { |e| e['class'] == 'preagg-ratio' && e['consumer'] == 'Take Rate' && e['preagg'] == 'DISTINCT_ORDERS' },
      'ratio consuming DISTINCT_* → preagg-ratio', fails)
check(ec.none? { |e| e['consumer'] == 'Distinct Shelf' },
      'name heuristic WITHOUT a ratio position stays silent (KPI-position rule)', fails)
check(ec.none? { |e| e['consumer'] == 'String Trap' },
      "a '/' or pre-agg name inside a string literal never counts (masked scan)", fails)

puts 'Part D — (iv) landing-manifest grain check'
LM = [{ 'slug' => 'wallet', 'sf_table' => 'DEMO_DB.ANALYTICS.DAILY_ROLLUP',
        'rows' => 10, 'grain' => ['CAL_DATE'] }].freeze
WB_D = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-t', 'kind' => 'bar-chart', 'name' => 'By Site',
    'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB ANALYTICS DAILY_ROLLUP] },
    'columns' => [
      { 'id' => 'd1', 'name' => 'Site Key', 'formula' => '[DAILY_ROLLUP/SITE_KEY]' },
      { 'id' => 'd2', 'name' => 'Buyers', 'formula' => 'Sum([DAILY_ROLLUP/BUYERS])' }
    ],
    'groupings' => [{ 'id' => 'g1', 'groupBy' => ['d1'], 'calculations' => ['d2'] }] }
] }] }.freeze
ed = AggSemanticsLint.derive([], wb_spec: JSON.parse(JSON.generate(WB_D)), landing_manifest: JSON.parse(JSON.generate(LM)))
gd = ed.find { |e| e['class'] == 'additive-over-preagg' && e['evidence']['kind'] == 'landing-grain' }
check(gd && gd['element'] == 'By Site' && gd['evidence']['outside_grain'] == ['Site Key'],
      'tile grouping OUTSIDE the declared landed grain + additive agg → additive-over-preagg (landing-grain)', fails)
check(AggSemanticsLint.derive([], wb_spec: JSON.parse(JSON.generate(WB_D))).empty?,
      'NO grain info in the manifest → no grain hits (metadata is never fabricated/required)', fails)
wb_ok = JSON.parse(JSON.generate(WB_D))
wb_ok['pages'][0]['elements'][0]['columns'][0] = { 'id' => 'd1', 'name' => 'Cal Date', 'formula' => '[DAILY_ROLLUP/CAL_DATE]' }
check(AggSemanticsLint.derive([], wb_spec: wb_ok, landing_manifest: JSON.parse(JSON.generate(LM))).empty?,
      'tile grouping AT the landed grain is clean', fails)

puts 'Part E — (v) lint script: block / resolve round-trip (n/a + faithful-to-source first-class)'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate('calcs' => [
    { 'name' => 'Daily Buyers', 'internal_name' => '[Calculation_1]',
      'formula' => '{FIXED [Cal Date]: COUNTD([Buyer Id])}', 'is_lod' => true },
    { 'name' => 'Spend per Buyer', 'internal_name' => '[Calculation_2]',
      'formula' => 'SUM([Amount]) / SUM([Calculation_1])' },
    { 'name' => 'Unique Sales', 'internal_name' => '[Calculation_3]',
      'formula' => 'COUNTD([Sale Id])' }
  ]))
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate('pages' => [{ 'elements' => [
    { 'id' => 'el', 'kind' => 'table', 'name' => 'Master',
      'columns' => [{ 'id' => 'c1', 'name' => 'Unique Sales', 'formula' => 'Sum([FACT/SALE_FLAG])' }] }
  ] }]))

  out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st.exitstatus == 2, "unresolved hits → exit 2 (got #{st.exitstatus})", fails)
  check(err.include?('AGGREGATION SEMANTICS WARN'), 'WARN-with-required-resolution block printed', fails)
  check(err.include?('faithful-to-source') && err.include?('--how n/a'),
        'the block names all three sanctioned resolutions', fails)
  check(err.include?('never') && err.include?('fabricate metadata'),
        'the n/a path is stated first-class (no fabricated metadata)', fails)
  ledger = JSON.parse(File.read(File.join(dir, 'agg-semantics.json')))
  # Daily Buyers additive hit + Daily Buyers ratio hit (name heuristic? 'Daily
  # Buyers' has no pre-agg token → only LOD class) + Unique Sales countd-as-sum.
  by_class = ledger['entries'].group_by { |e| e['class'] }
  check(by_class.key?('additive-over-preagg') && by_class.key?('countd-as-sum'),
        "ledger carries both fixture classes (got #{by_class.keys.sort.inspect})", fails)
  n = ledger['entries'].length

  hows = ['faithful-to-source', 'n/a'] + ['reaggregated'] * [n - 2, 0].max
  st_last = nil
  n.times do |i|
    _o, _e, st_last = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                                     '--resolve', i.to_s, '--how', hows[i],
                                     '--reason', "test evidence #{i}: #{hows[i]} path")
    check(st_last.exitstatus == 2, "resolution #{i} recorded, others still block → exit 2", fails) if i < n - 1
  end
  check(st_last.exitstatus.zero?, "all hits resolved → exit 0 (got #{st_last.exitstatus})", fails)

  # re-derivation preserves the recorded resolutions.
  out3, _e3, st3 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st3.exitstatus.zero?, "re-derive after resolutions → still exit 0 (got #{st3.exitstatus})", fails)
  check(out3.include?('1 n/a') && out3.include?('1 faithful-to-source'),
        're-derived ledger counts the n/a and faithful-to-source resolutions', fails)

  # a resolution without a reason is refused.
  _o4, e4, st4 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                                '--resolve', '0', '--how', 'n/a', '--reason', '  ')
  check(!st4.success? && e4.include?('non-empty --reason'), 'a reason-less resolution is refused', fails)
  # an unknown how is refused.
  _o5, e5, st5 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                                '--resolve', '0', '--how', 'skipped', '--reason', 'x')
  check(!st5.success? && e5.include?('reaggregated|n/a|faithful-to-source'), 'an unknown resolution how is refused', fails)
end

puts 'Part F — empty ledger is still written (gate evidence)'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate('calcs' => [
    { 'name' => 'Plain', 'formula' => 'SUM([Amount])' }
  ]))
  out, _err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st.success?, 'no hits → exit 0', fails)
  led = JSON.parse(File.read(File.join(dir, 'agg-semantics.json')))
  check(led['entries'] == [], 'empty agg-semantics.json written as evidence', fails)
  check(out.include?('Ledger'), 'summary names the ledger', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
