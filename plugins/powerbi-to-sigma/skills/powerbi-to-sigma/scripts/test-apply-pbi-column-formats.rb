#!/usr/bin/env ruby
# frozen_string_literal: true
# test-apply-pbi-column-formats.rb — theme palettes (CY18SU07 / theme dataColors / ThemeDataColor
# math), PbiConditionalFormats.column_fill_formats, and the post-build pass
# scripts/apply-pbi-column-formats.rb. Offline, synthetic names only.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'shellwords'
require_relative 'lib/ruby_compat'
require_relative 'lib/pbi_theme'
require_relative 'lib/pbi_conditional_formats'
require_relative 'lib/pbi_column_format_apply'
require_relative 'lib/polish_layout'

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

CLASSIC10 = %w[#01B8AA #374649 #FD625E #F2C80F #5F6B6D #8AD4EB #FE9666 #A66999 #3599B8 #DFBFBF].freeze

# --- 1. theme palettes ---------------------------------------------------------
ok('CY18SU07 is the classic 10-color sequence', PbiTheme.palette('CY18SU07') == CLASSIC10)
ok('known? true for CY18SU07 / classic / CY24SU10',
   %w[CY18SU07 classic CY24SU10].all? { |n| PbiTheme.known?(n) })
ok('known? false for an unknown name', !PbiTheme.known?('CY99SU99') && !PbiTheme.known?(nil))
ok('unknown name falls back to the 2024 palette', PbiTheme.palette('CY99SU99') == PbiTheme::FALLBACK)
own = %w[#112233 #aabbcc #445566]
ok('theme dataColors win over the name and are uppercased',
   PbiTheme.palette('CY18SU07', own) == %w[#112233 #AABBCC #445566])
ok('an empty / invalid dataColors list is ignored',
   PbiTheme.palette('CY18SU07', []) == CLASSIC10 && PbiTheme.palette('CY18SU07', %w[red]) == CLASSIC10)
ok('accent follows dataColors', PbiTheme.accent('CY18SU07', own) == '#112233')
ov = PbiTheme.overrides('CY18SU07', own)
ok('overrides carry the dataColors palette + highlight',
   ov['categoricalScheme'] == %w[#112233 #AABBCC #445566] && ov['colors']['highlight'] == '#112233')

ok('card_value_color: classic themes -> #333333',
   PbiTheme.card_value_color('CY18SU07') == '#333333' && PbiTheme.card_value_color('classic') == '#333333')
ok('card_value_color: 2024 themes keep the accent',
   PbiTheme.card_value_color('CY24SU10') == '#118DFF' && PbiTheme.card_value_color('CY23SU08') == '#118DFF' &&
   PbiTheme.card_value_color(nil) == '#118DFF')

# --- 2. ThemeDataColor math (values verified against rendered PBI) --------------
{ [0, -0.3] => '#B3B3B3', [1, 0.1] => '#1A1A1A', [2, 0.6] => '#99E3DD',
  [4, 0.2] => '#FD817E', [5, 0.6] => '#FAE99F', [9, 0.6] => '#DBC3D6' }.each do |(id, pct), want|
  got = PbiTheme.theme_color(id, pct, CLASSIC10)
  ok("theme_color(#{id}, #{pct}) = #{want} (got #{got})", got == want)
end
ok('theme_color percent 0 returns the base color', PbiTheme.theme_color(3, 0, CLASSIC10) == '#374649')
ok('theme_color out-of-range id -> nil', PbiTheme.theme_color(40, 0, CLASSIC10).nil?)

# --- 3. column_fill_formats ----------------------------------------------------
qr_cids = { 'Sales.Net Sales' => 'c1', 'Sales.Margin %' => 'c2', 'Sales.Units' => 'c3' }
cfs = [
  { 'target' => 'Sales.Net Sales', 'back' => '#99e3dd', 'font' => nil, 'header' => false, 'values' => true,
    'subtotals' => true, 'total' => false },
  { 'target' => 'Other.Margin %', 'back' => { 'theme' => 5, 'percent' => 0.6 }, 'font' => '#000000',
    'header' => false, 'values' => true, 'subtotals' => true, 'total' => false },
  { 'target' => 'Sales.Units', 'back' => '#112233', 'font' => nil, 'header' => true, 'values' => false,
    'subtotals' => true, 'total' => true },
  { 'target' => 'Sales.Gone', 'back' => '#112233', 'font' => nil, 'header' => false, 'values' => true,
    'subtotals' => true, 'total' => false },
  { 'target' => 'Sales.Net Sales', 'back' => nil, 'font' => nil, 'header' => false, 'values' => true,
    'subtotals' => true, 'total' => false }
]
res = PbiConditionalFormats.column_fill_formats(cfs, qr_cids, 'Matrix A', 'pivot-table', CLASSIC10)
ok('two value fills emitted (literal hex + leaf-matched theme color)', res['formats'].length == 2)
ok('literal fill -> single formula True backgroundColor uppercase',
   res['formats'][0] == { 'type' => 'single', 'columnIds' => ['c1'], 'condition' => 'formula',
                          'formula' => 'True', 'style' => { 'backgroundColor' => '#99E3DD' } })
ok('theme-color fill resolved through the palette, leaf match, font color carried',
   res['formats'][1]['columnIds'] == ['c2'] &&
   res['formats'][1]['style'] == { 'backgroundColor' => '#FAE99F', 'color' => '#000000' })
cov = res['coverage']
ok('header/total-only entry -> ONE approximated coverage entry listing the column',
   cov.count { |c| c[:detail] =~ /no per-column header or grand-total fill/ } == 1 &&
   cov.find { |c| c[:detail] =~ /no per-column header or grand-total fill/ }[:detail] =~ /Units.*#112233/m)
ok('value fills that also style subtotals get ONE "part not reproduced" note (subtotals count as chrome)',
   cov.count { |c| c[:detail] =~ /value cells filled/ } == 1 &&
   cov.find { |c| c[:detail] =~ /value cells filled/ }[:detail] =~ /subtotal/)
ok('unresolvable target -> degraded coverage',
   cov.any? { |c| c[:severity] == 'degraded' && c[:detail] =~ /Sales\.Gone/ })
ok('no-color entry emits nothing', res['formats'].none? { |f| f['style'].empty? })

# --- 4. post-build pass --------------------------------------------------------
vid = 'abc123def456'
eid = PolishLayout.element_id_for(vid)
mk_spec = lambda do
  { 'name' => 'T', 'document' => {
    'schemaVersion' => 1, 'kind' => 'workbook',
    'settings' => { 'theme' => { 'name' => 'Light', 'overrides' => {
      'hasCards' => 'shown', 'categoricalScheme' => PbiTheme::FALLBACK, 'colors' => { 'highlight' => '#118DFF' }
    } } },
    'elements' => [
      { 'id' => eid, 'kind' => 'pivot-table', 'name' => 'Matrix A',
        'columns' => [{ 'id' => "#{eid}-r0", 'name' => 'Region', 'formula' => '[T/Region]' },
                      { 'id' => "#{eid}-v0", 'name' => 'Net Sales', 'formula' => 'Sum([T/Sales])' },
                      { 'id' => "#{eid}-v1", 'name' => 'Margin Pct', 'formula' => 'Sum([T/M])' },
                      { 'id' => "#{eid}-v2", 'name' => 'Units', 'formula' => 'Sum([T/U])' }],
        'rowsBy' => [{ 'columnId' => "#{eid}-r0" }],
        'values' => ["#{eid}-v0", "#{eid}-v1", "#{eid}-v2"],
        'conditionalFormats' => [{ 'type' => 'dataBars', 'columnIds' => ["#{eid}-v0"], 'scheme' => ['#4caf7d'] }] },
      { 'id' => 'el-other', 'kind' => 'bar-chart', 'name' => 'Chart', 'columns' => [] }
    ] } }
end
signals = {
  'theme' => 'CY18SU07',
  'pages' => [{ 'visuals' => [
    { 'visual_id' => vid,
      'display_names' => { 'Orders.Margin %' => 'Margin Pct' },
      'column_formats' => [
        { 'target' => 'Orders.Net Sales', 'back' => { 'theme' => 5, 'percent' => 0.6 }, 'font' => nil,
          'header' => false, 'values' => true, 'subtotals' => true, 'total' => false },
        { 'target' => 'Orders.Margin %', 'back' => '#000000', 'font' => '#FFFFFF', 'header' => false,
          'values' => true, 'subtotals' => true, 'total' => false },
        { 'target' => 'Orders.Units', 'back' => '#99e3dd', 'font' => nil, 'header' => true, 'values' => false,
          'subtotals' => true, 'total' => false }
      ] },
    { 'visual_id' => 'no-match', 'column_formats' => [{ 'target' => 'X.Y', 'back' => '#111111', 'values' => true }] }
  ] }]
}
spec = mk_spec.call
sum = PbiColumnFormatApply.apply(spec, signals)
el = spec['document']['elements'][0]
cf = el['conditionalFormats']
ok('existing conditional format kept first', cf[0]['type'] == 'dataBars')
ok('fill added for the leaf-matched value column',
   cf.any? { |f| f['columnIds'] == ["#{eid}-v0"] && f['style'] == { 'backgroundColor' => '#FAE99F' } })
ok('display-name renamed column ("Margin Pct") resolved via display_names, with font color',
   cf.any? { |f| f['columnIds'] == ["#{eid}-v1"] && f['style'] == { 'backgroundColor' => '#000000', 'color' => '#FFFFFF' } })
ok('header-only column is not filled', cf.none? { |f| f['columnIds'] == ["#{eid}-v2"] })
ok('summary: 2 rules added, header-only + subtotal-part notes reported', sum['elements'].length == 1 &&
   sum['elements'][0]['added'] == 2 && sum['elements'][0]['coverage'].length == 2)
ov = spec['document']['settings']['theme']['overrides']
ok('theme palette rewritten to CY18SU07 + highlight',
   ov['categoricalScheme'] == CLASSIC10 && ov['colors']['highlight'] == '#01B8AA' && ov['hasCards'] == 'shown')
ok('non-table element untouched', spec['document']['elements'][1] == mk_spec.call['document']['elements'][1])

before = JSON.generate(spec)
sum2 = PbiColumnFormatApply.apply(spec, signals)
ok('idempotent: second run adds nothing and changes nothing',
   JSON.generate(spec) == before && sum2['elements'][0]['added'] == 0 &&
   sum2['elements'][0]['skipped_existing'] == 2 && !sum2['theme_changed'])

spec = mk_spec.call
PbiColumnFormatApply.apply(spec, signals.merge('theme_data_colors' => own), theme_only: true)
ok('--theme-only: palette from theme_data_colors, no fills added',
   spec['document']['settings']['theme']['overrides']['categoricalScheme'] == %w[#112233 #AABBCC #445566] &&
   spec['document']['elements'][0]['conditionalFormats'].length == 1)

flat = { 'schemaVersion' => 1, 'elements' => [] }
PbiColumnFormatApply.apply(flat, signals, theme_only: true)
ok('flat (non-document-wrapped) spec gets a theme block', flat['settings']['theme']['overrides']['categoricalScheme'] == CLASSIC10)

# --- 5. CLI --------------------------------------------------------------------
Dir.mktmpdir do |d|
  sp = File.join(d, 'wb.json')
  sg = File.join(d, 'signals.json')
  File.write(sp, JSON.generate(mk_spec.call))
  File.write(sg, JSON.generate(signals))
  script = File.join(__dir__, 'apply-pbi-column-formats.rb')
  cmd = "#{Shellwords.escape(RbConfig.ruby)} #{Shellwords.escape(script)} --spec #{Shellwords.escape(sp)} --signals #{Shellwords.escape(sg)} 2>&1"
  # Test harness: every interpolated value is shell-escaped (a fixed script and temp paths).
  # nosemgrep: ruby.lang.security.dangerous-subshell.dangerous-subshell
  out = `#{cmd}`
  ok('CLI exits 0 and prints the per-element summary',
     $?.success? && out =~ /Matrix A.*\+2 rule\(s\)/ && out =~ /skipped \(approximated\).*Units/)
  written = JSON.parse(File.read(sp))
  ok('CLI rewrote the spec in place with the fills', written['document']['elements'][0]['conditionalFormats'].length == 3)
  # Test harness: every interpolated value is shell-escaped (a fixed script and temp paths).
  # nosemgrep: ruby.lang.security.dangerous-subshell.dangerous-subshell
  out2 = `#{cmd}`
  ok('CLI re-run is a no-op', out2 =~ /\+0 rule\(s\), -0 stale, 2 already present/ && JSON.parse(File.read(sp)) == written)
  # Test harness: every interpolated value is shell-escaped (a fixed script and temp paths).
  # nosemgrep: ruby.lang.security.dangerous-subshell.dangerous-subshell
  out3 = `#{cmd.sub('2>&1', '--theme-only 2>&1')}`
  ok('CLI --theme-only prints no element lines', $?.success? && out3 !~ /rule\(s\), \d+ already/)
end

# A fill on values AND header/total: the value cells are filled and the lost header/total part is reported.
both = PbiConditionalFormats.column_fill_formats(
  [{ 'target' => 'T.Units', 'back' => '#99e3dd', 'header' => true, 'values' => true, 'total' => true }],
  { 'T.Units' => 'c-units' }, 'Matrix B', 'pivot-table', CLASSIC10
)
ok('values+header fill -> value rule emitted', both['formats'].length == 1 && both['formats'][0]['columnIds'] == ['c-units'])
ok('values+header fill -> header/total part reported as approximated',
   both['coverage'].length == 1 && both['coverage'][0][:detail] =~ /value cells filled, header\/total\/subtotal part.*Units/)

# KPI card values the builder colored with the previous palette's accent are re-colored to the
# theme's card value color; a value color Power BI set explicitly (signals value_color) is kept.
kpi_sig = { 'theme' => 'CY18SU07', 'pages' => [{ 'visuals' => [
  { 'visual_id' => 'cardvisual000000aa01', 'visual_type' => 'card' },
  { 'visual_id' => 'cardvisual000000aa02', 'visual_type' => 'card', 'value_color' => '#123456' }
] }] }
kid = ->(v) { PolishLayout.element_id_for(v) }
kpi_spec = { 'document' => {
  'settings' => { 'theme' => { 'name' => 'Light', 'overrides' => {
    'categoricalScheme' => PbiTheme::FALLBACK, 'colors' => { 'highlight' => PbiTheme::FALLBACK.first } } } },
  'elements' => [
    { 'id' => kid.call('cardvisual000000aa01'), 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'k1', 'color' => PbiTheme::FALLBACK.first } },
    { 'id' => kid.call('cardvisual000000aa02'), 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'k2', 'color' => '#123456' } },
    { 'id' => 'el-unmatched', 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'k3', 'color' => '#ABCDEF' } }
  ] } }
ksum = PbiColumnFormatApply.apply(kpi_spec, kpi_sig, theme_only: true)
kels = kpi_spec['document']['elements']
ok('KPI value in the old accent -> classic card value color #333333', kels[0]['value']['color'] == '#333333')
ok('KPI value with an explicit PBI color is kept', kels[1]['value']['color'] == '#123456')
ok('KPI not built from a signals card is untouched', kels[2]['value']['color'] == '#ABCDEF')
ok('summary counts the recolored KPI', ksum['kpis_recolored'] == 1)
PbiColumnFormatApply.apply(kpi_spec, kpi_sig, theme_only: true)
ok('KPI recolor is idempotent', kels[0]['value']['color'] == '#333333')

# F5: a source colour that was present but did not resolve (theme id past the palette, non-6-digit hex)
# is reported, not silently skipped; an entry with NO colours stays silent.
unres = PbiConditionalFormats.column_fill_formats(
  [{ 'target' => 'T.Units', 'back' => { 'theme' => 40, 'percent' => 0 }, 'values' => true },
   { 'target' => 'T.Net', 'back' => '#FFF', 'values' => true },
   { 'target' => 'T.None', 'back' => nil, 'font' => nil, 'values' => true }],
  { 'T.Units' => 'c1', 'T.Net' => 'c2', 'T.None' => 'c3' }, 'Matrix C', 'pivot-table', CLASSIC10
)
ok('unresolved colours emit no rule', unres['formats'].empty?)
ok('each unresolved-colour entry is reported (Units and Net), the colourless one is not',
   unres['coverage'].length == 2 && unres['coverage'].any? { |c| c[:detail] =~ /Units/ } &&
   unres['coverage'].any? { |c| c[:detail] =~ /Net/ } && unres['coverage'].none? { |c| c[:detail] =~ /None/ })
ok('unresolved-colour coverage is non-gating (approximated, not recoverable)',
   unres['coverage'].all? { |c| c[:severity] == 'approximated' && c[:recoverable] == false })

# F6: a fill that styles ONLY subtotals is reported (Sigma cannot fill subtotal rows per column).
sub_only = PbiConditionalFormats.column_fill_formats(
  [{ 'target' => 'T.Units', 'back' => '#99e3dd', 'values' => false, 'header' => false, 'total' => false, 'subtotals' => true }],
  { 'T.Units' => 'c1' }, 'Matrix D', 'pivot-table', CLASSIC10
)
ok('subtotals-only fill -> no rule, one coverage entry naming the column and subtotals',
   sub_only['formats'].empty? && sub_only['coverage'].length == 1 &&
   sub_only['coverage'][0][:detail] =~ /Units/ && sub_only['coverage'][0][:detail] =~ /subtotal/)
sub_vals = PbiConditionalFormats.column_fill_formats(
  [{ 'target' => 'T.Units', 'back' => '#99e3dd', 'values' => true, 'header' => false, 'total' => false, 'subtotals' => true }],
  { 'T.Units' => 'c1' }, 'Matrix E', 'pivot-table', CLASSIC10
)
ok('values+subtotals fill -> value rule plus a subtotal note',
   sub_vals['formats'].length == 1 && sub_vals['coverage'].length == 1 &&
   sub_vals['coverage'][0][:detail] =~ /subtotal/)

# F7: an explicit card colour given as a ThemeDataColor ({'theme','percent'}) is treated as SET and resolved
# through the palette; an unresolvable one falls back to unset (recolored).
tkpi_sig = { 'theme' => 'CY18SU07', 'pages' => [{ 'visuals' => [
  { 'visual_id' => 'cardvisual000000bb01', 'visual_type' => 'card', 'value_color' => { 'theme' => 5, 'percent' => 0.6 } },
  { 'visual_id' => 'cardvisual000000bb02', 'visual_type' => 'card', 'value_color' => { 'theme' => 99, 'percent' => 0 } }
] }] }
tkpi_spec = { 'document' => {
  'settings' => { 'theme' => { 'name' => 'Light', 'overrides' => {
    'categoricalScheme' => PbiTheme::FALLBACK, 'colors' => { 'highlight' => PbiTheme::FALLBACK.first } } } },
  'elements' => [
    { 'id' => kid.call('cardvisual000000bb01'), 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'k1', 'color' => PbiTheme::FALLBACK.first } },
    { 'id' => kid.call('cardvisual000000bb02'), 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'k2', 'color' => PbiTheme::FALLBACK.first } }
  ] } }
PbiColumnFormatApply.apply(tkpi_spec, tkpi_sig, theme_only: true)
tk = tkpi_spec['document']['elements']
ok('G4: KPI with an explicit ThemeDataColor callout is painted with the colour resolved on the current palette',
   tk[0]['value']['color'] == '#FAE99F')
ok('KPI whose ThemeDataColor cannot resolve falls back to the card default', tk[1]['value']['color'] == '#333333')
ok('resolve_color_signal: hex passes through, hash resolves, junk -> nil',
   PbiTheme.resolve_color_signal('#123456', CLASSIC10) == '#123456' &&
   PbiTheme.resolve_color_signal({ 'theme' => 5, 'percent' => 0.6 }, CLASSIC10) == '#FAE99F' &&
   PbiTheme.resolve_color_signal({ 'theme' => 99, 'percent' => 0 }, CLASSIC10).nil? &&
   PbiTheme.resolve_color_signal(nil, CLASSIC10).nil?)

# Multi-row card tiles (<eid>-k<i>) map back to their visual: explicit colours are painted, and on the classic
# theme an unset tile gets the classic card value colour; the accent is never applied to a tile.
mr_sig = { 'theme' => 'CY18SU07', 'pages' => [{ 'visuals' => [
  { 'visual_id' => 'multirowcard0000cc01', 'visual_type' => 'multiRowCard', 'value_color' => { 'theme' => 5, 'percent' => 0.6 } },
  { 'visual_id' => 'multirowcard0000cc02', 'visual_type' => 'multiRowCard' }
] }] }
mr_spec = { 'document' => {
  'settings' => { 'theme' => { 'name' => 'Light', 'overrides' => {
    'categoricalScheme' => PbiTheme::FALLBACK, 'colors' => { 'highlight' => PbiTheme::FALLBACK.first } } } },
  'elements' => [
    { 'id' => "#{kid.call('multirowcard0000cc01')}-k0", 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'm1' } },
    { 'id' => "#{kid.call('multirowcard0000cc01')}-k1", 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'm2' } },
    { 'id' => "#{kid.call('multirowcard0000cc02')}-k0", 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'm3' } }
  ] } }
PbiColumnFormatApply.apply(mr_spec, mr_sig, theme_only: true)
mt = mr_spec['document']['elements']
ok('multi-row tiles with an explicit theme colour are painted', mt[0]['value']['color'] == '#FAE99F' && mt[1]['value']['color'] == '#FAE99F')
ok('an unset multi-row tile on the classic theme gets the classic card colour', mt[2]['value']['color'] == '#333333')
mr_sig2 = { 'theme' => 'CY24SU10', 'pages' => [{ 'visuals' => [{ 'visual_id' => 'multirowcard0000cc02', 'visual_type' => 'multiRowCard' }] }] }
mr_spec2 = { 'document' => { 'elements' => [
  { 'id' => "#{kid.call('multirowcard0000cc02')}-k0", 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'm3' } }] } }
PbiColumnFormatApply.apply(mr_spec2, mr_sig2, theme_only: true)
ok('an unset multi-row tile on a modern theme stays unset (no accent)', mr_spec2['document']['elements'][0]['value']['color'].nil?)

# G2: a font-only fill still sets backgroundColor explicitly (Sigma paints a default green fill otherwise).
fo = PbiConditionalFormats.column_fill_formats(
  [{ 'target' => 'T.Units', 'back' => nil, 'font' => '#C00000', 'header' => false, 'values' => true }],
  { 'T.Units' => 'c1' }, 'Matrix F', 'pivot-table', CLASSIC10
)
ok('G2: font-only fill -> explicit white backgroundColor + font colour',
   fo['formats'].length == 1 && fo['formats'][0]['style'] == { 'backgroundColor' => '#FFFFFF', 'color' => '#C00000' })

# G5: subtotals are chrome only on a matrix; a flat table has no subtotal rows.
subcf = [{ 'target' => 'T.Units', 'back' => '#99e3dd', 'values' => true, 'header' => false, 'total' => false, 'subtotals' => true }]
flat_r = PbiConditionalFormats.column_fill_formats(subcf, { 'T.Units' => 'c1' }, 'Flat', 'table', CLASSIC10)
ok('G5: flat table value fill with default subtotals -> rule, no "not reproduced" note',
   flat_r['formats'].length == 1 && flat_r['coverage'].empty?)
mat_r = PbiConditionalFormats.column_fill_formats(subcf, { 'T.Units' => 'c1' }, 'Mx', 'pivot-table', CLASSIC10)
ok('G5: matrix value fill with subtotals still notes the lost subtotal part',
   mat_r['formats'].length == 1 && mat_r['coverage'].length == 1 && mat_r['coverage'][0][:detail] =~ /subtotal/)
flat_sub_only = PbiConditionalFormats.column_fill_formats(
  [subcf[0].merge('values' => false)], { 'T.Units' => 'c1' }, 'Flat', 'table', CLASSIC10
)
ok('G5: flat table subtotal-only fill is silent', flat_sub_only['formats'].empty? && flat_sub_only['coverage'].empty?)

# G3: a palette change replaces the stale theme-coloured fill (one rule per column); other rule shapes are kept.
g3_signals = { 'theme' => 'CY18SU07', 'theme_data_colors' => %w[#112233 #AABBCC #445566 #778899 #0A0B0C #1A1B1C #2A2B2C],
               'pages' => [{ 'visuals' => [{ 'visual_id' => vid, 'column_formats' => [
                 { 'target' => 'Orders.Net Sales', 'back' => { 'theme' => 5, 'percent' => 0 }, 'font' => nil,
                   'header' => false, 'values' => true, 'subtotals' => false, 'total' => false }] }] }] }
g3 = mk_spec.call
PbiColumnFormatApply.apply(g3, g3_signals)
fills = ->(sp) { sp['document']['elements'][0]['conditionalFormats'].select { |f| f['type'] == 'single' && f['columnIds'] == ["#{eid}-v0"] } }
ok('G3: first run -> one fill with palette colour', fills.call(g3).length == 1 && fills.call(g3)[0]['style']['backgroundColor'] == '#778899')
PbiColumnFormatApply.apply(g3, g3_signals.merge('theme_data_colors' => %w[#112233 #AABBCC #445566 #FF0000 #0A0B0C #1A1B1C #2A2B2C]))
ok('G3: palette changed -> still one fill, new colour',
   fills.call(g3).length == 1 && fills.call(g3)[0]['style']['backgroundColor'] == '#FF0000')
ok('G3: other rule shapes untouched', g3['document']['elements'][0]['conditionalFormats'].count { |f| f['type'] == 'dataBars' } == 1)
snap = JSON.generate(g3)
PbiColumnFormatApply.apply(g3, g3_signals.merge('theme_data_colors' => %w[#112233 #AABBCC #445566 #FF0000 #0A0B0C #1A1B1C #2A2B2C]))
ok('G3: third run changes nothing', JSON.generate(g3) == snap)

# H1-H4 (round 3): queryRef-keyed targets, per-column rule sets, pivot row/column fields, back-colour guard.
h_eid = PolishLayout.element_id_for('h1visual0000000001')
h_cf = lambda do |tgt, back, font = nil|
  { 'target' => tgt, 'back' => back, 'font' => font, 'header' => false, 'values' => true, 'subtotals' => false, 'total' => false }
end
# H1: two columns share the display name "Amount"; the fill belongs to Returns.Amount (-c2), not the last/first by name.
h1_el = lambda do
  { 'id' => h_eid, 'kind' => 'table', 'columns' => [
    { 'id' => "#{h_eid}-c0", 'name' => 'Region' }, { 'id' => "#{h_eid}-c1", 'name' => 'Amount' },
    { 'id' => "#{h_eid}-c2", 'name' => 'Amount' }] }
end
h1_sig = lambda do |binds, cfs|
  { 'theme' => 'CY18SU07', 'pages' => [{ 'visuals' => [{ 'visual_id' => 'h1visual0000000001',
    'bindings' => binds, 'column_formats' => cfs }] }] }
end
binds = { 'Values' => %w[Orders.Region Orders.Amount Returns.Amount] }
h1 = { 'document' => { 'elements' => [h1_el.call] } }
PbiColumnFormatApply.apply(h1, h1_sig.call(binds, [h_cf.call('Returns.Amount', '#AA0000')]))
h1f = h1['document']['elements'][0]['conditionalFormats'] || []
ok('H1: fill on Returns.Amount lands on its own column (-c2) only', h1f.length == 1 && h1f[0]['columnIds'] == ["#{h_eid}-c2"])
h1b = { 'document' => { 'elements' => [h1_el.call.merge('conditionalFormats' => [
  { 'type' => 'single', 'columnIds' => ["#{h_eid}-c1"], 'condition' => 'formula', 'formula' => 'True',
    'style' => { 'backgroundColor' => '#AA0000' } }])] } }
hs = PbiColumnFormatApply.apply(h1b, h1_sig.call(binds, [h_cf.call('Orders.Amount', '#AA0000')]))
ok('H1: builder-built spec (fill on Orders.Amount) -> no second fill', h1b['document']['elements'][0]['conditionalFormats'].length == 1 && hs['elements'][0]['added'] == 0)
# no bindings and an ambiguous name: skip, never guess, and say so
h1n = { 'document' => { 'elements' => [h1_el.call] } }
hn = PbiColumnFormatApply.apply(h1n, h1_sig.call(nil, [h_cf.call('Returns.Amount', '#AA0000')]))
ok('H1: ambiguous name with no bindings -> no fill, coverage says rebuild',
   h1n['document']['elements'][0]['conditionalFormats'].nil? &&
   hn['elements'][0]['coverage'].any? { |c| c[:detail] =~ /ambiguous.*rebuild to apply/ })

# H2: a backColor entry plus a separate fontColor entry on one column merge into ONE rule (J3); fresh builder spec is a no-op.
h2_cfs = [h_cf.call('Orders.Amount', '#FFFFFF'), h_cf.call('Orders.Amount', nil, '#112233')]
h2_built = PbiConditionalFormats.column_fill_formats(h2_cfs, { 'Orders.Amount' => "#{h_eid}-c1" }, 'T', 'table', CLASSIC10)['formats']
ok('H2: builder emits one merged rule for the column',
   h2_built.length == 1 && h2_built[0]['style'] == { 'backgroundColor' => '#FFFFFF', 'color' => '#112233' })
h2 = { 'document' => { 'elements' => [h1_el.call.merge('conditionalFormats' => JSON.parse(JSON.generate(h2_built)))] } }
h2snap = JSON.generate(h2['document']['elements'])
PbiColumnFormatApply.apply(h2, h1_sig.call(binds, h2_cfs))
ok('H2: pass on a fresh builder-built spec is a no-op (merged rule kept)', JSON.generate(h2['document']['elements']) == h2snap)
h2e = { 'document' => { 'elements' => [h1_el.call] } }
PbiColumnFormatApply.apply(h2e, h1_sig.call(binds, h2_cfs))
ok('H2: pass on a spec with no fills adds the merged rule', h2e['document']['elements'][0]['conditionalFormats'] == h2_built)

# H3: pivot row / column fields are fillable (the builder fills them), not a false "degraded".
h3_el = { 'id' => h_eid, 'kind' => 'pivot-table', 'rowsBy' => [{ 'columnId' => "#{h_eid}-r0" }],
          'columnsBy' => [{ 'columnId' => "#{h_eid}-col0" }], 'values' => ["#{h_eid}-v0"],
          'columns' => [{ 'id' => "#{h_eid}-r0", 'name' => 'Region' }, { 'id' => "#{h_eid}-col0", 'name' => 'Segment' },
                        { 'id' => "#{h_eid}-v0", 'name' => 'Amount' }] }
h3 = { 'document' => { 'elements' => [h3_el] } }
h3s = PbiColumnFormatApply.apply(h3, h1_sig.call({ 'Rows' => ['Orders.Region'], 'Columns' => ['Orders.Segment'], 'Values' => ['Orders.Amount'] },
  [h_cf.call('Orders.Region', '#AA0000'), h_cf.call('Orders.Segment', '#00AA00')]))
h3f = h3['document']['elements'][0]['conditionalFormats'] || []
ok('H3: row and column fields get their fills', h3f.map { |f| f['columnIds'][0] }.sort == ["#{h_eid}-col0", "#{h_eid}-r0"])
ok('H3: no false degraded coverage', h3s['elements'][0]['coverage'].empty?)

# H4: an unresolvable back colour with a resolvable font colour emits no rule (no white-on-white) and is reported.
h4 = PbiConditionalFormats.column_fill_formats(
  [{ 'target' => 'T.Units', 'back' => { 'theme' => 40, 'percent' => 0 }, 'font' => '#C00000', 'values' => true }],
  { 'T.Units' => 'c1' }, 'M', 'pivot-table', CLASSIC10)
ok('H4: unresolved back + resolved font -> no rule, coverage names the back colour',
   h4['formats'].empty? && h4['coverage'].length == 1 && h4['coverage'][0][:detail] =~ /unresolved back colour/ &&
   h4['coverage'][0][:detail] =~ /theme/)

# J1: a leaf fallback matching two bound columns is ambiguous -> no fill, non-recoverable coverage.
j_qr = { 'Orders.Region' => 'c0', 'Sum(Orders.Amount)' => 'c1', 'Sum(Returns.Amount)' => 'c2' }
j_cf = lambda do |t, b, f = nil|
  { 'target' => t, 'back' => b, 'font' => f, 'header' => false, 'values' => true, 'subtotals' => false, 'total' => false }
end
j1 = PbiConditionalFormats.column_fill_formats([j_cf.call('Sales.Amount', '#AA0000')], j_qr, 'T', 'table', CLASSIC10)
ok('J1: ambiguous leaf -> no rule', j1['formats'].empty?)
ok('J1: ambiguous leaf -> approximated, non-recoverable coverage',
   j1['coverage'].length == 1 && j1['coverage'][0][:severity] == 'approximated' &&
   j1['coverage'][0][:recoverable] == false && j1['coverage'][0][:detail] =~ /ambiguous/)
j1s = PbiConditionalFormats.column_fill_formats([j_cf.call('Sales.Region', '#AA0000')], j_qr, 'T', 'table', CLASSIC10)
ok('J1: a single leaf match still resolves', j1s['formats'].length == 1 && j1s['formats'][0]['columnIds'] == ['c0'])

# J2: back resolves, font does not -> background rule kept, font reported.
j2 = PbiConditionalFormats.column_fill_formats(
  [j_cf.call('Orders.Region', '#12239E', { 'theme' => 40, 'percent' => 0 })], j_qr, 'T', 'table', CLASSIC10)
ok('J2: background rule still emitted', j2['formats'].length == 1 && j2['formats'][0]['style'] == { 'backgroundColor' => '#12239E' })
ok('J2: unresolved font colour reported (approximated)',
   j2['coverage'].any? { |c| c[:severity] == 'approximated' && c[:detail] =~ /font colour/ && c[:detail] =~ /theme/ })

# J3: split back / font entries on one column merge into ONE rule; later wins on a shared property.
j3 = PbiConditionalFormats.column_fill_formats(
  [j_cf.call('Orders.Region', '#12239E'), j_cf.call('Orders.Region', nil, '#FFFFFF')], j_qr, 'T', 'table', CLASSIC10)
ok('J3: one merged rule with back + font', j3['formats'].map { |f| f['style'] } == [{ 'backgroundColor' => '#12239E', 'color' => '#FFFFFF' }])
j3b = PbiConditionalFormats.column_fill_formats(
  [j_cf.call('Orders.Region', '#111111', '#222222'), j_cf.call('Orders.Region', '#333333')], j_qr, 'T', 'table', CLASSIC10)
ok('J3: later entry wins a shared property', j3b['formats'].map { |f| f['style'] } == [{ 'backgroundColor' => '#333333', 'color' => '#222222' }])
j3_eid = PolishLayout.element_id_for('vJ')
j3_spec = { 'document' => { 'elements' => [{ 'id' => j3_eid, 'kind' => 'table', 'columns' => [{ 'id' => "#{j3_eid}-c0", 'name' => 'Region' }] }] } }
j3_sig = { 'pages' => [{ 'visuals' => [{ 'visual_id' => 'vJ', 'bindings' => { 'Values' => ['Orders.Region'] },
  'column_formats' => [j_cf.call('Orders.Region', '#12239E'), j_cf.call('Orders.Region', nil, '#FFFFFF')] }] }] }
PbiColumnFormatApply.apply(j3_spec, j3_sig)
j3_built = j3_spec['document']['elements'][0]['conditionalFormats'].map { |f| Marshal.load(Marshal.dump(f)) }
j3_sum = PbiColumnFormatApply.apply(j3_spec, j3_sig)
ok('J3: builder-shaped spec is a no-op under the pass',
   j3_sum['elements'][0]['added'] == 0 && j3_spec['document']['elements'][0]['conditionalFormats'] == j3_built &&
   j3_built.length == 1)

# K1: value-cell entries for one column merge even when their parts flags or target spellings differ.
k1 = PbiConditionalFormats.column_fill_formats(
  [j_cf.call('Orders.Region', '#12239E'), j_cf.call('Orders.Region', nil, '#FFFFFF').merge('header' => true)],
  j_qr, 'T', 'table', CLASSIC10)
ok('K1: differing parts flags -> one merged value-cell rule',
   k1['formats'].map { |f| f['style'] } == [{ 'backgroundColor' => '#12239E', 'color' => '#FFFFFF' }] &&
   k1['coverage'].any? { |c| c[:detail] =~ /value cells filled, header/ })
k1b = PbiConditionalFormats.column_fill_formats(
  [j_cf.call('Sum(Orders.Amount)', '#12239E'), j_cf.call('Orders.Amount', nil, '#FFFFFF')],
  { 'Sum(Orders.Amount)' => 'c1' }, 'T', 'table', CLASSIC10)
ok('K1: differing target spellings of one column -> one merged rule',
   k1b['formats'].length == 1 && k1b['formats'][0]['columnIds'] == ['c1'] &&
   k1b['formats'][0]['style'] == { 'backgroundColor' => '#12239E', 'color' => '#FFFFFF' })

# K2: a skipped fill (ambiguous or missing target) never also claims "value cells filled".
k2 = PbiConditionalFormats.column_fill_formats([j_cf.call('Sales.Amount', '#AA0000').merge('header' => true)],
                                               j_qr, 'T', 'table', CLASSIC10)
ok('K2: ambiguous fill with a header part -> no "value cells filled" note',
   k2['formats'].empty? && k2['coverage'].none? { |c| c[:detail] =~ /value cells filled/ } &&
   k2['coverage'].any? { |c| c[:detail] =~ /ambiguous/ })

# Stale fills: a fill that left the signals, or became header/total-only, loses its old value-cell rule; other
# rule shapes and other elements are untouched.
st_eid = PolishLayout.element_id_for('vS')
st_rule = ->(cid, bg) { { 'type' => 'single', 'columnIds' => [cid], 'condition' => 'formula', 'formula' => 'True', 'style' => { 'backgroundColor' => bg } } }
st_bars = { 'type' => 'dataBars', 'columnIds' => ["#{st_eid}-c1"] }
st_spec = lambda do
  { 'document' => { 'elements' => [{ 'id' => st_eid, 'kind' => 'table', 'columns' => [
    { 'id' => "#{st_eid}-c0", 'name' => 'Region' }, { 'id' => "#{st_eid}-c1", 'name' => 'Amount' }],
    'conditionalFormats' => [st_rule.call("#{st_eid}-c0", '#12239E'), st_rule.call("#{st_eid}-c1", '#AA0000'), st_bars] }] } }
end
st_vis = ->(cfs) { { 'visual_id' => 'vS', 'bindings' => { 'Values' => ['Orders.Region', 'Orders.Amount'] } }.merge(cfs ? { 'column_formats' => cfs } : {}) }
s1 = st_spec.call
r1 = PbiColumnFormatApply.apply(s1, { 'pages' => [{ 'visuals' => [st_vis.call([j_cf.call('Orders.Region', '#12239E')])] }] })
cf1 = s1['document']['elements'][0]['conditionalFormats']
ok('stale: a fill removed from the signals loses its value-cell rule',
   cf1.none? { |f| f['columnIds'] == ["#{st_eid}-c1"] && f['type'] == 'single' } && r1['elements'][0]['removed'] == 1)
ok('stale: the still-wanted fill and other rule shapes stay', cf1.include?(st_rule.call("#{st_eid}-c0", '#12239E')) && cf1.include?(st_bars))
s2 = st_spec.call
PbiColumnFormatApply.apply(s2, { 'pages' => [{ 'visuals' => [st_vis.call([j_cf.call('Orders.Region', '#12239E'),
  j_cf.call('Orders.Amount', '#AA0000').merge('values' => false, 'header' => true)])] }] })
ok('stale: a fill that became header-only loses its value-cell rule',
   s2['document']['elements'][0]['conditionalFormats'].none? { |f| f['columnIds'] == ["#{st_eid}-c1"] && f['type'] == 'single' })
s3 = st_spec.call
r3 = PbiColumnFormatApply.apply(s3, { 'pages' => [{ 'visuals' => [st_vis.call(nil)] }] })
ok('stale: a visual with no fills left keeps only non-fill rules',
   s3['document']['elements'][0]['conditionalFormats'] == [st_bars] && r3['elements'][0]['removed'] == 2)
s4 = st_spec.call
r4 = PbiColumnFormatApply.apply(s4, { 'pages' => [{ 'visuals' => [] }] })
ok('stale: an element not tied to a signals visual is untouched',
   s4['document']['elements'] == st_spec.call['document']['elements'] && r4['elements'].empty?)

puts($fail.zero? ? "\nall passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
