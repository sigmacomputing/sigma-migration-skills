#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline e2e for the DATASOURCE-FILTER gate (#483) — a virtual-connection
# data-source filter (an always-on `company_active = true` scoping filter hosted
# in a <shared-view>, database-domain, invisible on every dashboard) driven
# through the ACTUAL parser + builder, plus the pure gate lib in-process. No
# Tableau/Sigma calls; creds-free; neutral fixture names only.
#
#   A. parse-twb-layout tags it (is_datasource_filter / ui_domain / is_active_flag)
#   B. build-charts RECORDS it needs-master-default (not a silent warning+drop)
#   C. DatasourceFilterCheck.violations FAILS when it isn't applied and PASSES
#      when it is applied as a master default (and enforces that an always-on
#      flag surfaced only as a control is still a violation).
#
# Usage:  ruby scripts/test-datasource-filter-gate.rb
require 'json'
require 'tmpdir'
require_relative 'lib/datasource_filter_check'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# The `user:` xmlns MUST be declared or the REXML fallback throws on the
# user:ui-domain attribute. company_active lives ONLY in the shared-view (a
# virtual-connection data-source filter), not on a worksheet or dashboard.
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Orders (WH.ORDERS)' name='federated.ds1'>
        <column caption='Company Active' name='[company_active]' datatype='boolean' role='dimension' />
        <column caption='Region' name='[region]' datatype='string' role='dimension' />
        <column caption='Net Revenue' name='[net_revenue]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Revenue by Region'>
        <table>
          <view><datasource-dependencies datasource='federated.ds1' /></view>
          <rows>[federated.ds1].[sum:net_revenue:qk]</rows>
          <cols>[federated.ds1].[none:region:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Ops Overview'>
        <zones><zone id='1' name='Revenue by Region' x='0' y='0' w='100000' h='100000' /></zones>
      </dashboard>
    </dashboards>
    <shared-views>
      <shared-view name='federated.ds1'>
        <filter class='categorical' column='[federated.ds1].[none:company_active:nk]'>
          <groupfilter function='union' user:ui-domain='database' user:ui-marker='enumerate'>
            <groupfilter function='member' level='[none:company_active:nk]' member='&quot;true&quot;' />
          </groupfilter>
        </filter>
      </shared-view>
    </shared-views>
  </workbook>
XML

# Region + Net Revenue are charted dims; Company Active is deliberately OMITTED
# — a data-source scoping column is not a charted dimension, so it has no
# master-map entry and hits the needs-master-default path.
MASTER_MAP = {
  '(?i)^Region$'      => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Net Revenue$' => { 'id' => 'm-rev',    'name' => 'Net Revenue' }
}

meta = nil
scope_json = nil
cov_json = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Revenue by Region' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  meta_path = lay.sub(/\.json$/, '-meta.json')
  meta = JSON.parse(File.read(meta_path))
  out = File.join(d, 'specs.json')
  system('ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', meta_path, '--master-map', mm, '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test', '--title', 'Ops', '--out', out, out: File::NULL, err: %i[child out])
  sp = File.join(d, 'control-scope.json')
  scope_json = JSON.parse(File.read(sp)) if File.exist?(sp)
  cp = meta_path.sub(/(-meta)?\.json$/, '-controls-coverage.json')
  cov_json = JSON.parse(File.read(cp)) if File.exist?(cp)
end

# ---- A. parser tags the shared-view data-source filter ----------------------
sf = (meta['shared_filters'] || []).find { |f| f['column_caption'] == 'Company Active' }
check(!sf.nil?, "A1: shared-view filter on 'Company Active' parsed (got #{(meta['shared_filters'] || []).map { |f| f['column_caption'] }.inspect})", fails)
check(sf && sf['is_datasource_filter'] == true, 'A2: tagged is_datasource_filter', fails)
check(sf && sf['ui_domain'] == 'database', "A3: ui_domain == 'database' (got #{sf && sf['ui_domain'].inspect})", fails)
check(sf && sf['is_active_flag'] == true, 'A4: single-member boolean → is_active_flag', fails)
check(sf && sf['members'] == ['true'], "A5: members == ['true'] (%null% not leaked) (got #{sf && sf['members'].inspect})", fails)

# ---- B. build-charts records needs-master-default (not a silent drop) --------
ctls = (scope_json && scope_json['controls']) || []
rec = ctls.find { |c| c['name'].to_s == 'Company Active' }
check(!rec.nil?, 'B1: Company Active recorded in control-scope.json (not silently dropped)', fails)
check(rec && rec['status'] == 'needs-master-default', "B2: status needs-master-default (got #{rec && rec['status'].inspect})", fails)
check(rec && rec['datasource_filter'] == true, 'B3: record flagged datasource_filter', fails)
unacc = (cov_json && cov_json['unaccounted']) || []
check(!unacc.include?('filter:Company Active'), "B4: NOT in controls-coverage unaccounted (got #{unacc.inspect})", fails)

# ---- C. the gate lib FAILS unapplied, PASSES applied ------------------------
DS = [{ 'column_caption' => 'Company Active', 'is_datasource_filter' => true,
        'is_active_flag' => true, 'shared_view' => 'federated.ds1', 'members' => ['true'] }]
MASTER_COLS = [{ 'id' => 'm-active', 'name' => 'Company Active' }, { 'id' => 'm-region', 'name' => 'Region' }]

bad_spec = { 'pages' => [{ 'elements' => [
  { 'id' => 'master', 'kind' => 'table', 'columns' => MASTER_COLS },
  { 'id' => 'ch', 'kind' => 'bar-chart', 'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master' } } }
] }] }
v_bad = DatasourceFilterCheck.violations(datasource_filters: DS, filter_shelf: [], spec: bad_spec)
check(v_bad.any? { |v| v.include?('Company Active') }, "C1: gate FAILS when the flag isn't applied (got #{v_bad.inspect})", fails)

good_spec = { 'pages' => [{ 'elements' => [
  { 'id' => 'master', 'kind' => 'table', 'columns' => MASTER_COLS,
    'filters' => [{ 'columnId' => 'm-active', 'kind' => 'list', 'mode' => 'include', 'values' => ['true'] }] },
  { 'id' => 'ch', 'kind' => 'bar-chart', 'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master' } } }
] }] }
v_good = DatasourceFilterCheck.violations(datasource_filters: DS, filter_shelf: [], spec: good_spec)
check(v_good.empty?, "C2: gate PASSES when applied as a master default filter (got #{v_good.inspect})", fails)

# active flag surfaced ONLY as a control (no master filter) is STILL a violation
ctl_spec = { 'pages' => [{ 'elements' => [
  { 'id' => 'master', 'kind' => 'table', 'columns' => MASTER_COLS },
  { 'id' => 'c1', 'kind' => 'control', 'name' => 'Company Active' }
] }] }
v_ctl = DatasourceFilterCheck.violations(datasource_filters: DS, filter_shelf: [{ 'label' => 'Company Active' }], spec: ctl_spec)
check(v_ctl.any?, 'C3: an always-on flag surfaced only as a control is still a violation (must be applied)', fails)

# a NON-flag datasource filter (e.g. Region scope) surfaced as a control is satisfied
DS_REGION = [{ 'column_caption' => 'Region', 'is_datasource_filter' => true, 'is_active_flag' => false, 'members' => %w[West East] }]
v_region = DatasourceFilterCheck.violations(datasource_filters: DS_REGION, filter_shelf: [{ 'label' => 'Region' }], spec: ctl_spec)
check(v_region.empty?, "C4: a non-flag datasource filter is satisfied by a control (got #{v_region.inspect})", fails)

# an active flag whose column is bound ONLY by a user CONTROL (the control carries
# a `filters` binding) is STILL a violation — a control is user-widenable, not an
# always-on default. (Regression guard for the live-caught refinement: a control's
# filters entry must NOT satisfy applied_as_filter?.)
ctl_bound_spec = { 'pages' => [{ 'elements' => [
  { 'id' => 'master', 'kind' => 'table', 'columns' => MASTER_COLS },
  { 'id' => 'c1', 'kind' => 'control', 'name' => 'Company Active', 'controlType' => 'list', 'values' => ['true'],
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-active' }] }
] }] }
v_ctlbound = DatasourceFilterCheck.violations(datasource_filters: DS, filter_shelf: [{ 'label' => 'Company Active' }], spec: ctl_bound_spec)
check(v_ctlbound.any?, 'C5: active flag bound ONLY by a control (control.filters) is STILL a violation (must be a master default)', fails)

puts
if fails.empty?
  puts 'ALL PASS — datasource-filter tagged, recorded needs-master-default, and gated (unapplied FAILS, applied PASSES)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
