# frozen_string_literal: true
#
# phase_metrics.rb — LOCAL per-phase wall-clock/token capture (reconciled
# program ADD-6; ratified 2026-07-27 Q7: "local per-phase token/timing capture
# lands as LOCAL files only — nothing here ever sends them off-box").
#
# WHY: every sizing decision in the program currently steers by an n=3 ±30%
# priors-not-fits estimator (estimate-cost.rb's own header). This lib is the
# measurement substrate: orchestrators call PhaseMetrics.record at each phase
# boundary, and the accumulated <WORK>/phase-metrics.jsonl becomes the
# calibration source those coefficients have never had.
#
# CAPTURE, NEVER SEND — the local-only contract, stated once and load-bearing:
#   - record() only ever APPENDS to a file inside the caller's workdir.
#     Nothing here talks to the network, reads credentials, or imports any
#     off-box send path.
#   - phase-metrics.jsonl is machine-local run state, gitignored, never
#     committed (CONTRIBUTING.md "Run state stays local").
#   - Keys are coarse internal phase names + numbers only. Callers must not
#     put workbook/customer identifiers in `phase`.
#
# API (require-safe standalone — stdlib only, no repo siblings):
#   PhaseMetrics.record(workdir: W, phase: 'discover', wall_s: 61.7,
#                       tokens: 120_000,   # optional
#                       turn: 7,           # optional (W2.22 turn capture)
#                       inv: PhaseMetrics.invocation_token) # optional
#     → true on append, false when it could not record (missing workdir,
#       IO error). NEVER raises: metrics are bookkeeping, a metrics failure
#       must not break a run.
#   PhaseMetrics.invocation_token → per-process token (pid + boot millis,
#       numbers only — memoized). Grouping records by `inv` counts
#       orchestrator invocations; invocations − 1 = re-entries.
#   PhaseMetrics.entries(W)      → parsed records, oldest first ([] on any error)
#   PhaseMetrics.summarize(W)    → prints the per-phase table to stdout (or io:)
#                                  and returns {phase => aggregate} for callers
#   PhaseMetrics.run_stats(W)    → cross-record derivations for the W2.22/W2.24
#       measurement loop: {records, turn_events, invocations, re_entries,
#       wall_s_total, span_s, tokens_total, first_at, last_at}. Absence of a
#       capture is nil, never 0 (nil ≠ 0, same convention as tokens): a file
#       written before turn capture landed yields turn_events/invocations nil,
#       and consumers must refuse to derive a rate from it rather than guess.
#
# Record shape (one JSON line per call, append-only; turn/inv/tokens optional):
#   {"phase":"discover","wall_s":61.7,"tokens":120000,"turn":7,
#    "inv":"4242-1753660000000","at":"2026-07-27T00:00:00Z"}
#   `turn` is the caller's monotone per-invocation mark ordinal; `inv` is an
#   opaque per-process token (numbers only — hygiene: never a name).

require 'json'
require 'time'

module PhaseMetrics
  FILE_BASENAME = 'phase-metrics.jsonl'

  module_function

  def path(workdir)
    File.join(workdir.to_s, FILE_BASENAME)
  end

  # Append one phase measurement. Returns true when written, false otherwise.
  def record(workdir:, phase:, wall_s:, tokens: nil, at: nil, turn: nil, inv: nil)
    return false if workdir.to_s.empty? || !Dir.exist?(workdir.to_s)
    return false if phase.to_s.strip.empty?
    rec = {
      'phase'  => phase.to_s,
      'wall_s' => wall_s.to_f.round(3),
      'at'     => (at || Time.now.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    }
    rec['tokens'] = tokens.to_i unless tokens.nil?
    rec['turn']   = turn.to_i   unless turn.nil?
    rec['inv']    = inv.to_s    unless inv.nil?
    File.open(path(workdir), 'a') { |f| f.puts(JSON.generate(rec)) }
    true
  rescue StandardError
    false # bookkeeping only — never fail the run over metrics
  end

  # Per-process invocation token: pid + boot milliseconds — numbers only
  # (hygiene: an inv token must never carry a workbook/customer name).
  # Memoized: stable within one orchestrator invocation, distinct across
  # invocations of the same workdir, so distinct-inv count = invocations.
  def invocation_token
    @invocation_token ||= format('%d-%d', Process.pid, (Time.now.to_f * 1000).to_i)
  end

  # Parsed records, oldest first. Malformed lines are skipped (append-only
  # files survive crashes mid-write; a torn last line must not poison reads).
  def entries(workdir)
    p = path(workdir)
    return [] unless File.exist?(p)
    File.readlines(p).map { |l| JSON.parse(l) rescue nil }
        .select { |r| r.is_a?(Hash) && r['phase'] && r['wall_s'] }
  rescue StandardError
    []
  end

  # Per-phase aggregate: {phase => {'n', 'wall_s', 'wall_s_mean', 'tokens'}}
  # ('tokens' is nil when no record for that phase carried a token count —
  # distinguishable from a measured 0). Insertion order = first-seen order,
  # so the table reads in run order.
  def aggregate(workdir)
    agg = {}
    entries(workdir).each do |r|
      a = (agg[r['phase']] ||= { 'n' => 0, 'wall_s' => 0.0, 'tokens' => nil })
      a['n']      += 1
      a['wall_s'] = (a['wall_s'] + r['wall_s'].to_f).round(3)
      a['tokens'] = a['tokens'].to_i + r['tokens'].to_i if r.key?('tokens')
    end
    agg.each_value { |a| a['wall_s_mean'] = (a['wall_s'] / a['n']).round(3) }
    agg
  end

  # Cross-record derivations for the measurement protocol (W2.22 refit /
  # W2.24 cold-run harness). Everything here is mechanical bookkeeping over
  # the file — no estimation, no guessing:
  #   turn_events  count of records carrying a `turn` ordinal — the
  #                poll-contract proxy for countable turns. nil (not 0) when
  #                NO record carries one: the orchestrator predates turn
  #                capture, and a rate must not be derived from that file.
  #   invocations  distinct `inv` tokens (nil when none carry one)
  #   re_entries   invocations − 1 (nil when invocations is unknown)
  #   wall_s_total sum of recorded segment walls (the measured spine)
  #   span_s       last `at` − first `at` (nil when timestamps unparsable) —
  #                the cross-check against an operator's wall clock
  #   tokens_total sum where measured (nil when never measured)
  def run_stats(workdir)
    es = entries(workdir)
    turns  = es.count { |r| r.key?('turn') }
    invs   = es.map { |r| r['inv'] }.compact.uniq
    toks   = es.select { |r| r.key?('tokens') }
    first_at = es.first && es.first['at']
    last_at  = es.last && es.last['at']
    span = begin
      first_at && last_at ? (Time.parse(last_at) - Time.parse(first_at)).round(3) : nil
    rescue StandardError
      nil
    end
    {
      'records'      => es.size,
      'turn_events'  => (turns.zero? ? nil : turns),
      'invocations'  => (invs.empty? ? nil : invs.size),
      're_entries'   => (invs.empty? ? nil : invs.size - 1),
      'wall_s_total' => es.reduce(0.0) { |s, r| s + r['wall_s'].to_f }.round(3),
      'span_s'       => span,
      'tokens_total' => (toks.empty? ? nil : toks.reduce(0) { |s, r| s + r['tokens'].to_i }),
      'first_at'     => first_at,
      'last_at'      => last_at
    }
  end

  # Print the per-phase table; returns the aggregate hash (callers like the
  # wrap-up report can reuse the numbers without re-reading the file).
  def summarize(workdir, io: $stdout)
    agg = aggregate(workdir)
    if agg.empty?
      io.puts "phase-metrics: no records in #{path(workdir)}"
      return agg
    end
    io.puts format('%-28s %5s %12s %12s %14s', 'phase', 'n', 'wall_s', 'mean_s', 'tokens')
    agg.each do |phase, a|
      io.puts format('%-28s %5d %12.1f %12.1f %14s',
                     phase, a['n'], a['wall_s'], a['wall_s_mean'],
                     a['tokens'] ? a['tokens'].to_s : '-')
    end
    tot_wall   = agg.values.reduce(0.0) { |s, a| s + a['wall_s'] }.round(3)
    tot_tokens = agg.values.map { |a| a['tokens'] }.compact
    io.puts format('%-28s %5d %12.1f %12s %14s',
                   'TOTAL', agg.values.reduce(0) { |s, a| s + a['n'] }, tot_wall, '',
                   tot_tokens.empty? ? '-' : tot_tokens.reduce(:+).to_s)
    agg
  end
end
