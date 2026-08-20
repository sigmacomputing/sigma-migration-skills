# frozen_string_literal: true

# Single source of truth for which Tableau dashboard actions became real Sigma
# workbook actions and which remain manual residue.
#
# Why this exists: three surfaces (scan-workbook-gaps.rb, <out>-actions.md,
# POSTPUBLISH_GUIDE.md) each independently asserted "actions are manual". When
# that stopped being true, only one could be updated at a time and the others
# lied. Now all three render from this.
#
# Shapes verified live 2026-08-06 (real POST /v2/workbooks/spec + readback).
require 'json'

module ActionLedger
  SCHEMA_VERSION = 1

  TRIGGERS = %w[on-click on-select on-close
                on-primary-cta-click on-secondary-cta-click].freeze

  # effect => required property names (beyond "effect" itself).
  # NOTE: open-url's `url` is NOT required by the API — a missing url is
  # schema-valid and does nothing. We require it anyway; that is deliberate.
  EFFECT_REQUIRED = {
    'navigate'          => %w[target],
    'set-control-value' => %w[control value],
    'clear-control'     => %w[scope],
    'open-url'          => %w[openTarget url],
    'open-overlay'      => %w[overlayId],
    'close-overlay'     => [],
    'select-tab'        => %w[tabbedContainer selectedTab],
    'refresh-element'   => %w[target],
    'insert-rows'       => %w[table values],
    'update-rows'       => %w[table whichRows values],
    'delete-rows'       => %w[table whichRows],
    'open-document'     => %w[document documentType openTarget]
  }.freeze

  # Action ids must be unique across the ENTIRE workbook, not per element:
  # a per-element counter produces a live 400 "Duplicate action id".
  # `registry` is a Hash the caller keeps for one workbook.
  def self.new_id(registry, host_element_id)
    registry[host_element_id] = (registry[host_element_id] || 0) + 1
    "act-#{host_element_id}-#{registry[host_element_id]}"
  end

  # Returns an array of human-readable error strings; empty means valid.
  def self.validate_action(action)
    errs = []
    errs << 'action is missing required key `id`' if action['id'].to_s.empty?
    unless TRIGGERS.include?(action['trigger'])
      errs << "invalid trigger #{action['trigger'].inspect} (expected one of #{TRIGGERS.join(', ')})"
    end
    effects = action['effects']
    if !effects.is_a?(Array) || effects.empty?
      errs << 'action requires a non-empty effects[]'
      return errs
    end
    effects.each_with_index do |eff, i|
      name = eff['effect']
      unless EFFECT_REQUIRED.key?(name)
        errs << "effects[#{i}]: unknown effect #{name.inspect}"
        next
      end
      EFFECT_REQUIRED[name].each do |req|
        if eff[req].nil? || eff[req].to_s.empty?
          errs << "effects[#{i}] (#{name}): missing required property `#{req}`"
        end
      end
    end
    errs
  end

  def self.write_manifest(path, entries)
    File.write(path, JSON.pretty_generate(entries))
  end

  def self.read_manifest(path)
    return [] unless path && File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    []
  end

  # detected: entries from build-postpublish-guide's extractors
  #           (each has at least 'kind' and 'caption', and 'actionName' when
  #           the source Tableau action carries a per-instance identifier)
  # emitted:  entries from build-charts-from-signals' manifest
  #           (each has 'actionId' and 'source' => {'kind','caption',
  #           'actionName', ...})
  #
  # Invariant: detectedCount == emitted.size + residue.size, disjoint. This
  # only holds if `key_of` can tell apart two detected entries that happen to
  # share [kind, caption] — see key_of's comment for why it prefers
  # `actionName` for that reason.
  def self.join(detected:, emitted:)
    claimed = emitted.map { |e| key_of(e['source'] || {}) }.compact
    residue = detected.reject { |d| claimed.include?(key_of(d)) }
    {
      'schemaVersion'  => SCHEMA_VERSION,
      'detectedCount'  => detected.size,
      'emitted'        => emitted,
      'residue'        => residue
    }
  end

  # Identity of a detected action. Uses a two-element ARRAY, not string
  # concatenation: a "kind|caption" string would let ["a|b", "c"] and
  # ["a", "b|c"] collide, and any separator character can appear in a caption.
  #
  # [kind, caption] alone collides whenever two DIFFERENT Tableau actions
  # share both — e.g. two "Home" nav-buttons on different dashboards. If only
  # one of them is actually emitted, BOTH detected entries would match the
  # single claimed key and both would vanish from `residue`: the unemitted
  # one is silently dropped and nobody is told to wire it by hand. Prefer
  # `actionName` (a Tableau-sourced per-instance identifier — the <action>
  # element's `name` attribute where one exists, or an equivalent stable
  # handle the caller derives when it doesn't) when the entry carries one;
  # fall back to [kind, caption] only when it is absent. Not every detected
  # kind has an actionName (e.g. dynamic zone-visibility nodes have no
  # <action> element at all) — that is fine, since those kinds are never
  # currently auto-emitted and so never actually collide in `join`.
  def self.key_of(entry)
    return nil if entry.nil?
    name = entry['actionName']
    return [entry['kind'], name] if name && !name.to_s.empty?
    [entry['kind'], entry['caption']]
  end
end
