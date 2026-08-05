#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline tests for the speed workstream (refs/performance.md):
#   1. PhaseCache (lib/phase_cache.rb) — sha-stamped phase-output reuse: runs
#      the block once, skips on an unchanged key, re-runs on key change /
#      missing output, and never blesses a phase that failed to produce output.
#   2. find-or-pick-dm.rb re-entry cache — same workbook signature (+ <24h)
#      reuses dm-match.json with NO network; changed signature / stale age /
#      --refresh all fall through to a rescan.
#   3. verify-parity.rb trailing-partial-period guard — the named WARN fires
#      when the ACTUAL series' final point crashes >90% vs its prior-3 median
#      while the expectation doesn't, and stays quiet otherwise. WARN only:
#      statuses and exit codes are unchanged.
#   4. Drift guards — every mark()'d phase key has a PHASE_BUDGET entry and a
#      matching slow-<anchor> section in refs/performance.md; no unbounded
#      lane-reap loops remain in the orchestrator.
# Deterministic, no network (the negative dm-match cases point SIGMA_BASE_URL
# at an unroutable localhost port so a cache MISS fails fast instead of
# scanning). Usage: ruby scripts/test-phase-cache.rb

require 'json'
require 'time'
require 'tmpdir'
require 'open3'
require 'fileutils'
require_relative 'lib/phase_cache'

DIR     = __dir__
MIGRATE = File.join(DIR, 'migrate-tableau.rb')
PICKER  = File.join(DIR, 'find-or-pick-dm.rb')
VERIFY  = File.join(DIR, 'verify-parity.rb')
PERF_MD = File.expand_path('../refs/performance.md', DIR)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ── 1. PhaseCache semantics ──────────────────────────────────────────────────
puts '— PhaseCache.cached: sha-stamped skip semantics —'
Dir.mktmpdir do |work|
  out = File.join(work, 'derived.json')
  runs = 0
  produce = proc { runs += 1; File.write(out, '{"ok":true}') }

  st1 = PhaseCache.cached(work, 'demo-phase', key: 'k1', outputs: [out], &produce)
  check(st1 == :ran && runs == 1, "first call runs the block (got #{st1}, runs=#{runs})", fails)

  st2 = PhaseCache.cached(work, 'demo-phase', key: 'k1', outputs: [out], &produce)
  check(st2 == :reused && runs == 1, "same key + output present → :reused, block skipped (got #{st2}, runs=#{runs})", fails)

  st3 = PhaseCache.cached(work, 'demo-phase', key: 'k2', outputs: [out], &produce)
  check(st3 == :ran && runs == 2, "changed key → re-runs (got #{st3}, runs=#{runs})", fails)

  File.delete(out)
  st4 = PhaseCache.cached(work, 'demo-phase', key: 'k2', outputs: [out], &produce)
  check(st4 == :ran && runs == 3, 'missing output → re-runs even with a matching key', fails)

  # A phase that fails to produce its output is never stamped.
  noop_runs = 0
  2.times { PhaseCache.cached(work, 'broken-phase', key: 'k1', outputs: [File.join(work, 'never.json')]) { noop_runs += 1 } }
  check(noop_runs == 2, 'no output produced → not stamped → next call re-runs', fails)

  # file_sha keys change with content, and a corrupt stamp file degrades to a re-run.
  f = File.join(work, 'input.twb'); File.write(f, 'v1')
  k_a = PhaseCache.key(PhaseCache.file_sha(f), 'scope')
  File.write(f, 'v2')
  k_b = PhaseCache.key(PhaseCache.file_sha(f), 'scope')
  check(k_a != k_b, 'file_sha key changes when the input file content changes', fails)
  File.write(PhaseCache.path(work), 'not json {{{')
  check(PhaseCache.fresh?(work, 'demo-phase', key: 'k2', outputs: []) == false,
        'corrupt stamp file → fresh? false (degrades to re-run, never crashes)', fails)
end

# ── 2. find-or-pick-dm.rb re-entry cache ─────────────────────────────────────
puts '— find-or-pick-dm.rb: signature-keyed dm-match cache —'
# The negative cases MUST fail fast instead of scanning: point the API at an
# unroutable local port so any accidental network call errors immediately.
PICKER_ENV = { 'SIGMA_BASE_URL' => 'http://127.0.0.1:9', 'SIGMA_CLIENT_ID' => nil, 'SIGMA_API_TOKEN' => 'offline-test' }.freeze
SIG = { 'tableau_workbook' => 'Example Workbook',
        'warehouse_tables' => ['DB.SCHEMA.EXAMPLE_FACT'],
        'referenced_columns' => %w[ORDER_DATE REVENUE REGION],
        'measures' => [{ 'col' => 'REVENUE', 'derivation' => 'Sum' }] }.freeze

# Canonical signature hash — mirrors the picker's signature_sha (tables/columns/
# measures, sorted). Keep in lock-step with find-or-pick-dm.rb.
def sig_sha(sig)
  require 'digest'
  canon = { 'tables' => (sig['warehouse_tables'] || []).map(&:to_s).sort,
            'columns' => (sig['referenced_columns'] || []).map(&:to_s).sort,
            'measures' => (sig['measures'] || []).map { |m| "#{m['col']}/#{m['derivation']}" }.sort }
  Digest::SHA256.hexdigest(JSON.generate(canon))
end

# Read RANKING_VERSION out of the picker rather than hardcoding it, so bumping the
# ranking generation can never silently desync this fixture from the implementation.
def picker_ranking_version
  m = File.read(PICKER)[/^RANKING_VERSION\s*=\s*(\d+)/, 1]
  raise "RANKING_VERSION not found in #{PICKER}" unless m
  m.to_i
end

def run_picker(dir, extra = [])
  Open3.capture3(PICKER_ENV, 'ruby', PICKER,
                 '--workbook-signature', File.join(dir, 'workbook-signature.json'),
                 '--out', File.join(dir, 'dm-match.json'), *extra)
end

Dir.mktmpdir do |work|
  File.write(File.join(work, 'workbook-signature.json'), JSON.pretty_generate(SIG))
  # ranking_version must match the picker's current RANKING_VERSION: the re-entry
  # cache deliberately refuses to replay a recommendation computed under an older
  # candidate ranking (a stale recency-ranked result would hide the relevance fix).
  cached = { 'signature_sha256' => sig_sha(SIG), 'scanned_at' => Time.now.utc.iso8601,
             'ranking_version' => picker_ranking_version,
             'recommended_dm_id' => 'dm-example-1', 'auto_picked' => true, 'score' => 0.9,
             'rationale' => 'AUTO-PICKED (fixture)', 'candidates' => [] }
  File.write(File.join(work, 'dm-match.json'), JSON.pretty_generate(cached))

  _, err, st = run_picker(work)
  check(st.exitstatus.zero? && err.include?('dm-match REUSED'),
        "matching signature + fresh scan → REUSED, exit 0 (got exit #{st.exitstatus})", fails)

  # Cached recommendation of "build new" must reuse with the original exit 1.
  File.write(File.join(work, 'dm-match.json'),
             JSON.pretty_generate(cached.merge('recommended_dm_id' => nil, 'auto_picked' => false)))
  _, err, st = run_picker(work)
  check(st.exitstatus == 1 && err.include?('dm-match REUSED'),
        'cached "no candidate" → REUSED with the original exit 1', fails)

  # --refresh bypasses the cache (the rescan then fails fast on the dead port).
  File.write(File.join(work, 'dm-match.json'), JSON.pretty_generate(cached))
  _, err, st = run_picker(work, ['--refresh'])
  check(!err.include?('dm-match REUSED'), '--refresh bypasses the cache (attempts a rescan)', fails)

  # Changed signature → cache miss.
  sig2 = SIG.merge('referenced_columns' => %w[ORDER_DATE REVENUE REGION SEGMENT])
  File.write(File.join(work, 'workbook-signature.json'), JSON.pretty_generate(sig2))
  _, err, = run_picker(work)
  check(!err.include?('dm-match REUSED'), 'changed signature → cache miss (attempts a rescan)', fails)

  # Stale (>24h) scan → cache miss even with a matching signature.
  File.write(File.join(work, 'workbook-signature.json'), JSON.pretty_generate(SIG))
  File.write(File.join(work, 'dm-match.json'),
             JSON.pretty_generate(cached.merge('scanned_at' => (Time.now.utc - 25 * 3600).iso8601)))
  _, err, = run_picker(work)
  check(!err.include?('dm-match REUSED'), 'scan older than 24h → cache miss (the org DM set is live state)', fails)
end

# ── 3. verify-parity.rb trailing-partial-period guard ────────────────────────
puts '— verify-parity.rb: trailing-partial-period WARN —'
HEALTHY = [['2026-01', 100.0], ['2026-02', 110.0], ['2026-03', 95.0], ['2026-04', 105.0], ['2026-05', 102.0]].freeze
CRASHED = [['2026-01', 100.0], ['2026-02', 110.0], ['2026-03', 95.0], ['2026-04', 105.0], ['2026-05', 3.0]].freeze

def run_verify(dir, charts, extra = [])
  plan = File.join(dir, 'plan.json')
  File.write(plan, JSON.pretty_generate(charts))
  out, err, st = Open3.capture3('ruby', VERIFY, '--plan', plan, '--score-out', File.join(dir, 'score.json'), *extra)
  # The WARN text carries UTF-8 punctuation; a C-locale runner would otherwise
  # hand back US-ASCII-tagged strings that raise on regex match.
  [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), st]
end

Dir.mktmpdir do |work|
  # (a) Extract-mode: identical buckets, final point crashed only on the Sigma
  # side — the exact field bug: status stays PASS (drift is notes-only in
  # extract mode) but the named WARN must fire, and exit stays 0.
  out, _, st = run_verify(work, [{ 'chart' => 'Monthly Trend', 'expected' => HEALTHY,
                                   'actual' => { 'rows' => CRASHED } }], ['--extract-mode', '--extract-tol', '0.30'])
  check(out =~ /^PASS/ && st.exitstatus.zero?, 'extract-mode crashed-final chart still PASSes (WARN, not a gate)', fails)
  check(out.include?('TRAILING-PARTIAL-PERIOD WARN') && out =~ /-97% vs the prior-3-point median/,
        'named WARN fires with the drop percentage when only the actual side crashes', fails)
  score = JSON.parse(File.read(File.join(work, 'score.json')))
  check((score['tiles'][0]['warnings'] || []).any? { |w| w.start_with?('TRAILING-PARTIAL-PERIOD') },
        'score-out tile carries the warning', fails)

  # (b) Both sides crash → real data cliff, NOT a partial period: no WARN.
  out, _, = run_verify(work, [{ 'chart' => 'Real Cliff', 'expected' => CRASHED,
                                'actual' => { 'rows' => CRASHED } }])
  check(out =~ /^PASS/ && !out.include?('TRAILING-PARTIAL-PERIOD'),
        'both sides crashing → no WARN (source shows the same cliff)', fails)

  # (c) No expectation rows at all → still WARN (nothing proves the cliff is real).
  out, _, = run_verify(work, [{ 'chart' => 'No Expectation', 'expected' => [],
                                'actual' => { 'rows' => CRASHED } }])
  check(out.include?('TRAILING-PARTIAL-PERIOD WARN') && out.include?('no source expectation'),
        'missing expectation → WARN names the absent source side', fails)

  # (d) Healthy final point → quiet.
  out, _, st = run_verify(work, [{ 'chart' => 'Healthy', 'expected' => HEALTHY,
                                   'actual' => { 'rows' => HEALTHY } }])
  check(out =~ /^PASS/ && st.exitstatus.zero? && !out.include?('TRAILING-PARTIAL-PERIOD'),
        'healthy series → no WARN, PASS, exit 0', fails)

  # (e) Duplicate date keys (flattened multi-series) → ambiguous final point, no WARN.
  multi = CRASHED + [['2026-05', 400.0]]
  out, _, = run_verify(work, [{ 'chart' => 'Multi Series', 'expected' => multi,
                                'actual' => { 'rows' => multi } }])
  check(!out.include?('TRAILING-PARTIAL-PERIOD'), 'duplicate date keys (multi-series) → no WARN', fails)

  # (f) Non-date dimension → not a time series, no WARN.
  cat = [%w[North], %w[South], %w[East], %w[West]].map.with_index { |r, i| [r[0], i == 3 ? 1.0 : 100.0] }
  out, _, = run_verify(work, [{ 'chart' => 'By Region', 'expected' => cat, 'actual' => { 'rows' => cat } }])
  check(!out.include?('TRAILING-PARTIAL-PERIOD'), 'categorical dimension → no WARN', fails)

  # (g) Strict mode: the WARN rides along with a DIVERGE without changing it.
  out, _, st = run_verify(work, [{ 'chart' => 'Strict Crash', 'expected' => HEALTHY,
                                   'actual' => { 'rows' => CRASHED } }])
  check(out =~ /^DIVERGE/ && st.exitstatus == 1 && out.include?('TRAILING-PARTIAL-PERIOD WARN'),
        'strict mode: WARN appended to the DIVERGE report, status/exit unchanged', fails)
end

# ── 4. Drift guards: budgets ↔ mark keys ↔ performance.md anchors ────────────
puts '— drift guards: PHASE_BUDGET / mark keys / performance.md anchors —'
src = File.read(MIGRATE, encoding: 'UTF-8')
mark_keys = (src.scan(/mark\('([^']+)'\)/).flatten +
             src.scan(/PHASE_T\['([^']+)'\]\s*=/).flatten).uniq
budget_keys = src[/PHASE_BUDGET\s*=\s*\{(.*?)\}\.freeze/m, 1].to_s.scan(/'([^']+)'\s*=>/).flatten
missing_budget = mark_keys - budget_keys
check(missing_budget.empty?, "every mark()'d phase has a PHASE_BUDGET entry (missing: #{missing_budget.join(', ')})", fails)

perf = File.exist?(PERF_MD) ? File.read(PERF_MD, encoding: 'UTF-8') : ''
check(!perf.empty?, 'refs/performance.md exists', fails)
missing_anchor = budget_keys.reject do |k|
  anchor = k.gsub(/[^A-Za-z0-9]+/, '-').gsub(/\A-|-\z/, '').downcase
  perf.include?("### slow-#{anchor}")
end
check(missing_anchor.empty?, "every budgeted phase has a slow-<anchor> section in performance.md (missing: #{missing_anchor.join(', ')})", fails)
check(perf.include?('NEVER restart the orchestrator'), 'performance.md states the cardinal no-restart rule', fails)

# No unbounded lane-reap loops left in the orchestrator (poll-bounds audit).
check(!src.match?(/sleep 0\.1 until lane_done/), 'no raw unbounded `sleep 0.1 until lane_done` reap loops remain', fails)
check(src.include?('def reap_lane!'), 'bounded reap_lane! helper present', fails)
check(src.include?("require_relative 'lib/phase_cache'"), 'orchestrator wires lib/phase_cache', fails)
%w[parse-twb-layout calc-fields custom-sql].each do |ph|
  check(src.include?("'#{ph}'"), "orchestrator stamps the #{ph} phase", fails)
end

puts
if fails.empty?
  puts 'ALL PASS — phase-cache reuse, dm-match cache, trailing-period guard, and budget drift guards behave correctly'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
