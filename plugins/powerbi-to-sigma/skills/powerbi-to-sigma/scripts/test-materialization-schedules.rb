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

puts "\n5. run_now: 409 then pending, building, ready"
calls = []
slept = []
seq = [:conflict, :conflict, 'post-ok', %w[pending], %w[building], %w[ready]]
request = lambda do |method, path, payload|
  calls << [method, path, payload]
  if method == :post
    step = seq.shift
    raise 'POST -> 409 conflict_request: Materialization already in progress' if step == :conflict
    { 'materializationId' => 'mat1' }
  else
    { 'status' => seq.shift.first }
  end
end
res = MaterializationSchedules.run_now(data_model_id: 'dm', element_id: 'el1', sheet_id: 'sheet1', request: request,
                                       sleep: ->(s) { slept << s }, poll_seconds: 5)
check.call(res['status'] == 'ready', "ready after the conflict clears (#{res.inspect})")
check.call(res['states'] == %w[conflict pending building ready], "states are recorded in order (#{res['states'].inspect})")
check.call(calls.first == [:post, '/v2/dataModels/dm:materialize', { 'sheetId' => 'sheet1' }], 'the POST carries sheetId')
check.call(calls.any? { |m, p, _| m == :get && p == '/v2/dataModels/dm/materializations/mat1' }, 'the materialization is polled by id')
check.call(slept.length == 4 && res['seconds'] >= 20, 'it sleeps between retries and polls')

puts "\n6. run_now: skipped is terminal; failed is reported; element id is the default sheetId"
seq = ['post-ok', %w[pending], %w[skipped]]
sent = nil
request = lambda do |method, _path, payload|
  if method == :post
    seq.shift
    sent = payload
    { 'materializationId' => 'm2' }
  else
    { 'status' => seq.shift.first }
  end
end
res = MaterializationSchedules.run_now(data_model_id: 'dm', element_id: 'wh', request: request, sleep: ->(_s) {})
check.call(res['status'] == 'skipped' && sent == { 'sheetId' => 'wh' }, 'skipped (a warehouse-table element) ends the run')
seq = ['post-ok', %w[building], %w[failed]]
res = MaterializationSchedules.run_now(data_model_id: 'dm', element_id: 'x', request: request, sleep: ->(_s) {})
check.call(res['status'] == 'failed', 'a failed run is reported')

puts "\n7. run_now: a cap timeout, and a non-409 error"
polls = 0
request = lambda do |method, _path, _payload|
  next { 'materializationId' => 'm3' } if method == :post
  polls += 1
  { 'status' => 'building' }
end
res = MaterializationSchedules.run_now(data_model_id: 'dm', element_id: 'slow', request: request, sleep: ->(_s) {},
                                       cap_seconds: 60, poll_seconds: 10)
check.call(res['status'] == 'timeout' && polls <= 8 && res['seconds'] >= 60, "gives up at the cap (#{res['status']}, #{polls} polls)")
request = ->(_m, _p, _b) { raise 'POST -> 409 Materialization already in progress' }
res = MaterializationSchedules.run_now(data_model_id: 'dm', element_id: 'busy', request: request, sleep: ->(_s) {},
                                       cap_seconds: 30, poll_seconds: 10)
check.call(res['status'] == 'timeout', 'a permanent 409 times out too')
request = ->(_m, _p, _b) { raise 'POST -> 403 not_permitted' }
res = MaterializationSchedules.run_now(data_model_id: 'dm', element_id: 'e', request: request, sleep: ->(_s) { raise 'must not sleep' })
check.call(res['status'] == 'error' && res['error'].include?('403'), 'a non-409 error returns at once')
request = ->(_m, _p, _b) { raise 'POST /v2/dataModels/dm4090:materialize -> 500 Server Error: element 409 failed' }
res = MaterializationSchedules.run_now(data_model_id: 'dm', element_id: 'e', request: request, sleep: ->(_s) { raise 'must not sleep' })
check.call(res['status'] == 'error', 'a 409 substring elsewhere in the message is not a conflict')

puts "\n8. select_elements: default mode is Custom SQL only; pbi mode takes any kind"
specs = [
  { 'name' => 'Summary', 'source' => { 'kind' => 'sql' } },
  { 'name' => 'Sales', 'source' => { 'kind' => 'warehouse-table' } },
  { 'name' => 'Sales (flattened)', 'source' => { 'kind' => 'table' } }
]
paired = specs.each_with_index.map { |s, i| { 'id' => "srv#{i}", 'name' => s['name'] } }
sel, err = MaterializationSchedules.select_elements(specs, paired, selectors: [])
check.call(sel.map { |s, _| s['name'] } == ['Summary'] && err.empty?, 'default mode: no list selects Custom SQL elements only')
sel, err = MaterializationSchedules.select_elements(specs, paired, selectors: ['Sales'])
check.call(sel.empty? && err.size == 1 && err[0]['error'].include?('Custom SQL'), 'default mode: a warehouse-table element is not selectable')
targets = ['Summary', 'Sales (flattened)']
sel, = MaterializationSchedules.select_elements(specs, paired, selectors: [], targets: targets)
check.call(sel.map { |s, _| s['name'] } == ['Summary', 'Sales (flattened)'], 'pbi mode: no list uses the targets (summaries, flattened), not the plain fact')
sel, err = MaterializationSchedules.select_elements(specs, paired, selectors: ['Sales'], targets: targets)
check.call(sel.map { |s, _| s['name'] } == ['Sales'] && err.empty? && sel[0][1]['id'] == 'srv1', 'pbi mode: an explicit list accepts any element kind (non-SQL)')
sel, = MaterializationSchedules.select_elements(specs, paired, selectors: ['all-sql'], targets: targets)
check.call(sel.map { |s, _| s['name'] } == ['Summary'], 'pbi mode: all-sql still means Custom SQL')
requests = []
request = lambda do |method, path, payload|
  requests << [method, path]
  method == :get ? { 'entries' => [] } : { 'schedule' => payload['schedule'] }
end
acts = MaterializationSchedules.reconcile(data_model_id: 'dm', elements: [sel.first.last], cron: '0 2 * * *', request: request)
check.call(acts[0]['status'] == 'created', 'a selected element reconciles through the same call')
sel, = MaterializationSchedules.select_elements(specs, paired, selectors: ['Sales'], targets: targets)
acts = MaterializationSchedules.reconcile(data_model_id: 'dm', elements: sel.map(&:last), cron: '0 2 * * *', request: request)
check.call(requests.any? { |m, p| m == :post && p.include?('/elements/srv1/') } && acts[0]['status'] == 'created',
           'test_pbi_mode_materializes_non_sql_elements: a warehouse-table fact gets its schedule POST')

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
