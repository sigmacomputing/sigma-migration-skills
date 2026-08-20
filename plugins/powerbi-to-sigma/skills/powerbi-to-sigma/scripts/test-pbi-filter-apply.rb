#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-filter-apply.rb — integration test for Track 3b filter APPLICATION in
# build-workbook-from-pbir.rb ([bead]). Complements test-pbi-filters.py
# (which tests EXTRACTION). Offline: no API, no creds — runs the real builder on a
# hand-built signals.json + master-map.json and asserts the emitted Sigma
# workbook-spec.json filters[] and coverage.json.
#
# Pins the VERIFIED element-filter shapes (live PUT+GET round-trip 2026-07-17,
# memory reference_sigma_element_filter_shapes) AND the adversarial-review fixes:
#   - number-range uses MIN/MAX (not the control's low/high)
#   - top-n ranks BY the rankBy measure column, not the limited dimension
#   - Bottom-N (direction:asc) -> coverage, never shipped as a Top-N
#   - non-numeric number-range (date/text) -> coverage, not a "no-op"
#   - empty include-list -> skipped (never blanks the element)
#   - page/report filters resolve via field_spec to the AUTHORITATIVE master(s) —
#     never leak onto an unrelated same-column-NAME master
#
# Run: ruby scripts/test-pbi-filter-apply.rb
require 'json'
require 'tmpdir'

HERE = File.dirname(File.expand_path(__FILE__))
BUILDER = File.join(HERE, 'build-workbook-from-pbir.rb')

$fail = 0
def ok(name, cond, got = nil)
  puts((cond ? "  ok  " : "FAIL  ") + name + (cond ? '' : "   got=#{got.inspect}"))
  $fail += 1 unless cond
end

SIGNALS = {
  'source' => 'pbir', 'theme' => nil,
  # report number-range on Amount -> master-t only (field_spec-scoped), min/max
  'filters' => [
    { 'scope' => 'report', 'target' => 'T.Amount', 'type' => 'number-range',
      'condition' => [{ 'op' => '>=', 'value' => '100' }, { 'op' => '<=', 'value' => '500' }], 'mode' => 'include' }
  ],
  'pages' => [{
    'page_id' => 'p1', 'page_title' => 'Page 1', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [],
    'filters' => [
      # page list on Region -> master-t ONLY (master-z also has a "Region" column but is a different entity)
      { 'scope' => 'page', 'target' => 'T.Region', 'type' => 'list', 'mode' => 'include', 'values' => %w[West East] },
      # date-range -> coverage
      { 'scope' => 'page', 'target' => 'T.OrderDate', 'type' => 'date-range',
        'window' => { 'anchor' => 'last', 'n' => 30, 'unit' => 'day', 'includeToday' => true }, 'mode' => 'include' },
      # non-numeric "number-range" (absolute-date comparison the extractor tags number-range) -> coverage, NOT no-op
      { 'scope' => 'page', 'target' => 'T.OrderDate', 'type' => 'number-range',
        'condition' => [{ 'op' => '>=', 'value' => '2023-01-01' }], 'mode' => 'include' }
    ],
    'visuals' => [
      { 'visual_id' => 'v1', 'visual_type' => 'barChart', 'sigma_kind' => 'bar', 'title' => 'Amount by Region',
        'x' => 0, 'y' => 0, 'w' => 600, 'h' => 300, 'bindings' => { 'Category' => ['T.Region'], 'Y' => ['T.Amount'] },
        'filters' => [
          # top-N (desc): rank the Region dimension BY the Amount measure -> columnId must be the Amount col
          { 'scope' => 'visual', 'target' => 'T.Region', 'type' => 'top-n', 'n' => 5, 'direction' => 'desc', 'rankBy' => 'T.Amount', 'mode' => 'include' },
          # bottom-N (asc): must NOT ship as a Top-N -> coverage
          { 'scope' => 'visual', 'target' => 'T.Region', 'type' => 'top-n', 'n' => 3, 'direction' => 'asc', 'rankBy' => 'T.Amount', 'mode' => 'include' },
          # list exclude on the projected dim -> applied
          { 'scope' => 'visual', 'target' => 'T.Region', 'type' => 'list', 'mode' => 'exclude', 'values' => ['Other'] },
          # empty include-list -> skipped (never blanks)
          { 'scope' => 'visual', 'target' => 'T.Region', 'type' => 'list', 'mode' => 'include', 'values' => [] },
          # measure/HAVING -> coverage
          { 'scope' => 'visual', 'target' => 'T.Cost', 'type' => 'measure-filter',
            'condition' => [{ 'op' => '>', 'value' => '30' }], 'unsupported' => 'post-aggregate', 'mode' => 'include' },
          # non-projected column -> coverage
          { 'scope' => 'visual', 'target' => 'T.Segment', 'type' => 'list', 'mode' => 'include', 'values' => ['SMB'] }
        ] },
      { 'visual_id' => 'v2', 'visual_type' => 'pivotTable', 'sigma_kind' => 'pivot-table', 'title' => 'Pivot',
        'x' => 0, 'y' => 320, 'w' => 600, 'h' => 300, 'bindings' => { 'Rows' => ['T.Region'], 'Values' => ['T.Amount'] },
        'filters' => [
          { 'scope' => 'visual', 'target' => 'T.Region', 'type' => 'list', 'mode' => 'include', 'values' => ['West'] }
        ] }
    ]
  }]
}

MMAP = {
  'masters' => {
    'T' => { 'id' => 'master-t', 'element_id' => 'dm-el-1', 'data_model' => 'dm-1',
             'columns' => [
               { 'id' => 'mt-region', 'name' => 'Region', 'formula' => '[T/Region]' },
               { 'id' => 'mt-amount', 'name' => 'Amount', 'formula' => '[T/Amount]' },
               { 'id' => 'mt-cost',   'name' => 'Cost',   'formula' => '[T/Cost]' },
               { 'id' => 'mt-date',   'name' => 'OrderDate', 'formula' => '[T/OrderDate]' }
             ] },
    # A DIFFERENT entity that also has a "Region" column — a report/page Region
    # filter must NOT leak onto it (field_spec scopes to T, not a name match).
    'Z' => { 'id' => 'master-z', 'element_id' => 'dm-el-2', 'data_model' => 'dm-1',
             'columns' => [
               { 'id' => 'mz-region', 'name' => 'Region', 'formula' => '[Z/Region]' },
               { 'id' => 'mz-val',    'name' => 'Zval',   'formula' => '[Z/Zval]' }
             ] }
  },
  'fields' => {
    'T.Region'    => { 'master' => 'T', 'ref' => '[T/Region]', 'agg' => nil },
    'T.Amount'    => { 'master' => 'T', 'ref' => '[T/Amount]', 'agg' => 'Sum' },
    'T.Cost'      => { 'master' => 'T', 'ref' => '[T/Cost]', 'agg' => 'Sum' },
    'T.OrderDate' => { 'master' => 'T', 'ref' => '[T/OrderDate]', 'agg' => nil },
    'Z.Region'    => { 'master' => 'Z', 'ref' => '[Z/Region]', 'agg' => nil },
    'Z.Zval'      => { 'master' => 'Z', 'ref' => '[Z/Zval]', 'agg' => 'Sum' }
    # NB: T.Segment intentionally absent -> non-projected on the bar
  }
}

Dir.mktmpdir('pbi-filter-apply') do |dir|
  sig = File.join(dir, 'signals.json'); File.write(sig, JSON.generate(SIGNALS))
  mm  = File.join(dir, 'master-map.json'); File.write(mm, JSON.generate(MMAP))
  out = File.join(dir, 'wb.json'); lay = File.join(dir, 'lay.xml')
  cmd = ['ruby', BUILDER, '--signals', sig, '--master-map', mm, '--data-model', 'dm-1',
         '--out', out, '--layout-out', lay, '--name', 'Filter Apply Test']
  system(*cmd, out: File::NULL, err: File::NULL) || (abort "builder failed to run: #{cmd.join(' ')}")
  spec = JSON.parse(File.read(out))
  cov  = JSON.parse(File.read(File.join(dir, 'coverage.json')))

  els = spec.dig('document', 'elements')
  bar = els.find { |e| e['kind'] == 'bar-chart' }
  piv = els.find { |e| e['kind'] == 'pivot-table' }
  master_t = els.find { |e| e['id'] == 'master-t' }
  master_z = els.find { |e| e['id'] == 'master-z' }
  bf = bar['filters'] || []
  mtf = master_t['filters'] || []

  # --- visual filters on the bar ------------------------------------------
  vlist = bf.find { |f| f['kind'] == 'list' }
  ok('bar: visual list filter applied (exclude Other)',
     vlist && vlist['mode'] == 'exclude' && vlist['values'] == ['Other'], bf)
  ok('bar: list filter columnId targets the projected dim (Region)',
     vlist && (bar['columns'] || []).any? { |c| c['id'] == vlist['columnId'] && c['name'] == 'Region' }, bf)
  vtopn = bf.find { |f| f['kind'] == 'top-n' }
  amount_cid = (bar['columns'] || []).find { |c| c['name'] == 'Amount' }&.fetch('id', nil)
  region_cid = (bar['columns'] || []).find { |c| c['name'] == 'Region' }&.fetch('id', nil)
  ok('bar: top-n applied (rowCount 5, rank, mode top-n)',
     vtopn && vtopn['rowCount'] == 5 && vtopn['rankingFunction'] == 'rank' && vtopn['mode'] == 'top-n', bf)
  ok('bar: top-n ranks BY the Amount measure column, NOT the Region dim (review fix #1)',
     vtopn && vtopn['columnId'] == amount_cid && vtopn['columnId'] != region_cid, [vtopn, amount_cid, region_cid])
  ok('bar: exactly 2 applicable visual filters (bottom-n/empty/measure/non-projected -> coverage)',
     bf.length == 2, bf)
  ok('every emitted filter has an id', (bf + mtf).all? { |f| f['id'].is_a?(String) && !f['id'].empty? }, bf + mtf)

  # --- page/report filters on the master, field_spec-scoped ----------------
  mlist = mtf.find { |f| f['kind'] == 'list' }
  ok('master-t: page list filter applied (include West/East on Region)',
     mlist && mlist['mode'] == 'include' && mlist['values'] == %w[West East] && mlist['columnId'] == 'mt-region', mtf)
  mnr = mtf.find { |f| f['kind'] == 'number-range' }
  ok('master-t: report number-range uses min/max (NOT low/high) on Amount',
     mnr && mnr['min'] == 100 && mnr['max'] == 500 && mnr['columnId'] == 'mt-amount' && !mnr.key?('low') && !mnr.key?('high'), mtf)
  ok('master-t: exactly 2 applicable source filters (date-range + nonnumeric -> coverage)',
     mtf.length == 2, mtf)
  ok('master-z: NO filter leaked (Region name-collision scoped out by field_spec — review fix #3/#5)',
     (master_z['filters'] || []).empty?, master_z['filters'])

  # --- pivot + transient key hygiene --------------------------------------
  ok('pivot: NO element filters emitted (Sigma drops them)', (piv['filters'] || []).empty?, piv['filters'])
  ok('no _-prefixed transient keys leak into the spec',
     els.none? { |e| e.keys.any? { |k| k.to_s.start_with?('_') } }, els.flat_map(&:keys).uniq)

  # --- coverage routing ----------------------------------------------------
  u = cov['unresolved'] || []
  fcov = u.select { |x| x['pbi_type'].to_s.start_with?('filter:') }
  det = ->(re) { fcov.any? { |x| x['detail'] =~ re } }
  ok('coverage: date-range routed (recoverable, window in action)',
     fcov.any? { |x| x['pbi_type'] == 'filter:date-range' && x['recoverable'] == true && x['action'].to_s =~ /last 30 day/ }, fcov)
  ok('coverage: measure-filter routed',            fcov.any? { |x| x['pbi_type'] == 'filter:measure-filter' })
  ok('coverage: non-projected visual list routed', det.call(/does not project/))
  ok('coverage: pivot element filter routed',      det.call(/pivot-table is silently dropped/))
  ok('coverage: Bottom-N routed (NOT shipped as Top-N) — review fix #1', det.call(/Bottom-N/))
  ok('coverage: non-numeric number-range routed (NOT a no-op) — review fix #2', det.call(/non-numeric/))
  ok('coverage: empty include-list skipped (empty slot) — review fix #6',
     fcov.any? { |x| x['pbi_type'] == 'filter:list' && x['detail'] =~ /empty filter slot/ }, fcov)
  ok('coverage: every filter entry names its target', fcov.all? { |x| x['detail'] =~ /target/ }, fcov)
end

puts($fail.zero? ? "\nall pbi-filter-apply tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
