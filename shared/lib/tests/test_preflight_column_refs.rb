# frozen_string_literal: true

# R2: every column id an element's groupings / sort / pivot shelves point at
# must be declared in that element's own `columns[]`. The live Workbook Spec
# API 400s the whole POST otherwise, e.g.
#   elements[3].groupings[0].sort[0].columnId: references column 'c-dim'
#   which is not declared in columns.
# (powerbi-to-sigma 1.15.1: a pruned groupBy dimension left behind in
# groupings[0].sort.)
require 'minitest/autorun'
require_relative '../preflight_lint'

class TestPreflightColumnRefs < Minitest::Test
  LAYOUT = '<Page id="p1"><Element elementId="t1"/></Page>'

  def r2(spec)
    lint(spec).select { |message| message.start_with?('R2 ') }
  end

  def doc(*elements)
    { 'pages' => [{ 'id' => 'p1', 'name' => 'P1' }], 'elements' => elements, 'layout' => LAYOUT }
  end

  def grouped_table(groupings: nil, sort: nil, id: 't1')
    el = {
      'id' => id, 'kind' => 'table', 'name' => 'Summary',
      'columns' => [
        { 'id' => 'c-region', 'name' => 'Region', 'formula' => '[Source/Region]' },
        { 'id' => 'c-total', 'name' => 'Total', 'formula' => 'Sum([Source/Amount])' }
      ],
      'groupings' => groupings || [{ 'id' => 'g', 'groupBy' => ['c-region'], 'calculations' => ['c-total'] }]
    }
    el['sort'] = sort if sort
    el
  end

  def pivot(rows_by:, columns_by: [])
    {
      'id' => 'pv', 'kind' => 'pivot-table', 'name' => 'Deployments',
      'columns' => [
        { 'id' => 'p-cloud', 'name' => 'Cloud', 'formula' => '[Source/Cloud]' },
        { 'id' => 'p-env', 'name' => 'Environment', 'formula' => '[Source/Environment]' },
        { 'id' => 'p-count', 'name' => 'Deployments', 'formula' => 'CountDistinct([Source/Id])' }
      ],
      'values' => ['p-count'],
      'rowsBy' => rows_by,
      'columnsBy' => columns_by
    }
  end

  def test_fully_declared_grouped_table_is_clean
    spec = doc(grouped_table(
                 groupings: [{ 'id' => 'g', 'groupBy' => ['c-region'], 'calculations' => ['c-total'],
                               'sort' => [{ 'columnId' => 'c-total', 'direction' => 'descending' }] }],
                 sort: [{ 'columnId' => 'c-region', 'direction' => 'ascending' }]
               ))
    assert_empty r2(spec)
  end

  # The exact #992 failure: the dimension was pruned from columns + groupBy
  # but groupings[0].sort still points at it.
  def test_grouping_sort_on_pruned_dimension_names_path_and_id
    spec = doc(
      { 'id' => 'ctl', 'kind' => 'control', 'controlId' => 'ctl-id', 'controlType' => 'text', 'mode' => 'equals' },
      grouped_table(groupings: [{ 'id' => 'g', 'groupBy' => ['c-region'], 'calculations' => ['c-total'],
                                  'sort' => [{ 'columnId' => 'c-dropped', 'direction' => 'ascending' }] }])
    )
    errs = r2(spec)
    assert_equal 1, errs.size, errs.inspect
    assert_includes errs.first,
                    "elements[1].groupings[0].sort[0].columnId: references column 'c-dropped' " \
                    'which is not declared in columns.'
  end

  def test_group_by_undeclared
    spec = doc(grouped_table(groupings: [{ 'id' => 'g', 'groupBy' => %w[c-region c-gone], 'calculations' => ['c-total'] }]))
    assert_equal ["elements[0].groupings[0].groupBy[1]: references column 'c-gone'"],
                 r2(spec).map { |e| e[/elements\[.*?'c-gone'/] }
  end

  def test_calculations_undeclared
    spec = doc(grouped_table(groupings: [{ 'id' => 'g', 'groupBy' => ['c-region'], 'calculations' => %w[c-total c-gone] }]))
    assert_equal 1, r2(spec).size
    assert_includes r2(spec).first, "elements[0].groupings[0].calculations[1]: references column 'c-gone'"
  end

  def test_nested_grouping_level_index
    spec = doc(grouped_table(groupings: [
                               { 'id' => 'g1', 'groupBy' => ['c-region'], 'calculations' => ['c-total'] },
                               { 'id' => 'g2', 'groupBy' => ['c-gone'] }
                             ]))
    assert_includes r2(spec).first, "elements[0].groupings[1].groupBy[0]: references column 'c-gone'"
  end

  def test_element_level_sort_undeclared
    spec = doc(grouped_table(sort: [{ 'columnId' => 'c-region', 'direction' => 'ascending' },
                                    { 'columnId' => 'c-gone', 'direction' => 'descending' }]))
    assert_equal 1, r2(spec).size
    assert_includes r2(spec).first, "elements[0].sort[1].columnId: references column 'c-gone'"
  end

  def test_pivot_fully_declared_is_clean
    spec = doc(pivot(rows_by: [{ 'columnId' => 'p-cloud', 'sort' => { 'direction' => 'descending', 'by' => 'p-count' } }],
                     columns_by: [{ 'columnId' => 'p-env', 'sort' => { 'direction' => 'ascending' } }]))
    assert_empty r2(spec)
  end

  def test_pivot_sort_by_row_count_is_legal
    spec = doc(pivot(rows_by: [{ 'columnId' => 'p-cloud', 'sort' => { 'direction' => 'descending', 'by' => 'row-count' } }],
                     columns_by: [{ 'columnId' => 'p-env', 'sort' => { 'direction' => 'descending', 'by' => 'row-count' } }]))
    assert_empty r2(spec)
  end

  def test_pivot_shelf_column_undeclared
    spec = doc(pivot(rows_by: [{ 'columnId' => 'p-gone' }], columns_by: [{ 'columnId' => 'p-env' }, { 'columnId' => 'p-also-gone' }]))
    paths = r2(spec).map { |e| e[/elements\[\S+/] }
    assert_equal ['elements[0].rowsBy[0].columnId:', 'elements[0].columnsBy[1].columnId:'], paths
  end

  def test_pivot_sort_by_undeclared
    spec = doc(pivot(rows_by: [{ 'columnId' => 'p-cloud', 'sort' => { 'direction' => 'descending', 'by' => 'p-gone' } }],
                     columns_by: [{ 'columnId' => 'p-env', 'sort' => { 'direction' => 'descending', 'by' => 'p-gone2' } }]))
    errs = r2(spec)
    assert_equal 2, errs.size, errs.inspect
    assert_includes errs[0], "elements[0].rowsBy[0].sort.by: references column 'p-gone'"
    assert_includes errs[1], "elements[0].columnsBy[0].sort.by: references column 'p-gone2'"
  end

  # Guard: a shelf item's sort.by must never be reported against a later,
  # unsorted sibling. (Ruby already re-binds a block-local per iteration, so
  # this passes against the original `x = ... if cond` form too; the explicit
  # ternary in element_column_refs just makes that independence obvious.)
  def test_pivot_sort_by_does_not_leak_to_unsorted_sibling
    spec = doc(pivot(rows_by: [
                       { 'columnId' => 'p-cloud', 'sort' => { 'direction' => 'descending', 'by' => 'p-gone' } },
                       { 'columnId' => 'p-env' }
                     ]))
    errs = r2(spec)
    assert_equal 1, errs.size, errs.inspect
    assert_includes errs.first, "elements[0].rowsBy[0].sort.by: references column 'p-gone'"
  end

  # Another element's column with the same id does not satisfy the reference:
  # the API resolves these ids against the element's OWN columns.
  def test_column_declared_only_on_another_element_still_flags
    other = { 'id' => 'src', 'kind' => 'table', 'name' => 'Source',
              'columns' => [{ 'id' => 'c-gone', 'name' => 'Gone', 'formula' => '[T/Gone]' }] }
    spec = doc(other, grouped_table(groupings: [{ 'id' => 'g', 'groupBy' => ['c-gone'], 'calculations' => ['c-total'] }]))
    assert_includes r2(spec).first, "elements[1].groupings[0].groupBy[0]: references column 'c-gone'"
  end

  def test_legacy_page_nested_elements_report_page_path
    spec = { 'pages' => [{ 'id' => 'p1', 'name' => 'P1',
                           'elements' => [grouped_table(sort: [{ 'columnId' => 'c-gone' }])] }] }
    assert_includes r2(spec).first, "pages[0].elements[0].sort[0].columnId: references column 'c-gone'"
  end

  def test_cli_exits_nonzero_on_r2
    require 'json'
    require 'open3'
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'spec.json')
      File.write(path, JSON.generate(doc(grouped_table(sort: [{ 'columnId' => 'c-gone' }]))))
      _out, err, status = Open3.capture3(RbConfig.ruby, File.expand_path('../preflight_lint.rb', __dir__), path)
      refute status.success?
      assert_includes err, "R2 elements[0].sort[0].columnId: references column 'c-gone'"
    end
  end
end
