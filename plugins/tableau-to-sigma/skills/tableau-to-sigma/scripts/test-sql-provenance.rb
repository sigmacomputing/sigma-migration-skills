#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'lib/sql_provenance'

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

element = lambda do |id, name, sql|
  {
    'id' => id, 'name' => name, 'kind' => 'table',
    'source' => { 'kind' => 'sql', 'connectionId' => 'conn', 'statement' => sql }
  }
end

Dir.mktmpdir('sql-provenance') do |dir|
  twb = File.join(dir, 'source.twb')
  dm = File.join(dir, 'dm.json')
  meta = File.join(dir, 'conv-meta.json')
  File.write(twb, <<~XML)
    <workbook><datasources><datasource><connection>
      <relation type="text"><![CDATA[SELECT order_id, amount FROM orders]]></relation>
    </connection></datasource></datasources></workbook>
  XML
  File.write(dm, JSON.generate(
    'pages' => [{
      'elements' => [
        element.call('source-sql', 'Source SQL', 'SELECT order_id, amount FROM orders'),
        element.call('lod', 'Revenue LOD Helper', 'SELECT region, SUM(amount) FROM orders GROUP BY region'),
        element.call('mystery', 'Mystery',
                     'SELECT secret, COUNT(*) FROM nowhere GROUP BY secret')
      ]
    }]
  ))
  File.write(meta, JSON.generate(
    'sqlProvenance' => [{
      'elementId' => 'lod', 'originType' => 'generated-lod',
      'statement' => 'SELECT region, SUM(amount) FROM orders GROUP BY region'
    }]
  ))
  result = SqlProvenance.evaluate(dm_spec_path: dm, metadata_path: meta, twb_path: twb)
  by_id = result['sql_elements'].to_h { |row| [row['element_id'], row] }
  check.call(by_id['source-sql']['origin_type'] == 'source-custom-sql',
             'source Custom SQL is attributed to the Tableau relation')
  check.call(by_id['lod']['origin_type'] == 'generated-lod',
             'generated grouped helper is labeled by the converter ledger')
  check.call(result['status'] == 'fail' && by_id['mystery']['status'] == 'fail',
             'unrecognized SQL is blocked instead of appearing as an invented table')

  overrides = File.join(dir, 'sql-provenance-overrides.json')
  proof = File.join(dir, 'semantic-proof.json')
  File.write(proof, JSON.generate('match' => true, 'checks' => [{ 'name' => 'row-count', 'match' => true }]))
  File.write(overrides, JSON.generate(
    'entries' => [{
      'element_id' => 'mystery', 'origin_type' => 'generated-manual',
      'reason' => 'operator-proven semantic rewrite', 'proof' => proof
    }]
  ))
  result = SqlProvenance.evaluate(dm_spec_path: dm, metadata_path: meta,
                                  twb_path: twb, overrides_path: overrides)
  check.call(result['status'] == 'pass', 'a reasoned explicit override makes every SQL element accountable')

  # A live readback (finalize, or a reused DM) carries server-assigned element
  # ids, so the converter ledger is found by element name — still bound to the
  # exact statement it recorded.
  readback = File.join(dir, 'dm-readback.json')
  lod_sql = 'SELECT region, SUM(amount) FROM orders GROUP BY region'
  File.write(readback, JSON.generate(
    'pages' => [{
      'elements' => [
        element.call('srv-1', 'Revenue LOD Helper', lod_sql),
        element.call('srv-2', 'Edited Helper', 'SELECT region, MAX(amount) FROM orders GROUP BY region')
      ]
    }]
  ))
  File.write(meta, JSON.generate(
    'sqlProvenance' => [
      { 'elementId' => 'lod', 'elementName' => 'Revenue LOD Helper',
        'originType' => 'generated-lod', 'statement' => lod_sql },
      { 'elementId' => 'edit', 'elementName' => 'Edited Helper',
        'originType' => 'generated-lod', 'statement' => lod_sql }
    ]
  ))
  result = SqlProvenance.evaluate(dm_spec_path: readback, metadata_path: meta, twb_path: twb)
  by_id = result['sql_elements'].to_h { |row| [row['element_id'], row] }
  check.call(by_id['srv-1']['origin_type'] == 'generated-lod',
             'a readback helper with a server-assigned id is attributed by element name')
  check.call(by_id['srv-2']['status'] == 'fail',
             'a name match never attributes a statement the ledger did not record')

  File.write(meta, JSON.generate(
    'sqlProvenance' => [
      { 'elementId' => 'a', 'elementName' => 'Revenue LOD Helper', 'originType' => 'generated-lod', 'statement' => lod_sql },
      { 'elementId' => 'b', 'elementName' => 'Revenue LOD Helper', 'originType' => 'generated-lod', 'statement' => lod_sql }
    ]
  ))
  result = SqlProvenance.evaluate(dm_spec_path: readback, metadata_path: meta, twb_path: twb)
  check.call(result['sql_elements'].find { |row| row['element_id'] == 'srv-1' }['status'] == 'fail',
             'an ambiguous ledger name does not attribute anything')

  # A pass-1 override keyed by the converter's element id still applies to the
  # readback element (server id), by its name or through the ledger's name match.
  mystery_sql = 'SELECT secret, COUNT(*) FROM nowhere GROUP BY secret'
  File.write(readback, JSON.generate('pages' => [{ 'elements' => [element.call('srv-7', 'Mystery', mystery_sql)] }]))
  File.write(meta, JSON.generate(
    'sqlProvenance' => [{ 'elementId' => 'mystery', 'elementName' => 'Mystery',
                          'originType' => 'unattributed', 'statement' => mystery_sql }]
  ))
  override_entry = { 'element_id' => 'mystery', 'origin_type' => 'generated-manual',
                     'reason' => 'operator-proven semantic rewrite', 'proof' => proof }
  [override_entry.merge('element_name' => 'Mystery'), override_entry].each do |entry|
    File.write(overrides, JSON.generate('entries' => [entry]))
    result = SqlProvenance.evaluate(dm_spec_path: readback, metadata_path: meta,
                                    twb_path: twb, overrides_path: overrides)
    check.call(result['status'] == 'pass',
               "a pass-1 override (#{entry.key?('element_name') ? 'id + name' : 'converter id only'}) survives the readback")
  end

  File.write(readback, JSON.generate(
    'pages' => [{ 'elements' => [
      element.call('srv-7', 'Mystery', mystery_sql),
      element.call('srv-8', 'Mystery', mystery_sql)
    ] }]
  ))
  File.write(meta, JSON.generate(
    'sqlProvenance' => [
      { 'elementId' => 'mystery', 'elementName' => 'Mystery',
        'originType' => 'unattributed', 'statement' => mystery_sql },
      { 'elementId' => 'other', 'elementName' => 'Mystery',
        'originType' => 'unattributed', 'statement' => mystery_sql }
    ]
  ))
  File.write(overrides, JSON.generate(
    'entries' => [override_entry.merge('element_name' => 'Mystery')]
  ))
  result = SqlProvenance.evaluate(dm_spec_path: readback, metadata_path: meta,
                                  twb_path: twb, overrides_path: overrides)
  check.call(result['status'] == 'fail' &&
             result['sql_elements'].all? { |row| row['status'] == 'fail' },
             'an id-targeted override does not leak across an ambiguous readback name')

  # One ledger entry, two same-named readback elements: neither the ledger's
  # converter id nor a name-keyed override may pick one of them.
  [{ 'sqlProvenance' => [{ 'elementId' => 'mystery', 'elementName' => 'Mystery',
                           'originType' => 'unattributed', 'statement' => mystery_sql }] },
   { 'sqlProvenance' => [] }].zip([override_entry, override_entry.merge('element_id' => nil, 'element_name' => 'Mystery')])
                             .each do |ledger, entry|
    File.write(meta, JSON.generate(ledger))
    File.write(overrides, JSON.generate('entries' => [entry]))
    result = SqlProvenance.evaluate(dm_spec_path: readback, metadata_path: meta,
                                    twb_path: twb, overrides_path: overrides)
    check.call(result['sql_elements'].all? { |row| row['status'] == 'fail' },
               "a #{entry['element_id'] ? 'converter-id' : 'name-keyed'} override does not attribute duplicate readback names")
  end
end

if fails.empty?
  puts 'ALL PASS'
  exit 0
end
warn "#{fails.length} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
