#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test: a bracketed Tableau field name is OPAQUE to the calc rewrites.
#
# Tableau names a duplicated field `[Volume Measure - Mo (copy)_1230608612058259457]` and a group
# `[Officer Name (group)]`. translate_tableau_tc's RANK / RANK_DENSE / RANK_PERCENTILE / RANK_UNIQUE /
# LOOKUP / WINDOW_* / TOTAL rewrites (and translate_user_agg_formula's ZN loop) only allowed one or
# two levels of `(...)` nesting and did not treat `[...]` as a unit, so a paren or comma inside a
# name pushed them over: the rewrite returned nil and the window classifier said "STAYS MANUAL: window
# construct RANK() has no validated mapping in this shape". On a real leaderboard every rank measure
# fell back to Sum([Master/<rank calc>]), which is wrong.
#
# Part 1: translate_tableau_tc on names with `(copy)_digits`, `(group)`, nested parens and commas, for
#         every rewrite family. Part 2: translate_window_calc (inline / two-stage / top-N classes).
# Part 3: the CONTAINS(LOOKUP(MAX(UPPER([A (group)])),0),UPPER([Parameters].[P])) search shape.
# Part 4: end to end through parse-twb-layout + build-charts on fixtures/calc-paren-names.twb — the
#         worksheet plots RANK(SUM([Volume Measure (copy)_123])) and the built chart must carry a
#         Rank(...) formula, never the Sum([Master/...]) fallback.
#
# Usage:  ruby scripts/test-calc-paren-field-names.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/chart_calc_translate'

DIR     = __dir__
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
FIXTURE = File.join(DIR, 'fixtures', 'calc-paren-names.twb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Names whose bracketed token would defeat a bounded-nesting paren regex.
COPY   = '[Volume Measure - Mo (copy)_1230608612058259457]'
GROUP  = '[Officer Name (group)]'
NESTED = '[Adj Volume (net (of (fees)))]'
COMMA  = '[Volume, Net (Q1)]'
UNBAL  = '[Rate (pct]'

puts 'Part 1 - translate_tableau_tc: rewrites treat [..] as opaque'
rewrite = ->(f) { translate_tableau_tc(f).first }
{
  "RANK(SUM(#{COPY}))"                       => %(Rank(SUM(#{COPY}), "desc")),
  "RANK(SUM(#{COPY}), 'asc')"                => %(Rank(SUM(#{COPY}), "asc")),
  "RANK(SUM(#{NESTED}), 'desc')"             => %(Rank(SUM(#{NESTED}), "desc")),
  "RANK(SUM(#{COMMA}))"                      => %(Rank(SUM(#{COMMA}), "desc")),
  "RANK_DENSE(SUM(#{COPY}))"                 => %(RankDense(SUM(#{COPY}), "desc")),
  "RANK_DENSE(SUM(#{GROUP}), 'asc')"         => %(RankDense(SUM(#{GROUP}), "asc")),
  "RANK_DENSE(SUM(#{COMMA}))"                => %(RankDense(SUM(#{COMMA}), "desc")),
  "RANK_PERCENTILE(SUM(#{COPY}))"            => %(RankPercentile(SUM(#{COPY}), "desc")),
  "RANK_PERCENTILE(SUM(#{NESTED}), 'asc')"   => %(RankPercentile(SUM(#{NESTED}), "asc")),
  "RANK_UNIQUE(SUM(#{UNBAL}))"               => 'RowNumber()',
  "RANK_UNIQUE(#{COMMA}, 'asc')"             => 'RowNumber()',
  "RANK_UNIQUE(SUM(#{NESTED}), 'desc')"      => 'RowNumber()',
  "LOOKUP(#{COMMA}, 0)"                      => COMMA,
  "LOOKUP(SUM(#{UNBAL}), 0)"                 => "SUM(#{UNBAL})",
  "LOOKUP(MAX(UPPER(#{NESTED})), 0)"         => "MAX(UPPER(#{NESTED}))",
  "LOOKUP(SUM(#{NESTED}), -1)"               => "Lag(SUM(#{NESTED}), 1)",
  "LOOKUP(#{COMMA}, -2)"                     => "Lag(#{COMMA}, 2)",
  "LOOKUP(#{COMMA}, 1)"                      => "Lead(#{COMMA}, 1)",
  "LOOKUP(SUM(#{NESTED}), 3)"                => "Lead(SUM(#{NESTED}), 3)",
  "WINDOW_SUM(#{COMMA}, -2, 0)"              => "MovingSum(#{COMMA}, 2)",
  "WINDOW_MAX(SUM(#{NESTED}), -3, 1)"        => "MovingMax(SUM(#{NESTED}), 3, 1)",
  "WINDOW_MIN(AVG(#{UNBAL}), -1, 0)"         => "MovingMin(AVG(#{UNBAL}), 1)",
  "WINDOW_AVG(#{COMMA}, -6, 0)"              => "MovingAvg(#{COMMA}, 6)",
  "TOTAL(SUM(#{NESTED}))"                    => "Sum(#{NESTED})",
  "TOTAL(COUNTD(#{NESTED}))"                 => "CountDistinct(#{NESTED})",
  "TOTAL(AVG(#{NESTED}))"                    => "Avg(#{NESTED})",
  "RUNNING_SUM(RANK(SUM(#{COMMA})))"         => %(CumulativeSum(Rank(SUM(#{COMMA}), "desc"))),
  "ZN(RANK(SUM(#{COPY})))"                   => %(Coalesce(Rank(SUM(#{COPY}), "desc"), 0))
}.each do |input, want|
  got = rewrite.call(input)
  check(got == want, "#{input[0, 58]}#{input.length > 58 ? '...' : ''} -> #{want[0, 48]} (got #{got.inspect[0, 70]})", fails)
end

# A table calc INSIDE a bracketed name is not a table calc: the name is data, not syntax.
check(translate_tableau_tc('SUM([RANK(a) of x])').first.nil?, 'RANK( inside a bracketed NAME is not rewritten', fails)
check(translate_tableau_tc('SUM([INDEX() (copy)_7])').first.nil?, 'INDEX() inside a bracketed NAME is not rewritten', fails)

# GUARDS: these hold before AND after the fix (the masking must not change them), so they are not
# counted among the checks that have to fail without it.
puts '  (guards — hold with or without the masking)'
check(rewrite.call('RANK(SUM([Volume Measure]))') == 'Rank(SUM([Volume Measure]), "desc")',
      'guard: a paren-free name still translates exactly as before', fails)
all_out = [COPY, GROUP, NESTED, COMMA, UNBAL].map { |n| translate_tableau_tc("RANK(SUM(#{n}), 'asc')").join(' ') }.join(' ')
check(!all_out.include?("\u0001") && !all_out.include?("\u0002"), 'guard: the mask sentinel never leaks into the formula or hints', fails)
lod = translate_tableau_tc("{FIXED #{GROUP} : SUM(#{COPY})}")
check(lod.last.to_s.include?('inner grain = [Officer Name (group)], SUM(Volume Measure - Mo (copy)_1230608612058259457)'),
      'guard: the FIXED-LOD hint still names the real (unmasked) fields', fails)

puts
puts 'Part 2 - translate_window_calc: classification over paren names'
def mm(*names)
  names.each_with_object({}) { |n, h| h["(?i)^#{Regexp.escape(n)}$"] = { 'id' => "m-#{n.downcase.gsub(/\W+/, '-')}", 'name' => n } }
end
MMAP = mm('Volume Measure - Mo (copy)_1230608612058259457', 'Officer Name (group)', 'Rate (pct', 'Adj Volume (net (of (fees)))',
          'Volume, Net (Q1)').freeze
win = ->(f) { translate_window_calc(f, MMAP, {}) }

p1 = win.call("RANK(SUM(#{COPY}))")
check(p1 && p1['mode'] == 'inline' && p1['formula'] == 'Rank(Sum([Master/Volume Measure - Mo (copy)_1230608612058259457]), "desc")',
      "RANK(SUM(copy)) is an inline Rank(...), not 'stays manual' (got #{p1.inspect[0, 110]})", fails)
p2 = win.call("RANK_DENSE(SUM(#{NESTED}), 'asc')")
check(p2 && p2['mode'] == 'inline' && p2['formula'] == 'RankDense(Sum([Master/Adj Volume (net (of (fees)))]), "asc")',
      "RANK_DENSE(SUM(nested parens), 'asc') -> inline RankDense (got #{p2.inspect[0, 110]})", fails)
p3 = win.call("RANK_PERCENTILE(SUM(#{COMMA}))")
check(p3 && p3['mode'] == 'inline' && p3['formula'] == 'RankPercentile(Sum([Master/Volume, Net (Q1)]), "desc")',
      "RANK_PERCENTILE(SUM(comma name)) -> inline RankPercentile (got #{p3.inspect[0, 110]})", fails)
p4 = win.call("RANK_UNIQUE(SUM(#{UNBAL}), 'asc')")
check(p4 && p4['mode'] == 'inline' && p4['formula'] == 'RowNumber()',
      "RANK_UNIQUE(SUM(unbalanced paren), 'asc') -> RowNumber() (got #{p4.inspect[0, 110]})", fails)
p5 = win.call("WINDOW_SUM(SUM(#{UNBAL}), -2, 0)")
check(p5 && p5['mode'] == 'inline' && p5['formula'] == 'MovingSum(Sum([Master/Rate (pct]), 2)',
      "WINDOW_SUM(SUM(unbalanced paren), -2, 0) -> MovingSum (got #{p5.inspect[0, 110]})", fails)
p6 = win.call("WINDOW_MAX(SUM(#{NESTED}), -3, 1)")
check(p6 && p6['mode'] == 'inline' && p6['formula'] == 'MovingMax(Sum([Master/Adj Volume (net (of (fees)))]), 3, 1)',
      "WINDOW_MAX(SUM(nested parens), -3, 1) -> MovingMax (got #{p6.inspect[0, 110]})", fails)
p7 = win.call("WINDOW_MIN(AVG(#{UNBAL}), -1, 0)")
check(p7 && p7['mode'] == 'inline' && p7['formula'] == 'MovingMin(Avg([Master/Rate (pct]), 1)',
      "WINDOW_MIN(AVG(unbalanced paren), -1, 0) -> MovingMin (got #{p7.inspect[0, 110]})", fails)
p8 = win.call("RUNNING_SUM(RANK(SUM(#{NESTED})))")
check(p8 && p8['mode'] == 'inline' && p8['formula'] == 'CumulativeSum(Rank(Sum([Master/Adj Volume (net (of (fees)))]), "desc"))' && p8['follows_sort'],
      "RUNNING_SUM(RANK(SUM(nested parens))) -> CumulativeSum(Rank(..)) (got #{p8.inspect[0, 110]})", fails)
p9 = win.call("LOOKUP(SUM(#{NESTED}), -1)")
check(p9 && p9['mode'] == 'inline' && p9['formula'] == 'Lag(Sum([Master/Adj Volume (net (of (fees)))]), 1)',
      "LOOKUP(SUM(nested parens), -1) -> Lag (got #{p9.inspect[0, 110]})", fails)
p10 = win.call("LOOKUP(SUM(#{UNBAL}), 2)")
check(p10 && p10['mode'] == 'inline' && p10['formula'] == 'Lead(Sum([Master/Rate (pct]), 2)',
      "LOOKUP(SUM(unbalanced paren), 2) -> Lead (got #{p10.inspect[0, 110]})", fails)
p12 = win.call("ZN(RANK(SUM(#{NESTED})))")
check(p12 && p12['mode'] == 'inline' && p12['formula'] == 'Coalesce(Rank(Sum([Master/Adj Volume (net (of (fees)))]), "desc"), 0)',
      "ZN(RANK(SUM(nested parens))) -> Coalesce(Rank(...), 0) (got #{p12.inspect[0, 120]})", fails)

puts
puts 'Part 2b - RANK(...) <= N top-N shape'
t1 = win.call("RANK(ZN(SUM(#{NESTED}))) <= 10")
check(t1 && t1['mode'] == 'inline' && t1['top_n'] == 10 && t1['ranking'] == 'rank' &&
      t1['ranked_measure'] == 'Coalesce(Sum([Master/Adj Volume (net (of (fees)))]), 0)',
      "RANK(ZN(SUM(nested))) <= 10 -> top-10 filter ranked by the real measure (got #{t1.inspect[0, 160]})", fails)
t2 = win.call("RANK_UNIQUE(ZN(SUM(#{NESTED})), 'desc') <= 25")
check(t2 && t2['mode'] == 'inline' && t2['top_n'] == 25 && t2['ranking'] == 'row-number' &&
      t2['ranked_measure'] == 'Coalesce(Sum([Master/Adj Volume (net (of (fees)))]), 0)',
      "RANK_UNIQUE(ZN(SUM(nested)), 'desc') <= 25 -> top-25 row-number filter (got #{t2.inspect[0, 160]})", fails)
t3 = win.call("RANK(ZN(SUM(#{NESTED})), 'asc') < 5")
check(t3 && t3['mode'] == 'inline' && t3['top_n'] == 4 && t3['ranked_measure'] == 'Coalesce(Sum([Master/Adj Volume (net (of (fees)))]), 0)',
      "RANK(ZN(SUM(nested)), 'asc') < 5 -> top-4 (got #{t3.inspect[0, 160]})", fails)

puts
puts 'Part 2c - translate_user_agg_formula: the ZN loop and aggregate refs'
ua = translate_user_agg_formula("ZN(SUM(#{NESTED})) / ZN(SUM(#{COMMA}))", MMAP, {})
check(ua == 'Coalesce(Sum([Master/Adj Volume (net (of (fees)))]), 0) / Coalesce(Sum([Master/Volume, Net (Q1)]), 0)',
      "ZN(SUM(nested)) / ZN(SUM(comma name)) -> two Coalesce (got #{ua.inspect})", fails)

puts
puts 'Part 3 - the CONTAINS(LOOKUP(MAX(UPPER([A (group)])),0), UPPER([Parameters].[P])) search shape'
search = 'CONTAINS(LOOKUP(MAX(UPPER([Officer Name (group)])),0),UPPER([Parameters].[Parameter 3]))'
sr, hint = translate_tableau_tc(search)
check(sr == 'CONTAINS(MAX(UPPER([Officer Name (group)])),UPPER([Parameters].[Parameter 3]))',
      "LOOKUP(x, 0) is dropped to x inside the search shape (got #{sr.inspect})", fails)
check(hint.to_s.include?('LOOKUP(x, 0)'), 'the identity rewrite is reported in the hint', fails)
search_commas = 'CONTAINS(LOOKUP(MAX(UPPER([Name (a, b)])),0),UPPER([Parameters].[Parameter (x, y)]))'
check(translate_tableau_tc(search_commas).first == 'CONTAINS(MAX(UPPER([Name (a, b)])),UPPER([Parameters].[Parameter (x, y)]))',
      'commas/parens in a field AND in a [Parameters].[..] name are both opaque', fails)
check(translate_tableau_tc("LOOKUP(MAX(UPPER(#{GROUP})), -1)").first == "Lag(MAX(UPPER(#{GROUP})), 1)",
      'LOOKUP over UPPER(<group field>) with an offset -> Lag', fails)

puts
puts 'Part 4 - end to end: a RANK(SUM([Measure (copy)_123])) leaderboard builds a Rank(...) measure'
# One parse + one build over the fixture (the harness mirrors test-stress-gaps.rb).
def run_pipeline(twb_text, csvs:, mmap:)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    o, = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false, log: o } unless File.exist?(lay)
    views = csvs.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    csvs.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'PN', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(mmap))
    out = File.join(d, 'chart-specs.json')
    log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                              '--meta', File.join(d, 'dashboard-layout-meta.json'),
                              '--master-map', File.join(d, 'master-columns.json'),
                              '--master-element-id', 'master', '--auto-controls',
                              '--skip-dashboard-read', 'offline test fixture', '--out', out)
    specs = File.exist?(out) ? JSON.parse(File.read(out)) : nil
    flat = specs.is_a?(Hash) ? specs['pages'].flat_map { |pg| pg['elements'] } : (specs || [])
    { ok: st.success?, log: log, specs: specs, elements: flat }
  end
end

e2e_mmap = {}
['Officer Name', 'Volume Measure', 'Volume Measure (copy)'].each do |n|
  e2e_mmap["(?i)^(?:(?:sum|avg|min|max|distinct count|count) of |(?:avg|sum|min|max|cnt|ctd)\\.\\s*)?#{Regexp.escape(n)}$"] =
    { 'id' => "m-#{n.downcase.gsub(/\W+/, '-')}", 'name' => n }
end
csv = "Officer Name,Volume Rank\nAlice,1\nBob,2\n"
run = run_pipeline(File.read(FIXTURE, encoding: 'utf-8'), csvs: { 'Leaderboard' => csv }, mmap: e2e_mmap)
puts run[:log] if ENV['DEBUG_LOG']
check(run[:ok], "build-charts exits 0 on the fixture (got: #{run[:log].to_s.lines.grep(/Error/).first(2).inspect})", fails)
board = (run[:elements] || []).find { |e| e['id'] == 'el-leaderboard' }
check(!board.nil?, 'the Leaderboard tile is built', fails)
formulas = ((board || {})['columns'] || []).map { |c| c['formula'].to_s }
check(formulas.any? { |f| f =~ /\ARank\(Sum\(\[Master\/Volume Measure \(copy\)\]\), "desc"\)\z/ },
      "the rank measure is Rank(Sum([Master/Volume Measure (copy)]), \"desc\") (columns: #{formulas.inspect})", fails)
check(formulas.none? { |f| f =~ /Sum\(\[Master\/(?:Volume Rank|Calculation_2001)\]\)/ },
      'no Sum([Master/<rank calc>]) fallback — a rank must never be summed', fails)
check(!run[:log].to_s.include?('window construct RANK() has no validated mapping'),
      "the 'stays manual: window construct RANK()' warning is gone", fails)

puts
if fails.empty?
  puts 'test-calc-paren-field-names: ALL PASS'
else
  puts "test-calc-paren-field-names: #{fails.size} FAIL"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
