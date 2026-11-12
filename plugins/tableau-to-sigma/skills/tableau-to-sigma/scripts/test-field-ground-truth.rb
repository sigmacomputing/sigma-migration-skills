#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require_relative 'lib/ground_truth_sql'

class FieldGroundTruthTest < Minitest::Test
  def test_null_selections_and_exclusions_preserve_the_sql_population
    context = { 'calcs' => {}, 'resolve_col' => ->(*) { 'T1.REGION' } }
    base = { 'kind' => 'list', 'column_caption' => 'Region', 'datatype' => 'string', 'members' => [] }
    cases = [
      [{ 'includes_null' => true }, 'T1.REGION IS NULL'],
      [{ 'members' => ['West'], 'includes_null' => true }, "(T1.REGION IN ('West') OR T1.REGION IS NULL)"],
      [{ 'members' => ['West'], 'exclude' => true }, "(T1.REGION NOT IN ('West') OR T1.REGION IS NULL)"],
      [{ 'exclude' => true, 'excludes_null' => true }, 'T1.REGION IS NOT NULL'],
      [{ 'members' => ['West'], 'exclude' => true, 'excludes_null' => true }, "T1.REGION NOT IN ('West') AND T1.REGION IS NOT NULL"]
    ]
    cases.each do |selection, expected|
      assert_equal expected, GroundTruthSql.filter_clause(base.merge(selection), context)['sql']
    end
  end

  def test_single_object_needs_no_join_but_missing_or_disconnected_objects_fail
    object = { 'id' => 'o1', 'caption' => 'FACT', 'fqn' => 'DB.SC.FACT' }
    result = GroundTruthSql.build_from_relationships({ 'objects' => [object], 'relationships' => [] }, {})
    assert_equal 'FROM DB.SC.FACT T1', result['sql']
    assert_equal ['FACT'], result['joined']
    missing = GroundTruthSql.build_from_relationships({ 'objects' => [object.merge('fqn' => nil)] }, {})
    assert missing['error']
    disconnected = GroundTruthSql.build_from_relationships({ 'objects' => [object, object.merge('id' => 'o2')] }, {})
    assert disconnected['error']
    assert_nil disconnected['sql']
  end

  def range(type, low, high = nil)
    GroundTruthSql.filter_clause(
      { 'kind' => 'number-range', 'column_caption' => 'DATE_COL', 'datatype' => type, 'min' => low, 'max' => high },
      { 'calcs' => {}, 'resolve_col' => ->(*) { 'T1.DATE_COL' } }
    )
  end

  def test_typed_range_literals_and_invalid_bounds
    assert_equal "T1.DATE_COL >= DATE '2025-02-01'", range('date', '2025-02-01')['sql']
    assert_equal "T1.DATE_COL >= TIMESTAMP '2025-02-01 12:30:00'", range('datetime', '2025-02-01T12:30:00')['sql']
    assert_equal 'T1.DATE_COL >= -1.5 AND T1.DATE_COL <= 12', range('real', -1.5, 12)['sql']
    [['date', '2025-02-30'], ['datetime', '2025-02-01 25:00:00'], ['real', '1 OR 1=1'],
     ['real', Float::NAN], ['date', "2025-02-01' --"]].each do |type, value|
      result = range(type, value)
      assert result['error'], [type, value, result].inspect
      assert_nil result['sql']
    end
  end

  def test_physical_field_identity_precedes_caption
    ds = { 'tables' => [{ 'name' => 'FACT', 'columns' => ['SUM_TOTAL'] }] }
    meta = { 'columns_by_guid' => { 'SUM_TOTAL' => { 'caption' => 'Friendly Total' } } }
    resolve = GroundTruthSql.column_resolver(ds, { 'FACT' => 'T1' }, meta)
    assert_equal 'T1.SUM_TOTAL', resolve.call('Friendly Total', 'SUM_TOTAL')
  end

  def test_catalog_identifiers_are_preserved_and_missing_or_ambiguous_fields_refused
    ds = { 'tables' => [{ 'name' => 'FACT', 'columns' => ['Sales Region', 'AMOUNT'] },
                        { 'name' => 'DIM', 'columns' => ['AMOUNT'] }] }
    resolve = GroundTruthSql.column_resolver(ds, { 'FACT' => 'T1', 'DIM' => 'T2' })
    assert_equal 'T1."Sales Region"', resolve.call('Sales Region')
    assert_nil resolve.call('Invented Caption')
    assert_nil resolve.call('AMOUNT')
    assert_equal 'T2.AMOUNT', resolve.call('AMOUNT (DIM)')
  end

  def test_complete_table_path_is_not_prefixed_with_connection_database
    doc = TwbXml.parse("<workbook><named-connection name='c'><connection dbname='DB1'/></named-connection><relation name='FACT' connection='c' table='[DB2].[SC].[FACT]'/></workbook>")
    relation = doc.elements['/workbook/relation']
    assert_equal 'DB2.SC.FACT', JoinPlan.twb_table_fqn(doc, relation)
    relation.attributes['table'] = '[SC].[FACT]'
    assert_equal 'DB1.SC.FACT', JoinPlan.twb_table_fqn(doc, relation)
    relation.attributes['table'] = '[A].[B].[C].[D]'
    assert_nil JoinPlan.twb_table_fqn(doc, relation)
  end
end
