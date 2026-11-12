#!/usr/bin/env ruby
# frozen_string_literal: true

# apply-dim-preserve.rb — keep dimension members that have no fact rows
# (lib/dim_preserve.rb): a tile grouped by a related dimension table's field
# whose Tableau view CSV shows a member with every measure blank/0 is re-based
# on that dimension table LEFT-joined to the fact. migrate-tableau.rb runs the
# same pass automatically after the FIXED-LOD helper pass; this CLI is the
# offline / re-entry form of it.
#
#   ruby scripts/apply-dim-preserve.rb --workdir <WORK> --spec wb-spec.json [--out PATH]
#
# Reads <WORK>/dm-readback.json, metrics.json, chart-provenance.json and the
# view CSVs named in get-workbook.json. Writes the canonical workbook spec
# (default: overwrite --spec). Exit 0 on a readable input; prints what it built.

require 'json'
require 'optparse'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'workbook_code'
require 'dim_preserve'
require 'layout_merge'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:dir] = v }
  p.on('--spec PATH') { |v| opts[:spec] = v }
  p.on('--out PATH') { |v| opts[:out] = v }
end.parse!
abort('usage: apply-dim-preserve.rb --workdir DIR --spec PATH [--out PATH]') unless opts[:dir] && opts[:spec]

ctx = DimPreserve.context(opts[:dir])
abort("no #{File.join(opts[:dir], 'dm-readback.json')} — read the data model back first") unless ctx
spec = WorkbookCode.legacy_view(WorkbookCode.canonicalize(JSON.parse(File.read(opts[:spec], encoding: 'UTF-8'))))
res = DimPreserve.apply!(spec, ctx)
out = WorkbookCode.canonicalize(spec)
doc = WorkbookCode.document(out)
fill = LayoutMerge.complete_layout(doc['layout'], WorkbookCode.elements(out))
doc['layout'] = fill[:xml] if fill[:xml]
File.write(opts[:out] || opts[:spec], JSON.pretty_generate(out) + "\n")
res[:built].each { |b| puts "built #{b['clone']} (#{b['note']}) for #{b['tiles'].join(', ')}" }
fill[:placed].each { |pl| puts "placed #{pl['id']} on #{pl['page']} (#{pl['how']})" }
res[:notes].each { |n| puts "note: #{n}" }
puts 'no tile needs unmatched dimension members' if res[:built].empty?
