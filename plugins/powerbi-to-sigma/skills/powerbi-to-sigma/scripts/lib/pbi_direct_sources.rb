# frozen_string_literal: true
#
# Workbook direct-source pass (opt-in `--direct-sources`, with the Power BI-shaped data model).
#
# Today every chart reads a "master" table on a hidden Data page and each master reads a data model element.
# With direct masters (lib/pbi_direct_map.rb: `direct: true`, every master column carries the data model
# formula), this pass inlines the masters AFTER the builder has assembled the pages:
#
#   * an element that read a direct master reads the data model element: source {kind:'data-model', ...}
#   * every `[<master id>/<column name>]` in an element becomes that master column's formula
#   * a control that filtered a master filters every element on its page that read it; an element lacking the
#     column gets a plain (off-axis) column carrying the slicer field's formula (probe P2). The value list is
#     the first target's own column (P3 fallback form), a single select default is `value` (P2b), and a boolean
#     slicer filters a text column (P12)
#   * page / report filters that sat on a master move onto each element that read it
#   * a control whose page has no element reading its master is NOT wired to anything else: it is dropped and
#     returned in `unreachable`
#   * helper data elements (scatter grouped sources) cannot be inlined: they read the data model element too,
#     but stay in `data_elements`, and only then does the builder keep a Data page.
#
# Pure Ruby 2.6, no I/O. The caller (build-workbook-from-pbir.rb) passes its own structures; they are mutated.
require 'json'
require_relative 'pbi_slicer_carry'

module PbiDirectSources
  module_function

  PLAIN = 'plain'
  BOOL_TEXT = 'bool-text'

  # I6: a control that is not targeted at an element (a date pick that does not apply, or no column reaching the control's
  # field) leaves that element out of the control's scope and lists it as excluded with the reason, so control-scope.json,
  # apply_slicers! `unreached` and limits.md say so. `out` is the inline! result; control_scope the builder's control-scope entries.
  def exclude_unreached!(control_scope, out)
    (Array(out['date_ignored']).map { |d| [d, false] } + Array(out['not_reached']).map { |d| [d, true] }).each do |d, nr|
      sc = control_scope.find { |c| c['controlId'] == d['controlId'] }
      next unless sc
      sc['scope'] = Array(sc['scope']) - [d['element']]
      sc['excluded'] = Array(sc['excluded'])
      entry = { 'element' => d['element'], 'reason' => d['reason'] }
      entry['not_reached'] = true if nr
      sc['excluded'] << entry unless sc['excluded'].any? { |x| x.is_a?(Hash) && x['element'] == d['element'] }
    end
    control_scope
  end

  # content_pages: [{'id','name','elements'=>[...]}]; data_elements: the builder's master + helper elements;
  # masters: the master-map `masters` (name => {id, direct, element_name, columns}); dm_id: fallback data model id.
  # Returns {'data_elements_left','sources_rewritten','filter_columns_added','controls_retargeted',
  #          'unreachable','refs_rewritten','unresolved_refs'}.
  # ignore_date: {element id => true} for the elements whose measures are all as-of metrics: Power BI ignores a Date-table
  # pick for them (C1), so a control or page/report filter on a master column of the date table (master['date_columns'])
  # is not targeted at them. Those (control, element) pairs are returned in 'date_ignored'.
  def inline!(content_pages, data_elements, masters, dm_id, ignore_date = {})
    direct_ids = masters.values.select { |m| m.is_a?(Hash) && m['direct'] == true && m['id'] }.map { |m| m['id'] }
    by_id = {}
    data_elements.each { |de| by_id[de['id']] = de if direct_ids.include?(de['id']) && direct_column_formulas?(de) }
    out = { 'data_elements_left' => [], 'sources_rewritten' => 0, 'filter_columns_added' => 0,
            'controls_retargeted' => 0, 'unreachable' => [], 'not_reached' => [], 'date_ignored' => [], 'refs_rewritten' => 0, 'unresolved_refs' => [] }
    if by_id.empty?
      out['data_elements_left'] = data_elements.map { |e| e['id'] }
      return out
    end
    helpers = data_elements.reject { |de| direct_ids.include?(de['id']) }
    date_cols = masters.values.select { |m| m.is_a?(Hash) && m['id'] }.each_with_object({}) { |m, h| h[m['id']] = Array(m['date_columns']) }
    date_col = ->(mid, mcol) { date_cols[mid].to_a.include?(mcol['name']) }
    added = {} # [element id, master column id, variant] => column id
    reader_master = lambda do |e|
      s = e['source']
      next nil unless s.is_a?(Hash) && s['kind'] == 'table' && by_id.key?(s['elementId'])
      s['elementId']
    end
    all_page_elements = content_pages.flat_map { |pg| pg['elements'] || [] }
    readers = (all_page_elements + helpers).reject { |e| e['kind'] == 'control' }.select { |e| reader_master.call(e) }

    # ---- controls: retarget every filter that targeted a direct master -------------------------------------
    content_pages.each do |pg|
      dropped = []
      pairs = page_readers(pg, by_id, helpers)
      (pg['elements'] || []).each do |ctl|
        next unless ctl['kind'] == 'control'
        filters = ctl['filters'].is_a?(Array) ? ctl['filters'] : []
        entries = filters.select { |f| f.dig('source', 'kind') == 'table' && by_id.key?(f.dig('source', 'elementId')) }
        src = ctl['source']
        src_mid = src.is_a?(Hash) && src['kind'] == 'source' && src.dig('source', 'kind') == 'table' ? src.dig('source', 'elementId') : nil
        src_mid = nil unless by_id.key?(src_mid)
        next if entries.empty? && src_mid.nil?
        variant = ctl['_boolean'] ? BOOL_TEXT : PLAIN
        new_filters = filters - entries
        seen = {}
        list_src = nil
        wire = lambda do |t, mcol, date = false|
          next if seen[t['id']]
          seen[t['id']] = true
          if date && ignore_date[t['id']]
            out['date_ignored'] << { 'control' => ctl['id'], 'controlId' => ctl['controlId'], 'element' => t['id'],
                                     'reason' => 'its measures are all as-of metrics: Power BI ignores a pick on the Date table for them' }
            next
          end
          cid = add_filter_column!(t, mcol, variant, added, out)
          new_filters << { 'source' => { 'kind' => 'table', 'elementId' => t['id'] }, 'columnId' => cid }
          list_src ||= { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => t['id'] }, 'columnId' => cid }
        end
        dims = entries.map { |f| [f.dig('source', 'elementId'), column_by_id(by_id[f.dig('source', 'elementId')], f['columnId'])] }
                      .select { |_m, c| c }
        # the control's own column on every element that reads the table it filtered
        dims.each { |mid, mcol| pairs.each { |t, tm| wire.call(t, mcol, date_col.call(mid, mcol)) if tm == mid } }
        # ... and on every other element whose table sees that column through relationships
        dims.each do |mid, mcol|
          pairs.each do |t, tm|
            next if tm == mid || seen[t['id']]
            rel = related_column(by_id[tm], mcol)
            if rel.is_a?(Hash)
              wire.call(t, rel, date_col.call(mid, mcol))
            else
              out['not_reached'] << { 'control' => ctl['id'], 'controlId' => ctl['controlId'], 'element' => t['id'], 'reason' => rel }
            end
          end
        end
        # a value list sourced from a master with no filter entry for it: its column on a reader of that master
        if src_mid && list_src.nil?
          scol = column_by_id(by_id[src_mid], src['columnId'])
          pairs.each { |t, tm| wire.call(t, scol, date_col.call(src_mid, scol)) if scol && tm == src_mid }
        end
        if new_filters.empty? || list_src.nil? && src_mid
          dropped << ctl
          out['unreachable'] << { 'control' => ctl['id'], 'controlId' => ctl['controlId'], 'name' => ctl['name'],
                                  'page' => pg['name'],
                                  'reason' => 'no element on this control\'s page reads the table it filtered; ' \
                                              'not wired to an unrelated element' }
          next
        end
        ctl['filters'] = new_filters
        ctl['source'] = list_src if src.is_a?(Hash) && list_src && src_mid
        shape_control!(ctl, variant)
        out['controls_retargeted'] += 1
      end
      pg['elements'] -= dropped unless dropped.empty?
    end

    # ---- page / report filters that sat on a master move onto its readers ----------------------------------
    by_id.each do |mid, de|
      next if Array(de['filters']).empty?
      readers.select { |e| reader_master.call(e) == mid }.each do |e|
        de['filters'].each do |f|
          mcol = column_by_id(de, f['columnId']) or next
          next if ignore_date[e['id']] && date_col.call(mid, mcol) # C1: as-of only: the Date filter is ignored in Power BI
          cid = add_filter_column!(e, mcol, PLAIN, added, out)
          (e['filters'] ||= []) << f.merge('columnId' => cid)
        end
      end
    end

    # ---- sources and master references --------------------------------------------------------------------
    reader_mid = readers.each_with_object({}) { |e, h| h[e['id']] = reader_master.call(e) }
    readers.each do |e|
      m = by_id[reader_mid[e['id']]]
      e['source'] = { 'kind' => 'data-model', 'dataModelId' => (m.dig('source', 'dataModelId') || dm_id),
                      'elementId' => m.dig('source', 'elementId') }
      out['sources_rewritten'] += 1
    end
    re = /\[(#{by_id.keys.map { |k| Regexp.escape(k) }.join('|')})\/([^\]]*)\]/
    (all_page_elements + helpers).each { |e| resolve_refs!(e, by_id, out, re) }
    inline_kpi_metrics!(readers.select { |e| e['kind'] == 'kpi-chart' }, reader_mid, masters, out)
    data_elements.reject! { |de| by_id.key?(de['id']) }
    out['data_elements_left'] = data_elements.map { |e| e['id'] }
    out
  end

  # R54: the page's ONE live element for slicers a summary table does not carry. A WORKBOOK Custom SQL element
  # named "<Summary> - live, filtered by your slicer picks": the summary's own SQL with one predicate per
  # uncarried slicer on the fact rows, before any window (PbiSlicerCarry.live_sql: one {{#formula
  # ArrayLength([Ctl])}} guard per control, no union, no default/filtered pair). The page's charts that read the
  # summary are repointed to it.
  #   page             {'id','name','elements'=>[...]} (mutated: the element is appended, readers repointed)
  #   summary_element  {'id','name','source'=>{'kind'=>'sql','connectionId','statement'}, 'columns'=>[{name,formula}]}
  #                    the summary as the data model holds it; columns read `[Custom SQL/<SQL name>]`
  #   controls         PbiSlicerCarry.live_sql slicer descriptors (control_id, column, path, typed, blank)
  # Readers are non-control elements whose source is the summary (data-model or table kind); their
  # `[<summary name>/Col]` and `[<summary id>/Col]` references become `[<live id>/Col]`. Returns the element
  # (the existing one when called twice). Raises ArgumentError when the page already has a live element for another
  # summary (v1: one per page) or the summary is not Custom SQL; PbiSlicerCarry::NoHook when its SQL has no hook.
  # The summary itself stays built only while `summary_still_read?` is true.
  def live_element!(page, summary_element, controls, dialect:, statement: nil)
    summary = summary_element
    src = summary['source']
    raise ArgumentError, "#{summary['name']} is not a Custom SQL summary" unless src.is_a?(Hash) && src['kind'] == 'sql' && src['statement']
    name = "#{summary['name']}#{PbiSlicerCarry::LIVE_SUFFIX}"
    elements = (page['elements'] ||= [])
    live = elements.select { |e| e['name'].to_s.end_with?(PbiSlicerCarry::LIVE_SUFFIX) }
    existing = live.find { |e| e['name'] == name }
    return existing if existing
    raise ArgumentError, "page #{page['name']} already has a live element (#{live[0]['name']}); one per page" unless live.empty?
    raise ArgumentError, 'no slicer controls to apply' if Array(controls).empty?
    # `statement:` is a ready live SQL (a page summary's, built by pbi-live-page-fact.py, one predicate per hook fact)
    statement ||= PbiSlicerCarry.live_sql(src['statement'], controls, dialect: dialect)
    id = "live-#{summary['id']}"
    cols = Array(summary['columns']).each_with_index.map do |c, i|
      sql_name = c['formula'].to_s[%r{\A\[Custom SQL/([^\]]+)\]\z}, 1] || c['name']
      col = { 'id' => "#{id}-c#{i}", 'name' => c['name'], 'formula' => "[Custom SQL/#{sql_name}]" }
      col['format'] = c['format'] if c['format']
      col['description'] = c['description'] if c['description']
      col
    end
    ctl_ids = Array(controls).map { |c| c['control_id'] }
    cols << { 'id' => "#{id}-slicers", 'name' => 'Slicer Filter Count', 'formula' => ctl_ids.map { |c| "ArrayLength([#{c}])" }.join(' + ') }
    el = { 'id' => id, 'kind' => 'table', 'name' => name,
           'description' => "Runs #{summary['name']}'s SQL with your picks on #{ctl_ids.join(', ')} applied to the underlying rows, " \
                            'before any window or ratio, so every number equals Power BI after the same picks. An empty pick means no ' \
                            'filter. It is not materialized, so it runs on each pick; the charts on this page read it instead of the summary.',
           'source' => { 'kind' => 'sql', 'connectionId' => src['connectionId'], 'statement' => statement },
           'columns' => cols }
    readers = elements.reject { |e| e['kind'] == 'control' }.select { |e| reads_summary?(e, summary) }
    re = %r{\[(?:#{Regexp.escape(summary['name'].to_s)}|#{Regexp.escape(summary['id'].to_s)})/([^\]]*)\]}
    readers.each do |e|
      e['source'] = { 'kind' => 'table', 'elementId' => id }
      rewrite_live_refs!(e, re, id)
    end
    elements << el
    el
  end

  def reads_summary?(el, summary)
    s = el['source']
    s.is_a?(Hash) && %w[data-model table].include?(s['kind']) && s['elementId'] == summary['id']
  end

  # True while any non-control element on any of `pages` still reads the summary.
  def summary_still_read?(pages, summary_element)
    Array(pages).any? { |pg| Array(pg['elements']).any? { |e| e['kind'] != 'control' && reads_summary?(e, summary_element) } }
  end

  def rewrite_live_refs!(node, re, id)
    case node
    when Hash
      node.each do |k, v|
        if v.is_a?(String)
          node[k] = v.gsub(re) { "[#{id}/#{Regexp.last_match(1)}]" } unless k == 'elementId' || k == 'id'
        else
          rewrite_live_refs!(v, re, id)
        end
      end
    when Array
      node.each_with_index do |v, i|
        if v.is_a?(String)
          node[i] = v.gsub(re) { "[#{id}/#{Regexp.last_match(1)}]" }
        else
          rewrite_live_refs!(v, re, id)
        end
      end
    end
  end

  # R53: a KPI value reads the metric's INLINE aggregate (a bare [Metrics/X] KPI value can render null; shared
  # preflight K1). Chained metrics expand recursively in parentheses; bare column refs are qualified to the
  # element. Charts and pivots keep [Metrics/X].
  def inline_kpi_metrics!(kpis, reader_mid, masters, out)
    info = masters.values.select { |m| m.is_a?(Hash) && m['id'] }.each_with_object({}) { |m, h| h[m['id']] = m }
    kpis.each do |k|
      m = info[reader_mid[k['id']]] or next
      vcol = Array(k['columns']).find { |c| c['id'] == k.dig('value', 'columnId') } or next
      metrics = Array(m['metrics']).each_with_object({}) { |x, h| h[x['name'].to_s] = x['formula'].to_s }
      whole_ref = vcol['formula'].to_s =~ /\A\[Metrics\/[^\]]+\]\z/
      vcol['formula'] = vcol['formula'].to_s.gsub(/\[Metrics\/([^\]]+)\]/) do
        whole = Regexp.last_match(0)
        nm = Regexp.last_match(1)
        if metrics.key?(nm)
          body = expand_metric(metrics[nm], metrics, m['element_name'], 0)
          whole_ref ? body : "(#{body})"
        else
          out['unresolved_refs'] << whole
          whole
        end
      end
    end
  end

  def expand_metric(formula, metrics, element, depth)
    formula.gsub(/\[([^\/\]]+)\]/) do
      ref = Regexp.last_match(1)
      if metrics.key?(ref) && depth < 16
        "(#{expand_metric(metrics[ref], metrics, element, depth + 1)})"
      else
        "[#{element}/#{ref}]"
      end
    end
  end

  def direct_column_formulas?(de)
    cols = Array(de['columns'])
    !cols.empty? && cols.all? { |c| c['formula'].to_s.start_with?('[') || c['formula'].to_s =~ /\A\w+\(/ }
  end

  def column_by_id(de, id)
    Array(de['columns']).find { |c| c['id'] == id }
  end

  # [element, master id] for every element on `page` that reads a direct master: the element itself, or the
  # helper element it reads when that helper reads the master.
  def page_readers(page, by_id, helpers)
    helper_ids = helpers.each_with_object({}) { |h, acc| acc[h['id']] = h }
    seen = {}
    (page['elements'] || []).each do |e|
      next if e['kind'] == 'control'
      s = e['source']
      next unless s.is_a?(Hash) && s['kind'] == 'table'
      sid = s['elementId']
      if by_id.key?(sid)
        seen[e['id']] = [e, sid]
      elsif (h = helper_ids[sid]) && h.dig('source', 'kind') == 'table' && by_id.key?(h.dig('source', 'elementId'))
        seen[h['id']] = [h, h.dig('source', 'elementId')]
      end
    end
    seen.values
  end

  # The column of master `de` that reaches the same data model column as `dcol` (a column of another master)
  # through relationships: its formula path ends in the other column's formula path. A column when exactly one
  # matches; otherwise a String reason (none / ambiguous) and the caller records it.
  def related_column(de, dcol)
    inner = dcol['formula'].to_s[/\A\[(.+)\]\z/, 1]
    return 'no formula' unless inner
    hits = Array(de['columns']).select do |c|
      f = c['formula'].to_s[/\A\[(.+)\]\z/, 1]
      f && f.end_with?("/#{inner}")
    end
    return "the element has no column reaching #{dcol['formula']}" if hits.empty?
    return "more than one column reaches #{dcol['formula']} (role-playing); not guessed" if hits.length > 1
    hits.first
  end

  def bool_text(formula)
    %(If(IsNull(#{formula}), Null, If(#{formula}, "True", "False")))
  end

  # Add (once per element/column/variant) the plain column carrying a master column's data model formula.
  def add_filter_column!(el, mcol, variant, added, out)
    key = [el['id'], mcol['id'], variant]
    return added[key] if added[key]
    cols = (el['columns'] ||= [])
    names = cols.map { |c| c['name'] }
    id = "#{el['id']}-sl-#{mcol['id']}#{variant == BOOL_TEXT ? '-t' : ''}"
    name = mcol['name'].to_s
    if names.include?(name)
      base = "#{name} (filter)"
      name = base
      n = 1
      name = "#{base} #{n += 1}" while names.include?(name)
    end
    formula = variant == BOOL_TEXT ? bool_text(mcol['formula']) : mcol['formula']
    col = { 'id' => id, 'formula' => formula, 'name' => name }
    col['hidden'] = true if el['kind'] == 'table'
    cols << col
    out['filter_columns_added'] += 1
    added[key] = id
  end

  # A single select default is `value` (singular); a boolean slicer's saved selection maps to the text values.
  def shape_control!(ctl, variant)
    if variant == BOOL_TEXT
      map = ->(v) { v == true ? 'True' : v == false ? 'False' : v }
      ctl['values'] = Array(ctl['values']).map(&map) if ctl.key?('values')
      ctl['value'] = map.call(ctl['value']) if ctl.key?('value')
    end
    if ctl['selectionMode'] == 'single'
      if ctl.key?('values')
        v = Array(ctl.delete('values')).first
        ctl['value'] = v unless v.nil? || ctl.key?('value')
      end
    end
    ctl.delete('_boolean')
  end

  # Replace `[<master id>/<column name>]` everywhere an element carries a string.
  def resolve_refs!(node, by_id, out, re)
    walk = lambda do |o|
      case o
      when Hash
        o.each do |k, v|
          if v.is_a?(String)
            next if k == 'elementId' || k == 'id'
            nv = rewrite(v, re, by_id, out)
            o[k] = nv
          else
            walk.call(v)
          end
        end
      when Array
        o.each_with_index do |v, i|
          if v.is_a?(String)
            o[i] = rewrite(v, re, by_id, out)
          else
            walk.call(v)
          end
        end
      end
    end
    walk.call(node)
  end

  def rewrite(str, re, by_id, out)
    str.gsub(re) do
      whole = Regexp.last_match(0)
      mid = Regexp.last_match(1)
      name = Regexp.last_match(2)
      col = Array(by_id[mid]['columns']).find { |c| c['name'] == name }
      if col && col['formula']
        out['refs_rewritten'] += 1
        f = col['formula'].to_s
        f =~ /\A\[[^\]]*\]\z/ ? f : "(#{f})"
      else
        out['unresolved_refs'] << "[#{mid}/#{name}]"
        whole
      end
    end
  end
end
