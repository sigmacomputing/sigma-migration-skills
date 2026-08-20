#!/usr/bin/env ruby
# frozen_string_literal: true
# Object-model ("noodle") converter regression suite — locks the wave-2 batch
# that answered the 2026-07-28 field failure (single datasource, N logical
# tables, relationships serialized onto the FIRST-end-point = the authoring-
# order BASE table, routinely a dimension):
#
#   1. FACT ELECTION is evidence-ranked (relationship degree → measure columns
#      → not-dim-like name → width), ANNOUNCED in warnings, and overridable
#      via options.factTable — never "first relationship-carrier in document
#      order". Endpoint orientation must NOT change the outcome.
#   2. EDGE ORIENTATION: every wired relationship is CARRIED by the fact-side
#      element (Sigma relationships are directional; the many side is the
#      source), keys swapped to match.
#   3. NAMED GAPS: un-wire-able relationships (no key / computed-only /
#      non-equality) land in result.workbookPatterns kind:'unsupported' with
#      the pair + reason, plus a partial-wire summary warning — never a silent
#      drive-by WARN. A FULLY-WIRED noodle emits NO disconnect/partial noise
#      (the ≤5% false-trip budget case).
#   4. STRUCTURAL entitlement-table RLS: fires on the documented shape
#      (related table + user-identity column + datasource-filter/user-function
#      signal) as kind:'rls-entitlement-table' with Port strategies A/B/C —
#      NEVER on a name regex alone, NEVER on an identity-shaped column alone
#      (a plain dim with a user column must not false-trip). Never applied.
#   5. HELPER OWNERSHIP GUARDS: no LOD/Top-N helper SQL may SELECT FROM a
#      dimension table (the wrong-FROM class); off-fact groupings REFUSE loud.
#   6. SLASH-NAMED COLUMNS dropped from derived elements now WARN (name +
#      rename fix) instead of vanishing.
#   7. SINGLE-DS CONTROLID DEDUPE: near-identical parameter names collapse to
#      one control + a warning (previously duplicate ids that hard-fail POST).
#   8. MULTI-DATASOURCE NOT-MERGED regression: 2 independent datasources still
#      produce a multi-element DM with both sources present (owner veto).
#
# Needs `node` on PATH (same convention as test-converter-fixtures.rb): when
# node is absent the suite SKIPS with a warning, but a re-vendor that renames
# convertTableauToSigma still hard-aborts.
#
# Usage:  ruby scripts/test-object-model-converter.rb

require 'json'
require 'open3'
require 'set'
require 'tmpdir'

VENDORED = File.expand_path('../converter/tableau.mjs', __dir__)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Re-vendor guard runs before the node check — a silent skip must never hide a
# renamed export.
src = File.read(VENDORED, encoding: 'UTF-8')
abort 'FATAL: convertTableauToSigma no longer exported from converter/tableau.mjs — re-vendor broke the suite' \
  unless src.include?('convertTableauToSigma')

_o, _e, st = Open3.capture3('node', '--version') rescue nil
unless st&.success?
  warn '  WARN  node not found on PATH — object-model converter suite SKIPPED (CI runners may lack node).'
  exit 0
end

# ---------------------------------------------------------------------------
# Fixture builder — mirrors the neutral shapes of the empirical audit
# (FACT_VISITS / DIM_DATES / DIM_SITES / DIM_PROVIDERS / ENTITLEMENTS,
# db ANALYTICS.PUBLIC). All synthetic; no field identifiers.
# ---------------------------------------------------------------------------
TBL = {
  'FACT_VISITS' => { obj: 'FACT_VISITS_AA11BB22CC33DD44EE55FF6677889900',
                     cols: [%w[VISIT_ID string], %w[DATE_KEY integer], %w[SITE_KEY integer],
                            %w[PROVIDER_KEY integer], %w[VISIT_REVENUE real], %w[VISIT_COST real],
                            %w[PATIENT_COUNT integer], %w[VISIT_TYPE string]] },
  'DIM_DATES' => { obj: 'DIM_DATES_1122334455667788990011223344AABB',
                   cols: [%w[DATE_KEY integer], %w[DATE_DAY date], %w[DATE_MONTH string], %w[DATE_YEAR integer]] },
  'DIM_SITES' => { obj: 'DIM_SITES_99887766554433221100AABBCCDDEEFF',
                   cols: [%w[SITE_KEY integer], %w[SITE_NAME string], %w[SITE_REGION string]] },
  'DIM_PROVIDERS' => { obj: 'DIM_PROVIDERS_ABCDEF01234567890123456789ABCDEF',
                       cols: [%w[PROVIDER_KEY integer], %w[PROVIDER_NAME string], %w[USER_NAME string]] },
  'ENTITLEMENTS' => { obj: 'ENTITLEMENTS_FEDCBA98765432100123456789ABCDEF',
                      cols: [%w[SITE_KEY integer], %w[USER_EMAIL string]] },
  'RLS_LOOKUP' => { obj: 'RLS_LOOKUP_0123456789ABCDEF0123456789ABCDEF',
                    cols: [%w[SITE_KEY integer], %w[LOOKUP_CODE string]] }
}.freeze

def meta_records(tables, caption_overrides = {})
  tables.flat_map do |t|
    TBL[t][:cols].each_with_index.map do |(phys, typ), i|
      cap = caption_overrides[[t, phys]] || phys.split('_').map(&:capitalize).join(' ')
      rt = { 'real' => 5, 'integer' => 20, 'date' => 133 }.fetch(typ, 129)
      <<~XML
        <metadata-record class='column'>
          <remote-name>#{phys}</remote-name>
          <remote-type>#{rt}</remote-type>
          <local-name>[#{phys}]</local-name>
          <parent-name>[#{t}]</parent-name>
          <remote-alias>#{phys}</remote-alias>
          <ordinal>#{i}</ordinal>
          <caption>#{cap}</caption>
          <local-type>#{typ}</local-type>
          <object-id>[#{TBL[t][:obj]}]</object-id>
        </metadata-record>
      XML
    end
  end.join
end

# rel: [first, second, keys] — keys = [[l, r], ...], [] = empty expression,
# :computed = computed-only clause, :range = inequality-only clause.
def rel_xml(first, second, keys)
  expr =
    case keys
    when :computed
      "<expression op='='><expression op='DATE([ORDER_TS])'/><expression op='[DATE_DAY]'/></expression>"
    when :range
      "<expression op='&lt;='><expression op='[DATE_KEY]'/><expression op='[DATE_KEY]'/></expression>"
    else
      keys.map { |l, r| "<expression op='='><expression op='[#{l}]'/><expression op='[#{r}]'/></expression>" }.join
    end
  <<~XML
    <relationship>
      #{expr}
      <first-end-point object-id='#{TBL[first][:obj]}' />
      <second-end-point object-id='#{TBL[second][:obj]}' unique-key='true' />
    </relationship>
  XML
end

def noodle_ds(tables:, rels:, calcs: [], filters: [], caption_overrides: {}, ds_name: 'federated.1noodle')
  <<~XML
    <datasource caption='Visits Model' inline='true' name='#{ds_name}' version='18.1'>
      <connection class='federated'>
        <named-connections>
          <named-connection caption='warehouse' name='snowflake.conn1'>
            <connection authentication='oauth' class='snowflake' dbname='ANALYTICS' schema='PUBLIC' server='demo.example.com' warehouse='WH_TEST' />
          </named-connection>
        </named-connections>
        <relation type='collection'>
          #{tables.map { |t| "<relation connection='snowflake.conn1' name='#{t}' table='[PUBLIC].[#{t}]' type='table' />" }.join("\n          ")}
        </relation>
        <metadata-records>
          #{meta_records(tables, caption_overrides)}
        </metadata-records>
      </connection>
      <object-graph>
        <objects>
          #{tables.map { |t| "<object caption='#{t}' id='#{TBL[t][:obj]}' />" }.join("\n          ")}
        </objects>
        <relationships>
          #{rels.map { |f, s, k| rel_xml(f, s, k) }.join("\n          ")}
        </relationships>
      </object-graph>
      #{calcs.join("\n      ")}
      #{filters.join("\n      ")}
    </datasource>
  XML
end

PARAMS_DS = <<~XML
  <datasource hasconnection='false' inline='true' name='Parameters' version='18.1'>
    <column caption='Top N Sites' datatype='integer' name='[Parameter 1]' param-domain-type='range' role='measure' type='quantitative' value='5'>
      <calculation class='tableau' formula='5' />
      <range granularity='1' max='20' min='1' />
    </column>
    <column caption='Top_N_Sites' datatype='integer' name='[Parameter 2]' param-domain-type='range' role='measure' type='quantitative' value='10'>
      <calculation class='tableau' formula='10' />
      <range granularity='1' max='50' min='1' />
    </column>
  </datasource>
XML

def worksheet(ds_name)
  <<~XML
    <worksheet name='Visits Sheet'>
      <table>
        <view>
          <datasources><datasource caption='ds' name='#{ds_name}' /></datasources>
          <datasource-dependencies datasource='#{ds_name}'>
            <column datatype='string' name='[VISIT_TYPE]' role='dimension' type='nominal' />
            <column datatype='real' name='[VISIT_REVENUE]' role='measure' type='quantitative' />
          </datasource-dependencies>
          <aggregation value='true' />
        </view>
        <panes><pane><view><breakdown value='auto' /></view><mark class='Bar' /></pane></panes>
        <rows>[#{ds_name}].[sum:VISIT_REVENUE:qk]</rows>
        <cols>[#{ds_name}].[none:VISIT_TYPE:nk]</cols>
      </table>
    </worksheet>
  XML
end

def wb(ds_xml, params: false)
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook original-version='18.1' source-build='2023.1.0' source-platform='win' version='18.1' xmlns:user='http://www.tableausoftware.com/xml/user'>
      <preferences />
      <datasources>
        #{ds_xml}
        #{params ? PARAMS_DS : ''}
      </datasources>
      <worksheets>
        #{worksheet('federated.1noodle')}
      </worksheets>
    </workbook>
  XML
end

CALC = ->(caption, name, formula, dt = 'real', role = 'measure') {
  "<column caption='#{caption}' datatype='#{dt}' name='[#{name}]' role='#{role}' type='quantitative'><calculation class='tableau' formula='#{formula}' /></column>"
}
CAT_FILTER = "<filter class='categorical' column='[federated.1noodle].[none:USER_EMAIL:nk]' filter-group='2'><groupfilter function='level-members' level='[USER_EMAIL]' /></filter>"

# Edges: worst-case orientation (dims/entitlement serialized as FIRST-end-point).
DIM_FIRST_RELS = [
  ['DIM_DATES',    'FACT_VISITS', [%w[DATE_KEY DATE_KEY]]],
  ['DIM_SITES',    'FACT_VISITS', [%w[SITE_KEY SITE_KEY]]],
  ['DIM_PROVIDERS', 'FACT_VISITS', [%w[PROVIDER_KEY PROVIDER_KEY]]],
  ['ENTITLEMENTS', 'FACT_VISITS', [%w[SITE_KEY SITE_KEY]]]
].freeze
FACT_FIRST_RELS = DIM_FIRST_RELS.map { |f, s, k| [s, f, k.map(&:reverse)] }.freeze

# ---------------------------------------------------------------------------
# Role-played date-dimension fixtures (a later wave R3-1 parity killer): one
# physical DIM_DATES role-played as Admit/Discharge/Followup Date. Tableau
# serializes N <relation> entries sharing one physical table attr; the
# <object-graph> object CAPTION is the role name and the metadata object-ids
# ("DIM_DATES_<hex>") identify each instance. All names invented.
# ---------------------------------------------------------------------------
RP_FACT_OBJ = 'FACT_STAYS_AB12CD34EF56AB78CD90EF12AB34CD56'
RP_DIM_OBJS = %w[DIM_DATES_AA000000000000000000000000000001
                 DIM_DATES_BB000000000000000000000000000002
                 DIM_DATES_CC000000000000000000000000000003].freeze
RP_ROLES = ['Admit Date', 'Discharge Date', 'Followup Date'].freeze
RP_STAY_TS_UUID = 'aa11bb22-cc33-4dd5-8ee6-ff6677889900'
RP_FACT_COLS = [%w[STAY_ID string], %w[ADMIT_DATE_KEY integer], %w[DISCHARGE_DATE_KEY integer],
                %w[FOLLOWUP_DATE_KEY integer], %w[STAY_REVENUE real]].freeze
RP_DIM_COLS = [%w[DATE_KEY integer], %w[DATE_DAY date], %w[DATE_MONTH string]].freeze

def rp_meta(parent, objid, cols, with_objids: true)
  cols.each_with_index.map do |(phys, typ), i|
    cap = phys.split('_').map(&:capitalize).join(' ')
    rt = { 'real' => 5, 'integer' => 20, 'date' => 133 }.fetch(typ, 129)
    oid = with_objids ? "<object-id>[#{objid}]</object-id>" : ''
    <<~XML
      <metadata-record class='column'>
        <remote-name>#{phys}</remote-name>
        <remote-type>#{rt}</remote-type>
        <local-name>[#{phys}]</local-name>
        <parent-name>[#{parent}]</parent-name>
        <remote-alias>#{phys}</remote-alias>
        <ordinal>#{i}</ordinal>
        <caption>#{cap}</caption>
        <local-type>#{typ}</local-type>
        #{oid}
      </metadata-record>
    XML
  end.join
end

def rp_object(caption, objid, rel_name)
  <<~XML
    <object caption='#{caption}' id='#{objid}'>
      <properties context=''>
        <relation connection='snowflake.conn1' name='#{rel_name}' table='[PUBLIC].[DIM_DATES]' type='table' />
      </properties>
    </object>
  XML
end

def rp_rel(first_obj, second_obj, left_op, right_op)
  <<~XML
    <relationship>
      <expression op='='><expression op='#{left_op}'/><expression op='#{right_op}'/></expression>
      <first-end-point object-id='#{first_obj}' />
      <second-end-point object-id='#{second_obj}' unique-key='true' />
    </relationship>
  XML
end

def roleplay_ds(ds_name, with_objids: true, calckey_only: false)
  dim_instances = calckey_only ? %w[DIM_DATES] : %w[DIM_DATES DIM_DATES1 DIM_DATES2]
  fact_meta = rp_meta('FACT_STAYS', RP_FACT_OBJ, RP_FACT_COLS, with_objids: with_objids)
  if calckey_only
    # A fact date column referenced only by uuid — the DATE([uuid]) join side.
    fact_meta += <<~XML
      <metadata-record class='column'>
        <remote-name>#{RP_STAY_TS_UUID}</remote-name>
        <remote-type>133</remote-type>
        <local-name>[#{RP_STAY_TS_UUID}]</local-name>
        <parent-name>[FACT_STAYS]</parent-name>
        <remote-alias>STAY_START</remote-alias>
        <ordinal>9</ordinal>
        <caption>Stay Start</caption>
        <local-type>date</local-type>
        #{with_objids ? "<object-id>[#{RP_FACT_OBJ}]</object-id>" : ''}
      </metadata-record>
    XML
  end
  dim_meta = dim_instances.each_with_index.map do |_inst, i|
    rp_meta('DIM_DATES', RP_DIM_OBJS[i], RP_DIM_COLS, with_objids: with_objids)
  end.join
  objects = ["<object caption='FACT_STAYS' id='#{RP_FACT_OBJ}'><properties context=''>" \
             "<relation connection='snowflake.conn1' name='FACT_STAYS' table='[PUBLIC].[FACT_STAYS]' type='table' />" \
             '</properties></object>'] +
            dim_instances.each_with_index.map { |inst, i| rp_object(calckey_only ? 'DIM_DATES' : RP_ROLES[i], RP_DIM_OBJS[i], inst) }
  rels =
    if calckey_only
      [rp_rel(RP_FACT_OBJ, RP_DIM_OBJS[0], "DATE([#{RP_STAY_TS_UUID}])", '[DATE_KEY]')]
    else
      %w[ADMIT_DATE_KEY DISCHARGE_DATE_KEY FOLLOWUP_DATE_KEY].each_with_index.map do |fk, i|
        rp_rel(RP_FACT_OBJ, RP_DIM_OBJS[i], "[#{fk}]", '[DATE_KEY]')
      end
    end
  <<~XML
    <datasource caption='Stays Model' inline='true' name='#{ds_name}' version='18.1'>
      <connection class='federated'>
        <named-connections>
          <named-connection caption='warehouse' name='snowflake.conn1'>
            <connection authentication='oauth' class='snowflake' dbname='ANALYTICS' schema='PUBLIC' server='demo.example.com' warehouse='WH_TEST' />
          </named-connection>
        </named-connections>
        <relation type='collection'>
          <relation connection='snowflake.conn1' name='FACT_STAYS' table='[PUBLIC].[FACT_STAYS]' type='table' />
          #{dim_instances.map { |inst| "<relation connection='snowflake.conn1' name='#{inst}' table='[PUBLIC].[DIM_DATES]' type='table' />" }.join("\n          ")}
        </relation>
        <metadata-records>
          #{fact_meta}
          #{dim_meta}
        </metadata-records>
      </connection>
      <object-graph>
        <objects>
          #{objects.join("\n          ")}
        </objects>
        <relationships>
          #{rels.join("\n          ")}
        </relationships>
      </object-graph>
    </datasource>
  XML
end

def roleplay_wb(ds_name, **kw)
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook original-version='18.1' source-build='2023.1.0' source-platform='win' version='18.1' xmlns:user='http://www.tableausoftware.com/xml/user'>
      <preferences />
      <datasources>
        #{roleplay_ds(ds_name, **kw)}
      </datasources>
      <worksheets>
        <worksheet name='Stays Sheet'><table><view><datasources><datasource name='#{ds_name}'/></datasources></view><rows>[#{ds_name}].[sum:STAY_REVENUE:qk]</rows><cols>[#{ds_name}].[none:STAY_ID:nk]</cols></table></worksheet>
      </worksheets>
    </workbook>
  XML
end

ROLEPLAY_FIXTURES = {
  'roleplay' => { xml: roleplay_wb('federated.1role') },
  'roleplay-ambiguous' => { xml: roleplay_wb('federated.1roleamb', with_objids: false) },
  'roleplay-calckey' => { xml: roleplay_wb('federated.1rolekey', calckey_only: true) }
}.freeze

FIXTURES = {
  'e-worst' => { xml: wb(noodle_ds(
    tables: %w[DIM_DATES FACT_VISITS DIM_SITES DIM_PROVIDERS ENTITLEMENTS], # dim FIRST in doc order
    rels: DIM_FIRST_RELS,
    calcs: [CALC.call('Monthly Revenue', 'Calculation_100', '{FIXED [DATE_MONTH] : SUM([VISIT_REVENUE])}'),
            CALC.call('Site Revenue', 'Calculation_101', '{FIXED [SITE_NAME] : SUM([VISIT_REVENUE])}')],
    filters: [CAT_FILTER]), params: true) },
  'b-happy' => { xml: wb(noodle_ds(
    tables: %w[FACT_VISITS DIM_DATES DIM_SITES DIM_PROVIDERS ENTITLEMENTS],
    rels: FACT_FIRST_RELS, filters: [CAT_FILTER]), params: true) },
  'c-nokeys' => { xml: wb(noodle_ds(
    tables: %w[FACT_VISITS DIM_DATES DIM_SITES],
    rels: [['FACT_VISITS', 'DIM_DATES', []], ['FACT_VISITS', 'DIM_SITES', []]])) },
  'partial' => { xml: wb(noodle_ds(
    tables: %w[FACT_VISITS DIM_DATES DIM_SITES],
    rels: [['FACT_VISITS', 'DIM_SITES', [%w[SITE_KEY SITE_KEY]]], ['FACT_VISITS', 'DIM_DATES', :computed]])) },
  'range' => { xml: wb(noodle_ds(
    tables: %w[FACT_VISITS DIM_DATES],
    rels: [['FACT_VISITS', 'DIM_DATES', :range]])) },
  'slash' => { xml: wb(noodle_ds(
    tables: %w[FACT_VISITS DIM_SITES],
    rels: [['FACT_VISITS', 'DIM_SITES', [%w[SITE_KEY SITE_KEY]]]],
    caption_overrides: { %w[DIM_SITES SITE_REGION] => 'Site /Region' })) },
  'd2-userfn' => { xml: wb(noodle_ds(
    tables: %w[FACT_VISITS DIM_SITES ENTITLEMENTS],
    rels: [['FACT_VISITS', 'DIM_SITES', [%w[SITE_KEY SITE_KEY]]],
           ['ENTITLEMENTS', 'FACT_VISITS', [%w[SITE_KEY SITE_KEY]]]],
    calcs: [CALC.call('User Access', 'Calculation_200', 'USERNAME() = [USER_EMAIL]', 'boolean', 'dimension')],
    filters: [CAT_FILTER])) },
  'neg-dimuser' => { xml: wb(noodle_ds(
    tables: %w[FACT_VISITS DIM_PROVIDERS RLS_LOOKUP],
    rels: [['FACT_VISITS', 'DIM_PROVIDERS', [%w[PROVIDER_KEY PROVIDER_KEY]]],
           ['FACT_VISITS', 'RLS_LOOKUP', [%w[SITE_KEY SITE_KEY]]]])) },
  'pure-exprfilter' => { xml: wb(noodle_ds(
    tables: %w[FACT_VISITS DIM_SITES],
    rels: [['FACT_VISITS', 'DIM_SITES', [%w[SITE_KEY SITE_KEY]]]],
    filters: ["<filter class='expression' expression='USERNAME()=&quot;admin@example.com&quot;' />"])) },
  'e-override' => { xml: wb(noodle_ds(
    tables: %w[DIM_DATES FACT_VISITS DIM_SITES DIM_PROVIDERS ENTITLEMENTS],
    rels: DIM_FIRST_RELS, filters: [CAT_FILTER])), opts: { 'factTable' => 'DIM_DATES' } },
  'multi-ds' => { xml: <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook original-version='18.1' source-build='2023.1.0' source-platform='win' version='18.1' xmlns:user='http://www.tableausoftware.com/xml/user'>
      <preferences />
      <datasources>
        <datasource caption='Visits DS' inline='true' name='federated.0aaa' version='18.1'>
          <connection class='federated'>
            <named-connections><named-connection caption='w' name='snowflake.c1'>
              <connection authentication='oauth' class='snowflake' dbname='ANALYTICS' schema='PUBLIC' server='demo.example.com' warehouse='WH' />
            </named-connection></named-connections>
            <relation connection='snowflake.c1' name='FACT_VISITS' table='[PUBLIC].[FACT_VISITS]' type='table'>
              <columns><column datatype='real' name='[VISIT_REVENUE]' /><column datatype='string' name='[VISIT_TYPE]' /></columns>
            </relation>
          </connection>
        </datasource>
        <datasource caption='Sites DS' inline='true' name='federated.0bbb' version='18.1'>
          <connection class='federated'>
            <named-connections><named-connection caption='w' name='snowflake.c2'>
              <connection authentication='oauth' class='snowflake' dbname='ANALYTICS' schema='PUBLIC' server='demo.example.com' warehouse='WH' />
            </named-connection></named-connections>
            <relation connection='snowflake.c2' name='DIM_SITES' table='[PUBLIC].[DIM_SITES]' type='table'>
              <columns><column datatype='string' name='[SITE_NAME]' /></columns>
            </relation>
          </connection>
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='A'><table><view><datasources><datasource name='federated.0aaa'/></datasources></view><rows>[federated.0aaa].[sum:VISIT_REVENUE:qk]</rows><cols>[federated.0aaa].[none:VISIT_TYPE:nk]</cols></table></worksheet>
        <worksheet name='B'><table><view><datasources><datasource name='federated.0bbb'/></datasources></view><rows /><cols>[federated.0bbb].[none:SITE_NAME:nk]</cols></table></worksheet>
      </worksheets>
    </workbook>
  XML
  }
}.merge(ROLEPLAY_FIXTURES).freeze

DRIVER = <<~JS
  import { readFileSync, writeFileSync } from 'node:fs';
  import { pathToFileURL } from 'node:url';
  const [convPath, manifestPath, outPath] = process.argv.slice(2);
  const { convertTableauToSigma } = await import(pathToFileURL(convPath).href);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const results = {};
  for (const [name, rec] of Object.entries(manifest)) {
    const xml = readFileSync(rec.twb, 'utf8');
    let out;
    try {
      out = convertTableauToSigma(xml, Object.assign(
        { connectionId: 'test-conn', database: 'ANALYTICS', schema: 'PUBLIC' }, rec.opts || {}));
    } catch (e) {
      results[name] = { ERROR: String((e && e.stack) || e) };
      continue;
    }
    const model = out.model || out;
    const els = (model.pages || []).flatMap((p) => p.elements || []);
    const byId = Object.fromEntries(els.map((e) => [e.id, e]));
    const nameOf = (e) => e.name || (e.source && e.source.path ? e.source.path[e.source.path.length - 1] : (e.source && e.source.kind) || e.kind);
    results[name] = {
      elements: els.filter((e) => e.kind === 'table').map((e) => ({
        name: nameOf(e),
        kind: e.source && e.source.kind,
        colIds: (e.columns || []).map((c) => c.id),
        colDefs: (e.columns || []).map((c) => ({ id: c.id, name: c.name || null, formula: c.formula || null })),
        metricDefs: (e.metrics || []).map((m) => ({ id: m.id, name: m.name || null, formula: m.formula || null })),
        columns: (e.columns || []).length,
        statement: e.source && e.source.kind === 'sql' ? e.source.statement : null,
        relationships: (e.relationships || []).map((r) => ({
          target: byId[r.targetElementId] ? nameOf(byId[r.targetElementId]) : ('<missing ' + r.targetElementId + '>'),
          keys: r.keys || [],
          derivedVia: r.derivedVia || null,
          partial: r.partial === true,
          droppedConditions: r.droppedConditions || 0
        }))
      })),
      controls: els.filter((e) => e.kind === 'control').map((e) => ({ id: e.id, controlId: e.controlId })),
      warnings: out.warnings || [],
      security: out.security || (out.result && out.result.security) || [],
      workbookPatterns: out.workbookPatterns || [],
      relationshipCoverage: out.relationshipCoverage || null
    };
  }
  writeFileSync(outPath, JSON.stringify(results, null, 2));
JS

results = nil
Dir.mktmpdir do |dir|
  manifest = {}
  FIXTURES.each do |name, rec|
    twb = File.join(dir, "#{name}.twb")
    File.write(twb, rec[:xml])
    manifest[name] = { 'twb' => twb, 'opts' => rec[:opts] || {} }
  end
  mpath = File.join(dir, 'manifest.json')
  File.write(mpath, JSON.generate(manifest))
  runner = File.join(dir, 'driver.mjs')
  File.write(runner, DRIVER)
  outp = File.join(dir, 'out.json')
  _o, err, st = Open3.capture3('node', runner, VENDORED, mpath, outp)
  abort "FATAL: node driver failed:\n#{err}" unless st.success? && File.exist?(outp)
  results = JSON.parse(File.read(outp))
end

results.each { |n, r| abort "FATAL: fixture #{n} crashed the converter:\n#{r['ERROR']}" if r['ERROR'] }

fact_of = ->(r) { r['elements'].find { |e| e['name'].to_s.include?('FACT_VISITS') && e['kind'] != 'sql' } }
rels_of = ->(el) { (el && el['relationships'] || []).map { |x| x['target'] } }

# ---------------------------------------------------------------------------
puts 'Part 1 — evidence-ranked fact election (announced, orientation-invariant, overridable)'
%w[e-worst b-happy].each do |fx|
  r = results[fx]
  ann = r['warnings'].grep(/fact election/i)
  check(ann.any? { |w| w =~ /elected "FACT_VISITS"/ },
        "#{fx}: election warning names FACT_VISITS (got #{ann.first.to_s[0, 90].inspect})", fails)
  fact = fact_of.call(r)
  check(fact && rels_of.call(fact).sort == %w[DIM_DATES DIM_PROVIDERS DIM_SITES ENTITLEMENTS],
        "#{fx}: FACT_VISITS carries all 4 relationships (got #{rels_of.call(fact).sort.inspect})", fails)
  # Orientation: keys' sourceColumnId must live on the fact element.
  bad_keys = (fact['relationships'] || []).flat_map { |x| x['keys'] }.reject { |k| fact['colIds'].include?(k['sourceColumnId']) }
  check(bad_keys.empty?, "#{fx}: every relationship sourceColumnId lives on the fact (#{bad_keys.size} off-element)", fails)
  dims_carrying = r['elements'].select { |e| e['name'] =~ /DIM_|ENTITLEMENTS/ && e['kind'] != 'sql' }
                               .select { |e| rels_of.call(e).any? { |t| t.include?('FACT_VISITS') } }
  check(dims_carrying.empty?, "#{fx}: no dimension carries a relationship INTO the fact (got #{dims_carrying.map { |e| e['name'] }.inspect})", fails)
end
ovr = results['e-override']
check(ovr['warnings'].any? { |w| w =~ /set by factTable override/ && w =~ /DIM_DATES/i },
      'factTable override wins and is announced', fails)

puts 'Part 2 — helper ownership guards: no wrong-FROM SQL, off-fact groupings refuse loud'
e = results['e-worst']
wrong_from = e['elements'].select { |el| el['statement'].to_s =~ /FROM\s+\S*DIM_/i }
check(wrong_from.empty?, "no helper SQL selects FROM a dimension table (got #{wrong_from.map { |x| x['name'] }.inspect})", fails)
check(e['warnings'].any? { |w| w =~ /lives on related element|dimension-table column/i },
      'off-fact LOD/Top-N groupings are refused with an actionable warning', fails)

puts 'Part 3 — named gaps for un-wire-able relationships; fully-wired stays quiet'
# COMPOSED BEHAVIOR (an internal integration branch merge of #569's derivation ladder):
# a keyless pair whose tables share exactly ONE key-shaped column name is no
# longer a refuse — the ladder's name-inference rung recovers it (that IS the
# flattened-star fix), the wire is announced with a VERIFY warning, and gate
# 16's uniqueness probe validates it downstream via join-plan.json. What must
# never happen: a silent wire (no warning), a missing ledger record, or a
# leftover disconnected-tables refusal for a recoverable pair.
c = results['c-nokeys']
gaps = c['workbookPatterns'].select { |p| p['kind'] == 'unsupported' && p['name'] =~ /Object-model relationship/ }
check(gaps.size == 0, "no-keys-but-name-matched: both pairs are recovered by name-inference, no gaps (got #{gaps.size})", fails)
check(c['warnings'].none? { |w| w =~ /disconnected tables/i },
      'no-keys-but-name-matched: no disconnected-tables refusal for recoverable pairs', fails)
check(c['warnings'].count { |w| w =~ /no serialized join key.*inferred ".*_KEY".*VERIFY/ } == 2,
      'no-keys-but-name-matched: BOTH inferred wires are announced with a VERIFY warning (never silent)', fails)
c_fact = fact_of.call(c)
c_rels = (c_fact && c_fact['relationships']) || []
check(c_rels.map { |r| r['target'] }.sort == %w[DIM_DATES DIM_SITES] &&
      c_rels.all? { |r| r['derivedVia'] == 'name-inference' },
      "no-keys-but-name-matched: both edges attach to the elected fact with derivedVia name-inference " \
      "(got #{c_rels.map { |r| [r['target'], r['derivedVia']] }.inspect})", fails)
ccov = c['relationshipCoverage'] || {}
check(ccov['serialized'] == 2 && ccov['wired'] == 2 && (ccov['entries'] || []).length == 2,
      "no-keys-but-name-matched: coverage ledger records 2/2 wired (got #{ccov.reject { |k, _| k == 'entries' }.inspect})", fails)
p1 = results['partial']
check(p1['warnings'].none? { |w| w =~ /relationship\(s\) wired.*NOT wired/i },
      'computed-then-inferred: no partial-wire refusal summary — the computed pair is recovered by name-inference', fails)
check(p1['workbookPatterns'].none? { |p| p['kind'] == 'unsupported' && p['name'] =~ /computed-only-key/ },
      'computed-then-inferred: computed-only pair is recovered, not a named gap', fails)
check(p1['warnings'].any? { |w| w =~ /name-inference wired "DATE_KEY".*WIDER than Tableau/ },
      'computed-then-inferred: the dropped computed condition is called out as a WIDER-than-Tableau join', fails)
p_fact = fact_of.call(p1)
p_rels = (p_fact && p_fact['relationships']) || []
p_dates = p_rels.find { |r| r['target'] == 'DIM_DATES' }
p_sites = p_rels.find { |r| r['target'] == 'DIM_SITES' }
check(p_dates && p_dates['derivedVia'] == 'name-inference' && p_dates['partial'] == true && p_dates['droppedConditions'].to_i >= 1,
      'computed-then-inferred: DIM_DATES edge carries name-inference + partial/droppedConditions through pass-2 attachment', fails)
check(p_sites && p_sites['derivedVia'] == 'serialized' && p_sites['partial'] == false,
      'computed-then-inferred: DIM_SITES edge stays cleanly serialized (no partial bleed-over)', fails)
rg = results['range']
check(rg['warnings'].any? { |w| w =~ /non-equality operator/i } &&
      rg['workbookPatterns'].any? { |p| p['name'] =~ /non-equality-key/ },
      'range-only relationship: named gap + explicit non-equality warning', fails)
b = results['b-happy']
check(b['workbookPatterns'].none? { |p| p['name'] =~ /Object-model/ } &&
      b['warnings'].none? { |w| w =~ /disconnected|NOT wired/i },
      'fully-wired noodle: NO object-model gap entries, NO disconnect/partial warnings (false-trip budget)', fails)

puts 'Part 4 — structural entitlement-table RLS (owner-veto doctrine)'
%w[e-worst b-happy d2-userfn].each do |fx|
  ent = results[fx]['security'].select { |s| s['kind'] == 'rls-entitlement-table' }
  check(ent.size == 1, "#{fx}: exactly one rls-entitlement-table rule (got #{ent.size})", fails)
  next if ent.empty?
  rule = ent.first
  check(rule['elementName'].to_s =~ /ENTITLEMENTS/i, "#{fx}: rule names the entitlement element", fails)
  check(rule.dig('entitlement', 'identityColumn').to_s =~ /user.?email|see relationship/i,
        "#{fx}: rule carries the identity column (got #{rule.dig('entitlement', 'identityColumn').inspect})", fails)
  check(rule.dig('entitlement', 'strategies').to_a.size == 3,
        "#{fx}: Port strategies A/B/C present", fails)
  check(rule['note'].to_s =~ /NEVER auto-applied/i && rule['note'].to_s =~ /UNCONSTRAINED/i,
        "#{fx}: note states never-auto-applied + unconstrained-join risk", fails)
  check(results[fx]['warnings'].any? { |w| w =~ /Entitlement-table RLS pattern DETECTED/ },
        "#{fx}: loud detection warning", fails)
end
check(results['d2-userfn']['security'].select { |s| s['kind'] == 'rls-entitlement-table' }
        .first&.dig('entitlement', 'keys').to_a.any?,
      'd2: rule carries the fact↔entitlement key pair(s)', fails)
neg = results['neg-dimuser']
check(neg['security'].none? { |s| s['kind'] == 'rls-entitlement-table' },
      'NEGATIVE: a plain dim with a USER_NAME column + an RLS_LOOKUP-named table (no filter, no user function) does NOT trip', fails)
pure = results['pure-exprfilter']
prls = pure['security'].select { |s| s['kind'] == 'rls' }
check(prls.any?, 'pure expression datasource filter with USERNAME() emits a fact-local rls rule', fails)
check(pure['security'].none? { |s| s['kind'] == 'rls-entitlement-table' },
      'pure fact-local filter does not fabricate an entitlement rule', fails)

puts 'Part 5 — slash-named derived-column drops now WARN (name + rename fix)'
sl = results['slash']
slw = sl['warnings'].grep(%r{contains "/"})
check(slw.any? { |w| w =~ %r{Site /Region} && w =~ /Rename the column/ },
      "slash drop warning names the column + fix (got #{slw.first.to_s[0, 90].inspect})", fails)

puts 'Part 6 — single-DS controlId dedupe (near-identical parameter names)'
e_ctl = results['e-worst']['controls']
dupes = e_ctl.group_by { |ctl| ctl['controlId'] }.select { |_, v| v.size > 1 }
check(dupes.empty?, "no duplicate controlIds in the emitted model (got #{dupes.keys.inspect})", fails)
check(results['e-worst']['warnings'].any? { |w| w =~ /Duplicate controlId/ },
      'dedupe is loud (warning names the collision)', fails)

puts 'Part 7 — multi-datasource NOT-merged regression (owner veto)'
md = results['multi-ds']
names = md['elements'].map { |el| el['name'] }
check(names.any? { |n| n.include?('FACT_VISITS') } && names.any? { |n| n.include?('DIM_SITES') },
      "both independent datasources present as elements (got #{names.inspect})", fails)
check(md['warnings'].any? { |w| w =~ /multi-element data model|Multi-datasource workbook/i },
      'multi-element build announced (nothing silently dropped)', fails)

puts 'Part 8 — auto Sum metrics never collide with sibling column names (F4)'
auto_fact = fact_of.call(results['b-happy'])
auto_columns = (auto_fact['colDefs'] || []).map { |column| column['name'].to_s.downcase }.to_set
auto_metrics = auto_fact['metricDefs'] || []
collisions = auto_metrics.select { |metric| auto_columns.include?(metric['name'].to_s.downcase) }
check(collisions.empty?, "no fact column/metric name collisions (got #{collisions.map { |m| m['name'] }.inspect})", fails)
check(src.scan(/name:\s*_autoMetricName\(displayName\)/).length == 2,
      'both raw-measure auto-metric emitters use the collision-safe naming helper', fails)

puts 'Part 9 — role-played date dimension: one element instance per role (R3-1)'
rp = results['roleplay']
insts = rp['elements'].select { |e| e['name'].to_s =~ /\ADIM_DATES \((Admit|Discharge|Followup) Date\)\z/ }
check(insts.size == 3,
      "3 role instances with deterministic role names (got #{rp['elements'].map { |e| e['name'] }.inspect})", fails)
rfact = rp['elements'].find { |e| e['name'].to_s.include?('FACT_STAYS') && e['kind'] == 'warehouse-table' }
date_rels = (rfact && rfact['relationships'] || []).select { |r| r['target'].to_s.include?('DIM_DATES') }
check(date_rels.size == 3 && date_rels.map { |r| r['target'] }.uniq.size == 3,
      "fact carries exactly one relationship per role instance (got #{date_rels.map { |r| r['target'] }.inspect})", fails)
check(date_rels.all? { |r| (r['keys'] || []).size == 1 } &&
      date_rels.map { |r| r.dig('keys', 0, 'sourceColumnId') }.uniq.size == 3,
      'each role relationship keys once, on its OWN fact FK', fails)
drv = rp['elements'].find { |e| e['kind'] == 'table' && e['name'].to_s =~ /View\z/ }
drv_refs = (drv && drv['colDefs'] || []).map { |c| c['formula'].to_s }.grep(%r{/DIM_DATES \(})
check(drv_refs.any? && %w[Admit Discharge Followup].all? { |x| drv_refs.any? { |f| f.include?("(#{x} Date)/") } },
      '[Base/REL/Field] refs resolve through each role-named relationship (own instance)', fails)
check(rp['workbookPatterns'].none? { |p| p['name'].to_s =~ /role-ambiguous/ },
      'roleplay: no false role-ambiguous gap when metadata identifies each instance', fails)

amb = results['roleplay-ambiguous']
afact = amb['elements'].find { |e| e['name'].to_s.include?('FACT_STAYS') && e['kind'] == 'warehouse-table' }
check((afact && afact['relationships'] || []).none? { |r| r['target'].to_s.include?('DIM_DATES') },
      'ambiguous role attribution: NO date relationship wired (no silent instance-0 collapse)', fails)
check(amb['workbookPatterns'].count { |p| p['name'].to_s =~ /role-ambiguous/ } == 3,
      "ambiguous: all 3 role joins land as named role-ambiguous gaps (got #{amb['workbookPatterns'].map { |p| p['name'] }.inspect})", fails)
check(amb['warnings'].any? { |w| w =~ /role attribution AMBIGUOUS/ }, 'ambiguous: loud refuse warning', fails)

ck = results['roleplay-calckey']
cfact = ck['elements'].find { |e| e['name'].to_s.include?('FACT_STAYS') && e['kind'] == 'warehouse-table' }
ckcol = (cfact && cfact['colDefs'] || []).find { |c| c['formula'] == 'Date([Stay Start])' }
ckrel = (cfact && cfact['relationships'] || []).find { |r| r['target'].to_s.include?('DIM_DATES') }
check(ckcol && ckrel && ckrel.dig('keys', 0, 'sourceColumnId') == ckcol['id'],
      'computed DATE([col]) key wired via a synthesized calc key column on the fact', fails)
check(ck['warnings'].any? { |w| w =~ /wired via synthesized calc key/ }, 'calc-key wiring is announced', fails)
check(ck['workbookPatterns'].none? { |p| p['name'].to_s =~ /computed-only-key/ },
      'no computed-only-key gap when the wrapped column resolves (wire, not refuse)', fails)

puts
if fails.empty?
  puts "OK — object-model converter batch locked (#{results.size} fixtures)"
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
