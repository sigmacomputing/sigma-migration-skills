#!/usr/bin/env ruby
# rank-connections.rb — pre-rank the ambiguous Sigma-connection ASK by matching the
# Tableau workbook's warehouse against the org's Sigma connections.
#
# WHY: intake.rb writes connection-candidates.json and exits 3 when it can't pick
# safely (field run: 26 connections). The agent then hand-downloaded the .twb and
# grepped connection classes to recommend one — several wasted calls, and the user
# still guessed. This scores every candidate against the workbook's real warehouse
# (type + host/account, optionally database) so the ASK is either auto-resolved
# (unique type+host match) or presented already ranked with a clear top pick.
#
# Fingerprint source (no .twb/.twbx download needed — dodges the missing `zip` gem):
#   --workbook-id LUID   → GET /workbooks/{luid}/connections  (type + serverAddress)
#   --twb PATH           → parse a downloaded .twb (adds dbname/schema for tie-breaks)
# (at least one required; if both, they merge.)
#
# Usage:
#   ruby scripts/rank-connections.rb --workbook-id <LUID> [--twb <path>] \
#        [--candidates <connection-candidates.json>] [--out <ranked.json>]
#
# Exit codes:
#   0  confident recommendation (unique type+host match) — printed + written
#   3  ranked but ambiguous — top candidate suggested, ASK the user to confirm
#   4  no candidates / no fingerprint / API error
#   1  usage error
require 'json'
require 'optparse'
require 'set'

module RankConnections
  module_function

  # Tableau connection class / Sigma connection type → canonical warehouse family.
  TYPE_ALIASES = {
    'snowflake' => 'snowflake',
    'sqlserver' => 'sqlserver', 'mssql' => 'sqlserver', 'microsoftsqlserver' => 'sqlserver', 'sqlserverodbc' => 'sqlserver',
    'redshift' => 'redshift', 'amazonredshift' => 'redshift',
    'databricks' => 'databricks', 'spark' => 'databricks', 'sparksql' => 'databricks', 'databrickssql' => 'databricks',
    'bigquery' => 'bigquery', 'googlebigquery' => 'bigquery',
    'postgres' => 'postgres', 'postgresql' => 'postgres',
    'oracle' => 'oracle',
    'mysql' => 'mysql',
    'athena' => 'athena', 'awsathena' => 'athena', 'amazonathena' => 'athena',
    'presto' => 'presto', 'trino' => 'trino',
  }.freeze

  def canon_type(t)
    k = t.to_s.downcase.gsub(/[^a-z0-9]/, '')
    TYPE_ALIASES[k] || k
  end

  # Generic host labels that carry no identity — never match on these. Includes
  # cloud/vendor suffixes AND directional region words (a shared "east" from two
  # different "us-east-1" hosts must NOT count as an identity match).
  GENERIC = %w[snowflakecomputing com net org www database windows core amazonaws
               redshift databricks azuredatabricks gcp azure cloud
               comput05 sql server db data prod dev test staging
               east west north south central northeast northwest southeast southwest
               region zone].to_set.freeze

  # Meaningful tokens from a host / account string (leading account label, etc.).
  def host_tokens(*strs)
    toks = Set.new
    strs.compact.each do |s|
      s.to_s.downcase.split(/[^a-z0-9]+/).each do |t|
        next if t.empty? || t.length < 3
        next if GENERIC.include?(t)
        next if t =~ /\A(us|eu|ap|ca|sa)(east|west|north|south|central)?\d*\z/  # region codes
        next if t =~ /\A[a-z]{2}\d+\z/ && t.length <= 4                          # e.g. us1
        toks << t
      end
    end
    toks
  end

  # Score one Sigma candidate against the source fingerprint. Pure.
  #   fp:   { 'type'=>, 'host'=>, 'account'=>, 'database'=> }  (any may be nil)
  #   cand: { 'connection_id'=>, 'name'=>, 'type'=>, 'host'=>, 'account'=>, 'warehouse'=> }
  def score_candidate(fp, cand)
    reasons = []
    score = 0
    if fp['type'] && !fp['type'].to_s.empty? && canon_type(fp['type']) == canon_type(cand['type'])
      score += 100; reasons << "warehouse type matches (#{canon_type(cand['type'])})"
    end
    src_host = "#{fp['host']} #{fp['account']}"
    src_toks = host_tokens(fp['host'], fp['account'])
    cand_toks = host_tokens(cand['host'], cand['account'], cand['name'], cand['warehouse'])
    if fp['host'] && !fp['host'].to_s.empty? && !cand['host'].to_s.empty? &&
       fp['host'].to_s.downcase == cand['host'].to_s.downcase
      score += 80; reasons << "exact host match (#{cand['host']})"
    elsif !(src_toks & cand_toks).empty?
      shared = (src_toks & cand_toks).to_a.sort.join(', ')
      score += 50; reasons << "host/account token match (#{shared})"
    end
    if fp['database'] && !fp['database'].to_s.empty?
      dbtok = fp['database'].to_s.downcase
      if [cand['name'], cand['warehouse'], cand['database']].compact.any? { |v| v.to_s.downcase.include?(dbtok) }
        score += 15; reasons << "database name hint (#{fp['database']})"
      end
    end
    { 'connection_id' => cand['connection_id'], 'name' => cand['name'], 'type' => cand['type'],
      'match_score' => score, 'match_reasons' => reasons }
  end

  # Rank all candidates; decide whether the top is a confident auto-pick. Pure.
  def rank(fp, candidates)
    scored = candidates.map { |c| score_candidate(fp, c) }
                       .sort_by { |c| [-c['match_score'], c['name'].to_s] }
    top = scored.first
    second = scored[1]
    type_matches = scored.select { |c| c['match_score'] >= 100 }
    confident = !top.nil? && top['match_score'] >= 100 &&
                (type_matches.size == 1 ||                                   # only one right-type conn
                 (second && (top['match_score'] - second['match_score']) >= 30)) # host/db breaks the tie
    { 'ranked' => scored, 'recommended' => (confident ? top : nil),
      'confident' => confident, 'type_match_count' => type_matches.size }
  end

  # ---- fingerprint sources -------------------------------------------------
  # Primary non-extract warehouse connection from a Tableau REST connections list.
  SKIP_CLASSES = %w[federated sqlproxy publishedconnection excel-direct textscan hyper
                    msaccess dataengine tableau-server-connection].to_set.freeze
  # Indirection layers that POINT AT a warehouse rather than being one. A workbook
  # backed by these has no warehouse signal in its own /connections (serverAddress
  # is empty) — the real warehouse must be resolved from the published datasource
  # or virtual connection (fingerprint_via_published_source). Field-caught on
  # "orders e2e workbook" (all Sigma connections scored 0).
  INDIRECT_CLASSES = %w[publishedconnection sqlproxy].to_set.freeze

  def fingerprint_from_wb_connections(list)
    conns = (list || []).map { |c| { 'type' => (c['type'] || c['dbClass']), 'host' => (c['serverAddress'] || c['server']) } }
                        .reject { |c| c['type'].to_s.empty? || SKIP_CLASSES.include?(c['type'].to_s.downcase) }
    warehouse = conns.find { |c| !c['host'].to_s.empty? } || conns.first
    warehouse ? { 'type' => warehouse['type'], 'host' => warehouse['host'] } : {}
  end

  # Normalize a warehouse host: the VC/Metadata APIs store Snowflake as a console
  # URL ("https://acct.snowflakecomputing.com/console/login#/") — strip scheme,
  # path/fragment, and :port to the canonical host ("acct.snowflakecomputing.com").
  def clean_host(s)
    h = s.to_s.strip
    return h if h.empty?
    h.sub(%r{\Ahttps?://}i, '').sub(%r{[/#?].*\z}, '').sub(/:\d+\z/, '')
  end

  # Choose the Virtual Connection backing a workbook. The workbook's /connections
  # carries no VC LUID — only the (munged) published-DS name — so match VC by name.
  # NEVER guess between candidates: nil ⇒ caller falls back to the ranked ASK.
  def pick_virtual_connection(vcs, ds_name)
    vcs = (vcs || []).select { |v| v && v['id'] }
    return vcs.first if vcs.size == 1
    dn = ds_name.to_s.downcase
    hits = vcs.select { |v| !v['name'].to_s.empty? && dn.include?(v['name'].to_s.downcase) }
    hits.size == 1 ? hits.first : nil
  end

  # Resolve the real warehouse behind an INDIRECT (publishedConnection/sqlproxy)
  # workbook connection, via read-only REST: first the pointed-at datasource's own
  # connections (a CLASSIC published DS names the warehouse there); else resolve the
  # Virtual Connection by name and read ITS connection. Never raises, never guesses
  # — {} on any miss so the caller degrades to the ranked ASK.
  def fingerprint_via_published_source(raw_conns, rest)
    ptr = (raw_conns || []).find { |c| INDIRECT_CLASSES.include?(c['type'].to_s.downcase) }
    return {} unless ptr
    ds = ptr['datasource'] || {}
    if ds['id'] && !ds['id'].to_s.empty?
      fp = (fingerprint_from_wb_connections(rest.datasource_connections(ds['id'])) rescue {})
      return fp unless fp['type'].to_s.empty?   # classic PDS resolved
    end
    vc = pick_virtual_connection((rest.virtual_connections rescue []), ds['name'])
    return {} unless vc
    fp = (fingerprint_from_wb_connections(rest.virtual_connection_connections(vc['id'])) rescue {})
    fp['host'] = clean_host(fp['host']) unless fp['host'].to_s.empty?
    fp
  end

  # Orchestrator: the workbook's warehouse fingerprint, resolving through a
  # published-DS / virtual-connection indirection when the direct connection has no
  # warehouse signal. `rest` is duck-typed (the Tableau module in prod; a stub in tests).
  def fingerprint_from_workbook(rest, wb_id)
    raw = (rest.workbook_connections(wb_id) rescue [])
    fp = fingerprint_from_wb_connections(raw)
    return fp unless fp['type'].to_s.empty?
    via = fingerprint_via_published_source(raw, rest)
    via.empty? ? fp : via
  end

  # Fingerprint from a downloaded .twb (regex, no XML/zip deps). Adds dbname/schema.
  def fingerprint_from_twb(xml)
    best = nil
    xml.scan(/<connection\b[^>]*\bclass=(['"])(.*?)\1[^>]*>/m) do |_q, _cls|
      tag = Regexp.last_match(0)
      cls = _cls
      next if SKIP_CLASSES.include?(cls.downcase) || %w[automatic categorical].include?(cls.downcase)
      server = tag[/\bserver=(['"])(.*?)\1/, 2]
      dbname = tag[/\bdbname=(['"])(.*?)\1/, 2]
      schema = tag[/\bschema=(['"])(.*?)\1/, 2]
      cand = { 'type' => cls, 'host' => server, 'database' => dbname, 'schema' => schema }
      # prefer a connection that actually names a server (the real warehouse)
      best ||= cand
      best = cand if best['host'].to_s.empty? && !server.to_s.empty?
    end
    best || {}
  end

  def merge_fp(a, b)
    out = {}
    %w[type host account database schema].each { |k| out[k] = (a[k] && !a[k].to_s.empty? ? a[k] : b[k]) }
    out
  end
end

# ---- CLI --------------------------------------------------------------------
if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |p|
    p.on('--workbook-id LUID')  { |v| opts[:wb] = v }
    p.on('--twb PATH')          { |v| opts[:twb] = v }
    p.on('--candidates PATH')   { |v| opts[:cands] = v }
    p.on('--out PATH')          { |v| opts[:out] = v }
    p.on('--connections-fixture FILE', 'TEST ONLY: Sigma connections list') { |v| opts[:conn_fix] = v }
    p.on('--fingerprint-fixture FILE', 'TEST ONLY: {type,host,database} JSON') { |v| opts[:fp_fix] = v }
  end.parse!

  # 1) Source fingerprint
  fp = {}
  if opts[:fp_fix]
    fp = JSON.parse(File.read(opts[:fp_fix]))
  else
    if opts[:wb]
      require_relative 'lib/tableau_rest'
      begin
        Tableau.site_id
      rescue Tableau::Error
        Tableau.refresh_token!
      end
      fp = RankConnections.merge_fp(fp, RankConnections.fingerprint_from_workbook(Tableau, opts[:wb]))
    end
    if opts[:twb] && File.exist?(opts[:twb])
      fp = RankConnections.merge_fp(fp, RankConnections.fingerprint_from_twb(File.read(opts[:twb], encoding: 'UTF-8')))
    end
  end
  if fp['type'].to_s.empty?
    warn '[FAIL] rank-connections: no warehouse fingerprint (need --workbook-id or --twb).'
    exit 4
  end

  # 2) Sigma connections (rich: type/host/account/warehouse)
  raw = if opts[:conn_fix]
          JSON.parse(File.read(opts[:conn_fix]))
        else
          require_relative 'lib/sigma_rest'
          Sigma.request(:get, '/v2/connections?limit=500')
        end
  rows = raw.is_a?(Hash) ? (raw['entries'] || raw['connections'] || []) : (raw || [])
  conns = rows.map do |c|
    { 'connection_id' => c['connectionId'] || c['id'], 'name' => c['name'] || c['label'],
      'type' => c['type'] || c['connectionType'], 'host' => c['host'], 'account' => c['account'],
      'warehouse' => c['warehouse'] }
  end.reject { |c| c['connection_id'].to_s.empty? || c['isArchived'] }
  # scope to intake's candidate ids if provided
  if opts[:cands] && File.exist?(opts[:cands])
    ids = (JSON.parse(File.read(opts[:cands]))['candidates'] || []).map { |c| c['connection_id'] }.to_set
    conns = conns.select { |c| ids.include?(c['connection_id']) } unless ids.empty?
  end
  if conns.empty?
    warn '[FAIL] rank-connections: no Sigma connections to rank.'
    exit 4
  end

  result = RankConnections.rank(fp, conns)
  result['fingerprint'] = fp
  out_path = opts[:out] || (opts[:cands] ? File.join(File.dirname(opts[:cands]), 'connection-candidates-ranked.json') : nil)
  if out_path
    File.write(out_path, JSON.pretty_generate(result))
  end

  warn "── source warehouse: type=#{RankConnections.canon_type(fp['type'])} host=#{fp['host'] || '?'} db=#{fp['database'] || '?'}"
  result['ranked'].first(6).each_with_index do |c, i|
    mark = (result['recommended'] && c['connection_id'] == result['recommended']['connection_id']) ? '★' : ' '
    warn format('  %s #%d  %-40s  score=%-3d  %s', mark, i + 1, "#{c['name']} (#{c['type']})", c['match_score'], c['match_reasons'].join('; '))
  end
  if result['confident']
    rec = result['recommended']
    warn "\n[OK] rank-connections: confident pick → #{rec['name']} (#{rec['connection_id']})"
    warn "     re-run intake with:  --connection #{rec['connection_id']}"
    exit 0
  else
    warn "\n[ASK] rank-connections: no unique match (#{result['type_match_count']} same-type connection(s)) — confirm with the user, then re-run intake --connection <id>."
    exit 3
  end
end
