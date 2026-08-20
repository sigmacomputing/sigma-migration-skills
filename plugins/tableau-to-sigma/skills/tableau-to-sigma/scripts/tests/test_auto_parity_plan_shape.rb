# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../lib/code_rep'

SCRIPT = File.expand_path('../auto-parity-plan.rb', __dir__)
CLASSIFICATION = File.expand_path('../../refs/workbook-reader-classification.json', __dir__)

class TestAutoParityPlanShape < Minitest::Test
  def test_flat_workbook_elements_and_layout_owned_page_membership
    spec = {
      'document' => {
        'pages' => [{ 'id' => 'overview', 'name' => 'Executive Overview' }],
        'elements' => [
          { 'id' => 'master', 'kind' => 'table' },
          { 'id' => 'trend', 'kind' => 'line-chart' }
        ],
        'layout' => <<~XML
          <Page id="overview">
            <Element elementId="master"/>
            <Element elementId="trend"/>
          </Page>
        XML
      }
    }

    assert_equal %w[master trend],
                 Sigma::CodeRep.workbook_elements(spec).map { |element| element['id'] }
    assert_equal %w[master trend],
                 Sigma::CodeRep.workbook_elements_with_pages(spec)
                               .select { |_, page| page && page['id'] == 'overview' }
                               .map { |element, _| element['id'] }
    refute spec['document']['pages'].first.key?('elements')
  end

  def test_auto_parity_plan_uses_workbook_helpers
    source = File.read(SCRIPT)

    assert_match(/(?:Sigma::CodeRep|WorkbookCode)\.workbook_elements|WorkbookCode\.elements/,
                 source,
                 'auto-parity-plan must enumerate flat document.elements through a workbook helper')
    assert_match(/workbook_elements_with_pages|elements_for_page/,
                 source,
                 'page-scoped parity must derive page ownership from layout')
    refute_match(/\b(?:pg|page)\[['"]elements['"]\]/, source,
                 'workbook pages are metadata-only and must not be read as element owners')
  end

  def test_reader_classification_is_machine_readable_and_complete_for_confirmed_readers
    doc = JSON.parse(File.read(CLASSIFICATION))
    entries = Array(doc['readers'])
    by_path = entries.each_with_object({}) { |entry, out| out[entry.fetch('path')] = entry }

    %w[
      scripts/auto-parity-plan.rb
      scripts/export-chart-png.rb
      scripts/remap-wb-spec-to-dm-ids.rb
      scripts/migration-notes.rb
      scripts/lib/action_gates.rb
      scripts/lib/control_field_census.rb
      scripts/lib/datasource_filter_check.rb
      scripts/lib/style_normalize.rb
      scripts/scan-customer-style.rb
    ].each do |path|
      assert_equal 'workbook', by_path.fetch(path).fetch('classification'), path
    end

    entries.each do |entry|
      assert_includes %w[workbook data-model dual transitional adapter],
                      entry.fetch('classification')
      assert File.exist?(File.expand_path("../../#{entry.fetch('path')}", __dir__)),
             "classified path does not exist: #{entry.fetch('path')}"
    end
  end
end
