#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression: auto-parity-plan.rb must resolve virtual-connection-qualified CSV
# headers ("Region (DIM_A (SCHEMA_A.DIM_A))"), skip Tableau-generated geo columns
# and formatting-only flag columns WITH a recorded reason, and still abort on a
# genuinely unresolved column identity.

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

SCRIPT = File.join(__dir__, 'auto-parity-plan.rb')
fails = []
check = lambda do |cond, msg|
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def stage(dir, csv, columns)
  File.write(File.join(dir, 'get-workbook.json'),
             JSON.generate('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Sales Sheet' }] }))
  Dir.mkdir(File.join(dir, 'views'))
  File.write(File.join(dir, 'views', 'v1.csv'), csv)
  File.write(File.join(dir, 'chart-provenance.json'), JSON.generate(
    'version' => 1, 'elements' => { 'el-sales' => { 'worksheet' => 'Sales Sheet', 'dashboard' => 'Board', 'name' => 'Sales' } }
  ))
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate([{
    'dashboard' => 'Board',
    'zones' => [{ 'kind' => 'chart', 'caption' => 'Sales Sheet', 'measures' => ['Sales'],
                  'rows_shelf' => { 'dim_count' => 1 }, 'cols_shelf' => { 'measure_count' => 1 } }]
  }]))
  File.write(File.join(dir, 'wb.json'), JSON.generate(
    'schemaVersion' => 4, 'kind' => 'workbook',
    'pages' => [{ 'id' => 'p', 'name' => 'Board' }],
    'elements' => [{ 'id' => 'el-sales', 'kind' => 'bar-chart', 'name' => 'Sales',
                     'source' => { 'kind' => 'data-model' }, 'columns' => columns,
                     'xAxis' => { 'columnId' => 'x-region' }, 'yAxis' => { 'columnIds' => ['y-sales'] } }],
    'layout' => '<Page id="p"><Element elementId="el-sales"/></Page>'
  ))
end

def run_plan(dir)
  out = File.join(dir, 'plan.json')
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  so, se, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--tableau', dir, '--workbook-spec', File.join(dir, 'wb.json'),
                              '--out', out, '--workbook-id', 'wb-test', '--dashboard', 'Board')
  [File.exist?(out) ? JSON.parse(File.read(out)) : nil, so + se, st]
end

COLS = [{ 'id' => 'x-region', 'name' => 'Region' }, { 'id' => 'y-sales', 'name' => 'Sales' }].freeze
reason_for = ->(chart, h) { (chart['skipped_columns'] || []).find { |s| s['header'] == h }&.fetch('reason', nil) }

# a. nested virtual-connection qualifier
Dir.mktmpdir do |dir|
  stage(dir, "Region (DIM_A (SCHEMA_A.DIM_A)),Sales\nEast,10\nWest,20\n", COLS)
  plan, log, st = run_plan(dir)
  chart = plan && plan['charts'].first
  check.call(st.success?, "VC-qualified header resolves (#{log[0, 200]})")
  check.call(chart && chart['sigma_columns'] == %w[x-region y-sales], 'qualified header maps to the Region column')
  check.call(chart && chart['expected'] == [['East', 10.0], ['West', 20.0]], 'expected rows are intact')
end

# a2. doubly nested qualifier
Dir.mktmpdir do |dir|
  stage(dir, "Region (DIM_A (SCHEMA_A.DIM_A)) (DIM_B (SCHEMA_A.DIM_B)),Sales\nEast,10\n", COLS)
  plan, = run_plan(dir)
  check.call(plan && plan['charts'].first['sigma_columns'] == %w[x-region y-sales], 'repeated qualifiers are all stripped')
end

# a3. ambiguous base name is disambiguated by table, else aborts
amb = [{ 'id' => 'x-a', 'name' => 'Region', 'table' => 'DIM_A' }, { 'id' => 'x-b', 'name' => 'Region', 'table' => 'DIM_B' },
       { 'id' => 'y-sales', 'name' => 'Sales' }]
Dir.mktmpdir do |dir|
  stage(dir, "Region (DIM_B (SCHEMA_A.DIM_B)),Sales\nEast,10\n", amb)
  plan, = run_plan(dir)
  check.call(plan && plan['charts'].first['sigma_columns'] == %w[x-b y-sales], 'ambiguous base name disambiguated by table qualifier')
end
Dir.mktmpdir do |dir|
  stage(dir, "Region (DIM_C (SCHEMA_A.DIM_C)),Sales\nEast,10\n", amb)
  _, log, st = run_plan(dir)
  check.call(!st.success? && log.include?('ambiguous'), 'unresolvable ambiguity still aborts')
end

# a4. live-proof shape: the DM disambiguates the shared VC field as
# "<field> (<table>)" while the export header is fully qualified — match both ways
dm_cols = [{ 'id' => 'x-region', 'name' => 'Region (DIM_A)' }, { 'id' => 'y-sales', 'name' => 'Sales' }]
Dir.mktmpdir do |dir|
  stage(dir, "Region (DIM_A (SCHEMA_A.DIM_A)),Sales\nEast,10\nWest,20\n", dm_cols)
  plan, log, st = run_plan(dir)
  check.call(st.success? && plan['charts'].first['sigma_columns'] == %w[x-region y-sales],
             "qualified header -> '<field> (<table>)' Sigma column (#{log[0, 160]})")
end
Dir.mktmpdir do |dir|
  stage(dir, "Region,City (DIM_A (SCHEMA_A.DIM_A)),Sales\nEast,X,10\n",
        [{ 'id' => 'x-region', 'name' => 'Region (DIM_A)' }, { 'id' => 'c-city', 'name' => 'City' }, { 'id' => 'y-sales', 'name' => 'Sales' }])
  plan, log, st = run_plan(dir)
  check.call(st.success? && plan['charts'].first['sigma_columns'] == %w[x-region c-city y-sales],
             "plain header -> '<field> (<known VC table>)' Sigma column (#{log[0, 160]})")
end
Dir.mktmpdir do |dir|
  stage(dir, "Region,Sales\nEast,10\n", [{ 'id' => 'x-region', 'name' => 'Region' }, { 'id' => 'y-sales', 'name' => 'Sales (USD)' }])
  _, log, st = run_plan(dir)
  check.call(!st.success? && log.include?('identity is unresolved'), "'Sales (USD)' is not peeled to 'Sales' (USD is no VC table)")
end
Dir.mktmpdir do |dir|
  stage(dir, "Region (DIM_A (SCHEMA_A.DIM_A)),Is Promo (DIM_P (SCHEMA_A.DIM_P)),Sales\nEast,True,10\nWest,False,20\n", dm_cols)
  plan, log, st = run_plan(dir)
  chart = plan && plan['charts'].first
  check.call(st.success? && chart['sigma_columns'] == %w[x-region y-sales] &&
             reason_for.call(chart, 'Is Promo (DIM_P (SCHEMA_A.DIM_P))').to_s.include?('formatting-only'),
             "VC-qualified boolean flag column skipped with reason (#{log[0, 160]})")
end

# b. generated geo columns
Dir.mktmpdir do |dir|
  stage(dir, "Region,Latitude (generated),Longitude (generated),Sales\nEast,1.5,2.5,10\nWest,3.5,4.5,20\n", COLS)
  plan, log, st = run_plan(dir)
  chart = plan && plan['charts'].first
  check.call(st.success?, "generated geo columns do not abort (#{log[0, 200]})")
  check.call(chart && chart['sigma_columns'] == %w[x-region y-sales] && chart['expected'] == [['East', 10.0], ['West', 20.0]],
             'remaining columns compare exactly')
  check.call(chart && reason_for.call(chart, 'Latitude (generated)') && reason_for.call(chart, 'Longitude (generated)'),
             'each skipped geo column is recorded with a reason')
end

# c. formatting-only flag column
Dir.mktmpdir do |dir|
  stage(dir, "Region,Over Target Flag,Sales\nEast,true,10\nWest,false,20\n", COLS)
  plan, = run_plan(dir)
  chart = plan && plan['charts'].first
  check.call(chart && chart['sigma_columns'] == %w[x-region y-sales] && reason_for.call(chart, 'Over Target Flag').to_s.include?('formatting-only'),
             'boolean flag column is skipped with a recorded reason')
end
Dir.mktmpdir do |dir|
  stage(dir, "Region,Mystery,Sales\nEast,5,10\nWest,6,20\n", COLS)
  _, log, st = run_plan(dir)
  check.call(!st.success? && log.include?('identity is unresolved'), 'unmatched numeric column is NOT skipped (hard abort kept)')
end
Dir.mktmpdir do |dir|
  stage(dir, "Region,Mystery,Sales\nEast,Only Member,10\nWest,Only Member,20\n", COLS)
  _, log, st = run_plan(dir)
  check.call(!st.success? && log.include?('identity is unresolved'), 'unmatched singleton text dimension is NOT skipped (hard abort kept)')
end


# d. tooltip-only field (Stress 4 "Store State Map": the CSV exports Orders, a
# field only on the tooltip; Sigma tooltips are UI-only so the element has no
# Orders column) — skipped with a reason; without the tooltip signal it aborts
Dir.mktmpdir do |dir|
  stage(dir, "Region,Orders,Sales\nEast,0,\nWest,7,20\n", COLS)
  lp = File.join(dir, 'dashboard-layout.json')
  layout = JSON.parse(File.read(lp))
  layout[0]['zones'][0]['channels'] = { 'color' => { 'column' => '[ds].[sum:Sales Rank:qk]' },
                                        'tooltip' => { 'column' => '[ds].[sum:Sales Rank:qk]' } }
  layout[0]['zones'][0]['tooltip_fields'] = ['[ds].[sum:Sales Rank:qk]', '[ds].[usr:Sales:qk]']
  # measures / aggregations list every marks-card field (live shape) — not plotting evidence
  layout[0]['zones'][0]['aggregations'] = { '[Sales Rank]' => 'Sum', '[Sales]' => 'User' }
  File.write(lp, JSON.generate(layout))
  File.write(File.join(dir, 'dashboard-layout-meta.json'), JSON.generate(
    'columns_by_guid' => { 'Sales Rank' => { 'caption' => 'Sales' }, 'Sales' => { 'caption' => 'Orders' } }
  ))
  plan, log, st = run_plan(dir)
  chart = plan && plan['charts'].first
  check.call(st.success? && chart['sigma_columns'] == %w[x-region y-sales] &&
             reason_for.call(chart, 'Orders').to_s.include?('tooltip-only'),
             "tooltip-only CSV column skipped despite its GUID being a plotted GUID substring (#{log[0, 160]})")
  File.write(File.join(dir, 'dashboard-layout-meta.json'), '{}')
  layout[0]['zones'][0]['tooltip_fields'] = ['[ds].[sum:Sales Rank:qk]']
  File.write(lp, JSON.generate(layout))
  _, log2, st2 = run_plan(dir)
  check.call(!st2.success? && log2.include?('identity is unresolved'), 'no tooltip-only signal → the unmatched column still aborts')
end

puts
if fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{fails.length}):"
fails.each { |f| puts "  - #{f}" }
exit 1
