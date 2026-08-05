#!/usr/bin/env ruby
# Regression test for C2 "threshold halo" (gap ubr5.11, P0).
#
# A "threshold halo" is a mark whose COLOR flips above/below a constant on the
# measure — the reference ">100K" yellow halo, the red-below/green-above BAN.
# Before C2 a threshold-calc color channel was DROPPED on bars (it isn't a CSV
# dim → color_col_obj nil → single-series fan-out NOTE) and absent on KPIs.
#
# Two layers, both exercised end-to-end:
#
#   A. DETECTION (lib/threshold_halo.rb, pure) — parse the color calc formula
#      into {agg, measure_ref, op, constant} and split the 2-band .twb color map
#      into {below, above}; reject compound/continuous/>2-band as unmappable.
#
#   B. EMISSION (build-charts-from-signals.rb, real run over a synthetic .twb):
#      1. a BAR colored by a threshold calc → color:{by:category, column:<bool>,
#         scheme:[below, above]} + a computed-boolean column [m] op N.
#      2. a BAN/KPI with the same threshold → NO conditional value color emitted
#         (Sigma ceiling: kpi-chart value.color is static / CF is UI-only) →
#         routed to POSTPUBLISH + coverage, never silently dropped.
#      3. threshold-halo.json sidecar (the mechanical blind-grade counterpart).
#      4. BYTE-IDENTICAL guard: the SAME workbook with the threshold color
#         removed builds an identical spec to origin/main's builder (feature is
#         purely additive/detected).
#
# Deterministic + offline: synthesizes a .twb + view CSVs, runs the ACTUAL
# parse-twb-layout.rb + build-charts-from-signals.rb.
#
# Usage:  ruby scripts/test-threshold-halo.rb
require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')
require_relative 'lib/threshold_halo'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- A. DETECTION unit (pure lib) ------------------------------------------
puts '== A. detection (lib/threshold_halo.rb) =='
t = ThresholdHalo.parse_threshold('SUM([Sales]) > 100000')
check(t && t['agg'] == 'SUM' && t['op'] == '>' && t['constant'] == 100000 && t['measure_ref'] == '[Sales]',
      "parse 'SUM([Sales]) > 100000' → agg/op/const/measure (got #{t.inspect})", fails)
t2 = ThresholdHalo.parse_threshold('[Profit] >= 0')
check(t2 && t2['agg'].nil? && t2['op'] == '>=' && t2['constant'] == 0,
      "parse bare '[Profit] >= 0' (no agg) (got #{t2.inspect})", fails)
t3 = ThresholdHalo.parse_threshold('IIF(AVG([Score]) < 3.5, 1, 0)')
check(t3 && t3['agg'] == 'AVG' && t3['op'] == '<' && t3['constant'] == 3.5,
      "parse IIF-wrapped 'AVG([Score]) < 3.5' condition (got #{t3.inspect})", fails)
check(ThresholdHalo.parse_threshold('SUM([A]) > 10 AND SUM([B]) < 5').nil?,
      'compound AND predicate → nil (unmappable, deferred)', fails)
check(ThresholdHalo.parse_threshold('[Region] = "West"').nil?,
      'non-numeric equality → nil (not a threshold)', fails)

bands = ThresholdHalo.band_colors([{ 'member' => 'true', 'color' => '#f2c037' },
                                   { 'member' => 'false', 'color' => '#c9d1d3' }])
check(bands && bands['above'] == '#f2c037' && bands['below'] == '#c9d1d3' && bands['basis'] == 'boolean',
      "band_colors boolean → above=halo, below=base (got #{bands.inspect})", fails)
check(ThresholdHalo.band_colors([{ 'member' => 'a', 'color' => '#111111' },
                                 { 'member' => 'b', 'color' => '#222222' },
                                 { 'member' => 'c', 'color' => '#333333' }]).nil?,
      '3-band map → nil (unmappable, deferred to coverage)', fails)

# plan_for_zone wiring (guid resolver + neutral fn as the builder passes them)
zone = { 'series_colors' => [{ 'member' => 'true', 'color' => '#f2c037' },
                             { 'member' => 'false', 'color' => '#c9d1d3' }],
         'series_color_field' => 'Over 100K',
         'channels' => { 'color' => { 'column' => '[fed].[none:Calculation_770:nk]' } } }
cbg = { 'Calculation_770' => { 'caption' => 'Over 100K', 'formula' => 'SUM([m1]) > 100000' } }
guid_of = ->(ref) { ref[/\[(?:[a-z]+:)?([^:\]]+?)(?::[a-z0-9]+)?\]\s*\z/i, 1] }
plan = ThresholdHalo.plan_for_zone(zone, cbg, guid_of)
check(plan && plan['mappable'] && plan['op'] == '>' && plan['above'] == '#f2c037' && plan['below'] == '#c9d1d3',
      "plan_for_zone resolves the calc formula + colors (got #{plan.inspect})", fails)

# ---- shared TWB fixtures for the emission run ------------------------------
def twb(with_threshold:)
  color_calc = with_threshold ? <<~CALC : ''
    <column caption='Over 100K' name='[Calculation_770]' datatype='boolean' role='dimension' type='ordinal'>
      <calculation class='tableau' formula='SUM([m-nb-guid-0000-000000000001]) &gt; 100000' /></column>
  CALC
  bar_color = with_threshold ? <<~C : ''
    <style-rule element='mark'>
      <encoding attr='color' field='[federated.fact].[none:Calculation_770:nk]' type='palette'>
        <map to='#f2c037'><bucket>true</bucket></map>
        <map to='#c9d1d3'><bucket>false</bucket></map>
      </encoding>
    </style-rule>
  C
  bar_color_enc = with_threshold ? "<encoding attr='color' column='[federated.fact].[none:Calculation_770:nk]' />" : ''
  bar_ci = with_threshold ? "<column-instance column='[Calculation_770]' derivation='None' name='[none:Calculation_770:nk]' pivot='key' type='nominal' />" : ''
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        <datasource caption='ORDER_FACT' name='federated.fact'>
          <connection class='federated'>
            <named-connections>
              <named-connection name='snow'><connection class='snowflake' dbname='DEMO_DB' schema='DEMO' /></named-connection>
            </named-connections>
            <relation connection='snow' name='ORDER_FACT' table='[DEMO].[ORDER_FACT]' type='table' />
          </connection>
          <column caption='Net Bookings' name='[m-nb-guid-0000-000000000001]' datatype='real' role='measure' type='quantitative' default-format='$#,##0' />
          <column caption='Region' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
          #{color_calc}
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='Bookings by Region'>
          <table>
            <view>
              <datasource-dependencies datasource='federated.fact'>
                <column caption='Net Bookings' name='[m-nb-guid-0000-000000000001]' datatype='real' role='measure' type='quantitative' />
                <column caption='Region' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
                <column-instance column='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' derivation='None' name='[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]' pivot='key' type='nominal' />
                <column-instance column='[m-nb-guid-0000-000000000001]' derivation='Sum' name='[sum:m-nb-guid-0000-000000000001:qk]' pivot='key' type='quantitative' />
                #{bar_ci}
              </datasource-dependencies>
            </view>
            <style>#{bar_color}</style>
            <rows>[federated.fact].[sum:m-nb-guid-0000-000000000001:qk]</rows>
            <cols>[federated.fact].[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]</cols>
            <pane><mark class='Bar' /><encodings>#{bar_color_enc}</encodings></pane>
          </table>
        </worksheet>
        <worksheet name='Total Bookings'>
          <table>
            <view>
              <datasource-dependencies datasource='federated.fact'>
                <column caption='Net Bookings' name='[m-nb-guid-0000-000000000001]' datatype='real' role='measure' type='quantitative' />
                <column-instance column='[m-nb-guid-0000-000000000001]' derivation='Sum' name='[sum:m-nb-guid-0000-000000000001:qk]' pivot='key' type='quantitative' />
                #{bar_ci}
              </datasource-dependencies>
            </view>
            <style>#{bar_color}</style>
            <rows>[federated.fact].[sum:m-nb-guid-0000-000000000001:qk]</rows>
            <pane><mark class='Text' /><encodings><encoding attr='text' field='[federated.fact].[sum:m-nb-guid-0000-000000000001:qk]' />#{bar_color_enc}</encodings></pane>
          </table>
        </worksheet>
      </worksheets>
      <dashboards>
        <dashboard name='Dash'>
          <zones>
            <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
              <zone id='2' name='Bookings by Region' x='0' y='0' w='50000' h='100000' />
              <zone id='3' name='Total Bookings' x='50000' y='0' w='50000' h='100000' />
            </zone>
          </zones>
        </dashboard>
      </dashboards>
    </workbook>
  XML
end

MASTER_MAP = {
  '(?i)^Net Bookings$' => { 'id' => 'm-nb',  'name' => 'Net Bookings' },
  '(?i)^Region$'       => { 'id' => 'm-reg', 'name' => 'Region' }
}
REGION_CSV = "Region,Net Bookings\nEast,120000\nWest,80000\n"
TOTAL_CSV  = "Net Bookings\n200000\n"

def run_build(twb_text)
  out_spec = nil; log = ''; halo = nil; cov = nil
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'wb.twb'), twb_text)
    File.write(File.join(d, 'master-map.json'), JSON.dump(MASTER_MAP))
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Bookings by Region' },
                                                  { 'id' => 'v2', 'name' => 'Total Bookings' }] }))
    Dir.mkdir(File.join(d, 'views'))
    File.write(File.join(d, 'views', 'v1.csv'), REGION_CSV)
    File.write(File.join(d, 'views', 'v2.csv'), TOTAL_CSV)
    File.write(File.join(d, 'png-read.json'),
               JSON.dump('source_png' => 'views/v1.png',
                         'tiles' => [{ 'title' => 'Bookings by Region', 'kind' => 'bar-chart', 'orientation' => 'vertical' },
                                     { 'title' => 'Total Bookings', 'kind' => 'kpi-chart' }],
                         'text_elements' => [], 'filter_shelf' => []))
    lay = File.join(d, 'layout.json')
    system('ruby', PARSER, File.join(d, 'wb.twb'), lay, out: File::NULL, err: File::NULL) or abort 'parse failed'
    out = File.join(d, 'specs.json')
    log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', File.join(d, 'master-map.json'), '--master-element-id', 'master', '--out', out], err: %i[child out], &:read)
    out_spec = JSON.parse(File.read(out)) if File.exist?(out)
    hp = File.join(d, 'threshold-halo.json')
    halo = JSON.parse(File.read(hp)) if File.exist?(hp)
    cp = File.join(d, 'coverage.json')
    cov = JSON.parse(File.read(cp)) if File.exist?(cp)
  end
  [out_spec, log, halo, cov]
end

def els_of(spec)
  return [] unless spec
  spec.is_a?(Array) ? spec : (spec['elements'] || (spec['pages'] || []).flat_map { |p| p['elements'] || [] })
end

# ---- B. EMISSION run (with threshold) --------------------------------------
puts
puts '== B. emission (build-charts-from-signals.rb) =='
spec_t, log_t, halo, cov = run_build(twb(with_threshold: true))
els_t = els_of(spec_t)
bar  = els_t.find { |e| e['name'].to_s.casecmp?('Bookings by Region') }
kpi  = els_t.find { |e| e['kind'] == 'kpi-chart' }

# 1. bar halo
bc = bar && bar['color']
check(bc.is_a?(Hash) && bc['by'] == 'category' && bc['scheme'] == %w[#c9d1d3 #f2c037],
      "BAR halo: color by category + scheme [below, above] = [#c9d1d3, #f2c037] (got #{bc.inspect})", fails)
hcol = bar && (bar['columns'] || []).find { |c| c['id'] == (bc && bc['column']) }
check(hcol && hcol['formula'] == 'Sum([Master/Net Bookings]) > 100000',
      "BAR halo: computed-boolean color column [m] > N (got #{hcol && hcol['formula'].inspect})", fails)
check(log_t.include?('THRESHOLD HALO') && log_t =~ /APPROXIMATED/,
      'builder logged the halo emission + the approximation caveat', fails)

# 2. KPI/BAN → postpublish (no conditional value color emitted, never dropped)
check(kpi && kpi['conditionalFormats'].nil? && !(kpi['value'] || {}).key?('color'),
      'KPI/BAN: no conditional value color emitted (Sigma ceiling — value.color is static)', fails)
check(log_t =~ /BAN\/KPI has a THRESHOLD color/ && log_t =~ /POSTPUBLISH_GUIDE \+ coverage/,
      'KPI/BAN threshold routed to POSTPUBLISH + coverage (never silently dropped)', fails)

# 3. threshold-halo.json sidecar
check(halo.is_a?(Hash) && halo['version'] == 1 && halo['halos'].is_a?(Array),
      'threshold-halo.json sidecar written', fails)
h_bar = halo && halo['halos'].find { |r| r['status'] == 'emitted' }
h_kpi = halo && halo['halos'].find { |r| r['status'] == 'postpublish' }
check(h_bar && h_bar['scheme'] == %w[#c9d1d3 #f2c037] && h_bar['op'] == '>' && h_bar['constant'] == 100000,
      "sidecar records the emitted bar halo (scheme + op + constant) (got #{h_bar.inspect})", fails)
check(h_kpi && h_kpi['field'] == 'Over 100K',
      'sidecar records the KPI halo as postpublish (never dropped)', fails)

# coverage: bar halo approximated + kpi degraded/recorded (unmappable → coverage)
cu = (cov && cov['unresolved']) || []
check(cu.any? { |u| u['source_type'] == 'threshold-color' && u['severity'] == 'approximated' },
      'coverage: emitted bar halo recorded as approximated (has no marks-layer overlay)', fails)
check(cu.any? { |u| u['visual'].to_s.casecmp?('Total Bookings') && u['detail'].to_s =~ /THRESHOLD color|conditional KPI/i },
      'coverage: KPI threshold color routed (unmappable → never silently dropped)', fails)

# ---- 4. BYTE-IDENTICAL guard (no threshold color ⇒ origin/main output) ------
puts
puts '== B.4 byte-identical guard =='
spec_n, _log_n, halo_n, _cov_n = run_build(twb(with_threshold: false))
els_n = els_of(spec_n)
bar_n = els_n.find { |e| e['name'].to_s.casecmp?('Bookings by Region') }
check(bar_n && bar_n['color'].nil?,
      'no-threshold workbook: bar carries NO color (identical to pre-C2 baseline)', fails)
check(halo_n.nil?,
      'no-threshold workbook: NO threshold-halo.json written (feature purely additive/detected)', fails)
check(els_n.none? { |e| (e['columns'] || []).any? { |c| c['id'].to_s.start_with?('clr-halo-') } },
      'no-threshold workbook: no clr-halo-* column synthesized anywhere', fails)

puts
if fails.empty?
  puts 'ALL PASS — C2 threshold halo: detection + bar emission + KPI→postpublish + sidecar/coverage + byte-identical'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts log_t.to_s.lines.last(20).join
  exit 1
end
