#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression tests for the #7 dedup work (speed review, reconciled program):
#
#   ExportPool::Cache — the RAW export cache shared by verify-anchors.rb and
#     collect-parity-actuals.rb, keyed strictly
#     (workbookId, latestDocumentVersion, elementId, format, rowLimit).
#     Every cache path carries the ratified trio of tests:
#       * HIT          — an unchanged workbook re-run makes ZERO export calls;
#       * INVALIDATION — a bumped latestDocumentVersion forces re-export;
#       * NEVER-VERDICT-REUSE — the cache holds raw wire bytes only, and
#         verdicts are recomputed from them on every run (a changed anchor set
#         changes the verdict over the SAME cached payloads, with no wire I/O).
#   collect-parity-actuals.rb — readback version probe (#7b): a stale
#     wb-readback.json is named LOUDLY and disables the cache.
#   ExportPool.pooled_sql_probe (#7c) — one probe workbook, one SQL element
#     per entry, pooled exports, ONE delete (~4T REST calls → T+2).
#
# The Sigma REST layer is stubbed (no network); every request is logged so the
# call-count assertions are exact. Usage:  ruby scripts/test-export-cache.rb
require 'json'
require 'csv'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'

SCRIPTS = __dir__
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', SCRIPTS)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Stub sigma_rest (same seam as test-bounded-exports.rb): loaded FIRST via
# `ruby -I <stub> -r sigma_rest`; the real lib path is then marked required so
# the scripts' own `require 'sigma_rest'` no-ops. Logs EVERY request to
# STUB_LOG as {"m":method,"p":path}. STUB_SPEC serves both the live /spec GET
# and the probe workbook POST reply.
STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      File.open(ENV['STUB_LOG'], 'a') { |f| f.puts(JSON.generate('m' => method.to_s, 'p' => path)) }
      return File.read(ENV['STUB_SPEC']) if method == :get && path.end_with?('/spec')
      if method == :post && path.include?('/export')
        req = JSON.parse(body)
        return { 'queryId' => req['elementId'] }
      end
      if method == :get && path.start_with?('/v2/query/')
        case path.split('/')[3]
        when 'el-anchor' then return "Account,Revenue\nUnited Widgets,12345\nAcme,678\n"
        when 'el-ok'     then return "Region,Revenue\nEast,100\nWest,200\n"
        end
      end
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_stubbed(stub_dir, extra_env, *argv)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub' }.merge(extra_env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', *argv)
end

def read_log(log)
  File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
end

def export_posts(log)
  read_log(log).count { |r| r['m'] == 'post' && r['p'].include?('/export') }
end

def write_spec(path, version)
  elements = [
    { 'id' => 'el-anchor', 'name' => 'Top Accounts', 'kind' => 'table',
      'columns' => [{ 'id' => 'c-a', 'name' => 'Account' }, { 'id' => 'c-v', 'name' => 'Revenue' }] },
    { 'id' => 'el-ok', 'name' => 'Region Chart', 'kind' => 'bar-chart',
      'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v2', 'name' => 'Revenue' }] }
  ]
  File.write(path, JSON.pretty_generate(
               'workbookId' => 'wb', 'latestDocumentVersion' => version,
               'document' => {
                 'schemaVersion' => 4,
                 'kind' => 'workbook',
                 'pages' => [{ 'id' => 'pg1', 'name' => 'Overview' }],
                 'elements' => elements,
                 'layout' => "<Page id=\"pg1\">#{elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
               }))
end

def write_anchors(dir, anchors)
  File.write(File.join(dir, 'source-anchors.json'),
             JSON.pretty_generate('source_image' => 'views/dash.png',
                                  'transcribed_at' => '2026-07-27T00:00:00Z',
                                  'anchors' => anchors))
end

A1 = { 'id' => 'a1', 'panel' => 'TOP', 'label' => 'United Widgets revenue',
       'raw' => '12,345', 'sigma_element_hint' => 'Top Accounts' }.freeze
A2 = { 'id' => 'a2', 'panel' => 'TOP', 'label' => 'phantom total', 'raw' => '99,999' }.freeze
A3 = { 'id' => 'a3', 'panel' => 'TOP', 'label' => 'Acme revenue',
       'raw' => '678', 'sigma_element_hint' => 'Top Accounts' }.freeze

# ============================================================================
# Part 1 — verify-anchors: HIT (re-run against an unchanged workbook exports
# nothing), then NEVER-VERDICT-REUSE (a grown anchor set changes the verdict
# over the SAME cached payloads), then VERSION-INVALIDATION (bump → re-export).
# ============================================================================
puts '-- verify-anchors: cache hit / verdict recomputation / version invalidation --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  spec_path = File.join(dir, 'stub-spec.json')
  write_spec(spec_path, 5)
  log = File.join(dir, 'stub-log.jsonl')
  env = { 'STUB_SPEC' => spec_path, 'STUB_LOG' => log }
  va = File.join(SCRIPTS, 'verify-anchors.rb')
  # This section tests cache semantics, not worker scheduling. Keep exports
  # serial so each strict cache key is asserted deterministically; pool
  # concurrency has dedicated coverage in test-bounded-exports.rb.
  va_args = ['--workdir', dir, '--workbook-id', 'wb', '--timeout', '60', '--pool', '1']

  # Run 1 — cold cache: a1 matches, a2 misses → exit 1; both elements exported.
  write_anchors(dir, [A1, A2])
  _o1, e1, s1 = run_stubbed(stub_dir, env, va, *va_args)
  check(s1.exitstatus == 1, "run 1 (cold): a2 missing → exit 1 (got #{s1.exitstatus})", fails)
  check(export_posts(log) == 2, "run 1 exported both elements (got #{export_posts(log)})", fails)
  check(e1.include?('raw export cache active'), 'cache states itself active with the doc version', fails)
  cache_files = Dir[File.join(dir, 'export-cache', '*')]
  check(cache_files.any? { |f| f =~ /\.csv(\.r\d+)?\z/ } && cache_files.any? { |f| f.end_with?('.meta.json') },
        'payload + meta sidecar written under <workdir>/export-cache/', fails)
  raw = File.read(Dir[File.join(dir, 'export-cache', 'el-anchor.csv*')].reject { |f| f.end_with?('.meta.json') }.first)
  check(raw.start_with?('Account,Revenue'), "cache holds the RAW wire CSV bytes (got #{raw.inspect})", fails)
  check(!raw.include?('verdict') && !Dir[File.join(dir, 'export-cache', '*.meta.json')]
        .any? { |f| JSON.parse(File.read(f)).key?('pass') || JSON.parse(File.read(f)).key?('verdict') },
        'nothing verdict-shaped is stored anywhere in the cache', fails)

  # Run 2 — warm cache, same workbook version: ZERO exports, same verdict.
  File.write(log, '')
  _o2, e2, s2 = run_stubbed(stub_dir, env, va, *va_args)
  check(s2.exitstatus == 1, "run 2 (warm): verdict recomputed → still exit 1 (got #{s2.exitstatus})", fails)
  check(export_posts(log).zero?, "run 2 made ZERO export POSTs (got #{export_posts(log)})", fails)
  check(e2.include?('CACHED') && e2.include?('verdicts recomputed'),
        'progress names the cache hits and the recompute contract', fails)
  vd2 = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  check(vd2['export_cache'] && vd2['export_cache']['hits'] == 2 && vd2['export_cache']['doc_version'] == '5',
        'verdict records cache provenance (hits + doc version)', fails)

  # Run 3 — NEVER-VERDICT-REUSE: adding anchor a3 (additions are lock-legal)
  # changes the verdict over the SAME cached payloads — matched grows from the
  # recorded RAW bytes with still ZERO wire exports.
  write_anchors(dir, [A1, A2, A3])
  File.write(log, '')
  _o3, _e3, s3 = run_stubbed(stub_dir, env, va, *va_args)
  vd3 = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  check(s3.exitstatus == 1 && vd3['checked'] == 3 && vd3['matched'] == 2,
        "run 3: verdict RECOMPUTED over cached raw (3 checked, 2 matched; got #{vd3['checked']}/#{vd3['matched']})", fails)
  check(export_posts(log).zero?, 'run 3 still made ZERO export POSTs', fails)

  # Run 4 — VERSION INVALIDATION: any new POST/PUT bumps the version; the
  # cache must refuse the stale payloads and re-export everything.
  write_spec(spec_path, 6)
  File.write(log, '')
  _o4, e4, s4 = run_stubbed(stub_dir, env, va, *va_args)
  check(s4.exitstatus == 1, "run 4 (bumped version) still verdicts honestly (got #{s4.exitstatus})", fails)
  check(export_posts(log) == 2, "run 4 re-exported both elements after the version bump (got #{export_posts(log)})", fails)
  check(e4.include?('doc v6'), 'cache re-keys to the new document version', fails)
end

# ============================================================================
# Part 2 — collect-parity-actuals: readback version probe + shared cache.
# ============================================================================
puts '-- collect-parity-actuals: version-checked readback + cache hit + stale readback --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  spec_path = File.join(dir, 'stub-spec.json')   # the LIVE spec the stub serves
  rb_path   = File.join(dir, 'wb-readback.json') # the post-POST readback (spec source)
  write_spec(spec_path, 5)
  write_spec(rb_path, 5)
  plan_path = File.join(dir, 'parity-plan.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  File.write(plan_path, JSON.pretty_generate('charts' => [
    { 'chart' => 'Region Chart', 'sigma_kind' => 'bar-chart',
      'sigma_element_id' => 'el-ok', 'sigma_columns' => %w[c-r c-v2] }
  ]))
  log = File.join(dir, 'stub-log.jsonl')
  env = { 'STUB_SPEC' => spec_path, 'STUB_LOG' => log }
  cpa = File.join(SCRIPTS, 'collect-parity-actuals.rb')
  args = [cpa, '--plan', plan_path, '--workbook-id', 'wb', '--workbook-spec', rb_path,
          '--out', out_path, '--timeout', '60', '--drift-warn-minutes', '0']

  # Run 1 — cold: one live version probe validates the readback, one export.
  _o1, e1, s1 = run_stubbed(stub_dir, env, *args)
  check(s1.exitstatus.zero?, "run 1 exits 0 (got #{s1.exitstatus})", fails)
  check(e1.include?('raw export cache active'), 'version probe matched → cache active', fails)
  check(export_posts(log) == 1, "run 1 exported the chart once (got #{export_posts(log)})", fails)
  check(JSON.parse(File.read(out_path))['Region Chart'] == [['East', 100.0], ['West', 200.0]],
        'actuals collected from the wire', fails)

  # Run 2 — warm: version unchanged → ZERO exports; actuals identical,
  # recomputed from the cached raw body.
  File.write(out_path, '{}') # prove rows are re-derived, not re-merged
  File.write(log, '')
  _o2, _e2, s2 = run_stubbed(stub_dir, env, *args)
  check(s2.exitstatus.zero?, "run 2 exits 0 (got #{s2.exitstatus})", fails)
  check(export_posts(log).zero?, "run 2 made ZERO export POSTs (got #{export_posts(log)})", fails)
  check(JSON.parse(File.read(out_path))['Region Chart'] == [['East', 100.0], ['West', 200.0]],
        'actuals recomputed from cached raw bytes', fails)

  # Run 3 — STALE READBACK (#7b): live moved to v7 while the readback says v5.
  # The staleness is named LOUDLY and the cache is disabled (fresh export).
  write_spec(spec_path, 7)
  File.write(log, '')
  _o3, e3, s3 = run_stubbed(stub_dir, env, *args)
  check(s3.exitstatus.zero?, "run 3 exits 0 (got #{s3.exitstatus})", fails)
  check(e3.include?('STALE READBACK') && e3.include?('v5') && e3.include?('v7'),
        'stale readback named LOUDLY with both versions', fails)
  check(e3.include?('phase6-parity.rb PASS 1'), 'remedy names the readback refresh path', fails)
  check(export_posts(log) == 1, 'stale readback → cache off → fresh wire export', fails)
end

# ============================================================================
# Part 2b — CROSS-SCRIPT hit (A3, wave-1 review): verify-anchors.rb and
# collect-parity-actuals.rb now share ONE default rowLimit
# (ExportPool::DEFAULT_EXPORT_ROW_LIMIT), so an element exported by one script
# is a cache HIT for the other in the same workdir — the wave's original
# cross-script claim, previously defeated by the 50k-floor vs 100k defaults.
# ============================================================================
puts '-- cross-script: verify-anchors export → collect-parity-actuals ZERO-export hit --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  spec_path = File.join(dir, 'stub-spec.json')
  write_spec(spec_path, 5)
  File.write(File.join(dir, 'wb-readback.json'), File.read(spec_path))
  log = File.join(dir, 'stub-log.jsonl')
  env = { 'STUB_SPEC' => spec_path, 'STUB_LOG' => log }

  # Script 1: verify-anchors exports BOTH elements at the shared default limit.
  write_anchors(dir, [A1, A3]) # both match → exit 0
  _o1, _e1, s1 = run_stubbed(stub_dir, env, File.join(SCRIPTS, 'verify-anchors.rb'),
                             '--workdir', dir, '--workbook-id', 'wb', '--timeout', '60', '--pool', '1')
  check(s1.exitstatus.zero?, "verify-anchors run exits 0 (got #{s1.exitstatus})", fails)
  check(export_posts(log) == 2, "verify-anchors exported both elements (got #{export_posts(log)})", fails)
  check(Dir[File.join(dir, 'export-cache', 'el-ok.csv.r100000*')].any?,
        'entries keyed at the SHARED default rowLimit (.r100000)', fails)

  # Script 2: collect-parity-actuals against the SAME workdir + element +
  # default → ZERO export POSTs (the cross-script hit the review found dead).
  plan_path = File.join(dir, 'parity-plan.json')
  out_path = File.join(dir, 'parity-actuals.json')
  File.write(plan_path, JSON.pretty_generate('charts' => [
    { 'chart' => 'Region Chart', 'sigma_kind' => 'bar-chart',
      'sigma_element_id' => 'el-ok', 'sigma_columns' => %w[c-r c-v2] }
  ]))
  File.write(log, '')
  _o2, _e2, s2 = run_stubbed(stub_dir, env, File.join(SCRIPTS, 'collect-parity-actuals.rb'),
                             '--plan', plan_path, '--workbook-id', 'wb',
                             '--workbook-spec', File.join(dir, 'wb-readback.json'),
                             '--out', out_path, '--timeout', '60', '--drift-warn-minutes', '0')
  check(s2.exitstatus.zero?, "collect-parity-actuals exits 0 (got #{s2.exitstatus})", fails)
  check(export_posts(log).zero?,
        "collect-parity-actuals re-used verify-anchors' export — ZERO export POSTs (got #{export_posts(log)})", fails)
  cached_actuals = JSON.parse(File.read(out_path))['Region Chart']
  check(cached_actuals == [['East', 100.0], ['West', 200.0]],
        "actuals recomputed from the cross-script cached raw bytes (got #{cached_actuals.inspect})", fails)
end

# ============================================================================
# Part 3 — ExportPool::Cache unit rules: age expiry + rowLimit satisfaction
# (exact key, plus the A3 ≥-acceptance for COMPLETE bodies) + A7 element_id.
# ============================================================================
puts '-- Cache unit: age bound + rowLimit satisfaction + element_id equality --'
$LOAD_PATH.unshift File.expand_path('lib', SCRIPTS)
module Sigma # minimal in-process stand-in; Cache itself never calls it
  class Error < StandardError; end
end
require 'export_pool'
Dir.mktmpdir do |dir|
  c = ExportPool::Cache.new(dir, workbook_id: 'wb', doc_version: '5')
  c.store('el-x', 'csv', 100, "H\n1\n")
  check(c.fetch('el-x', 'csv', 100) == "H\n1\n", 'young same-key fetch hits', fails)
  check(c.fetch('el-x', 'csv', 100, now: Time.now + ExportPool::Cache::DEFAULT_MAX_AGE_S + 60).nil?,
        'entry older than 30 min → MISS (age bound)', fails)
  # A3 ≥-acceptance: 1 data row < the cached r100 bound → the body is the
  # COMPLETE result set, so it serves any SMALLER-bounded request too.
  check(c.fetch('el-x', 'csv', 50) == "H\n1\n",
        'A3: un-truncated cached r100 (complete) serves the r50 request', fails)
  check(c.fetch('el-x', 'csv', 50, now: Time.now + ExportPool::Cache::DEFAULT_MAX_AGE_S + 60).nil?,
        'the ≥-acceptance path still honors the age bound', fails)
  check(c.fetch('el-x', 'csv', 200).nil?,
        'a LARGER request is never served by a smaller-bounded entry', fails)
  check(c.fetch('el-x', 'json', 100).nil?, 'different format → MISS (strict key)', fails)
  # A cached body that FILLED its own bound may be truncated — it can never
  # stand in for a different limit (verdicts over it could differ).
  c.store('el-t', 'csv', 2, "H\n1\n2\n")
  check(c.fetch('el-t', 'csv', 2) == "H\n1\n2\n", 'filled entry still hits its EXACT key', fails)
  check(c.fetch('el-t', 'csv', 1).nil?,
        'a filled (possibly truncated) entry is a MISS for any other limit', fails)
  # An UNCAPPED entry (complete by construction, below the API hard cap)
  # serves any bounded request; a bounded entry never serves an uncapped one.
  c.store('el-u', 'csv', nil, "H\n1\n")
  check(c.fetch('el-u', 'csv', nil) == "H\n1\n", 'uncapped exact key hits', fails)
  check(c.fetch('el-u', 'csv', 10) == "H\n1\n", 'A3: uncapped complete entry serves a bounded request', fails)
  check(c.fetch('el-x', 'csv', nil).nil?, 'an uncapped request accepts only an uncapped entry', fails)
  # A7: two element ids that differ only in scrubbed chars share an on-disk
  # name — the meta element_id equality must refuse the cross-serve.
  c.store('el_y', 'csv', 100, "H\nY\n")
  check(c.fetch('el_y', 'csv', 100) == "H\nY\n", 'scrubbed-name element hits its own entry', fails)
  check(c.fetch('el y', 'csv', 100).nil?,
        "A7: 'el y' never cross-serves 'el_y' (meta element_id equality)", fails)
  check(c.fetch('el y', 'csv', 50).nil?,
        'A7 equality also guards the ≥-acceptance path', fails)
  c6 = ExportPool::Cache.new(dir, workbook_id: 'wb', doc_version: '6')
  check(c6.fetch('el-x', 'csv', 100).nil?, 'different doc version → MISS (strict key)', fails)
  check(c6.fetch('el-x', 'csv', 50).nil?, 'different doc version → MISS on the ≥ path too', fails)
  cnil = ExportPool::Cache.new(dir, workbook_id: 'wb', doc_version: nil)
  check(!cnil.enabled? && cnil.fetch('el-x', 'csv', 100).nil? && cnil.store('el-x', 'csv', 100, 'x').nil?,
        'unknown doc version → cache disabled entirely (no reuse, no store)', fails)
  # sha binding: corrupt the payload after store → MISS, never corrupt rows.
  payload = Dir[File.join(dir, 'export-cache', 'el-x.csv.r100')].first
  File.write(payload, "H\nTAMPERED\n")
  check(c.fetch('el-x', 'csv', 100).nil?, 'payload bytes changed after store → MISS (sha binding)', fails)
  check(c.fetch('el-x', 'csv', 50).nil?, 'tampered bytes are refused on the ≥ path too', fails)
end

# ============================================================================
# Part 4 — pooled_sql_probe (#7c): T entries = 1 workbook POST + T exports +
# 1 DELETE; per-entry errors isolated; the DELETE survives timeouts. Plus the
# W2.11 REGISTRY-IN-POOL red line (E7.1, wave-1 review): the pooled workbook
# registers created AT POST TIME (before the first export) and marks its
# DELETE outcome in ensure — a crash between POST and DELETE can never orphan
# it untraceably.
# ============================================================================
puts '-- pooled_sql_probe: one workbook, pooled exports, one delete --'
require 'probe_registry'
# Keep dev-probe registry fallback writes (calls without workdir:) out of the
# real ~/.tableau-to-sigma.
POOL_HOME = Dir.mktmpdir
ENV['TABLEAU_TO_SIGMA_HOME'] = POOL_HOME
POOL_LOG = []
def Sigma.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
  POOL_LOG << [method, path]
  if method == :post && path == '/v2/workbooks/spec'
    raise Sigma::Error, 'stub: 502 spec POST refused' if ENV['POOL_SPEC_FAIL'] == '1'
    return { 'workbookId' => 'wb-probe' }
  end
  if method == :post && path.include?('/export')
    # Crash-safety observation point: was the created record ALREADY on disk
    # when the first export fired? (register-at-creation ordering proof)
    if ENV['POOL_REG_FILE'].to_s != '' && POOL_LOG.none? { |m, _| m == :reg_seen_at_first_export }
      seen = File.exist?(ENV['POOL_REG_FILE']) && File.read(ENV['POOL_REG_FILE']).include?('"created_at"')
      POOL_LOG << [:reg_seen_at_first_export, seen]
    end
    raise Sigma::Error, 'stub: 500 export refused' if ENV['POOL_EXPORT_FAIL'] == '1'
    req = JSON.parse(body)
    return { 'queryId' => req['elementId'] }
  end
  if method == :get && path.start_with?('/v2/query/')
    qid = path.split('/')[3]
    return '<html>renderer error' if qid == 'probe1' && ENV['POOL_HTML1'] == '1'
    return "A,B\n#{qid[-1]},#{qid[-1]}\n"
  end
  if method == :delete
    raise Sigma::Error, 'stub: 500 delete refused' if ENV['POOL_DELETE_FAIL'] == '1'
    return {}
  end
  raise Sigma::Error, "stub: unexpected #{method} #{path}"
end
entries = [{ 'sql' => 'SELECT 1', 'columns' => %w[A B] },
           { 'sql' => 'SELECT 2', 'columns' => %w[A B] },
           { 'sql' => 'SELECT 3', 'columns' => %w[A B] }]
deadline = ExportPool::Deadline.new(30)
res = ExportPool.pooled_sql_probe('conn-1', entries, deadline, pool: 2, row_limit: 500)
check(res.length == 3 && res.all? { |st, rows| st == :ok && rows.length == 2 },
      'all three entries return parsed CSV rows', fails)
check(POOL_LOG.count { |m, p| m == :post && p == '/v2/workbooks/spec' } == 1,
      'exactly ONE probe workbook POST for the whole batch', fails)
check(POOL_LOG.count { |m, p| m == :post && p.include?('/export') } == 3,
      'one export per entry (pooled)', fails)
check(POOL_LOG.count { |m, _| m == :delete } == 1, 'exactly ONE delete for the whole batch', fails)
# W2.11 registry-in-pool is SELF-ARMING: even a caller that passes no
# workdir:/script: (this legacy-signature call is the frozen-signature pin)
# gets created+cleaned records — in the home registry.
reg_home = File.join(POOL_HOME, ProbeRegistry::FILE_BASENAME)
hreg = File.exist?(reg_home) ? File.readlines(reg_home).map { |l| JSON.parse(l) } : []
check(hreg.any? { |r| r['created_at'] && r['id'] == 'wb-probe' } &&
      hreg.any? { |r| r['deleted_at'] && r['id'] == 'wb-probe' },
      'legacy call (no workdir:) still registers created+cleaned in the home registry', fails)
File.delete(reg_home) if File.exist?(reg_home)

POOL_LOG.clear
ENV['POOL_HTML1'] = '1'
res2 = ExportPool.pooled_sql_probe('conn-1', entries, ExportPool::Deadline.new(30), pool: 3)
check(res2[0].first == :ok && res2[2].first == :ok && res2[1].first == :error &&
      res2[1].last.include?('HTML'),
      'a renderer error on one entry is isolated (others still :ok)', fails)
check(POOL_LOG.count { |m, _| m == :delete } == 1, 'delete still exactly once on the error path', fails)
ENV.delete('POOL_HTML1')

POOL_LOG.clear
res3 = ExportPool.pooled_sql_probe('conn-1', entries, ExportPool::Deadline.new(-1), pool: 2)
check(res3.all? { |st, _| st == :timeout }, 'expired deadline → per-entry :timeout markers', fails)
check(POOL_LOG.count { |m, _| m == :delete } == 1, 'the probe workbook is deleted even on timeout', fails)

# ============================================================================
# Part 4b — W2.11 REGISTRY-IN-POOL (E7.1 litter red line, wave-1 review):
# created is written AT POST TIME — before the first export fires — and the
# DELETE outcome lands in the same ensure, so no crash window between POST and
# DELETE can orphan the pooled probe workbook untraceably.
# ============================================================================
puts '-- registry-in-pool: created at POST (pre-export), outcome at DELETE --'
File.delete(File.join(POOL_HOME, ProbeRegistry::FILE_BASENAME)) if File.exist?(File.join(POOL_HOME, ProbeRegistry::FILE_BASENAME))

# A) ordering proof + workdir/script threading (the run-ground-truth shape).
Dir.mktmpdir do |wd|
  POOL_LOG.clear
  ENV['POOL_REG_FILE'] = File.join(wd, ProbeRegistry::FILE_BASENAME)
  r = ExportPool.pooled_sql_probe('conn-1', entries, ExportPool::Deadline.new(30), pool: 2,
                                  name: '_probe_groundtruth_pool', workdir: wd,
                                  script: 'run-ground-truth.rb')
  ENV.delete('POOL_REG_FILE')
  check(r.all? { |st, _| st == :ok }, 'workdir-threaded pooled run still returns rows', fails)
  reg = File.readlines(File.join(wd, ProbeRegistry::FILE_BASENAME)).map { |l| JSON.parse(l) }
  created = reg.find { |x| x['created_at'] }
  cleaned = reg.find { |x| x['deleted_at'] }
  check(POOL_LOG.include?([:reg_seen_at_first_export, true]),
        'created record was ALREADY on disk when the first export fired (register-at-creation)', fails)
  check(created && created['id'] == 'wb-probe' && created['name'] == '_probe_groundtruth_pool' &&
        created['script'] == 'run-ground-truth.rb',
        'created record carries id + caller script + probe name into <workdir>/probe-artifacts.jsonl', fails)
  check(cleaned && cleaned['id'] == 'wb-probe' && cleaned['via'] == 'ensure' && cleaned['outcome'] == 'deleted',
        'cleaned record: DELETE outcome marked via ensure', fails)
  check(reg.index(created) < reg.index(cleaned), 'created line precedes cleaned line', fails)
  check(ProbeRegistry.outstanding(wd).empty?, 'registry shows ZERO open probes after the pooled run', fails)
end

# B) a FAILED delete leaves the entry OUTSTANDING so the sweep retries it.
Dir.mktmpdir do |wd|
  POOL_LOG.clear
  ENV['POOL_DELETE_FAIL'] = '1'
  r = ExportPool.pooled_sql_probe('conn-1', entries, ExportPool::Deadline.new(30), pool: 2, workdir: wd)
  ENV.delete('POOL_DELETE_FAIL')
  check(r.all? { |st, _| st == :ok }, 'a failed DELETE never breaks the probe results', fails)
  reg = File.readlines(File.join(wd, ProbeRegistry::FILE_BASENAME)).map { |l| JSON.parse(l) }
  check(reg.any? { |x| x['deleted_at'] && x['outcome'] == 'failed' },
        'failed delete marked outcome=failed', fails)
  out = ProbeRegistry.outstanding(wd)
  check(out.length == 1 && out.first['id'] == 'wb-probe',
        'failed-delete probe stays OUTSTANDING for the sweep to retry', fails)
end

# C) every export raising (the crash shape) still cannot orphan: created was
# recorded first, DELETE + cleaned still run in ensure.
Dir.mktmpdir do |wd|
  POOL_LOG.clear
  ENV['POOL_EXPORT_FAIL'] = '1'
  ENV['POOL_REG_FILE'] = File.join(wd, ProbeRegistry::FILE_BASENAME)
  r = ExportPool.pooled_sql_probe('conn-1', entries, ExportPool::Deadline.new(30), pool: 2, workdir: wd)
  ENV.delete('POOL_EXPORT_FAIL')
  ENV.delete('POOL_REG_FILE')
  check(r.all? { |st, _| st == :error }, 'all-exports-raise → per-entry :error markers', fails)
  check(POOL_LOG.include?([:reg_seen_at_first_export, true]),
        'created record predates the exports even when they all raise', fails)
  check(ProbeRegistry.outstanding(wd).empty?,
        'export crash-path: workbook still deleted + marked — zero open probes', fails)
end

# D) spec-POST failure is litter-CLEAN: nothing created → nothing registered,
# nothing deleted (the raise carries the failure to the caller's fallback).
Dir.mktmpdir do |wd|
  POOL_LOG.clear
  ENV['POOL_SPEC_FAIL'] = '1'
  err = nil
  begin
    ExportPool.pooled_sql_probe('conn-1', entries, ExportPool::Deadline.new(30), pool: 2, workdir: wd)
  rescue StandardError => e
    err = e
  end
  ENV.delete('POOL_SPEC_FAIL')
  check(err && err.message.include?('pooled probe workbook POST failed'),
        'pool POST failure raises to the caller (serial-fallback hook)', fails)
  check(!File.exist?(File.join(wd, ProbeRegistry::FILE_BASENAME)),
        'nothing was created → nothing registered (litter-clean failure)', fails)
  check(POOL_LOG.none? { |m, _| m == :delete }, 'no phantom DELETE on the failed-POST path', fails)
end

# ============================================================================
# Part 5 — W2.11 run-ground-truth.rb POOLED WIRING: the live path routes every
# warehouse-sql entry through pooled_sql_probe (1 spec POST + T exports +
# 1 DELETE), verdicts stay caller-side (transport-only), pool-POST failure
# falls back to the serial seam (fail-open, litter-safe), --no-pool forces it.
# Subprocess runs use the same SIGMA_STUB seam as Parts 1–2.
# ============================================================================
GT_POOL_STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      File.open(ENV['GTP_LOG'], 'a') { |f| f.puts(JSON.generate('m' => method.to_s, 'p' => path)) }
      if method == :post && path == '/v2/workbooks/spec'
        posted = JSON.parse(body)
        # Task 3.2: pooled_sql_probe now nests the workbook document under a
        # top-level `document` key (the live surface 400s on the old flat
        # body), with current writes flattening elements into
        # document.elements. run-ground-truth.rb's own SERIAL per-entry probe
        # POST can still use the legacy nested-page shape, so tolerate both.
        doc = posted['document'] || posted
        n_els = (doc['elements'] || (doc['pages'] || []).flat_map { |page| page['elements'] || [] }).length
        raise Error, 'stub: HTTP 502 pooled spec POST refused' if n_els > 1 && ENV['GTP_POOL_SPEC_FAIL'] == '1'
        n = File.exist?(ENV['GTP_SEQ']) ? File.read(ENV['GTP_SEQ']).to_i + 1 : 1
        File.write(ENV['GTP_SEQ'], n.to_s)
        return { 'workbookId' => "wb-#{n}" }
      end
      if method == :post && path.include?('/export')
        return { 'queryId' => JSON.parse(body)['elementId'] }
      end
      if method == :get && path.start_with?('/v2/query/')
        # Download that never materializes: the pooled deadline expires while
        # polling → per-entry :timeout markers (the deadline-skipped mapping).
        raise Error, 'stub: HTTP 404 query not yet materialized' if ENV['GTP_NEVER_READY'] == '1'
        qid = path.split('/')[3]
        return '<html>renderer error' if qid == 'probe2' && ENV['GTP_HTML'] == '1'
        if qid == 'probe1' && ENV['GTP_EXPLODE'] == '1'
          return "Region,Sales (sum)\na,1\nb,2\nc,3\n"
        end
        return "Region,Sales (sum)\nEast,100.5\n"
      end
      return {} if method == :delete
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

GT_SCRIPT = File.join(SCRIPTS, 'run-ground-truth.rb')
SWEEP_SCRIPT = File.join(SCRIPTS, 'sweep-run-artifacts.rb')

def gt_plan(dir, n_sql)
  entries = (1..n_sql).map do |k|
    { 'chart' => "Tile #{k}", 'sigma_element_id' => "el-#{k}", 'classification' => 'warehouse-sql',
      'sql' => "SELECT R AS \"Region\", SUM(S) AS \"Sales (sum)\"\nFROM T#{k}\nGROUP BY 1",
      'columns' => [{ 'alias' => 'Region', 'role' => 'dim' }, { 'alias' => 'Sales (sum)', 'role' => 'measure' }] }
  end
  entries << { 'chart' => 'Tile Vds', 'sigma_element_id' => 'el-vds', 'classification' => 'vds',
               'reason' => 'test reason' }
  File.write(File.join(dir, 'ground-truth-plan.json'),
             JSON.pretty_generate('version' => 1, 'generated_at' => '2026-07-18T00:00:00Z',
                                  'entries' => entries))
end

def gtp_env(dir)
  { 'GTP_LOG' => File.join(dir, 'gtp-log.jsonl'), 'GTP_SEQ' => File.join(dir, 'gtp-seq'),
    'TABLEAU_TO_SIGMA_HOME' => File.join(dir, 'home') }
end

def gtp_reg(dir)
  p = File.join(dir, 'probe-artifacts.jsonl')
  File.exist?(p) ? File.readlines(p).map { |l| JSON.parse(l) } : []
end

puts '-- run-ground-truth pooled: 1 spec POST + T exports + 1 DELETE, registry-in-pool --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), GT_POOL_STUB)
  gt_plan(dir, 3)
  env = gtp_env(dir)
  out, _err, st = run_stubbed(stub_dir, env, GT_SCRIPT, '--workdir', dir, '--connection-id', 'conn-1')
  check(st.exitstatus.zero?, "pooled run exits 0 (got #{st.exitstatus})", fails)
  log = read_log(env['GTP_LOG'])
  check(log.count { |r| r['m'] == 'post' && r['p'] == '/v2/workbooks/spec' } == 1,
        'exactly ONE probe-workbook POST for 3 warehouse-sql entries', fails)
  check(log.count { |r| r['m'] == 'post' && r['p'].include?('/export') } == 3,
        'one pooled export per entry', fails)
  check(log.count { |r| r['m'] == 'delete' } == 1, 'exactly ONE delete for the whole plan', fails)
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  check(doc['transport'] == 'pooled' && doc['summary']['pool'] &&
        doc['summary']['pool']['entries'] == 3,
        'actuals record transport=pooled + pool summary', fails)
  check(doc['summary']['ok'] == 3 && doc['summary']['complete'] == true,
        'all 3 pooled entries ok; complete=true', fails)
  check(doc['results'].select { |r| r['status'] == 'ok' }
           .all? { |r| r['columns'] == ['Region', 'Sales (sum)'] && r['rows'] == [['East', '100.5']] },
        'pooled rows land per entry with the header split off', fails)
  check(doc['results'].any? { |r| r['status'] == 'skipped-vds' },
        'non-warehouse-sql entries still mirrored (pooling changes transport only)', fails)
  check(out.include?('[1/3]') && out.include?('[3/3]'), 'per-entry progress lines survive pooling', fails)
  reg = gtp_reg(dir)
  created = reg.select { |r| r['created_at'] }
  cleaned = reg.select { |r| r['deleted_at'] }
  check(created.length == 1 && created[0]['script'] == 'run-ground-truth.rb' &&
        created[0]['name'].to_s.start_with?('_probe_groundtruth_'),
        'ONE pooled workbook registered at POST (script + name recorded)', fails)
  check(cleaned.length == 1 && cleaned[0]['id'] == created[0]['id'] && cleaned[0]['outcome'] == 'deleted',
        'pooled workbook marked cleaned at DELETE', fails)
  check(ProbeRegistry.outstanding(dir).empty?, 'registry zero-open after the pooled run', fails)

  # ── LIVE SMOKE (authored here, STUBBED offline): after a run + a simulated
  # crash orphan, one sweep --delete leaves the registry ZERO-OPEN. Live runs
  # execute this exact sequence against the real org (no stub).
  ProbeRegistry.created('wb-orphan', name: '_probe_groundtruth_orphan', workdir: dir,
                        script: 'run-ground-truth.rb') # crash between POST and DELETE
  check(ProbeRegistry.outstanding(dir).length == 1, 'simulated crash leaves one open probe', fails)
  s_out, _s_err, s_st = run_stubbed(stub_dir, env, SWEEP_SCRIPT, '--workdir', dir, '--delete')
  check(s_st.exitstatus.zero? && s_out.include?('wb-orphan'),
        "sweep deletes the crash orphan from the registry (got #{s_st.exitstatus})", fails)
  check(ProbeRegistry.outstanding(dir).empty?, 'LIVE-SMOKE assertion: registry zero-open after sweep', fails)
  s2_out, _e2, s2 = run_stubbed(stub_dir, env, SWEEP_SCRIPT, '--workdir', dir)
  check(s2.exitstatus.zero? && s2_out.include?('nothing outstanding'),
        'second sweep confirms: nothing outstanding — registry clean', fails)
end

puts '-- run-ground-truth pooled: verdicts stay caller-side (transport-only) --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), GT_POOL_STUB)
  gt_plan(dir, 3)
  env = gtp_env(dir).merge('GTP_EXPLODE' => '1', 'GTP_HTML' => '1')
  _out, err, st = run_stubbed(stub_dir, env, GT_SCRIPT, '--workdir', dir, '--connection-id', 'conn-1',
                              '--row-limit', '2')
  check(st.exitstatus == 2, "mixed verdicts → exit 2 (got #{st.exitstatus})", fails)
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  by = doc['results'].each_with_object({}) { |r, h| h[r['chart']] = r }
  check(by['Tile 1']['status'] == 'ok', 'entry 1 ok', fails)
  check(by['Tile 2']['status'] == 'row-explosion' && by['Tile 2']['error'].to_s.include?('GROUP BY'),
        'row-explosion verdict computed HERE over pooled raw rows (transport-only pool)', fails)
  check(by['Tile 3']['status'] == 'error' && by['Tile 3']['error'].to_s.include?('HTML'),
        'renderer-error entry isolated as error (others unaffected)', fails)
  check(err.include?('ROW-EXPLOSION'), 'stderr still shouts ROW-EXPLOSION', fails)
  log = read_log(env['GTP_LOG'])
  check(log.count { |r| r['m'] == 'delete' } == 1 && ProbeRegistry.outstanding(dir).empty?,
        'one delete + zero-open registry even with failing verdicts', fails)
end

puts '-- run-ground-truth: pool-POST failure → loud serial fallback (fail-open) --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), GT_POOL_STUB)
  gt_plan(dir, 2)
  env = gtp_env(dir).merge('GTP_POOL_SPEC_FAIL' => '1')
  _out, err, st = run_stubbed(stub_dir, env, GT_SCRIPT, '--workdir', dir, '--connection-id', 'conn-1')
  check(st.exitstatus.zero?, "fallback run still completes → exit 0 (got #{st.exitstatus})", fails)
  check(err.include?('falling back to the serial'), 'fallback is LOUD on stderr', fails)
  log = read_log(env['GTP_LOG'])
  check(log.count { |r| r['m'] == 'post' && r['p'] == '/v2/workbooks/spec' } == 3,
        '1 refused pooled POST + 2 serial probe POSTs', fails)
  check(log.count { |r| r['m'] == 'delete' } == 2, 'serial fallback deletes per-entry probes', fails)
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  check(doc['transport'] == 'serial' && doc['summary']['ok'] == 2,
        'actuals record transport=serial; both entries still collected', fails)
  reg = gtp_reg(dir)
  check(reg.count { |r| r['created_at'] } == 2 && ProbeRegistry.outstanding(dir).empty?,
        'failed pool POST registered NOTHING; serial probes registered + cleaned (litter-safe)', fails)
end

puts '-- run-ground-truth --no-pool: serial seam forced --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), GT_POOL_STUB)
  gt_plan(dir, 2)
  env = gtp_env(dir)
  _out, _err, st = run_stubbed(stub_dir, env, GT_SCRIPT, '--workdir', dir, '--connection-id', 'conn-1',
                               '--no-pool')
  check(st.exitstatus.zero?, "--no-pool run exits 0 (got #{st.exitstatus})", fails)
  log = read_log(env['GTP_LOG'])
  check(log.count { |r| r['m'] == 'post' && r['p'] == '/v2/workbooks/spec' } == 2 &&
        log.count { |r| r['m'] == 'delete' } == 2,
        '--no-pool: one probe workbook per entry (the serial seam, unchanged)', fails)
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  check(doc['transport'] == 'serial' && doc['results'].select { |r| r['elapsed_s'] }.length == 2,
        '--no-pool actuals record transport=serial with per-entry timings', fails)
end

puts '-- run-ground-truth pooled timeout: deadline-skipped + exit 3 PARTIAL --'
# The pooled-timeout mapping (pooled[i][0]==:timeout → status deadline-skipped
# → exit 3): downloads never materialize, the total --timeout expires inside
# the pool, and every warehouse-sql entry is marked deadline-skipped — the
# actuals stay PARTIAL and honest, and summary.pool still records the attempt.
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), GT_POOL_STUB)
  gt_plan(dir, 2)
  env = gtp_env(dir).merge('GTP_NEVER_READY' => '1')
  _out, err, st = run_stubbed(stub_dir, env, GT_SCRIPT, '--workdir', dir, '--connection-id', 'conn-1',
                              '--timeout', '2')
  check(st.exitstatus == 3, "pooled timeout → exit 3 PARTIAL (got #{st.exitstatus})", fails)
  check(err.include?('[PARTIAL]'), 'PARTIAL warning lands on stderr', fails)
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  skipped = doc['results'].select { |r| r['status'] == 'deadline-skipped' }
  check(skipped.length == 2 && skipped.all? { |r| r['error'].to_s.include?('pooled') },
        'both pooled entries marked deadline-skipped with the pooled wording', fails)
  check(doc['transport'] == 'pooled' && doc['summary']['pool'] &&
        doc['summary']['pool']['entries'] == 2,
        'summary.pool still records the attempted pooled transport', fails)
  check(doc['summary']['deadline_skipped'] == 2 && doc['summary']['complete'] == false,
        'summary counts the skips; complete=false', fails)
  log = read_log(env['GTP_LOG'])
  check(log.count { |r| r['m'] == 'delete' } == 1 && ProbeRegistry.outstanding(dir).empty?,
        'pooled workbook still deleted + registry zero-open on the timeout path', fails)
end

puts '-- run-ground-truth --fixture beats --connection-id: zero live calls --'
# Guard pin: --fixture + --connection-id together must NOT fire the live pool
# (the fixture branch discards live results per entry, and a pooled :timeout
# would corrupt the offline run's statuses/exit before the fixture branch is
# consulted). A fixture run is offline by contract: zero REST calls.
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), GT_POOL_STUB)
  gt_plan(dir, 2)
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  2.times do |i|
    File.write(File.join(fx, "entry-#{i}.json"),
               JSON.generate('columns' => ['Region', 'Sales (sum)'], 'rows' => [['East', '100.5']]))
  end
  env = gtp_env(dir).merge('GTP_NEVER_READY' => '1') # any live poll would hang toward :timeout — proves none fires
  _out, _err, st = run_stubbed(stub_dir, env, GT_SCRIPT, '--workdir', dir, '--fixture', fx,
                               '--connection-id', 'conn-1', '--timeout', '2')
  check(st.exitstatus.zero?, "fixture + connection-id run exits 0 (got #{st.exitstatus})", fails)
  check(read_log(env['GTP_LOG']).empty?,
        'ZERO live REST calls — the pool guard defers to --fixture', fails)
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  check(doc['mode'] == 'fixture' && doc['transport'] == 'fixture' && doc['summary']['ok'] == 2,
        'fixture verdicts win: mode/transport=fixture, both entries ok', fails)
end

# ============================================================================
# Part 6 — W2.12 probe-controls.rb FLIP-EXPORT POOLING: baselines + flips run
# pooled through ExportPool.pooled_element_exports; verdict logic (row-set
# signatures, PASS/FAIL/SKIP, exit codes) untouched; evidence recorded per the
# version-keyed raw contract (probe-evidence.json binds CSV sha256s to the
# workbook doc version); --no-pool = serial transport through the same seam.
# ============================================================================
PC_STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.list_entries(path, limit: 1000, http: nil)
      data = request(:get, "#{path}?limit=#{limit}", http: http)
      (data.is_a?(Hash) ? data['entries'] : data) || []
    end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      rec = { 'm' => method.to_s, 'p' => path }
      rec['body'] = body if body
      File.open(ENV['PC_LOG'], 'a') { |f| f.puts(JSON.generate(rec)) }
      return File.read(ENV['PC_SPEC']) if method == :get && path.end_with?('/spec')
      if method == :get && path.split('?').first.end_with?('/columns')
        return { 'entries' => [{ 'elementId' => 'el-data', 'columnId' => 'c-reg', 'label' => 'Region' }] }
      end
      if method == :post && path.include?('/export')
        req = JSON.parse(body)
        return { 'queryId' => "#{req['elementId']}#{req['parameters'] ? '.flip' : '.base'}" }
      end
      if method == :get && path.start_with?('/v2/query/')
        case path.split('/')[3]
        when 'el-data.base' then return "Region,Sales\nEast,1\nWest,2\n"
        when 'el-data.flip' then return "Region,Sales\nWest,2\n"
        when 'el-out.base'  then return "K,V\nx,1\n"
        when 'el-out.flip'  then return ENV['PC_LEAK'] == '1' ? "K,V\ny,9\n" : "K,V\nx,1\n"
        # Served only if the no-waste pin REGRESSES (label-unresolvable
        # value-source pooled anyway) — keeps the failure a count mismatch,
        # not an unexpected-path crash.
        when 'el-data2.base' then return "M,V\n1,2\n"
        end
      end
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

PC_SCRIPT = File.join(SCRIPTS, 'probe-controls.rb')

def pc_spec(path, with_unlabeled: false)
  elements = [
    { 'id' => 'ctl-el', 'kind' => 'control', 'controlType' => 'list',
      'controlId' => 'c-region', 'name' => 'Region Filter', 'values' => ['East'],
      'source' => { 'kind' => 'source', 'source' => { 'elementId' => 'el-data' },
                    'columnId' => 'c-reg' },
      'filters' => [{ 'columnId' => 'c-reg', 'source' => { 'elementId' => 'el-data' } }] },
    { 'id' => 'el-data', 'kind' => 'table', 'name' => 'Data' },
    { 'id' => 'el-out', 'kind' => 'bar-chart', 'name' => 'Out Chart' }
  ]
  if with_unlabeled
    # A list control whose value-source column has NO /columns label: serial
    # pick_value SKIPs it BEFORE any export — the pooled prefetch must not
    # export its baseline either (no-waste pin, label-unresolvable shape).
    elements += [
      { 'id' => 'ctl-mystery', 'kind' => 'control', 'controlType' => 'list',
        'controlId' => 'c-mystery', 'name' => 'Mystery Filter', 'values' => ['A'],
        'source' => { 'kind' => 'source', 'source' => { 'elementId' => 'el-data2' },
                      'columnId' => 'c-unlabeled' },
        'filters' => [{ 'columnId' => 'c-unlabeled', 'source' => { 'elementId' => 'el-data2' } }] },
      { 'id' => 'el-data2', 'kind' => 'table', 'name' => 'Data 2' }
    ]
  end
  File.write(path, JSON.pretty_generate(
               'workbookId' => 'wb', 'latestDocumentVersion' => 5,
               'document' => {
                 'schemaVersion' => 4,
                 'kind' => 'workbook',
                 'pages' => [{ 'id' => 'p1', 'name' => 'p1' }],
                 'elements' => elements,
                 'layout' => "<Page id=\"p1\">#{elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
               }))
end

def pc_export_posts(log)
  read_log(log).select { |r| r['m'] == 'post' && r['p'].include?('/export') }
end

puts '-- probe-controls pooled: flip verdicts unchanged, evidence version-keyed --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), PC_STUB)
  spec_path = File.join(dir, 'pc-spec.json')
  pc_spec(spec_path)
  log = File.join(dir, 'pc-log.jsonl')
  env = { 'PC_SPEC' => spec_path, 'PC_LOG' => log }
  out1 = File.join(dir, 'probe-out-pooled')
  o1, _e1, s1 = run_stubbed(stub_dir, env, PC_SCRIPT, '--workbook-id', 'wb', '--out', out1)
  check(s1.exitstatus.zero?, "pooled probe exits 0 (got #{s1.exitstatus})", fails)
  check(o1.include?('PASS'), 'per-control table still prints PASS', fails)
  results = JSON.parse(File.read(File.join(out1, 'probe-results.json')))
  check(results.is_a?(Array) && results.length == 1 && results[0]['result'] == 'PASS' &&
        results[0]['value'] == 'West',
        'probe-results.json keeps its ARRAY shape; flip auto-picked + verdict PASS', fails)
  require 'flip_gate'
  decision, info = FlipGate.decide(s1.exitstatus, results)
  check(decision == :ok && info[:passes] == ['c-region'],
        'gate 7b consumes the pooled results unchanged (FlipGate.decide → :ok)', fails)
  posts = pc_export_posts(log)
  check(posts.length == 2, "pooled run makes exactly the serial exports — 2 (got #{posts.length})", fails)
  check(posts.any? { |p| p['body'].include?('"parameters"') && p['body'].include?('West') },
        'flip export POST carries parameters:{controlId: flip value}', fails)
  ev = JSON.parse(File.read(File.join(out1, 'probe-evidence.json')))
  check(ev['workbook_id'] == 'wb' && ev['doc_version'] == '5' && ev['transport'] == 'pooled(5)',
        'evidence sidecar keys the raw CSVs to workbook + doc version + transport', fails)
  check(ev['exports'].length == 2 && ev['exports'].all? do |fname, sha|
          require 'digest'
          Digest::SHA256.hexdigest(File.binread(File.join(out1, fname))) == sha
        end,
        'every evidence CSV byte-matches its recorded sha256 (raw, tamper-evident)', fails)
  base_csv = File.read(File.join(out1, 'c-region--el-data--base.csv'))
  check(base_csv == "Region,Sales\nEast,1\nWest,2\n",
        'evidence CSV is the untouched wire body (raw contract)', fails)

  # Serial transport (--no-pool): same seam, same verdicts, same export count.
  File.write(log, '')
  out2 = File.join(dir, 'probe-out-serial')
  _o2, _e2, s2 = run_stubbed(stub_dir, env, PC_SCRIPT, '--workbook-id', 'wb', '--out', out2, '--no-pool')
  check(s2.exitstatus.zero?, "--no-pool probe exits 0 (got #{s2.exitstatus})", fails)
  r2 = JSON.parse(File.read(File.join(out2, 'probe-results.json')))
  check(r2 == results, 'serial and pooled runs produce IDENTICAL verdicts (transport-only)', fails)
  check(pc_export_posts(log).length == 2, 'serial transport also makes 2 exports (no-waste pin)', fails)
  check(JSON.parse(File.read(File.join(out2, 'probe-evidence.json')))['transport'] == 'serial',
        'serial evidence sidecar records transport=serial', fails)
end

puts '-- probe-controls pooled + --check-out-of-closure: leak FAIL still fires --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), PC_STUB)
  spec_path = File.join(dir, 'pc-spec.json')
  pc_spec(spec_path)
  log = File.join(dir, 'pc-log.jsonl')
  out3 = File.join(dir, 'probe-out-leakfree')
  env = { 'PC_SPEC' => spec_path, 'PC_LOG' => log }
  _o3, _e3, s3 = run_stubbed(stub_dir, env, PC_SCRIPT, '--workbook-id', 'wb', '--out', out3,
                             '--check-out-of-closure')
  check(s3.exitstatus.zero?, "leak-free pooled leak-check exits 0 (got #{s3.exitstatus})", fails)
  r3 = JSON.parse(File.read(File.join(out3, 'probe-results.json')))
  check(r3.any? { |r| r['result'] == 'OK' && r['note'].to_s.include?('no leak') },
        'out-of-closure OK row recorded (flip did not leak)', fails)
  check(pc_export_posts(log).length == 4, "leak check pools 4 exports (got #{pc_export_posts(log).length})", fails)
  check(JSON.parse(File.read(File.join(out3, 'probe-evidence.json')))['exports'].length == 4,
        'all four evidence CSVs recorded in the sidecar', fails)

  # A leaking flip (out-of-closure export CHANGES) must still FAIL loudly —
  # the pooled transport moved bytes, never the verdict.
  out4 = File.join(dir, 'probe-out-leaky')
  _o4, _e4, s4 = run_stubbed(stub_dir, env.merge('PC_LEAK' => '1'), PC_SCRIPT,
                             '--workbook-id', 'wb', '--out', out4, '--check-out-of-closure')
  check(s4.exitstatus == 1, "leaking flip → exit 1 (got #{s4.exitstatus})", fails)
  r4 = JSON.parse(File.read(File.join(out4, 'probe-results.json')))
  check(r4.any? { |r| r['result'] == 'FAIL' && r['note'].to_s.include?('closure walk missed an edge') },
        'leak FAIL verdict computed from pooled raw bytes (verdict logic untouched)', fails)
end

puts '-- probe-controls no-waste pin: label-unresolvable value-source exports NOTHING --'
# Serial pick_value SKIPs a list control whose value-source column has no
# /columns label BEFORE exporting; the pooled round-1 prefetch must mirror
# that check or it pools a baseline the serial path never pays for.
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), PC_STUB)
  spec_path = File.join(dir, 'pc-spec.json')
  pc_spec(spec_path, with_unlabeled: true)
  log = File.join(dir, 'pc-log.jsonl')
  env = { 'PC_SPEC' => spec_path, 'PC_LOG' => log }
  out5 = File.join(dir, 'probe-out-unlabeled-pooled')
  _o5, _e5, s5 = run_stubbed(stub_dir, env, PC_SCRIPT, '--workbook-id', 'wb', '--out', out5)
  check(s5.exitstatus.zero?, "pooled run with unlabeled control exits 0 (got #{s5.exitstatus})", fails)
  r5 = JSON.parse(File.read(File.join(out5, 'probe-results.json')))
  by5 = r5.each_with_object({}) { |r, h| h[r['control']] = r }
  check(by5['c-region'] && by5['c-region']['result'] == 'PASS',
        'labeled control still probes to PASS', fails)
  check(by5['c-mystery'] && by5['c-mystery']['result'] == 'SKIP' &&
        by5['c-mystery']['note'].to_s.include?('no /columns label'),
        'unlabeled value-source control SKIPs with the label note', fails)
  posts5 = pc_export_posts(log)
  check(posts5.length == 2 && posts5.none? { |p| p['body'].include?('el-data2') },
        "no-waste pin: pooled run exports 2 (no el-data2 baseline; got #{posts5.length})", fails)

  # Serial parity: identical verdicts, identical export count for the shape.
  File.write(log, '')
  out6 = File.join(dir, 'probe-out-unlabeled-serial')
  _o6, _e6, s6 = run_stubbed(stub_dir, env, PC_SCRIPT, '--workbook-id', 'wb', '--out', out6, '--no-pool')
  check(s6.exitstatus.zero? && JSON.parse(File.read(File.join(out6, 'probe-results.json'))) == r5,
        'serial run: identical verdicts for the unlabeled shape (transport-only)', fails)
  check(pc_export_posts(log).length == 2,
        'serial run also exports exactly 2 (the pin holds on both transports)', fails)
end

puts '-- probe-controls without export_pool.rb: loads + serial fallback seam --'
# The probe-controls manifest targets are a SUPERSET of export_pool.rb's (e.g.
# the domo twin has no scripts/lib/export_pool.rb). A twin in that shape must
# still LOAD (soft require) and complete the probe on the serial fallback
# seam — same verdicts, same export count, transport recorded as serial.
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), PC_STUB)
  fb_dir = File.join(dir, 'twin-without-pool')
  Dir.mkdir(fb_dir)
  Dir.mkdir(File.join(fb_dir, 'lib'))
  FileUtils.cp(PC_SCRIPT, File.join(fb_dir, 'probe-controls.rb'))
  FileUtils.cp(File.join(SCRIPTS, 'lib', 'control_lint.rb'), File.join(fb_dir, 'lib', 'control_lint.rb'))
  FileUtils.cp(File.join(SCRIPTS, 'lib', 'code_rep.rb'), File.join(fb_dir, 'lib', 'code_rep.rb'))
  # deliberately NO lib/export_pool.rb — the domo manifest shape
  spec_path = File.join(dir, 'pc-spec.json')
  pc_spec(spec_path)
  log = File.join(dir, 'pc-log.jsonl')
  env = { 'PC_SPEC' => spec_path, 'PC_LOG' => log }
  out7 = File.join(dir, 'probe-out-fallback')
  _o7, e7, s7 = run_stubbed(stub_dir, env, File.join(fb_dir, 'probe-controls.rb'),
                            '--workbook-id', 'wb', '--out', out7)
  check(s7.exitstatus.zero?, "no-export_pool twin exits 0 (got #{s7.exitstatus}; stderr: #{e7[0, 200]})", fails)
  r7 = JSON.parse(File.read(File.join(out7, 'probe-results.json')))
  check(r7.length == 1 && r7[0]['result'] == 'PASS' && r7[0]['value'] == 'West',
        'fallback seam still auto-picks the flip and verdicts PASS', fails)
  check(pc_export_posts(log).length == 2,
        'fallback transport makes exactly the serial exports (2)', fails)
  ev7 = JSON.parse(File.read(File.join(out7, 'probe-evidence.json')))
  check(ev7['transport'] == 'serial' && ev7['doc_version'] == '5',
        'evidence sidecar records transport=serial + doc version without the pool lib', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — #7 dedup: raw export cache + version checks + pooled probes'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
