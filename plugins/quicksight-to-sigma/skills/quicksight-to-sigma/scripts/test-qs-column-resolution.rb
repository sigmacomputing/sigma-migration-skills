#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-column-resolution.rb — master-column formulas must reference the columns the
# data-model element REALLY has, and anything that cannot be resolved must be reported.
#
# On --reuse-dm the data model can name its columns anything. The builder used to title-case
# the QuickSight dataset column name (`amount` -> `Amount`) and emit `[Orders/Amount]`
# even when the element's column is `Amount USD`; it left bare identifiers in calc fields
# (`channel = 'Online'`) unbracketed, emitted a `{calc}` reference as if it were a data-model
# column, and validate-spec.rb --dm-context checked only the element PREFIX of a ref, so none
# of it was caught before the POST.
#
# Covered here (all offline; the REAL builder and validator run as subprocesses):
#   1. column resolution — by source reference / column id first, display label second,
#      ignoring case and punctuation; NO fuzzy matching; ambiguity narrowed by the
#      converter's own display name; unresolved -> manual item
#   2. calc-field translation — bare identifiers, string literals and [refs] left alone,
#      calc -> calc references, NULL and same-signature scalar functions
#   3. validate-spec.rb --dm-context fails on a master ref to a column that does not exist
#   4. byte-identical output when the model's labels already equal the display-name guess
#
# Run: ruby scripts/test-qs-column-resolution.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

HERE      = __dir__
BUILDER   = File.join(HERE, 'build-workbook-from-quicksight.rb')
VALIDATOR = File.join(HERE, 'validate-spec.rb')
RUBY      = RbConfig.ruby
$LOAD_PATH.unshift File.join(HERE, 'lib')
require 'dm_column_index'

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def col(c)
  { 'DataSetIdentifier' => 'orders', 'ColumnName' => c }
end

def dim(fid, c);  { 'CategoricalDimensionField' => { 'FieldId' => fid, 'Column' => col(c) } }; end

def meas(fid, c, agg = 'SUM')
  { 'NumericalMeasureField' => { 'FieldId' => fid, 'Column' => col(c),
                                 'AggregationFunction' => { 'SimpleNumericalAggregation' => agg } } }
end

def bar(vid, title, cats, vals)
  { 'BarChartVisual' => { 'VisualId' => vid, 'Title' => { 'FormatText' => { 'PlainText' => title } },
                          'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
                            'Category' => cats, 'Values' => vals } } } } }
end

def analysis(calcs: [], visuals:)
  { 'Name' => 'Synthetic Orders', 'AnalysisId' => 'syn-1',
    'Definition' => { 'CalculatedFields' => calcs.map { |n, e| { 'DataSetIdentifier' => 'orders', 'Name' => n, 'Expression' => e } },
                      'ParameterDeclarations' => [], 'FilterGroups' => [],
                      'Sheets' => [{ 'SheetId' => 's1', 'Name' => 'Overview', 'Visuals' => visuals }] } }
end

# dataset OutputColumns for --discover-dir (the bare-identifier candidate set)
DATASET_COLS = %w[order_id region Channel ship_date order_date returned_at amount discount customer_id].freeze

# A reused model: the DM names its columns freely; each keeps its warehouse source.
#   source        -> label
#   order_id      -> Order ID          region     -> Region
#   channel       -> Sales Channel     amount     -> Amount USD
#   ship_date     -> Ship Date         returned_at-> Returned At
def entries(rows)
  rows.map do |src, label, type|
    { 'elementId' => 'dm-orders', 'columnId' => "inode-t/#{src}", 'label' => label,
      'formula' => "[ORDERS/#{src}]", 'type' => { 'type' => type || 'text' } }
  end
end

ROWS = [['order_id', 'Order ID'], ['region', 'Region'], ['channel', 'Sales Channel'], ['amount', 'Amount USD', 'number'],
        ['ship_date', 'Ship Date'], ['returned_at', 'Returned At', 'datetime']].freeze

def readback(rows = ROWS)
  rb = { 'dataModelId' => 'dm-1', 'reusedDataModel' => true,
         'pages' => [{ 'id' => 'pg', 'name' => 'Data', 'elements' => [{ 'id' => 'dm-orders', 'kind' => 'table', 'name' => 'Orders' }] }] }
  DmColumnIndex.enrich_readback!(rb, entries(rows))
  rb
end

# Build the analysis; return [spec_document, warnings_json, stderr, dir]
def build(analysis_h, rb, discover: true)
  dir = Dir.mktmpdir('qs-colres')
  File.write(File.join(dir, 'analysis.json'), JSON.generate(analysis_h))
  File.write(File.join(dir, 'dm-readback.json'), JSON.generate(rb))
  args = [RUBY, BUILDER, '--analysis', File.join(dir, 'analysis.json'), '--dm-readback', File.join(dir, 'dm-readback.json'),
          '--folder-id', 'f', '--out', File.join(dir, 'wb-spec.json')]
  if discover
    FileUtils.mkdir_p(File.join(dir, 'disc', 'datasets'))
    File.write(File.join(dir, 'disc', 'datasets', 'orders.json'), JSON.generate('DataSet' => {
      'DataSetId' => 'orders', 'PhysicalTableMap' => {},
      'OutputColumns' => DATASET_COLS.map { |c| { 'Name' => c, 'Type' => 'STRING' } } }))
    args += ['--discover-dir', File.join(dir, 'disc')]
  end
  _o, e, st = Open3.capture3(*args)
  abort "builder failed: #{e}" unless st.success?
  doc = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))['document']
  warns = JSON.parse(File.read(File.join(dir, 'wb-spec.warnings.json')))
  [doc, warns, e, dir]
end

def master(doc);  doc['elements'].find { |e| e['id'] == 'master' }; end
def mcol(doc, name); master(doc)['columns'].find { |c| c['name'] == name }; end
def mformula(doc, name); (c = mcol(doc, name)) && c['formula']; end

# => [stdout + stderr, status]   (ERROR lines go to stdout, warnings to stderr)
def validate(dir, rb_path = nil)
  # Test harness: runs a fixed script under test against temp-dir inputs; no user input reaches the command.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  o, e, st = Open3.capture3(RUBY, VALIDATOR, '--type', 'workbook', '--dm-context', rb_path || File.join(dir, 'dm-readback.json'),
                            File.join(dir, 'wb-spec.json'))
  [o + e, st]
end

require 'fileutils'
puts 'test-qs-column-resolution.rb'

# ---- 1. plain-column resolution ---------------------------------------------------
doc, warns, _e, dir = build(
  analysis(visuals: [bar('b1', 'Amount by Region', [dim('c1', 'region')], [meas('v1', 'amount')])]), readback)
ok 'a renamed measure column resolves via its SOURCE reference (amount -> Amount USD)',
   mformula(doc, 'Amount') == '[Orders/Amount USD]'
ok 'the master keeps the display-name guess as the column NAME (downstream refs stay stable)',
   mformula(doc, 'Region') == '[Orders/Region]'
ok 'nothing unresolved => no manual items', (warns['manual'] || []).empty?
_vout, st = validate(dir)
ok 'validate-spec --dm-context passes when every master ref exists', st.success?
FileUtils.rm_rf(dir)

# ---- 2. calc-field translation -------------------------------------------------------
calcs = [
  ['Net Amount', "ifelse(channel = 'Online', {amount} * 0.9, {amount})"],
  ['Literal Guard', "ifelse({region} = 'amount channel [x]', 1, 0)"],
  ['Calc Reader', "ifelse({Net Amount} > 100, 'big', 'small')"],
  ['Scalars', "concat(toUpper({region}), ' - ', {channel})"],
  ['Null Probe', 'ifelse(isNull({returned_at}), NULL, 1)']
]
vis = [bar('b1', 'Reader', [dim('c1', 'Calc Reader')], [meas('v1', 'amount')]),
       bar('b2', 'Scalars', [dim('c2', 'Scalars')], [meas('v2', 'amount')]),
       bar('b3', 'Literal', [dim('c3', 'Literal Guard')], [meas('v3', 'Null Probe')])]
doc, warns, _e, dir = build(analysis(calcs: calcs, visuals: vis), readback)
ok 'a bare identifier naming a dataset column is bracketed and resolved',
   mformula(doc, 'Net Amount') == 'If([Orders/Sales Channel] = "Online", [Orders/Amount USD] * 0.9, [Orders/Amount USD])'
ok 'bare identifier matching is case-insensitive and does not emit UnresolvedIdentifier',
   (warns['manual'] || []).none? { |m| m['type'] == 'UnresolvedIdentifier' }
ok 'string literals (and a [ref]-looking literal) are left untouched',
   mformula(doc, 'Literal Guard') == 'If([Orders/Region] = "amount channel [x]", 1, 0)'
ok 'a {calc} reference becomes a SIBLING column ref, not a data-model column',
   mformula(doc, 'Calc Reader') == 'If([Net Amount] > 100, "big", "small")'
ok 'the referenced calc is landed on the master so the sibling ref resolves', !mcol(doc, 'Net Amount').nil?
ok 'same-signature scalar functions map to their Sigma names',
   mformula(doc, 'Scalars') == 'Concat(Upper([Orders/Region]), " - ", [Orders/Sales Channel])'
ok 'NULL becomes Null and isNull becomes IsNull',
   mformula(doc, 'Null Probe') == 'If(IsNull([Orders/Returned At]), Null, 1)'
verr, st = validate(dir)
ok 'the translated workbook passes the validator (function whitelist + refs)', st.success?
puts verr unless st.success?
FileUtils.rm_rf(dir)

# A title-cased calc may intentionally wrap the same lower-cased physical column.
shadow_calc = [['Amount', '{amount} * 2']]
shadow_visuals = [bar('calc', 'Calculated Amount', [dim('c1', 'region')], [meas('v1', 'Amount')]),
                  bar('raw', 'Raw Amount', [dim('c2', 'region')], [meas('v2', 'amount')])]
doc, warns, _e, dir = build(analysis(calcs: shadow_calc, visuals: shadow_visuals), readback)
ok 'a differently cased calc does not shadow its physical column reference',
   mformula(doc, 'Amount') == '[Orders/Amount USD] * 2'
ok 'the physical column reference does not produce a false calc cycle',
   (warns['manual'] || []).none? { |m| m['type'] == 'CalcCycle' }
FileUtils.rm_rf(dir)

# ---- 2b. bare calc reads participate in initial and per-visual master routing ---------------
multi_rb = {
  'dataModelId' => 'dm-1', 'reusedDataModel' => true,
  'pages' => [{ 'id' => 'pg', 'elements' => [
    { 'id' => 'dm-primary', 'kind' => 'table', 'name' => 'Primary' },
    { 'id' => 'dm-channel', 'kind' => 'table', 'name' => 'Channel Data' }
  ] }]
}
DmColumnIndex.enrich_readback!(multi_rb, [
  { 'elementId' => 'dm-primary', 'columnId' => 'p/region', 'label' => 'Region', 'formula' => '[P/region]' },
  { 'elementId' => 'dm-primary', 'columnId' => 'p/amount', 'label' => 'Amount', 'formula' => '[P/amount]' },
  { 'elementId' => 'dm-primary', 'columnId' => 'p/order_id', 'label' => 'Order Id', 'formula' => '[P/order_id]' },
  { 'elementId' => 'dm-channel', 'columnId' => 'c/channel', 'label' => 'Channel', 'formula' => '[C/channel]' },
  { 'elementId' => 'dm-channel', 'columnId' => 'c/amount', 'label' => 'Amount', 'formula' => '[C/amount]' }
])
bare_calc = [['Channel Bucket', "ifelse(channel = 'Online', 'Online', 'Other')"]]
calc_visual = bar('calc-only', 'By Channel Bucket', [dim('c1', 'Channel Bucket')], [meas('v1', 'amount')])
doc, _warns, _e, dir = build(analysis(calcs: bare_calc, visuals: [calc_visual]), multi_rb)
ok 'initial master selection includes bare columns read by a calc',
   master(doc).dig('source', 'elementId') == 'dm-channel'
FileUtils.rm_rf(dir)

visuals = [
  bar('primary-vis', 'By Region', [dim('p1', 'region')], [meas('p2', 'amount')]),
  calc_visual
]
doc, _warns, _e, dir = build(analysis(calcs: bare_calc, visuals: visuals), multi_rb)
calc_el = doc['elements'].find { |e| e['name'] == 'By Channel Bucket' }
calc_master = doc['elements'].find { |e| e['id'] == calc_el.dig('source', 'elementId') }
ok 'per-visual routing includes bare columns read by a calc',
   master(doc).dig('source', 'elementId') == 'dm-primary' &&
   calc_master.dig('source', 'elementId') == 'dm-channel'
FileUtils.rm_rf(dir)

# ---- 3. unresolved references: reported, not silent; validator fails ---------------------
vis = [bar('b1', 'Discount', [dim('c1', 'region')], [meas('v1', 'discount')])]   # `discount` is not in the model
doc, warns, err, dir = build(analysis(visuals: vis), readback)
manual = warns['manual'] || []
ok 'an unresolvable column is a manual item (type UnresolvedColumn) naming the column',
   manual.any? { |m| m['type'] == 'UnresolvedColumn' && m['reason'].to_s.include?('discount') }
ok 'the manual item names the data-model element it searched', manual.any? { |m| m['reason'].to_s.include?('Orders') }
ok 'the build prints the manual list at the end', err.include?('MANUAL') && err.include?('discount')
verr, st = validate(dir)
ok 'validate-spec --dm-context FAILS on a master ref to a column the element does not have',
   !st.success? && verr.include?('Discount') && verr.downcase.include?('not found')
FileUtils.rm_rf(dir)

# no fuzzy matching: `channel` is NOT matched to `Sales Channel` when the model's source is `sales_channel`
rows = [['order_id', 'Order ID'], ['region', 'Region'], ['sales_channel', 'Sales Channel'], ['amount', 'Amount USD', 'number']]
vis = [bar('b1', 'By Channel', [dim('c1', 'channel')], [meas('v1', 'amount')])]
doc, warns, _e, dir = build(analysis(visuals: vis), readback(rows))
ok 'NO fuzzy matching: `channel` is not guessed to be `Sales Channel`',
   (warns['manual'] || []).any? { |m| m['type'] == 'UnresolvedColumn' && m['reason'].to_s.include?('channel') }
FileUtils.rm_rf(dir)

# ambiguity: a fact FK and a join-leg column share the same source key; the converter's own
# display name ("Customer Id") breaks the tie, the suffixed leg column is never picked blindly
rows = [['customer_id', 'Customer Id'], ['customer_id', 'Customer Id (CUSTOMER_DIM)'], ['amount', 'Amount USD', 'number']]
vis = [bar('b1', 'By Customer', [dim('c1', 'customer_id')], [meas('v1', 'amount')])]
doc, warns, _e, dir = build(analysis(visuals: vis), readback(rows))
ok 'two labels sharing one source key resolve to the display-name match', mformula(doc, 'Customer Id') == '[Orders/Customer Id]' && (warns['manual'] || []).empty?
FileUtils.rm_rf(dir)

# ---- 4. validate-spec: no labels => skipped with a warning, never a false failure ---------
vis = [bar('b1', 'Amount by Region', [dim('c1', 'region')], [meas('v1', 'amount')])]
doc, _w, _e, dir = build(analysis(visuals: vis), readback)
bare = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'pg', 'elements' => [{ 'id' => 'dm-orders', 'kind' => 'table', 'name' => 'Orders' }] }] }
File.write(File.join(dir, 'bare-rb.json'), JSON.generate(bare))
verr, st = validate(dir, File.join(dir, 'bare-rb.json'))
ok 'an element with no column labels is not verified (warning, exit 0)', st.success? && verr.include?('no column labels')
FileUtils.rm_rf(dir)

# ---- 5. byte-identical when labels already equal the display-name guess -----------------
legacy = { 'dataModelId' => 'dm-1', 'pages' => [{ 'elements' => [{ 'id' => 'dm-orders', 'name' => 'Orders',
           'columns' => [{ 'name' => 'Region' }, { 'name' => 'Amount' }] }] }] }
indexed = { 'dataModelId' => 'dm-1', 'pages' => [{ 'elements' => [{ 'id' => 'dm-orders', 'name' => 'Orders',
            'columnLabels' => %w[Region Amount], 'columnTypes' => { 'Region' => 'text', 'Amount' => 'number' } }] }] }
vis = [bar('b1', 'Amount by Region', [dim('c1', 'region')], [meas('v1', 'amount')])]
d1, _w, _e, dir1 = build(analysis(visuals: vis), legacy)
d2, _w, _e, dir2 = build(analysis(visuals: vis), indexed)
ok 'a legacy name-only readback and an indexed readback with equal labels build the same spec',
   JSON.generate(d1) == JSON.generate(d2)
FileUtils.rm_rf(dir1); FileUtils.rm_rf(dir2)

puts
if $fail.zero?
  puts 'test-qs-column-resolution.rb: ALL PASS'
else
  puts "test-qs-column-resolution.rb: #{$fail} FAILURE(S)"
  exit 1
end
