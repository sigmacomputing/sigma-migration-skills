#!/usr/bin/env ruby
# frozen_string_literal: true
#
# pbi-shaped-report.rb -- the map, the limits list and the views/pbi comparison of a Power BI migration run
# (Task 19 of the opt-in `--model-shape pbi` mode). REPORT ONLY: it reads its inputs and writes only into
# --out-dir (pbi-map.json, pbi-map.md, limits.md, and with --compare-dir comparison.json, comparison.md).
# It works on both shapes: the default (views) shape gets the map and the limits it can derive.
#
#   ruby scripts/pbi-shaped-report.rb --tmsl model.bim --signals signals.json --dm-spec dm-spec.json \
#        --wb-spec workbook-spec.json [--classes measure-classes.json] [--shaped-log pbi-shaped-model.json] \
#        [--slicer-carry slicer-carry.json] --out-dir DIR [--compare-dir OTHER_WORK]
#
# Shape detection: a dir is the pbi shape when it holds pbi-shaped-model.json (the current dir: or --shaped-log
# was passed). Pure Ruby 2.6; a missing optional input is recorded as null, never a failure.
require 'json'
require 'optparse'
require 'fileutils'
require 'digest'
require 'set'
require_relative 'lib/ruby_compat'
require_relative 'lib/pbi_measure_class'

module PbiShapedReport
  module_function

  BAND = [30, 40].freeze
  LIVE_TRADEOFF = 'computed in the warehouse on every slicer change instead of read from a summary'
  CALCULATE_MARK = "Power BI's CALCULATE filter on"

  # ---- reading -----------------------------------------------------------------------------

  def read_json(path)
    return nil unless path && File.file?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def norm(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  def short(id)
    clean = id.to_s.gsub(/[^a-zA-Z0-9]/, '').downcase
    "#{clean[-6, 6] || clean}#{Digest::SHA1.hexdigest(id.to_s)[0, 6]}"
  end

  def dm_elements(dm)
    return [] unless dm.is_a?(Hash)
    return Array(dm['elements']) if dm['elements'].is_a?(Array)
    Array(dm['pages']).flat_map { |p| Array(p['elements']) }
  end

  # The real workbook-spec.json is {name, document: {elements, layout, pages, ...}, folderId}; a bare
  # document (elements at the top) is read as it is.
  def wb_doc(wb)
    wb.is_a?(Hash) && wb['document'].is_a?(Hash) ? wb['document'] : wb
  end

  def wb_elements(wb)
    wb = wb_doc(wb)
    wb.is_a?(Hash) ? Array(wb['elements']) : []
  end

  def model_of(tmsl)
    tmsl.is_a?(Hash) ? (tmsl['model'] || tmsl) : {}
  end

  # ---- layout / pages ------------------------------------------------------------------------

  # {page id => [element ids]} from the layout XML (a regex scan: the layout is generated, not hand-written)
  def layout_pages(wb)
    wb = wb_doc(wb)
    xml = wb.is_a?(Hash) ? wb['layout'].to_s : ''
    out = {}
    xml.scan(%r{<Page\b([^>]*)>(.*?)</Page>}m) do |attrs, body|
      id = attrs[/\bid="([^"]*)"/, 1]
      next unless id
      out[id] = body.scan(/\belementId="([^"]+)"/).flatten
    end
    out
  end

  def page_of(wb, el_id)
    wb = wb_doc(wb)
    lp = layout_pages(wb)
    pid = lp.keys.find { |k| lp[k].include?(el_id) }
    page = Array(wb['pages']).find { |p| p['id'] == pid }
    page && page['name']
  end

  def hidden_or_unread(wb)
    wb = wb_doc(wb)
    lp = layout_pages(wb)
    hidden_pages = Array(wb['pages']).select { |p| p['visibility'] == 'hidden' }.map { |p| p['id'] }
    placed = lp.values.flatten.to_set
    hidden = hidden_pages.flat_map { |pid| lp[pid] || [] }.to_set
    ids = wb_elements(wb).map { |e| e['id'] }
    ids.count { |i| hidden.include?(i) || !placed.include?(i) }
  end

  # ---- clicks to source ----------------------------------------------------------------------

  KNOWN_STOP = %w[warehouse-table sql].freeze

  def first_input(src)
    return nil unless src.is_a?(Hash)
    return src if %w[table data-model warehouse-table sql].include?(src['kind'])
    cand = Array(src['sources'] || src['inputs']).first || src['primary'] || src['left'] || src['base'] || src['source']
    cand ||= src.values.find { |v| v.is_a?(Hash) && v['kind'] }
    cand.is_a?(Hash) && cand != src ? first_input(cand) : nil
  end

  def visual_elements(wb)
    els = wb_elements(wb)
    read = Set.new
    els.each do |e|
      s = e['source']
      read << s['elementId'] if s.is_a?(Hash) && s['kind'] == 'table' && s['elementId']
    end
    els.select do |e|
      s = e['source']
      e['kind'] != 'control' && s.is_a?(Hash) && %w[data-model table].include?(s['kind']) && !read.include?(e['id'])
    end
  end

  def clicks(el, wb_by, dm_by)
    n = 0
    src = el['source']
    ctx = :wb
    20.times do
      src = first_input(src)
      break if src.nil? || KNOWN_STOP.include?(src['kind'])
      if src['kind'] == 'data-model'
        n += 1
        tgt = dm_by[src['elementId']]
        ctx = :dm
        break unless tgt
        src = tgt['source']
      else # table
        n += 1
        tgt = (ctx == :wb ? wb_by : dm_by)[src['elementId']]
        break unless tgt
        src = tgt['source']
      end
    end
    n
  end

  def shape_facts(dm, wb)
    dels = dm_elements(dm)
    wb_by = {}
    wb_elements(wb).each { |e| wb_by[e['id']] = e }
    dm_by = {}
    dels.each { |e| dm_by[e['id']] = e }
    by_visual = {}
    visual_elements(wb).each { |e| by_visual[e['name'] || e['id']] = clicks(e, wb_by, dm_by) }
    vals = by_visual.values
    freq = Hash.new(0)
    vals.each { |v| freq[v] += 1 }
    mode = freq.keys.max_by { |v| [freq[v], v] }
    n = dels.length
    {
      'dm_elements' => n,
      'sql_elements' => dels.count { |e| (e['source'] || {})['kind'] == 'sql' },
      'band_target' => "#{BAND[0]}-#{BAND[1]}",
      'band' => n < BAND[0] ? 'below' : (n > BAND[1] ? 'above' : 'within'),
      'wb_elements' => wb_elements(wb).length,
      'hidden_or_unread' => hidden_or_unread(wb),
      'clicks_to_source' => mode,
      'clicks_to_source_max' => vals.max,
      'clicks_by_visual' => by_visual
    }
  end

  def read_timing(dir)
    read_json(File.join(dir, 'timings.json')) || read_json(File.join(dir, 'timing.json'))
  end

  def read_parity(dir)
    doc = read_json(File.join(dir, 'parity-final.json'))
    return nil if doc.nil? && !File.file?(File.join(dir, 'parity-final.json'))
    v = verdict(doc)
    v.nil? ? 'unknown' : v
  end

  def verdict(doc, depth = 0)
    return doc.upcase if doc.is_a?(String) && !doc.strip.empty? && depth.positive?
    return nil unless doc.is_a?(Hash) && depth < 3
    %w[overall verdict status result grade].each do |k|
      v = doc[k]
      return v.upcase if v.is_a?(String) && !v.strip.empty?
      r = v.is_a?(Hash) ? verdict(v, depth + 1) : nil
      return r if r
    end
    %w[pass passed ok success].each do |k|
      return(doc[k] ? 'PASS' : 'FAIL') if doc[k] == true || doc[k] == false
    end
    r = doc['summary'].is_a?(Hash) ? verdict(doc['summary'], depth + 1) : nil
    r
  end

  # ---- the map -------------------------------------------------------------------------------

  def item(pbi, el, kind, homes, reason)
    sigma = el ? { 'kind' => kind, 'name' => el['name'].to_s, 'id' => el['id'].to_s } : nil
    { 'pbi' => pbi, 'sigma' => sigma, 'homes' => homes, 'reason' => reason }
  end

  def elements_for_table(dels, table)
    t = norm(table)
    exact = dels.select { |e| norm(e['name']) == t }
    by_path = dels.select do |e|
      p = (e['source'] || {})['path']
      p.is_a?(Array) && norm(p.last) == t && !exact.include?(e)
    end
    split = dels.select { |e| norm(e['name']).start_with?(t) && !exact.include?(e) && e['name'].to_s =~ /\A#{Regexp.escape(table)}\s*\(/ }
    exact + by_path + split
  end

  def map_tables(tmsl, dels, log, scope_dropped = [])
    dropped = Array(((log || {})['dropped'] || {})['elements']).map(&:to_s)
    out_of_scope = Array(scope_dropped).map(&:to_s)
    Array(model_of(tmsl)['tables']).map do |t|
      hits = elements_for_table(dels, t['name'])
      if hits.empty?
        why = out_of_scope.any? { |d| norm(d) == norm(t['name']) } ? 'not used by the report: scoped out of the model (no visual, slicer or measure reads it)' : dropped.any? { |d| norm(d) == norm(t['name']) } ? 'dropped by the shaped model (the report does not use it)' : 'no data model element carries this table (not used by the report, or read through another element)'
        item(t['name'], nil, 'table', [], why)
      else
        item(t['name'], hits[0], 'table', hits.map { |h| h['name'] }, "carried as data model element '#{hits[0]['name']}'")
      end
    end
  end

  def keys_unverified?(log)
    log.is_a?(Hash) && Array(log['notes']).any? { |n| n.to_s.start_with?('key check skipped') }
  end

  def map_relationships(tmsl, dels, log, scope_dropped = [])
    out_of_scope = Array(scope_dropped).map { |d| norm(d) }
    by_id = {}
    dels.each { |e| by_id[e['id']] = e }
    relationship_log = ((log || {})['relationships'] || {})
    not_carried = Array(relationship_log['not_carried'])
    # which Sigma relationship carries each Power BI relationship, as the shaper decided it (by key columns)
    carried = relationship_log['carried']
    unverified = keys_unverified?(log)
    Array(model_of(tmsl)['relationships']).map do |r|
      label = "#{r['fromTable']} -> #{r['toTable']}#{r['name'] ? " (#{r['name']})" : ''}"
      flags = []
      flags << 'bidirectional' if r['crossFilteringBehavior'].to_s == 'bothDirections'
      flags << 'many-to-many' if r['fromCardinality'].to_s == 'many' && r['toCardinality'].to_s == 'many'
      flags << 'inactive' if r['isActive'] == false
      suffix = flags.empty? ? '' : " [#{flags.join(', ')}]"
      nc = not_carried.find { |n| n['relationship'].to_s == r['name'].to_s }
      cands = []
      elements_for_table(dels, r['fromTable']).each do |from_el|
        Array(from_el['relationships']).each do |rel|
          tgt = by_id[rel['targetElementId']]
          cands << [from_el, rel] if tgt && norm(tgt['name']) == norm(r['toTable'])
        end
      end
      if carried.is_a?(Array)
        # never by a guessed name: a uniquified " (2)", an occupant holding the plain name, or a numeric fromColumn
        # ("Date (2)") read alike. The shaper's element and final name first (names are unique on an element; a
        # split fact's "<Fact>" child carries copies of the relationships of its "<Fact> (source)" base), else its id.
        entry = carried.find { |c| c['relationship'].to_s == r['name'].to_s }
        found = entry && (cands.find { |el, rel| norm(el['name']) == norm(entry['element']) && norm(rel['name']) == norm(entry['name']) } ||
                          cands.find { |_el, rel| !entry['id'].to_s.empty? && rel['id'].to_s == entry['id'].to_s })
      else
        # no carried log (a views run, or an older log): the shaper's name for it, exactly
        expected_name = norm(r['isActive'] == false ? "#{r['toTable']} (#{r['fromColumn']})" : r['toTable'])
        found = cands.find { |_el, rel| norm(rel['name']) == expected_name }
      end
      if found
        rel = found[1]
        h = { 'pbi' => label + suffix, 'sigma' => { 'kind' => 'relationship', 'name' => rel['name'].to_s, 'id' => rel['id'].to_s },
              'homes' => ["#{found[0]['name']}.#{rel['name']}"],
              'reason' => "carried as a relationship on '#{found[0]['name']}'#{unverified ? ' (key uniqueness not verified: no key check ran)' : ''}" }
      else
        gone = [r['fromTable'], r['toTable']].find { |t| out_of_scope.include?(norm(t)) }
        why = gone ? "not carried: table '#{gone}' is scoped out of the model (the report does not use it)" : nc ? "not carried: #{nc['reason']}" : 'no matching relationship on the data model elements'
        h = { 'pbi' => label + suffix, 'sigma' => nil, 'homes' => [], 'reason' => why }
      end
      h
    end
  end

  # Where a measure lives in the data model: every element holding a metric (else a column) of that name.
  # A page summary names its columns for what they hold ("YTD at Month"), not for the measure; its column descriptions
  # say which measures a column feeds: "Feeds <measure>[ and <measure>][: ...| with ...]". A column home by name wins; the description
  # is the fallback (Task 21b).
  def feeds?(description, name)
    text = description.to_s
    text =~ /\AFeeds (.*?)(?::| with |\z)/m ? $1.split(/,\s*|\s+and\s+(?=\S)/).map(&:strip).any? { |m| m.casecmp(name.to_s).zero? } : false
  end

  def measure_column_rank(column, name)
    desc = column['description'].to_s
    ref = /[^\[]+\[#{Regexp.escape(name.to_s)}\]/
    return 0 if column['name'].to_s.casecmp(name.to_s).zero? && desc =~ /\APower BI measure #{ref}\.\z/
    return 1 if column['name'].to_s.casecmp(name.to_s).zero? && desc !~ /, read by /
    return 2 if desc =~ /\A(?:Numerator|Denominator) of Power BI measure #{ref}(?:[ .(]|\z)/
    return 3 if feeds?(desc, name)
    return 4 if column['name'].to_s.casecmp(name.to_s).zero?
    nil
  end

  def measure_homes(dels, name)
    metric = []
    column = []
    dels.each_with_index do |e, i|
      m = Array(e['metrics']).find { |x| x['name'].to_s.casecmp(name.to_s).zero? }
      metric << [e, m] if m
      ranked = Array(e['columns']).each_with_object([]) do |c, out|
        rank = measure_column_rank(c, name)
        out << [rank, c] if rank
      end
      rank, c = ranked.min_by(&:first)
      column << [e, c, rank, i] if c
    end
    [metric, column.sort_by { |x| [x[2], x[3]] }.map { |x| x[0, 2] }]
  end

  def map_measures(tmsl, signals, dels, classes)
    vis = PbiMeasureClass.visible_measures(signals, tmsl)
    vis.map do |m|
      key = "#{m['table']}.#{m['measure']}"
      cls = (classes || {})[key]
      metric, column = measure_homes(dels, m['measure'])
      cnote = cls ? "class #{cls['class']} (#{cls['reason']})" : nil
      if !metric.empty?
        e, mm = metric[0]
        reason = "data model metric '#{mm['name']}' on '#{e['name']}'"
        reason = "#{cnote}: #{reason}" if cnote
        { 'pbi' => key, 'sigma' => { 'kind' => 'metric', 'name' => mm['name'].to_s, 'id' => mm['id'].to_s },
          'homes' => metric.map { |x| x[0]['name'].to_s }, 'reason' => reason }
      elsif !column.empty?
        e, c = column[0]
        { 'pbi' => key, 'sigma' => { 'kind' => 'column', 'name' => c['name'].to_s, 'id' => c['id'].to_s },
          'homes' => column.map { |x| x[0]['name'].to_s }, 'reason' => "#{cnote ? cnote + ': ' : ''}built as column '#{c['name']}' on '#{e['name']}'" }
      else
        { 'pbi' => key, 'sigma' => nil, 'homes' => [],
          'reason' => "#{cnote ? cnote + ': ' : ''}no data model metric or column of that name; the measure is not carried" }
      end
    end
  end

  def find_wb_element(wb, vid, title, control)
    els = wb_elements(wb)
    sid = "el-#{short(vid)}"
    hit = els.find { |e| e['id'] == sid } || els.find { |e| e['id'].to_s.start_with?(sid) && (e['kind'] == 'control') == control }
    hit ||= els.find { |e| (e['kind'] == 'control') == control && !title.to_s.empty? && e['name'].to_s == title.to_s }
    hit
  end

  def read_dm_name(el, dm_by)
    s = el['source'].is_a?(Hash) ? el['source'] : {}
    s = s['source'] if s['kind'] == 'source' && s['source'].is_a?(Hash)
    t = s['elementId'] && dm_by[s['elementId']]
    t ? t['name'].to_s : nil
  end

  def visual_title(v)
    (v['title'].to_s.empty? ? v['visual_id'].to_s : v['title'].to_s)
  end

  def map_visuals(signals, wb, dels, coverage)
    dm_by = {}
    dels.each { |e| dm_by[e['id']] = e }
    unresolved = Array((coverage || {})['unresolved'])
    out = []
    Array((signals || {})['pages']).each do |pg|
      next if pg['hidden']
      Array(pg['visuals']).each do |v|
        next if v['hidden'] || v['sigma_kind'].to_s == 'control' || v['visual_type'].to_s == 'slicer'
        label = "#{pg['page_title']}: #{visual_title(v)}"
        el = find_wb_element(wb, v['visual_id'], v['title'], false)
        cov = unresolved.select { |u| u['visual_id'] == v['visual_id'] }
        if el
          page = page_of(wb, el['id'])
          src = read_dm_name(el, dm_by)
          reason = "built as #{el['kind']}#{page ? " on page '#{page}'" : ''}#{src ? ", reading '#{src}'" : ''}"
          cov.each { |u| reason += "; #{u['severity']}: #{u['detail']}" }
          out << item(label, el, el['kind'].to_s, [src, page].compact, reason)
        else
          reason = cov.empty? ? 'no workbook element was built for this visual' : cov.map { |u| "#{u['severity']}: #{u['detail']}" }.join('; ')
          out << item(label, nil, 'element', [], reason)
        end
      end
    end
    out
  end

  def map_slicers(signals, wb, scope, log)
    controls = Array((scope || {})['controls'])
    unbound = Array((scope || {})['unbound'])
    sl = (log || {})['slicers'] || {}
    out = []
    Array((signals || {})['pages']).each do |pg|
      next if pg['hidden']
      Array(pg['visuals']).each do |v|
        next if v['hidden'] || !(v['sigma_kind'].to_s == 'control' || v['visual_type'].to_s == 'slicer')
        label = "#{pg['page_title']}: #{visual_title(v)}"
        el = find_wb_element(wb, v['visual_id'], v['title'], true)
        if el
          sc = controls.find { |c| c['controlId'] == el['controlId'] }
          wired = sc ? Array(sc['wiredMasters']) : []
          reason = sc ? "control #{sc['status'] || 'wired'}#{wired.empty? ? '' : " to #{wired.length} element(s)"}" : "control '#{el['name']}'"
          na = Array(sl['not_applied']).find { |n| n['page'].to_s == pg['page_title'].to_s && [el['controlId'].to_s, el['id'].to_s, visual_title(v)].include?(n['control'].to_s) }
          reason += "; not applied: #{na['reason']}" if na
          unf = Array((((log || {})['filters']) || {})['dimension_unfiltered']).select do |u|
            Array(v['bindings']).flat_map { |_k, refs| Array(refs) }.any? { |ref| norm(ref.to_s.split('.', 2)[0]) == norm(u['element']) }
          end
          unf.each do |u|
            reason += "; the report filter #{u['filter']} is not applied to #{u['element']} itself, so this slicer still lists the excluded members"
          end
          out << item(label, el, 'control', wired.map(&:to_s), reason)
        else
          ub = unbound.find { |u| u['sourceName'].to_s.include?(v['visual_id'].to_s) }
          out << item(label, nil, 'control', [], ub ? ub['reason'].to_s : 'no control was built for this slicer')
        end
      end
    end
    out
  end

  # ---- limits.md -----------------------------------------------------------------------------

  def upper_snake(name)
    s = name.to_s.gsub(/[^\x00-\x7F]/, '').gsub(/([a-z0-9])([A-Z])/, '\1_\2').gsub(/[^A-Za-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').upcase
    s.empty? ? 'VIEW' : s
  end

  def create_views(dels)
    dels.select { |e| (e['source'] || {})['kind'] == 'sql' }.map do |e|
      stmt = e['source']['statement'].to_s.strip.sub(/;+\s*\z/, '').rstrip
      last = stmt.lines.last.to_s
      sep = last.include?('--') ? "\n" : ''
      "CREATE OR REPLACE VIEW <TARGET_SCHEMA>.#{upper_snake(e['name'])} AS\n#{stmt}#{sep};"
    end
  end

  def relationship_limits(tmsl)
    Array(model_of(tmsl)['relationships']).map do |r|
      bidi = r['crossFilteringBehavior'].to_s == 'bothDirections'
      m2m = r['fromCardinality'].to_s == 'many' && r['toCardinality'].to_s == 'many'
      next nil unless bidi || m2m
      kinds = []
      kinds << 'bidirectional' if bidi
      kinds << 'many-to-many' if m2m
      "- #{r['fromTable']}.#{r['fromColumn']} -> #{r['toTable']}.#{r['toColumn']}#{r['name'] ? " (#{r['name']})" : ''}: #{kinds.join(' and ')}. " \
        'A Sigma relationship filters one way and is one-to-many; check the numbers a slicer on either table drives.'
    end.compact
  end

  def build_limits(tmsl, dels, classes, log, scope, carry, wb = nil, flip = nil, coverage = nil)
    ctl_name = lambda do |id|
      el = wb_elements(wb).find { |e| e['kind'] == 'control' && [e['controlId'].to_s, e['id'].to_s].include?(id.to_s) }
      el && !el['name'].to_s.empty? ? el['name'].to_s : id
    end
    sections = []
    sec = lambda do |title, lines, always = false|
      sections << "## #{title}\n\n#{lines.join("\n")}\n" if always || !lines.empty?
    end

    # 1. class D
    d_keys = (classes || {}).select { |_k, c| c['class'] == 'D' }.keys
    d_keys = Array((((log || {})['direct_map']) || {})['class_d_fields']) if d_keys.empty?
    d_lines = d_keys.map do |k|
      _t, mname = k.split('.', 2)
      metric, column = measure_homes(dels, mname.to_s)
      homes = (metric + column).map { |x| x[0]['name'].to_s }.uniq
      c = (classes || {})[k]
      "- #{k}#{c ? " (#{c['reason']})" : ''}: lands in #{homes.empty? ? 'no summary (not carried)' : "summary '#{homes.join("', '")}'"}"
    end
    # visual-level class D (Task 21x): the visual needs two relationship paths to one table; held back unless a page summary carries it
    d_vis = Array((((log || {})['direct_map']) || {})['class_d_visuals'])
    # still held back only while coverage.json records it dropped (--page-facts builds it on a page summary)
    if coverage.is_a?(Hash)
      held = Array(coverage['unresolved']).select { |u| u['severity'].to_s == 'dropped' && u['detail'].to_s.include?('held back') }.map { |u| u['visual'].to_s }
      d_vis = d_vis.select { |dv| held.include?(dv['visual'].to_s) }
    end
    d_lines += d_vis.map do |dv|
      "- Visual '#{dv['visual']}' on page '#{dv['page']}': #{dv['reason']}. Held back (no chart built) unless a page summary carries it " \
        '(--scaffold-page-facts, then --page-facts).'
    end
    sec.call(d_vis.empty? ? 'Class D measures' : 'Class D measures and visuals', d_lines)

    # 2. measures on summaries (a metric that lives on an element other than its Power BI table's)
    on_summary = []
    ((classes || {}).keys).each do |k|
      next if classes[k]['class'] == 'D' # listed in section 1
      t, mname = k.split('.', 2)
      home_table = (classes[k]['home'] || t).to_s
      metric, _col = measure_homes(dels, mname.to_s)
      at_home = elements_for_table(dels, home_table)
      away = metric.map { |x| x[0] }.reject { |e| at_home.include?(e) }
      on_summary << "- #{k}: lives on summary '#{away.map { |e| e['name'] }.uniq.join("', '")}'" unless away.empty?
    end
    sec.call('Measures on summaries', on_summary)

    # 3. relationships
    rl = relationship_limits(tmsl)
    sec.call('Bidirectional and many-to-many relationships', rl.empty? ? ['None in this model.'] : rl, true)

    # 4. live pages
    live = Array((((log || {})['slicers']) || {})['live'])
    sec.call('Live pages', live.map do |l|
      fields = Array(l['controls']).map { |c| c.is_a?(Hash) ? c['field'] : c }.compact.join(', ')
      "- Element '#{l['element']}' on page '#{l['page']}', controls: #{fields.empty? ? 'none recorded' : fields}. " \
        "Trade-off: #{LIVE_TRADEOFF}."
    end)

    # 5. physical names
    sec.call('Physical names shown', Array((log || {})['element_name_resets']).map do |r|
      "- '#{r['from']}' shows physical name '#{r['to']}' (the connection does not use friendly names)"
    end)

    # 6. CALCULATE overrides
    calc = []
    dels.each do |e|
      Array(e['metrics']).each do |m|
        next unless m['description'].to_s.include?(CALCULATE_MARK)
        calc << "- #{e['name']}.#{m['name']}: #{m['description']}. In Power BI that filter overrides slicers on the column; in Sigma a slicer still applies, " \
                 "so a visual that binds the filtered column on an axis, or sits under a slicer, page, report or visual filter on it, is class D (held back)."
      end
    end
    sec.call('CALCULATE-override measures', calc)

    # 7. slicers not applied / unreached
    sl = (log || {})['slicers'] || {}
    sl_lines = []
    Array(sl['not_applied']).each do |n|
      what = n['control'] ? ctl_name.call(n['control']) : n['summary']
      sl_lines << "- Not applied: #{what} on page '#{n['page']}'#{n['field'] ? " (#{n['field']})" : ''}: #{n['reason']}"
    end
    # one line per control: the distinct reading elements, and the reasons, each listed once
    groups = {}
    Array(sl['unreached']).each do |u|
      g = (groups[u['control'].to_s] ||= { 'sources' => [], 'elements' => [], 'reasons' => [] })
      g['sources'] << u['source']
      g['elements'] << u['element']
      g['reasons'] << u['reason']
    end
    groups.each do |ctl, g|
      els = g['elements'].compact.uniq
      sl_lines << "- Unreached: #{ctl_name.call(ctl)} (#{g['sources'].compact.uniq.join('; ')})" \
        "#{els.empty? ? '' : "; not applied to: #{els.join(', ')}"}: #{g['reasons'].compact.uniq.join(' | ')}"
    end
    if log.nil?
      Array((scope || {})['unbound']).each { |u| sl_lines << "- Unreached: #{u['sourceName']}: #{u['reason']}" }
    end
    sec.call('Slicers not applied, and unreached slicers', sl_lines)

    # 7b. report filters kept off a dimension element (pbi shape): a fact visual is filtered, a read of the dimension alone is not
    unf = Array((((log || {})['filters']) || {})['dimension_unfiltered'])
    sec.call('Report filters', unf.map do |u|
      tbl = u['element'].to_s
      expr = u['filter'].to_s.sub(/\A#{Regexp.escape(tbl)}\./, '')
      "- #{tbl} filter #{expr} applies to fact visuals; slicer value lists and dimension-only visuals on #{tbl} still show the excluded members " \
        "(a Lookup() into a filtered element returns NULL for the excluded keys instead of dropping the fact rows, so the filter stays on the facts)."
    end)

    # 7c. controls the runtime flip test could not prove (pbi shape; read from probe-controls/probe-results.json)
    if log
      unproven = Array(flip).select { |r| r.is_a?(Hash) && r['result'].to_s == 'SKIP' && r['control'] }
      sec.call('Controls the flip test could not verify', unproven.map do |r|
        "- #{ctl_name.call(r['control'])}: UNVERIFIED (the runtime control-flip proof skipped it): #{r['note']}. " \
          'Flip it by hand, or rerun probe-controls.rb with --value <controlId>=<value>.'
      end)
    end

    # 7d. time-axis density (pbi shape): a fact whose Date table has periods with no fact rows cannot be a grouped element
    td = ((log || {})['time_density'] || {})['facts'] || {}
    td_lines = []
    td.each do |fact, grains|
      grains.each do |grain, r|
        if r['verified'] == false
          td_lines << "- #{fact} at #{grain} grain: time-axis density not verified (#{r['reason']}). If the Date table has #{grain}s with no #{fact} rows " \
                      "(trailing periods or gaps), the grouped element misses those chart points and a no-axis prior-period read undercounts."
        elsif r['sparse']
          td_lines << "- #{fact} at #{grain} grain: sparse (#{r['present']} of #{r['expected']} Date-table #{grain}s have #{fact} rows). Its grouped time-intelligence " \
                      "measures are class D (held back, listed above): Power BI shows every Date-table period, which needs a page summary over the Date table."
        end
      end
    end
    sec.call('Time-axis density', td_lines)

    # 7e. what a run could not verify or held back by rule (final review I7, Fix A, m4)
    ti = Array((log || {})['time_intel'])
    cls_entries = (classes || {})
    key_lines = []
    if log
      skipped = Array(log['notes']).select { |n| n.to_s.start_with?('key check skipped') }
      unless skipped.empty?
        carried = Array(model_of(tmsl)['relationships']).size - Array((log['relationships'] || {})['not_carried']).size
        key_lines << "- #{[carried, 0].max} relationship(s) unverified: #{skipped.join('; ')}. Every relationship was kept without a uniqueness check, " \
                     'so a duplicated or many-to-many target key fans the Lookup and relationship joins out, and the rolling carry joins too. ' \
                     'Rerun with --probe-sources (or --shape-probe-results) to verify them.'
      end
      Array(log['waivers']).each do |w|
        next unless w['flag'] == '--allow-unverified-keys'
        key_lines << "- #{Array(w['relationships']).join(', ')}: kept unverified (--allow-unverified-keys); the key check returned no result for them."
      end
    end
    sec.call('Key check not run', key_lines)

    if log
      asof = ti.select { |r| r['form'] == 'metric' }.map { |r| r['measure'] }
      ignore = Array((log['direct_map'] || {})['asof_ignore_date'])
      as_lines = asof.empty? ? [] : ["- #{asof.join(', ')}: as-of measure(s). Power BI holds an as-of measure flat across the Date table (its CALCULATE filter replaces the Date filter), " \
                                      'so a visual that binds one with a Date-table field, mixes it under a date control, or sits under a report or visual Date filter is class D (held back).']
      ignore.each do |i|
        as_lines << "- Visual '#{i['visual']}' on page '#{i['page']}': every measure is as-of, so a page Date slicer or page filter pick is not applied to it, as in Power BI " \
                    '(listed as excluded in the control scope).'
      end
      sec.call('As-of measures', as_lines)

      roll_lines = ti.select { |r| r['form'] == 'rolling_sql' }.map do |r|
        flt = Array(r['report_filters'])
        "- #{r['element']}: #{flt.empty? ? 'no report filter applies' : "report filter(s) applied inside the window SQL: #{flt.join('; ')}"}."
      end
      unless roll_lines.empty?
        roll_lines << '- A list report filter on a non-date table is written into the rolling SQL; a Date-table report filter is replaced inside the window by Power BI and not applied. ' \
                      "A filter that cannot be written exactly (a blank member, a backslash or control character in a value, a composite or non-physical key) sends the fact's rolling measures to class D. " \
                      'A page filter reaches a rolling element only on a field the element carries, else its readers are class D. An empty window reads blank, as in DAX.'
      end
      sec.call('Rolling windows and report filters', roll_lines)

      date_lines = ti.empty? ? [] : ['- Only provable calendar fields bind to a time-intelligence element: the Date or Day column, a calculated column that is DATE(YEAR(...), MONTH(...), 1) or STARTOF*(...) of it, ' \
                                     'and integer Year, Quarter and Month Number columns (carried as Year Number, Quarter Number and Month Number on the grouped elements). ' \
                                     'A fiscal, week, name, key or physical Month Start field gets no binding: a visual that binds one beside a time-intelligence measure is class D, ' \
                                     'and so is an integer Quarter or Month Number with no Year beside it.']
      sec.call('Date fields', date_lines)

      userel = cls_entries.select { |_k, c| c['class'] != 'D' && c['reason'].to_s =~ /inactive relationship|USERELATIONSHIP/i }.keys
      sec.call('USERELATIONSHIP measures', userel.empty? ? [] : ["- #{userel.join(', ')}: the role-playing Date path is activated per visual. Slicers, page filters and report filters on the Date table follow that path; " \
                                                                   'a control that also reaches an active-path visual on the page, or any report-level Date filter, holds the USERELATIONSHIP visuals back (class D).'])

      form_lines = cls_entries.select { |_k, c| c['class'] == 'D' && c['reason'].to_s =~ /DATESBETWEEN|day-grain/i }.map do |k, c|
        rule = c['reason'].to_s =~ /day-grain/i ? 'a prior-period read at day grain is not probed' :
                                                    'a DATESBETWEEN rolling window is built only as MAX(<date column>) - N .. MAX(<date column>) over one column'
        "- #{k}: #{c['reason']}. Rule: #{rule}; the measure is class D."
      end
      sec.call('Time-intelligence forms held back', form_lines)

      blank = Array(log['blank_arith']).map { |x| x.is_a?(Hash) ? "#{x['element']}.#{x['metric']}" : x.to_s }.uniq
      sec.call('Blank-as-zero arithmetic', blank.empty? ? [] : ["- #{blank.join(', ')}: a top-level + or - between metrics is rewritten to read a blank side as 0, as DAX does. " \
                                                                 'Only a top-level binary + or - is rewritten; a + or - inside a function argument, or between aggregates inside another call, is not.'])

      dcs = cls_entries.select { |_k, c| %w[A B].include?(c['class']) }.keys.select do |k|
        t, m = k.split('.', 2)
        tb = Array(model_of(tmsl)['tables']).find { |x| x['name'] == t }
        meas = tb && Array(tb['measures']).find { |x| x['name'] == m }
        meas && Array(meas['expression']).join("\n") =~ /\bDISTINCTCOUNT\s*\(/i
      end
      sec.call('DISTINCTCOUNT counts BLANK', dcs.empty? ? [] : ["- #{dcs.join(', ')}: DAX DISTINCTCOUNT counts BLANK as a value, while the Sigma CountDistinct ignores NULL. " \
                                                                    'The two differ by one when the column holds NULL (nullability is not probed).'])
    end

    # 8. mixed summaries
    sec.call('Mixed-summary dropped fields', Array((log || {})['limits']).select { |l| l['kind'] == 'mixed_summary' }.map do |l|
      "- #{l['visual']} reads '#{l['source']}' only; dropped: #{Array(l['dropped']).join(', ')}. #{l['reason']}"
    end)

    # 9. CREATE VIEW
    views = create_views(dels)
    body = ["Where a customer wants a Custom SQL source to be a warehouse view instead, create it once and point the data model element at it. Replace `<TARGET_SCHEMA>` with the schema to create the views in.", '']
    body << 'No Custom SQL sources in this model.' if views.empty?
    views.each { |v| body.concat(['```sql', v, '```', '']) }
    sections << "## Optional customer step: Custom SQL as views\n\n#{body.join("\n").rstrip}\n"

    "# Limits of this migration\n\n#{sections.join("\n")}"
  end

  # ---- markdown ------------------------------------------------------------------------------

  def map_md(map)
    out = ["# Power BI to Sigma map\n"]
    map.each do |sec, items|
      out << "\n## #{sec.capitalize} (#{items.length})\n"
      out << "| Power BI | Sigma | Homes | Reason |\n|---|---|---|---|"
      items.each do |i|
        sg = i['sigma'] ? "#{i['sigma']['kind']}: #{i['sigma']['name']}" : '(none)'
        out << "| #{cell(i['pbi'])} | #{cell(sg)} | #{cell(i['homes'].join(', '))} | #{cell(i['reason'])} |"
      end
    end
    out.join("\n") + "\n"
  end

  def cell(s)
    s.to_s.gsub('|', '\\|').gsub(/\s*\n\s*/, ' ')
  end

  def comparison_md(cmp)
    keys = cmp.keys
    rows = %w[dm_elements sql_elements band wb_elements hidden_or_unread clicks_to_source clicks_to_source_max parity]
    out = ["# Views shape vs pbi shape\n", "| | #{keys.join(' | ')} |", "|---|#{keys.map { '---' }.join('|')}|"]
    rows.each { |r| out << "| #{r} | #{keys.map { |k| cmp[k][r].inspect }.join(' | ')} |" }
    out << "| total seconds | #{keys.map { |k| ((cmp[k]['timing'] || {})['totalSeconds']).inspect }.join(' | ')} |"
    out << "\nGuidance: #{BAND[0]}-#{BAND[1]} elements per data model.\n"
    out.join("\n") + "\n"
  end

  # ---- driver --------------------------------------------------------------------------------

  def run(o)
    out = o[:out_dir]
    FileUtils.mkdir_p(out)
    tmsl = read_json(o[:tmsl]) || {}
    signals = read_json(o[:signals]) || {}
    dm = read_json(o[:dm_spec]) || {}
    wb = wb_doc(read_json(o[:wb_spec]) || {})
    classes = read_json(o[:classes])
    classes = classes['classes'] if classes.is_a?(Hash) && classes['classes'].is_a?(Hash)
    log = read_json(o[:shaped_log]) || read_json(File.join(out, 'pbi-shaped-model.json'))
    if log.nil? && o[:shaped_log]
      warn "[warn] pbi-shaped-report: --shaped-log #{o[:shaped_log]} is missing or unreadable; continuing with an empty log"
      log = {}
    end
    classes ||= read_json(File.join(out, 'measure-classes.json')) if log
    scope = read_json(File.join(out, 'control-scope.json'))
    coverage = read_json(File.join(out, 'coverage.json'))
    dels = dm_elements(dm)
    scope_dropped = Array((read_json(File.join(out, 'model-scope.json')) || {})['dropped_tables'])

    map = {
      'tables' => map_tables(tmsl, dels, log, scope_dropped),
      'relationships' => map_relationships(tmsl, dels, log, scope_dropped),
      'measures' => map_measures(tmsl, signals, dels, classes),
      'visuals' => map_visuals(signals, wb, dels, coverage),
      'slicers' => map_slicers(signals, wb, scope, log)
    }
    written = []
    w = lambda do |name, text|
      # binwrite, as the builder does: a text-mode write turns "\n" into "\r\n" on Windows
      File.binwrite(File.join(out, name), text)
      written << name
    end
    w.call('pbi-map.json', JSON.pretty_generate(map))
    w.call('pbi-map.md', map_md(map))
    w.call('limits.md', build_limits(tmsl, dels, classes, log, scope, o[:slicer_carry] ? read_json(o[:slicer_carry]) : nil, wb,
                                     read_json(File.join(out, 'probe-controls', 'probe-results.json')), coverage))

    if o[:compare_dir]
      cur_shape = log ? 'pbi' : 'views'
      cmp = {}
      cur = shape_facts(dm, wb).merge('timing' => read_timing(out), 'parity' => read_parity(out))
      cmp[cur_shape] = cur
      od = o[:compare_dir]
      other_shape = File.file?(File.join(od, 'pbi-shaped-model.json')) ? 'pbi' : 'views'
      other = shape_facts(read_json(File.join(od, 'dm-spec.json')) || {}, wb_doc(read_json(File.join(od, 'workbook-spec.json')) || {}))
      other = other.merge('timing' => read_timing(od), 'parity' => read_parity(od))
      cmp[other_shape == cur_shape ? "#{other_shape}_compare" : other_shape] = other
      w.call('comparison.json', JSON.pretty_generate(cmp))
      w.call('comparison.md', comparison_md(cmp))
    end
    written
  end
end

if $PROGRAM_NAME == __FILE__
  o = {}
  OptionParser.new do |p|
    p.on('--tmsl PATH') { |v| o[:tmsl] = v }
    p.on('--signals PATH') { |v| o[:signals] = v }
    p.on('--dm-spec PATH') { |v| o[:dm_spec] = v }
    p.on('--wb-spec PATH') { |v| o[:wb_spec] = v }
    p.on('--classes PATH') { |v| o[:classes] = v }
    p.on('--shaped-log PATH') { |v| o[:shaped_log] = v }
    p.on('--slicer-carry PATH') { |v| o[:slicer_carry] = v }
    p.on('--out-dir DIR') { |v| o[:out_dir] = v }
    p.on('--compare-dir DIR') { |v| o[:compare_dir] = v }
  end.parse!
  abort 'FATAL: --out-dir is required' unless o[:out_dir]
  written = PbiShapedReport.run(o)
  puts "pbi-shaped-report: wrote #{written.join(', ')} in #{o[:out_dir]}"
end
