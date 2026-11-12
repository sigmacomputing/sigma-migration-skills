#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-theme-fixes.rb — builder-level regressions for the report-theme / column-fill work.
# Runs build-workbook-from-pbir.rb offline (files only) on synthetic Orders names and asserts:
#   F1/F2  the "(report theme)" coverage gap is a non-gating decoration note
#   F3     matrix (pivot-table) visuals record qr_cids, so column fills build
#   F4     prune_columns! removes pruned ids from conditionalFormats[].columnIds
#   F7     a card callout colour given as a ThemeDataColor resolves through the palette
require 'json'
require 'tmpdir'
require 'rbconfig'

BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')
$fail = 0
def ok(name, cond); puts((cond ? '  ok  ' : 'FAIL  ') + name); $fail += 1 unless cond; end

MMAP = {
  'masters' => { 'Orders' => { 'id' => 'master-ord', 'element_id' => 'el-ord', 'data_model' => 'dm-x',
    'columns' => [{ 'id' => 'mc-region', 'name' => 'Region', 'formula' => '[Orders/Region]' },
                  { 'id' => 'mc-cat', 'name' => 'Category', 'formula' => '[Orders/Category]' },
                  { 'id' => 'mc-amt', 'name' => 'Amount', 'formula' => '[Orders/Amount]' }] } },
  'fields' => {
    'Orders.Region'   => { 'master' => 'Orders', 'ref' => '[master-ord/Region]', 'agg' => nil },
    'Orders.Category' => { 'master' => 'Orders', 'ref' => '[master-ord/Category]', 'agg' => nil },
    'Orders.Amount'   => { 'master' => 'Orders', 'ref' => 'Sum([master-ord/Amount])', 'agg' => nil }
  }
}.freeze

def vis(id, type, kind, bindings, extra = {})
  { 'visual_id' => id, 'visual_type' => type, 'sigma_kind' => kind, 'title' => "#{kind} #{id}",
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => bindings, 'sort' => nil, 'formats' => {} }.merge(extra)
end

def fill(target, back)
  { 'target' => target, 'back' => back, 'font' => nil, 'header' => false, 'values' => true,
    'subtotals' => false, 'total' => false }
end

def build(signals)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'mmap.json'), JSON.generate(MMAP))
    File.write(File.join(d, 'sig.json'), JSON.generate(signals))
    wb = File.join(d, 'wb.json'); cov = File.join(d, 'cov.json')
    st = system(RbConfig.ruby, BUILD, '--signals', File.join(d, 'sig.json'), '--master-map', File.join(d, 'mmap.json'),
                '--data-model', 'dm-x', '--name', 'T', '--out', wb, '--layout-out', File.join(d, 'l.xml'),
                '--coverage-out', cov, out: File::NULL, err: File::NULL)
    return [st, nil, nil] unless st
    [st, JSON.parse(File.read(wb)), JSON.parse(File.read(cov))]
  end
end

def sig(visuals, extra = {})
  { 'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
    'pages' => [{ 'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720,
                  'interactions' => [], 'visuals' => visuals }] }.merge(extra)
end

els = ->(spec) { spec.dig('document', 'elements').reject { |e| e['visibleAsSource'] == false } }

# --- F1 / F2: unknown named theme -> informational decoration gap ----------------
st, spec, cov = build(sig([vis('v_t', 'tableEx', 'table', { 'Values' => ['Orders.Region', 'Orders.Amount'] })],
                           'theme' => 'CY99SU99'))
ok('builder exits 0 (theme)', st)
gap = (cov['unresolved'] || []).find { |u| u['visual'] == '(report theme)' }
ok('unknown theme records a (report theme) gap', !gap.nil?)
ok('theme gap is approximated, NOT recoverable (must not block --coverage)',
   gap && gap['severity'] == 'approximated' && gap['recoverable'] == false)
ok('theme gap carries role_class decoration', gap && gap['role_class'] == 'decoration')

# --- F3: matrix column fills; F4: pruned column leaves no dangling rule ----------
matrix = vis('v_m', 'pivotTable', 'pivot-table',
             { 'Rows' => ['Orders.Region'], 'Columns' => ['Orders.Category'], 'Values' => ['Orders.Amount'] },
             'column_formats' => [fill('Orders.Amount', '#99E3DD')], 'show_totals' => false)
tbl = vis('v_g', 'tableEx', 'table',
          { 'Values' => ['Orders.Region', 'Orders.Amount', 'Orders.Ghost'] },
          'column_formats' => [fill('Orders.Amount', '#99E3DD'), fill('Orders.Ghost', '#112233')])
st, spec, cov = build(sig([matrix, tbl]))
ok('builder exits 0 (fills)', st)
m = els.call(spec).find { |e| e['kind'] == 'pivot-table' }
ok('matrix built as pivot-table', !m.nil?)
cfs = m && m['conditionalFormats']
amt = m && m['columns'].find { |c| c['name'] == 'Amount' }
ok('matrix column fill built (qr_cids recorded for pivot values)',
   cfs && amt && cfs.any? { |f| f['columnIds'] == [amt['id']] && f['style'] == { 'backgroundColor' => '#99E3DD' } })
t = els.call(spec).find { |e| e['kind'] == 'table' && e['name'].to_s.include?('v_g') }
ok('table kept its Amount fill', t && t['conditionalFormats'].to_a.any? { |f| f['style'] == { 'backgroundColor' => '#99E3DD' } })
col_ids = (t['columns'] || []).map { |c| c['id'] }
dangling = Array(t['conditionalFormats']).flat_map { |f| Array(f['columnIds']) }.reject { |i| col_ids.include?(i) }
ok('ghost column pruned from the table', t['columns'].none? { |c| c['name'] == 'Ghost' })
ok('no conditionalFormats rule points at a pruned column', dangling.empty?)
ok('rule for the pruned ghost column is gone',
   Array(t['conditionalFormats']).none? { |f| f['style'] == { 'backgroundColor' => '#112233' } })

# --- G1: a native matrix keeps HEAD behaviour outside column fills ----------------
# An unresolvable Rows field (entity not in the master map) is still dropped + reported, and the
# row formula is never Coalesce-wrapped by the pivot sort; fills still build.
gm = vis('v_gm', 'pivotTable', 'pivot-table',
         { 'Rows' => ['Ghost.Region'], 'Columns' => ['Orders.Category'], 'Values' => ['Orders.Amount'] },
         'sort' => { 'queryRef' => 'Ghost.Region', 'direction' => 'Ascending' },
         'column_formats' => [fill('Orders.Amount', '#99E3DD')], 'show_totals' => false)
st, spec, cov = build(sig([gm]))
ok('builder exits 0 (G1)', st)
gme = els.call(spec).find { |e| e['kind'] == 'pivot-table' }
ok('G1: pivot built', !gme.nil?)
ok('G1: unresolvable Rows field dropped from the matrix', gme && gme['columns'].none? { |c| c['name'] == 'Region' })
ok('G1: no row formula is Coalesce-wrapped', gme && gme['columns'].none? { |c| c['formula'].to_s.start_with?('Coalesce(') })
ok('G1: the drop is reported', (cov['unresolved'] || []).any? { |u| u['severity'] == 'dropped' && u['detail'].to_s =~ /Region/ })
gamt = gme && gme['columns'].find { |c| c['name'] == 'Amount' }
ok('G1: matrix fill still builds', gamt && Array(gme['conditionalFormats']).any? { |f| f['columnIds'] == [gamt['id']] })

# --- F7: card callout colour given as a ThemeDataColor ---------------------------
card_theme = vis('v_c1', 'card', 'kpi', { 'Values' => ['Orders.Amount'] },
                 'value_color' => { 'theme' => 2, 'percent' => 0 })
card_hex = vis('v_c2', 'card', 'kpi', { 'Values' => ['Orders.Amount'] }, 'value_color' => '#123456')
st, spec, = build(sig([card_theme, card_hex], 'theme_data_colors' => %w[#112233 #445566 #778899]))
ok('builder exits 0 (cards)', st)
colors = els.call(spec).select { |e| e['kind'] == 'kpi-chart' }.map { |e| e.dig('value', 'color') }
ok('ThemeDataColor id 2 resolves to palette[0]', colors.include?('#112233'))
ok('hex value_color passes through unchanged', colors.include?('#123456'))
ok('no card painted the default for an explicit theme colour', colors.none? { |c| c == '#333333' })

# --- multi-row card tiles get the card colour too -------------------------------------
mrc_theme = vis('v_m1', 'multiRowCard', 'kpi', { 'Values' => ['Orders.Amount', 'Orders.Region'] },
                'value_color' => { 'theme' => 3, 'percent' => 0 })
mrc_plain = vis('v_m2', 'multiRowCard', 'kpi', { 'Values' => ['Orders.Amount', 'Orders.Region'] })
st, spec, = build(sig([mrc_theme, mrc_plain], 'theme_data_colors' => %w[#112233 #445566 #778899]))
tiles = ->(s, vid) { els.call(s).select { |e| e['kind'] == 'kpi-chart' && e['id'] =~ /-k\d+\z/ && e['id'].include?(vid.sub('v_', '')) } }
all_tiles = els.call(spec).select { |e| e['kind'] == 'kpi-chart' && e['id'] =~ /-k\d+\z/ }
ok('multi-row card builds tiles', st && all_tiles.length == 4)
ok('multi-row tiles with an explicit ThemeDataColor callout get the resolved colour',
   all_tiles.count { |e| e.dig('value', 'color') == '#445566' } == 2)
ok('multi-row tiles with no callout on a non-classic theme stay unset (no accent)',
   all_tiles.count { |e| e.dig('value', 'color').nil? } == 2)
st, spec, = build(sig([mrc_plain], 'theme' => 'CY18SU07'))
ct = els.call(spec).select { |e| e['kind'] == 'kpi-chart' && e['id'] =~ /-k\d+\z/ }
ok('multi-row tiles on the classic theme get the classic card value colour',
   st && ct.length == 2 && ct.all? { |e| e.dig('value', 'color') == '#333333' })

puts($fail.zero? ? "\nall passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
