#!/usr/bin/env ruby
# frozen_string_literal: true
# test-layout-geometry-check.rb — layout-geometry-check.rb: per-visual IoU between the source canvas
# box and the Sigma grid box, and the inverted-order flag. Synthetic Sales names.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'digest'

SCRIPT = File.join(__dir__, 'layout-geometry-check.rb')
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def eid(id)
  clean = id.to_s.gsub(/[^a-zA-Z0-9]/, '').downcase
  # Not a security use: a short deterministic id tag that must stay stable across runs.
  # nosemgrep: ruby.lang.security.weak-hashes-sha1.weak-hashes-sha1
  "el-#{clean[-6, 6] || clean}#{Digest::SHA1.hexdigest(id.to_s)[0, 6]}"
end

def vis(id, x, y, w, h)
  { 'visual_id' => id, 'visual_type' => 'card', 'sigma_kind' => 'kpi', 'title' => id, 'x' => x, 'y' => y, 'w' => w, 'h' => h, 'z' => 0 }
end

# canvas 1280x720: sales (left), units (right), region (below, full width)
SIGNALS = { 'pages' => [{ 'page_id' => 'p1', 'page_title' => 'Overview', 'page_w' => 1280, 'page_h' => 720, 'visuals' => [
  vis('sales', 0, 0, 640, 360), vis('units', 640, 0, 640, 360), vis('region', 0, 360, 1280, 360),
  vis('gone', 0, 0, 10, 10) # not built (held back) -> not reported
] }] }

def el(id, c0, c1, r0, r1)
  %(<Element elementId="#{id}" gridColumn="#{c0} / #{c1}" gridRow="#{r0} / #{r1}"/>)
end

def page(*children)
  %(<Page type="grid" id="page-p1">\n#{children.join("\n")}\n</Page>)
end

FAITHFUL = page(el(eid('sales'), 1, 13, 1, 11), el(eid('units'), 13, 25, 1, 11), el(eid('region'), 1, 25, 11, 21))
# nested: the same layout, but sales/units live inside one container (relative rows/cols)
NESTED = page(%(<Container elementId="band-1" gridColumn="1 / 25" gridRow="1 / 11">\n#{el(eid('sales'), 1, 13, 1, 11)}\n#{el(eid('units'), 13, 25, 1, 11)}\n</Container>),
              el(eid('region'), 1, 25, 11, 21))
# scrambled: units piled at the top-left, sales to the right of it, region on top
SCRAMBLED = page(el(eid('units'), 1, 13, 11, 21), el(eid('sales'), 13, 25, 11, 21), el(eid('region'), 1, 25, 1, 11))

def run(dir, layout)
  File.write(File.join(dir, 'signals.json'), JSON.generate(SIGNALS))
  File.write(File.join(dir, 'spec.json'), JSON.generate('name' => 'x', 'layout' => layout))
  out = File.join(dir, 'report.json')
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  st = system(RbConfig.ruby, SCRIPT, '--signals', File.join(dir, 'signals.json'), '--spec', File.join(dir, 'spec.json'),
              '--out', out, err: File.join(dir, 'err.txt'))
  [st, $CHILD_STATUS, File.exist?(out) ? JSON.parse(File.read(out)) : nil, File.read(File.join(dir, 'err.txt'))]
end

require 'English'
Dir.mktmpdir do |d|
  st, _, rep, err = run(d, FAITHFUL)
  ok('exits 0', st)
  rows = rep['pages'][0]['visuals'].each_with_object({}) { |r, h| h[r['visual_id']] = r }
  ok('only built visuals are reported (the held-back one is not)', rows.keys.sort == %w[region sales units])
  ok('a faithful layout has IoU 1.0 for every visual', rows.values.all? { |r| (r['iou'] - 1.0).abs < 1e-6 })
  ok('a faithful layout flags no inverted order', rep['pages'][0]['inverted'].empty?)
  ok('the summary line is printed', err.include?('[layout-geometry-check] 3 visual(s)'))

  _, _, rep2, = run(d, NESTED)
  ok('container-nested elements resolve to absolute cells (IoU 1.0)', rep2['pages'][0]['visuals'].all? { |r| (r['iou'] - 1.0).abs < 1e-6 })

  st3, _, rep3, err3 = run(d, SCRAMBLED)
  ok('a scrambled layout still exits 0 (informational)', st3)
  rows3 = rep3['pages'][0]['visuals'].each_with_object({}) { |r, h| h[r['visual_id']] = r }
  ok('a lower IoU is reported for the moved visuals', rows3['sales']['iou'] < 0.5 && rows3['region']['iou'] < 0.5)
  ok('sales/units left-right inversion is flagged both ways',
     rows3['sales']['order_inverted_with'].include?('units') && rows3['units']['order_inverted_with'].include?('sales'))
  ok('region (moved above the row) is flagged against both',
     rows3['region']['order_inverted_with'].sort == %w[sales units])
  ok('the summary counts the inverted visuals', err3.include?('3 with inverted'))
end

# A source-hidden visual (a slicer in a hidden pane) has no visible source box: a builder moves it to a
# bottom "hidden filters" band. It is not scored, and the extra rows it adds do not distort the others.
Dir.mktmpdir do |d|
  sig = JSON.parse(JSON.generate(SIGNALS))
  sig['pages'][0]['visuals'] << vis('hidslicer', 0, 0, 200, 60).merge('hidden' => true)
  lay = FAITHFUL.sub('</Page>', "#{el(eid('hidslicer'), 1, 7, 21, 25)}\n</Page>")
  File.write(File.join(d, 'signals.json'), JSON.generate(sig))
  File.write(File.join(d, 'spec.json'), JSON.generate('name' => 'x', 'layout' => lay))
  out = File.join(d, 'report.json')
  system(RbConfig.ruby, SCRIPT, '--signals', File.join(d, 'signals.json'), '--spec', File.join(d, 'spec.json'),
         '--out', out, err: File.join(d, 'err.txt'))
  rep = JSON.parse(File.read(out))
  rows = rep['pages'][0]['visuals'].each_with_object({}) { |r, h| h[r['visual_id']] = r }
  ok('a source-hidden visual is not scored', !rows.key?('hidslicer'))
  ok('a bottom hidden band does not distort the visible visuals (IoU 1.0)',
     rows.values.all? { |r| (r['iou'] - 1.0).abs < 1e-6 })
end

# A real workbook spec: the layout is a run of sibling <Page> elements (no root) under document.layout.
Dir.mktmpdir do |d|
  sig = JSON.parse(JSON.generate(SIGNALS))
  sig['pages'] << { 'page_id' => 'p2', 'page_title' => 'Detail', 'page_w' => 1280, 'page_h' => 720,
                    'visuals' => [vis('detail', 0, 0, 1280, 720)] }
  p2 = %(<Page type="grid" id="page-p2">\n#{el(eid('detail'), 1, 25, 1, 21)}\n</Page>)
  File.write(File.join(d, 'signals.json'), JSON.generate(sig))
  File.write(File.join(d, 'spec.json'), JSON.generate('name' => 'x', 'document' => { 'layout' => %(<?xml version="1.0" encoding="utf-8"?>\n) + FAITHFUL + p2 }))
  out = File.join(d, 'report.json')
  st = system(RbConfig.ruby, SCRIPT, '--signals', File.join(d, 'signals.json'), '--spec', File.join(d, 'spec.json'),
              '--out', out, err: File.join(d, 'err.txt'))
  rep = File.exist?(out) ? JSON.parse(File.read(out)) : { 'pages' => [] }
  ok('a rootless multi-page document.layout parses (exit 0)', st)
  ok('both pages are reported', rep['pages'].map { |p| p['page_title'] || p['page'] }.compact.size == 2)
end

puts($fail.zero? ? "\nall passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
