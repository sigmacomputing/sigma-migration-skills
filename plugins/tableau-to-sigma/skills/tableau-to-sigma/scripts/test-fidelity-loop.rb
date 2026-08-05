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
FidelityLoop.add_entry(led, dimension: 'kpi-spark', delta: 'sparkline missing', cls: 'ui-only')
ok(led['entries'].length == 2, 'entries appended')
ok(led['entries'][0]['id'] == 'e0', 'stable id assigned')
ok(!FidelityLoop.ledger_ok?(led), 'unresolved spec-fixable blocks the gate')
ok(FidelityLoop.unresolved_specfixable(led).length == 1, 'ui-only does NOT block')

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
  live = { 'pages' => [{ 'id' => 'PG', 'elements' => [{ 'elementId' => 'k1', 'kind' => 'kpi-chart' }] }],
           'layout' => '<Page><LayoutElement/></Page>', 'themeName' => 'Light' }
  File.write(File.join(dir, 'live.json'), JSON.generate(live))
  File.write(File.join(dir, 'patch.json'),
             JSON.generate({ 'themeOverrides' => { 'categoricalScheme' => ['#0e7c7b'] } }))
  out, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'),
                '--dry-run', '--live-spec', File.join(dir, 'live.json'),
                '--out', File.join(dir, 'merged.json'), '--resolves', 'e0', dir: dir)
  ok(st.exitstatus.zero?, 'dry-run apply-patch exits 0')
  merged = JSON.parse(File.read(File.join(dir, 'merged.json')))
  ok(merged['layout'] == live['layout'], 'layout preserved through the merge (PUT-wipes-layout trap avoided)')
  ok(merged['themeOverrides']['categoricalScheme'] == ['#0e7c7b'], 'patch applied to merged spec')
  ok(merged['pages'][0]['elements'][0]['elementId'] == 'k1', 'existing element retained')

  # after --resolves e0, status clears
  _, st = run('status', dir: dir)
  ok(st.exitstatus.zero?, 'status exits 0 after the delta is resolved')

  # apply-patch refuses a merge that would blank the workbook (no pages)
  File.write(File.join(dir, 'nopages.json'), JSON.generate({ 'themeName' => 'Light' }))
  _, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'),
              '--dry-run', '--live-spec', File.join(dir, 'nopages.json'),
              '--out', File.join(dir, 'x.json'), dir: dir)
  ok(st.exitstatus == 4, 'apply-patch refuses a live spec with no pages (exit 4)')
end

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
  run('record', '--dimension', 'palette', '--delta', 'x', '--class', 'ui-only', dir: dir)
  out, st = run('init', '--workbook-id', 'WB', '--page-id', 'live-other', dir: dir)
  led = JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json')))
  ok(st.exitstatus.zero? && out.include?('OVERRIDDEN'), 'init --page-id on an existing ledger overrides in place')
  ok(led['page_id'] == 'live-other' && led['entries'].length == 1, 'override preserves the recorded entries')
end

Dir.mktmpdir do |dir|
  _out, st = run('init', '--workbook-id', 'WB', dir: dir)
  ok(st.exitstatus == 2, 'init dies (usage) with no --page-id and nothing to auto-pick from')
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
  wb_spec = { 'pages' => [{ 'id' => 'page-ov', 'elements' => [
    { 'elementId' => 'k1', 'kind' => 'kpi-chart', 'style' => { 'x' => 1 } },
    { 'elementId' => 'k2', 'kind' => 'bar-chart' }] }], 'themeName' => 'Light' }
  File.write(File.join(dir, 'wb-spec.json'), JSON.generate(wb_spec))
  live = { 'pages' => [{ 'id' => 'PG', 'elements' => [{ 'elementId' => 'k1', 'kind' => 'kpi-chart' }] }] }
  File.write(File.join(dir, 'live.json'), JSON.generate(live))
  File.write(File.join(dir, 'patch.json'),
             JSON.generate('themeOverrides' => { 'categoricalScheme' => ['#0e7c7b'] }))
  out, st = run('apply-patch', '--patch', File.join(dir, 'patch.json'), '--dry-run',
                '--live-spec', File.join(dir, 'live.json'), '--out', File.join(dir, 'merged.json'), dir: dir)
  ok(st.exitstatus.zero?, 'apply-patch (dual-write) exits 0')
  ok(out.include?('persisted into'), 'apply-patch reports the wb-spec.json persistence')
  ws = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))
  ok(ws['themeOverrides'] == { 'categoricalScheme' => ['#0e7c7b'] },
     'patch deep-merged into wb-spec.json (a re-entry full-spec PUT now carries the fix)')
  ok(ws['pages'][0]['elements'].length == 2 && ws['themeName'] == 'Light',
     'wb-spec.json untouched keys/elements preserved by the merge')

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
  _, st = run('render', dir: dir)
  ok(st.exitstatus == 3, 'render exits 3 when the pass budget is exhausted')
end

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
