#!/usr/bin/env ruby
# frozen_string_literal: true

# Live proofs (every run this week): the datasource-level calc
# "YTD Revenue" = {FIXED [Year] : SUM([Net Revenue])} is used by no sheet,
# dashboard or filter, yet the ORCHESTRATOR's lod-audit marked it
# silently-dropped / unresolved and --finalize needed an `--how waived`
# waiver. The CLI already passed the gap scan's unused-field census; the
# orchestrator's LodAudit.derive call did not. With the census an unused LOD
# is `unused-source` (resolved), with no waiver and no degradation entry.

require 'json'
require 'tmpdir'
require_relative 'lib/lod_audit'
require_relative 'lib/degradation_ledger'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Fact' name='federated.fixture'>
        <column caption='Year' datatype='integer' name='[Year]' role='dimension' type='ordinal' />
        <column caption='Net Revenue' datatype='real' name='[Net Revenue]' role='measure' type='quantitative' />
        <column datatype='real' name='[YTD Revenue]' role='measure' type='quantitative'>
          <calculation class='tableau' formula='{FIXED [Year] : SUM([Net Revenue])}' />
        </column>
      </datasource>
    </datasources>
    <worksheets><worksheet name='Trend'><table><view /></table></worksheet></worksheets>
  </workbook>
XML

Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'workdir-marker'), '')
  calcs = LodAudit.lod_calcs_from_twb(TWB)
  ok(calcs.any? { |c| c['calc'] == 'YTD Revenue' }, "the LOD is in the census (#{calcs.map { |c| c['calc'] }.inspect})")
  without = LodAudit.derive(calcs, wb_spec: { 'pages' => [] })
  ok(without.first['class'] == 'silently-dropped', "without the census it blocks as silently-dropped (#{without.first['class']})")
  File.write(File.join(wd, 'workbook-content-gaps-report.json'),
             JSON.generate('field_statistics' => { 'unused_field_names' => ['Has Cafe', '[YTD Revenue]'] }))
  unused = LodAudit.unused_fields_from(wd)
  ok(unused.include?('[YTD Revenue]'), 'unused_fields_from reads the gap scan census')
  entries = LodAudit.derive(calcs, wb_spec: { 'pages' => [] }, unused_fields: unused)
  e = entries.first
  ok(e['class'] == 'unused-source' && LodAudit.resolved?(e), "with it: unused-source, resolved (#{e.slice('class', 'status').inspect})")
  ok(!e.key?('resolution'), 'no waiver/resolution recorded')
  LodAudit.write(File.join(wd, 'lod-audit.json'), entries)
  ok(DegradationLedger.derive(wd).none? { |x| x['item'].to_s.include?('YTD Revenue') }, 'no degradation-ledger entry')
  ok(LodAudit.unused_fields_from(Dir.mktmpdir) == [], 'no gap report → empty census (the LOD stays unresolved, never guessed)')
end

src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
ok(src.include?('unused_fields: LodAudit.unused_fields_from(WORK)'), 'the orchestrator passes the census to LodAudit.derive')

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
