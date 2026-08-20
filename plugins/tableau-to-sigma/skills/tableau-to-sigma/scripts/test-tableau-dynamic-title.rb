#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/tableau_dynamic_title'

failures = []
check = ->(condition, message) { failures << message unless condition }

calculations = [
  {
    'name' => '[Parameter 1 1]',
    'caption' => 'Metric_Switch_Parameter',
    'formula' => '"AOS60D"'
  }
]

source = 'Sales Order $ at Risk (Based on <[Parameters].[Parameter 1 1]>)'
expected =
  'Sales Order $ at Risk (Based on {{[ctl-param-metric_switch_parameter]}})'
check.call(
  TableauDynamicTitle.translate(source, calculations) == expected,
  'Tableau parameter token becomes a Sigma dynamic control reference'
)

caption_source = 'Sales Order $ at Risk (<[Parameters].[Metric_Switch_Parameter]>)'
check.call(
  TableauDynamicTitle.translate(caption_source, calculations) ==
    'Sales Order $ at Risk ({{[ctl-param-metric_switch_parameter]}})',
  'parameter captions resolve as well as internal parameter names'
)

unknown = 'Sales Order $ at Risk (<[Parameters].[Unknown Parameter]>)'
check.call(
  TableauDynamicTitle.translate(unknown, calculations) == unknown,
  'unknown parameter tokens remain visible for migration review'
)

plain = 'Sales Order $ at Risk'
check.call(
  TableauDynamicTitle.translate(plain, calculations) == plain,
  'static titles remain byte-identical'
)

# A Tableau PARAMETER is not a worksheet calculated field. Resolving a title
# against calculations alone shipped "Sales Orders - Last
# <[Parameters].[Parameter 1 3]> weeks" into a live element name.
parameters = [
  { 'name' => '[Parameter 1 3]', 'caption' => 'How Many Weeks',
    'datatype' => 'integer', 'default_value' => '12' }
]
weeks = 'Sales Orders - Last <[Parameters].[Parameter 1 3]> weeks'
check.call(
  TableauDynamicTitle.translate(weeks, [], parameters: parameters) ==
    'Sales Orders - Last {{[ctl-param-how-many-weeks]}} weeks',
  'a parameter resolves from the parameter list, not only from calculations'
)

# Dynamic text renders only against a control the WORKBOOK carries. The
# converter emits Tableau parameters as DATA-MODEL controls, which workbook
# dynamic text cannot reference.
notes = []
check.call(
  TableauDynamicTitle.translate(
    weeks, [], parameters: parameters, control_ids: [], notes: notes
  ) == 'Sales Orders - Last 12 weeks',
  'without a workbook control the parameter value is substituted'
)
check.call(
  notes.any? { |note| note.include?('How Many Weeks') && note.include?('data-model') },
  'the value substitution is reported rather than applied silently'
)
check.call(
  TableauDynamicTitle.translate(
    weeks, [], parameters: parameters, control_ids: ['ctl-param-how-many-weeks']
  ) == 'Sales Orders - Last {{[ctl-param-how-many-weeks]}} weeks',
  'a present workbook control keeps the title dynamic'
)

valueless = [{ 'name' => '[Parameter 9]', 'caption' => 'No Value' }]
token = 'Bottom <[Parameters].[Parameter 9]> stores'
check.call(
  TableauDynamicTitle.translate(token, [], parameters: valueless, control_ids: []) == token,
  'a parameter with no control and no value keeps its token for review'
)

check.call(
  TableauDynamicTitle.translate('<Sheet Name> detail', [], sheet_name: 'KPIs by Manager') ==
    'KPIs by Manager detail',
  'the sheet-name token resolves to the worksheet name'
)

check.call(
  TableauDynamicTitle.residual_tokens(weeks) == ['<[Parameters].[Parameter 1 3]>'],
  'residual_tokens finds a raw parameter token'
)
check.call(
  TableauDynamicTitle.residual_tokens('<Sheet Name> detail').length == 1,
  'residual_tokens finds a raw sheet-name token'
)
check.call(
  TableauDynamicTitle.residual_tokens('Revenue > Plan and Cost < Budget').empty?,
  'residual_tokens ignores ordinary comparison text'
)
check.call(
  TableauDynamicTitle.residual_tokens('Last {{[ctl-param-how-many-weeks]}} weeks').empty?,
  'residual_tokens ignores a translated Sigma dynamic reference'
)

puts
if failures.empty?
  puts 'ALL PASS'
  exit 0
end

puts "FAILURES (#{failures.length}):"
failures.each { |failure| puts "  - #{failure}" }
exit 1
