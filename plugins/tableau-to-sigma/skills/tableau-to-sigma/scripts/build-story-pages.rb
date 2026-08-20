#!/usr/bin/env ruby
# Emit one Sigma PAGE per Tableau story point ([bead]).
#
# Tableau stories are sequential slide decks: each story point captures a
# dashboard or worksheet plus a navigator caption. Sigma has no story
# primitive; the verified translation is one Sigma page per story point, in
# story order, with:
#   - the page NAMED by the story-point caption (the slide's narrative)
#   - the story annotation (caption + "point i of n" navigation strip) as a
#     text element atop the page, wrapped in the dark header band
#   - the captured dashboard page's / worksheet's elements CLONED onto the
#     page (new ids; controls get suffixed controlIds with formula rewrites,
#     mirroring build-charts-from-signals.rb --page-per-worksheet)
#
# Two passes, mirroring the build-dashboard-layout.rb architecture:
#
# PASS 1 (spec): append the story pages to the pre-POST workbook spec.
#   ruby scripts/build-story-pages.rb \
#     --story-plan /tmp/<name>/story-plan.json \
#     --spec /tmp/<name>/wb-spec.json \
#     --out /tmp/<name>/wb-spec-with-story.json \
#     [--story "Story 1"]           # default: first story in the plan
#     [--replace-source-pages]      # drop the captured originals (story-only workbook)
#
# PASS 2 (layout, after post-and-readback.rb): banded layout per story page.
#   ruby scripts/build-story-pages.rb \
#     --story-plan /tmp/<name>/story-plan.json \
#     --wb-ids /tmp/<name>/wb-ids.json \
#     --layout-out /tmp/<name>/story-layout.xml
#   Writes story-layout.xml fragments (one <Page> per story page, annotation in
#   the header band, charts tiled 2-per-row) + story-layout.xml.elements.json
#   (container sidecar for put-layout.rb), covering ONLY the story pages —
#   merge with the workbook's existing page layouts before PUT.
#
# Sources stay shared: cloned charts keep their source.elementId (the Data-page
# master), so story pages add no extra warehouse queries beyond the charts
# themselves. Element-level filters are cloned per page, so per-point filter
# states diverge safely (a story page can later be filtered without touching
# the original dashboard page — see build-bookmark-workbooks.py for the
# state-per-workbook variant of the same idea).

require 'json'
require 'optparse'
require_relative 'lib/layout'
require_relative 'lib/workbook_code'
include SigmaLayout

opts = {}
OptionParser.new do |p|
  p.on('--story-plan PATH')        { |v| opts[:plan] = v }
  p.on('--spec PATH')              { |v| opts[:spec] = v }
  p.on('--out PATH')               { |v| opts[:out] = v }
  p.on('--wb-ids PATH')            { |v| opts[:wb_ids] = v }
  p.on('--layout-out PATH')        { |v| opts[:layout_out] = v }
  p.on('--story NAME')             { |v| opts[:story] = v }
  p.on('--replace-source-pages')   { opts[:replace] = true }
end.parse!
abort('missing --story-plan') unless opts[:plan]

stories = JSON.parse(File.read(opts[:plan]))
story = opts[:story] ? stories.find { |s| s['story'] == opts[:story] } : stories.first
abort("no story #{opts[:story] ? opts[:story].inspect : ''} in #{opts[:plan]}") unless story
points = story['points'] || []
abort('story has no points') if points.empty?

# Story-point captions become page names. Sigma page names should be short and
# unique — truncate and dedupe ("…", " (2)").
def page_name_for(point, idx, seen)
  base = (point['caption'].to_s.strip.empty? ? "Point #{idx + 1}" : point['caption'].strip)
  base = "#{base[0..57]}…" if base.length > 58
  name = base
  n = 2
  while seen.include?(name)
    name = "#{base} (#{n})"
    n += 1
  end
  seen << name
  name
end

def annotation_body(story_name, point, idx, total, points)
  prev_cap = idx.positive? ? points[idx - 1]['caption'] : nil
  next_cap = idx < total - 1 ? points[idx + 1]['caption'] : nil
  nav = ["Story point #{idx + 1} of #{total}"]
  nav << "◀ #{prev_cap}" if prev_cap
  nav << "#{next_cap} ▶" if next_cap
  caption = point['caption'].to_s.strip
  body = +"## <span style=\"color: #FFFFFF\">#{caption.empty? ? story_name : caption}</span>"
  body << "\n<span style=\"color: #CBD5E1\">#{story_name} — #{nav.join('  ·  ')}</span>"
  body
end

def rewrite_control_refs!(node, rewrites)
  case node
  when Hash
    node.each_value { |value| rewrite_control_refs!(value, rewrites) }
  when Array
    node.each { |value| rewrite_control_refs!(value, rewrites) }
  when String
    rewrites.each { |from, to| node.gsub!("[#{from}]", "[#{to}]") }
  end
  node
end

# ---- PASS 1: spec mode ------------------------------------------------------
if opts[:spec]
  abort('--spec mode needs --out') unless opts[:out]
  raw  = JSON.parse(File.read(opts[:spec]))
  spec = WorkbookCode.legacy_view(raw['workbook'].is_a?(Hash) ? raw['workbook'] : raw)
  pages = spec['pages'] || abort('spec has no pages[]')

  find_page = lambda do |name|
    pages.find { |pg| pg['name'].to_s.strip.casecmp(name.to_s.strip).zero? }
  end
  find_element = lambda do |name|
    pages.each do |pg|
      next if pg['id'] == 'page-data' || pg['name'] == 'Data'
      el = (pg['elements'] || []).find { |e| e['name'].to_s.strip.casecmp(name.to_s.strip).zero? }
      return el if el
    end
    nil
  end

  seen_names = pages.map { |pg| pg['name'] }.compact
  cloned_sources = []
  story_pages = []

  story_page_names = points.each_with_index.map { |point, index| page_name_for(point, index, seen_names) }
  story_page_ids = points.each_index.map { |index| "page-story-#{index + 1}" }

  points.each_with_index do |pt, i|
    prefix = "sp#{i + 1}"
    src_els = nil
    captured = pt['captured_sheet']
    if (src_page = captured && find_page.call(captured))
      src_els = src_page['elements'] || []
      cloned_sources << src_page['name']
    elsif (src_el = captured && find_element.call(captured))
      src_els = [src_el]
    end
    if src_els.nil?
      warn "WARN: story point #{i + 1} (#{pt['caption'].inspect}) captures " \
           "#{captured.inspect} — no matching page or element in the spec; " \
           'page emitted with the annotation only'
      src_els = []
    end

    # Clone with fresh ids. controlIds must be workbook-globally unique, and
    # any calc formula referencing a cloned control needs the suffixed ref —
    # same discipline as build-charts-from-signals.rb --page-per-worksheet.
    ctl_rewrites = {}
    clones = src_els.map do |el|
      dup = JSON.parse(el.to_json)
      old_id = dup['id']
      dup['id'] = "#{prefix}-#{old_id}"
      if dup['controlId']
        ctl_rewrites[dup['controlId']] = "#{dup['controlId']}-#{prefix}"
        dup['controlId'] = "#{dup['controlId']}-#{prefix}"
      end
      (dup['filters'] || []).each { |f| f['id'] = "#{prefix}-#{f['id']}" if f['id'] }
      dup
    end
    # Intra-page references: element-sourced controls / charts that pointed at
    # a sibling on the captured page must point at the sibling's clone.
    id_map = src_els.each_with_object({}) { |el, h| h[el['id']] = "#{prefix}-#{el['id']}" }
    remap = lambda do |node|
      case node
      when Hash
        node.each do |k, v|
          if %w[elementId sourceId targetElementId].include?(k) && id_map[v]
            node[k] = id_map[v]
          else
            remap.call(v)
          end
        end
      when Array then node.each { |v| remap.call(v) }
      end
    end
    clones.each do |el|
      remap.call(el)
      # Control handles can appear outside columns (dynamic text, filters,
      # actions, progress values, titles). Rewrite every serialized string, not
      # only columns[].formula, while leaving the controlId field itself intact.
      rewrite_control_refs!(el, ctl_rewrites)
    end

    annotation = {
      'id'   => "#{prefix}-story-annotation",
      'kind' => 'text',
      'body' => annotation_body(story['story'], pt, i, points.length, points)
    }
    navigation = {
      'id' => "#{prefix}-story-navigation",
      'kind' => 'navigation',
      'mode' => 'manual',
      'options' => story_page_names.each_with_index.map do |label, index|
        { 'label' => label,
          'destination' => { 'type' => 'page', 'pageId' => story_page_ids[index] } }
      end
    }
    story_pages << {
      'id'       => story_page_ids[i],
      'name'     => story_page_names[i],
      'elements' => [annotation, navigation] + clones
    }
  end

  if opts[:replace]
    pages.reject! { |pg| cloned_sources.include?(pg['name']) }
  end
  spec['pages'] = pages + story_pages
  File.write(opts[:out], JSON.pretty_generate(WorkbookCode.canonicalize(spec)))
  puts "wrote #{opts[:out]} (+#{story_pages.size} story page(s) for story #{story['story'].inspect}" \
       "#{opts[:replace] ? ", #{cloned_sources.uniq.size} source page(s) replaced" : ''})"
  story_pages.each_with_index do |pg, i|
    puts "  #{i + 1}. #{pg['name']}  (#{pg['elements'].size - 2} cloned element(s) + annotation + native navigation)"
  end
end

# ---- PASS 2: layout mode (post-readback) ------------------------------------
if opts[:wb_ids]
  abort('--wb-ids mode needs --layout-out') unless opts[:layout_out]
  wb_ids = WorkbookCode.legacy_view(JSON.parse(File.read(opts[:wb_ids])))
  seen = []
  wanted = points.each_with_index.map { |pt, i| page_name_for(pt, i, seen) }

  page_frags = []
  sidecar = {}
  wanted.each do |pname|
    pg = (wb_ids['pages'] || []).find { |p| p['name'] == pname }
    if pg.nil?
      warn "WARN: story page #{pname.inspect} not found in wb-ids — skipped (POST the PASS-1 spec first)"
      next
    end
    els = pg['elements'] || []
    annotation = els.find { |e| e['kind'] == 'text' }
    navigation = els.find { |e| e['kind'] == 'navigation' }
    charts = els.reject { |e| %w[text navigation container].include?(e['kind']) }
    # Tile charts 2-per-row, 9 rows tall; banded_page reflows under-filled
    # bands so a 1- or 3-chart point still fills the grid.
    items = []
    items << [navigation['id'], 1, 25, 1, 3] if navigation
    items.concat(charts.each_with_index.map do |e, j|
      c0 = j.even? ? 1 : 13
      c1 = j.even? ? 13 : 25
      r0 = 3 + (j / 2) * 9
      [e['id'], c0, c1, r0, r0 + 9]
    end)
    xml, extra = banded_page(pg['id'], items, header_el: annotation && annotation['id'],
                                              id_prefix: "story-#{pg['id']}")
    page_frags << xml
    sidecar[pg['id']] = extra
  end
  abort('no story pages matched wb-ids — nothing to lay out') if page_frags.empty?
  File.write(opts[:layout_out], assemble(*page_frags) + "\n")
  File.write("#{opts[:layout_out]}.elements.json", JSON.pretty_generate(sidecar))
  puts "wrote #{opts[:layout_out]} (#{page_frags.size} story page layout(s); merge with the " \
       'workbook layout before put-layout.rb)'
  puts "wrote #{opts[:layout_out]}.elements.json (container/header sidecar)"
end

abort('nothing to do: pass --spec/--out (pass 1) and/or --wb-ids/--layout-out (pass 2)') if !opts[:spec] && !opts[:wb_ids]
