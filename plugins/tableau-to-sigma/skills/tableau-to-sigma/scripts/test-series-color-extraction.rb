#!/usr/bin/env ruby
# Regression test for PR-12 extraction in parse-twb-layout.rb: per-series
# color assignments + per-column default formats.
#
# Tableau serializes an EXPLICIT member→color map on the categorical color
# encoding (worksheet style-rules):
#
#   <encoding attr='color' field='[fed].[none:<tier-guid>:nk]' type='palette'>
#     <map to='#f2c037'><bucket>&quot;Top 500&quot;</bucket></map>
#     <map to='#c9d1d3'><bucket>&quot;Bottom 500&quot;</bucket></map>
#   </encoding>
#
# and a column's default number format as <column default-format='$#,##0.00'>.
# Before PR-12 the member→color BINDING was dropped (only a frequency-ranked
# palette survived) — the field failure was Top/Bottom-500 colors INVERTED on
# a key chart — and default-formats were never read (a KPI printed raw where
# the source shows $-formatted).
#
# Asserts, end-to-end through the ACTUAL parse-twb-layout.rb:
#   1. chart zone carries series_colors verbatim (document order) + the
#      encoded column's resolved caption (series_color_field).
#   2. a ramp encoding (type='custom-interpolated') does NOT produce
#      series_colors (its buckets are breakpoints, not members) — it stays
#      heat_scheme.
#   3. meta sidecar carries column_formats {caption → raw default-format}.
#   4. ThemeDerive orders categoricalScheme ASCENDING BY MEMBER from the
#      explicit map ("Bottom 500" slot first) — the positional contract that
#      kills the inversion class (incl. the pie/donut theme-only path).
#
# Usage:  ruby scripts/test-series-color-extraction.rb
require 'json'
require 'tmpdir'
require_relative 'lib/theme_derive'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='ORDER_FACT' name='federated.fact'>
        <column caption='Net Bookings' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' default-format='$#,##0.00' />
        <column caption='Order Date' name='[c2ec6b07-897e-39ab-9422-aa895d35a627]' datatype='date' role='dimension' type='ordinal' />
        <column caption='Value Tier' name='[a1b2c3d4-1111-2222-3333-444455556666]' datatype='string' role='dimension' type='nominal' />
        <column caption='Return Rate' name='[b2c3d4e5-2222-3333-4444-555566667777]' datatype='real' role='measure' type='quantitative' default-format='p0.0%' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Bookings by Tier'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Net Bookings' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Value Tier' name='[a1b2c3d4-1111-2222-3333-444455556666]' datatype='string' role='dimension' type='nominal' />
              <column-instance column='[a1b2c3d4-1111-2222-3333-444455556666]' derivation='None' name='[none:a1b2c3d4-1111-2222-3333-444455556666:nk]' pivot='key' type='nominal' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <style>
            <style-rule element='mark'>
              <encoding attr='color' field='[federated.fact].[none:a1b2c3d4-1111-2222-3333-444455556666:nk]' type='palette'>
                <map to='#f2c037'><bucket>&quot;Top 500&quot;</bucket></map>
                <map to='#c9d1d3'><bucket>&quot;Bottom 500&quot;</bucket></map>
              </encoding>
            </style-rule>
          </style>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[none:a1b2c3d4-1111-2222-3333-444455556666:nk]</cols>
          <pane>
            <mark class='Bar' />
            <encodings>
              <encoding attr='color' column='[federated.fact].[none:a1b2c3d4-1111-2222-3333-444455556666:nk]' />
            </encodings>
          </pane>
        </table>
      </worksheet>
      <worksheet name='Bookings Heatmap'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Net Bookings' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
            </datasource-dependencies>
          </view>
          <style>
            <style-rule element='mark'>
              <encoding attr='color' field='[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' type='custom-interpolated'>
                <color-palette>
                  <color>#f1f1f1</color>
                  <color>#52baee</color>
                </color-palette>
                <map to='#f1f1f1'><bucket>0.0</bucket></map>
                <map to='#52baee'><bucket>1000.0</bucket></map>
              </encoding>
            </style-rule>
          </style>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols />
          <pane><mark class='Square' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Tiers'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' name='Bookings by Tier' x='0' y='0' w='50000' h='100000' />
            <zone id='3' name='Bookings Heatmap' x='50000' y='0' w='50000' h='100000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

layout = nil
meta = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  layout = JSON.parse(File.read(lay))
  meta   = JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))
end

dash  = (layout || []).find { |x| x['dashboard'] == 'Tiers' }
zones = (dash && dash['zones']) || []
tier  = zones.find { |z| z['caption'] == 'Bookings by Tier' }
heat  = zones.find { |z| z['caption'] == 'Bookings Heatmap' }

# ---- 1. explicit member→color map, verbatim + document order ---------------
sc = tier && tier['series_colors']
check(sc == [{ 'member' => 'Top 500', 'color' => '#f2c037' },
             { 'member' => 'Bottom 500', 'color' => '#c9d1d3' }],
      "series_colors = member→color pairs in .twb document order (got #{sc.inspect})", fails)
check(tier && tier['series_color_field'] == 'Value Tier',
      "series_color_field resolves the encoding GUID → caption (got #{tier && tier['series_color_field'].inspect})", fails)

# ---- 2. ramp encodings are NOT series maps ---------------------------------
check(heat && heat['series_colors'].nil?,
      "interpolated ramp encoding yields NO series_colors (got #{heat && heat['series_colors'].inspect})", fails)
check(heat && heat['heat_scheme'] == %w[#f1f1f1 #52baee],
      "ramp still lands in heat_scheme (got #{heat && heat['heat_scheme'].inspect})", fails)

# ---- 3. per-column default-formats in the meta sidecar ----------------------
cf = (meta || {})['column_formats'] || {}
check(cf['Net Bookings'] == '$#,##0.00',
      "meta column_formats carries the raw default-format (got #{cf['Net Bookings'].inspect})", fails)
check(cf['Return Rate'] == 'p0.0%',
      "percent default-format captured too (got #{cf['Return Rate'].inspect})", fails)

# ---- 4. theme scheme ordered ASCENDING BY MEMBER ----------------------------
theme = ThemeDerive.derive(layout)
check(theme['categoricalScheme'] == %w[#c9d1d3 #f2c037],
      "themeOverrides.categoricalScheme ordered ascending by member — 'Bottom 500' slot first " \
      "(got #{theme['categoricalScheme'].inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — PR-12 extraction: series member→color map + column default-formats'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
