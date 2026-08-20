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

entity = {
  'tables' => [{
    'name' => 'Proxy',
    'partitions' => [{ 'mode' => 'directQuery', 'source' => { 'type' => 'entity' } }]
  }]
}
reasons = PbiComposite.incomplete_reasons(entity)
check.call(reasons.any? { |r| r.include?('DirectQuery') }, 'DirectQuery partition remains gated')
check.call(reasons.any? { |r| r.include?("'entity'") }, 'entity partition remains gated')

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
