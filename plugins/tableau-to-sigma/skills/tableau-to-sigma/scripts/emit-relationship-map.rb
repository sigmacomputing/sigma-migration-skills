#!/usr/bin/env ruby
# frozen_string_literal: true
#
# emit-relationship-map.rb — derive <workdir>/relationship-map.json for the
# reused-DM relationship evidence route (see lib/relationship_map.rb) and print
# where it stands. Re-running keeps reasons and every probe whose edge is
# unchanged.
#
# Inputs (all from the workdir): workbook-content.twb, dm-spec-reused.json
# (the live reused model the orchestrator read back), dashboard-scope.json
# (optional — migrated dashboards), parity-final.json (optional — for the
# summary only).
#
# Usage:
#   ruby scripts/emit-relationship-map.rb --workdir <WORK> [--out PATH]
#     [--db DB --schema SCHEMA --table-mapping SRC=TABLE ...]
#     (the run's table resolution, as the converter used it; without flags the
#     orchestrator's persisted migrate-state.json relationship_resolution)
#   ruby scripts/emit-relationship-map.rb --workdir <WORK> --annotate <INDEX> --reason "<why>"
#     (a reason is shown in the report; it never satisfies evidence)
#
# Exit codes: 0 = written; 2 = bad input.

require 'json'
require 'optparse'
require_relative 'lib/workdir_guard' # refuse a workdir inside the installed plugin
require_relative 'lib/relationship_map'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:workdir] = WorkdirGuard.check!(File.expand_path(v), '--workdir') }
  p.on('--out PATH') { |v| opts[:out] = File.expand_path(v) }
  p.on('--annotate INDEX', Integer) { |v| opts[:annotate] = v }
  p.on('--reason TEXT') { |v| opts[:reason] = v }
  p.on('--db NAME') { |v| opts[:db] = v }
  p.on('--schema NAME') { |v| opts[:schema] = v }
  p.on('--table-mapping PAIR') do |v|
    k, val = v.split('=', 2)
    (opts[:table_mapping] ||= {})[k.to_s.strip] = val.to_s.strip
  end
end.parse!

bad = lambda do |msg|
  warn "FATAL: #{msg}"
  exit 2
end
work = opts[:workdir] || bad.call('usage: emit-relationship-map.rb --workdir <WORK> [--out PATH | --annotate N --reason R]')
out_path = opts[:out] || File.join(work, 'relationship-map.json')
read_json = lambda do |path, required|
  return nil unless File.file?(path) || required
  bad.call("required input missing: #{path}") unless File.file?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  bad.call("#{path} is malformed JSON: #{e.message.lines.first.to_s.strip[0, 120]}")
end

if opts[:annotate]
  bad.call('--annotate requires a non-empty --reason') if opts[:reason].to_s.strip.empty?
  map = read_json.call(out_path, true)
  entry = Array(map['entries']).find { |e| e['index'] == opts[:annotate] }
  bad.call("no relationship-map entry at index #{opts[:annotate]}") unless entry
  entry['reason'] = opts[:reason].strip
  RelationshipMap.write(out_path, map)
  puts "relationship-map: entry #{opts[:annotate]} (#{entry['left']} ↔ #{entry['right']}, #{entry['disposition']}) — reason recorded"
  exit 0
end

twb_path = File.join(work, 'workbook-content.twb')
bad.call("required input missing: #{twb_path}") unless File.file?(twb_path)
twb_xml = File.read(twb_path, encoding: 'bom|utf-8')
dm_spec = read_json.call(File.join(work, 'dm-spec-reused.json'), true)
scope = read_json.call(File.join(work, 'dashboard-scope.json'), false)
parity = read_json.call(File.join(work, 'parity-final.json'), false)
dashboards = RelationshipMap.scoped_dashboards(scope)
resolution = if opts[:db] || opts[:schema] || opts[:table_mapping]
               { 'db' => opts[:db], 'schema' => opts[:schema], 'table_mapping' => opts[:table_mapping] || {} }
             else
               (read_json.call(File.join(work, 'migrate-state.json'), false) || {})['relationship_resolution']
             end

fresh = begin
  RelationshipMap.derive(twb_xml: twb_xml, dm_spec: dm_spec, dashboards: dashboards, resolution: resolution)
rescue StandardError => e
  bad.call("relationship map could not be derived: #{e.class}: #{e.message.to_s[0, 160]}")
end
prior = File.file?(out_path) ? (JSON.parse(File.read(out_path)) rescue nil) : nil
map = RelationshipMap.merge_prior(fresh, prior)
RelationshipMap.write(out_path, map)

result = RelationshipMap.evaluate(map, twb_xml: twb_xml, dm_spec: dm_spec, dashboards: dashboards,
                                       parity: parity, final: false, resolution: resolution)
puts "relationship-map: #{RelationshipMap.summary_line(result)} — #{result['status'].upcase} -> #{out_path}"
result['blockers'].each { |b| puts "  - #{b['kind']}: #{b['reason']}" }
if result['blockers'].any? { |b| b['kind'] == 'unprobed' }
  puts "  prove the edges: ruby scripts/probe-join-keys.rb --workdir #{work} --relationship-map #{out_path} --connection-id <id>"
end
exit 0
