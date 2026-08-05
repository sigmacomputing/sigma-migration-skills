#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-w4-redteam-bypasses.rb — replay every gate-satisfaction move from the
# 2026-07 field-workbook false-GREEN and prove each is now RED. The empty-tile
# gate itself is covered end-to-end in test-w1-empty-tiles-gate.rb; this file
# covers the remaining bypasses:
#   (A) editing source-anchors.json after first verify (oracle tampering)
#   (B) laundering a "no data" delta as sigma-capability (fidelity-class)
#   (C) recording a visual PASS over measured-empty tiles (false attestation)
#   (D) the dead handoff nudge (RunState first-stamp preservation)
# Each check is deterministic and offline; no workbook specifics.

require 'json'
require 'tmpdir'
require 'open3'
require 'time'

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

def run(*args, dir: nil)
  Open3.capture3('ruby', File.join(HERE, *args[0, 1]), *args[1..])
end

puts 'test-w4-redteam-bypasses:'

# --- (A) source-anchor post-hoc edit is refused -----------------------------
Dir.mktmpdir do |d|
  File.write(File.join(d, 'wb-readback.json'), JSON.generate(
    'pages' => [{ 'id' => 'p', 'elements' => [
      { 'id' => 'el-a', 'kind' => 'chart', 'name' => 'A', 'source' => { 'elementId' => 'tbl' } },
      { 'id' => 'tbl', 'kind' => 'table', 'name' => 'T' }] }]))
  exdir = File.join(d, 'exports'); Dir.mkdir(exdir)
  File.write(File.join(exdir, 'el-a.csv'), "x,y\n1,100\n")     # tile has data
  File.write(File.join(exdir, 'tbl.csv'), "v\n999\n")
  anchors = { 'source_image' => 'v.png', 'anchors' =>
    (1..5).map { |i| { 'id' => "a#{i}", 'label' => "L#{i}", 'raw' => (i.even? ? '999' : '100'), 'kind' => 'number' } } }
  File.write(File.join(d, 'source-anchors.json'), JSON.generate(anchors))

  o1, e1, s1 = Open3.capture3('ruby', File.join(HERE, 'verify-anchors.rb'),
    '--workdir', d, '--workbook-spec', File.join(d, 'wb-readback.json'), '--exports-dir', exdir)
  ok(s1.success?, "(A) baseline verify-anchors passes with honest anchors (got #{s1.exitstatus})")
  ok(File.exist?(File.join(d, 'source-anchors.lock.json')), '(A) immutability lock stamped on first verify')

  # tamper: change an anchor to the actual, then re-verify
  a = JSON.parse(File.read(File.join(d, 'source-anchors.json')))
  a['anchors'][0]['raw'] = '424242'
  File.write(File.join(d, 'source-anchors.json'), JSON.generate(a))
  o2, e2, s2 = Open3.capture3('ruby', File.join(HERE, 'verify-anchors.rb'),
    '--workdir', d, '--workbook-spec', File.join(d, 'wb-readback.json'), '--exports-dir', exdir)
  ok(!s2.success? && (o2 + e2) =~ /source-anchor VALUE\(s\) changed since first verification/i,
     '(A) post-hoc source-anchor VALUE edit is REFUSED')

  # authorized re-transcription proceeds and logs the diff
  o3, e3, s3 = Open3.capture3('ruby', File.join(HERE, 'verify-anchors.rb'),
    '--workdir', d, '--workbook-spec', File.join(d, 'wb-readback.json'), '--exports-dir', exdir,
    '--retranscribed', 're-read source PNG')
  ok((o3 + e3) =~ /RETRANSCRIBED/i, '(A) --retranscribed authorizes + logs the change')
  verdict = JSON.parse(File.read(File.join(d, 'anchors-verdict.json')))
  ok(verdict['anchors_retranscribed'].is_a?(Hash), '(A) retranscription recorded in the verdict for the report')
end

# --- (B) "no data" delta cannot be classed sigma-capability -----------------
Dir.mktmpdir do |d|
  Open3.capture3('ruby', File.join(HERE, 'fidelity-loop.rb'), 'init',
    '--workdir', d, '--workbook-id', 'wb', '--page-id', 'p')
  o, e, _ = Open3.capture3('ruby', File.join(HERE, 'fidelity-loop.rb'), 'record',
    '--workdir', d, '--dimension', 'rendering',
    '--delta', 'Sigma export-to-PNG does not execute queries - all charts show No Data',
    '--class', 'sigma-capability')
  ok((o + e) =~ /REJECTED for a "no data \/ empty" delta/i,
     '(B) "no data" delta as sigma-capability is REJECTED')
  o2, e2, s2 = Open3.capture3('ruby', File.join(HERE, 'fidelity-loop.rb'), 'record',
    '--workdir', d, '--dimension', 'rendering', '--delta', 'all charts show No Data', '--class', 'data')
  ok(s2.success?, '(B) the same delta as class=data is accepted (and blocks the gate unconditionally)')
end

# --- (C) visual PASS over measured-empty tiles is refused -------------------
Dir.mktmpdir do |d|
  File.write(File.join(d, 'parity-final.json'), JSON.generate('charts_total' => 0))
  File.write(File.join(d, 'anchors-verdict.json'), JSON.generate(
    'tiles_all_nonempty' => false,
    'dashboard_tiles_empty' => [{ 'id' => 'el-x', 'name' => 'X', 'kind' => 'chart' }]))
  cl = 'element_titles_hidden=pass,palette_match=pass,composition_match=pass,' \
       'chart_shapes_match=pass,labels_legible=pass,numbers_formatted=pass'
  o, e, s = Open3.capture3('ruby', File.join(HERE, 'record-visual-check.rb'),
    '--workdir', d, '--agent-vision', 'true', '--verdict', 'pass', '--checklist', cl, '--notes', 'looks fine')
  ok(!s.success? && (o + e) =~ /cannot record a visual PASS/i,
     '(C) visual PASS over measured-empty tiles is REFUSED')
end

# --- (D) handoff nudge survives multi-pass re-stamping ----------------------
Dir.mktmpdir do |d|
  code = <<~'RUBY'
    lib, dir = ARGV
    $LOAD_PATH.unshift lib
    require 'run_state'; require 'json'; require 'time'
    RunState.stamp(dir, 'phase-1')
    doc = RunState.load(dir)
    old = (Time.now.utc - 95 * 60).iso8601
    doc['run_started_at'] = old
    doc['phases']['phase-1']['first_ts'] = old
    File.write(RunState.path(dir), JSON.pretty_generate(doc))
    RunState.stamp(dir, 'phase-1')   # re-pass
    RunState.stamp(dir, 'phase-6')   # later pass
    started = RunState.started_at(dir)
    elapsed = ((Time.now.utc - Time.parse(started)) / 60).round
    puts(RunState.load(dir)['run_started_at'] == old ? "PRESERVED #{elapsed}" : 'RESET')
  RUBY
  o, _, _ = Open3.capture3('ruby', '-e', code, File.join(HERE, 'lib'), d)
  ok(o =~ /PRESERVED (\d+)/ && $1.to_i >= 90,
     "(D) run_started_at survives re-stamping — nudge would fire (#{o.strip})")
end

# --- (E) FALSE-POSITIVE guard: benign cosmetic deltas mentioning "data" ARE OK -
# (review-caught: an over-greedy regex rejected "no data labels" etc.)
Dir.mktmpdir do |d|
  Open3.capture3('ruby', File.join(HERE, 'fidelity-loop.rb'), 'init',
    '--workdir', d, '--workbook-id', 'wb', '--page-id', 'p')
  benign = ['legend shows no data labels', 'no data-label padding on bars',
            'axis has no data ticks shown', 'blank chart background color wrong']
  all_ok = benign.all? do |delta|
    _o, _e, s = Open3.capture3('ruby', File.join(HERE, 'fidelity-loop.rb'), 'record',
      '--workdir', d, '--dimension', 'palette', '--delta', delta, '--class', 'ui-only')
    s.success?
  end
  ok(all_ok, '(E) benign cosmetic deltas that merely mention "data"/"blank" are ALLOWED (no false reject)')
end

# --- (F) FALSE-POSITIVE guard: re-serializing identical anchors does NOT refuse -
# (review-caught: a byte hash tripped on a pretty-print / key reorder of identical anchors)
Dir.mktmpdir do |d|
  Dir.mkdir(File.join(d, 'exports'))
  File.write(File.join(d, 'wb.json'), JSON.generate('pages' => [{ 'id' => 'p', 'elements' => [
    { 'id' => 'tbl', 'kind' => 'table', 'name' => 'T' }] }]))
  File.write(File.join(d, 'exports', 'tbl.csv'), "v\n100\n999\n")
  anchors = (1..5).map { |i| { 'id' => "a#{i}", 'raw' => (i.even? ? '999' : '100'), 'kind' => 'number', 'label' => "L#{i}" } }
  File.write(File.join(d, 'source-anchors.json'), JSON.generate('anchors' => anchors))
  a1 = ['ruby', File.join(HERE, 'verify-anchors.rb'), '--workdir', d, '--workbook-spec', File.join(d, 'wb.json'), '--exports-dir', File.join(d, 'exports')]
  _o1, _e1, s1 = Open3.capture3(*a1)
  # rewrite identical anchors with different key order + pretty whitespace
  reordered = anchors.map { |a| { 'label' => a['label'], 'kind' => a['kind'], 'raw' => a['raw'], 'id' => a['id'] } }
  File.write(File.join(d, 'source-anchors.json'), JSON.pretty_generate('anchors' => reordered))
  _o2, _e2, s2 = Open3.capture3(*a1)
  ok(s1.success? && s2.success?, '(F) reorder/whitespace re-serialization of identical anchors does NOT false-refuse')
end

# --- (G) FALSE-NEGATIVE guard: a referenced dual-role CHART stays displayed -----
# (review-caught: a referenced element was blanket-classed feeder. Only a base
# TABLE that is referenced is a feeder; a referenced chart/kpi is still displayed
# and its emptiness must be gated.)
Dir.mktmpdir do |d|
  Dir.mkdir(File.join(d, 'exports'))
  # el-src is a CHART that el-derived sources from (dual role); el-src is EMPTY.
  spec = { 'pages' => [{ 'id' => 'dash', 'elements' => [
    { 'id' => 'el-src', 'kind' => 'chart', 'name' => 'Source Chart' },
    { 'id' => 'el-derived', 'kind' => 'chart', 'name' => 'Derived', 'source' => { 'elementId' => 'el-src' } },
    { 'id' => 'base', 'kind' => 'table', 'name' => 'Base' } ] }] }
  File.write(File.join(d, 'wb.json'), JSON.generate(spec))
  File.write(File.join(d, 'exports', 'el-src.csv'), "x,y\n")        # EMPTY dual-role chart
  File.write(File.join(d, 'exports', 'el-derived.csv'), "x,y\n1,2\n")
  File.write(File.join(d, 'exports', 'base.csv'), "v\n7\n")
  File.write(File.join(d, 'source-anchors.json'), JSON.generate('anchors' =>
    (1..5).map { |i| { 'id' => "a#{i}", 'raw' => %w[2 1 7 2 7][i - 1], 'kind' => 'number', 'label' => "L#{i}" } }))
  _o, _e, s = Open3.capture3('ruby', File.join(HERE, 'verify-anchors.rb'),
    '--workdir', d, '--workbook-spec', File.join(d, 'wb.json'), '--exports-dir', File.join(d, 'exports'))
  v = JSON.parse(File.read(File.join(d, 'anchors-verdict.json')))
  src = v['tiles'].find { |t| t['id'] == 'el-src' }
  ok(!s.success? && src && src['displayed'] == true,
     '(G) a referenced dual-role CHART stays displayed; its empty export is caught')
end

puts
if FAIL.empty?
  puts "ALL PASS — #{PASS.length} checks: every field-workbook bypass is now RED"
  exit 0
else
  puts "#{FAIL.length} FAILED, #{PASS.length} passed"
  exit 1
end
