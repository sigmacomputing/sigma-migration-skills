# frozen_string_literal: true

require 'json'
require 'csv'

# dim_preserve.rb — keep dimension members that have NO fact rows.
#
# WHY: Tableau's relationship model keeps unmatched dimension members when a
# viz is keyed by dimension-table fields: Stress 4's "Store Scorecard" /
# "Store Rank Table" / "Store State Map" show Phoenix Outlet (0 orders, margin
# blank), Retail Command Center's "RC State Map" shows AZ blank. The Sigma
# master is fact-grained (the DM's order-fact view), so a store with no orders
# has no rows and the tile silently loses the member (parity 9/10, the
# independent checker counts the missing rows).
#
# The fix is EVIDENCE-GATED and NARROW:
#   * a displayed tile qualifies only when every dimension column it reads
#     comes from ONE related dimension table T (master columns reached through
#     the fact's T relationship carry the "(T)" suffix) AND its Tableau view
#     CSV shows a member whose every measure is blank or 0 — the unmatched
#     member Tableau kept;
#   * a page-level clone of the master is added right after it on the Data
#     page, sourced from a workbook `join`: T's data-model element as the
#     primary source, LEFT-OUTER joined to the fact element on the DM
#     relationship's keys. It keeps the master's column NAMES; T columns read
#     T itself (so the member survives), fact columns read the fact leg
#     (measures null, CountDistinct 0 — what the CSV shows);
#   * only the chain element that reads the master is re-pointed to the clone
#     ([Master/…] → [<clone>/…]; [Metrics/<m>] inlined — DM metrics do not
#     exist on a join). The master and every other tile are untouched.
module DimPreserve
  GENERATED_RE = /\(generated\)\s*\z/i.freeze
  AGG_RE = /\A\s*(?:Sum|Avg|Min|Max|Count|CountDistinct|CountIf|Median|Rank|RankDense|Percentile)\s*\(/i.freeze

  module_function

  def read_json(path)
    JSON.parse(File.read(path, encoding: 'UTF-8'))
  rescue StandardError
    nil
  end

  def dm_elements(dm)
    d = dm.is_a?(Hash) ? (dm['document'] || dm['contents'] || dm) : {}
    Array(d['elements']) + Array(d['pages']).flat_map { |p| Array(p['elements']) }
  end

  # The fact element behind a data-model master, its relationships, and
  # { rel_name => { dim:, keys: [{ left:, right: }] } }.
  def relationship_index(dm, master_src)
    els = dm_elements(dm)
    view = els.find { |e| e['id'] == master_src['elementId'] } or return {}
    fact = view.dig('source', 'kind') == 'table' ? els.find { |e| e['id'] == view.dig('source', 'elementId') } : view
    return {} unless fact
    col_name = lambda do |el, cid|
      c = Array(el['columns']).find { |x| x['id'] == cid }
      c && (c['name'] || c['formula'].to_s[%r{/([^/\]]+)\]\z}, 1])
    end
    Array(fact['relationships']).each_with_object({}) do |r, out|
      dim = els.find { |e| e['id'] == r['targetElementId'] }
      raw_keys = Array(r['keys'])
      next unless dim && raw_keys.any?
      keys = raw_keys.map do |k| # map+compact, not filter_map: Ruby 2.6 floor
        lk = col_name.call(dim, k['targetColumnId'])
        fact_key = col_name.call(fact, k['sourceColumnId'])
        view_key = if view == fact
                     Array(view['columns']).find { |c| c['id'] == k['sourceColumnId'] }
                   else
                     Array(view['columns']).find do |c|
                       c['id'] == k['sourceColumnId'] ||
                         c['formula'] == "[#{fact['name']}/#{fact_key}]"
                     end
                   end
        rk = col_name.call(view, view_key && view_key['id'])
        { 'left' => lk, 'right' => rk } if lk && rk
      end.compact
      next unless keys.length == raw_keys.length
      out[r['name'].to_s] = { 'dim' => dim, 'keys' => keys, 'view' => view }
    end
  end

  # A master column read through relationship T: "[<View>/<Field> (T)]".
  def dim_field(formula, rels)
    m = formula.to_s.match(/\A\[[^\/\]]+\/(.+) \(([^()]+)\)\]\z/) or return nil
    rels.key?(m[2]) ? [m[2], m[1]] : nil
  end

  # Tableau CSV evidence: a member whose every measure is blank or 0.
  def unmatched_member?(csv_path)
    rows = CSV.read(csv_path, encoding: 'bom|utf-8')
    header = Array(rows.first).map(&:to_s)
    body = rows.drop(1)
    return false if body.empty?
    num = ->(v) { s = v.to_s.strip.delete(',$%'); s.empty? ? nil : (Float(s) rescue nil) }
    blankish = ->(v) { (n = num.call(v)).nil? ? v.to_s.strip.empty? : n.zero? }
    mv = header.index { |h| h.strip.casecmp?('Measure Values') }
    mn = header.index { |h| h.strip.casecmp?('Measure Names') }
    skip = header.each_index.select { |i| header[i] =~ GENERATED_RE }
    if mv && mn
      dims = header.each_index.reject { |i| [mv, mn].include?(i) || skip.include?(i) }
      body.group_by { |r| dims.map { |i| r[i] } }.any? { |_, rs| rs.all? { |r| blankish.call(r[mv]) } }
    else
      meas = header.each_index.reject { |i| skip.include?(i) }.select { |i| body.any? { |r| num.call(r[i]) } && body.all? { |r| r[i].to_s.strip.empty? || num.call(r[i]) } }
      return false if meas.empty?
      body.any? { |r| meas.all? { |i| blankish.call(r[i]) } }
    end
  rescue StandardError
    false
  end

  def strip_quals(s)
    cur = s.to_s.strip
    cur = cur.sub(/\s*\([^()]*(?:\([^()]*\))?[^()]*\)\s*\z/, '').strip while cur =~ /\)\s*\z/
    cur.downcase
  end

  # CSV columns that are dimensions: not Measure Names/Values, not generated
  # geo, not numeric throughout.
  def csv_dimensions(csv_path)
    rows = CSV.read(csv_path, encoding: 'bom|utf-8')
    header = Array(rows.first).map(&:to_s)
    body = rows.drop(1)
    num = ->(v) { s = v.to_s.strip.delete(',$%'); s.empty? || !(Float(s) rescue nil).nil? }
    header.each_index.reject do |i|
      h = header[i].strip
      h =~ /\AMeasure (Names|Values)\z/i || h =~ GENERATED_RE || (body.any? && body.all? { |r| num.call(r[i]) })
    end.map { |i| header[i].strip }
  rescue StandardError
    []
  end

  # A CSV header ("Store Name", "State (STORE_DIM (DB.STORE_DIM))") → the
  # master column it reads ("Store Name", "State (STORE_DIM)"), qualifiers
  # stripped both ways.
  def master_column_for(header, mcols)
    mcols[header] || mcols.values.find { |c| strip_quals(c['name']) == strip_quals(header) }
  end

  # Walk from a displayed element to the chain element that reads `master_id`.
  def chain_reader(by_id, el, master_id)
    seen = {}
    cur = el
    while cur && !seen[cur['id']]
      seen[cur['id']] = true
      return cur if cur.dig('source', 'kind') == 'table' && cur.dig('source', 'elementId') == master_id
      nxt = cur.dig('source', 'kind') == 'table' ? by_id[cur.dig('source', 'elementId')] : nil
      break unless nxt && nxt.dig('source', 'kind') == 'table'
      cur = nxt
    end
    nil
  end

  # spec: legacy view. ctx: { dm:, metrics: [{name, formula}], provenance: {el => {worksheet}},
  # view_csv: ->(worksheet) { path or nil } }. Returns { built: [...], notes: [...] }.
  def apply!(spec, ctx)
    out = { built: [], notes: [] }
    pages = Array(spec['pages'])
    all = pages.flat_map { |p| Array(p['elements']) }
    by_id = all.each_with_object({}) { |e, h| h[e['id']] = e }
    metrics = Array(ctx[:metrics]).each_with_object({}) { |m, h| h[m['name'].to_s] = m['formula'].to_s }
    clones = {}
    keep_after_master!(pages, by_id)
    Array(ctx[:provenance]).each do |el_id, prov|
      el = by_id[el_id]
      ws = prov.is_a?(Hash) ? prov['worksheet'] : nil
      next unless el && ws
      reader = nil
      master = nil
      by_id.each_value do |cand|
        next unless cand.dig('source', 'kind') == 'data-model' && cand['name']
        r = chain_reader(by_id, el, cand['id'])
        if r
          reader = r
          master = cand
          break
        end
      end
      next unless reader && master
      rels = relationship_index(ctx[:dm], master['source'])
      next if rels.empty?
      mcols = Array(master['columns']).each_with_object({}) { |c, h| h[c['name'].to_s] = c }
      csv = ctx[:view_csv]&.call(ws)
      next unless csv && File.file?(csv)
      # The tile's DIMENSIONS are the Tableau CSV's non-measure columns; each
      # one that is a master column must come from the same table T (a
      # fact-table dimension means the fact grain is right as is).
      dims = csv_dimensions(csv).map { |h| master_column_for(h, mcols) }.compact.uniq
      tables = dims.map { |c| (dim_field(c['formula'], rels) || [nil]).first }.uniq
      next unless dims.any? && tables.size == 1 && tables.first
      t = tables.first
      next unless unmatched_member?(csv)

      key = [master['id'], t]
      clone = clones[key] ||= build_clone!(pages, master, t, rels[t], ctx, out)
      next unless clone
      clone['_dim_preserve_rels'] ||= rels
      clone['_dim_preserve'] ||= { 'table' => t }
      rewrite!(reader, master['name'], clone['name'], metrics)
      reader['source'] = { 'kind' => 'table', 'elementId' => clone['id'] }
      # every column the re-pointed reader now reads off the clone (including
      # the bare refs of inlined metrics) must exist on it
      refs = Array(reader['columns']).flat_map { |c| c['formula'].to_s.scan(/\[#{Regexp.escape(clone['name'])}\/([^\]]+)\]/).flatten }
      refs.uniq.each do |n|
        next if Array(clone['columns']).any? { |c| c['name'] == n }
        src = mcols[n] || { 'id' => n.downcase.gsub(/[^a-z0-9]+/, '-'), 'name' => n,
                            'formula' => "[#{rels[t]['view']['name']}/#{n}]" } # a fact-leg column the master never carried
        clone['columns'] << clone_column(src, rels, t, clone)
      end
      rec = out[:built].find { |b| b['clone'] == clone['id'] }
      (rec['tiles'] << el_id).uniq!
    end
    wire_controls!(all, clones, by_id)
    clones.each_value { |c| next unless c; c.delete('_dim_preserve_rels'); c.delete('_dim_preserve') }
    out
  end

  # A clone already in the spec (re-entry) sits right after its master: the
  # layout round trip orders elements by grid position, which put it after the
  # tiles that read it — spec references resolve forward-in-document-order.
  def keep_after_master!(pages, by_id)
    pages.each do |page|
      els = Array(page['elements'])
      els.select { |e| e['id'].to_s =~ /-keep-[a-z0-9-]+\z/ && e.dig('source', 'kind') == 'join' }.each do |clone|
        master = by_id[clone['id'].sub(/-keep-[a-z0-9-]+\z/, '')]
        next unless master && els.include?(master)
        els.delete(clone)
        els.insert(els.index(master) + 1, clone)
      end
    end
  end

  # Every control that filters a master also filters its dimension-preserving
  # clone on the same column (else control lint reports a partial control and
  # the re-pointed tiles ignore the page's filters).
  def wire_controls!(all, clones, by_id)
    clones.each do |(master_id, _t), clone|
      next unless clone
      master = by_id[master_id]
      all.select { |e| e['kind'] == 'control' }.each do |ctl|
        Array(ctl['filters']).dup.each do |f|
          next unless f.is_a?(Hash) && f.dig('source', 'elementId') == master_id
          mc = Array(master['columns']).find { |c| c['id'] == f['columnId'] } or next
          cc = Array(clone['columns']).find { |c| c['name'] == mc['name'] }
          unless cc
            rels_t = clone.dig('_dim_preserve', 'table')
            cc = clone_column(mc, clone['_dim_preserve_rels'] || {}, rels_t, clone)
            clone['columns'] << cc
          end
          tgt = { 'source' => { 'kind' => 'table', 'elementId' => clone['id'] }, 'columnId' => cc['id'] }
          ctl['filters'] << tgt unless ctl['filters'].any? { |x| x == tgt }
        end
      end
    end
  end

  def clone_column(src, rels, t, clone)
    f = dim_field(src['formula'], rels)
    formula = if f && f.first == t then "[#{clone['source']['name']}/#{f.last}]"
              else src['formula']
              end
    { 'id' => "#{clone['id']}-#{src['id']}", 'name' => src['name'], 'formula' => formula }
  end

  def build_clone!(pages, master, t, rel, ctx, out)
    dm_id = master.dig('source', 'dataModelId')
    view = rel['view']
    base_name = "#{rel['dim']['name']} (all members)"
    clone_id = "#{master['id']}-keep-#{t.downcase.gsub(/[^a-z0-9]+/, '-')}"
    # Re-entry with an operator-edited spec that already carries the clone:
    # reuse it (never a second copy).
    existing = pages.flat_map { |p| Array(p['elements']) }.find { |e| e['id'] == clone_id }
    if existing
      existing['columns'] ||= []
      out[:built] << { 'clone' => clone_id, 'table' => t, 'tiles' => [], 'note' => 'reused (already in the spec)' }
      return existing
    end
    clone = {
      'id' => clone_id,
      'kind' => 'table',
      'name' => "#{master['name']} (all #{t} members)",
      'source' => {
        'kind' => 'join', 'name' => base_name,
        'primarySource' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => rel['dim']['id'] },
        'joins' => [{
          'name' => view['name'], 'joinType' => 'left-outer',
          'left' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => rel['dim']['id'] },
          'right' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => view['id'] },
          'columns' => rel['keys'].map { |k| { 'left' => "[#{k['left']}]", 'right' => "[#{k['right']}]" } }
        }]
      },
      'columns' => []
    }
    page = pages.find { |p| Array(p['elements']).include?(master) } or return nil
    page['elements'].insert(page['elements'].index(master) + 1, clone)
    on = rel['keys'].map { |k| "#{k['left']} = #{k['right']}" }.join(' AND ')
    out[:built] << { 'clone' => clone['id'], 'table' => t, 'tiles' => [],
                     'note' => "#{rel['dim']['name']} LEFT-OUTER #{view['name']} on #{on}" }
    out[:notes] << "dimension-preserving base #{clone['id']}: #{t} members with no fact rows are kept (Tableau relationship semantics)"
    clone
  end

  def rewrite!(el, from, to, metrics)
    Array(el['columns']).each do |c|
      f = c['formula'].to_s.gsub("[#{from}/", "[#{to}/")
      f = f.gsub(%r{\[Metrics/([^\]]+)\]}) do
        inline = metrics[Regexp.last_match(1)]
        inline ? "(#{inline.gsub(/\[([^\]\/]+)\]/) { "[#{to}/#{Regexp.last_match(1)}]" }})" : Regexp.last_match(0)
      end
      c['formula'] = f
    end
  end
end

module DimPreserve
  module_function

  # The pass's inputs from a workdir: the DM readback (dm-readback.json, or the
  # given readback on DM reuse), metrics.json, chart-provenance.json and the
  # worksheet CSVs named in get-workbook.json. nil when there is no readback.
  def context(work, dm: nil)
    require_relative 'mcp_source'
    dm ||= read_json(File.join(work, 'dm-readback.json'))
    return nil unless dm
    prov = read_json(File.join(work, 'chart-provenance.json'))
    gw = read_json(File.join(work, 'get-workbook.json')) || {}
    views = (McpSource.views_for(work, gw) rescue []).each_with_object({}) { |v, h| h[v['name'].to_s] = v if v.is_a?(Hash) }
    metrics = read_json(File.join(work, 'metrics.json'))
    metrics = metrics['metrics'] if metrics.is_a?(Hash)
    { dm: dm, metrics: Array(metrics),
      provenance: prov.is_a?(Hash) ? (prov['elements'] || {}) : {},
      view_csv: lambda { |ws|
        v = views[ws.to_s]
        v && (McpSource.csv_path(work, v) rescue nil)
      } }
  end
end
