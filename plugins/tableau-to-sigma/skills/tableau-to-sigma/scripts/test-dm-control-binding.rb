#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/dm_control_binding'

failures = []
check = lambda do |condition, message|
  failures << message unless condition
end

dm_elements = [
  { 'id' => 'dm-ctl-region', 'kind' => 'control', 'controlId' => 'Region-Pick' },
  { 'id' => 'dm-ctl-metric', 'kind' => 'control',
    'controlId' => 'ctl-parameter-17', 'name' => 'Metric Picker' },
  { 'id' => 'dm-table', 'kind' => 'table', 'name' => 'Orders' }
]
spec = {
  'pages' => [
    {
      'id' => 'page-dashboard',
      'elements' => [
        { 'id' => 'wb-region', 'kind' => 'control',
          'controlId' => 'ctl-param-region-pick-dashboard', 'name' => 'Region Pick' },
        { 'id' => 'wb-metric', 'kind' => 'control',
          'controlId' => 'ctl-parameter-17', 'name' => 'Metric Picker' },
        { 'id' => 'wb-filter', 'kind' => 'control',
          'controlId' => 'ctl-category', 'name' => 'Category' }
      ]
    }
  ]
}

result = DmControlBinding.bind!(
  spec, data_model_id: 'dm-123', data_model_elements: dm_elements
)
controls = spec['pages'][0]['elements']
region_target = controls[0]['parameters']&.first
metric_target = controls[1]['parameters']&.first

check.call(region_target == {
             'kind' => 'data-model',
             'dataModelId' => 'dm-123',
             'controlId' => 'Region-Pick'
           }, 'caption match binds a page-suffixed workbook control to the DM control')
check.call(metric_target && metric_target['controlId'] == 'ctl-parameter-17',
           'exact converter controlId match binds to the DM control')
check.call(!controls[2].key?('parameters'),
           'ordinary workbook filters do not gain a data-model parameter target')
check.call(result[:bound].length == 2 && result[:unmatched] == ['Category'],
           'audit distinguishes bound parameter controls from unmatched filters')

DmControlBinding.bind!(spec, data_model_id: 'dm-123', data_model_elements: dm_elements)
check.call(controls[0]['parameters'].length == 1,
           'binding is idempotent and does not duplicate parameters')

canonical = {
  'document' => {
    'elements' => [
      { 'id' => 'wb-region-2', 'kind' => 'control',
        'controlId' => 'ctl-param-region-pick', 'name' => 'Region Pick' }
    ]
  }
}
DmControlBinding.bind!(
  canonical, data_model_id: 'dm-123', data_model_elements: dm_elements
)
check.call(canonical.dig('document', 'elements', 0, 'parameters', 0, 'controlId') == 'Region-Pick',
           'canonical flat document.elements shape is supported')

if failures.empty?
  puts 'ALL PASS — workbook controls target matching data-model controls'
else
  warn failures.map { |failure| "FAIL: #{failure}" }.join("\n")
  exit 1
end
