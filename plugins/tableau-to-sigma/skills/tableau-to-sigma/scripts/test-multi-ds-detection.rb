#!/usr/bin/env ruby
# Regression test: scan-workbook-gaps.rb "independent multi-datasource"
# detection (fix-workstream F from a live migration failure).
#
# The failure: a workbook with 4 independent datasources (2 published sqlproxy,
# 2 direct) feeding DIFFERENT worksheets — NOT a blend (no linking fields) —
# was collapsed by the converter (datasourceIndex default 0) into a single-
# element DM; every other datasource's columns + calcs were silently dropped
# and the workbook spec POST failed ~28x with "Dependency not found".
#
# What this locks:
#   1. multids-independent.twb  → TRIGGERS: one ❌-unhandled gap row (drives
#      the orchestrator's exit-11 gap stop) routing to
#      refs/multi-datasource.md + a multi-ds-plan.json sidecar with the exact
#      contract shape (independent flag, per-datasource
#      name/caption/connection_class/table/sqlproxy/worksheets/dashboards).
#   2. multids-blend.twb        → does NOT trigger (a genuine blend — secondary
#      is never primary; blend-plan.json path unchanged).
#   3. multids-single.twb       → does NOT trigger (one datasource).
#
# Deterministic/offline/creds-free: runs the real scanner as a subprocess on
# synthetic fixtures (scripts/test-fixtures/multids-*.twb — invented names, no
# customer data).
#
# Usage:  ruby scripts/test-multi-ds-detection.rb

require 'json'
require 'open3'
require 'tmpdir'

SCANNER  = File.join(__dir__, 'scan-workbook-gaps.rb')
FIXTURES = File.join(__dir__, 'test-fixtures')

$fails = []

def check(desc, cond)
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{desc}"
  $fails << desc unless cond
end

# Run the scanner on a fixture inside a fresh temp dir; return
# { gaps: <parsed -gaps json>, plan: <parsed multi-ds-plan.json or nil>,
#   blend: <parsed blend-plan.json or nil>, status: Process::Status }
def scan(fixture)
  twb = File.join(FIXTURES, fixture)
  abort "fixture missing: #{twb}" unless File.exist?(twb)
  out = {}
  Dir.mktmpdir('multids-test') do |dir|
    report_md = File.join(dir, 'report.md')
    _o, _e, st = Open3.capture3({ 'LANG' => 'en_US.UTF-8' },
                                RbConfig.ruby, SCANNER, twb, report_md)
    out[:status] = st
    gaps_json = File.join(dir, 'report.json')
    out[:gaps]  = File.exist?(gaps_json) ? JSON.parse(File.read(gaps_json)) : nil
    plan_json = File.join(dir, 'multi-ds-plan.json')
    out[:plan]  = File.exist?(plan_json) ? JSON.parse(File.read(plan_json)) : nil
    blend_json = File.join(dir, 'blend-plan.json')
    out[:blend] = File.exist?(blend_json) ? JSON.parse(File.read(blend_json)) : nil
  end
  out
end

def feature_row(gaps, name)
  return nil unless gaps
  (gaps['detected_features'] || []).find { |f| f['name'] == name }
end

MULTI_DS_ROW = 'Multiple independent datasources (converter collapses to primary)'

# ── 1. Independent multi-DS fixture MUST trigger ────────────────────────────
puts 'multids-independent.twb (4 independent datasources — the live-failure shape):'
r = scan('multids-independent.twb')
check('scanner exits 0', r[:status].success?)
check('multi-ds-plan.json written', !r[:plan].nil?)
check('blend-plan.json NOT written (no linking fields anywhere)', r[:blend].nil?)

row = feature_row(r[:gaps], MULTI_DS_ROW)
check("gap row \"#{MULTI_DS_ROW}\" present", !row.nil?)
if row
  check('gap row status is unhandled (drives the exit-11 gap stop)', row['status'] == 'unhandled')
  check('gap row routes to multi-element DM (refs/multi-datasource.md)',
        row['blurb'].to_s.include?('route: multi-element DM (refs/multi-datasource.md)'))
end

if (plan = r[:plan])
  check('plan.independent == true', plan['independent'] == true)
  dses = plan['datasources'] || []
  check('plan lists 4 datasources', dses.length == 4)
  by_caption = dses.group_by { |d| d['caption'] }.transform_values(&:first)

  # contract shape: every entry carries every key
  %w[name caption connection_class table sqlproxy worksheets dashboards].each do |k|
    check("every datasource entry has key '#{k}'", dses.all? { |d| d.key?(k) })
  end

  sales = by_caption['Sales Pipeline']
  fin   = by_caption['Finance Actuals']
  ops   = by_caption['Ops Inventory']
  hr    = by_caption['HR Headcount']
  check('all four expected captions present', [sales, fin, ops, hr].none?(&:nil?))

  if sales && fin && ops && hr
    # sqlproxy flags: 2 published, 2 direct
    check('Sales Pipeline is sqlproxy',   sales['sqlproxy'] == true)
    check('Finance Actuals is sqlproxy',  fin['sqlproxy'] == true)
    check('Ops Inventory is direct',      ops['sqlproxy'] == false)
    check('HR Headcount is direct',       hr['sqlproxy'] == false)

    # table: null for published (hydration resolves later), db.schema.table for direct
    check('published sources have table=null', sales['table'].nil? && fin['table'].nil?)
    check('Ops Inventory table resolved', ops['table'] == 'ANALYTICS.PUBLIC.OPS_INVENTORY')
    check('HR Headcount table resolved',  hr['table'] == 'ANALYTICS.PUBLIC.HR_HEADCOUNT')
    check('direct connection_class is snowflake',
          ops['connection_class'] == 'snowflake' && hr['connection_class'] == 'snowflake')

    # worksheet routing (the per-chart source routing table)
    check('Sales Pipeline owns its 2 worksheets',
          sales['worksheets'].sort == ['Pipeline by Owner', 'Pipeline by Stage'])
    check('Finance Actuals owns Actuals vs Budget', fin['worksheets'] == ['Actuals vs Budget'])
    check('Ops Inventory owns Inventory Levels',    ops['worksheets'] == ['Inventory Levels'])
    check('HR Headcount owns Headcount Trend',      hr['worksheets'] == ['Headcount Trend'])

    # dashboard assignment via zones
    check('Sales Pipeline routes to Executive Overview', sales['dashboards'] == ['Executive Overview'])
    check('Finance Actuals routes to Executive Overview', fin['dashboards'] == ['Executive Overview'])
    check('Ops Inventory routes to Operations', ops['dashboards'] == ['Operations'])
    check('HR Headcount routes to Operations',  hr['dashboards'] == ['Operations'])
  end
end

# ── 2. Blend fixture must NOT trigger (blend path unchanged) ────────────────
puts
puts 'multids-blend.twb (genuine blend — secondary never primary):'
r = scan('multids-blend.twb')
check('scanner exits 0', r[:status].success?)
check('multi-ds-plan.json NOT written', r[:plan].nil?)
check("no \"#{MULTI_DS_ROW}\" gap row", feature_row(r[:gaps], MULTI_DS_ROW).nil?)
check('blend-plan.json still written (path unchanged)', !r[:blend].nil?)
if (bp = r[:blend])
  blends = bp['blends'] || []
  check('exactly 1 blend detected', blends.length == 1)
  check('blend routes same-warehouse-repoint',
        blends.all? { |b| b['route'] == 'same-warehouse-repoint' })
  check('blend links on Region', blends.all? { |b| (b['linking_fields'] || []).include?('Region') })
end

# ── 3. Single-datasource fixture must NOT trigger ───────────────────────────
puts
puts 'multids-single.twb (one datasource):'
r = scan('multids-single.twb')
check('scanner exits 0', r[:status].success?)
check('multi-ds-plan.json NOT written', r[:plan].nil?)
check("no \"#{MULTI_DS_ROW}\" gap row", feature_row(r[:gaps], MULTI_DS_ROW).nil?)
check('blend-plan.json NOT written', r[:blend].nil?)

puts
if $fails.empty?
  puts 'ALL PASS — independent multi-DS workbooks are detected with the exact ' \
       'multi-ds-plan.json contract; blends and single-DS workbooks do not trigger'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
