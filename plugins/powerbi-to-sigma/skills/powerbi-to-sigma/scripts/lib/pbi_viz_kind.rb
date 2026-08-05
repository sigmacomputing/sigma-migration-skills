# frozen_string_literal: true
#
# PbiVizKind — resolve a raw Power BI `visualType` to a Sigma element kind + ROLE
# CLASS, from the documentation-grounded catalogs (single source of truth):
#
#   refs/catalogs/viz-kind.json       native PBI visualTypes (exact match)
#   refs/catalogs/custom-visual.json  third-party/AppSource visuals (regex match)
#
# WHY THIS EXISTS (measured on 4 real customer .pbix files, 2026-07-30): the
# extractors mapped visualType -> kind with `VISUAL_KIND.get(vt, "bar")`, so ANY
# unrecognized type silently became a bar chart. That turned 21 third-party
# date-picker SLICERS into bar charts (every page lost its date filter), plus 4
# modern `cardVisual` cards and 5 decorative `shape`s. The builder warned, but
# recorded them as severity 'approximated' — which the coverage headline counts as
# CARRIED OVER, so no gate failed — with guidance that was wrong ("Sigma has no
# native Datepicker"; Sigma has a native date-range control).
#
# Two design rules follow, both enforced by test-viz-kind-catalog.rb:
#   1. NO SILENT DEFAULT. An unresolved token returns nil; `resolve_or_guidance`
#      yields role_class 'unsupported' + actionable guidance and NO sigma target.
#   2. ROLE CLASS decides severity. Losing a `control` (the page lost its filter),
#      `kpi`, `chart` or `table` is a FUNCTIONAL loss the gate can fail on; losing
#      a `decoration` or `text` is cosmetic. `functional?` is that test. `image`
#      is ALSO non-functional (a missing logo is cosmetic, not a data loss) but
#      is its OWN role_class, distinct from `decoration`: an image visual DOES
#      build a real Sigma element when --image-map supplies a hosted URL, and
#      has its own dedicated coverage entry when it can't — unlike a shape,
#      which never builds anything. Conflating the two made every image visual
#      return nil before ever reaching its build logic (review-caught regression).
#
# ALL prose (per-row guidance, the unknown/heuristic templates) lives in the
# catalog JSON, never in code — so this resolver and its Python mirror
# (lib/pbi_viz_kind.py, used by the extractors) stay thin and cannot drift in
# wording. Resolution order: viz-kind exact -> custom-visual regex -> generic
# slicer/filter heuristic -> nil. Pure + stdlib-only.
require 'json'

module PbiVizKind
  module_function

  FUNCTIONAL_ROLES = %w[control kpi chart table].freeze
  NO_TARGET_ROLES  = %w[decoration unsupported].freeze

  # True when losing this visual is a FUNCTIONAL regression (gate-worthy).
  def functional?(role_class)
    FUNCTIONAL_ROLES.include?(role_class.to_s)
  end

  def load(catalog_dir)
    Catalog.new(catalog_dir)
  end

  # Fallback templates if custom-visual.json is absent (viz-kind-only install).
  DEFAULT_UNKNOWN_GUIDANCE =
    "Unrecognized visual '{token}' — no Sigma kind was assumed; recorded as " \
    'unsupported rather than silently rendered as a chart. Inspect what it binds and ' \
    'what it does, then add a row to refs/catalogs/custom-visual.json.'

  class Catalog
    attr_reader :rows, :custom_rows

    def initialize(dir)
      @dir = dir
      @rows = JSON.parse(File.read(File.join(dir, 'viz-kind.json')))['rows'] || []
      cvp = File.join(dir, 'custom-visual.json')
      @env = File.exist?(cvp) ? JSON.parse(File.read(cvp)) : {}
      @custom_rows = @env['rows'] || []
      @by_type = {}
      @rows.each do |r|
        (r['pbi_visual_types'] || []).each { |t| @by_type[t.to_s.downcase] ||= r }
      end
      @compiled = @custom_rows.select { |cr| cr['match'] }
                              .map { |cr| [Regexp.new(cr['match'], Regexp::IGNORECASE), cr] }
      @slicer_hint = Regexp.new(@env['slicer_hint_pattern'] || 'slicer|filter|picker', Regexp::IGNORECASE)
      @date_hint   = Regexp.new(@env['date_hint_pattern'] || 'date|timeline|calendar', Regexp::IGNORECASE)
    end

    # Raw PBI visualType -> normalized row hash, or nil when nothing matches.
    # Keys: source, role_class, sigma (concrete Sigma kind), sigma_target,
    #       builder_kind (coarse token the builder switches on), guidance,
    #       approximate (data-preserving substitution), catalog, visual_type.
    def resolve(visual_type)
      t = visual_type.to_s.strip
      return nil if t.empty?
      if (r = @by_type[t.downcase])
        return normalize(r, t, 'viz-kind')
      end
      if (pair = @compiled.find { |rx, _| rx.match?(t) })
        return normalize(pair[1], t, 'custom-visual')
      end
      heuristic(t)
    end

    # Never nil — every caller gets a role_class + guidance to record.
    def resolve_or_guidance(visual_type)
      resolve(visual_type) || unknown_row(visual_type)
    end

    def unknown_row(token)
      tmpl = @env['unknown_guidance'] || PbiVizKind::DEFAULT_UNKNOWN_GUIDANCE
      { 'source' => token.to_s, 'role_class' => 'unsupported', 'sigma' => nil,
        'sigma_target' => nil, 'builder_kind' => nil, 'catalog' => 'none',
        'approximate' => false, 'visual_type' => token.to_s,
        'guidance' => tmpl.gsub('{token}', token.to_s) }
    end

    private

    # An unlisted visual whose NAME says it filters -> a control. Deliberately
    # conservative: a false control is recoverable; a false bar chart silently
    # deletes a page's filter.
    def heuristic(t)
      return nil unless @slicer_hint.match?(t)
      kind = @date_hint.match?(t) ? 'date-range' : 'list'
      tmpl = @env['heuristic_guidance'] ||
             "Unlisted visual '{token}' looks like a filter — emitted as a Sigma {kind} control."
      { 'source' => t, 'role_class' => 'control', 'sigma' => kind, 'sigma_target' => kind,
        'builder_kind' => 'control', 'catalog' => 'heuristic', 'approximate' => false,
        'visual_type' => t,
        'guidance' => tmpl.gsub('{token}', t).gsub('{kind}', kind) }
    end

    def normalize(r, token, which)
      role = r['role_class'].to_s
      # The two catalogs carry the two names in DIFFERENT fields:
      #   viz-kind.json      `source` = the coarse token the Ruby builder switches
      #                      on (SIGMA_KIND[source] = sigma); `sigma` = Sigma kind.
      #   custom-visual.json `sigma`  = that coarse token; `sigma_target` = Sigma kind.
      # Getting this backwards emits sigma_kind:'bar-chart' where the builder
      # expects 'bar' — caught by test-extract-viz-signals.py.
      builder = which == 'viz-kind' ? r['source'] : r['sigma']
      # concrete Sigma kind: explicit sigma_target wins; a control with no target
      # defaults to a list control; decoration/unsupported get NO target so no
      # caller can accidentally render one.
      sigma = r['sigma_target'] || r['sigma']
      sigma = 'list' if role == 'control' && (sigma.nil? || sigma == 'control')
      if NO_TARGET_ROLES.include?(role)
        sigma = nil
        builder = nil                      # inert: the builder routes on role_class
      end
      approx = Array(r['approximate_types']).map { |x| x.to_s.downcase }.include?(token.downcase)
      { 'source' => r['source'], 'role_class' => role, 'sigma' => sigma,
        'sigma_target' => r['sigma_target'], 'builder_kind' => builder,
        'guidance' => r['guidance'], 'notes' => r['notes'], 'approximate' => approx,
        'catalog' => which, 'visual_type' => token }
    end
  end
end
