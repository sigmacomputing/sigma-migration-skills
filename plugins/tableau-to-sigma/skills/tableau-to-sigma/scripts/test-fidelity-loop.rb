#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Unit tests for fidelity-loop.rb — the RCF loop mechanics (Phase 5g).
# Covers the pure core (deep_merge, ledger add/resolve/gate eval) and the CLI
# dry-run apply-patch codepath (GET→merge→out, no network). No live warehouse.
#
#   ruby scripts/test-fidelity-loop.rb

require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'
require_relative 'fidelity-loop' # defines module FidelityLoop; CLI is guarded off

HERE = __dir__
SCRIPT = File.join(HERE, 'fidelity-loop.rb')
$failures = 0

def ok(cond, msg)
  if cond
    puts "  ok - #{msg}"
  else
    puts "  FAIL - #{msg}"
    $failures += 1
  end
end

def run(*args, dir:)
  Open3.capture2e({ 'FIDELITY_LOOP_CLI' => '1' }, 'ruby', SCRIPT, *args, '--workdir', dir)
end

puts 'deep_merge:'
# Hash recursion
base = { 'themeName' => 'Light', 'themeOverrides' => { 'borderRadius' => 'round' } }
patch = { 'themeOverrides' => { 'categoricalScheme' => %w[#0e7c7b #14b8a6] } }
m = FidelityLoop.deep_merge(base, patch)
ok(m['themeName'] == 'Light', 'untouched scalar preserved')
ok(m['themeOverrides']['borderRadius'] == 'round', 'nested untouched key preserved')
ok(m['themeOverrides']['categoricalScheme'].length == 2, 'nested new key added')
hidden = FidelityLoop.deep_merge({ 'name' => { 'text' => 'Title', 'fontSize' => 24 } }, { 'name' => { 'visibility' => 'hidden' } })
ok(hidden['name'] == { 'visibility' => 'hidden' }, 'hidden title replaces the mutually exclusive shown-title branch')
shown = FidelityLoop.deep_merge(hidden, { 'name' => { 'text' => 'Restored' } })
ok(shown['name'] == { 'text' => 'Restored' }, 'shown title does not retain hidden visibility')
# Chart legend: {visibility:'hidden'} XOR shown config. Sigma rejects the mix ("cannot mix hidden with
# content", live probe plan C live regression R1) and has no visibility 'visible'.
lg_hidden = { 'legend' => { 'visibility' => 'hidden' } }
ok(FidelityLoop.deep_merge(lg_hidden, { 'legend' => { 'position' => 'right' } })['legend'] == { 'position' => 'right' },
   'shown legend config over a hidden legend drops the hidden marker')
ok(FidelityLoop.deep_merge(lg_hidden, { 'legend' => { 'visibility' => 'visible', 'position' => 'left' } })['legend'] == { 'position' => 'left' },
   "visibility 'visible' is not a Sigma value: dropped, config kept")
ok(!FidelityLoop.deep_merge(lg_hidden, { 'legend' => { 'visibility' => 'visible' } }).key?('legend'),
   "visibility 'visible' alone over a hidden legend removes the key (Sigma default shows it)")
ok(FidelityLoop.deep_merge({ 'legend' => { 'position' => 'left', 'fontSize' => 12 } }, { 'legend' => { 'visibility' => 'hidden' } })['legend'] == { 'visibility' => 'hidden' },
   'hiding replaces a shown legend wholesale')
ok(FidelityLoop.deep_merge({ 'legend' => { 'position' => 'left', 'fontSize' => 12 } }, { 'legend' => { 'position' => 'top' } })['legend'] == { 'position' => 'top', 'fontSize' => 12 },
   'shown-over-shown legend stays a deep merge')
ok(FidelityLoop.deep_merge({ 'legend' => { 'position' => 'left' } }, { 'legend' => { 'visibility' => 'hidden', 'position' => 'top' } })['legend'] == { 'visibility' => 'hidden' },
   'a patch carrying hidden AND content merges to hidden only')
ok(FidelityLoop.deep_merge({ 'a' => 1 }, { 'legend' => { 'position' => 'top' } })['legend'] == { 'position' => 'top' },
   'legend patch on an element with no legend inserts it')

# Array-of-hashes merge by elementId — patch one element's style, others intact
base2 = { 'pages' => [{ 'id' => 'p1', 'elements' => [
  { 'elementId' => 'a', 'kind' => 'bar-chart', 'style' => { 'x' => 1 } },
  { 'elementId' => 'b', 'kind' => 'kpi-chart' }
] }] }
patch2 = { 'pages' => [{ 'id' => 'p1', 'elements' => [
  { 'elementId' => 'a', 'style' => { 'backgroundColor' => '#00000000' } }
] }] }
m2 = FidelityLoop.deep_merge(base2, patch2)
els = m2['pages'][0]['elements']
ok(els.length == 2, 'merge by id did NOT drop the un-patched sibling element')
a = els.find { |e| e['elementId'] == 'a' }
ok(a['kind'] == 'bar-chart' && a['style']['x'] == 1 && a['style']['backgroundColor'] == '#00000000',
   'patched element keeps old keys + gains new one')
ok(els.find { |e| e['elementId'] == 'b' }['kind'] == 'kpi-chart', 'sibling element untouched')

# New element appended when id not present
patch3 = { 'pages' => [{ 'id' => 'p1', 'elements' => [{ 'elementId' => 'c', 'kind' => 'table' }] }] }
m3 = FidelityLoop.deep_merge(base2, patch3)
ok(m3['pages'][0]['elements'].length == 3, 'new element id appended, not replacing the array')

# Keyless array → replaced wholesale
ok(FidelityLoop.deep_merge({ 'v' => [1, 2, 3] }, { 'v' => [9] })['v'] == [9], 'keyless array replaced')

puts 'ledger add / gate eval:'
led = FidelityLoop.new_ledger(workbook_id: 'wb1', page_id: 'pg1', max_passes: 5)
led['pass'] = 1
FidelityLoop.add_entry(led, dimension: 'palette', delta: 'blue vs teal', cls: 'spec-fixable', fix: 'categoricalScheme')
FidelityLoop.add_entry(led, dimension: 'kpi-spark', delta: 'sparkline missing', cls: 'ui-only', catalog_id: 'nav-button-style')
ok(led['entries'].length == 2, 'entries appended')
ok(led['entries'][0]['id'] == 'e0', 'stable id assigned')
ok(!FidelityLoop.ledger_ok?(led), 'unresolved spec-fixable blocks the gate')
ok(FidelityLoop.unresolved_specfixable(led).length == 1, 'catalogued ui-only does NOT block')

# Resolve → gate clears
led['entries'][0]['resolved'] = true
ok(FidelityLoop.ledger_ok?(led), 'resolving the spec-fixable delta clears the gate')

# Accept-residuals waives an unresolved one (by id and by index)
led2 = FidelityLoop.new_ledger(workbook_id: 'w', page_id: 'p')
FidelityLoop.add_entry(led2, dimension: 'font', delta: 'x', cls: 'spec-fixable')
ok(!FidelityLoop.ledger_ok?(led2), 'baseline blocks')
ok(FidelityLoop.ledger_ok?(led2, ['e0']), 'accept-residuals by id waives')
ok(FidelityLoop.ledger_ok?(led2, ['0']), 'accept-residuals by index waives')

# Bad class rejected
begin
  FidelityLoop.add_entry(led2, dimension: 'x', delta: 'y', cls: 'nonsense')
  ok(false, 'invalid class raised')
rescue ArgumentError
  ok(true, 'invalid class raised ArgumentError')
end

puts 'CLI end-to-end (dry-run, no network):'
Dir.mktmpdir do |dir|
  out, = run('init', '--workbook-id', 'WB', '--page-id', 'PG', '--max-passes', '3', dir: dir)
  ok(out.include?('initialized'), 'init writes ledger')
  ok(File.exist?(File.join(dir, 'fidelity-ledger.json')), 'ledger file created')

  out, = run('record', '--dimension', 'palette', '--delta', 'blue not teal', '--class', 'spec-fixable',
             '--fix', 'themeOverrides.categoricalScheme', dir: dir)
  ok(out.include?('recorded e0'), 'record appends entry e0')

  # status blocks while unresolved
  _, st = run('status', dir: dir)
  ok(st.exitstatus == 6, 'status exits 6 while a spec-fixable delta is unresolved')

  # dry-run apply-patch: merge a themeOverrides patch into a fake live spec
  live = {
    'workbookId' => 'WB',
    'document' => {
      'schemaVersion' => 1, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'PG' }],
      'elements' => [{ 'id' => 'k1', 'kind' => 'kpi-chart' }],
      'layout' => '<Page id="PG"><Element elementId="k1"/></Page>',
      'themeName' => 'Light'
    }
  }
  File.write(File.join(dir, 'live.json'), JSON.generate(live))
  File.write(File.join(dir, 'patch.json'),
             JSON.generate({ 'themeOverrides' => { 'categoricalScheme' => ['#0e7c7b'] } }))
  out, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'),
                '--dry-run', '--live-spec', File.join(dir, 'live.json'),
                '--out', File.join(dir, 'merged.json'), '--resolves', 'e0', dir: dir)
  ok(st.exitstatus.zero?, 'dry-run apply-patch exits 0')
  merged = JSON.parse(File.read(File.join(dir, 'merged.json')))
  merged_doc = merged['document']
  ok(merged_doc['layout'] == live['document']['layout'], 'layout preserved through the merge (PUT-wipes-layout trap avoided)')
  ok(merged_doc.dig('settings', 'theme', 'overrides', 'categoricalScheme') == ['#0e7c7b'],
     'patch applied to canonical theme overrides')
  ok(merged_doc['elements'][0]['id'] == 'k1', 'existing element retained')

  # after --resolves e0, status clears
  _, st = run('status', dir: dir)
  ok(st.exitstatus.zero?, 'status exits 0 after the delta is resolved')

  # apply-patch refuses a merge that would blank the workbook (no pages)
  File.write(File.join(dir, 'nopages.json'), JSON.generate({ 'themeName' => 'Light' }))
  _, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'),
              '--dry-run', '--live-spec', File.join(dir, 'nopages.json'),
              '--out', File.join(dir, 'x.json'), dir: dir)
  ok(st.exitstatus == 4, 'apply-patch refuses a live spec with no pages (exit 4)')

  # Workbook code-rep GETs nest pages/layout/schemaVersion under `document`
  # (live since 2026-08). A --live-spec fixture shaped like the LIVE response
  # (workbookId/name at top level, pages/layout nested) must merge correctly
  # instead of tripping the "no `pages`" guard (exit 4) on a workbook that
  # actually has pages.
  nested_live = {
    'workbookId' => 'wb1', 'name' => 'Exec Overview',
    'document' => {
      'schemaVersion' => 5, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'PG' }],
      'elements' => [{ 'id' => 'k1', 'kind' => 'kpi-chart' }],
      'layout' => '<Page id="PG"><Element elementId="k1"/></Page>'
    }
  }
  File.write(File.join(dir, 'nested-live.json'), JSON.generate(nested_live))
  out, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'),
                '--dry-run', '--live-spec', File.join(dir, 'nested-live.json'),
                '--out', File.join(dir, 'nested-merged.json'), dir: dir)
  ok(st.exitstatus.zero?, 'apply-patch on a nested-document --live-spec exits 0 (not exit 4)')
  nested_merged = (JSON.parse(File.read(File.join(dir, 'nested-merged.json'))) rescue nil)
  nested_doc = nested_merged && nested_merged['document']
  ok(nested_doc.is_a?(Hash) && nested_doc['pages'].is_a?(Array) && nested_doc['pages'].length == 1,
     'nested `document.pages` retained in the canonical merged spec')
  ok(nested_doc && nested_doc['layout'] == nested_live['document']['layout'],
     'nested `document.layout` preserved through the merge')
  ok(nested_doc && nested_doc.dig('settings', 'theme', 'overrides', 'categoricalScheme') == ['#0e7c7b'],
     'patch still applies inside the canonical nested live spec')

  # #698 / live RCF regression: workbook patches use flat document.elements.
  # A partial element patch must merge into the complete flat record, never
  # shadow it with an id/style-only record after a legacy pages[] conversion.
  nested_live['document']['elements'] << { 'id' => 'k2', 'kind' => 'bar-chart' }
  nested_live['document']['layout'] = '<Page id="PG"><Element elementId="k1"/><Element elementId="k2"/></Page>'
  File.write(File.join(dir, 'nested-live.json'), JSON.generate(nested_live))
  File.write(File.join(dir, 'element-patch.json'),
             JSON.generate('elements' => [{ 'id' => 'k1', 'style' => { 'backgroundColor' => '#ffffff' } }]))
  out, st = run('apply-patch', '--patch', File.join(dir, 'element-patch.json'),
                '--dry-run', '--live-spec', File.join(dir, 'nested-live.json'),
                '--out', File.join(dir, 'element-merged.json'), dir: dir)
  element_doc = JSON.parse(File.read(File.join(dir, 'element-merged.json')))['document']
  element_k1 = element_doc['elements'].find { |element| element['id'] == 'k1' }
  ok(st.exitstatus.zero?, 'flat document.elements fidelity patch exits 0')
  ok(element_k1['kind'] == 'kpi-chart' && element_k1.dig('style', 'backgroundColor') == '#ffffff',
     'partial flat element patch preserves required kind and merges style')
  ok(element_doc['elements'].any? { |element| element['id'] == 'k2' && element['kind'] == 'bar-chart' },
     'partial flat element patch preserves unpatched sibling elements')

  # 2026-11-03 live run: a patch in the release shape {"document": {...}} was
  # merged into a nested copy that canonicalize() discarded — the PUT reported
  # OK and nothing changed. The release shape must land like the flat shape.
  File.write(File.join(dir, 'document-patch.json'), JSON.generate(
    'document' => {
      'elements' => [{ 'id' => 'k2', 'style' => { 'backgroundColor' => '#123456' } }],
      'settings' => { 'theme' => { 'overrides' => { 'categoricalScheme' => ['#abcdef'] } } }
    }
  ))
  out, st = run('apply-patch', '--patch', File.join(dir, 'document-patch.json'),
                '--dry-run', '--live-spec', File.join(dir, 'nested-live.json'),
                '--out', File.join(dir, 'document-merged.json'), dir: dir)
  document_doc = (JSON.parse(File.read(File.join(dir, 'document-merged.json')))['document'] rescue {})
  document_k2 = Array(document_doc['elements']).find { |element| element['id'] == 'k2' } || {}
  ok(st.exitstatus.zero?, "release-shape {document:{...}} patch exits 0 (#{out.lines.last&.strip})")
  ok(document_k2['kind'] == 'bar-chart' && document_k2.dig('style', 'backgroundColor') == '#123456',
     'release-shape element patch lands on the flat element record')
  ok(document_doc.dig('settings', 'theme', 'overrides', 'categoricalScheme') == ['#abcdef'],
     'release-shape settings patch lands in document.settings')

  # Legacy page-nested element patches canonicalize() would otherwise drop
  # (existing flat records win by id) — they must land too.
  File.write(File.join(dir, 'page-patch.json'), JSON.generate(
    'pages' => [{ 'id' => 'PG', 'elements' => [{ 'id' => 'k1', 'style' => { 'backgroundColor' => '#654321' } }] }]
  ))
  out, st = run('apply-patch', '--patch', File.join(dir, 'page-patch.json'),
                '--dry-run', '--live-spec', File.join(dir, 'nested-live.json'),
                '--out', File.join(dir, 'page-merged.json'), dir: dir)
  page_doc = (JSON.parse(File.read(File.join(dir, 'page-merged.json')))['document'] rescue {})
  page_k1 = Array(page_doc['elements']).find { |element| element['id'] == 'k1' } || {}
  ok(st.exitstatus.zero? && page_k1['kind'] == 'kpi-chart' && page_k1.dig('style', 'backgroundColor') == '#654321',
     "page-nested element patch lands on the flat element record (#{out.lines.last&.strip})")

  # Anything the document PUT cannot carry is refused LOUDLY, never dropped.
  File.write(File.join(dir, 'metadata-patch.json'), JSON.generate('name' => 'Renamed', 'elementz' => []))
  out, st = run('apply-patch', '--patch', File.join(dir, 'metadata-patch.json'),
                '--dry-run', '--live-spec', File.join(dir, 'nested-live.json'),
                '--out', File.join(dir, 'metadata-merged.json'), dir: dir)
  ok(st.exitstatus == 4 && out.include?('elementz') && !File.exist?(File.join(dir, 'metadata-merged.json')),
     'a patch key outside the workbook document is refused (exit 4), not silently dropped')
end

puts 'patch landing check:'
landed_doc = {
  'elements' => [{ 'id' => 'k1', 'kind' => 'kpi-chart', 'style' => { 'backgroundColor' => '#fff' } }],
  'settings' => { 'theme' => { 'overrides' => { 'categoricalScheme' => ['#0e7c7b'] } } }
}
ok(FidelityLoop.unlanded_paths({ 'elements' => [{ 'id' => 'k1', 'style' => { 'backgroundColor' => '#fff' } }] }, landed_doc).empty?,
   'a patched element leaf present in the document has landed')
missing = FidelityLoop.unlanded_paths({ 'elements' => [{ 'id' => 'k1', 'style' => { 'fontSize' => 12 } }],
                                        'settings' => { 'theme' => { 'name' => 'Dark' } } }, landed_doc)
ok(missing.include?('elements[id=k1].style.fontSize') && missing.include?('settings.theme.name'),
   "absent patched leaves are reported as unlanded (#{missing.inspect})")
ok(FidelityLoop.unlanded_paths({ 'elements' => [{ 'id' => 'zz', 'kind' => 'table' }] }, landed_doc) == ['elements[id=zz]'],
   'a patched element missing from the readback is reported by id')
norm = FidelityLoop.normalize_patch('document' => { 'elements' => [{ 'id' => 'k1' }] }, 'themeOverrides' => { 'x' => 1 })
ok(norm['elements'] == [{ 'id' => 'k1' }] && norm.dig('settings', 'theme', 'overrides') == { 'x' => 1 } && !norm.key?('document'),
   'normalize_patch hoists document.* and folds legacy theme keys')

puts 'RCF page picking (#422):'
helper_pg = { 'id' => 'pg-help', 'name' => 'Data Helpers', 'elements' => [
  { 'id' => 'h1', 'kind' => 'table', 'visibleAsSource' => false },
  { 'id' => 'h2', 'kind' => 'table', 'visibleAsSource' => false }
] }
content_pg = { 'id' => 'pg-main', 'name' => 'Overview', 'elements' => [
  { 'id' => 'c1', 'kind' => 'bar-chart' }, { 'id' => 'c2', 'kind' => 'kpi-chart' },
  { 'id' => 'ctl', 'kind' => 'control' }
] }
ok(FidelityLoop.visible_count(helper_pg).zero?, 'visibleAsSource:false helper tables count 0 visible')
ok(FidelityLoop.visible_count(content_pg) == 3, 'content page counts its rendered elements')
ok(FidelityLoop.visible_count('elements' => [{ 'id' => 'x', 'hidden' => true }]).zero?,
   'hidden:true elements count 0 visible')
pick, top = FidelityLoop.pick_rcf_page([helper_pg, content_pg])
ok(pick && pick['id'] == 'pg-main' && top.length == 1,
   'pick_rcf_page prefers the most-visible page over first-by-order')
_, top2 = FidelityLoop.pick_rcf_page([content_pg, content_pg.merge('id' => 'pg-b', 'name' => 'B')])
ok(top2.length == 2, 'equal visible counts reported as a tie')
ok(FidelityLoop.pick_rcf_page([]) == [nil, []], 'no pages → [nil, []]')

Dir.mktmpdir do |dir|
  # wb-ids carries the LIVE page ids; visibility (visibleAsSource:false) only
  # lives in wb-spec — the picker joins the two by page name. The hidden-helper
  # data page comes FIRST: the exact shape that made the old first-by-order
  # pick render a hidden helper table (#422 live run).
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('pages' => [
    { 'id' => 'live-data', 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table' }] },
    { 'id' => 'live-help', 'name' => 'Data Helpers', 'elements' => [
      { 'id' => 'h1', 'kind' => 'table' }, { 'id' => 'h2', 'kind' => 'table' }] },
    { 'id' => 'live-main', 'name' => 'Overview', 'elements' => [
      { 'id' => 'c1', 'kind' => 'bar-chart' }, { 'id' => 'c2', 'kind' => 'kpi-chart' }] }
  ]))
  File.write(File.join(dir, 'wb-spec.json'), JSON.generate('pages' => [
    { 'id' => 'page-data', 'name' => 'Data', 'elements' => [
      { 'id' => 'master', 'kind' => 'table', 'visibleAsSource' => false }] },
    { 'id' => 'page-help', 'name' => 'Data Helpers', 'elements' => [
      { 'id' => 'h1', 'kind' => 'table', 'visibleAsSource' => false },
      { 'id' => 'h2', 'kind' => 'table', 'visibleAsSource' => false }] },
    { 'id' => 'page-main', 'name' => 'Overview', 'elements' => [
      { 'id' => 'c1', 'kind' => 'bar-chart' }, { 'id' => 'c2', 'kind' => 'kpi-chart' }] }
  ]))
  out, st = run('init', '--workbook-id', 'WB', dir: dir)
  led = JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
  ok(st.exitstatus.zero? && out.include?('auto-picked'), 'init without --page-id auto-picks a page')
  ok(led['page_id'] == 'live-main',
     'auto-pick chose the VISIBLE content page (live id), not the first-by-order helper page')

  # --page-id override on the EXISTING ledger (entries preserved) — the old
  # init had no way to repoint an already-initialized ledger.
  run('record', '--dimension', 'composition_match', '--delta', 'x', '--class', 'ui-only', '--catalog-id', 'nav-button-style', dir: dir)
  out, st = run('init', '--workbook-id', 'WB', '--page-id', 'live-other', dir: dir)
  led = JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
  ok(st.exitstatus.zero? && out.include?('OVERRIDDEN'), 'init --page-id on an existing ledger overrides in place')
  ok(led['page_id'] == 'live-other' && led['entries'].length == 1, 'override preserves the recorded entries')
end

Dir.mktmpdir do |dir|
  _out, st = run('init', '--workbook-id', 'WB', dir: dir)
  ok(st.exitstatus == 2, 'init dies (usage) with no --page-id and nothing to auto-pick from')
end

# 2026-11-03 live run (reused DM): the Data page's master table is VISIBLE (no
# visibleAsSource:false), so Data (1 table) tied the dashboard page (1 chart)
# and first-by-order rendered the data table for the only Tier-S pass.
data_pg = { 'id' => 'page-data', 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table' }] }
dash_pg = { 'id' => 'page-dash', 'name' => 'Sales Overview', 'elements' => [{ 'id' => 'c1', 'kind' => 'bar-chart' }] }
pick, = FidelityLoop.pick_rcf_page([data_pg, dash_pg])
ok(pick && pick['id'] == 'page-dash', 'a 1-table Data page does not beat a 1-chart dashboard page')
tables_pg = dash_pg.merge('id' => 'page-tables', 'name' => 'Detail',
                          'elements' => [{ 'id' => 't1', 'kind' => 'table' }, { 'id' => 't2', 'kind' => 'table' }])
pick, = FidelityLoop.pick_rcf_page([tables_pg, dash_pg], dashboard_names: ['Sales Overview'])
ok(pick && pick['id'] == 'page-dash', 'the page named after the source dashboard wins over a busier page')
pick, = FidelityLoop.pick_rcf_page([tables_pg, dash_pg.merge('elements' => [{ 'id' => 't3', 'kind' => 'table' }, { 'id' => 'c1', 'kind' => 'bar-chart' }])])
ok(pick && pick['id'] == 'page-dash', 'equal visible counts break toward the page holding chart elements')

Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('pages' => [
    { 'id' => 'live-data', 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table' }] },
    { 'id' => 'live-dash', 'name' => 'Sales Overview', 'elements' => [{ 'id' => 'c1', 'kind' => 'bar-chart' }] }
  ]))
  out, st = run('init', '--workbook-id', 'WB', dir: dir)
  led = JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
  ok(st.exitstatus.zero? && led['page_id'] == 'live-dash',
     "reused-DM shape: init auto-picks the dashboard page, not the visible-master Data page (#{out.lines.last&.strip})")
end

Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'dashboard-scope.json'), JSON.generate('dashboards' => ['Sales Overview']))
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('pages' => [
    { 'id' => 'live-detail', 'name' => 'Detail', 'elements' => [
      { 'id' => 't1', 'kind' => 'table' }, { 'id' => 't2', 'kind' => 'bar-chart' }] },
    { 'id' => 'live-dash', 'name' => 'Sales Overview', 'elements' => [{ 'id' => 'c1', 'kind' => 'bar-chart' }] }
  ]))
  _out, st = run('init', '--workbook-id', 'WB', dir: dir)
  led = JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
  ok(st.exitstatus.zero? && led['page_id'] == 'live-dash',
     'init auto-pick prefers the page named after the source dashboard (dashboard-scope.json)')
end

Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('pages' => [
    { 'id' => 'live-a', 'name' => 'A', 'elements' => [{ 'id' => 'c1', 'kind' => 'bar-chart' }] },
    { 'id' => 'live-b', 'name' => 'B', 'elements' => [{ 'id' => 'c2', 'kind' => 'bar-chart' }] }
  ]))
  out, st = run('init', '--workbook-id', 'WB', dir: dir)
  led = JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
  ok(st.exitstatus.zero? && out =~ /tie/ && led['page_id'] == 'live-a',
     'tied visible counts WARN and pick first-by-order (deterministic)')
end

puts 'apply-patch dual-write (#422):'
Dir.mktmpdir do |dir|
  run('init', '--workbook-id', 'WB', '--page-id', 'PG', dir: dir)
  wb_spec = {
    'document' => {
      'schemaVersion' => 1, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'page-ov' }],
      'elements' => [
        { 'id' => 'k1', 'kind' => 'kpi-chart', 'style' => { 'x' => 1 } },
        { 'id' => 'k2', 'kind' => 'bar-chart' }
      ],
      'layout' => '<Page id="page-ov"><Element elementId="k1"/><Element elementId="k2"/></Page>',
      'themeName' => 'Light'
    }
  }
  File.write(File.join(dir, 'wb-spec.json'), JSON.generate(wb_spec))
  live = {
    'document' => {
      'schemaVersion' => 1, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'PG' }],
      'elements' => [{ 'id' => 'k1', 'kind' => 'kpi-chart' }],
      'layout' => '<Page id="PG"><Element elementId="k1"/></Page>'
    }
  }
  File.write(File.join(dir, 'live.json'), JSON.generate(live))
  File.write(File.join(dir, 'patch.json'),
             JSON.generate('themeOverrides' => { 'categoricalScheme' => ['#0e7c7b'] }))
  out, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'), '--dry-run',
                '--live-spec', File.join(dir, 'live.json'), '--out', File.join(dir, 'merged.json'), dir: dir)
  ok(st.exitstatus.zero?, 'apply-patch (dual-write) exits 0')
  ok(out.include?('persisted into'), 'apply-patch reports the wb-spec.json persistence')
  ws = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))
  ok(ws.dig('document', 'settings', 'theme', 'overrides') == { 'categoricalScheme' => ['#0e7c7b'] },
     'patch deep-merged into wb-spec.json document.settings (a re-entry full-spec PUT now carries the fix)')
  ok(ws.dig('document', 'elements').length == 2 && ws.dig('document', 'settings', 'theme', 'name') == 'Light',
     'wb-spec.json untouched keys/elements preserved by the merge')

  File.write(File.join(dir, 'patch.json'), JSON.generate(
    'pages' => [{ 'id' => 'page-ov', 'elements' => [{ 'id' => 'k1', 'style' => { 'x' => 2 } }] }]
  ))
  _, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'), '--dry-run',
              '--live-spec', File.join(dir, 'live.json'), '--out', File.join(dir, 'merged.json'), dir: dir)
  ws = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))
  k1 = ws.dig('document', 'elements').find { |element| element['id'] == 'k1' }
  ok(st.exitstatus.zero? && k1['kind'] == 'kpi-chart' && k1.dig('style', 'x') == 2,
     'page-nested partial element patch preserves the complete wb-spec.json element record')
  ok(ws.dig('document', 'elements').any? { |element| element['id'] == 'k2' && element['kind'] == 'bar-chart' },
     'page-nested partial element patch preserves wb-spec.json sibling elements')

  # guard: unparseable wb-spec.json → warned, left untouched, apply still succeeds
  File.write(File.join(dir, 'wb-spec.json'), '{ not json')
  out, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'), '--dry-run',
                '--live-spec', File.join(dir, 'live.json'), '--out', File.join(dir, 'merged2.json'), dir: dir)
  ok(st.exitstatus.zero? && out.include?('NOT persisted'),
     'unparseable wb-spec.json → warn, apply-patch still succeeds')
  ok(File.read(File.join(dir, 'wb-spec.json')) == '{ not json', 'unparseable wb-spec.json left untouched')
end

puts 'render budget:'
Dir.mktmpdir do |dir|
  run('init', '--workbook-id', 'WB', '--page-id', 'PG', '--max-passes', '1', dir: dir)
  # Force pass counter to the budget so render must STOP (no real renderer called).
  led = JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
  led['pass'] = 1
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(led))
  out, st = run('render', dir: dir)
  ok(st.exitstatus == 3, 'render exits 3 when the pass budget is exhausted')
  exhausted = JSON.parse(File.read(File.join(dir, 'rcf-exhausted.json')))
  ok(exhausted['status'] == 'exhausted' && exhausted['pass'] == 1 &&
     exhausted['max_passes'] == 1,
     'budget exhaustion writes a terminal rcf-exhausted.json marker')
  File.write(File.join(dir, 'live.json'), JSON.generate(
    'document' => {
      'schemaVersion' => 1, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'PG' }],
      'elements' => [{ 'id' => 'k1', 'kind' => 'kpi-chart' }],
      'layout' => '<Page id="PG"><Element elementId="k1"/></Page>'
    }
  ))
  File.write(File.join(dir, 'patch.json'), JSON.generate(
    'elements' => [{ 'id' => 'k1', 'style' => { 'backgroundColor' => '#fff' } }]
  ))
  out, st = run(
    'apply-patch', '--patch', File.join(dir, 'patch.json'),
    '--dry-run', '--live-spec', File.join(dir, 'live.json'),
    '--out', File.join(dir, 'merged.json'), dir: dir
  )
  ok(st.exitstatus == 3 && out.include?('budget is exhausted'),
     'rcf-exhausted marker blocks post-budget apply-patch attempts')
end

puts 'deep_merge null = delete (defect 3):'
del = FidelityLoop.deep_merge({ 'a' => 1, 'b' => { 'c' => 2, 'd' => 3 } }, { 'b' => { 'c' => nil } })
ok(del == { 'a' => 1, 'b' => { 'd' => 3 } }, 'null deletes the key, siblings kept')
noop = FidelityLoop.deep_merge({ 'a' => 1 }, { 'zzz' => nil, 'n' => { 'x' => nil, 'y' => 1 } })
ok(!noop.key?('zzz') && noop['n'] == { 'y' => 1 }, 'null for an absent key is a no-op (not inserted), also inside fresh inserts')
axis = FidelityLoop.deep_merge(
  { 'elements' => [{ 'id' => 'x', 'xAxis' => { 'format' => { 'title' => { 'text' => 'T' }, 'grid' => true } } }, { 'id' => 'y' }] },
  { 'elements' => [{ 'id' => 'x', 'xAxis' => { 'format' => { 'title' => nil } } }] }
)
ok(axis['elements'].length == 2 && axis['elements'][0]['xAxis']['format'] == { 'grid' => true },
   'null inside an id-keyed array element deletes the nested key')
newel = FidelityLoop.deep_merge({ 'elements' => [{ 'id' => 'x' }] }, { 'elements' => [{ 'id' => 'n', 'k' => 1, 'gone' => nil }] })
ok(newel['elements'][1] == { 'id' => 'n', 'k' => 1 }, 'new array element appended without its null keys')
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(FidelityLoop.new_ledger(workbook_id: 'wbX', page_id: 'p1')))
  File.write(File.join(dir, 'live.json'), JSON.generate('pages' => [{ 'id' => 'p1' }], 'elements' => [{ 'id' => 'x', 'xAxis' => { 'format' => { 'title' => { 'text' => 'T' }, 'grid' => true } } }]))
  File.write(File.join(dir, 'patch.json'), '{"elements":[{"id":"x","xAxis":{"format":{"title":null}}}]}')
  out, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'), '--dry-run',
                '--live-spec', File.join(dir, 'live.json'), '--out', File.join(dir, 'merged.json'), dir: dir)
  ok(st.exitstatus.zero?, "null-delete patch dry-run exits 0 (#{out.lines.last.to_s.strip})")
  fmt = JSON.parse(File.read(File.join(dir, 'merged.json')))
  xf = (fmt['document'] || fmt).dig('elements', 0, 'xAxis', 'format')
  ok(xf == { 'grid' => true }, 'CLI merged spec has the title removed, grid kept')
end

puts 'preflight control lint honors control-scope.json (defect 4):'
src = File.read(SCRIPT)
ok(src.include?('ControlLint.lint(put_body, scope: control_scope)') && src.include?('ControlLint.lint(spec, scope: control_scope)') &&
   src.scan("File.read(File.join(opts[:dir], 'control-scope.json'))").length == 1, 'pre-PUT and post-patch lints both receive the single loaded control_scope')

puts 'budget-exhausted message (defect 9a):'
require_relative 'lib/repair_state'
exp = FidelityLoop.new_ledger(workbook_id: 'w', page_id: 'p', max_seconds: 60)
exp['started_at'] = (Time.now.utc - 3600).strftime('%Y-%m-%dT%H:%M:%SZ')
exp['max_passes'] = 5
hint = RepairState.extend_hint(exp, '/tmp/wd')
ok(hint.include?('fidelity-loop.rb extend --workdir "/tmp/wd" --max-passes 8 --max-seconds 1860') && hint.include?('--approved-by') && hint.include?('Alternative'),
   'extend_hint fills the exact command with current values and names the alternative')
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(exp))
  File.write(File.join(dir, 'patch.json'), '{"themeName":"x"}')
  out, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'), dir: dir)
  ok(st.exitstatus == 3 && out.include?('budget exhausted') && out.include?('fidelity-loop.rb extend --workdir') && out.include?('--max-seconds 1860'),
     'CLI apply-patch past the wall-time budget prints the exact extend command (exit 3)')
end

puts 'parity-plan regeneration after patch (defect 5):'
Dir.mktmpdir do |dir|
  cp = File.join(dir, 'repair-checkpoints', 'c1'); FileUtils.mkdir_p(cp)
  File.write(File.join(dir, 'parity-plan.json'), '{"extract":true,"dashboards_scope":["Sales"]}')
  File.write(File.join(dir, 'parity-final.json'), '{}')
  File.write(File.join(dir, 'repair-pending.json'), '{}')
  prior = JSON.parse(File.read(File.join(dir, 'parity-plan.json')))
  RepairState.invalidate(dir, cp)
  ok(!File.exist?(File.join(dir, 'parity-plan.json')) && File.exist?(File.join(cp, 'prior-evidence', 'parity-plan.json')), 'invalidate archives the stale plan')
  seen = nil
  runner = ->(argv) { seen = argv; File.write(File.join(dir, 'parity-plan.json'), '{"charts":[]}'); [true, ''] }
  good, cmd = RepairState.regen_parity_plan(dir, 'wb1', prior, script: '/s/phase6-parity.rb', runner: runner)
  ok(good && File.exist?(File.join(dir, 'parity-plan.json')), 'regen rebuilds parity-plan.json')
  ok(seen.include?('--regen-plan') && seen.include?('--extract-mode') && seen.each_cons(2).include?(['--dashboard', 'Sales']) &&
     seen.each_cons(2).include?(['--workbook-id', 'wb1']), 'regen reuses extract flag + dashboard scope from the prior plan')
  File.delete(File.join(dir, 'parity-plan.json'))
  bad, cmd2 = RepairState.regen_parity_plan(dir, 'wb1', prior, script: '/s/phase6-parity.rb', runner: ->(_) { [false, 'boom'] })
  ok(!bad && cmd2.include?('phase6-parity.rb') && cmd2.include?('--regen-plan'), 'regen failure returns the exact command to print')
end

puts 'ExportViewport (defect 11c):'
require_relative 'lib/export_viewport'
def png_bytes(w, h)
  "\x89PNG\r\n\x1a\n".b + [13].pack('N') + 'IHDR' + [w, h].pack('NN') + "\x08\x02\x00\x00\x00".b + "\x00\x00\x00\x00".b
end
Dir.mktmpdir do |dir|
  ok(ExportViewport.for(workdir: dir) == [1600, 900], 'empty workdir → 1600x900')
  File.write(File.join(dir, 'wb-spec.json'), JSON.generate('layout' => '<Page id="p1"><Element elementId="a" gridColumn="1 / 25" gridRow="1 / 101"/></Page><Page id="p2"><Element elementId="b" gridColumn="1 / 25" gridRow="1 / 9"/></Page>'))
  ok(ExportViewport.for(workdir: dir, page_id: 'p1') == [1600, 100 * 28 + 120], 'layout rows → height for the named page')
  ok(ExportViewport.for(workdir: dir, page_id: 'p2')[1] == 600, 'short layout clamps up to 600')
  ok(ExportViewport.for(workdir: dir)[1] == 100 * 28 + 120, 'no page id → tallest page')
  FileUtils.mkdir_p(File.join(dir, 'visual-qa'))
  File.binwrite(File.join(dir, 'visual-qa', 'sales.source.png'), png_bytes(1400, 2400))
  ok(ExportViewport.for(workdir: dir) == [1400, 2400], 'source PNG IHDR wins over layout')
  File.write(File.join(dir, 'png-read.json'), '{"source_png":"views/big.png"}')
  FileUtils.mkdir_p(File.join(dir, 'views')); File.binwrite(File.join(dir, 'views', 'big.png'), png_bytes(5000, 20_000))
  ok(ExportViewport.for(workdir: dir) == [3200, 6000], 'huge source PNG clamped to 3200x6000 (tallest candidate wins)')
  File.write(File.join(dir, 'views', 'big.png'), 'not a png')
  File.delete(File.join(dir, 'visual-qa', 'sales.source.png'))
  ok(ExportViewport.for(workdir: dir)[1] == 100 * 28 + 120, 'corrupt PNG → falls back to layout')
  FileUtils.mkdir_p(File.join(dir, 'dashboards'))
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('pages' => [
    { 'id' => 'p1', 'name' => 'Overview' }, { 'id' => 'p2', 'name' => 'Operations' }
  ]))
  File.binwrite(File.join(dir, 'dashboards', 'Overview.png'), png_bytes(1200, 900))
  File.binwrite(File.join(dir, 'dashboards', 'Operations.png'), png_bytes(1600, 2000))
  ok(ExportViewport.for(workdir: dir, page_id: 'p1') == [1200, 900] &&
     ExportViewport.for(workdir: dir, page_id: 'p2') == [1600, 2000],
     'named dashboard source PNG sizes each composite page independently')
  File.binwrite(File.join(dir, 'views', 'big.png'), png_bytes(1000, 700))
  File.binwrite(File.join(dir, 'visual-qa', 'sales.source.png'), png_bytes(1400, 2400))
  ok(ExportViewport.for(workdir: dir, page_id: 'missing') == [1400, 2400],
     'missing page lookup uses the tallest generic source PNG')
end
# Live Stress 4: discovery's resolution=high PNG is a 2x render (a 1400x900
# canvas arrives 2800x1800); the viewport must be the LOGICAL size.
Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, 'dashboards'))
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('pages' => [{ 'id' => 'p1', 'name' => 'Fulfillment Performance' }]))
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate([
    { 'dashboard' => 'Fulfillment Performance', 'canvas_px' => { 'w' => 1400, 'h' => 900 } }
  ]))
  File.binwrite(File.join(dir, 'dashboards', 'Fulfillment_Performance.png'), png_bytes(2800, 1800))
  ok(ExportViewport.for(workdir: dir, page_id: 'p1') == [1400, 900], '2x capture of a 1400x900 canvas → 1400x900 viewport')
  File.binwrite(File.join(dir, 'source-composite.png'), png_bytes(2800, 3616))
  File.write(File.join(dir, 'fidelity-ledger.json'), '{"source_image":"source-composite.png"}')
  ok(ExportViewport.for(workdir: dir) == [1400, 1808], 'stacked 2x composite → halved too')
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate([
    { 'dashboard' => 'Fulfillment Performance', 'canvas_px' => { 'w' => 1400, 'h' => 900 } },
    { 'dashboard' => 'Wide Dashboard', 'canvas_px' => { 'w' => 2800, 'h' => 900 } }
  ]))
  ok(ExportViewport.for(workdir: dir, page_id: 'p1') == [1400, 900],
     '2x capture uses its page canvas even when another dashboard has the captured width')
  File.binwrite(File.join(dir, 'dashboards', 'Fulfillment_Performance.png'), png_bytes(1400, 900))
  ok(ExportViewport.for(workdir: dir, page_id: 'p1') == [1400, 900], 'a 1x capture (width = canvas) is not halved')
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate([{ 'dashboard' => 'x', 'canvas_px' => { 'w' => 1000, 'h' => 800 } }]))
  File.binwrite(File.join(dir, 'dashboards', 'Fulfillment_Performance.png'), png_bytes(3200, 2000))
  ok(ExportViewport.for(workdir: dir, page_id: 'p1') == [3200, 2000], 'width not ~2x any canvas → header size kept')
end

puts 'RCF page auto-pick prefers the dashboard page (defect 11d):'
tbl = ->(n) { Array.new(n) { |i| { 'id' => "t#{i}", 'kind' => 'table' } } }
pages = [
  { 'id' => 'pd', 'name' => 'Data', 'elements' => tbl.call(8) },
  { 'id' => 'pa', 'name' => 'Overview', 'elements' => [{ 'id' => 'k', 'kind' => 'kpi-chart' }, { 'id' => 'c', 'kind' => 'bar-chart' }] }
]
pick, = FidelityLoop.pick_rcf_page(pages)
ok(pick['id'] == 'pa', 'Data page with many tables loses to the chart page')
pick, = FidelityLoop.pick_rcf_page(pages + [{ 'id' => 'pt', 'name' => 'Helpers', 'elements' => tbl.call(9) }])
ok(pick['id'] == 'pa', 'a tables-only page is de-prioritised too')
pick, = FidelityLoop.pick_rcf_page(
  [{ 'id' => 'p1', 'name' => 'Scratch', 'elements' => [{ 'id' => 'a', 'kind' => 'bar-chart' }] * 4 },
   { 'id' => 'p2', 'name' => 'Sales Dash', 'elements' => [{ 'id' => 'b', 'kind' => 'bar-chart' }] }], dashboard_names: ['sales dash'])
ok(pick['id'] == 'p2', 'a page named after a source dashboard beats a bigger non-dashboard page')
pick, top = FidelityLoop.pick_rcf_page([{ 'id' => 'pd', 'name' => 'Data', 'elements' => tbl.call(2) }])
ok(pick['id'] == 'pd' && top.length == 1, 'only a data page → still picked (fallback)')
pick, top = FidelityLoop.pick_rcf_page([{ 'id' => 'a', 'name' => 'A', 'elements' => [{ 'id' => 'x', 'kind' => 'bar-chart' }] }, { 'id' => 'b', 'name' => 'B', 'elements' => [{ 'id' => 'y', 'kind' => 'bar-chart' }] }])
ok(pick['id'] == 'a' && top.length == 2, 'ties keep first-by-order and report the tie')
multi = [
  { 'id' => 'p1', 'name' => 'Overview', 'elements' => [{ 'id' => 'x', 'kind' => 'bar-chart' }] },
  { 'id' => 'p2', 'name' => 'Customers', 'elements' => [{ 'id' => 'y', 'kind' => 'bar-chart' }] },
  { 'id' => 'p3', 'name' => 'Ops', 'elements' => [{ 'id' => 'z', 'kind' => 'bar-chart' }] }
]
ok(FidelityLoop.dashboard_pages(multi, dashboard_names: %w[Overview Customers Operations]).map { |p| p['id'] } ==
   %w[p1 p2 p3], 'a partial source-name match falls back to every visible dashboard page')
puts 'catalog-backed sigma-capability / ui-only (B2.1):'
def write_json(dir, name, doc)
  File.write(File.join(dir, name), JSON.generate(doc))
end

def read_ledger(dir)
  JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
end

def init_ledger(dir, max_passes: 5)
  run('init', '--workbook-id', 'WB', '--page-id', 'PG', '--max-passes', max_passes.to_s, dir: dir)
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  out, st = run('record', '--dimension', 'composition_match', '--delta', 'tab strip border', '--class', 'sigma-capability', dir: dir)
  ok(st.exitstatus == 6, 'sigma-capability without catalog id refused (exit 6)')
  ok(out.include?('--catalog-id') && out.include?('nav-button-style'), 'refusal names the flag and lists valid ids')
  ok(read_ledger(dir)['entries'].empty?, 'refused record writes nothing')

  out, st = run('record', '--dimension', 'composition_match', '--delta', 'x', '--class', 'sigma-capability',
                '--catalog-id', 'no-such-id', dir: dir)
  ok(st.exitstatus == 6 && out.include?('no-such-id') && out.include?('nav-button-style'),
     'unknown catalog id refused (exit 6), naming the id and listing valid ids')

  out, st = run('record', '--dimension', 'composition_match', '--delta', 'tab strip border', '--class', 'ui-only',
                '--catalog-id', 'nav-button-style', dir: dir)
  e = read_ledger(dir)['entries'].last
  ok(st.exitstatus.zero? && e && e['cls'] == 'sigma-capability' && e['catalog_id'] == 'nav-button-style',
     'ui-only maps to sigma-capability with catalog id')
  _, st = run('record', '--dimension', 'composition_match', '--delta', 'y', '--class', 'ui-only', dir: dir)
  ok(st.exitstatus == 6, 'ui-only without catalog id refused (exit 6)')
  _, st = run('status', dir: dir)
  ok(st.exitstatus.zero?, 'a catalogued entry never blocks status')
end

Dir.mktmpdir do |dir|
  # Legacy ledger: ui-only / sigma-capability entries with no catalog_id.
  init_ledger(dir)
  led = read_ledger(dir)
  led['entries'] = [
    { 'id' => 'e0', 'pass' => 1, 'dimension' => 'kpi-spark', 'delta' => 'spark', 'cls' => 'ui-only', 'resolved' => false },
    { 'id' => 'e1', 'pass' => 1, 'dimension' => 'legend', 'delta' => 'leg', 'cls' => 'sigma-capability', 'resolved' => false },
    { 'id' => 'e2', 'pass' => 1, 'dimension' => 'x', 'delta' => 'bad id', 'cls' => 'sigma-capability',
      'catalog_id' => 'bogus', 'resolved' => false },
    { 'id' => 'e3', 'pass' => 1, 'dimension' => 'x', 'delta' => 'ok', 'cls' => 'sigma-capability',
      'catalog_id' => 'nav-button-style', 'resolved' => false }
  ]
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(led))
  ok(FidelityLoop.unresolved_specfixable(led) == [0, 1, 2],
     'legacy/uncatalogued ui-only + sigma-capability count as spec-fixable (agrees with gate 8d); catalogued does not')
  ok(!FidelityLoop.ledger_ok?(led), 'ledger_ok? false while uncatalogued entries are unresolved')
  _, st = run('status', dir: dir)
  ok(st.exitstatus == 6, 'status exits 6 for legacy uncatalogued entries while budget remains')
end

puts 'green-offer (B2.1):'
def offer(dir)
  out, st = run('green-offer', dir: dir)
  [(JSON.parse(out) rescue nil), st, out]
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  run('record', '--dimension', 'numbers_formatted', '--delta', 'K vs k', '--class', 'spec-fixable', dir: dir)
  write_json(dir, 'visual-residuals.json', 'schema' => 'visual-residuals/v1', 'residuals' => [
    { 'tile' => 'pos 3', 'dimension' => 'labels_legible', 'description' => 'clipped label', 'severity' => 'minor', 'class' => 'fixable' }
  ], 'fixable_major' => [])
  o, st, = offer(dir)
  ok(st.exitstatus.zero? && o, 'green-offer exits 0 and prints JSON')
  ok(o && o['realistic'] == true && o['est_passes'] >= 1 && o['why_not'].nil?,
     'green-offer realistic when all gaps have recipes')
  ok(o && o['gaps'].length == 3 && o['est_passes'] == 1, 'gaps = RCF entries + residuals; est_passes = ceil(3/3)')
  ok(o && o['gaps'].all? { |g| g['route'].to_s.start_with?('recipe:') }, 'every gap routed to a recipe heading')
  pal = o && o['gaps'].find { |g| g['id'] == 'e0' }
  ok(pal && pal['route'] == 'recipe:canvas-theme--palette' && pal['dimension'] == 'palette_match',
     'palette gap routes to the Canvas, theme & palette recipe anchor')
  ok(o && o['gaps'].any? { |g| g['tile'] == 'pos 3' }, 'visual residual identified by tile')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  run('record', '--dimension', 'data', '--delta', 'revenue total differs', '--class', 'data', dir: dir)
  o, st, = offer(dir)
  ok(st.exitstatus.zero? && o && o['realistic'] == false && o['why_not'].to_s.include?('data'),
     'green-offer not realistic with a data gap (why_not mentions data)')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  write_json(dir, 'visual-residuals.json', 'schema' => 'visual-residuals/v1', 'residuals' => [],
             'fixable_major' => [{ 'tile' => 'pos 1', 'dimension' => 'chart_shapes_match',
                                   'description' => 'bar-table rebuilt as bars', 'severity' => 'major', 'class' => 'fixable' }],
             'platform_differences' => [{ 'tile' => 'pos 2', 'dimension' => 'composition_match',
                                          'description' => 'tabs', 'severity' => 'minor', 'class' => 'nav-button-style' }])
  o, = offer(dir)
  ok(o && o['realistic'] && o['gaps'].length == 1 && o['gaps'][0]['tile'] == 'pos 1' &&
     o['gaps'][0]['route'] == 'recipe:chart-kind-marks--axes',
     'fixable_major visual gap included in the offer; platform_differences excluded')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'composition_match', '--delta', 'tabs', '--class', 'sigma-capability',
      '--catalog-id', 'nav-button-style', dir: dir)
  o, st, = offer(dir)
  ok(st.exitstatus.zero? && o && o['gaps'].empty? && o['realistic'] == false &&
     o['why_not'] == 'no fixable gaps remain' && o['est_passes'].zero?,
     'catalogued platform difference excluded; no gaps -> realistic false, "no fixable gaps remain"')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'mystery_dim', '--delta', 'odd', '--class', 'spec-fixable', dir: dir)
  o, = offer(dir)
  ok(o && o['realistic'] == false && o['why_not'].to_s.include?('e0') && o['gaps'][0]['route'].nil?,
     'a gap with no recipe and no sdk route makes the offer unrealistic and is named')
  led = read_ledger(dir)
  led['entries'][0]['route'] = 'sdk' # per-entry route is NOT a producer contract: must be ignored
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(led))
  o, = offer(dir)
  ok(o && o['realistic'] == false && o['gaps'][0]['route'].nil?, 'REST ledger (no top-level route) with unmapped dimension stays unrealistic; per-entry route ignored')
  led['route'] = 'sdk'
  led['sdk'] = {}
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(led))
  o, = offer(dir)
  ok(o && o['realistic'] && o['gaps'][0]['route'] == 'sdk', "top-level ledger route 'sdk' routes a non-data gap to sdk")
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  File.write(File.join(dir, 'visual-residuals.json'), '{ not json')
  out, st = run('green-offer', dir: dir)
  ok(st.exitstatus != 0 && out.include?('visual-residuals.json'), 'malformed visual-residuals.json -> non-zero exit with clear message')
end

puts 'recipe_headings fence skipping:'
Dir.mktmpdir do |dir|
  f = File.join(dir, 'r.md')
  File.write(f, "## Real\n```\n## Fake\n```\n### Also real\n")
  ok(FidelityLoop.recipe_headings(f) == ['Real', 'Also real'], 'headings inside code fences are skipped')
end

puts 'status YELLOW-ready (B2.1):'
Dir.mktmpdir do |dir|
  init_ledger(dir, max_passes: 1)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  _, st = run('status', dir: dir)
  ok(st.exitstatus == 6, 'budget remaining: status still exits 6')
  led = read_ledger(dir)
  led['pass'] = 1
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(led))
  out, st = run('status', dir: dir)
  ok(st.exitstatus.zero? && out.include?('YELLOW-ready'), 'status YELLOW-ready after budget with spec-fixable left')
  run('record', '--dimension', 'data', '--delta', 'wrong total', '--class', 'data', dir: dir)
  _, st = run('status', dir: dir)
  ok(st.exitstatus == 6, 'unresolved data-class entry keeps status blocking even when budget is spent')
end

puts 'status: spent budget does not bypass an open SDK session (#939 x #945 combined):'
Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  led = read_ledger(dir)
  led['sdk'] = { 'state' => 'open', 'sessions' => [{ 'id' => 'S1', 'writes' => [] }] } # open SDK session (no network)
  led['pass'] = 1
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(led))
  out, st = run('status', dir: dir)
  ok(st.exitstatus == 6 && !out.include?('YELLOW-ready'),
     'budget spent + open SDK session: status still blocks (exit 6), never YELLOW-ready')
  ok(out.include?('SDK route'), 'the block names the SDK route')
end


puts 'green-offer ledger blockers (final-review I2):'
Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  write_json(dir, 'parity-final.json', 'waivers' => ['--skip-anchor-check'],
             'waiver_reasons' => { '--skip-anchor-check' => 'no anchors for this source' })
  write_json(dir, 'visual-residuals.json', 'schema' => 'visual-residuals/v1', 'residuals' => [
    { 'tile' => 'pos 3', 'dimension' => 'labels_legible', 'description' => 'clipped label', 'severity' => 'minor', 'class' => 'fixable' }
  ], 'fixable_major' => [])
  o, st, = offer(dir)
  ok(st.exitstatus.zero? && o && o['realistic'] == false &&
     o['why_not'] == 'GREEN is forfeited by quality-waiver: --skip-anchor-check',
     'a quality waiver forfeits GREEN even with a minor visual residual: why_not names it')
  ok(o && o['blockers'] == ['quality-waiver: --skip-anchor-check'], 'blockers array lists the offender')
  ok(o && o['gaps'].length == 2, 'gaps are still listed')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  run('record', '--dimension', 'numbers_formatted', '--delta', 'K vs k', '--class', 'spec-fixable', dir: dir)
  out, st = run('green-offer', '--accept-residuals', 'e0', dir: dir)
  o = JSON.parse(out) rescue nil
  ok(st.exitstatus.zero? && o && o['gaps'].map { |g| g['id'] } == ['e1'], 'accepted residual dropped from gaps')
  ok(o && o['realistic'] == false && o['why_not'].to_s.include?('GREEN is forfeited by') && o['why_not'].to_s.include?('e0'),
     'an accepted residual is a waiver: it forfeits GREEN and is named')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  write_json(dir, 'layout-arrangement.json', 'pages' => [{ 'page' => 'P1', 'violations' => ['KPI row below the fold'] }])
  write_json(dir, 'visual-residuals.json', 'schema' => 'visual-residuals/v1', 'residuals' => [
    { 'tile' => 'pos 3', 'dimension' => 'labels_legible', 'description' => 'clipped', 'severity' => 'minor', 'class' => 'fixable' }
  ], 'fixable_major' => [])
  o, = offer(dir)
  ok(o && o['realistic'] == false && o['why_not'].to_s.start_with?('GREEN is forfeited by fidelity-residual: arrangement: P1'),
     'a layout-arrangement fidelity-residual forfeits GREEN')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  File.write(File.join(dir, 'offramps.jsonl'), JSON.generate('kind' => 'skip-flag-waived', 'detail' => '--skip-ref-check', 'reason' => 'r') + "\n")
  o, = offer(dir)
  ok(o && o['realistic'] == false && o['why_not'].to_s.include?('recorded-escape'), 'a recorded escape forfeits GREEN')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  write_json(dir, 'security-decision.json', 'decision' => 'skip', 'reason' => 'no RLS in source')
  o, = offer(dir)
  ok(o && o['realistic'] == false && o['why_not'].to_s.include?('security'), 'a security skip forfeits GREEN')
end

Dir.mktmpdir do |dir|
  init_ledger(dir)
  run('record', '--dimension', 'palette_match', '--delta', 'blue vs teal', '--class', 'spec-fixable', dir: dir)
  write_json(dir, 'visual-residuals.json', 'schema' => 'visual-residuals/v1', 'faithful' => true, 'residuals' => [
    { 'tile' => 'pos 3', 'dimension' => 'labels_legible', 'description' => 'clipped', 'severity' => 'minor', 'class' => 'fixable' }
  ], 'fixable_major' => [])
  o, = offer(dir)
  ok(o && o['realistic'] == true && o['blockers'] == [], 'clean ledger (only RCF + visual residuals) stays realistic with empty blockers')
end

puts 'green-offer / status unfaithful with no named gap (final-review m3):'
Dir.mktmpdir do |dir|
  init_ledger(dir, max_passes: 1)
  write_json(dir, 'visual-residuals.json', 'schema' => 'visual-residuals/v1', 'faithful' => false, 'score' => 60.0,
             'reasons' => ['score 60.0 is below the pass bar 75'], 'residuals' => [], 'fixable_major' => [])
  o, = offer(dir)
  ok(o && o['realistic'] == false &&
     o['why_not'] == 'unfaithful (score 60.0 is below the pass bar 75) but the grade named no fixable gap',
     'unfaithful grade with no gaps: not realistic, reasons quoted')
  out, st = run('status', dir: dir)
  ok(st.exitstatus.zero? && !out.include?('YELLOW-ready'), 'status budget remaining + unfaithful no gaps: plain satisfied (agrees with gate 8d)')
  led = read_ledger(dir)
  led['pass'] = 1
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(led))
  out, st = run('status', dir: dir)
  ok(st.exitstatus.zero? && out.include?('YELLOW-ready'), 'status prints YELLOW-ready after budget when only visual-divergent remains')
end

puts 'record --catalog-id dimension check (final-review m5):'
Dir.mktmpdir do |dir|
  init_ledger(dir)
  out, st = run('record', '--dimension', 'palette_match', '--delta', 'labels outside', '--class', 'sigma-capability',
                '--catalog-id', 'bar-label-outside-end', dir: dir)
  ok(st.exitstatus == 6 && out.include?('palette_match') && out.include?('labels_legible'),
     'a rubric dimension that differs from the catalog entry dimension is refused (exit 6) naming both')
  out, st = run('record', '--dimension', 'palette', '--delta', 'labels outside', '--class', 'sigma-capability',
                '--catalog-id', 'bar-label-outside-end', dir: dir)
  ok(st.exitstatus == 6 && out.include?('labels_legible'), 'free-form dimension that maps to another rubric key is also refused')
  out, st = run('record', '--dimension', 'labels_legible', '--delta', 'labels outside', '--class', 'sigma-capability',
                '--catalog-id', 'bar-label-outside-end', dir: dir)
  ok(st.exitstatus.zero?, 'matching rubric dimension accepted')
  out, st = run('record', '--dimension', 'kpi', '--delta', 'labels outside', '--class', 'sigma-capability',
                '--catalog-id', 'bar-label-outside-end', dir: dir)
  ok(st.exitstatus.zero? && out.include?('labels_legible') && out.include?('outside'),
     'unmapped free-form dimension accepted; entry dimension + description echoed')
end

puts 'minor = notes (TJ 2026-11-09): minor gaps on a PASSING grade are polish, never offered:'
POLISH_GAP = { 'tile' => 'r3c1', 'dimension' => 'palette_match', 'description' => 'thinner line',
               'severity' => 'minor', 'class' => 'fixable' }.freeze
POLISH_MAJOR = { 'tile' => 'r1c1', 'dimension' => 'composition_match', 'description' => 'KPI row missing',
                 'severity' => 'major', 'class' => 'fixable' }.freeze
def polish_dir(dir, verdict: 'pass', faithful: true, major: [], waivers: [])
  init_ledger(dir)
  write_json(dir, 'parity-final.json', 'status' => 'PASS', 'visual_verdict' => verdict, 'waivers' => waivers)
  write_json(dir, 'visual-residuals.json', 'schema' => 'visual-residuals/v1', 'faithful' => faithful,
                                           'residuals' => [POLISH_GAP], 'fixable_major' => major, 'reasons' => [])
end
Dir.mktmpdir do |dir|
  polish_dir(dir)
  o, st, = offer(dir)
  ok(st.exitstatus.zero? && o && o['realistic'] == false && o['gaps'].empty?,
     'pass grade + minor only: no push offered, no gaps')
  ok(o && o['why_not'] == 'GREEN, optional polish: 1 note', "why_not is 'GREEN, optional polish: 1 note'")
  ok(o && o['polish_notes'] == ['r3c1: thinner line'] && o['blockers'].empty?, 'polish_notes lists it; no blockers')
  ok(FidelityLoop.visual_gaps(dir).empty?, 'visual_gaps drops the minor on a passing grade')
  led = read_ledger(dir)
  led['pass'] = led['max_passes'] # budget spent: polish must still not be YELLOW-ready
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(led))
  out, st = run('status', dir: dir)
  ok(st.exitstatus.zero? && !out.include?('YELLOW-ready') && out.include?('GREEN, optional polish: 1 note'),
     'status with budget spent and only polish: not YELLOW-ready, prints GREEN, optional polish')
end
Dir.mktmpdir do |dir|
  polish_dir(dir, faithful: false, major: [POLISH_MAJOR])
  o, = offer(dir)
  ok(o && o['gaps'].map { |g| g['tile'] }.sort == %w[r1c1 r3c1] && o['polish_notes'].empty?,
     'pass + one major: both the major and the minor are offered gaps, no polish notes')
end
Dir.mktmpdir do |dir|
  polish_dir(dir, verdict: 'divergent', faithful: false)
  o, = offer(dir)
  ok(o && o['gaps'].map { |g| g['tile'] } == ['r3c1'] && o['polish_notes'].empty?,
     'divergent grade + minor: the minor stays an offered gap')
end
Dir.mktmpdir do |dir|
  polish_dir(dir, waivers: ['--skip-anchor-check'])
  o, = offer(dir)
  ok(o && o['realistic'] == false && o['why_not'].to_s.start_with?('GREEN is forfeited by') &&
     o['polish_notes'] == ['r3c1: thinner line'],
     'pass + minor + waiver: GREEN forfeited by the waiver (not by the polish note)')
end

Dir.mktmpdir do |dir|
  polish_dir(dir)
  write_json(dir, 'migration-result.json', 'source_objects' => [
    { 'type' => 'worksheet', 'id' => 'w1', 'name' => 'Margin', 'status' => 'approximated' }])
  o, = offer(dir)
  ok(o && o['realistic'] == false && o['why_not'].to_s.start_with?('GREEN is forfeited by object-approximated') &&
     o['polish_notes'] == ['r3c1: thinner line'],
     'review I1: pass + minor + an approximated object: never "GREEN, optional polish" (report-level forfeit)')
end
Dir.mktmpdir do |dir|
  polish_dir(dir)
  write_json(dir, 'waivers.json', 'waivers' => [{ 'flag' => '--allow-missing-tiles', 'reason' => 'x' }])
  o, = offer(dir)
  ok(o && o['why_not'].to_s.start_with?('GREEN is forfeited by waiver'), 'review I1: a waivers.json entry forfeits GREEN in green-offer')
end
Dir.mktmpdir do |dir|
  polish_dir(dir, waivers: ['--skip-anchor-check'])
  out, st = run('status', dir: dir)
  ok(st.exitstatus.zero? && !out.include?('GREEN, optional polish') && out.include?('1 polish note'),
     'review I1: status with a waiver prints the polish note but not "GREEN"')
end

puts 'pivot width guard (plan C R7: widths fit the cell or Sigma discards them all):'
Dir.mktmpdir do |dir|
  run('init', '--workbook-id', 'WB', '--page-id', 'PG', dir: dir)
  # Builder-emitted: 2 row headers x 93 + 25 value columns x 26 = 836 in a 898px cell.
  pivot = lambda do |body: 26, spacing: 'extra-small'|
    { 'id' => 'pv', 'kind' => 'pivot-table',
      'rowsBy' => [{ 'columnId' => 'r1' }, { 'columnId' => 'r2' }], 'columnsBy' => [{ 'columnId' => 'c1' }],
      'values' => %w[v1 v2 v3 v4 v5],
      'display' => { 'rowLayout' => 'separate-columns', 'headerWidths' => { 'uniformWidth' => 93 },
                     'bodyWidths' => { 'uniformWidth' => body } },
      'tableStyle' => { 'cellSpacing' => spacing } }
  end
  live = { 'document' => { 'schemaVersion' => 1, 'kind' => 'workbook', 'pages' => [{ 'id' => 'PG' }],
                           'elements' => [pivot.call], 'layout' => '<Page id="PG"><Element elementId="pv"/></Page>' } }
  File.write(File.join(dir, 'live.json'), JSON.generate(live))
  attempt = lambda do |patch|
    File.write(File.join(dir, 'patch.json'), JSON.generate('elements' => [patch.merge('id' => 'pv')]))
    run('apply-patch', '--patch', File.join(dir, 'patch.json'), '--dry-run', '--live-spec', File.join(dir, 'live.json'),
        '--out', File.join(dir, 'merged.json'), dir: dir)
  end

  # Cell unknown (no provenance/layout in the workdir): the builder-emitted widths are the ceiling.
  out, st = attempt.call('display' => { 'bodyWidths' => { 'uniformWidth' => 30 } })
  ok(st.exitstatus == 4 && out.include?('discard') && out.include?('26'),
     'widening the body past the builder width (no cell known) is rejected, naming the max (26)')
  out, st = attempt.call('display' => { 'bodyWidths' => { 'uniformWidth' => 24 } })
  ok(st.exitstatus.zero?, 'narrowing the body is accepted')

  # Cell known (provenance -> zone caption -> layout canvas x w_pct): canvas 1000 x w_pct 100 -> cell 936.
  File.write(File.join(dir, 'chart-provenance.json'),
             JSON.generate('version' => 1, 'elements' => { 'pv' => { 'worksheet' => 'Sales Matrix', 'dashboard' => 'D' } }))
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate([{ 'dashboard' => 'D', 'canvas_px' => { 'w' => 1000 },
    'zones' => [{ 'id' => '4', 'caption' => 'Sales Matrix', 'chart_kind' => 'pivot-table', 'w_pct' => 100 }] }]))
  # cell 936; builder 2x93 + V x 26 fits, V_est = floor((936-186-8)/26) = 28; max body = floor((936-8-186)/28) = 26
  out, st = attempt.call('display' => { 'bodyWidths' => { 'uniformWidth' => 30 } })
  ok(st.exitstatus == 4 && out.include?('max body width that fits is 26'), 'overflowing body rejected with the max-fit number from the cell')
  out, st = attempt.call('display' => { 'headerWidths' => { 'uniformWidth' => 60 }, 'bodyWidths' => { 'uniformWidth' => 26 } })
  ok(st.exitstatus.zero?, 'a patch that fits the cell is accepted (narrower header)')

  # Squeezed pivot (body < 48): cellSpacing medium/large is illegible (live-proven) -> rejected.
  %w[large medium].each do |sp|
    out, st = attempt.call('tableStyle' => { 'cellSpacing' => sp })
    ok(st.exitstatus == 4 && out.include?('extra-small') && out.include?(sp), "cellSpacing #{sp} on a squeezed pivot is rejected")
  end
  out, st = attempt.call('tableStyle' => { 'cellSpacing' => 'small' })
  ok(st.exitstatus.zero?, 'cellSpacing small on a squeezed pivot is accepted')
  # A roomy pivot (body >= 48) may use any spacing.
  File.write(File.join(dir, 'live.json'), JSON.generate('document' => live['document'].merge('elements' => [pivot.call(body: 50)])))
  out, st = attempt.call('tableStyle' => { 'cellSpacing' => 'large' })
  ok(st.exitstatus.zero?, 'cellSpacing large on a roomy pivot is accepted')
  # Builder emitted no body width (value columns unknown / body < 16px): an RCF patch that ADDS one
  # cannot be checked (value_n is a Tableau-CSV figure the guard cannot reach) -> rejected when the cell is known.
  File.write(File.join(dir, 'live.json'), JSON.generate('document' => live['document'].merge(
    'elements' => [pivot.call.tap { |e| e['display'].delete('bodyWidths') }])))
  out, st = attempt.call('display' => { 'bodyWidths' => { 'uniformWidth' => 30 } })
  ok(st.exitstatus == 4 && out.include?('builder omitted') && out.include?('discard'),
     'adding a body width where the builder emitted none is rejected (cell known, value_n not derivable)')
  File.write(File.join(dir, 'live.json'), JSON.generate('document' => live['document'].merge('elements' => [{ 'id' => 'pv', 'kind' => 'pivot-table', 'display' => {} }])))
  out, st = attempt.call('display' => { 'bodyWidths' => { 'uniformWidth' => 30 } })
  ok(st.exitstatus == 4, 'adding a body width to a pivot with an empty display ({}) is rejected too')
  out, st = attempt.call('tableStyle' => { 'cellSpacing' => 'large' })
  ok(st.exitstatus.zero?, 'a patch that touches no widths on a pivot without a body width is accepted')

  # One row-header column (rowLayout != separate-columns): n_hdr = 1.
  one = pivot.call.tap { |e| e['display'].delete('rowLayout') }
  File.write(File.join(dir, 'live.json'), JSON.generate('document' => live['document'].merge('elements' => [one])))
  # V = floor((936 - 93 - 8) / 26) = 32; body 30 -> 93 + 32 x 30 > 928; max = floor(835 / 32) = 26
  out, st = attempt.call('display' => { 'bodyWidths' => { 'uniformWidth' => 30 } })
  ok(st.exitstatus == 4 && out.include?('1 x 93 + 32 x 30') && out.include?('max body width that fits is 26'),
     'n_hdr = 1 (single row-header column) overflow rejected with the n_hdr = 1 arithmetic')

  # --full-spec: the guard compares against the persisted workbook spec (wb-spec.json), not a --patch merge.
  File.write(File.join(dir, 'wb-spec.json'), JSON.generate('document' => live['document'].merge('elements' => [pivot.call])))
  full = lambda do |el|
    File.write(File.join(dir, 'full.json'), JSON.generate('document' => live['document'].merge('elements' => [el])))
    run('apply-patch', '--full-spec', File.join(dir, 'full.json'), '--dry-run', '--out', File.join(dir, 'merged.json'), dir: dir)
  end
  wide = pivot.call.tap { |e| e['display']['bodyWidths']['uniformWidth'] = 30 }
  out, st = full.call(wide)
  ok(st.exitstatus == 4 && out.include?('max body width that fits is 26'), '--full-spec overflowing a pivot vs wb-spec.json is rejected')
  out, st = full.call(pivot.call(body: 24))
  ok(st.exitstatus.zero?, '--full-spec narrowing a pivot is accepted')
  out, st = full.call(pivot.call(spacing: 'large'))
  ok(st.exitstatus == 4 && out.include?('extra-small'), '--full-spec large cellSpacing on a squeezed pivot is rejected')
  File.delete(File.join(dir, 'wb-spec.json'))
  out, st = full.call(wide)
  ok(st.exitstatus.zero? && out.include?('WARN') && out.include?('pivot'),
     '--full-spec with no baseline: accepted with a pivot-guard warning (value_n not derivable)')
end

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
