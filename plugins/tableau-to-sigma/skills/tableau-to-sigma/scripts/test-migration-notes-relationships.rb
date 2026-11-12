#!/usr/bin/env ruby
# frozen_string_literal: true
#
# migration-notes.rb lists every relationship deviation of a reused data model
# (relationship-map.json beside --out) with its evidence; no map → no section.

require 'json'
require 'open3'
require 'tmpdir'
require_relative 'test-fixtures/relationship-map/workdir_helper'

HERE = File.expand_path(__dir__)
fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

notes = lambda do |work|
  File.write(File.join(work, 'conv-meta.json'), JSON.generate('model' => { 'pages' => [] }))
  File.write(File.join(work, 'chart-specs.json'), JSON.generate('pages' => []))
  File.write(File.join(work, 'wb-spec.json'), JSON.generate('pages' => []))
  out = File.join(work, 'migration-notes.md')
  _, err, st = Open3.capture3('ruby', File.join(HERE, 'migration-notes.rb'),
                              '--conv-meta', File.join(work, 'conv-meta.json'),
                              '--chart-specs', File.join(work, 'chart-specs.json'),
                              '--wb-spec', File.join(work, 'wb-spec.json'), '--out', out)
  [st, err, File.file?(out) ? File.read(out) : '']
end

puts 'test-migration-notes-relationships'
Dir.mktmpdir('notes-relmap') do |work|
  RelationshipMapWorkdir.build(work, 'replaced-key', parity: ['Revenue by Customer'])
  map_path = File.join(work, 'relationship-map.json')
  map = JSON.parse(File.read(map_path))
  map['entries'].find { |e| e['disposition'] == 'replaced' }['reason'] = 'joined on the alternate key by design'
  File.write(map_path, JSON.generate(map))
  st, err, md = notes.call(work)
  check.(st.success?, "migration-notes runs (#{err.strip.lines.last})")
  check.(md.include?('## Relationship deviations (reused data model)'), 'the deviations section is present')
  check.(md.include?('1 matched, 1 replaced, 0 dropped, 0 disconnected, 0 extra — PASS'),
         "the section states the counts and the evidence status (got #{md[/Judged.*$/]})")
  row = md.lines.find { |l| l.include?('| replaced |') }.to_s
  check.(row.include?('ANALYTICS.PUBLIC.ORDERS ↔ ANALYTICS.PUBLIC.DIM_CUSTOMER') &&
         row.include?('CUSTOMER_KEY → CUSTOMER_ALT_KEY') && row.include?('probe pass') &&
         row.include?('parity: Revenue by Customer') && row.include?('joined on the alternate key by design'),
         "one row per deviation with tables, model keys, probe, parity and reason (got #{row.strip})")
  check.(md.lines.none? { |l| l.include?('| matched |') }, 'matched relationships are not listed as deviations')
end
Dir.mktmpdir('notes-relmap') do |work|
  RelationshipMapWorkdir.build(work, 'dropped-unused')
  _, _, md = notes.call(work)
  row = md.lines.find { |l| l.include?('| dropped |') }.to_s
  check.(row.include?('field use pass'), "a dropped table row shows its field-use evidence (got #{row.strip})")
end
Dir.mktmpdir('notes-relmap') do |work|
  _, _, md = notes.call(work)
  check.(!md.include?('Relationship deviations'), 'no relationship-map.json → no section')
end

puts ''
if fails.empty?
  puts 'test-migration-notes-relationships.rb: ALL PASS'
  exit 0
end
puts "test-migration-notes-relationships.rb: #{fails.size} FAILURE(S)"
fails.each { |f| puts "  - #{f}" }
exit 1
