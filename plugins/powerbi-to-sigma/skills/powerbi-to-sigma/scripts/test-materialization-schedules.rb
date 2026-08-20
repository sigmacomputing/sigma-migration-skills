#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/materialization_schedules'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

puts "\n1. list follows nextPageToken with pageSize"
calls = []
request = lambda do |method, path, _payload|
  calls << [method, path]
  if path.include?('pageToken=next')
    { 'entries' => [{ 'elementId' => 'e2', 'schedule' => { 'cronSpec' => '0 2 * * *' } }] }
  else
    { 'entries' => [{ 'elementId' => 'e1', 'schedule' => { 'cronSpec' => '0 1 * * *' } }],
      'nextPageToken' => 'next' }
  end
end
entries = MaterializationSchedules.list('dm', request: request)
check.call(entries.map { |e| e['elementId'] } == %w[e1 e2], 'all schedule pages are collected')
check.call(calls[0][1].include?('pageSize=500') && calls[1][1].include?('pageToken=next'),
           'data-model pagination uses pageSize/pageToken')

puts "\n2. reconcile creates, preserves, and patches schedules"
requests = []
request = lambda do |method, path, payload|
  requests << [method, path, payload]
  if method == :get
    {
      'entries' => [
        { 'elementId' => 'same', 'schedule' => { 'cronSpec' => '0 2 * * *', 'timezone' => 'America/Chicago' } },
        { 'elementId' => 'change', 'schedule' => { 'cronSpec' => '0 1 * * *', 'timezone' => 'UTC' } }
      ]
    }
  else
    { 'schedule' => payload['schedule'] }
  end
end
actions = MaterializationSchedules.reconcile(
  data_model_id: 'dm',
  elements: [
    { 'id' => 'new', 'name' => 'New SQL' },
    { 'id' => 'same', 'name' => 'Same SQL' },
    { 'id' => 'change', 'name' => 'Changed SQL' }
  ],
  cron: '0 2 * * *',
  timezone: 'America/Chicago',
  request: request
)
check.call(actions.map { |a| a['status'] } == %w[created unchanged updated],
           'reconcile selects POST, no-op, and PATCH correctly')
check.call(requests.any? { |m, p, _| m == :post && p.include?('/elements/new/') },
           'missing schedule is created on the element endpoint')
check.call(requests.none? { |m, p, _| m != :get && p.include?('/elements/same/') },
           'matching schedule makes no write call')
check.call(requests.any? { |m, p, _| m == :patch && p.include?('/elements/change/') },
           'changed schedule is patched')

puts "\n3. permission and write-access failures are actionable"
denied = lambda do |method, _path, _payload|
  method == :get ? { 'entries' => [] } : raise('POST -> 403 not_permitted')
end
action = MaterializationSchedules.reconcile(
  data_model_id: 'dm', elements: [{ 'id' => 'e', 'name' => 'Expensive SQL' }],
  cron: '0 2 * * *', request: denied
).first
check.call(action['status'] == 'error', 'API failure is recorded, not swallowed')
check.call(action['remediation'].include?('Schedule materializations'), 'permission remediation is explicit')

puts "\n4. invalid schedules fail before API calls"
begin
  MaterializationSchedules.validate!(cron: '0 2 * * *', timezone: 'UTC')
  check.call(true, 'UTC is accepted as an IANA timezone')
rescue ArgumentError
  check.call(false, 'UTC is accepted as an IANA timezone')
end
begin
  MaterializationSchedules.validate!(cron: 'hourly')
  check.call(false, 'invalid cron rejected')
rescue ArgumentError
  check.call(true, 'invalid cron rejected')
end
begin
  MaterializationSchedules.validate!(cron: '0 2 * * *', timezone: 'CST')
  check.call(false, 'non-IANA timezone rejected')
rescue ArgumentError
  check.call(true, 'non-IANA timezone rejected')
end

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
