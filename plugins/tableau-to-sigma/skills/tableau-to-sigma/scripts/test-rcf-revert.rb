#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof: a pass-1 re-run after a 5g apply-patch re-PUT the rebuilt
# spec in place and reverted the RCF layout patch, while fidelity-ledger.json
# still marked that delta resolved — ledger and live workbook disagreed
# silently. Now: applied patches are recorded; a rebuild over the ledger's
# workbook REOPENS the resolved spec-fixable entries (the 8d status gate then
# blocks) and returns the exact re-apply commands; re-applying a recorded
# patch is allowed past an exhausted render budget.

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/rcf_revert'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

FL = File.join(__dir__, 'fidelity-loop.rb')
def ledger(wb)
  { 'workbook_id' => wb, 'page_id' => 'p1', 'max_passes' => 5, 'pass' => 2, 'renders' => [],
    'entries' => [
      { 'id' => 'e0', 'pass' => 1, 'dimension' => 'labels / number formats', 'delta' => '2dp vs 1dp', 'cls' => 'spec-fixable', 'resolved' => true },
      { 'id' => 'e1', 'pass' => 1, 'dimension' => 'layout / containers', 'delta' => 'header band at bottom', 'cls' => 'spec-fixable', 'resolved' => true },
      { 'id' => 'e2', 'pass' => 1, 'dimension' => 'layout / containers', 'delta' => 'map legend overlap', 'cls' => 'ui-only', 'catalog_id' => 'nav-button-style', 'resolved' => false }
    ] }
end

Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'fidelity-ledger.json'), JSON.generate(ledger('wb-1')))
  patch = JSON.generate('layout' => '<Page id="p1"/>')
  rec = RcfRevert.record_patch!(wd, patch, resolves: %w[e1], document_version: 5)
  ok(File.file?(rec['path']) && File.read(rec['path']) == patch, 'applied patch saved verbatim under rcf-patches/')
  ok(RcfRevert.applied_sha?(wd, patch) && !RcfRevert.applied_sha?(wd, '{}'), 'applied_sha? recognizes exactly the recorded patch')

  st_before = Open3.capture2e(RbConfig.ruby, FL, 'status', '--workdir', wd)[1]
  r = RcfRevert.reopen_after_rebuild!(wd, workbook_id: 'wb-1')
  led = JSON.parse(File.read(File.join(wd, 'fidelity-ledger.json')))
  ok(r[:reopened] == %w[e0 e1], "rebuild over the ledger's workbook reopens resolved spec-fixable entries (#{r[:reopened].inspect})")
  ok(led['entries'].find { |e| e['id'] == 'e1' }['reopened'].to_h['reason'].to_s.include?('re-PUT'), 'reopened entries carry the reason')
  ok(led['entries'].find { |e| e['id'] == 'e2' }['resolved'] == false, 'ui-only residual untouched')
  ok(r[:commands] == ["ruby scripts/fidelity-loop.rb apply-patch --workdir #{wd} --patch #{rec['path']} --resolves e1"],
     "exact re-apply command (#{r[:commands].inspect})")
  out, st = Open3.capture2e(RbConfig.ruby, FL, 'status', '--workdir', wd)
  ok(st_before.success? && !st.success?, "8d status gate: passed before, BLOCKS after the reopen (#{out.lines.grep(/FAIL|BLOCK|unresolved/i).first.to_s.strip})")

  # re-apply past an exhausted render budget (dry-run: no network)
  File.write(File.join(wd, 'rcf-exhausted.json'), JSON.generate('status' => 'exhausted'))
  live = File.join(wd, 'live.json')
  File.write(live, JSON.generate('document' => { 'schemaVersion' => 1, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p1', 'name' => 'D' }],
                                                 'elements' => [], 'layout' => '<Page id="p1"/>' }, 'latestDocumentVersion' => 5))
  out, st = Open3.capture2e(RbConfig.ruby, FL, 'apply-patch', '--workdir', wd, '--patch', rec['path'], '--dry-run', '--live-spec', live,
                            '--out', File.join(wd, 'm.json'), '--resolves', 'e1')
  ok(st.success? && out.include?('re-applying a recorded RCF patch'), "recorded patch re-applies past rcf-exhausted.json (#{out.lines.last.to_s.strip})")
  other = File.join(wd, 'new.json')
  File.write(other, JSON.generate('layout' => '<Page id="p1"><Element elementId="x"/></Page>'))
  _out, st = Open3.capture2e(RbConfig.ruby, FL, 'apply-patch', '--workdir', wd, '--patch', other, '--dry-run', '--live-spec', live,
                             '--out', File.join(wd, 'm2.json'))
  ok(st.exitstatus == 3, 'a NEW patch is still refused once the budget is exhausted')
end

Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'fidelity-ledger.json'), JSON.generate(ledger('wb-1')))
  ok(RcfRevert.reopen_after_rebuild!(wd, workbook_id: 'wb-1')[:reopened].empty?, 'no repair ever written → nothing reopened')
  RcfRevert.record_patch!(wd, '{}')
  ok(RcfRevert.reopen_after_rebuild!(wd, workbook_id: 'wb-OTHER')[:reopened].empty?, "another workbook's ledger is untouched")
end

src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
ok(src.include?('RcfRevert.reopen_after_rebuild!(WORK, workbook_id: wb_id)'), 'the orchestrator checks after every workbook build')

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
