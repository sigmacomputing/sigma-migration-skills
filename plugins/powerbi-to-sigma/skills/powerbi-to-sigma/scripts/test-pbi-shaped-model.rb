#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for lib/pbi_shaped_model.rb and the `--model-shape pbi` flag of migrate-powerbi.rb
# (Power BI-shaped model mode, task 8): the security refusal, view dropping, Power BI element and
# column names, and the reference rewriting that follows them.
#
# Fixtures: fixtures/pbi-shaped/{sales,inventory,rls}/ (placeholder Snowflake coordinates only).
# Synthetic names only. No network. Run: ruby scripts/test-pbi-shaped-model.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/pbi_shaped_model'

SKILL    = File.dirname(__dir__)
FIX      = File.join(SKILL, 'fixtures', 'pbi-shaped')
MIGRATE  = File.join(__dir__, 'migrate-powerbi.rb')
CONN     = '12345678-1234-1234-1234-123456789012'
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def load_json(*parts)
  JSON.parse(File.read(File.join(FIX, *parts)))
end

def sales_dm
  load_json('sales', 'dm-raw.json')
end

def sales_tmsl
  load_json('sales', 'model.bim')
end

def elements(dm)
  PbiShapedModel.elements_of(dm)
end

def all_formulas(dm)
  elements(dm).flat_map { |el| (el['columns'] || []).map { |c| c['formula'] } + (el['metrics'] || []).map { |m| m['formula'] } }.compact
end

# Run the shaped pipeline the way the orchestrator will: attribute first, then drop, rename, rewrite.
def shaped(dm, tmsl)
  table_for = PbiShapedModel.table_for_elements(dm, tmsl)
  PbiShapedModel.drop_views!(dm)
  el_renames = PbiShapedModel.rename_elements!(dm, table_for)
  col_renames = PbiShapedModel.rename_columns!(dm, tmsl, table_for)
  PbiShapedModel.rewrite_refs!(dm, el_renames, col_renames)
  [table_for, el_renames, col_renames]
end

# ---- the orchestrator, offline (same fake-Sigma stub idea as test-pbi-page-facts-orchestrator.rb) ----
STUB = <<~'RUBY'
  require 'net/http'
  require 'json'
  class FakeSigmaConn
    def request(req)
      File.open(ENV.fetch('FAKE_SIGMA_LOG'), 'a') { |f| f.flock(File::LOCK_EX); f.puts("#{req.method} #{req.path}") }
      body = if req.path =~ %r{\A/v2/dataModels\?} then JSON.generate('entries' => [], 'nextPage' => nil)
             elsif req.path.start_with?('/v2/connections/') then JSON.generate('friendlyName' => true)
             elsif req.path.start_with?('/v2/whoami') then JSON.generate('userId' => 'user-1')
             else '{}'
             end
      res = Net::HTTPOK.new('1.1', '200', 'OK')
      res.instance_variable_set(:@body, body)
      res.instance_variable_set(:@read, true)
      res
    end
  end
  class Net::HTTP
    def self.start(*_args, **_opts)
      conn = FakeSigmaConn.new
      block_given? ? yield(conn) : conn
    end
  end
RUBY

VIS = JSON.generate('name' => 'v1', 'singleVisual' => { 'visualType' => 'card', 'projections' => { 'Values' => [{ 'queryRef' => 'Orders.Total Amount' }] } })
BUNDLE = JSON.generate('report.json' => JSON.generate('sections' => [{ 'name' => 'S1', 'displayName' => 'Sales Page', 'width' => 1280, 'height' => 720,
                                                                         'visualContainers' => [{ 'x' => 0, 'y' => 0, 'width' => 200, 'height' => 100, 'z' => 0, 'config' => VIS }] }]))

def native_m(sql)
  ['let', "  Source = Value.NativeQuery(Snowflake.Databases(\"acct\"){[Name=\"DB\"]}[Data], \"#{sql}\", null, [EnableFolding=true])", 'in', '  Source']
end

def orders_model(roles)
  cols = [%w[Order\ Id ORDER_ID int64], %w[Amount AMOUNT decimal]].map { |n, s, t| { 'name' => n, 'sourceColumn' => s, 'dataType' => t } }
  model = { 'name' => 'T', 'tables' => [{
    'name' => 'Orders', 'columns' => cols,
    'measures' => [{ 'name' => 'Total Amount', 'expression' => 'SUM(Orders[Amount])' }],
    'partitions' => [{ 'name' => 'Orders', 'mode' => 'import',
                       'source' => { 'type' => 'm', 'expression' => native_m('SELECT ORDER_ID, AMOUNT FROM SALES.ORDERS') } }]
  }] }
  model['roles'] = roles unless roles.nil?
  { 'model' => model }
end

def run_migrate(dir, tmsl_path, *extra)
  stub = File.join(dir, 'fake_sigma_http.rb')
  File.write(stub, STUB) unless File.exist?(stub)
  File.write(File.join(dir, 'bundle.json'), BUNDLE)
  env = { 'RUBYOPT' => "-r#{stub}", 'FAKE_SIGMA_LOG' => File.join(dir, 'http.log'), 'HOME' => dir, 'SIGMA_API_TOKEN' => 'tok',
          'SIGMA_BASE_URL' => 'https://api.sigmacomputing.com', 'SIGMA_ALLOW_INSECURE_BASE_URL' => '',
          'SIGMA_CLIENT_ID' => '', 'SIGMA_CLIENT_SECRET' => '' }
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture2e(env, RbConfig.ruby, MIGRATE, '--tmsl', tmsl_path, '--pbir', File.join(dir, 'bundle.json'),
                  '--out', File.join(dir, "out-#{rand(1 << 30)}"), '--connection', CONN, '--database', 'DB', '--schema', 'SALES',
                  '--folder', 'f1', '--yes', '--stop-before-post', '--no-reuse', *extra)
end

# ------------------------------------------------------------------------------------------------

puts "\ntest_security_roles_detects_filter_and_column_permissions"
roles_tmsl = { 'model' => { 'roles' => [
  { 'name' => 'Filtered', 'tablePermissions' => [{ 'name' => 'Store', 'filterExpression' => '[Region] = "West"' }] },
  { 'name' => 'Hidden Cols', 'tablePermissions' => [{ 'name' => 'Customer', 'columnPermissions' => [{ 'name' => 'Segment', 'metadataPermission' => 'none' }] }] },
  { 'name' => 'Plain', 'modelPermission' => 'read' },
  { 'name' => 'Empty Filter', 'tablePermissions' => [{ 'name' => 'Store', 'filterExpression' => '  ' }] },
  { 'name' => 'Array Filter', 'tablePermissions' => [{ 'name' => 'Store', 'filterExpression' => ['[Region]', ' = "East"'] }] }
] } }
got = PbiShapedModel.security_roles(roles_tmsl)
check(got.include?('Filtered'), 'a role with a table filter is returned', fails)
check(got.include?('Hidden Cols'), 'a role with column permissions is returned', fails)
check(got.include?('Array Filter'), 'a filter stored as a line array counts', fails)
check(!got.include?('Plain'), 'a role with no permissions is not returned', fails)
check(!got.include?('Empty Filter'), 'a blank filter expression is not security', fails)
ols_tmsl = { 'model' => { 'roles' => [
  { 'name' => 'Table OLS', 'tablePermissions' => [{ 'name' => 'Salaries', 'metadataPermission' => 'none' }] },
  { 'name' => 'Table Read', 'tablePermissions' => [{ 'name' => 'Salaries', 'metadataPermission' => 'read' }] },
  { 'name' => 'Table Default', 'tablePermissions' => [{ 'name' => 'Salaries' }] }
] } }
ols = PbiShapedModel.security_roles(ols_tmsl)
check(ols == ['Table OLS'], "m2: table-level object-level security (metadataPermission none) is refused, a read table is not (#{ols.inspect})", fails)
check(PbiShapedModel.security_roles({ 'model' => {} }).empty? && PbiShapedModel.security_roles({}).empty?, 'no roles at all gives an empty list', fails)
check(PbiShapedModel.security_roles(load_json('rls', 'model.bim')) == ['West Stores'], 'the rls fixture names its one role', fails)
check(PbiShapedModel.security_roles(sales_tmsl).empty?, 'the sales fixture has no security roles', fails)

puts "\ntest_drop_views_removes_view_and_rewrites_refs"
dm = sales_dm
check(elements(dm).any? { |e| e['name'].to_s.end_with?(' View') }, 'precondition: the raw converter output has View elements', fails)
dm['pages'][0]['elements'] << { 'id' => 'x1', 'kind' => 'table', 'name' => 'Calc',
                                'source' => { 'kind' => 'table', 'elementId' => 'x0' },
                                'columns' => [{ 'id' => 'xc', 'name' => 'Region', 'formula' => '[FACT_SALES View/Store/Store Region]' }] }
removed = PbiShapedModel.drop_views!(dm)
check(removed.sort == ['DIM_PRODUCT View', 'DIM_SKU View', 'FACT_SALES View'], "the three Views are removed (#{removed.inspect})", fails)
check(elements(dm).none? { |e| e['name'].to_s.end_with?(' View') }, 'no element named "* View" is left', fails)
check(all_formulas(dm).none? { |f| f.include?('View/') }, 'no formula contains "View/"', fails)
check(elements(dm).find { |e| e['name'] == 'Calc' }['columns'][0]['formula'] == '[FACT_SALES/Store/Store Region]',
      '[<X> View/...] became [<X>/...] in a surviving element', fails)
check(elements(dm).size == 10, 'the nine base elements and the synthetic one remain', fails)

puts "\ntest_drop_views_removes_converter_helpers"
dm = { 'pages' => [{ 'elements' => [
  { 'id' => 'a', 'kind' => 'table', 'name' => 'FACT', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S FACT] }, 'columns' => [] },
  { 'id' => 'b', 'kind' => 'table', 'name' => 'Sales YTD', 'source' => { 'kind' => 'table', 'elementId' => 'a' },
    'groupings' => [{ 'id' => 'g', 'groupBy' => ['c'] }], 'columns' => [] },
  { 'id' => 'c', 'kind' => 'table', 'name' => 'Running Date', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT d, SUM(x) OVER (ORDER BY d) AS r FROM t' }, 'columns' => [] },
  { 'id' => 'd', 'kind' => 'table', 'name' => 'Group Sales', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT 1 AS x' }, 'columns' => [] }
] }] }
removed = PbiShapedModel.drop_views!(dm)
check(removed.sort == ['Running Date', 'Sales YTD'], "time-intelligence and window helper elements go (#{removed.inspect})", fails)
check(elements(dm).map { |e| e['name'] } == ['FACT', 'Group Sales'], 'a plain Custom SQL element with a helper-like name stays', fails)

puts "\ntest_drop_views_retargets_and_resolves_view_columns"
def view_dm
  { 'pages' => [{ 'elements' => [
    { 'id' => 'fact', 'kind' => 'table', 'name' => 'FACT', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S FACT] },
      'columns' => [{ 'id' => 'inode-F/KEY', 'formula' => '[FACT/Key]' }, { 'id' => 'inode-F/AMT', 'formula' => '[FACT/Amt]' }],
      'relationships' => [{ 'id' => 'r0', 'name' => 'Dim', 'targetElementId' => 'dim', 'keys' => [{ 'sourceColumnId' => 'inode-F/KEY', 'targetColumnId' => 'inode-D/KEY' }] }] },
    { 'id' => 'dim', 'kind' => 'table', 'name' => 'DIM', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S DIM] },
      'columns' => [{ 'id' => 'inode-D/KEY', 'formula' => '[DIM/Key]' }, { 'id' => 'inode-D/NAME', 'formula' => '[DIM/Name]' }] },
    { 'id' => 'fv', 'kind' => 'table', 'name' => 'FACT View', 'source' => { 'kind' => 'table', 'elementId' => 'fact' },
      'columns' => [{ 'id' => 'vk', 'formula' => '[FACT/Key]' }, { 'id' => 'vn', 'formula' => '[FACT/Dim/Name]', 'hidden' => true },
                    { 'id' => 'vc', 'name' => 'Calc', 'formula' => '[FACT/Amt] * 2' }] },
    { 'id' => 'dv', 'kind' => 'table', 'name' => 'DIM View', 'source' => { 'kind' => 'table', 'elementId' => 'dim' },
      'columns' => [{ 'id' => 'dvk', 'formula' => '[DIM/Key]' }, { 'id' => 'dvj', 'formula' => '[DIM/Other/Thing]' }] },
    { 'id' => 'child', 'kind' => 'table', 'name' => 'Child', 'source' => { 'kind' => 'table', 'elementId' => 'fv' },
      'columns' => [{ 'id' => 'c1', 'name' => 'Dim Name', 'formula' => '[FACT View/Name]' },
                    { 'id' => 'c2', 'name' => 'Twice', 'formula' => '[FACT View/Calc]' },
                    { 'id' => 'c3', 'name' => 'Nope', 'formula' => '[FACT View/Missing]' },
                    { 'id' => 'c4', 'name' => 'Plain', 'formula' => '[FACT View/Key]' }] },
    { 'id' => 'other', 'kind' => 'table', 'name' => 'Other', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S OTHER] }, 'columns' => [],
      'relationships' => [
        { 'id' => 'r1', 'name' => 'Dim', 'targetElementId' => 'dv', 'keys' => [{ 'sourceColumnId' => 'x', 'targetColumnId' => 'dvk' }] },
        { 'id' => 'r2', 'name' => 'Joined', 'targetElementId' => 'dv', 'keys' => [{ 'sourceColumnId' => 'x', 'targetColumnId' => 'dvj' }] }
      ] }
  ] }] }
end
dm = view_dm
res = PbiShapedModel.drop_views!(dm)
child = elements(dm).find { |e| e['id'] == 'child' }
check(res.sort == ['DIM View', 'FACT View'], "both Views removed (#{res.to_a.inspect})", fails)
check(child['columns'][0]['formula'] == '[FACT/Dim/Name]', "a ref to a related-path View column becomes the column's own path (#{child['columns'][0]['formula']})", fails)
check(child['columns'][3]['formula'] == '[FACT/Key]', 'a ref to a plain View column becomes [Base/Col]', fails)
check(child['columns'][1]['formula'] == '[FACT View/Calc]' && res.unresolved.any? { |u| u['ref'] == '[FACT View/Calc]' && u['reason'].include?('calculation') },
      'a View column that is a calc expression is recorded as unresolved and the ref is kept', fails)
check(res.unresolved.any? { |u| u['ref'] == '[FACT View/Missing]' }, 'a ref to a column the View lacks is recorded as unresolved', fails)
check(child['source']['elementId'] == 'fact' && res.retargeted.any? { |r| r.include?('Child: source moved from FACT View to FACT') },
      'an element sourced from a View is retargeted to the base element', fails)
other = elements(dm).find { |e| e['id'] == 'other' }
check(other['relationships'].map { |r| r['name'] } == ['Dim'], 'the relationship whose keys no longer resolve is dropped', fails)
check(other['relationships'][0]['targetElementId'] == 'dim' && other['relationships'][0]['keys'][0]['targetColumnId'] == 'inode-D/KEY',
      'the relationship to a View is retargeted to the base with its key column mapped', fails)
check(res.dropped_relationships == [{ 'element' => 'Other', 'relationship' => 'Joined', 'target' => 'DIM View' }], 'the dropped relationship is recorded', fails)
check(elements(dm).flat_map { |e| [e.dig('source', 'elementId')] + (e['relationships'] || []).map { |r| r['targetElementId'] } }.compact.all? { |id| elements(dm).any? { |e| e['id'] == id } },
      'no source or relationship points at a removed element', fails)

puts "\ntest_drop_views_records_dangling_helper_refs"
dm = { 'pages' => [{ 'elements' => [
  { 'id' => 'a', 'kind' => 'table', 'name' => 'FACT', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S FACT] },
    'columns' => [{ 'id' => 'inode-A/X', 'formula' => '[FACT/X]' }, { 'id' => 'k', 'name' => 'Ytd', 'formula' => '[Sales YTD/Value]' }],
    'relationships' => [{ 'id' => 'r', 'name' => 'Ti', 'targetElementId' => 'ti', 'keys' => [] }] },
  { 'id' => 'ti', 'kind' => 'table', 'name' => 'Sales YTD', 'source' => { 'kind' => 'table', 'elementId' => 'a' }, 'groupings' => [{ 'id' => 'g', 'groupBy' => ['c'] }], 'columns' => [] },
  { 'id' => 'use', 'kind' => 'table', 'name' => 'Uses', 'source' => { 'kind' => 'table', 'elementId' => 'ti' }, 'columns' => [] }
] }] }
res = PbiShapedModel.drop_views!(dm)
kinds = res.dangling.map { |d| d['kind'] }.sort
check(res.to_a == ['Sales YTD'] && kinds == %w[formula relationship source], "formula, relationship and source refs to a removed helper are recorded as dangling (#{kinds.inspect})", fails)
check(elements(dm).find { |e| e['id'] == 'a' }['relationships'].empty?, 'a relationship to a removed helper is not left pointing nowhere', fails)

puts "\ntest_rename_reserves_metric_names"
dm = { 'pages' => [{ 'elements' => [{
  'id' => 'e1', 'kind' => 'table', 'name' => 'WH_T', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S WH_T] },
  'columns' => [{ 'id' => 'inode-A/AMT_X', 'formula' => '[T/Amt X]' }],
  'metrics' => [{ 'id' => 'm', 'name' => 'Amount', 'formula' => 'Sum([Amt X])' }]
}] }] }
tmsl = { 'model' => { 'tables' => [{ 'name' => 'T', 'columns' => [{ 'name' => 'Amount', 'sourceColumn' => 'AMT_X' }],
                                      'partitions' => [{ 'source' => { 'expression' => 'x{[Name="WH_T",Kind="Table"]}' } }] }] } }
rn = PbiShapedModel.rename_columns!(dm, tmsl, PbiShapedModel.table_for_elements(dm, tmsl))
check(rn.map { |r| r['to'] } == ['Amount (2)'], "a column does not take a name a metric already has (#{rn.map { |r| r['to'] }.inspect})", fails)

puts "\ntest_elements_take_pbi_names"
dm = sales_dm
tmsl = sales_tmsl
table_for = PbiShapedModel.table_for_elements(dm, tmsl)
check(table_for.size == 9, "all nine base elements are attributed (#{table_for.size})", fails)
PbiShapedModel.drop_views!(dm)
renames = PbiShapedModel.rename_elements!(dm, table_for)
pbi_tables = tmsl['model']['tables'].map { |t| t['name'] }
check(elements(dm).map { |e| e['name'] }.sort == pbi_tables.sort, "element names equal the Power BI table names (#{elements(dm).map { |e| e['name'] }.inspect})", fails)
check(renames['FACT_SALES'] == 'Sales' && renames['DIM_SKU'] == 'SKU' && renames['DIM_PRODUCT'] == 'Product', 'the returned map is {warehouse name => Power BI name}', fails)
check(!elements(dm).any? { |e| e['name'] == 'FACT_SALES' }, 'no warehouse name is left on an element', fails)
inv = load_json('inventory', 'dm-raw.json')
inv_for = PbiShapedModel.table_for_elements(inv, load_json('inventory', 'model.bim'))
un = PbiShapedModel.unattributed_elements(inv, inv_for)
check(un.any? { |u| u['name'].nil? }, 'the unnamed Custom SQL element is reported as unattributed', fails)
PbiShapedModel.drop_views!(inv)
PbiShapedModel.rename_elements!(inv, inv_for)
check(elements(inv).count { |e| e['name'].nil? } == 1, 'an unattributed element keeps its converter name', fails)

puts "\ntest_columns_take_pbi_names_and_refs_follow"
dm = sales_dm
tmsl = sales_tmsl
fact = elements(dm).find { |e| e['name'] == 'FACT_SALES' }
fact['columns'] << { 'id' => 'calc1', 'name' => 'Key Echo', 'formula' => 'Text([Order Date Key]) & Text([FACT_SALES/Order Date Key])' }
fact['columns'] << { 'id' => 'calc2', 'name' => 'Date Month', 'formula' => '[Date/Month Num] & " [Order Date Key]"' }
fact['columns'] << { 'id' => 'calc3', 'name' => 'Cal Date Alt', 'formula' => 'DateTrunc("day", [DATE_VIA_SHIPDATEKEY/Cal Date])' }
fact['metrics'] << { 'id' => 'm9', 'name' => 'Distinct Keys', 'formula' => 'CountDistinct([Sales Line Key])' }
before_keys = fact['relationships'].map { |r| r['keys'] }
_tf, el_renames, col_renames = shaped(dm, tmsl)
sales = elements(dm).find { |e| e['name'] == 'Sales' }
names = sales['columns'].map { |c| c['name'] }.compact
check(names.include?('OrderDateKey'), 'Sales has a column named OrderDateKey', fails)
check(!names.include?('Order Date Key'), 'the old display name is gone', fails)
odk = sales['columns'].find { |c| c['name'] == 'OrderDateKey' }
check(odk['id'].end_with?('/ORDER_DATE_KEY') && odk['formula'] == '[SALES/Order Date Key]',
      "the physical binding is untouched (#{odk['id']}, #{odk['formula']})", fails)
check(sales['columns'].find { |c| c['name'] == 'Key Echo' }['formula'] == 'Text([OrderDateKey]) & Text([Sales/OrderDateKey])',
      'sibling and [Element/Col] refs follow the new name', fails)
check(sales['columns'].find { |c| c['name'] == 'Date Month' }['formula'] == '[Date/Month Number] & " [Order Date Key]"',
      'a relationship-path ref follows the target column rename; text in a string literal is not touched', fails)
check(sales['columns'].find { |c| c['name'] == 'Cal Date Alt' }['formula'] == 'DateTrunc("day", [DATE_VIA_SHIPDATEKEY/Date])',
      'a ref through a differently named (inactive) relationship follows too', fails)
check(sales['metrics'].find { |m| m['name'] == 'Distinct Keys' }['formula'] == 'CountDistinct([SalesLineKey])', 'a metric follows the new column name', fails)
check(sales['metrics'].find { |m| m['name'] == 'Sales Amount' }['formula'] == 'Sum([Quantity] * [Unit Price] * (1 - [Discount]))',
      'a metric over columns that kept their names is unchanged', fails)
check(sales['relationships'].map { |r| r['keys'] } == before_keys, 'relationship keys (column ids) are unchanged', fails)
dates = elements(dm).find { |e| e['name'] == 'Date' }
check(dates['columns'].find { |c| c['name'] == 'Month Start' }['formula'] == 'MakeDate(Year([Date]), Month([Date]), 1)',
      "a calc column on the Date table follows Cal Date -> Date (#{dates['columns'].find { |c| c['name'] == 'Month Start' }['formula']})", fails)
check(col_renames.any? { |r| r['element'] == 'Sales' && r['from'] == 'Order Date Key' && r['to'] == 'OrderDateKey' }, 'the rename list names element, from and to', fails)
check(el_renames['FACT_SALES'] == 'Sales', 'element renames are returned alongside', fails)
# every ref in the model still resolves to a column or metric name of its element, or a path
stale = elements(dm).flat_map { |e| (e['columns'] + (e['metrics'] || [])).reject { |c| c['id'].to_s.start_with?('inode-') }.map { |c| c['formula'].to_s } }
check(stale.none? { |f| f.gsub(/"[^"]*"/, '') =~ /\[(Order Date Key|Sales Line Key|Sku Key|Ship Date Key)\]/ }, 'no formula still names a renamed-away column', fails)

puts "\ntest_rename_collision_gets_suffix_and_map_entry"
dm = { 'pages' => [{ 'elements' => [{
  'id' => 'e1', 'kind' => 'table', 'name' => 'WH_T', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S WH_T] },
  'columns' => [
    { 'id' => 'inode-AAA/ORDER_DATE', 'formula' => '[T/Order Date]' },
    { 'id' => 'inode-AAA/ORDERDATE', 'formula' => '[T/Orderdate]' },
    { 'id' => 'c3', 'name' => 'Twice', 'formula' => '[Order Date] & [Orderdate]' }
  ]
}] }] }
tmsl = { 'model' => { 'tables' => [{ 'name' => 'T', 'columns' => [{ 'name' => 'OrderDate', 'sourceColumn' => 'ORDER_DATE' }],
                                      'partitions' => [{ 'source' => { 'expression' => ['let Source = X{[Name="WH_T",Kind="Table"]}[Data] in Source'] } }] }] } }
tf = PbiShapedModel.table_for_elements(dm, tmsl)
check(tf == { 'e1' => 'T' }, 'the synthetic element is attributed', fails)
renames = PbiShapedModel.rename_columns!(dm, tmsl, tf)
cols = dm['pages'][0]['elements'][0]['columns']
check(cols[0]['name'] == 'OrderDate' && cols[1]['name'] == 'OrderDate (2)', "the two columns become X and X (2) (#{cols.map { |c| c['name'] }.inspect})", fails)
check(renames.map { |r| [r['from'], r['to']] } == [['Order Date', 'OrderDate'], ['Orderdate', 'OrderDate (2)']], "the returned renames list both (#{renames.inspect})", fails)
PbiShapedModel.rewrite_refs!(dm, {}, renames)
check(cols[2]['formula'] == '[OrderDate] & [OrderDate (2)]', 'refs follow both renames', fails)

puts "\ntest_rename_names_stay_ref_safe"
dm = { 'pages' => [{ 'elements' => [
  { 'id' => 'e1', 'kind' => 'table', 'name' => 'WH_A', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S WH_A] },
    'columns' => [{ 'id' => 'inode-A/AMT', 'formula' => '[A/Amt]' }, { 'id' => 'inode-A/QTY', 'formula' => '[A/Qty]' },
                  { 'id' => 'inode-A/TAXED', 'formula' => '[A/Taxed]' }] },
  { 'id' => 'e2', 'kind' => 'table', 'name' => 'Sales', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT 1' }, 'columns' => [] }
] }] }
tmsl = { 'model' => { 'tables' => [
  { 'name' => 'Sales [Fact] ', 'columns' => [{ 'name' => 'Amt [USD]', 'sourceColumn' => 'AMT' }, { 'name' => 'Qty ', 'sourceColumn' => 'QTY' },
                                              { 'name' => 'Taxed', 'sourceColumn' => 'TAXED' }],
    'partitions' => [{ 'source' => { 'expression' => 'x{[Name="WH_A",Kind="Table"]}' } }] }
] } }
tf = PbiShapedModel.table_for_elements(dm, tmsl)
er = PbiShapedModel.rename_elements!(dm, tf)
cr = PbiShapedModel.rename_columns!(dm, tmsl, tf)
check(er == { 'WH_A' => 'Sales (Fact)' }, "[ ] and trailing space are made ref-safe in element names (#{er.inspect})", fails)
check(dm['pages'][0]['elements'][1]['name'] == 'Sales', 'an unattributed element keeps its name', fails)
check(dm['pages'][0]['elements'][0]['columns'].map { |c| PbiShapedModel.display_name(c) } == ['Amt (USD)', 'Qty', 'Taxed'], 'column names are ref-safe too', fails)
check(cr.map { |r| r['to'] } == ['Amt (USD)'], 'a column whose name is already the Power BI name (even after trimming) is not listed', fails)

puts "\ntest_unmatched_columns_and_idempotent"
dm = sales_dm
tmsl = sales_tmsl
shaped(dm, tmsl)
snap = JSON.generate(dm)
tf2 = PbiShapedModel.table_for_elements(dm, tmsl)
check(PbiShapedModel.rename_columns!(dm, tmsl, tf2).empty? && JSON.generate(dm) == snap, 'a second rename pass changes nothing', fails)

def inventory_dm
  load_json('inventory', 'dm-raw.json')
end

def inventory_tmsl
  load_json('inventory', 'model.bim')
end

# sales_dm plus two calc columns on FACT_SALES that read the Date table through the converter's relationship
# names (the raw fixture only reaches them through the dropped Views).
def sales_dm_with_date_paths
  dm = sales_dm
  fact = elements(dm).find { |e| e['name'] == 'FACT_SALES' }
  fact['columns'] << { 'id' => 'zz1', 'name' => 'Ship Date', 'formula' => '[FACT_SALES/DATE_VIA_SHIPDATEKEY/Cal Date]' }
  fact['columns'] << { 'id' => 'zz2', 'name' => 'Order Date', 'formula' => '[FACT_SALES/Date/Cal Date]' }
  dm
end

def rel_names(el)
  (el['relationships'] || []).map { |r| r['name'] }
end

puts "\ntest_relationship_name"
check(PbiShapedModel.relationship_name('toTable' => 'Date', 'fromColumn' => 'OrderDateKey') == 'Date', 'an active relationship is named after the target table', fails)
check(PbiShapedModel.relationship_name('toTable' => 'Date', 'fromColumn' => 'ShipDateKey', 'isActive' => false) == 'Date (ShipDateKey)', 'an inactive one is "<Target> (<fromColumn>)"', fails)

puts "\ntest_active_rel_named_after_target"
dm = sales_dm_with_date_paths
tmsl = sales_tmsl
table_for, = shaped(dm, tmsl)
res = PbiShapedModel.relationships!(dm, tmsl, table_for)
sales = elements(dm).find { |e| e['name'] == 'Sales' }
check(%w[Date SKU Customer Store].all? { |n| rel_names(sales).include?(n) }, "Sales relationships are named after their targets (#{rel_names(sales).inspect})", fails)
check(rel_names(elements(dm).find { |e| e['name'] == 'Product' }).sort == %w[Category Vendor], 'Product keeps Category and Vendor', fails)
check(res['added'] == [] && res['not_carried'] == [], 'nothing added, nothing not carried for the sales fixture', fails)

puts "\ntest_activated_inactive_rel_named_target_from_column"
check(rel_names(sales).include?('Date (ShipDateKey)'), 'the activated inactive relationship is "Date (ShipDateKey)"', fails)
check(res['renamed'].any? { |r| r['from'] == 'DATE_VIA_SHIPDATEKEY' && r['to'] == 'Date (ShipDateKey)' && r['element'] == 'Sales' }, 'the rename is recorded', fails)
check(!JSON.generate(dm).include?('DATE_VIA_SHIPDATEKEY'), 'DATE_VIA_SHIPDATEKEY is absent everywhere, formulas included', fails)
check(all_formulas(dm).include?('[Sales/Date (ShipDateKey)/Date]'), 'formula paths follow the new name', fails)
check(all_formulas(dm).include?('[Sales/Date/Date]'), 'a path through an unrenamed relationship is untouched', fails)
check(all_formulas(dm).none? { |f| f.include?('Sales/DATE_VIA') }, 'no path keeps the old segment', fails)
res2 = PbiShapedModel.relationships!(dm, tmsl, table_for)
check(res2['renamed'].empty?, 'a second call renames nothing', fails)

puts "\ntest_carried_records_which_power_bi_relationship_each_sigma_relationship_carries"
ship_tr = sales_tmsl['model']['relationships'].find { |r| r['isActive'] == false && r['fromColumn'].to_s =~ /ship/i }
ship_rel = sales['relationships'].find { |r| r['name'] == 'Date (ShipDateKey)' }
carried = res['carried'].find { |c| c['relationship'] == ship_tr['name'] }
check(carried && carried['element'] == 'Sales' && carried['name'] == 'Date (ShipDateKey)' && carried['id'] == ship_rel['id'],
      "carried names the Power BI relationship, its element, Sigma name and id: #{carried.inspect}", fails)
check(res2['carried'].map { |c| c['relationship'] }.sort == res['carried'].map { |c| c['relationship'] }.sort,
      'a second call still lists every carried relationship', fails)
# a relationship the converter built that no Power BI relationship claims ("occupant") already holds the name:
# the carried one is uniquified, and carried points at it, not at the occupant
dmo = sales_dm_with_date_paths
fact = elements(dmo).find { |e| e['name'] == 'FACT_SALES' }
occ_target = fact['relationships'].find { |r| r['name'] == 'DATE_VIA_SHIPDATEKEY' }['targetElementId']
fact['relationships'] << { 'id' => 'rel-occupant', 'name' => 'Date (ShipDateKey)', 'targetElementId' => occ_target, 'keys' => [] }
tfo, = shaped(dmo, sales_tmsl)
reso = PbiShapedModel.relationships!(dmo, sales_tmsl, tfo)
co = reso['carried'].find { |c| c['relationship'] == ship_tr['name'] }
check(co && co['name'] == 'Date (ShipDateKey) (2)' && co['id'] != 'rel-occupant',
      "a uniquified relationship is carried under its new name, not the occupant's: #{co.inspect}", fails)

puts "\ntest_unactivated_inactive_rel_listed_not_carried"
dm = inventory_dm
tmsl = inventory_tmsl
table_for, = shaped(dm, tmsl)
res = PbiShapedModel.relationships!(dm, tmsl, table_for)
nc = res['not_carried']
check(nc.size == 1 && nc[0]['relationship'] == 'PO_ExpectedDate' && nc[0]['fromColumn'] == 'ExpectedDateKey' && nc[0]['reason'].include?('inactive'),
      "the unused inactive PO_ExpectedDate is listed (#{nc.inspect})", fails)
po = elements(dm).find { |e| e['name'] == 'Purchase Orders' }
check(po && rel_names(po).sort == %w[Date SKU], 'Purchase Orders carries only its two active relationships', fails)
check(rel_names(elements(dm).find { |e| e['name'] == 'Sales' }).include?('Date (ShipDateKey)'), 'the activated Sales ship-date relationship is still renamed', fails)

puts "\ntest_key_check_queries_one_per_relationship"
dm = sales_dm
tmsl = sales_tmsl
table_for, = shaped(dm, tmsl)
PbiShapedModel.relationships!(dm, tmsl, table_for)
total = elements(dm).sum { |e| (e['relationships'] || []).size }
qs = PbiShapedModel.key_check_queries(dm, dialect: 'snowflake')
check(qs.size == total && total == 8, "one query per relationship (#{qs.size} of #{total})", fails)
check(qs['Sales->Date'] == 'SELECT COUNT("DATE_KEY") - COUNT(DISTINCT "DATE_KEY") AS dup FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_DATE"', "a warehouse-table target is a quoted three-part name (#{qs['Sales->Date']})", fails)
check(qs.key?('Sales->Date (ShipDateKey)') && qs.key?('SKU->Product'), 'the activated inactive relationship has its own key', fails)
check(PbiShapedModel.key_check_queries(dm, dialect: 'databricks')['Sales->Date'].include?('`SAMPLE_DB`.`ZZ_CLAUDE_PBI_SHAPED`.`DIM_DATE`'), 'Databricks quotes with backticks', fails)
sql_dm = { 'pages' => [{ 'elements' => [
  { 'id' => 'f', 'name' => 'F', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S F] }, 'columns' => [{ 'id' => 'inode-F/K', 'formula' => '[F/K]' }],
    'relationships' => [{ 'id' => 'r', 'name' => 'Q', 'targetElementId' => 'q', 'keys' => [{ 'sourceColumnId' => 'inode-F/K', 'targetColumnId' => 'inode-Q/BUCKET' }] }] },
  { 'id' => 'q', 'name' => 'Q', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT 1 AS "Bucket"' }, 'columns' => [{ 'id' => 'inode-Q/BUCKET', 'formula' => '[Custom SQL/Bucket]' }] }
] }] }
check(PbiShapedModel.key_check_queries(sql_dm, dialect: 'snowflake')['F->Q'] == 'SELECT COUNT("Bucket") - COUNT(DISTINCT "Bucket") AS dup FROM (' + "\n" + 'SELECT 1 AS "Bucket"' + "\n" + ') AS t',
      'a Custom SQL target is the statement in parentheses, keyed on the alias', fails)

puts "\ntest_duplicate_key_result_drops_and_records"
dm = sales_dm_with_date_paths
tmsl = sales_tmsl
table_for, = shaped(dm, tmsl)
PbiShapedModel.relationships!(dm, tmsl, table_for)
qs = PbiShapedModel.key_check_queries(dm)
results = qs.keys.each_with_object({}) { |k, h| h[k] = 0 }
results['Sales->Date (ShipDateKey)'] = 3
kr = PbiShapedModel.apply_key_results!(dm, results)
sales = elements(dm).find { |e| e['name'] == 'Sales' }
check(kr.size == qs.size, 'one entry per checked relationship', fails)
drop = kr.find { |r| r['relationship'] == 'Sales->Date (ShipDateKey)' }
check(drop && drop['action'] == 'dropped' && drop['dup'] == 3, "the duplicated key drops the relationship (#{drop.inspect})", fails)
check(kr.count { |r| r['action'] == 'kept' } == qs.size - 1, 'every unique key is kept', fails)
check(!rel_names(sales).include?('Date (ShipDateKey)') && rel_names(sales).include?('Date'), 'the dropped relationship is gone, the active one stays', fails)
date = elements(dm).find { |e| e['name'] == 'Date' }
check(date['description'].to_s.include?('Date (ShipDateKey)') && date['description'].include?('not carried'), 'the choice is recorded in the target description', fails)
check(kr.dangling.map { |d| d['ref'] } == ['[Sales/Date (ShipDateKey)/Date]'] && kr.dangling[0]['relationship'] == 'Sales->Date (ShipDateKey)' && kr.dangling[0]['column'] == 'Ship Date',
      "only the formula through the dropped relationship is recorded as dangling (#{kr.dangling.inspect})", fails)
check(drop && drop['action'] == 'dropped' && !kr.any? { |r| r['action'] == 'rekeyed' }, 'a Date target read beyond its key is not re-keyed', fails)
check(PbiShapedModel.apply_key_results!(sales_dm, {}).empty?, 'no results, no entries', fails)

puts "\ntest_duplicate_key_rekeys_a_key_only_target"
def rekey_dm
  { 'pages' => [{ 'elements' => [
    { 'id' => 'f', 'kind' => 'table', 'name' => 'Fact', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S FACT] },
      'columns' => [{ 'id' => 'inode-F/DIM_KEY', 'formula' => '[FACT/Dim Key]' }, { 'id' => 'c1', 'name' => 'Dim Key Copy', 'formula' => '[Dim/Dim Key]' }],
      'relationships' => [{ 'id' => 'r', 'name' => 'Dim', 'targetElementId' => 'd', 'keys' => [{ 'sourceColumnId' => 'inode-F/DIM_KEY', 'targetColumnId' => 'inode-D/DIM_KEY' }] }] },
    { 'id' => 'd', 'kind' => 'table', 'name' => 'Dim', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S DIM] },
      'columns' => [{ 'id' => 'inode-D/DIM_KEY', 'formula' => '[DIM/Dim Key]' }, { 'id' => 'inode-D/LABEL', 'formula' => '[DIM/Label]' }] }
  ] }] }
end
dm = rekey_dm
kr = PbiShapedModel.apply_key_results!(dm, { 'Fact->Dim' => 2 }, rekey: true)
fact = elements(dm).find { |e| e['name'] == 'Fact' }
child = elements(dm).find { |e| e['name'] == 'Dim (distinct Dim Key)' }
check(kr[0]['action'] == 'rekeyed' && kr[0]['child'] == 'Dim (distinct Dim Key)' && kr.dangling.empty?, "a key-only warehouse target is re-keyed (#{kr.to_a.inspect})", fails)
check(child && child['source'] == { 'kind' => 'table', 'elementId' => 'd' } && child['groupings'][0]['groupBy'] == [child['columns'][0]['id']], 'the child is grouped on the key', fails)
check(fact['relationships'][0]['targetElementId'] == child['id'] && fact['relationships'][0]['keys'][0]['targetColumnId'] == child['columns'][0]['id'], 'the relationship points at the child key column', fails)
check(fact['relationships'][0]['name'] == 'Dim' && fact['columns'][1]['formula'] == '[Dim/Dim Key]', 'the relationship name and key paths stay valid', fails)
check(child['columns'][0]['name'] == 'Dim Key' && child['columns'][0]['formula'] == '[Dim/Dim Key]', 'the child column keeps the key name', fails)
check(elements(dm).index(child) == elements(dm).index(elements(dm).find { |e| e['name'] == 'Dim' }) + 1, 'the child sits next to its target', fails)
check(elements(dm).find { |e| e['name'] == 'Dim' }['description'].to_s.include?('duplicated'), 'recorded on the target', fails)
dm = rekey_dm
kr = PbiShapedModel.apply_key_results!(dm, { 'Fact->Dim' => 2 })
check(kr[0]['action'] == 'dropped' && kr[0]['dup'] == 2 && elements(dm).none? { |e| e['name'].to_s.include?('distinct') }, 'default: the same fixture drops the relationship (no re-key)', fails)
check(kr.dangling.map { |d| d['ref'] } == ['[Dim/Dim Key]'] && elements(dm)[0]['relationships'].empty? && elements(dm)[1]['description'].to_s.include?('not carried'), 'default: the drop is recorded with its dangling formulas', fails)
dm = rekey_dm
elements(dm)[0]['columns'] << { 'id' => 'c2', 'name' => 'Lbl', 'formula' => '[Fact/Dim/Label]' }
kr = PbiShapedModel.apply_key_results!(dm, { 'Fact->Dim' => 2 }, rekey: true)
check(kr[0]['action'] == 'dropped' && kr.dangling.map { |d| d['ref'] }.sort == ['[Dim/Dim Key]', '[Fact/Dim/Label]'], 'a target read beyond its key is dropped and every path through it is dangling', fails)
dm = rekey_dm
elements(dm)[1]['source'] = { 'kind' => 'sql', 'statement' => 'SELECT 1' }
check(PbiShapedModel.apply_key_results!(dm, { 'Fact->Dim' => 2 }, rekey: true)[0]['action'] == 'dropped', 'a Custom SQL target is dropped, not re-keyed', fails)


puts "\ntest_key_check_nulls_semicolons_composite"
sql_dm['pages'][0]['elements'][1]['source']['statement'] = "SELECT 1 AS \"Bucket\" ;\n"
check(PbiShapedModel.key_check_queries(sql_dm)['F->Q'].end_with?("FROM (\nSELECT 1 AS \"Bucket\"\n) AS t"), 'a trailing semicolon is stripped and the alias kept', fails)
sql_dm['pages'][0]['elements'][1]['source']['statement'] = "SELECT 1 AS \"Bucket\" -- trailing comment\n"
check(PbiShapedModel.key_check_queries(sql_dm)['F->Q'].end_with?("-- trailing comment\n) AS t"), 'a trailing -- comment cannot swallow the closing paren (statement on its own lines)', fails)
check(PbiShapedModel.key_check_queries(sql_dm)['F->Q'].start_with?('SELECT COUNT("Bucket") - COUNT(DISTINCT'), 'single key counts non-NULL values only', fails)
comp = { 'pages' => [{ 'elements' => [
  { 'id' => 'f', 'name' => 'F', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S F] }, 'columns' => [{ 'id' => 'inode-F/A', 'formula' => '[F/A]' }],
    'relationships' => [{ 'id' => 'r', 'name' => 'Q', 'targetElementId' => 'q', 'keys' => [{ 'sourceColumnId' => 'inode-F/A', 'targetColumnId' => 'inode-Q/A' }, { 'sourceColumnId' => 'inode-F/A', 'targetColumnId' => 'inode-Q/B' }] }] },
  { 'id' => 'q', 'name' => 'Q', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[D S Q] }, 'columns' => [{ 'id' => 'inode-Q/A', 'formula' => '[Q/A]' }, { 'id' => 'inode-Q/B', 'formula' => '[Q/B]' }] }
] }] }
%w[snowflake databricks bigquery].each do |d|
  q = PbiShapedModel.key_check_queries(comp, dialect: d)['F->Q']
  check(q.include?('IS NOT NULL') && q.include?('HAVING COUNT(*) > 1') && !q.include?('DISTINCT'), "composite key (#{d}) uses GROUP BY/HAVING over non-NULL tuples, no multi-column DISTINCT", fails)
end

puts "\ntest_relationship_name_conflict_recorded"
dmc = sales_dm
tmc = sales_tmsl
tfc, = shaped(dmc, tmc)
dup_tr = tmc['model']['relationships'].find { |r| r['name'] == 'Sales_OrderDate' }.dup
dup_tr['name'] = 'Sales_OrderDate_Copy'
tmc['model']['relationships'] << dup_tr
resc = PbiShapedModel.relationships!(dmc, tmc, tfc)
check(resc['conflicts'].size == 1 && resc['conflicts'][0]['claimed_by'] == %w[Sales_OrderDate Sales_OrderDate_Copy], "two TMSL relationships on one Sigma relationship are a recorded conflict (#{resc['conflicts'].inspect})", fails)

puts "\ntest_name_unattributed_subset_rules"
calc = ->(name, cols) { { 'name' => name, 'columns' => cols.map { |c| { 'name' => c } }, 'partitions' => [{ 'source' => { 'type' => 'calculated' } }] } }
tm = { 'model' => { 'tables' => [calc.call('Wide', %w[Id Name Kind Sort]), calc.call('Narrow', %w[Code Label])] } }
mk = ->(id, cols) { { 'id' => id, 'name' => "E#{id}", 'source' => { 'kind' => 'sql', 'statement' => 'SELECT 1' }, 'columns' => cols.map { |c| { 'id' => "inode-#{id}/#{c.upcase}", 'formula' => "[Custom SQL/#{c}]" } } } }
d1 = { 'pages' => [{ 'elements' => [mk.call('a', %w[Id])] }] }
r1 = PbiShapedModel.name_unattributed!(d1, tm, {})
check(r1['named'].empty? && r1['unmatched'].size == 1, 'a 1-column subset (a quarter of the table) is not claimed', fails)
d2 = { 'pages' => [{ 'elements' => [mk.call('a', %w[Code]), mk.call('b', %w[Code Label])] }] }
r2 = PbiShapedModel.name_unattributed!(d2, tm, {})
check(r2['named'].map { |n| [n['id'], n['to']] } == [%w[b Narrow]] && r2['unmatched'].map { |u| u['id'] } == ['a'], "an exact match wins over an earlier half-subset claimant (#{r2['named'].inspect})", fails)
d3 = { 'pages' => [{ 'elements' => [mk.call('a', %w[Id Name])] }] }
check(PbiShapedModel.name_unattributed!(d3, tm, {})['named'].map { |n| n['to'] } == ['Wide'], 'a 2-column subset of one table is accepted', fails)

puts "\ntest_name_unattributed_names_calc_table_element"
dm = inventory_dm
tmsl = inventory_tmsl
table_for = PbiShapedModel.table_for_elements(dm, tmsl)
un = PbiShapedModel.unattributed_elements(dm, table_for)
check(un.any? { |u| u['name'].nil? }, 'precondition: the unnamed Custom SQL element is unattributed', fails)
PbiShapedModel.drop_views!(dm)
PbiShapedModel.rename_elements!(dm, table_for)
named = PbiShapedModel.name_unattributed!(dm, tmsl, table_for)
cover = elements(dm).find { |e| e['id'] == 'AAAAAAAABV' }
check(cover['name'] == 'Cover Bucket' && table_for['AAAAAAAABV'] == 'Cover Bucket', "the DATATABLE element is named Cover Bucket (#{cover['name'].inspect})", fails)
check(named['named'].size == 1 && named['named'][0]['to'] == 'Cover Bucket', 'exactly one element is named', fails)
check(named['unmatched'].empty?, "nothing is left unmatched (#{named['unmatched'].inspect})", fails)
dm2 = { 'pages' => [{ 'elements' => [
  { 'id' => 'u1', 'name' => 'Custom SQL', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT 1' }, 'columns' => [{ 'id' => 'inode-u1/ZZZ', 'formula' => '[Custom SQL/Zzz]' }] },
  { 'id' => 'u2', 'name' => 'Custom SQL (2)', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT 1 AS "Bucket"' }, 'columns' => [{ 'id' => 'inode-u2/BUCKET', 'formula' => '[Custom SQL/Bucket]' }, { 'id' => 'inode-u2/MIN_DAYS', 'formula' => '[Custom SQL/Min Days]' }] }
] }] }
named2 = PbiShapedModel.name_unattributed!(dm2, tmsl, {})
check(named2['unmatched'].map { |u| u['id'] } == ['u1'] && elements(dm2)[0]['name'] == 'Custom SQL', 'an element whose columns match no calculated table stays unmatched and keeps its name', fails)
check(named2['renames'] == { 'Custom SQL (2)' => 'Cover Bucket' }, 'a previously named element is in the renames map so refs follow', fails)

puts "\ntest_pbi_mode_refuses_roles_exit_10"
Dir.mktmpdir('pbi-shaped') do |dir|
  out, st = run_migrate(dir, File.join(FIX, 'rls', 'model.bim'), '--model-shape', 'pbi',
                        '--converter-out', File.join(FIX, 'sales', 'dm-raw.json'))
  check(st.exitstatus == 10, "exit 10 (got #{st.exitstatus})#{st.exitstatus == 10 ? '' : "\n#{out.lines.last(10).join}"}", fails)
  check(st.exitstatus == 10, 'exit code is 10 on its own', fails)
  check(out.include?('OPEN QUESTION'), 'the output says OPEN QUESTION', fails)
  check(out.include?('West Stores'), 'the output names the role', fails)
  check(out.include?('default'), 'it tells the user to use the default shape', fails)
  log = File.join(dir, 'http.log')
  writes = (File.exist?(log) ? File.readlines(log) : []).map(&:strip).grep(/\A(POST|PUT|PATCH|DELETE) /)
  check(writes.empty?, 'nothing was written to Sigma', fails)
  out, st = run_migrate(dir, File.join(FIX, 'rls', 'model.bim'), '--converter-out', File.join(FIX, 'sales', 'dm-raw.json'))
  check(!out.include?('model_shape'), 'the default shape does not mention the refusal', fails)
  check(st.exitstatus != 10 || !out.include?('West Stores'), 'the default shape is not refused for roles', fails)
  out, st = run_migrate(dir, File.join(FIX, 'rls', 'model.bim'), '--model-shape', 'views', '--converter-out', File.join(FIX, 'sales', 'dm-raw.json'))
  check(!out.include?('model_shape'), '--model-shape views behaves as the default', fails)
  out, st = run_migrate(dir, File.join(FIX, 'rls', 'model.bim'), '--model-shape', 'bogus')
  check(!st.success? && out.include?('invalid argument'), 'an unknown shape is rejected by the option parser', fails)
  out, st = run_migrate(dir, File.join(FIX, 'rls', 'model.bim'), '--model-shape', 'pbi', '--flatten', 'Sales,Inventory',
                        '--converter-out', File.join(FIX, 'sales', 'dm-raw.json'))
  check(st.exitstatus == 10 && out.include?('West Stores'), '--flatten LIST parses (the refusal still comes first)', fails)
end

puts "\ntest_role_without_permissions_passes"
Dir.mktmpdir('pbi-shaped') do |dir|
  tmsl_path = File.join(dir, 'model.bim')
  File.write(tmsl_path, JSON.pretty_generate(orders_model([{ 'name' => 'Everyone', 'modelPermission' => 'read' }])))
  out, st = run_migrate(dir, tmsl_path, '--model-shape', 'pbi')
  check(st.exitstatus.zero? && !out.include?('OPEN QUESTION'), "a role with no permissions does not stop the run (exit #{st.exitstatus})#{st.exitstatus.zero? ? '' : "\n#{out.lines.last(12).join}"}", fails)
  File.write(tmsl_path, JSON.pretty_generate(orders_model([{ 'name' => 'Filtered', 'tablePermissions' => [{ 'name' => 'Orders', 'filterExpression' => '[Amount] > 0' }] }])))
  out, st = run_migrate(dir, tmsl_path, '--model-shape', 'pbi')
  check(st.exitstatus == 10 && out.include?('Filtered'), 'the same model with a filtered role is refused', fails)
  out, st = run_migrate(dir, tmsl_path)
  check(st.exitstatus.zero?, "and the default shape still runs it (exit #{st.exitstatus})", fails)
end


# ---- Task 11: fact split, Lookup chains, report filters, folders, names, descriptions ----------------
require_relative 'lib/pbi_measure_class'

# The real pipeline: drop Views, rename, name relationships, classify, build the B metrics the converter
# dropped. split_facts! is left to the test.
def split_setup(fixture = 'sales')
  dm = load_json(fixture, 'dm-raw.json')
  tmsl = load_json(fixture, 'model.bim')
  signals = load_json(fixture, 'signals.json')
  table_for, = shaped(dm, tmsl)
  PbiShapedModel.relationships!(dm, tmsl, table_for)
  rels = (tmsl['model'] || tmsl)['relationships']
  classes = PbiMeasureClass.classify_all(signals, tmsl, rels)
  built = PbiShapedModel.build_b_metrics!(dm, tmsl, classes)
  [dm, tmsl, signals, classes, built]
end

def element_named(dm, name)
  elements(dm).find { |e| e['name'] == name }
end

puts "\ntest_split_only_facts_with_class_b"
dm, _tmsl, _sig, classes = split_setup
res = PbiShapedModel.split_facts!(dm, classes)
check(res.map { |r| r['fact'] } == ['Sales'], "only Sales is split (#{res.map { |r| r['fact'] }.inspect})", fails)
check(res[0]['base'] == 'Sales (source)' && res[0]['child'] == 'Sales', 'base is "Sales (source)", child keeps the Power BI name', fails)
base = element_named(dm, 'Sales (source)')
child = element_named(dm, 'Sales')
check(base && child && child['source'] == { 'kind' => 'table', 'elementId' => base['id'] }, 'child is a table over the base', fails)
check(!base.key?('metrics') && child['metrics'].map { |m| m['name'] }.include?('List Value') && child['metrics'].length == 10,
      'all 10 metrics moved to the child, none left on the base', fails)
check(elements(dm).count { |e| e['name'] == 'Product' } == 1 && !element_named(dm, 'Product (source)'), 'dimensions are not split', fails)
check(base['columns'].map { |c| c['id'] } == base['order'] && base['columns'].none? { |c| c['formula'].to_s.include?('Lookup(') }, 'the base keeps its columns and gets no lookups', fails)
check(child['columns'].first['formula'] == '[Sales (source)/SalesLineKey]', "child columns read the base: #{child['columns'].first['formula']}", fails)
check(child['order'] == child['columns'].map { |c| c['id'] }, 'child order lists every column', fails)
ids = elements(dm).flat_map { |e| [e['id']] + Array(e['columns']).map { |c| c['id'] } + Array(e['relationships']).map { |r| r['id'] } }
check(ids.uniq.length == ids.length, 'ids stay unique', fails)

inv_dm, _t, _s, inv_classes = split_setup('inventory')
check(inv_classes.values.none? { |c| c['class'] == 'B' && !c['related'].empty? }, 'inventory has no class B metric with related inputs', fails)
before = JSON.generate(inv_dm)
check(PbiShapedModel.split_facts!(inv_dm, inv_classes) == [] && JSON.generate(inv_dm) == before, 'Inventory (class A only) is not split and not touched', fails)
only_userel = { 'Sales.Sales by Ship Date' => classes['Sales.Sales by Ship Date'] }
dm_u, = split_setup
check(PbiShapedModel.split_facts!(dm_u, only_userel) == [], 'a USERELATIONSHIP-only fact needs no split', fails)

puts "\ntest_child_has_lookup_chain_for_list_price"
lookups = res[0]['lookups'].each_with_object({}) { |l, h| h[l['name']] = l['formula'] }
check(lookups['ProductKey (SKU)'] == 'Lookup([SKU/ProductKey], [SkuKey], [SKU/SkuKey])', "hop 1: #{lookups['ProductKey (SKU)']}", fails)
lp = lookups.find { |k, _| k.start_with?('List Price') }
check(lp && lp[1] == 'Lookup([Product/List Price], [ProductKey (SKU)], [Product/ProductKey])', "hop 2: #{lp.inspect}", fails)
check(lookups.keys.sort == ['List Price (Product)', 'Private Label (Product)', 'ProductKey (SKU)'], "one shared key column, one value column per related input: #{lookups.keys.inspect}", fails)
lv = child['metrics'].find { |m| m['name'] == 'List Value' }
check(lv['formula'] == 'Sum([Quantity] * [List Price (Product)])', "List Value reads the lookup column: #{lv['formula']}", fails)
pl = child['metrics'].find { |m| m['name'] == 'Private Label Sales' }
check(pl['formula'] == 'SumIf(Coalesce([Quantity], 0) * Coalesce([Unit Price], 0) * (1 - Coalesce([Discount], 0)), [Private Label (Product)] = True)', "CALCULATE filter becomes SumIf over the lookup: #{pl['formula']}", fails)
sd = child['metrics'].find { |m| m['name'] == 'Sales by Ship Date' }
check(sd['formula'] == child['metrics'].find { |m| m['name'] == 'Sales Amount' }['formula'], 'the USERELATIONSHIP metric is the Sales Amount formula and needs no chain', fails)
check(child['metrics'].find { |m| m['name'] == 'Sales Amount' }['formula'] == 'Sum(Coalesce([Quantity], 0) * Coalesce([Unit Price], 0) * (1 - Coalesce([Discount], 0)))', 'R51: the class A Sales Amount follows the blank rule (id and name kept)', fails)
check(child['metrics'].find { |m| m['name'] == 'Units' }['formula'] == 'Sum([Quantity])', 'a class A metric without + or - is untouched', fails)
check(child['columns'].none? { |c| c['formula'].to_s =~ %r{\[(SKU|Sales)/[^\]]*/} }, 'no relationship-path calc column on the child (P4)', fails)

puts "\ntest_child_copies_relationships"
check(child['relationships'].map { |r| r['name'] } == base['relationships'].map { |r| r['name'] }, 'same relationship names on the child', fails)
check(child['relationships'].map { |r| r['targetElementId'] } == base['relationships'].map { |r| r['targetElementId'] }, 'same targets', fails)
ccol_ids = child['columns'].map { |c| c['id'] }
check(child['relationships'].all? { |r| r['keys'].all? { |k| ccol_ids.include?(k['sourceColumnId']) } }, 'child keys are the child\'s own columns (P5)', fails)
check((child['relationships'].map { |r| r['id'] } & base['relationships'].map { |r| r['id'] }).empty?, 'child relationship ids are new', fails)
check(base['relationships'].all? { |r| r['keys'].all? { |k| base['columns'].any? { |c| c['id'] == k['sourceColumnId'] } } }, 'the base keeps its relationships', fails)

puts "\ntest_report_filter_null_safe_on_child"
fr = PbiShapedModel.report_filters!(dm, signals_for = load_json('sales', 'signals.json'), classes)
cf = child['filters'] || []
check(fr['applied'].any? { |a| a['element'] == 'Sales' } && fr['skipped'].empty? && fr['not_reachable'].empty?, "applied to the child (#{fr['applied'].inspect}, skipped #{fr['skipped'].inspect})", fails)
catname = child['columns'].find { |c| c['name'].to_s.start_with?('Category Name') }
check(catname && catname['formula'] == 'Lookup([Category/Category Name], [CategoryKey (Product)], [Category/CategoryKey])',
      "Category Name is a Lookup chain: #{catname && catname['formula']}", fails)
check(child['columns'].any? { |c| c['name'] == 'CategoryKey (Product)' && c['formula'] == 'Lookup([Product/CategoryKey], [ProductKey (SKU)], [Product/ProductKey])' },
      'the chain reuses the shared Product key column', fails)
check(cf.length == 1 && cf[0] == { 'id' => cf[0]['id'], 'columnId' => catname['id'], 'kind' => 'text-match', 'mode' => 'does-not-equal',
                                   'value' => 'Discontinued', 'case' => 'insensitive', 'includeNulls' => 'always' },
      "m3: single excluded text value: a case-insensitive text-match that keeps nulls (#{cf.inspect})", fails)
check(!(base['filters'] || []).any? && (element_named(dm, 'Category')['filters'] || []).empty?, 'the base is not filtered; the Category table is NOT filtered when the fact carries the filter (a Lookup into it would return NULL, live-proven)', fails)
check(fr['dimension_unfiltered'].length == 1 && fr['dimension_unfiltered'][0]['element'] == 'Category', "the skipped dimension filter is recorded (#{fr['dimension_unfiltered'].inspect})", fails)
check(child['columns'].count { |c| c['name'].to_s.start_with?('ProductKey') } == 1, 'the shared Product key column is reused, not repeated', fails)

dm2, _t2, _s2, classes2 = split_setup
PbiShapedModel.split_facts!(dm2, classes2)
multi = { 'filters' => [{ 'scope' => 'report', 'target' => 'Category.Category Name', 'type' => 'list', 'mode' => 'exclude', 'values' => %w[Discontinued Seasonal] }] }
PbiShapedModel.report_filters!(dm2, multi, classes2)
c2 = element_named(dm2, 'Sales')
keep = c2['columns'].find { |c| c['name'].to_s.start_with?('Keep (') }
check(keep && keep['formula'].start_with?('If(IsNull([') && keep['formula'].include?('Not(In(Lower([') && keep['formula'].include?('"discontinued", "seasonal"'),
      "m3: several values: the helper keeps NULL and compares case-insensitively (#{keep && keep['formula']})", fails)
check(c2['filters'].length == 1 && c2['filters'][0]['kind'] == 'list' && c2['filters'][0]['values'] == ['keep'] && c2['filters'][0]['columnId'] == keep['id'],
      'several values: list include "keep" on the helper', fails)
dm3, _t3, _s3, classes3 = split_setup
nosplit = { 'filters' => [{ 'scope' => 'report', 'target' => 'Category.Category Name', 'type' => 'list', 'mode' => 'exclude', 'values' => ['Discontinued'] },
                          { 'scope' => 'page', 'target' => 'Product.Brand', 'type' => 'list', 'mode' => 'include', 'values' => ['X'] },
                          { 'scope' => 'report', 'target' => 'Product.Brand', 'type' => 'list', 'mode' => 'include', 'values' => %w[A B] }] }
r3 = PbiShapedModel.report_filters!(dm3, nosplit, classes3)
s3 = element_named(dm3, 'Sales')
check(!element_named(dm3, 'Sales (source)') && s3['columns'].any? { |c| c['name'].to_s.start_with?('Category Name') } && s3['filters'].length == 2,
      'no split: the filter and its lookup chain land on the element itself', fails)
check(s3['filters'].any? { |f| f['kind'] == 'list' && f['mode'] == 'include' && f['values'] == %w[A B] }, 'an include list is a plain list filter; page scope is ignored', fails)
check(r3['applied'].none? { |a| a['column'].to_s.include?('X') }, 'page-scope filters are not applied', fails)

puts "\ntest_metric_folders_follow_display_folders"
dm4, tmsl4, _s4, classes4 = split_setup
PbiShapedModel.split_facts!(dm4, classes4)
before_names = elements(dm4).flat_map { |e| (e['metrics'] || []).map { |m| m['name'] } }
out = PbiShapedModel.metric_display_folders!(dm4, tmsl4)
m4 = element_named(dm4, 'Sales')['metrics']
check(m4.find { |m| m['name'] == 'Sales Amount' }['description'] == 'Power BI display folder: Sales', 'Sales Amount description names its folder', fails)
check(m4.find { |m| m['name'] == 'List Value' }['description'] == 'Power BI display folder: Product', 'List Value is in the Product folder', fails)
check(m4.find { |m| m['name'] == 'Sales by Ship Date' }['description'] == 'Power BI display folder: Shipping', 'Sales by Ship Date is in the Shipping folder', fails)
check(elements(dm4).flat_map { |e| (e['metrics'] || []).map { |m| m['name'] } } == before_names, 'no metric is renamed or prefixed', fails)
check(elements(dm4).none? { |e| e.key?('folders') }, 'no folders[] entry holds a metric id (P14)', fails)
PbiShapedModel.metric_display_folders!(dm4, tmsl4)
check(m4.find { |m| m['name'] == 'Units' }['description'] == 'Power BI display folder: Sales', 'running it twice does not duplicate the line', fails)
check(out.any? { |o| o['metric'] == 'List Value' && o['folder'] == 'Product' }, 'the result lists metric and folder', fails)

puts "\ntest_metric_column_collision_on_one_element_suffixed"
syn = { 'pages' => [{ 'elements' => [
  { 'id' => 'e1', 'name' => 'Inventory', 'columns' => [{ 'id' => 'c1', 'name' => 'Units', 'formula' => '[INV/Units]' }, { 'id' => 'c2', 'name' => 'On Hand', 'formula' => '[INV/On Hand]' }],
    'metrics' => [{ 'id' => 'm1', 'name' => 'Units', 'formula' => 'Sum([Units])' }, { 'id' => 'm2', 'name' => 'Open', 'formula' => 'Sum([On Hand])' }] },
  { 'id' => 'e2', 'name' => 'Purchase Orders', 'columns' => [{ 'id' => 'c3', 'name' => 'Qty', 'formula' => '[PO/Qty]' }],
    'metrics' => [{ 'id' => 'm3', 'name' => 'Units', 'formula' => 'Sum([Qty])' }, { 'id' => 'm4', 'name' => 'Qty', 'formula' => 'Sum([Qty])' }] }
] }] }
ren = PbiShapedModel.unique_metric_names!(syn)
el1, el2 = elements(syn)
check(ren == [{ 'from' => 'Units', 'to' => 'Units (measure)', 'element' => 'Inventory' }, { 'from' => 'Qty', 'to' => 'Qty (measure)', 'element' => 'Purchase Orders' }],
      "metric/column collisions are suffixed (#{ren.inspect})", fails)
check(el1['metrics'].map { |m| m['name'] } == ['Units (measure)', 'Open'], 'only the colliding metric is renamed', fails)
check(el2['metrics'].map { |m| m['name'] } == ['Units', 'Qty (measure)'], 'the same metric name on a different element is left alone', fails)
check(PbiShapedModel.unique_metric_names!(syn) == [], 'a second run changes nothing', fails)
sales_dm_names = split_setup
check(PbiShapedModel.unique_metric_names!(sales_dm_names[0]) == [], 'the sales fixture has no collisions', fails)

def run_apply_for_blank
  dm = sales_dm
  tm = sales_tmsl
  PbiShapedModel.apply!(dm, tmsl: tm, signals: load_json('sales', 'signals.json'), dialect: 'snowflake')
  metrics = elements(dm).flat_map { |e| e['metrics'] || [] }
  (metrics.find { |m| m['name'] == 'Gross Margin' } || {})['formula']
end

puts "\ntest_metric_to_metric_plus_minus_keeps_blank_as_zero_i1"
bm = { 'pages' => [{ 'id' => 'p', 'elements' => [
  { 'id' => 'e1', 'name' => 'Sales', 'columns' => [{ 'id' => 'c1', 'name' => 'Qty', 'formula' => '[T/Qty]' }],
    'metrics' => [{ 'id' => 'm1', 'name' => 'Sales Amount', 'formula' => 'Sum([Qty])' },
                  { 'id' => 'm2', 'name' => 'Cost', 'formula' => 'Sum([Qty] * 2)' },
                  { 'id' => 'm3', 'name' => 'Gross Margin', 'formula' => '[Metrics/Sales Amount] - [Metrics/Cost]' },
                  { 'id' => 'm4', 'name' => 'GM %', 'formula' => '([Metrics/Gross Margin]) / NullIf(([Metrics/Sales Amount]), 0)' },
                  { 'id' => 'm5', 'name' => 'Plus One', 'formula' => '[Metrics/Cost] + 1' },
                  { 'id' => 'm6', 'name' => 'Nested', 'formula' => '[Metrics/Sales Amount] - ([Metrics/Cost] + [Metrics/Plus One])' },
                  { 'id' => 'm7', 'name' => 'Neg', 'formula' => '-[Metrics/Cost] + [Metrics/Sales Amount]' }] }
] }] }
brec = PbiShapedModel.blank_arith_metrics!(bm)
bf = elements(bm)[0]['metrics'].map { |m| m['formula'] }
sa = '[Metrics/Sales Amount]'
co = '[Metrics/Cost]'
check(bf[0] == 'Sum([Qty])' && bf[1] == 'Sum([Qty] * 2)' && bf[3] == '([Metrics/Gross Margin]) / NullIf(([Metrics/Sales Amount]), 0)',
      'aggregates and division of refs are untouched', fails)
check(bf[2] == "If(IsNull(#{sa}) and IsNull(#{co}), Null, Coalesce(#{sa}, 0) - Coalesce(#{co}, 0))",
      "I1: [Sales Amount] - [Cost] reads each blank side as 0 and stays blank only when both are (#{bf[2]})", fails)
check(bf[4] == "Coalesce(#{co}, 0) + 1", "a literal term is never blank, so no all-blank guard (#{bf[4]})", fails)
check(bf[5] == "If(IsNull(#{sa}) and IsNull((If(IsNull(#{co}) and IsNull([Metrics/Plus One]), Null, Coalesce(#{co}, 0) + Coalesce([Metrics/Plus One], 0)))), Null, " \
               "Coalesce(#{sa}, 0) - Coalesce((If(IsNull(#{co}) and IsNull([Metrics/Plus One]), Null, Coalesce(#{co}, 0) + Coalesce([Metrics/Plus One], 0))), 0))",
      "a parenthesised group is rewritten, then coalesced as one term (#{bf[5]})", fails)
check(bf[6] == "If(IsNull(#{co}) and IsNull(#{sa}), Null, -Coalesce(#{co}, 0) + Coalesce(#{sa}, 0))", "a leading unary minus keeps its sign (#{bf[6]})", fails)
check(brec.map { |r| r['metric'] } == ['Gross Margin', 'Plus One', 'Nested', 'Neg'], "records the rewritten metrics (#{brec.map { |r| r['metric'] }.inspect})", fails)
check(PbiShapedModel.blank_arith_metrics!(bm) == [], 'a second run changes nothing', fails)
lg = run_apply_for_blank
check(lg == "If(IsNull(#{sa}) and IsNull(#{co}), Null, Coalesce(#{sa}, 0) - Coalesce(#{co}, 0))", "apply! ships the sales fixture's Gross Margin blank-as-0 (#{lg})", fails)

puts "\ntest_metric_to_metric_refs_are_qualified"
mm = { 'pages' => [{ 'id' => 'p', 'elements' => [
  { 'id' => 'e1', 'name' => 'Sales', 'columns' => [{ 'id' => 'c1', 'name' => 'Qty', 'formula' => '[T/Qty]' }],
    'metrics' => [{ 'id' => 'm1', 'name' => 'Sales Amount', 'formula' => 'Sum([Qty])' },
                  { 'id' => 'm2', 'name' => 'Cost', 'formula' => 'Sum([Qty] * 2)' },
                  { 'id' => 'm3', 'name' => 'Gross Margin', 'formula' => '[Sales Amount] - [Cost]' },
                  { 'id' => 'm4', 'name' => 'GM %', 'formula' => '([Gross Margin]) / NullIf(([Sales Amount]), 0)' },
                  { 'id' => 'm5', 'name' => 'Done', 'formula' => '[Metrics/Cost] + [Qty]' }] }
] }] }
qrec = PbiShapedModel.qualify_metric_refs!(mm)
mf = elements(mm)[0]['metrics'].map { |m| m['formula'] }
check(mf[0] == 'Sum([Qty])' && mf[1] == 'Sum([Qty] * 2)', 'plain aggregates are untouched', fails)
check(mf[2] == '[Metrics/Sales Amount] - [Metrics/Cost]', "metric refs are qualified (#{mf[2]})", fails)
check(mf[3] == '([Metrics/Gross Margin]) / NullIf(([Metrics/Sales Amount]), 0)', "nested composite (#{mf[3]})", fails)
check(mf[4] == '[Metrics/Cost] + [Qty]', 'already qualified refs and column refs are left alone', fails)
check(qrec.map { |r| r['metric'] } == ['Gross Margin', 'GM %'], "records the rewritten metrics (#{qrec.inspect})", fails)
check(PbiShapedModel.qualify_metric_refs!(mm) == [], 'a second run changes nothing', fails)
ci = { 'pages' => [{ 'id' => 'p', 'elements' => [
  { 'id' => 'e1', 'name' => 'Sales', 'columns' => [],
    'metrics' => [{ 'id' => 'm1', 'name' => 'Sales Amount', 'formula' => 'Sum([Qty])' },
                  { 'id' => 'm2', 'name' => 'Net', 'formula' => '[sales amount] - [SALES AMOUNT]' }] }] }] }
cirec = PbiShapedModel.qualify_metric_refs!(ci)
check(elements(ci)[0]['metrics'][1]['formula'] == '[Metrics/Sales Amount] - [Metrics/Sales Amount]' && cirec.length == 1,
      "m16: a metric ref in another case is qualified and keeps the metric's own spelling (#{elements(ci)[0]['metrics'][1]['formula']})", fails)

puts "\ntest_descriptions_present_on_sql_source_and_child"
dm5, tmsl5, _s5, classes5 = split_setup
PbiShapedModel.split_facts!(dm5, classes5)
sql_el = { 'id' => 'esql', 'kind' => 'table', 'name' => 'Region Targets',
           'source' => { 'kind' => 'sql', 'connectionId' => 'c', 'statement' => 'SELECT a FROM DB.SCH.TARGETS t JOIN "DB"."SCH"."REGIONS" r ON t.r = r.r' },
           'columns' => [] }
dm5['pages'][0]['elements'] << sql_el
native = { 'converted' => [{ 'table' => 'Region Targets' }], 'blockers' => [] }
d = PbiShapedModel.describe!(dm5, tmsl5, native)
check(sql_el['description'] == 'Power BI query for Region Targets; reads DB.SCH.TARGETS, DB.SCH.REGIONS', "Custom SQL: #{sql_el['description']}", fails)
check(element_named(dm5, 'Sales (source)')['description'] == 'Source of the Power BI table Sales; charts read Sales.', 'the base points at the child', fails)
cd = element_named(dm5, 'Sales')['description']
check(cd.include?('Lookup()') && cd.include?('List Price (Product)') && cd.include?('ProductKey (SKU)'), "child lists its lookups: #{cd}", fails)
check(element_named(dm5, 'Product')['description'].nil?, 'unrelated elements get no description', fails)
before_d = JSON.generate(dm5)
PbiShapedModel.describe!(dm5, tmsl5, native)
check(JSON.generate(dm5) == before_d, 'describe! is idempotent', fails)


puts "\ntest_build_b_metrics_from_the_real_converter_output"
dmb, tmslb, _sb, classesb, builtb = split_setup
sales_b = element_named(dmb, 'Sales')['metrics'].to_h { |m| [m['name'], m['formula']] }
check(builtb['built'].sort == ['Sales.List Value', 'Sales.Private Label Sales', 'Sales.Sales by Ship Date'], "built the three B measures (#{builtb['built'].inspect})", fails)
check(builtb['reclassified'].empty?, 'nothing is reclassified on the fixture', fails)
check(sales_b['List Value'] == 'Sum([Quantity] * [SKU/Product/List Price])', "(a) iterator: relationship-path form before the split (#{sales_b['List Value']})", fails)
check(sales_b['Private Label Sales'] == 'SumIf(Coalesce([Quantity], 0) * Coalesce([Unit Price], 0) * (1 - Coalesce([Discount], 0)), [SKU/Product/Private Label] = True)', "(b) CALCULATE filter: SumIf (#{sales_b['Private Label Sales']})", fails)
check(sales_b['Sales by Ship Date'] == sales_b['Sales Amount'], '(c) USERELATIONSHIP: the A measure formula unchanged', fails)
check(!sales_b['Sales by Ship Date'].nil? && classesb['Sales.Sales by Ship Date']['userel'] == 'Date (ShipDateKey)', 'the userel is kept in the class entry for chart time', fails)
check(PbiShapedModel.build_b_metrics!(dmb, tmslb, classesb)['built'].empty?, 'a second run builds nothing', fails)

puts "\ntest_untranslatable_b_measure_is_reclassified_d"
dmr, tmslr, _sr, classesr, _b = split_setup
model_r = tmslr['model'] || tmslr
model_r['tables'].find { |t| t['name'] == 'Sales' }['measures'] += [
  { 'name' => 'Distinct Private', 'expression' => 'CALCULATE(DISTINCTCOUNT(Sales[Order Number]), Product[Private Label] = TRUE())' },
  { 'name' => 'Blend', 'expression' => 'SUMX(Sales, Sales[Quantity] * IF(Sales[Discount] > 0, 1, 2) * RELATED(Product[List Price]))' },
  { 'name' => 'Dynamic', 'expression' => 'CALCULATE([Sales Amount], Product[Brand] = SELECTEDVALUE(Product[Brand]))' }
]
rel_entry = classesr['Sales.List Value']['related']
%w[Distinct\ Private Blend Dynamic].each do |nm|
  classesr["Sales.#{nm}"] = { 'class' => 'B', 'reason' => 'x', 'home' => 'Sales', 'userel' => nil, 'related' => rel_entry.map { |r| r.merge('column' => nm == 'Distinct Private' ? 'Private Label' : (nm == 'Dynamic' ? 'List Price' : 'List Price')) } }
end
rr = PbiShapedModel.build_b_metrics!(dmr, tmslr, classesr)
check(rr['reclassified'].map { |x| x['key'] }.sort == ['Sales.Blend', 'Sales.Distinct Private', 'Sales.Dynamic'], "three forms outside the narrow set (#{rr['reclassified'].map { |x| x['key'] }.inspect})", fails)
check(rr['reclassified'].all? { |x| x['reason'].start_with?('B form not translatable:') } && classesr['Sales.Blend']['class'] == 'D' && classesr['Sales.Blend']['reason'].start_with?('B form not translatable:'),
      "class set to D with the reason (#{classesr['Sales.Blend']['reason']})", fails)
check(element_named(dmr, 'Sales')['metrics'].none? { |m| %w[Blend Dynamic Distinct\ Private].include?(m['name']) }, 'no metric is written for them', fails)
check(classesr['Sales.List Value']['class'] == 'B', 'translatable measures keep class B', fails)

puts "\ntest_unresolved_related_read_removes_metric_and_blocks_split"
dmu, _tu, _su, classesu, _bu = split_setup
broken = Marshal.load(Marshal.dump(classesu))
broken['Sales.Private Label Sales']['related'][0]['path'] = %w[SKU Nope]
ru = PbiShapedModel.split_facts!(dmu, broken)
childu = element_named(dmu, 'Sales')
check(ru.length == 1 && ru.reclassified.map { |x| x['key'] } == ['Sales.Private Label Sales'], "reclassified returned (#{ru.reclassified.inspect})", fails)
check(broken['Sales.Private Label Sales']['class'] == 'D' && broken['Sales.Private Label Sales']['reason'] =~ /did not resolve/, 'class set to D with a reason', fails)
check(childu['metrics'].none? { |m| m['name'] == 'Private Label Sales' } && childu['metrics'].any? { |m| m['name'] == 'List Value' }, 'the failed metric is removed, the good one stays', fails)
check(ru[0]['reclassified'].length == 1, 'the fact entry lists it too', fails)
dmn, _tn, _sn, classesn, _bn = split_setup
nope = Marshal.load(Marshal.dump(classesn))
nope.each_value { |c| c['related'].each { |r| r['path'] = %w[Nope] } if c['class'] == 'B' }
rn = PbiShapedModel.split_facts!(dmn, nope)
check(rn.empty? && !element_named(dmn, 'Sales (source)') && elements(dmn).count { |e| e['name'] == 'Sales' } == 1, 'no Lookup resolves: the fact is not split', fails)
check(rn.reclassified.length == 2 && element_named(dmn, 'Sales')['metrics'].none? { |m| %w[List\ Value Private\ Label\ Sales].include?(m['name']) }, 'both related metrics reclassified and removed', fails)
check(element_named(dmn, 'Sales')['metrics'].any? { |m| m['name'] == 'Sales Amount' } && !element_named(dmn, 'Sales').key?('filters'), 'the unsplit element keeps its other metrics', fails)

puts "\ntest_empty_exclude_filter_is_a_no_op"
dme, _te, _se, classese, _be = split_setup
PbiShapedModel.split_facts!(dme, classese)
fe = PbiShapedModel.report_filters!(dme, { 'filters' => [{ 'scope' => 'report', 'target' => 'Category.Category Name', 'type' => 'list', 'mode' => 'exclude', 'values' => [] }] }, classese)
check(fe['applied'].empty? && fe['skipped'].length == 1 && fe['skipped'][0]['reason'] =~ /no-op/, "recorded as skipped (#{fe['skipped'].inspect})", fails)
check(elements(dme).none? { |e| e.key?('filters') } && element_named(dme, 'Sales')['columns'].none? { |c| c['name'].to_s.start_with?('Keep') }, 'no filter and no helper column', fails)

puts "\ntest_page_filters_skipped_and_unreachable_separate"
dmp, _tp, _sp, classesp, _bp = split_setup
PbiShapedModel.split_facts!(dmp, classesp)
fp = PbiShapedModel.report_filters!(dmp, { 'filters' => [
  { 'scope' => 'page', 'target' => 'Product.Brand', 'type' => 'list', 'mode' => 'include', 'values' => ['X'] },
  { 'scope' => 'report', 'target' => 'Store.Channel', 'type' => 'list', 'mode' => 'include', 'values' => ['Web'] }] }, classesp)
check(fp['skipped'] == [{ 'filter' => 'Product.Brand include ["X"]', 'reason' => 'page filter: handled by the workbook builder' }], "page filter recorded in skipped (#{fp['skipped'].inspect})", fails)
check(fp['not_reachable'].empty? && fp['applied'].any? { |a| a['element'] == 'Sales' }, 'a reachable filter is applied', fails)
dmq = { 'pages' => [{ 'elements' => [
  { 'id' => 'f1', 'name' => 'Facts', 'columns' => [{ 'id' => 'f1c', 'name' => 'Qty', 'formula' => '[F/Qty]' }], 'metrics' => [{ 'id' => 'f1m', 'name' => 'Q', 'formula' => 'Sum([Qty])' }] },
  { 'id' => 'd1', 'name' => 'Island', 'columns' => [{ 'id' => 'd1c', 'name' => 'Name', 'formula' => '[I/Name]' }] }] }] }
fq = PbiShapedModel.report_filters!(dmq, { 'filters' => [{ 'scope' => 'report', 'target' => 'Island.Name', 'type' => 'list', 'mode' => 'include', 'values' => ['a'] },
                                                         { 'scope' => 'report', 'target' => 'Island.Name', 'type' => 'list', 'mode' => 'include', 'values' => ['a'] }] }, {})
check(fq['not_reachable'].map { |x| x['element'] } == %w[Facts Facts] && fq['skipped'].empty? && fq['applied'].length == 2, "unreachable elements go under not_reachable (#{fq.inspect})", fails)

puts "\ntest_composite_key_lookup_chain_returns_a_reason"
dmc = { 'pages' => [{ 'elements' => [
  { 'id' => 'f', 'name' => 'Facts', 'columns' => [{ 'id' => 'f1', 'name' => 'A', 'formula' => '[F/A]' }, { 'id' => 'f2', 'name' => 'B', 'formula' => '[F/B]' }],
    'relationships' => [{ 'id' => 'r', 'name' => 'Dim', 'targetElementId' => 'd', 'keys' => [{ 'sourceColumnId' => 'f1', 'targetColumnId' => 'd1' }, { 'sourceColumnId' => 'f2', 'targetColumnId' => 'd2' }] }] },
  { 'id' => 'd', 'name' => 'Dim', 'columns' => [{ 'id' => 'd1', 'name' => 'A', 'formula' => '[D/A]' }, { 'id' => 'd2', 'name' => 'B', 'formula' => '[D/B]' }, { 'id' => 'd3', 'name' => 'Label', 'formula' => '[D/Label]' }] }] }] }
cn, cr = nil
begin
  cn, cr = PbiShapedModel.lookup_chain!(dmc, elements(dmc)[0], ['Dim'], 'Label')
  check(cn.nil? && cr =~ /composite key/, "returns [nil, reason] (#{cr})", fails)
rescue StandardError => e
  check(false, "must not raise (#{e.class}: #{e.message})", fails)
end
check(elements(dmc)[0]['columns'].length == 2, 'no column is added on failure', fails)


puts "\ntest_form_b_filter_semantics_match_dax"
dmf, _tf, _sf, _cf, _bf = split_setup
elf = element_named(dmf, 'Sales')
by_id_f = PbiShapedModel.by_id_map(dmf)
row = 'Coalesce([Quantity], 0) * Coalesce([Unit Price], 0) * (1 - Coalesce([Discount], 0))'
brand = [{ 'table' => 'Product', 'column' => 'Brand', 'path' => %w[SKU Product] },
         { 'table' => 'Product', 'column' => 'Private Label', 'path' => %w[SKU Product] }]
tr = lambda do |dax|
  PbiShapedModel.translate_b_metric(dax, elf, 'Sales', by_id_f, brand)['formula']
rescue PbiShapedModel::NotTranslatable => e
  "NOT: #{e.message}"
end
b = '[SKU/Product/Brand]'
pl = '[SKU/Product/Private Label]'
{
  'CALCULATE([Sales Amount], Product[Brand] <> "Acme")' => "SumIf(#{row}, (IsNull(#{b}) or Lower(#{b}) != Lower(\"Acme\")))",
  'CALCULATE([Sales Amount], Product[Private Label] <> TRUE())' => "SumIf(#{row}, (IsNull(#{pl}) or #{pl} != True))",
  'CALCULATE([Sales Amount], Product[Private Label] <> FALSE())' => "SumIf(#{row}, #{pl} != False)",
  'CALCULATE([Sales Amount], Sales[Discount] <> 0)' => "SumIf(#{row}, [Discount] != 0)",
  'CALCULATE([Sales Amount], Product[Brand] <> "")' => "SumIf(#{row}, #{b} != \"\")",
  'CALCULATE([Sales Amount], Sales[Discount] = 0)' => "SumIf(#{row}, (IsNull([Discount]) or [Discount] = 0))",
  'CALCULATE([Sales Amount], Product[Brand] = "")' => "SumIf(#{row}, (IsNull(#{b}) or #{b} = \"\"))",
  'CALCULATE([Sales Amount], Product[Private Label] = FALSE())' => "SumIf(#{row}, (IsNull(#{pl}) or #{pl} = False))",
  'CALCULATE([Sales Amount], Product[Private Label] = TRUE())' => "SumIf(#{row}, #{pl} = True)",
  'CALCULATE([Sales Amount], Sales[Discount] = 5)' => "SumIf(#{row}, [Discount] = 5)",
  'CALCULATE([Sales Amount], Product[Brand] = "Acme")' => "SumIf(#{row}, Lower(#{b}) = Lower(\"Acme\"))",
  'CALCULATE([Sales Amount], Product[Brand] IN {"Acme", "Beta"})' => "SumIf(#{row}, In(Lower(#{b}), \"acme\", \"beta\"))",
  'CALCULATE([Sales Amount], Product[Brand] = "Acme", Product[Private Label] = TRUE())' => "SumIf(#{row}, Lower(#{b}) = Lower(\"Acme\") and #{pl} = True)",
  'CALCULATE(COUNT(Sales[Order Number]), Product[Private Label] = TRUE())' => "CountIf(#{pl} = True and Not(IsNull([Order Number])))",
  'CALCULATE(COUNTROWS(Sales), Product[Private Label] = TRUE())' => "CountIf(#{pl} = True)",
  'CALCULATE([Sales Amount], Product[Brand] = "a""b")' => 'SumIf(' + row + ', Lower(' + b + ') = Lower("a\\"b"))',
  'CALCULATE([Sales Amount], Product[Brand] = "a\\b")' => 'SumIf(' + row + ', Lower(' + b + ') = Lower("a\\\\b"))'
}.each do |dax, want|
  got = tr.call(dax)
  check(got == want, "#{dax} -> #{got}", fails)
end
check(tr.call('CALCULATE([Sales Amount], Product[Brand] = SELECTEDVALUE(Product[Brand]))').start_with?('NOT:'), 'a non-literal filter stays untranslatable', fails)

puts "\ntest_form_b_metric_description_names_the_override"
dmd, = split_setup
plm = element_named(dmd, 'Sales')['metrics'].find { |m| m['name'] == 'Private Label Sales' }
check(plm['description'] == "Power BI's CALCULATE filter on Private Label overrides slicers on that column; in Sigma a slicer on Private Label still applies.", "form (b) description (#{plm['description']})", fails)
check(element_named(dmd, 'Sales')['metrics'].find { |m| m['name'] == 'List Value' }['description'].nil?, 'form (a) has no such line', fails)
check(element_named(dmd, 'Sales')['metrics'].find { |m| m['name'] == 'Sales by Ship Date' }['description'].nil?, 'form (c) has no such line', fails)

# ---- Task 17: flattened child, recommendations, materialization targets ----
def flat_setup(fixture = 'sales', flatten: [])
  dm = load_json(fixture, 'dm-raw.json')
  tmsl = load_json(fixture, 'model.bim')
  sig = load_json(fixture, 'signals.json')
  log = PbiShapedModel.apply!(dm, tmsl: tmsl, signals: sig, flatten: flatten)
  [dm, tmsl, sig, log]
end

puts "\ntest_flatten_refuses_join_free_fact"
dmj, _t, sigj, = flat_setup
before = JSON.generate(dmj)
res = PbiShapedModel.flatten!(dmj, 'Customer', sigj)
check(res['element'].nil? && res['reason'].to_s.include?('join-free'), "a fact whose visuals read no related fields is refused (#{res['reason']})", fails)
check(JSON.generate(dmj) == before, 'a refusal leaves the model untouched', fails)
begin
  PbiShapedModel.flatten!(dmj, 'Nope', sigj)
  check(false, 'an unknown fact raises', fails)
rescue ArgumentError
  check(true, 'an unknown fact raises', fails)
end
begin
  flat_setup('sales', flatten: ['Nope'])
  check(false, 'apply! raises on an unknown flatten name', fails)
rescue ArgumentError
  check(true, 'apply! raises on an unknown flatten name', fails)
end

puts "\ntest_flattened_child_is_the_p11_form"
dmf, _t, _s, logf = flat_setup('sales', flatten: ['Sales', 'Customer'])
flat = element_named(dmf, 'Sales (flattened)')
base = element_named(dmf, 'Sales (source)')
check(flat && flat['source'] == { 'kind' => 'table', 'elementId' => base['id'] }, 'Sales (flattened) is a child of Sales (source)', fails)
check(!flat.key?('relationships'), 'and has no relationships', fails)
f = flat['columns'].map { |c| c['formula'] }
check(f.include?('Lookup([Store/Store Region], [StoreKey], [Store/StoreKey])'), 'Store Region is a Lookup on the local key (P11 form)', fails)
check(f.include?('Lookup([SKU/ProductKey], [SkuKey], [SKU/SkuKey])') &&
      f.include?('Lookup([Product/Brand], [ProductKey (SKU)], [Product/ProductKey])'), 'a Product column chains through the SKU key', fails)
check(f.include?('Lookup([Category/Category Name], [CategoryKey (Product)], [Category/CategoryKey])'), 'a three-hop column chains hop by hop', fails)
check(base['columns'].all? { |bc| flat['columns'].any? { |c| c['formula'] == "[Sales (source)/#{PbiShapedModel.display_name(bc)}]" } }, 'every column of the fact is carried', fails)
check(flat['metrics'].map { |m| m['name'] } == element_named(dmf, 'Sales')['metrics'].map { |m| m['name'] }, "the fact's metrics are copied", fails)
check(flat['filters'].to_a.length == element_named(dmf, 'Sales')['filters'].to_a.length && flat['filters'].all? { |x| flat['columns'].any? { |c| c['id'] == x['columnId'] } },
      "the report filters follow on the flattened element's own columns", fails)
ids = elements(dmf).flat_map { |e| [e['id']] + (e['columns'] || []).map { |c| c['id'] } }
check(ids.length == ids.uniq.length, 'all ids stay unique', fails)
check(logf['flattened'].map { |r| [r['fact'], r['element']] } == [['Sales', 'Sales (flattened)'], ['Customer', nil]], 'apply! logs the flattened child and the refusal', fails)
check(PbiShapedModel.materialize_targets(dmf, logf) == ['Sales (flattened)'], 'the flattened child is a materialization target', fails)
lit_dm = { 'pages' => [{ 'elements' => [
  { 'name' => 'Cover Bucket', 'source' => { 'kind' => 'sql', 'statement' => "SELECT 'From a day' AS \"Bucket\", 0 AS \"Min Days\" UNION ALL SELECT '7 to 14 days', 7" } },
  { 'name' => 'Rolling', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT d.x FROM "DB"."S"."T" d' } },
  { 'name' => 'Quoted', 'source' => { 'kind' => 'sql', 'statement' => "SELECT 'a from b' AS \"x\"" } }
] }] }
check(PbiShapedModel.materialize_targets(lit_dm) == ['Rolling'],
      'a Custom SQL element made only of literal rows (no base table; Snowflake refuses a dynamic table over it) is not a materialization target', fails)
check(PbiShapedModel.literal_sql?("-- don't touch\nSELECT a FROM t WHERE x = 'y'") == false,
      'an apostrophe in a -- comment does not hide the FROM (not literal rows)', fails)
check(PbiShapedModel.literal_sql?("SELECT 1 /* it's */ AS a FROM t WHERE n = 'x'") == false,
      'an apostrophe in a /* */ comment does not hide the FROM (not literal rows)', fails)
check(PbiShapedModel.literal_sql?("SELECT 'a' AS x UNION ALL SELECT 'b'") == true,
      'a pure literal-rows statement is literal rows', fails)
check(PbiShapedModel.literal_sql?("-- comment from here\nSELECT 'a' AS x UNION ALL SELECT 'b'") == false,
      'a comment containing FROM makes the statement not literal rows (conservative)', fails)

puts "\ntest_flattened_child_folders_named_after_pbi_tables"
folders = flat['folders']
check(folders.map { |x| x['name'] }.sort == %w[Category Customer Date Product SKU Store], "folders are named after the Power BI tables (#{folders.map { |x| x['name'] }.inspect})", fails)
check(folders.all? { |x| x['id'] && x['items'].all? { |i| flat['columns'].any? { |c| c['id'] == i } } }, 'every folder item is a column id', fails)
store = folders.find { |x| x['name'] == 'Store' }
check(store['items'].map { |i| flat['columns'].find { |c| c['id'] == i }['name'] }.sort == ['Channel (Store)', 'Store Region (Store)'], 'the Store folder holds the Store lookups', fails)
check(flat['order'].last(folders.length) == folders.map { |x| x['id'] }, 'folder ids are at the end of order', fails)

puts "\ntest_slicer_only_fields_are_chained"
slicer_cols = flat['columns'].map { |c| c['name'] }
check(slicer_cols.include?('Brand (Product)') && flat['columns'].any? { |c| c['formula'].to_s.include?('[Customer/Segment]') } &&
      flat['columns'].any? { |c| c['formula'].to_s.include?('[Customer/Loyalty Member]') },
      'fields only a slicer binds (Customer.Segment, Customer.Loyalty Member) get Lookup columns', fails)
check(folders.map { |x| x['name'] }.include?('Customer'), 'and a Customer folder', fails)
flat_log = logf['flattened'].find { |r| r['fact'] == 'Sales' }
check(Array(flat_log['unresolved']).empty?, 'nothing is left unresolved on the fixture', fails)
puts "\ntest_no_gain_from_preexisting_lookups_is_refused"
dmg, _t, sigg, = flat_setup('sales', flatten: ['Sales'])
check(PbiShapedModel.flatten!(dmg, 'Sales', sigg)['reason'] == 'already flattened', 'a second flatten is a no-op', fails)

puts "\ntest_recommendation_needs_two_relationships"
dmr, _t, sigr, = flat_setup
recs = PbiShapedModel.flatten_recommendations(dmr, sigr)
check(recs.map { |r| r['fact'] } == ['Sales'] && recs[0]['relationships_read'].length >= 2, "Sales reads through several relationships (#{recs.inspect})", fails)
one = JSON.parse(JSON.generate(sigr))
one['filters'] = []
one['pages'].each { |pg| pg['visuals'].each { |v| (v['bindings'] || {}).each { |k, refs| v['bindings'][k] = refs.reject { |r| r.start_with?('Date.', 'Category.', 'Product.', 'SKU.', 'Customer.') } } } }
recs1 = PbiShapedModel.flatten_recommendations(dmr, one)
check(recs1.empty?, "a fact read through one relationship (Store) is not recommended (#{recs1.inspect})", fails)
inv_dm, _t, inv_sig, = flat_setup('inventory')
check(PbiShapedModel.flatten_recommendations(inv_dm, inv_sig).is_a?(Array), 'Inventory yields a list', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILED:"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
