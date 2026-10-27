#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-dm-column-index.rb — the data-model COLUMN INDEX carried in dm-readback.json.
#
# The workbook builder needs the data model's real column labels (and their types) to
# choose the master element, to emit formulas that resolve, and to pick a control kind.
# Both readback paths must therefore carry, per data-model element:
#     columnLabels  [label, ...]            (the existing contract the builder reads)
#     columnTypes   { label => 'datetime' } (Sigma value type: text/number/integer/datetime/...)
# sourced from GET /v2/dataModels/{id}/columns, EXHAUSTIVELY paginated (Sigma's default
# page is 50, so a bare first-page read silently truncates a wide data model — and made
# post-and-readback.rb's `error`-column guard blind past column 50).
#
# Offline: GET/POST are stubbed with `ruby -r` (only Sigma.request is replaced; the real
# shared client, pagination loop and scripts run unmodified).
#
# Run: ruby scripts/test-qs-dm-column-index.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

HERE    = __dir__
RUBY    = RbConfig.ruby
BUILDER = File.join(HERE, 'build-workbook-from-quicksight.rb')
$LOAD_PATH.unshift File.join(HERE, 'lib')
begin
  require 'dm_column_index'
rescue LoadError
  nil # section 1 reports the missing lib; sections 2-4 still run and fail on their own merits
end

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def entry(el, label, type = 'text')
  { 'elementId' => el, 'columnId' => "#{el}/#{label}", 'label' => label, 'formula' => "[T/#{label}]",
    'type' => { 'type' => type } }
end

puts 'test-qs-dm-column-index.rb'

# ---- 1. DmColumnIndex.enrich_readback! -------------------------------------------
if defined?(DmColumnIndex)
rb = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'pg', 'elements' => [
  { 'id' => 'el-a', 'name' => 'Orders', 'columns' => [{ 'id' => 'c1' }, { 'id' => 'c2' }] },
  { 'id' => 'el-b', 'name' => 'Lookup' }] }] }
entries = [entry('el-a', 'Order ID'), entry('el-a', 'Ship Date', 'datetime'), entry('el-a', 'Amount USD', 'number'),
           entry('el-b', 'Zip', 'text'), entry('el-gone', 'Orphan')]
DmColumnIndex.enrich_readback!(rb, entries)
a, b = rb['pages'][0]['elements']
ok 'columnLabels keep API order per element', a['columnLabels'] == ['Order ID', 'Ship Date', 'Amount USD']
ok 'columnTypes map label -> Sigma value type', a['columnTypes'] == { 'Order ID' => 'text', 'Ship Date' => 'datetime', 'Amount USD' => 'number' }
ok 'a second element gets its own index', b['columnLabels'] == ['Zip'] && b['columnTypes'] == { 'Zip' => 'text' }
ok 'entries for elements not in the readback are ignored', rb.to_s !~ /Orphan/
ok 'type_of reads the index case-insensitively on the type', DmColumnIndex.type_of(a, 'Ship Date') == 'datetime' &&
                                                                  DmColumnIndex.type_of(a, 'Nope').nil?
ok 'an empty/missing entry list leaves the readback untouched',
   (r2 = { 'pages' => [{ 'elements' => [{ 'id' => 'x' }] }] }
    DmColumnIndex.enrich_readback!(r2, []); r2 == { 'pages' => [{ 'elements' => [{ 'id' => 'x' }] }] })
else
  ok 'scripts/lib/dm_column_index.rb exists (DmColumnIndex)', false
end

# ---- 2. post-and-readback.rb paginates /columns and persists the index -------------
STUB = <<~'RUBY'
  # replace only Sigma.request: POST/GET spec + a PAGED /columns endpoint
  require ENV.fetch('QS_SIGMA_REST')
  module Sigma
    PAGES = JSON.parse(File.read(ENV.fetch('QS_COLUMN_PAGES')))
    def self.request(method, path, **kw)
      case path
      when %r{\A/v2/dataModels/spec\z}
        JSON.generate('dataModelId' => 'dm-9')
      when %r{\A/v2/dataModels/dm-9/spec\z}
        JSON.generate('pages' => [{ 'id' => 'pg', 'name' => 'Data', 'elements' => [
          { 'id' => 'el-1', 'kind' => 'table', 'name' => 'Orders' }] }])
      when %r{\A/v2/dataModels/dm-9/columns}
        token = path[/[?&]page=([^&]+)/, 1] || '0'
        page = PAGES.fetch(token.to_i)
        body = { 'entries' => page }
        body['nextPage'] = (token.to_i + 1).to_s if token.to_i + 1 < PAGES.size
        body
      else
        raise "unexpected request #{method} #{path}"
      end
    end
  end
RUBY

def run_post_and_readback(dir, pages)
  File.write(File.join(dir, 'stub.rb'), STUB)
  File.write(File.join(dir, 'pages.json'), JSON.generate(pages))
  File.write(File.join(dir, 'dm-spec.json'), JSON.generate('name' => 'Synthetic DM', 'schemaVersion' => 1, 'pages' => []))
  env = { 'QS_SIGMA_REST' => File.join(HERE, 'lib', 'sigma_rest'), 'QS_COLUMN_PAGES' => File.join(dir, 'pages.json') }
  # Test harness: runs a fixed script under test against temp-dir inputs; no user input reaches the command.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture3(env, RUBY, "-r#{File.join(dir, 'stub.rb')}", File.join(HERE, 'post-and-readback.rb'),
                 '--type', 'datamodel', '--spec', File.join(dir, 'dm-spec.json'),
                 '--out', File.join(dir, 'dm-readback.json'), '--workdir', dir)
end

Dir.mktmpdir('qs-colidx') do |dir|
  # 120 columns across 3 pages (50/50/20): Sigma's default page size is 50.
  cols = (1..120).map { |i| entry('el-1', "Col #{i}", i == 7 ? 'datetime' : 'text') }
  _o, err, st = run_post_and_readback(dir, cols.each_slice(50).to_a)
  ok 'post-and-readback.rb succeeds on a 3-page /columns listing', st.success?
  out = (JSON.parse(File.read(File.join(dir, 'dm-readback.json'))) rescue {})
  el = (out['pages'] || []).flat_map { |p| p['elements'] || [] }.find { |e| e['id'] == 'el-1' } || {}
  ok 'every one of 120 labels is read back (not just the first 50)', (el['columnLabels'] || []).size == 120
  ok 'columnTypes carries the datetime column from a later position', el.dig('columnTypes', 'Col 7') == 'datetime'
  ok 'the clean guard reports ALL 120 columns', err.include?('120 columns clean')
end

Dir.mktmpdir('qs-colidx-err') do |dir|
  # an `error`-typed column on page 3 — the old first-page-only guard never saw it
  cols = (1..100).map { |i| entry('el-1', "Col #{i}") } + [entry('el-1', 'Broken Col', 'error')]
  _o, err, st = run_post_and_readback(dir, cols.each_slice(50).to_a)
  ok 'an error column past column 50 now fails the guard (exit 2)', st.exitstatus == 2 && err.include?('Broken Col')
end

# ---- 3. the builder selects the master element from columnLabels ------------------
def analysis
  col = ->(c) { { 'DataSetIdentifier' => 'orders', 'ColumnName' => c } }
  { 'Name' => 'Synthetic Orders', 'AnalysisId' => 'syn-1',
    'Definition' => { 'CalculatedFields' => [], 'ParameterDeclarations' => [], 'FilterGroups' => [],
      'Sheets' => [{ 'SheetId' => 's1', 'Name' => 'Overview',
        'Visuals' => [{ 'BarChartVisual' => { 'VisualId' => 'bar-1',
          'Title' => { 'FormatText' => { 'PlainText' => 'Amount by Region' } },
          'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
            'Category' => [{ 'CategoricalDimensionField' => { 'FieldId' => 'c1', 'Column' => col.('region') } }],
            'Values' => [{ 'NumericalMeasureField' => { 'FieldId' => 'v1', 'Column' => col.('amount'),
                           'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } } } }] }] } }
end

Dir.mktmpdir('qs-colidx-b') do |dir|
  # A reused data model's spec readback often has NAMELESS columns (name is optional); the
  # labels live in columnLabels. The wider unrelated element comes first and must lose.
  wide  = { 'id' => 'dm-wide', 'name' => 'Wide Unrelated', 'columns' => (1..9).map { |i| { 'id' => "w#{i}" } },
            'columnLabels' => (1..9).map { |i| "Wide #{i}" } }
  match = { 'id' => 'dm-orders', 'name' => 'Orders', 'columns' => [{ 'id' => 'o1' }, { 'id' => 'o2' }],
            'columnLabels' => %w[Region Amount] }
  rb2 = { 'dataModelId' => 'dm-1', 'reusedDataModel' => true, 'pages' => [{ 'id' => 'pg', 'elements' => [wide, match] }] }
  File.write(File.join(dir, 'analysis.json'), JSON.generate(analysis))
  File.write(File.join(dir, 'dm-readback.json'), JSON.generate(rb2))
  _o, e, st = Open3.capture3(RUBY, BUILDER, '--analysis', File.join(dir, 'analysis.json'),
                             '--dm-readback', File.join(dir, 'dm-readback.json'), '--folder-id', 'f',
                             '--out', File.join(dir, 'wb-spec.json'))
  ok 'builder runs on a labels-only reuse readback', st.success?
  master = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))['document']['elements'].find { |x| x['id'] == 'master' }
  ok 'master sources the element whose columnLabels cover the charted columns',
     master && master.dig('source', 'elementId') == 'dm-orders'
end

# ---- 4. wiring contracts for scripts that need live access -----------------------
msrc = File.read(File.join(HERE, 'migrate-quicksight.rb'), encoding: 'UTF-8')
ok 'migrate --reuse-dm reads /columns through Sigma.list_entries and enriches the readback',
   msrc.include?('Sigma.list_entries("/v2/dataModels/#{opts[:reuse_dm]}/columns")') &&
   msrc.include?('DmColumnIndex.enrich_readback!(dm_rb')
ok 'migrate phase-6 guard paginates the workbook /columns read',
   msrc.include?('Sigma.list_entries("/v2/workbooks/#{wb_id}/columns")') &&
   !msrc.match?(/Sigma\.request\(:get, "\/v2\/workbooks\/#\{wb_id\}\/columns"\)/)
psrc = File.read(File.join(HERE, 'post-and-readback.rb'), encoding: 'UTF-8')
ok 'post-and-readback.rb paginates its /columns read', psrc.include?('Sigma.list_entries(columns_path)')

puts
if $fail.zero?
  puts 'test-qs-dm-column-index.rb: ALL PASS'
else
  puts "test-qs-dm-column-index.rb: #{$fail} FAILURE(S)"
  exit 1
end
