#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/pbi_composite'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

native = {
  'tables' => [{
    'name' => 'COR',
    'partitions' => [{
      'mode' => 'import',
      'source' => {
        'type' => 'm',
        'expression' => [
          'let',
          'Source = Value.NativeQuery(Snowflake.Databases("acct"), "SELECT * FROM DB.SCHEMA.COR")',
          'in Source'
        ]
      }
    }]
  }]
}
check.call(PbiComposite.incomplete_reasons(native).empty?,
           'Value.NativeQuery import partition is not classified as a remote model')

# The live-test shape that was wrongly stopped: every table a DirectQuery partition
# navigating a Snowflake warehouse. DirectQuery to a warehouse is fully convertible.
snowflake_dq_partition = lambda do |table|
  {
    'name' => table,
    'mode' => 'directQuery',
    'source' => {
      'type' => 'm',
      'expression' => [
        'let',
        '    Source = Snowflake.Databases("acct.snowflakecomputing.com", "WH"),',
        '    DB_Database = Source{[Name = "DB", Kind = "Database"]}[Data],',
        '    PUBLIC_Schema = DB_Database{[Name = "PUBLIC", Kind = "Schema"]}[Data],',
        "    T = PUBLIC_Schema{[Name = \"#{table}\", Kind = \"Table\"]}[Data]",
        'in',
        '    T'
      ]
    }
  }
end
snowflake_dq = {
  'tables' => %w[ORDERS CUSTOMERS PRODUCTS].map do |t|
    { 'name' => t, 'partitions' => [snowflake_dq_partition.call(t)] }
  end,
  'expressions' => [{ 'name' => 'Warehouse', 'kind' => 'm',
                      'expression' => '"WH" meta [IsParameterQuery=true, Type="Text"]' }]
}
reasons = PbiComposite.incomplete_reasons(snowflake_dq)
check.call(reasons.empty?, "DirectQuery Snowflake partitions pass the gate (got #{reasons.inspect})")

sql_dq = {
  'tables' => [{
    'name' => 'Sales',
    'partitions' => [{ 'mode' => 'directQuery',
                       'source' => { 'type' => 'm',
                                     'expression' => 'let Source = Sql.Database("srv", "db") in Source' } }]
  }]
}
check.call(PbiComposite.incomplete_reasons(sql_dq).empty?,
           'DirectQuery SQL Server partition passes the gate')

analysis_services = {
  'tables' => [{
    'name' => 'Remote',
    'partitions' => [{
      'source' => { 'type' => 'm', 'expression' => 'AnalysisServices.Database("server", "dataset")' }
    }]
  }]
}
check.call(PbiComposite.incomplete_reasons(analysis_services).any? { |r| r.include?('remote Power BI dataset') },
           'Analysis Services connector remains a remote-model signal')

dq_over_as = {
  'tables' => [{
    'name' => 'Remote',
    'partitions' => [{
      'mode' => 'directQuery',
      'source' => { 'type' => 'm',
                    'expression' => 'AnalysisServices.Database("powerbi://api.powerbi.com/v1.0/myorg/WS", "Sales")' }
    }]
  }]
}
check.call(PbiComposite.incomplete_reasons(dq_over_as).any? { |r| r.include?('remote Power BI dataset') },
           'DirectQuery partition over a remote Power BI dataset still gates')

entity = {
  'tables' => [{
    'name' => 'Proxy',
    'partitions' => [{ 'mode' => 'directQuery', 'source' => { 'type' => 'entity' } }]
  }]
}
reasons = PbiComposite.incomplete_reasons(entity)
check.call(reasons.any? { |r| r.include?("'entity'") }, 'entity partition remains gated')

# Fabric composite shape: entity partitions whose expressionSource names a shared
# expression that connects to the remote semantic model.
remote_expression = {
  'name' => 'DirectQuery to AS - Sales Model',
  'kind' => 'm',
  'expression' => [
    'let',
    '    Source = AnalysisServices.Database("powerbi://api.powerbi.com/v1.0/myorg/WS", "Sales Model"),',
    '    Cubes = Table.ToRows(Source),',
    '    Cube = Cubes{0}{1}',
    'in',
    '    Cube'
  ]
}
entity_remote = {
  'tables' => [
    { 'name' => 'Sales',
      'partitions' => [{ 'mode' => 'directQuery',
                         'source' => { 'type' => 'entity', 'entityName' => 'Sales',
                                       'expressionSource' => 'DirectQuery to AS - Sales Model' } }] },
    { 'name' => 'LocalTargets', 'partitions' => [snowflake_dq_partition.call('TARGETS')] }
  ],
  'expressions' => [remote_expression]
}
reasons = PbiComposite.incomplete_reasons(entity_remote)
check.call(reasons.any? { |r| r.include?("'Sales'") && r.include?('DirectQuery to AS - Sales Model') },
           "entity partition's expressionSource to a remote dataset gates")
check.call(reasons.none? { |r| r.include?('LocalTargets') },
           'warehouse DirectQuery table beside a remote entity is not itself flagged')

m_ref_remote = {
  'tables' => [{
    'name' => 'Sales',
    'partitions' => [{ 'mode' => 'directQuery',
                       'source' => { 'type' => 'm', 'expressionSource' => 'DirectQuery to AS - Sales Model',
                                     'expression' => 'let Source = #"DirectQuery to AS - Sales Model" in Source' } }]
  }],
  'expressions' => [remote_expression]
}
check.call(PbiComposite.incomplete_reasons(m_ref_remote).any? { |r| r.include?('remote Power BI dataset') },
           'M partition whose expressionSource is a remote dataset gates')

shared_remote_only = {
  'tables' => [{ 'name' => 'ORDERS', 'partitions' => [snowflake_dq_partition.call('ORDERS')] }],
  'expressions' => [remote_expression]
}
check.call(PbiComposite.incomplete_reasons(shared_remote_only).any? { |r| r.include?("expression 'DirectQuery to AS") },
           'a shared expression connecting to a remote dataset gates')

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
