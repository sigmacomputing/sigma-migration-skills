#!/usr/bin/env ruby
# Unit test for lib/format_map.rb (PR-12) — the ONE Tableau→Sigma format
# translator (parse-twb-layout.rb translate_format and
# build-charts-from-signals.rb tableau_format_to_sigma both delegate here).
#
# Covers:
#   1. numbers: percent shorthand + Excel percent masks, currency (decimals,
#      €/£ symbols, locale code C1033), thousands, paren-negative prefix,
#      displayNullAs from a quoted 4th segment.
#   2. scale-comma masks refuse (nil) — the exact-format scaled-column recipe
#      owns them; a bare ',.0f' would be off by 1e3 per trailing comma.
#   3. dates: Tableau tokens → d3-time (%-directives) — Sigma date-time
#      formats are d3-time strings ('%B %-d, %Y').
#   4. THE LITERAL-FORMAT HAZARD: moment-style token strings ("MMM D, YYYY")
#      print LITERALLY in Sigma. The translator must either fully tokenize to
#      %-directives (no bare letter residue) or refuse (nil) — it must NEVER
#      emit a formatString with unmapped letter tokens.
#
# Usage:  ruby scripts/test-format-map.rb
require_relative 'lib/format_map'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

t = ->(s) { FormatMap.translate(s) }
fs = ->(s) { (t.call(s) || {})['formatString'] }

# ---- 1. numbers -------------------------------------------------------------
check(fs.call('p0%')    == ',.0%',  "p0% → ,.0% (got #{fs.call('p0%').inspect})", fails)
check(fs.call('p0.0%')  == ',.1%',  'p0.0% → ,.1%', fails)
check(fs.call('p0.00%') == ',.2%',  'p0.00% → ,.2%', fails)
check(fs.call('#,##0.0%') == ',.1%', 'Excel percent mask #,##0.0% → ,.1%', fails)
check(fs.call('#,##0')  == ',.0f',  '#,##0 → ,.0f', fails)
check(fs.call('0.00')   == ',.2f',  '0.00 → ,.2f', fails)
cur = t.call('$#,##0.00')
check(cur == { 'kind' => 'number', 'formatString' => '$,.2f', 'currencySymbol' => '$' },
      "$#,##0.00 → $,.2f + currencySymbol (got #{cur.inspect})", fails)
eur = t.call('€#,##0')
check(eur && eur['formatString'] == '$,.0f' && eur['currencySymbol'] == '€',
      "€#,##0 → $,.0f + currencySymbol € (got #{eur.inspect})", fails)
loc = t.call('C1033')
check(loc && loc['formatString'] == '$,.0f' && loc['currencySymbol'] == '$',
      'locale code C1033 → $,.0f + $', fails)
check(fs.call('$#,##0;($#,##0)') == '($,.0f',
      "paren-negative segment → leading '(' sign modifier (got #{fs.call('$#,##0;($#,##0)').inspect})", fails)
nul = t.call('#,##0;-#,##0;0;"—"')
check(nul && nul['displayNullAs'] == '—',
      "quoted 4th segment → displayNullAs '—' (got #{nul.inspect})", fails)

# ---- 2. scale-comma masks refuse (recorded, never guessed) ------------------
check(t.call('#,##0,,,B;-#,##0,,,B').nil?,
      'scale+suffix mask (#,##0,,,B) → nil (exact-format scaled-column recipe owns it)', fails)
check(t.call('#,##0,,').nil?,
      'bare trailing scale-commas (#,##0,,) → nil, NOT an unscaled ,.0f', fails)

# ---- 3. dates → d3-time -----------------------------------------------------
check(fs.call('yyyy-MM-dd') == '%Y-%m-%d', 'yyyy-MM-dd → %Y-%m-%d', fails)
check(fs.call('MMM yyyy')   == '%b %Y',    'MMM yyyy → %b %Y', fails)
check(fs.call('mmm yyyy')   == '%b %Y',    'lowercase mmm yyyy → %b %Y', fails)
check(fs.call('yyyy')       == '%Y',       'yyyy → %Y', fails)
check(fs.call('dd/mm/yyyy') == '%d/%m/%Y',
      "dd/mm/yyyy → %d/%m/%Y (mm before an hour token is MONTH — the old fork emitted minute %M; got #{fs.call('dd/mm/yyyy').inspect})", fails)
check(fs.call('HH:mm:ss')   == '%H:%M:%S', 'HH:mm:ss → %H:%M:%S (mm after hour = minute)', fails)
check(fs.call('dddd, MMMM d, yyyy') == '%A, %B %-d, %Y',
      "weekday+long month → %A, %B %-d, %Y (got #{fs.call('dddd, MMMM d, yyyy').inspect})", fails)

# ---- 4. the literal-format hazard ------------------------------------------
# "MMM D, YYYY" (moment style) previously leaked 'YYYY'/'D' literals through
# the gsub chain ('%b D, YYYY'). Contract: fully-mapped d3-time OR nil.
haz = t.call('MMM D, YYYY')
check(haz && haz['formatString'] == '%b %-d, %Y',
      "moment-style 'MMM D, YYYY' fully tokenizes → %b %-d, %Y (got #{haz.inspect})", fails)
check(fs.call('MMMM D, YYYY') == '%B %-d, %Y', 'MMMM D, YYYY → %B %-d, %Y', fails)
# Any translate() output must carry ZERO bare-letter residue outside %-directives.
%w[MMM\ D,\ YYYY yyyy-MM-dd dddd,\ MMMM\ d,\ yyyy HH:mm:ss MMM\ yyyy].each do |s|
  out = t.call(s)
  next unless out && out['kind'] == 'datetime'
  residue = out['formatString'].gsub(/%-?[A-Za-z]/, '')
  check(residue !~ /[A-Za-z]/,
        "no literal letter residue in translated #{s.inspect} (got #{out['formatString'].inspect})", fails)
end
# Unmappable strings refuse — never a literal-printing emission.
check(t.call('MMM Qq, YYYY').nil?, "unmappable token run ('Qq') → nil, never emitted literally", fails)
check(t.call('0.0△').nil?, 'non-format garbage → nil', fails)
check(t.call('').nil? && t.call(nil).nil?, 'empty/nil → nil', fails)

# ---- 5. emitted_records: internal-id ↔ caption bridge -----------------------
# Worksheet per-pill format keys are keyed by the field's INTERNAL id
# (`[usr:Calculation_AOV:qk]`); KPI/measure columns are named by CAPTION
# ("Average Order Value"). The ledger must resolve the id→caption via
# columns_by_guid, else it false-reports a correctly-formatted column 'unmapped'.
kpi_el = {
  'id' => 'el-kpi-aov', '_worksheet' => 'KPI Panel', '_dashboard' => 'Overview',
  'columns' => [{ 'id' => 'k1', 'name' => 'Average Order Value',
                  'format' => { 'kind' => 'number', 'formatString' => '$,.2f', 'currencySymbol' => '$' } }]
}
ws_meta = { 'KPI Panel' => { 'formats' => {
  '[federated.demo].[usr:Calculation_AOV:qk]' => 'n"$"#,##0.00'
} } }
cbg = { 'Calculation_AOV' => { 'caption' => 'Average Order Value' } }

with_bridge = FormatMap.emitted_records([kpi_el], ws_meta, {}, cbg)
rec = with_bridge.first
check(rec && rec['field'] == 'Calculation_AOV' && rec['source_format'] == 'n"$"#,##0.00' &&
      rec['status'] == 'mapped' && rec.dig('emitted_format', 'formatString') == '$,.2f',
      "id→caption bridge: caption-named KPI col maps its internal-id-keyed $ format (got #{rec.inspect})", fails)

# Without the bridge (no columns_by_guid) the internal id cannot reach the
# caption, so the same row falls back to unmapped — this is exactly the
# false-negative the bridge removes.
no_bridge = FormatMap.emitted_records([kpi_el], ws_meta, {})
check(no_bridge.first && no_bridge.first['status'] == 'unmapped',
      'without columns_by_guid the internal-id key cannot match the caption (pre-fix behavior)', fails)

puts
if fails.empty?
  puts 'ALL PASS — FormatMap: numbers, dates→d3-time, literal-format hazard refused'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
