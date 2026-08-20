#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression coverage for dashboard-page eligibility:
# - text/image-only dashboards (User Guide) are real pages;
# - storyboards and parser-marked hidden/parameter dashboards are not emitted
#   as ordinary pages;
# - truly empty dashboards remain omitted.
require 'json'
require 'open3'
require 'tmpdir'

BUILD = File.join(__dir__, 'build-charts-from-signals.rb')
PARSER = File.join(__dir__, 'parse-twb-layout.rb')

fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

layout = [
  {
    'dashboard' => 'User Guide',
    'is_story' => false,
    'zones' => [
      {
        'id' => 'guide-copy', 'kind' => 'text',
        'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100,
        'text_runs' => [{ 'text' => 'How to use this dashboard' }]
      }
    ]
  },
  {
    'dashboard' => 'Executive Story',
    'is_story' => true,
    'zones' => [
      {
        'id' => 'story-copy', 'kind' => 'text',
        'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100,
        'text_runs' => [{ 'text' => 'Story chrome' }]
      }
    ]
  },
  {
    'dashboard' => 'Harrison Parameter',
    'is_story' => false,
    'emit_page' => false,
    'zones' => [
      {
        'id' => 'hidden-copy', 'kind' => 'text',
        'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100,
        'text_runs' => [{ 'text' => 'Hidden parameter dashboard' }]
      }
    ]
  },
  { 'dashboard' => 'Actually Empty', 'is_story' => false, 'zones' => [] }
]
meta = {
  'worksheets' => {}, 'stories' => [], 'shared_filters' => [],
  'parameters' => [], 'column_aliases' => {}, 'columns_by_guid' => {}
}

result = nil
log = nil
Dir.mktmpdir do |dir|
  layout_path = File.join(dir, 'layout.json')
  meta_path = File.join(dir, 'meta.json')
  mmap_path = File.join(dir, 'master-map.json')
  out_path = File.join(dir, 'specs.json')
  File.write(layout_path, JSON.generate(layout))
  File.write(meta_path, JSON.generate(meta))
  File.write(mmap_path, JSON.generate({}))
  File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))
  Dir.mkdir(File.join(dir, 'views'))
  stdout, stderr, status = Open3.capture3(
    'ruby', BUILD,
    '--tableau-dir', dir,
    '--layout', layout_path,
    '--meta', meta_path,
    '--master-map', mmap_path,
    '--master-element-id', 'master',
    '--page-per-dashboard',
    '--skip-dashboard-read', 'unit-test',
    '--title', 'Eligibility Test',
    '--out', out_path
  )
  log = stdout + stderr
  check(status.success?, "builder exits 0 (#{status.exitstatus}): #{log.lines.first}", fails)
  result = JSON.parse(File.read(out_path)) if File.exist?(out_path)
end

pages = result && result['pages'] || []
names = pages.map { |page| page['name'] }
check(names == ['User Guide'], "only the eligible text-only dashboard is emitted (got #{names.inspect})", fails)
guide = pages.first || {}
guide_text = (guide['elements'] || []).select { |element| element['kind'] == 'text' }
check(guide_text.any? { |element| element['body'].to_s.include?('How to use this dashboard') },
      'text-only dashboard keeps its source content', fails)

parsed = nil
Dir.mktmpdir do |dir|
  twb = File.join(dir, 'visibility.twb')
  out = File.join(dir, 'layout.json')
  File.write(twb, <<~XML)
    <workbook>
      <dashboards>
        <dashboard name='User Guide'><zones id='visible-root'/></dashboard>
        <dashboard name='Harrison Parameter'><zones id='hidden-root'/></dashboard>
      </dashboards>
      <windows>
        <window class='dashboard' name='User Guide'/>
        <window class='worksheet' hidden='true' name='Parameter Host'/>
      </windows>
    </workbook>
  XML
  _stdout, stderr, status = Open3.capture3('ruby', PARSER, twb, out)
  check(status.success?, "parser exits 0 for visibility fixture (#{status.exitstatus}): #{stderr.lines.first}", fails)
  parsed = JSON.parse(File.read(out)) if File.exist?(out)
end
visibility = (parsed || []).to_h { |dashboard| [dashboard['dashboard'], dashboard['emit_page']] }
check(visibility['User Guide'] == true && visibility['Harrison Parameter'] == false,
      "parser maps visible windows to page eligibility (got #{visibility.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — text-only dashboards survive; story/hidden/empty debris stays out'
  exit 0
end

puts "FAILURES (#{fails.length}):"
fails.each { |failure| puts "  - #{failure}" }
exit 1
