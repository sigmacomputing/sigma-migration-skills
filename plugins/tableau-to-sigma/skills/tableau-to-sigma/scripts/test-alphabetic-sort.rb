#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K21 (narrowed): Tableau's <alphabetic-sort> must be
# migrated, and must sort by the DIMENSION.
#
# Scope discipline: <computed-sort> is ALREADY migrated end to end
# (parse-twb-layout.rb -> sort_target_column_id -> three consumers). K21 as filed
# said "Tableau sorts are not migrated at all", which is wrong. Only
# <alphabetic-sort> is unhandled. This test asserts the alphabetic path works AND
# that the computed-sort path is left intact.
#
# THE TRAP: the vendored XSD (schemas/twb_2026.2.0.xsd, Sort-Alphabetic-G, ~:3034)
# declares <alphabetic-sort> as an EMPTY element — no attributes at all. So a
# naive wire-through gives sort_target_column_id an empty column token, and its
# existing `return meas_col_id if token.empty?` sorts by the MEASURE — silently
# the wrong axis. An explicit alphabetic marker is required.
# Deterministic + offline.

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

parser = File.read(File.join(DIR, 'parse-twb-layout.rb'))
builder = File.read(File.join(DIR, 'build-charts-from-signals.rb'))

puts 'Part A — the parser recognises <alphabetic-sort>'
check(parser.include?('alphabetic-sort'),
      'parse-twb-layout.rb looks for .//alphabetic-sort', fails)
check(parser.match?(/alphabetic:\s*true/),
      'the parser sets an explicit `alphabetic: true` marker', fails)

puts 'Part B — the consumer sorts by the DIMENSION when the marker is set'
check(builder.match?(/sort_info\[['"]alphabetic['"]\]/),
      'sort_target_column_id reads the alphabetic marker', fails)
# The marker check must come BEFORE the empty-token bail-out, or the measure wins.
if builder.match?(/sort_info\[['"]alphabetic['"]\]/)
  fn = builder[/def sort_target_column_id.*?\nend/m].to_s
  a = fn.index('alphabetic')
  b = fn.index('token.empty?')
  check(!a.nil? && !b.nil? && a < b,
        'the alphabetic check precedes the empty-token measure fallback', fails)
end

puts 'Part C — <computed-sort> is left intact (do not regress the working path)'
check(parser.include?('.//computed-sort'), 'computed-sort parsing still present', fails)
check(builder.include?('sort_target_column_id'), 'the shared resolver is still used', fails)

puts 'Part D — behavioral: replicate the shipped resolver'
# Mirror of the shipped op. Keep in lock-step with build-charts-from-signals.rb.
def resolve(sort_info, dim_name, dim_col_id, meas_col_id)
  return dim_col_id if sort_info['alphabetic']

  raw   = sort_info['column'].to_s
  inner = raw[/\[([^\[\]]+)\]\z/, 1].to_s
  token = (inner.split(':')[1] || inner).downcase.gsub(/\W+/, '')
  return meas_col_id if token.empty?

  key = dim_name.to_s.downcase.gsub(/\W+/, '')
  return dim_col_id if !key.empty? && (token == key || token.include?(key) || key.include?(token))

  meas_col_id
end

check(resolve({ 'alphabetic' => true }, 'Region', 'x-dim', 'y-meas') == 'x-dim',
      'alphabetic marker -> sorts by the dimension', fails)
check(resolve({ 'column' => '[federated.a].[none:REGION:nk]' }, 'Region', 'x-dim', 'y-meas') == 'x-dim',
      'computed-sort on the dim -> dimension (unchanged)', fails)
check(resolve({ 'column' => '[federated.a].[sum:NET_REVENUE:qk]' }, 'Region', 'x-dim', 'y-meas') == 'y-meas',
      'computed-sort on a measure -> measure (unchanged)', fails)

puts 'Part E — planted-defect guard: without the marker, an empty token picks the MEASURE'
# This is the silent-wrong-axis bug. If it ever stops happening, Part D proves nothing.
naive = lambda do |si, dim_col_id, meas_col_id|
  token = si['column'].to_s[/\[([^\[\]]+)\]\z/, 1].to_s.split(':')[1].to_s.downcase.gsub(/\W+/, '')
  token.empty? ? meas_col_id : dim_col_id
end
check(naive.call({}, 'x-dim', 'y-meas') == 'y-meas',
      'PLANTED-DEFECT GUARD: an attribute-less alphabetic-sort would sort by the MEASURE', fails)
check(resolve({ 'alphabetic' => true }, 'Region', 'x-dim', 'y-meas') != naive.call({}, 'x-dim', 'y-meas'),
      'PLANTED-DEFECT GUARD: the marker changes the outcome', fails)

puts 'Part F — a computed-sort BY a measure sorts by the measure, even when `column` names the plotted dim'
# Live-caught: a bar on a group dim sorted by a parameter-switched measure
# (<computed-sort column='[none:Store Name (group):nk]' using='[sum:Volume Measure - Mo:qk]'>)
# came out reverse-alphabetical, because `column` (always the sorted dim) matched
# the plotted dim. Exercised against the REAL builder function, not a mirror.
real_src = builder[/def sort_target_column_id.*?\nend/m].to_s
real = Module.new { module_eval(real_src); module_function :sort_target_column_id }
group_sort = { 'column' => '[federated.a].[none:Store Name (group):nk]', 'direction' => 'descending',
               'using' => '[federated.a].[sum:Volume Measure - Mo:qk]' }
dim = { 'name' => 'Store Name (group)' }
check(real.sort_target_column_id(group_sort, dim, 'Store Name (group)', 'x-dim', 'y-meas') == 'y-meas',
      'computed-sort column=<plotted dim> using=<measure> -> sorts by the MEASURE', fails)
check(real.sort_target_column_id(group_sort.merge('column' => '[federated.a].[none:3c4fbb09-a975-3126-96e1-2f64fae9ff89:nk]'),
                                 dim, 'Store Name (group)', 'x-dim', 'y-meas') == 'y-meas',
      'computed-sort on a GUID-named dim using a measure -> measure (unchanged)', fails)
check(real.sort_target_column_id({ 'column' => '[federated.a].[none:REGION:nk]' }, { 'name' => 'Region' }, 'Region', 'x-dim', 'y-meas') == 'x-dim',
      'a sort on the dim with no `using` -> dimension (unchanged)', fails)
check(real.sort_target_column_id({ 'alphabetic' => true, 'using' => '[x].[sum:A:qk]' }, dim, nil, 'x-dim', 'y-meas') == 'x-dim',
      'alphabetic marker still wins', fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
