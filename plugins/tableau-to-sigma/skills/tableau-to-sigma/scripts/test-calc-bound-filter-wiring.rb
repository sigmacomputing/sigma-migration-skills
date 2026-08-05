#!/usr/bin/env ruby
# Regression test for calc-bound-filter wiring (#259 — the plan-hierarchy miss).
#
# A quick-filter bound to a CALCULATED field arrives with a caption that is
# EITHER the calc's Tableau-internal name (often blend-suffixed, "Calculation_NNN
# 1") or the friendly caption. When that calc is already MATERIALIZED on the
# master, the control must WIRE (matched by the calc's identity) instead of being
# falsely recorded `needs-materialization`. materialized_calc_column bridges both
# directions against columns_by_guid.
#
# Pure-helper extraction harness (same pattern as test-param-measure-picker.rb).
# Genericized fixtures — no customer identifiers.
#
# Usage:  ruby scripts/test-calc-bound-filter-wiring.rb
require 'json'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
%w[map_column materialized_calc_column].each do |fn|
  m = SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

NORM = ->(s) { s.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '') }
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# columns_by_guid: internal calc name → friendly caption (as parse-twb-layout emits).
CBG = {
  'Calculation_10000000000000001' => { 'caption' => '2. Region Group' },
  'Team Bucket'                   => { 'caption' => 'Team Bucket' }
}

# ---- Direction 1: filter caption is the INTERNAL name, blend-suffixed --------
# Master materialized the calc UNDER ITS CAPTION ("2. Region Group") — the
# rename-to-caption case. Filter arrives as "Calculation_NNN 1".
MMAP_CAPTION = { '(?i)^2\. Region Group$' => { 'id' => 'm-rg', 'name' => '2. Region Group' } }
m1 = materialized_calc_column('Calculation_10000000000000001 1', CBG, MMAP_CAPTION, NORM)
check(m1 && m1['id'] == 'm-rg',
      "internal-name (blend-suffixed) filter → resolves to caption, matches materialized column (got #{m1.inspect})", fails)

# same without the blend suffix
m1b = materialized_calc_column('Calculation_10000000000000001', CBG, MMAP_CAPTION, NORM)
check(m1b && m1b['id'] == 'm-rg', 'internal-name (no suffix) filter also resolves', fails)

# ---- Direction 2: filter caption is the CAPTION, calc materialized under raw internal name
MMAP_INTERNAL = { '(?i)^Calculation_10000000000000001$' => { 'id' => 'm-raw', 'name' => 'Calculation_10000000000000001' } }
m2 = materialized_calc_column('2. Region Group', CBG, MMAP_INTERNAL, NORM)
check(m2 && m2['id'] == 'm-raw',
      "caption filter → finds the internal-named materialized column (got #{m2.inspect})", fails)

# ---- Not materialized → nil (genuinely needs materialization) ----------------
check(materialized_calc_column('Calculation_10000000000000001 1', CBG, {}, NORM).nil?,
      'calc absent from master → nil (still needs-materialization)', fails)
check(materialized_calc_column('Unknown Calc', CBG, MMAP_CAPTION, NORM).nil?,
      'caption not in columns_by_guid → nil', fails)

# ---- A plain raw-column filter is unaffected (map_column handles it directly) -
# materialized_calc_column is only a FALLBACK; a raw caption that maps directly
# never reaches it, but if it did it must not misfire.
check(materialized_calc_column('Team Bucket', { 'Team Bucket' => { 'caption' => 'Team Bucket' } },
      { '(?i)^Team Bucket$' => { 'id' => 'm-tb', 'name' => 'Team Bucket' } }, NORM)&.fetch('id') == 'm-tb',
      'caption==internal-name still resolves (no infinite/degenerate skip)', fails)

# ---- degenerate ----
check(materialized_calc_column(nil, CBG, MMAP_CAPTION, NORM).nil?, 'nil caption → nil', fails)
check(materialized_calc_column('x', nil, MMAP_CAPTION, NORM).nil?, 'nil columns_by_guid → nil', fails)

puts
if fails.empty?
  puts 'ALL PASS — calc-bound-filter wiring: identity match (both directions) + blend-suffix strip'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
