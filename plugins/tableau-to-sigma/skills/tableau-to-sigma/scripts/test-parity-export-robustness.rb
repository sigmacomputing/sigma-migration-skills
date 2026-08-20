#!/usr/bin/env ruby
# frozen_string_literal: true
# Parity/export-robustness bundle (issue #422). Three items, one coherent PR:
#
#   1. SPEED — pivot CSV-export 500 → JSON-export fallback in
#      collect-parity-actuals.rb. Sigma's element CSV export 500s server-side
#      for any pivot carrying a `totals` key; the JSON export is unaffected and
#      returns long-form rows. Two automatic paths (no agent mediation, no
#      retry loop against the doomed CSV):
#        * PROACTIVE — the workbook spec shows a `totals` key → skip the CSV
#          round-trip entirely and read JSON straight away (the recurring time
#          sink this removes).
#        * REACTIVE — a CSV 5xx we couldn't foresee falls back to JSON.
#      Only if the JSON export ALSO 5xx's does the render-verify marker apply.
#
#   2. Live-drift auto-warn. collect-parity-actuals stamps nothing new but reads
#      the plan's source-capture time (source_csv_max_mtime) and emits a LOUD
#      advisory WARN when the Sigma actuals are collected > N minutes later
#      (default 30, --drift-warn-minutes / $PARITY_DRIFT_WARN_MINUTES; 0 = off).
#      Advisory, never a gate.
#
#   3. Finalize-flag ergonomics — migrate-tableau.rb --finalize now forwards
#      --regen-plan (→ phase6-parity.rb), which phase6-parity already accepts.
#
# The Sigma REST layer is stubbed per element+format; no network. Every export
# POST (element id + format + rowLimit) is logged so we can prove the CSV
# round-trip is SKIPPED for a totals pivot and never retried.
#   ruby scripts/test-parity-export-robustness.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPTS = __dir__
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', SCRIPTS)
RENDER_VERIFY_REASON = 'pivot CSV export 500/empty (known Sigma limitation)'
COLLECT = File.join(SCRIPTS, 'collect-parity-actuals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Stub sigma_rest: loaded FIRST (ruby -I <stub> -r sigma_rest); it then marks the
# real lib as already-required so the script's own `require 'sigma_rest'` no-ops.
# POST /export logs {eid, fmt, rowLimit} to STUB_LOG and returns a format-tagged
# queryId; GET /query/<qid>/download serves the body for that queryId.
#   el-ok          → CSV works (bar chart)
#   el-piv500      → CSV 500s, JSON works (REACTIVE fallback → real rows)
#   el-totals      → carries a `totals` key; JSON works (PROACTIVE — no CSV POST)
#   el-both500     → CSV 500s AND JSON 500s (→ render-verify marker)
STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    @counts = Hash.new(0) # per-process call counters (one collect run = one process)
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if method == :post && path.include?('/export')
        req = JSON.parse(body)
        eid = req['elementId']
        fmt = req.dig('format', 'type')
        @counts["post:#{eid}:#{fmt}"] += 1
        File.open(ENV['STUB_LOG'], 'a') do |f|
          f.puts(JSON.generate('eid' => eid, 'fmt' => fmt, 'rowLimit' => req['rowLimit']))
        end
        if fmt == 'csv'
          raise Error, "POST #{path} -> 500 Internal Server Error\n{}" if %w[el-piv500 el-both500 el-totals].include?(eid)
          return { 'queryId' => "#{eid}::csv" }
        else # json
          raise Error, "POST #{path} -> 500 Internal Server Error\n{}" if eid == 'el-both500'
          return { 'queryId' => "#{eid}::json" }
        end
      end
      if method == :get && path.start_with?('/v2/query/')
        qid = path.split('/')[3]
        @counts["get:#{qid}"] += 1
        File.open(ENV['STUB_LOG'], 'a') { |f| f.puts(JSON.generate('download' => qid)) }
        case qid
        when 'el-ok::csv'      then return "Region,Revenue\nEast,100\nWest,200\n"
        when 'el-piv500::json' then return JSON.generate([{ 'Region' => 'East', 'Revenue' => 100 },
                                                          { 'Region' => 'West', 'Revenue' => 200 }])
        when 'el-totals::json' then return JSON.generate([{ 'Quarter' => 'Q1', 'Net' => 10 },
                                                          { 'Quarter' => 'Q2', 'Net' => 20 }])
        when 'el-204::csv'
          # E3.1: a still-rendering export downloads as a 204 / EMPTY body —
          # the poller must keep polling with backoff, never fail, never retry
          # the export. Serve two empty bodies, then the real CSV.
          return '' if @counts['get:el-204::csv'] <= 2
          return "Region,Revenue\nEast,100\nWest,200\n"
        when 'el-flaky::csv'
          # E3.1 contrast case: a RETRYABLE 5xx on the download IS a failure —
          # it must count toward the bounded retry budget (fresh export POST).
          raise Error, "GET #{path} -> 503 Service Unavailable\n{}" if @counts['post:el-flaky:csv'] == 1
          return "Region,Revenue\nEast,100\nWest,200\n"
        end
      end
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def workbook_spec(elements)
  {
    'document' => {
      'schemaVersion' => 4,
      'kind' => 'workbook',
      'pages' => [{ 'id' => 'p1', 'name' => 'Overview' }],
      'elements' => elements,
      'layout' => "<Page id=\"p1\">#{elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
    }
  }
end

SPEC = workbook_spec([
  { 'id' => 'el-ok',      'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v', 'name' => 'Revenue' }] },
  { 'id' => 'el-piv500',  'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v', 'name' => 'Revenue' }] },
  # A pivot carrying a totals key — CSV export would 500; collect must go
  # straight to JSON without ever POSTing the CSV export.
  { 'id' => 'el-totals',  'totals' => { 'showGrandTotals' => true },
    'columns' => [{ 'id' => 'c-q', 'name' => 'Quarter' }, { 'id' => 'c-n', 'name' => 'Net' }] },
  { 'id' => 'el-both500', 'columns' => [{ 'id' => 'c-a', 'name' => 'A' }, { 'id' => 'c-b', 'name' => 'B' }] }
]).freeze

PLAN_CHARTS = [
  { 'chart' => 'OK Chart',       'sigma_kind' => 'bar-chart', 'sigma_element_id' => 'el-ok',      'sigma_columns' => %w[c-r c-v] },
  { 'chart' => 'Pivot 500',      'sigma_kind' => 'table',     'sigma_element_id' => 'el-piv500',  'sigma_columns' => %w[c-r c-v] },
  { 'chart' => 'Totals Pivot',   'sigma_kind' => 'table',     'sigma_element_id' => 'el-totals',  'sigma_columns' => %w[c-q c-n] },
  { 'chart' => 'Both 500',       'sigma_kind' => 'table',     'sigma_element_id' => 'el-both500', 'sigma_columns' => %w[c-a c-b] }
].freeze

def run_collect(dir, extra_env, *extra_args)
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir) unless Dir.exist?(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub' }.merge(extra_env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', COLLECT, *extra_args)
end

# ============================================================================
# Part 1 — pivot CSV 500 → JSON fallback (SPEED win)
# ============================================================================
puts '-- Part 1: pivot CSV-export 500 → JSON fallback --'
Dir.mktmpdir do |dir|
  plan_path = File.join(dir, 'parity-plan.json')
  spec_path = File.join(dir, 'wb-readback.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  log       = File.join(dir, 'stub-log.jsonl')
  # Fresh source capture (now) so the drift advisory stays silent here.
  File.write(plan_path, JSON.pretty_generate('charts' => PLAN_CHARTS, 'source_csv_max_mtime' => Time.now.to_i))
  File.write(spec_path, JSON.pretty_generate(SPEC))

  out, err, st = run_collect(dir, { 'STUB_LOG' => log },
                             '--plan', plan_path, '--workbook-id', 'wb',
                             '--workbook-spec', spec_path, '--out', out_path)
  check(st.success?, "collect exits 0 (got #{st.exitstatus}: #{err.lines.grep(/rror/).first})", fails)
  actuals = JSON.parse(File.read(out_path))

  check(actuals['OK Chart'] == [['East', 100.0], ['West', 200.0]], 'healthy CSV chart collected as rows', fails)
  check(actuals['Pivot 500'] == [['East', 100.0], ['West', 200.0]],
        "REACTIVE: CSV 500 → JSON fallback → correct rows (got #{actuals['Pivot 500'].inspect})", fails)
  check(actuals['Totals Pivot'] == [['Q1', 10.0], ['Q2', 20.0]],
        "PROACTIVE: totals pivot → JSON → correct rows (got #{actuals['Totals Pivot'].inspect})", fails)
  check(actuals['Both 500'] == { 'status' => 'render-verify-required', 'reason' => RENDER_VERIFY_REASON },
        'CSV 500 AND JSON 500 → render-verify marker (safety net preserved)', fails)

  posts = File.readlines(log).map { |l| JSON.parse(l) }
  # PROACTIVE speed win: the totals pivot never wastes a CSV export round-trip.
  totals_posts = posts.select { |p| p['eid'] == 'el-totals' }
  check(totals_posts.map { |p| p['fmt'] } == ['json'],
        "totals pivot: NO CSV export POST, exactly one JSON POST (got #{totals_posts.map { |p| p['fmt'] }.inspect})", fails)
  # NO RETRY LOOP: a CSV 500 is attempted exactly once before the JSON fallback.
  piv500_csv = posts.select { |p| p['eid'] == 'el-piv500' && p['fmt'] == 'csv' }
  piv500_json = posts.select { |p| p['eid'] == 'el-piv500' && p['fmt'] == 'json' }
  check(piv500_csv.length == 1, "reactive path: CSV 500 tried once, NOT retried (got #{piv500_csv.length})", fails)
  check(piv500_json.length == 1, 'reactive path: exactly one JSON fallback POST', fails)
  # bounded rowLimit still carried on the JSON export.
  check(piv500_json.first['rowLimit'] == 100_000, 'JSON export carries the bounded rowLimit', fails)
end

# ============================================================================
# Part 1b — E3.1 retry honesty: a 204/empty download stream is STILL-RENDERING
# (poll-with-backoff, NEVER a retry-counter increment / re-export), while a
# RETRYABLE 5xx IS a failure that counts toward the bounded retry budget.
# PLAN-v4 E3.1 acceptance (stubbed export seam, offline).
# ============================================================================
puts '-- Part 1b: E3.1 — 204 stream never increments the retry counter; a 5xx does --'
SPEC_204 = workbook_spec([
  { 'id' => 'el-204',   'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v', 'name' => 'Revenue' }] },
  { 'id' => 'el-flaky', 'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v', 'name' => 'Revenue' }] }
]).freeze
PLAN_204 = [
  { 'chart' => 'Slow Render', 'sigma_kind' => 'bar-chart', 'sigma_element_id' => 'el-204',   'sigma_columns' => %w[c-r c-v] },
  { 'chart' => 'Flaky 503',   'sigma_kind' => 'bar-chart', 'sigma_element_id' => 'el-flaky', 'sigma_columns' => %w[c-r c-v] }
].freeze
Dir.mktmpdir do |dir|
  plan_path = File.join(dir, 'parity-plan.json')
  spec_path = File.join(dir, 'wb-readback.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  log       = File.join(dir, 'stub-log.jsonl')
  File.write(plan_path, JSON.pretty_generate('charts' => PLAN_204, 'source_csv_max_mtime' => Time.now.to_i))
  File.write(spec_path, JSON.pretty_generate(SPEC_204))

  _out, err, st = run_collect(dir, { 'STUB_LOG' => log },
                              '--plan', plan_path, '--workbook-id', 'wb',
                              '--workbook-spec', spec_path, '--out', out_path)
  check(st.success?, "collect exits 0 (got #{st.exitstatus}: #{err.lines.grep(/rror/).first})", fails)
  actuals = JSON.parse(File.read(out_path))
  check(actuals['Slow Render'] == [['East', 100.0], ['West', 200.0]],
        '204/empty stream → kept polling → rows collected (never marked failed/empty)', fails)
  check(actuals['Flaky 503'] == [['East', 100.0], ['West', 200.0]],
        '503 then success → retried within budget → rows collected', fails)

  lines = File.readlines(log).map { |l| JSON.parse(l) }
  posts_204   = lines.select { |p| p['eid'] == 'el-204' && p['fmt'] == 'csv' }
  posts_flaky = lines.select { |p| p['eid'] == 'el-flaky' && p['fmt'] == 'csv' }
  polls_204   = lines.select { |p| p['download'] == 'el-204::csv' }
  check(posts_204.length == 1,
        "204 stream NEVER increments the retry counter — exactly ONE export POST (got #{posts_204.length})", fails)
  check(polls_204.length >= 3,
        "the empty bodies were POLLED through, not failed (#{polls_204.length} download attempts >= 3)", fails)
  check(posts_flaky.length == 2,
        "a RETRYABLE 5xx DOES count toward the retry budget — fresh export POST on retry (got #{posts_flaky.length})", fails)
end

# ============================================================================
# Part 2 — live-drift advisory WARN (past threshold loud, within silent)
# ============================================================================
puts '-- Part 2: live-drift advisory --'
DRIFT_RE = /LIVE-DRIFT RISK/
def drift_run(env_extra, *args)
  Dir.mktmpdir do |dir|
    plan_path = File.join(dir, 'parity-plan.json')
    spec_path = File.join(dir, 'wb-readback.json')
    out_path  = File.join(dir, 'parity-actuals.json')
    File.write(plan_path, JSON.pretty_generate('charts' => [], 'source_csv_max_mtime' => yield))
    File.write(spec_path, JSON.pretty_generate(
                           'document' => {
                             'schemaVersion' => 4,
                             'kind' => 'workbook',
                             'pages' => [],
                             'elements' => [],
                             'layout' => ''
                           }))
    _o, err, st = run_collect(dir, env_extra.merge('STUB_LOG' => File.join(dir, 'log.jsonl')),
                              '--plan', plan_path, '--workbook-id', 'wb',
                              '--workbook-spec', spec_path, '--out', out_path, *args)
    [err, st]
  end
end

err, st = drift_run({}) { (Time.now - 40 * 60).to_i } # 40 min old, default 30 min threshold
check(st.success?, 'drift run still exits 0 (advisory, never a gate)', fails)
check(err.match?(DRIFT_RE), 'source captured 40 min ago (> 30) → loud WARN fires', fails)
check(err.include?('synchronized recapture') && err.include?('--regen-plan'),
      'WARN names the drift risk AND the synchronized-recapture remedy', fails)

err, _st = drift_run({}) { Time.now.to_i } # fresh capture
check(!err.match?(DRIFT_RE), 'fresh capture → NO warn (byte-identical to main path)', fails)

err, _st = drift_run({}, '--drift-warn-minutes', '60') { (Time.now - 40 * 60).to_i } # below higher threshold
check(!err.match?(DRIFT_RE), 'gap below --drift-warn-minutes threshold → silent', fails)

err, _st = drift_run({}, '--drift-warn-minutes', '0') { (Time.now - 999 * 60).to_i } # disabled
check(!err.match?(DRIFT_RE), '--drift-warn-minutes 0 disables the advisory entirely', fails)

err, _st = drift_run({ 'PARITY_DRIFT_WARN_MINUTES' => '5' }) { (Time.now - 10 * 60).to_i } # env lowers default
check(err.match?(DRIFT_RE), '$PARITY_DRIFT_WARN_MINUTES lowers the default threshold (10 > 5 → warn)', fails)

# ============================================================================
# Part 3 — finalize-flag ergonomics: migrate-tableau forwards --regen-plan
# ============================================================================
puts '-- Part 3: finalize-flag forwarding --'
migrate_src = File.read(File.join(SCRIPTS, 'migrate-tableau.rb'))
phase6_src  = File.read(File.join(SCRIPTS, 'phase6-parity.rb'))

check(migrate_src.include?("o.on('--regen-plan'"), 'migrate-tableau ACCEPTS --regen-plan', fails)
check(migrate_src.scan(/p6 \+= \['--regen-plan'\] if opts\[:regen_plan\]/).length >= 2,
      '--regen-plan forwarded to phase6-parity on BOTH the pass-1 and finalize invocations', fails)
# Receiver already accepts it (regression guard against a silent rename).
check(phase6_src.include?("p.on('--regen-plan'"), 'phase6-parity still accepts --regen-plan', fails)

puts
if fails.empty?
  puts 'ALL PASS — parity/export robustness bundle (JSON fallback · drift advisory · finalize flags)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
