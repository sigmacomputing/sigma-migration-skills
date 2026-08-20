#!/usr/bin/env ruby
# frozen_string_literal: true
# W2.14 — batched validation probes: validate-sigma-formula.rb --batch.
#
# Offline (stubbed Sigma REST — same seam as test-export-cache.rb; every
# request logged so call-count assertions are EXACT). Pins:
#
#   1. N formulas → ONE workbook POST + ONE columns readback + ONE DELETE,
#      whatever N is (10 here; 74 below — the regression-corpus
#      formula_coverage scale). Registry: ONE created + ONE cleaned entry.
#   2. Per-entry verdicts keyed by column id: the one bad formula is named
#      with its error payload; the rest are ok — exit 2 (any formula error).
#   3. All-ok batch → status ok, exit 0.
#   4. REFUSALS (nothing created, log stays empty): --batch with a chart
#      kind (wired-axes singleton rule); --batch plus --formula.
#   5. W2.11 sequencing gate — trip AND no-false-trip: entries carrying
#      "sql" refuse LOUDLY while lib/export_pool.rb lacks ProbeRegistry
#      (registry-in-pool not landed), naming the contract, creating NOTHING;
#      the same batch WITHOUT sql entries sails through (no false trip).
#      The gate reads the lib source, so it auto-opens when lane E lands.
#   6. Singleton path unchanged: one formula still probes 1 POST + 1 GET +
#      1 DELETE with the same registry contract (neighbor no-regression).
#
# Usage: ruby scripts/test-batch-validate.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPTS = __dir__
VALIDATE = File.join(SCRIPTS, 'validate-sigma-formula.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', SCRIPTS)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Stub sigma_rest: logs every request; serves the DM spec, the workbook POST
# (echoing the posted test-element columns into STUB_STATE so the columns
# readback can answer per-column), the columns GET (label containing 'bad'
# → error type), and DELETE.
STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      File.open(ENV['STUB_LOG'], 'a') { |f| f.puts(JSON.generate('m' => method.to_s, 'p' => path)) }
      if method == :get && path.start_with?('/v2/dataModels/')
        return { 'pages' => [{ 'elements' => [{ 'id' => 'dm-el', 'name' => 'Orders',
                                                'columns' => [{ 'name' => 'Net Revenue', 'formula' => '[T/Net Revenue]' }] }] }] }
      end
      if method == :post && path == '/v2/workbooks/spec'
        posted = JSON.parse(body)
        # Workbook code-rep POSTs nest the spec under a top-level `document`
        # key and flatten elements into document.elements (live since
        # 2026-08). Keep the nested-page fallback for older payload fixtures.
        raise Error, 'stub: probe POST body is not `document`-wrapped' unless posted.is_a?(Hash) && posted['document'].is_a?(Hash)
        doc = posted['document']
        elements = doc['elements'] || (doc['pages'] || []).flat_map { |p| p['elements'] || [] }
        test = elements.find { |e| e['id'] == 'el-scout-test' }
        File.write(ENV['STUB_STATE'], JSON.generate((test && test['columns']) || []))
        return { 'workbookId' => 'wb-probe-1' }
      end
      if method == :get && path.end_with?('/elements/el-scout-test/columns')
        cols = JSON.parse(File.read(ENV['STUB_STATE']))
        entries = cols.map do |c|
          t = c['name'].to_s.include?('bad') ? { 'type' => 'error', 'message' => 'unknown function' } : { 'type' => 'number' }
          { 'columnId' => c['id'], 'label' => c['name'], 'formula' => c['formula'], 'type' => t }
        end
        return { 'entries' => entries }
      end
      return {} if method == :delete && path.start_with?('/v2/files/')
      raise Error, "stub: unexpected #{method} #{path}"
    end
    def self.list_entries(path, limit: 1000, http: nil)
      (request(:get, path, http: http) || {})['entries'] || []
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_stubbed(stub_dir, extra_env, *argv)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub' }.merge(extra_env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', VALIDATE, *argv)
end

def read_log(log)
  File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
end

def counts(log)
  rs = read_log(log)
  { post: rs.count { |r| r['m'] == 'post' && r['p'] == '/v2/workbooks/spec' },
    cols: rs.count { |r| r['m'] == 'get' && r['p'].end_with?('/columns') },
    del:  rs.count { |r| r['m'] == 'delete' } }
end

def registry_counts(dir)
  f = File.join(dir, 'probe-artifacts.jsonl')
  rs = File.exist?(f) ? File.readlines(f).map { |l| JSON.parse(l) } : []
  { created: rs.count { |r| r['created_at'] }, cleaned: rs.count { |r| r['deleted_at'] } }
end

Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  log   = File.join(dir, 'stub-log.jsonl')
  state = File.join(dir, 'stub-state.json')
  env   = { 'STUB_LOG' => log, 'STUB_STATE' => state,
            'TABLEAU_TO_SIGMA_HOME' => File.join(dir, 'home') }

  puts '-- batch of 10: ONE POST / ONE readback / ONE DELETE, per-entry verdicts --'
  wd1 = File.join(dir, 'wd1'); Dir.mkdir(wd1)
  batch = (1..9).map { |i| { 'label' => "f#{i}", 'formula' => "Sum([Master/Net Revenue]) + #{i}" } }
  batch << { 'label' => 'bad-one', 'formula' => 'NoSuchFn([Master/Net Revenue])' }
  bf = File.join(dir, 'batch10.json'); File.write(bf, JSON.generate(batch))
  o, _e, s = run_stubbed(stub_dir, env, '--batch', bf, '--data-model-id', 'dm1',
                         '--master-element-id', 'dm-el', '--workdir', wd1)
  res = JSON.parse(o)
  c = counts(log)
  check(s.exitstatus == 2, "exit 2 on any formula error (got #{s.exitstatus})", fails)
  check(c == { post: 1, cols: 1, del: 1 }, "10 formulas = 1 POST + 1 readback + 1 DELETE (got #{c})", fails)
  check(res['mode'] == 'batch' && res['status'] == 'error', 'batch doc says mode=batch status=error', fails)
  check(res['counts'] == { 'total' => 10, 'ok' => 9, 'error' => 1 }, "counts 9 ok / 1 error (got #{res['counts']})", fails)
  bad = res['results'].find { |r| r['label'] == 'bad-one' }
  check(bad && bad['status'] == 'error' && bad['err'].is_a?(Hash), 'the bad formula is NAMED with its error payload', fails)
  check(res['results'].count { |r| r['status'] == 'ok' } == 9, 'the other 9 read back ok', fails)
  check(res['workbook_cleaned'] == true, 'workbook reported cleaned', fails)
  rc = registry_counts(wd1)
  check(rc == { created: 1, cleaned: 1 }, "registry: ONE created + ONE cleaned (got #{rc})", fails)

  puts '-- all-ok batch → status ok, exit 0 --'
  File.write(log, ''); File.write(state, '[]')
  bf2 = File.join(dir, 'batch3.json')
  File.write(bf2, JSON.generate((1..3).map { |i| { 'label' => "g#{i}", 'formula' => "Avg([Master/Net Revenue])" } }))
  o, _e, s = run_stubbed(stub_dir, env, '--batch', bf2, '--data-model-id', 'dm1',
                         '--master-element-id', 'dm-el', '--workdir', wd1)
  res = JSON.parse(o)
  check(s.exitstatus == 0 && res['status'] == 'ok', "all-ok batch exits 0 status ok (got #{s.exitstatus}/#{res['status']})", fails)
  check(res['results'].length == 3 && res['results'].all? { |r| r['status'] == 'ok' }, 'three results back, all ok', fails)

  puts '-- 74-formula batch (formula_coverage scale): still ONE POST --'
  File.write(log, ''); File.write(state, '[]')
  bf3 = File.join(dir, 'batch74.json')
  File.write(bf3, JSON.generate((1..74).map { |i| { 'formula' => "Sum([Master/Net Revenue]) * #{i}" } }))
  o, _e, s = run_stubbed(stub_dir, env, '--batch', bf3, '--data-model-id', 'dm1',
                         '--master-element-id', 'dm-el', '--workdir', wd1)
  res = JSON.parse(o)
  c = counts(log)
  check(s.exitstatus == 0 && res['counts']['total'] == 74, '74 entries validated', fails)
  check(c == { post: 1, cols: 1, del: 1 }, "74 formulas STILL 1 POST + 1 readback + 1 DELETE (got #{c})", fails)

  puts '-- refusals: chart-kind batch / --batch + --formula (nothing created) --'
  File.write(log, '')
  _o, e, s = run_stubbed(stub_dir, env, '--batch', bf2, '--chart-kind', 'bar-chart',
                         '--data-model-id', 'dm1', '--master-element-id', 'dm-el')
  check(s.exitstatus != 0 && e.include?('singleton'), 'chart-kind batch refused, names the singleton rule', fails)
  _o, e, s = run_stubbed(stub_dir, env, '--batch', bf2, '--formula', 'Sum(1)',
                         '--data-model-id', 'dm1', '--master-element-id', 'dm-el')
  check(s.exitstatus != 0 && e.include?('mutually exclusive'), '--batch + --formula refused', fails)
  check(read_log(log).empty?, 'refusals created NOTHING (stub log empty)', fails)

  puts '-- W2.11 gate: sql entries refuse while the pool lacks registry; no false trip without sql --'
  File.write(log, '')
  bf4 = File.join(dir, 'batch-sql.json')
  File.write(bf4, JSON.generate([{ 'formula' => 'Sum([Master/Net Revenue])',
                                   'sql' => 'SELECT 1 AS X', 'sql_columns' => ['X'] }]))
  pool_src = File.read(File.join(SCRIPTS, 'lib', 'export_pool.rb'), encoding: 'UTF-8')
  if pool_src.include?('ProbeRegistry')
    puts '  SKIP  gate-trip pin: lane E W2.11 (registry-in-pool) has LANDED — the gate is open by design; retire this pin'
  else
    _o, e, s = run_stubbed(stub_dir, env, '--batch', bf4, '--data-model-id', 'dm1',
                           '--master-element-id', 'dm-el', '--connection-id', 'conn1')
    check(s.exitstatus != 0 && e.include?('W2.11') && e.include?('registry-in-pool'),
          'sql half refused LOUDLY naming the W2.11 contract', fails)
    check(read_log(log).empty?, 'gate refusal created NOTHING', fails)
  end
  _o, e, s = run_stubbed(stub_dir, env, '--batch', bf4, '--data-model-id', 'dm1',
                         '--master-element-id', 'dm-el')
  check(s.exitstatus != 0 && e.include?('--connection-id'), 'sql entries without --connection-id refused', fails)
  File.write(log, '')
  o, _e, s = run_stubbed(stub_dir, env, '--batch', bf2, '--data-model-id', 'dm1',
                         '--master-element-id', 'dm-el', '--workdir', wd1)
  check(s.exitstatus == 0, 'the same batch WITHOUT sql entries sails through (gate no-false-trip)', fails)

  puts '-- singleton path unchanged (neighbor no-regression) --'
  File.write(log, ''); File.write(state, '[]')
  wd2 = File.join(dir, 'wd2'); Dir.mkdir(wd2)
  o, _e, s = run_stubbed(stub_dir, env, '--formula', 'Sum([Master/Net Revenue])',
                         '--data-model-id', 'dm1', '--master-element-id', 'dm-el', '--workdir', wd2)
  res = JSON.parse(o)
  c = counts(log)
  check(s.exitstatus == 0 && res['status'] == 'ok' && res['mode'].nil?,
        "singleton ok run unchanged (exit #{s.exitstatus})", fails)
  check(c == { post: 1, cols: 1, del: 1 }, "singleton still 1 POST + 1 readback + 1 DELETE (got #{c})", fails)
  check(registry_counts(wd2) == { created: 1, cleaned: 1 }, 'singleton registry contract intact', fails)
end

puts
if fails.empty?
  puts 'test-batch-validate: ALL PASS'
else
  puts "test-batch-validate: #{fails.length} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
