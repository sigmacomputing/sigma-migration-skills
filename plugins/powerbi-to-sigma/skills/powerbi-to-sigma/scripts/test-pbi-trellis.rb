#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-pbi-trellis.rb — end-to-end regression for the Power BI "Small multiples"
# field well -> Sigma native `trellis` wiring in build-workbook-from-pbir.rb
# (shared TrellisEmit). Offline: no API, no creds. Runs the REAL builder as a
# subprocess against synthesized signals + master-map fixtures and asserts on the
# emitted workbook spec + the native-trellis-emitted.json round-trip sidecar.
#
# Covers:
#   1. bar visual WITH SmallMultiples  -> ONE bar-chart element carrying
#      trellis.columnsBy referencing the facet column (single PBI facet -> Sigma
#      tile grid via columnsBy); the facet is added as a real column.
#   2. bar visual WITHOUT SmallMultiples -> NO trellis key (detection-gated;
#      built exactly as before).
#   3. pie visual WITH SmallMultiples  -> flipped to donut-chart + trellis
#      (pie silently strips the key on readback; donut supports it).
#   4. kpi visual WITH SmallMultiples  -> NO trellis (Sigma strips it on a
#      kpi-chart); recorded as a degraded fallback, not silently emitted.
#   5. the round-trip sidecar lists exactly the trellised elements (bar + donut).
#   6. a signals file with NO small-multiples visual writes NO sidecar and emits
#      NO trellis anywhere (byte-identical-shape guarantee).
#
# Run: ruby scripts/test-pbi-trellis.rb
require 'json'
require 'tmpdir'
require 'open3'

HERE     = __dir__
BUILDER  = File.join(HERE, 'build-workbook-from-pbir.rb')
DM_ID    = 'dm-test-0001'

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# One master "OF" carrying every field the fixtures bind (Channel dim, Region
# facet dim, Revenue measure). Region is the small-multiples facet.
MASTER_MAP = {
  'masters' => {
    'OF' => {
      'id' => 'master-of', 'element_id' => 'el-of', 'data_model' => DM_ID,
      'columns' => [
        { 'id' => 'mof-rev', 'name' => 'Net Revenue',  'formula' => '[Order Fact/Net Revenue]' },
        { 'id' => 'mof-ch',  'name' => 'Order Channel', 'formula' => '[Order Fact/Order Channel]' },
        { 'id' => 'mof-rg',  'name' => 'Region',        'formula' => '[Order Fact/Region]' }
      ]
    }
  },
  'fields' => {
    'ORDER_FACT.Total Net Revenue' => { 'master' => 'OF', 'ref' => '[OF/Net Revenue]',   'agg' => 'Sum' },
    'ORDER_FACT.Order Channel'      => { 'master' => 'OF', 'ref' => '[OF/Order Channel]', 'agg' => nil },
    'ORDER_FACT.Region'             => { 'master' => 'OF', 'ref' => '[OF/Region]',        'agg' => nil }
  }
}.freeze

def visual(id, type, kind, bindings, title)
  { 'visual_id' => id, 'visual_type' => type, 'sigma_kind' => kind, 'title' => title,
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'orientation' => nil,
    'bindings' => bindings, 'formats' => {} }
end

# Run the real builder; return the parsed workbook spec + parsed sidecar (or nil).
def build(signals)
  Dir.mktmpdir do |dir|
    sig  = File.join(dir, 'signals.json')
    mmap = File.join(dir, 'master-map.json')
    out  = File.join(dir, 'wb-spec.json')
    File.write(sig,  JSON.generate(signals))
    File.write(mmap, JSON.generate(MASTER_MAP))
    _o, _e, st = Open3.capture3('ruby', BUILDER, '--signals', sig, '--master-map', mmap,
                                '--data-model', DM_ID, '--out', out, '--name', 'Trellis Test')
    unless st.success? && File.exist?(out)
      warn "builder failed:\n#{_e}"
      return [nil, nil]
    end
    spec = JSON.parse(File.read(out))
    sidecar_path = File.join(dir, 'native-trellis-emitted.json')
    sidecar = File.exist?(sidecar_path) ? JSON.parse(File.read(sidecar_path)) : nil
    [spec, sidecar]
  end
end

# Every content-page element (skip the Data page). Builder hashes visual ids into
# element ids, so tests match on the (unique) visual title instead.
def content_elements(spec)
  Array(spec.dig('document', 'elements'))
       .select { |e| e.is_a?(Hash) && e['visibleAsSource'] != false }
end

def el_name(el)
  n = el['name']
  n.is_a?(Hash) ? n['text'].to_s : n.to_s
end

def find_el(spec, needle)
  content_elements(spec).find { |e| el_name(e).include?(needle) }
end

def facet_col(el)
  Array(el['columns']).find { |c| c['name'].to_s.casecmp?('Region') }
end

# =============================================================================
# CASE A — a mixed page: bar+SM, bar (no SM), pie+SM, kpi+SM.
# =============================================================================
signals = {
  'source' => 'pbir', 'theme' => nil,
  'pages' => [{
    'page_id' => 'p1', 'page_title' => 'Trellis', 'page_w' => 1280, 'page_h' => 720,
    'visuals' => [
      visual('v-bar-sm', 'clusteredColumnChart', 'bar',
             { 'Category' => ['ORDER_FACT.Order Channel'], 'Y' => ['ORDER_FACT.Total Net Revenue'],
               'SmallMultiples' => ['ORDER_FACT.Region'] }, 'Revenue by Channel (small multiples)'),
      visual('v-bar-plain', 'clusteredColumnChart', 'bar',
             { 'Category' => ['ORDER_FACT.Order Channel'], 'Y' => ['ORDER_FACT.Total Net Revenue'] },
             'Revenue by Channel'),
      visual('v-pie-sm', 'pieChart', 'pie',
             { 'Category' => ['ORDER_FACT.Order Channel'], 'Values' => ['ORDER_FACT.Total Net Revenue'],
               'SmallMultiples' => ['ORDER_FACT.Region'] }, 'Revenue share (small multiples)'),
      visual('v-kpi-sm', 'card', 'kpi',
             { 'Values' => ['ORDER_FACT.Total Net Revenue'], 'SmallMultiples' => ['ORDER_FACT.Region'] },
             'Total Revenue')
    ],
    'interactions' => []
  }]
}

spec, sidecar = build(signals)
ok('CASE A: builder produced a spec', !spec.nil?)
if spec
  # 1. bar + SmallMultiples -> single bar-chart with trellis.columnsBy on the facet.
  bar = find_el(spec, 'Revenue by Channel (small multiples)')
  ok('bar+SM element exists and stayed a bar-chart', bar && bar['kind'] == 'bar-chart')
  fc = bar && facet_col(bar)
  ok('bar+SM: facet dimension added as a column', !fc.nil?)
  tr = bar && bar['trellis']
  ok('bar+SM: has trellis.columnsBy (single facet -> tile grid)',
     tr.is_a?(Hash) && tr.key?('columnsBy') && !tr.key?('rowsBy'))
  ok('bar+SM: trellis references the facet column id',
     fc && tr && tr['columnsBy'] == [{ 'columnId' => fc['id'] }])

  # 2. bar WITHOUT SmallMultiples -> no trellis (detection-gated). Exact-match the
  # title so the "(small multiples)" variant isn't picked up.
  plain = content_elements(spec).find { |e| el_name(e) == 'Revenue by Channel' }
  ok('bar (no SM) exists', !plain.nil?)
  ok('bar (no SM): NO trellis key', plain && !plain.key?('trellis'))
  ok('bar (no SM): NO Region facet column leaked', plain && facet_col(plain).nil?)

  # 3. pie + SmallMultiples -> donut-chart + trellis (pie->donut fallback).
  pie = find_el(spec, 'Revenue share (small multiples)')
  ok('pie+SM: flipped to donut-chart', pie && pie['kind'] == 'donut-chart')
  ok('pie+SM: has trellis.columnsBy', pie && pie['trellis'].is_a?(Hash) && pie['trellis'].key?('columnsBy'))

  # 4. kpi + SmallMultiples -> NO trellis (Sigma strips it on a kpi-chart). A
  # single-value card names itself after its measure leaf ("Total Net Revenue").
  kpi = find_el(spec, 'Total Net Revenue')
  ok('kpi+SM: exists as kpi-chart', kpi && kpi['kind'] == 'kpi-chart')
  ok('kpi+SM: NO trellis emitted (would be silently stripped)', kpi && !kpi.key?('trellis'))

  # 5. round-trip sidecar lists exactly the two trellised elements (bar + donut).
  ok('sidecar written', !sidecar.nil?)
  if sidecar && bar && pie
    recs = Array(sidecar['elements'])
    ids  = recs.map { |r| r['element_id'] }.sort
    ok('sidecar lists exactly the bar + donut trellis element ids',
       ids == [bar['id'], pie['id']].sort)
    ok('sidecar records the correct kinds (bar-chart + donut-chart)',
       recs.map { |r| r['kind'] }.sort == %w[bar-chart donut-chart])
    ok('sidecar records the columnsBy axis',
       recs.all? { |r| r['axis'] == 'columnsBy' })
    ok('sidecar records the facet columnId',
       recs.all? { |r| r['columnId'].to_s.end_with?('-sm') })
  end
end

# =============================================================================
# CASE B — no small-multiples anywhere: no sidecar, no trellis (byte-shape guard).
# =============================================================================
plain_signals = {
  'source' => 'pbir', 'theme' => nil,
  'pages' => [{
    'page_id' => 'p1', 'page_title' => 'Plain', 'page_w' => 1280, 'page_h' => 720,
    'visuals' => [
      visual('v1', 'clusteredColumnChart', 'bar',
             { 'Category' => ['ORDER_FACT.Order Channel'], 'Y' => ['ORDER_FACT.Total Net Revenue'] },
             'Revenue by Channel'),
      visual('v2', 'card', 'kpi', { 'Values' => ['ORDER_FACT.Total Net Revenue'] }, 'Total Revenue')
    ],
    'interactions' => []
  }]
}
spec_b, sidecar_b = build(plain_signals)
ok('CASE B: builder produced a spec', !spec_b.nil?)
if spec_b
  any_trellis = content_elements(spec_b).any? { |e| e.key?('trellis') }
  ok('CASE B: NO element carries a trellis key', !any_trellis)
  ok('CASE B: NO round-trip sidecar written (nothing trellised)', sidecar_b.nil?)
end

puts $fail.zero? ? "\nall pbi-trellis tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
