# frozen_string_literal: true

# warehouse_fqn_resolver.rb — derive the warehouse database/schema from
# FULLY-QUALIFIED relation/table names when the workbook's <connection> carries
# no dbname=/schema= (published datasource / virtual connection field case).
#
#   twb:  <relation name='DIM_A' table='[SCHEMA_A].[DIM_A]' type='table'/>
#         <relation ... table='DB.SCHEMA_A.DIM_A' .../>
#   csv:  header  Region (DIM_A (SCHEMA_A.DIM_A))
#
# Rule (never guess): the evidence must agree on ONE schema. Database comes
# only from 3-part names (or the caller's Sigma-connection default database
# when evidence names a schema but no database). Multiple schemas, or multiple
# databases, are AMBIGUOUS: report the candidates and let the caller hard-stop.
require 'uri'

module WarehouseFqn
  RELATION_RE = /<relation\b[^>]*?\btable\s*=\s*(?:'([^']*)'|"([^"]*)")/m.freeze
  CSV_FQN_RE  = /\(\s*([\w$]+(?:\.[\w$]+){1,2})\s*\)/.freeze

  module_function

  def unescape(s)
    s.to_s.gsub('&apos;', "'").gsub('&quot;', '"').gsub('&lt;', '<').gsub('&gt;', '>').gsub('&amp;', '&')
  end

  # "[A].[B].[C]" / "A.B.C" / "\"A\".\"B\"" -> ["A","B","C"]
  def split_parts(str)
    parts = str.to_s.scan(/\[([^\]]+)\]|"([^"]+)"|([^.\[\]"\s]+)/).map { |a| a.compact.first }
    parts.map { |p| p.to_s.strip }.reject(&:empty?)
  end

  # parts -> [db_or_nil, schema] or nil (unqualified / over-qualified).
  def pair_from(parts)
    case parts.length
    when 3 then [parts[0], parts[1]]
    when 2 then [nil, parts[0]]
    end
  end

  UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/.freeze
  # Virtual-connection display name: "ORDER_FACT (DB_OR_SCHEMA.ORDER_FACT)".
  VC_NAME_RE = /\A\s*([\w$]+)\s*\(\s*([\w$]+(?:\.[\w$]+){1,2})\s*\)\s*\z/.freeze

  # A virtual-connection relation serializes as
  #   table='[<vc-table-uuid>].[FACT_A (DB_A.FACT_A)]'
  # — the UUID is the VC's table id, NOT a schema (the live proof read seven
  # UUIDs as seven "schemas" and hard-stopped as ambiguous). The display
  # name's qualifier is the evidence; returns its parts or nil.
  def vc_qualifier(tbl)
    parts = split_parts(tbl)
    name = parts.last.to_s
    if parts.length == 2 && parts.first.match?(UUID_RE)
      m = name.match(VC_NAME_RE)
      return m ? m[2].split('.') : []
    end
    nil
  end

  def twb_pairs(text)
    out = []
    text.to_s.scan(RELATION_RE) do |a, b|
      tbl = unescape(a || b)
      next unless vc_qualifier(tbl).nil? # VC relations are qualifier evidence (vc_refs), not schema pairs
      next if tbl =~ /\s/ && tbl !~ /\[/ # prose / SQL-ish, not an identifier path
      pr = pair_from(split_parts(tbl))
      out << pr if pr
    end
    out
  end

  # Virtual-connection references: { qual: [..parts before table], table: } for
  # every VC relation / qualified export header. A 3-part qualifier is
  # db.schema.table; a 2-part "Q.TABLE" names the database OR the schema — the
  # VC drops one level (live proof: "DB_A.FACT_A" lives at DB_A.SCHEMA_A.FACT_A,
  # DB_A being the DATABASE) — so it is resolved against the Sigma connection
  # catalog, never assumed.
  def vc_refs(text, headers = [])
    refs = []
    text.to_s.scan(RELATION_RE) do |a, b|
      q = vc_qualifier(unescape(a || b))
      refs << { qual: q[0..-2], table: q[-1] } if q && q.length >= 2
    end
    Array(headers).each do |h|
      h.to_s.scan(CSV_FQN_RE) do |(fqn)|
        parts = fqn.split('.')
        refs << { qual: parts[0..-2], table: parts[-1] } if parts.length >= 2
      end
    end
    refs.uniq { |r| [r[:qual].map(&:upcase), r[:table].upcase] }
  end

  # Match VC refs against the connection catalog: 3-part [db, schema, table]
  # paths whose table is a VC table and whose db or schema equals the VC
  # qualifier (or BOTH, for a 3-part qualifier). A (db, schema) pair must hold
  # EVERY referenced table; exactly one such pair resolves, more is ambiguous.
  def catalog_decide(refs, paths, hint_db: nil, hint_schema: nil)
    return { status: :none, candidates: [] } if refs.empty?
    want = refs.map { |r| r[:table].upcase }.uniq
    quals = refs.map { |r| r[:qual].map(&:upcase) }.uniq
    by_pair = Hash.new { |h, k| h[k] = {} }
    Array(paths).each do |pth|
      next unless pth.is_a?(Array) && pth.length == 3
      d, sc, t = pth.map(&:to_s)
      next unless want.include?(t.upcase)
      next if hint_db && !d.casecmp?(hint_db.to_s)
      next if hint_schema && !sc.casecmp?(hint_schema.to_s)
      ok = quals.any? do |q|
        q.length >= 2 ? (q[-2] == d.upcase && q[-1] == sc.upcase) : (q[0] == d.upcase || q[0] == sc.upcase)
      end
      next unless ok
      by_pair[[d, sc]][t.upcase] = true
    end
    full = by_pair.select { |_, ts| want.all? { |t| ts[t] } }.keys
    if full.size == 1
      return { status: :resolved, db: full[0][0], schema: full[0][1], candidates: full,
               source: "virtual-connection qualifier #{quals.map { |q| q.join('.') }.join(', ')} + Sigma connection catalog " \
                       "(all #{want.size} table(s) found under #{full[0].join('.')})" }
    end
    return { status: :ambiguous, candidates: full, vc: true } if full.size > 1
    { status: :vc_unresolved, candidates: by_pair.keys, quals: quals, tables: want }
  end

  # Page the Sigma connection catalog (GET /v2/connections/paths) through
  # `request` (a ->(path) { parsed_json } callable). Bounded; returns
  # [paths, complete?].
  def list_catalog_paths(connection_id, request, max_pages: 200)
    out = []
    page = nil
    max_pages.times do
      q = "connectionId=#{connection_id}&limit=500"
      if page
        enc = page.to_s.include?('%') ? page.to_s : URI.encode_www_form_component(page.to_s)
        q += "&page=#{enc}"
      end
      body = request.call("/v2/connections/paths?#{q}")
      return [out, false] unless body.is_a?(Hash)
      Array(body['entries']).each { |e| out << e['path'] if e.is_a?(Hash) && e['path'].is_a?(Array) }
      return [out, true] unless body['hasMore'] && body['nextPage']
      page = body['nextPage']
    end
    [out, false]
  end

  def csv_pairs(headers)
    out = []
    Array(headers).each do |h|
      h.to_s.scan(CSV_FQN_RE) do |(fqn)|
        pr = pair_from(fqn.split('.'))
        out << pr if pr
      end
    end
    out
  end

  # Raw pairs -> verdict. Compare case-insensitively, report first-seen casing.
  def decide(pairs, default_db: nil)
    pairs = pairs.compact
    return { status: :none, candidates: [] } if pairs.empty?
    cands = pairs.each_with_object({}) { |(d, s), h| h["#{d.to_s.upcase}|#{s.to_s.upcase}"] ||= [d, s] }.values
    schemas = cands.map { |_, s| s.to_s.upcase }.uniq
    dbs     = cands.map(&:first).compact.map { |d| d.to_s.upcase }.uniq
    if schemas.length > 1 || dbs.length > 1
      return { status: :ambiguous, candidates: cands }
    end
    schema = cands.find { |_, s| s }[1]
    db = cands.map(&:first).compact.first
    return { status: :resolved, db: db, schema: schema, source: 'fully-qualified relation names', candidates: cands } if db
    if default_db.to_s.empty?
      { status: :schema_only, schema: schema, candidates: cands }
    else
      { status: :resolved, db: default_db.to_s, schema: schema,
        source: 'fully-qualified relation names + Sigma connection default database', candidates: cands }
    end
  end

  # Gather evidence from a workdir (.twb/.tds text + views/*.csv headers).
  def gather(workdir, twb_path: nil)
    paths = [twb_path, *Dir.glob(File.join(workdir.to_s, '*.twb')), *Dir.glob(File.join(workdir.to_s, '*.tds'))]
            .compact.uniq.select { |p| File.file?(p) }
    pairs = paths.flat_map { |p| twb_pairs((File.read(p, encoding: 'UTF-8') rescue '')) }
    headers = Dir.glob(File.join(workdir.to_s, 'views', '*.csv')).first(20).flat_map do |p|
      File.open(p, 'r:bom|utf-8', &:gets).to_s.chomp.split(',') rescue []
    end
    pairs + csv_pairs(headers)
  end

  def gather_vc_refs(workdir, twb_path: nil)
    paths = [twb_path, *Dir.glob(File.join(workdir.to_s, '*.twb')), *Dir.glob(File.join(workdir.to_s, '*.tds'))]
            .compact.uniq.select { |p| File.file?(p) }
    headers = Dir.glob(File.join(workdir.to_s, 'views', '*.csv')).first(20).flat_map do |p|
      File.open(p, 'r:bom|utf-8', &:gets).to_s.chomp.split(',') rescue []
    end
    paths.flat_map { |p| vc_refs((File.read(p, encoding: 'UTF-8') rescue ''), []) }
         .concat(vc_refs('', headers))
         .uniq { |r| [r[:qual].map(&:upcase), r[:table].upcase] }
  end

  # catalog_lookup: ->() { [paths, complete?] } over the Sigma connection
  # catalog (nil offline). hint_db / hint_schema: a lone --db or --schema flag.
  def resolve(workdir, twb_path: nil, default_db_lookup: nil, catalog_lookup: nil, hint_db: nil, hint_schema: nil)
    pairs = gather(workdir, twb_path: twb_path)
    refs = gather_vc_refs(workdir, twb_path: twb_path)
    plain = pairs - csv_pairs_from_refs(refs)
    first = decide(plain)
    return first if first[:status] == :resolved && first[:db]
    if refs.any? && catalog_lookup
      cat_paths, complete = begin
        catalog_lookup.call
      rescue StandardError
        [nil, false]
      end
      if cat_paths
        cat = catalog_decide(refs, cat_paths, hint_db: hint_db, hint_schema: hint_schema)
        cat[:catalog_complete] = complete
        return cat if cat[:status] == :resolved && complete
        if cat[:status] == :resolved
          # truncated scan: one full match is a lead, not proof another schema
          # holds the same tables — stop with the exact flag line instead.
          return cat.merge(status: :vc_unresolved, lead: [cat[:db], cat[:schema]])
        end
        return cat
      end
    end
    first = decide(pairs)
    return first unless first[:status] == :schema_only
    dd = begin
      default_db_lookup&.call
    rescue StandardError
      nil
    end
    decide(pairs, default_db: dd)
  end

  # The CSV-header pairs that are really VC qualifiers (excluded from the
  # plain-pair verdict when the catalog can judge them).
  def csv_pairs_from_refs(refs)
    refs.select { |r| r[:qual].length == 1 }.map { |r| [nil, r[:qual][0]] }
  end

  # The hard-stop block's candidate lines + exact flag line.
  def describe(res)
    cands = res[:candidates].map { |d, s| d ? "#{d}.#{s}" : "(database unknown).#{s}" }
    flag = case res[:status]
           when :schema_only then "--db <DATABASE> --schema #{res[:schema]}"
           when :ambiguous
             if res[:vc] && res[:candidates].all? { |d, _| d }
               "--db <DB> --schema <SCHEMA>, ONE OF: #{res[:candidates].map { |d, sc| "--db #{d} --schema #{sc}" }.join(' | ')}"
             else
               "--db <DATABASE> --schema <ONE OF: #{res[:candidates].map(&:last).uniq.join(' | ')}>"
             end
           when :vc_unresolved
             if res[:lead]
               "--db #{res[:lead][0]} --schema #{res[:lead][1]}"
             else
               q = Array(res[:quals]).find { |x| x.length == 1 }&.first
               q ? "--db #{q} --schema <SCHEMA holding #{Array(res[:tables]).first(3).join(', ')}>   (or --db <DATABASE> --schema #{q})" : '--db <DATABASE> --schema <SCHEMA>'
             end
           end
    [cands, flag]
  end

  # One-paragraph reason for the hard stop (nil when the status needs none).
  def explain(res)
    case res[:status]
    when :vc_unresolved
      q = Array(res[:quals]).map { |x| x.join('.') }.uniq.join(', ')
      t = Array(res[:tables]).first(4).join(', ')
      base = "Virtual-connection tables are qualified as #{q}.<TABLE> (#{t}) — a 2-part VC qualifier names the " \
             'database OR the schema, never both.'
      if res[:lead]
        "#{base} The connection catalog scan was truncated; its only full match is #{res[:lead].join('.')} — confirm it."
      elsif res[:catalog_complete] == false
        "#{base} The Sigma connection catalog could not be listed completely."
      else
        "#{base} No database.schema in the Sigma connection catalog holds all of them" \
          "#{res[:candidates].any? ? " (partial: #{res[:candidates].map { |d, s| "#{d}.#{s}" }.join(', ')})" : ''}."
      end
    when :ambiguous
      res[:vc] ? 'More than one database.schema in the Sigma connection catalog holds every virtual-connection table — NOT guessing.' : nil
    end
  end

  # Tolerant default-database extraction from a GET /v2/connections/{id} body.
  def default_database_from(conn)
    return nil unless conn.is_a?(Hash)
    pools = [conn, conn['details'], conn['connectionDetails'], conn['config']].select { |h| h.is_a?(Hash) }
    pools.each do |h|
      %w[defaultDatabase default_database database databaseName dbname].each do |k|
        v = h[k].to_s.strip
        return v unless v.empty?
      end
    end
    nil
  end
end
