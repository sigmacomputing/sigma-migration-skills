# frozen_string_literal: true

# ActionGates — Tableau-only hard-gate logic for the workbook actions layer
# (G1 action-schema validation + the post-publish guide-residue check).
#
# Deliberately NOT part of the shared assert-phase6-ran.rb. That script is
# vendored CANONICAL to 8 converters (shared/manifest.json) — looker,
# microstrategy, powerbi, quicksight, tableau, thoughtspot, domo, hex. The
# concept these two checks model (Tableau dashboard filter/highlight/nav/
# parameter/set actions, parsed from a .twb, tracked via the action ledger —
# scripts/lib/action_ledger.rb) has no equivalent in the other 7 converters.
# An earlier attempt forked the shared script directly for this logic; that
# was reverted (2026-08-07) because a 200+ line divergence in one vendored
# copy means future shared fixes stop reaching tableau. This lib — and its
# thin CLI twin scripts/assert-action-gates.rb — is the permanent home
# instead; see that script's header for the full rationale and usage.
require 'json'
$LOAD_PATH.unshift File.expand_path(__dir__)
require 'action_ledger'
require_relative 'workbook_code'

module ActionGates
  module_function

  # G1 — every actions[] entry in `spec` is schema-valid
  # (ActionLedger.validate_action) and its id is unique across the WHOLE
  # workbook (not per-element — a per-element counter produces a live 400
  # "Duplicate action id"). Exists because a previously-shipped button action
  # omitted `id` on every run and nothing noticed until a live POST 400.
  # Returns an array of human-readable error strings; empty means valid.
  def action_schema_violations(spec)
    errs = []
    seen = {}
    WorkbookCode.elements_with_pages(spec).each do |element, page|
      (element['actions'] || []).each do |action|
        ActionLedger.validate_action(action).each do |error|
          errs << "#{page&.dig('id') || '(unplaced)'}/#{element['id']}: #{error}"
        end
        id = action['id']
        next if id.to_s.empty?
        if seen[id]
          errs << "duplicate action id #{id.inspect} on #{element['id']} (already on #{seen[id]}) " \
                  '— action ids must be unique across the WHOLE workbook'
        end
        seen[id] = element['id']
      end
    end
    errs
  end

  def action_count(spec)
    WorkbookCode.elements(spec).sum { |element| Array(element['actions']).size }
  end

  # Ledger/spec contradiction check — the built `spec` (--spec) is the one
  # ground truth for "how many actions actually exist"; `ledger['emitted']`
  # is a CLAIM about how many of those the converter auto-wired. The two are
  # written by the SAME code path in build-charts-from-signals.rb (every
  # `actions' => [action]` it adds to a spec element is paired, in the same
  # statement block, with an append to the manifest that becomes
  # ledger['emitted']) — so in a healthy run they are exactly equal, not just
  # both-nonzero-or-both-zero. Exists because build-postpublish-guide.rb run
  # without --emitted-manifest defaults to emitted: [] regardless of what the
  # spec actually contains (ActionLedger.read_manifest(nil) == []): a spec
  # with N real emitted actions then pairs with a ledger claiming 0, the guide
  # instructs the customer to hand-wire work that is already done, AND
  # guide_residue_violations (below) had nothing to compare against, so the
  # gate printed [OK] on both checks in the same run a spec inspection would
  # show is a lie. Checking strict equality (not just "spec>0 && emitted==0")
  # also catches the mirror-image drift — a stale/partial manifest that
  # UNDER- or OVER-claims relative to the spec that was actually built.
  # Returns an array of error strings; empty means valid.
  def ledger_spec_mismatch_violations(spec, ledger)
    return [] if spec.nil?
    spec_n   = action_count(spec)
    ledger_n = (ledger['emitted'] || []).size
    return [] if spec_n == ledger_n
    ["ledger/spec mismatch — the built spec contains #{spec_n} action(s) but the ledger claims " \
     "#{ledger_n} emitted (residue reports #{(ledger['residue'] || []).size}) — the ledger is not " \
     'trustworthy here; re-run build-postpublish-guide.rb with the correct --emitted-manifest ' \
     '(the actions-emitted.json sidecar build-charts-from-signals.rb wrote for this spec) and ' \
     'rebuild the guide before trusting it']
  end

  # Guide-residue check — `ledger` (the parsed action-ledger.json contents)
  # must have its conservation invariant hold (detectedCount == emitted.size +
  # residue.size), and `guide_text` (POSTPUBLISH_GUIDE.md's contents) must not
  # render any of the ledger's `emitted` entries as still-open work — a guide
  # instructing the customer to hand-wire an action the converter already
  # built is a FAIL, not a pass. Returns an array of error strings; empty
  # means valid. Callers check ledger/guide file existence and
  # JSON-parseability themselves before calling this (existence is a distinct
  # failure mode from content violations, and the CLI reports them with
  # distinct remedies).
  #
  # Matches STRUCTURALLY, not by caption substring. A caption can legitimately
  # recur in unrelated prose — e.g. an uncaptioned nav-button's caption falls
  # back to its target DASHBOARD NAME (build-charts-from-signals.rb), and the
  # guide legitimately renders dashboard names in OTHER actions' residue prose
  # (build-postpublish-guide.rb's `parse_source` — "any sheet on dashboard
  # '<name>'"). `guide_text.include?(cap)` matched that unrelated prose and
  # FAILED a run that was actually fine. build-postpublish-guide.rb's
  # render_guide now stamps each rendered residue entry with an invisible
  # `<!-- ledger-key: [...] -->` marker carrying its ActionLedger.key_of
  # identity (actionName-preferred, [kind, caption] fallback — the SAME
  # identity ActionLedger.join uses to compute residue in the first place);
  # this check parses those markers back out and compares by identity, never
  # by scanning the human-readable text.
  def guide_residue_violations(ledger, guide_text)
    errs = []
    if ledger['detectedCount'] != ledger['emitted'].size + ledger['residue'].size
      errs << "ledger conservation broken — detected=#{ledger['detectedCount']} " \
              "emitted=#{ledger['emitted'].size} residue=#{ledger['residue'].size}"
      return errs
    end
    # map + compact, not filter_map — that's Ruby 2.7+; this skill's floor is
    # the system Ruby 2.6 (see lib/offramp.rb, lib/calc_coverage.rb).
    rendered_keys = guide_text.scan(/<!--\s*ledger-key:\s*(\[.*?\])\s*-->/).map do |raw|
      begin
        JSON.parse(raw.first)
      rescue JSON::ParserError
        nil
      end
    end.compact
    # Marker-ABSENCE blind spot (live reviewer repro, follow-up to the
    # structural-match fix above): a guide with ZERO `ledger-key` markers —
    # a stale pre-fix file, a hand-edited guide, or output from any code path
    # that isn't the current render_guide — makes the per-entry loop below
    # silently vacuous: `rendered_keys.include?(key)` is false for every
    # emitted entry because there is nothing to match against, so a guide
    # that genuinely instructs hand-wiring an already-emitted action passes
    # with zero violations reported. Fail closed instead: if something was
    # actually emitted, a marker-less guide cannot be verified at all, so it
    # must not report OK. Do NOT fall back to substring matching here — that
    # is exactly what reintroduces the dashboard-name false-FAIL these
    # markers exist to avoid (see the caption-collision case above).
    # Legitimate zero case: when `emitted` is empty, nothing was auto-wired,
    # so a marker-less guide's open-work prose — however it's written —
    # cannot be mis-describing already-done work as still open; that guide
    # is fine and must not be failed here.
    if !ledger['emitted'].empty? && rendered_keys.empty?
      return ["the guide carries zero <!-- ledger-key --> markers but the ledger claims " \
              "#{ledger['emitted'].size} action(s) emitted — this guide cannot be verified against the " \
              'ledger (it appears to predate or bypass render_guide: a stale file, a hand-edited copy, or ' \
              'output from a different code path) — regenerate it with build-postpublish-guide.rb before ' \
              'trusting it']
    end
    ledger['emitted'].each do |e|
      key = ActionLedger.key_of(e['source'] || {})
      next if key.nil? || key[1].to_s.empty? # no stable identity to compare against
      next unless rendered_keys.include?(key)
      cap = e.dig('source', 'caption').to_s
      errs << "the guide instructs hand-wiring #{cap.inspect} (action #{key.inspect}), but the " \
              'converter already emitted it — the guide must describe ONLY the residue, work still to do'
    end
    errs
  end
end
