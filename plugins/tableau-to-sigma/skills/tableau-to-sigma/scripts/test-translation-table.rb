#!/usr/bin/env ruby
# frozen_string_literal: true
# test-translation-table.rb — W2.13 acceptance: the ONE generated translation
# table (refs/functions.json + the coverage-manifest.json compat view) cannot
# drift from the code that produces it or from the surfaces it serves.
#
# Legs:
#   1. DETERMINISM / FRESHNESS (needs node): re-run the generator into a
#      scratch dir and byte-diff both artifacts against the committed ones.
#      A converter (bundle) change without a regen fails here — this is the
#      CI-diff discipline. SKIPs with a notice when node is unavailable.
#   2. CATALOG PIN: table rows == live tflex catalog (187), keyed identically;
#      the known TABLEAU_FUNC_MAP-not-in-catalog gap is pinned EXACTLY
#      (HOUR/MINUTE/MOD/SECOND) — growth or shrinkage is new drift and fails.
#   3. WHITELIST PIN: every Sigma function name emitted on a translated row
#      resolves in SigmaFunctions::ALL (validate-spec's whitelist tier and the
#      table read the same truth). Case-insensitive membership is FATAL when
#      absent; exact-case mismatches are pinned as a named list (Ltrim/Rtrim —
#      upstream map casing vs whitelist casing, flagged for live verification,
#      growth fails).
#   4. COMPAT VIEW: coverage-manifest.json is derived from the same rows —
#      same fn set, counts recomputed, old status vocabulary closed.
#   5. API + SPOT PINS: CalcCoverage.translation_index / translated_names
#      serve the table; provably-stale reclassifications stay fixed (ZN spec,
#      SIN spec, WINDOW_CORR chart_only, WINDOW_MEDIAN not_converted, TOTAL
#      not_converted, USERNAME rls).
#
# Offline; ruby 2.6-safe. Run: ruby scripts/test-translation-table.rb
require 'json'
require 'set'
require 'tmpdir'
require 'open3'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'calc_coverage'
require 'sigma_functions'

SKILL_ROOT = File.expand_path('..', __dir__)
TABLE      = File.join(SKILL_ROOT, 'refs', 'functions.json')
MANIFEST   = File.join(SKILL_ROOT, 'refs', 'coverage-manifest.json')
GENERATOR  = File.join(SKILL_ROOT, 'scripts', 'dev', 'gen-translation-table.mjs')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

table    = JSON.parse(File.read(TABLE))
manifest = JSON.parse(File.read(MANIFEST))
rows     = table['functions']

puts '== 1. determinism / freshness (regenerate + byte-diff) =='
# NODE_BIN env wins (dev machines with node outside PATH); PATH otherwise.
node = ENV['NODE_BIN'].to_s.empty? ? `which node 2>/dev/null`.strip : ENV['NODE_BIN']
if node && !node.empty? && File.executable?(node)
  Dir.mktmpdir do |dir|
    out, err, st = Open3.capture3(node, GENERATOR, '--out-dir', dir)
    check(st.success?, "generator runs (#{st.exitstatus})#{st.success? ? '' : " — #{err.lines.first}"}", fails)
    if st.success?
      check(File.read(File.join(dir, 'functions.json')) == File.read(TABLE),
            'refs/functions.json is byte-identical to a fresh regeneration', fails)
      check(File.read(File.join(dir, 'coverage-manifest.json')) == File.read(MANIFEST),
            'refs/coverage-manifest.json is byte-identical to a fresh regeneration', fails)
    end
    _ = out
  end
else
  puts '  SKIP  node unavailable — determinism leg not run (CI runners ship node)'
end

puts '== 2. catalog pin =='
catalog_names = CalcCoverage.catalog_index.keys.to_set
table_names = rows.map { |r| r['tableau_fn'] }.to_set
check(rows.length == CalcCoverage.catalog['functions'].length,
      "one row per catalog function (#{rows.length}/#{CalcCoverage.catalog['functions'].length})", fails)
check(table_names == catalog_names, 'table fn set == catalog fn set', fails)
check(rows.map { |r| r['tableau_fn'] } == rows.map { |r| r['tableau_fn'] }.sort,
      'rows sorted by tableau_fn (determinism)', fails)
known_gap = %w[HOUR MINUTE MOD SECOND]
check(table['_generated']['map_not_in_catalog'] == known_gap,
      "TABLEAU_FUNC_MAP∖catalog gap pinned exactly (#{known_gap.join('/')}) — growth is new drift", fails)

puts '== 3. whitelist pin (same truth as validate-spec whitelist tier) =='
statuses_closed = CalcCoverage::TRANSLATION_STATUSES.to_set
bad_status = rows.reject { |r| statuses_closed.include?(r['status']) }
check(bad_status.empty?, "status vocabulary closed (#{CalcCoverage::TRANSLATION_STATUSES.join('|')})", fails)
by_ci = {}
SigmaFunctions::ALL.each { |n| by_ci[n.downcase] = n }
missing = []
case_mismatch = []
rows.each do |r|
  next unless CalcCoverage::TRANSLATED_STATUSES.include?(r['status'])
  Array(r['sigma_functions']).each do |name|
    canon = by_ci[name.downcase]
    if canon.nil?
      missing << "#{r['tableau_fn']}→#{name}"
    elsif canon != name
      case_mismatch << "#{r['tableau_fn']}→#{name} (whitelist: #{canon})"
    end
  end
end
check(missing.empty?, "every emitted Sigma function exists in SigmaFunctions::ALL#{missing.empty? ? '' : " — MISSING: #{missing.uniq.join(', ')}"}", fails)
pinned_mismatch = ['LTRIM→Ltrim (whitelist: LTrim)', 'RTRIM→Rtrim (whitelist: RTrim)']
check(case_mismatch.uniq.sort == pinned_mismatch.sort,
      "exact-case mismatches pinned to the known pair (Ltrim/Rtrim — verify live, upstream map casing)#{case_mismatch.uniq.sort == pinned_mismatch.sort ? '' : " — got: #{case_mismatch.uniq.join('; ')}"}", fails)

puts '== 4. compat view (coverage-manifest.json derived, counts honest) =='
m_rows = manifest['functions']
check(m_rows.map { |r| r['fn'] }.to_set == table_names, 'manifest fn set == table fn set', fails)
old_vocab = %w[spec verify chart_only reported flagged unmapped].to_set
check(m_rows.all? { |r| old_vocab.include?(r['status']) }, 'manifest status vocabulary closed (old schema)', fails)
recount = Hash.new(0)
m_rows.each { |r| recount[r['status']] += 1 }
check(manifest['counts'] == recount.sort.to_h, 'manifest counts == recomputed from rows', fails)
check(manifest['generated_by'].to_s.include?('gen-translation-table.mjs'),
      'manifest self-identifies as a build artifact', fails)
tcount = Hash.new(0)
rows.each { |r| tcount[r['status']] += 1 }
check(table['counts'] == tcount.sort.to_h, 'table counts == recomputed from rows', fails)

puts '== 5. API + provably-stale spot pins =='
idx = CalcCoverage.translation_index
check(idx.length == rows.length, 'CalcCoverage.translation_index serves the table', fails)
spot = { 'ZN' => 'spec', 'SIN' => 'spec', 'SQUARE' => 'spec', 'WINDOW_CORR' => 'chart_only',
         'WINDOW_MEDIAN' => 'not_converted', 'TOTAL' => 'not_converted', 'USERNAME' => 'rls',
         'DATEPARSE' => 'verify', 'MAKEDATETIME' => 'unmapped' }
spot.each do |fn, want|
  check(idx[fn] && idx[fn]['status'] == want, "#{fn} status == #{want} (got #{idx[fn] && idx[fn]['status']})", fails)
end
translated = CalcCoverage.translated_names
check(translated.include?('ZN') && translated.include?('WINDOW_CORR') && !translated.include?('WINDOW_MEDIAN'),
      'translated_names serves spec+verify+chart_only+rls and excludes refusals', fails)
check(translated == translated.sort && translated.uniq == translated, 'translated_names sorted unique', fails)
cov = CalcCoverage.coverage(['ZN(SUM([x]))', 'WINDOW_MEDIAN(SUM([x]), -3, 0)'], translated: translated)
check(cov[:covered].include?('ZN') && cov[:uncovered].any? { |u| u[:name] == 'WINDOW_MEDIAN' },
      'coverage() with the generated translated set: ZN covered, WINDOW_MEDIAN named residue', fails)

puts
if fails.empty?
  puts 'test-translation-table: ALL PASS'
else
  puts "test-translation-table: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
