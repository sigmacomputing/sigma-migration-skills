#!/usr/bin/env ruby
# Regression test for the Phase-6 hidden_filters gate's quick-filter skip in
# auto-parity-plan.rb (the Python twin is covered by test_auto_parity_plan.py).
# A calc-field worksheet filter whose field is also a quick-filter zone on the
# dashboard is skipped only when it is a plain member list left at "All". A
# wildcard, condition or top-N filter also carries an empty member list but
# still restricts rows, so it must stay in the gate.
#
# Deterministic + offline: runs the ACTUAL auto-parity-plan.rb on a minimal
# fixture.
#
# Usage: ruby scripts/test-hidden-filter-quick-filter-skip.rb

require 'json'
require 'tmpdir'

DIR  = __dir__
PLAN = File.join(DIR, 'auto-parity-plan.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

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
}

def plan_hidden(hidden)
  Dir.mktmpdir do |d|
    File.write("#{d}/wb.json", JSON.dump(WB_SPEC))
    File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Chart' }] }))
    Dir.mkdir("#{d}/views")
    File.write("#{d}/views/v1.csv", "Region,Net Revenue\nWest,100\n")
    File.write("#{d}/dashboard-layout.json", JSON.dump([{
      'dashboard' => 'Overview',
      'zones' => [
        { 'kind' => 'chart', 'caption' => 'Chart', 'measures' => ['Net Revenue'],
          'hidden_filters' => [{ 'calc_ref' => '[ds].[none:Calculation_1:nk]', 'caption' => 'Channel Group',
                                 'filter_type' => 'categorical' }.merge(hidden)] },
        { 'kind' => 'filter', 'filter_column_caption' => 'Channel Group' }
      ]
    }]))
    o = "#{d}/plan.json"
    IO.popen(['ruby', PLAN, '--tableau', d, '--workbook-spec', "#{d}/wb.json",
              '--master-id', 'master', '--out', o], err: %i[child out], &:read)
    File.exist?(o) ? (JSON.parse(File.read(o))['hidden_filters'] || []) : nil
  end
end

all = plan_hidden('kind' => 'list')
check(all == [], "a list quick filter left at All is skipped (got #{all.inspect})", fails)

{ 'wildcard' => { 'kind' => 'wildcard' },
  'condition' => { 'kind' => 'list+condition' },
  'top-N' => { 'kind' => 'list', 'topn' => true },
  'restrictive list' => { 'kind' => 'list', 'members' => ['Store'] },
  'no kind' => {} }.each do |label, hidden|
  got = plan_hidden(hidden)
  check(got.is_a?(Array) && got.length == 1, "a #{label} filter still gates (got #{got.inspect})", fails)
end

puts
if fails.empty?
  puts 'ALL PASS — only an All-valued list quick filter skips the hidden_filters gate'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
