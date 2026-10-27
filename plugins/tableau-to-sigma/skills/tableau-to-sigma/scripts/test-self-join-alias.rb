#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Contract test: a join datasource that joins a table to ITSELF under a second
# relation name (Tableau: [Sale Lines] x [Same Day Sales], both SALES_FACT).
#
# WHY: the converter keyed join elements by physical table, so both aliases
# collapsed onto one element and the join became a relationship from that
# element to itself. The DM POST rejects that ("Circular dependency detected
# among: table ..."), stopping the migration before any Sigma object exists.
# A relationship would be wrong even if Sigma accepted it: it is a many-to-one
# lookup returning one arbitrary alias row per key, while Tableau's join fans
# the primary rows out. Live-verified 2026-10-27 on a virtual-connection
# workbook: only a real join element reproduced Tableau's totals and all 25
# per-customer rows of a calc summing both aliases.
#
# Pins (offline, creds-free, synthetic fixture test-fixtures/join-self-alias.twb):
#   1. converter: the alias is its own warehouse element named after its
#      relation; a kind:'join' element joins the two (inner, on both keys)
#      and also inner-joins the Tableau inner-joined dimension; no element
#      carries a relationship to itself.
#   2. converter: calcs over both aliases live on the join element with the
#      alias's "<Col> (<Alias>)" names; dimension columns sit on the dimension
#      element with Tableau's "(TABLE)" caption suffix stripped from the
#      physical name; the derived view builds on the join element and picks
#      up a dim-referencing calc through the relationship.
#   3. join_plan.rb: the self-join is a terminal "emitted-join" ledger entry
#      (gate 16 must not probe an alias of the fact for uniqueness); the
#      dimension join stays a probed federated-join entry.
#   4. mechanical-specs.rb fixup_dm_spec: a phantom base column cascades
#      through the join element and on into the derived view.
#
# Usage: ruby scripts/test-self-join-alias.rb

require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lib/join_plan'
require_relative 'mechanical-specs'

HERE      = File.expand_path(__dir__)
TWB       = File.join(HERE, 'test-fixtures', 'join-self-alias.twb')
CONVERTER = File.join(HERE, '..', 'converter', 'tableau.mjs')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

_o, _e, node_st = Open3.capture3('node', '--version') rescue nil
unless node_st&.success?
  warn '  WARN  node not found on PATH — self-join alias suite SKIPPED.'
  exit 0
end

def convert(twb)
  doc = nil
  Dir.mktmpdir('self-join-alias') do |dir|
    shim = File.join(dir, '_convert.mjs')
    out_path = File.join(dir, 'out.json')
    spec = Gem.win_platform? && CONVERTER.match?(/\A[A-Za-z]:/) ? 'file:///' + CONVERTER.tr('\\', '/') : CONVERTER
    File.write(shim, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { convertTableauToSigma } from #{spec.to_json};
      const out = convertTableauToSigma(readFileSync(#{twb.to_json}, 'utf8'),
        { connectionId: 'test-conn', database: 'DEMO_DB', schema: 'DEMO' });
      writeFileSync(#{out_path.to_json}, JSON.stringify({ model: out.model, warnings: out.warnings || [] }));
    JS
    o, e, st = Open3.capture3('node', shim)
    abort "converter failed:\n#{e}#{o}" unless st.success?
    doc = JSON.parse(File.read(out_path))
  end
  doc
end

doc = convert(TWB)
model = doc['model']
els = model['pages'][0]['elements'].reject { |e| e['kind'] == 'control' }
by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
path_of = ->(e) { Array(e.dig('source', 'path')).last }
disp = ->(c) { c['name'] || c['formula'].to_s[%r{\A\[[^/\]]+/([^\]]+)\]\z}, 1] }

puts 'test-self-join-alias.rb — self-join of a table with its own alias'
puts '1. element shape'
alias_el = els.find { |e| e['name'] == 'Same Day Sales' }
primary  = els.find { |e| path_of.call(e) == 'SALES_FACT' && e != alias_el }
store    = els.find { |e| path_of.call(e) == 'STORE_DIM' }
join_el  = els.find { |e| e.dig('source', 'kind') == 'join' }
check(alias_el && alias_el.dig('source', 'kind') == 'warehouse-table' && path_of.call(alias_el) == 'SALES_FACT',
      'the alias is its own SALES_FACT warehouse element named after its Tableau relation', fails)
check(primary && primary['name'] == 'Sales Fact',
      "the primary SALES_FACT element is named explicitly (got #{primary && primary['name'].inspect})", fails)
check(els.none? { |e| Array(e['relationships']).any? { |r| r['targetElementId'] == e['id'] } },
      'no element carries a relationship to itself (the circular-dependency POST failure)', fails)
check(els.none? { |e| Array(e['relationships']).any? { |r| by_id[r['targetElementId']] == alias_el } },
      'the self-join is not modelled as a relationship to the alias (a lookup would undercount the fan-out)', fails)
joins = Array(join_el && join_el.dig('source', 'joins'))
self_join = joins.find { |j| j.dig('right', 'elementId') == alias_el&.dig('id') }
dim_join  = joins.find { |j| j.dig('right', 'elementId') == store&.dig('id') }
check(join_el && join_el['name'] == 'Sale Lines' && join_el.dig('source', 'primarySource', 'elementId') == primary&.dig('id'),
      "the join element is named after the primary relation and sources the primary element (got #{join_el && join_el['name'].inspect})", fails)
check(self_join && self_join['joinType'] == 'inner' &&
      self_join['columns'] == [{ 'left' => '[Store Key]', 'right' => '[Store Key]' },
                               { 'left' => '[Sale Day Key]', 'right' => '[Sale Day Key]' }],
      "self-join is inner on both Tableau keys (got #{self_join.inspect})", fails)
check(dim_join && dim_join['joinType'] == 'inner' &&
      dim_join['columns'] == [{ 'left' => '[Store Key]', 'right' => '[Store Key (STORE_DIM)]' }],
      "the Tableau inner-joined dimension also filters the join element's rows (got #{dim_join.inspect})", fails)

puts '2. columns, calcs, dimension routing, derived view'
jcols = Array(join_el && join_el['columns'])
paired = jcols.find { |c| c['name'] == 'Paired Amount' }
check(paired && paired['formula'] == 'Zn([Sale Amount]) + Zn([Sale Amount (Same Day Sales)])',
      "the calc over both aliases lives on the join element with alias-suffixed refs (got #{paired.inspect})", fails)
alias_amt = jcols.find { |c| c['name'] == 'Sale Amount (Same Day Sales)' }
check(alias_amt && alias_amt['formula'] == '[Same Day Sales/Sale Amount]',
      "the join element exposes the alias column under Tableau's '<Col> (<Alias>)' name (got #{alias_amt.inspect})", fails)
check(Array(alias_el && alias_el['columns']).map { |c| c['formula'] }.sort ==
        ['[SALES_FACT/Sale Amount]', '[SALES_FACT/Sale Day Key]', '[SALES_FACT/Store Key]'],
      'the alias element reads plain physical SALES_FACT columns (no "(Same Day Sales)" phantoms)', fails)
check(Array(primary && primary['columns']).none? { |c| c['formula'].to_s.include?('(') },
      'the primary element keeps only physical passthroughs (calcs and alias columns moved off it)', fails)
store_formulas = Array(store && store['columns']).map { |c| c['formula'] }
check(store_formulas.sort == ['[STORE_DIM/Store City]', '[STORE_DIM/Store Key]', '[STORE_DIM/Store Name]'],
      "dimension columns sit on the dimension element, '(STORE_DIM)' stripped from the physical name (got #{store_formulas.inspect})", fails)
rel = Array(join_el && join_el['relationships']).find { |r| r['targetElementId'] == store&.dig('id') }
key_tgt = rel && Array(store['columns']).find { |c| c['id'] == rel.dig('keys', 0, 'targetColumnId') }
check(key_tgt && key_tgt['formula'] == '[STORE_DIM/Store Key]' && key_tgt['name'] == 'Store Key (STORE_DIM)',
      'the dimension relationship moved to the join element and keys on the real STORE_KEY column', fails)
view = els.find { |e| e.dig('source', 'elementId') == join_el&.dig('id') }
label = view && Array(view['columns']).find { |c| c['name'] == 'Store Label' }
check(view && view['name'] == 'Sale Lines View' &&
      Array(view['columns']).any? { |c| c['formula'] == '[Sale Lines/Sale Amount (Same Day Sales)]' },
      'the derived view builds on the join element, addressing its columns by name', fails)
check(label && label['formula'] == '[Sale Lines/STORE_DIM/Store Name] & " / " & [Sale Lines/STORE_DIM/Store City]',
      "a dim-referencing calc reaches the view through the relationship (got #{label.inspect})", fails)
check(doc['warnings'].none? { |w| w.start_with?('⚠ Dropped calc') },
      'no calc is dropped as unresolvable', fails)

puts '3. join-plan ledger'
entries = JoinPlan.derive(model, File.read(TWB, encoding: 'UTF-8'), db: 'DEMO_DB', schema: 'DEMO')
self_e = entries.find { |e| e['right'] == 'Same Day Sales' }
dim_e  = entries.find { |e| e['right'].to_s.start_with?('STORE_DIM') }
check(self_e && self_e['kind'] == 'emitted-join' && self_e['status'] == 'emitted' && self_e['join_type'] == 'inner',
      "the self-join is a terminal emitted-join entry (got #{self_e.inspect})", fails)
check(dim_e && dim_e['kind'] == 'federated-join' && dim_e['status'] == 'unprobed',
      "the dimension join is still probed for uniqueness (got #{dim_e.inspect})", fails)

puts '4. phantom cascade through the join element'
cascade = JSON.parse(JSON.generate(model))
real = { 'SALES_FACT' => %w[STORE_KEY SALE_DAY_KEY], 'STORE_DIM' => %w[STORE_KEY STORE_NAME STORE_CITY] }
MechanicalSpecs.fixup_dm_spec(cascade, real)
cels = cascade['pages'][0]['elements']
cjoin = cels.find { |e| e.dig('source', 'kind') == 'join' }
cview = cels.find { |e| e.dig('source', 'elementId') == cjoin&.dig('id') }
check(cjoin && Array(cjoin['columns']).none? { |c| c['formula'] == '[Sales Fact/Sale Amount]' || c['formula'] == '[Same Day Sales/Sale Amount]' },
      'a phantom base column is dropped from the join element too', fails)
check(cview && Array(cview['columns']).none? { |c| %w[[Sale\ Lines/Sale\ Amount] [Sale\ Lines/Sale\ Amount\ (Same\ Day\ Sales)]].include?(c['formula']) },
      'and from the derived view built on it (base -> join -> view)', fails)

puts '5. two aliases of the fact become ONE join element'
# A second alias ("Prior Day Sales") joined to the primary on Store Key: one
# Tableau join of all three relations, so one join element carrying both
# alias joins, every calc, and the dimension relationship.
two = File.read(TWB, encoding: 'UTF-8')
two = two.sub("          <relation join='inner' type='join'>\n            <clause type='join'>\n              <expression op='AND'>",
              "          <relation join='inner' type='join'>\n            <clause type='join'>\n              <expression op='='>\n" \
              "                <expression op='[Sale Lines].[aaaa0001-0000-4000-8000-000000000001]' />\n" \
              "                <expression op='[Prior Day Sales].[aaaa0001-0000-4000-8000-000000000001]' />\n" \
              "              </expression>\n            </clause>\n" \
              "          <relation join='inner' type='join'>\n            <clause type='join'>\n              <expression op='AND'>")
two = two.sub("            <relation connection='publishedConnection.selfjoin01' name='Same Day Sales' table='[00000000-0000-4000-8000-0000000000f1].[SALES_FACT (DEMO.SALES_FACT)]' type='table' />\n          </relation>",
              "            <relation connection='publishedConnection.selfjoin01' name='Same Day Sales' table='[00000000-0000-4000-8000-0000000000f1].[SALES_FACT (DEMO.SALES_FACT)]' type='table' />\n          </relation>\n" \
              "          <relation connection='publishedConnection.selfjoin01' name='Prior Day Sales' table='[00000000-0000-4000-8000-0000000000f1].[SALES_FACT (DEMO.SALES_FACT)]' type='table' />\n          </relation>")
two = two.sub("        </cols>",
              "          <map key='[aaaa0003-0000-4000-8000-000000000003 (Prior Day Sales)]' value='[Prior Day Sales].[aaaa0003-0000-4000-8000-000000000003]' />\n        </cols>")
two = two.sub("      <column caption='Store Key (STORE_DIM)'",
              "      <column caption='Sale Amount (Prior Day Sales)' datatype='real' name='[aaaa0003-0000-4000-8000-000000000003 (Prior Day Sales)]' role='measure' type='quantitative' />\n" \
              "      <column caption='Prior Gap' datatype='real' name='[Calculation_1003]' role='measure' type='quantitative'>\n" \
              "        <calculation class='tableau' formula='ZN([aaaa0003-0000-4000-8000-000000000003]) - ZN([aaaa0003-0000-4000-8000-000000000003 (Prior Day Sales)])' />\n" \
              "      </column>\n      <column caption='Store Key (STORE_DIM)'")
Dir.mktmpdir('self-join-two') do |dir|
  vp = File.join(dir, 'two-aliases.twb')
  File.write(vp, two)
  tdoc = convert(vp)
  tels = tdoc['model']['pages'][0]['elements'].reject { |e| e['kind'] == 'control' }
  tjoins = tels.select { |e| e.dig('source', 'kind') == 'join' }
  tj = tjoins.first
  rights = Array(tj && tj.dig('source', 'joins')).map { |j| tels.find { |e| e['id'] == j.dig('right', 'elementId') }&.dig('name') }
  tnames = Array(tj && tj['columns']).map { |c| c['name'] }
  check(two.include?('Prior Day Sales') && tjoins.size == 1,
        "two aliases of the fact produce ONE join element (got #{tjoins.size})", fails)
  check(rights.include?('Same Day Sales') && rights.include?('Prior Day Sales'),
        "the join element joins both aliases (got #{rights.inspect})", fails)
  check(%w[Paired\ Amount Prior\ Gap Sale\ Amount\ (Prior\ Day\ Sales) Sale\ Amount\ (Same\ Day\ Sales)].all? { |n| tnames.include?(n) },
        "it carries both aliases' columns and the calcs over each (got #{tnames.inspect})", fails)
  check(Array(tj && tj['relationships']).any? { |r| tels.find { |e| e['id'] == r['targetElementId'] }&.dig('source', 'path')&.last == 'STORE_DIM' },
        'the dimension relationship lives on the single join element', fails)
  # Gate 16 honors emitted-join rows only up to the spec's "kind": "join"
  # count; one join element for two aliases must be ONE ledger row.
  tentries = JoinPlan.derive(tdoc['model'], two, db: 'DEMO_DB', schema: 'DEMO')
  emitted_rows = tentries.select { |e| e['kind'] == 'emitted-join' }
  join_occurrences = JSON.generate(tdoc['model']).scan(/"kind":"join"/).size
  check(emitted_rows.size == 1 && emitted_rows.size <= join_occurrences &&
        emitted_rows[0]['aliases'].sort == ['Prior Day Sales', 'Same Day Sales'],
        "one emitted-join ledger row names both aliases, within gate 16's join-count bound (got #{emitted_rows.map { |e| e['aliases'] }.inspect} for #{join_occurrences} join element(s))", fails)
  check(tentries.none? { |e| e['kind'] == 'federated-join' && e['right'].to_s.end_with?('Day Sales') },
        'no alias is left behind as a probed federated-join row', fails)
end

puts ''
if fails.empty?
  puts 'test-self-join-alias.rb: ALL PASS'
  exit 0
else
  puts "test-self-join-alias.rb: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
