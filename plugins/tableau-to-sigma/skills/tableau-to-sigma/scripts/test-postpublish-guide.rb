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
  json = File.join(dir, 'action-ledger.json')
  ok = system(RUBY, SCRIPT, '--twb', twb, '--out', out, '--json-out', json,
              *extra, err: File::NULL)
  raise "generator exited nonzero for #{twb}" unless ok
  # Explicit UTF-8: the guide carries →/⋮/☐ and a LANG-less shell would read
  # it back as US-ASCII, breaking include? checks.
  # --json-out now writes the LEDGER OBJECT ({schemaVersion, detectedCount,
  # emitted, residue}), not a bare entries array — that is the contract Task
  # 6's gates read. Callers that want "all detected interactions" (nothing
  # was passed via --emitted-manifest) should read ledger['residue'], which
  # equals the full detected set when nothing was auto-wired.
  [File.read(out, encoding: 'UTF-8'), JSON.parse(File.read(json, encoding: 'UTF-8'))]
end

# Slice out one rendered section's markdown by its heading, e.g.
# "## 3. Parameter actions (1)\n\n...body...\n## 4. Set actions ...". Used to
# check the per-entry "Sigma status" badge text without the JSON carrying a
# raw sigma_status field any more (status is now derived from kind + ledger
# membership at render time, not asserted per-entry).
def section_text(md, title)
  md[/^## \d+\. #{Regexp.escape(title)}\b.*?(?=\n## \d+\.|\n## Checklist|\z)/m] || ''
end

Dir.mktmpdir do |d|
  # ---- 1. Full action fixture (no wb-ids) ----------------------------------
  puts "== postpublish-actions.twb =="
  md, ledger = run_guide(File.join(FIXTURE, 'postpublish-actions.twb'), File.join(Dir.mktmpdir))
  # No --emitted-manifest was passed, so nothing was auto-wired: residue ==
  # every detected interaction, same content the old bare-array contract used
  # to hand back directly.
  entries = ledger['residue']
  check(ledger['detectedCount'] == entries.length, 'no manifest passed: residue == everything detected')
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
  check(entries.all? { |e| e['ui_steps'] }, 'every entry carries ui_steps')
  check(entries.none? { |e| e.key?('sigma_status') },
        'entries no longer carry a hardcoded sigma_status field — status is now ' \
        'derived from kind + ledger membership at render time, not asserted per-entry')

  # Filter action: fields from the tsl: link mapping; target dashboard expands
  # to its sheets minus the exclude list.
  fa = (by_kind['filter-action'] || []).first || {}
  check(fa['fields'] == ['Region'], "filter action field mapping resolves to Region (got #{fa['fields'].inspect})")
  fa_sheets = ((fa['targets'] || []).first || {})['sheets'] || []
  check(fa_sheets.include?('Sales by Region') && fa_sheets.include?('Region Detail') &&
        !fa_sheets.include?('Metric Buttons'),
        "filter target expands dashboard sheets minus exclude (got #{fa_sheets.inspect})")
  check(section_text(md, 'Cross-element filter actions').include?('UI-configurable'),
        'filter action renders as UI-configurable in the guide')

  # Highlight: no equivalent, never a claimed UI path.
  hl = (by_kind['highlight-action'] || []).first || {}
  check(section_text(md, 'Highlight actions').include?('no equivalent'),
        'highlight action renders as no equivalent in the guide')
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
  check(section_text(md, 'Parameter actions').include?('control-based equivalent already built'),
        'param action renders as control-equivalent-built in the guide')

  # Set action: no equivalent.
  sa = (by_kind['set-action'] || []).first || {}
  check(section_text(md, 'Set actions').include?('no equivalent') &&
        ((sa['targets'] || []).first || {})['name'] == 'Top Regions Set',
        'set action renders as no-equivalent with the set named')

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
  check(viz['viz_in_tooltip'] == true, 'viz-in-tooltip detected')
  check(section_text(md, 'Custom tooltips').include?('no equivalent'),
        'the viz-in-tooltip entry renders as no-equivalent in the guide')

  # Buttons: toggle names its toggled container's content; goto-sheet button
  # resolves the window uuid to the dashboard; export names the format.
  sh = (by_kind['show-hide-button'] || []).first || {}
  check(((sh['targets'] || []).first || {})['name'].to_s.include?('Filter Panel Sheet'),
        'show/hide toggle names the toggled container content')
  check(section_text(md, 'Show/hide container buttons').include?('no equivalent'),
        'show/hide toggle renders as no-equivalent in the guide')
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
  md2, ledger2 = run_guide(File.join(FIXTURE, 'postpublish-actions.twb'),
                           File.join(Dir.mktmpdir), ['--wb-ids', ids_path])
  entries2 = ledger2['residue']
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
  md3, ledger3 = run_guide(File.join(FIXTURE, 'postpublish-zone-visibility.twb'),
                           File.join(Dir.mktmpdir))
  entries3 = ledger3['residue']
  zv = entries3.select { |e| e['kind'] == 'zone-visibility' }
  check(zv.length == 1, "detects 1 zone-visibility (got #{zv.length})")
  z = zv.first || {}
  check(z['fields'] == ['Show Detail'],
        "visibility driving field resolves through the graph, (copy)_n stripped (got #{z['fields'].inspect})")
  check(z['caption'].to_s.include?("sheet 'Detail Band'") && z['caption'].to_s.include?('KPI Dash'),
        'visibility zone + dashboard resolved by uuid/zone-id')
  check(section_text(md3, 'Dynamic zone visibility').include?('no equivalent') &&
        md3.include?('No direct equivalent today'),
        'zone visibility renders as no-equivalent, shipped pattern stated')

  # ---- 4. Zero-action workbook ----------------------------------------------
  puts "== postpublish-empty.twb =="
  dir4 = File.join(Dir.mktmpdir)
  md4, ledger4 = run_guide(File.join(FIXTURE, 'postpublish-empty.twb'), dir4)
  check(ledger4['residue'] == [], 'zero-action workbook has empty residue')
  check(ledger4['emitted'] == [] && ledger4['detectedCount'] == 0 && ledger4['schemaVersion'] == 1,
        'zero-action ledger still carries the full shape (schemaVersion, detectedCount 0, empty emitted)')
  check(File.exist?(File.join(dir4, 'POSTPUBLISH_GUIDE.md')),
        'guide file exists even with zero actions (gate contract)')
  check(md4.include?('No interactive actions detected'),
        'zero-action guide states the minimal body')

  # ---- 5. Ledger shape + emitted-vs-residue disjointness (--emitted-manifest) ----
  # This is the contract Task 6's gates read: --json-out must now write the
  # FULL LEDGER OBJECT ({schemaVersion, detectedCount, emitted, residue}), not
  # a bare entries array, and the guide must render ONLY residue (no
  # instructions for work the converter already did).
  puts "== postpublish-actions.twb + --emitted-manifest =="
  manifest = File.join(d, 'm-actions-emitted.json')
  # 'Go to Detail' is the zone-11 goto-sheet button on the 'Overview'
  # dashboard in postpublish-actions.twb (see extract_buttons). Its
  # actionName ('Overview::zone-11') is what build-charts-from-signals.rb
  # now also records on the manifest entry's source — dashboard-object
  # button zones carry no Tableau `name=` attribute, so kind+caption alone
  # can't disambiguate two same-captioned buttons; actionName can.
  File.write(manifest, JSON.generate([
    { 'actionId' => 'act-btn-11-1',
      'source' => { 'kind' => 'nav-button', 'caption' => 'Go to Detail',
                    'actionName' => 'Overview::zone-11' },
      'hostElementId' => 'btn-11', 'trigger' => 'on-click',
      'effects' => [{ 'effect' => 'navigate',
                      'target' => { 'type' => 'page', 'page' => 'page-detail' } }] }
  ]))
  md5, led5 = run_guide(File.join(FIXTURE, 'postpublish-actions.twb'),
                        Dir.mktmpdir, ['--emitted-manifest', manifest])
  check(led5['schemaVersion'] == 1, 'ledger carries schemaVersion')
  check(led5.key?('emitted') && led5.key?('residue'), 'ledger has emitted and residue')
  check(led5['detectedCount'] == led5['emitted'].size + led5['residue'].size,
        'CONSERVATION holds on a real fixture')
  key_pairs = ->(a) { a.map { |e| [e['kind'], e['caption']] } }
  check((key_pairs.(led5['residue']) & key_pairs.(led5['emitted'].map { |e| e['source'] })).empty?,
        'emitted and residue are disjoint')
  check(!md5.include?('Go to Detail'),
        'an EMITTED action does NOT appear in the guide (no instructions for done work)')
  check(md5.include?('Brush') || md5.match?(/highlight/i),
        'residue still appears in the guide')
  check(led5['residue'].none? { |e| e['kind'] == 'nav-button' && e['caption'] == 'Go to Detail' },
        'the emitted nav-button is excluded from residue')
end

puts ''
if $fails.empty?
  puts 'ALL PASS'
else
  puts "#{$fails.length} FAILURE(S):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
