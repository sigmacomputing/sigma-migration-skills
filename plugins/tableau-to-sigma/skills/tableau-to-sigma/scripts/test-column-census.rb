#!/usr/bin/env ruby
# Offline test for scripts/lib/column_census.rb (fix-workstream G).
#
# The census turns the silent posted-vs-readback column drop (a live DM run
# resolved a small fraction of the hundreds of columns POSTed, with no HTTP
# error and no type=error entries for the dropped ones) into a loud abort.
# Pure-function fixtures only — no live API. post-and-readback.rb wires
# ColumnCensus.census + report_lines on the DM path and exits 2 on problems.
#
# Usage:  ruby scripts/test-column-census.rb

require 'json'
require_relative 'lib/column_census'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def posted_spec(names_by_element)
  { 'pages' => [{ 'id' => 'pg', 'name' => 'Model', 'elements' =>
    names_by_element.map do |el_name, names|
      { 'id' => "posted-#{el_name.downcase.tr(' ', '-')}", 'kind' => 'table', 'name' => el_name,
        'columns' => names.map { |n| { 'id' => "c-#{n.downcase.tr(' ', '-')}", 'name' => n } } }
    end }] }
end

# Readback: server REASSIGNS element ids (DM POST always does) — names survive.
def readback_spec(el_names)
  { 'pages' => [{ 'id' => 'srv-pg', 'name' => 'Model', 'elements' =>
    el_names.map.with_index { |n, i| { 'id' => "srv-el-#{i}", 'kind' => 'table', 'name' => n } } }] }
end

def entries_for(labels_by_server_id, error_labels: [])
  labels_by_server_id.flat_map do |sid, labels|
    labels.map do |l|
      { 'elementId' => sid, 'columnId' => "srv-#{l}", 'label' => l,
        'type' => { 'type' => error_labels.include?(l) ? 'error' : 'number' } }
    end
  end
end

puts 'Part A — clean readback: no problems'
posted = posted_spec('Order Fact' => %w[Sales Profit Region])
rb = readback_spec(['Order Fact'])
problems = ColumnCensus.census(posted, rb, entries_for({ 'srv-el-0' => %w[Sales Profit Region] }))
check(problems.empty?, "all columns resolved -> [] (got #{problems.inspect})", fails)
check(ColumnCensus.posted_column_count(posted) == 3, 'posted_column_count sums columns', fails)

puts
puts 'Part B — the silent-drop catastrophe: most posted columns missing'
many = (1..30).map { |i| "Col #{format('%02d', i)}" }
posted = posted_spec('Order Fact' => many)
rb = readback_spec(['Order Fact'])
problems = ColumnCensus.census(posted, rb, entries_for({ 'srv-el-0' => many.first(4) }))
check(problems.size == 1, 'one problem element reported', fails)
p1 = problems.first
check(p1['posted'] == 30 && p1['resolved'] == 4, "posted 30 / resolved 4 counted (got #{p1['posted']}/#{p1['resolved']})", fails)
check(p1['missing'].size == 26 && p1['missing'].include?('Col 05'), '26 missing names listed', fails)
lines = ColumnCensus.report_lines(problems)
check(lines.first.include?('posted 30') && lines.first.include?('resolved 4'), 'report shows the N->M collapse', fails)
check(lines.any? { |l| l.include?('and 6 more') }, "missing list capped at first 20 with '... and 6 more' (got #{lines.inspect})", fails)
check(lines.join.scan('Col ').size <= 21, 'no more than 20 missing names printed', fails)

puts
puts 'Part C — element entirely absent from readback'
posted = posted_spec('Order Fact' => %w[Sales], 'Ghost Element' => %w[A B])
rb = readback_spec(['Order Fact'])
problems = ColumnCensus.census(posted, rb, entries_for({ 'srv-el-0' => %w[Sales] }))
check(problems.size == 1 && problems.first['element'] == 'Ghost Element', 'dropped element reported', fails)
check(problems.first['resolved'] == 0 && problems.first['missing'] == %w[A B], 'all its columns missing', fails)
check(problems.first['note'].to_s.include?('missing from readback'), 'note explains the element-level drop', fails)

puts
puts 'Part D — readback column with type=error flagged'
posted = posted_spec('Order Fact' => %w[Sales Profit])
rb = readback_spec(['Order Fact'])
problems = ColumnCensus.census(posted, rb, entries_for({ 'srv-el-0' => %w[Sales Profit] }, error_labels: %w[Profit]))
check(problems.size == 1 && problems.first['error_columns'] == %w[Profit], 'error-typed column reported', fails)
check(problems.first['missing'].empty?, 'error column is present, not missing', fails)
check(ColumnCensus.report_lines(problems).any? { |l| l.include?('type=error 1: Profit') }, 'report shows the error column', fails)

puts
puts 'Part E — suffixed-label tolerance (Sigma joined-dim relabeling)'
posted = posted_spec('Order Fact' => ['Customer Id', 'Sales'])
rb = readback_spec(['Order Fact'])
problems = ColumnCensus.census(posted, rb, entries_for({ 'srv-el-0' => ['Customer Id (CUSTOMER_DIM)', 'Sales'] }))
check(problems.empty?, "posted 'Customer Id' resolved by suffixed label (got #{problems.inspect})", fails)

puts
puts 'Part F — id fallback when names are blank but ids survive'
posted = { 'pages' => [{ 'elements' => [{ 'id' => 'kept-id', 'kind' => 'table',
                                          'columns' => [{ 'id' => 'c1', 'name' => 'Sales' }] }] }] }
rb = { 'pages' => [{ 'elements' => [{ 'id' => 'kept-id', 'kind' => 'table' }] }] }
problems = ColumnCensus.census(posted, rb, entries_for({ 'kept-id' => %w[Sales] }))
check(problems.empty?, 'nameless element matched by surviving id', fails)

puts
puts 'Part G — metrics counted alongside columns'
posted = { 'pages' => [{ 'elements' => [{ 'id' => 'e1', 'name' => 'Fact', 'kind' => 'table',
                                          'columns' => [{ 'id' => 'c1', 'name' => 'Sales' }],
                                          'metrics' => [{ 'id' => 'm1', 'name' => 'Total Sales' }] }] }] }
rb = readback_spec(['Fact'])
problems = ColumnCensus.census(posted, rb, entries_for({ 'srv-el-0' => ['Sales'] }))
check(problems.size == 1 && problems.first['missing'] == ['Total Sales'], 'missing metric caught', fails)

puts
if fails.empty?
  puts 'OK — column census pure-function checks all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
