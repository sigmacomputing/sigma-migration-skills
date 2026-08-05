# frozen_string_literal: true
#
# JoinPlanResolutions — surfaces gate-16 join-cardinality RESOLUTIONS
# (probe-join-keys.rb `--resolve <i> --how preaggregated|waived --reason
# "<...>"`) from <workdir>/join-plan.json into the consolidated end-of-run
# readout, instead of leaving them recorded but unread.
#
# WHY (beads-sigma-zjkw, the real M5 gap): when a join/Lookup target is not
# unique at the key grain, probe-join-keys.rb lets an operator resolve it by
# (a) adding a pre-aggregated helper element to the data model at the key
# grain and repointing the Lookup at it (`--how preaggregated`), or (b)
# accepting the arbitrary-match risk (`--how waived`) — either way recording
# a human-written `reason` on the entry's `resolution` key. NOTHING
# downstream ever read that back out: migrate-tableau.rb's MIGRATION
# COVERAGE readout is built solely from build-charts' own coverage.json, never
# from join-plan.json. So a DM-level pre-aggregated helper table — the actual
# "Custom SQL aggregate table that wasn't in Tableau" a field report
# described — had a recorded reason that never reached any customer-visible
# surface. This module closes that gap.
#
# Pure + offline + no network — unit-tested in
# test-join-plan-resolution-surfacing.rb. Plugin-local: NOT vendored to other
# plugins (only scripts/lib/coverage_gate.rb is shared — see
# shared/manifest.json).
require 'json'

module JoinPlanResolutions
  module_function

  # Read join-plan.json defensively; nil when absent/garbage so callers can
  # no-op (a run before the ledger existed, or one whose derivation failed,
  # should never crash the end-of-run readout over this).
  def load(path)
    return nil unless path && File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  # 'how' values probe-join-keys.rb accepts for --resolve (see its --resolve
  # handling). Anything else on a 'resolution' key (absent, malformed, or an
  # unrecognized value) is treated as NOT resolved — surfacing it here would
  # misrepresent a still-blocking entry as explained.
  RESOLVED_HOW = %w[preaggregated waived].freeze

  # Entries carrying an operator-recorded resolution. Unresolved entries
  # (unprobed, unique, or non-unique-but-not-yet-resolved) are excluded on
  # purpose — this surfacing is only for entries that already have a
  # human-written explanation to show.
  def resolved_entries(doc)
    entries = doc.is_a?(Hash) ? Array(doc['entries']) : []
    entries.select do |e|
      e.is_a?(Hash) && e['resolution'].is_a?(Hash) && RESOLVED_HOW.include?(e['resolution']['how'].to_s)
    end
  end

  # One short line per resolved entry: which relationship, its kind, how it
  # was resolved, and the recorded reason — the piece of information the
  # field report needed and never had.
  def report_lines(doc)
    resolved_entries(doc).map do |e|
      res = e['resolution']
      "   - #{e['left']} -> #{e['right']} (#{e['kind']}, #{res['how']}): #{res['reason']}"
    end
  end

  def headline(doc)
    n = resolved_entries(doc).size
    "#{n} gate-16 join-cardinality resolution(s) recorded in join-plan.json " \
      '(each added or accepted a helper element / arbitrary-match risk to fix a non-unique join target):'
  end
end
