#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for three dashboard-fidelity gaps two blind visual graders found on a live migration of a
# sales-leaderboard workbook, driven offline through the real parse-twb-layout.rb + build-charts-from-signals.rb
# + build-dashboard-layout.rb on scripts/fixtures/layout-filter-fidelity.twb (synthetic, invented names):
#
#   1. Text tables were clipped. A Tableau text table whose zone shows all 15 rows came out as 8 rows + a
#      partial one + a "SUMMARY n rows - m columns" footer (the footer also eats ~30px of the tile). Now the
#      worksheet `table` hides the summary bar (tableComponents.summaryBar='hidden') and the layout sizes the
#      tile from the worksheet's exported view CSV (distinct rows x a Sigma row pitch + header + title) when the
#      source zone shows them all.
#   2. A quick filter on a CALCULATED dimension had no control. (a) The vendored converter skipped every field
#      whose name ends in "(group)", so a normal class='tableau' IF/IN calc called "Store Name (group)" never
#      became a DM column. (b) Independently, when no master column exists for a calc-bound quick filter the
#      builder now materializes the translated calc on the workbook master (master_calc_columns) and binds the
#      list control to it, instead of recording needs-materialization and shipping no control.
#
#   3. A chart carrying an axis title (xAxis/yAxis.format.title) is laid out at >= 15 grid rows: Sigma silently
#      drops the bottom axis title on a shorter tile (absent at 12-14 rows, drawn at 15+).
#
# Part 1  converter: a class='tableau' calc named "... (group)" is a DM calculated column  (needs `node`)
# Part 2  materialize_calc_filter_master_column: row-level dim / boolean / refusals (pure)
# Part 3  build-charts: control bound to a materialized master column; to a DM-provided one; summary bar hidden
# Part 4  build-dashboard-layout: the 15-row table tile is sized to fit
# Part 5  build-dashboard-layout: an axis-titled chart gets a 15-row floor
#
# Usage:  ruby scripts/test-layout-filter-fidelity.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/ruby_compat'
require_relative 'lib/chart_calc_translate'

DIR      = __dir__
PARSER   = File.join(DIR, 'parse-twb-layout.rb')
BUILD    = File.join(DIR, 'build-charts-from-signals.rb')
LAYOUT   = File.join(DIR, 'build-dashboard-layout.rb')
FIXTURE  = File.join(DIR, 'fixtures', 'layout-filter-fidelity.twb')
VENDORED = File.expand_path('../converter/tableau.mjs', __dir__)
RUBY     = RbConfig.ruby
VENDORED_SPEC =
  if Gem.win_platform? && VENDORED.to_s.match?(/\A[A-Za-z]:/)
    'file:///' + VENDORED.gsub('\\', '/')
  else
    VENDORED
  end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

BUILD_SRC = File.read(BUILD, encoding: 'UTF-8')
%w[unique_col_id mapped_master_names materialize_calc_filter_master_column].each do |fn|
  m = BUILD_SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end
eval(BUILD_SRC[/^CALC_FILTER_NON_ROW_LEVEL_RE =.*?\.freeze$/m] || abort('could not extract CALC_FILTER_NON_ROW_LEVEL_RE')) # rubocop:disable Security/Eval

def base_mmap(extra = [])
  names = { 'Store Name' => 'STORE_NAME', 'Net Revenue' => 'NET_REVENUE', 'Quantity Ordered' => 'QUANTITY_ORDERED' }
  names = names.merge(extra.to_h { |n| [n, n] })
  names.each_with_object({}) do |(name, raw), h|
    entry = { 'id' => "m-#{name.downcase.gsub(/\W+/, '-')}", 'name' => name }
    [name, raw].uniq.each do |alias_name|
      h["(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of |(?:avg|sum|min|max|med|cnt|ctd)\\.\\s*)?#{Regexp.escape(alias_name)}$"] = entry
    end
  end
end

STORES = %w[Harbor\ Flagship Lakeside\ Standard Summit\ Outlet Canyon\ Kiosk Delta\ Standard Eastgate\ Outlet
            Foxhollow\ Flagship Granite\ Kiosk Hillcrest\ Standard Ironwood\ Outlet Juniper\ Flagship Kestrel\ Kiosk
            Lantern\ Standard Meadow\ Outlet Quarry\ Outlet].freeze # 15; the last has no sales (empty measures)
MEASURES = ['Dense Rank - Yr along Table (Down)', 'Rank - Yr along Table (Down)',
            'Share of Total along Table (Down)', 'Volume Measure - Yr'].freeze

def rank_table_csv
  rows = ['Measure Names,Store Name,Measure Values']
  STORES.each_with_index do |store, i|
    last = i == STORES.size - 1
    MEASURES.each { |m| rows << "#{m},#{store},#{last ? '' : (1000 - i * 7)}" }
  end
  rows.join("\n") + "\n"
end

CSVS = {
  'Rank Table Yr' => rank_table_csv,
  'Team Board' => "Store Name (group),Net Revenue\nEast Team,2000\nWest Team,1500\nDelta Standard,900\n"
}.freeze
PNG_READ = { 'verified' => true, 'tiles' => [{ 'title' => 'Rank Table Yr', 'kind' => 'table' }] }.freeze

def run_pipeline(twb_text, mmap:, axis_titled: [], strip_axis_titles: false)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    parse_log, = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false, log: parse_log } unless File.exist?(lay)
    views = CSVS.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    CSVS.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'LF', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'png-read.json'), JSON.dump(PNG_READ))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(mmap))
    out = File.join(d, 'chart-specs.json')
    # Test harness: runs the script under test against a temp-dir fixture; every argument is this file's literal.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                              '--meta', File.join(d, 'dashboard-layout-meta.json'),
                              '--master-map', File.join(d, 'master-columns.json'),
                              '--master-element-id', 'master', '--auto-controls', '--page-per-dashboard',
                              '--skip-dashboard-read', 'offline test fixture', '--out', out)
    rd = ->(n) { f = File.join(d, n); File.exist?(f) ? JSON.parse(File.read(f)) : nil }
    specs = rd.call('chart-specs.json')
    pages = specs.is_a?(Hash) ? specs['pages'] : []
    layout_xml = nil
    # The layout builder reads axis format from the spec beside --layout. The chart builder now emits
    # measure/dimension axis titles itself, so the UNTITLED control case strips them, and `axis_titled`
    # still stamps a title explicitly so the floor is exercised whatever the builder decides.
    if (axis_titled.any? || strip_axis_titles) && specs.is_a?(Hash)
      pages.each do |pg|
        pg['elements'].each do |e|
          if strip_axis_titles
            %w[xAxis yAxis].each { |ax| e[ax]['format'].delete('title') if e[ax].is_a?(Hash) && e[ax]['format'].is_a?(Hash) }
          end
          next unless axis_titled.include?(e['id'])
          e['yAxis'] = (e['yAxis'].is_a?(Hash) ? e['yAxis'] : {}).merge('format' => { 'title' => { 'text' => 'Net Revenue' } })
        end
      end
      File.write(File.join(d, 'chart-specs.json'), JSON.dump(specs))
    end
    if pages.any?
      wb_ids = { 'pages' => [{ 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] }] +
                            pages.each_with_index.map { |pg, i| { 'id' => "page-#{i + 1}", 'name' => pg['name'], 'elements' => pg['elements'].map { |e| { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'].is_a?(Hash) ? e['name']['text'].to_s : e['name'].to_s } } } } }
      File.write(File.join(d, 'wb-ids.json'), JSON.dump(wb_ids))
      lx = File.join(d, 'layout.xml')
      Open3.capture2e(RUBY, LAYOUT, '--layout', lay, '--wb-ids', File.join(d, 'wb-ids.json'), '--out', lx)
      layout_xml = File.exist?(lx) ? File.read(lx, encoding: 'UTF-8') : nil
    end
    { ok: st.success?, log: log, specs: specs, elements: pages.flat_map { |p| p['elements'] },
      scope: rd.call('control-scope.json'), layout_xml: layout_xml }
  end
end

FIXTURE_TEXT = File.read(FIXTURE, encoding: 'utf-8')

# ---------------------------------------------------------------------------------------------
puts 'Part 1 - converter: a class=tableau calc whose NAME ends in "(group)" is a normal calculated DM column'
if `which node 2>/dev/null`.strip.empty?
  warn 'SKIP  node not on PATH - Part 1 not run (install node to enable)'
else
  Dir.mktmpdir do |dir|
    twb = File.join(dir, 'wb.twb')
    File.write(twb, FIXTURE_TEXT)
    drive = File.join(dir, 'drive.mjs')
    File.write(drive, <<~MJS)
      import { convertTableauToSigma } from #{VENDORED_SPEC.to_json};
      import { readFileSync } from 'fs';
      const xml = readFileSync(#{twb.to_json}, 'utf8');
      console.log(JSON.stringify(convertTableauToSigma(xml, { connectionId: 'CONN' })));
    MJS
    out, err, st = Open3.capture3('node', drive)
    abort "node driver failed: #{err}" unless st.success?
    res = JSON.parse(out)
    cols = (res.dig('model', 'pages') || []).flat_map { |p| p['elements'] || [] }.flat_map { |e| e['columns'] || [] }
    grp = cols.find { |c| c['name'] == 'Store Name (group)' && c['formula'].to_s.start_with?('If(') }
    check(!grp.nil? && grp['formula'].include?('"East Team"') && grp['formula'].include?('[Store Name]'),
          "the IF/IN calc [Store Name (group)] reaches the DM as a calculated column (got #{grp.inspect})", fails)
    check((res['warnings'] || []).any? { |w| w.include?('"Store Name (group)" → calculated column') },
          'the conversion is announced (named warning), not silently skipped', fails)
  end
end

# ---------------------------------------------------------------------------------------------
puts
puts 'Part 2 - materialize_calc_filter_master_column (pure)'
mm = base_mmap
group_formula = 'IF [STORE_NAME] IN ("Harbor Flagship", "Lakeside Standard") THEN "East Team" ELSE [STORE_NAME] END'
col = materialize_calc_filter_master_column('Store Name (group)', group_formula, 'string', mm, {}, ['m-store-name'], ['Store Name'])
check(col && col['id'] == 'm-store-name-group' && col['name'] == 'Store Name (group)' &&
      col['formula'] == 'If(In([Store Name], "Harbor Flagship", "Lakeside Standard"), "East Team", [Store Name])',
      "a row-level IF/IN dimension becomes a master column over BARE master refs (got #{col.inspect})", fails)
taken = materialize_calc_filter_master_column('Store Name (group)', group_formula, 'string', mm, {}, ['m-store-name-group'], ['Store Name (group)'])
check(taken && taken['id'] != 'm-store-name-group' && taken['name'] == 'Store Name (group) (filter)',
      "an id / name already on the master is never reused (got #{taken.inspect})", fails)
flag = materialize_calc_filter_master_column('Is Big', '[NET_REVENUE] > 100', 'boolean', mm, {}, [], [])
check(flag && flag['formula'] == 'Text([Net Revenue] > 100)',
      "a boolean calc is Text()-wrapped so the list control filters STRING members (got #{flag.inspect})", fails)
check(materialize_calc_filter_master_column('Big Total', 'SUM([NET_REVENUE])', 'real', mm, {}, [], []).nil?,
      'an aggregate calc is NOT a row-level master column (stays needs-materialization)', fails)
check(materialize_calc_filter_master_column('Picked', 'IF [Parameters].[Parameter 1] = "x" THEN [STORE_NAME] ELSE "y" END', 'string', mm, {}, [], []).nil?,
      'a calc over a parameter is refused (a master column cannot read a control)', fails)
check(materialize_calc_filter_master_column('Ghost', 'IF [NOT_A_COLUMN] = "a" THEN "b" ELSE "c" END', 'string', mm, {}, [], []).nil?,
      'a calc over a column the master map does not expose is refused (no dangling ref)', fails)

# ---------------------------------------------------------------------------------------------
puts
puts 'Part 3 - build-charts: the calc-bound quick filter gets a control; the table hides its summary bar'
# 3a: the master map has NO column for the calc (a reused DM that predates it): materialize + bind.
run = run_pipeline(FIXTURE_TEXT, mmap: base_mmap)
puts run[:log] if ENV['DEBUG_LOG']
check(run[:ok], "build-charts exits 0 (got: #{run[:log].to_s.lines.grep(/Error/).first(2).inspect})", fails)
mcc = Array((run[:specs].is_a?(Hash) ? run[:specs]['master_calc_columns'] : nil))
mcol = mcc.find { |c| c['name'] == 'Store Name (group)' }
check(mcol && mcol['formula'].to_s.start_with?('If(') && !mcol['formula'].include?('[Master/'),
      "the calc rides master_calc_columns with bare master refs (got #{mcc.inspect})", fails)
ctl = run[:elements].find { |e| e['kind'] == 'control' && e['name'].to_s == 'Store Name (group)' }
check(ctl && mcol && ctl.dig('source', 'columnId') == mcol['id'] && ctl.dig('source', 'source', 'elementId') == 'master' &&
      ctl['controlType'] == 'list' && Array(ctl['filters']).any?,
      "a list control is bound to the materialized master column and targets the charts (control: #{ctl.inspect[0, 220]})", fails)
rec = Array((run[:scope] || {}).is_a?(Hash) ? run[:scope]['controls'] || run[:scope]['records'] : run[:scope])
          .find { |r| r.is_a?(Hash) && r['name'] == 'Store Name (group)' }
check(rec.nil? || rec['status'] == 'emitted', "the control is recorded emitted, not needs-materialization (got #{rec.inspect})", fails)
check(run[:log].to_s.include?('materialized it on the master') && !run[:log].to_s.include?('binds to a CALCULATED field, not a raw column'),
      'the build log says the calc was materialized, not "materialize it on the master, then add a master-columns.json regex"', fails)

# 3b: the DM already carries the calc (the converter fix): bind to it, add nothing to the master.
mm2 = base_mmap(['Store Name (group)'])
dm_col_id = mm2.values.find { |e| e['name'] == 'Store Name (group)' }['id']
run2 = run_pipeline(FIXTURE_TEXT, mmap: mm2)
ctl2 = run2[:elements].find { |e| e['kind'] == 'control' && e['name'].to_s == 'Store Name (group)' }
check(ctl2 && ctl2.dig('source', 'columnId') == dm_col_id &&
      Array((run2[:specs].is_a?(Hash) ? run2[:specs]['master_calc_columns'] : nil)).none? { |c| c['name'] == 'Store Name (group)' },
      "with the calc on the master map the control binds to that column and nothing is re-materialized (columnId #{ctl2 && ctl2.dig('source', 'columnId').inspect}; master_calc_columns #{(run2[:specs].is_a?(Hash) ? run2[:specs]['master_calc_columns'] : nil).inspect[0, 200]})", fails)

# 3c: the worksheet table drops Sigma's SUMMARY footer; other kinds are untouched.
tbl = run[:elements].find { |e| e['kind'] == 'table' && e['name'].to_s == 'Rank Table' }
bar = run[:elements].find { |e| e['kind'] == 'bar-chart' }
check(tbl && tbl['tableComponents'] == { 'summaryBar' => 'hidden' },
      "the rank table carries tableComponents.summaryBar='hidden' (got #{(tbl || {})['tableComponents'].inspect})", fails)
check(bar && !bar.key?('tableComponents'), 'a chart element gets no tableComponents', fails)

# ---------------------------------------------------------------------------------------------
puts
puts 'Part 4 - build-dashboard-layout: the table tile is sized to show every source row'
xml = run[:layout_xml].to_s
m = xml.match(%r{<Element elementId="el-rank-table-yr" gridColumn="[^"]+" gridRow="(\d+) / (\d+)"})
span = m ? m[2].to_i - m[1].to_i : 0
need_px = 15 * 20 + 30 + 72 + 43 # 15 rows + header + card-top + card chrome (see SIGMA_TABLE_* in the builder)
check(m && span * 28 >= need_px,
      "the 15-row rank table spans >= #{(need_px / 28.0).ceil} grid rows so every row fits (got #{span})", fails)
# Use a genuinely short source tile for the axis-title floor comparison. Removing
# an invented page header otherwise gives the original tile enough room already.
short_fixture = FIXTURE_TEXT.sub("h='44000' id='23'", "h='30000' id='23'")
untitled = run_pipeline(short_fixture, mmap: base_mmap, strip_axis_titles: true)
bar_m = untitled[:layout_xml].to_s.match(%r{<Element elementId="el-team-board" gridColumn="[^"]+" gridRow="(\d+) / (\d+)"})
bar_span = bar_m ? bar_m[2].to_i - bar_m[1].to_i : 0
check(bar_m && bar_span >= 4, 'the chart beside it is still placed (layout intact)', fails)

puts
puts 'Part 5 - build-dashboard-layout: a chart that carries an axis title gets a 15-row floor'
# Sigma drops the BOTTOM axis title below 15 grid rows (probe: absent at 12-14, drawn at 15+).
titled = run_pipeline(short_fixture, mmap: base_mmap, axis_titled: ['el-team-board'])
tm = titled[:layout_xml].to_s.match(%r{<Element elementId="el-team-board" gridColumn="[^"]+" gridRow="(\d+) / (\d+)"})
tspan = tm ? tm[2].to_i - tm[1].to_i : 0
check(bar_span < 15 && tspan >= 15,
      "an axis-titled chart spans >= 15 rows (got #{tspan}); the same chart with no title keeps its source height (#{bar_span} < 15)", fails)
trm = titled[:layout_xml].to_s.match(%r{<Element elementId="el-rank-table-yr" gridColumn="[^"]+" gridRow="(\d+) / (\d+)"})
check(trm && trm[2].to_i - trm[1].to_i >= span,
      'growing the chart pushes later bands down: the rank table keeps its full-row height and the page still lays out', fails)

puts
if fails.empty?
  puts 'test-layout-filter-fidelity: ALL PASS'
else
  puts "test-layout-filter-fidelity: #{fails.size} FAIL"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
