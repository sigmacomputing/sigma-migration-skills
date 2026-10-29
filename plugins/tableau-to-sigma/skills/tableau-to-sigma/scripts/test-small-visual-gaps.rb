#!/usr/bin/env ruby
# frozen_string_literal: true
# Three small visual-fidelity gaps blind graders flagged on a live leaderboard migration, driven offline
# through parse-twb-layout.rb + build-charts-from-signals.rb on scripts/fixtures/leaderboard-fidelity.twb
# (synthetic; a parameter zone is injected at run time):
#
#   1. A parameter control that SITS on a dashboard but that no worksheet reads is inert in Tableau too,
#      yet the builder dropped it (a gap in the filter column). It is now emitted (default from the .twb)
#      and marked source-inert (control-scope sourceInert:true, coverage status 'source-inert') so the
#      dead-control lint, the control-flip probe and the needs-wiring blocker leave it alone. A parameter
#      NO dashboard shows is still refused, and only the marked control is exempt.
#   2. A rank label on a bar (label: [{columnId}]) rendered inside the longest bar, clipped. A reference
#      line at 1.15x the longest bar (relative: it follows the measure) widens the axis so the label sits
#      past the bar end (live-probed; dataLabel.anchor and a formula scale.domain.max do not work).
#   3. The rank table's column header lost Tableau's "along Table (Down)" tail. The column now keeps the
#      full header, and the parity plan still matches it (the CSV is pivoted under the base name).
#
# Usage:  ruby scripts/test-small-visual-gaps.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'csv'
require_relative 'lib/ruby_compat'
require_relative 'lib/control_lint'

DIR     = __dir__
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
PLAN_RB = File.join(DIR, 'auto-parity-plan.rb')
PLAN_PY = File.join(DIR, 'auto-parity-plan.py')
GATE_RB = File.join(DIR, 'assert-reconstruction-integrity.rb')
GATE_PY = File.join(DIR, 'assert-reconstruction-integrity.py')
FIXTURE = File.join(DIR, 'fixtures', 'leaderboard-fidelity.twb')
RUBY    = RbConfig.ruby

fails = []
check = lambda do |cond, msg|
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Two extra parameters on top of the leaderboard fixture: 'Fiscal Year Param' sits on the Monthly dashboard
# only (read by no worksheet), 'Orphan Year' sits on no dashboard at all.
def with_inert_params(text)
  extra = <<~XML
    <column caption='Fiscal Year Param' datatype='integer' name='[Parameter 3]' param-domain-type='any' role='measure' type='quantitative' value='2024'>
      <calculation class='tableau' formula='2024' />
    </column>
    <column caption='Orphan Year' datatype='integer' name='[Parameter 4]' param-domain-type='any' role='measure' type='quantitative' value='2020'>
      <calculation class='tableau' formula='2020' />
    </column>
  XML
  text = text.sub("    </datasource>\n    <datasource caption='Sales Leaderboards'", "#{extra}    </datasource>\n    <datasource caption='Sales Leaderboards'")
  zone = "<zone h='12000' id='12' mode='type_in' param='[Parameters].[Parameter 3]' type-v2='paramctrl' w='30000' x='60000' y='12000' />\n"
  text.sub("            <zone h='12000' id='18' name='X' w='13000' x='60000' y='0' />\n",
           "#{zone}            <zone h='12000' id='18' name='X' w='13000' x='60000' y='0' />\n")
end

def base_mmap
  { 'Store Name' => 'STORE_NAME', 'Quantity Ordered' => 'QUANTITY_ORDERED', 'Net Revenue' => 'NET_REVENUE' }
    .each_with_object({}) do |(name, raw), h|
    entry = { 'id' => "m-#{name.downcase.gsub(/\W+/, '-')}", 'name' => name }
    [name, raw].each do |alias_name|
      h["(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of |(?:avg|sum|min|max|med|cnt|ctd)\\.\\s*)?#{Regexp.escape(alias_name)}$"] = entry
    end
  end
end

CSVS = {
  'Store Leaderboard Mo' => "Store Name,Rank - Mo,Volume Measure - Mo\nHarbor Flagship,1,\"16,920.69\"\nSummit Outlet,2,\"16,372.62\"\n",
  'Rank Table Yr' => "Measure Names,Store Name,Measure Values\n" \
                     "Dense Rank - Yr along Table (Down),Harbor Flagship,1\n" \
                     "Rank - Yr along Table (Down),Harbor Flagship,1\n" \
                     "Share of Total along Table (Down),Harbor Flagship,0.0876\n" \
                     "Volume Measure - Yr,Harbor Flagship,\"16,920.69\"\n" \
                     "Dense Rank - Yr along Table (Down),Summit Outlet,2\n" \
                     "Rank - Yr along Table (Down),Summit Outlet,2\n" \
                     "Share of Total along Table (Down),Summit Outlet,0.0848\n" \
                     "Volume Measure - Yr,Summit Outlet,\"16,372.62\"\n",
  'Store Lookup' => "Blank Lookup,Store Name (group),Rank - Mo,Volume Measure - Mo\n0,East Team,1,\"64,887.9\"\n0,West Team,2,\"44,859.44\"\n",
  'X' => "Net Revenue\n\"1,000.00\"\n",
  'X ' => "Quantity Ordered\n\"250\"\n",
  'X  ' => "Avg. Net Revenue\n\"40.00\"\n"
}.freeze

# Drive the pipeline once and hand the workdir to the block (the checks read several artifacts).
def with_build(twb_text)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'wb.twb'), twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    Open3.capture2e(RUBY, PARSER, File.join(d, 'wb.twb'), lay)
    return nil unless File.exist?(lay)
    views = CSVS.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    CSVS.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'LB', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'png-read.json'),
               JSON.dump('verified' => true, 'tiles' => [{ 'title' => 'Rank Table Yr', 'kind' => 'table' }]))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(base_mmap))
    out = File.join(d, 'chart-specs.json')
    log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                              '--meta', File.join(d, 'dashboard-layout-meta.json'),
                              '--master-map', File.join(d, 'master-columns.json'),
                              '--master-element-id', 'master', '--auto-controls', '--page-per-dashboard',
                              '--skip-dashboard-read', 'offline test fixture', '--out', out)
    rd = ->(n) { f = File.join(d, n); File.exist?(f) ? JSON.parse(File.read(f)) : nil }
    specs = rd.call('chart-specs.json')
    pages = specs.is_a?(Hash) ? specs['pages'] : []
    return yield({ dir: d, ok: st.success?, log: log, pages: pages, elements: pages.flat_map { |p| p['elements'] },
                   scope: rd.call('control-scope.json'), coverage: rd.call('dashboard-layout-controls-coverage.json') })
  end
end

puts 'Part 1 - the build'
with_build(with_inert_params(File.read(FIXTURE, encoding: 'utf-8'))) do |run|
  check.call(run[:ok] && run[:pages].size == 2, "the build ran and produced two dashboard pages (#{run[:log].to_s.lines.last(2).join.strip})")
  els = run[:elements]
  ctls = ->(page, name) { run[:pages].find { |p| p['name'] == page }['elements'].select { |e| e['kind'] == 'control' && e['name'] == name } }

  puts '-- 1. source-inert parameter controls'
  fy = ctls.call('Monthly Board', 'Fiscal Year Param').first
  check.call(fy && fy['controlType'] == 'number' && fy['value'] == 2024,
             "an unread parameter shown on a dashboard is emitted as a number control with the .twb default 2024 (got #{fy.inspect})")
  check.call(ctls.call('Annual Board', 'Fiscal Year Param').empty?,
             'it is placed only on the dashboard that shows it (the Annual dashboard has no such zone)')
  check.call(els.none? { |e| e['kind'] == 'control' && e['name'] == 'Orphan Year' },
             'a parameter NO dashboard shows is still refused (no control on any page)')
  scope = (run[:scope] || {})
  entry = Array(scope['controls']).find { |c| c['name'] == 'Fiscal Year Param' }
  check.call(entry && entry['sourceInert'] == true && entry['status'] == 'source-inert' && entry['controlId'] == fy&.dig('controlId'),
             "control-scope.json marks it sourceInert on the page's own controlId (got #{entry && entry.slice('controlId', 'status', 'sourceInert').inspect})")
  check.call(Array(scope['controls']).select { |c| c['sourceInert'] }.size == 1,
             'only that one control carries the marker (Units vs Volume, Store Lookup, the filters do not)')
  rows = ((run[:coverage] || {})['detail'] || [])
  cov = rows.find { |r| r['name'] == 'Fiscal Year Param' }
  check.call(cov && cov['status'] == 'source-inert' && cov['reason'].to_s.include?('inert in Tableau too'),
             "coverage reports status source-inert with the reason (got #{cov.inspect})")
  orphan = rows.find { |r| r['name'] == 'Orphan Year' }
  check.call(orphan && orphan['status'] == 'needs-wiring',
             "the refused parameter keeps its needs-wiring status (got #{orphan.inspect})")

  puts '-- 2. rank label headroom'
  bars = els.select { |e| e['kind'] == 'bar-chart' && e['label'].is_a?(Array) && !e['label'].empty? }
  check.call(bars.size >= 3, "ranked bar charts were built (#{bars.map { |e| e['id'] }.inspect})")
  mo = els.find { |e| e['id'] == 'el-store-leaderboard-mo' } || {}
  ymeas = (mo['columns'] || []).find { |c| c['id'] == Array(mo.dig('yAxis', 'columnIds')).first } || {}
  marks = Array(mo['refMarks'])
  check.call(marks.size == 1 && marks[0]['type'] == 'line' && marks[0]['axis'] == 'series' &&
             marks[0].dig('value', 'formula') == "Max([#{ymeas['name']}]) * 1.15",
             "a ranked bar carries ONE reference line at 1.15x its own measure column (got #{marks.inspect})")
  check.call(marks.all? { |m| m.dig('line', 'color') == '#ffffff' && !m.key?('label') },
             'the reference line is the white, unlabeled kind (invisible)')
  check.call(bars.all? { |e| Array(e['refMarks']).any? { |m| m.dig('value', 'formula').to_s.start_with?('Max([') } },
             'every rank-labelled bar gets the headroom line (control-driven measures too, the formula is relative)')
  check.call(els.reject { |e| e['label'].is_a?(Array) && !e['label'].empty? }.none? { |e| e['refMarks'] },
             'elements without a rank label get no reference line')

  puts '-- 3. rank table header'
  rt = els.find { |e| e['id'] == 'el-rank-table-yr' } || {}
  names = (rt['columns'] || []).map { |c| c['name'] }
  check.call(names.include?('Rank - Yr along Table (Down)') && names.include?('Dense Rank - Yr along Table (Down)') &&
             names.include?('Share of Total along Table (Down)'),
             "the rank table columns keep Tableau's full header text (got #{names.inspect})")
  check.call(names.include?('Volume Measure - Yr'), 'a measure header without addressing is unchanged')
  # Nothing references a rank column by name: every reference to the table's columns is by id.
  check.call(els.none? { |e| e['id'] != rt['id'] && e.to_json.include?('[Annual Rank Table/') },
             'no other element reads the rank table by column name')

  puts '-- 3b. parity plan still matches'
  rt_view = 'Rank Table Yr'
  wb = { 'workbookId' => 'wb-neutral', 'latestDocumentVersion' => 1,
         'document' => { 'schemaVersion' => 4, 'pages' => [{ 'id' => 'p1', 'name' => 'Annual Board' }],
                         'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Master' }] + [rt] } }
  spec_path = File.join(run[:dir], 'wb-spec.json')
  File.write(spec_path, JSON.dump(wb))
  # The python twin's strict completeness gate needs every source tile mapped; it is covered by
  # test_auto_parity_plan.py (test_table_keeps_full_header_as_column_name_and_still_matches).
  out_path = File.join(run[:dir], 'plan-rb.json')
  log, = Open3.capture2e(RUBY, PLAN_RB, '--tableau', run[:dir], '--workbook-spec', spec_path, '--out', out_path)
  plan = File.exist?(out_path) ? JSON.parse(File.read(out_path)) : {}
  chart = Array(plan['charts']).find { |c| c['tableau_view'] == rt_view } || {}
  got = Array(chart['sigma_columns'])
  check.call(got.length == 5 && got.include?('y0-el-rank-table-yr') && got.include?('y1-el-rank-table-yr') &&
             !log.include?('did not all match'),
             "the CSV's pivoted rank headers resolve onto the full-name rank columns (got #{got.inspect})")
  check.call(Array(chart['expected']).first.to_a.length == got.length,
             'expected rows carry a value per matched column')
end

puts 'Part 2 - gates honour the marker, and only the marker'
spec = {
  'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
  'elements' => [
    { 'id' => 'chart-1', 'kind' => 'bar-chart', 'name' => 'Chart', 'source' => { 'kind' => 'table', 'elementId' => 'tbl-1' } },
    { 'id' => 'tbl-1', 'kind' => 'table', 'name' => 'T' },
    { 'id' => 'ctl-inert', 'kind' => 'control', 'controlId' => 'ctl-param-inert-p1', 'name' => 'Inert', 'controlType' => 'number', 'value' => 1 },
    { 'id' => 'ctl-dead', 'kind' => 'control', 'controlId' => 'ctl-param-dead-p1', 'name' => 'Dead', 'controlType' => 'number', 'value' => 1 }
  ],
  'layout' => '<Page id="p1"><Element elementId="chart-1"/><Element elementId="tbl-1"/><Element elementId="ctl-inert"/><Element elementId="ctl-dead"/></Page>'
}
mk_scope = lambda do |inert_flag, dead_flag|
  c = ->(cid, name, flag) { { 'controlId' => cid, 'name' => name, 'scope' => [], 'sourceInert' => flag }.compact }
  { 'sourceFilterSignals' => 2, 'controls' => [c.call('ctl-param-inert-p1', 'Inert', inert_flag), c.call('ctl-param-dead-p1', 'Dead', dead_flag)] }
end
dead = ->(vs, cid) { vs.any? { |v| v.include?('dead control') && v.include?(cid) } }
v = ControlLint.lint(spec, scope: mk_scope.call(true, nil))
check.call(!dead.call(v, 'ctl-param-inert-p1') && dead.call(v, 'ctl-param-dead-p1'),
           "lint: the sourceInert-marked control passes; an unmarked empty-reach control is still a dead control (got #{v.inspect})")
v = ControlLint.lint(spec, scope: mk_scope.call(nil, nil))
check.call(dead.call(v, 'ctl-param-inert-p1') && dead.call(v, 'ctl-param-dead-p1'),
           'lint: without the marker both controls are dead controls (the exemption is the marker, not the control kind)')
v = ControlLint.lint(spec, scope: mk_scope.call(false, nil))
check.call(dead.call(v, 'ctl-param-inert-p1'), 'lint: sourceInert:false does not exempt')
v = ControlLint.lint(spec, scope: nil)
check.call(dead.call(v, 'ctl-param-inert-p1'), 'lint: no sidecar at all, no exemption')

[['rb', [RUBY, GATE_RB]], ['py', ['python3', GATE_PY]]].each do |tag, cmd|
  { 'source-inert' => true, 'needs-wiring' => false }.each do |status, passes|
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'neutral-controls-coverage.json'), JSON.pretty_generate(
        'detail' => [{ 'kind' => 'parameter', 'name' => 'Fiscal Year Param', 'status' => status }]
      ))
      _o, err, st = Open3.capture3(*cmd, '--workdir', dir)
      check.call(st.success? == passes, "[#{tag}] reconstruction integrity #{passes ? 'passes' : 'blocks'} a #{status} control (#{err.lines.first.to_s.strip[0, 100]})")
    end
  end
end

probe = File.read(File.join(DIR, 'probe-controls.rb'))
check.call(probe.include?("c['sourceInert'] == true") && probe.include?('SOURCE_INERT.include?(cid)'),
           'probe-controls: an empty-reach control is skipped only when the sidecar marks it sourceInert')
phase6 = File.read(File.join(DIR, 'assert-phase6-ran.rb'))
check.call(phase6.include?("%w[emitted source-inert].include?(status)"), 'gate 7c: a source-inert census row counts as built')
report = File.read(File.join(DIR, 'build-migration-report.rb'))
check.call(report.include?("'source-inert' => 'approximated'"), 'migration report: source-inert maps to approximated')

puts
if fails.empty?
  puts 'ALL PASS - inert controls, rank-label headroom and full rank headers carry through'
else
  warn "#{fails.size} failure(s):\n  - #{fails.join("\n  - ")}"
  exit 1
end
