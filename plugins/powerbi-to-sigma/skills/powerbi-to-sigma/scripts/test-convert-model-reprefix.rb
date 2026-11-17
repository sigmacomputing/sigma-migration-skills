#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

raw = {
  'pages' => [{
    'id' => 'p1',
    'elements' => [
      {
        'id' => 'cost', 'kind' => 'table', 'name' => 'COST_CENTER',
        'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB SCHEMA COST_CENTER] },
        'columns' => [
          { 'id' => 'id', 'formula' => '[Cost Center/ID]' },
          { 'id' => 'dim', 'formula' => '[DIM/Label]' }
        ]
      },
      {
        'id' => 'dim', 'kind' => 'table', 'name' => 'DIM',
        'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB SCHEMA DIM] },
        'columns' => [{ 'id' => 'label', 'formula' => '[DIM/LABEL]' }]
      },
      {
        # Power BI-shaped mode: element named after the Power BI table, prefix stays the physical table name
        'id' => 'dt', 'kind' => 'table', 'name' => 'Date',
        'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB SCHEMA DIM_DATE] },
        'columns' => [{ 'id' => 'dk', 'formula' => '[DIM_DATE/Date Key]' }, { 'id' => 'dm', 'formula' => '[Date/Month]' }]
      }
    ]
  }]
}

source = File.read(File.expand_path('convert-model.rb', __dir__))
check.call(source.include?("require_relative 'lib/sigma_rest'") &&
           source.include?('Sigma.request(:get, "/v2/dataModels/#{opts[:ref_dm]}/spec")'),
           'reference-DM harvest delegates browser/client auth and one-401 retry to sigma_rest')
check.call(!source.include?("ENV.fetch('SIGMA_API_TOKEN')") &&
           !source.include?("req['Authorization']"),
           'reference-DM harvest does not read or attach a static bearer')

# Fixup 3b target: the views shape rewrites to the ELEMENT NAME (byte-for-byte what it always did); only the pbi shape
# (--model-shape pbi, passed by the orchestrator in pbi mode) rewrites to the physical path tail (Task 21x item 5).
convert = lambda do |dir, *extra|
  input = File.join(dir, 'raw.json')
  output = File.join(dir, "spec-#{extra.join}.json")
  File.write(input, JSON.generate(raw))
  text, status = Open3.capture2e('ruby', File.expand_path('convert-model.rb', __dir__), '--converter-out', input, '--out', output,
                                 '--folder-id', 'folder', '--owner-id', 'owner', *extra)
  check.call(status.success?, "convert-model #{extra.join(' ')} succeeds#{": #{text}" unless status.success?}")
  status.success? ? JSON.parse(File.read(output)) : nil
end

Dir.mktmpdir('reprefix-test') do |dir|
  spec = convert.call(dir)
  if spec
    cost = spec['pages'][0]['elements'][0]
    check.call(cost['columns'][0]['formula'] == '[COST_CENTER/ID]',
               'space/underscore lookalike is rewritten to the literal element name')
    check.call(cost['columns'][1]['formula'] == '[DIM/Label]',
               'an exact reference to another known element is preserved')
    check.call(spec['pages'][0]['elements'][1]['columns'][0]['formula'] == '[DIM/LABEL]',
               'an exact self-reference remains unchanged')
    dt = spec['pages'][0]['elements'][2]
    check.call(dt['columns'][0]['formula'] == '[Date/Date Key]',
               'views shape: an element whose name differs from its path tail is rewritten to the element name, as before')
    check.call(dt['columns'][1]['formula'] == '[Date/Month]',
               'views shape: a prefix equal to the element name is left alone')
  end
  spec = convert.call(dir, '--model-shape', 'views')
  check.call(spec && spec == convert.call(dir) , 'an explicit --model-shape views is identical to the default')
  spec = convert.call(dir, '--model-shape', 'pbi')
  if spec
    cost = spec['pages'][0]['elements'][0]
    check.call(cost['columns'][0]['formula'] == '[COST_CENTER/ID]' && cost['columns'][1]['formula'] == '[DIM/Label]',
               'pbi shape: the same-name cases are unchanged')
    dt = spec['pages'][0]['elements'][2]
    check.call(dt['columns'][0]['formula'] == '[DIM_DATE/Date Key]',
               'pbi shape: a physical-table prefix (path tail) on a renamed element is kept')
    check.call(dt['columns'][1]['formula'] == '[Date/Month]',
               'pbi shape: a prefix equal to the element name is left alone')
    # a prefix that matches nothing is rewritten to the path tail, not the element name
    raw['pages'][0]['elements'][2]['columns'] << { 'id' => 'dx', 'formula' => '[Friendly Date/Year]' }
    spec = convert.call(dir, '--model-shape', 'pbi')
    check.call(spec && spec['pages'][0]['elements'][2]['columns'][2]['formula'] == '[DIM_DATE/Year]',
               'pbi shape: an unknown prefix is rewritten to the path tail')
    spec = convert.call(dir, '--model-shape', 'views')
    check.call(spec && spec['pages'][0]['elements'][2]['columns'][2]['formula'] == '[Date/Year]',
               'views shape: the same unknown prefix is rewritten to the element name')
  end
end

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
