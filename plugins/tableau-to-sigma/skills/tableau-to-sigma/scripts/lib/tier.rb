# frozen_string_literal: true
#
# tier.rb — the W2.1 tier-ratchet DETECTOR: one PURE function over on-disk
# discovery artifacts, evaluated at the Phase-0c checkpoint (the first point
# where discovery metadata + the gap scan both exist, before any DM/workbook
# POST). Pure-lib precedent: lib/fast_path.rb ("decide() is a PURE function…
# unit-testable offline").
#
# THE PREDICATE IS MECHANICAL ONLY — every input is an artifact some script
# wrote to the workdir; nothing here accepts an agent-supplied count (the
# anti-gaming guard). Tier NEVER removes a gate: the resolved tier shrinks
# budgets and duplicate oracles only (rcf_passes 5→1, gate-side waiver-budget
# scale + the gate-18 valued-anchors trio skip — lane B's half). All 25 gates
# still execute on every tier.
#
# Tier-S predicate (merged plan W2.1, consensus of all three planners):
#   ≤1 dashboard  ∧  ≤8 content zones  ∧  0 ❌-unhandled gap classes
#   ∧  ≤2 controls  ∧  no pivot tiles  ∧  no extracts
# Every feature that fails flips the tier to M (named in `reasons`).
# FAIL-CLOSED: a missing/unreadable predicate input resolves 'full' — the
# complete battery, today's behavior — never a guessed S/M.
#
# Vocabulary contract (cross-lane contract 4 + 7): the tier strings written to
# migrate-state.json are lane B's closed vocabulary — Offramp::TIER_VALUES
# (%w[S M full]), Offramp::TIER_AUTO ('auto', CLI sentinel only, never written
# to state) and Offramp::TIER_BASIS (%w[auto-predicate operator-override
# fail-closed]) in shared/lib/offramp.rb; the canonical example state is
# pinned in shared/lib/testdata/wave2-tier-state.json. The literals below are
# those tokens VERBATIM (this lib stays loadable before the vocabulary commit
# merges; test-tier-detect.rb cross-checks the fixture whenever it is present).
#
# Artifacts read (all workdir-local, all optional-with-consequences):
#   dashboard-layout.json  dashboards, zones, controls, pivots  (parse-twb-layout.rb)
#   get-workbook.json      hasExtracts                          (tableau-discover.rb)
#   *gaps*report*.json     ❌-unhandled feature classes          (scan-workbook-gaps.rb)

require 'json'

module Tier
  # Lane B's Offramp::TIER_VALUES / TIER_BASIS tokens, verbatim (see header).
  TIER_S    = 'S'
  TIER_M    = 'M'
  TIER_FULL = 'full'
  BASIS_AUTO     = 'auto-predicate'
  BASIS_OVERRIDE = 'operator-override'
  BASIS_CLOSED   = 'fail-closed'

  # Zone kinds that are dashboard CONTENT for the ≤8-zones feature. Structural
  # scaffolding (containers, spacers, titles) is layout plumbing — a real
  # single-chart dashboard routinely nests 3-5 layout-flow containers, so an
  # all-zones count would flip every real workbook to M on scaffolding alone.
  STRUCTURAL_ZONE_KINDS = %w[container spacer title].freeze
  # Zone kinds that are interactive CONTROLS for the ≤2-controls feature
  # (parse-twb-layout.rb zone_kind: 'filter' = filter card, 'parameter' =
  # parameter control; legends are read-only and do not count).
  CONTROL_ZONE_KINDS = %w[filter parameter].freeze
  MAX_S_DASHBOARDS = 1
  MAX_S_ZONES      = 8
  MAX_S_CONTROLS   = 2

  module_function

  # detect(workdir) → {
  #   'tier'       => 'S' | 'M' | 'full',
  #   'tier_basis' => 'auto-predicate' | 'fail-closed',
  #   'features'   => {dashboards:, zones:, controls:, pivots:,
  #                    unhandled_gap_classes:, extracts:},   (nil per unreadable input)
  #   'reasons'    => [String, …]   # why not S (empty when tier == 'S')
  # }
  # Pure: reads the named files, touches nothing, never raises.
  def detect(workdir)
    reasons = []
    features = {}

    layout = read_json(File.join(workdir.to_s, 'dashboard-layout.json'))
    gw     = read_json(File.join(workdir.to_s, 'get-workbook.json'))
    gap_path = Dir[File.join(workdir.to_s, '*gaps*report*.json')].min ||
               Dir[File.join(workdir.to_s, '*gaps*.json')].min
    gaps = gap_path ? read_json(gap_path) : nil

    # FAIL-CLOSED trajectory: any unreadable predicate input → the full
    # battery. Never guess a shrunk tier from partial evidence.
    missing = []
    missing << 'dashboard-layout.json' unless layout.is_a?(Array) || layout.is_a?(Hash)
    missing << 'get-workbook.json' unless gw.is_a?(Hash)
    missing << '*gaps*report*.json' unless gaps.is_a?(Hash)
    if missing.any?
      return { 'tier' => TIER_FULL, 'tier_basis' => BASIS_CLOSED,
               'features' => features,
               'reasons' => ["predicate input(s) missing/unreadable: #{missing.join(', ')} — fail-closed to the full battery"] }
    end

    dashes = layout.is_a?(Array) ? layout : [layout]
    dashes = dashes.select { |d| d.is_a?(Hash) }.reject { |d| d['dashboard'].to_s.start_with?('[synthetic]') }
    zones  = dashes.flat_map { |d| Array(d['zones']).select { |z| z.is_a?(Hash) } }
    features['dashboards'] = dashes.size
    features['zones']      = zones.reject { |z| STRUCTURAL_ZONE_KINDS.include?(z['kind'].to_s) }.size
    features['controls']   = zones.count { |z| CONTROL_ZONE_KINDS.include?(z['kind'].to_s) }
    features['pivots']     = zones.count { |z| z['kind'].to_s == 'chart' && z['chart_kind'].to_s == 'pivot-table' }

    wb = gw['workbook'] || gw
    features['extracts'] = wb['hasExtracts'] == true ||
                           [wb['hasExtracts'], wb['datasources']].to_s.include?('true')

    feats = Array(gaps['detected_features']).select { |f| f.is_a?(Hash) }
    features['unhandled_gap_classes'] =
      feats.select { |f| f['status'].to_s == 'unhandled' }.map { |f| f['name'].to_s }.uniq.size

    reasons << "#{features['dashboards']} dashboards > #{MAX_S_DASHBOARDS}" if features['dashboards'] > MAX_S_DASHBOARDS
    reasons << "#{features['zones']} content zones > #{MAX_S_ZONES}" if features['zones'] > MAX_S_ZONES
    reasons << "#{features['controls']} controls > #{MAX_S_CONTROLS}" if features['controls'] > MAX_S_CONTROLS
    reasons << "#{features['pivots']} pivot tile(s)" if features['pivots'].positive?
    reasons << "#{features['unhandled_gap_classes']} ❌-unhandled gap class(es)" if features['unhandled_gap_classes'].positive?
    reasons << 'extracts (hasExtracts=true)' if features['extracts']

    { 'tier' => reasons.empty? ? TIER_S : TIER_M,
      'tier_basis' => BASIS_AUTO, 'features' => features, 'reasons' => reasons }
  rescue StandardError => e
    { 'tier' => TIER_FULL, 'tier_basis' => BASIS_CLOSED, 'features' => {},
      'reasons' => ["detector raised (#{e.class}) — fail-closed to the full battery"] }
  end

  def read_json(path)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path, encoding: 'UTF-8'))
  rescue StandardError
    nil
  end
end
