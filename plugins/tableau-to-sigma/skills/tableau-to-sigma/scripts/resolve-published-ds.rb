#!/usr/bin/env ruby
# Resolve the PUBLISHED data sources (PDS) behind a workbook's sqlproxy connections
# and emit a descriptor per PDS that hydrate-custom-sql.rb can splice into the .twb.
#
# WHY (see PUBLISHED_DS_FINDINGS): a workbook on a published DS carries only a
# <connection class='sqlproxy'> placeholder — the real relation (a warehouse table
# OR a Custom SQL <relation type='text'>) lives in the PDS object on Tableau Server.
# The RELIABLE way to get it is the REST content download, NOT the Metadata GraphQL
# lineage (which lags for hours on fresh PDSes and whose downstream links are often
# empty). We resolve the PDS by contentUrl (== the sqlproxy `dbname` /
# <repository-location id>), GET /datasources/{id}/content, and read the inner .tds.
#
# Output: JSON array of
#   { "caption":, "contentUrl":, "relationType": "text"|"table",
#     "sql":, "table":, "db":, "schema":, "columns": [...] }
#
# Usage:
#   eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/resolve-published-ds.rb --twb /tmp/<name>/workbook-content.twb --out /tmp/<name>/pds.json

require 'json'
require 'optparse'
require 'rexml/document'
require 'tempfile'
require 'open3'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'tableau_rest'
require_relative 'hydrate-custom-sql'

opts = {}
OptionParser.new do |o|
  o.on('--twb PATH') { |v| opts[:twb] = v }
  o.on('--out PATH') { |v| opts[:out] = v }
end.parse!
abort 'usage: --twb PATH --out PATH' unless opts[:twb] && opts[:out]

# Extract the inner .tds text from a datasource content download (a .tdsx zip, or
# a bare .tds when there's no extract).
def tds_text_from(bytes)
  if bytes[0, 2] == 'PK' # zip
    require_relative 'lib/zip_extract' # stdlib Zlib reader — no rubygems 'zip', no shelled unzip binary (Windows-safe)
    Tempfile.create(['pds', '.tdsx']) do |f|
      f.binmode; f.write(bytes); f.flush
      tds = ZipExtract.entries(f.path).find { |n| n.end_with?('.tds') }
      return nil unless tds
      ZipExtract.read(f.path, tds)&.force_encoding('UTF-8')
    end
  else
    bytes
  end
end

# Read {relationType, sql|table, db, schema} out of a PDS .tds.
def descriptor_from_tds(tds_text)
  doc = REXML::Document.new(tds_text)
  # Prefer a Custom SQL relation; else the first real table relation.
  text_rel = nil; table_rel = nil
  doc.each_element('//relation') do |r|
    type = (r.attributes['type'] || 'table').to_s
    if type == 'text' && !r.text.to_s.strip.empty?
      text_rel ||= r
    elsif type == 'table'
      tbl = r.attributes['table'].to_s
      table_rel ||= r unless tbl.empty? || tbl == '[sqlproxy]' || tbl == '[Extract].[Extract]'
    end
  end
  rel = text_rel || table_rel
  return nil unless rel
  # The connection carrying db/schema (skip the federated wrapper).
  conn = nil
  doc.each_element('//connection') do |c|
    cls = c.attributes['class'].to_s
    next if cls == 'federated' || cls.empty?
    conn = c; break
  end
  conn ||= doc.elements['//connection']
  db = conn && conn.attributes['dbname'].to_s
  schema = conn && conn.attributes['schema'].to_s
  # #454: the PDS's real warehouse class (snowflake / databricks / …) lives on this
  # connection. Carry it into the descriptor so hydration case-normalizes with the
  # right rules per-PDS (a case-preserving warehouse must not be upper-folded).
  wcls = HydrateCustomSql.canon_warehouse_class(conn && conn.attributes['class'])
  if text_rel
    sql = rel.text.to_s.strip
    cols = HydrateCustomSql.parse_sql_columns(sql)
    star_table = cols.empty? ? HydrateCustomSql.bare_select_star_table(sql) : nil
    if star_table
      # #453: a bare `SELECT * FROM <table>` PDS is semantically just <table>.
      # parse_sql_columns can't enumerate `*`, so resolve it as a TABLE relation
      # (the warehouse catalog supplies the columns downstream) instead of emitting
      # a 0-column Custom SQL relation that would hard-abort the migration.
      { 'relationType' => 'table', 'table' => star_table, 'db' => db, 'schema' => schema,
        'columns' => [], 'warehouseClass' => wcls, 'expandedFrom' => 'select-star' }
    else
      { 'relationType' => 'text', 'sql' => sql, 'db' => db, 'schema' => schema,
        'columns' => cols, 'warehouseClass' => wcls }
    end
  else
    { 'relationType' => 'table', 'table' => rel.attributes['table'].to_s, 'db' => db,
      'schema' => schema, 'columns' => [], 'warehouseClass' => wcls }
  end
end

# --- transient-401 survivability -------------------------------------------
# The PDS-resolve Tableau calls below used to run with ONLY lib/tableau_rest.rb's
# single inline 401 refresh (request: res.code==401 && attempts==1 → refresh_token!).
# A 401 that RACES that one retry — a startup / session-signin race, common when a
# freshly minted token is used before its server-side session is fully live —
# escaped with no cushion. And because a dropped PDS is (correctly) treated as
# "abort rather than fabricate a phantom relation" (refs/multi-datasource.md), a
# single transient 401 on this path took the WHOLE migration down. The discovery
# path never had this problem: tableau-discover.rb#run_task gives every fetch an
# outer re-mint budget on a 401 that escapes the lib retry. Give the two PDS
# calls the SAME budget here. A genuine NON-401 failure (e.g. 403 "no Download
# capability") is NOT retried — it re-raises at once so the abort-don't-fabricate
# contract still fails loudly rather than being masked.
def with_remint_on_401(label, max_attempts: 3)
  attempts = 0
  begin
    attempts += 1
    yield
  rescue Tableau::Error => e
    if attempts < max_attempts && e.message.to_s =~ /\b401\b/
      warn "  ↻ #{label}: 401 escaped the lib retry — re-minting token (attempt #{attempts}/#{max_attempts})"
      Tableau.refresh_token! rescue nil
      sleep 1.0 + rand * 0.5
      retry
    end
    raise
  end
end

# Generously-excerpted Tableau error for the log — NOT `e.message.lines.first`,
# which dropped everything after the status line (the HTTP status detail AND the
# response body), making a real 403 "no Download capability" indistinguishable
# from a transient signin-race 401. Tableau error bodies never carry credential
# values, so the excerpt is safe to log verbatim; the cap just bounds a runaway body.
def tableau_error_detail(e, limit: 800)
  e.message.to_s.strip[0, limit]
end

doc = REXML::Document.new(File.read(opts[:twb], encoding: 'UTF-8'))
descriptors = []
seen = {}
doc.each_element('/workbook/datasources/datasource') do |ds|
  conn = ds.elements['connection']
  next unless conn && HydrateCustomSql.sqlproxy_connection?(conn) && !HydrateCustomSql.has_real_relation?(conn)
  content_url = HydrateCustomSql.pds_content_url(ds)
  caption = (ds.attributes['caption'] || '').to_s
  next if content_url.to_s.empty? || seen[content_url]
  seen[content_url] = true

  rec = begin
    with_remint_on_401("PDS lookup for contentUrl=#{content_url.inspect}") do
      Tableau.find_datasource_by_content_url(content_url)
    end
  rescue Tableau::Error => e
    warn "  ⚠ PDS lookup failed for contentUrl=#{content_url.inspect}: #{tableau_error_detail(e)}"
    nil
  end
  unless rec && rec['id']
    warn "  ⚠ could not resolve published DS for contentUrl=#{content_url.inspect} (not found on site / no permission)"
    next
  end

  begin
    bytes = with_remint_on_401("content download for PDS #{content_url.inspect}") do
      Tableau.download_datasource_content(rec['id'])
    end
    tds = tds_text_from(bytes)
    d = tds && descriptor_from_tds(tds)
    unless d
      warn "  ⚠ downloaded PDS #{content_url.inspect} but found no usable relation in its .tds"
      next
    end
    d['caption'] = caption
    d['contentUrl'] = content_url
    d['pdsName'] = rec['name']
    d['pdsLuid'] = rec['id']
    descriptors << d
    detail = d['relationType'] == 'text' ? "Custom SQL, #{d['columns'].size} col(s)" : "table #{d['table']}"
    warn "  resolved PDS #{rec['name'].inspect} (#{content_url}) → #{detail}"
  rescue Tableau::Error => e
    warn "  ⚠ content download failed for PDS #{content_url.inspect}: #{tableau_error_detail(e)}"
  end
end

File.write(opts[:out], JSON.pretty_generate(descriptors))
puts "wrote #{opts[:out]} (#{descriptors.size} published data source(s) resolved)"
