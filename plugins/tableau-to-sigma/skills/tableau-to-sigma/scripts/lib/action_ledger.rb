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
  #
  # ACTION FIELD RENAME (live since 2026-08-26, probe-verified): identifier
  # properties now carry the referenced resource type and an `Id` suffix. The
  # names below are the post-rename ones; the pre-rename spellings (`table`,
  # `tabbedContainer`, `document`) are REJECTED by the API.
  #
  # `set-control-value` keeps a bare `control`, and `navigate`/`refresh-element`
  # keep a bare `target` — those were deliberately NOT renamed (probe-confirmed
  # that the `*Id` form 400s). Don't "regularise" them.
  # Required top-level properties per effect, DERIVED FROM the canonical OpenAPI
  # asset (assets.sigmacomputing.com/openapi/public-rest-api/...) on 2026-08-26,
  # the day the action field rename went live. All 23 effects the API accepts are
  # listed: the previous table had 12, so any converter emitting one of the other
  # 11 was rejected by our own validator as an "unknown effect".
  #
  # `open-url` is deliberately STRICTER than the spec, which requires only
  # openTarget: an open-url with no `url` is schema-valid, persists, and does
  # NOTHING. A generator bug that drops the url ships a healthy-looking button
  # that is inert, so assert it here.
  EFFECT_REQUIRED = {
    'call-agent'                  => %w[agentId prompt],
    'call-api'                    => %w[connectorId],
    'call-stored-procedure'       => %w[storedProcedure],
    'clear-chat-element-messages' => %w[chatElementId],
    'clear-control'               => %w[scope],
    'close-overlay'               => [],
    'custom-sort'                 => %w[elementId sort],
    'delete-rows'                 => %w[tableElementId whichRows],
    'export'                      => %w[channel source uri],
    'if-else'                     => %w[if],
    'insert-rows'                 => %w[tableElementId values],
    'navigate'                    => %w[target],
    'open-document'               => %w[documentId documentType openTarget],
    'open-overlay'                => %w[overlayId],
    'open-url'                    => %w[openTarget url],
    'refresh-element'             => %w[target],
    'reset-form'                  => [],
    'run-python-element'          => %w[codeElementId],
    'select-tab'                  => %w[tabbedContainerElementId selectedTab],
    'set-control-value'           => %w[control value],
    'set-form-values'             => %w[formElementId values],
    'trigger-plugin'              => %w[pluginElementId pluginEffectId],
    'update-rows'                 => %w[tableElementId whichRows values]
  }.freeze

  # ---- the 2026-08-26 action field rename -----------------------------------
  #
  # Sigma renamed identifier fields to an explicit *Id shape. Every old name now
  # hard-400s EXCEPT ONE, which is why this table exists rather than a code
  # comment: `clear-control` `scope:{type:page, page:}` returns 200 OK and
  # SILENTLY DROPS the key -- readback is a bare `scope:{type:page}` and the
  # button clears nothing. A generator still emitting `page:` looks completely
  # healthy. Status codes are not evidence here; the emitted shape is.
  #
  # Nested paths matter as much as top-level ones and had NO coverage before:
  # a value source, a whichRows selector, a custom-sort key and a column-range
  # bound are all places the old bare name still parsed fine locally.
  DEAD_KEYS = {
    'table'            => 'tableElementId',
    'form'             => 'formElementId',
    'tabbedContainer'  => 'tabbedContainerElementId',
    'document'         => 'documentId',
    'pluginElement'    => 'pluginElementId',
    'pluginEffect'     => 'pluginEffectId',
    'column'           => 'columnId',
    'min'              => 'minColumnId',
    'max'              => 'maxColumnId'
  }.freeze

  # Renames that apply ONLY inside a discriminated union member, because the
  # bare name is still the ONLY accepted form elsewhere. The rename is
  # deliberately selective -- these three were probed and NOT renamed, so
  # "fixing" them to *Id is itself a 400:
  #   set-control-value.control                  stays `control`
  #   navigate         target{type:page}.page    stays `page`
  #   refresh-element  target{type:element}.element stays `element`
  # So `page`/`element`/`control` are dead only under a clear-control scope.
  DEAD_KEYS_IN_CLEAR_CONTROL_SCOPE = {
    'page'      => 'pageId',
    'control'   => 'controlId',
    'container' => 'containerElementId'
  }.freeze

  # Union members whose required keys we can check once we see `type`.
  # Spec-derived; `column-range` is listed with NO required keys on purpose --
  # minColumnId/maxColumnId are both OPTIONAL in the API, so a range that lost
  # its bounds is schema-valid and silently unbounded. Warned about separately.
  UNION_REQUIRED = {
    'column'       => %w[columnId],
    'column-match' => %w[columnId],
    'column-range' => [],
    'control'      => %w[controlId],
    'container'    => %w[containerElementId],
    'constant'     => %w[value],
    'formula'      => %w[formula]
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
      # Nested shapes. Before this, EFFECT_REQUIRED only saw the top level, so a
      # values[]/whichRows/sort/scope still carrying a pre-rename key passed
      # validation here and then 400'd live (or, for clear-control page,
      # succeeded and silently did nothing).
      errs.concat(deep_errors(eff, "effects[#{i}] (#{name})", name))
    end
    errs
  end

  # Walks an effect looking for (a) dead pre-rename keys, (b) union members
  # missing their required *Id, and (c) the two shapes that are schema-valid but
  # inert. Path-aware because the SAME key name can be live or dead depending on
  # where it sits: `control` is correct under set-control-value and dead under a
  # clear-control scope.
  def self.deep_errors(node, path, effect_name, in_clear_control_scope = false)
    errs = []
    case node
    when Hash
      node.each_key do |key|
        if (replacement = DEAD_KEYS[key])
          errs << "#{path}.#{key}: `#{key}` was renamed to `#{replacement}` " \
                  '(Sigma action field rename, 2026-08-26) — the old key is rejected'
        end
        next unless in_clear_control_scope && (replacement = DEAD_KEYS_IN_CLEAR_CONTROL_SCOPE[key])
        errs << "#{path}.#{key}: under a clear-control scope `#{key}` was renamed to " \
                "`#{replacement}`" + (key == 'page' ? ' — and the old key is dropped SILENTLY (200 OK, clears nothing)' : '')
      end

      type = node['type']
      if type.is_a?(String) && UNION_REQUIRED.key?(type)
        UNION_REQUIRED[type].each do |req|
          if node[req].nil? || node[req].to_s.empty?
            errs << "#{path}: {type: #{type.inspect}} requires `#{req}`"
          end
        end
        # Both bounds optional in the API, so an empty range is accepted and
        # silently matches everything. Almost always a dropped/renamed key.
        if type == 'column-range' && node['minColumnId'].to_s.empty? && node['maxColumnId'].to_s.empty?
          errs << "#{path}: {type: \"column-range\"} has neither minColumnId nor maxColumnId — " \
                  'the API accepts this and the range silently matches everything'
        end
      end

      node.each do |key, val|
        scope_now = in_clear_control_scope || (effect_name == 'clear-control' && key == 'scope')
        errs.concat(deep_errors(val, "#{path}.#{key}", effect_name, scope_now))
      end
    when Array
      node.each_with_index { |val, idx| errs.concat(deep_errors(val, "#{path}[#{idx}]", effect_name, in_clear_control_scope)) }
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
