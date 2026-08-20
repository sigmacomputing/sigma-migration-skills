#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-trellis.rb — end-to-end regression for the QuickSight "Small multiples"
# (SmallMultiplesOptions + SmallMultiples field well) -> Sigma native `trellis`
# wiring in build-workbook-from-quicksight.rb (shared TrellisEmit). Offline: no
# API, no creds. Runs the REAL builder as a subprocess against a synthetic
# analysis + dm-readback and asserts on the emitted workbook spec + the
# native-trellis-emitted.json round-trip sidecar.
#
# Covers:
#   1. bar visual + SmallMultiples (MaxVisibleColumns) -> ONE bar-chart carrying
#      trellis.columnsBy referencing the facet column (single facet -> tile grid);
#      the facet dimension is added as a real column.
#   2. bar visual + SmallMultiples (MaxVisibleRows) -> trellis.rowsBy (orientation
#      mapped from Max rows/cols).
#   3. bar visual + SmallMultiples (MaxVisibleRows AND MaxVisibleColumns) -> :grid,
#      which a single facet degrades to columnsBy (a true 2-D grid needs two facet
#      columns; QuickSight small multiples is one dimension).
#   4. bar visual WITHOUT SmallMultiples -> NO trellis key (detection-gated).
#   5. pie visual + SmallMultiples -> flipped to donut-chart + trellis (pie silently
#      strips the key on readback; donut supports it).
#   6. kpi visual + SmallMultiples -> NO trellis (Sigma strips it on a kpi-chart);
#      recorded as a degraded fallback, not silently emitted.
#   7. the round-trip sidecar lists exactly the trellised elements (bars + donut).
#   8. an analysis with NO small-multiples visual writes NO sidecar and emits NO
#      trellis anywhere (byte-shape guarantee — detection-gated).
#
# Run: ruby scripts/test-qs-trellis.rb
require 'json'
require 'tmpdir'
require 'rbconfig'

HERE    = __dir__
BUILDER = File.join(HERE, 'build-workbook-from-quicksight.rb')
RUBY    = RbConfig.ruby

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# One readback DM element ("Orders") covering every charted column: the Order
# Channel dim, the Region small-multiples facet, and the Net Revenue measure.
def readback
  { 'dataModelId' => 'dm-1', 'pages' => [{ 'elements' => [
    { 'id' => 'el-1', 'name' => 'Orders', 'columns' => [
      { 'name' => 'Order Channel' }, { 'name' => 'Net Revenue' }, { 'name' => 'Region' }
    ] }
  ] }] }
end

# ---- QuickSight field-well builders -----------------------------------------
def dim(fid, col);  { 'CategoricalDimensionField' => { 'FieldId' => fid, 'Column' => { 'ColumnName' => col } } }; end
def meas(fid, col); { 'NumericalMeasureField' => { 'FieldId' => fid, 'Column' => { 'ColumnName' => col },
                                                   'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }; end

# A bar visual, optionally with a SmallMultiples facet + SmallMultiplesOptions.
def bar_visual(id, title, small_multiples: nil, sm_opts: nil)
  wells = { 'Category' => [dim('d1', 'ORDER_CHANNEL')], 'Values' => [meas('f1', 'NET_REVENUE')] }
  wells['SmallMultiples'] = [dim('sm1', small_multiples)] if small_multiples
  cfg = { 'FieldWells' => { 'BarChartAggregatedFieldWells' => wells } }
  cfg['SmallMultiplesOptions'] = sm_opts if sm_opts
  { 'BarChartVisual' => { 'VisualId' => id, 'Title' => { 'FormatText' => { 'PlainText' => title } },
                          'ChartConfiguration' => cfg } }
end

def pie_visual(id, title, small_multiples: nil, sm_opts: nil)
  wells = { 'Category' => [dim('d1', 'ORDER_CHANNEL')], 'Values' => [meas('f1', 'NET_REVENUE')] }
  wells['SmallMultiples'] = [dim('sm1', small_multiples)] if small_multiples
  cfg = { 'FieldWells' => { 'PieChartAggregatedFieldWells' => wells } }
  cfg['SmallMultiplesOptions'] = sm_opts if sm_opts
  { 'PieChartVisual' => { 'VisualId' => id, 'Title' => { 'FormatText' => { 'PlainText' => title } },
                          'ChartConfiguration' => cfg } }
end

def kpi_visual(id, title, small_multiples: nil)
  wells = { 'Values' => [meas('f1', 'NET_REVENUE')] }
  wells['SmallMultiples'] = [dim('sm1', small_multiples)] if small_multiples
  { 'KPIVisual' => { 'VisualId' => id, 'Title' => { 'FormatText' => { 'PlainText' => title } },
                     'ChartConfiguration' => { 'FieldWells' => wells } } }
end

def analysis(visuals)
  { 'Name' => 'Trellis Test',
    'Definition' => { 'Sheets' => [{ 'SheetId' => 's1', 'Name' => 'S1', 'Visuals' => visuals }] } }
end

# Run the real builder; return [spec, sidecar_or_nil, warnings, stderr].
def build(an)
  Dir.mktmpdir do |d|
    anp = File.join(d, 'an.json'); rbp = File.join(d, 'rb.json'); out = File.join(d, 'wb.json')
    File.write(anp, JSON.generate(an))
    File.write(rbp, JSON.generate(readback))
    stderr_r, stderr_w = IO.pipe
    pid = spawn(RUBY, BUILDER, '--analysis', anp, '--dm-readback', rbp, '--out', out,
                out: File::NULL, err: stderr_w)
    Process.wait(pid); status = $?.exitstatus
    stderr_w.close; err = stderr_r.read; stderr_r.close
    unless status.zero? && File.exist?(out)
      warn "builder failed (#{status}):\n#{err}"
      return [nil, nil, [], err]
    end
    spec = JSON.parse(File.read(out))
    scp = File.join(d, 'native-trellis-emitted.json')
    sidecar = File.exist?(scp) ? JSON.parse(File.read(scp)) : nil
    warns = JSON.parse(File.read(out.sub(/\.json$/, '') + '.warnings.json'))['warnings']
    [spec, sidecar, warns, err]
  end
end

def content_elements(spec)
  Array(spec.dig('document', 'elements')).select { |element| element.is_a?(Hash) }
end

def find_el(spec, name)
  content_elements(spec).find { |e| e['name'].to_s == name }
end

def facet_col(el)
  Array(el['columns']).find { |c| c['name'].to_s.casecmp?('Region') }
end

# =============================================================================
# CASE A — a mixed sheet: bar+SM(cols), bar+SM(rows), bar+SM(grid), bar(no SM),
#          pie+SM, kpi+SM.
# =============================================================================
an = analysis([
  bar_visual('v-bar-cols', 'Rev by Channel cols', small_multiples: 'REGION', sm_opts: { 'MaxVisibleColumns' => 4 }),
  bar_visual('v-bar-rows', 'Rev by Channel rows', small_multiples: 'REGION', sm_opts: { 'MaxVisibleRows' => 3 }),
  bar_visual('v-bar-grid', 'Rev by Channel grid', small_multiples: 'REGION',
             sm_opts: { 'MaxVisibleRows' => 2, 'MaxVisibleColumns' => 2 }),
  bar_visual('v-bar-plain', 'Rev by Channel plain'),
  pie_visual('v-pie-sm', 'Rev share sm', small_multiples: 'REGION', sm_opts: { 'MaxVisibleColumns' => 3 }),
  kpi_visual('v-kpi-sm', 'Total Rev', small_multiples: 'REGION')
])

spec, sidecar, warns, err = build(an)
ok('CASE A: builder produced a spec', !spec.nil?)
if spec
  # 1. bar + SM(cols) -> bar-chart, trellis.columnsBy on the facet column.
  bcols = find_el(spec, 'Rev by Channel cols')
  ok('bar+SM(cols): stayed a bar-chart', bcols && bcols['kind'] == 'bar-chart')
  fc = bcols && facet_col(bcols)
  ok('bar+SM(cols): facet dimension added as a column', !fc.nil?)
  tr = bcols && bcols['trellis']
  ok('bar+SM(cols): trellis.columnsBy (single facet -> tile grid), NOT rowsBy',
     tr.is_a?(Hash) && tr.key?('columnsBy') && !tr.key?('rowsBy'))
  ok('bar+SM(cols): trellis references the facet column id',
     fc && tr && tr['columnsBy'] == [{ 'columnId' => fc['id'] }])
  ok('bar+SM(cols): facet column id is the stable -sm id', fc && fc['id'].to_s.end_with?('-sm'))

  # 2. bar + SM(rows) -> trellis.rowsBy (orientation from MaxVisibleRows).
  brows = find_el(spec, 'Rev by Channel rows')
  trr = brows && brows['trellis']
  ok('bar+SM(rows): trellis.rowsBy (MaxVisibleRows -> vertical), NOT columnsBy',
     trr.is_a?(Hash) && trr.key?('rowsBy') && !trr.key?('columnsBy'))

  # 3. bar + SM(grid): both Max rows/cols -> :grid, degrades to columnsBy for one facet.
  bgrid = find_el(spec, 'Rev by Channel grid')
  trg = bgrid && bgrid['trellis']
  ok('bar+SM(grid): single facet degrades :grid -> columnsBy only',
     trg.is_a?(Hash) && trg.key?('columnsBy') && !trg.key?('rowsBy'))

  # 4. bar WITHOUT SmallMultiples -> no trellis, no facet column (detection-gated).
  plain = find_el(spec, 'Rev by Channel plain')
  ok('bar (no SM): exists', !plain.nil?)
  ok('bar (no SM): NO trellis key', plain && !plain.key?('trellis'))
  ok('bar (no SM): NO Region facet column leaked', plain && facet_col(plain).nil?)

  # 5. pie + SM -> donut-chart + trellis (pie->donut fallback).
  pie = find_el(spec, 'Rev share sm')
  ok('pie+SM: flipped to donut-chart', pie && pie['kind'] == 'donut-chart')
  ok('pie+SM: has trellis.columnsBy', pie && pie['trellis'].is_a?(Hash) && pie['trellis'].key?('columnsBy'))
  ok('pie+SM: a pie->donut warning was recorded',
     warns.any? { |w| w['type'] == 'SmallMultiples' && w['reason'].include?('PIE -> Sigma DONUT') })

  # 6. kpi + SM -> NO trellis (Sigma strips it on a kpi-chart); degraded fallback warn.
  kpi = find_el(spec, 'Total Rev')
  ok('kpi+SM: exists as kpi-chart', kpi && kpi['kind'] == 'kpi-chart')
  ok('kpi+SM: NO trellis emitted (would be silently stripped)', kpi && !kpi.key?('trellis'))
  ok('kpi+SM: NO Region facet column leaked', kpi && facet_col(kpi).nil?)
  ok('kpi+SM: degraded-fallback warning recorded',
     warns.any? { |w| w['type'] == 'SmallMultiples' && w['reason'].include?('no native trellis for that kind') })

  # 7. round-trip sidecar lists exactly the four trellised elements (3 bars + 1 donut).
  ok('sidecar written', !sidecar.nil?)
  if sidecar && bcols && brows && bgrid && pie
    recs = Array(sidecar['elements'])
    ids  = recs.map { |r| r['element_id'] }.sort
    ok('sidecar lists exactly the 3 bar + 1 donut trellis element ids',
       ids == [bcols['id'], brows['id'], bgrid['id'], pie['id']].sort)
    ok('sidecar records the correct kinds (3 bar-chart + 1 donut-chart)',
       recs.map { |r| r['kind'] }.sort == %w[bar-chart bar-chart bar-chart donut-chart])
    ok('sidecar records the correct per-element axis (rows: rowsBy; cols/grid/donut: columnsBy)',
       recs.find { |r| r['element_id'] == brows['id'] }['axis'] == 'rowsBy' &&
       recs.select { |r| r['element_id'] != brows['id'] }.all? { |r| r['axis'] == 'columnsBy' })
    ok('sidecar records the facet columnId (-sm)',
       recs.all? { |r| r['columnId'].to_s.end_with?('-sm') })
    ok('sidecar carries version + visual_id', sidecar['version'] == 1 &&
       recs.all? { |r| !r['visual_id'].to_s.empty? })
  end
end

# =============================================================================
# CASE B — no small-multiples anywhere: no sidecar, no trellis (byte-shape guard).
# =============================================================================
an_b = analysis([
  bar_visual('v1', 'Rev by Channel plain'),
  kpi_visual('v2', 'Total Rev')
])
spec_b, sidecar_b, = build(an_b)
ok('CASE B: builder produced a spec', !spec_b.nil?)
if spec_b
  any_trellis = content_elements(spec_b).any? { |e| e.key?('trellis') }
  ok('CASE B: NO element carries a trellis key', !any_trellis)
  ok('CASE B: NO round-trip sidecar written (nothing trellised)', sidecar_b.nil?)
end

puts $fail.zero? ? "\nall qs-trellis tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
