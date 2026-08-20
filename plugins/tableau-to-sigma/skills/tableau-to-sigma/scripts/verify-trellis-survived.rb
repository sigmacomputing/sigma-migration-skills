#!/usr/bin/env ruby
# Round-trip guard for native trellis (SUPERSEDES #451 card-trellis).
#
# Sigma accepts a POST with an element `trellis` property (200 OK) but SILENTLY
# STRIPS it on unsupported element kinds — the key is simply gone from the
# readback spec and the tile renders flat, with no error. build-charts-from-
# signals.rb records every trellis it emitted in native-trellis-emitted.json;
# this asserts each one still carries its `trellis` key (with the same axis) on
# the readback spec. A stripped trellis is a FAILURE to surface — never a silent
# "flat but green".
#
# Usage:
#   ruby verify-trellis-survived.rb --emitted <native-trellis-emitted.json> \
#        --spec <readback wb-spec JSON (GET /v2/workbooks/{id}/spec .spec)>
#
# Exit 0 = every emitted trellis survived; exit 1 = one or more were stripped
# (or the axis changed). Pure stdlib; no network.

require 'json'
require 'optparse'

begin
  require_relative 'lib/code_rep'
rescue LoadError
  require_relative '../lib/code_rep'
end

opts = {}
OptionParser.new do |p|
  p.on('--emitted PATH', 'native-trellis-emitted.json from build-charts') { |v| opts[:emitted] = v }
  p.on('--spec PATH', 'readback workbook spec JSON (the .spec object, or the full GET response)') { |v| opts[:spec] = v }
end.parse!

abort 'FATAL: --emitted and --spec are required' unless opts[:emitted] && opts[:spec]
unless File.exist?(opts[:emitted])
  # No sidecar = no trellis was emitted this run — nothing to verify (pass).
  puts 'verify-trellis-survived: no native-trellis-emitted.json (no trellis emitted) — nothing to assert'
  exit 0
end

emitted = JSON.parse(File.read(opts[:emitted]))
records = Array(emitted['elements'])
if records.empty?
  puts 'verify-trellis-survived: 0 emitted trellis records — nothing to assert'
  exit 0
end

raw  = JSON.parse(File.read(opts[:spec]))
spec = Sigma::CodeRep.document(raw['spec'].is_a?(Hash) ? raw['spec'] : raw)

# Index every flat workbook element by id.
by_id = Sigma::CodeRep.workbook_elements(spec).each_with_object({}) do |e, out|
  out[e['id']] = e if e['id']
end

fails = []
oks = []
records.each do |r|
  eid  = r['element_id']
  axis = r['axis'] # 'rowsBy' | 'columnsBy'
  el = by_id[eid]
  if el.nil?
    fails << "element #{eid.inspect} (#{r['name'].inspect}) NOT FOUND on the readback spec"
    next
  end
  tr = el['trellis']
  if !tr.is_a?(Hash) || tr[axis].nil? || Array(tr[axis]).empty?
    fails << "element #{eid.inspect} (#{r['name'].inspect}, kind #{el['kind'].inspect}) lost its trellis.#{axis} " \
             'on readback — Sigma STRIPPED it (unsupported kind or malformed). Route to the documented fallback ' \
             '(pie→donut / kpi→N siblings / pivot→own shelves / table→postpublish).'
  else
    oks << "#{eid} trellis.#{axis} survived (#{el['kind']})"
  end
end

oks.each { |m| puts "  OK   #{m}" }
if fails.empty?
  puts "verify-trellis-survived: PASS — all #{records.size} native trellis element(s) survived readback"
  exit 0
else
  warn "verify-trellis-survived: FAIL — #{fails.size}/#{records.size} trellis element(s) were STRIPPED:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
