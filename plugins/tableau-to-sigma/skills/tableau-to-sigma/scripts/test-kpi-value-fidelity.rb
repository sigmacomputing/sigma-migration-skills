#!/usr/bin/env ruby
# Regression test for KPI VALUE FIDELITY (bead: KPIs come out wrong).
#
# Two coupled emit-side fixes, exercised on a genericized marks-card measure
# list that mirrors the real structural shape (no customer identifiers):
#
#   1. pick_kpi_measure — a Tableau scorecard's Marks card carries several
#      measures (a raw aggregate column, opaque calc ids, and the MATERIALIZED
#      VALIDATED calc). The old `measures.first` grabbed the raw column, so the
#      KPI re-derived `Sum(rawcol)` and printed the wrong number. The picker must
#      prefer the validated/materialized calc and never pick a `(Label)` text calc.
#
#   2. resolve_shelf_field — a calc column is named `[Calculation_NNN]` /
#      `[X (copy)_NNN]`, NOT a 36-char GUID, so guid_from_text() is nil and the
#      guid lookup misses. The internal-name fallback must still resolve the
#      real caption from columns_by_guid, so the calc-formula ladder can fire
#      (instead of falling back to a naive Sum of the raw internal name).
#
# Pure-helper extraction harness (same pattern as test-param-measure-picker.rb).
#
# Usage:  ruby scripts/test-kpi-value-fidelity.rb
require 'json'
# Ruby 2.6 floor: this test READS a sibling script and eval()s a method out
# of it, so that script's own require_relative lines never run -- the test
# must supply the polyfill itself. See shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb')) +
  File.read(File.join(__dir__, 'lib', 'chart_calc_translate.rb'), encoding: 'UTF-8') # translators moved to the shared lib

USER_AGG_FN = { 'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max', 'MEDIAN' => 'Median' }.freeze
%w[map_column guid_from_text placeholder_calc? pick_kpi_measure resolve_shelf_field split_top_level_args
   tableau_iif_to_sigma translate_kpi_measure_formula].each do |fn|
  m = SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn} from build-charts-from-signals.rb")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# columns_by_guid keyed by INTERNAL NAME (as parse-twb-layout emits it) → caption.
# Generic field names; the shape (raw col + opaque calc + (copy)_NNN validated +
# (Label) copy) is what matters, and it matches how Tableau materializes calcs.
CBG = {
  'GROSS_AMT'                       => { 'caption' => 'GROSS_AMT' },
  'Calculation_10000000000000001'   => { 'caption' => 'Gross Sales' },
  'Gross Sales  (copy)_20000000002' => { 'caption' => 'Gross Sales  (validated)' },
  'Return Rate  (copy)_30000000003' => { 'caption' => 'Return Rate  (validated)' },
  'Gross Sales (Label) (copy)_40000000004' => { 'caption' => 'Gross Sales (Label)' },
  'Gross Sales (copy)_50000000005'  => { 'caption' => 'Gross Sales' }
}

# ---- 1. value tile: raw agg col + opaque calc + validated (copy) -------------
# Must pick the validated (copy), NOT the raw column first entry.
value_measures = [
  { 'column' => '[GROSS_AMT]',                        'derivation' => 'Sum' },
  { 'column' => '[Calculation_10000000000000001]',    'derivation' => 'User' },
  { 'column' => '[Gross Sales  (copy)_20000000002]',  'derivation' => 'User' }
]
picked = pick_kpi_measure(value_measures, CBG)
check(picked && picked['column'] == '[Gross Sales  (copy)_20000000002]',
      "value tile picks the validated (copy) calc, not the raw agg column (got #{picked && picked['column']})", fails)

# ---- 2. ratio tile: single validated (copy) — picked unchanged ---------------
ratio_measures = [{ 'column' => '[Return Rate  (copy)_30000000003]', 'derivation' => 'User' }]
check(pick_kpi_measure(ratio_measures, CBG)['column'] == '[Return Rate  (copy)_30000000003]',
      'ratio tile (single validated copy) is picked', fails)

# ---- 3. a (Label) calc must never be chosen as the value ---------------------
label_measures = [
  { 'column' => '[Gross Sales (Label) (copy)_40000000004]', 'derivation' => 'User' },
  { 'column' => '[Gross Sales (copy)_50000000005]',         'derivation' => 'User' }
]
picked_lbl = pick_kpi_measure(label_measures, CBG)
check(picked_lbl['column'] !~ /\(label\)/i,
      "does not pick the (Label) text calc as the value (got #{picked_lbl['column']})", fails)

# ---- 4. degenerate inputs ----------------------------------------------------
check(pick_kpi_measure([], CBG).nil?, 'empty measure list → nil', fails)
check(pick_kpi_measure(nil, CBG).nil?, 'nil measure list → nil', fails)
only_label = [{ 'column' => '[Foo (Label)]', 'derivation' => 'User' }]
check(pick_kpi_measure(only_label, CBG)['column'] == '[Foo (Label)]',
      'a lone (Label) measure is still returned (tile not lost)', fails)

# ---- 5. resolve_shelf_field: internal-name caption fallback ------------------
# The (copy)_NNN column has no 36-char GUID; caption must still resolve so the
# calc-formula ladder can find "…(validated)".
meta = { 'columns_by_guid' => CBG }
mmap = {} # no master entry — we only assert the resolved CAPTION here
field = { 'role' => 'measure', 'derivation' => 'user',
          'raw' => '[Gross Sales  (copy)_20000000002]',
          'guid' => guid_from_text('[Gross Sales  (copy)_20000000002]') }
check(field['guid'].nil?, 'guid_from_text is nil for a (copy)_NNN calc column (the trigger)', fails)
_m, cap = resolve_shelf_field(field, meta, mmap)
check(cap == 'Gross Sales  (validated)',
      "resolve_shelf_field resolves the (copy) column to its validated caption (got #{cap.inspect})", fails)

# A raw column with no columns_by_guid caption still resolves to its own name.
field2 = { 'raw' => '[Some Raw Col]', 'guid' => nil }
_m2, cap2 = resolve_shelf_field(field2, { 'columns_by_guid' => {} }, {})
check(cap2 == 'Some Raw Col', "unknown raw column falls back to its stripped name (got #{cap2.inspect})", fails)

# ---- 6. ratio translator: bare materialized-measure refs → Sum()/Sum() -------
# mmap simulating the master AFTER the (copy) columns are materialized (generic
# names). map_column matches a caption/name against these regex patterns.
RMMAP = {
  '(?i)^Amount Saved \(copy\)_20000000002$' => { 'id' => 'm-amt', 'name' => 'Amount Saved (copy)_20000000002' },
  '(?i)^Cost \(copy\)_30000000003$'         => { 'id' => 'm-cost', 'name' => 'Cost (copy)_30000000003' },
  '(?i)^ENTITY_ID$'                     => { 'id' => 'm-aid', 'name' => 'ENTITY_ID' },
  '(?i)^BASE_AMT$'                       => { 'id' => 'm-rc', 'name' => 'BASE_AMT' }
}
# ratio of two bare materialized measure refs → Sum(a)/Sum(b)
roi = translate_kpi_measure_formula('[Amount Saved (copy)_20000000002]/[Cost (copy)_30000000003]', RMMAP, {})
check(roi == 'Sum([Master/Amount Saved (copy)_20000000002]) / Sum([Master/Cost (copy)_30000000003])' ||
      roi == 'Sum([Master/Amount Saved (copy)_20000000002])/Sum([Master/Cost (copy)_30000000003])',
      "ratio of bare copy refs → Sum(a)/Sum(b) (got #{roi.inspect})", fails)
# bare measure ref / explicit COUNT → Sum(copy) / CountIf(IsNotNull(id))  (avg-cost shape)
avg = translate_kpi_measure_formula('[Cost (copy)_30000000003]/COUNT([ENTITY_ID])', RMMAP, {})
check(avg && avg.include?('Sum([Master/Cost (copy)_30000000003])') && avg.include?('CountIf(IsNotNull([Master/ENTITY_ID]))'),
      "bare copy / COUNT(id) → Sum(copy)/CountIf(IsNotNull(id)) (got #{avg.inspect})", fails)
# plain SUM of a base column (Cost-of-Service class) still resolves
cost = translate_kpi_measure_formula('SUM([BASE_AMT])', RMMAP, {})
check(cost == 'Sum([Master/BASE_AMT])', "explicit SUM([base]) → Sum([Master/base]) (got #{cost.inspect})", fails)
# param-scalar KPI → nil (bails so the param→control path handles it)
check(translate_kpi_measure_formula('MAX(If(Contains(Lower([Parameters].[X]),"y"),[Parameters].[A],[Parameters].[B]))', RMMAP, {}).nil?,
      'param-scalar calc → nil (deferred to param→control handling)', fails)
# unmappable bare ref → nil (never emits a half-resolved formula)
check(translate_kpi_measure_formula('[Ghost Col]/[Cost (copy)_30000000003]', RMMAP, {}).nil?,
      'unmappable bare ref → nil (no half-resolved formula)', fails)

# ---- v5.0 exact-format Text() columns for scale-comma + suffix formats ------
# Tableau '#,##0,,,B' renders "1B"; Sigma's d3 enum can't (,.2s shows SI 'G').
# The mechanized fidelity recipe: parse the scale/suffix, emit a Text() column.
# FORMAT_KEY_CAPTIONS is normally built from meta['columns_by_guid'] at load;
# stub it empty so format_key_match_keys resolves format keys on their own token.
FORMAT_KEY_CAPTIONS = {} unless defined?(FORMAT_KEY_CAPTIONS)
%w[format_header_keys format_key_match_keys parse_scaled_suffix_format scaled_suffix_column pick_tableau_format_raw].each do |fn|
  m = SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval
end
b = parse_scaled_suffix_format('n#,##0,,,B;-#,##0,,,B')
check(b == { 'scale' => 1_000_000_000, 'decimals' => 0, 'suffix' => 'B' },
      "',,,B' → /1e9 + literal B (got #{b.inspect})", fails)
m6 = parse_scaled_suffix_format('n#,##0,,.0M;-#,##0,,.0M')
check(m6 == { 'scale' => 1_000_000, 'decimals' => 1, 'suffix' => 'M' },
      "',,.0M' → /1e6, 1 decimal, literal M (got #{m6.inspect})", fails)
check(parse_scaled_suffix_format('#,##0').nil?, 'no scale-commas → nil (enum path keeps it)', fails)
check(parse_scaled_suffix_format('p0.0%').nil?, 'percent format → nil (enum path keeps it)', fails)
# Review-hardened: NUMERIC scaled column + fixed-decimal format + literal
# `suffix` (spec/verify-confirmed) — trailing zeros and grouping survive,
# unlike the earlier Text(Round()) concat ('3.0M' stayed '3.0M', not '3M').
f = scaled_suffix_column('Sum([Master/REV])', b)
check(f == { 'formula' => '(Sum([Master/REV])) / 1000000000',
             'format' => { 'kind' => 'number', 'formatString' => ',.0f', 'suffix' => 'B' } },
      "exact-format scaled column (got #{f.inspect})", fails)
f2 = scaled_suffix_column('Sum([Master/UNITS])', m6)
check(f2['format'] == { 'kind' => 'number', 'formatString' => ',.1f', 'suffix' => 'M' },
      "zero-padded decimals survive via ,.1f (got #{f2['format'].inspect})", fails)
raw = pick_tableau_format_raw({ '[federated.x].[sum:Revenue (current US$):qk]' => 'n#,##0,,,B;-#,##0,,,B' },
                              'Revenue (current US$)')
check(raw == 'n#,##0,,,B;-#,##0,,,B', "raw format string resolvable by header (got #{raw.inspect})", fails)

# ---- C6: KPI BAN band (borderless sibling BANs share ONE source container) ---
# Real builder (offline harness) + real layout builder. The band fill comes only
# from the source container's fill; bordered/filled source BANs keep card style.
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/builder_test_harness'
require_relative 'lib/layout'

def ban_zone(id, x, extra = {})
  BuilderTestHarness.chart_zone(id: id, caption: "BAN #{id}", chart_kind: 'kpi', mark_class: 'Shape',
                                extra: { 'x_pct' => x, 'y_pct' => 10, 'w_pct' => 18, 'h_pct' => 10,
                                         'kpi_value_font_size' => 30 }.merge(extra))
end

def ban_tree(zones, container_extra = {})
  [{ 'id' => 'band', 'kind' => 'container', 'caption' => nil, 'x_pct' => 0, 'y_pct' => 10,
     'w_pct' => 100, 'h_pct' => 10, 'direction' => 'horz',
     'children' => zones.map { |z| { 'id' => z['id'], 'kind' => 'chart', 'caption' => z['caption'] } } }
     .merge(container_extra)]
end

xs = [0, 20, 40, 60, 80]
plain = xs.each_with_index.map { |x, i| ban_zone("b#{i}", x) }
res = BuilderTestHarness.run(plain, zone_tree: ban_tree(plain, 'fill_color' => '#f7f8fa'))
kpis = res[:elements].select { |e| e['kind'] == 'kpi-chart' }
check(kpis.length == 5, "5 BANs emitted as kpi-charts (got #{kpis.length})", fails)
check(kpis.all? { |k| !k.dig('style', 'backgroundColor') || k.dig('style', 'backgroundColor') != 'transparent' },
      'builder keeps the pre-band card style (band restyle is the layout\'s decision, applied by put-layout)', fails)
check(kpis.all? { |k| k.dig('value', 'fontSize') == 30 },
      'value size comes from the source BAN size', fails)
check(SigmaLayout.ban_kpi_patch == { 'style' => { 'backgroundColor' => 'transparent', 'borderRadius' => 'square', 'borderWidth' => 0 },
                                     'layout' => { 'anchor' => 'center', 'titleOrient' => 'top' } },
      'band KPI patch is exactly {transparent, square, borderWidth 0} + centre/top layout', fails)

filled = xs.each_with_index.map { |x, i| ban_zone("f#{i}", x, 'fill_color' => '#e0f0ff') }
rf = BuilderTestHarness.run(filled, zone_tree: ban_tree(filled, 'fill_color' => '#f7f8fa'))
fk = rf[:elements].select { |e| e['kind'] == 'kpi-chart' }
check(fk.length == 5 && fk.all? { |k| k.dig('style', 'backgroundColor') == '#e0f0ff' },
      'filled source BANs keep today per-card style (fill carried)', fails)
bordered = xs.each_with_index.map { |x, i| ban_zone("r#{i}", x, 'border_color' => '#888888', 'border_width' => '1') }
rb = BuilderTestHarness.run(bordered, zone_tree: ban_tree(bordered, 'fill_color' => '#f7f8fa'))
bk = rb[:elements].select { |e| e['kind'] == 'kpi-chart' }
check(bk.length == 5 && bk.none? { |k| k.dig('style', 'backgroundColor') == 'transparent' },
      'bordered source BANs keep per-card style (no band restyle)', fails)
loose = xs.each_with_index.map { |x, i| ban_zone("l#{i}", x) }
rl = BuilderTestHarness.run(loose) # no container tree -> no shared source container
check(rl[:elements].select { |e| e['kind'] == 'kpi-chart' }.none? { |k| k.dig('style', 'backgroundColor') == 'transparent' },
      'no shared source container -> no band restyle', fails)

# Layout: one band container, source fill, equal spans with remainder left-to-right.
def layout_for(zones, tree, args = [])
  dl = [{ 'dashboard' => 'Overview', 'zones' => zones, 'zone_tree' => tree }]
  els = zones.map { |z| { 'id' => "el-#{z['id']}", 'kind' => 'kpi-chart', 'name' => z['caption'] } }
  wb = { 'pages' => [
    { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
    { 'name' => 'Overview', 'id' => 'page-ov', 'elements' => [{ 'id' => 'title-ov', 'kind' => 'text', 'name' => nil }] + els }
  ] }
  Dir.mktmpdir do |d|
    File.write("#{d}/dl.json", JSON.generate(dl))
    File.write("#{d}/wb.json", JSON.generate(wb))
    out = "#{d}/layout.xml"
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    _o, _e, _s = Open3.capture3(RbConfig.ruby, File.join(DIR, 'build-dashboard-layout.rb'), '--layout', "#{d}/dl.json",
                                '--wb-ids', "#{d}/wb.json", '--out', out, *args)
    xml = File.exist?(out) ? File.read(out) : ''
    extra = File.exist?("#{out}.elements.json") ? JSON.parse(File.read("#{out}.elements.json")).values.flatten : []
    $last_patches = File.exist?("#{out}.kpi-band-style.json") ? JSON.parse(File.read("#{out}.kpi-band-style.json")) : nil
    [xml, extra]
  end
end

xml, extra = layout_for(plain, ban_tree(plain, 'fill_color' => '#f7f8fa'))
band = extra.find { |e| e['kind'] == 'container' && e['id'].to_s.include?('-kpi-') }
check($last_patches && $last_patches.keys.sort == (0..4).map { |i| "el-b#{i}" },
      'layout writes the band KPI restyle for exactly the 5 banded KPIs', fails)
check(band && band.dig('style', 'backgroundColor') == '#f7f8fa',
      "one band container carries the SOURCE container fill (got #{band && band['style'].inspect})", fails)
check(band && band['style'] && band['style']['padding'] == 'none' && band['style']['borderRadius'] == 'square',
      'band container style is padding none + square corners', fails)
spans = xml.scan(/elementId="el-b\d"[^>]*gridColumn="(\d+) \/ (\d+)"|gridColumn="(\d+) \/ (\d+)"[^>]*elementId="el-b\d"/)
                .map { |m| m.compact.map(&:to_i) }.map { |a, b| b - a }
check(spans == [5, 5, 5, 5, 4], "equal spans for 5 cards on 24 cols, remainder left to right (got #{spans.inspect})", fails)

nofill_xml, nofill_extra = layout_for(plain, ban_tree(plain))
nb = nofill_extra.find { |e| e['kind'] == 'container' && e['id'].to_s.include?('-kpi-') }
check(nb && !nb.fetch('style', {}).key?('backgroundColor'),
      'source container without a fill -> band has NO invented tint', fails)

bxml, bextra = layout_for(bordered, ban_tree(bordered, 'fill_color' => '#f7f8fa'))
bbk = bextra.find { |e| e['kind'] == 'container' && e['id'].to_s.include?('-kpi-') }
check(bbk && bbk['style'].nil?, 'bordered BANs -> plain KPI container (no band style)', fails)

# Fallback agreement: no band container -> no KPI restyle (BANs keep card style).
nc_xml, nc_extra = layout_for(plain, ban_tree(plain, 'fill_color' => '#f7f8fa'), ['--no-containers'])
check(nc_extra.none? { |e| e['kind'] == 'container' && e['style'] && e['style']['padding'] == 'none' && e['id'].to_s.include?('-kpi-') },
      '--no-containers: no band container emitted', fails)
check($last_patches == {}, "--no-containers: no KPI band restyle emitted (got #{$last_patches.inspect})", fails)
layout_for(bordered, ban_tree(bordered, 'fill_color' => '#f7f8fa'))
check($last_patches == {}, 'bordered BANs: no KPI band restyle emitted', fails)

# Stale-sidecar hazard: migrate-tableau's two non-regenerating layout paths
# (reuse-workbook preserve, spec-generator layout) must neutralise a sidecar an
# earlier run left in WORK, before put-layout reads it by default.
Dir.mktmpdir do |wd|
  lp = File.join(wd, 'layout.xml')
  File.write("#{lp}.kpi-band-style.json", '{"el-b0":{"style":{}}}')
  SigmaLayout.clear_band_style_sidecar(lp)
  check(!File.exist?("#{lp}.kpi-band-style.json"), 'clear_band_style_sidecar removes a stale sidecar', fails)
  SigmaLayout.clear_band_style_sidecar(lp) # idempotent when absent
end
mt = File.read(File.join(DIR, 'migrate-tableau.rb'))
pres = mt[/if _lr_preserve
.*?
elsif layout_xml/m].to_s
gen  = mt[/elsif layout_xml
.*?
elsif File\.exist\?\(layout_json\)/m].to_s
check(pres.include?('File.write(layout_path, $layout_reuse[:xml])') && pres.include?('SigmaLayout.clear_band_style_sidecar(layout_path)'),
      'migrate-tableau reuse-workbook preserve path clears the stale band sidecar', fails)
check(gen.include?('File.write(layout_path, layout_xml)') && gen.include?('SigmaLayout.clear_band_style_sidecar(layout_path)'),
      'migrate-tableau spec-generator layout path clears the stale band sidecar', fails)

puts
if fails.empty?
  puts 'ALL PASS — KPI value fidelity: validated-calc preference + internal-name caption resolution + ratio translation'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
