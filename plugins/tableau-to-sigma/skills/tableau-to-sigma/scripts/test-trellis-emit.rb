#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-trellis-emit.rb — unit test for TrellisEmit (the shared native-trellis
# emitter). Converter-agnostic, pure, no network. Canonical in shared/scripts;
# edit there, run tools/sync-shared.rb.
# Run: ruby scripts/test-trellis-emit.rb
require_relative 'lib/trellis_emit'

$fail = 0
def ok(name, cond); puts((cond ? '  ok  ' : 'FAIL  ') + name); $fail += 1 unless cond; end

def el(kind, cols = [{ 'id' => 'c-cat' }])
  { 'id' => 'el-1', 'kind' => kind, 'columns' => cols }
end

# ---- supported kinds → trellis set, right axis per orientation --------------
%w[bar-chart line-chart area-chart combo-chart scatter-chart donut-chart].each do |k|
  e = el(k)
  r = TrellisEmit.apply(e, facet_column_id: 'c-cat', orientation: :rows)
  ok("#{k}: rows → :trellised + trellis.rowsBy", r == :trellised &&
     e['trellis'] == { 'rowsBy' => [{ 'columnId' => 'c-cat' }] })

  e2 = el(k)
  r2 = TrellisEmit.apply(e2, facet_column_id: 'c-cat', orientation: :cols)
  ok("#{k}: cols → trellis.columnsBy (and NOT rowsBy)", r2 == :trellised &&
     e2['trellis'] == { 'columnsBy' => [{ 'columnId' => 'c-cat' }] })
end

# String orientation is accepted the same as the symbol.
e = el('bar-chart')
TrellisEmit.apply(e, facet_column_id: 'c-cat', orientation: 'rows')
ok('orientation may be a String', e['trellis'] == { 'rowsBy' => [{ 'columnId' => 'c-cat' }] })

# ---- pie-chart → donut + trellis (fallback) ---------------------------------
e = el('pie-chart')
r = TrellisEmit.apply(e, facet_column_id: 'c-cat', orientation: :cols)
ok('pie-chart → :fallback_donut', r == :fallback_donut)
ok('pie-chart kind flipped to donut-chart', e['kind'] == 'donut-chart')
ok('pie→donut carries the native trellis', e['trellis'] == { 'columnsBy' => [{ 'columnId' => 'c-cat' }] })
ok('pie-chart trellises? is true (converts)', TrellisEmit.trellises?('pie-chart'))

# ---- kpi-chart → needs-sibling signal, element untouched --------------------
e = el('kpi-chart')
r = TrellisEmit.apply(e, facet_column_id: 'c-cat', orientation: :cols)
ok('kpi-chart → :needs_sibling_fanout', r == :needs_sibling_fanout)
ok('kpi-chart left UNTOUCHED (no trellis, kind unchanged)',
   !e.key?('trellis') && e['kind'] == 'kpi-chart')
ok('kpi-chart trellises? is false', !TrellisEmit.trellises?('kpi-chart'))

# ---- pivot-table → needs-shelves signal, untouched --------------------------
e = el('pivot-table')
r = TrellisEmit.apply(e, facet_column_id: 'c-cat', orientation: :rows)
ok('pivot-table → :needs_pivot_shelves', r == :needs_pivot_shelves)
ok('pivot-table left UNTOUCHED', !e.key?('trellis') && e['kind'] == 'pivot-table')

# ---- table → flat no-op -----------------------------------------------------
e = el('table')
r = TrellisEmit.apply(e, facet_column_id: 'c-cat', orientation: :cols)
ok('table → :flat', r == :flat)
ok('table left UNTOUCHED', !e.key?('trellis'))

# ---- unknown kind → flat (default fallback) ---------------------------------
e = el('funnel-chart')
ok('unknown kind → :flat disposition', TrellisEmit.disposition('funnel-chart') == :flat)
r = TrellisEmit.apply(e, facet_column_id: 'c-cat', orientation: :cols)
ok('unknown kind → :flat + untouched', r == :flat && !e.key?('trellis'))

# ---- 2-D grid → BOTH keys, two different columns ----------------------------
e = el('bar-chart', [{ 'id' => 'c-row' }, { 'id' => 'c-col' }])
r = TrellisEmit.apply(e, facet_column_id: %w[c-row c-col], orientation: :grid)
ok('grid + two facet ids → :trellised', r == :trellised)
ok('grid → rowsBy AND columnsBy on the two distinct columns',
   e['trellis'] == { 'rowsBy' => [{ 'columnId' => 'c-row' }],
                     'columnsBy' => [{ 'columnId' => 'c-col' }] })

# A single-field grid wraps into a tile grid → columnsBy only (tableau parity).
e = el('bar-chart')
TrellisEmit.apply(e, facet_column_id: 'c-cat', orientation: :grid)
ok('grid + single facet id → columnsBy only (single-field tile grid)',
   e['trellis'] == { 'columnsBy' => [{ 'columnId' => 'c-cat' }] })

# ---- disposition is the single source of truth (non-mutating) ---------------
ok('disposition(bar-chart) == :trellised', TrellisEmit.disposition('bar-chart') == :trellised)
ok('disposition(pie-chart) == :fallback_donut', TrellisEmit.disposition('pie-chart') == :fallback_donut)
ok('disposition(kpi-chart) == :needs_sibling_fanout',
   TrellisEmit.disposition('kpi-chart') == :needs_sibling_fanout)
ok('disposition(pivot-table) == :needs_pivot_shelves',
   TrellisEmit.disposition('pivot-table') == :needs_pivot_shelves)
ok('disposition(table) == :flat', TrellisEmit.disposition('table') == :flat)
ok('SUPPORTED_KINDS is the documented readback-safe set',
   TrellisEmit::SUPPORTED_KINDS == %w[bar-chart line-chart area-chart combo-chart scatter-chart donut-chart])

puts
if $fail.zero?
  puts 'ALL PASS — TrellisEmit (supported→trellis by orientation; pie→donut; ' \
       'kpi/pivot/table fallbacks; 2-D grid → both keys)'
  exit 0
else
  puts "#{$fail} FAILURE(S)"
  exit 1
end
