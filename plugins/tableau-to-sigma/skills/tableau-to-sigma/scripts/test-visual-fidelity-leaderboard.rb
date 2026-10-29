#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Presentation fidelity for a leaderboard-style dashboard (two blind visual
# graders failed a live migration on these):
#   1. a single mark color (<format attr='mark-color'>, NO color encoding) is
#      carried as color:{by:single,value} instead of the theme's default blue;
#   2. a navigation button's own fill (button-visual-state background-color) lands
#      on the native kind:button as fillColor (the zone-style carries none);
#   3. axis titles: the measure title (yAxis.format.title) and the dimension
#      header (xAxis.format.title) are carried, and each is dropped where the
#      source hides it (Show Field Labels off, cleared/overridden axis title);
#   4. a KPI tile's tinted zone background lands as style.backgroundColor;
#   5. a 'Tableau Bold' title run loses the non-web font family (Sigma falls back
#      to a serif) and keeps its weight as bold.
#
# Deterministic + offline: drives test-fixtures/visual-fidelity-leaderboard.twb
# through parse-twb-layout (.rb AND .py twins) and build-charts-from-signals.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR     = __dir__
FIXTURE = File.join(DIR, 'test-fixtures', 'visual-fidelity-leaderboard.twb')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  layout_rb = File.join(d, 'layout-rb.json')
  layout_py = File.join(d, 'layout-py.json')
  _, st = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'), FIXTURE, layout_rb)
  check(st.success?, 'parse-twb-layout.rb succeeded on the fixture')
  _, st = Open3.capture2e('python3', File.join(DIR, 'parse-twb-layout.py'), FIXTURE, layout_py)
  check(st.success?, 'parse-twb-layout.py succeeded on the fixture')

  zones = lambda do |path|
    JSON.parse(File.read(path)).find { |dd| dd['dashboard'] == 'Demo Board' }['zones']
  end

  puts '== Parser (Ruby + Python twins agree) ===================================='
  [['rb', layout_rb], ['py', layout_py]].each do |tag, path|
    zs = zones.call(path)
    by_cap = ->(c) { zs.find { |z| z['caption'] == c } }
    check(by_cap.call('Store Bars')['mark_color'] == '#1f4e79', "[#{tag}] Store Bars mark_color = #1f4e79")
    check(by_cap.call('Store Bars Quiet')['mark_color'] == '#e76f51', "[#{tag}] Store Bars Quiet mark_color = #e76f51")
    check(by_cap.call('Store Bars Custom')['mark_color'].nil?, "[#{tag}] a sheet with no mark-color has no mark_color")
    check(by_cap.call('Store Bars Quiet')['field_labels_hidden'].sort == %w[cols rows],
          "[#{tag}] hidden field labels surfaced")
    custom = Array(by_cap.call('Store Bars Custom')['axis_titles']).first
    check(custom && custom['scope'] == 'cols' && custom['text'] == 'Revenue (USD)',
          "[#{tag}] explicit axis title override surfaced (got #{custom.inspect})")
    btn = zs.find { |z| z['button_intent'] == 'navigate' }
    check(btn && btn['button_fill_color'] == '#1f4e79', "[#{tag}] nav button fill surfaced from button-visual-state")
    title = zs.find { |z| z['text_runs'] }
    run = title && title['text_runs'].first
    check(run && run['font'].nil? && run['bold'] == true,
          "[#{tag}] 'Tableau Bold' run: family dropped, weight kept as bold (got #{run.inspect})")
  end

  puts '== Builder ==============================================================='
  mmap = File.join(d, 'master-map.json')
  File.write(mmap, JSON.dump(
               '(?i)^Store Name$'  => { 'id' => 'm-store', 'name' => 'Store Name' },
               '(?i)^Net Revenue$' => { 'id' => 'm-rev',   'name' => 'Net Revenue' },
               '(?i)^Region$'      => { 'id' => 'm-region', 'name' => 'Region' }
             ))
  views = %w[Store\ Bars Store\ Bars\ Quiet Store\ Bars\ Custom Net\ KPI]
  File.write(File.join(d, 'get-workbook.json'), JSON.dump(
               'views' => { 'view' => views.each_with_index.map { |n, i| { 'id' => "v#{i + 1}", 'name' => n } } }
             ))
  Dir.mkdir(File.join(d, 'views'))
  bars = "Store Name,Net Revenue\nPortland,100\nBoston,80\nAustin,60\n"
  %w[v1 v3].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), bars) }
  # 'Store Bars Quiet' also carries a Detail dim (Region, no color encoding): the view CSV
  # exports it as a leading column that the chart does not plot.
  File.write(File.join(d, 'views', 'v2.csv'),
             "Region,Store Name,Net Revenue\nWest,Portland,100\nEast,Boston,80\nWest,Austin,60\n")
  File.write(File.join(d, 'views', 'v4.csv'), "Net Revenue\n240\n")
  File.write(File.join(d, 'png-read.json'), JSON.dump(
               'source_png' => 'views/v1.png',
               'tiles' => [
                 { 'title' => 'Store Bars',        'kind' => 'bar-chart', 'orientation' => 'horizontal' },
                 { 'title' => 'Store Bars Quiet',  'kind' => 'bar-chart', 'orientation' => 'horizontal' },
                 { 'title' => 'Store Bars Custom', 'kind' => 'bar-chart', 'orientation' => 'horizontal' },
                 { 'title' => 'Net KPI',           'kind' => 'kpi-chart' }
               ],
               'text_elements' => [], 'filter_shelf' => []
             ))
  charts = File.join(d, 'chart-specs.json')
  blog, bst = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                              '--tableau-dir', d, '--layout', layout_rb,
                              '--meta', File.join(d, 'layout-rb-meta.json'),
                              '--master-map', mmap, '--master-element-id', 'master',
                              '--page-per-dashboard', '--out', charts)
  check(bst.success?, 'the chart build succeeded' + (bst.success? ? '' : " (log:\n#{blog})"))
  raw = JSON.parse(File.read(charts))
  els = raw.is_a?(Hash) ? Array(raw['pages']).flat_map { |p| p['elements'] || [] } : raw
  el = ->(ws) { els.find { |e| e['_worksheet'] == ws || e['id'].to_s.start_with?("el-#{ws.downcase.gsub(/\W+/, '-')}") && e['_worksheet'].nil? } }
  ids = els.map { |e| [e['id'], e['kind'], e['_worksheet']] }

  navy  = el.call('Store Bars')
  quiet = el.call('Store Bars Quiet')
  cust  = el.call('Store Bars Custom')
  check(navy && quiet && cust, "all three bar sheets built (elements: #{ids.inspect})")

  puts '-- 1. single mark colors'
  check(navy && navy['color'] == { 'by' => 'single', 'value' => '#1f4e79' },
        "navy sheet: color:{by:single, value:#1f4e79} (got #{navy && navy['color'].inspect})")
  check(quiet && quiet['color'] == { 'by' => 'single', 'value' => '#e76f51' },
        "orange sheet: color:{by:single, value:#e76f51} (got #{quiet && quiet['color'].inspect})")
  check(cust && cust['color'].nil?, 'a sheet with NO mark color keeps the theme default (no color key)')
  # A Detail dim the CSV defaulted into the color slot stays a column but must sit on a
  # channel: Sigma's element export (and the parity collector) reads only plotted channels,
  # so a bare column makes the view CSV's Region header look missing on a chart that renders.
  detail = quiet && Array(quiet['columns']).find { |c| c['id'].to_s.start_with?('c-') && c['name'] == 'Region' }
  check(detail, "single-color sheet keeps its defaulted Detail dim 'Region' as a column (columns: #{quiet && quiet['columns'].map { |c| c['name'] }.inspect})")
  check(detail && Array(quiet.dig('tooltip', 'columns')).any? { |t| t['id'] == detail['id'] },
        "the Detail dim rides on the tooltip channel so it exports (got tooltip #{quiet && quiet['tooltip'].inspect})")
  check(navy && navy['tooltip'].nil?, 'a single-color sheet with no Detail dim gets no tooltip block')

  puts '-- 3. axis titles (shown vs hidden vs overridden)'
  check(navy && navy.dig('yAxis', 'format', 'title', 'text') == 'Net Revenue',
        "shown: measure axis title carried on yAxis (got #{navy && navy.dig('yAxis', 'format', 'title').inspect})")
  check(navy && navy.dig('xAxis', 'format', 'title', 'text') == 'Store Name',
        "shown: dimension header carried on xAxis (got #{navy && navy.dig('xAxis', 'format', 'title').inspect})")
  check(quiet && quiet.dig('yAxis', 'format', 'title').nil?,
        'hidden (Show Field Labels off, cols): no measure axis title')
  check(quiet && quiet.dig('xAxis', 'format', 'title').nil?,
        'hidden (Show Field Labels off, rows): no dimension header')
  check(cust && cust.dig('yAxis', 'format', 'title', 'text') == 'Revenue (USD)',
        "override: custom axis title text wins (got #{cust && cust.dig('yAxis', 'format', 'title').inspect})")

  puts '-- 4. KPI tile tint'
  kpi = els.find { |e| e['kind'] == 'kpi-chart' }
  check(kpi && kpi['style'] == { 'backgroundColor' => '#f6f8fb' },
        "KPI tile fill carried as style.backgroundColor (got #{kpi && kpi['style'].inspect})")

  puts '-- 2 + 5. nav button fill, bold-sans title'
  btn = els.find { |e| e['kind'] == 'button' }
  check(btn && btn['fillColor'] == '#1f4e79' && btn['fontColor'] == '#ffffff',
        "native button carries fill + font color (got #{btn && btn.values_at('fillColor', 'fontColor').inspect})")
  text = els.find { |e| e['kind'] == 'text' && e['body'].to_s.include?('Leaderboard Overview') }
  body = text && text['body'].to_s
  check(body && !body.include?('font-family') && body.include?('**Store Sales Leaderboard Overview Demo Board**') && body.include?('font-size: 22px'),
        "title text: no font-family, bold markers, size kept (got #{body.inspect})")
end

puts
if $fails.empty?
  puts 'ALL PASS'
else
  puts "#{$fails.size} FAILED:"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
