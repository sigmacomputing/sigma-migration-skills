# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'twb_xml'
require_relative 'fcp_normalize'
require_relative 'join_plan'

# relationship-map.json — the reused-DM relationship evidence route.
#
# WHY: relationship-coverage.json judges a converter-generated data model by an
# exact count against Tableau's serialized relationships. A data model the
# customer built themselves (reused by explicit --reuse-dm <id>) deliberately
# restructures relationships, so that count can never match even when every
# join is proven. This module compares the Tableau object-graph(s) with the
# LIVE reused model and classifies each Tableau relationship:
#   matched      — the model joins the same two tables on the same key columns
#   replaced     — both tables connected, but by different keys / another path
#   disconnected — both tables in the model, no path between them
#   dropped      — a table has no model element at all
# and lists model edges with no Tableau counterpart as `extra`. Everything not
# matched names the evidence it needs (`requires`); evaluate() checks that
# evidence. Facts are always re-derived, so a hand-edited map is stale, and a
# `reason` is display-only — it never satisfies evidence.
#
# Ruby 2.6-compatible. Offline; parsing via lib/twb_xml.rb.
module RelationshipMap
  SCHEMA_VERSION = 1
  ROUTE = 'reused-dm-evidence'
  # Stands in for a worksheet field the derivation could not trace to a table:
  # unknown usage fails a field-use check (fail closed), never passes it.
  UNRESOLVED = '?unresolved-field'
  # Worksheet usage also records the Tableau object each field reads, under
  # this prefix (never a table id): a self-join's two ends are one table, so
  # only the objects tell the table from its aliased copy.
  OBJECT = '?object:'

  module_function

  # dashboard-scope.json → migrated dashboard names (nil = every dashboard).
  def scoped_dashboards(scope)
    return nil unless scope.is_a?(Hash) && scope['mode'].to_s == 'selected'
    Array(scope['dashboards']).map(&:to_s).reject(&:empty?)
  end

  # resolution: how this run maps Tableau relations to warehouse tables, the
  # same inputs the converter used — { 'db', 'schema', 'table_mapping' }
  # (--db / --schema / --table-mapping, or a target-model plan). nil = the
  # .twb's own connection db/schema, no remapping.
  def derive(twb_xml:, dm_spec:, dashboards: nil, resolution: nil)
    doc = parse(twb_xml)
    resolution = normalize_resolution(resolution)
    source = tableau_model(doc, resolution)
    model = dm_model(dm_spec)
    blockers = []
    tables = map_tables(source[:tables], model[:elements], blockers)
    el_table = {}
    tables.each { |t| t['dm_element_ids'].each { |id| el_table[id] ||= t['table'] } }
    edges = model[:edges].map do |edge|
      edge.merge('source_table' => el_table[edge['source_element']],
                 'target_table' => el_table[edge['target_element']])
    end
    usage = worksheet_tables(doc, source, dashboards)
    mapped = tables.reject { |t| t['dm_element_ids'].empty? }.map { |t| t['table'] }.uniq
    elements_of = lambda do |table|
      tables.select { |t| t['table'] == table }.flat_map { |t| t['dm_element_ids'] }.uniq
    end
    used_edges = {}

    entries = source[:relationships].map do |rel|
      classify(rel, edges, elements_of, mapped, usage, used_edges)
    end
    bridge_pairs(source, mapped, usage).each do |pair|
      rel = { 'datasource' => nil, 'left' => pair[:left], 'right' => pair[:right], 'tableau_keys' => [] }
      entries << classify(rel, edges, elements_of, mapped, usage, used_edges).merge('bridge_for' => pair[:via])
    end
    edges.each do |edge|
      next if used_edges[edge['edge_id']]
      entries << {
        'kind' => 'extra', 'datasource' => nil,
        'left' => edge['source_table'], 'right' => edge['target_table'], 'tableau_keys' => [],
        'disposition' => 'extra', 'dm_path' => [edge['edge_id']], 'requires' => %w[key_probe parity],
        'field_use' => nil, 'affected_worksheets' => affected(usage, [edge['source_table'], edge['target_table']]),
        'reason' => nil
      }
    end
    entries.each_with_index { |e, i| e['index'] = i }
    entries = entries.map { |e| { 'index' => e['index'], 'kind' => e['kind'] }.merge(e) }

    inputs = { 'twb_sha256' => Digest::SHA256.hexdigest(twb_xml.to_s),
               'dm_sha256' => Digest::SHA256.hexdigest(JSON.generate(dm_spec)) }
    inputs['resolution'] = resolution if resolution
    {
      'schema_version' => SCHEMA_VERSION,
      'route' => ROUTE,
      'inputs' => inputs,
      'tables' => tables,
      'dm_edges' => edges.map do |edge|
        { 'edge_id' => edge['edge_id'], 'edge_sha' => edge_sha(edge),
          'source_element' => edge['source_element'], 'target_element' => edge['target_element'],
          'source_table' => edge['source_table'], 'target_table' => edge['target_table'],
          'keys' => edge['keys'], 'probe' => nil }
      end,
      'entries' => entries,
      'blockers' => blockers
    }
  end

  def write(path, doc)
    File.write(path, "#{JSON.pretty_generate(doc)}\n")
  end

  # Carry the operator's reasons (by entry identity) and probe results (by
  # edge_id, only while edge_sha is unchanged) from a prior map onto a fresh one.
  def merge_prior(fresh, prior)
    return fresh unless prior.is_a?(Hash)
    out = JSON.parse(JSON.generate(fresh))
    reasons = Array(prior['entries']).each_with_object({}) do |e, h|
      h[[e['kind'], e['left'], e['right']]] = e['reason'] unless e['reason'].nil?
    end
    probes = Array(prior['dm_edges']).each_with_object({}) { |d, h| h[d['edge_id']] = d }
    out['entries'].each { |e| e['reason'] = reasons[[e['kind'], e['left'], e['right']]] if reasons.key?([e['kind'], e['left'], e['right']]) }
    out['dm_edges'].each do |d|
      old = probes[d['edge_id']]
      d['probe'] = old['probe'] if old && old['edge_sha'] == d['edge_sha']
    end
    out
  end

  COUNT_KINDS = %w[matched replaced disconnected dropped extra].freeze
  PENDING_KINDS = %w[unprobed parity-missing].freeze

  # final: false (pass 1) reports unprobed edges and missing parity as pending;
  # final: true (--finalize / verify-complete) blocks on them.
  def evaluate(map, twb_xml:, dm_spec:, dashboards: nil, parity: nil, final: true, resolution: nil)
    blockers = []
    entries = Array(map.is_a?(Hash) ? map['entries'] : nil)
    fresh = derive(twb_xml: twb_xml, dm_spec: dm_spec, dashboards: dashboards, resolution: resolution)
    unless facts(map) == facts(fresh)
      blockers << { 'kind' => 'stale-map',
                    'reason' => 'relationship-map.json does not match the current .twb and data model; re-run emit-relationship-map' }
    end
    Array(fresh['blockers']).each { |b| blockers << b }
    edges = Array(map.is_a?(Hash) ? map['dm_edges'] : nil).each_with_object({}) { |d, h| h[d['edge_id']] = d }
    passed = Array(parity.is_a?(Hash) ? parity['pass_names'] : nil).map { |n| n.to_s.strip.downcase }
    failed = Array(parity.is_a?(Hash) ? parity['fail_names'] : nil).map { |n| n.to_s.strip.downcase }
    entries.each do |e|
      req = Array(e['requires'])
      if req.include?('key_probe')
        Array(e['dm_path']).each do |edge_id|
          kind = probe_problem(edges[edge_id] && edges[edge_id]['probe'])
          blockers << { 'kind' => kind, 'index' => e['index'], 'edge_id' => edge_id,
                        'reason' => "#{e['left']} ↔ #{e['right']}: edge #{edge_id} #{kind}" } if kind
        end
      end
      if req.include?('parity')
        Array(e['affected_worksheets']).each do |ws|
          key = ws.to_s.strip.downcase
          kind = if failed.include?(key) then 'parity-failed'
                 elsif passed.include?(key) then nil
                 else 'parity-missing'
                 end
          next unless kind
          blockers << { 'kind' => kind, 'index' => e['index'], 'worksheet' => ws,
                        'reason' => "#{e['left']} ↔ #{e['right']}: worksheet #{ws} #{kind}" }
        end
      end
      next unless req.include?('field_use') && e.dig('field_use', 'status') != 'pass'
      blockers << { 'kind' => 'field-use', 'index' => e['index'],
                    'reason' => "#{e['left']} ↔ #{e['right']} (#{e['disposition']}): used together by " \
                                "#{Array(e.dig('field_use', 'worksheets')).join(', ')}" }
    end
    counts = COUNT_KINDS.each_with_object({}) { |k, h| h[k] = entries.count { |e| e['disposition'] == k } }
    status = if blockers.empty? then 'pass'
             elsif !final && blockers.all? { |b| PENDING_KINDS.include?(b['kind']) } then 'pending'
             else 'fail'
             end
    { 'status' => status, 'counts' => counts, 'blockers' => blockers }
  end

  # The final gates' entry point (assert-relationship-coverage, verify-complete):
  # judge <workdir>/relationship-map.json against the workdir's own inputs.
  def evaluate_workdir(workdir, final: true, state_file: 'migrate-state.json')
    read = lambda do |name|
      path = File.join(workdir, name)
      File.file?(path) ? JSON.parse(File.read(path)) : nil
    end
    missing = %w[relationship-map.json workbook-content.twb dm-spec-reused.json].reject do |name|
      File.file?(File.join(workdir, name))
    end
    unless missing.empty?
      return { 'status' => 'fail', 'counts' => COUNT_KINDS.each_with_object({}) { |k, h| h[k] = 0 },
               'blockers' => missing.map { |name| { 'kind' => 'input-missing', 'reason' => "#{File.join(workdir, name)} is missing" } } }
    end
    evaluate(read.call('relationship-map.json'),
             twb_xml: File.read(File.join(workdir, 'workbook-content.twb'), encoding: 'bom|utf-8'),
             dm_spec: read.call('dm-spec-reused.json'),
             dashboards: scoped_dashboards(read.call('dashboard-scope.json')),
             parity: normalize_parity(read.call('parity-final.json'), read.call('parity-expected.json'),
                                      read.call('parity-plan.json')),
             final: final, resolution: (read.call(state_file) || {})['relationship_resolution'])
  rescue JSON::ParserError, SystemCallError => e
    { 'status' => 'fail', 'counts' => {}, 'blockers' => [{ 'kind' => 'input-unreadable', 'reason' => e.message.to_s[0, 200] }] }
  end

  # Parity names Sigma charts; the map names Tableau worksheets. Normalize
  # parity-final.json into pass/fail names and alias each chart to its
  # Tableau worksheet through parity-plan.json (charts[].tableau_view), so a
  # renamed tile still answers for its worksheet. The Python profile's
  # parity-final.json is one whole-workbook verdict (verify-parity.py: match
  # + differences with paths like "$.<chart>[i]"): it is split by chart using
  # parity-expected.json's keys, and a whole-document difference ("$")
  # fails every chart.
  def normalize_parity(parity, expected, plan = nil)
    return parity unless parity.is_a?(Hash)
    if parity.key?('pass_names')
      passed = Array(parity['pass_names'])
      failed = Array(parity['fail_names'])
    elsif expected.is_a?(Hash)
      paths = Array(parity['differences']).map { |d| d.is_a?(Hash) ? d['path'].to_s : '' }
      failed = if paths.any? { |path| !path.start_with?('$.') }
                 expected.keys
               else
                 expected.keys.select do |name|
                   paths.any? { |path| path == "$.#{name}" || path.start_with?("$.#{name}.", "$.#{name}[") }
                 end
               end
      passed = expected.keys - failed
    else
      return parity
    end
    views = Array(plan.is_a?(Hash) ? plan['charts'] : nil).each_with_object({}) do |chart, h|
      h[chart['chart'].to_s] = chart['tableau_view'].to_s if chart.is_a?(Hash) && !chart['tableau_view'].to_s.empty?
    end
    with_views = ->(names) { (names + names.map { |n| views[n.to_s] }.compact).uniq }
    { 'pass_names' => with_views.call(passed), 'fail_names' => with_views.call(failed) }
  end

  # Markdown for migration-notes.md: one row per deviation with its evidence.
  def notes_markdown(map, result)
    edges = Array(map['dm_edges']).each_with_object({}) { |d, h| h[d['edge_id']] = d }
    md = +"## Relationship deviations (reused data model)\n\n"
    md << "Judged on the reused-DM evidence route: #{summary_line(result)} — #{result['status'].upcase}.\n\n"
    rows = Array(map['entries']).reject { |e| e['disposition'] == 'matched' }
    return md << "No deviations: every Tableau relationship is carried as-is.\n" if rows.empty?
    md << "| # | Tables | Disposition | Keys (model) | Evidence | Reason |\n|---|---|---|---|---|---|\n"
    rows.each do |e|
      path = Array(e['dm_path']).map { |id| edges[id] }.compact
      keys = path.flat_map { |d| Array(d['keys']).map { |k| "#{k['source']} → #{k['target']}" } }
      evidence = []
      path.each do |d|
        probe = d['probe']
        evidence << if probe.nil? then "#{d['edge_id']}: probe pending"
                    elsif probe['status'] == 'error' then "#{d['edge_id']}: probe error"
                    else
                      "#{d['edge_id']}: probe #{probe['status']} (#{probe.dig('unique', 'total')} rows, " \
                        "#{probe['unmatched']} unmatched)"
                    end
      end
      evidence << "parity: #{Array(e['affected_worksheets']).join(', ')}" if Array(e['requires']).include?('parity')
      if e['field_use']
        used = Array(e.dig('field_use', 'worksheets'))
        evidence << "field use #{e.dig('field_use', 'status')}#{used.empty? ? '' : " (#{used.join(', ')})"}"
      end
      evidence << "bridges #{Array(e['bridge_for']).join(', ')}" if e['bridge_for']
      md << "| #{e['index']} | #{e['left']} ↔ #{e['right']} | #{e['disposition']} | #{keys.empty? ? '—' : keys.join('; ')} | " \
            "#{evidence.join('; ')} | #{e['reason'] || '—'} |\n"
    end
    md
  end

  def summary_line(result)
    c = result['counts']
    "#{c['matched']} matched, #{c['replaced']} replaced, #{c['dropped']} dropped, " \
      "#{c['disconnected']} disconnected, #{c['extra']} extra"
  end

  # Probe evidence is re-checked from its numbers: a status of 'pass' alone is
  # not trusted.
  def probe_problem(probe)
    return 'unprobed' if probe.nil?
    return 'probe-error' if probe['status'] == 'error'
    unique = probe['unique'] || {}
    ok = probe['status'] == 'pass' && unique['total'].is_a?(Integer) && unique['total'] == unique['distinct'] &&
         probe['unmatched'] == 0
    ok ? nil : 'probe-failed'
  end

  # Everything derive() computes; reasons and probes are the only fields a
  # later step may add.
  def facts(map)
    copy = JSON.parse(JSON.generate(map))
    return copy unless copy.is_a?(Hash)
    Array(copy['entries']).each { |e| e.delete('reason') }
    Array(copy['dm_edges']).each { |d| d.delete('probe') }
    copy
  end

  # ---- classification -------------------------------------------------------

  def classify(rel, edges, elements_of, mapped, usage, used_edges)
    left = rel['left']
    right = rel['right']
    base = { 'kind' => 'tableau', 'datasource' => rel['datasource'], 'left' => left, 'right' => right,
             'tableau_keys' => rel['tableau_keys'] }
    base['computed_conditions'] = rel['computed_conditions'] if rel['computed_conditions']
    unless mapped.include?(left) && mapped.include?(right)
      dropped = [left, right].reject { |t| mapped.include?(t) }
      return base.merge('disposition' => 'dropped', 'dm_path' => [], 'requires' => %w[field_use not_a_bridge],
                        'field_use' => field_use(usage) { |used| (used & (dropped + [UNRESOLVED])).any? },
                        'affected_worksheets' => [], 'reason' => nil)
    end
    matchable = !rel['tableau_keys'].empty? && rel['computed_conditions'].to_i.zero?
    direct = matchable ? edges.find { |edge| same_join?(edge, rel) } : nil
    if direct
      used_edges[direct['edge_id']] = true
      return base.merge('disposition' => 'matched', 'dm_path' => [direct['edge_id']], 'requires' => [],
                        'field_use' => nil, 'affected_worksheets' => [], 'reason' => nil)
    end
    path = shortest_path(edges, elements_of.call(left), elements_of.call(right))
    if path
      path.each { |edge| used_edges[edge['edge_id']] = true }
      path_tables = path.flat_map { |edge| [edge['source_table'], edge['target_table']] }.compact.uniq
      return base.merge('disposition' => 'replaced', 'dm_path' => path.map { |edge| edge['edge_id'] },
                        'requires' => %w[key_probe parity], 'field_use' => nil,
                        'affected_worksheets' => affected(usage, path_tables, left == right ? rel['objects'] : nil),
                        'reason' => nil)
    end
    # A self-join is used only by a worksheet reading both of its objects.
    ends = left == right && rel['objects'] && rel['objects'].uniq.size == 2 ? rel['objects'] : [left, right]
    base.merge('disposition' => 'disconnected', 'dm_path' => [], 'requires' => ['field_use'],
               'field_use' => field_use(usage) do |used|
                 ends.all? { |e| used.include?(e) } || used.include?(UNRESOLVED)
               end,
               'affected_worksheets' => [], 'reason' => nil)
  end

  # Same two tables, same key columns, either orientation.
  def same_join?(edge, rel)
    pairs = rel['tableau_keys'].map { |k| [k['left'], k['right']] }.sort
    keys = edge['keys'].map { |k| [k['source'], k['target']] }
    forward = edge['source_table'] == rel['left'] && edge['target_table'] == rel['right']
    reverse = edge['source_table'] == rel['right'] && edge['target_table'] == rel['left']
    # a self-join satisfies both orientations, so either key order matches
    (forward && keys.sort == pairs) || (reverse && keys.map(&:reverse).sort == pairs)
  end

  # Undirected BFS over model edges from any element of one table to any of the
  # other; neighbors in edge_id order so the chosen path is deterministic. A
  # self-join (both ends one table) needs a path that leaves its start: the
  # shortest one from each start element to another element (or a self-loop).
  def shortest_path(edges, from_ids, to_ids)
    return nil if from_ids.empty? || to_ids.empty?
    adjacency = Hash.new { |h, k| h[k] = [] }
    edges.sort_by { |edge| edge['edge_id'] }.each do |edge|
      adjacency[edge['source_element']] << [edge['target_element'], edge]
      adjacency[edge['target_element']] << [edge['source_element'], edge]
    end
    return bfs_path(adjacency, from_ids.sort, to_ids) if (from_ids & to_ids).empty?
    from_ids.sort.map { |start| bfs_path(adjacency, [start], to_ids - [start], start) }.compact.min_by(&:size)
  end

  def bfs_path(adjacency, starts, to_ids, loop_at = nil)
    if loop_at
      self_loop = adjacency[loop_at].find { |(nxt, _edge)| nxt == loop_at }
      return [self_loop[1]] if self_loop
    end
    back = {}
    queue = starts.dup
    queue.each { |id| back[id] = nil }
    until queue.empty?
      node = queue.shift
      if to_ids.include?(node)
        path = []
        while back[node]
          prev, edge = back[node]
          path.unshift(edge)
          node = prev
        end
        return path.empty? ? nil : path
      end
      adjacency[node].each do |(nxt, edge)|
        next if back.key?(nxt)
        back[nxt] = [node, edge]
        queue << nxt
      end
    end
    nil
  end

  # A worksheet exercises a join only when it uses fields from at least two of
  # the joined tables; one table alone never reaches the relationship. A
  # single-table deviation (a self-join's path, a same-table extra edge) is
  # exercised by a worksheet reading both of the self-join's objects, or, with
  # no objects to tell the copies apart, by any worksheet reading the table.
  def affected(usage, tables, objects = nil)
    wanted = tables.compact.uniq
    usage.select do |_ws, used|
      next true if used.include?(UNRESOLVED)
      next (used & wanted).size >= 2 if wanted.size >= 2
      objects && objects.uniq.size == 2 ? (objects - used).empty? : (used & wanted).any?
    end.keys.sort
  end

  def field_use(usage)
    hits = usage.select { |_ws, used| yield(used) }.keys.sort
    { 'status' => hits.empty? ? 'pass' : 'fail', 'worksheets' => hits }
  end

  # not-a-bridge: two kept tables one migrated worksheet uses together, joined
  # in Tableau only THROUGH a dropped table. The model must connect them itself.
  def bridge_pairs(source, mapped, usage)
    adjacency = Hash.new { |h, k| h[k] = [] }
    direct = {}
    source[:relationships].each do |rel|
      adjacency[rel['left']] << rel['right']
      adjacency[rel['right']] << rel['left']
      direct[[rel['left'], rel['right']].sort] = true
    end
    pairs = usage.values.flat_map { |used| (used & mapped).uniq.sort.combination(2).to_a }.uniq.sort
    pairs.each_with_object([]) do |(a, b), out|
      next if direct[[a, b]]
      full = tableau_path(adjacency, a, b, nil)
      next unless full
      next if tableau_path(adjacency, a, b, mapped)
      out << { left: a, right: b, via: (full - [a, b]).reject { |t| mapped.include?(t) }.sort }
    end
  end

  def tableau_path(adjacency, from, to, allowed)
    back = { from => nil }
    queue = [from]
    until queue.empty?
      node = queue.shift
      if node == to
        path = [node]
        path.unshift(node) while (node = back[node])
        return path
      end
      adjacency[node].sort.each do |nxt|
        next if back.key?(nxt) || (allowed && !allowed.include?(nxt))
        back[nxt] = node
        queue << nxt
      end
    end
    nil
  end

  def edge_sha(edge)
    Digest::SHA256.hexdigest(JSON.generate([edge['source_element'], edge['target_element'],
                                            edge['source_table'], edge['target_table'], edge['keys']]))
  end

  # ---- table identity -------------------------------------------------------

  # A Tableau table matches a model element by full DB.SCHEMA.TABLE when both
  # sides have one; a shorter Tableau name (no dbname) must agree with the
  # model path on every part it has (SCHEMA.TABLE, or the table token alone).
  # A name that reaches two distinct model tables, or two distinct Tableau
  # tables that reach one model element, is ambiguous: blocked, never guessed.
  # Custom SQL objects match a SQL element by whitespace/case-normalized
  # statement.
  def map_tables(source_tables, elements, blockers)
    ambiguous = lambda do |table, reason|
      blockers << { 'kind' => 'ambiguous-table', 'table' => table, 'reason' => reason } unless blockers.any? { |b| b['table'] == table }
    end
    rows = source_tables.map do |t|
      ids = if t[:sql]
              elements.select { |e| e[:sql] && e[:sql] == t[:sql] }.map { |e| e[:id] }
            elsif t[:parts].size == 3 && elements.any? { |e| e[:path].size == 3 }
              elements.select { |e| e[:path].size == 3 && e[:fqn] == t[:id] }.map { |e| e[:id] }
            else
              hits = elements.select { |e| suffix_match?(t[:parts], e[:path]) }
              if hits.map { |e| e[:fqn] }.uniq.size > 1
                ambiguous.call(t[:id], "#{t[:id]} matches #{hits.map { |e| e[:fqn] }.uniq.sort.join(', ')} by name only")
                []
              else
                hits.map { |e| e[:id] }
              end
            end
      { 'table' => t[:id], 'datasource' => t[:datasource], 'dm_element_ids' => ids.sort }
    end
    claims = Hash.new { |h, k| h[k] = [] }
    rows.each { |r| r['dm_element_ids'].each { |id| claims[id] << r['table'] } }
    shared = claims.select { |_id, tables| tables.uniq.size > 1 }
    shared.each do |id, tables|
      tables.uniq.sort.each { |table| ambiguous.call(table, "#{tables.uniq.sort.join(' and ')} both resolve to model element #{id}") }
    end
    blocked = blockers.select { |b| b['kind'] == 'ambiguous-table' }.map { |b| b['table'] }
    rows.each { |r| r['dm_element_ids'] = [] if blocked.include?(r['table']) }
    rows
  end

  def suffix_match?(parts, path)
    return false if parts.empty? || path.empty? || parts.size > path.size
    tail = path.last(parts.size).map(&:upcase)
    tail[0...-1] == parts[0...-1].map(&:upcase) &&
      JoinPlan.object_table_key(tail.last) == JoinPlan.object_table_key(parts.last.to_s)
  end

  # ---- Tableau side ---------------------------------------------------------

  def parse(twb_xml)
    xml = twb_xml.to_s
    xml = FcpNormalize.normalize(xml) if FcpNormalize.needed?(xml)
    TwbXml.parse(xml)
  end

  def normalize_sql(sql)
    sql.to_s.strip.sub(/;\s*\z/, '').gsub(/\s+/, ' ').downcase
  end

  def relation_table(doc, rel, resolution = nil)
    if rel.attributes['type'].to_s == 'text'
      { id: "SQL:#{rel.attributes['name']}", parts: [], sql: normalize_sql(rel.text) }
    else
      parts = warehouse_path(doc, rel, resolution)
      { id: parts.join('.'), parts: parts, sql: nil }
    end
  end

  def normalize_resolution(resolution)
    return nil unless resolution.is_a?(Hash)
    out = { 'db' => resolution['db'].to_s.strip, 'schema' => resolution['schema'].to_s.strip,
            'table_mapping' => (resolution['table_mapping'].is_a?(Hash) ? resolution['table_mapping'] : {})
                                 .each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s } }
    out['db'] = nil if out['db'].empty?
    out['schema'] = nil if out['schema'].empty?
    out['db'] || out['schema'] || !out['table_mapping'].empty? ? out : nil
  end

  GUID_PART = /\A[0-9A-F]{8}-[0-9A-F]{4}-/i.freeze

  # The warehouse path the converter builds for a Tableau relation
  # (converter/tableau.mjs extractPath + resolveTableName): brackets and
  # parentheticals stripped, upper-cased, GUID parts (a Hyper extract's
  # dbname) dropped, the table name mapped through table_mapping (trailing
  # '$' extract suffix stripped), then db/schema overridden. Without a
  # resolution the .twb's own named-connection dbname supplies the db.
  def warehouse_path(doc, rel, resolution)
    raw = (rel.attributes['table'] || rel.attributes['name']).to_s
    cleaned = raw.gsub(/[\[\]]/, '').gsub(/\s*\([^)]*\)/, '')
    parts = cleaned.split('.').map { |p| p.strip.upcase }.reject { |p| p.empty? || p =~ GUID_PART }
    parts = [rel.attributes['name'].to_s.upcase] if parts.empty?
    mapping = resolution ? resolution['table_mapping'] : {}
    parts[-1] = resolve_table_name(parts[-1].sub(/_[0-9A-Fa-f]{16,}\z/, ''), mapping)
    db = resolution && resolution['db'] ? resolution['db'].upcase : connection_db(doc, rel)
    schema = resolution && resolution['schema'] ? resolution['schema'].upcase : nil
    parts = [schema] + parts if schema && parts.size == 1
    if db
      parts.size >= 3 ? parts[0] = db : parts.unshift(db)
    end
    if schema
      if parts.size >= 3 then parts[1] = schema
      elsif parts.size == 2 && !db then parts[0] = schema
      end
    end
    parts
  end

  def resolve_table_name(table, mapping)
    stripped = table.sub(/\$+\z/, '')
    hit = mapping.find { |k, _v| [table, stripped].include?(k.to_s.upcase) || [table, stripped].include?(k.to_s.upcase.sub(/\$+\z/, '')) }
    hit ? hit[1].to_s.upcase : stripped
  end

  def connection_db(doc, rel)
    conn_name = rel.attributes['connection'].to_s
    return nil if conn_name.empty?
    db = nil
    doc.elements.each("//named-connection[@name='#{conn_name}']//connection") { |c| db ||= c.attributes['dbname'] }
    db.to_s.empty? || db =~ GUID_PART ? nil : db.upcase
  end

  def tableau_model(doc, resolution = nil)
    tables = []
    relationships = []
    columns = {} # datasource name => { local name => table id }
    calcs = {}   # datasource name => { calc name => formula }
    doc.elements.each('//datasource') do |ds|
      graph = ds.elements['.//object-graph']
      next unless graph
      ds_name = ds.attributes['name'].to_s
      caption = (ds.attributes['caption'] || ds_name).to_s
      objects = {}
      by_relation = {} # relation name => object id (metadata-records without object-id)
      graph.elements.each('.//objects/object') do |obj|
        rel = obj.elements[".//relation[@type='table']"] || obj.elements[".//relation[@type='text']"]
        next unless rel
        objects[obj.attributes['id'].to_s] = relation_table(doc, rel, resolution)
        by_relation[rel.attributes['name'].to_s] = obj.attributes['id'].to_s
      end
      object_token = ->(oid) { "#{OBJECT}#{ds_name}|#{oid}" }
      objects.values.uniq { |t| t[:id] }.each do |t|
        tables << t.merge(datasource: caption) unless tables.any? { |x| x[:id] == t[:id] && x[:datasource] == caption }
      end
      local = {}
      ds.elements.each(".//metadata-record[@class='column']") do |mr|
        name = mr.elements['local-name']&.text.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
        oid = mr.elements['object-id']&.text.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
        parent = mr.elements['parent-name']&.text.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
        oid = by_relation[parent].to_s unless objects[oid]
        table = objects[oid]
        next if name.empty? || table.nil?
        local[name] = { table: table[:id], physical: mr.elements['remote-name']&.text.to_s.upcase,
                        object: object_token.(oid) }
      end
      columns[ds_name] = local
      calcs[ds_name] = {}
      ds.elements.each('column') do |col|
        calc = col.elements['calculation']
        next unless calc
        calcs[ds_name][col.attributes['name'].to_s.sub(/\A\[/, '').sub(/\]\z/, '')] = calc_formula(calc)
      end
      # Sets: their members come from the fields their groupfilters level on.
      ds.elements.each('group') do |group|
        levels = group.elements.to_a('.//groupfilter').map { |gf| gf.attributes['level'].to_s }.reject(&:empty?)
        calcs[ds_name][group.attributes['name'].to_s.sub(/\A\[/, '').sub(/\]\z/, '')] =
          levels.map { |l| "[#{field_ref(l)}]" }.uniq.join(' ')
      end
      graph.elements.each('.//relationships/relationship') do |r|
        first_id = r.elements['first-end-point']&.attributes&.[]('object-id').to_s
        second_id = r.elements['second-end-point']&.attributes&.[]('object-id').to_s
        first = objects[first_id]
        second = objects[second_id]
        next unless first && second
        keys = []
        computed = relationship_conditions(r.elements['expression'], local, keys)
        rel = { 'datasource' => caption, 'left' => first[:id], 'right' => second[:id], 'tableau_keys' => keys }
        rel['computed_conditions'] = computed if computed.positive?
        rel['objects'] = [object_token.(first_id), object_token.(second_id)] if first[:id] == second[:id]
        relationships << rel
      end
    end
    { tables: tables, relationships: relationships, columns: columns, calcs: calcs }
  end

  # Walk a relationship's predicate: AND of conditions. A plain field = field
  # condition becomes a physical key pair; anything else (a function-wrapped
  # side such as DATETRUNC('month',[TS]), a range or other comparison) is a
  # computed condition, counted so the relationship can never read as
  # matched by its physical keys alone. Returns the computed count.
  def relationship_conditions(expr, local, keys)
    return 1 if expr.nil?
    op = expr.attributes['op'].to_s
    children = expr.elements.to_a('expression')
    return children.sum { |child| relationship_conditions(child, local, keys) } if op.casecmp?('AND')
    sides = children.map { |x| x.attributes['op'].to_s[/\A\[([^\]]+)\]\z/, 1] }
    if op == '=' && sides.size == 2 && sides.all?
      keys << { 'left' => physical_key(local, sides[0]), 'right' => physical_key(local, sides[1]) }
      0
    else
      1
    end
  end

  def physical_key(local, name)
    hit = local[name]
    return hit[:physical] unless hit.nil? || hit[:physical].empty?
    name.sub(/\s*\([^)]*\)\s*\z/, '').strip.gsub(/\s+/, '_').upcase
  end

  # Migrated worksheet => Tableau tables whose fields it uses (calcs resolve
  # recursively to the fields they reference).
  def worksheet_tables(doc, source, dashboards)
    sheets = migrated_worksheets(doc, dashboards)
    doc.elements.to_a('//worksheet').each_with_object({}) do |ws, out|
      name = ws.attributes['name'].to_s
      next unless sheets.include?(name)
      used = []
      ws.elements.each('.//datasource-dependencies') do |dd|
        ds_name = dd.attributes['datasource'].to_s
        # Parameters and datasources outside the object-graph model own no
        # object-graph table.
        next unless source[:columns].key?(ds_name)
        dd.elements.each('column') do |col|
          ref = col.attributes['name'].to_s.sub(/\A\[/, '').sub(/\]\z/, '')
          calc = col.elements['calculation']
          used.concat(field_tables(source, ds_name, ref, calc ? calc_formula(calc) : nil, {}))
        end
      end
      out[name] = used.uniq.sort
    end
  end

  # Tables a field reads (plus the OBJECT token of each column it reaches),
  # through calcs / groups / sets. A field that is neither a column nor a calc
  # is UNRESOLVED (unknown usage), except
  # Tableau's own pseudo-fields (:Measure Names, ...). [Parameters].[X] and
  # refs into a datasource outside the object-graph model own no table.
  def field_tables(source, ds_name, ref, formula, seen)
    hit = (source[:columns][ds_name] || {})[ref]
    return [hit[:table], hit[:object]] if hit
    return [] if seen[ref] || ref.start_with?(':')
    formula ||= (source[:calcs][ds_name] || {})[ref]
    # an empty formula (or a group naming no field) is unknown usage too
    return [UNRESOLVED] if formula.nil? || formula.strip.empty?
    seen = seen.merge(ref => true)
    formula.scan(/(?:\[([^\]]+)\]\.)?\[([^\]]+)\]/).uniq.flat_map do |(qualifier, inner)|
      if qualifier.nil? then field_tables(source, ds_name, inner, nil, seen)
      elsif source[:columns].key?(qualifier) then field_tables(source, qualifier, inner, nil, seen)
      else []
      end
    end
  end

  # A calculation's formula; a group (categorical-bin) names its one field in
  # column= instead.
  def calc_formula(calc)
    formula = calc.attributes['formula'].to_s
    return formula unless formula.empty?
    column = calc.attributes['column'].to_s
    column.empty? ? '' : "[#{field_ref(column)}]"
  end

  # [none:PRODUCT_NAME:nk] / [PRODUCT_NAME] -> PRODUCT_NAME
  def field_ref(token)
    name = token.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
    m = name.match(/\A[a-z]+:(.+):[a-z]+\z/)
    m ? m[1] : name
  end

  def migrated_worksheets(doc, dashboards)
    worksheets = doc.elements.to_a('//worksheet').map { |ws| ws.attributes['name'].to_s }
    boards = doc.elements.to_a('/workbook/dashboards/dashboard')
    return worksheets if boards.empty?
    boards.select { |d| dashboards.nil? || dashboards.include?(d.attributes['name'].to_s) }
          .flat_map { |d| d.elements.to_a('.//zone').map { |z| z.attributes['name'].to_s } }
          .select { |n| worksheets.include?(n) }.uniq
  end

  # ---- model side -----------------------------------------------------------

  # A key column's warehouse name. A customer-built model often renames
  # columns, so the formula passthrough ([TABLE/Source Column]) wins over the
  # display name (JoinPlan.dm_column_probe_keys, gate 16's resolution). A key
  # that resolves to several columns keeps its display name, so it neither
  # matches a Tableau key nor reaches SQL unrefused.
  def key_column(el, col_id)
    keys = JoinPlan.dm_column_probe_keys(el, col_id)
    keys.size == 1 ? keys.first.to_s : JoinPlan.dm_column_physical_name(el, col_id).to_s
  end

  def dm_model(dm_spec)
    els = Array(dm_spec.is_a?(Hash) ? dm_spec['pages'] : nil).flat_map { |p| Array(p['elements']) }
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    elements = els.select { |e| %w[warehouse-table sql].include?(e.dig('source', 'kind').to_s) }.map do |e|
      path = Array(e.dig('source', 'path')).map(&:to_s)
      { id: e['id'].to_s, path: path, fqn: path.join('.').upcase,
        sql: e.dig('source', 'kind') == 'sql' ? normalize_sql(e.dig('source', 'statement')) : nil }
    end
    counts = Hash.new(0)
    edges = []
    els.each do |el|
      Array(el['relationships']).each do |rel|
        target = by_id[rel['targetElementId']]
        next unless target
        keys = Array(rel['keys']).map do |k|
          { 'source' => key_column(el, k['sourceColumnId']), 'target' => key_column(target, k['targetColumnId']) }
        end
        id = "#{el['id']}->#{target['id']}"
        counts[id] += 1
        edges << { 'edge_id' => counts[id] > 1 ? "#{id}##{counts[id]}" : id,
                   'source_element' => el['id'].to_s, 'target_element' => target['id'].to_s, 'keys' => keys }
      end
    end
    { elements: elements, edges: edges }
  end
end
