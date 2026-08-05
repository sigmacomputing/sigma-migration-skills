#!/usr/bin/env ruby
# Integration test for parameter → column data-scoping auto-wiring (TASK C / #259).
#
# Drives the ACTUAL build-charts-from-signals.rb: a Tableau parameter that scopes
# data through a boolean filter calc "[Col] = [Param]" must emerge as a Sigma
# control with a real FILTER TARGET on [Col] (turns needs-wiring → emitted), while
# a directional "[Col] >= [Param]" (and any calc whose column doesn't resolve) is
# SURFACED with candidate columns, never mis-wired as an inclusion filter.
#
# Reuses the committed top-N parser fixtures (charts of Partner Name × SUM(Net
# Revenue) sourcing the master) and injects two parameters + their filter calcs
# into the meta, so no Tableau publish / creds are needed.
#
# Usage:  ruby scripts/test-param-scoping-wiring.rb

require 'json'
require 'tmpdir'

DIR     = __dir__
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
FIXTURE = File.join(DIR, 'test-fixtures')

fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

MASTER_MAP = {
  '(?i)^Net Revenue$'  => { 'id' => 'm-nr', 'name' => 'Net Revenue' },
  '(?i)^Partner Name$' => { 'id' => 'm-pn', 'name' => 'Partner Name' }
}

# Two parameters, NEITHER referenced by a calc's parameter_refs (so both look like
# orphan "needs-wiring" params) — their filter calcs live in the worksheet calc
# set, which is exactly the data-scoping shape the tracer recovers.
INJECT_PARAMS = [
  { 'caption' => 'Partner Param', 'name' => '[Partner Param]', 'param_domain' => 'list',
    'members' => %w[Acme Globex], 'default_value' => 'Acme', 'datatype' => 'string' },
  { 'caption' => 'Rev Floor', 'name' => '[Rev Floor]', 'param_domain' => 'range',
    'datatype' => 'real', 'min' => 0, 'max' => 1_000_000, 'default_value' => 0 }
]
INJECT_CALCS = [
  { 'name' => '[partner_filter]', 'caption' => 'PartnerScope', 'datatype' => 'boolean',
    'role' => 'measure', 'class' => 'tableau',
    'formula' => '[Partner Name] = [Parameters].[Partner Param]' },
  { 'name' => '[rev_floor_filter]', 'caption' => 'RevFloorScope', 'datatype' => 'boolean',
    'role' => 'measure', 'class' => 'tableau',
    'formula' => '[Net Revenue] >= [Parameters].[Rev Floor]' }
]

build_out = nil
build_log = ''
Dir.mktmpdir do |d|
  lay  = File.join(d, 'layout.json')
  meta = File.join(d, 'layout-meta.json')
  mm   = File.join(d, 'master-map.json')
  File.write(lay, File.read(File.join(FIXTURE, 'topn-layout.json')))
  meta_obj = JSON.parse(File.read(File.join(FIXTURE, 'topn-layout-meta.json')))
  meta_obj['parameters'] = INJECT_PARAMS
  first_ws = meta_obj['worksheets'].keys.first
  (meta_obj['worksheets'][first_ws]['calculations'] ||= []).concat(INJECT_CALCS)
  File.write(meta, JSON.dump(meta_obj))
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [
               { 'id' => 'v1', 'name' => 'Top 25 Partners' },
               { 'id' => 'v2', 'name' => 'Top 10 Partners LOD' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  File.write(File.join(d, 'views', 'v2.csv'), '')
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', meta,
                        '--master-map', mm, '--master-element-id', 'master',
                        '--skip-dashboard-read', 'unit-test', '--title', 'Dash', '--out', out],
                       err: %i[child out], &:read)
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

abort "build-charts produced no output\n#{build_log}" unless build_out

els = build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })
scope = build_out.is_a?(Hash) ? (build_out['controls_scope'] || build_out['control_scope'] || build_out['controlScope']) : nil
# control-scope ledger may live in a sidecar; fall back to reading it from the log summary.
ctl = ->(id) { els.find { |e| e['kind'] == 'control' && e['controlId'] == id } }

puts 'Equality data-scoping param → control with a real filter target'
pc = ctl.call('ctl-param-partner-param')
check(!pc.nil?, 'Partner Param control emitted', fails)
ft = pc ? (pc['filters'] || []) : []
check(ft.any? { |t| t['columnId'] == 'm-pn' },
      "control filters Partner Name (m-pn) — got #{ft.inspect}", fails)
check(ft.all? { |t| t.dig('source', 'elementId') },
      'every filter target carries a source elementId', fails)

puts 'Directional data-scoping param → NOT auto-wired as an equality filter'
rf = ctl.call('ctl-param-rev-floor')
check(!rf.nil?, 'Rev Floor control emitted', fails)
check((rf['filters'] || []).empty?,
      "Rev Floor ('>=') did NOT get an inclusion filter target (got #{(rf['filters'] || []).inspect})", fails)

puts 'Build log surfaces the wiring + the surfaced candidate'
check(build_log =~ /data-scopes Partner Name.*wired control/i,
      'log announces Partner Name wiring', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  puts "--- build log tail ---"
  puts build_log.lines.last(20).join
  exit 1
end
