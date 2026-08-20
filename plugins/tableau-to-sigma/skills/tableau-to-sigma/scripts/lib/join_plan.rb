# frozen_string_literal: true
#
# join_plan.rb — derive the JOIN PLAN LEDGER (<workdir>/join-plan.json) for the
# join-cardinality probe (PR-4).
#
# WHY: the converter synthesizes cross-element null-fallback calcs as
#   Coalesce([X], Lookup([Target/X], [key], [Target/key]))
# (see test-join-coalesce-synthesis.rb). Sigma's Lookup() returns ONE ARBITRARY
# match per key — when the Lookup target is NOT unique at the key grain (a
# field run: target at user×date×line-item, key at user×date) every aggregate
# over the looked-up column silently undercounts, with zero errors anywhere.
# The same grain assumption underlies every federated .twb join (an agent
# deleting a "no-op" LEFT JOIN without proof risks fan-out the other way).
#
# The ledger records one entry per (a) .twb source join and (b) synthesized
# Lookup() in the dm-spec, each carrying the grain assumption ("right unique
# on keys") and status "unprobed". scripts/probe-join-keys.rb then PROVES or
# REFUTES each assumption against the warehouse and updates the entry; the
# final gate (assert-phase6-ran.rb gate 16, exit 23) refuses GREEN while any
# entry is unproven or unresolved non-unique.
#
# .twb JOIN SHAPES COVERED (the canonical list converter/tableau.mjs and
# parse-twb-layout.rb read — an EMBEDDED datasource serializes joins with the
# same elements as a published/VC one, but may wrap or relocate them):
#   1. <relation type='join' join='left'> with a <clause type='join'> of
#      <expression op='='> pairs whose sides are '[TABLE].[COL]' (multi-key
#      joins AND-wrap the pairs; a side may be function-wrapped, e.g.
#      DATE([T].[C]) — the computed-key join mechanical-specs.rb recovers).
#   2. The same relation tree behind Tableau's forward-compatibility mangling
#      (_.fcp.ObjectModelEncapsulateLegacy.true...relation — lib/fcp_normalize
#      is applied BEFORE parsing, exactly as parse-twb-layout.rb does; a
#      literal-name XPath is otherwise blind to every embedded-DS join Tableau
#      2020.2+ serializes behind FCP names).
#   3. The 2020.2+ logical (relationship / object-graph) model:
#      <object-graph><relationships><relationship> with <expression op='='>
#      key pairs and first/second-end-point object ids — Tableau culls these
#      joins per-viz at query time, so a Sigma join/Lookup over the same
#      tables carries the identical fan-out risk and MUST be on the ledger.
#
# An EMPTY ledger is still written — its presence is the gate's evidence that
# the derivation ran and found nothing.
#
# Entry shape:
#   { "kind"             => "federated-join" | "lookup-synthesis",
#     "left"             => <left table / source element name>,
#     "right"            => <right table / Lookup target element name>,
#     "keys"             => [<right-side key column name>, ...],
#     "grain_assumption" => "right unique on keys",
#     "status"           => "unprobed",         # probe: unique|non-unique|error
#     "right_table"      => "DB.SCHEMA.TABLE",  # probe target FQN when derivable
#     "right_sql"        => "SELECT ...",       # Custom-SQL Lookup target: the
#                                               #   statement (right_table null;
#                                               #   probed as a subquery)
#     "probe_keys"       => [...],              # physical columns to GROUP BY
#     "derived_via"      => "serialized" | "name-inference",  # object-graph
#                                               #   entries only (see below):
#                                               #   Ruby snake_case of the
#                                               #   converter's derivedVia —
#                                               #   PROOF that an inferred key
#                                               #   gets probed, not trusted.
#     "partial"          => true,               # object-graph, serialized-only:
#                                               #   a mixed physical+computed
#                                               #   key kept the physical half
#     "dropped_conditions" => 1,                # count of computed conditions
#                                               #   dropped from a partial key
#     ... }                                     # + per-kind provenance fields
#
# derived_via/partial/dropped_conditions PROVENANCE: gate 16's probe (below)
# proves a key's grain-assumption (right unique on keys) against the
# warehouse regardless of provenance — it does NOT and CANNOT prove a key is
# the CORRECT one, only that it does not fan out. derived_via exists so an
# inferred key is visible to that probe AND to a human/gate reading the
# ledger afterward — it is not itself a correctness check.
#
# Ruby 2.6-compatible. Offline (no network); parsing via lib/twb_xml.rb
# (Nokogiri when present, REXML fallback — same as the other .twb parsers).

require 'json'
require_relative 'twb_xml'
require_relative 'fcp_normalize'
require_relative 'sql_ident_check' # single identifier-legality oracle (W2.9)

module JoinPlan
  GRAIN_ASSUMPTION = 'right unique on keys'

  module_function

  # dm_spec: parsed dm-spec Hash (or nil). twb_xml: raw .twb XML String (or nil).
  # db/schema: the run's resolved warehouse database/schema (--db/--schema or the
  # orchestrator's manifest/workbook derivation) — used to complete published-VC
  # physical paths into probeable FQNs (see vc_physical_fqn). Returns the entry
  # array (possibly empty). Deterministic order: federated join-clause joins
  # (document order), then object-graph relationship joins (document order),
  # then lookup syntheses (element order).
  def derive(dm_spec, twb_xml = nil, db: nil, schema: nil)
    entries = []
    entries.concat(federated_joins(twb_xml, db, schema, dm_spec)) if twb_xml && !twb_xml.to_s.strip.empty?
    entries.concat(lookup_syntheses(dm_spec)) if dm_spec.is_a?(Hash)
    entries
  end

  # The run's .twb straight from the workdir — for callers whose own .twb
  # bookkeeping is route-dependent. FASTPATH live defect (Twin-B e2e
  # 2026-07-19): migrate-tableau's have_twb is assigned inside the
  # full-pipeline block only, so the FAST PATH (--reuse-dm + --wb-spec) passed
  # twb_xml=nil even though workbook-content.twb sat in the workdir — the
  # source LEFT JOIN never landed in the ledger, gate 16 passed on an EMPTY
  # ledger, and the DM shipped without the join (every tile diverged 3-23x).
  # Returns the XML String, or nil when no .twb exists (MCP-only datasource).
  def workdir_twb(workdir)
    return nil if workdir.to_s.empty?
    %w[workbook-content.twb workbook-hydrated.twb].each do |name|
      p = File.join(workdir, name)
      return File.read(p, encoding: 'UTF-8') if File.exist?(p)
    end
    nil
  end

  def write(path, entries)
    File.write(path, JSON.pretty_generate(
                       'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                       'grain_note'   => 'Sigma Lookup() returns one arbitrary match per key; a non-unique ' \
                                         'right side silently undercounts every aggregate over the looked-up column.',
                       'entries'      => entries
                     ))
    path
  end

  # ---- (a) federated joins in the .twb --------------------------------------
  # Shapes 1-3 from the header. FCP names are normalized FIRST (same as
  # parse-twb-layout.rb) so `//relation[@type='join']` and `//object-graph`
  # also match the _.fcp.ObjectModelEncapsulateLegacy-wrapped trees an
  # embedded datasource serializes. Multi-key joins AND-wrap the '=' pairs;
  # the descendant scans handle both shapes.
  # dm_spec (optional): threaded through to object_graph_joins so a
  # name-inferred object-graph relationship (no <expression> at all in the
  # .twb for THIS method's own XML scan to find) still lands on the ledger —
  # see object_graph_joins / dm_object_graph_index below.
  def federated_joins(twb_xml, db = nil, schema = nil, dm_spec = nil)
    xml = twb_xml.to_s.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
    xml = FcpNormalize.normalize(xml) if FcpNormalize.needed?(xml)
    doc = begin
      TwbXml.parse(xml)
    rescue StandardError
      return []
    end
    # Table relations by name (for the right side's warehouse FQN).
    table_rels = {}
    doc.elements.each("//relation[@type='table']") do |r|
      table_rels[r.attributes['name'].to_s] ||= r
    end
    captions = guid_caption_index(doc)
    out = []
    doc.elements.each("//relation[@type='join']") do |rel|
      # Only THIS join's clause (an immediate child) — a nested join carries its
      # own <clause> and gets its own ledger entry from the same document scan.
      pairs = [] # [{left table, left col, right table, right col}]
      rel.elements.each("clause[@type='join']//expression[@op='=']") do |eq|
        # unwrap_fn: a computed-key side (DATE([T].[C]) = [T2].[C2]) still
        # names its physical column — record it rather than dropping the join.
        sides = eq.elements.to_a('expression').map { |e| parse_side(unwrap_fn(e.attributes['op'])) }.compact
        pairs << { l: sides[0], r: sides[1] } if sides.size == 2
      end
      next if pairs.empty?
      left  = pairs.first[:l][:table]
      right = pairs.first[:r][:table]
      keys  = pairs.select { |p| p[:l][:table] == left && p[:r][:table] == right }
      next if keys.empty?
      out << {
        'kind'             => 'federated-join',
        'join_type'        => (rel.attributes['join'] || 'inner').to_s,
        'left'             => left,
        'right'            => right,
        'keys'             => keys.map { |p| p[:r][:column] },
        'key_pairs'        => keys.map { |p| { 'left' => p[:l][:column], 'right' => p[:r][:column] } },
        'grain_assumption' => GRAIN_ASSUMPTION,
        'status'           => 'unprobed',
        'right_table'      => vc_physical_fqn(right, db, schema) || twb_table_fqn(doc, table_rels[right]),
        'probe_keys'       => keys.map { |p| physical_probe_key(p[:r][:column], captions) }
      }
    end
    out.concat(object_graph_joins(doc, captions, db, schema, dm_spec))
    out
  end

  # ---- 2020.2+ logical (relationship / object-graph) joins ------------------
  # <object-graph><relationships><relationship> with <expression op='='> key
  # pairs (AND-wrapped when multi-key) between <first-end-point object-id=>
  # and <second-end-point object-id=>. Sides are bare '[COL]' / '[<guid>]'
  # refs (optionally function-wrapped — converter parseOpRef semantics), NOT
  # '[TABLE].[COL]'. Tableau culls these joins per-viz at query time; a Sigma
  # relationship/Lookup over the same tables fans out unless the second
  # end-point is unique on the keys — same grain assumption, same probe.
  # dm_spec (optional, see federated_joins): a name-inferred relationship has
  # NO <expression> at all in the .twb (Tableau auto-matches it at query
  # time), so this method's own XML-only pair extraction finds nothing for
  # it — the exact gap this task closes. When the converter's dm_spec is
  # available, dm_object_graph_index recovers what it actually wired (keys +
  # derivedVia) so the relationship still lands on the ledger instead of
  # being silently absent (worse than "trusted": nothing to probe at all).
  # Without dm_spec (nil — e.g. the --reuse-dm path's live-readback spec,
  # which does not round-trip these custom fields through the Sigma API),
  # behavior is UNCHANGED from before this task: a relationship with no
  # physical <expression> is skipped, same as always.
  def object_graph_joins(doc, captions, db = nil, schema = nil, dm_spec = nil)
    # object-id -> its physical <relation type='table'> (label + node).
    objects = {}
    doc.elements.each('//object-graph/objects/object') do |obj|
      rel = obj.elements[".//relation[@type='table']"]
      next unless rel
      objects[obj.attributes['id'].to_s] = {
        label: (obj.attributes['caption'] || rel.attributes['name']).to_s,
        name:  rel.attributes['name'].to_s,
        rel:   rel
      }
    end
    dm_index = dm_object_graph_index(dm_spec)
    out = []
    doc.elements.each('//object-graph/relationships/relationship') do |r|
      first  = r.elements['first-end-point']
      second = r.elements['second-end-point']
      next unless first && second
      lobj = objects[first.attributes['object-id'].to_s]
      robj = objects[second.attributes['object-id'].to_s]
      next unless lobj && robj
      left  = lobj[:name].empty? ? lobj[:label] : lobj[:name]
      right = robj[:name].empty? ? robj[:label] : robj[:name]
      eq_nodes = r.elements.to_a(".//expression[@op='=']")
      pairs = []
      eq_nodes.each do |eq|
        sides = eq.elements.to_a('expression').map { |e| unwrap_fn(e.attributes['op']) }
                  .map { |op| op.to_s[/\A\[([^\]]+)\]\z/, 1] }.compact
        pairs << { l: sides[0], r: sides[1] } if sides.size == 2
      end
      dm_rel      = dm_index[[left, right]]
      right_table = vc_physical_fqn(right, db, schema) || twb_table_fqn(doc, robj[:rel])
      if pairs.empty?
        # No physical key survives the .twb's own <expression> scan — either
        # there was none at all (auto-matched) or every condition present is
        # purely computed. Nothing to probe UNLESS the converter recovered a
        # key by name-inference (dm_rel); if it didn't either, this
        # relationship genuinely never got wired into the model — there is no
        # join for gate 16 to probe, so (as before) no ledger entry.
        next unless dm_rel
        out << {
          'kind'             => 'federated-join',
          'join_type'        => 'relationship',
          'shape'            => 'object-graph',
          'left'             => left,
          'right'            => right,
          'keys'             => dm_rel[:keys],
          'key_pairs'        => dm_rel[:keys].map { |k| { 'left' => k, 'right' => k } },
          'grain_assumption' => GRAIN_ASSUMPTION,
          'status'           => 'unprobed',
          'right_table'      => right_table,
          'probe_keys'       => dm_rel[:keys],
          'derived_via'      => dm_rel[:derived_via]
        }
        next
      end
      entry = {
        'kind'             => 'federated-join',
        'join_type'        => 'relationship',
        'shape'            => 'object-graph',
        'left'             => left,
        'right'            => right,
        'keys'             => pairs.map { |p| p[:r] },
        'key_pairs'        => pairs.map { |p| { 'left' => p[:l], 'right' => p[:r] } },
        'grain_assumption' => GRAIN_ASSUMPTION,
        'status'           => 'unprobed',
        'right_table'      => right_table,
        'probe_keys'       => pairs.map { |p| relationship_probe_key(p[:r], captions) }
      }
      # A physical pair was found, so this is necessarily the converter's
      # "serialized" branch (name-inference only fires when NO physical pair
      # survives — the pairs.empty? branch above). Prefer dm_rel's own count
      # of dropped computed conditions when available (the converter's own
      # isPhysical bookkeeping); fall back to this method's local count
      # (total '=' expressions found minus the physical pairs kept) so the
      # field is still populated when dm_spec is unavailable.
      entry['derived_via'] = (dm_rel && dm_rel[:derived_via]) || 'serialized'
      dropped = (dm_rel && dm_rel[:dropped_conditions]) || (eq_nodes.size - pairs.size)
      if (dm_rel && dm_rel[:partial]) || dropped.to_i.positive?
        entry['partial']            = true
        entry['dropped_conditions'] = dropped
      end
      out << entry
    end
    out
  end

  # Index of ACTUALLY-WIRED object-graph relationships from the converter's
  # dm_spec, keyed by [left element name, right element name] — the SAME two
  # names object_graph_joins' own .twb-only extraction resolves (both derive
  # from the physical warehouse table name: the .twb's
  # <relation type='table' name=...> on this side, element_name()'s
  # source.path.last on the dm_spec side — see converter/tableau.mjs's
  # cleanName = path[path.length - 1]). An "unwired" relationship is NEVER in
  # this index: the converter only ever pushes a relationship onto
  # element['relationships'] once it is wired (see converter/tableau.mjs
  # wireInferred / the serialized branch) — an unwired one is recorded only
  # in the converter's OWN relationshipCoverage report, a different artifact
  # (see emit-relationship-coverage.rb), never here. nil/malformed dm_spec
  # (or one with no such relationship) yields no entry for that pair — the
  # caller's pairs.empty? branch then correctly treats it as unwired.
  def dm_object_graph_index(dm_spec)
    idx = {}
    return idx unless dm_spec.is_a?(Hash)
    els   = (dm_spec['pages'] || []).flat_map { |p| p['elements'] || [] }
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    els.each do |el|
      (el['relationships'] || []).each do |rel|
        next unless rel.is_a?(Hash) && rel['derivedVia']
        tgt        = by_id[rel['targetElementId']]
        right_name = (rel['name'] || (tgt && element_name(tgt))).to_s
        next if right_name.empty?
        keys = (rel['keys'] || []).map { |k| dm_column_physical_name(tgt, k['targetColumnId']) }.compact
        next if keys.empty?
        idx[[element_name(el), right_name]] = {
          derived_via:        rel['derivedVia'],
          partial:            rel['partial'] == true,
          dropped_conditions: rel['droppedConditions'],
          keys:               keys
        }
      end
    end
    idx
  end

  # A dm_spec column's PHYSICAL (warehouse) name: its explicit display `name`
  # when set (real metadata-record columns carry one), else parsed from its
  # `[Element/Display Name]` formula (a column ensureCol fabricated carries
  # no `name`) — folded upcase+underscore via physical_name, same convention
  # every other probe-key resolution in this file uses.
  def dm_column_physical_name(el, col_id)
    return nil unless el && col_id
    col = (el['columns'] || []).find { |c| c['id'] == col_id }
    return nil unless col
    disp = col['name'] || (col['formula'].is_a?(String) && col['formula'][/\/([^\]]+)\]\z/, 1])
    disp && physical_name(disp)
  end

  # A relationship key is a bare column ref: a GUID resolves via caption (as
  # physical_probe_key), anything else folds display -> physical directly
  # ('Entity Id' -> ENTITY_ID; an already-physical 'ENTITY_ID' is a no-op).
  # Role parentheticals are stripped BEFORE folding (see strip_role_paren).
  def relationship_probe_key(key, captions)
    # Duplicate logical-table roles suffix the field id itself, e.g.
    #   <guid> (DATE_DIM (DEMO_SCHEMA.DATE_DIM)1)
    # That whole token is not GUID-shaped, but the datasource's column census
    # carries an exact caption for it. Prefer exact caption evidence before
    # falling back to the plain-GUID and display-name paths.
    caption = captions[key.to_s.downcase]
    return physical_name(strip_role_paren(caption)) if caption
    guid_like?(key) ? physical_probe_key(key, captions) : physical_name(strip_role_paren(key))
  end

  # 'FN([X])' / 'FN([T].[C])' -> the inner bracketed ref (converter
  # extractOpUuid semantics — a computed-key join side, e.g. DATE([T].[C]));
  # anything else passes through unchanged.
  def unwrap_fn(op)
    m = op.to_s.match(/\A\w+\((\[.+\])\)\z/)
    m ? m[1] : op
  end

  # ---- published/virtual-connection resolution ------------------------------
  # A workbook backed by a Tableau published/virtual connection carries no
  # metadata-records: its relation labels read 'NAME (DB.TABLE)' or
  # 'NAME (DB.SCHEMA.TABLE)', and its named-connection dbname is the VC inode
  # GUID — so twb_table_fqn yields '<inode-guid>.NAME (X.TABLE)', which the probe
  # cannot query (live e2e: every VC entry errored, exit 3, instead of
  # measuring). Extract the parenthesized physical path and complete it with
  # the run's resolved db/schema. When neither resolution works we return nil
  # and the caller keeps the old FQN — the probe errors and the gate keeps
  # blocking, the safe direction.
  # Tableau appends a numeric role suffix after the closing physical-path
  # parenthesis when the same logical table appears more than once:
  #   DATE_DIM (DEMO_SCHEMA.DATE_DIM)1
  # The suffix identifies the role, not a warehouse table.
  VC_LABEL_RE = /\(\s*([A-Za-z0-9_$]+(?:\.[A-Za-z0-9_$]+){1,2})\s*\)\d*\s*\z/

  def vc_physical_fqn(label, db, schema)
    m = label.to_s.match(VC_LABEL_RE)
    return nil unless m
    parts = m[1].split('.')
    return parts.join('.') if parts.size == 3 # 'DB.SCHEMA.TABLE' — already full
    return nil if db.to_s.empty?
    if parts[0].casecmp(db.to_s).zero?
      # 'DB.TABLE' where the label already names the run database — add schema.
      schema.to_s.empty? ? nil : [db, schema, parts[1]].join('.')
    else
      # 'SCHEMA.TABLE' — prepend the run database.
      [db, parts[0], parts[1]].join('.')
    end
  end

  # GUID-like Tableau internal field ids: the canonical hex 8-4-4-4-12 shape,
  # plus the looser long hex-hyphen inode-tail shape mechanical-specs.rb's
  # guid_display_index accepts. The shape itself lives in the single legality
  # oracle (SqlIdentCheck.guid_shaped? — W2.9); this name is kept for callers.
  def guid_like?(s)
    SqlIdentCheck.guid_shaped?(s)
  end

  # GUID column id -> caption, from every <column caption= name='[<guid>]'> in
  # the .twb. Published-VC workbooks name columns by Tableau field GUID and
  # carry no metadata-records — the caption is the only handle on the physical
  # column.
  def guid_caption_index(doc)
    idx = {}
    doc.elements.each('//column[@caption]') do |c|
      name = c.attributes['name'].to_s.sub(/\A\[/, '').sub(/\]\z/, '')
      # A duplicate logical-table role preserves the physical GUID at the
      # start, then appends " (role-name)N". Index both the exact role token
      # and its base GUID, but reject unrelated strings that merely begin with
      # 36 GUID-looking characters.
      base = name[0, 36]
      suffix = name[36..].to_s
      next unless guid_like?(base)
      next unless suffix.empty? || suffix.match?(/\A\s+\(.+\)\d*\z/)
      cap = c.attributes['caption'].to_s
      unless cap.empty?
        idx[name.downcase] ||= cap
        idx[base.downcase] ||= cap
      end
    end
    idx
  rescue StandardError
    {}
  end

  # Physical GROUP BY column for a federated-join key. A published-VC key is a
  # Tableau field GUID (no physical column of that name exists): resolve it via
  # the .twb caption, then fold caption -> physical with the SAME
  # upcase+underscore folding the phantom-column filter uses
  # (mechanical-specs.rb fixup_dm_spec / physical_name below — do not diverge).
  # The caption's trailing role parenthetical is display-only — stripped before
  # the fold (W2.9). An unresolvable GUID stays as-is: emission REFUSES it
  # (SqlIdentCheck — clean 'error', routed to --resolve), the gate blocks (safe).
  def physical_probe_key(key, captions)
    return key unless guid_like?(key)
    cap = captions[key.to_s.downcase]
    cap ? physical_name(strip_role_paren(cap)) : key
  end

  # '[TABLE].[COL]' -> {table:, column:}; anything else -> nil.
  def parse_side(op)
    m = op.to_s.match(/\A\[([^\]]+)\]\.\[([^\]]+)\]\z/)
    m && { table: m[1], column: m[2] }
  end

  # DB.SCHEMA.TABLE for a <relation type='table'> — schema+table from its
  # table='[SCHEMA].[TABLE]' attr, database from the named-connection it names.
  def twb_table_fqn(doc, rel)
    return nil unless rel
    parts = rel.attributes['table'].to_s.scan(/\[([^\]]+)\]/).flatten
    parts = [rel.attributes['name'].to_s] if parts.empty?
    conn_name = rel.attributes['connection'].to_s
    db = nil
    unless conn_name.empty?
      doc.elements.each("//named-connection[@name='#{conn_name}']//connection") do |c|
        db ||= c.attributes['dbname']
      end
    end
    ([db] + parts).compact.reject { |s| s.to_s.empty? }.join('.')
  end

  # ---- (b) synthesized Lookup()s in the dm-spec -----------------------------
  # Scan every element's column formulas for
  #   Lookup([Target/Col], [source key], [Target/target key])
  # and record one entry per distinct (source element, target element, key set),
  # aggregating the columns that depend on it.
  LOOKUP_RE = /Lookup\(\s*\[([^\]\/]+)\/([^\]]+)\]\s*,\s*\[([^\]]+)\]\s*,\s*\[([^\]\/]+)\/([^\]]+)\]\s*\)/

  def lookup_syntheses(dm_spec)
    els = (dm_spec['pages'] || []).flat_map { |p| p['elements'] || [] }
    by_name = {}
    els.each { |e| by_name[element_name(e)] = e }
    seen = {}
    order = []
    els.each do |el|
      (el['columns'] || []).each do |col|
        f = col['formula'].to_s
        next unless f.include?('Lookup(')
        f.scan(LOOKUP_RE) do |target, _tcol, src_key, target2, tgt_key|
          next unless target == target2 # malformed / cross-target — leave to validators
          sig = [element_name(el), target, tgt_key]
          entry = seen[sig]
          unless entry
            tgt_el = by_name[target]
            entry = {
              'kind'             => 'lookup-synthesis',
              'left'             => element_name(el),
              'right'            => target,
              'keys'             => [tgt_key],
              'source_key'       => src_key,
              'grain_assumption' => GRAIN_ASSUMPTION,
              'status'           => 'unprobed',
              'right_table'      => element_table_fqn(tgt_el),
              'probe_keys'       => resolve_probe_keys(tgt_el, tgt_key),
              'columns'          => []
            }
            # Custom-SQL Lookup target: no warehouse path exists (right_table
            # stays null) — record the statement so probe-join-keys.rb can
            # measure the grain by probing it as a subquery.
            if tgt_el && tgt_el.dig('source', 'kind') == 'sql'
              stmt = tgt_el.dig('source', 'statement').to_s
              entry['right_sql'] = stmt unless stmt.strip.empty?
            end
            seen[sig] = entry
            order << entry
          end
          entry['columns'] << (col['name'] || col['id']).to_s unless entry['columns'].include?((col['name'] || col['id']).to_s)
        end
      end
    end
    order
  end

  def element_name(el)
    n = el['name'].to_s
    return n unless n.empty?
    path = el.dig('source', 'path')
    path.is_a?(Array) ? path.last.to_s : el['id'].to_s
  end

  def element_table_fqn(el)
    path = el && el.dig('source', 'path')
    path.is_a?(Array) ? path.join('.') : nil
  end

  # Physical GROUP BY columns for the probe. A synthesized composite key
  # ('Daily Contra Join Key' = Text([A]) & "|" & Text([B])) is a CALC column
  # that does not exist in the warehouse — unwrap its bracket refs to the base
  # columns instead. Display names map to physical via the converter's
  # upcase+underscore convention ('Entity Id' -> ENTITY_ID).
  def resolve_probe_keys(tgt_el, tgt_key)
    col = tgt_el && (tgt_el['columns'] || []).find { |c| (c['name'] || '').to_s == tgt_key }
    f = col && col['formula'].to_s
    if f && f =~ /&|\|\|/ && f.include?('Text(')
      refs = f.scan(/\[([^\]\/]+)\]/).flatten.uniq
      return refs.map { |r| physical_name(strip_role_paren(r)) } unless refs.empty?
    end
    [physical_name(strip_role_paren(tgt_key))]
  end

  # Tableau disambiguates same-named fields across joined objects by suffixing
  # the DISPLAY label with the object name in parens — 'Product Key (Product
  # Dim)', nested when the object itself is renamed: 'Product Key (Product Dim
  # (Extract))'. That parenthetical is display-only; folding it into the
  # physical identifier emitted PRODUCT_KEY_(PRODUCT_DIM)-shaped SQL (field-
  # measured: HTTP 400 on every gate-16 probe → re-entry). Strip ONE balanced
  # trailing parenthetical before display->physical folding. The ledger keeps
  # the display label verbatim in `keys`; only `probe_keys` (the physical side)
  # is stripped. Conservative on purpose: a label that is ONLY a parenthetical,
  # or unbalanced, passes through unchanged — emission then REFUSES anything
  # still illegal (SqlIdentCheck, refuse-don't-guess), never guessing into SQL.
  def strip_role_paren(display)
    s = display.to_s.rstrip
    return display unless s.end_with?(')')
    depth = 0
    i = s.length - 1
    while i >= 0
      case s[i]
      when ')' then depth += 1
      when '(' then depth -= 1
      end
      break if depth.zero?
      i -= 1
    end
    return display if i <= 0 # unbalanced, or the whole label is '(...)'
    rest = s[0...i].rstrip
    rest.empty? ? display : rest
  end

  def physical_name(display)
    display.to_s.strip.gsub(/\s+/, '_').upcase
  end
end
