#!/usr/bin/env ruby
# frozen_string_literal: true
# layout-geometry-check.rb — informational check that the built Sigma layout keeps the SOURCE
# report's geometry.
#
#   ruby scripts/layout-geometry-check.rb --signals signals.json --spec workbook-spec.json \
#        [--layout layout.xml] [--out report.json]
#
# For each built visual it compares the Sigma grid box (from the spec's layout XML, normalized to the
# 24-column grid and the page's total rows; container-nested elements are resolved to absolute grid
# cells) with the source canvas box (signals x/y/w/h over page_w and the content height), and reports
# the IoU per visual. It also flags every visual whose relative order against another visual
# (left/right, above/below) is INVERTED in Sigma -- the symptom of grouped visuals piled at the
# top-left or a scrambled band layout.
#
# The clean layout deliberately re-bands, so a low IoU alone is not a defect; an inverted order is.
# Output: JSON on stdout (or --out) and a summary line on stderr. Exit status is always 0.
require 'json'
require 'optparse'
require 'rexml/document'
require 'digest'

GRID_COLS = 24.0
opts = {}
OptionParser.new do |p|
  p.on('--signals PATH') { |v| opts[:signals] = v }
  p.on('--spec PATH') { |v| opts[:spec] = v }
  p.on('--layout PATH', "layout XML (default: the spec's top-level `layout`)") { |v| opts[:layout] = v }
  p.on('--out PATH') { |v| opts[:out] = v }
end.parse!
abort('usage: layout-geometry-check.rb --signals signals.json --spec workbook-spec.json') unless opts[:signals] && opts[:spec]

def read_json(path)
  JSON.parse(File.read(path, encoding: 'UTF-8'))
end

# Same id the builder gives a visual's element (build-workbook-from-pbir.rb `short`).
def short_id(id)
  clean = id.to_s.gsub(/[^a-zA-Z0-9]/, '').downcase
  # Not a security use: a short deterministic id tag that must stay stable across runs.
  # nosemgrep: ruby.lang.security.weak-hashes-sha1.weak-hashes-sha1
  h = Digest::SHA1.hexdigest(id.to_s)[0, 6]
  "#{clean[-6, 6] || clean}#{h}"
end

def span(attr)
  attr.to_s.split('/').map { |x| x.strip.to_i }
end

# element id -> [c0, c1, r0, r1] ABSOLUTE grid lines (1-based, end-exclusive).
# A container's children use container-relative lines on the container's own 24-col grid.
def absolute_boxes(node, origin = [1, 25, 1, 1], out = {})
  node.elements.each do |el|
    next unless %w[Element Container].include?(el.name)
    c0, c1 = span(el.attributes['gridColumn'])
    r0, r1 = span(el.attributes['gridRow'])
    next if c0.to_i.zero? || r0.to_i.zero?
    w = (origin[1] - origin[0]) / GRID_COLS
    abs = [origin[0] + (c0 - 1) * w, origin[0] + (c1 - 1) * w, origin[2] + (r0 - 1), origin[2] + (r1 - 1)]
    out[el.attributes['elementId']] = abs
    absolute_boxes(el, abs, out) if el.name == 'Container'
  end
  out
end

def iou(a, b)
  ix = [[a[2], b[2]].min - [a[0], b[0]].max, 0].max
  iy = [[a[3], b[3]].min - [a[1], b[1]].max, 0].max
  inter = ix * iy
  union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
  union.positive? ? inter / union : 0.0
end

# boxes are [x0, y0, x1, y1]
def left_of?(a, b)
  a[2] <= b[0] + 1e-9
end

def above?(a, b)
  a[3] <= b[1] + 1e-9
end

signals = read_json(opts[:signals])
spec = read_json(opts[:spec])
layout_xml = if opts[:layout]
               File.read(opts[:layout], encoding: 'UTF-8')
             else
               (spec['layout'] || (spec['document'] || {})['layout']).to_s
             end
abort('no layout XML (pass --layout, or use a spec with `layout` / `document.layout`)') if layout_xml.strip.empty?
# A workbook layout is a run of sibling <Page> elements with no root element.
doc = REXML::Document.new("<Layout>#{layout_xml.sub(/\A\s*<\?xml[^>]*\?>/, '')}</Layout>")

pages = []
# Overlay pages (filters drawers) are laid out in a <Page> whose id is in document.overlays, not
# document.pages; they hold no source visuals, so they are never scored.
overlay_ids = Array((spec['document'] || spec)['overlays']).map { |o| o.is_a?(Hash) ? o['id'].to_s : nil }.compact
REXML::XPath.each(doc, '//Page') do |page|
  pid = page.attributes['id'].to_s
  next if overlay_ids.include?(pid)
  src = signals['pages'].find { |p| "page-#{p['page_id']}" == pid || p['page_id'] == pid }
  next unless src
  boxes = absolute_boxes(page)
  # leaf elements only: the containers are bands, not visuals
  leaf = boxes.reject { |id, _| REXML::XPath.first(page, "//Container[@elementId='#{id}']") }
  # A source-hidden visual (e.g. a slicer in a hidden pane, moved to a bottom band)
  # has no visible source box: it is not scored and does not count toward the height.
  visuals = src['visuals'].reject { |v| v['visual_type'].to_s == 'unknown' || v['hidden'] }
  built = []
  visuals.each do |v|
    base = "el-#{short_id(v['visual_id'])}"
    ids = leaf.keys.select { |k| k == base || k.start_with?("#{base}-k") }
    next if ids.empty?
    built << [v, ids]
  end
  scored = built.flat_map { |_, ids| ids }
  total_rows = [(scored.map { |i| leaf[i][3] }.max || boxes.values.map { |b| b[3] }.max).to_f - 1, 1].max
  content_h = ([src['page_h'].to_f] + built.map { |v, _| v['y'].to_f + v['h'].to_f }).max
  content_h = 720.0 if content_h <= 0
  pw = (src['page_w'] || 1280).to_f

  rows = built.map do |v, ids|
    gb = ids.map { |i| leaf[i] }
    sg = [gb.map { |b| b[0] }.min, gb.map { |b| b[2] }.min, gb.map { |b| b[1] }.max, gb.map { |b| b[3] }.max]
    sigma = [(sg[0] - 1) / GRID_COLS, (sg[1] - 1) / total_rows, (sg[2] - 1) / GRID_COLS, (sg[3] - 1) / total_rows]
    source = [v['x'].to_f / pw, v['y'].to_f / content_h, (v['x'].to_f + v['w'].to_f) / pw, (v['y'].to_f + v['h'].to_f) / content_h]
    { 'visual_id' => v['visual_id'], 'title' => v['title'], 'element_ids' => ids,
      'source_box' => source.map { |x| x.round(4) }, 'sigma_box' => sigma.map { |x| x.round(4) },
      'iou' => iou(source, sigma).round(4), 'order_inverted_with' => [], '_s' => source, '_g' => sigma }
  end
  rows.combination(2).each do |a, b|
    inv = (left_of?(a['_s'], b['_s']) && left_of?(b['_g'], a['_g'])) ||
          (left_of?(b['_s'], a['_s']) && left_of?(a['_g'], b['_g'])) ||
          (above?(a['_s'], b['_s']) && above?(b['_g'], a['_g'])) ||
          (above?(b['_s'], a['_s']) && above?(a['_g'], b['_g']))
    next unless inv
    a['order_inverted_with'] << b['visual_id']
    b['order_inverted_with'] << a['visual_id']
  end
  rows.each { |r| r.delete('_s'); r.delete('_g') }
  pages << { 'page_id' => src['page_id'], 'page_title' => src['page_title'], 'sigma_total_rows' => total_rows.to_i,
             'built_visuals' => rows.size, 'visuals' => rows,
             'mean_iou' => rows.empty? ? nil : (rows.sum { |r| r['iou'] } / rows.size).round(4),
             'inverted' => rows.select { |r| !r['order_inverted_with'].empty? }.map { |r| r['visual_id'] } }
end

report = { 'pages' => pages,
           'summary' => { 'pages' => pages.size, 'built_visuals' => pages.sum { |p| p['built_visuals'] },
                          'inverted_visuals' => pages.sum { |p| p['inverted'].size },
                          'mean_iou' => (pages.flat_map { |p| p['visuals'].map { |r| r['iou'] } }.then do |xs|
                            xs.empty? ? nil : (xs.sum / xs.size).round(4)
                          end) } }
json = JSON.pretty_generate(report)
opts[:out] ? File.write(opts[:out], json) : puts(json)
s = report['summary']
warn "[layout-geometry-check] #{s['built_visuals']} visual(s) on #{s['pages']} page(s): mean IoU #{s['mean_iou'].inspect}, " \
     "#{s['inverted_visuals']} with inverted left/right or above/below order (informational; exit 0)"
exit 0
