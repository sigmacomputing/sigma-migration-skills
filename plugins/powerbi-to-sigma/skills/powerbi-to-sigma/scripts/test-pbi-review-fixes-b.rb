#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-review-fixes-b.rb — regressions for the code-review findings fixed on the large-PBIX
# speedups branch (group B). Offline, synthetic names only (Sales / Region / Segment).
#
#   compat-1 / sigma-shapes-1 / whole-2  bookmark contract: the builder reads the extractor's
#        real bookmark shape ({name, display_name, hides, shows}); a route with NO bookmark data
#        (classic) never holds a hidden visual back
#   compat-2   a by-design held-back hidden visual is recoverable:false (no ack demanded)
#   sigma-shapes-3  boolean element list filters ship as the exclude complement
#   sigma-shapes-4  slicer_state.saved_selection_unsupported -> degraded coverage (list + date)
#   whole-4    extractor-typed saved selections are never re-parsed as PBIR literals
#   whole-9    a (Blank)-only saved selection never ships as include []
#
# Run: ruby scripts/test-pbi-review-fixes-b.rb
require 'json'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative 'lib/pbi_reportbuild'
require_relative 'lib/ruby_compat'

$fail = 0
def ok(name, cond, got = nil)
  puts((cond ? '  ok  ' : 'FAIL  ') + name + (cond ? '' : "   got=#{got.inspect}"))
  $fail += 1 unless cond
end
R = PbiReportBuild
HERE = File.dirname(File.expand_path(__FILE__))
BUILD = File.join(HERE, 'build-workbook-from-pbir.rb')
EXTRACT = File.join(HERE, 'extract-pbir.py')

# ---------------------------------------------------------------------------------------------
# Cross-boundary: a tiny PBIR fixture -> the REAL extractor -> the builder's partitioning
# ---------------------------------------------------------------------------------------------
def write_json(path, obj)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate(obj))
end

def col(entity, prop)
  { 'Column' => { 'Expression' => { 'SourceRef' => { 'Entity' => entity } }, 'Property' => prop } }
end

def pbir_visual(name, vtype, entity, prop, hidden: false, x: 0, general: nil)
  v = { 'name' => name, 'position' => { 'x' => x, 'y' => 0, 'width' => 100, 'height' => 50, 'z' => 0 },
        'visual' => { 'visualType' => vtype,
                      'query' => { 'queryState' => { 'Values' => { 'projections' => [
                        { 'field' => col(entity, prop), 'queryRef' => "#{entity}.#{prop}" }] } } } } }
  v['isHidden'] = true if hidden
  v['visual']['objects'] = { 'general' => [{ 'properties' => { 'filter' => { 'filter' => general } } }] } if general
  v
end

def in_filter(entity, prop, literals)
  { 'Version' => 2, 'From' => [{ 'Name' => 's', 'Entity' => entity, 'Type' => 0 }],
    'Where' => [{ 'Condition' => { 'In' => {
      'Expressions' => [{ 'Column' => { 'Expression' => { 'SourceRef' => { 'Source' => 's' } }, 'Property' => prop } }],
      'Values' => literals.map { |l| [{ 'Literal' => { 'Value' => l } }] } } } }] }
end

def between_filter(entity, prop)
  { 'Version' => 2, 'From' => [{ 'Name' => 's', 'Entity' => entity, 'Type' => 0 }],
    'Where' => [{ 'Condition' => { 'Between' => {
      'Expression' => { 'Column' => { 'Expression' => { 'SourceRef' => { 'Source' => 's' } }, 'Property' => prop } },
      'LowerBound' => { 'Literal' => { 'Value' => "datetime'2025-01-01T00:00:00'" } },
      'UpperBound' => { 'Literal' => { 'Value' => "datetime'2025-12-31T00:00:00'" } } } } }] }
end

def extract_fixture(dir)
  d = File.join(dir, 'definition')
  write_json(File.join(d, 'pages', 'pages.json'), { 'pageOrder' => ['p1'], 'activePageName' => 'p1' })
  write_json(File.join(d, 'pages', 'p1', 'page.json'), { 'name' => 'p1', 'displayName' => 'Overview' })
  pv = File.join(d, 'pages', 'p1', 'visuals')
  write_json(File.join(pv, 'vShown', 'visual.json'), pbir_visual('vShown', 'card', 'Sales', 'Total'))
  write_json(File.join(pv, 'vToggled', 'visual.json'), pbir_visual('vToggled', 'card', 'Sales', 'Total', hidden: true, x: 10))
  write_json(File.join(pv, 'vScaffold', 'visual.json'), pbir_visual('vScaffold', 'card', 'Sales', 'Total', hidden: true, x: 20))
  write_json(File.join(pv, 'sText', 'visual.json'),
             pbir_visual('sText', 'slicer', 'Sales', 'Status', x: 30,
                         general: in_filter('Sales', 'Status', ["'True'", "'100D'", "'N/A'", "'null'"])))
  write_json(File.join(pv, 'sBlank', 'visual.json'),
             pbir_visual('sBlank', 'slicer', 'Sales', 'Region', x: 40, general: in_filter('Sales', 'Region', ['null'])))
  write_json(File.join(pv, 'sDate', 'visual.json'),
             pbir_visual('sDate', 'slicer', 'Sales', 'OrderDate', x: 50, general: between_filter('Sales', 'OrderDate')))
  bm = File.join(d, 'bookmarks')
  write_json(File.join(bm, 'bookmarks.json'), { 'items' => [{ 'name' => 'bmDetail' }] })
  write_json(File.join(bm, 'bmDetail.bookmark.json'),
             { 'name' => 'bmDetail', 'displayName' => 'Show detail',
               'explorationState' => { 'activeSection' => 'p1', 'sections' => { 'p1' => { 'visualContainers' => {
                 'vToggled' => { 'singleVisual' => { 'visualType' => 'card' } } } } } } })
  out = File.join(dir, 'signals.json')
  ok('extractor runs on the PBIR fixture',
     # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
     # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
     system('python3', '-I', EXTRACT, '--pbir-dir', dir, '--out', out, out: File::NULL, err: File::NULL))
  JSON.parse(File.read(out))
end

Dir.mktmpdir('pbi-xbound') do |dir|
  sig = extract_fixture(dir)
  bms = sig['bookmarks']
  visuals = sig['pages'][0]['visuals']
  ok('extractor bookmark shape is {name, display_name, shows}',
     bms.is_a?(Array) && bms[0]['display_name'] == 'Show detail' && bms[0]['shows'] == ['vToggled'], bms)
  part = R.partition_hidden(visuals, bms)
  ok('compat-1/whole-2: a bookmark-toggled hidden visual (real extractor output) is KEPT and revealed',
     part['revealed'].map { |v, _| v['visual_id'] } == ['vToggled'] && part['kept'].any? { |v| v['visual_id'] == 'vToggled' },
     part['revealed'].map { |v, n| [v['visual_id'], n] })
  ok('sigma-shapes-1: the revealed visual carries the extractor display_name',
     part['revealed'][0][1] == ['Show detail'], part['revealed'][0])
  ok('compat-1: a hidden visual no bookmark shows is still held back (bookmark data present)',
     part['held'].map { |v, _| v['visual_id'] } == ['vScaffold'], part['held'].map { |v, _| v['visual_id'] })

  # whole-4 / whole-9 / sigma-shapes-4 on real extractor output
  by = visuals.each_with_object({}) { |v, h| h[v['visual_id']] = v }
  d = R.list_default(is_bool: false, type: :text, state: by['sText']['slicer_state'], qr: 'Sales.Status')
  ok('whole-4: extractor-typed text members True / 100D / N/A / null survive verbatim (no double decode)',
     d['values'] == %w[True 100D N/A null] && d['has_null'] == false && d['skipped'] == [], d)
  d = R.list_default(is_bool: false, type: :text, state: by['sBlank']['slicer_state'], qr: 'Sales.Region')
  ok('whole-9: a (Blank)-only saved selection is flagged blank_only (never a silent include [])',
     d['blank_only'] == true && d['mode'] == 'include' && d['values'] == [], d)
  ok('sigma-shapes-4: a date Between slicer carries saved_selection_unsupported from the extractor',
     by['sDate']['slicer_state']['saved_selection_unsupported'] == 'not-an-in-list', by['sDate']['slicer_state'])
end

# ---------------------------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------------------------
v = ->(id, extra = {}) { { 'visual_id' => id, 'sigma_kind' => 'bar', 'visual_type' => 'barChart' }.merge(extra) }
hid = [v.call('a'), v.call('h', 'hidden' => true)]
ok('no bookmark data at all (nil, e.g. classic route): hidden visual is kept + listed unverified, never held',
   (p1 = R.partition_hidden(hid, nil)) && p1['held'].empty? && p1['kept'].size == 2 &&
     p1['unverified'].map { |(x)| x['visual_id'] } == ['h'], p1)
ok('bookmark data present but empty: hidden visual held back (nothing shows it)',
   (p2 = R.partition_hidden(hid, [])) && p2['held'].size == 1 && p2['unverified'].empty?, p2)
ok('legacy bookmark keys (shown / displayName) are still honoured as fallbacks',
   R.partition_hidden(hid, [{ 'name' => 'x', 'displayName' => 'Old', 'shown' => ['h'] }])['revealed'] == [[hid[1], ['Old']]])
ok('label falls back display_name -> displayName -> name',
   R.bookmark_reveals([{ 'name' => 'n', 'shows' => ['h'] }]) == { 'h' => ['n'] })

# whole-4: decoded values by JSON type only; raw literals still parse
sel = ->(vals, extra = {}) { { 'saved_selection' => { 'mode' => 'include', 'column' => 'T.C', 'values' => vals, 'has_null' => false }.merge(extra) } }
d = R.list_default(is_bool: false, type: :text, state: sel.call(['True', '100D', 'N/A', 'null']))
ok('whole-4: text "True" / "100D" / "null" in saved_selection are not re-parsed', d['values'] == %w[True 100D N/A null] && !d['has_null'], d)
d = R.list_default(is_bool: false, type: :int, state: sel.call([2026, 2025]))
ok('whole-4: JSON ints stay ints', d['values'] == [2026, 2025], d)
d = R.list_default(is_bool: true, type: :bool, state: sel.call([false]))
ok('whole-4: JSON bool coerces to bool', d['values'] == [false], d)
d = R.list_default(is_bool: false, type: :text,
                   state: { 'selection' => { 'type' => 'list', 'mode' => 'include', 'column' => 'T.C', 'values' => ["'O''Brien'", '2026L'] } })
ok('whole-4: the legacy `selection` path still parses quoted / suffixed literals', d['values'] == ["O'Brien", '2026'], d)
t = R.typed_selection({ 'mode' => 'include', 'values' => ["'A'", 'null', '1.5D'] }, :text)
ok('typed_selection on raw (undecoded) literals is unchanged', t['values'] == ['A', '1.5'] && t['has_null'], t)

# whole-9
d = R.list_default(is_bool: false, type: :text, state: sel.call([], 'has_null' => true))
ok('whole-9: include + only (Blank) -> blank_only, default left at the all-rows default',
   d['blank_only'] && d['mode'] == 'include' && d['values'] == [], d)
d = R.list_default(is_bool: false, type: :text, state: sel.call(['A'], 'has_null' => true))
ok('whole-9: (Blank) plus real members is NOT blank_only', !d['blank_only'] && d['values'] == ['A'], d)
d = R.list_default(is_bool: false, type: :text, state: sel.call([], 'has_null' => true, 'mode' => 'exclude'))
ok('whole-9: exclude (Blank) only is not blank_only', !d['blank_only'], d)

# ---------------------------------------------------------------------------------------------
# End-to-end builds
# ---------------------------------------------------------------------------------------------
MMAP = {
  'masters' => { 'T' => { 'id' => 'master-t', 'element_id' => 'dm-el-1', 'data_model' => 'dm-1',
                          'columns' => %w[Region Segment Status Active OrderDate Amount].map { |c|
                            { 'id' => "mt-#{c.downcase}", 'name' => c, 'formula' => "[T/#{c}]" } } } },
  'fields' => %w[Region Segment Status Active OrderDate Amount].each_with_object({}) { |c, h|
    h["T.#{c}"] = { 'master' => 'T', 'ref' => "[T/#{c}]", 'agg' => (c == 'Amount' ? 'Sum' : nil) }
  }
}.freeze

def vis(id, kind, vtype, bindings, title, x, extra = {})
  { 'visual_id' => id, 'visual_type' => vtype, 'sigma_kind' => kind, 'title' => title, 'x' => x, 'y' => 0, 'w' => 140, 'h' => 80,
    'bindings' => bindings }.merge(extra)
end

def slicer(id, col, title, x, extra = {})
  vis(id, 'control', 'slicer', { 'Values' => ["T.#{col}"] }, title, x, extra)
end

def signals(bookmarks: :none)
  s = {
    'source' => 'pbir', 'theme' => nil,
    # report filter on a boolean column: include [false] -> exclude [true]
    'filters' => [{ 'scope' => 'report', 'target' => 'T.Active', 'type' => 'list', 'mode' => 'include', 'values' => [false] }],
    'pages' => [{
      'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [],
      # include both -> provably a no-op -> no filter at all
      'filters' => [{ 'scope' => 'page', 'target' => 'T.Active', 'type' => 'list', 'mode' => 'include', 'values' => [true, false] }],
      'visuals' => [
        vis('v_bar', 'bar', 'barChart', { 'Category' => ['T.Region'], 'Y' => ['T.Amount'] }, 'By Region', 0),
        vis('v_bool', 'bar', 'barChart', { 'Category' => ['T.Active'], 'Y' => ['T.Amount'] }, 'By Active', 150,
            'filters' => [{ 'scope' => 'visual', 'target' => 'T.Active', 'type' => 'list', 'mode' => 'include', 'values' => [true] }]),
        slicer('s_date', 'OrderDate', 'Order Date', 300, 'sigma_target' => 'date-range',
               'slicer_state' => { 'saved_selection_unsupported' => 'not-an-in-list' }),
        slicer('s_seg', 'Segment', 'Segment', 450, 'slicer_state' => { 'saved_selection_unsupported' => 'unmodeled-literal' }),
        slicer('s_blank', 'Region', 'Region', 600,
               'slicer_state' => { 'saved_selection' => { 'mode' => 'include', 'column' => 'T.Region', 'values' => [], 'has_null' => true } }),
        slicer('s_text', 'Status', 'Status', 750,
               'slicer_state' => { 'saved_selection' => { 'mode' => 'include', 'column' => 'T.Status',
                                                           'values' => %w[True 100D], 'has_null' => false } }),
        vis('h_plain', 'bar', 'barChart', { 'Category' => ['T.Segment'], 'Y' => ['T.Amount'] }, 'Hidden Plain', 900, 'hidden' => true),
        vis('h_rev', 'bar', 'barChart', { 'Category' => ['T.Segment'], 'Y' => ['T.Amount'] }, 'Hidden Toggle', 1050, 'hidden' => true)
      ]
    }]
  }
  s['bookmarks'] = bookmarks unless bookmarks == :none
  s
end

def build(dir, sigs)
  File.write(File.join(dir, 'sig.json'), JSON.generate(sigs))
  File.write(File.join(dir, 'mm.json'), JSON.generate(MMAP))
  wb = File.join(dir, 'wb.json')
  err = File.join(dir, 'err.txt')
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  st = system(RbConfig.ruby, BUILD, '--signals', File.join(dir, 'sig.json'), '--master-map', File.join(dir, 'mm.json'),
              '--data-model', 'dm-1', '--out', wb, '--layout-out', File.join(dir, 'l.xml'), '--name', 'Review B',
              '--coverage-out', File.join(dir, 'cov.json'), '--no-prune-masters', out: File::NULL, err: File.open(err, 'w'))
  puts File.read(err).lines.last(8).join unless st
  return nil unless st
  [JSON.parse(File.read(wb)), JSON.parse(File.read(File.join(dir, 'cov.json'))), File.read(err)]
end

bm_real = [{ 'name' => 'bmDetail', 'display_name' => 'Show detail', 'page_id' => 'p1', 'hides' => [], 'shows' => ['h_rev'],
             'spotlight' => [], 'applies_to' => nil, 'suppress_display' => false }]

Dir.mktmpdir('pbi-review-b') do |dir|
  res = build(dir, signals(bookmarks: bm_real))
  ok('PBIR-route build exits 0', !res.nil?)
  spec, cov, = res
  els = spec.dig('document', 'elements')
  cover = cov['unresolved'] || []
  by_name = ->(n) { els.find { |e| e['name'] == n } }

  # compat-1 / compat-2
  ok('compat-1: the bookmark-revealed hidden visual is kept (real extractor bookmark shape)', by_name.call('Hidden Toggle'))
  ok('compat-1: its coverage entry names the bookmark display_name',
     cover.any? { |u| u['visual'] == 'Hidden Toggle' && u['detail'].to_s.include?('Show detail') }, cover.map { |u| u['detail'] })
  ok('compat-1: a hidden visual no bookmark shows is held back', by_name.call('Hidden Plain').nil?)
  held = cover.find { |u| u['visual'] == 'Hidden Plain' }
  ok('compat-2: the by-design held-back visual is recorded recoverable:false (no acknowledgement demanded)',
     held && held['severity'] == 'dropped' && held['recoverable'] == false, held)

  # sigma-shapes-3
  mt = els.find { |e| e['id'] == 'master-t' }
  mf = Array(mt['filters'])
  ok('sigma-shapes-3: report boolean include [false] ships as exclude [true] on the master',
     mf.size == 1 && mf[0]['kind'] == 'list' && mf[0]['mode'] == 'exclude' && mf[0]['values'] == [true], mf)
  ok('sigma-shapes-3: a boolean include of both values (page filter) emits no filter at all',
     mf.none? { |f| f['values'] == [true, false] || f['values'] == [false, true] })
  bar = by_name.call('By Active')
  bf = Array(bar && bar['filters'])
  ok('sigma-shapes-3: a visual boolean include [true] ships as exclude [false]',
     bf.size == 1 && bf[0]['mode'] == 'exclude' && bf[0]['values'] == [false], bf)

  # sigma-shapes-4
  ok('sigma-shapes-4: an unmodeled saved selection on the DATE slicer is recorded degraded',
     cover.any? { |u| u['visual'] == 'Order Date' && u['severity'] == 'degraded' && u['detail'].to_s.include?('not-an-in-list') }, cover)
  ok('sigma-shapes-4: an unmodeled saved selection on the LIST slicer is recorded degraded',
     cover.any? { |u| u['visual'] == 'Segment' && u['severity'] == 'degraded' && u['detail'].to_s.include?('unmodeled-literal') }, cover)

  # whole-9
  blank = by_name.call('Region')
  ok('whole-9: a (Blank)-only default never ships as a silent include [] without a dropped coverage entry',
     blank && cover.any? { |u| u['visual'] == 'Region' && u['severity'] == 'dropped' &&
                                u['detail'].to_s.include?('default shows all rows; source showed only blanks') }, cover)
  # whole-4
  txt = by_name.call('Status')
  ok('whole-4: the text slicer default keeps "True" / "100D" verbatim', txt && txt['values'] == %w[True 100D], txt)
end

Dir.mktmpdir('pbi-review-b-classic') do |dir|
  res = build(dir, signals) # no 'bookmarks' key at all: the classic Report/Layout route
  ok('classic-route build exits 0', !res.nil?)
  spec, cov, = res
  els = spec.dig('document', 'elements')
  cover = cov['unresolved'] || []
  ok('compat-1: with no bookmark data on the route, hidden visuals are laid out, not dropped',
     els.any? { |e| e['name'] == 'Hidden Plain' } && els.any? { |e| e['name'] == 'Hidden Toggle' })
  ok('compat-1: each laid-out hidden visual gets an informational coverage note (recoverable:false)',
     %w[Hidden\ Plain Hidden\ Toggle].all? do |n|
       cover.any? { |u| u['visual'] == n && u['recoverable'] == false && u['detail'].to_s.include?('no bookmark data') }
     end, cover.map { |u| [u['visual'], u['detail']] })
end

puts($fail.zero? ? "\nall review-fix-B tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
