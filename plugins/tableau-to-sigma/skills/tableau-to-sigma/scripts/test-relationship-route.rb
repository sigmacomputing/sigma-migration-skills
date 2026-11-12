#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Reused-DM relationship evidence route: eligibility (lib/relationship_route.rb),
# the emitter CLI (emit-relationship-map.rb), and the orchestrator wiring.
# Creds-free; the orchestrator part is a static check because driving its
# discovery path needs a live Tableau source.

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/relationship_route'

HERE = File.expand_path(__dir__)
FIXTURES = File.join(HERE, 'test-fixtures', 'relationship-map')

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

puts 'test-relationship-route — eligibility'
Dir.mktmpdir('relroute') do |work|
  check.(RelationshipRoute.eligible?(workdir: work, reuse_dm: 'dm-123'), 'an explicit --reuse-dm id is eligible')
  check.(!RelationshipRoute.eligible?(workdir: work, reuse_dm: :recommended), 'a bare --reuse-dm (recommended pick) is not')
  check.(!RelationshipRoute.eligible?(workdir: work, reuse_dm: nil), 'no --reuse-dm is not')
  check.(!RelationshipRoute.eligible?(workdir: work, reuse_dm: '  '), 'a blank id is not')
  File.write(File.join(work, 'posted-datamodels.jsonl'), "#{JSON.generate('id' => 'dm-123')}\nnot json\n")
  check.(!RelationshipRoute.eligible?(workdir: work, reuse_dm: 'dm-123'),
         'a model this workdir posted (converter output) is not eligible')
  check.(RelationshipRoute.eligible?(workdir: work, reuse_dm: 'dm-999'), 'another explicit id still is')

  check.(RelationshipRoute.current(work).nil?, 'no state file → no route')
  File.write(File.join(work, 'migrate-state.json'),
             JSON.generate('relationship_route' => 'reused-dm-evidence', 'reused_dm' => true, 'data_model_id' => 'dm-777'))
  check.(RelationshipRoute.current(work) == RelationshipRoute::EVIDENCE, 'route is read from migrate-state.json')
  # Gate-time re-check (review C1): the route only stands while the state says
  # the shipped model IS the reused one and this workdir never posted it.
  File.write(File.join(work, 'migrate-state.json'),
             JSON.generate('relationship_route' => 'reused-dm-evidence', 'reused_dm' => false, 'data_model_id' => 'dm-777'))
  check.(RelationshipRoute.current(work).nil?, 'a route left behind after reuse was abandoned is ignored')
  File.write(File.join(work, 'migrate-state.json'),
             JSON.generate('relationship_route' => 'reused-dm-evidence', 'reused_dm' => true, 'data_model_id' => 'dm-123'))
  check.(RelationshipRoute.current(work).nil?, 'a route over a model this workdir posted is ignored')
  File.write(File.join(work, 'migrate-state.json'), JSON.generate('relationship_route' => 'reused-dm-evidence', 'reused_dm' => true))
  check.(RelationshipRoute.current(work).nil?, 'a route with no recorded data model is ignored')
  File.write(File.join(work, 'migrate-state.json'), JSON.generate('relationship_route' => 'anything-else'))
  check.(RelationshipRoute.current(work).nil?, 'an unknown route value is ignored')
  File.write(File.join(work, 'migrate-state.json'), '{')
  check.(RelationshipRoute.current(work).nil?, 'an unreadable state file → no route')
end

puts ''
puts 'test-relationship-route — settle (reuse abandoned after the pre-POST check)'
s = RelationshipRoute.settle(route: RelationshipRoute::EVIDENCE, reused: true, coverage_deferred: true)
check.(s == { route: RelationshipRoute::EVIDENCE, stop: false }, "reuse kept: the route stands (got #{s})")
s = RelationshipRoute.settle(route: RelationshipRoute::EVIDENCE, reused: false, coverage_deferred: true)
check.(s == { route: nil, stop: true },
       "reuse abandoned after the coverage stop was deferred: route cleared and the strict STOP fires (got #{s})")
s = RelationshipRoute.settle(route: RelationshipRoute::EVIDENCE, reused: false, coverage_deferred: false)
check.(s == { route: nil, stop: false }, "reuse abandoned with complete coverage: route cleared, no stop (got #{s})")
s = RelationshipRoute.settle(route: nil, reused: false, coverage_deferred: false)
check.(s == { route: nil, stop: false }, "strict route untouched (got #{s})")

puts ''
puts 'test-relationship-route — refresh_reused_model (--finalize live re-read)'
Dir.mktmpdir('relroute-refresh') do |work|
  path = File.join(work, 'dm-spec-reused.json')
  File.write(path, JSON.generate('pages' => [{ 'elements' => [{ 'id' => 'old' }] }]))
  ok, msg = RelationshipRoute.refresh_reused_model(work, fetch: -> { { 'pages' => [{ 'elements' => [{ 'id' => 'live' }] }] } })
  check.(ok && JSON.parse(File.read(path))['pages'][0]['elements'][0]['id'] == 'live',
         "a successful re-read replaces the pass-1 copy (#{msg})")
  ok, msg = RelationshipRoute.refresh_reused_model(work, fetch: -> { raise IOError, 'connection reset' })
  check.(!ok && !File.exist?(path) && msg.include?('connection reset'),
         "a failed re-read removes the pass-1 copy so the gate blocks instead of judging stale evidence (#{msg})")
  File.write(path, '{}')
  ok, = RelationshipRoute.refresh_reused_model(work, fetch: -> { { 'error' => 'nope' } })
  check.(!ok && !File.exist?(path), 'a re-read with no pages is a failure too')
end

puts ''
puts 'test-relationship-route — emit-relationship-map.rb'
emit = ->(*args) { Open3.capture3('ruby', File.join(HERE, 'emit-relationship-map.rb'), *args) }
Dir.mktmpdir('relroute-emit') do |work|
  %w[workbook-content.twb dm-spec-reused.json dashboard-scope.json].each do |f|
    FileUtils.cp(File.join(FIXTURES, 'replaced-key', f), work)
  end
  out, err, st = emit.('--workdir', work)
  map_path = File.join(work, 'relationship-map.json')
  map = File.exist?(map_path) ? JSON.parse(File.read(map_path)) : {}
  check.(st.success? && map['route'] == 'reused-dm-evidence', "emitter writes relationship-map.json (exit #{st.exitstatus}: #{err.strip})")
  check.(out.include?('1 replaced') && out.include?('PENDING') && out.include?('probe-join-keys.rb'),
         "emitter prints counts, the pending status and the probe command (got #{out.lines.first(4).join.strip})")
  replaced = map['entries'].find { |e| e['disposition'] == 'replaced' }
  _, err, st = emit.('--workdir', work, '--annotate', replaced['index'].to_s, '--reason', 'joined on the alternate key by design')
  map = JSON.parse(File.read(map_path))
  check.(st.success? && map['entries'][replaced['index']]['reason'] == 'joined on the alternate key by design',
         "--annotate records a reason on one entry (exit #{st.exitstatus}: #{err.strip})")
  map['dm_edges'].each { |d| d['probe'] = { 'status' => 'pass', 'unique' => { 'total' => 1, 'distinct' => 1 }, 'unmatched' => 0 } }
  File.write(map_path, JSON.generate(map))
  emit.('--workdir', work)
  map = JSON.parse(File.read(map_path))
  check.(map['entries'][replaced['index']]['reason'] == 'joined on the alternate key by design' &&
         map['dm_edges'].all? { |d| d['probe'] && d['probe']['status'] == 'pass' },
         're-emitting keeps reasons and still-valid probes')
  _, _, st = emit.('--workdir', work, '--annotate', '99', '--reason', 'x')
  check.(st.exitstatus == 2, 'annotating a missing entry is bad input (exit 2)')
  _, _, st = emit.('--workdir', work, '--annotate', '0', '--reason', ' ')
  check.(st.exitstatus == 2, 'an empty reason is bad input (exit 2)')
  File.delete(File.join(work, 'dm-spec-reused.json'))
  _, err, st = emit.('--workdir', work)
  check.(st.exitstatus == 2 && err.include?('dm-spec-reused.json'), 'a missing reused model is bad input (exit 2) and named')
end

Dir.mktmpdir('relroute-resolution') do |work|
  %w[workbook-content.twb dm-spec-reused.json dashboard-scope.json].each do |f|
    FileUtils.cp(File.join(FIXTURES, 'extract-renamed', f), work)
  end
  out, = emit.('--workdir', work)
  check.(out.include?('0 matched'), "without the run's table resolution the extract tables cannot match (got #{out.lines.first.strip})")
  out, err, st = emit.('--workdir', work, '--db', 'ANALYTICS', '--schema', 'LANDED', '--table-mapping', 'FACT_SALES=SALES_WIDE',
                       '--table-mapping', 'FACT_ORDERS=SALES_WIDE', '--table-mapping', 'DIM_CUSTOMER=CUSTOMERS')
  check.(st.success? && out.include?('2 matched') && out.include?('PASS'),
         "--db/--schema/--table-mapping resolve tables like the converter (got #{(out + err).lines.first.strip})")
  File.write(File.join(work, 'migrate-state.json'), JSON.generate(
    'relationship_resolution' => JSON.parse(File.read(File.join(FIXTURES, 'extract-renamed', 'resolution.json')))
  ))
  out, = emit.('--workdir', work)
  check.(out.include?('2 matched'), "the persisted run resolution (migrate-state.json) is used when no flags are given (got #{out.lines.first.strip})")
end

puts ''
puts 'test-relationship-route — orchestrator wiring (static)'
mt = File.read(File.join(HERE, 'migrate-tableau.rb'), encoding: 'utf-8')
_, err, st = Open3.capture3('ruby', '-c', File.join(HERE, 'migrate-tableau.rb'))
check.(st.success?, "migrate-tableau.rb parses (#{err.strip})")
check.(mt.include?('relationship_route = ') && mt.include?('RelationshipRoute.eligible?(workdir: WORK, reuse_dm: opts[:reuse_dm])'),
       'pass 1 derives the route from the explicit --reuse-dm id')
check.(mt.include?('rel_cov_deferred = true') && mt.include?('relationship_coverage_stop.call unless rel_cov_deferred'),
       'the pre-POST coverage stop is deferred (not skipped) on the evidence route')
check.(mt.include?('RelationshipRoute.settle(route: relationship_route, reused: !reuse_dm_id.nil?, coverage_deferred: rel_cov_deferred)'),
       'the route is settled once the reuse decision is final (abandoned reuse clears it and fires the deferred stop)')
check.(mt.include?("'relationship_route' => relationship_route"), 'the settled route is persisted in migrate-state.json')
check.(mt.include?("'relationship_resolution' => (relationship_route ? relationship_resolution : nil)"),
       "the run's table resolution (db / schema / table mapping) is persisted for the gates")
check.(mt.scan('relationship_route = RelationshipRoute.eligible?(workdir: WORK, reuse_dm: opts[:reuse_dm])').size == 2,
       'the route is re-derived after a target-model plan can set reuse_dm_id')
check.(mt.include?("File.join(HERE, 'emit-relationship-map.rb')"), 'the orchestrator emits the map on the reuse path')

puts ''
if fails.empty?
  puts 'test-relationship-route.rb: ALL PASS'
  exit 0
end
puts "test-relationship-route.rb: #{fails.size} FAILURE(S)"
fails.each { |f| puts "  - #{f}" }
exit 1
