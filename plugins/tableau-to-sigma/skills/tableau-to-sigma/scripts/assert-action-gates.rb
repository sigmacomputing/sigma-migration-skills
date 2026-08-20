#!/usr/bin/env ruby
# frozen_string_literal: true
#
# assert-action-gates.rb — Tableau-only hard gate for the workbook actions
# layer. TWO independent checks:
#
#   G1 — every actions[] entry in the built spec (--spec) is schema-valid
#     (ActionLedger.validate_action) and every action id is unique across the
#     WHOLE workbook. Catches: a missing `id` (a REAL shipping bug — a button
#     action omitted `id` on every run and nothing noticed until a live POST
#     400), a workbook-duplicate id (a REAL live API 400), and an `open-url`
#     effect with no `url` (schema-valid upstream, but a silent no-op —
#     rejected on purpose). NEVER waivable — not even by
#     --skip-postpublish-guide below: a waiver on the hand-off guide is not a
#     waiver on spec validity.
#
#   Guide-residue check — <workdir>/action-ledger.json (written by
#     build-postpublish-guide.rb --json-out) must exist with its conservation
#     invariant holding (detectedCount == emitted.size + residue.size),
#     <workdir>/POSTPUBLISH_GUIDE.md must exist, the guide must not render any
#     of the ledger's `emitted` entries as still-open work (matched
#     STRUCTURALLY by ActionLedger identity via an invisible per-entry marker
#     build-postpublish-guide.rb stamps into the guide — never by scanning
#     visible prose for a caption substring, which false-FAILed whenever a
#     caption legitimately recurred in unrelated prose, e.g. a dashboard
#     name), and — when --spec is also given — action_count(spec) must equal
#     ledger['emitted'].size (ActionGates.ledger_spec_mismatch_violations): a
#     ledger claiming fewer/more auto-emitted actions than the spec actually
#     contains is not trustworthy input for either check above, however
#     clean the guide text itself looks. Previously this lived as gate 11
#     inside the SHARED assert-phase6-ran.rb as a bare file-exists check, so a
#     guide instructing the customer to hand-wire an action the converter had
#     ALREADY built still passed green. That weak check stays in the shared
#     script (it's canonical to 7 other converters with no action-ledger
#     concept) — THIS is the strong version, Tableau-only.
#
# WHY THIS IS A SEPARATE, TABLEAU-ONLY SCRIPT (not folded into
# assert-phase6-ran.rb): that script is vendored CANONICAL to 8 converters
# (shared/manifest.json — looker/microstrategy/powerbi/quicksight/tableau/
# thoughtspot/domo/hex). A 200+ line divergence in the tableau copy would stop
# future shared fixes from reaching tableau. The action-ledger concept
# (Tableau dashboard filter/highlight/nav/parameter/set actions, parsed from a
# .twb) has no equivalent in the other 7, so this logic belongs in its own
# permanent tableau-only script — the SAME pattern already used for #483's
# assert-datasource-filters.rb. migrate-tableau.rb --finalize invokes this
# unconditionally and folds its result into the GREEN decision; never rely on
# someone invoking it by hand.
#
# Usage:
#   ruby assert-action-gates.rb --workdir <WORK> [--spec <built-spec.json>] \
#        [--skip-postpublish-guide "<reason>"]
#
# --spec is REQUIRED for G1 to actually check anything; if omitted, G1 is a
# stated SKIP (nothing was asked to be checked) — legitimate for a standalone
# diagnostic run. migrate-tableau.rb's --finalize wiring ALWAYS resolves and
# passes one (checking <workdir>/wb-spec.json, then
# <workdir>/wb-spec.resolved.json — the two files Phase 4 can write; see its
# own header comment for which route writes which) and FAILS LOUDLY, before
# ever invoking this script, if neither exists. A gate that can be silently
# skipped on a real, common route (the agent-authored manual-spec path writes
# wb-spec.resolved.json instead of wb-spec.json, specifically so the authored,
# re-resolvable placeholders file is never clobbered) is worse than no gate at
# all — so the orchestrator never lets that route reach this script without a
# spec path, rather than this script silently no-op-ing on a missing default
# filename.
#
# --skip-postpublish-guide waives the GUIDE-RESIDUE check ONLY. It has zero
# effect on G1 — spec validity is not optional.
require 'json'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_gates'

opts = {}
OptionParser.new do |p|
  p.banner = 'usage: assert-action-gates.rb --workdir <WORK> [--spec <built-spec.json>] [--skip-postpublish-guide "<reason>"]'
  p.on('--workdir PATH', '--tableau PATH') { |v| opts[:work] = v }
  p.on('--spec PATH', 'built workbook spec JSON to validate for G1 (action schema + workbook-wide id uniqueness)') { |v| opts[:spec] = v }
  p.on('--skip-postpublish-guide REASON', 'waive the GUIDE-RESIDUE check ONLY — never G1. REQUIRED reason string; name it in your migration report.') { |v| opts[:skip_guide] = v }
end.parse!(ARGV)

abort 'usage: assert-action-gates.rb --workdir <WORK> [--spec <built-spec.json>]' if opts[:work].nil? || opts[:work].empty?

failed = false
spec = nil # populated below when --spec resolves; reused by the guide-residue
           # section's ledger/spec mismatch check so a spec with real actions
           # can never be paired with a ledger that lies about how many were
           # emitted (see ActionGates.ledger_spec_mismatch_violations).

# ---------------------------------------------------------------------------
# G1 — action schema validation (NEVER waivable).
# ---------------------------------------------------------------------------
if opts[:spec].nil?
  puts '[SKIP] G1: no --spec given — nothing to validate (a real --finalize run always supplies one)'
elsif !File.exist?(opts[:spec])
  warn "[FAIL] G1: --spec #{opts[:spec]} not found"
  failed = true
else
  spec = JSON.parse(File.read(opts[:spec]))
  errs = ActionGates.action_schema_violations(spec)
  if errs.empty?
    puts "[OK] G1: #{ActionGates.action_count(spec)} action(s) validated (#{opts[:spec]})"
  else
    warn "[FAIL] G1: #{errs.length} action-schema violation(s) in #{opts[:spec]}:"
    errs.each { |e| warn "       - #{e}" }
    warn '       Fix the emitting builder (every action needs `id`; ids are unique per WORKBOOK,'
    warn '       not per element) and re-build. G1 is NOT waivable — spec validity is not optional.'
    failed = true
  end
end

# ---------------------------------------------------------------------------
# Guide-residue check (waivable ONLY via --skip-postpublish-guide, and that
# flag has no effect on G1 above).
# ---------------------------------------------------------------------------
if opts[:skip_guide]
  puts "[WAIVED] guide-residue check — --skip-postpublish-guide: #{opts[:skip_guide]}"
  puts '         (name this waiver in your migration report; G1 above is UNAFFECTED by this flag.)'
  begin
    require 'offramp'
    Offramp.log(opts[:work], kind: 'skip-flag-waived', reason: opts[:skip_guide],
                detail: '--skip-postpublish-guide')
  rescue LoadError
    warn '       WARN: lib/offramp.rb not vendored — the waiver could not be recorded to offramps.jsonl.'
  end
else
  ledger_path = File.join(opts[:work], 'action-ledger.json')
  guide_path  = File.join(opts[:work], 'POSTPUBLISH_GUIDE.md')
  if !File.exist?(ledger_path)
    warn "[FAIL] guide-residue check: #{ledger_path} missing — build-postpublish-guide.rb must be run " \
         'with --json-out (escape hatch: --skip-postpublish-guide "<reason>", names it in your report)'
    failed = true
  else
    ledger = begin
      JSON.parse(File.read(ledger_path))
    rescue JSON::ParserError
      nil
    end
    if ledger.nil?
      warn "[FAIL] guide-residue check: #{ledger_path} is not valid JSON"
      failed = true
    elsif !File.exist?(guide_path)
      warn "[FAIL] guide-residue check: #{guide_path} missing — build-postpublish-guide.rb writes it " \
           'unconditionally (even for zero detected actions); re-run it'
      failed = true
    else
      guide = File.read(guide_path)
      errs = ActionGates.guide_residue_violations(ledger, guide)
      errs += ActionGates.ledger_spec_mismatch_violations(spec, ledger)
      if errs.empty?
        puts "[OK] guide-residue check: guide matches ledger residue " \
             "(#{ledger['emitted'].size} auto-emitted, #{ledger['residue'].size} manual)"
      else
        errs.each { |e| warn "[FAIL] guide-residue check: #{e}" }
        failed = true
      end
    end
  end
end

exit(failed ? 1 : 0)
