# frozen_string_literal: true
#
# pivot_patch_guard.rb — plan C R7. Sigma honours a pivot's display.headerWidths /
# bodyWidths uniformWidth only when n_hdr x header + value_cols x body fits the element cell;
# otherwise it discards ALL widths (48px defaults, columns clipped). The builder emits widths
# that fit (PivotWidths.display). An RCF patch must not widen them past the cell, and must not
# put a squeezed pivot (body < 48px) on medium/large cellSpacing (illegible, live-proven).
#
# check(live, merged, dir:) -> [error strings] for pivot elements whose widths/spacing a patch changed.
require 'json'
require_relative 'pivot_widths'

module PivotPatchGuard
  module_function

  ILLEGIBLE_SPACINGS = %w[medium large].freeze
  SLACK = PivotWidths::SLACK_PX

  def pivots(node, acc = {})
    case node
    when Array then node.each { |n| pivots(n, acc) }
    when Hash
      acc[node['id']] ||= node if node['kind'] == 'pivot-table' && node['id']
      node.each_value { |v| pivots(v, acc) if v.is_a?(Array) || v.is_a?(Hash) }
    end
    acc
  end

  def width(el, key)
    v = el.dig('display', key, 'uniformWidth')
    v.is_a?(Numeric) ? v : nil
  end

  def row_header_cols(el)
    el.dig('display', 'rowLayout') == 'separate-columns' ? [Array(el['rowsBy']).size, 1].max : 1
  end

  # Element cell width from workdir artifacts: provenance (element -> worksheet caption), then the
  # dashboard-layout zone with that caption (w_pct) and the canvas width. nil when any link is missing.
  def cell_px(dir, element_id)
    return nil unless dir
    read = ->(name) { (JSON.parse(File.read(File.join(dir, name))) rescue nil) }
    prov = read.call('chart-provenance.json')
    ent = prov.is_a?(Hash) && prov['elements'].is_a?(Hash) ? prov['elements'][element_id] : nil
    return nil unless ent.is_a?(Hash) && ent['worksheet']
    layouts = read.call('dashboard-layout.json')
    layouts = [layouts] if layouts.is_a?(Hash)
    Array(layouts).each do |d|
      next unless d.is_a?(Hash)
      next if ent['dashboard'] && d['dashboard'] && d['dashboard'] != ent['dashboard']
      z = Array(d['zones']).find { |zn| zn.is_a?(Hash) && zn['caption'] == ent['worksheet'] && zn['w_pct'] }
      cell = z && PivotWidths.cell_px(d.dig('canvas_px', 'w'), z['w_pct'])
      return cell if cell
    end
    nil
  end

  def check(live, merged, dir: nil)
    before = pivots(live)
    errors = []
    pivots(merged).each do |id, el|
      old = before[id] || {}
      hdr, body = width(el, 'headerWidths'), width(el, 'bodyWidths')
      old_hdr, old_body = width(old, 'headerWidths'), width(old, 'bodyWidths')
      widths_changed = hdr != old_hdr || body != old_body
      if widths_changed && body && old_body.nil?
        # The builder omitted widths deliberately (columns unknown, or body < 16px). value_n is a
        # Tableau-CSV figure the guard cannot reach, so an added body width cannot be checked.
        if cell_px(dir, id)
          errors << "pivot '#{id}': the patch adds bodyWidths (#{body}px) where the builder emitted none; the builder " \
                    'omitted them deliberately (value columns unknown, or the body would be under ' \
                    "#{PivotWidths::MIN_BODY_PX}px), so the fit cannot be verified and Sigma would discard ALL pivot " \
                    'widths on overflow (48px default columns, clipped). Do not add pivot body widths.'
        end
      elsif widths_changed && body && old_body && (hdr || old_hdr)
        hdr ||= old_hdr
        old_hdr ||= hdr
        n_hdr = row_header_cols(el)
        cell = cell_px(dir, id)
        if cell
          # Value-column count is not in the spec: bound it from the builder's own fit (>= the true count).
          v = [(cell - SLACK - n_hdr * old_hdr) / old_body, 1].max
          budget = cell - SLACK
          if n_hdr * hdr + v * body > budget
            max = (budget - n_hdr * hdr) / v
            errors << overflow_msg(id, "#{n_hdr} x #{hdr} + #{v} x #{body} > #{budget} (cell #{cell} - #{SLACK})", max)
          end
        elsif body > old_body || hdr > old_hdr
          errors << overflow_msg(id, "header #{hdr} / body #{body} widen the builder-emitted #{old_hdr} / #{old_body} (cell unknown)", old_body)
        end
      end
      spacing = el.dig('tableStyle', 'cellSpacing')
      if body && PivotWidths.squeezed?(body) && ILLEGIBLE_SPACINGS.include?(spacing) &&
         (spacing != old.dig('tableStyle', 'cellSpacing') || widths_changed)
        errors << "pivot '#{id}': cellSpacing '#{spacing}' on a squeezed pivot (body #{body}px < #{PivotWidths::LEGIBLE_BODY_PX}) " \
                  "makes #{body}px cells illegible (live-proven); squeezed pivots keep 'extra-small' spacing"
      end
    end
    errors
  end

  def overflow_msg(id, detail, max_body)
    "pivot '#{id}': widths overflow the element cell (#{detail}); Sigma would discard ALL pivot widths " \
      "(48px default columns, clipped). The max body width that fits is #{max_body}. " \
      'Do not widen builder-emitted pivot widths.'
  end
end
