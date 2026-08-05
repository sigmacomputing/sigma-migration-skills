#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test: migrate-tableau.rb actually RUNS the typed-literal lint
# after DM spec generation (v5.6-P0.4 / W2.2 wiring — the lint existed since
# v5.5 but was invoked by nothing; audit D4b called it "dead weight").
#
# Locks:
#   1. With a warehouse type source (cols-<TABLE>.json) in the workdir, the
#      wiring builds typed-literal-types.json, runs lint-typed-literals.rb
#      against dm-spec.json, writes typed-literal-findings.json, and WARNs on
#      findings — WITHOUT aborting (advisory; corpus safety).
#   2. Without any type source, the wiring states a SKIP (never a silent no-op).
#   3. A landing manifest aliases each landed table's type map under its
#      sf_table FQN and the original Tableau captions.
#   4. A clean spec reports 0 findings.
#
# The block under test is extracted verbatim from migrate-tableau.rb and eval'd
# in a harness (same pattern as test-calc-gap-classification.rb), so the test
# fails if the wiring is removed or its contract drifts.
#
# Offline, no creds. Usage: ruby scripts/test-typed-literal-wiring.rb

require 'json'
require 'open3'
require 'tmpdir'

SRC = File.join(__dir__, 'migrate-tableau.rb')
src = File.read(SRC, encoding: 'UTF-8')
BLOCK = src[/^  # W2\.2 \/ v5\.6-P0\.4 wiring.*?typed-literal lint wiring failed.*?\n  end$/m]
abort "could not extract the typed-literal wiring block from #{SRC}" unless BLOCK

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

HERE = __dir__
$lines = []
def line(msg)
  $lines << msg.to_s
  puts "   | #{msg}"
end

# migrate-tableau's run! contract: [captured_output, Process::Status];
# allow_fail: true never aborts.
def run!(cmd, allow_fail: false, env: nil)
  out, st = env ? Open3.capture2e(env, *cmd) : Open3.capture2e(*cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success? || allow_fail
  [out, st]
end

def run_block(work, dm_spec_path)
  $lines = []
  # The block references WORK (constant in migrate-tableau) — shadow per run.
  Object.send(:remove_const, :WORK) if Object.const_defined?(:WORK)
  Object.const_set(:WORK, work)
  eval(BLOCK, binding, SRC) # rubocop:disable Security/Eval — trusted first-party source, test-only
end

DIRTY_SPEC = {
  'name' => 'test dm',
  'pages' => [{ 'id' => 'pg1', 'elements' => [
    { 'id' => 'el1', 'name' => 'Orders Fact',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH ORDERS_FACT] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Year Flag', 'formula' => 'If([Year] = "2014", 1, 0)' },
        { 'id' => 'c2', 'name' => 'Region', 'formula' => '[Region]' }
      ] }
  ] }]
}.freeze

COLS_FIXTURE = {
  'connection_id' => 'conn-test', 'path' => %w[DB SCH ORDERS_FACT],
  'columns' => [{ 'name' => 'YEAR', 'type' => 'NUMBER(38,0)' },
                { 'name' => 'REGION', 'type' => 'VARCHAR(64)' }]
}.freeze

puts '-- 1. type source present + dirty spec → findings, WARN, no abort --'
Dir.mktmpdir do |work|
  dm_spec_path = File.join(work, 'dm-spec.json')
  File.write(dm_spec_path, JSON.pretty_generate(DIRTY_SPEC))
  File.write(File.join(work, 'cols-ORDERS_FACT.json'), JSON.pretty_generate(COLS_FIXTURE))
  run_block(work, dm_spec_path)
  fp = File.join(work, 'typed-literal-findings.json')
  check(File.exist?(fp), 'typed-literal-findings.json written')
  findings = (JSON.parse(File.read(fp)) rescue [])
  check(findings.length == 1 && findings[0]['literal'] == '2014',
        'the NUMBER-vs-"2014" comparison is the single finding')
  check($lines.any? { |l| l =~ /WARN: typed-literal lint: 1 finding/ },
        'orchestrator WARNs with the finding count (advisory, not fatal)')
  check(File.exist?(File.join(work, 'typed-literal-types.json')),
        'the derived --types map is persisted for the report')
end

puts '-- 2. no type source → stated SKIP --'
Dir.mktmpdir do |work|
  dm_spec_path = File.join(work, 'dm-spec.json')
  File.write(dm_spec_path, JSON.pretty_generate(DIRTY_SPEC))
  run_block(work, dm_spec_path)
  check($lines.any? { |l| l =~ /typed-literal lint: SKIPPED/ }, 'missing type source is stated, never silent')
  check(!File.exist?(File.join(work, 'typed-literal-findings.json')),
        'no findings file fabricated without a type source')
end

puts '-- 3. landing manifest aliases FQN + original captions --'
Dir.mktmpdir do |work|
  dm_spec_path = File.join(work, 'dm-spec.json')
  File.write(dm_spec_path, JSON.pretty_generate(DIRTY_SPEC))
  File.write(File.join(work, 'cols-ORDERS_FACT.json'), JSON.pretty_generate(COLS_FIXTURE))
  File.write(File.join(work, 'landing-manifest.json'), JSON.pretty_generate(
               [{ 'slug' => 'wb', 'datasource' => 'ds', 'caption' => 'Extract',
                  'hyper' => 'x.hyper', 'hyper_table' => 'Extract',
                  'sf_table' => 'DB.SCH.ORDERS_FACT', 'rows' => 10,
                  'columns' => { 'Fiscal Year' => 'YEAR', 'Sales Region' => 'REGION' } }]
             ))
  run_block(work, dm_spec_path)
  tm = JSON.parse(File.read(File.join(work, 'typed-literal-types.json')))
  check(tm['DB.SCH.ORDERS_FACT'].is_a?(Hash), 'sf_table FQN bucket present in the types map')
  check(tm['DB.SCH.ORDERS_FACT']['Fiscal Year'] == 'NUMBER(38,0)',
        'original Tableau caption aliased onto the landed column type')
end

puts '-- 4. clean spec → 0 findings --'
Dir.mktmpdir do |work|
  clean = JSON.parse(JSON.generate(DIRTY_SPEC))
  clean['pages'][0]['elements'][0]['columns'][0]['formula'] = 'If([Year] = 2014, 1, 0)'
  dm_spec_path = File.join(work, 'dm-spec.json')
  File.write(dm_spec_path, JSON.pretty_generate(clean))
  File.write(File.join(work, 'cols-ORDERS_FACT.json'), JSON.pretty_generate(COLS_FIXTURE))
  run_block(work, dm_spec_path)
  check($lines.any? { |l| l =~ /typed-literal lint: clean \(0 findings/ }, 'clean spec reported clean')
  findings = (JSON.parse(File.read(File.join(work, 'typed-literal-findings.json'))) rescue nil)
  check(findings == [], 'findings file written empty (also when clean)')
end

puts
if $fails.empty?
  puts 'ALL PASS — typed-literal lint wiring (migrate-tableau → lint-typed-literals.rb)'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
