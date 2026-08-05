#!/usr/bin/env ruby
# test-layout-fill-gate.rb — unit test for gate 8c (layout fill / grid coverage)
# in assert-phase6-ran.rb (#259 item 1). Reaches gate 8c by seeding the
# artifacts every prior gate checks, then asserts exit codes on a range of
# layout-census.json inputs. Offline, creds-free (no workbook id / SIGMA env —
# the live gates SKIP on their own). Run: ruby scripts/test-layout-fill-gate.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/blind_fixture'

GATE = File.join(__dir__, 'assert-phase6-ran.rb')
RUBY = RbConfig.ruby

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# Every gate before 8c is satisfied by SEEDING the artifacts it checks (the
# base_workdir pattern from test-assert-phase6-gates.rb) rather than by
# stacking waivers — the waiver budget (exit 19) caps runs at >2 quality
# waivers, so a waive-everything harness would trip it. SIGMA env stripped so
# nothing dials out (the live gates 3/4/6/7 SKIP on their own without creds);
# gate 8c is the only gate that can change the exit code.
def gate_code(dir, *extra)
  unless File.exist?(File.join(dir, 'parity-final.json'))
    File.write(File.join(dir, 'parity-final.json'), JSON.generate(
      'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
      'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
      'visual_checked' => true, 'visual_verdict' => 'pass', 'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass', 'composition_match' => 'pass', 'chart_shapes_match' => 'pass', 'labels_legible' => 'pass', 'numbers_formatted' => 'pass' }, 'agent_vision' => true))
    File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
    BlindFixture.install(dir) # PR-9: gate 8b refuses a self-attested visual pass
  end
  env = { 'SIGMA_API_TOKEN' => nil, 'SIGMA_BASE_URL' => nil }
  system(env, RUBY, GATE, '--workdir', dir, *extra, out: File::NULL, err: File::NULL)
  $?.exitstatus
end

def write_census(dir, pages)
  File.write(File.join(dir, 'layout-census.json'), JSON.generate({ 'pages' => pages }))
end

FULL     = { 'page' => 'Overview', 'zones' => 9, 'placed' => 9, 'dropped' => 0, 'grid_fill_pct' => 0.71 }
DROPPED  = { 'page' => 'Overview', 'zones' => 9, 'placed' => 8, 'dropped' => 1, 'grid_fill_pct' => 0.71 }
SPARSE   = { 'page' => 'Overview', 'zones' => 9, 'placed' => 9, 'dropped' => 0, 'grid_fill_pct' => 0.30 }

# 1. a full page passes (exit 0 — every other gate waived)
Dir.mktmpdir do |d|
  write_census(d, [FULL])
  ok('full page passes gate 8c', gate_code(d) == 0)
end

# 2. a dropped tile (placed < zones) fails with exit 14
Dir.mktmpdir do |d|
  write_census(d, [DROPPED])
  ok('dropped tile fails (exit 14)', gate_code(d) == 14)
end

# 3. an under-filled grid (< default 0.45) fails with exit 14
Dir.mktmpdir do |d|
  write_census(d, [SPARSE])
  ok('grid_fill < 0.45 fails (exit 14)', gate_code(d) == 14)
end

# 4. one bad page among good ones still fails
Dir.mktmpdir do |d|
  write_census(d, [FULL, DROPPED.merge('page' => 'Detail')])
  ok('any bad page fails the gate', gate_code(d) == 14)
end

# 5. --skip-layout-fill waives a bad census
Dir.mktmpdir do |d|
  write_census(d, [DROPPED])
  ok('--skip-layout-fill waives (exit 0)', gate_code(d, '--skip-layout-fill', 'intentionally sparse') == 0)
end

# 6. --min-grid-fill tunes the threshold: 0.30 fill passes at min 0.25, fails at 0.80
Dir.mktmpdir do |d|
  write_census(d, [SPARSE])
  ok('--min-grid-fill 0.25 passes a 0.30 page', gate_code(d, '--min-grid-fill', '0.25') == 0)
  ok('--min-grid-fill 0.80 fails a 0.71 page (re-checked)',
     (write_census(d, [FULL]); gate_code(d, '--min-grid-fill', '0.80')) == 14)
end

# 7. absent census + NO dashboard layout built -> SKIP (N/A), exit 0
Dir.mktmpdir do |d|
  ok('absent census, no dashboard layout -> pass (N/A)', gate_code(d) == 0)
end

# 8. absent census but a dashboard layout WAS built -> conditional FAIL (exit 14)
Dir.mktmpdir do |d|
  File.write(File.join(d, 'dashboard-layout.json'), '[]')
  ok('absent census + dashboard-layout.json -> fail (exit 14)', gate_code(d) == 14)
end

# 9. malformed census -> exit 14
Dir.mktmpdir do |d|
  File.write(File.join(d, 'layout-census.json'), '{ not json')
  ok('malformed census fails (exit 14)', gate_code(d) == 14)
end

# 10. orphan elements (unplaced_elements non-empty) fail even at full fill —
# an element no layout band references is auto-flowed by Sigma as a stray
# white card (the live-caught synthetic-title defect).
Dir.mktmpdir do |d|
  write_census(d, [FULL.merge('unplaced_elements' => ['title-profitability-watch'])])
  ok('orphan element fails (exit 14)', gate_code(d) == 14)
end

# 11. an empty unplaced_elements list (the invariant holds) still passes
Dir.mktmpdir do |d|
  write_census(d, [FULL.merge('unplaced_elements' => [])])
  ok('empty unplaced_elements passes', gate_code(d) == 0)
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
