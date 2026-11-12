# frozen_string_literal: true
# export_viewport.rb — pick the headless-render viewport for sigma-export-png.py
# so tall dashboards are not clipped by its 1600x900 default.
#
#   w, h = ExportViewport.for(workdir: dir, page_id: nil)
#
# Sizing sources, in order:
#   1. the SOURCE dashboard PNG in the workdir (png-read.json `source_png`, else
#      visual-qa/*.source.png — tallest wins, else fidelity-ledger source_image);
#      IHDR width/height read without gems, at LOGICAL size (a resolution=high
#      2x capture is halved — see logical_dims).
#   2. the Sigma layout of the page in wb-spec.json: max gridRow end * 28 px
#      (SigmaLayout::SIGMA_ROW_PX) + chrome padding, width 1600.
#   3. 1600x900.
# Result is clamped to W 800..3200, H 600..6000.
require 'json'

module ExportViewport
  DEFAULT = [1600, 900].freeze
  W_RANGE = (800..3200).freeze
  H_RANGE = (600..6000).freeze
  ROW_PX = 28
  CHROME_PX = 120

  module_function

  def for(workdir:, page_id: nil)
    dims = source_png_dims(workdir, page_id) || layout_dims(workdir, page_id) || DEFAULT
    [dims[0].clamp(W_RANGE.min, W_RANGE.max), dims[1].clamp(H_RANGE.min, H_RANGE.max)]
  end

  # PNG IHDR: 8-byte signature, 4 len, 'IHDR', 4 width, 4 height (big-endian).
  def png_dims(path)
    head = File.binread(path, 24)
    return nil unless head && head.bytesize == 24 && head[0, 8] == "\x89PNG\r\n\x1a\n".b && head[12, 4] == 'IHDR'
    w, h = head[16, 8].unpack('NN')
    w.positive? && h.positive? ? [w, h] : nil
  rescue StandardError
    nil
  end

  def source_png_dims(workdir, page_id = nil)
    candidates = []
    named_source = nil
    if page_id
      ids = read_json(File.join(workdir, 'wb-ids.json'))
      ids = ids['document'] if ids.is_a?(Hash) && ids['document'].is_a?(Hash)
      page = Array(ids.is_a?(Hash) ? ids['pages'] : nil).find { |p| p.is_a?(Hash) && p['id'] == page_id }
      if page && !page['name'].to_s.empty?
        require_relative 'source_png'
        named_source = SourcePng.path(workdir, page['name']) || File.join(workdir, 'dashboards', "#{page['name']}.png")
      end
      candidates << named_source if named_source
    end
    pr = read_json(File.join(workdir, 'png-read.json'))
    sp = pr.is_a?(Hash) ? pr['source_png'] : nil
    candidates << File.expand_path(sp, workdir) if sp.is_a?(String) && !sp.empty?
    candidates.concat(Dir.glob(File.join(workdir, 'visual-qa', '*.source.png')).sort)
    led = read_json(File.join(workdir, 'fidelity-ledger.json'))
    si = led.is_a?(Hash) ? led['source_image'] : nil
    candidates << File.expand_path(si, workdir) if si.is_a?(String) && !si.empty?
    named_dims = logical_dims(named_source, workdir) if named_source && File.file?(named_source)
    return named_dims if named_dims
    dims = candidates.select { |p| File.file?(p) }.map { |p| logical_dims(p, workdir) }.compact
    dims.max_by { |_, h| h } # tallest source PNG (a multi-dashboard workdir clips otherwise)
  end

  # The source PNG's LOGICAL (CSS-pixel) size. Discovery fetches dashboard PNGs
  # at resolution=high — a 2x render (a 1400x900 canvas arrives 2800x1800) — and
  # sizing the render viewport from the raw header wasted the first RCF pass on
  # a viewport twice the dashboard. A PNG is halved only on evidence: its width
  # is ~2x (±10%) a dashboard's declared canvas width (dashboard-layout.json
  # canvas_px) and ~1x of none. No canvas on record → the header size is used.
  def logical_dims(path, workdir)
    d = png_dims(path)
    return nil unless d
    scale = png_scale(path, workdir, d[0])
    scale == 1 ? d : [(d[0] / scale.to_f).round, (d[1] / scale.to_f).round]
  end

  def png_scale(path, workdir, width)
    widths = canvas_widths(workdir, path)
    return 1 if widths.empty? || widths.any? { |w| (width.to_f / w - 1.0).abs <= 0.1 }
    widths.any? { |w| (width.to_f / w - 2.0).abs <= 0.1 } ? 2 : 1
  end

  def canvas_widths(workdir, path = nil)
    layout = read_json(File.join(workdir, 'dashboard-layout.json'))
    dashboards = Array(layout.is_a?(Array) ? layout : (layout.is_a?(Hash) ? layout['dashboards'] : nil))
    path_key = File.basename(path.to_s, '.png').downcase.gsub(/[^a-z0-9]/, '')
    matching = dashboards.select do |d|
      d.is_a?(Hash) && d['dashboard'].to_s.downcase.gsub(/[^a-z0-9]/, '') == path_key
    end
    dashboards = matching unless matching.empty?
    dashboards.map do |d|
      d.is_a?(Hash) ? d.dig('canvas_px', 'w').to_i : 0
    end.select(&:positive?).uniq
  end

  def layout_dims(workdir, page_id)
    spec = read_json(File.join(workdir, 'wb-spec.json'))
    return nil unless spec.is_a?(Hash)
    layout = spec['layout'] || spec.dig('contents', 'layout') || spec.dig('document', 'layout')
    return nil unless layout.is_a?(String)
    blocks = layout.scan(%r{<Page\b[^>]*\bid="([^"]*)"[^>]*>(.*?)</Page>}m).to_h
    body = page_id && blocks[page_id]
    bodies = body ? [body] : (blocks.empty? ? [layout] : blocks.values)
    rows = bodies.flat_map { |b| b.scan(/gridRow="\s*(\d+)\s*\/\s*(\d+)\s*"/).map { |_, e| e.to_i } }
    return nil if rows.empty?
    [DEFAULT[0], (rows.max - 1) * ROW_PX + CHROME_PX]
  end

  def read_json(path)
    JSON.parse(File.read(path))
  rescue StandardError
    nil
  end
end
