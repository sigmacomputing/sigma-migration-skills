#!/usr/bin/env ruby
# Regression test: ROLE-PLAYING DIMENSION copies must stay distinct.
#
# THE BUG (measured on real customer report R2, 2026-07-30): the model imports the SAME
# warehouse table SIX times under different names to get six role-playing date
# dimensions —
#     DATE_DIM Policy Count / Quoted date / prod trans date /
#     submission date / submission eff date / uw quotes
# — each a different column subset of CSA-style DATE_DIM (31/31/35/31/31/30 data columns).
#
# The converter names each emitted element after the WAREHOUSE table, so all six come
# out named "DATE_DIM". migrate-powerbi.rb then did:
#     mkey = cname                                    # the warehouse name
#     mid  = "master-#{SHA1(cname)[0,8]}"
#     masters[mkey] = { ... }                          # <-- OVERWRITES, last wins
#     field_map["#{cname}.#{col}"] = ...               # "DATE_DIM.CALENDAR_DATE"
# so six masters collapsed into one (only the LAST copy's columns survived, and all six
# shared one id), while the report's visuals bind under the PBI name
# ("DATE_DIM submission date.CALENDAR_DATE") — a key that never existed. The
# `physical_to_pbi` alias patch is a 1:1 Hash over a 1:N problem, so five of the six got
# no alias at all. Net effect: dropped columns, and controls silently targeting the
# WRONG date dimension.
#
# Measured facts this fix relies on (verified against R2):
#   * column NAME SETS are unique across the six copies (6 of 6) — column COUNTS are
#     not (only 3 distinct), so counts alone cannot disambiguate.
#   * the converter emits one element per model table IN TABLE ORDER, so position is a
#     valid primary signal, verified by column-set agreement.
#
# Usage:  ruby scripts/test-roleplaying-dims.rb
require 'json'
require_relative 'lib/pbi_master_key'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# --- R2's shape, reduced: 3 PBI tables all sourcing DATE_DIM, distinct column sets ----
def tbl(name, cols)
  m = 'let Source = Snowflake.Databases("h","W"), ' \
      '#"N1" = Source{[Name = "CSA", Kind = "Database"]}[Data], ' \
      '#"N2" = #"N1"{[Name = "TJ", Kind = "Schema"]}[Data], ' \
      '#"N3" = #"N2"{[Name = "DATE_DIM", Kind = "Table"]}[Data] in #"N3"'
  # a non-DATE_DIM table points at its own warehouse table
  m = m.sub('Name = "DATE_DIM"', %(Name = "#{name}")) unless name.start_with?('DATE_DIM')
  { 'name' => name,
    'columns' => cols.map { |c| { 'name' => c, 'sourceColumn' => c } },
    'partitions' => [{ 'name' => name, 'mode' => 'import',
                       'source' => { 'type' => 'm', 'expression' => m } }] }
end

TABLES = [
  tbl('FACT',                     %w[FACT_KEY AMOUNT DATE_KEY]),
  tbl('DATE_DIM submission date', %w[CALENDAR_DATE FISCAL_YEAR SUBMISSION_FLAG]),
  tbl('DATE_DIM quoted date',     %w[CALENDAR_DATE FISCAL_YEAR QUOTED_FLAG]),
  tbl('DATE_DIM uw quotes',       %w[CALENDAR_DATE UW_FLAG])
].freeze

# what the converter emits: one element per table, IN ORDER, each named after the
# warehouse table — so three identical names.
ELEMENTS = [
  { 'id' => 'e0', 'name' => 'FACT', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ FACT] },
    'columns' => [{ 'formula' => '[FACT/Fact Key]' }, { 'formula' => '[FACT/Amount]' }, { 'formula' => '[FACT/Date Key]' }] },
  { 'id' => 'e1', 'name' => 'DATE_DIM', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ DATE_DIM] },
    'columns' => [{ 'formula' => '[DATE_DIM/Calendar Date]' }, { 'formula' => '[DATE_DIM/Fiscal Year]' }, { 'formula' => '[DATE_DIM/Submission Flag]' }] },
  { 'id' => 'e2', 'name' => 'DATE_DIM', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ DATE_DIM] },
    'columns' => [{ 'formula' => '[DATE_DIM/Calendar Date]' }, { 'formula' => '[DATE_DIM/Fiscal Year]' }, { 'formula' => '[DATE_DIM/Quoted Flag]' }] },
  { 'id' => 'e3', 'name' => 'DATE_DIM', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ DATE_DIM] },
    'columns' => [{ 'formula' => '[DATE_DIM/Calendar Date]' }, { 'formula' => '[DATE_DIM/Uw Flag]' }] }
].freeze

puts "\n1. each converter element resolves to its OWN PBI table"
map = PbiMasterKey.table_names(ELEMENTS, TABLES)
check(map[0] == 'FACT', "element 0 -> FACT (got #{map[0].inspect})", fails)
check(map[1] == 'DATE_DIM submission date', "element 1 -> submission date (got #{map[1].inspect})", fails)
check(map[2] == 'DATE_DIM quoted date', "element 2 -> quoted date (got #{map[2].inspect})", fails)
check(map[3] == 'DATE_DIM uw quotes', "element 3 -> uw quotes (got #{map[3].inspect})", fails)
check(map.values.uniq.size == 4, 'all four resolve to DISTINCT PBI tables — no collapse', fails)

puts "\n2. ORDER is authoritative; the column set is a CONFIDENCE signal, not an override"
# This contract was inverted in the first draft: making the column set authoritative
# (requiring the table to COVER the element's columns) measured WORSE than the old
# behaviour on 4 real models — distinct masters fell 18->12 and 21->14, because the
# converter adds columns the TMSL table lacks (time-intel, window helpers) so cover
# failed and elements went unresolved. Order assigns 20/21, 26/28, 11/11, 13/13 on the
# same models and recovers all six DATE_DIM copies by name.
full = PbiMasterKey.pbi_table_for_elements(ELEMENTS, TABLES)
check(full[1]['confidence'] == 1.0,
      "a clean match reports confidence 1.0 (got #{full[1]['confidence'].inspect})", fails)
# an element carrying a column its table does NOT have is still assigned (order wins),
# but its confidence drops so the caller can warn.
extra = ELEMENTS[1].merge('columns' => ELEMENTS[1]['columns'] + [{ 'formula' => '[DATE_DIM/Invented Col]' }])
low = PbiMasterKey.pbi_table_for_elements([ELEMENTS[0], extra], TABLES)
check(low[1]['table'] == 'DATE_DIM submission date',
      'an element with a converter-added column is STILL assigned by order', fails)
check(low[1]['confidence'] < 1.0 && low[1]['confidence'] > 0.5,
      "and its confidence drops below 1.0 (got #{low[1]['confidence'].inspect})", fails)

puts "\n3. master keys and ids are DISTINCT per copy (the collapse)"
keys = map.values.map { |t| PbiMasterKey.master_key(t) }
check(keys.uniq.size == 4, "4 distinct master keys (got #{keys.uniq.size})", fails)
ids = keys.map { |k| PbiMasterKey.master_id(k) }
check(ids.uniq.size == 4, "4 distinct master ids (got #{ids.uniq.size}) — all six shared one before", fails)
check(ids.all? { |i| i.start_with?('master-') }, 'ids keep the master- prefix', fails)

puts "\n4. a single-copy model is UNCHANGED (no regression for the common case)"
one_tbl = [tbl('ORDERS', %w[ORDER_ID AMOUNT])]
one_el  = [{ 'id' => 'z', 'name' => 'ORDERS', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ ORDERS] },
             'columns' => [{ 'formula' => '[ORDERS/Order Id]' }, { 'formula' => '[ORDERS/Amount]' }] }]
m3 = PbiMasterKey.table_names(one_el, one_tbl)
check(m3[0] == 'ORDERS', 'single table resolves to itself', fails)
check(PbiMasterKey.master_key('ORDERS') == 'ORDERS',
      'master_key of a table whose PBI name == warehouse name is that name verbatim', fails)

puts "\n5. physical->PBI is 1:N, not 1:1 (five of six copies got no alias before)"
p2p = PbiMasterKey.physical_to_pbi(TABLES)
check(p2p['datedim'].is_a?(Array), 'the map holds an ARRAY per physical table', fails)
check(p2p['datedim'].sort == ['DATE_DIM quoted date', 'DATE_DIM submission date', 'DATE_DIM uw quotes'],
      "all three DATE_DIM copies are recorded (got #{p2p['datedim'].inspect})", fails)
check(p2p['fact'] == ['FACT'], 'a single-copy table still maps to a one-element array', fails)

puts "\n6. an element the tables cannot explain returns nil, never a wrong guess"
orphan = [{ 'id' => 'o', 'name' => 'MYSTERY', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ MYSTERY] },
            'columns' => [{ 'formula' => '[MYSTERY/Nope]' }] }]
m4 = PbiMasterKey.table_names(orphan, TABLES)
check(m4[0].nil?, "an unmatched element maps to nil (got #{m4[0].inspect}) — caller falls back to the element name", fails)
# a SEVENTH element for a table that only has three copies must also be nil, not a reuse
seventh = ELEMENTS + [ELEMENTS[1].merge('id' => 'e4')]
m5 = PbiMasterKey.table_names(seventh, TABLES)
check(m5[4].nil?, "a copy beyond the table count maps to nil (got #{m5[4].inspect}), never a duplicate claim", fails)

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
