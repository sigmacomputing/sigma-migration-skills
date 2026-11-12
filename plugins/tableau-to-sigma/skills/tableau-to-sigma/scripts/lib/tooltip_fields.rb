# frozen_string_literal: true

require 'json'

# tooltip_fields.rb — Tableau fields a worksheet carries ONLY on its tooltip.
#
# A Tableau view CSV exports every field on the marks card, tooltip included
# (Stress 4 "Store State Map": State, Orders, Net Revenue). Sigma tooltips are
# UI-only, so the region map plots Net Revenue and has no Orders column; the
# parity planner aborted ("source export column identity is unresolved") and
# the run needed a hand-patched spec. A field that appears in the zone's
# tooltip_fields and on NO other channel or shelf is tooltip-only: the parity
# plan skips its CSV column with a recorded reason (never silently).
module TooltipFields
  module_function

  def guid(ref)
    ref.to_s[/\[(?:[a-z]+:)?([^:\]\[]+)(?::[a-z]+)?\]\z/i, 1]
  end

  def guids(value)
    case value
    when Hash then value.values.flat_map { |v| guids(v) }
    when Array then value.flat_map { |v| guids(v) }
    else
      [guid(value)].compact
    end
  end

  def read_json(path)
    JSON.parse(File.read(path, encoding: 'UTF-8'))
  rescue StandardError
    nil
  end

  # => ["Orders", ...] (captions, original case) for the worksheet's zone.
  def tooltip_only_captions(workdir, worksheet)
    layout = read_json(File.join(workdir, 'dashboard-layout.json'))
    zones = Array(layout.is_a?(Array) ? layout : (layout.is_a?(Hash) ? (layout['dashboards'] || [layout]) : nil))
            .flat_map { |d| d.is_a?(Hash) ? Array(d['zones']) : [] }
    zone = zones.find { |z| z.is_a?(Hash) && z['caption'].to_s == worksheet.to_s && Array(z['tooltip_fields']).any? }
    return [] unless zone
    # Plotted = a non-tooltip marks-card channel or a rows/columns shelf.
    # (measures / aggregations / calculations list EVERY marks-card field,
    # tooltip included, so they are no evidence of plotting.)
    chans = zone['channels'].is_a?(Hash) ? zone['channels'].reject { |k, _| k == 'tooltip' } : {}
    elsewhere = guids([chans, zone['rows_shelf'], zone['cols_shelf']])
    meta = read_json(File.join(workdir, 'dashboard-layout-meta.json')) || {}
    by_guid = meta['columns_by_guid'].is_a?(Hash) ? meta['columns_by_guid'] : {}
    Array(zone['tooltip_fields']).map do |ref|
      g = guid(ref)
      next nil if g.nil? || elsewhere.include?(g)
      c = by_guid[g]
      (c.is_a?(Hash) ? c['caption'] : nil) || g
    end.compact.uniq
  end
end
