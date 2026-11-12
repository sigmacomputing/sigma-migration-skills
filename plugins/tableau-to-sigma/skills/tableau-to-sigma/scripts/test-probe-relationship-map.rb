#!/usr/bin/env ruby
# frozen_string_literal: true
#
# probe-join-keys.rb --relationship-map: offline (--fixture) contract. Each DM
# edge a deviation relies on gets a probe block (target unique on its key, 0
# source keys with no match); join-plan.json is never touched (gate 16 keeps
# its own ledger).

require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lib/relationship_map'

HERE = File.expand_path(__dir__)
FIXTURES = File.join(HERE, 'test-fixtures', 'relationship-map')

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

puts 'test-probe-relationship-map'

Dir.mktmpdir('probe-relmap') do |work|
  src = File.join(FIXTURES, 'extra-edge')
  twb = File.read(File.join(src, 'workbook-content.twb'), encoding: 'bom|utf-8')
  dm = JSON.parse(File.read(File.join(src, 'dm-spec-reused.json')))
  els = dm['pages'][0]['elements']
  # orders -> cust on a different key makes a replaced entry beside the extra
  # prod -> cust edge (whose key is later given a quote the identifier oracle
  # refuses). A renamed key column still resolves through its formula.
  cust = els.find { |e| e['id'] == 'cust' }
  cust['columns'] << { 'id' => 'cust-alt', 'formula' => '[DIM_CUSTOMER/CUSTOMER_ALT_KEY]', 'name' => 'Alt Customer #' }
  els.find { |e| e['id'] == 'orders' }['relationships'][0]['keys'][0]['targetColumnId'] = 'cust-alt'
  dm['folderId'] = 'folder-1'
  File.write(File.join(work, 'dm-spec-reused.json'), JSON.generate(dm))
  map = RelationshipMap.derive(twb_xml: twb, dm_spec: dm)
  map_path = File.join(work, 'relationship-map.json')
  RelationshipMap.write(map_path, map)
  join_plan = File.join(work, 'join-plan.json')
  File.write(join_plan, "{\"entries\":[]}\n")
  before = File.read(join_plan)

  fx = File.join(work, 'fixture')
  Dir.mkdir(fx)
  File.write(File.join(fx, 'edge-orders__cust.json'), JSON.generate('total' => 10, 'distinct' => 10, 'unmatched' => 0))
  File.write(File.join(fx, 'edge-prod__cust.json'), JSON.generate('total' => 10, 'distinct' => 10, 'unmatched' => 2))
  run = lambda do
    Open3.capture3('ruby', File.join(HERE, 'probe-join-keys.rb'), '--workdir', work,
                   '--relationship-map', map_path, '--fixture', fx)
  end
  out, err, st = run.call
  doc = JSON.parse(File.read(map_path))
  probe = ->(id) { doc['dm_edges'].find { |d| d['edge_id'] == id }['probe'] }
  check.(st.exitstatus == 2, "a failing edge exits 2 (got #{st.exitstatus}: #{err.lines.last.to_s.strip})")
  check.(probe.('orders->cust')&.dig('status') == 'pass' && probe.('orders->cust')['unique'] == { 'total' => 10, 'distinct' => 10 },
         "the replaced edge is probed and passes (got #{probe.('orders->cust').inspect})")
  check.(probe.('prod->cust')&.dig('status') == 'fail' && probe.('prod->cust')['unmatched'] == 2,
         "the extra edge with unmatched keys fails (got #{probe.('prod->cust').inspect})")
  check.(probe.('orders->prod').nil?, 'a matched edge needs no probe and is left alone')
  check.(probe.('orders->cust').to_h.dig('sql', 'unmatched').to_s.include?('NOT EXISTS'),
         'the unmatched-key SQL is recorded on the probe')
  check.(probe.('orders->cust').to_h.dig('sql', 'totals').to_s.include?('COUNT(DISTINCT CUSTOMER_ALT_KEY)'),
         'a renamed key column probes its warehouse column (formula passthrough), not its display name')
  check.(File.read(join_plan) == before, 'join-plan.json is untouched')

  stamp = probe.('orders->cust')['probed_at']
  File.write(File.join(fx, 'edge-prod__cust.json'), JSON.generate('total' => 10, 'distinct' => 10, 'unmatched' => 0))
  doc['dm_edges'].find { |d| d['edge_id'] == 'prod->cust' }['probe'] = nil
  RelationshipMap.write(map_path, doc)
  _, _, st = run.call
  doc = JSON.parse(File.read(map_path))
  check.(st.exitstatus.zero? && probe.('orders->cust').to_h['probed_at'] == stamp && !stamp.nil?,
         "already-probed edges are not re-probed; all passing exits 0 (got exit #{st.exitstatus})")

  # A failed probe is re-run (after a warehouse fix) instead of standing
  # until the model changes; a passing one is kept.
  doc['dm_edges'].find { |d| d['edge_id'] == 'prod->cust' }['probe'] =
    { 'status' => 'fail', 'unique' => { 'total' => 10, 'distinct' => 10 }, 'unmatched' => 2 }
  RelationshipMap.write(map_path, doc)
  _, _, st = run.call
  doc = JSON.parse(File.read(map_path))
  check.(st.exitstatus.zero? && probe.('prod->cust').to_h['status'] == 'pass',
         "a failed edge is re-probed on the next run (got exit #{st.exitstatus}, #{probe.('prod->cust').inspect})")

  # Custom SQL elements are wrapped as an aliased subquery with any trailing
  # ';' or line comment neutralized (Postgres/Redshift need the alias).
  prod_sql = els.find { |e| e['id'] == 'prod' }
  prod_sql['source'] = { 'kind' => 'sql', 'connectionId' => 'conn-1',
                         'statement' => "SELECT PRODUCT_KEY, CUSTOMER_KEY FROM PUBLIC.PRODUCTS; -- active only" }
  File.write(File.join(work, 'dm-spec-reused.json'), JSON.generate(dm))
  sql_map = RelationshipMap.derive(twb_xml: twb, dm_spec: dm)
  RelationshipMap.write(map_path, sql_map)
  run.call
  sql = JSON.parse(File.read(map_path))['dm_edges'].find { |d| d['edge_id'] == 'prod->cust' }['probe'].to_h['sql'].to_h
  check.(sql['unmatched'].to_s.include?("FROM (SELECT PRODUCT_KEY, CUSTOMER_KEY FROM PUBLIC.PRODUCTS -- active only\n) s ") &&
         !sql['unmatched'].to_s.include?(';'),
         "a Custom SQL source is an aliased subquery without its trailing ';' (got #{sql['unmatched']})")
  els.find { |e| e['id'] == 'prod' }['source'] = { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1',
                                                   'path' => %w[ANALYTICS PUBLIC DIM_PRODUCT] }

  # Review (Bugbot): a probe result missing a count is never proof — it is an
  # error, not a pass or a fail.
  doc['dm_edges'].each { |d| d['probe'] = nil }
  RelationshipMap.write(map_path, doc)
  File.write(File.join(fx, 'edge-orders__cust.json'), JSON.generate('total' => 0, 'distinct' => 0))
  File.write(File.join(fx, 'edge-prod__cust.json'), JSON.generate('total' => '10', 'distinct' => 10, 'unmatched' => 'n/a'))
  _, _, st = run.call
  doc = JSON.parse(File.read(map_path))
  check.(st.exitstatus == 3 && probe.('orders->cust').to_h['status'] == 'error' && probe.('prod->cust').to_h['status'] == 'error',
         "a result with a missing or non-numeric count is a probe error, never proof (got exit #{st.exitstatus}, " \
         "#{probe.('orders->cust').to_h['status']}/#{probe.('prod->cust').to_h['status']})")
  File.write(File.join(fx, 'edge-orders__cust.json'), JSON.generate('total' => 10, 'distinct' => 10, 'unmatched' => 0))

  prod = els.find { |e| e['id'] == 'prod' }
  prod['columns'].find { |c| c['id'] == 'prod-customer_key' }['formula'] = '[DIM_PRODUCT/CUSTOMER"KEY]'
  File.write(File.join(work, 'dm-spec-reused.json'), JSON.generate(dm))
  RelationshipMap.write(map_path, RelationshipMap.derive(twb_xml: twb, dm_spec: dm))
  _, _, st = run.call
  doc = JSON.parse(File.read(map_path))
  refused = doc['dm_edges'].find { |d| d['edge_id'] == 'prod->cust' }['probe']
  check.(st.exitstatus == 3 && refused&.dig('status') == 'error' && refused['sql'].nil?,
         "an identifier the oracle refuses errors with no SQL sent, exit 3 (got exit #{st.exitstatus}, #{refused.inspect})")
end

puts ''
if fails.empty?
  puts 'test-probe-relationship-map.rb: ALL PASS'
  exit 0
end
puts "test-probe-relationship-map.rb: #{fails.size} FAILURE(S)"
fails.each { |f| puts "  - #{f}" }
exit 1
