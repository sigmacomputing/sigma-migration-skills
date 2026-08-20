# frozen_string_literal: true
#
# datasource_filter_check.rb — does the built workbook actually APPLY every
# Tableau DATA-SOURCE-level (always-on) filter the source carried? (#483)
#
# A Tableau data-source filter (a <filter> on a <datasource>/<extract>, or a
# database-domain filter hosted in a virtual-connection <shared-view>) row-scopes
# EVERY worksheet on that datasource and renders NOTHING on any dashboard surface.
# So the Phase-1d "read the PNG" gate structurally cannot catch a miss: the
# migrated workbook queries unfiltered data and every aggregate silently
# over-reports (the field signature is a suspiciously UNIFORM ~20-25% inflation
# across unrelated distinct counts). This is a pure function used by
# assert-phase6-ran.rb's datasource-filter gate; it takes the parsed inputs and
# returns human-readable violation strings (empty = clean). No I/O, so the gate
# and the offline regression test drive the same logic.
#
# A data-source filter is SATISFIED when its column is either:
#   - APPLIED as a workbook-wide default filter (an element-level `filters`
#     entry on the master, or on any element sourcing it), OR
#   - surfaced as a visible CONTROL (a png-read filter_shelf label, or a
#     kind:control element named for it) — EXCEPT for an always-on boolean
#     `active` flag (is_active_flag), which must be APPLIED, not left as a
#     user-widenable open control.
#
# API:
#   DatasourceFilterCheck.violations(datasource_filters:, filter_shelf:, spec:, master_id: 'master')
require 'json'
require 'set'
require_relative 'workbook_code'

module DatasourceFilterCheck
  module_function

  def norm(s)
    s.to_s.downcase.strip.gsub(/\s+/, ' ')
  end

  # Every workbook element regardless of envelope. Canonical workbooks use
  # flat document.elements; WorkbookCode retains a legacy nested fallback for
  # pre-release fixtures.
  def all_elements(spec)
    return [] unless spec.is_a?(Hash) || spec.is_a?(Array)
    records = spec.is_a?(Array) ? spec : WorkbookCode.elements(spec)
    records.select { |element| element.is_a?(Hash) }
  end

  # columnIds (across every element) whose column display name matches `caption`.
  def column_ids_for(elems, caption)
    key = norm(caption)
    ids = Set.new
    elems.each do |el|
      Array(el['columns']).each do |c|
        next unless c.is_a?(Hash)
        name = c['name'] || c['displayName'] || c['caption'] || c['label'] || c['columnName']
        cid  = c['id'] || c['columnId']
        ids << cid if cid && norm(name) == key
      end
    end
    ids
  end

  # A filter target's columnId, however the shape nests it.
  def target_column_id(t)
    return nil unless t.is_a?(Hash)
    t['columnId'] || t.dig('source', 'columnId') || t.dig('column', 'id') || t['column']
  end

  # Is `caption` applied as an always-on element-level filter anywhere in the
  # spec? Matches by columnId (a column named for the caption that some element
  # filters on) OR by the caption text appearing in a serialized element filter.
  # CONTROL elements are EXCLUDED: a control's `filters` are its user-toggleable
  # target bindings, NOT an always-on default — an always-on data-source filter
  # (esp. an is_active_flag) is only satisfied by a genuine element-level filter
  # (e.g. on the master table), never by a control that happens to bind the
  # column. (Non-flag filters can still be satisfied via surfaced_as_control?.)
  def applied_as_filter?(elems, caption)
    cids = column_ids_for(elems, caption)
    key  = norm(caption)
    elems.any? do |el|
      next false if el['kind'].to_s == 'control'
      filt = el['filters'] || el['filter']
      next false if filt.nil?
      list = filt.is_a?(Array) ? filt : [filt]
      list.any? do |t|
        next false unless t.is_a?(Hash)
        cid = target_column_id(t)
        (cid && cids.include?(cid)) || norm(JSON.generate(t)).include?(key)
      end
    end
  end

  # Is `caption` surfaced as a visible control (png-read filter_shelf label or a
  # kind:control element named for it)?
  def surfaced_as_control?(elems, filter_shelf, caption)
    key = norm(caption)
    return true if Array(filter_shelf).any? { |f| f.is_a?(Hash) && norm(f['label'] || f['caption'] || f['name']) == key }
    elems.any? { |el| el['kind'].to_s == 'control' && norm(el['name']) == key }
  end

  def violations(datasource_filters:, filter_shelf:, spec:, master_id: 'master')
    elems = all_elements(spec)
    out = []
    Array(datasource_filters).each do |df|
      next unless df.is_a?(Hash)
      next if df['is_action']
      cap = df['column_caption']
      next if cap.nil? || cap.to_s.strip.empty? # unresolvable caption — build-charts already warns; can't enforce here
      active = df['is_active_flag'] == true
      applied = applied_as_filter?(elems, cap)
      control = surfaced_as_control?(elems, filter_shelf, cap)
      satisfied = active ? applied : (applied || control)
      next if satisfied

      scope = df['filter_scope'] || (df['shared_view'] ? 'shared-view datasource' : 'datasource')
      if active && control && !applied
        out << "datasource filter NOT applied: always-on flag #{cap.inspect} (#{scope}) is surfaced only as a " \
               'user CONTROL, but an always-on data-source filter must NOT be user-widenable — apply it as a ' \
               "workbook-wide default filter on the master element #{master_id.inspect} (members: #{Array(df['members']).inspect})."
      else
        out << "datasource filter NOT applied: #{cap.inspect} (#{scope}) is a Tableau always-on data-source " \
               'filter that renders nothing on any dashboard, but the built workbook neither applies it as a ' \
               "workbook-wide default filter on the master element #{master_id.inspect} nor surfaces it as a " \
               'control. Every aggregate silently over-reports until it is applied. Apply it as a master ' \
               "default filter (members: #{Array(df['members']).inspect})#{df['is_active_flag'] ? '' : ', or expose it as a control with its default set'}."
      end
    end
    out.uniq
  end
end
