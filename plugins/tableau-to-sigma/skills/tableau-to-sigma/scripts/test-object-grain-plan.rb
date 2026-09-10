#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression for single-datasource dashboards that mix logical-table grains.
# The DM converter emits a many-side derived view per child fact; the workbook
# router needs a deduplicated registry naming those views, the parent base, and
# a non-null relationship key for Tableau's generated Count-of-table measures.

require_relative 'mechanical-specs'

fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

employee_columns = [
  { 'id' => 'emp-id', 'name' => 'Employee Id', 'formula' => '[EMPLOYEES/EMPLOYEE_ID]' },
  { 'id' => 'dept', 'name' => 'Department', 'formula' => '[EMPLOYEES/DEPARTMENT]' }
]
absence_columns = [
  { 'id' => 'abs-id', 'name' => 'Absence Id', 'formula' => '[ABSENCE_RECORDS/ABSENCE_ID]' },
  { 'id' => 'abs-emp', 'name' => 'Employee Id', 'formula' => '[ABSENCE_RECORDS/EMPLOYEE_ID]' },
  { 'id' => 'abs-date', 'name' => 'Date', 'formula' => '[ABSENCE_RECORDS/DATE]' }
]
time_columns = [
  { 'id' => 'entry-id', 'name' => 'Entry Id', 'formula' => '[TIME_ENTRIES/ENTRY_ID]' },
  { 'id' => 'time-emp', 'name' => 'Employee Id', 'formula' => '[TIME_ENTRIES/EMPLOYEE_ID]' }
]

employees = {
  'id' => 'employees', 'kind' => 'table',
  'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ EMPLOYEES] },
  'columns' => employee_columns
}
absences = {
  'id' => 'absences', 'kind' => 'table',
  'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ ABSENCE_RECORDS] },
  'columns' => absence_columns,
  'relationships' => [{
    'id' => 'abs-employee', 'name' => 'EMPLOYEES', 'targetElementId' => 'employees',
    'keys' => [{ 'sourceColumnId' => 'abs-emp', 'targetColumnId' => 'emp-id' }]
  }]
}
time_entries = {
  'id' => 'time', 'kind' => 'table',
  'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ TIME_ENTRIES] },
  'columns' => time_columns,
  'relationships' => [{
    'id' => 'time-employee', 'name' => 'EMPLOYEES', 'targetElementId' => 'employees',
    'keys' => [{ 'sourceColumnId' => 'time-emp', 'targetColumnId' => 'emp-id' }]
  }]
}
absence_view = {
  'id' => 'absence-view', 'kind' => 'table', 'name' => 'Absence Records View',
  'source' => { 'kind' => 'table', 'elementId' => 'absences' },
  'columns' => absence_columns + [
    { 'id' => 'abs-dept', 'name' => 'Department', 'formula' => '[Absence Records/EMPLOYEES/Department]' }
  ]
}
time_view = {
  'id' => 'time-view', 'kind' => 'table', 'name' => 'Time Entries View',
  'source' => { 'kind' => 'table', 'elementId' => 'time' },
  'columns' => time_columns
}
# Real converter output can include duplicate physical-table helpers. The plan
# must collapse them onto the relationship-participating element.
employee_duplicate = {
  'id' => 'employees-copy', 'kind' => 'table',
  'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ EMPLOYEES] },
  'columns' => employee_columns.first(1)
}

model = {
  'pages' => [{
    'elements' => [employees, absences, time_entries, absence_view, time_view, employee_duplicate]
  }]
}
plan = MechanicalSpecs.object_grain_plan(model, default_element_name: 'Employees')
grains = plan && plan['datasources']

check(grains&.size == 3, "duplicate physical elements collapse to three logical grains (got #{grains&.size})", fails)
employee = grains&.find { |grain| grain['table'] == 'EMPLOYEES' }
absence = grains&.find { |grain| grain['table'] == 'ABSENCE_RECORDS' }
time = grains&.find { |grain| grain['table'] == 'TIME_ENTRIES' }
check(employee && employee['default'] && employee['caption'] == 'Employees',
      'unique parent uses its base element as the default source', fails)
check(absence && absence['caption'] == 'Absence Records View' && absence['count_key'] == 'Employee Id',
      'absence child uses its grain-preserving derived view + relationship count key', fails)
check(absence && %w[Absence\ Id Date Department].all? { |name| absence['columns'].include?(name) },
      'absence grain exposes child fields and related parent dimensions', fails)
check(time && time['caption'] == 'Time Entries View' && time['count_key'] == 'Employee Id',
      'second child fact gets an independent grain source', fails)

if fails.empty?
  puts 'OK — object-model grain plan'
  exit 0
end

warn "#{fails.size} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
