#!/usr/bin/env ruby
# encoding: utf-8
# Federated-join cross-table coalesce synthesis (calc-flex item 1, field S9).
#
# WHY: a Tableau federated JOIN serializes the secondary table's duplicate
# fields as "[X (TABLE_B)]" and the canonical null-fallback calcs as
# IFNULL / ZN / IF-ISNULL chains across the two tables. Sigma ground truth
# (refs/data-model-spec.md): a bare cross-element ref in a DM calc column
# compiles but returns NULL on every row — the correct form is
#   Coalesce([local X], Lookup([Target/X], [local key], [Target/key]))
# and Sigma's Lookup takes ONE key pair, so multi-key joins need a
# Text()-wrapped composite key column synthesized on BOTH elements. A field
# run hand-built exactly this over ~55 min; the converter now emits it.
#
# Fixtures (synthetic, invented names):
#   test-fixtures/join-coalesce.twb          single-key join, all three shapes
#   test-fixtures/join-coalesce-multikey.twb AND-wrapped 2-key join
#
# Offline + deterministic; needs `node` (SKIPs with a warning when absent,
# same convention as test-converter-fixtures.rb Part A).
#
# Usage:  ruby scripts/test-join-coalesce-synthesis.rb
require 'json'
require 'open3'
require 'tmpdir'

VENDORED = File.expand_path('../converter/tableau.mjs', __dir__)
# Node ESM on Windows rejects a bare drive-letter specifier
# (ERR_UNSUPPORTED_ESM_URL_SCHEME) — absolute paths must be file:// URLs there
# (same idiom as test-converter-fixtures.rb / mechanical-specs.rb run_converter).
VENDORED_SPEC =
  if Gem.win_platform? && VENDORED.to_s.match?(/\A[A-Za-z]:/)
    'file:///' + VENDORED.gsub('\\', '/')
  else
    VENDORED
  end

FIX1 = File.join(__dir__, 'test-fixtures', 'join-coalesce.twb')
FIX2 = File.join(__dir__, 'test-fixtures', 'join-coalesce-multikey.twb')

if `which node 2>/dev/null`.strip.empty?
  warn 'SKIP  node not on PATH — join-coalesce synthesis fixtures not run (install node to enable)'
  exit 0
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def convert(twb_path)
  script = <<~MJS
    import { convertTableauToSigma } from #{VENDORED_SPEC.to_json};
    import { readFileSync } from 'fs';
    const xml = readFileSync(#{twb_path.to_json}, 'utf8');
    const res = convertTableauToSigma(xml, { connectionId: 'CONN', database: 'ANALYTICS', schema: 'PUBLIC' });
    console.log(JSON.stringify(res));
  MJS
  Dir.mktmpdir do |dir|
    p = File.join(dir, 'drive.mjs')
    File.write(p, script)
    out, err, st = Open3.capture3('node', p)
    abort "node driver failed for #{twb_path}: #{err}" unless st.success?
    return JSON.parse(out)
  end
end

def elements_of(res)
  res.dig('model', 'pages', 0, 'elements') || []
end

def col(el, name)
  (el['columns'] || []).find { |c| c['name'] == name }
end

puts "== single-key join (#{File.basename(FIX1)}) =="
res = convert(FIX1)
els = elements_of(res)
fact = els.find { |e| (e['relationships'] || []).any? }
tgt  = els.find { |e| e['id'] != fact['id'] && e.dig('source', 'kind') == 'warehouse-table' }
check(!fact.nil?, 'primary (relationship-bearing) element exists', fails)
check(tgt && tgt['name'] == 'Rev Contra', "target element carries the display name refs use (got #{tgt && tgt['name'].inspect})", fails)
check(fact['relationships'][0]['keys'].size == 1, 'single-key relationship wired with 1 key pair', fails)

c = col(fact, 'Unified Region')
check(!c.nil?, 'IFNULL cross-table calc survives as a fact calc column', fails)
check(c && c['formula'] == 'Coalesce([Region], Lookup([Rev Contra/Region], [Entity Id], [Rev Contra/Entity Id]))',
      "IFNULL(primary, secondary) → Coalesce(local, Lookup(...)) (got #{c && c['formula']})", fails)

c = col(fact, 'Contra Amount Zn')
check(c && c['formula'] == 'Coalesce(Lookup([Rev Contra/Contra Amt], [Entity Id], [Rev Contra/Entity Id]), 0)',
      "ZN(secondary ref) → Coalesce(Lookup(...), 0) (got #{c && c['formula']})", fails)

c = col(fact, 'Unified Entity Group')
check(c && c['formula'] == 'Coalesce([Entity Group], Lookup([Rev Contra/Entity Group], [Entity Id], [Rev Contra/Entity Id]))',
      'IF ISNULL(a) THEN b ELSE a END → Coalesce(a, Lookup(b...))', fails)

c = col(fact, 'Local Fallback')
check(c && c['formula'] == 'Coalesce([Channel], [Backup Channel])',
      'local-only IFNULL stays a plain local Coalesce (correct display casing)', fails)

c = col(fact, 'Unified Channel')
check(c && c['formula'] == 'Coalesce([Channel], Lookup([Rev Contra/Channel], [Entity Id], [Rev Contra/Entity Id]), [Backup Channel])',
      'chained IFNULL flattens into one ordered Coalesce', fails)

check(res['warnings'].count { |w| w.include?('federated-join coalesce') } == 5,
      '5 synthesis warnings (one per calc)', fails)
check(res['warnings'].none? { |w| w =~ /Dropped calc "Unified/ },
      'synthesized calcs are NOT dropped by the unresolvable-ref pass (nameless base columns count by formula-tail label)', fails)

puts "\n== multi-key join (#{File.basename(FIX2)}) =="
res2 = convert(FIX2)
els2 = elements_of(res2)
fact2 = els2.find { |e| (e['relationships'] || []).any? }
tgt2  = els2.find { |e| e['id'] != fact2['id'] && e.dig('source', 'kind') == 'warehouse-table' }
check(!fact2.nil?, 'AND-wrapped 2-key join wires a relationship at all (previously dropped)', fails)
check(fact2 && fact2['relationships'][0]['keys'].size == 2, 'relationship carries BOTH key pairs', fails)

kf = col(fact2, 'Daily Contra Join Key')
kt = tgt2 && col(tgt2, 'Daily Contra Join Key')
expect_key = 'Text([Entity Id]) & "|" & Text([Activity Date])'
check(kf && kf['formula'] == expect_key, "composite key on primary is Text()-wrapped (got #{kf && kf['formula']})", fails)
check(kt && kt['formula'] == expect_key, 'composite key mirrored on the target element', fails)
check(fact2 && (fact2['order'] || []).include?(kf && kf['id']), 'primary composite key is in order[]', fails)

c = col(fact2, 'Merged Segment')
check(c && c['formula'] == 'Coalesce([Segment], Lookup([Daily Contra/Segment], [Daily Contra Join Key], [Daily Contra/Daily Contra Join Key]))',
      'multi-key IFNULL → Lookup over the synthesized composite key', fails)
check(res2['warnings'].any? { |w| w.include?('Synthesized composite join key') },
      'composite-key synthesis is announced', fails)

puts
if fails.empty?
  puts 'test-join-coalesce-synthesis: ALL PASS'
else
  puts "test-join-coalesce-synthesis: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
