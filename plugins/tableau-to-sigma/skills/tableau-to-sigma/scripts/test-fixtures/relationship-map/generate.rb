#!/usr/bin/env ruby
# frozen_string_literal: true
#
# generate.rb — writes the relationship-map fixture cases (invented names, no
# customer data). Each case directory gets the three inputs the reused-DM
# relationship route reads from a workdir:
#   workbook-content.twb  — object-graph datasources, worksheets, dashboards
#   dm-spec-reused.json   — the customer-built data model as GET /spec returns it
#   dashboard-scope.json  — migrated dashboards ({"mode": "full"} unless narrowed)
# The Ruby and Python suites both read these committed files, so regenerate
# (ruby scripts/test-fixtures/relationship-map/generate.rb) and commit after
# editing a case here; never hand-edit the outputs.

require 'json'
require 'fileutils'

HERE = File.expand_path(__dir__)

# A datasource: tables => { NAME => [cols] }, rels => [[t1, c1, t2, c2], ...],
# calcs => { 'Caption' => formula over local names }, db/schema for FQNs
# (db: nil drops dbname from the named-connection: short-name identity).
# alias_of => { ALIAS => TABLE } makes ALIAS a second object over TABLE's
# physical table (a Tableau self-join / role-played copy).
def twb(datasources:, worksheets:, dashboards:)
  ds_xml = datasources.map.with_index { |ds, i| datasource_xml(ds, i) }.join
  ws_xml = worksheets.map do |name, uses|
    deps = uses.group_by { |u| u[0] }.map do |ds_name, cols|
      body = cols.map { |(_, col)| "              <column name='[#{col}]' />\n" }.join
      "            <datasource-dependencies datasource='#{ds_name}'>\n#{body}            </datasource-dependencies>\n"
    end.join
    srcs = uses.map(&:first).uniq.map { |n| "              <datasource name='#{n}' />\n" }.join
    "    <worksheet name='#{name}'>\n      <table>\n        <view>\n          <datasources>\n#{srcs}          </datasources>\n#{deps}        </view>\n      </table>\n    </worksheet>\n"
  end.join
  db_xml = dashboards.map do |name, sheets|
    zones = sheets.map.with_index { |s, i| "          <zone id='#{i + 2}' name='#{s}' />\n" }.join
    "    <dashboard name='#{name}'>\n      <zones>\n        <zone id='1'>\n#{zones}        </zone>\n      </zones>\n    </dashboard>\n"
  end.join
  "<?xml version='1.0' encoding='utf-8' ?>\n<workbook source-build='2023.1.0' version='18.1'>\n" \
    "  <datasources>\n#{ds_xml}  </datasources>\n  <worksheets>\n#{ws_xml}  </worksheets>\n" \
    "  <dashboards>\n#{db_xml}  </dashboards>\n</workbook>\n"
end

# Tableau suffixes a column local name that repeats across tables with the
# owning table: [CUSTOMER_KEY] then [CUSTOMER_KEY (DIM_CUSTOMER)].
def local_names(tables)
  seen = {}
  tables.each_with_object({}) do |(t, cols), out|
    cols.each do |c|
      out[[t, c]] = seen[c] ? "#{c} (#{t})" : c
      seen[c] = true
    end
  end
end

def datasource_xml(ds, idx)
  conn = "conn.#{idx}"
  db_attr = ds[:db] ? " dbname='#{ds[:db]}'" : ''
  names = local_names(ds[:tables])
  relation = lambda do |t, ind|
    if ds[:sql] && ds[:sql][t]
      "#{ind}<relation connection='#{conn}' name='#{t}' type='text'>#{ds[:sql][t]}</relation>\n"
    else
      physical = (ds[:alias_of] || {})[t] || t
      table = ds[:schema] ? "[#{ds[:schema]}].[#{physical}]" : "[#{physical}]"
      "#{ind}<relation connection='#{conn}' name='#{t}' table='#{table}' type='table' />\n"
    end
  end
  records = ds[:tables].flat_map do |t, cols|
    cols.map do |c|
      oid = ds[:no_object_id] ? '' : "            <object-id>[#{t}_OBJ]</object-id>\n"
      "          <metadata-record class='column'>\n            <remote-name>#{c}</remote-name>\n" \
        "            <local-name>[#{names[[t, c]]}]</local-name>\n            <parent-name>[#{t}]</parent-name>\n" \
        "#{oid}          </metadata-record>\n"
    end
  end.join
  calcs = (ds[:calcs] || {}).map.with_index do |(cap, formula), i|
    "      <column caption='#{cap}' datatype='real' name='[Calculation_#{idx}#{i}]' role='measure' type='quantitative'>\n" \
      "        <calculation class='tableau' formula='#{formula}' />\n      </column>\n"
  end.join
  calcs += (ds[:groups] || {}).map.with_index do |(cap, field), i|
    "      <column caption='#{cap}' datatype='string' name='[Group_#{idx}#{i}]' role='dimension' type='nominal'>\n" \
      "        <calculation class='categorical-bin' column='[#{field}]' new-bin='true' />\n      </column>\n"
  end.join
  objects = ds[:tables].keys.map do |t|
    "          <object caption='#{t}' id='#{t}_OBJ'>\n            <properties context=''>\n" \
      "#{relation.call(t, '              ')}            </properties>\n          </object>\n"
  end.join
  # A 5th element adds a computed second condition, ANDed like Tableau does:
  # { expr: "DATETRUNC(&apos;month&apos;,[COL])", col: 'TARGET_COL' }.
  rels = ds[:rels].map do |(t1, c1, t2, c2, computed)|
    eq = "<expression op='='><expression op='[#{names[[t1, c1]]}]' /><expression op='[#{names[[t2, c2]]}]' /></expression>"
    if computed
      second = "<expression op='='><expression op='#{computed[:expr]}' /><expression op='[#{names[[t2, computed[:col]]]}]' /></expression>"
      eq = "<expression op='AND'>#{eq}#{second}</expression>"
    end
    "          <relationship>\n            #{eq}\n            <first-end-point object-id='#{t1}_OBJ' />\n" \
      "            <second-end-point object-id='#{t2}_OBJ' />\n          </relationship>\n"
  end.join
  "    <datasource caption='#{ds[:caption]}' inline='true' name='#{ds[:name]}' version='18.1'>\n" \
    "      <connection class='federated'>\n        <named-connections>\n" \
    "          <named-connection caption='#{ds[:conn_class] || 'snowflake'}' name='#{conn}'>\n" \
    "            <connection class='#{ds[:conn_class] || 'snowflake'}'#{db_attr}#{ds[:schema] ? " schema='#{ds[:schema]}'" : ''} server='example.snowflakecomputing.com' />\n" \
    "          </named-connection>\n        </named-connections>\n        <relation type='collection'>\n" \
    "#{ds[:tables].keys.map { |t| relation.call(t, '          ') }.join}        </relation>\n" \
    "        <metadata-records>\n#{records}        </metadata-records>\n      </connection>\n#{calcs}" \
    "      <object-graph>\n        <objects>\n#{objects}        </objects>\n" \
    "        <relationships>\n#{rels}        </relationships>\n      </object-graph>\n    </datasource>\n"
end

# DM elements: id => { path: [DB, SCHEMA, T] | sql: statement, cols: [...] };
# rels => [[src_id, src_col, tgt_id, tgt_col], ...].
def dm(elements:, rels:)
  els = elements.map do |id, e|
    label = e[:path] ? e[:path].last : id.upcase
    source = e[:path] ? { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1', 'path' => e[:path] }
                      : { 'kind' => 'sql', 'connectionId' => 'conn-1', 'statement' => e[:sql] }
    cols = e[:cols].map { |c| { 'id' => "#{id}-#{c.downcase}", 'formula' => "[#{label}/#{c}]" } }
    out = { 'id' => id, 'kind' => 'table', 'source' => source, 'columns' => cols }
    out['name'] = e[:name] if e[:name]
    mine = rels.select { |r| r[0] == id }
    unless mine.empty?
      out['relationships'] = mine.map.with_index do |(s, sc, t, tc), i|
        { 'id' => "rel-#{s}-#{i}", 'targetElementId' => t,
          'keys' => [{ 'sourceColumnId' => "#{s}-#{sc.downcase}", 'targetColumnId' => "#{t}-#{tc.downcase}" }] }
      end
    end
    out
  end
  { 'name' => 'Customer Model', 'schemaVersion' => 1,
    'pages' => [{ 'id' => 'page-1', 'name' => 'Page 1', 'elements' => els }] }
end

STAR = {
  caption: 'Sales', name: 'federated.sales', db: 'ANALYTICS', schema: 'PUBLIC',
  tables: { 'ORDERS' => %w[ORDER_ID CUSTOMER_KEY PRODUCT_KEY AMOUNT],
            'DIM_CUSTOMER' => %w[CUSTOMER_KEY CUSTOMER_NAME],
            'DIM_PRODUCT' => %w[PRODUCT_KEY PRODUCT_NAME] },
  rels: [%w[ORDERS CUSTOMER_KEY DIM_CUSTOMER CUSTOMER_KEY], %w[ORDERS PRODUCT_KEY DIM_PRODUCT PRODUCT_KEY]]
}.freeze
P = ->(t) { ['ANALYTICS', 'PUBLIC', t] }
STAR_ELS = {
  'orders' => { path: P.('ORDERS'), cols: %w[ORDER_ID CUSTOMER_KEY PRODUCT_KEY AMOUNT] },
  'cust' => { path: P.('DIM_CUSTOMER'), cols: %w[CUSTOMER_KEY CUSTOMER_NAME] },
  'prod' => { path: P.('DIM_PRODUCT'), cols: %w[PRODUCT_KEY PRODUCT_NAME] }
}.freeze
S = 'federated.sales'
REVENUE = { 'Revenue by Customer' => [[S, 'CUSTOMER_NAME'], [S, 'AMOUNT']],
            'Revenue by Product' => [[S, 'PRODUCT_NAME'], [S, 'AMOUNT']] }.freeze
OVERVIEW = { 'Overview' => REVENUE.keys }.freeze
E = 'federated.people'
EMPLOYEES = {
  caption: 'People', name: E, db: 'ANALYTICS', schema: 'PUBLIC',
  tables: { 'EMPLOYEES' => %w[EMP_ID EMP_NAME MANAGER_ID], 'MANAGER' => %w[EMP_ID EMP_NAME MANAGER_ID] },
  alias_of: { 'MANAGER' => 'EMPLOYEES' },
  rels: [%w[EMPLOYEES MANAGER_ID MANAGER EMP_ID]]
}.freeze

CASES = {
  'matched-star' => {
    twb: twb(datasources: [STAR], worksheets: REVENUE, dashboards: OVERVIEW),
    dm: dm(elements: STAR_ELS, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY], %w[orders PRODUCT_KEY prod PRODUCT_KEY]])
  },
  'replaced-key' => {
    twb: twb(datasources: [STAR], worksheets: REVENUE, dashboards: OVERVIEW),
    dm: dm(elements: STAR_ELS.merge('cust' => { path: P.('DIM_CUSTOMER'), cols: %w[CUSTOMER_KEY CUSTOMER_NAME CUSTOMER_ALT_KEY] }),
           rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_ALT_KEY], %w[orders PRODUCT_KEY prod PRODUCT_KEY]])
  },
  'dropped-unused' => {
    twb: twb(datasources: [STAR], worksheets: { 'Revenue by Customer' => REVENUE['Revenue by Customer'] },
             dashboards: { 'Overview' => ['Revenue by Customer'] }),
    dm: dm(elements: STAR_ELS.reject { |k, _| k == 'prod' }, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  'dropped-used-by-calc' => {
    twb: twb(datasources: [STAR.merge(calcs: { 'Named Revenue' => 'IF [PRODUCT_NAME] = "" THEN 0 ELSE [AMOUNT] END' })],
             worksheets: { 'Revenue by Customer' => [[S, 'CUSTOMER_NAME'], [S, 'Calculation_00']] },
             dashboards: { 'Overview' => ['Revenue by Customer'] }),
    dm: dm(elements: STAR_ELS.reject { |k, _| k == 'prod' }, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  # Review I3: field use must see through groups (categorical-bin column=),
  # metadata-records without object-id (parent-name fallback), and fail
  # closed on a field it cannot resolve. Parameters / :Measure Names are not
  # table fields.
  'dropped-used-by-group' => {
    twb: twb(datasources: [STAR.merge(groups: { 'Product Group' => 'PRODUCT_NAME' })],
             worksheets: { 'Revenue by Customer' => [[S, 'CUSTOMER_NAME'], [S, 'Group_00']] },
             dashboards: { 'Overview' => ['Revenue by Customer'] }),
    dm: dm(elements: STAR_ELS.reject { |k, _| k == 'prod' }, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  'dropped-no-object-id' => {
    twb: twb(datasources: [STAR.merge(no_object_id: true)],
             worksheets: { 'Revenue by Product' => REVENUE['Revenue by Product'] },
             dashboards: { 'Overview' => ['Revenue by Product'] }),
    dm: dm(elements: STAR_ELS.reject { |k, _| k == 'prod' }, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  'dropped-unresolved-field' => {
    twb: twb(datasources: [STAR],
             worksheets: { 'Revenue by Customer' => [[S, 'CUSTOMER_NAME'], [S, 'MYSTERY_FIELD']] },
             dashboards: { 'Overview' => ['Revenue by Customer'] }),
    dm: dm(elements: STAR_ELS.reject { |k, _| k == 'prod' }, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  'dropped-unused-with-pseudo-fields' => {
    twb: twb(datasources: [STAR],
             worksheets: { 'Revenue by Customer' => [[S, 'CUSTOMER_NAME'], [S, ':Measure Names'],
                                                     ['Parameters', 'Parameter 1']] },
             dashboards: { 'Overview' => ['Revenue by Customer'] }),
    dm: dm(elements: STAR_ELS.reject { |k, _| k == 'prod' }, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  # A Tableau relationship with a computed condition the model does not carry
  # is never 'matched': the model's single-key join is wider than Tableau's.
  'computed-condition' => {
    twb: twb(datasources: [STAR.merge(
      tables: STAR[:tables].merge('ORDERS' => STAR[:tables]['ORDERS'] + ['ORDER_TS'],
                                  'DIM_PRODUCT' => STAR[:tables]['DIM_PRODUCT'] + ['EFFECTIVE_MONTH']),
      rels: [STAR[:rels][0],
             STAR[:rels][1] + [{ expr: 'DATETRUNC(&apos;month&apos;,[ORDER_TS])', col: 'EFFECTIVE_MONTH' }]]
    )], worksheets: REVENUE, dashboards: OVERVIEW),
    dm: dm(elements: STAR_ELS, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY], %w[orders PRODUCT_KEY prod PRODUCT_KEY]])
  },
  'dropped-bridge' => {
    twb: twb(datasources: [{
               caption: 'Chain', name: 'federated.chain', db: 'ANALYTICS', schema: 'PUBLIC',
               tables: { 'SHIPMENTS' => %w[SHIPMENT_ID ORDER_ID WEIGHT], 'ORDERS' => %w[ORDER_ID REGION_KEY],
                         'REGIONS' => %w[REGION_KEY REGION_NAME] },
               rels: [%w[SHIPMENTS ORDER_ID ORDERS ORDER_ID], %w[ORDERS REGION_KEY REGIONS REGION_KEY]]
             }],
             worksheets: { 'Weight by Region' => [['federated.chain', 'REGION_NAME'], ['federated.chain', 'WEIGHT']] },
             dashboards: { 'Logistics' => ['Weight by Region'] }),
    dm: dm(elements: { 'ship' => { path: P.('SHIPMENTS'), cols: %w[SHIPMENT_ID ORDER_ID WEIGHT REGION_KEY] },
                       'reg' => { path: P.('REGIONS'), cols: %w[REGION_KEY REGION_NAME] } },
           rels: [%w[ship REGION_KEY reg REGION_KEY]])
  },
  'disconnected-mixed' => {
    twb: twb(datasources: [STAR], worksheets: REVENUE, dashboards: OVERVIEW),
    dm: dm(elements: STAR_ELS, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  'extra-edge' => {
    twb: twb(datasources: [STAR], worksheets: REVENUE, dashboards: OVERVIEW),
    dm: dm(elements: STAR_ELS.merge('prod' => { path: P.('DIM_PRODUCT'), cols: %w[PRODUCT_KEY PRODUCT_NAME CUSTOMER_KEY] }),
           rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY], %w[orders PRODUCT_KEY prod PRODUCT_KEY],
                  %w[prod CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  'two-schemas-same-name' => {
    twb: twb(datasources: [
               { caption: 'Sales', name: 'federated.s', db: 'SALES', schema: 'PUBLIC',
                 tables: { 'ORDERS' => %w[ORDER_ID DATE_KEY], 'DATE_DIM' => %w[DATE_KEY CAL_DATE] },
                 rels: [%w[ORDERS DATE_KEY DATE_DIM DATE_KEY]] },
               { caption: 'HR', name: 'federated.h', db: 'HR', schema: 'PUBLIC',
                 tables: { 'HIRES' => %w[HIRE_ID DATE_KEY], 'DATE_DIM' => %w[DATE_KEY CAL_DATE] },
                 rels: [%w[HIRES DATE_KEY DATE_DIM DATE_KEY]] }
             ],
             worksheets: { 'Orders by Day' => [['federated.s', 'CAL_DATE']], 'Hires by Day' => [['federated.h', 'CAL_DATE']] },
             dashboards: { 'Daily' => ['Orders by Day', 'Hires by Day'] }),
    dm: dm(elements: { 'orders' => { path: %w[SALES PUBLIC ORDERS], cols: %w[ORDER_ID DATE_KEY] },
                       'sdate' => { path: %w[SALES PUBLIC DATE_DIM], cols: %w[DATE_KEY CAL_DATE] },
                       'hires' => { path: %w[HR PUBLIC HIRES], cols: %w[HIRE_ID DATE_KEY] },
                       'hdate' => { path: %w[HR PUBLIC DATE_DIM], cols: %w[DATE_KEY CAL_DATE] } },
           rels: [%w[orders DATE_KEY sdate DATE_KEY], %w[hires DATE_KEY hdate DATE_KEY]])
  },
  'short-name-ambiguous' => {
    twb: twb(datasources: [{ caption: 'Sales', name: 'federated.s', db: nil, schema: 'PUBLIC',
                             tables: { 'ORDERS' => %w[ORDER_ID DATE_KEY], 'DATE_DIM' => %w[DATE_KEY CAL_DATE] },
                             rels: [%w[ORDERS DATE_KEY DATE_DIM DATE_KEY]] }],
             worksheets: { 'Orders by Day' => [['federated.s', 'CAL_DATE']] },
             dashboards: { 'Daily' => ['Orders by Day'] }),
    dm: dm(elements: { 'orders' => { path: %w[SALES PUBLIC ORDERS], cols: %w[ORDER_ID DATE_KEY] },
                       'sdate' => { path: %w[SALES PUBLIC DATE_DIM], cols: %w[DATE_KEY CAL_DATE] },
                       'hdate' => { path: %w[HR PUBLIC DATE_DIM], cols: %w[DATE_KEY CAL_DATE] } },
           rels: [%w[orders DATE_KEY sdate DATE_KEY]])
  },
  # Review I2: a schema-only Tableau name (no dbname) must agree with the model
  # on schema too — HR.DATE_DIM is not ANALYTICS.SALES.DATE_DIM.
  'schema-mismatch' => {
    twb: twb(datasources: [{ caption: 'HR', name: 'federated.h', db: nil, schema: 'HR',
                             tables: { 'HIRES' => %w[HIRE_ID DATE_KEY], 'DATE_DIM' => %w[DATE_KEY CAL_DATE] },
                             rels: [%w[HIRES DATE_KEY DATE_DIM DATE_KEY]] }],
             worksheets: { 'Hires' => [['federated.h', 'HIRE_ID']] },
             dashboards: { 'HR' => ['Hires'] }),
    dm: dm(elements: { 'hires' => { path: %w[ANALYTICS HR HIRES], cols: %w[HIRE_ID DATE_KEY] },
                       'date' => { path: %w[ANALYTICS SALES DATE_DIM], cols: %w[DATE_KEY CAL_DATE] } },
           rels: [%w[hires DATE_KEY date DATE_KEY]])
  },
  # Two different Tableau tables (PUBLIC.DATE_DIM, bare DATE_DIM) that both
  # resolve to the one model element: ambiguous, never silently shared.
  'two-tables-one-element' => {
    twb: twb(datasources: [
               { caption: 'Sales', name: 'federated.s', db: nil, schema: 'PUBLIC',
                 tables: { 'ORDERS' => %w[ORDER_ID DATE_KEY], 'DATE_DIM' => %w[DATE_KEY CAL_DATE] },
                 rels: [%w[ORDERS DATE_KEY DATE_DIM DATE_KEY]] },
               { caption: 'Plan', name: 'federated.p', db: nil, schema: nil,
                 tables: { 'TARGETS' => %w[TARGET_ID DATE_KEY], 'DATE_DIM' => %w[DATE_KEY CAL_DATE] },
                 rels: [%w[TARGETS DATE_KEY DATE_DIM DATE_KEY]] }
             ],
             worksheets: { 'Orders by Day' => [['federated.s', 'CAL_DATE']] },
             dashboards: { 'Daily' => ['Orders by Day'] }),
    dm: dm(elements: { 'orders' => { path: %w[ANALYTICS PUBLIC ORDERS], cols: %w[ORDER_ID DATE_KEY] },
                       'targets' => { path: %w[ANALYTICS PLAN TARGETS], cols: %w[TARGET_ID DATE_KEY] },
                       'date' => { path: %w[ANALYTICS PUBLIC DATE_DIM], cols: %w[DATE_KEY CAL_DATE] } },
           rels: [%w[orders DATE_KEY date DATE_KEY], %w[targets DATE_KEY date DATE_KEY]])
  },
  # Live-test shape (review follow-up): a Tableau Hyper extract (GUID dbname,
  # Extract schema) whose tables were renamed when landed in the warehouse,
  # resolved exactly like the converter does (--db/--schema + --table-mapping);
  # two Tableau tables (FACT_SALES, FACT_ORDERS) land on one warehouse table.
  'extract-renamed' => {
    twb: twb(datasources: [{ caption: 'Extract', name: 'federated.x', conn_class: 'hyper',
                             db: '6B3C612D-54EF-4690-ACEE-1AEDA06DECE2', schema: 'Extract',
                             tables: { 'FACT_SALES' => %w[ORDER_ID ORDER_LINE_NO CUSTOMER_KEY AMOUNT],
                                       'DIM_CUSTOMER' => %w[CUSTOMER_KEY CUSTOMER_NAME],
                                       'FACT_ORDERS' => %w[ORDER_ID ORDER_LINE_NO] },
                             rels: [%w[FACT_SALES CUSTOMER_KEY DIM_CUSTOMER CUSTOMER_KEY],
                                    %w[FACT_SALES ORDER_ID FACT_ORDERS ORDER_ID]] }],
             worksheets: { 'Customer Revenue' => [['federated.x', 'CUSTOMER_NAME'], ['federated.x', 'AMOUNT']] },
             dashboards: { 'Overview' => ['Customer Revenue'] }),
    dm: dm(elements: { 'sales' => { path: %w[ANALYTICS LANDED SALES_WIDE], cols: %w[ORDER_ID ORDER_LINE_NO CUSTOMER_KEY AMOUNT] },
                       'cust' => { path: %w[ANALYTICS LANDED CUSTOMERS], cols: %w[CUSTOMER_KEY CUSTOMER_NAME] },
                       'orders' => { path: %w[ANALYTICS LANDED SALES_WIDE], cols: %w[ORDER_ID ORDER_LINE_NO] } },
           rels: [%w[sales CUSTOMER_KEY cust CUSTOMER_KEY], %w[sales ORDER_ID orders ORDER_ID]]),
    resolution: { 'db' => 'ANALYTICS', 'schema' => 'LANDED',
                  'table_mapping' => { 'FACT_SALES' => 'SALES_WIDE', 'FACT_ORDERS' => 'SALES_WIDE',
                                       'DIM_CUSTOMER' => 'CUSTOMERS' } }
  },
  'role-played' => {
    twb: twb(datasources: [{ caption: 'Flights', name: 'federated.f', db: 'ANALYTICS', schema: 'PUBLIC',
                             tables: { 'FLIGHTS' => %w[FLIGHT_ID ORIGIN_KEY], 'AIRPORTS' => %w[AIRPORT_KEY AIRPORT_NAME] },
                             rels: [%w[FLIGHTS ORIGIN_KEY AIRPORTS AIRPORT_KEY]] }],
             worksheets: { 'Flights by Origin' => [['federated.f', 'AIRPORT_NAME'], ['federated.f', 'FLIGHT_ID']] },
             dashboards: { 'Ops' => ['Flights by Origin'] }),
    dm: dm(elements: { 'flights' => { path: P.('FLIGHTS'), cols: %w[FLIGHT_ID ORIGIN_KEY DEST_KEY] },
                       'origin' => { path: P.('AIRPORTS'), cols: %w[AIRPORT_KEY AIRPORT_NAME], name: 'Origin Airport' },
                       'dest' => { path: P.('AIRPORTS'), cols: %w[AIRPORT_KEY AIRPORT_NAME], name: 'Destination Airport' } },
           rels: [%w[flights ORIGIN_KEY origin AIRPORT_KEY], %w[flights DEST_KEY dest AIRPORT_KEY]])
  },
  # Review: a self-join's field use needs a worksheet that reads BOTH objects
  # (the table and its aliased copy); reading the one table alone never
  # reaches the self relationship.
  'self-join-unused' => {
    twb: twb(datasources: [EMPLOYEES], worksheets: { 'Headcount' => [[E, 'EMP_ID'], [E, 'EMP_NAME']] },
             dashboards: { 'People' => ['Headcount'] }),
    dm: dm(elements: { 'emp' => { path: P.('EMPLOYEES'), cols: %w[EMP_ID EMP_NAME MANAGER_ID] } }, rels: [])
  },
  'self-join-used' => {
    twb: twb(datasources: [EMPLOYEES], worksheets: { 'Org Chart' => [[E, 'EMP_NAME'], [E, 'EMP_NAME (MANAGER)']] },
             dashboards: { 'People' => ['Org Chart'] }),
    dm: dm(elements: { 'emp' => { path: P.('EMPLOYEES'), cols: %w[EMP_ID EMP_NAME MANAGER_ID] } }, rels: [])
  },
  # Review: an empty calculation formula is unknown usage (fail closed), not
  # a field that reads no table.
  'dropped-used-by-empty-calc' => {
    twb: twb(datasources: [STAR.merge(calcs: { 'Blank Calc' => '' })],
             worksheets: { 'Revenue by Customer' => [[S, 'CUSTOMER_NAME'], [S, 'Calculation_00']] },
             dashboards: { 'Overview' => ['Revenue by Customer'] }),
    dm: dm(elements: STAR_ELS.reject { |k, _| k == 'prod' }, rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY]])
  },
  'custom-sql' => {
    twb: twb(datasources: [STAR.merge(sql: { 'DIM_PRODUCT' => 'SELECT PRODUCT_KEY, PRODUCT_NAME FROM PUBLIC.PRODUCTS WHERE ACTIVE' })],
             worksheets: REVENUE, dashboards: OVERVIEW),
    dm: dm(elements: STAR_ELS.merge('prod' => { sql: "select product_key, product_name\n  from public.products where active",
                                                cols: %w[PRODUCT_KEY PRODUCT_NAME] }),
           rels: [%w[orders CUSTOMER_KEY cust CUSTOMER_KEY], %w[orders PRODUCT_KEY prod PRODUCT_KEY]])
  }
}.freeze

CASES.each do |name, c|
  dir = File.join(HERE, name)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, 'workbook-content.twb'), c[:twb])
  File.write(File.join(dir, 'dm-spec-reused.json'), "#{JSON.pretty_generate(c[:dm])}\n")
  File.write(File.join(dir, 'dashboard-scope.json'), "#{JSON.pretty_generate(c[:scope] || { 'mode' => 'full' })}\n")
  File.write(File.join(dir, 'resolution.json'), "#{JSON.pretty_generate(c[:resolution])}\n") if c[:resolution]
end
puts "relationship-map fixtures: wrote #{CASES.size} case(s) under #{HERE}"

# --goldens: expected-map.json per case — the Ruby derivation, pinned so the
# Python twin (scripts/lib/relationship_map.py) is held to the same output.
# Review the diff before committing: a golden change is a behavior change.
if ARGV.include?('--goldens')
  require_relative '../../lib/relationship_map'
  CASES.each_key do |name|
    dir = File.join(HERE, name)
    map = RelationshipMap.derive(
      twb_xml: File.read(File.join(dir, 'workbook-content.twb'), encoding: 'bom|utf-8'),
      dm_spec: JSON.parse(File.read(File.join(dir, 'dm-spec-reused.json'))),
      dashboards: RelationshipMap.scoped_dashboards(JSON.parse(File.read(File.join(dir, 'dashboard-scope.json')))),
      resolution: File.file?(File.join(dir, 'resolution.json')) ? JSON.parse(File.read(File.join(dir, 'resolution.json'))) : nil
    )
    RelationshipMap.write(File.join(dir, 'expected-map.json'), map)
  end
  puts "relationship-map fixtures: wrote #{CASES.size} golden map(s)"
end
