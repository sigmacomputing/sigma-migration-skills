#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Contract test: object-graph relationships whose join key Tableau did NOT
# serialize must still be wired, and every derivation must be recorded.
#
# WHY: Tableau AUTO-MATCHES relationships by column name at query time, and can
# serialize a relationship whose key is a computed expression
# (DATE([Order Date]) = [Date Key]). That is how modern star schemas are built,
# so the converter saw a star and emitted disconnected tables — after which a
# parity gate with no relationships to satisfy it pushes the run into joined/
# aggregated Custom SQL. That is the "flattened star schema" a field report
# described.
#
# LIVE-VERIFIED CORRECTION (2026-10-27): Sigma CAN join on a computed
# expression — a relationship keyed on a calculated column
# (DateTrunc("day", [Order Date]) -> DIM_TIME.DATE_KEY) was accepted, read back
# unchanged, and grouped exactly like the hand-written warehouse LEFT JOIN. The
# converter's computed-key rung therefore carries a whitelisted single-column
# endpoint expression (DATE / DATETIME / INT / STR / DATETRUNC / IFNULL) as a
# calculated key column and records derivedVia "computed-key". Only an
# untranslatable expression (or mismatched key types) falls through to
# name-inference / unwired.
#
# LIVE-VERIFIED CORRECTION (2026-08, logical-model-objectgraph fixture): a
# relationship with literally NO <expression> at all — this test's original
# model of "auto-matched, no serialized key" — does not survive a real Tableau
# Server publish (HTTP 400011, "The relationship/expression tag is missing or
# invalid"). Every relationship in genuine Tableau output carries SOME
# expression. The name-inference rung this test exercises is instead reached
# via a relationship whose serialized expression is present but not a usable
# PHYSICAL key (e.g. wrapped in IFNULL/DATETRUNC) — see case 4 (LMOG_DIM_STORE)
# below. Its IFNULL([STORE_KEY],-1) now wires by the computed-key rung, so the
# name-inference rung is exercised on a ZN([STORE_KEY]) variant (ZN is outside
# the computed-key whitelist) — see name_inference_twb below.
#
# Inference is only safe because inferred keys are written into join-plan.json,
# where gate 16's warehouse uniqueness probe validates them before GREEN. A wrong
# inference becomes a fan-out FATAL, not a silently undercounting model.
#
# Creds-free and network-free: runs the vendored converter over a static .twb.
#
# HOW IT DRIVES THE CONVERTER: converter/tableau.mjs is a library module with no
# CLI entry point — `node converter/tableau.mjs <path>` does nothing (no argv
# handling, no stdout). This test instead follows the established pattern in
# scripts/mechanical-specs.rb's run_converter (see :776-810): write a small ESM
# shim into a throwaway temp dir that imports convertTableauToSigma by name,
# calls it, and writes its result to a JSON file this script then reads. The
# `bare = out.model || out.sigmaDataModel || out` idiom is lifted verbatim from
# that production path — it is what actually unwraps the model regardless of
# which key generation the converter returns it under.
#
# Usage: ruby scripts/test-relationship-derivation.rb
# Override the .twb for local sanity-checking the harness itself (never set in
# CI/production): TEST_RELATIONSHIP_DERIVATION_TWB=/path/to.twb ruby ...

require 'json'
require 'open3'
require 'tmpdir'
require 'set'
require 'fileutils'
require_relative 'lib/join_plan'

HERE      = File.expand_path(__dir__)
FIXTURE   = File.expand_path('../../../../../corpus/tableau/logical-model-objectgraph', HERE)
TWB       = File.join(FIXTURE, 'workbook-content.twb')
CONVERTER = File.join(HERE, '..', 'converter', 'tableau.mjs')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Locate the elements array without assuming one fixed nesting depth: today the
# converter returns { model: { pages: [{ elements }] }, ... }, but a bare
# top-level `elements` key is also plausible for a future shape. Rather than
# crash the whole run on a shape change, record it as a diagnosable FAILURE (so
# every other assertion still reports) naming exactly what was found instead.
def locate_elements(model, fails)
  return model['elements'] if model.is_a?(Hash) && model['elements'].is_a?(Array)
  if model.is_a?(Hash) && model['pages'].is_a?(Array) &&
     model['pages'][0].is_a?(Hash) && model['pages'][0]['elements'].is_a?(Array)
    return model['pages'][0]['elements']
  end
  found = model.is_a?(Hash) ? "a Hash with keys #{model.keys.inspect}" : model.class.to_s
  msg = "cannot locate elements array on converter output model " \
        "(checked ['elements'] and ['pages'][0]['elements']; found #{found})"
  check(false, msg, fails)
  []
end

# Same normalization the converter's own candidateNames()/colIdMap keys apply
# (converter/tableau.mjs, PR2a derivation ladder): strip a trailing "(...)"
# annotation a metadata-record caption may carry (e.g. "Order Date (Order
# Date)"), collapse whitespace to underscore, uppercase. Applied identically
# to BOTH sides below (the .twb's declared names and the model's resolved
# display names) so the two are comparable.
def normalize_name(n)
  return nil if n.nil?
  n.to_s.sub(/\s*\([^)]*\)\s*\z/, '').strip.gsub(/\s+/, '_').upcase
end

# Finding 1 (review, 2026-07-30): the anti-fabrication check must NOT compare
# against element.columns, because ensureCol (converter/tableau.mjs) PUSHES
# whatever name it's given into element.columns as its very mechanism for
# supplying a serialized-but-not-yet-materialized physical key — a fabricated
# guess would appear there just as legitimately as a real column and the
# check would always pass. The .twb itself — its <metadata-record> captions
# and <column name="..."> attributes — is what Tableau actually declared; a
# fabricated name cannot appear there. This scans the fixture's raw XML
# (regex, not the full XML parser tableau.mjs uses) for both column-
# declaration shapes the converter's collection-branch column build loop
# reads from (converter/tableau.mjs ~4762-4792): metadata-record class="column"
# blocks (caption / remote-alias / local-name, in that fallback order — same
# as the converter) and plain <column name="..."> attributes (the no-
# metadata-records fallback path).
def declared_twb_column_names(twb_path)
  raw = File.read(twb_path, encoding: 'utf-8')
  names = []
  raw.scan(/<column\b[^>]*\bname=(["'])(.*?)\1/m) { |_, n| names << n }
  raw.scan(/<metadata-record\b[^>]*>.*?<\/metadata-record>/m).each do |block|
    next unless block =~ /\bclass=(["'])column\1/
    cap = block[/<caption>(.*?)<\/caption>/m, 1] ||
          block[/<remote-alias>(.*?)<\/remote-alias>/m, 1] ||
          block[/<local-name>(.*?)<\/local-name>/m, 1]
    names << cap if cap
  end
  names.map { |n| normalize_name(n) }.reject { |n| n.nil? || n.empty? }.to_set
end

def display_name_for(el, col_id)
  col = (el['columns'] || []).find { |c| c['id'] == col_id }
  return nil unless col
  col['name'] || (col['formula'].is_a?(String) && col['formula'][/\/([^\]]+)\]\z/, 1])
end

twb_path = ENV['TEST_RELATIONSHIP_DERIVATION_TWB'] || TWB
abort "fixture missing: #{twb_path}" unless File.exist?(twb_path)

# Run the vendored converter over a .twb and capture model + coverage. Same
# shim mechanics as before, factored out so the deny-list scenarios below can
# convert surgically-modified fixture variants.
def run_converter_capture(twb)
  doc = nil
  Dir.mktmpdir('relationship-derivation') do |dir|
    shim = File.join(dir, '_convert_tableau.mjs')
    out_path = File.join(dir, 'out.json')
    # Node ESM on Windows rejects a bare drive-letter specifier
    # (ERR_UNSUPPORTED_ESM_URL_SCHEME, protocol 'c:') — absolute paths must be
    # file:// URLs there. Same guard as mechanical-specs.rb's run_converter.
    import_specifier =
      if Gem.win_platform? && CONVERTER.match?(/\A[A-Za-z]:/)
        'file:///' + CONVERTER.gsub('\\', '/')
      else
        CONVERTER
      end
    File.write(shim, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { convertTableauToSigma } from #{import_specifier.to_json};
      const xml = readFileSync(#{twb.to_json}, 'utf8');
      const out = convertTableauToSigma(xml, {
        connectionId: 'test-conn', database: 'TESTDB', schema: 'TESTSCHEMA', tableMapping: {},
      });
      const bare = out.model || out.sigmaDataModel || out;
      writeFileSync(#{out_path.to_json}, JSON.stringify({
        model: bare,
        relationshipCoverage: out.relationshipCoverage || null,
        warnings: out.warnings || []
      }, null, 2));
    JS
    o, e, st = Open3.capture3('node', shim)
    warn e unless e.empty?
    abort "converter failed (exit #{st.exitstatus}):\n#{e}#{o}" unless st.success?
    doc = JSON.parse(File.read(out_path))
  end
  doc
end

doc = run_converter_capture(twb_path)

# The name-inference rung needs a computed-only key the computed-key rung
# cannot carry. ZN() is outside its whitelist, so this variant keeps the
# fixture's STORE pair on the inference path.
def name_inference_twb(raw)
  raw.sub('IFNULL([STORE_KEY],-1)', 'ZN([STORE_KEY])')
end
NI_TWB_DIR = Dir.mktmpdir('relationship-derivation-ni')
at_exit { FileUtils.rm_rf(NI_TWB_DIR) }
ni_twb_path = File.join(NI_TWB_DIR, 'name-inference.twb')
File.write(ni_twb_path, name_inference_twb(File.read(twb_path, encoding: 'utf-8')))
ni_doc = run_converter_capture(ni_twb_path)

puts 'test-relationship-derivation.rb — object-graph key derivation'

cov = doc['relationshipCoverage'] || {}
check(cov['serialized'].to_i == 5,
      "coverage reports all 5 serialized relationships (got #{cov['serialized'].inspect})", fails)
entries = cov['entries'] || []
by_target = entries.each_with_object({}) { |e, h| h[e['right']] = e }
# The plain-physical-key, mixed-key, computed-key (IFNULL), and 5th (new,
# plain physical) relationships MUST wire. The computed-only/
# no-shared-name one may legitimately stay unwired under the conservative rule
# (no key-shaped name match) — what matters is that it is RECORDED, never
# silently absent.
check(cov['wired'].to_i >= 4,
      "at least the plain-physical-key, mixed-key, computed-key, and 5th relationships " \
      "are WIRED (got #{cov['wired'].inspect}) — fewer means the star still becomes disconnected tables", fails)
check(entries.length == 5,
      "all 5 relationships appear in the ledger, wired or not (got #{entries.length})", fails)

entries = cov['entries'] || []
by_target = entries.each_with_object({}) { |e, h| h[e['right']] = e }

# 1. PLAIN PHYSICAL KEY (CUSTOMER_KEY = CUSTOMER_KEY). LIVE-VERIFIED CORRECTION
#    (see header note above): this fixture originally modeled this
#    relationship with NO serialized expression at all ("auto-matched, no
#    serialized key"), to exercise name-inference on a relationship Tableau
#    itself never wrote a key for. Publishing that shape to real Tableau
#    Server 400s — every relationship needs an expression — so this case is
#    now a plain serialized physical key instead. It still proves the
#    baseline "serialized physical key wires cleanly" rung; name-inference is
#    now exercised solely by case 4 (LMOG_DIM_STORE) below.
cust = by_target['LMOG_DIM_CUSTOMER'] || {}
check(cust['derivedVia'] == 'serialized',
      "plain-physical-key LMOG_FACT_WIDE->LMOG_DIM_CUSTOMER is derived as serialized (got #{cust['derivedVia'].inspect})",
      fails)
check(cust['partial'] != true, 'plain-physical-key relationship is not marked partial', fails)

# 2. MIXED keys: physical subset wired, computed condition recorded as dropped.
prod = by_target['LMOG_DIM_PRODUCT'] || {}
check(prod['derivedVia'] == 'serialized',
      "mixed-key LMOG_FACT_WIDE->LMOG_DIM_PRODUCT keeps its serialized physical key (got #{prod['derivedVia'].inspect})",
      fails)
check(prod['partial'] == true && prod['droppedConditions'].to_i >= 1,
      'mixed-key relationship is marked partial with a dropped-condition count', fails)
# Its computed half (DATETRUNC('month',[ORDER_TS]) = [EFFECTIVE_MONTH]) is
# translatable, but EFFECTIVE_MONTH is a string: a date key cannot equal a
# string key in Sigma, so the computed-key rung must refuse it, by name.
check((doc['warnings'] || []).any? { |w| w.include?('LMOG_DIM_PRODUCT') && w.include?('key types differ (date vs string)') },
      'mixed-key: the date-vs-string computed condition is refused with a named type reason', fails)

# 3. COMPUTED-ONLY key, inference fails (no shared key-shaped name): no physical
#    column to join on, so inference by name is the only route. Whatever the
#    outcome, it must be RECORDED, never silently absent.
date = by_target['LMOG_DIM_DATE'] || {}
check(!date.empty?, 'computed-key LMOG_FACT_WIDE->LMOG_DIM_DATE appears in the coverage ledger', fails)
check(%w[serialized computed-key name-inference unwired].include?(date['derivedVia']),
      "computed-key relationship records a known derivedVia (got #{date['derivedVia'].inspect})", fails)
# DATETRUNC('day',[ORDER_TS]) is translatable but CALENDAR_KEY is an integer:
# a date-vs-number key is refused, and with no shared key-shaped name the edge
# stays unwired under its existing reason.
check(date['derivedVia'] == 'unwired' && date['reason'] == 'no existing column name matches on both sides',
      "date-vs-number computed key stays unwired with its existing reason (got #{date.inspect})", fails)

# 4. COMPUTED KEY (IFNULL([STORE_KEY],-1) = [STORE_KEY]): the computed-key
#    rung carries the IFNULL as a calculated key column on the fact, so the
#    relationship wires with Tableau's full condition — no dropped condition,
#    not partial.
store = by_target['LMOG_DIM_STORE'] || {}
check(store['derivedVia'] == 'computed-key',
      "IFNULL-keyed LMOG_FACT_WIDE->LMOG_DIM_STORE is derived as computed-key (got #{store['derivedVia'].inspect})",
      fails)
check(store['partial'] != true && store['droppedConditions'].nil? && store['keyCount'] == 1,
      "computed-key relationship carries its whole condition: not partial, one key (got #{store.inspect})", fails)

# 4b. COMPUTED-ONLY key the computed-key rung cannot carry (ZN variant),
#    inference SUCCEEDS (review fix-wave, 2026-07-30, Important finding 2):
#    no physical pair survives, but STORE_KEY is a shared key-shaped column
#    name on both sides, so name-inference wires it. The ledger entry must say
#    the computed condition was dropped (a WIDER-than-Tableau join).
ni_store = ((ni_doc['relationshipCoverage'] || {})['entries'] || []).find { |e| e['right'] == 'LMOG_DIM_STORE' } || {}
check(ni_store['derivedVia'] == 'name-inference',
      "computed-only-but-name-matched LMOG_FACT_WIDE->LMOG_DIM_STORE is derived by name-inference " \
      "(got #{ni_store['derivedVia'].inspect})", fails)
check(ni_store['partial'] == true && ni_store['droppedConditions'].to_i >= 1,
      'computed-only-but-name-inferred relationship is marked partial with a dropped-condition count ' \
      '(a wider-than-Tableau join must never look clean)', fails)
check((ni_doc['warnings'] || []).any? { |w| w.include?('ZN([STORE_KEY])') && w.include?('not a whitelisted single-column expression') },
      'an untranslatable endpoint names why the computed-key rung refused it', fails)

# 5. NEW (live-fixture addition, orthogonal to the derivation ladder): a plain
#    serialized physical equality key with no complexity at all. Exists to
#    exercise gate 16's join-cardinality probe live (LMOG_DIM_REGION is
#    deliberately non-unique on REGION_KEY in the live warehouse fixture —
#    see MANIFEST.md's live validation section) — the offline converter
#    check here only proves the key wires; the non-uniqueness itself is a
#    live-warehouse-only behavior no offline check can exercise.
region = by_target['LMOG_DIM_REGION'] || {}
check(region['derivedVia'] == 'serialized',
      "plain-physical-key LMOG_FACT_WIDE->LMOG_DIM_REGION is derived as serialized (got #{region['derivedVia'].inspect})",
      fails)
check(region['partial'] != true, 'plain-physical-key LMOG_FACT_WIDE->LMOG_DIM_REGION relationship is not marked partial', fails)

# 5. Every wired relationship's keys must trace back to a column NAME the
#    .twb itself declared — not merely one present in element.columns, which
#    ensureCol will happily contain a fabricated name in (see
#    declared_twb_column_names above). This is the actual anti-fabrication
#    check; an inferred key resolving to a name absent from the .twb source
#    of truth is a fabrication regardless of what element.columns says.
declared_names = declared_twb_column_names(twb_path)
els = locate_elements(doc['model'] || {}, fails)
by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
bad = []
els.each do |el|
  (el['relationships'] || []).each do |rel|
    tgt = by_id[rel['targetElementId']]
    (rel['keys'] || []).each do |k|
      src_name = normalize_name(display_name_for(el, k['sourceColumnId']))
      tgt_name = tgt && normalize_name(display_name_for(tgt, k['targetColumnId']))
      ok = src_name && declared_names.include?(src_name) &&
           tgt_name && declared_names.include?(tgt_name)
      bad << "#{el['id']}->#{rel['targetElementId']} (src=#{src_name.inspect}, tgt=#{tgt_name.inspect})" unless ok
    end
  end
end
check(bad.empty?,
      "every wired key's column name is DECLARED in the .twb itself, not merely present in " \
      "element.columns post-ensureCol (offenders: #{bad.uniq.join(', ')})",
      fails)

# 6. The ledger gate 16 probes must carry the derivation, so an INFERRED key is
#    proven against the warehouse rather than trusted. This is the entire safety
#    argument for inference.
src = File.read(File.join(HERE, 'lib', 'join_plan.rb'))
check(src.include?('derived_via'),
      'join_plan.rb records derived_via on each entry so gate 16 probes inferred keys', fails)
check(src.include?('partial'),
      'join_plan.rb records partial for a mixed-key relationship (a wider join than Tableau\'s)',
      fails)

# 7. BEHAVIORAL pin (not a source grep): JoinPlan.derive must actually RECOVER
#    the name-inferred LMOG_FACT_WIDE->LMOG_DIM_STORE relationship (ZN
#    variant) — the .twb's sole serialized condition for it (ZN([STORE_KEY]) = [STORE_KEY]) is
#    computed, not a bare physical key, so this only passes if join_plan.rb
#    reads the converter's dm-spec relationships (dm_object_graph_index), not
#    merely if it mentions the string "derived_via" somewhere. This is the
#    check that pins the recovery branch AND the dm-spec/.twb name-matching
#    together. (Pinned against LMOG_DIM_STORE, not LMOG_DIM_CUSTOMER, per the
#    header's live-verified correction: LMOG_DIM_CUSTOMER now carries a plain
#    serialized physical key, so it is derived as "serialized", not
#    "name-inference" — LMOG_DIM_STORE is this fixture's only remaining
#    name-inference case.)
jp_entries = JoinPlan.derive(ni_doc['model'], File.read(ni_twb_path, encoding: 'UTF-8'))
store_jp = jp_entries.find { |e| e['left'] == 'LMOG_FACT_WIDE' && e['right'] == 'LMOG_DIM_STORE' }
check(!store_jp.nil?,
      'JoinPlan.derive recovers a join-plan.json entry for the name-inferred LMOG_FACT_WIDE->LMOG_DIM_STORE ' \
      'relationship (absent before this task — nothing for gate 16 to probe)', fails)
check(store_jp && store_jp['derived_via'] == 'name-inference',
      "recovered entry's derived_via is name-inference (got #{(store_jp || {})['derived_via'].inspect})", fails)
check(store_jp && store_jp['probe_keys'] == ['STORE_KEY'],
      "recovered entry's probe_keys resolve to the physical inferred key (got #{(store_jp || {})['probe_keys'].inspect})",
      fails)
# The computed-key edge reaches gate 16 too: its target key is physical, so it
# is probed like any other, and it is NOT partial.
ck_jp = JoinPlan.derive(doc['model'], File.read(twb_path, encoding: 'UTF-8'))
          .find { |e| e['left'] == 'LMOG_FACT_WIDE' && e['right'] == 'LMOG_DIM_STORE' }
check(ck_jp && ck_jp['derived_via'] == 'computed-key' && ck_jp['probe_keys'] == ['STORE_KEY'] && ck_jp['partial'].nil?,
      "computed-key edge lands on join-plan.json as computed-key, probed on STORE_KEY, not partial (got #{ck_jp.inspect})",
      fails)

# 8. COMPOSITION (an internal integration branch merge of #569 + W2-OM): the derivation
#    ladder decides WHICH keys wire; the object-model passes decide HOW edges
#    attach (evidence-ranked fact election, pass-2 orientation). These are two
#    independently-authored rewrites of the same loop, so pin their composed
#    behavior at the ELEMENT level, not just in the coverage ledger:
#      - the name-INFERRED edge must ride pass 2 like a serialized one and
#        attach to the ELECTED fact (a doc-order attachment, or an inference
#        rung that bypasses orientation, both fail here);
#      - derivedVia and the partial/droppedConditions census must SURVIVE
#        pass-2 attachment onto the relationship object itself.
#    Table/relationship names below are this fixture's real LMOG_-prefixed
#    ones (see the header's live-verified correction), and the name-inference
#    edge checked is LMOG_DIM_STORE (this fixture's sole name-inference case
#    now — LMOG_DIM_CUSTOMER moved to a plain serialized key; see case 1's
#    comment above).
fact_el = els.find { |e| ((e['source'] || {})['path'] || []).last == 'LMOG_FACT_WIDE' }
check(!fact_el.nil?, 'composition: LMOG_FACT_WIDE element located by warehouse source path', fails)
rels_on_fact = fact_el ? (fact_el['relationships'] || []) : []
ck_rel = rels_on_fact.find { |r| r['name'] == 'LMOG_DIM_STORE' }
ck_col = fact_el && (fact_el['columns'] || []).find { |c| c['id'] == ck_rel&.dig('keys', 0, 'sourceColumnId') }
check(ck_rel && ck_rel['derivedVia'] == 'computed-key' && ck_rel['partial'].nil?,
      "composition: computed-key derivedVia survives pass-2 attachment (got #{(ck_rel || {}).inspect})", fails)
check(ck_col && ck_col['name'] == 'Store Key (join key)' && ck_col['formula'] == 'Coalesce([Store Key], -1)',
      "composition: the computed key is a named calc column on the fact (got #{ck_col.inspect})", fails)
ni_els = locate_elements(ni_doc['model'] || {}, fails)
ni_fact = ni_els.find { |e| ((e['source'] || {})['path'] || []).last == 'LMOG_FACT_WIDE' }
ni_rels_on_fact = ni_fact ? (ni_fact['relationships'] || []) : []
store_pass2_rel = ni_rels_on_fact.find { |r| r['name'] == 'LMOG_DIM_STORE' }
check(!store_pass2_rel.nil?,
      'composition: the name-inferred LMOG_DIM_STORE edge attaches to the ELECTED fact via pass-2 ' \
      'orientation (not first-end-point document order)', fails)
check(store_pass2_rel && store_pass2_rel['derivedVia'] == 'name-inference',
      "composition: derivedVia survives pass-2 attachment on the element relationship " \
      "(got #{(store_pass2_rel || {})['derivedVia'].inspect})", fails)
check(store_pass2_rel && store_pass2_rel['partial'] == true && store_pass2_rel['droppedConditions'].to_i >= 1,
      'composition: partial/droppedConditions survive pass-2 attachment (wider-than-Tableau join ' \
      'stays visible on the wired relationship object)', fails)
check(!rels_on_fact.empty? && rels_on_fact.all? { |r| %w[serialized computed-key name-inference].include?(r['derivedVia']) },
      'composition: every relationship attached in pass 2 carries a known derivedVia', fails)
check((doc['warnings'] || []).any? { |w| w.include?('fact election') && w.include?('"LMOG_FACT_WIDE"') },
      'composition: evidence-ranked fact election ran and announced LMOG_FACT_WIDE', fails)

# ── deny-list: unique-on-right NON-keys never inferred as join keys ─────────
# TJ handoff §3+§6d (disclosed residual hole): EXTERNAL_ID / ROW_ID / GUID /
# HASH_KEY are key-shaped by suffix and often unique on the right — but they
# are lineage/tech columns, not the relationship key. Gate 16's probe proves
# UNIQUENESS, not CORRECTNESS, so a wired one silently returns wrong rows.
# Two directions pinned on surgically-modified fixture variants:
#   (a) deny blocks the wrong wire: the ONLY shared key-shaped name on the
#       store pair (the fixture's sole name-inference case) is EXTERNAL_ID →
#       unwired, reason names the deny-list;
#   (b) deny rescues a right wire: EXTERNAL_ID beside the genuine STORE_KEY
#       previously made 2 key-shaped candidates (ambiguous → refuse); denied
#       from candidacy, the genuine key wires alone.
puts ''
puts 'deny-list: unique-on-right non-keys'
raw_twb = name_inference_twb(File.read(TWB, encoding: 'utf-8'))

Dir.mktmpdir('deny-a') do |dir|
  variant = raw_twb.gsub('store_key', 'external_id').gsub('Store Key', 'External Id')
  vp = File.join(dir, 'variant-a.twb')
  File.write(vp, variant)
  vdoc = run_converter_capture(vp)
  vcust = ((vdoc['relationshipCoverage'] || {})['entries'] || []).find { |e| e['right'] == 'LMOG_DIM_STORE' } || {}
  check(vcust['derivedVia'] == 'unwired',
        "sole shared key-shaped name EXTERNAL_ID → unwired, never guessed (got #{vcust['derivedVia'].inspect})", fails)
  check(vcust['reason'].to_s =~ /deny/i && vcust['reason'].to_s.include?('EXTERNAL_ID'),
        "unwired reason names the deny-list and the denied column (got #{vcust['reason'].inspect})", fails)
end

Dir.mktmpdir('deny-b') do |dir|
  # Twin every customer_key metadata-record (both parents) as external_id, so
  # BOTH sides share customer_key AND external_id.
  variant = raw_twb.gsub(/<metadata-record class='column'>\s*<remote-name>store_key<\/remote-name>.*?<\/metadata-record>/m) do |block|
    block + "\n" + block.gsub('store_key', 'external_id').gsub('Store Key', 'External Id')
  end
  vp = File.join(dir, 'variant-b.twb')
  File.write(vp, variant)
  vdoc = run_converter_capture(vp)
  vcust = ((vdoc['relationshipCoverage'] || {})['entries'] || []).find { |e| e['right'] == 'LMOG_DIM_STORE' } || {}
  check(vcust['derivedVia'] == 'name-inference',
        "genuine STORE_KEY beside denied EXTERNAL_ID still wires (no false ambiguity; got #{vcust['derivedVia'].inspect})", fails)
end

puts ''
puts 'normalized-name collision: never trust the last colIdMap write'
Dir.mktmpdir('collision') do |dir|
  # Add a second, distinct FACT column whose display name normalizes to the
  # same STORE_KEY inference key ("Store  Key" -> STORE_KEY). The converter's
  # legacy colIdMap assignment kept only the last writer and could wire a real
  # but wrong column id with no signal.
  variant = raw_twb.sub(
    /<metadata-record class='column'>\s*<remote-name>store_key<\/remote-name>.*?<parent-name>\[LMOG_FACT_WIDE\]<\/parent-name>.*?<\/metadata-record>/m
  ) do |block|
    shadow = block.gsub('store_key', 'store_key_shadow').gsub('Store Key', 'Store  Key')
    block + "\n" + shadow
  end
  vp = File.join(dir, 'variant-collision.twb')
  File.write(vp, variant)
  vdoc = run_converter_capture(vp)
  vstore = ((vdoc['relationshipCoverage'] || {})['entries'] || [])
           .find { |e| e['right'] == 'LMOG_DIM_STORE' } || {}
  check(vstore['derivedVia'] == 'unwired',
        "normalized STORE_KEY collision leaves the relationship unwired (got #{vstore['derivedVia'].inspect})", fails)
  check(Array(vstore['collisions']).include?('STORE_KEY') &&
        vstore['reason'].to_s.include?('normalized column name collision'),
        "coverage names STORE_KEY collision and the refusal reason (got #{vstore.inspect})", fails)
end

puts ''
puts 'computed-key: mixed physical + carried computed condition is NOT partial'
Dir.mktmpdir('computed-mixed') do |dir|
  # STR(integer) = string is type-compatible, so the product pair's computed
  # half is carried instead of dropped: two keys, nothing dropped.
  variant = File.read(TWB, encoding: 'utf-8').sub('DATETRUNC(&apos;month&apos;,[ORDER_TS])', 'STR([PRODUCT_KEY])')
  vp = File.join(dir, 'variant-mixed.twb')
  File.write(vp, variant)
  vdoc = run_converter_capture(vp)
  vprod = ((vdoc['relationshipCoverage'] || {})['entries'] || []).find { |e| e['right'] == 'LMOG_DIM_PRODUCT' } || {}
  check(vprod['derivedVia'] == 'computed-key' && vprod['keyCount'] == 2 && vprod['partial'].nil?,
        "physical + carried computed condition: computed-key, 2 keys, not partial (got #{vprod.inspect})", fails)
  vjp = JoinPlan.derive(vdoc['model'], variant).find { |e| e['right'] == 'LMOG_DIM_PRODUCT' }
  check(vjp && vjp['partial'].nil? && vjp['probe_keys'] == %w[PRODUCT_KEY EFFECTIVE_MONTH],
        "join-plan.json probes both target keys and does not count the carried condition as dropped (got #{vjp.inspect})",
        fails)
end

puts ''
puts 'computed-key: a refusal in the serialized operand order still tries the swapped order'
Dir.mktmpdir('computed-swap') do |dir|
  # The serialized order puts STR() on the dimension, whose CUSTOMER_KEY is a
  # string here: integer fact key vs STR(string) is a type mismatch. Swapped,
  # STR() lands on the fact's integer key and equals the dimension's string
  # key, which is the reading that types.
  variant = File.read(TWB, encoding: 'utf-8')
  variant = variant.sub(%r{(<remote-name>customer_key</remote-name>(?:(?!</metadata-record>).)*?<parent-name>\[LMOG_DIM_CUSTOMER\]</parent-name>(?:(?!</metadata-record>).)*?<local-type>)integer(</local-type>)}m, '\\1string\\2')
  variant = variant.sub("<expression op='[CUSTOMER_KEY]' />\n              <expression op='[CUSTOMER_KEY]' />",
                        "<expression op='[CUSTOMER_KEY]' />\n              <expression op='STR([CUSTOMER_KEY])' />")
  vp = File.join(dir, 'variant-swap.twb')
  File.write(vp, variant)
  vdoc = run_converter_capture(vp)
  vcust = ((vdoc['relationshipCoverage'] || {})['entries'] || []).find { |e| e['right'] == 'LMOG_DIM_CUSTOMER' } || {}
  vfact = locate_elements(vdoc['model'] || {}, fails).find { |e| ((e['source'] || {})['path'] || []).last == 'LMOG_FACT_WIDE' }
  vrel = vfact && (vfact['relationships'] || []).find { |r| r['name'] == 'LMOG_DIM_CUSTOMER' }
  vkey = vrel && vfact['columns'].find { |c| c['id'] == vrel.dig('keys', 0, 'sourceColumnId') }
  check(variant.include?("STR([CUSTOMER_KEY])") && vcust['derivedVia'] == 'computed-key' && vcust['partial'].nil?,
        "swapped operand order wires the computed key instead of falling to name inference (got #{vcust.inspect})", fails)
  check(vkey && vkey['formula'] == 'Text([Customer Key])',
        "STR() is carried on the fact's integer key, the side where it types (got #{vkey.inspect})", fails)
end

# ── computed-key over a virtual-connection GUID-only date (field shape) ─────
# The 2026-10-27 field case: a published/virtual connection serializes
# DATE([<guid>]) = [<dim guid>], where <guid> is a date-parse-format re-typed
# column whose metadata-record carries no caption (only the datasource-level
# <column caption=...> does). The converter cannot see its warehouse column,
# so it places the same-caption placeholder ([SALES_FACT/Sale Date]) on the
# OWNING table only, keys a calc column on it, and the skill's GUID-backed
# date recovery later replaces the placeholder with the warehouse formula.
puts ''
puts 'computed-key: virtual-connection GUID-only date endpoint'
VC_TWB = File.join(HERE, 'test-fixtures', 'vc-computed-join-key.twb')
vc_raw = File.read(VC_TWB, encoding: 'utf-8')
vc = run_converter_capture(VC_TWB)
vc_entry = ((vc['relationshipCoverage'] || {})['entries'] || []).first || {}
check(vc_entry['derivedVia'] == 'computed-key' && vc_entry['keyCount'] == 1 && vc_entry['partial'].nil?,
      "DATE([guid-only date]) = [dim date] wires as computed-key (got #{vc_entry.inspect})", fails)
vc_els = locate_elements(vc['model'] || {}, fails)
vc_fact = vc_els.find { |e| ((e['source'] || {})['path'] || []).last == 'SALES_FACT' }
vc_cal = vc_els.find { |e| ((e['source'] || {})['path'] || []).last == 'CALENDAR' }
vc_rel = vc_fact && (vc_fact['relationships'] || []).first
vc_cols = vc_fact ? vc_fact['columns'] : []
placeholder = vc_cols.find { |c| c['name'] == 'Sale Date' }
key_col = vc_cols.find { |c| c['id'] == vc_rel&.dig('keys', 0, 'sourceColumnId') }
check(placeholder && placeholder['formula'] == '[SALES_FACT/Sale Date]',
      "the GUID-only column gets the same-caption placeholder on its owning table (got #{placeholder.inspect})", fails)
check(key_col && key_col['name'] == 'Sale Date (join key)' && key_col['formula'] == 'DateTrunc("day", [Sale Date])',
      "relationship keys on DateTrunc(\"day\", [Sale Date]) named 'Sale Date (join key)' (got #{key_col.inspect})", fails)
check(vc_rel && vc_cal && vc_rel['targetElementId'] == vc_cal['id'] && vc_rel['derivedVia'] == 'computed-key',
      'the relationship targets CALENDAR and carries derivedVia computed-key', fails)
check(vc_cal && (vc_cal['columns'] || []).none? { |c| c['name'].to_s.include?('join key') },
      'no key column is fabricated on the other end-point', fails)

# Hand-off: the skill's GUID-backed date recovery replaces the placeholder in
# place, so the calc key resolves against the warehouse formula.
require_relative 'mechanical-specs'
recovery = MechanicalSpecs.recover_guid_backed_date_fields!(
  vc['model'], vc_raw, { 'SALES_FACT' => %w[SALE_ID NET_AMOUNT SALE_DATE_KEY] },
  { 'SALES_FACT' => [{ 'name' => 'SALE_ID', 'type' => 'TEXT' }, { 'name' => 'NET_AMOUNT', 'type' => 'NUMBER' },
                     { 'name' => 'SALE_DATE_KEY', 'type' => 'NUMBER' }] }
)
recovered = vc_fact && vc_fact['columns'].find { |c| c['id'] == placeholder&.dig('id') }
check(recovery[:recovered] == 1 && recovered && recovered['formula'].start_with?('Date(Left(Text([Sale Date Key])'),
      "GUID-backed date recovery rewrites the placeholder in place from SALE_DATE_KEY (got #{recovered.inspect})", fails)
check(vc_fact && vc_fact['columns'].count { |c| c['name'] == 'Sale Date' } == 1,
      'recovery does not add a second Sale Date column beside the placeholder', fails)

Dir.mktmpdir('computed-vc') do |dir|
  # The GUID-only record claims the OTHER table: no structural ownership on
  # the fact, so nothing is placed there and the edge stays unwired.
  wrong_owner = vc_raw.sub(%r{(<remote-name>11111111-1111-4111-8111-111111111111</remote-name>.*?)<parent-name>\[SALES_FACT \(DEMO\.SALES_FACT\)\]</parent-name>(.*?)<object-id>\[SALES_FACT \(DEMO\.SALES_FACT\)_AAAA1111BBBB2222CCCC3333DDDD4444\]</object-id>}m) do
    "#{Regexp.last_match(1)}<parent-name>[CALENDAR (DEMO.CALENDAR)]</parent-name>#{Regexp.last_match(2)}" \
      '<object-id>[CALENDAR (DEMO.CALENDAR)_EEEE5555FFFF6666AAAA7777BBBB8888]</object-id>'
  end
  vp = File.join(dir, 'wrong-owner.twb')
  File.write(vp, wrong_owner)
  wdoc = run_converter_capture(vp)
  went = ((wdoc['relationshipCoverage'] || {})['entries'] || []).first || {}
  wfact = locate_elements(wdoc['model'] || {}, fails).find { |e| ((e['source'] || {})['path'] || []).last == 'SALES_FACT' }
  check(went['derivedVia'] == 'unwired' && went['reason'] == 'no existing column name matches on both sides',
        "a GUID-only column owned by the other table is never placed on this one: unwired (got #{went.inspect})", fails)
  check(wfact && (wfact['columns'] || []).none? { |c| c['name'].to_s.start_with?('Sale Date') },
        'no placeholder or key column is left behind by a refused computed key', fails)

  week = vc_raw.sub('DATE([11111111-1111-4111-8111-111111111111])',
                    'DATETRUNC(&apos;week&apos;,[11111111-1111-4111-8111-111111111111])')
  vp = File.join(dir, 'week.twb')
  File.write(vp, week)
  kdoc = run_converter_capture(vp)
  kent = ((kdoc['relationshipCoverage'] || {})['entries'] || []).first || {}
  check(kent['derivedVia'] == 'unwired',
        "DATETRUNC('week') is refused (start-of-week is data-source dependent) (got #{kent.inspect})", fails)
  check((kdoc['warnings'] || []).any? { |w| w.include?("DATETRUNC('week') depends on the data source's start-of-week") },
        'the week refusal is named in the warnings', fails)
end

puts ''
if fails.empty?
  puts 'test-relationship-derivation.rb: ALL PASS'
  exit 0
else
  puts "test-relationship-derivation.rb: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
