#!/usr/bin/env ruby
# Regression test: migrate-tableau.rb's TWO advisory prints of the
# build-postpublish-guide.rb command line must actually wire the ledger join
# — i.e. include --emitted-manifest and point --json-out at the CONTRACTUAL
# <workdir>/action-ledger.json path, not the old postpublish-guide.json.
#
# WHY THIS TEST EXISTS: build-postpublish-guide.rb's ledger join
# (ActionLedger.read_manifest/join) was correctly implemented and covered by
# test-postpublish-guide.rb and test-action-ledger.rb — but migrate-
# tableau.rb (the ONLY orchestrated driver) told the agent/operator to run
# the generator WITHOUT --emitted-manifest at both of its advisory print
# sites. ActionLedger.read_manifest(nil) == [], so omitting the flag makes
# `residue` equal EVERY detected interaction, including ones
# build-charts-from-signals.rb already auto-wired (nav-buttons). The guide
# then re-instructs the customer to hand-wire work that is already done —
# precisely the bug this whole ledger design exists to eliminate. The fix
# was correct in isolation but inert end-to-end until both advisory sites
# were updated. This test catches a regression of that exact shape.
#
# A full `migrate-tableau.rb` run is too heavy for this suite — it requires
# live Sigma + Tableau credentials and drives the entire multi-phase
# conversion pipeline (chart building, DM POST, phase6 parity, etc.) just to
# reach either print site. Per the coordinator's approved fallback, this
# instead asserts on the CONSTRUCTED COMMAND LINE: it extracts each site's
# exact source block (the same Ruby the orchestrator runs, not a hand-typed
# copy) and `eval`s it with a real `WORK` binding and captured stdout, then
# checks the actual printed command text — not merely that a substring
# exists somewhere in the file.
#
# Usage: ruby scripts/test-postpublish-manifest-wiring.rb

require 'stringio'
require 'tmpdir'

DIR    = __dir__
SCRIPT = File.join(DIR, 'migrate-tableau.rb')
SRC    = File.read(SCRIPT, encoding: 'UTF-8')

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Extract the exact source lines from `start_line` (inclusive) to `end_line`
# (inclusive) — both must be present VERBATIM in the file, so this fails
# loudly (not silently no-ops) if the advisory text is ever renamed or moved
# without updating this test.
def extract_block(src, start_line, end_line)
  si = src.index(start_line)
  raise "start anchor not found in migrate-tableau.rb (moved/renamed?): #{start_line.inspect}" unless si
  ei = src.index(end_line, si)
  raise "end anchor not found after start in migrate-tableau.rb (moved/renamed?): #{end_line.inspect}" unless ei
  src[si..(ei + end_line.length - 1)]
end

# Eval the extracted chunk (an assignment + several `puts "...#{WORK...}"`
# lines — no other free variables) with a real WORK binding and capture what
# it actually prints. This runs the REAL interpolation/derivation logic from
# the file, not a re-derivation the test invents independently.
#
# WORK is migrate-tableau.rb's own top-level CONSTANT (not a local var), so
# it must be set via Object.const_set, not binding.local_variable_set.
def render(chunk, work)
  Object.send(:remove_const, :WORK) if Object.const_defined?(:WORK)
  Object.const_set(:WORK, work)
  out = StringIO.new
  orig = $stdout
  begin
    $stdout = out
    eval(chunk) # rubocop:disable Security/Eval -- test-only, source is this repo's own file, not user input
  ensure
    $stdout = orig
  end
  out.string
end

Dir.mktmpdir do |work|
  puts '== Site 1: INTERACTIVITY STOP advisory (gst.exitstatus == 16) =='
  # NOTE: the end-anchor below uses \#{ (escaped), not #{ — this string is
  # itself a Ruby literal that must NOT interpolate here; it needs to match
  # migrate-tableau.rb's own literal source text verbatim (which DOES
  # interpolate, but only when THAT line runs inside `render`, not now).
  chunk1 = extract_block(
    SRC,
    "manifest_path = File.join(WORK, 'chart-specs.json').sub(/\\.json$/, '-actions-emitted.json')",
    "puts \"      --json-out \#{File.join(WORK, 'action-ledger.json')}\""
  )
  cmd1 = render(chunk1, work)
  check(cmd1.include?('--emitted-manifest'),
        "site 1's constructed command line includes --emitted-manifest:\n#{cmd1}")
  check(cmd1[/--json-out\s+(\S+)/, 1].to_s.end_with?('action-ledger.json'),
        "site 1's --json-out ends in action-ledger.json (got #{cmd1[/--json-out\s+(\S+)/, 1].inspect})")
  check(!cmd1.include?('postpublish-guide.json'),
        'site 1 no longer points --json-out at the old, non-contractual postpublish-guide.json')
  m1 = cmd1[/--emitted-manifest\s+(\S+)/, 1]
  check(m1.to_s.end_with?('-actions-emitted.json'),
        "site 1's --emitted-manifest points at a real *-actions-emitted.json sidecar (got #{m1.inspect})")
  check(m1 == File.join(work, 'chart-specs-actions-emitted.json'),
        "site 1's manifest path matches what build-charts-from-signals.rb actually writes for --out chart-specs.json (got #{m1.inspect})")

  puts '== Site 2: end-of-run INTERACTIVITY advisory =='
  chunk2 = extract_block(
    SRC,
    "manifest_path2 = File.join(WORK, 'chart-specs.json').sub(/\\.json$/, '-actions-emitted.json')",
    "puts \"                  --json-out \#{File.join(WORK, 'action-ledger.json')}\""
  )
  cmd2 = render(chunk2, work)
  check(cmd2.include?('--emitted-manifest'),
        "site 2's constructed command line includes --emitted-manifest:\n#{cmd2}")
  check(cmd2[/--json-out\s+(\S+)/, 1].to_s.end_with?('action-ledger.json'),
        "site 2's --json-out ends in action-ledger.json (got #{cmd2[/--json-out\s+(\S+)/, 1].inspect})")
  check(!cmd2.include?('postpublish-guide.json'),
        'site 2 no longer points --json-out at the old, non-contractual postpublish-guide.json')
  m2 = cmd2[/--emitted-manifest\s+(\S+)/, 1]
  check(m2.to_s.end_with?('-actions-emitted.json'),
        "site 2's --emitted-manifest points at a real *-actions-emitted.json sidecar (got #{m2.inspect})")

  check(m1 == m2,
        "both advisory sites derive the IDENTICAL --emitted-manifest path for the same workdir " \
        "(they share one build-charts-from-signals.rb call site) (site1=#{m1.inspect}, site2=#{m2.inspect})")
end

puts ''
if $fails.empty?
  puts 'ALL PASS'
else
  puts "#{$fails.length} FAILURE(S):"
  $fails.each { |f| puts "  - #{f}" }
end
exit($fails.empty? ? 0 : 1)
