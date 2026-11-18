#!/usr/bin/env ruby
# frozen_string_literal: true

# Measures homed on a DAX calculated table. The pinned converter builds a calculated
# table's element in a branch that skips its measure loop, so those measures vanished
# with no warning naming them. End to end: pinned converter -> PbiCalcTableSql.apply!
# -> PbiCalcTableMeasures.translate/apply! -> DAX gate. fixture_01_mechanical plus a
# synthetic Targets table. Needs node. Run: ruby scripts/test-pbi-calc-table-measures.rb
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lib/pbi_native_query'
require_relative 'lib/pbi_calc_table_sql'
require_relative 'lib/pbi_calc_table_measures'
require_relative 'lib/dax_gate'
require_relative 'lib/pbi_external_measure'
require_relative 'lib/pbi_master_key'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

CONVERTER = File.expand_path('../converter/powerbi.mjs', __dir__)
FIXTURE = File.expand_path('../fixtures/fixture_01_mechanical.bim', __dir__)

def measure(name, dax)
  { 'name' => name, 'expression' => dax }
end

def calc_col(name, type, source = name)
  { 'name' => name, 'dataType' => type, 'type' => 'calculatedTableColumn', 'sourceColumn' => "[#{source}]",
    'isNameInferred' => true }
end

# fixture_01 + one calculated table homing `measures`.
def model_with(table_name, dax, columns, measures)
  bim = JSON.parse(File.read(FIXTURE))
  (bim['model'] || bim)['tables'] << {
    'name' => table_name, 'columns' => columns, 'measures' => measures,
    'partitions' => [{ 'name' => table_name, 'mode' => 'import', 'source' => { 'type' => 'calculated', 'expression' => dax } }]
  }
  bim
end

DATATABLE_DAX = 'DATATABLE("Dept", STRING, "Target", DOUBLE, {{"A", 1}, {"B", 2}})'
DATATABLE_COLS = [calc_col('Dept', 'string'), calc_col('Target', 'double')].freeze

# Runs the pinned converter on the TMSL; returns [dm, warnings].
def convert(tmsl, dir)
  input = File.join(dir, 'model.json')
  output = File.join(dir, 'out.json')
  shim = File.join(dir, 'convert.mjs')
  File.write(input, JSON.generate(PbiNativeQuery.normalize_tmsl(tmsl)))
  File.write(shim, <<~JS)
    import { readFileSync, writeFileSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    const { convertPowerBIToSigma } = await import(pathToFileURL(#{CONVERTER.to_json}).href);
    const out = convertPowerBIToSigma(JSON.parse(readFileSync(#{input.to_json}, 'utf8')), { connectionId: 'conn' });
    writeFileSync(#{output.to_json}, JSON.stringify({ model: out.model || out.sigmaDataModel || out, warnings: out.warnings || [] }));
  JS
  # Test harness: runs the temp shim this test writes, with no arguments.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  _o, err, status = Open3.capture3('node', shim)
  raise "converter failed: #{err}" unless status.success?

  r = JSON.parse(File.read(output))
  [r['model'], r['warnings']]
end

# The orchestrator's sequence after Phase 2: calculated tables, then their measures.
def pipeline(tmsl, dir, converter: CONVERTER)
  dm, warnings = convert(tmsl, dir)
  model = tmsl['model'] || tmsl
  PbiCalcTableSql.apply!(dm, model, warnings)
  before = { 'metrics' => all_metrics(dm).map { |m| m['name'] }, 'warnings' => warnings.dup }
  translations = PbiCalcTableMeasures.translate(model, converter, dir)
  result = PbiCalcTableMeasures.apply!(dm, model, warnings, translations)
  [dm, warnings, result, before, translations]
end

def elements(dm)
  dm['pages'].flat_map { |p| p['elements'] }
end

def all_metrics(dm)
  elements(dm).flat_map { |e| e['metrics'] || [] }
end

def metric(dm, name)
  elements(dm).each do |e|
    m = (e['metrics'] || []).find { |x| x['name'] == name }
    return [e, m] if m
  end
  [nil, nil]
end

def names_measure?(warnings, name)
  warnings.any? { |w| DaxGate.measure_of(w.to_s.gsub(/\s+/, ' ').strip) == name }
end

def asked?(warnings, dm, name)
  DaxGate.dax_questions(warnings, dm).any? { |q| DaxGate.measure_of(q['detail']) == name }
end

Dir.mktmpdir('pbi-calc-table-measures') do |dir|
  puts "\n1. DATATABLE measure SUM(Targets[Target]) becomes a metric on the Targets element"
  tmsl = model_with('Targets', DATATABLE_DAX, DATATABLE_COLS, [measure('Target Total', 'SUM(Targets[Target])')])
  dm, warnings, result, before, = pipeline(tmsl, dir)
  check.call(!before['metrics'].include?('Target Total') && !names_measure?(before['warnings'], 'Target Total'),
             'precondition: the converter drops the measure with no warning naming it')
  el, m = metric(dm, 'Target Total')
  check.call(el && el['name'] == 'Targets' && el.dig('source', 'kind') == 'sql', "metric is on the Targets Custom SQL element (#{el&.dig('name').inspect})")
  check.call(m && m['formula'] == 'Sum([Target])', "formula is the converter's translation (#{m&.dig('formula').inspect})")
  col_names = el ? el['columns'].map { |c| c['name'] } : []
  check.call(col_names.include?('Target'), "the formula's column is a column of that element (#{col_names.inspect})")
  check.call(DaxGate.realized_names(dm).include?('Target Total'), 'the DAX gate sees the measure as realized')
  check.call(!asked?(warnings, dm, 'Target Total'), 'no DAX gate question for a carried measure')
  check.call(result['attached'].map { |a| a['measure'] } == ['Target Total'] && result['reported'].empty?,
             "audit records the attach (#{result.inspect[0, 160]})")
  ids = elements(dm).flat_map { |e| [e['id']] + e['columns'].map { |c| c['id'] } + (e['metrics'] || []).map { |x| x['id'] } }
  check.call(ids.uniq.size == ids.size, 'every element, column and metric id is unique')

  puts "\n2. measures built on other measures: a sibling resolves, another table's measure is reported"
  tmsl = model_with('Targets', DATATABLE_DAX, DATATABLE_COLS, [
                      measure('Target Total', 'SUM(Targets[Target])'),
                      measure('Target Doubled', '[Target Total] * 2'),
                      measure('Target per Head', 'DIVIDE([Target Total], [Headcount])'),
                      measure('Per Head Doubled', '[Target per Head] * 2')
                    ])
  dm, warnings, result, = pipeline(tmsl, dir)
  _el, dbl = metric(dm, 'Target Doubled')
  check.call(dbl && dbl['formula'].include?('[Target Total]'), "sibling-measure ref kept (#{dbl&.dig('formula').inspect})")
  _el, head = metric(dm, 'Target per Head')
  check.call(head.nil?, 'a measure on another table ([Headcount] on EMPLOYEES) is not attached to Targets')
  check.call(names_measure?(warnings, 'Target per Head') && asked?(warnings, dm, 'Target per Head'),
             'the dropped cross-table measure is named in a warning the DAX gate asks about')
  check.call(warnings.any? { |w| w.include?('"Target per Head"') && w.include?('[Headcount]') && w =~ /cross-table/ },
             'the warning names the unresolved ref and reads as cross-table (coverage-gate cause)')
  _el, chained = metric(dm, 'Per Head Doubled')
  check.call(chained.nil? && asked?(warnings, dm, 'Per Head Doubled'), 'a measure on a dropped sibling is dropped and reported too')
  check.call(result['reported'].map { |r| r['measure'] }.sort == ['Per Head Doubled', 'Target per Head'],
             "audit lists both reported measures (#{result['reported'].map { |r| r['measure'] }.inspect})")

  puts "\n3. GENERATESERIES: a renamed column maps to the element's SQL output name"
  tmsl = model_with('Steps', 'GENERATESERIES(0, 20, 1)', [{ 'name' => 'Step', 'dataType' => 'int64', 'type' => 'calculatedTableColumn',
                                                           'sourceColumn' => '[Value]', 'isNameInferred' => false }],
                    [measure('Step Total', 'SUM(Steps[Step])'), measure('Picked Step', 'SELECTEDVALUE(Steps[Step], 10)')])
  dm, warnings, = pipeline(tmsl, dir)
  _el, st = metric(dm, 'Step Total')
  check.call(st && st['formula'] == 'Sum([Value])', "Steps[Step] -> the element column [Value] (#{st&.dig('formula').inspect})")
  _el, pk = metric(dm, 'Picked Step')
  check.call(pk && pk['formula'] == 'If(CountDistinct([Value]) = 1, Min([Value]), 10)', "SELECTEDVALUE carried (#{pk&.dig('formula').inspect})")
  check.call(!asked?(warnings, dm, 'Step Total') && !asked?(warnings, dm, 'Picked Step'), 'no gate question for carried measures')

  puts "\n4. DISTINCT table converted by PbiCalcTableSql keeps its measures"
  tmsl = model_with('Departments', 'DISTINCT(EMPLOYEES[DEPARTMENT])', [calc_col('Department', 'string', 'DEPARTMENT')],
                    [measure('Department Rows', 'COUNTROWS(Departments)')])
  dm, warnings, = pipeline(tmsl, dir)
  el, dr = metric(dm, 'Department Rows')
  check.call(el && el['name'] == 'Departments' && dr && dr['formula'] == 'Count()', "COUNTROWS -> Count() on Departments (#{dr.inspect})")

  puts "\n5. string literals with brackets are not read as refs"
  tmsl = model_with('Targets', DATATABLE_DAX, DATATABLE_COLS,
                    [measure('Bracket Dept', 'IF(MAX(Targets[Dept]) = "[Headcount]", 1, 0)')])
  dm, warnings, = pipeline(tmsl, dir)
  _el, br = metric(dm, 'Bracket Dept')
  check.call(br && br['formula'] == 'If(Max([Dept]) = "[Headcount]", 1, 0)', "literal left intact (#{br&.dig('formula').inspect})")
  formula, bad = PbiCalcTableMeasures.rewrite_refs('Concat("a ""[x]"" b", [dept], [Gone])', ['Dept'], {}, [])
  check.call(formula == 'Concat("a ""[x]"" b", [Dept], [Gone])' && bad == ['Gone'],
             "doubled quotes stay inside the literal; refs outside are resolved or reported (#{[formula, bad].inspect})")

  puts "\n6. an untranslatable measure is reported, never silently lost"
  tmsl = model_with('Targets', DATATABLE_DAX, DATATABLE_COLS, [
                      measure('Target Rank', 'RANKX(ALL(Targets[Dept]), SUM(Targets[Target]))'),
                      measure('Rank Doubled', '[Target Rank] * 2'),
                      measure('Rank Plus One', '[target rank] + 1'),
                      measure('Doubled Plus One', '[Rank Doubled] + 1'),
                      measure('Cross Doubled', '[Target Cross] * 2'),
                      measure('Target Cross', 'CALCULATE(SUM(Targets[Target]), CROSSFILTER(Targets[Dept], EMPLOYEES[DEPARTMENT], BOTH))')
                    ])
  dm, warnings, result, = pipeline(tmsl, dir)
  # The coverage gate's cross-table selector (migrate-powerbi.rb): a measure it names is stamped recoverable.
  cross_named = warnings.select { |w| w.to_s =~ /cross-table|different relationship path/i }.map { |w| DaxGate.measure_of(w) }
  ['Rank Plus One', 'Doubled Plus One', 'Cross Doubled'].each do |n|
    check.call(metric(dm, n)[1].nil? && names_measure?(warnings, n) && !cross_named.include?(n) &&
               warnings.any? { |w| w.include?("\"#{n}\"") && w.include?('dropped too') },
               "#{n}: dropped as the sibling of an untranslatable measure, never as cross-table")
  end
  check.call(warnings.any? { |w| w.include?('"Rank Plus One"') && w.include?('[target rank]') },
             'a sibling ref that differs only in case is matched to the sibling (the warning keeps the ref as written)')
  check.call(metric(dm, 'Target Rank')[1].nil? && asked?(warnings, dm, 'Target Rank'), 'RANKX measure is asked about by the DAX gate')
  check.call(metric(dm, 'Target Cross')[1].nil? &&
             warnings.any? { |w| w.start_with?('⛔') && w.include?('"Target Cross"') && w.include?('CROSSFILTER') } &&
             asked?(warnings, dm, 'Target Cross'), 'a CROSSFILTER measure is reported, not carried with the modifier silently dropped')
  check.call(warnings.any? { |w| w.include?('"Rank Doubled"') && w.include?('measure on calculated table') && w.include?('dropped too') } &&
             warnings.none? { |w| w.include?('"Rank Doubled"') && w.include?('cross-table') },
             'a sibling of an untranslatable measure is reported as a dropped sibling, not cross-table')
  check.call(result['reported'].map { |r| r['measure'] }.sort ==
             ['Cross Doubled', 'Doubled Plus One', 'Rank Doubled', 'Rank Plus One', 'Target Cross', 'Target Rank'],
             "audit records all six (#{result['reported'].map { |r| r['measure'] }.sort.inspect})")

  puts "\n7. a calculated table left as a placeholder: its measures are reported"
  tmsl = model_with('Odd', 'ADDCOLUMNS(SomethingElse, "X", 1)', [calc_col('X', 'int64')], [measure('Odd Total', 'SUM(Odd[X])')])
  dm, warnings, result, = pipeline(tmsl, dir)
  check.call(metric(dm, 'Odd Total')[1].nil?, 'nothing attached to a placeholder')
  check.call(warnings.any? { |w| w.start_with?('⛔') && w.include?('"Odd Total"') && w.include?('placeholder') },
             'a ⛔ warning names the measure and the placeholder')
  check.call(asked?(warnings, dm, 'Odd Total') && result['reported'].map { |r| r['measure'] } == ['Odd Total'],
             'the DAX gate asks about it and the audit records it')

  puts "\n8. no converter to translate with: every measure is reported"
  tmsl = model_with('Targets', DATATABLE_DAX, DATATABLE_COLS, [measure('Target Total', 'SUM(Targets[Target])')])
  dm, warnings, result, _before, translations = pipeline(tmsl, dir, converter: File.join(dir, 'missing.mjs'))
  check.call(translations.nil?, 'translate returns nil without a converter module')
  check.call(metric(dm, 'Target Total')[1].nil? && warnings.any? { |w| w.start_with?('⛔') && w.include?('"Target Total"') },
             'a ⛔ warning names the untranslated measure')
  check.call(asked?(warnings, dm, 'Target Total') && result['reported'].size == 1, 'the DAX gate asks about it')

  puts "\n9. a measure the DM already carries is left alone (idempotent)"
  tmsl = model_with('Targets', DATATABLE_DAX, DATATABLE_COLS, [measure('Target Total', 'SUM(Targets[Target])')])
  dm, warnings, = pipeline(tmsl, dir)
  model = tmsl['model'] || tmsl
  before = JSON.generate([dm, warnings])
  again = PbiCalcTableMeasures.apply!(dm, model, warnings, PbiCalcTableMeasures.translate(model, CONVERTER, dir))
  check.call(JSON.generate([dm, warnings]) == before && again['attached'].empty? && again['reported'].empty?,
             'a second apply! changes nothing')
  check.call(all_metrics(dm).count { |x| x['name'] == 'Target Total' } == 1, 'exactly one Target Total metric')

  puts "\n10. a ref to a column of the table that is not on the element is reported, not invented"
  tmsl = model_with('Targets', DATATABLE_DAX, DATATABLE_COLS, [measure('Target Total', 'SUM(Targets[Target])')])
  dm, warnings = convert(tmsl, dir)
  model = tmsl['model'] || tmsl
  PbiCalcTableSql.apply!(dm, model, warnings)
  targets = elements(dm).find { |e| e['name'] == 'Targets' }
  targets['columns'].reject! { |c| c['name'] == 'Target' }
  result = PbiCalcTableMeasures.apply!(dm, model, warnings, PbiCalcTableMeasures.translate(model, CONVERTER, dir))
  check.call(metric(dm, 'Target Total')[1].nil? && asked?(warnings, dm, 'Target Total'), 'not attached; the DAX gate asks')
  check.call(warnings.any? { |w| w.include?('"Target Total"') && w.include?('[Target]') && w.include?('Targets') },
             'the warning names the measure, the missing column and the table')
  check.call(result['reported'].size == 1, 'audit records it')

  puts "\n11a. --allow-incomplete-model: remote (EXTERNALMEASURE) measures on a calculated table stay #1002's Null gaps"
  tmsl = model_with('Targets', DATATABLE_DAX, DATATABLE_COLS, [
                      measure('Remote Target', 'EXTERNALMEASURE("Remote Target", DOUBLE, "DirectQuery to AS - Sales Model")'),
                      measure('Remote Doubled', '[Remote Target] * 2'),
                      measure('Target Total', 'SUM(Targets[Target])')
                    ])
  dm, warnings = convert(tmsl, dir)
  model = tmsl['model'] || tmsl
  # migrate-powerbi.rb order: REMOTE MEASURES on the converter output, calculated tables, then their measures.
  scan = PbiExternalMeasure.scan(model)
  els = elements(dm)
  home = PbiExternalMeasure.home_elements(els, model['tables'], PbiMasterKey.table_names(els, model['tables']))
  PbiExternalMeasure.neutralize!(dm, scan)
  PbiExternalMeasure.place_missing!(dm, scan, home: home)
  PbiCalcTableSql.apply!(dm, model, warnings)
  result = PbiCalcTableMeasures.apply!(dm, model, warnings, PbiCalcTableMeasures.translate(model, CONVERTER, dir))
  remote = all_metrics(dm).select { |x| ['Remote Target', 'Remote Doubled'].include?(x['name']) }
  check.call(remote.size == 2 && remote.all? { |x| x['formula'] == 'Null' }, "pointer and dependent are one Null metric each (#{remote.map { |x| [x['name'], x['formula']] }.inspect})")
  _el, tt = metric(dm, 'Target Total')
  check.call(tt && tt['formula'] == 'Sum([Target])', 'the local measure on the same table is still carried')
  check.call(result['attached'].map { |a| a['measure'] } == ['Target Total'] && result['reported'].empty?,
             "the remote measures are neither re-translated nor reported again (#{result.inspect[0, 160]})")

  puts "\n11. a model with no calculated-table measures is untouched"
  tmsl = JSON.parse(File.read(FIXTURE))
  dm, warnings = convert(tmsl, dir)
  model = tmsl['model'] || tmsl
  before = JSON.generate([dm, warnings])
  translations = PbiCalcTableMeasures.translate(model, CONVERTER, dir)
  result = PbiCalcTableMeasures.apply!(dm, model, warnings, translations)
  check.call(translations == {} && JSON.generate([dm, warnings]) == before && result['attached'].empty? && result['reported'].empty?,
             'no node run, no change')
end

puts "\n12. migrate-powerbi.rb wiring"
src = File.read(File.join(__dir__, 'migrate-powerbi.rb'), encoding: 'utf-8')
at = ->(needle) { src.index(needle) || Float::INFINITY }
check.call(src.include?("require 'pbi_calc_table_measures'"), 'the orchestrator requires the module')
check.call(at.call('PbiCalcTableSql.apply!(') < at.call('PbiCalcTableMeasures.apply!(') &&
           at.call('PbiCalcTableMeasures.apply!(') < at.call('DaxGate.calculated_table_issues(') &&
           at.call('PbiCalcTableMeasures.apply!(') < at.call('DaxGate.dax_questions('),
           'measures are carried after the Custom SQL conversion and before the calculated-table and DAX gates')
check.call(src.include?('PbiCalcTableMeasures.translate(calc_measure_model, CONV_MODULE, WORK)'),
           'translation uses the resolved converter module')

puts
if fails.empty?
  puts 'all calculated-table measure checks passed'
else
  puts "#{fails.size} check(s) FAILED"
  exit 1
end
