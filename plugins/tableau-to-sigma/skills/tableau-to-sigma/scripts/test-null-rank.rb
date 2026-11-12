#!/usr/bin/env ruby
# frozen_string_literal: true

# Live Stress 4 check of PR #940: Store Rank Table's Rank(Sum(Net Revenue),
# "desc") gave the NULL-revenue Phoenix Outlet rank 1 and shifted every store
# down one (Sigma ranks NULL first when descending; Tableau's RANK skips
# nulls). lib/null_rank.rb rewrites every rank to rank nulls last and return
# NULL for a NULL measure.

require_relative 'lib/null_rank'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Sigma Rank semantics (help.sigmacomputing.com/docs/rank): competition rank;
# NULLs rank last ascending, FIRST descending, tied with one another.
def sigma_rank(vals, dir)
  key = ->(v) { dir == 'desc' ? -v : v }
  nn = vals.compact
  vals.map do |v|
    if v.nil?
      dir == 'desc' ? 1 : nn.size + 1
    else
      (dir == 'desc' ? vals.count(&:nil?) : 0) + 1 + nn.count { |w| key.call(w) < key.call(v) }
    end
  end
end

# Evaluate the rewritten shape If(IsNull(E), Null, Rank(<E or -(E)>, "asc"))
# (or a bare Rank(E, dir)) over per-row values of E.
def evaluate(formula, vals)
  if (m = formula.match(/\AIf\(IsNull\((.+)\), Null, (?:Rank|RankDense)\((-\()?.+, "(asc|desc)"\)\)\z/))
    neg = !m[2].nil?
    ranks = sigma_rank(vals.map { |v| v.nil? ? nil : (neg ? -v : v) }, m[3])
    vals.zip(ranks).map { |v, r| v.nil? ? nil : r }
  elsif (m = formula.match(/\ARank\(.+, "(asc|desc)"\)\z/))
    sigma_rank(vals, m[1])
  end
end

revenue = [16_920.69, 16_818.22, nil, 16_792.30, 9_000.0] # Phoenix Outlet = nil
before = 'Rank(Sum([TopN Source (store-rank-table)/Net Revenue]), "desc")'
after = NullRank.rewrite(before)

puts 'Stress 4 Store Rank Table shape'
ok(evaluate(before, revenue) == [2, 3, 1, 4, 5], 'before: the NULL row takes rank 1 and shifts the rest (the defect)')
ok(evaluate(after, revenue) == [1, 2, nil, 3, 4], "after: NULL row blank, the others 1..n-1 (#{after})")
ok(NullRank.rewrite(after) == after, 'idempotent')

puts 'other rank shapes'
helper = NullRank.rewrite('Rank([Rank Measure], "desc")')
ok(evaluate(helper, [5.0, nil, 7.0]) == [2, nil, 1], "Top-N rank helper: NULL member takes no keep slot (#{helper})")
asc = NullRank.rewrite('RankDense(Avg([x]), "asc")')
ok(asc == 'If(IsNull(Avg([x])), Null, RankDense(Avg([x]), "asc"))', "ascending: masked, not negated (#{asc})")
ok(NullRank.rewrite('RankPercentile(Sum([x]))') == 'If(IsNull(Sum([x])), Null, RankPercentile(Sum([x]), "asc"))',
   'no direction = Sigma default asc')
nested = NullRank.rewrite('If(Rank(Sum([x]), "desc") <= 5, "keep", "cut")')
ok(nested == 'If(If(IsNull(Sum([x])), Null, Rank(-(Sum([x])), "asc")) <= 5, "keep", "cut")', "rank inside an expression (#{nested})")
ok(NullRank.rewrite('Rank()') == 'Rank()', 'argument-less Rank() (follows the table sort) untouched')
ok(NullRank.rewrite('Rank(Min([T/Name]), "desc")') == 'Rank(Min([T/Name]), "desc")',
   'DESC rank over a possibly-text operand is not negated')
ok(NullRank.rewrite('Rank(Min([T/Name]), "asc")') == 'If(IsNull(Min([T/Name])), Null, Rank(Min([T/Name]), "asc"))',
   'ASC rank over any operand is still null-masked')
quoted = NullRank.rewrite('Rank(CountIf([Status] = "Active"), "desc")')
ok(quoted == 'If(IsNull(CountIf([Status] = "Active")), Null, Rank(-(CountIf([Status] = "Active")), "asc"))',
   'DESC rank over a numeric aggregate with a quoted predicate is rewritten')
ok(NullRank.rewrite('Sum([Rank])') == 'Sum([Rank])', 'a column NAMED Rank is not a call')

spec = { 'pages' => [{ 'elements' => [{ 'id' => 'e', 'columns' => [{ 'id' => 'r', 'formula' => before },
                                                                     { 'id' => 'v', 'formula' => 'Sum([x])' }] }] }] }
ok(NullRank.apply!(spec) == 1 && spec['pages'][0]['elements'][0]['columns'][0]['formula'] == after, 'apply! rewrites spec columns')
ok(NullRank.apply!(spec).zero?, 'apply! is a no-op the second time')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
