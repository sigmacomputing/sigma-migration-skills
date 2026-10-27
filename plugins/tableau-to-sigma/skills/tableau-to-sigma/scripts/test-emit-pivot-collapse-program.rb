#!/usr/bin/env ruby
# Offline test for emit-pivot-collapse-program.rb and its Python twin: the
# optional Sigma MCP step that collapses a pivot to a Tableau drill hierarchy's
# first level (the REST spec cannot store that state). The emitted program's
# shape was run live through the MCP build_workbook tool on 2026-10-27; this
# test pins that shape and the entry filtering.
#
# Usage: ruby scripts/test-emit-pivot-collapse-program.rb

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

DIR = __dir__
RB  = File.join(DIR, 'emit-pivot-collapse-program.rb')
PY  = File.join(DIR, 'emit-pivot-collapse-program.py')
RUBY = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

ENTRIES = [
  { 'kind' => 'pivot-collapse', 'caption' => 'Channel Hierarchy', 'worksheet' => 'Channel Pivot',
    'element_id' => 'el-channel-pivot',
    'levels' => [{ 'name' => 'Channel Group', 'column_id' => 'p-cg' },
                 { 'name' => 'Breakdown', 'column_id' => 'dl-channel-hierarchy-1-el-channel-pivot' }] },
  # non-ASCII ids/names: both emitters must escape them identically (\uXXXX)
  { 'kind' => 'pivot-collapse', 'caption' => 'H', 'worksheet' => 'Übersicht', 'element_id' => 'el-ünï',
    'levels' => [{ 'name' => 'Grüße 階層', 'column_id' => 'p-ü' }, { 'name' => 'B', 'column_id' => 'dl-ß' }] },
  # not a pivot-collapse entry
  { 'kind' => 'drill-hierarchy', 'caption' => 'Channel Hierarchy', 'fields' => %w[A B] },
  # one level only: nothing to collapse
  { 'kind' => 'pivot-collapse', 'element_id' => 'el-one', 'levels' => [{ 'name' => 'A', 'column_id' => 'a' }] },
  # a level without a column id
  { 'kind' => 'pivot-collapse', 'element_id' => 'el-bad', 'levels' => [{ 'name' => 'A', 'column_id' => 'a' }, { 'name' => 'B' }] }
].freeze

Dir.mktmpdir do |d|
  File.write(File.join(d, 'auto-interactions.json'), JSON.dump(ENTRIES))
  File.write(File.join(d, 'migrate-state.json'), JSON.dump('workbook_id' => 'wb-123'))

  out, err, st = Open3.capture3(RUBY, RB, '--workdir', d)
  check(st.success?, 'Ruby emitter exits 0', fails)
  check(err.include?('workbookId: wb-123'), 'workbook id read from migrate-state.json', fails)
  check(out.lines.first.strip == 'from sigma.pivotTable import PivotTable', 'program imports PivotTable for the type check', fails)
  check(out.include?('pt = sigma.workbook.get_element("el-channel-pivot")'), 'program opens the recorded pivot', fails)
  check(out.include?('levels = [pt.get_column(c) for c in ["p-cg","dl-channel-hierarchy-1-el-channel-pivot"]]'),
        'program resolves the level columns by id, outer level first', fails)
  check(out.include?('pt.add_pivot_row(col)') && out.include?('pt.collapse_rows(levels[0])'),
        'program adds the lower levels to Rows and collapses at the first level', fails)
  check(!out.include?('el-one') && !out.include?('el-bad'), 'single-level and id-less entries are skipped', fails)

  check(out.include?('get_element("el-\\u00fcn\\u00ef")') && out.include?('collapsed el-\\u00fcn\\u00ef at Gr\\u00fc\\u00dfe \\u968e\\u5c64'),
        'non-ASCII ids and level names are \\uXXXX-escaped like Python json.dumps', fails)
  pout, _perr, pst = Open3.capture3('python3', PY, '--workdir', d)
  check(pst.success? && pout == out, 'Python twin prints the identical program', fails)

  jout, = Open3.capture2(RUBY, RB, '--workdir', d, '--json')
  j = JSON.parse(jout)
  check(j['workbookId'] == 'wb-123' && j['program'] == out && j['pivots'].map { |p| p['element_id'] } == ['el-channel-pivot', 'el-ünï'],
        '--json carries workbookId, program and the pivot list', fails)
  pj, = Open3.capture2('python3', PY, '--workdir', d, '--json')
  check(JSON.parse(pj) == j, 'Python twin --json matches', fails)
end

Dir.mktmpdir do |d|
  # no --workdir: the workbook id is nil in both twins (never read from '/migrate-state.json')
  side = File.join(d, 's.json')
  File.write(side, JSON.dump(ENTRIES))
  _o, err_rb, = Open3.capture3(RUBY, RB, '--sidecar', side)
  _p, err_py, = Open3.capture3('python3', PY, '--sidecar', side)
  check(err_rb.include?('workbookId: <workbook id>') && err_py.include?('workbookId: <workbook id>'),
        'no workdir: both twins fall back to the <workbook id> placeholder', fails)
  out, err, st = Open3.capture3(RUBY, RB, '--workdir', d)
  check(st.success? && out.empty? && err.include?('nothing to do'), 'no sidecar: exit 0, no program', fails)
  pout, perr, pst = Open3.capture3('python3', PY, '--workdir', d)
  check(pst.success? && pout.empty? && perr.include?('nothing to do'), 'Python twin: no sidecar, exit 0, no program', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — pivot-collapse program emitter'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
