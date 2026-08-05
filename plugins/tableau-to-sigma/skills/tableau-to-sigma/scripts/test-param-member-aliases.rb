#!/usr/bin/env ruby
# encoding: utf-8
# Parameter member-alias reconciliation (audit P1.5 / §7.4) — the fixture run
# that CLOSES the flag, plus a lock on the converter-side fix.
#
# The V5.6 controls audit carried a contradiction:
#   [G-V missed 1] "member `alias` attrs are never read by either extractor"
#   [B]            "alias labels applied at build-charts :6256-6291"
# Reconciled truth (both were right, about different .twb shapes):
#   - build-charts-from-signals.rb DOES apply labels, but from
#     parse-twb-layout's <aliases>/<alias> ELEMENT walk (meta.column_aliases).
#   - The <members><member alias='...'> ATTRIBUTE shape was read by neither
#     extractor; converter/tableau.mjs read only @value and shipped raw codes.
# Fix under test: the converter now captures memberAliases {value -> alias}
# and emits them as the manual-list source's labels[] (values stay the codes
# a translated Switch compares against). Residue: parse-twb-layout still
# reads only the <aliases> element shape.
#
# Offline + deterministic; needs `node` (SKIPs when absent, same convention
# as test-converter-fixtures.rb Part A).
#
# Usage:  ruby scripts/test-param-member-aliases.rb
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

FIX = File.join(__dir__, 'test-fixtures', 'param-member-aliases.twb')

if `which node 2>/dev/null`.strip.empty?
  warn 'SKIP  node not on PATH — param member-alias fixtures not run (install node to enable)'
  exit 0
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

script = <<~MJS
  import { convertTableauToSigma } from #{VENDORED_SPEC.to_json};
  import { readFileSync } from 'fs';
  const xml = readFileSync(#{FIX.to_json}, 'utf8');
  const res = convertTableauToSigma(xml, { connectionId: 'CONN' });
  console.log(JSON.stringify(res));
MJS
res = nil
Dir.mktmpdir do |dir|
  p = File.join(dir, 'drive.mjs')
  File.write(p, script)
  out, err, st = Open3.capture3('node', p)
  abort "node driver failed: #{err}" unless st.success?
  res = JSON.parse(out)
end

params = res['parameters'] || []
picker = params.find { |p| p['name'] == 'Metric Picker' }
plain  = params.find { |p| p['name'] == 'Plain Picker' }
check(!picker.nil? && !plain.nil?, 'both parameters captured', fails)
check(picker && picker['memberAliases'] == { '1' => 'Total Revenue', '3' => 'Net Revenue' },
      "member alias ATTRS captured as memberAliases (got #{picker && picker['memberAliases'].inspect})", fails)
check(plain && !plain.key?('memberAliases'), 'alias-less parameter carries no memberAliases key', fails)

controls = elements = res.dig('model', 'pages', 0, 'elements') || []
ctl = controls.find { |e| e['kind'] == 'control' && (e.dig('source', 'values') || []).include?('1') }
plain_ctl = controls.find { |e| e['kind'] == 'control' && (e.dig('source', 'values') || []).include?('East') }
check(!ctl.nil?, 'aliased list parameter emits a list control', fails)
check(ctl && ctl.dig('source', 'values') == %w[1 3 5],
      'control VALUES stay the raw codes (what a translated Switch compares against)', fails)
check(ctl && ctl.dig('source', 'labels') == ['Total Revenue', 'Net Revenue', '5'],
      "aliases surface as labels[] (unaliased member falls back to its code) (got #{ctl && ctl.dig('source', 'labels').inspect})", fails)
check(plain_ctl && !plain_ctl['source'].key?('labels'),
      'no aliases → labels[] omitted entirely (no value-add)', fails)
check(res['warnings'].any? { |w| w.include?('member alias(es) → labels[]') },
      'alias wiring is announced in warnings', fails)

puts
if fails.empty?
  puts 'test-param-member-aliases: ALL PASS'
else
  puts "test-param-member-aliases: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
