# frozen_string_literal: true

# layout_merge.rb — `--reuse-workbook` re-entry: keep the LIVE layout for every
# element it already places and place ONLY what is new.
#
# WHY: the first cut of layout preservation regenerated the WHOLE layout from
# the Tableau zones whenever the new spec added one element (a new control on
# an edit), reverting every RCF layout fix on every page (live proof: 19
# placements reverted for one added list control). Now the live layout is the
# base; each new element is inserted, in order of preference, where
#   1. a placement SOURCE (the new spec's own layout, then the zone-tree
#      layout) puts it, when that source's parent Page/Container exists live;
#   2. else, for a control / text / button, after the last element of the same
#      kind in the live container holding the most of that kind on its page
#      (the control rail);
#   3. else appended below the page's content, full width.
# Siblings that would overlap are pushed down, and a container that outgrows
# its row span grows (pushing its own later siblings) — no existing element
# changes columns or relative order. Ids the live layout places but the new
# spec dropped are pruned. Pure: XML strings in, XML string + ledger out.
require 'rexml/document'

module LayoutMerge
  module_function

  DEFAULT_HEIGHT = { 'control' => 3, 'text' => 2, 'button' => 3, 'kpi-chart' => 6 }.freeze
  INSERT_BY_KIND = %w[control text button].freeze
  CHROME_RE = /\A(?:(?:tc|syn|band)-|dv-)/.freeze

  # live_xml  — live layout XML (multiple root <Page> nodes)
  # new_ids   — element ids of the NEW spec
  # keep_ids  — ids that stay satisfiable though absent from new_ids (live chrome)
  # sources   — [xml, ...] placement sources, most authoritative first
  # kinds     — { element_id => kind } for the new spec
  # Returns { xml:, placed: [{ 'id', 'how', 'page', 'parent', 'gridRow', 'gridColumn' }], pruned: [ids] }
  # data_ids: elements that belong on the hidden Data page (masters / grouped
  # helpers another element reads as its source) — never inferred onto a
  # dashboard page.
  def merge(live_xml:, new_ids:, keep_ids: [], sources: [], kinds: {}, data_ids: [])
    @data_ids = Array(data_ids).map(&:to_s)
    doc = parse(live_xml)
    new_ids = Array(new_ids).map(&:to_s)
    keep = new_ids + Array(keep_ids).map(&:to_s)
    pruned = []
    doc.root.each_element('.//Element') do |el|
      id = el.attributes['elementId'].to_s
      pruned << id unless keep.include?(id)
    end
    pruned.each { |id| node_by_id(doc, id)&.then { |n| n.parent.delete_element(n) } }

    placed_ids = ids_in(doc)
    srcs = Array(sources).compact.reject { |s| s.to_s.strip.empty? }.map { |s| parse(s) rescue nil }.compact
    placed = []
    new_ids.each do |id|
      next if placed_ids.include?(id)
      next if id.empty?
      # containers and put-layout-injected chrome are structure, not tiles —
      # never inserted as a bare <Element>
      next if kinds[id].to_s == 'container' || id.match?(CHROME_RE)

      rec = place!(doc, id, srcs, kinds)
      next unless rec

      placed << rec
      placed_ids << id
    end
    { xml: serialize(doc), placed: placed, pruned: pruned }
  end

  # An authored workbook spec whose own layout leaves some elements unplaced
  # (an edit added a control and did not place it): place them INTO that
  # layout with the same rules (same-kind rail, else page bottom) so the spec
  # validates and the --reuse-workbook merge then sees an authored placement.
  # elements: [{ 'id', 'kind' }]. Returns { xml:, placed: } (xml nil when
  # nothing was unplaced or the layout is blank).
  def complete_layout(layout_xml, elements)
    return { xml: nil, placed: [] } if layout_xml.to_s.strip.empty?

    ids = Array(elements).map { |e| e['id'].to_s }.reject(&:empty?)
    kinds = Array(elements).each_with_object({}) { |e, h| h[e['id'].to_s] = e['kind'].to_s }
    placed_now = layout_xml.to_s.scan(/elementId="([^"]+)"/).flatten
    todo = ids.reject { |id| placed_now.include?(id) || kinds[id] == 'container' || id.match?(CHROME_RE) }
    return { xml: nil, placed: [] } if todo.empty?

    r = merge(live_xml: layout_xml, new_ids: ids, keep_ids: placed_now, sources: [], kinds: kinds,
              data_ids: data_element_ids(elements))
    { xml: r[:xml], placed: r[:placed] }
  end

  # Table elements another element reads as its source (or by [<Name>/...]
  # column refs): masters and grouped helpers — Data-page residents.
  def data_element_ids(elements)
    els = Array(elements).select { |e| e.is_a?(Hash) }
    names = els.each_with_object({}) { |e, h| h[e['name'].to_s] = e['id'].to_s if e['name'] }
    used = els.flat_map do |e|
      src = e.dig('source', 'elementId').to_s
      refs = Array(e['columns']).flat_map { |c| c['formula'].to_s.scan(%r{\[([^\]/]+)/}).flatten }.map { |n| names[n] }
      [src, *refs].compact
    end
    els.select { |e| e['kind'] == 'table' && used.include?(e['id'].to_s) }.map { |e| e['id'].to_s }
  end

  def data_page_of(doc)
    doc.root.elements.to_a.find { |p| p.name == 'Page' && data_page?(p) }
  end

  def place!(doc, id, srcs, kinds)
    kind = kinds[id].to_s
    # 1. a source places it under a parent that exists live
    srcs.each do |src|
      snode = node_by_id(src, id)
      next unless snode

      sparent = snode.parent
      live_parent = live_counterpart(doc, sparent)
      next unless live_parent

      r = span(snode.attributes['gridRow'])
      c = snode.attributes['gridColumn'].to_s
      insert!(live_parent, id, c, r)
      return ledger(id, 'source', live_parent, r, c)
    end
    # A helper another element reads as its source lives on the Data page,
    # appended below the masters (live re-proof: inferred onto a dashboard
    # page, the layout step reordered it after its consumer → forward-ref fail).
    if Array(@data_ids).include?(id) && (dp = data_page_of(doc))
      r0 = dp.elements.to_a.map { |n| span(n.attributes['gridRow'])[1] }.max || 1
      c = "1 / #{columns(dp) + 1}"
      insert!(dp, id, c, [r0, r0 + 10])
      return ledger(id, 'data-page', dp, [r0, r0 + 10], c)
    end
    # page the sources put it on (for the fallbacks)
    page = srcs.lazy.map { |s| node_by_id(s, id) }.reject(&:nil?).map { |n| page_of(n) }
               .map { |p| live_page(doc, p.attributes['id']) }.reject(&:nil?).first
    page ||= page_by_suffix(doc, id) || first_dashboard_page(doc)
    return nil unless page

    src_h = srcs.lazy.map { |s| node_by_id(s, id) }.reject(&:nil?).map { |n| span(n.attributes['gridRow']) }.first
    # 2. nearest container holding the same kind (the control rail)
    if INSERT_BY_KIND.include?(kind)
      host, last = same_kind_host(page, kind, kinds)
      if host && last
        h = src_h ? (src_h[1] - src_h[0]) : (span(last.attributes['gridRow'])[1] - span(last.attributes['gridRow'])[0])
        r0 = span(last.attributes['gridRow'])[1]
        c = last.attributes['gridColumn'].to_s
        insert!(host, id, c, [r0, r0 + h])
        return ledger(id, "after-last-#{kind}", host, [r0, r0 + h], c)
      end
    end
    # 3. append below the page's content, full width
    h = src_h ? (src_h[1] - src_h[0]) : (DEFAULT_HEIGHT[kind] || 15)
    r0 = page.elements.to_a.map { |n| span(n.attributes['gridRow'])[1] }.max || 1
    c = "1 / #{columns(page) + 1}"
    insert!(page, id, c, [r0, r0 + h])
    ledger(id, 'append-page', page, [r0, r0 + h], c)
  end

  # Insert an <Element> into parent at rows r=[start,end), pushing every
  # sibling that starts at/after the insertion row down when the new rect
  # collides with one, then growing ancestors that overflow.
  def insert!(parent, id, cols, r)
    el = REXML::Element.new('Element', nil, parent.context)
    el.add_attribute('elementId', id)
    el.add_attribute('gridColumn', cols)
    h = r[1] - r[0]
    start = r[0]
    loop do
      blocker = parent.elements.to_a.find do |s|
        sr = span(s.attributes['gridRow'])
        sr[0] < start && sr[1] > start && cols_overlap?(cols, s.attributes['gridColumn'])
      end
      break unless blocker

      start = span(blocker.attributes['gridRow'])[1]
    end
    collide = parent.elements.to_a.any? do |s|
      sr = span(s.attributes['gridRow'])
      sr[0] < start + h && sr[1] > start && cols_overlap?(cols, s.attributes['gridColumn'])
    end
    if collide
      parent.elements.to_a.each do |s|
        sr = span(s.attributes['gridRow'])
        s.attributes['gridRow'] = fmt(sr[0] + h, sr[1] + h) if sr[0] >= start
      end
    end
    el.add_attribute('gridRow', fmt(start, start + h))
    anchor = parent.elements.to_a.find { |s| span(s.attributes['gridRow'])[0] >= start + h }
    anchor ? parent.insert_before(anchor, el) : parent.add_element(el)
    grow!(parent)
  end

  # A Container whose children now run past its row span grows; its later
  # siblings move down by the same amount (recursively up to the Page).
  def grow!(node)
    return unless node.name == 'Container'

    cr = span(node.attributes['gridRow'])
    need = (node.elements.to_a.map { |n| span(n.attributes['gridRow'])[1] }.max || 1) - 1
    excess = need - (cr[1] - cr[0])
    return unless excess.positive?

    node.attributes['gridRow'] = fmt(cr[0], cr[1] + excess)
    node.parent.elements.to_a.each do |s|
      next if s.equal?(node)

      sr = span(s.attributes['gridRow'])
      s.attributes['gridRow'] = fmt(sr[0] + excess, sr[1] + excess) if sr[0] >= cr[1]
    end
    grow!(node.parent)
  end

  def same_kind_host(page, kind, kinds)
    best = nil
    page.each_element('.//Container') do |cont|
      same = cont.elements.to_a.select { |n| n.name == 'Element' && kinds[n.attributes['elementId'].to_s].to_s == kind }
      best = [cont, same] if same.any? && (best.nil? || same.size > best[1].size)
    end
    return [nil, nil] unless best

    [best[0], best[1].max_by { |n| span(n.attributes['gridRow'])[1] }]
  end

  def live_counterpart(doc, sparent)
    case sparent.name
    when 'Page' then live_page(doc, sparent.attributes['id'])
    when 'Container' then node_by_id(doc, sparent.attributes['elementId'].to_s, 'Container')
    end
  end

  def live_page(doc, page_id)
    doc.root.elements.to_a.find { |p| p.name == 'Page' && p.attributes['id'].to_s == page_id.to_s }
  end

  def page_of(node)
    n = node
    n = n.parent while n && n.respond_to?(:name) && n.name != 'Page'
    n
  end

  # Per-page converter ids share the page's slug suffix ("el-ctl-x-overview"
  # sits with "el-ctl-region-overview"): pick the page whose ids share the
  # longest hyphen-token suffix with the new id.
  def page_by_suffix(doc, id)
    toks = id.split('-')
    best = nil
    doc.root.elements.to_a.select { |p| p.name == 'Page' && !data_page?(p) }.each do |p|
      p.each_element('.//Element') do |el|
        ot = el.attributes['elementId'].to_s.split('-')
        n = 0
        n += 1 while n < [toks.size, ot.size].min - 1 && toks[-1 - n] == ot[-1 - n]
        best = [p, n] if n.positive? && (best.nil? || n > best[1])
      end
    end
    best && best[0]
  end

  def first_dashboard_page(doc)
    pages = doc.root.elements.to_a.select { |p| p.name == 'Page' }
    pages.find { |p| !data_page?(p) } || pages.first
  end

  # The converter's hidden Data page (masters + helpers) never receives a new
  # dashboard element by inference.
  def data_page?(page)
    page.attributes['id'].to_s.downcase.include?('data')
  end

  def node_by_id(doc, id, name = nil)
    found = nil
    doc.root.each_recursive do |n|
      next unless n.attributes['elementId'].to_s == id
      next if name && n.name != name

      found = n
      break
    end
    found
  end

  def ids_in(doc)
    out = []
    doc.root.each_recursive { |n| out << n.attributes['elementId'].to_s if %w[Element Container].include?(n.name) }
    out
  end

  def columns(page)
    page.attributes['gridTemplateColumns'].to_s[/repeat\((\d+)/, 1]&.to_i || 24
  end

  def cols_overlap?(a, b)
    x = span(a)
    y = span(b)
    x[0] < y[1] && y[0] < x[1]
  end

  def span(attr)
    m = attr.to_s.match(%r{(\d+)\s*/\s*(\d+)})
    m ? [m[1].to_i, m[2].to_i] : [1, 2]
  end

  def fmt(a, b)
    "#{a} / #{b}"
  end

  def ledger(id, how, parent, r, c)
    { 'id' => id, 'how' => how, 'page' => page_of(parent)&.attributes&.[]('id'),
      'parent' => parent.name == 'Page' ? parent.attributes['id'] : parent.attributes['elementId'],
      'gridRow' => fmt(*r), 'gridColumn' => c }
  end

  def parse(xml)
    body = xml.to_s.sub(/\A\s*<\?xml[^>]*\?>/, '')
    REXML::Document.new("<LayoutMergeRoot>#{body}</LayoutMergeRoot>", attribute_quote: :quote)
  end

  # Hand-rolled writer: keeps each node's attribute order as parsed and the
  # double-quoted, two-space-indented shape put-layout.rb and every
  # elementId="…" scanner expect.
  def serialize(doc)
    out = +%(<?xml version="1.0" encoding="utf-8"?>\n)
    doc.root.elements.each { |page| write_node(page, 0, out) }
    out
  end

  def write_node(node, depth, out)
    attrs = []
    node.attributes.each_attribute { |a| attrs << %( #{a.expanded_name}="#{esc(a.value)}") }
    pad = '  ' * depth
    kids = node.elements.to_a
    if kids.empty?
      out << "#{pad}<#{node.name}#{attrs.join}/>\n"
    else
      out << "#{pad}<#{node.name}#{attrs.join}>\n"
      kids.each { |k| write_node(k, depth + 1, out) }
      out << "#{pad}</#{node.name}>\n"
    end
  end

  def esc(v)
    v.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
  end
end
