#!/usr/bin/env ruby
# Schema-coverage ratchet against the OFFICIAL vendored .twb grammar
# (schemas/twb_2026.2.0.xsd — see schemas/PROVENANCE.md).
#
# The skill's design-parity surface was reverse-engineered until Tableau
# published its document schemas (Feb 2026). This test pins the contract:
#   A. Every StyleAttribute-ST value is CLASSIFIED — either parsed at zone
#      scope by parse-twb-layout.rb (ZONE_PARSED) or explicitly known as
#      worksheet/mark/axis-scope surface consumed by the style-rules /
#      chart-translation passes (WORKSHEET_SCOPE snapshot). A future schema
#      refresh that introduces a NEW attribute fails here — Tableau adding
#      design surface becomes a test failure, not a silent parity gap
#      (the FCP-normalization lesson: native rounded corners shipped in
#      2026.1 and stayed invisible to this skill for a full release cycle).
#   B. Every ZONE_PARSED attribute literally appears in parse-twb-layout.rb,
#      so this list can't rot ahead of the parser.
#   C. The vendored XSD is intact (element sanity + the rounded-corner
#      surface present) and both parse entry points run behind
#      lib/fcp_normalize.rb (the schema models only canonical names).
#
# Usage:  ruby scripts/test-schema-coverage.rb

XSD    = File.join(__dir__, '..', 'schemas', 'twb_2026.2.0.xsd')
PARSER = File.join(__dir__, 'parse-twb-layout.rb')

# Zone-scope attributes parse-twb-layout.rb extracts (zone_style_fields +
# zone_text_fields). Add here ONLY together with parser support (check B).
ZONE_PARSED = %w[
  background-color background-transparency
  border-color border-style border-width
  border-color-top border-color-right border-color-bottom border-color-left
  border-style-top border-style-right border-style-bottom border-style-left
  border-width-top border-width-right border-width-bottom border-width-left
  corner-radius corner-radius-top-left corner-radius-top-right
  corner-radius-bottom-left corner-radius-bottom-right rounding
  margin margin-top margin-right margin-bottom margin-left
  padding padding-top padding-right padding-bottom padding-left
  text-align
].freeze

# Worksheet/mark/axis/map-scope surface (style-rules inside a worksheet's
# <style>, not dashboard zone chrome). Consumed by the chart-translation +
# theme passes or classified named-residue there. Snapshot of the 2026.2
# enum at vendor time — a refresh that ADDS values fails check A below.
WORKSHEET_SCOPE = %w[
  alt-mark-color alternate-text animation-duration animation-on animation-style aspect
  auto-subtitle band-color band-level band-size body-type boxplot-style
  break-on-special cell cell-h cell-q cell-qmark cell-w
  col-height col-horiz-height col-levels col-vert-height col-vert-levels col-width
  color color-mode content density-color density-intensity density-kernel-size
  density-max-value display display-alternate-text display-field-labels div-level enabled
  fill-above fill-below fill-color fog-bg-color fog-desaturation-with-selection fog-desaturation-without-selection
  font-family font-size font-style font-weight geo-area-type halign
  halo-color halo-color-selected has-fill has-halo has-label has-stroke
  height height-header highlight-legend hnaxis hnlabel in-tooltip
  line-end line-end-size line-interpolation line-marker-position line-pattern line-pattern-only
  line-visibility map map-snap-zoom map-style mark-color mark-labels-cull
  mark-labels-line-first mark-labels-line-last mark-labels-mode mark-labels-range-field mark-labels-range-max mark-labels-range-min
  mark-labels-range-scope mark-labels-show mark-line-pattern mark-markers-mode mark-transparency max-font-size
  max-stroke-width maxheight maxwidth middle-stroke-width min-font-size min-length
  min-map-size min-size min-stroke-width minheight minwidth nonhighlight-color
  omit-on-special opacity orientation palette render-fold-reversed reverse-palette
  row-horiz-levels row-horiz-width row-levels row-vert-width separator shape
  show-labels show-null-value-warning size size-bar smart-auto-align space
  stroke-color stroke-size subtitle text-align-default text-decoration text-format
  text-indent text-orientation tick-color tick-length tick-spacing title
  total-label valign vertical-align vertical-align-default vnaxis vnlabel
  washout whisker-end whisker-stroke-color whisker-stroke-size width width-header
  wrap zoom
].freeze

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'Part 0 — vendored schema integrity'
check(File.exist?(XSD), 'schemas/twb_2026.2.0.xsd is vendored', fails)
abort('FATAL: vendored XSD missing — see schemas/PROVENANCE.md') unless File.exist?(XSD)
xsd = File.read(XSD)
check(xsd.include?('name="StyleAttribute-ST"'), 'XSD carries the StyleAttribute-ST enum', fails)
check(xsd.include?('"corner-radius"'), 'rounded-corner surface present (2026.1+ feature)', fails)
check(xsd.include?('<xs:element name="zone"') || xsd.include?('name="zone"'),
      'zone element modeled', fails)

enum_block = xsd[/name="StyleAttribute-ST".*?<\/xs:simpleType>/m].to_s
enum = enum_block.scan(/enumeration value="([^"]+)"/).flatten.sort
check(enum.size >= 170, "enum extraction sane (#{enum.size} values, expected ~174)", fails)

puts
puts 'Part A — every enum value is classified (the ratchet)'
overlap = ZONE_PARSED & WORKSHEET_SCOPE
check(overlap.empty?, "classification lists are disjoint#{overlap.empty? ? '' : ": #{overlap.join(', ')}"}", fails)
unknown = enum - ZONE_PARSED - WORKSHEET_SCOPE
check(unknown.empty?,
      unknown.empty? ? 'no unclassified style attributes' :
        "NEW/unclassified style attribute(s) — Tableau added design surface, classify them: #{unknown.join(', ')}",
      fails)
stale = (ZONE_PARSED + WORKSHEET_SCOPE) - enum
# Removed-from-schema values are informational, not fatal (older workbooks
# still carry them and the parser must keep reading them).
puts "  NOTE  #{stale.size} classified value(s) not in this schema version (kept for old workbooks): #{stale.join(', ')}" unless stale.empty?

puts
puts 'Part B — ZONE_PARSED list cannot rot ahead of the parser'
parser_src = File.read(PARSER)
# Per-side/regex-parsed families are matched by their regex presence; scalar
# attrs must appear literally.
regex_families = {
  /border-(color|style|width)-(top|right|bottom|left)/ => 'border-(color|style|width)-(top|right|bottom|left)',
  /corner-radius-(top|bottom)-(left|right)/            => 'corner-radius-(top|bottom)-(left|right)',
  /\Amargin(-top|-right|-bottom|-left)?\z/              => 'margin(-top|-right|-bottom|-left)',
  /\Apadding(-top|-right|-bottom|-left)?\z/             => 'padding(-top|-right|-bottom|-left)'
}
missing = ZONE_PARSED.reject do |attr|
  next true if parser_src.include?("'#{attr}'")
  regex_families.any? { |re, src| attr =~ re && parser_src.include?(src) }
end
check(missing.empty?,
      missing.empty? ? 'every ZONE_PARSED attr is handled in parse-twb-layout.rb' :
        "ZONE_PARSED attr(s) not found in parser: #{missing.join(', ')}",
      fails)

puts
puts 'Part C — FCP normalization guards both parse entry points'
%w[parse-twb-layout.rb tableau-discover.rb].each do |f|
  src = File.read(File.join(__dir__, f))
  check(src.include?('FcpNormalize') || src.include?('fcp_normalize'),
        "#{f} runs behind lib/fcp_normalize.rb (schema models canonical names only)", fails)
end

if fails.empty?
  puts "OK — schema coverage holds (#{enum.size} style attrs: #{ZONE_PARSED.size} zone-parsed, #{WORKSHEET_SCOPE.size} worksheet-scope)"
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
