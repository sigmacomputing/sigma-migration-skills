#!/usr/bin/env ruby
# frozen_string_literal: true
#
# check-sql-idents — preflight the Custom SQL (kind:"sql") elements of a DM
# spec against LIVE warehouse catalog columns, BEFORE the POST (hackathon F2:
# emitted SQL referenced CUSTOMER_SFDC_ID unquoted while the actual Snowflake
# column is "Customer SFDC ID" — a compile error that only surfaced at POST).
#
# ALSO checks (#693) that every emitted `AS <alias>` is itself LEGAL SQL —
# independent of any catalog. A FIXED-LOD/window-helper alias built from a
# hyphenated Tableau caption ("Sub-Category") reused the caption's physical
# name unquoted, emitting `AS SUB-CATEGORY`; Snowflake reads the bare `-` as
# a minus operator. The SOURCE side of that statement resolved fine, so the
# catalog check above printed a clean "identifiers resolve" for the very
# element that then failed compilation — this alias-legality check closes
# that gap and fails the element locally instead.
#
# Offline + pure: reads the spec and the column JSONs you already fetched
# (scripts/discover-columns.rb output, or any {"columns":[{"name":...}]} /
# ["NAME", ...] file). No network, no creds.
#
# Usage:
#   ruby scripts/check-sql-idents.rb --dm-spec <workdir>/dm-spec.json \
#     --columns DEAL_FACTS=<workdir>/columns-DEAL_FACTS.json \
#     [--columns OTHER_TABLE=path.json ...]
#
#   Table keys match the LAST path segment of the SQL's FROM/JOIN refs,
#   case-insensitively. Fetch each file first with e.g.:
#     ruby scripts/discover-columns.rb --connection-id <id> \
#       --table-path DB.SCHEMA.DEAL_FACTS --out columns-DEAL_FACTS.json
#
# Exit codes:
#   0  every kind:"sql" element's identifiers resolve against the catalog
#   1  unknown identifier(s) found — per-element fix list printed
#   2  usage / input error (missing file, malformed JSON, no --columns)
#
# List the tables a spec references (to know what to fetch):
#   ruby scripts/check-sql-idents.rb --dm-spec dm-spec.json --list-tables

require 'json'
require 'optparse'
require_relative 'lib/sql_ident_check'

opts = { columns: {} }
OptionParser.new do |p|
  p.on('--dm-spec PATH') { |v| opts[:spec] = v }
  p.on('--columns PAIR', 'TABLE=path-to-columns-json (repeatable)') do |v|
    t, path = v.split('=', 2)
    abort "bad --columns #{v.inspect} — expected TABLE=path.json" if t.to_s.empty? || path.to_s.empty?
    opts[:columns][t] = path
  end
  p.on('--list-tables', 'print the base tables the spec\'s SQL references, then exit') { opts[:list] = true }
end.parse!
abort 'missing --dm-spec' unless opts[:spec]
abort("dm-spec not found: #{opts[:spec]}") unless File.exist?(opts[:spec])

spec = begin
  JSON.parse(File.read(opts[:spec], encoding: 'UTF-8'))
rescue JSON::ParserError => e
  warn "malformed dm-spec JSON: #{e.message}"
  exit 2
end

sql_els = SqlIdentCheck.sql_elements(spec)
if sql_els.empty?
  puts 'no kind:"sql" elements in the spec — nothing to preflight'
  exit 0
end

if opts[:list]
  tables = SqlIdentCheck.referenced_tables(spec)
  puts "#{sql_els.size} kind:\"sql\" element(s) reference #{tables.size} base table(s):"
  tables.each { |t| puts "  #{t}" }
  puts 'Fetch each with discover-columns.rb, then re-run with --columns TABLE=path.json.'
  exit 0
end

if opts[:columns].empty?
  warn 'no --columns supplied — run with --list-tables to see what to fetch, then pass'
  warn '  --columns TABLE=columns.json for each referenced table.'
  exit 2
end

# Accept discover-columns.rb output ({"columns":[{"name":..}]}), a bare
# ["NAME", ...] array, or [{"name": ...}] — be liberal in what we read.
columns_by_table = {}
opts[:columns].each do |table, path|
  unless File.exist?(path)
    warn "columns file not found for #{table}: #{path}"
    exit 2
  end
  doc = begin
    JSON.parse(File.read(path, encoding: 'UTF-8'))
  rescue JSON::ParserError => e
    warn "malformed columns JSON for #{table} (#{path}): #{e.message}"
    exit 2
  end
  cols = doc.is_a?(Hash) ? doc['columns'] : doc
  names = Array(cols).map { |c| c.is_a?(Hash) ? (c['name'] || c['label']) : c }.compact.map(&:to_s)
  if names.empty?
    warn "no column names readable for #{table} in #{path} (expected {\"columns\":[{\"name\":..}]} or [\"NAME\",...])"
    exit 2
  end
  columns_by_table[table] = names
end

bad_total = 0
sql_els.each do |el|
  res = SqlIdentCheck.check(el['statement'], columns_by_table)
  if res[:ok]
    puts "OK   #{el['name']} (page #{el['page']}) — identifiers resolve"
    next
  end
  bad_total += res[:unknown].size
  puts "FAIL #{el['name']} (page #{el['page']}, id #{el['id']}) — #{res[:unknown].size} unknown identifier(s):"
  res[:unknown].each do |u|
    if u[:illegal_alias]
      detail = u[:suggestion] ? "quote it: #{u[:suggestion]}" : "cannot be safely quoted (#{u[:reason]})"
      puts "  AS #{u[:identifier]} → illegal/unquoted SQL alias — #{detail}"
      next
    end
    shown = u[:quoted] ? %("#{u[:identifier]}") : u[:identifier]
    fix = u[:suggestion] ? " → #{u[:suggestion]}" : ' → no catalog match (typo? wrong table? missing --columns?)'
    scope = u[:table] ? " [#{u[:table]}]" : ''
    puts "  #{shown}#{scope}#{fix}"
  end
end

if bad_total.zero?
  puts "all #{sql_els.size} kind:\"sql\" element(s) clean — identifiers match the live catalog"
  exit 0
else
  puts
  puts "#{bad_total} unknown identifier(s). Apply the quoted fixes above to each element's"
  puts 'source.statement in the DM spec (double-quote spaced/mixed-case Snowflake columns),'
  puts 'then re-run this preflight before POSTing.'
  exit 1
end
