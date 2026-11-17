#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-pbi-flip-gate.rb — offline unit tests for migrate-powerbi.rb Phase 6b
# (runtime control-flip proof) decision glue: lib/pbi_flip.rb + the shared
# lib/flip_gate.rb contract Phase 6b depends on. No live API.

require_relative 'lib/pbi_flip'
require_relative 'lib/flip_gate'
require_relative 'lib/pbi_flip_values'
require 'json'

$failures = 0
def check(cond, msg)
  if cond
    puts "  ok  #{msg}"
  else
    $failures += 1
    warn "  FAIL #{msg}"
  end
end

# --- FlipGate.decide contract (the live-probe path Phase 6b relies on) --------
puts 'FlipGate.decide:'
d, i = FlipGate.decide(0, [{ 'control' => 'c1', 'result' => 'PASS' }])
check(d == :ok && i[:passes] == ['c1'], 'rc=0 + PASS -> :ok')
d, i = FlipGate.decide(1, [{ 'control' => 'c1', 'result' => 'FAIL', 'note' => 'inert' }])
check(d == :fail && i[:fails] == [['c1', 'inert']], 'rc=1 + FAIL -> :fail with note')
d, = FlipGate.decide(1, [])
check(d == :error, 'rc=1 + no FAIL rows -> :error (abort, could not verify)')
d, = FlipGate.decide(2, [{ 'control' => 'c1', 'result' => 'SKIP', 'note' => 'date-range' }])
check(d == :advisory, 'rc=2 (nothing auto-probeable) -> :advisory')
d, = FlipGate.decide(0, [])
check(d == :advisory, 'rc=0 + no PASS rows -> :advisory')
d, = FlipGate.decide(99, nil)
check(d == :error, 'unknown rc / nil results -> :error')

# --- PbiFlip.recorded (offline recorded-evidence path) ------------------------
puts 'PbiFlip.recorded:'
d, i = PbiFlip.recorded([{ 'control' => 'c1', 'result' => 'PASS' }])
check(d == :ok && i[:passes] == ['c1'], 'recorded PASS -> :ok')
d, i = PbiFlip.recorded([{ 'control' => 'c1', 'result' => 'PASS' },
                         { 'control' => 'c2', 'result' => 'FAIL', 'note' => 'inert' }])
check(d == :fail && i[:fails] == [['c2', 'inert']], 'recorded FAIL beats PASS -> :fail')
d, = PbiFlip.recorded([])
check(d == :offline, 'recorded empty -> :offline (UNVERIFIED, do not hard-fail)')
d, = PbiFlip.recorded(nil)
check(d == :offline, 'recorded nil -> :offline')

# --- PbiFlip.outcome (decision -> summary + exit code) ------------------------
puts 'PbiFlip.outcome:'
st, line, ex = PbiFlip.outcome(:ok, { passes: %w[a b], fails: [], skips: [] })
check(st == :ok && ex.nil? && line.include?('2 control'), ':ok -> no exit, counts passes')
st, _, ex = PbiFlip.outcome(:fail, { passes: [], fails: [['c', 'inert']], skips: [] })
check(st == :fail && ex == 21, ':fail -> exit 21 (blocks migration)')
st, _, ex = PbiFlip.outcome(:error, nil)
check(st == :error && ex == 21, ':error -> exit 21 (fail-closed)')
st, _, ex = PbiFlip.outcome(:advisory, { passes: [], fails: [], skips: [['c', 'date']] })
check(st == :advisory && ex.nil?, ':advisory -> WARN, no exit')
st, _, ex = PbiFlip.outcome(:none, nil)
check(st == :none && ex.nil?, ':none (0 controls) -> pass, no exit')
st, _, ex = PbiFlip.outcome(:offline, nil)
check(st == :offline && ex.nil?, ':offline -> UNVERIFIED, no exit (never hard-fail an offline run)')

# --- PbiFlipValues (pbi shape: pick the flip value where the probe's own export lookup cannot) ----------------
# Root cause (Task 21x): probe-controls.rb reads a control's value list by exporting the control's SOURCE element and
# looking for the source column in that export. In the pbi shape the control's source is a helper (lookup) column of its
# first target chart (a KPI, bar, table ...), and a chart export carries only the displayed columns, so the lookup column
# is never in the export: "column X not in export of <chart> - pass --value" and every list control is SKIPped.
puts 'PbiFlipValues:'
dm = { 'pages' => [{ 'elements' => [
  { 'id' => 'd-cat', 'name' => 'Category', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH DIM_CATEGORY] },
    'columns' => [{ 'id' => 'inode-a/CATEGORY_KEY', 'formula' => '[DIM_CATEGORY/Category Key]', 'name' => 'CategoryKey' },
                  { 'id' => 'inode-a/CATEGORY_NAME', 'formula' => '[DIM_CATEGORY/Category Name]', 'name' => 'Category Name' }] },
  { 'id' => 'd-src', 'name' => 'Sales (source)', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH FACT_SALES] },
    'columns' => [{ 'id' => 'inode-b/CATEGORY_KEY', 'formula' => '[FACT_SALES/Category Key]', 'name' => 'CategoryKey' },
                  { 'id' => 'inode-b/CHANNEL', 'formula' => '[FACT_SALES/Channel]', 'name' => 'Channel' }] },
  { 'id' => 'd-sales', 'name' => 'Sales', 'source' => { 'kind' => 'table', 'elementId' => 'd-src' },
    'columns' => [{ 'id' => 's1', 'formula' => '[Sales (source)/CategoryKey]', 'name' => 'CategoryKey' },
                  { 'id' => 's2', 'formula' => '[Sales (source)/Channel]', 'name' => 'Channel' },
                  { 'id' => 's3', 'formula' => 'Lookup([Category/Category Name], [CategoryKey], [Category/CategoryKey])', 'name' => 'Category Name (Category)' },
                  { 'id' => 's4', 'formula' => 'Upper([Channel])', 'name' => 'Channel Upper' }] },
  { 'id' => 'd-sql', 'name' => 'Rolling', 'source' => { 'kind' => 'sql', 'statement' => 'select 1' },
    'columns' => [{ 'id' => 'r1', 'formula' => '[Custom SQL/X]', 'name' => 'X' }] }
] }] }
kpi = { 'id' => 'k1', 'kind' => 'kpi-chart', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'd-sales' },
        'columns' => [{ 'id' => 'kv', 'formula' => 'Sum([Sales/Quantity])', 'name' => 'Units' },
                      { 'id' => 'kc', 'formula' => '[Sales/Category Name (Category)]', 'name' => 'Category Name (Category)' },
                      { 'id' => 'kh', 'formula' => '[Sales/Channel]', 'name' => 'Channel' },
                      { 'id' => 'ku', 'formula' => '[Sales/Channel Upper]', 'name' => 'Channel Upper' },
                      { 'id' => 'kx', 'formula' => '[Rolling/X]', 'name' => 'X' }] }
ctl = lambda do |cid, col, type = 'list', mode = 'include', vals = []|
  { 'id' => "el-#{cid}", 'kind' => 'control', 'controlId' => cid, 'name' => cid, 'controlType' => type, 'mode' => mode, 'values' => vals,
    'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'k1' }, 'columnId' => col } }
end
wb = { 'elements' => [kpi, ctl.call('CategoryFilter', 'kc'), ctl.call('ChannelFilter', 'kh', 'list', 'include', ['Web']),
                      ctl.call('UpperFilter', 'ku'), ctl.call('XFilter', 'kx'), ctl.call('DateRange', 'kc', 'date-range'),
                      ctl.call('SwitchOn', 'kc', 'switch')] }
tg = PbiFlipValues.targets(wb, dm)
by = tg.each_with_object({}) { |t, h| h[t['control_id']] = t }
check(by['CategoryFilter'] && by['CategoryFilter']['fact'] == %w[DB SCH FACT_SALES] && by['CategoryFilter']['expr'] == %w[j1 CATEGORY_NAME] &&
      by['CategoryFilter']['joins'] == [{ 'alias' => 'j1', 'path' => %w[DB SCH DIM_CATEGORY], 'match' => 'CATEGORY_KEY', 'key' => %w[f CATEGORY_KEY] }],
      "a lookup column resolves to the dimension column joined to the FACT on the Lookup's keys: #{by['CategoryFilter'].inspect}")
check(by['ChannelFilter'] && by['ChannelFilter']['fact'] == %w[DB SCH FACT_SALES] && by['ChannelFilter']['expr'] == %w[f CHANNEL] &&
      by['ChannelFilter']['joins'].empty? && by['ChannelFilter']['defaults'] == ['Web'],
      "a plain fact column reads the fact directly (no join), with its saved selection: #{by['ChannelFilter'].inspect}")
check(by['UpperFilter']['skip'].to_s.include?('not a plain column'), "a computed column is UNVERIFIED with a reason: #{by['UpperFilter']['skip'].inspect}")
check(by['XFilter']['skip'].nil? && by['XFilter']['sql'] == 'select 1' && by['XFilter']['sql_column'] == 'X',
      "a Custom SQL (page summary) column is listed from its own statement: #{by['XFilter'].inspect}")
check(!by.key?('DateRange') && !by.key?('SwitchOn'), 'only list-type controls are picked here (the probe flips switches, and derives date ranges)')
q = PbiFlipValues.queries(tg, 'snowflake')
check(q['flip:CategoryFilter'] == 'SELECT j1."CATEGORY_NAME" AS "V" FROM "DB"."SCH"."FACT_SALES" f LEFT JOIN "DB"."SCH"."DIM_CATEGORY" j1 ON j1."CATEGORY_KEY" = f."CATEGORY_KEY" ' \
      'WHERE j1."CATEGORY_NAME" IS NOT NULL GROUP BY j1."CATEGORY_NAME" ORDER BY COUNT(*) DESC, 1 LIMIT 50' &&
      q['flip:ChannelFilter'] == 'SELECT f."CHANNEL" AS "V" FROM "DB"."SCH"."FACT_SALES" f WHERE f."CHANNEL" IS NOT NULL GROUP BY f."CHANNEL" ORDER BY COUNT(*) DESC, 1 LIMIT 50' &&
      q.keys.sort == %w[flip:CategoryFilter flip:ChannelFilter flip:XFilter],
      "values are listed THROUGH the fact, most frequent first, so a dimension member with no fact rows is never picked: #{q['flip:CategoryFilter']}")
check(q['flip:CategoryFilter'].index('FROM "DB"."SCH"."FACT_SALES"') && !q['flip:CategoryFilter'].include?('FROM "DB"."SCH"."DIM_CATEGORY"'), 'the FROM is the fact, never the bare dimension')
bq = PbiFlipValues.queries(tg, 'bigquery')
check(bq['flip:ChannelFilter'].include?('AS `V`') && !bq['flip:ChannelFilter'].include?('AS "V"'), 'the alias is quoted with the dialect (bigquery backticks)')
res = { 'flip:CategoryFilter' => { 'ok' => true, 'rows' => [{ 'V' => 'Tools' }, { 'V' => 'Toys' }] },
        'flip:ChannelFilter' => { 'ok' => true, 'rows' => [{ 'V' => 'Web' }, { 'V' => 'Store' }] } }
vals, skipped = PbiFlipValues.values(tg, res)
check(vals == { 'CategoryFilter' => 'Tools', 'ChannelFilter' => 'Store' } && PbiFlipValues.values(tg, { 'flip:CategoryFilter' => { 'ok' => true, 'rows' => [{ 'V' => 'Toys' }, { 'V' => 'Tools' }] } })[0]['CategoryFilter'] == 'Toys', "the flip value is the first warehouse value not in the saved selection: #{vals.inspect}")
check(skipped.map(&:first).sort == %w[UpperFilter XFilter], "controls with no value are returned with their reason: #{skipped.inspect}")
vals2, skipped2 = PbiFlipValues.values(tg, { 'flip:CategoryFilter' => { 'ok' => false, 'error' => 'boom' } })
check(vals2.empty? && skipped2.any? { |c, r| c == 'CategoryFilter' && r.include?('boom') } && skipped2.any? { |c, r| c == 'ChannelFilter' && r.include?('no value') },
      "a failed or missing warehouse result leaves the control for the probe, with the reason: #{skipped2.inspect}")
check(q['flip:XFilter'] == "SELECT \"X\" AS \"V\" FROM (\nselect 1\n) t WHERE \"X\" IS NOT NULL GROUP BY \"X\" ORDER BY COUNT(*) DESC, 1 LIMIT 50" &&
      PbiFlipValues.queries(tg, 'bigquery')['flip:XFilter'].include?("SELECT `X` AS `V` FROM (\nselect 1\n) t"),
      "a Custom SQL column is listed over the statement as a subquery, dialect-quoted: #{q['flip:XFilter']}")
tg_c = [{ 'control_id' => 'C', 'sql' => "select 1 as x -- trailing comment", 'sql_column' => 'X' }]
check(PbiFlipValues.queries(tg_c, 'snowflake')['flip:C'].include?("FROM (\nselect 1 as x -- trailing comment\n) t WHERE"),
      'a trailing -- line comment cannot swallow the closing paren of the subquery (the statement is on its own lines)')
dm_w = { 'pages' => [{ 'elements' => [{ 'id' => 'd-w', 'name' => 'Page', 'source' => { 'kind' => 'sql', 'statement' => "WITH a AS (SELECT 1)\nSELECT * FROM a;\n" },
                                       'columns' => [{ 'id' => 'w1', 'formula' => '[Custom SQL/REGION]', 'name' => 'Region' }] },
                                     { 'id' => 'd-bad', 'name' => 'Bad', 'source' => { 'kind' => 'sql', 'statement' => 'DELETE FROM t' },
                                       'columns' => [{ 'id' => 'b1', 'formula' => '[Custom SQL/X]', 'name' => 'X' }] }] }] }
wb_w = { 'elements' => [{ 'id' => 'k2', 'kind' => 'kpi-chart', 'columns' => [{ 'id' => 'a', 'formula' => '[Page/Region]', 'name' => 'Region' }, { 'id' => 'b', 'formula' => '[Bad/X]', 'name' => 'X' }] },
                        { 'id' => 'c1', 'kind' => 'control', 'controlId' => 'R', 'controlType' => 'list', 'values' => [], 'source' => { 'kind' => 'table', 'elementId' => 'k2', 'columnId' => 'a' } },
                        { 'id' => 'c2', 'kind' => 'control', 'controlId' => 'B', 'controlType' => 'list', 'values' => [], 'source' => { 'kind' => 'table', 'elementId' => 'k2', 'columnId' => 'b' } }] }
tw = PbiFlipValues.targets(wb_w, dm_w).each_with_object({}) { |t, h| h[t['control_id']] = t }
check(tw['R']['sql'] == "WITH a AS (SELECT 1)\nSELECT * FROM a" && tw['B']['skip'].to_s.include?('read-only'),
      "a WITH statement is accepted (trailing ; dropped); a non-SELECT statement is never run: #{tw.inspect}")
check(PbiFlipValues.args(vals) == ['--value', 'CategoryFilter=Tools', '--value', 'ChannelFilter=Store'], 'the values become probe-controls.rb --value arguments')

# Root cause (Task 21a2, live): a list control's helper column is mostly NOT a Lookup() calc column. It is a relationship-path
# reference the child element resolves through its relationships ([Sales/SKU/Product/Brand]), or a boolean wrapper
# (If(IsNull([x]), Null, If([x], "True", "False"))). Both fell to "no column ... on Sales" / "not a plain column" and left 9 of
# 10 live controls UNVERIFIED.
puts 'PbiFlipValues (relationship paths, boolean wrapper):'
rdm = { 'pages' => [{ 'elements' => [
  { 'id' => 'p-prod', 'name' => 'Product', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH DIM_PRODUCT] },
    'columns' => [{ 'id' => 'inode-p/PRODUCT_KEY', 'formula' => '[DIM_PRODUCT/Product Key]', 'name' => 'ProductKey' },
                  { 'id' => 'inode-p/BRAND', 'formula' => '[DIM_PRODUCT/Brand]', 'name' => 'Brand' },
                  { 'id' => 'inode-p/PRIVATE_LABEL', 'formula' => '[DIM_PRODUCT/Private Label]', 'name' => 'Private Label' }] },
  { 'id' => 'p-sku', 'name' => 'SKU', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH DIM_SKU] },
    'columns' => [{ 'id' => 'inode-s/SKU_KEY', 'formula' => '[DIM_SKU/Sku Key]', 'name' => 'SkuKey' },
                  { 'id' => 'inode-s/PRODUCT_KEY', 'formula' => '[DIM_SKU/Product Key]', 'name' => 'ProductKey' }],
    'relationships' => [{ 'id' => 'r2', 'name' => 'Product', 'targetElementId' => 'p-prod',
                          'keys' => [{ 'sourceColumnId' => 'inode-s/PRODUCT_KEY', 'targetColumnId' => 'inode-p/PRODUCT_KEY' }] }] },
  { 'id' => 'p-src', 'name' => 'Sales (source)', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH FACT_SALES] },
    'columns' => [{ 'id' => 'inode-f/SKU_KEY', 'formula' => '[FACT_SALES/Sku Key]', 'name' => 'SkuKey' }] },
  { 'id' => 'p-sales', 'name' => 'Sales', 'source' => { 'kind' => 'table', 'elementId' => 'p-src' },
    'columns' => [{ 'id' => 'c-sku', 'formula' => '[Sales (source)/SkuKey]', 'name' => 'SkuKey' }],
    'relationships' => [{ 'id' => 'r1', 'name' => 'SKU', 'targetElementId' => 'p-sku',
                          'keys' => [{ 'sourceColumnId' => 'c-sku', 'targetColumnId' => 'inode-s/SKU_KEY' }] }] }
] }] }
hk = { 'id' => 'k2', 'kind' => 'kpi-chart', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'p-sales' },
       'columns' => [{ 'id' => 'hb', 'formula' => '[Sales/SKU/Product/Brand]', 'name' => 'Brand (Product)' },
                     { 'id' => 'hp', 'formula' => 'If(IsNull([Sales/SKU/Product/Private Label]), Null, If([Sales/SKU/Product/Private Label], "True", "False"))', 'name' => 'Private Label (Product)' },
                     { 'id' => 'hn', 'formula' => '[Sales/SKU/Nope/Brand]', 'name' => 'Bad' }] }
rctl = lambda do |cid, col|
  { 'id' => "el-#{cid}", 'kind' => 'control', 'controlId' => cid, 'name' => cid, 'controlType' => 'list', 'mode' => 'include', 'values' => [],
    'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'k2' }, 'columnId' => col } }
end
rtg = PbiFlipValues.targets({ 'elements' => [hk, rctl.call('BrandFilter', 'hb'), rctl.call('PLFilter', 'hp'), rctl.call('BadFilter', 'hn')] }, rdm)
rby = rtg.each_with_object({}) { |t, h| h[t['control_id']] = t }
check(rby['BrandFilter'] && rby['BrandFilter']['fact'] == %w[DB SCH FACT_SALES] && rby['BrandFilter']['expr'] == %w[j2 BRAND] &&
      rby['BrandFilter']['joins'] == [{ 'alias' => 'j1', 'path' => %w[DB SCH DIM_SKU], 'match' => 'SKU_KEY', 'key' => %w[f SKU_KEY] },
                                      { 'alias' => 'j2', 'path' => %w[DB SCH DIM_PRODUCT], 'match' => 'PRODUCT_KEY', 'key' => %w[j1 PRODUCT_KEY] }],
      "a relationship-path column joins the fact through each hop: #{rby['BrandFilter'].inspect}")
check(rby['PLFilter'] && rby['PLFilter']['expr'] == %w[j2 PRIVATE_LABEL] && rby['PLFilter']['bool'] == true, "a boolean wrapper resolves to the wrapped column and is flagged: #{rby['PLFilter'].inspect}")
check(rby['BadFilter']['skip'].to_s.include?('Nope'), "an unknown relationship is UNVERIFIED with the relationship named: #{rby['BadFilter']['skip'].inspect}")
rq = PbiFlipValues.queries(rtg, 'snowflake')
check(rq['flip:BrandFilter'].include?('FROM "DB"."SCH"."FACT_SALES" f LEFT JOIN "DB"."SCH"."DIM_SKU" j1 ON j1."SKU_KEY" = f."SKU_KEY" LEFT JOIN "DB"."SCH"."DIM_PRODUCT" j2 ON j2."PRODUCT_KEY" = j1."PRODUCT_KEY" WHERE'),
      "the query chains the joins from the fact: #{rq['flip:BrandFilter']}")
rv, = PbiFlipValues.values(rtg, { 'flip:PLFilter' => { 'ok' => true, 'rows' => [{ 'V' => false }, { 'V' => true }] }, 'flip:BrandFilter' => { 'ok' => true, 'rows' => [{ 'V' => 'Acme' }] } })
check(rv['PLFilter'] == 'False' && rv['BrandFilter'] == 'Acme', "boolean warehouse values become the wrapper's True/False text: #{rv.inspect}")
rv2, = PbiFlipValues.values(rtg, { 'flip:PLFilter' => { 'ok' => true, 'rows' => [{ 'V' => 'true' }, { 'V' => 'FALSE' }] } })
check(rv2['PLFilter'] == 'True', "string true/FALSE are normalised too: #{rv2.inspect}")

# --- orchestrator wiring smoke: --skip-control-flip is a known flag -----------
puts 'orchestrator wiring:'
mp = File.join(__dir__, 'migrate-powerbi.rb')
src = File.read(mp)
check(src.include?("--skip-control-flip"), 'migrate-powerbi.rb declares --skip-control-flip')
check(src.include?('control_flip_required'), 'migrate-powerbi.rb stamps control_flip_required into migrate-state.json')
check(src.include?('Phase 6b'), 'migrate-powerbi.rb has a Phase 6b block')
check(src.include?("require_relative 'lib/pbi_flip'"), 'migrate-powerbi.rb loads lib/pbi_flip')
check(src.include?("require_relative 'lib/pbi_flip_values'") && src.include?('PbiFlipValues.args'), 'migrate-powerbi.rb picks flip values for the pbi shape')

if $failures.zero?
  puts "\ntest-pbi-flip-gate: ALL PASS"
  exit 0
else
  warn "\ntest-pbi-flip-gate: #{$failures} FAILURE(S)"
  exit 1
end
