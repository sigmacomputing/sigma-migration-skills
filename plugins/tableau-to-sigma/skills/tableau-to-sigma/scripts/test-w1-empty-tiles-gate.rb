#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-w1-empty-tiles-gate.rb — W1.1/W1.2 red-team regression.
#
# Reproduces the 2026-07 field-workbook false-GREEN OFFLINE and proves it now
# goes RED: a workbook whose raw unfiltered feeder table ("Master All") carries
# every anchor value, but whose 9 DISPLAYED dashboard tiles all export ZERO data
# rows (the control-filter/typed-literal blanking). Pre-W1.1 the anchors oracle
# passed 15/15 on the feeder matches and the run went GREEN. Now:
#   - verify-anchors (offline) exits 1, writes dashboard_tiles_empty + tiles_all_nonempty=false
#   - the anchors that matched are flagged in_displayed_tile=false
#   - assert-phase6-ran's anchors-oracle substitution (charts_total==0) is BLOCKED

require 'json'
require 'tmpdir'
require 'open3'

# Locale robustness: the gate scripts emit UTF-8 (arrows, em-dashes). Under a bare
# LANG="" CI, capturing + regex-matching that output raises "invalid byte sequence
# in US-ASCII". Tag read strings UTF-8 so the checks are locale-independent.
Encoding.default_external = Encoding::UTF_8

HERE = __dir__
PASS = []
FAIL = []
def ok(cond, msg)
  (cond ? PASS : FAIL) << msg
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# --- Build an offline fixture: page-data feeders + page-dash-1 empty tiles ----
def build_fixture(dir)
  tiles = %w[el-revpie el-revregionline el-rev-top3 el-nfipie el-nfiregionline
             el-nfi-top3 el-unitspie el-unitsregionline el-units-top3]
  data_elements = [
    { 'id' => 'masterAll', 'kind' => 'table', 'name' => 'Master All' },
    { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
      'source' => { 'kind' => 'element', 'elementId' => 'masterAll' } }
  ]
  # The Region control FILTERS all 9 tiles — realistic wiring (filters[].source.
  # elementId points at each tile). A prior version of this test left the control
  # with NO filters, which hid a blocker: control-filter targets were being
  # misclassified as feeders, so the empty tiles escaped the gate. Keep the real
  # filter wiring so that regression can never re-hide.
  dashboard_elements = [
    { 'id' => 'el-param-region', 'kind' => 'control', 'name' => 'Region',
      'selectionMode' => 'single', 'value' => 'Region A & B',
      'filters' => tiles.map { |t| { 'source' => { 'elementId' => t }, 'columnId' => "#{t}-region" } } }
  ] + tiles.map do |t|
    { 'id' => t, 'kind' => (t.end_with?('pie') ? 'chart' : 'table'),
      'name' => t.sub(/\Ael-/, '').tr('-', ' '),
      'source' => { 'kind' => 'table', 'elementId' => 'master' } }
  end
  data_layout = data_elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join
  dashboard_layout = dashboard_elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join
  spec = {
    'workbookId' => 'wb-test',
    'document' => {
      'schemaVersion' => 4,
      'kind' => 'workbook',
      'pages' => [
        { 'id' => 'page-data', 'name' => 'Data' },
        { 'id' => 'page-dash-1', 'name' => 'Dashboard' }
      ],
      'elements' => data_elements + dashboard_elements,
      'layout' => "<Page id=\"page-data\">#{data_layout}</Page>" \
                  "<Page id=\"page-dash-1\">#{dashboard_layout}</Page>"
    }
  }
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(spec))

  exdir = File.join(dir, 'exports')
  Dir.mkdir(exdir)
  # Feeder masterAll: has data, carries the anchor values.
  File.write(File.join(exdir, 'masterAll.csv'),
             "Country,REV,NFI,UNITS\nUnited Widgets,12337.890121,5000,999\nAcme Holdings,9100.5,4000,888\n")
  # Feeder master (control-filtered to a value that matches nothing): header only.
  File.write(File.join(exdir, 'master.csv'), "Country,REV,NFI,UNITS\n")
  # Every displayed tile: header only = ZERO data rows (renders "No data").
  tiles.each { |t| File.write(File.join(exdir, "#{t}.csv"), "x,y\n") }

  # >= 5 anchors, all transcribed from the source; their values live ONLY in the
  # feeder table (warehouse landed, nothing displayed).
  anchors = {
    'source_image' => 'views/macro.png',
    'anchors' => [
      { 'id' => 'a1', 'label' => 'United Widgets REV', 'raw' => '12,338B', 'kind' => 'currency' },
      { 'id' => 'a2', 'label' => 'Acme Holdings REV', 'raw' => '9,101B', 'kind' => 'currency' },
      { 'id' => 'a3', 'label' => 'US NFI', 'raw' => '5,000', 'kind' => 'number' },
      { 'id' => 'a4', 'label' => 'Acme Holdings NFI', 'raw' => '4,000', 'kind' => 'number' },
      { 'id' => 'a5', 'label' => 'US UNITS', 'raw' => '999', 'kind' => 'number' }
    ]
  }
  File.write(File.join(dir, 'source-anchors.json'), JSON.pretty_generate(anchors))
end

puts 'test-w1-empty-tiles-gate:'

Dir.mktmpdir do |dir|
  build_fixture(dir)

  # --- verify-anchors offline: must FAIL on empty displayed tiles -------------
  out, err, st = Open3.capture3(
    'ruby', File.join(HERE, 'verify-anchors.rb'),
    '--workdir', dir, '--workbook-spec', File.join(dir, 'wb-readback.json'),
    '--exports-dir', File.join(dir, 'exports'))
  combined = out + err

  ok(!st.success?, "verify-anchors exits non-zero on empty displayed tiles (got #{st.exitstatus})")
  verdict = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  ok(verdict['pass'] == true, 'anchors themselves still "matched" (in the feeder) — pass=true')
  ok(verdict['tiles_all_nonempty'] == false, 'tiles_all_nonempty=false written')
  empties = verdict['dashboard_tiles_empty'] || []
  ok(empties.length == 9, "all 9 displayed tiles reported empty (got #{empties.length})")
  ok(empties.none? { |t| %w[master masterAll].include?(t['id']) }, 'feeder tables (master/masterAll) NOT counted as empty displayed tiles')
  ok(verdict['anchors_matched_in_displayed'].to_i.zero?, 'zero anchors matched inside a displayed tile (all feeder-only)')
  ok(combined =~ /displayed dashboard tile\(s\) export ZERO data rows/i, 'failure message names the empty-tile data-path break')

  # --- assert-phase6-ran anchors-oracle substitution: must be BLOCKED --------
  # charts_total==0 (all-embedded) → the oracle stand-in must refuse because
  # condition (c) tiles_all_nonempty is false.
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(
    'charts_total' => 0, 'charts_pass' => 0, 'status' => 'FAIL', 'mode' => 'strict'))
  Dir.mkdir(File.join(dir, 'visual-verify'))
  File.write(File.join(dir, 'visual-verify', 'manifest.json'), JSON.pretty_generate(
    (0..8).map { |i| { 'worksheet' => "w#{i}", 'element_id' => "el#{i}", 'visual_verified' => true, 'shape_match' => true } }))

  a_out, a_err, a_st = Open3.capture3(
    'ruby', File.join(HERE, 'assert-phase6-ran.rb'), '--tableau', dir)
  a_combined = a_out + a_err
  # The oracle substitution (gate 1/2) runs first and exits 2 when it refuses.
  ok(!a_st.success?, "assert-phase6-ran exits non-zero (oracle refused; got #{a_st.exitstatus})")
  blocked = a_combined =~ /every displayed tile returns >=1 data row \(\d+ tile\(s\) EMPTY/i
  ok(blocked, 'assert-phase6-ran oracle substitution surfaces the empty-tile condition (c)')
  ok(a_combined !~ /the ANCHORS ORACLE stands in/i, 'oracle does NOT declare gate-2 PASS over empty tiles')
end

puts
if FAIL.empty?
  puts "ALL PASS — #{PASS.length} checks: the empty-tile false-GREEN is now RED"
  exit 0
else
  puts "#{FAIL.length} FAILED, #{PASS.length} passed"
  exit 1
end
