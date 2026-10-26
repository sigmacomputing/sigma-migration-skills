#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-reuse-dm-guard.rb — a stale <workdir>/dm-spec.json must never steer the
# data-model element choice when the workbook is built on a REUSED data model.
#
# The builder picks the master's DM element by INDEX: it scores the elements of
# --dm-spec, then takes the readback element at the winning index (the two lists are
# in the same order only when the readback was produced by POSTing that very spec).
# `migrate-quicksight.rb --reuse-dm` never writes dm-spec.json (only the new-model path
# does) but passed `--dm-spec` whenever the file existed, so a workdir left over from an
# earlier new-model run silently pointed the master at the wrong DM element.
#
# Offline: runs the REAL builder as a subprocess on a synthetic analysis.
#
# Run: ruby scripts/test-qs-reuse-dm-guard.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

HERE    = __dir__
BUILDER = File.join(HERE, 'build-workbook-from-quicksight.rb')
MIGRATE = File.join(HERE, 'migrate-quicksight.rb')
RUBY    = RbConfig.ruby

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

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

ORDERS  = { 'id' => 'dm-orders', 'kind' => 'table', 'name' => 'Orders',
            'columns' => [{ 'name' => 'Region' }, { 'name' => 'Amount' }] }.freeze
LOOKUP  = { 'id' => 'dm-lookup', 'kind' => 'table', 'name' => 'Unrelated Lookup',
            'columns' => [{ 'name' => 'Zzz Code' }] }.freeze

def readback(els, extra = {})
  { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'pg', 'name' => 'Data', 'elements' => els }] }.merge(extra)
end

# Stale file: a previous NEW-model run's spec, where the covering element was index 0.
STALE_SPEC = { 'pages' => [{ 'elements' => [
  { 'name' => 'Orders', 'columns' => [{ 'name' => 'Region' }, { 'name' => 'Amount' }] },
  { 'name' => 'Unrelated Lookup', 'columns' => [{ 'name' => 'Zzz Code' }] }] }] }.freeze

def build(dir, rb, with_dm_spec:)
  File.write(File.join(dir, 'analysis.json'), JSON.generate(analysis))
  File.write(File.join(dir, 'dm-readback.json'), JSON.generate(rb))
  File.write(File.join(dir, 'dm-spec.json'), JSON.generate(STALE_SPEC))
  args = [RUBY, BUILDER, '--analysis', File.join(dir, 'analysis.json'),
          '--dm-readback', File.join(dir, 'dm-readback.json'), '--folder-id', 'f',
          '--out', File.join(dir, 'wb-spec.json')]
  args += ['--dm-spec', File.join(dir, 'dm-spec.json')] if with_dm_spec
  # Test harness: runs a fixed script under test against temp-dir inputs; no user input reaches the command.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  _o, e, st = Open3.capture3(*args)
  abort "builder failed: #{e}" unless st.success?
  doc = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))['document']
  doc['elements'].find { |el| el['id'] == 'master' }.dig('source', 'elementId')
end

puts 'test-qs-reuse-dm-guard.rb'

Dir.mktmpdir('qs-reuse') do |dir|
  reuse_rb = readback([LOOKUP, ORDERS], 'reusedDataModel' => true)   # unrelated element FIRST

  ok 'control: with no dm-spec the master follows readback coverage (Orders)',
     build(dir, reuse_rb, with_dm_spec: false) == 'dm-orders'

  ok 'stale dm-spec + a REUSED data-model readback does not steer element choice (the bug)',
     build(dir, reuse_rb, with_dm_spec: true) == 'dm-orders'

  # the new-model path (readback written by post-and-readback.rb, no reuse marker) keeps
  # using dm-spec: here the spec order [Orders, Lookup] matches the readback order.
  new_rb = readback([ORDERS, LOOKUP])
  ok 'new-model readback still uses dm-spec index selection (unchanged behaviour)',
     build(dir, new_rb, with_dm_spec: true) == 'dm-orders'
end

# migrate-quicksight.rb is a top-level script that needs live Sigma/AWS access, so the
# guard on the argument it passes is asserted against its source (same technique as
# test-destination-resolver.rb / test-verify-complete.rb).
msrc = File.read(MIGRATE, encoding: 'UTF-8')
ok "migrate-quicksight.rb passes --dm-spec only on the new-model path",
   msrc =~ /build \+= \['--dm-spec', dm_spec\] if File\.exist\?\(dm_spec\) && !opts\[:reuse_dm\]/
ok 'migrate-quicksight.rb stamps the reused-data-model marker into the synthesized readback',
   msrc.include?("'reusedDataModel' => true")

puts
if $fail.zero?
  puts 'test-qs-reuse-dm-guard.rb: ALL PASS'
else
  puts "test-qs-reuse-dm-guard.rb: #{$fail} FAILURE(S)"
  exit 1
end
