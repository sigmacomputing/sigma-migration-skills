#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the same-failure loop breaker (PR-2 field-ops; PR-507
# finding-1A redesign: mode + progress measure + attempt cap).
#
# Offramp.loop_check appends a caller-supplied failure signature to
# <WORK>/loop-log.jsonl and returns :first / :stop / :cap. Three stop rules:
# a VERBATIM signature repeat (identical or reordered failure — stop at 2, as
# before), the same failure MODE recurring WITHOUT strict improvement over the
# best progress measure yet seen (growing / oscillating / churning — stop at
# 2; a CONVERGING 5→3→2→1 repair loop improves every attempt and never
# stops), and the unconditional per-scope SIGMA_LOOP_ATTEMPT_CAP budget.
# Signatures are built from the NORMALIZED error text — identifiers (paths /
# quoted names / brackets / file:line / mixed-alnum ids) become placeholders
# while BARE INTEGERS SURVIVE as the measure — plus the multi-line error
# REGION digest ([FAIL] summary + sorted ✗-detail + an overflow trailer
# carrying the count of lines past the region cap), so a repair patch that
# shuffles which element fails first cannot mint a fresh signature, while two
# genuinely different failure states no longer collapse into one.
# verify-complete.rb refuses completion (exit 5) over a 2-count signature OR a
# stop-stamped record (S2/S3 stop without any signature repeating). Counting
# is post-reset: a GREEN finalize appends a {'reset'} record
# (Offramp.loop_reset) and counting restarts after it. The trajectory matrix
# below drives the REAL assert-wb-refs-resolve.rb child (offline --dm-ids
# mode) so every multi-line emission shape is the shipped one, not a hand-
# written string. Offline.
#
# Usage: ruby scripts/test-offramp-loop.rb

require 'json'
require 'tmpdir'
require 'open3'

DIR = __dir__
require_relative 'lib/offramp'
VC = File.join(DIR, 'verify-complete.rb')
GATE = File.join(DIR, 'assert-wb-refs-resolve.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# Run the REAL ref gate (offline --dm-ids mode) against a spec whose refs to
# `missing` columns cannot resolve — the exact multi-line
# [FAIL]-summary-then-✗-detail emission the exit-4 breaker consumes. Detail
# lines print in formula order, so `missing` order controls report order.
def run_ref_gate(dir, missing, resolving: %w[Alpha Bravo Charlie])
  ids = { 'elements' => [{ 'id' => 'el-dm', 'columnLabels' => resolving }] }
  formula = (resolving + missing).map { |c| "[Master/#{c}]" }.join(' + ')
  spec = { 'pages' => [{ 'elements' => [{ 'id' => 'el-1', 'name' => 'Chart',
                                          'kind' => 'bar', 'formula' => formula }] }] }
  File.write(File.join(dir, 'dm-ids.json'), JSON.generate(ids))
  File.write(File.join(dir, 'wb-spec.json'), JSON.generate(spec))
  out, st = Open3.capture2e('ruby', GATE, '--wb-spec', File.join(dir, 'wb-spec.json'),
                            '--dm-ids', File.join(dir, 'dm-ids.json'))
  # The capture arrives tagged with the LOCALE encoding (US-ASCII under a C
  # locale) while the gate emits UTF-8 (— and ✗) — retag so this suite's own
  # comparisons don't raise; the lib under test scrubs for itself.
  out = out.force_encoding(Encoding::UTF_8)
  [out.valid_encoding? ? out : out.scrub('?'), st]
end

# The exit-4 call site's exact processing chain (migrate-tableau.rb): region →
# mode + measure + signature → loop_check under the exit4 cap scope.
EXIT4_VERDICT = lambda do |wd, out|
  region = Offramp.error_region(out)
  mode = Offramp.failure_mode(script: 'migrate-tableau', context: 'exit4',
                              exit_code: { handoff: 4, child: 1 },
                              error_class: 'WorkbookBuildError', error_region: region)
  sig = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4',
                                  exit_code: { handoff: 4, child: 1 },
                                  error_class: 'WorkbookBuildError',
                                  error_line: Offramp.first_error_line(out),
                                  error_region: region)
  verdict = Offramp.loop_check(wd, signature: sig, mode: mode,
                               measure: Offramp.region_measure(region),
                               scope: 'migrate-tableau:exit4')
  [verdict, sig, mode]
end

Dir.mktmpdir do |wd|
  sig_a = 'migrate-tableau:exit4:exit=4:WorkbookBuildError:aaaa11112222'
  sig_b = 'migrate-tableau:finalize:phase6=2:gate=7'

  # occurrence ladder: :first -> :stop (second occurrence) — a third identical
  # attempt must never be reachable, so 2 is already :stop (and stays :stop)
  check(Offramp.loop_check(wd, signature: sig_a) == :first, 'first occurrence => :first', fails)
  check(Offramp.loop_check(wd, signature: sig_a) == :stop,  'same signature twice => :stop (stop-at-2)', fails)
  check(Offramp.loop_check(wd, signature: sig_a) == :stop,  'third occurrence stays :stop', fails)

  # two DIFFERENT signatures do NOT stop — each counts independently
  check(Offramp.loop_check(wd, signature: sig_b) == :first, 'different signature => :first (no cross-trip)', fails)
  check(Offramp.loop_check(wd, signature: sig_b) == :stop,  'different signature stops independently at 2', fails)

  # the log is structured + readable back
  trail = Offramp.loop_trail(wd)
  check(trail.size == 5, "loop-log carries all 5 records (got #{trail.size})", fails)
  check(trail.all? { |r| r['signature'] && r['at'] =~ /\d{4}-\d\d-\d\dT/ }, 'records carry signature + timestamp', fails)
  counts = Offramp.loop_counts(wd)
  check(counts[sig_a] == 3 && counts[sig_b] == 2, 'loop_counts tallies per signature', fails)

  # never fatal on a missing workdir
  begin
    check(Offramp.loop_check('/no/such/dir/really', signature: 'x') == :first,
          'missing workdir => :first, no raise', fails)
  rescue StandardError => e
    check(false, "missing workdir raised: #{e.class}", fails)
  end
end

# signature normalization: two attempts failing the SAME WAY — raw first lines
# differing only in element ids / quoted names / paths / counts — must produce
# ONE signature, so the second attempt is already :stop
Dir.mktmpdir do |wd|
  line1 = 'Dependency not found: element k9Xy2Qw81 "Sales by Region" at /work/out-1/wb-spec.json:412'
  line2 = 'Dependency not found: element p3Ab7Zt45 "Profit Trend" at /work/out-2/wb-spec.json:87'
  sig1 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError', error_line: line1)
  sig2 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError', error_line: line2)
  check(sig1 == sig2, 'id/quoted-name/path churn normalizes to ONE signature', fails)
  check(Offramp.loop_check(wd, signature: sig1) == :first, 'normalized signature, first attempt => :first', fails)
  check(Offramp.loop_check(wd, signature: sig2) == :stop,  'same failure with shuffled ids => :stop at attempt 2', fails)

  # a genuinely DIFFERENT failure mode still gets its own signature
  sig3 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError',
                                   error_line: 'invalid formula: unknown function DATEPARSE')
  check(sig3 != sig1, 'a different failure MODE keeps a distinct signature', fails)
  check(Offramp.loop_check(wd, signature: sig3) == :first, 'distinct failure mode => :first (no cross-trip)', fails)

  # a different error class alone is a different signature
  sig4 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'RuntimeError', error_line: line1)
  check(sig4 != sig1, 'error class is part of the signature key', fails)

  # Hash exit codes reproduce the structural finalize signature format
  fsig = Offramp.failure_signature(script: 'migrate-tableau', context: 'finalize',
                                   exit_code: { phase6: 2, gate: 7 })
  check(fsig == 'migrate-tableau:finalize:phase6=2:gate=7',
        "finalize signature keeps its structural format (got #{fsig})", fails)

  # first_error_line picks the ERROR line, not the leading report line: two
  # captures sharing a stable NORMALIZE: lead but naming DIFFERENT defects
  # must yield DISTINCT signatures (first-line hashing collided them) …
  norm_lead = 'NORMALIZE: columns/3: "round" -> "Round" (report-only — apply via FormulaNormalize)'
  cap_a = "#{norm_lead}\nERROR: unknown column \"Ship Speed\" referenced by element el-1\n"
  cap_b = "#{norm_lead}\nERROR: page \"Overview\" mixes master table(s) [M] with 2 chart\n"
  el_a = Offramp.first_error_line(cap_a)
  el_b = Offramp.first_error_line(cap_b)
  check(el_a.start_with?('ERROR:') && el_b.start_with?('ERROR:'),
        'first_error_line skips the NORMALIZE report line and returns the ERROR line', fails)
  sa = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                 error_class: 'WorkbookBuildError', error_line: el_a)
  sb = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                 error_class: 'WorkbookBuildError', error_line: el_b)
  check(sa != sb, 'identical report lead + DIFFERENT ERROR lines => DISTINCT signatures', fails)
  # … and the inverse hazard: dropping the leading warning while the SAME
  # error persists must NOT mint a fresh signature
  cap_a2 = "ERROR: unknown column \"Ship Speed\" referenced by element el-9\n"
  sa2 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                  error_class: 'WorkbookBuildError',
                                  error_line: Offramp.first_error_line(cap_a2))
  check(sa2 == sa, 'removing the leading warning keeps the SAME signature for the same error', fails)
  check(Offramp.first_error_line("  progress line one\n  progress line two\n") == 'progress line one | progress line two',
        'no error-shaped line => falls back to the WHOLE output collapsed, not the first line', fails)
  # the fallback must DISCRIMINATE: no error-shaped line anywhere (e.g. bare
  # interpreter backtraces) with a STABLE lead line but different tails is two
  # DIFFERENT failures — a first-line fallback would falsely collide them …
  nf_a = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError',
                                   error_line: Offramp.first_error_line("stable progress lead\nwb-build.rb:41:in call: nil deref\n"))
  nf_b = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError',
                                   error_line: Offramp.first_error_line("stable progress lead\ntimeout waiting for readback\n"))
  check(nf_a != nf_b, 'no-error-line fallback: stable lead + different tails => DISTINCT signatures (no false stop)', fails)
  # … while digit/id churn in the SAME un-shaped failure still merges to one
  # signature (normalization applies to the collapsed output too)
  nf_a2 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                    error_class: 'WorkbookBuildError',
                                    error_line: Offramp.first_error_line("stable progress lead\nwb-build.rb:99:in call: nil deref\n"))
  check(nf_a2 == nf_a, 'no-error-line fallback: same failure with digit churn => ONE signature (still stops at 2)', fails)
  check(Offramp.first_error_line('') .nil? && Offramp.first_error_line(nil).nil?,
        'empty/nil output => nil (caller falls back to e.message)', fails)

  # an apostrophe contraction must NOT pair with a quoted name's opening quote
  # (that would leak the churn-prone name past <name> and re-mint signatures)
  c1 = Offramp.normalize_error_line("can't resolve field 'Sales LY' in workbook")
  c2 = Offramp.normalize_error_line("can't resolve field 'Profit Margin' in workbook")
  check(c1 == c2 && !c1.include?('Sales'),
        "contraction + quoted name still normalizes to one shape (got #{c1.inspect})", fails)

  # invalid UTF-8 from captured child output (cp1252/Latin-1 accented field
  # names) must never raise — and same-shaped lines still merge to ONE signature
  bad1 = "field \xE9tat 'Sales' unresolved".dup.force_encoding('UTF-8')
  bad2 = "field \xE9tat 'Profit' unresolved".dup.force_encoding('UTF-8')
  begin
    check(!bad1.valid_encoding? &&
          Offramp.normalize_error_line(bad1) == 'field ?tat <name> unresolved',
          'invalid-UTF-8 error line normalizes (scrubbed) instead of raising', fails)
    s1 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError', error_line: bad1)
    s2 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError', error_line: bad2)
    check(s1 == s2, 'two same-shaped invalid-UTF-8 failures merge to one signature', fails)
    check(Offramp.loop_check(wd, signature: s1) == :first &&
          Offramp.loop_check(wd, signature: s2) == :stop,
          'invalid-UTF-8 failure loop still stops at attempt 2', fails)
  rescue StandardError => e
    check(false, "invalid-UTF-8 error line raised: #{e.class}", fails)
  end
end

# ── Green reset semantics (loop_reset re-arms the breaker) ──────────────────
Dir.mktmpdir do |wd|
  sig = 'migrate-tableau:finalize:phase6=2:gate=7:cleanup=0'
  check(Offramp.loop_check(wd, signature: sig) == :first, 'pre-reset: first occurrence => :first', fails)
  check(Offramp.loop_check(wd, signature: sig) == :stop,  'pre-reset: second occurrence => :stop', fails)
  Offramp.loop_reset(wd, run_id: 'run-1')
  check(Offramp.loop_counts(wd).empty?, 'after a green reset, loop_counts is empty (post-reset window)', fails)
  check(Offramp.loop_check(wd, signature: sig) == :first,
        'the SAME signature after a green reset => :first again (re-armed, no false STOP)', fails)
  check(Offramp.loop_check(wd, signature: sig) == :stop,
        'stop-at-2 still enforced within the post-reset window', fails)
  trail = Offramp.loop_trail(wd)
  check(trail.size == 5 && trail.count { |r| r['reset'] } == 1,
        "reset is append-only: full trail keeps all records incl. the reset (got #{trail.size})", fails)
  check(trail.find { |r| r['reset'] }['run_id'] == 'run-1',
        'reset record carries the run_id stamp (E5.19 reset-defense hook)', fails)
  check(Offramp.loop_active_trail(wd).size == 2, 'active trail counts only post-reset entries', fails)
  # a reset on an empty/absent log is a no-op (no record minted, no raise)
  Dir.mktmpdir do |wd2|
    Offramp.loop_reset(wd2)
    check(Offramp.loop_trail(wd2).empty?, 'reset with nothing to re-arm appends nothing', fails)
  end
  begin
    Offramp.loop_reset('/no/such/dir/really')
    check(true, 'reset on a missing workdir is a silent no-op', fails)
  rescue StandardError => e
    check(false, "reset on a missing workdir raised: #{e.class}", fails)
  end
end

# ── Orchestrator wiring pins (house pattern: test-reuse-selfheal.rb) ────────
# The blocks above prove Offramp semantics in isolation; these pin
# migrate-tableau.rb's two call sites to them, so reverting to raw error-line
# hashing, dropping the error class, or re-gating on the retired :second value
# cannot pass this suite. Order pin: inside the WorkbookBuildError rescue, the
# loop-stop offramp record and the hard `exit 4` must PRECEDE the EXIT-4
# handoff prose — the retry instructions a third invocation would follow.
# (explicit encoding: the source is UTF-8 prose; a C/US-ASCII locale must not
# make these pins raise on it)
src = File.read(File.join(DIR, 'migrate-tableau.rb'), encoding: 'UTF-8')
check(src.include?("Offramp.failure_signature(script: 'migrate-tableau', context: 'finalize'"),
      'finalize call site builds its signature via Offramp.failure_signature', fails)
check(src.include?('cleanup: clst.exitstatus'),
      'finalize signature keys the cleanup gate too (a cleanup-only NOT-GREEN is not "phase6=0:gate=0")', fails)
check(src.include?("context: 'exit4'") && src.include?('error_class: e.class'),
      'exit-4 call site keys script + context + error class', fails)
check(src.include?('handoff: 4, child: _child_exit'),
      'exit-4 signature keys the failing CHILD exit status, not just the handoff 4', fails)
check(src.include?('Offramp.first_error_line(e.captured_output)'),
      'exit-4 call site signatures the first ERROR line (not the first output line)', fails)
check(src.include?('Offramp.loop_reset(WORK)'),
      'a green finalize re-arms the breaker via Offramp.loop_reset', fails)
check(!src.include?('Digest::SHA1'),
      'orchestrator never hashes an error line itself (no raw Digest::SHA1)', fails)
check(src.scan(/Offramp\.loop_check\(WORK, signature: _\w+, /).size == 2 &&
      src.include?("scope: 'migrate-tableau:exit4'") &&
      src.include?("scope: 'migrate-tableau:finalize'"),
      'both call sites pass an explicit attempt-cap scope to loop_check', fails)
check(src.scan(/_\w*verdict != :first/).size == 2,
      'both call sites act on :stop AND :cap (not a bare == :stop)', fails)
check(src.include?('mode: _mode, measure: _measure'),
      'exit-4 site passes the failure MODE + progress measure (converge-vs-grind rule)', fails)
check(src.include?('_err_region = [_err_line.to_s] if _err_region.empty?'),
      'exit-4 site keeps a region fallback for crash-before-output captures', fails)
check(src.include?('dsfilters: dsfst.exitstatus'),
      'finalize signature keys the ds-filters gate too (N1: it decides all_green)', fails)
check(src.include?('error_region: _fregion'),
      'finalize signature carries the failing child\'s error region, not exit codes alone', fails)
check(!src.include?('This EXACT finalize failure') &&
      !src.include?('The SAME workbook-build failure'),
      'stop banners no longer claim SAME/EXACT failure identity beyond what the signature keys', fails)
ridx = src.index('rescue WorkbookBuildError')
check(!ridx.nil?, 'WorkbookBuildError rescue present', fails)
stop_log_at  = ridx && src.index("Offramp.log(WORK, kind: 'loop-stop'", ridx)
stop_exit_at = ridx && src.index('exit 4', ridx)
handoff_at   = ridx && src.index('EXIT 4 — WORKBOOK HANDOFF', ridx)
check(stop_log_at && stop_exit_at && handoff_at &&
      stop_log_at < handoff_at && stop_exit_at < handoff_at,
      'loop-stop record + hard exit 4 precede the EXIT-4 handoff instructions', fails)
# A loop STOP is still an orchestrator STOP: it must mint the manual-path
# token before its exit, or a stop whose attempt-1 handoff never wrote the
# token (crash between loop_check and authorize) strands the operator's
# sanctioned --reuse-dm/--wb-spec re-entry behind the manual-spec gate.
stop_auth_at = ridx && src.index("authorize_manual_path!(via: 'loop-stop'", ridx)
check(stop_auth_at && stop_exit_at && stop_auth_at < stop_exit_at,
      'a loop STOP mints the manual-path token BEFORE its exit 4 (re-entry never stranded)', fails)

# verify-complete refuses completion over a tripped/breached loop-log — even
# with a success marker on disk (a green claim over a grind loop is invalid).
# Threshold is 2+ (PLAN E5.1: landed in the same PR as the stop-at-2 breaker);
# the breach-by-3 fixture pins that a deeper breach still refuses.
Dir.mktmpdir do |wd|
  sig = 'migrate-tableau:exit4:exit=4:WorkbookBuildError:aaaa11112222'
  3.times { Offramp.loop_check(wd, signature: sig) }
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  out = IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  code = $?.exitstatus
  check(code == 5, "verify-complete over a breached loop-log => exit 5 (got #{code})", fails)
  check(out.include?('NOT DONE') && out.include?(sig), 'refusal names the looping signature', fails)
end

# … and at EXACTLY 2 occurrences (the acceptance case: "verify-complete
# refuses completion over a 2-count signature")
Dir.mktmpdir do |wd|
  sig = 'migrate-tableau:exit4:exit=4:WorkbookBuildError:aaaa11112222'
  2.times { Offramp.loop_check(wd, signature: sig) }
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  out = IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  code = $?.exitstatus
  check(code == 5, "verify-complete refuses a 2-count signature => exit 5 (got #{code})", fails)
  check(out.include?(sig), '2-count refusal names the signature', fails)
  # a green reset re-arms the refusal too: same log + reset => DONE
  Offramp.loop_reset(wd)
  IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check($?.exitstatus.zero?, 'after a green reset the same loop-log no longer refuses (exit 0)', fails)
end

# a clean workdir (no loop-log) is unaffected
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check($?.exitstatus.zero?, 'no loop-log => verify-complete still exits 0', fails)
end

# ── Normalization inversion (PR-507 1A): counts SURVIVE, identifiers do not ──
n = Offramp.normalize_error_line('[FAIL] workbook ref-resolution gate — 5 of 340 referenced ' \
                                 'column(s) do NOT exist in the live DM (335 columns):')
check(n.include?('5 of 340') && n.include?('(335 columns)') && n.include?('[FAIL]'),
      "bare integers SURVIVE normalization as the progress measure (got #{n.inspect})", fails)
check(Offramp.normalize_error_line('✗ Profit Ratio   (referenced via [Master/…], [Detail/…])') ==
      '✗ Profit Ratio (referenced via <ref>, <ref>)',
      'bracketed refs collapse to <ref>; house markers like [FAIL] are exempt', fails)
check(Offramp.normalize_error_line('element el-9 vs k9Xy2Qw81 at 2026-07-25T18:22:04Z took 450ms id 12345678901') ==
      'element <id> vs <id> at <time> took <time> id <id>',
      'mixed-alnum / uuid-ish / timestamp / duration / 7+-digit tokens are consumed by explicit rules', fails)

# ── error_region / error_digest / failure_mode / region_measure units ───────
REAL_FAIL = "NORMALIZE: columns/3 report line\n" \
            "[FAIL] workbook ref-resolution gate — 3 of 9 referenced column(s) do NOT exist in the live DM (6 columns):\n" \
            "         ✗ Delta   (referenced via [Master/…])\n" \
            "         ✗ Echo   (referenced via [Master/…])\n" \
            "         ✗ Foxtrot   (referenced via [Master/…])\n" \
            "\n" \
            "       These refs would fail the workbook POST with \"Dependency not found\". The usual\n" \
            "       cause is a MULTI-DATASOURCE workbook…\n"
region = Offramp.error_region(REAL_FAIL)
check(region.size == 4 && region.first.start_with?('[FAIL]') && region.last.include?('Foxtrot'),
      "error_region starts at the [FAIL] line and ends at the blank-line terminator (got #{region.size} lines)", fails)
check(!Offramp.error_digest(region).include?('Dependency not found'),
      'the constant advice prose after the blank line never reaches the digest', fails)
reordered = [region[0], region[3], region[1], region[2]]
check(Offramp.error_digest(region) == Offramp.error_digest(reordered),
      'error_digest sorts the detail tail (reorder-invariant)', fails)
check(Offramp.error_digest(['ERROR: x', 'ERROR: x', 'ERROR: x']) !=
      Offramp.error_digest(['ERROR: x']),
      'error_digest keeps multiplicity (3 identical error lines != 1)', fails)
check(Offramp.error_region("line one\nline two\n").size == 2,
      'no error-shaped line => bounded whole-output fallback region', fails)
big = ([ 'ERROR: head 12 of 900' ] + Array.new(50) { |i| "detail row #{i % 3}" }).join("\n")
check(Offramp.error_region(big).size == Offramp::ERROR_REGION_MAX_LINES &&
      Offramp.error_digest(Offramp.error_region(big)).length <= Offramp::ERROR_REGION_MAX_CHARS,
      'region/digest bounds hold on oversized output', fails)
bad_utf = "[FAIL] gate \xE9tat — 3 of 9 columns missing:\n\xE9 Profit\n".dup.force_encoding('UTF-8')
begin
  check(Offramp.error_digest(Offramp.error_region(bad_utf)).include?('3 of 9'),
        'invalid UTF-8 region scrubs instead of raising, counts still survive', fails)
rescue StandardError => e
  check(false, "invalid UTF-8 region raised: #{e.class}", fails)
end

m5 = Offramp.failure_mode(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                          error_class: 'WorkbookBuildError',
                          error_region: ['[FAIL] gate — 5 of 340 referenced column(s) do NOT exist (335 columns):'])
m1 = Offramp.failure_mode(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                          error_class: 'WorkbookBuildError',
                          error_region: ['[FAIL] gate — 1 of 340 referenced column(s) do NOT exist (335 columns):'])
mo = Offramp.failure_mode(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                          error_class: 'WorkbookBuildError',
                          error_region: ['ERROR: page mixes master tables'])
check(m5 == m1, 'failure_mode masks the counts: 5-of-340 and 1-of-340 fail the same WAY', fails)
check(m5 != mo, 'a different head shape is a different failure mode', fails)
check(Offramp.region_measure(['[FAIL] gate — 5 of 340 referenced (335 columns):']) == 5,
      'region_measure reads the head line\'s leading surviving count', fails)
check(Offramp.region_measure(['ERROR: no counts here', 'ERROR: a', 'ERROR: b']) == 2,
      'no head count => measure falls back to the detail-line count', fails)
check(Offramp.region_measure(['ERROR: no counts at all']).nil? && Offramp.region_measure([]).nil?,
      'nothing measurable => nil (S2 then stops on mode recurrence — conservative)', fails)

# ── Region-cap overflow: a LONG block's truth survives truncation ───────────
# validate-spec-shaped emission (validate-spec.rb:393-395): one count-less
# `ERROR: …` line per defect + a trailing `--- N errors` tally — the tally is
# the block's LAST line, i.e. past the 16-line cap exactly when N > 15. Before
# the overflow trailer, attempts differing only past the cap minted IDENTICAL
# signatures (S1 false 'repeat') and the detail-line measure plateaued at 15
# (S2 false 'no-progress'): a converging 20→17→14 run stopped at attempt 2 —
# the finding-1A pathology resurfacing past ERROR_REGION_MAX_LINES.
VS_ERRORS = lambda do |n|
  (1..n).map { |i| "ERROR: element el-#{i} references unknown column \"Col #{i}\"" }
        .join("\n") + "\n--- #{n} errors\n"
end
r20 = Offramp.error_region(VS_ERRORS.call(20))
r17 = Offramp.error_region(VS_ERRORS.call(17))
check(r20.size == Offramp::ERROR_REGION_MAX_LINES &&
      r20.last =~ Offramp::ERROR_REGION_OVERFLOW_RE && r20.last.include?('+6 more'),
      "capped region spends its last slot on the overflow trailer (got #{r20.last.inspect})", fails)
check(Offramp.error_digest(r20) != Offramp.error_digest(r17),
      'long lists differing only PAST the cap mint DISTINCT digests (trailer carries the count)', fails)
check([r20, r17, Offramp.error_region(VS_ERRORS.call(14))].map { |r| Offramp.region_measure(r) } == [20, 17, 14],
      'measure reads the UNCAPPED block count (20/17/14, not a 15/15/14 cap plateau)', fails)
check(Offramp.error_region(VS_ERRORS.call(15)).size == 16 &&
      Offramp.error_region(VS_ERRORS.call(15)).grep(Offramp::ERROR_REGION_OVERFLOW_RE).empty? &&
      Offramp.region_measure(Offramp.error_region(VS_ERRORS.call(16))) == 16,
      'cap boundary: an exactly-fitting block keeps every line; one past it still measures true', fails)
# the trailer is pinned after the HEAD in the digest: ~300-char detail lines
# sorting before '(' (e.g. '#'-led) would otherwise push it past
# ERROR_REGION_MAX_CHARS and re-collide two long lists that agree on every
# shown line
hashy = lambda { |n| "ERROR: readback dependency sweep failed\n" +
                     (1..n).map { |i| "## #{'pad ' * 70}el-#{i}" }.join("\n") + "\n" }
check(Offramp.error_digest(Offramp.error_region(hashy.call(25))) !=
      Offramp.error_digest(Offramp.error_region(hashy.call(22))),
      'overflow trailer survives the char cap (pinned after the head, not sorted away)', fails)

# converging 20→17→14 through the exit-4 chain — pre-fix verdicts were
# [:first, :stop, :first] with measures [15, 15, 14]
Dir.mktmpdir do |wd|
  verdicts = [20, 17, 14].map { |n| EXIT4_VERDICT.call(wd, VS_ERRORS.call(n)).first }
  check(verdicts == %i[first first first],
        "CONVERGING 20→17→14 past the region cap never stops (got #{verdicts.inspect})", fails)
end
# the fix must not weaken the stop rules on long lists
Dir.mktmpdir do |wd|
  v1 = EXIT4_VERDICT.call(wd, VS_ERRORS.call(20)).first
  v2 = EXIT4_VERDICT.call(wd, VS_ERRORS.call(20)).first
  check(v1 == :first && v2 == :stop, 'IDENTICAL 20-error list still stops at attempt 2', fails)
end
Dir.mktmpdir do |wd|
  v1 = EXIT4_VERDICT.call(wd, VS_ERRORS.call(20)).first
  v2 = EXIT4_VERDICT.call(wd, VS_ERRORS.call(24)).first
  check(v1 == :first && v2 == :stop,
        'GROWING 20→24 past the region cap stops at attempt 2 (no-progress rule)', fails)
end
# the REAL ref gate past the cap: >15 ✗ detail lines with a head count — the
# head count stays the measure and a converging run keeps proceeding
Dir.mktmpdir do |fx|
  Dir.mktmpdir do |wd|
    names = (1..18).map { |i| "Delta#{i}" }
    out_a, = run_ref_gate(fx, names)
    out_b, = run_ref_gate(fx, names.first(17))
    ra = Offramp.error_region(out_a)
    check(ra.size == Offramp::ERROR_REGION_MAX_LINES && ra.last =~ Offramp::ERROR_REGION_OVERFLOW_RE,
          'real >cap ✗-detail block carries the overflow trailer', fails)
    check(Offramp.region_measure(ra) == 18,
          "head count still wins over the trailer fallback on the real gate (got #{Offramp.region_measure(ra).inspect})", fails)
    v1 = EXIT4_VERDICT.call(wd, out_a).first
    v2 = EXIT4_VERDICT.call(wd, out_b).first
    check(v1 == :first && v2 == :first,
          'real converging 18→17 with a >cap detail block keeps proceeding', fails)
  end
end

# ── Trajectory matrix — REAL child emission through the REAL loop_check ─────
# Each attempt runs the shipped assert-wb-refs-resolve.rb offline and feeds
# its verbatim multi-line output through the exit-4 site's processing chain.
Dir.mktmpdir do |fx|
  out5, st5 = run_ref_gate(fx, %w[Delta Echo Foxtrot Golf Hotel])
  check(st5.exitstatus == 1 && out5.include?('[FAIL] workbook ref-resolution gate — 5 of 8') &&
        out5.scan(/✗/).size == 5,
        'fixture sanity: the real gate emits the [FAIL]-summary-then-✗-detail shape', fails)

  # CONVERGING 5→3→2→1: strict improvement every attempt — must NEVER stop.
  Dir.mktmpdir do |wd|
    verdicts = [%w[Delta Echo Foxtrot Golf Hotel], %w[Foxtrot Golf Hotel],
                %w[Golf Hotel], %w[Hotel]].map do |missing|
      out, = run_ref_gate(fx, missing)
      EXIT4_VERDICT.call(wd, out).first
    end
    check(verdicts == %i[first first first first],
          "CONVERGING 5→3→2→1 never stops (got #{verdicts.inspect})", fails)
  end

  # IDENTICAL: the same failure twice — stop at 2.
  Dir.mktmpdir do |wd|
    out, = run_ref_gate(fx, %w[Delta Echo Foxtrot])
    v1, sig1, = EXIT4_VERDICT.call(wd, out)
    v2, sig2, = EXIT4_VERDICT.call(wd, out)
    check(v1 == :first && v2 == :stop && sig1 == sig2,
          'IDENTICAL failure stops at attempt 2', fails)
  end

  # PURE REORDER: same failures, shuffled report order — stop at 2.
  Dir.mktmpdir do |wd|
    out_a, = run_ref_gate(fx, %w[Delta Echo Foxtrot])
    out_b, = run_ref_gate(fx, %w[Foxtrot Delta Echo])
    v1, sig_a, = EXIT4_VERDICT.call(wd, out_a)
    v2, sig_b, = EXIT4_VERDICT.call(wd, out_b)
    check(out_a != out_b && sig_a == sig_b && v1 == :first && v2 == :stop,
          'PURE REORDER mints the SAME signature and stops at attempt 2', fails)
  end

  # OSCILLATING A-B: same count, disjoint membership — same mode, no
  # improvement — stop at 2 (before it can even flip back to A).
  Dir.mktmpdir do |wd|
    out_a, = run_ref_gate(fx, %w[Delta Echo Foxtrot])
    out_b, = run_ref_gate(fx, %w[India Juliet Kilo])
    v1, sig_a, mode_a = EXIT4_VERDICT.call(wd, out_a)
    v2, sig_b, mode_b = EXIT4_VERDICT.call(wd, out_b)
    check(sig_a != sig_b && mode_a == mode_b && v1 == :first && v2 == :stop,
          'OSCILLATING (A-B, equal counts) stops at attempt 2 via the no-progress rule', fails)
  end

  # GROWING 3→4: measure worsens — stop at 2.
  Dir.mktmpdir do |wd|
    out_a, = run_ref_gate(fx, %w[Delta Echo Foxtrot])
    out_b, = run_ref_gate(fx, %w[Delta Echo Foxtrot Golf])
    v1, sig_a, = EXIT4_VERDICT.call(wd, out_a)
    v2, sig_b, = EXIT4_VERDICT.call(wd, out_b)
    check(v1 == :first && v2 == :stop && sig_b != sig_a,
          'GROWING 3→4 stops at attempt 2 (distinct signatures — the mode rule catches it)', fails)
  end

  # CHURN (fix-one-break-one): same count, rolling membership — stop at 2.
  Dir.mktmpdir do |wd|
    out_a, = run_ref_gate(fx, %w[Delta Echo Foxtrot])
    out_b, = run_ref_gate(fx, %w[Echo Foxtrot Golf])
    v1, = EXIT4_VERDICT.call(wd, out_a)
    v2, = EXIT4_VERDICT.call(wd, out_b)
    check(v1 == :first && v2 == :stop,
          'CHURN with no shrink stops at attempt 2', fails)
  end

  # ATTEMPT CAP boundary: a genuinely converging loop is still bounded —
  # attempt CAP-1 proceeds, attempt CAP stops with :cap.
  Dir.mktmpdir do |wd|
    sets = [%w[D1 D2 D3 D4 D5 D6 D7], %w[D2 D3 D4 D5 D6 D7], %w[D3 D4 D5 D6 D7],
            %w[D4 D5 D6 D7], %w[D5 D6 D7], %w[D6 D7]]
    verdicts = sets.map do |missing|
      out, = run_ref_gate(fx, missing)
      EXIT4_VERDICT.call(wd, out).first
    end
    check(Offramp::ATTEMPT_CAP == 6, "SIGMA_LOOP_ATTEMPT_CAP defaults to 6 (got #{Offramp::ATTEMPT_CAP})", fails)
    check(verdicts[0..4] == %i[first first first first first] && verdicts[5] == :cap,
          "cap boundary: attempt 5 proceeds, attempt 6 => :cap (got #{verdicts.inspect})", fails)
    check(Offramp.loop_stops(wd).size == 1 &&
          Offramp.loop_stops(wd).first['stop_rule'] == 'attempt-cap',
          'the cap stop is stamped on the record (stop_rule=attempt-cap)', fails)
    # green reset re-arms the cap budget too
    Offramp.loop_reset(wd)
    out, = run_ref_gate(fx, %w[D9 D8])
    check(EXIT4_VERDICT.call(wd, out).first == :first && Offramp.loop_stops(wd).empty?,
          'a green reset re-arms the attempt cap (post-reset attempt => :first)', fails)
  end

  # GREEN-RESET re-arm for the mode rule: stop, reset, same failure => :first.
  Dir.mktmpdir do |wd|
    out, = run_ref_gate(fx, %w[Delta Echo Foxtrot])
    EXIT4_VERDICT.call(wd, out)
    check(EXIT4_VERDICT.call(wd, out).first == :stop, 'pre-reset: identical attempt 2 => :stop', fails)
    Offramp.loop_reset(wd)
    check(EXIT4_VERDICT.call(wd, out).first == :first,
          'green reset re-arms the mode/no-progress rule (same failure => :first again)', fails)
  end
end

# ── Backward compat: pre-upgrade records restart counting, never pair ───────
Dir.mktmpdir do |wd|
  5.times do |i|
    File.open(File.join(wd, 'loop-log.jsonl'), 'a') do |f|
      f.puts(JSON.generate('signature' => "migrate-tableau:exit4:exit=4:oldhash#{i}",
                           'at' => '2026-07-01T00:00:00Z'))
    end
  end
  v = Offramp.loop_check(wd, signature: 'migrate-tableau:exit4:handoff=4:child=1:newhash',
                         mode: 'migrate-tableau:exit4:handoff=4:child=1:mAAA', measure: 3,
                         scope: 'migrate-tableau:exit4')
  check(v == :first,
        'legacy signature-only records neither pair with new ones nor spring the cap (counting restarts)', fails)
  check(Offramp.loop_counts(wd).size == 6, 'legacy records still tally in loop_counts', fails)
end

# ── Finalize: distinct sub-causes behind ONE exit tuple no longer collide ───
# The census gate emits one shared [FAIL] header for several root causes; the
# discriminating detail sits on indented continuation lines ERROR_LINE_RE can
# never match — only the REGION digest separates them (PR-507 finding 1B).
FIN_HEAD = '[FAIL] parity-final.json reports charts_total=12 but the census found problems:'
OUT_COVERAGE = FIN_HEAD + "\n" \
  "   ✗ dashboard tile 'Orders by Segment' has NO anchor coverage\n" \
  "   ✗ dashboard tile 'Rev Q3' has NO anchor coverage\n" \
  "   ✗ dashboard tile 'Margin' has NO anchor coverage\n\n" \
  "       Fix the anchors, then re-run --finalize.\n"
OUT_EMPTY = FIN_HEAD + "\n" \
  "   ✗ dashboard tile 'Profit Trend' exported an EMPTY csv\n" \
  "   ✗ dashboard tile 'Sales by Region' exported an EMPTY csv\n\n" \
  "       Re-export the tiles, then re-run --finalize.\n"
fin_sig = lambda do |out, dsf|
  Offramp.failure_signature(script: 'migrate-tableau', context: 'finalize',
                            exit_code: { phase6: 0, gate: 2, cleanup: 0, dsfilters: dsf },
                            error_region: Offramp.error_region(out))
end
check(fin_sig.call(OUT_COVERAGE, 0) != fin_sig.call(OUT_EMPTY, 0),
      'finalize: two sub-causes sharing one [FAIL] header + exit tuple get DISTINCT signatures', fails)
Dir.mktmpdir do |wd|
  v1 = Offramp.loop_check(wd, signature: fin_sig.call(OUT_COVERAGE, 0), scope: 'migrate-tableau:finalize')
  v2 = Offramp.loop_check(wd, signature: fin_sig.call(OUT_EMPTY, 0), scope: 'migrate-tableau:finalize')
  v3 = Offramp.loop_check(wd, signature: fin_sig.call(OUT_EMPTY, 0), scope: 'migrate-tableau:finalize')
  check(v1 == :first && v2 == :first && v3 == :stop,
        'finalize sub-cause flip => no false stop; a genuine repeat still stops at 2', fails)
end
s_ds = Offramp.failure_signature(script: 'migrate-tableau', context: 'finalize',
                                 exit_code: { phase6: 0, gate: 0, cleanup: 0, dsfilters: 1 })
check(s_ds.include?('dsfilters=1') &&
      s_ds != Offramp.failure_signature(script: 'migrate-tableau', context: 'finalize',
                                        exit_code: { phase6: 0, gate: 0, cleanup: 0, dsfilters: 0 }),
      'N1: a ds-filters-only NOT-GREEN keys its own gate status (no three-passing-gates signature)', fails)

# ── verify-complete refuses S2/S3 stops that never repeat a signature ───────
# An S2 (no-progress) stop leaves every signature at a 1-count — without the
# stop-stamp check, a hard-STOPPED run would falsely report DONE (the
# integration hole the redesign opens and must close in the same change).
Dir.mktmpdir do |wd|
  mode = 'migrate-tableau:exit4:handoff=4:child=1:mSAME'
  v1 = Offramp.loop_check(wd, signature: 'migrate-tableau:exit4:handoff=4:child=1:aaa',
                          mode: mode, measure: 3, scope: 'migrate-tableau:exit4')
  v2 = Offramp.loop_check(wd, signature: 'migrate-tableau:exit4:handoff=4:child=1:bbb',
                          mode: mode, measure: 3, scope: 'migrate-tableau:exit4')
  check(v1 == :first && v2 == :stop, 'S2 setup: distinct signatures, same mode, equal measure => :stop', fails)
  check(Offramp.loop_counts(wd).values.max == 1,
        'S2 stop leaves NO 2-count signature (the count rule alone would miss it)', fails)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  out = IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check($?.exitstatus == 5, "verify-complete refuses a stop-stamped trail without any 2-count (got #{$?.exitstatus})", fails)
  check(out.include?('no-progress'), 'the refusal names the stop rule', fails)
  Offramp.loop_reset(wd)
  IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check($?.exitstatus.zero?, 'a green reset re-arms the stop-stamp refusal (exit 0)', fails)
end
Dir.mktmpdir do |wd|
  6.times { |i| Offramp.loop_check(wd, signature: "migrate-tableau:finalize:sig#{i}", scope: 'migrate-tableau:finalize') }
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  out = IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check($?.exitstatus == 5 && out.include?('attempt-cap'),
        "verify-complete refuses an attempt-cap stop (got #{$?.exitstatus})", fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
