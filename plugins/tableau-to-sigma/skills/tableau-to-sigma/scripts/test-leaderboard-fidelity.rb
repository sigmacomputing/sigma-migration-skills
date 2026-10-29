#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for four gaps a live migration of a sales-leaderboard workbook exposed, driven end to
# end (offline) through the real parse-twb-layout.rb + build-charts-from-signals.rb +
# build-dashboard-layout.rb on scripts/fixtures/leaderboard-fidelity.twb (synthetic, invented names):
#
#   1. Worksheets whose names differ only by whitespace ('X', 'X ', 'X  ') slugged to ONE element id, so
#      the second and later copies collided (the per-page namespacing fixes a reused worksheet once per
#      PAGE, not once per worksheet) and the layout placed one element several times. Ids are now unique
#      per distinct worksheet name, every id/provenance/zone maps to its own element, and
#      dashboard_read.rb keys png-read tiles by exact title.
#   2. Rank values never reached the chart: (a) a bar whose Label shelf is RANK(SUM(<param measure>))
#      is built with a `label` column carrying Rank(<the control-driven measure>); (b) a Measure
#      Names/Values table whose CSV headers carry " along Table (Down)" resolves its rank / dense-rank /
#      share columns (over a "(copy)" duplicate of the measure) to translated table calcs over a
#      grouped table.
#   3. A table-calc search box (CONTAINS(LOOKUP(MAX(UPPER(<dim>)),0),UPPER(<text parameter>)) kept on
#      true) became a filter over the parameter's control (the control is not "dropped-unused"), and the
#      chart's rank is read back from an UNFILTERED hidden helper so searching does not re-rank the rows.
#   4. A group field's infix `[f] IN ("a", "b")` is emitted as Sigma's In([f], "a", "b").
#
# Usage:  ruby scripts/test-leaderboard-fidelity.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/ruby_compat'
require_relative 'lib/chart_calc_translate'
require_relative 'lib/dashboard_read'

DIR     = __dir__
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
LAYOUT  = File.join(DIR, 'build-dashboard-layout.rb')
FIXTURE = File.join(DIR, 'fixtures', 'leaderboard-fidelity.twb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
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
  # Measure Names/Values long format; the rank calcs' headers carry the table-calc addressing
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

# The verified source-image kind (Phase 1d png-read.json) is what makes the rank table a `table`.
PNG_READ = {
  'verified' => true,
  'tiles' => [{ 'title' => 'Rank Table Yr', 'kind' => 'table' }]
}.freeze

def run_pipeline(twb_text, csvs: CSVS)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    parse_log, = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false, log: parse_log } unless File.exist?(lay)
    views = csvs.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    csvs.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'LB', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'png-read.json'), JSON.dump(PNG_READ))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(base_mmap))
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
    layout_xml = layout_err = nil
    if pages.any?
      wb_ids = { 'pages' => [{ 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] }] +
                            pages.each_with_index.map { |pg, i| { 'id' => "page-#{i + 1}", 'name' => pg['name'], 'elements' => pg['elements'].map { |e| { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'].is_a?(Hash) ? e['name']['text'].to_s : e['name'].to_s } } } } }
      File.write(File.join(d, 'wb-ids.json'), JSON.dump(wb_ids))
      lx = File.join(d, 'layout.xml')
      layout_err, = Open3.capture2e(RUBY, LAYOUT, '--layout', lay, '--wb-ids', File.join(d, 'wb-ids.json'), '--out', lx)
      layout_xml = File.exist?(lx) ? File.read(lx) : nil
    end
    { ok: st.success?, log: log, specs: specs, pages: pages, elements: pages.flat_map { |p| p['elements'] },
      data: (specs.is_a?(Hash) ? specs['data_elements'] : nil) || [],
      provenance: rd.call('chart-provenance.json'), controls: rd.call('dashboard-layout-controls-coverage.json'),
      layout_xml: layout_xml, layout_err: layout_err }
  end
end

# ---------------------------------------------------------------------------------------------
puts 'Part 1 - pure helpers'
{ 'Rank - Mo along Table (Down)' => 'Rank - Mo',
  'Share of Total along Table (Across then Down)' => 'Share of Total',
  'Rank along Store Name' => 'Rank',
  'Rank - Yr along Pane (Down)' => 'Rank - Yr',
  'Volume Measure - Mo' => 'Volume Measure - Mo' }.each do |hdr, want|
  check(strip_tc_addressing(hdr) == want, "strip_tc_addressing(#{hdr.inspect}) => #{want.inspect} (got #{strip_tc_addressing(hdr).inspect})", fails)
end
check(parse_tc_over_operand('RANK(SUM([Volume Measure - Mo (copy)_555]))') ==
      { 'agg' => 'SUM', 'token' => 'Volume Measure - Mo (copy)_555', 'kind' => 'rank', 'direction' => 'desc' },
      'RANK over a (copy)-named operand parses (the parens in the name are not call structure)', fails)
check((parse_tc_over_operand("RANK_DENSE(SUM([m]), 'asc')") || {}).values_at('kind', 'direction') == %w[rank-dense asc],
      'RANK_DENSE with an explicit direction parses', fails)
check((parse_tc_over_operand('SUM([m]) / WINDOW_SUM(SUM([m]))') || {})['kind'] == 'share' &&
      parse_tc_over_operand('SUM([a]) / WINDOW_SUM(SUM([b]))').nil?,
      'share of total parses; a ratio of two different measures does not', fails)
params = [{ 'name' => '[Parameter 2]', 'caption' => 'Store Lookup' }]
sp = parse_search_filter_calc('CONTAINS(LOOKUP(MAX(UPPER([Store Name (group)])),0),UPPER([Parameters].[Parameter 2]))', {}, params)
check(sp && sp['dimension_caption'] == 'Store Name (group)' && sp['param_caption'] == 'Store Lookup' &&
      sp['mode'] == 'contains' && sp['case'] == 'insensitive' && sp['table_calc'],
      "the LOOKUP(...,0) search shape parses (got #{sp.inspect})", fails)
check(parse_search_filter_calc('UPPER([Store]) = UPPER([Parameters].[Parameter 2])', {}, params)&.dig('mode') == 'equals' &&
      parse_search_filter_calc('STARTSWITH([Store], [Parameters].[Parameter 2])', {}, params)&.dig('case') == 'sensitive',
      'an equality and a case-sensitive STARTSWITH search parse', fails)
check(parse_search_filter_calc('CONTAINS(LOOKUP(MAX(UPPER([Store])),1),UPPER([Parameters].[Parameter 2]))', {}, params).nil? &&
      parse_search_filter_calc('SUM([a]) > [Parameters].[Parameter 2]', {}, params).nil?,
      'a LOOKUP with a non-zero offset (not an identity) and a non-search comparison are not search filters', fails)
check(translate_dim_calc('IF [S] IN ("a", "b") THEN 1 ELSE 0 END', {}, {}) == 'If(In([Master/S], "a", "b"), 1, 0)' &&
      translate_row_level_calc("[S] IN ('a', 'b')", {}, {}) == 'In([Master/S], "a", "b")',
      'infix IN becomes the In() function in dimension and row-level calcs', fails)

puts 'Part 2 - dashboard_read keys png-read tiles by exact title'
Dir.mktmpdir do |d|
  File.write(File.join(d, 'png-read.json'), JSON.dump(
    'verified' => true, 'text_elements' => [],
    'tiles' => [{ 'title' => 'X', 'kind' => 'kpi-chart', 'measure' => 'Net Revenue' },
                { 'title' => 'X ', 'kind' => 'kpi-chart' }],
    'filter_shelf' => [{ 'label' => 'Pick', 'target_tiles' => [], 'highlight_tiles' => ['X'] }],
    'point_in_time' => { 'not_applicable' => true, 'reason' => 'synthetic' }
  ))
  _ok, errs = DashboardRead.validate(d)
  check(errs.none? { |e| e.include?('highlight tile "X"') },
        "highlighting tile 'X' resolves to the 'X' tile (its measure is set), not to 'X ' (got #{errs.inspect})", fails)
end

# ---------------------------------------------------------------------------------------------
puts 'Part 3 - pipeline on the leaderboard fixture'
fx = File.read(FIXTURE, encoding: 'utf-8')
run = run_pipeline(fx)
check(run[:ok] && run[:pages].size == 2, "the build ran and produced two dashboard pages (#{run[:log].to_s.lines.last(2).join.strip})", fails)
els = run[:elements]
ids = els.map { |e| e['id'] }
dups = ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
check(dups.empty?, "element ids are unique across the workbook (duplicates: #{dups.inspect})", fails)
kpis = els.select { |e| e['id'].to_s.start_with?('el-kpi-x') }
check(kpis.size == 6, "three whitespace-distinct KPI sheets x two dashboards = 6 KPI elements (got #{kpis.size})", fails)
page1_kpis = run[:pages][0]['elements'].select { |e| e['id'].to_s.start_with?('el-kpi-x') }
check(page1_kpis.map { |e| e['id'] }.uniq.size == 3, 'page 1 carries three distinct KPI ids', fails)
check(page1_kpis.map { |e| e['name'].is_a?(Hash) ? e['name']['text'] : e['name'] }.sort == %w[Net\ Revenue Orders Units],
      'each X sheet became its own tile (Net Revenue / Units / Orders)', fails)
check(ids.include?('el-kpi-x') && ids.include?('el-store-leaderboard-mo'),
      'ids of workbooks without a collision keep their historical form (el-kpi-x, el-store-leaderboard-mo)', fails)
prov = (run[:provenance] || {})['elements'] || {}
prov_ws = kpis.map { |e| prov.dig(e['id'], 'worksheet') }
check(prov_ws.sort == ['X', 'X', 'X ', 'X ', 'X  ', 'X  '],
      "chart-provenance maps each KPI element to its own worksheet (got #{prov_ws.inspect})", fails)
lx = run[:layout_xml].to_s
placed = lx.scan(/elementId="([^"]+)"/).flatten
check(run[:layout_xml] && placed.group_by(&:itself).none? { |_, v| v.size > 1 } && kpis.all? { |e| placed.include?(e['id']) },
      "the layout places every KPI element exactly once (layout: #{run[:layout_err].to_s.lines.last.to_s.strip[0, 160]})", fails)

puts 'Part 4 - the rank label on the bar'
mo = els.find { |e| e['id'] == 'el-store-leaderboard-mo' } || {}
lbl_ref = Array(mo['label']).first
lbl = (mo['columns'] || []).find { |c| lbl_ref && c['id'] == lbl_ref['columnId'] }
check(lbl && lbl['formula'] =~ /\ARank\(Sum\(Switch\(\[ctl-param-units-vs-volume[^\]]*\], 'Units', \[Quantity Ordered\], \[Net Revenue\]\)\), "desc"\)\z/,
      "the Label-shelf rank is a label column Rank(<control-driven measure>) (got #{lbl && lbl['formula']})", fails)
mo_helper = run[:data].find { |e| e['id'] == 'el-store-leaderboard-mo-tc-rank' }
check(lbl && !mo.key?('dataLabel') && mo_helper.nil?,
      "the bar's own value is not printed over the rank label (no dataLabel), and with no search filter the rank is inline (no helper)", fails)
ymeas = (mo['columns'] || []).find { |c| c['id'] == Array(mo.dig('yAxis', 'columnIds')).first }
check(ymeas && lbl && lbl['formula'].include?(ymeas['formula']),
      'the rank ranks the SAME control-driven measure the bar plots', fails)

puts 'Part 5 - Measure Names rank table (CSV headers carry the table-calc addressing)'
rt = els.find { |e| e['id'] == 'el-rank-table-yr' } || {}
# The table keeps Tableau's full header text (" along Table (Down)" included) as the column name.
FULL_HDR = { 'Rank - Yr' => 'Rank - Yr along Table (Down)', 'Dense Rank - Yr' => 'Dense Rank - Yr along Table (Down)',
             'Share of Total' => 'Share of Total along Table (Down)' }.freeze
by_name = ->(n) { (rt['columns'] || []).find { |c| c['name'] == (FULL_HDR[n] || n) } }
check(rt['kind'] == 'table' && rt['groupings'].is_a?(Array) && !rt.key?('xAxis'),
      'the verified-table kind is a grouped (level) table, not a chart with axes', fails)
check(run[:log].to_s !~ /UNRESOLVED measure/, 'no measure of the rank table is left unresolved', fails)
sw = 'Switch\(\[ctl-param-units-vs-volume[^\]]*\], \'Units\', \[Master/Quantity Ordered\], \[Master/Net Revenue\]\)'
check(by_name.call('Rank - Yr')&.dig('formula').to_s =~ /\ARank\(Sum\(#{sw}\), "desc"\)\z/,
      "'Rank - Yr along Table (Down)' (over the (copy) internal name) => Rank(Sum(control-driven measure)) (got #{by_name.call('Rank - Yr')&.dig('formula')})", fails)
check(by_name.call('Dense Rank - Yr')&.dig('formula').to_s =~ /\ARankDense\(Sum\(#{sw}\), "desc"\)\z/, 'dense rank => RankDense(...)', fails)
check(by_name.call('Share of Total')&.dig('formula').to_s =~ /\APercentOfTotal\(Sum\(#{sw}\), "grand_total"\)\z/, 'share of total => PercentOfTotal(...)', fails)
check(by_name.call('Volume Measure - Yr')&.dig('formula').to_s =~ /\ASum\(#{sw}\)\z/,
      'the table measure itself is aggregated (a group calculation, not a row-level Switch)', fails)
grp = (rt['groupings'] || []).first || {}
check(%w[Rank\ -\ Yr Dense\ Rank\ -\ Yr Share\ of\ Total].all? { |n| (grp['calculations'] || []).include?(by_name.call(n)&.dig('id')) } &&
      grp['groupBy'] == [(rt['columns'] || []).first&.dig('id')],
      'the rank / dense rank / share columns are group calculations over the Store Name grouping', fails)
check(grp.dig('sort', 0, 'columnId') == by_name.call('Volume Measure - Yr')&.dig('id'),
      'the table sorts by the measure (the computed-sort "using" field), not by a rank column', fails)

puts 'Part 6 - the search filter (table-calc boolean over a text parameter)'
lk = els.find { |e| e['id'] == 'el-store-lookup' } || {}
srch = (lk['columns'] || []).find { |c| c['name'] == 'Store Lookup Match' }
filt = (lk['filters'] || []).find { |f| srch && f['columnId'] == srch['id'] }
check(srch && srch['formula'] =~ /\AText\(Contains\(Upper\(\[Store Name \(group\)\]\), Upper\(Coalesce\(\[ctl-param-store-lookup[^\]]*\], ""\)\)\)\)\z/,
      "a match column over the Store Lookup control keeps rows whose dimension contains the text, case-insensitively (got #{srch && srch['formula']})", fails)
check(filt && filt['kind'] == 'list' && filt['values'] == ['true'], 'and a `true` list filter applies it (blank control = every row)', fails)
check(run[:pages].all? do |pg|
        ctl = pg['elements'].find { |e| e['kind'] == 'control' && e['name'] == 'Store Lookup' }
        chart = pg['elements'].find { |e| e['id'].to_s.start_with?('el-store-lookup') }
        ctl && chart && (chart['columns'] || []).any? { |c| c['formula'].to_s.include?("[#{ctl['controlId']}]") }
      end, "each page carries the Store Lookup control and its chart reads THAT page's control", fails)
cov = ((run[:controls] || {})['detail'] || []).find { |r| r['name'] == 'Store Lookup' }
check(cov && cov['status'] == 'emitted', "the Store Lookup parameter is emitted, not dropped-unused (got #{cov.inspect})", fails)
blank = (lk['columns'] || []).find { |c| c['name'] == 'Blank Lookup' }
check(blank && blank['formula'] =~ /\AIf\(IsNull\(\[ctl-param-store-lookup[^\]]*\]\) or \[ctl-param-store-lookup[^\]]*\] = "", 0, 1\)\z/,
      "the blank-search color flag reads the parameter's control (got #{blank && blank['formula']})", fails)

puts 'Part 7 - the search must not re-rank the surviving rows'
lk_lbl = (lk['columns'] || []).find { |c| lk['label'] && c['id'] == Array(lk['label']).first['columnId'] }
helper = run[:data].find { |e| e['id'] == 'el-store-lookup-tc-rank' }
check(lk_lbl && helper && lk_lbl['formula'].start_with?("Max(Lookup([#{helper['name']}/Table Calc], "),
      "the chart's rank label is read back from a hidden helper with Lookup() (got #{lk_lbl && lk_lbl['formula'].to_s[0, 90]})", fails)
hcols = (helper || {})['columns'] || []
check(hcols.map { |c| c['name'] } == ['Rank Key', 'Rank Measure', 'Table Calc'] &&
      hcols.last['formula'] == 'Rank([Rank Measure], "desc")' &&
      hcols[1]['formula'] =~ /\ASum\(Switch\(\[ctl-param-units-vs-volume[^\]]*\], 'Units', \[Master\/Quantity Ordered\], \[Master\/Net Revenue\]\)\)\z/ &&
      hcols.none? { |c| c['formula'].to_s.include?('[ctl-param-store-lookup') },
      'the helper ranks the control-driven measure by dimension and never reads the search control', fails)
check(((helper || {})['groupings'] || []).first&.dig('groupBy') == [hcols.first&.dig('id')], 'the helper is grouped at the dimension grain', fails)

puts 'Part 8 - group field IN list'
grp_col = (lk['columns'] || []).find { |c| c['name'] == 'Store Name (group)' }
check(grp_col && grp_col['formula'].include?('In([Master/Store Name], "Harbor Flagship", "Lakeside Standard")') && grp_col['formula'] !~ /\]\s+IN\s*\(/i,
      "the group field's IN list is the In() function (got #{grp_col && grp_col['formula'].to_s[0, 110]})", fails)

if fails.empty?
  puts 'ALL PASS - leaderboard ids, rank labels, rank tables and the search filter carry through'
else
  warn "#{fails.size} failure(s):\n  - #{fails.join("\n  - ")}"
  exit 1
end
