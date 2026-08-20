#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate and canonicalize every physical Qlik LOAD source through Sigma's
# warehouse catalog. This is the no-MCP/no-direct-warehouse path: the supplied
# Sigma connection is enough to browse tables, resolve an inode, and enumerate
# columns.
require 'json'
require 'optparse'
require_relative 'lib/sigma_rest'

def clean_part(value)
  value.to_s.strip.sub(/\A["`\[]/, '').sub(/["`\]]\z/, '')
end

def expected_path(source, database, schema)
  parts = source.to_s.split('.').map { |part| clean_part(part) }.reject(&:empty?)
  parts.size == 1 ? [database, schema, parts.first].compact : parts
end

def path_for_table(expected, connection_id, catalog_paths)
  rows = Array(catalog_paths).select { |entry| entry['connectionId'].to_s == connection_id.to_s }
  paths = rows.map { |entry| Array(entry['path']).map { |part| clean_part(part) } }.reject(&:empty?)
  exact = paths.select do |path|
    path.size == expected.size && path.map(&:upcase) == expected.map(&:upcase)
  end
  return [exact.first, nil] if exact.size == 1
  return [nil, "multiple case-insensitive catalog paths match #{expected.join('.')}: #{exact.map { |p| p.join('.') }.join(', ')}"] if exact.size > 1

  same_table = paths.select { |path| path.last.to_s.casecmp?(expected.last.to_s) }
  if same_table.size == 1
    [same_table.first, nil]
  elsif same_table.empty?
    [expected, nil] # direct lookup may still work when /connections/paths is unavailable/stale
  else
    [nil, "table #{expected.last} is ambiguous on the connection: #{same_table.map { |p| p.join('.') }.join(', ')}"]
  end
end

def preflight_tables(reconcile, connection_id:, database:, schema:, catalog_paths:,
                     lookup:, list_columns:)
  report = { 'connectionId' => connection_id, 'tables' => [], 'errors' => [] }
  resolved = JSON.parse(JSON.generate(reconcile))
  resolved.each do |table|
    source = table['sourceTable'].to_s
    if source.empty? || source.upcase.start_with?('RESIDENT ', 'INLINE', 'AUTOGENERATE', '?')
      report['errors'] << "#{table['qlikTable']}: source #{source.inspect} is not a physical warehouse table"
      next
    end
    expected = expected_path(source, database, schema)
    path, path_error = path_for_table(expected, connection_id, catalog_paths)
    if path_error
      report['errors'] << "#{table['qlikTable']}: #{path_error}"
      next
    end

    begin
      found = lookup.call(connection_id, path)
      inode = found.is_a?(Hash) && found['inodeId']
      kind = found.is_a?(Hash) && found['kind']
      unless inode && kind == 'table'
        report['errors'] << "#{table['qlikTable']}: #{path.join('.')} resolved to #{kind || 'no object'} (inode=#{inode.inspect}), not a table"
        next
      end
      columns = Array(list_columns.call(inode))
      by_upper = columns.each_with_object({}) do |column, memo|
        name = column['name'].to_s
        memo[name.upcase] = name unless name.empty?
      end
      simple_aliases = table['fields'].each_with_object({}) do |field, memo|
        next if field['isExpression'] || field['realColumn'] == '*'
        memo[field['qlikField'].to_s.upcase] = clean_part(field['realColumn'])
      end
      required = table['fields'].flat_map do |field|
        if field['isExpression']
          resolved_inputs = Array(field['expressionColumns']).map do |name|
            simple_aliases[clean_part(name).upcase] || clean_part(name)
          end
          field['expressionColumnsResolved'] = resolved_inputs
          resolved_inputs
        elsif field['realColumn'] != '*'
          [field['realColumn']]
        else
          []
        end
      end.map(&:to_s).uniq
      missing = required.reject { |name| by_upper.key?(clean_part(name).upcase) }
      if missing.any?
        report['errors'] << "#{table['qlikTable']}: #{path.join('.')} is missing required column(s): #{missing.join(', ')}"
      end

      table['sourceTable'] = path.join('.')
      table['warehouseColumns'] = by_upper
      table['fields'].each do |field|
        next if field['isExpression'] || field['realColumn'] == '*'
        actual = by_upper[clean_part(field['realColumn']).upcase]
        field['realColumn'] = actual if actual
      end
      report['tables'] << {
        'qlikTable' => table['qlikTable'], 'path' => path, 'inodeId' => inode,
        'columnsFound' => columns.size, 'requiredColumns' => required, 'missingColumns' => missing
      }
    rescue Sigma::Error => e
      first = e.message.lines.first.to_s.strip
      advice = first.match?(/-> 404\b/) ?
        "; sync it with POST /v2/connections/#{connection_id}/sync and body #{JSON.generate('path' => path)}" : ''
      report['errors'] << "#{table['qlikTable']}: Sigma catalog lookup failed for #{path.join('.')}: #{first}#{advice}"
    rescue StandardError => e
      report['errors'] << "#{table['qlikTable']}: catalog error for #{path.join('.')}: #{e.class}: #{e.message}"
    end
  end
  [resolved, report]
end

def main
  opts = {}
  OptionParser.new do |parser|
    parser.on('--reconcile PATH') { |value| opts[:reconcile] = value }
    parser.on('--connection ID') { |value| opts[:connection] = value }
    parser.on('--database DB') { |value| opts[:database] = value }
    parser.on('--schema SCHEMA') { |value| opts[:schema] = value }
    parser.on('--out PATH') { |value| opts[:out] = value }
    parser.on('--report PATH') { |value| opts[:report] = value }
  end.parse!
  %i[reconcile connection database schema out report].each do |key|
    abort "missing --#{key.to_s.tr('_', '-')}" unless opts[key]
  end

  reconcile = JSON.parse(File.read(opts[:reconcile]))
  catalog_paths = begin
    Sigma.list_entries('/v2/connections/paths')
  rescue Sigma::Error => e
    warn "warehouse preflight: connection-path browse unavailable (#{e.message.lines.first.to_s.strip}); trying exact paths"
    []
  end
  lookup = lambda do |connection_id, path|
    Sigma.request(:post, "/v2/connection/#{connection_id}/lookup",
                  body: JSON.generate('path' => path))
  end
  list_columns = lambda do |inode|
    Sigma.list_entries("/v2/connections/tables/#{inode}/columns")
  end
  resolved, report = preflight_tables(
    reconcile, connection_id: opts[:connection], database: opts[:database], schema: opts[:schema],
    catalog_paths: catalog_paths, lookup: lookup, list_columns: list_columns
  )
  File.write(opts[:out], JSON.pretty_generate(resolved))
  File.write(opts[:report], JSON.pretty_generate(report))
  if report['errors'].any?
    warn "FATAL: Sigma connection catalog preflight failed; no Sigma objects were created:"
    report['errors'].each { |error| warn "  - #{error}" }
    exit 4
  end
  puts "warehouse preflight: #{report['tables'].size} table(s), " \
       "#{report['tables'].sum { |table| table['columnsFound'].to_i }} column(s) verified via Sigma REST -> #{opts[:report]}"
end

main if __FILE__ == $PROGRAM_NAME
