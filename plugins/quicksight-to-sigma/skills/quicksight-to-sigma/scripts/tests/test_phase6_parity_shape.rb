# frozen_string_literal: true
#
# test_phase6_parity_shape.rb — behaviour regression for phase6-parity-quicksight.rb
# PASS 1/PASS 2 against the CURRENT workbook code-rep readback shape.
#
# Live GET /v2/workbooks/{id}/spec nests everything under `document`; workbook
# elements are a FLAT `document.elements` collection, pages are metadata only and the
# layout XML owns page membership (shared/lib/code_rep.rb). The script used to iterate
# `spec['pages'][*]['elements']`, so PASS 1 aborted with "no plannable chart elements"
# for every workbook the builder emits. The previous version of this file only grepped
# the script source for `Sigma::CodeRep.document(` and stayed green while PASS 1 was
# broken — these tests run the real script (offline, GET stubbed with -r) and assert on
# the plan it writes.
#
# Run: ruby scripts/tests/test_phase6_parity_shape.rb

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../lib/code_rep'

class TestPhase6ParityShape < Minitest::Test
  SCRIPTS = File.expand_path('..', __dir__)
  SCRIPT  = File.join(SCRIPTS, 'phase6-parity-quicksight.rb')
  RUBY    = RbConfig.ruby

  # ---- readback fixtures (synthetic) ------------------------------------------
  def col(id, name, formula = nil)
    { 'id' => id, 'name' => name, 'formula' => formula || "[Orders/#{name}]" }
  end

  def master
    { 'id' => 'master', 'kind' => 'table', 'name' => 'Orders',
      'source' => { 'dataModelId' => 'dm-1', 'elementId' => 'dm-orders', 'kind' => 'data-model' },
      'columns' => [col('m-1', 'Region'), col('m-2', 'Amount')] }
  end

  def bar(name = 'Amount by Region')
    { 'id' => 'bar-1', 'kind' => 'bar-chart', 'name' => name,
      'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => [col('d-1', 'Region', '[Orders/Region]'), col('v-1', 'Amount', 'Sum([Orders/Amount])')],
      'xAxis' => { 'columnId' => 'd-1' }, 'yAxis' => { 'columnIds' => ['v-1'] } }
  end

  def kpi(name = 'Total Amount')
    { 'id' => 'kpi-1', 'kind' => 'kpi-chart', 'name' => name,
      'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => [col('k-1', name, 'Sum([Orders/Amount])')], 'value' => { 'columnId' => 'k-1' } }
  end

  def table(id, name, cols = nil)
    { 'id' => id, 'kind' => 'table', 'name' => name,
      'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => cols || [col("#{id}-1", 'Order Id'), col("#{id}-2", 'Region'),
                            col("#{id}-3", 'Internal Key').merge('hidden' => true)] }
  end

  # Flat document in the shape the builder emits: hidden Data page owns the master.
  def flat_document(elements, content_ids)
    layout = +'<Page type="grid" id="page-data"><Element elementId="master"/></Page>'
    layout << %(<Page type="grid" id="page-dash">#{content_ids.map { |i| %(<Element elementId="#{i}"/>) }.join}</Page>)
    { 'schemaVersion' => 1, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'visibility' => 'hidden' },
                  { 'id' => 'page-dash', 'name' => 'Dash' }],
      'elements' => [master] + elements, 'layout' => layout, 'panels' => [], 'overlays' => [] }
  end

  def readback(document)
    { 'workbookId' => 'wb-test', 'name' => 'Synthetic (from QuickSight)', 'document' => document }
  end

  # ---- harness ----------------------------------------------------------------
  def with_workdir
    Dir.mktmpdir('qs-p6') do |dir|
      stub = File.join(dir, 'stub_get.rb')
      File.write(stub, <<~RUBY)
        # replace only the HTTP GET; everything else is the real shared client
        require #{File.join(SCRIPTS, 'lib', 'sigma_rest').inspect}
        module Sigma
          def self.request(_method, _path, **_kw)
            File.read(ENV.fetch('STUB_BODY'))
          end
        end
      RUBY
      yield dir, stub
    end
  end

  def pass1(dir, stub, body, extra = [])
    body_path = File.join(dir, 'get-body.json')
    File.write(body_path, JSON.generate(body))
    # Test harness: runs a fixed script under test against temp-dir inputs; no user input reaches the command.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, err, st = Open3.capture3({ 'STUB_BODY' => body_path }, RUBY, "-r#{stub}", SCRIPT,
                                  '--workdir', dir, '--workbook-id', 'wb-test', *extra)
    [out, err, st]
  end

  def plan(dir)
    JSON.parse(File.read(File.join(dir, 'parity-plan.json')))
  end

  # ---- adapter sanity (kept from the original file) -----------------------------
  def test_document_resolves_nested_readback
    rb = { 'workbookId' => 'w', 'document' => { 'pages' => [{ 'id' => 'p1' }] } }
    assert_equal [{ 'id' => 'p1' }], Sigma::CodeRep.document(rb)['pages']
    assert_nil rb['pages'], 'proves the old flat read was nil'
  end

  # ---- the regression: flat document.elements ----------------------------------
  def test_flat_elements_bar_and_kpi_are_planned
    with_workdir do |dir, stub|
      doc = flat_document([bar, kpi], %w[bar-1 kpi-1])
      out, err, st = pass1(dir, stub, readback(doc))
      assert st.success?, "PASS 1 must not abort on the flat shape: #{err}"
      kinds = plan(dir)['charts'].map { |c| c['kind'] }.sort
      assert_equal %w[bar-chart kpi-chart], kinds
      assert_match(/Amount by Region/, out)
    end
  end

  def test_legacy_page_nested_shape_still_plans
    with_workdir do |dir, stub|
      pages = [{ 'id' => 'page-data', 'name' => 'Data', 'visibility' => 'hidden', 'elements' => [master] },
               { 'id' => 'page-dash', 'name' => 'Dash', 'elements' => [bar, kpi] }]
      _out, err, st = pass1(dir, stub, { 'workbookId' => 'wb-test', 'pages' => pages })
      assert st.success?, err
      assert_equal 2, plan(dir)['charts'].size
    end
  end

  # ---- plain tables: profile checks -----------------------------------------------
  def test_all_table_workbook_plans_table_profile_checks
    with_workdir do |dir, stub|
      doc = flat_document([table('tbl-1', 'Order Detail'), table('tbl-2', 'Returned Orders')], %w[tbl-1 tbl-2])
      out, err, st = pass1(dir, stub, readback(doc))
      assert st.success?, "an all-table workbook must plan profile checks, not abort: #{err}"
      charts = plan(dir)['charts']
      assert_equal %w[table-profile table-profile], charts.map { |c| c['kind'] }
      assert_equal ['Order Detail', 'Returned Orders'], charts.map { |c| c['chart'] }
      refute(charts.any? { |c| c['sigma_element_id'] == 'master' }, 'hidden Data-page master is not a content table')
      first = charts.first
      assert_equal %w[tbl-1-1 tbl-1-2], first['sigma_column_ids'], 'hidden columns are not profiled'
      assert_match(/PROFILE/, out, 'plan must be labelled as a profile check, not value parity')
      assert_match(/COUNT\(\*\)/, out)
      assert_match(/COUNT\(DISTINCT/, out)
      assert_match(/value parity|not value/i, first['check'].to_s)
    end
  end

  def test_data_element_ids_from_builder_map_are_excluded
    with_workdir do |dir, stub|
      helper = table('helper-1', 'Hidden Helper')
      doc = flat_document([helper, table('tbl-1', 'Order Detail')], %w[helper-1 tbl-1])
      File.write(File.join(dir, 'wb-spec.map.json'), JSON.generate('dataElementIds' => %w[master helper-1]))
      _out, err, st = pass1(dir, stub, readback(doc))
      assert st.success?, err
      assert_equal ['Order Detail'], plan(dir)['charts'].map { |c| c['chart'] }
    end
  end

  # ---- visible "not planned" listing ---------------------------------------------
  def test_unplannable_content_elements_are_listed_not_silently_skipped
    with_workdir do |dir, stub|
      pivot = { 'id' => 'pv-1', 'kind' => 'pivot-table', 'name' => 'Pivot View', 'columns' => [col('p-1', 'Region')] }
      rmap  = { 'id' => 'rm-1', 'kind' => 'region-map', 'name' => 'Region Map', 'columns' => [col('r-1', 'Region')] }
      ring  = { 'id' => 'pg-1', 'kind' => 'progress', 'name' => 'Goal', 'value' => 'Sum([Orders/Amount])' }
      doc = flat_document([bar, pivot, rmap, ring], %w[bar-1 pv-1 rm-1 pg-1])
      out, err, st = pass1(dir, stub, readback(doc))
      assert st.success?, err
      np = plan(dir)['not_planned']
      assert_equal %w[Goal Pivot\ View Region\ Map].sort, np.map { |e| e['name'] }.sort
      assert(np.all? { |e| !e['reason'].to_s.empty? })
      assert_match(/NOT PLANNED/, out)
      assert_match(/Pivot View/, out)
    end
  end

  # ---- plan names are keys of parity-expected/actuals.json: they must be unique ----
  def test_duplicate_element_names_get_unique_plan_names
    with_workdir do |dir, stub|
      b2 = bar.merge('id' => 'bar-2')
      doc = flat_document([bar, b2, table('tbl-1', 'Amount by Region')], %w[bar-1 bar-2 tbl-1])
      _out, err, st = pass1(dir, stub, readback(doc))
      assert st.success?, err
      names = plan(dir)['charts'].map { |c| c['chart'] }
      assert_equal names.uniq.size, names.size, "duplicate plan names: #{names.inspect}"
      assert_equal 3, names.size
    end
  end

  def test_workbook_with_nothing_plannable_aborts_loudly
    with_workdir do |dir, stub|
      _out, err, st = pass1(dir, stub, readback(flat_document([], [])))
      refute st.success?
      assert_match(/no plannable/, err)
    end
  end

  # ---- PASS 2: profile checks flow through the verifier and are counted ------------
  def test_finalize_passes_profile_checks_and_counts_them
    with_workdir do |dir, stub|
      doc = flat_document([table('tbl-1', 'Order Detail'), bar], %w[tbl-1 bar-1])
      _out, err, st = pass1(dir, stub, readback(doc))
      assert st.success?, err
      prof_rows = [['row_count', 120], ['Order Id: non_null', 120], ['Order Id: distinct', 120],
                   ['Region: non_null', 118], ['Region: distinct', 4]]
      File.write(File.join(dir, 'parity-expected.json'),
                 JSON.generate('Order Detail' => prof_rows, 'Amount by Region' => [['North', 10.5]]))
      File.write(File.join(dir, 'parity-actuals.json'),
                 JSON.generate('Order Detail' => prof_rows, 'Amount by Region' => [['North', 10.5]]))
      _fo, ferr, fst = Open3.capture3(RUBY, SCRIPT, '--workdir', dir, '--finalize')
      assert fst.success?, ferr
      sum = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
      assert_equal 'PASS', sum['status']
      assert_equal 2, sum['charts_total']
      assert_equal 1, sum['profile_checks'], 'profile checks are counted separately from value parity'
      assert_equal 1, sum['value_parity_checks']
      assert_equal ['Order Detail'], sum['profile_names']
    end
  end

  def test_finalize_fails_when_a_profile_diverges
    with_workdir do |dir, stub|
      doc = flat_document([table('tbl-1', 'Order Detail')], %w[tbl-1])
      _out, err, st = pass1(dir, stub, readback(doc))
      assert st.success?, err
      File.write(File.join(dir, 'parity-expected.json'), JSON.generate('Order Detail' => [['row_count', 120]]))
      File.write(File.join(dir, 'parity-actuals.json'),  JSON.generate('Order Detail' => [['row_count', 80]]))
      _fo, _ferr, fst = Open3.capture3(RUBY, SCRIPT, '--workdir', dir, '--finalize')
      refute fst.success?, 'a row-count divergence must fail the gate'
      assert_equal 'FAIL', JSON.parse(File.read(File.join(dir, 'parity-final.json')))['status']
    end
  end
end
