#!/usr/bin/env ruby
# Warehouse-agnostic column discovery for a single warehouse table via Sigma's
# REST API. Resolves a fully-qualified `<db>.<schema>.<table>` path to its
# Sigma inodeId on the given connection, then lists columns.
#
# Works against any Sigma-supported warehouse (Snowflake, BigQuery, Databricks,
# Postgres, SQL Server, Redshift, etc.) — Sigma's catalog API is uniform.
#
# Use this in place of warehouse-specific CLIs (`snow sql DESCRIBE TABLE`,
# `bq show`, `databricks tables get`, `psql \d <table>`) when building a DM —
# it's the same call regardless of which warehouse the connection points at.
#
# Usage:
#   eval "$(scripts/get-token.sh)"
#   ruby discover-columns.rb \
#     --connection-id <id> \
#     --table-path <db>.<schema>.<table> \
#     [--out <file>.json]
#
# Output (stdout, or to --out if given):
#   { "connection_id": "...",
#     "path": ["DB", "SCHEMA", "TABLE"],
#     "inode_id": "...",
#     "columns": [ { "name": "...", "type": "..." }, ... ] }
#
# On 404 (table not found in Sigma's catalog), exits 4 with a stderr hint.
# The table may physically exist in the warehouse but not yet be indexed by
# Sigma. First re-index via the API — POST /v2/connections/{id}/sync with
# body {"path":["DB","SCHEMA","TABLE"]} (verified 2026-07-07) — then retry;
# fall back to Custom SQL (Phase 1e.1 in SKILL.md) only if the retry 404s.

require 'net/http'
require 'uri'
require 'json'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'warehouse_columns_pagination'

opts = {}
OptionParser.new do |p|
  p.on('--connection-id ID')     { |v| opts[:conn] = v }
  p.on('--table-path PATH',
       'Fully-qualified path: DB.SCHEMA.TABLE for Snowflake / Databricks; ' \
       'project.dataset.table for BigQuery; database.schema.table for Postgres. ' \
       'Case-sensitive against the warehouse — usually UPPERCASE for Snowflake, ' \
       'lowercase for BigQuery / Databricks / Postgres.') { |v| opts[:path] = v }
  p.on('--out PATH')             { |v| opts[:out] = v }
end.parse!
%i[conn path].each { |k| abort "missing --#{k}" unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL') { abort 'set SIGMA_BASE_URL' }
TOK  = ENV.fetch('SIGMA_API_TOKEN') { abort 'set SIGMA_API_TOKEN' }

def http(method, path, body = nil)
  uri = URI("#{BASE}#{path}")
  req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{TOK}"
  req['Accept'] = 'application/json'
  if body
    req['Content-Type'] = 'application/json'
    req.body = body
  end
  # Bound every call. Sigma's warehouse-catalog lookup/columns endpoints make the
  # warehouse introspect the table; a cold warehouse or a very wide view (e.g. a
  # 300+-column view) can otherwise leave this blocked with NO client-side cap —
  # the "migration stuck for hours" hang. Fail loud instead of hanging forever.
  # Override with SIGMA_HTTP_TIMEOUT (seconds) if a legitimately huge catalog read
  # needs longer.
  timeout = (ENV['SIGMA_HTTP_TIMEOUT'] || '90').to_i
  begin
    # use_ssl keyed off the scheme (not hard-coded true) so the hermetic tests can
    # point SIGMA_BASE_URL at a plain-http loopback stub. Production SIGMA_BASE_URL
    # is https, so live behaviour is unchanged. Same pattern as find-or-pick-dm.rb.
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                          open_timeout: [timeout, 30].min, read_timeout: timeout) do |h|
      h.request(req)
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    abort "TIMEOUT after #{timeout}s calling #{method.to_s.upcase} #{path} (#{e.class}). " \
          "Sigma's warehouse catalog lookup did not return — often a cold warehouse or a very " \
          "wide view. Retry, raise SIGMA_HTTP_TIMEOUT, or source this table via Custom SQL " \
          "(SKILL.md Phase 1e.1) to skip per-column catalog introspection."
  end
  [res.code.to_i, res.body]
end

path_parts = opts[:path].split('.', 3)
abort "table-path must be DB.SCHEMA.TABLE (got #{opts[:path].inspect})" unless path_parts.size == 3

# 1. Resolve the table to an inodeId via POST /v2/connection/{conn}/lookup
#    with body { "path": ["DB","SCHEMA","TABLE"] }.
#    (NOT GET /v2/connections/{conn}/tables — that endpoint does not exist.)
status, body = http(:post, "/v2/connection/#{opts[:conn]}/lookup",
                    JSON.generate('path' => path_parts))

if status == 404
  warn "Table #{opts[:path]} not found in Sigma's catalog for connection #{opts[:conn]}."
  warn 'This usually means the table physically exists in the warehouse but'
  warn "Sigma's static catalog hasn't been re-indexed since it was created."
  warn 'First: force a catalog sync via the API, then re-run this script:'
  warn "  curl -sX POST -H \"Authorization: Bearer $SIGMA_API_TOKEN\" -H 'Content-Type: application/json' \\"
  warn "    \"$SIGMA_BASE_URL/v2/connections/#{opts[:conn]}/sync\" \\"
  warn "    -d '{\"path\": #{JSON.generate(path_parts)}}'"
  warn 'If the retry still 404s, fall back to Custom SQL — see SKILL.md Phase 1e.1:'
  warn "  source: { kind: 'sql', connectionId: '#{opts[:conn]}', statement: 'SELECT * FROM #{opts[:path]}' }"
  exit 4
end
abort "lookup failed: HTTP #{status}\n#{body}" unless status == 200

lookup = JSON.parse(body)
inode = lookup['inodeId'] or abort "lookup returned no inodeId: #{body}"
unless lookup['kind'] == 'table'
  abort "path resolved to a #{lookup['kind']}, not a table (got #{lookup.inspect})"
end

# 2. List columns at /v2/connections/tables/<inodeId>/columns (per
#    feedback_sigma_columns_api_endpoint — connectionId NOT in the path).
#
#    PAGINATED. Sigma's server default page size is 50, so a bare first-page GET
#    silently truncates a wide table — unpaginated single-page reads reached END OF
#    SUPPORT 2026-06-02. Truncation here is not a cosmetic loss: a join key past
#    ordinal 50 leaves the DM builder no column to point a relationship at, and
#    fields past the cut read as "not on the table", whose fallback is Custom SQL.
#
#    Sends limit=1000 and follows this endpoint's ACTUAL cursor to exhaustion via
#    WarehouseColumnsPagination (scripts/lib/warehouse_columns_pagination.rb),
#    not Sigma.list_entries: live verification against this endpoint (2026-08,
#    the logical-model-objectgraph fixture's real 64-column FACT_WIDE table)
#    found it returns `nextPageToken`/expects `pageToken`, not the `nextPage`/
#    `page` shape list_entries assumes — list_entries silently stops after page
#    1 (50 columns) against this specific endpoint. See that file's header for
#    the full repro. Built on the same Sigma.request primitive, so 401-refresh
#    behavior is unchanged, and it stops loudly (not spinning) on a repeated
#    cursor exactly like Sigma.list_entries does.
#
#    The connection is INJECTED so this read keeps this script's
#    SIGMA_HTTP_TIMEOUT bound — the "migration stuck for hours" guard above —
#    instead of the library's fixed 120s read timeout with no open timeout. Every
#    page also shares the one TLS handshake. The block counts pages so a
#    multi-page (wide-table) fetch announces itself on stderr.
cols_path = "/v2/connections/tables/#{inode}/columns"
timeout   = (ENV['SIGMA_HTTP_TIMEOUT'] || '90').to_i
cols_uri  = URI("#{BASE}#{cols_path}")
pages = 0
entries =
  begin
    Net::HTTP.start(cols_uri.host, cols_uri.port, use_ssl: cols_uri.scheme == 'https',
                    open_timeout: [timeout, 30].min, read_timeout: timeout) do |h|
      WarehouseColumnsPagination.list(cols_path, http: h) { pages += 1 }
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    abort "TIMEOUT after #{timeout}s listing columns for #{opts[:path]} (#{e.class}). " \
          "Sigma's warehouse catalog lookup did not return — often a cold warehouse or a very " \
          "wide view. Retry, raise SIGMA_HTTP_TIMEOUT, or source this table via Custom SQL " \
          "(SKILL.md Phase 1e.1) to skip per-column catalog introspection."
  rescue Sigma::Error => e
    abort "columns list failed: #{e.message}"
  end
cols = entries.map do |c|
  # type may come back as a nested object { type: <warehouse-type> }; flatten to a string
  t = c['type']
  t = t['type'] if t.is_a?(Hash) && t['type']
  { 'name' => c['name'], 'type' => t.to_s }
end
warn "columns list spanned #{pages} pages (#{cols.size} columns total) — wide table, all pages fetched" if pages > 1

result = {
  'connection_id' => opts[:conn],
  'path'          => path_parts,
  'inode_id'      => inode,
  'columns'       => cols
}

out = JSON.pretty_generate(result)
if opts[:out]
  File.write(opts[:out], out)
  puts "wrote #{opts[:out]} (#{cols.size} columns)"
else
  puts out
end
