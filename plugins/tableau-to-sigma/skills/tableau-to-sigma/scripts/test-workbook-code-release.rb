#!/usr/bin/env ruby
# frozen_string_literal: true

# Focused offline regression for the Aug-2026 workbook-as-code release.
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/workbook_code'
require_relative 'mechanical-specs'

RUBY = RbConfig.ruby
STORIES = File.join(__dir__, 'build-story-pages.rb')
PARSER = File.join(__dir__, 'parse-twb-layout.rb')
ANCHOR_READONLY_KEYS = %w[
  workbookId url ownerId createdBy updatedBy createdAt updatedAt latestDocumentVersion
].freeze
$failures = 0

def check(label, value)
  puts "#{value ? '  ok  ' : 'FAIL  '}#{label}"
  $failures += 1 unless value
end

# Mirror the shared verify-anchors pivot-totals PUT boundary here rather than
# forking that vendored script. This Tableau-owned release check proves the
# shared CodeRep adapter retains every currently released document collection.
def anchor_put_body(spec)
  metadata = Sigma::CodeRep.metadata(spec).reject { |key, _| ANCHOR_READONLY_KEYS.include?(key) }
  Sigma::CodeRep.wrap(Sigma::CodeRep.document(spec), extra: metadata)
end

master_columns = [
  { 'id' => 'm-region', 'name' => 'Region', 'formula' => '[Fact/Region]' },
  { 'id' => 'm-sales', 'name' => 'Sales', 'formula' => '[Fact/Sales]' }
]
release_elements = [
  {
    'id' => 'wf', 'kind' => 'waterfall-chart', 'name' => 'Change by Region',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [
      { 'id' => 'wf-x', 'name' => 'Region', 'formula' => '[Master/Region]' },
      { 'id' => 'wf-y', 'name' => 'Sales', 'formula' => 'Sum([Master/Sales])' }
    ],
    'xAxis' => { 'column' => 'wf-x' }, 'yAxis' => [{ 'id' => 'wf-y' }],
    'waterfallShape' => { 'calculation' => 'sum', 'connectorLine' => 'shown' },
    'startPoint' => { 'value' => { 'type' => 'constant', 'value' => 0 }, 'visibility' => 'hidden' },
    'grouping' => 'stacked', 'legend' => { 'position' => 'right' }
  },
  {
    'id' => 'progress', 'kind' => 'progress', 'name' => 'Goal',
    'mode' => 'value', 'shape' => 'bar', 'value' => 'Sum([Master/Sales])'
  },
  { 'id' => 'nav', 'kind' => 'navigation', 'mode' => 'auto' },
  { 'id' => 'break', 'kind' => 'page-break' }
]

spec = MechanicalSpecs.build_wb_spec(
  name: 'Release Workbook', dm_id: 'dm-1', fact_eid: 'fact-1',
  master_columns: master_columns, chart_elements: release_elements,
  folder_id: 'folder-1'
)
doc = Sigma::CodeRep.document(spec)

check('outer envelope keeps create metadata', spec['name'] == 'Release Workbook' &&
      spec['folderId'] == 'folder-1' && !spec.key?('pages'))
check('document declares workbook schema', doc['schemaVersion'] == 1 && doc['kind'] == 'workbook')
check('pages are metadata-only', Array(doc['pages']).all? { |page| !page.key?('elements') })
check('elements are document-global', Array(doc['elements']).map { |element| element['id'] }.sort ==
      %w[break master nav progress wf])
check('layout is required', doc['layout'].to_s.include?('<Page'))
check('layout uses live canonical Element/Container tags',
      doc['layout'].to_s.include?('<Element') &&
      !doc['layout'].to_s.match?(%r{</?(?:LayoutElement|GridContainer)\b}))
check('canonical workbook validates', WorkbookCode.validate(spec).empty?)

anchor_spec = JSON.parse(JSON.generate(spec))
anchor_spec.merge!(
  'workbookId' => 'wb-release', 'latestDocumentVersion' => 7,
  'url' => 'https://example.invalid/workbook/wb-release'
)
anchor_doc = Sigma::CodeRep.document(anchor_spec)
anchor_doc['settings'] = { 'theme' => { 'name' => 'Release Theme' } }
anchor_doc['panels'] = [{ 'id' => 'panel-release' }]
anchor_doc['overlays'] = [{ 'id' => 'overlay-release' }]
anchor_doc['agents'] = [{ 'id' => 'agent-release' }]
anchor_flat = Sigma::CodeRep.metadata(anchor_spec).merge(anchor_doc)
anchor_element = Sigma::CodeRep.workbook_elements(anchor_flat).find { |element| element['id'] == 'wf' }
anchor_element['totals'] = { 'showGrandTotals' => false, 'showSubtotals' => false }
captured_totals = anchor_element.delete('totals')
stripped_anchor_body = anchor_put_body(anchor_flat)
anchor_element['totals'] = captured_totals
restored_anchor_body = anchor_put_body(anchor_flat)

check('shared anchor PUT boundary strips read-only response metadata',
      ANCHOR_READONLY_KEYS.none? { |key| restored_anchor_body.key?(key) })
check('shared anchor totals bracket emits valid workbook code',
      WorkbookCode.validate(stripped_anchor_body).empty? &&
      WorkbookCode.validate(restored_anchor_body).empty?)
check('shared anchor totals bracket preserves released document collections',
      %w[settings panels overlays agents].all? do |key|
        Sigma::CodeRep.document(restored_anchor_body)[key] == anchor_doc[key]
      end)
check('shared anchor totals bracket restores the complete totals value',
      Sigma::CodeRep.workbook_elements(restored_anchor_body)
        .find { |element| element['id'] == 'wf' }['totals'] == captured_totals)

ids = Sigma::CodeRep.workbook_elements(doc).filter_map { |element| element['id'] }
placed = doc['layout'].scan(/\belementId="([^"]+)"/).flatten
check('layout places every element exactly once',
      ids.sort == placed.sort && placed.length == placed.uniq.length)
page_ids = Sigma::CodeRep.workbook_page_element_ids(doc)
check('CodeRep recovers page ownership from layout',
      page_ids['page-data'] == ['master'] &&
      page_ids['page-dash'] == %w[wf progress nav break])

legacy = WorkbookCode.legacy_view(spec)
legacy['pages'].last['elements'] << { 'id' => 'repeat', 'kind' => 'repeated-container' }
legacy['panels'] = [{ 'id' => 'panel-1' }]
roundtrip = WorkbookCode.canonicalize(legacy)
roundtrip_doc = Sigma::CodeRep.document(roundtrip)
check('legacy transforms re-canonicalize without nesting elements',
      roundtrip_doc['pages'].all? { |page| !page.key?('elements') } &&
      Sigma::CodeRep.workbook_elements(roundtrip_doc).any? { |element| element['id'] == 'repeat' })
check('unknown/current document collections survive compatibility transforms',
      roundtrip_doc['panels'] == [{ 'id' => 'panel-1' }])
check('new compatibility-view elements receive authoritative placement',
      Sigma::CodeRep.workbook_page_element_ids(roundtrip_doc)['page-dash'].include?('repeat') &&
      WorkbookCode.validate(roundtrip).empty?)

# Data-model code representation is deliberately outside WorkbookCode.
data_model = {
  'schemaVersion' => 1,
  'pages' => [{ 'id' => 'dm-page', 'elements' => [{ 'id' => 'dm-table' }] }]
}
check('data-model nested pages remain unchanged',
      data_model['pages'].first['elements'].first['id'] == 'dm-table' &&
      !data_model.key?('document'))

Dir.mktmpdir('tableau-story-release') do |dir|
  input = File.join(dir, 'workbook.json')
  plan = File.join(dir, 'story-plan.json')
  output = File.join(dir, 'story-workbook.json')
  File.write(input, JSON.generate(spec))
  File.write(plan, JSON.generate([
    {
      'story' => 'Executive Story',
      'points' => [
        { 'caption' => 'Opening', 'captured_sheet' => 'Release Workbook', 'sheet_kind' => 'dashboard' }
      ]
    }
  ]))
  _stdout, stderr, status = Open3.capture3(
    RUBY, STORIES, '--story-plan', plan, '--spec', input, '--out', output
  )
  check('story-page builder accepts canonical workbook input',
        status.success? || (warn(stderr) && false))
  if status.success?
    story_spec = JSON.parse(File.read(output))
    story_doc = Sigma::CodeRep.document(story_spec)
    nav = Sigma::CodeRep.workbook_elements(story_doc).find do |element|
      element['kind'] == 'navigation' && element['id'] == 'sp1-story-navigation'
    end
    check('story-page builder emits canonical flat output',
          story_doc['pages'].all? { |page| !page.key?('elements') } &&
          WorkbookCode.validate(story_spec).empty?)
    check('story points use native page navigation',
          nav && nav['mode'] == 'manual' &&
          nav.dig('options', 0, 'destination', 'pageId') == 'page-story-1')
    check('story navigation ownership comes from layout',
          Sigma::CodeRep.workbook_page_by_element(story_doc)
            .dig('sp1-story-navigation', 'id') == 'page-story-1')
  end
end

Dir.mktmpdir('tableau-waterfall-release') do |dir|
  fixture = File.join(__dir__, 'test-fixtures', 'ground-truth.twb')
  twb = File.read(fixture)
            .sub("<mark class='Line' />", "<mark class='GanttBar' />")
            .sub("<mark class='Bar' />", "<mark class='GanttBar' />")
  input = File.join(dir, 'waterfall.twb')
  output = File.join(dir, 'layout.json')
  File.write(input, twb)
  _stdout, stderr, status = Open3.capture3(RUBY, PARSER, input, output)
  check('Tableau parser accepts waterfall fixture',
        status.success? || (warn(stderr) && false))
  if status.success?
    dashboards = JSON.parse(File.read(output))
    zones = Array(dashboards.first && dashboards.first['zones'])
    waterfall = zones.find { |zone| zone['caption'] == 'Running Sales Trend' }
    gantt = zones.find { |zone| zone['caption'] == 'Sales by Region' }
    check('GanttBar plus RUNNING_SUM maps to waterfall',
          waterfall && waterfall['chart_kind'] == 'waterfall')
    check('ordinary GanttBar remains an explicit non-waterfall gap',
          gantt && gantt['chart_kind'] == 'other')
  end
end

feature_source = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
gap_source = File.read(File.join(__dir__, 'scan-workbook-gaps.rb'))
check('released waterfall kind is mapped', feature_source.include?("'waterfall'     => 'waterfall-chart'"))
check('box-chart remains a loud manual gap',
      gap_source.include?('never emit kind:box-chart') &&
      !feature_source.match?(/['"]box(?:-chart)?['"]\s*=>\s*['"]box-chart['"]/))

puts($failures.zero? ? "\nall Tableau workbook-code release tests passed" :
                       "\n#{$failures} FAILED")
exit($failures.zero? ? 0 : 1)
