#!/usr/bin/env ruby
# Regression test for build-postpublish-guide.rb — the post-publish
# interactivity guide generator (Workstream D). Locks:
#
#   1. Detection: every interaction class the generator claims to parse is
#      actually detected from the committed fixtures (filter / highlight / URL /
#      nav / parameter / set actions, dynamic zone visibility, drill
#      hierarchies, custom tooltips incl. viz-in-tooltip, toggle / export /
#      goto-sheet buttons) with the right kinds, resolved captions (GUID →
#      caption, "(copy)_<n>" stripped), targets, and field mappings.
#   2. Truthful steps: the guide states the VERIFIED Sigma UI step patterns
#      verbatim ('Use as filter', Button → 'Navigate to page', 'Drill down',
#      Tooltip panel) and never upgrades a no-equivalent interaction (highlight,
#      zone visibility, viz-in-tooltip, show/hide toggle, set action) to a
#      claimed UI path.
#   3. wb-ids enrichment: parameter actions name the built Sigma control;
#      dashboard targets resolve to Sigma pages.
#   4. Zero-action contract: a workbook with no interactivity still gets a
#      guide file (the phase-6 gate requires the file to exist) with the
#      minimal "no interactive actions detected" body and an empty JSON array.
#
# Deterministic + offline + creds-free: drives the ACTUAL CLI against the
# committed test-fixtures/postpublish-*.twb (synthetic XML mirroring the Skills
# Test corpus structures; no customer data).
#
# Usage:  ruby scripts/test-postpublish-guide.rb

require 'json'
require 'tmpdir'
require 'rbconfig'

DIR     = __dir__
SCRIPT  = File.join(DIR, 'build-postpublish-guide.rb')
FIXTURE = File.join(DIR, 'test-fixtures')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def run_guide(twb, dir, extra = [])
  out  = File.join(dir, 'POSTPUBLISH_GUIDE.md')
  json = File.join(dir, 'postpublish-guide.json')
  ok = system(RUBY, SCRIPT, '--twb', twb, '--out', out, '--json-out', json,
              *extra, err: File::NULL)
  raise "generator exited nonzero for #{twb}" unless ok
  # Explicit UTF-8: the guide carries →/⋮/☐ and a LANG-less shell would read
  # it back as US-ASCII, breaking include? checks.
  [File.read(out, encoding: 'UTF-8'), JSON.parse(File.read(json, encoding: 'UTF-8'))]
end

Dir.mktmpdir do |d|
  # ---- 1. Full action fixture (no wb-ids) ----------------------------------
  puts "== postpublish-actions.twb =="
  md, entries = run_guide(File.join(FIXTURE, 'postpublish-actions.twb'), File.join(Dir.mktmpdir))
  by_kind = entries.group_by { |e| e['kind'] }

  expected = {
    'filter-action' => 1, 'highlight-action' => 1, 'url-action' => 1,
    'nav-action' => 1, 'parameter-action' => 1, 'set-action' => 1,
    'drill-hierarchy' => 1, 'custom-tooltip' => 2,
    'show-hide-button' => 1, 'export-button' => 1, 'nav-button' => 1
  }
  expected.each do |kind, n|
    check((by_kind[kind] || []).length == n,
          "detects #{n} #{kind} (got #{(by_kind[kind] || []).length})")
  end
  check(entries.length == expected.values.reduce(:+),
        "total interactions == #{expected.values.reduce(:+)} (got #{entries.length})")
  check(entries.all? { |e| e['sigma_status'] && e['ui_steps'] },
        'every entry carries sigma_status + ui_steps')

  # Filter action: fields from the tsl: link mapping; target dashboard expands
  # to its sheets minus the exclude list.
  fa = (by_kind['filter-action'] || []).first || {}
  check(fa['fields'] == ['Region'], "filter action field mapping resolves to Region (got #{fa['fields'].inspect})")
  fa_sheets = ((fa['targets'] || []).first || {})['sheets'] || []
  check(fa_sheets.include?('Sales by Region') && fa_sheets.include?('Region Detail') &&
        !fa_sheets.include?('Metric Buttons'),
        "filter target expands dashboard sheets minus exclude (got #{fa_sheets.inspect})")
  check(fa['sigma_status'] == 'ui-configurable', 'filter action is ui-configurable')

  # Highlight: no equivalent, never a claimed UI path.
  hl = (by_kind['highlight-action'] || []).first || {}
  check(hl['sigma_status'] == 'no-equivalent', 'highlight action is no-equivalent')
  check(hl['ui_steps'].to_s.include?('no cross-element highlight'),
        "highlight steps state the gap plainly")

  # URL action: template + rewritten Sigma formula with the column ref.
  ua = (by_kind['url-action'] || []).first || {}
  check(ua['url_template'].to_s.include?('https://example.com/orders?id='),
        'URL action carries the template')
  check(ua['sigma_formula'] == '"https://example.com/orders?id=" & [Order ID]',
        "URL rewritten as Sigma concat formula (got #{ua['sigma_formula'].inspect})")

  # Nav action targets the other dashboard.
  na = (by_kind['nav-action'] || []).first || {}
  check(((na['targets'] || []).first || {})['name'] == 'Detail Page',
        'nav action resolves the target dashboard')

  # Parameter action: source field + target parameter captions resolved
  # (Calculation_100 → 'Metric Button', [Parameter 1] → 'Metric Picker').
  pa = (by_kind['parameter-action'] || []).first || {}
  check(pa['fields'] == ['Metric Button'],
        "param action source field caption resolved (got #{pa['fields'].inspect})")
  check(((pa['targets'] || []).first || {})['name'] == 'Metric Picker',
        'param action target parameter caption resolved')
  check(pa['sigma_status'] == 'control-equivalent-built', 'param action is control-equivalent-built')

  # Set action: no equivalent.
  sa = (by_kind['set-action'] || []).first || {}
  check(sa['sigma_status'] == 'no-equivalent' &&
        ((sa['targets'] || []).first || {})['name'] == 'Top Regions Set',
        'set action is no-equivalent with the set named')

  # Drill hierarchy: levels in order.
  dh = (by_kind['drill-hierarchy'] || []).first || {}
  check(dh['fields'] == ['Category', 'Sub-Category', 'Product Name'],
        "drill levels in order (got #{dh['fields'].inspect})")

  # Tooltips: one field tooltip (resolved calc caption), one viz-in-tooltip
  # flagged no-equivalent.
  tips = by_kind['custom-tooltip'] || []
  plain = tips.find { |t| t['caption'] == 'Sales by Region' } || {}
  viz   = tips.find { |t| t['caption'] == 'Region Detail' } || {}
  check(plain['fields'] == ['Profit Ratio'],
        "tooltip calc ref resolves to caption (got #{plain['fields'].inspect})")
  check(viz['viz_in_tooltip'] == true && viz['sigma_status'] == 'no-equivalent',
        'viz-in-tooltip detected and marked no-equivalent')

  # Buttons: toggle names its toggled container's content; goto-sheet button
  # resolves the window uuid to the dashboard; export names the format.
  sh = (by_kind['show-hide-button'] || []).first || {}
  check(((sh['targets'] || []).first || {})['name'].to_s.include?('Filter Panel Sheet'),
        'show/hide toggle names the toggled container content')
  check(sh['sigma_status'] == 'no-equivalent', 'show/hide toggle is no-equivalent')
  nb = (by_kind['nav-button'] || []).first || {}
  check(((nb['targets'] || []).first || {})['name'] == 'Detail Page',
        'goto-sheet button resolves window uuid → dashboard')
  eb = (by_kind['export-button'] || []).first || {}
  check(((eb['targets'] || []).first || {})['name'] == 'export as pdf',
        'export button names the export format')
  check(eb['ui_steps'].to_s.include?('verify in your Sigma version'),
        'export steps carry the verify-in-your-version caveat')

  # Guide text: verified step patterns present verbatim; structure intact.
  [
    "'Use as filter'",
    'Add element → UI → Button',
    "'Navigate to page'",
    "'Drill down'",
    'Tooltip panel',
    'verify the join columns match',
    '## Summary',
    '## Checklist',
    '| ☐ |'
  ].each do |needle|
    check(md.include?(needle), "guide contains #{needle.inspect}")
  end
  check(md.scan(/^\| ☐ \|/).length == entries.length - tips.length + 1,
        'checklist has one row per interaction (tooltips aggregated into one)')

  # ---- 2. wb-ids enrichment -------------------------------------------------
  puts "== postpublish-actions.twb + wb-ids =="
  wb_ids = {
    'workbookId' => 'wb-test',
    'pages' => [
      { 'id' => 'p1', 'name' => 'Overview', 'elements' => [
        { 'id' => 'e1', 'kind' => 'bar-chart', 'name' => 'Sales by Region' },
        { 'id' => 'e2', 'kind' => 'table',     'name' => 'Region Detail' },
        { 'id' => 'c1', 'kind' => 'control',   'name' => 'Metric Picker' }
      ] },
      { 'id' => 'p2', 'name' => 'Detail Page', 'elements' => [] }
    ]
  }
  ids_path = File.join(d, 'wb-ids.json')
  File.write(ids_path, JSON.generate(wb_ids))
  md2, entries2 = run_guide(File.join(FIXTURE, 'postpublish-actions.twb'),
                            File.join(Dir.mktmpdir), ['--wb-ids', ids_path])
  pa2 = entries2.find { |e| e['kind'] == 'parameter-action' } || {}
  check(pa2['ui_steps'].to_s.include?("the Sigma control 'Metric Picker'"),
        'wb-ids: parameter action names the built control')
  fa2 = entries2.find { |e| e['kind'] == 'filter-action' } || {}
  check(((fa2['targets'] || []).first || {})['sigma_page'] == 'Overview',
        'wb-ids: filter target dashboard resolves to the Sigma page')
  check(md2.include?("(Sigma: 'Sales by Region'"),
        'wb-ids: guide annotates matched elements with Sigma names')

  # ---- 3. Zone visibility fixture -------------------------------------------
  puts "== postpublish-zone-visibility.twb =="
  md3, entries3 = run_guide(File.join(FIXTURE, 'postpublish-zone-visibility.twb'),
                            File.join(Dir.mktmpdir))
  zv = entries3.select { |e| e['kind'] == 'zone-visibility' }
  check(zv.length == 1, "detects 1 zone-visibility (got #{zv.length})")
  z = zv.first || {}
  check(z['fields'] == ['Show Detail'],
        "visibility driving field resolves through the graph, (copy)_n stripped (got #{z['fields'].inspect})")
  check(z['caption'].to_s.include?("sheet 'Detail Band'") && z['caption'].to_s.include?('KPI Dash'),
        'visibility zone + dashboard resolved by uuid/zone-id')
  check(z['sigma_status'] == 'no-equivalent' &&
        md3.include?('No direct equivalent today'),
        'zone visibility marked no-equivalent, shipped pattern stated')

  # ---- 4. Zero-action workbook ----------------------------------------------
  puts "== postpublish-empty.twb =="
  dir4 = File.join(Dir.mktmpdir)
  md4, entries4 = run_guide(File.join(FIXTURE, 'postpublish-empty.twb'), dir4)
  check(entries4 == [], 'zero-action workbook emits an empty JSON array')
  check(File.exist?(File.join(dir4, 'POSTPUBLISH_GUIDE.md')),
        'guide file exists even with zero actions (gate contract)')
  check(md4.include?('No interactive actions detected'),
        'zero-action guide states the minimal body')
end

puts ''
if $fails.empty?
  puts 'ALL PASS'
else
  puts "#{$fails.length} FAILURE(S):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
