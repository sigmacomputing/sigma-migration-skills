#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lib/pbi_native_query'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

native_m = lambda do |sql, post = nil|
  escaped = sql.gsub('"', '""').gsub("\n", '#(lf)')
  lines = [
    'let',
    "  Source = Value.NativeQuery(Snowflake.Databases(\"acct\"){[Name=\"ENTERPRISE\"]}[Data], \"#{escaped}\", null, [EnableFolding=true])#{post ? ',' : ''}"
  ]
  lines << post if post
  lines << "in #{post ? '#\"Renamed Columns\"' : 'Source'}"
  lines
end

cor_sql = <<~SQL.strip
  SELECT c.COST_CENTER, c.PROPERTY_ID, c.AMOUNT
  FROM ENTERPRISE.MASTER.COR_DETAIL c
  JOIN ENTERPRISE.MASTER.PROPERTY p ON p.ID = c.PROPERTY_ID
SQL
property_sql = <<~SQL.strip
  SELECT c.PROPERTY_ID, p.PROPERTY_NAME
  FROM ENTERPRISE.MASTER.COR_DETAIL c
  JOIN ENTERPRISE.MASTER.PROPERTY p ON p.ID = c.PROPERTY_ID
SQL

fixture = File.expand_path('../fixtures/native_query_cor_pl/model.bim', __dir__)
tmsl = JSON.parse(File.read(fixture))

puts "\n1. normalize array-valued calculation items"
normalized = PbiNativeQuery.normalize_tmsl(tmsl)
expr = normalized.dig('model', 'tables', 2, 'calculationGroup', 'calculationItems', 1, 'expression')
check.call(expr.is_a?(String) && expr.include?("SELECTEDMEASURE(),\n"), 'calculation-item expression is joined into a string')

puts "\n2. pinned converter runs, then compatibility layer restores native SQL"
Dir.mktmpdir('pbi-native-query-test') do |dir|
  input = File.join(dir, 'model.json')
  output = File.join(dir, 'result.json')
  shim = File.join(dir, 'convert.mjs')
  converter = File.expand_path('../converter/powerbi.mjs', __dir__)
  File.write(input, JSON.generate(normalized))
  File.write(shim, <<~JS)
    import { readFileSync, writeFileSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    const { convertPowerBIToSigma } = await import(pathToFileURL(#{converter.to_json}).href);
    const out = convertPowerBIToSigma(JSON.parse(readFileSync(#{input.to_json}, 'utf8')), { connectionId: 'conn' });
    writeFileSync(#{output.to_json}, JSON.stringify(out.model || out.sigmaDataModel || out));
  JS
  _out, err, status = Open3.capture3('node', shim)
  check.call(status.success?, "pinned converter accepts normalized calc group#{": #{err}" unless status.success?}")
  if status.success?
    dm = JSON.parse(File.read(output))
    result = PbiNativeQuery.apply!(dm, tmsl['model'])
    check.call(result['blockers'].empty?, 'native queries restore without blockers')
    sql_elements = dm['pages'][0]['elements'].select { |e| e.dig('source', 'kind') == 'sql' && %w[COR Property].include?(e['name']) }
    check.call(sql_elements.size == 2, 'two logical Custom SQL elements remain distinct')
    cor = sql_elements.find { |e| e['name'] == 'COR' }
    property = sql_elements.find { |e| e['name'] == 'Property' }
    check.call(cor&.dig('source', 'statement') == cor_sql, 'COR preserves the complete multi-join SQL')
    check.call(property&.dig('source', 'statement') == property_sql, 'Property preserves its distinct SQL')
    check.call(cor && cor['columns'].first['formula'] == '[Custom SQL/COST_CENTER]', 'column formula uses exact SQL output name')
    check.call(cor && cor['columns'].first['name'] == 'Cost Center', 'column keeps the Power BI display name')
    check.call(!dm['pages'][0]['elements'].any? { |e| e.dig('source', 'kind') == 'warehouse-table' && e.dig('source', 'path')&.last == 'COR_DETAIL' },
               'first FROM table is not emitted as the source architecture')
    view = dm['pages'][0]['elements'].find { |e| e['name'] == 'COR View' }
    check.call(view && view['columns'].all? { |c| !c['formula'].to_s.start_with?('[COR_DETAIL/') },
               'derived View references are re-prefixed to the logical table')
  end
end

puts "\n3. unsupported post-query M transforms are gated"
post_tmsl = JSON.parse(JSON.generate(tmsl))
post = '  #"Renamed Columns" = Table.RenameColumns(Source, {{"COST_CENTER", "Cost Center"}})'
post_tmsl['model']['tables'][0]['partitions'][0]['source']['expression'] = native_m.call(cor_sql, post)
native = PbiNativeQuery.native_queries(post_tmsl['model']).first
check.call(native.post_transform, 'post-NativeQuery transform is detected')

puts "\n4. connector Query option is extracted"
query = PbiNativeQuery.extract_from_expression(
  'Orders',
  'let Source = Sql.Database("server", "DB", [Query="SELECT ORDER_ID FROM dbo.orders"]) in Source'
)
check.call(query&.statement == 'SELECT ORDER_ID FROM dbo.orders', 'Query= SQL is preserved')

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
