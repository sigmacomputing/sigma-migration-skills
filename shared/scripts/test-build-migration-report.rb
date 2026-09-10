#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline regression tests for build-migration-report.rb.

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

BUILDER = File.join(__dir__, 'build-migration-report.rb')
RUBY = RbConfig.ruby
TERMINAL = %w[migrated approximated needs-review skipped not-applicable].freeze

$failures = 0

def ok(name, condition)
  puts "#{condition ? '  ok  ' : 'FAIL  '}#{name}"
  $failures += 1 unless condition
end

def write_json(path, value)
  File.write(path, JSON.pretty_generate(value))
end

def run_builder(dir, *args, env: {})
  Open3.capture3(env, RUBY, BUILDER, '--workdir', dir, *args)
end

def write_health_artifacts(dir)
  write_json(File.join(dir, 'parity-final.json'),
             'status' => 'PASS', 'charts_pass' => 2, 'charts_total' => 2,
             'visual_checked' => true, 'visual_verdict' => 'pass', 'waivers' => [])
  write_json(File.join(dir, 'dashboard-render-health.json'),
             'status' => 'healthy', 'failed_count' => 0)
  write_json(File.join(dir, 'dashboard-blank-risk.json'),
             'risk' => false, 'blank_count' => 0)
  write_json(File.join(dir, 'degradation-ledger.json'),
             'version' => 1, 'counts' => {}, 'entries' => [])
  write_json(File.join(dir, 'waivers.json'), 'waivers' => [])
end

# Full accounting: normalize type-keyed arrays and obtain terminal states from
# the object, inventory accounting, coverage, and controls coverage.
Dir.mktmpdir('migration-report-full') do |dir|
  inventory = {
    'summary' => { 'total' => 4, 'migrated' => 4 },
    'objects' => {
      'dashboards' => [
        { 'id' => 'd1', 'name' => 'Executive', 'status' => 'migrated' }
      ],
      'worksheets' => [
        { 'id' => 'w1', 'name' => 'Revenue' },
        { 'id' => 'w2', 'name' => 'Margin' }
      ],
      'parameters' => [
        { 'id' => 'p1', 'name' => 'Region' }
      ]
    },
    'accounting' => [
      { 'type' => 'worksheet', 'source_object_id' => 'w1', 'status' => 'completed' }
    ]
  }
  write_json(File.join(dir, 'source-inventory.json'), inventory)
  write_json(File.join(dir, 'coverage.json'),
             'objects' => [
               { 'type' => 'worksheet', 'source_object_id' => 'w2', 'status' => 'built' }
             ])
  write_json(File.join(dir, 'tableau-controls-coverage.json'),
             'detail' => [
               { 'kind' => 'parameter', 'id' => 'p1', 'name' => 'Region', 'status' => 'emitted' }
             ])
  write_health_artifacts(dir)

  _stdout, stderr, status = run_builder(dir, env: { 'SOURCE_DATE_EPOCH' => '0' })
  ok('full accounting exits 0', status.exitstatus == 0)
  ok('full accounting emits no error', stderr.empty?)

  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  markdown = File.read(File.join(dir, 'MIGRATION_REPORT.md'))
  ok('full accounting is GREEN', result['verdict'] == 'GREEN')
  ok('all four objects accounted as migrated',
     result.dig('summary', 'total') == 4 &&
       result.dig('summary', 'accounted') == 4 &&
       result.dig('summary', 'counts', 'migrated') == 4)
  ok('type-keyed arrays normalize to singular canonical types',
     result['source_objects'].map { |object| object['type'] }.sort ==
       %w[dashboard parameter worksheet worksheet])
  ok('SOURCE_DATE_EPOCH is the only generated timestamp source',
     result['generated_at'] == '1970-01-01T00:00:00Z')
  ok('Markdown and JSON verdict agree',
     markdown.include?("Verdict: **#{result['verdict']}**"))
  ok('Markdown and JSON accounting totals agree',
     markdown.include?("Accounting: **#{result.dig('summary', 'accounted')}/#{result.dig('summary', 'total')}**"))
  TERMINAL.each do |terminal|
    ok("Markdown and JSON #{terminal} counts agree",
       markdown.include?("| #{terminal} | #{result.dig('summary', 'counts', terminal)} |"))
  end

  _stdout, _stderr, check_status = run_builder(
    dir, '--check', env: { 'SOURCE_DATE_EPOCH' => '0' }
  )
  ok('--check accepts current deterministic outputs', check_status.exitstatus == 0)

  # Cross-platform freshness is semantic for JSON and line-ending-neutral for
  # Markdown. Windows text-mode tools may reserialize JSON or write CRLF without
  # changing the report contract.
  File.binwrite(File.join(dir, 'migration-result.json'), JSON.generate(result))
  report_path = File.join(dir, 'MIGRATION_REPORT.md')
  File.binwrite(report_path, markdown.gsub("\n", "\r\n"))
  _stdout, _stderr, portable_status = run_builder(
    dir, '--check', env: { 'SOURCE_DATE_EPOCH' => '0' }
  )
  ok('--check accepts semantic JSON and CRLF Markdown', portable_status.exitstatus == 0)

  File.open(report_path, 'a') { |file| file.write("manual edit\n") }
  before = File.binread(report_path)
  _stdout, stale_stderr, stale_status = run_builder(
    dir, '--check', env: { 'SOURCE_DATE_EPOCH' => '0' }
  )
  ok('--check rejects a stale Markdown report', stale_status.exitstatus == 1)
  ok('--check identifies stale output', stale_stderr.include?('stale or missing'))
  ok('--check writes nothing', File.binread(report_path) == before)
end

# An inventory object with no terminal status is an omission: write the RED
# report for diagnosis and return exit 1.
Dir.mktmpdir('migration-report-omitted') do |dir|
  write_json(File.join(dir, 'source-object-census.json'),
             'objects' => [
               { 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Accounted', 'status' => 'migrated' },
               { 'type' => 'dashboard', 'id' => 'd2', 'name' => 'Omitted' }
             ])
  write_health_artifacts(dir)

  _stdout, _stderr, status = run_builder(dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  omitted = result['source_objects'].find { |object| object['id'] == 'd2' }
  ok('omitted object exits 1', status.exitstatus == 1)
  ok('omitted object makes verdict RED', result['verdict'] == 'RED')
  ok('omitted object is explicit in canonical accounting', omitted['status'] == 'missing')
  ok('omitted object fails source-accounting check',
     result['checks'].any? { |check| check['name'] == 'source-accounting' && check['status'] == 'FAIL' })
end

# Different terminal states for one source identity are contradictory even when
# each individual record uses valid vocabulary.
Dir.mktmpdir('migration-report-contradictory') do |dir|
  write_json(File.join(dir, 'inventory.json'),
             'objects' => [
               { 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }
             ],
             'accounting' => [
               { 'type' => 'dashboard', 'object_id' => 'd1', 'status' => 'skipped',
                 'reason' => 'explicit fixture contradiction' }
             ])
  write_health_artifacts(dir)

  _stdout, _stderr, status = run_builder(dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  object = result['source_objects'].first
  ok('contradictory statuses exit 1', status.exitstatus == 1)
  ok('contradictory statuses make verdict RED', result['verdict'] == 'RED')
  ok('contradictory object preserves both evidence records',
     object['status'] == 'contradictory' &&
       object['status_sources'].map { |source| source['status'] }.sort == %w[migrated skipped])
  ok('contradiction is named by consistency check',
     result['checks'].any? do |check|
       check['name'] == 'status-consistency' && check['status'] == 'FAIL' &&
         check['message'].include?('migrated and skipped')
     end)
end

# Explicit approximation is complete accounting but caps the result at YELLOW.
Dir.mktmpdir('migration-report-yellow') do |dir|
  write_json(File.join(dir, 'inventory.json'),
             'objects' => [
               { 'type' => 'chart', 'id' => 'c1', 'name' => 'Gauge', 'status' => 'approximated' }
             ])
  write_health_artifacts(dir)
  _stdout, _stderr, status = run_builder(dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  ok('approximated full accounting exits 0', status.exitstatus == 0)
  ok('approximated full accounting is YELLOW', result['verdict'] == 'YELLOW')
  ok('approximated accounting remains complete', result.dig('summary', 'complete') == true)
end

# Hard verification evidence dominates complete source accounting.
Dir.mktmpdir('migration-report-render-failure') do |dir|
  write_json(File.join(dir, 'inventory.json'),
             'objects' => [
               { 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }
             ])
  write_health_artifacts(dir)
  write_json(File.join(dir, 'dashboard-render-health.json'),
             'status' => 'failed', 'errors' => ['export returned a blank page'])
  write_json(File.join(dir, 'dashboard-blank-risk.json'),
             'risk' => 'high', 'blank_count' => 1)
  _stdout, _stderr, status = run_builder(dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  ok('failed render/blank risk exits 1', status.exitstatus == 1)
  ok('failed render/blank risk makes verdict RED', result['verdict'] == 'RED')
  ok('render and blank-risk checks both fail',
     %w[render-health blank-risk].all? do |name|
       result['checks'].any? { |check| check['name'] == name && check['status'] == 'FAIL' }
     end)
end

# A self-reported inventory summary cannot disagree with canonical detail.
Dir.mktmpdir('migration-report-inconsistent') do |dir|
  write_json(File.join(dir, 'inventory.json'),
             'summary' => { 'total' => 2, 'migrated' => 2 },
             'objects' => [
               { 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }
             ])
  write_health_artifacts(dir)
  _stdout, _stderr, status = run_builder(dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  consistency = result['checks'].find { |check| check['name'] == 'artifact-consistency' }
  ok('inconsistent report counts exit 1', status.exitstatus == 1)
  ok('inconsistent report counts are RED', result['verdict'] == 'RED')
  ok('inconsistent report count is named', consistency['status'] == 'FAIL' &&
                                                consistency['message'].include?('summary total 2 != 1'))
end

builder_source = File.read(BUILDER)
ok('report outputs use binary writes so --check is byte-stable on Windows',
   builder_source.include?('File.binwrite(temporary, content)') &&
     !builder_source.include?('File.write(temporary, content)'))

puts($failures.zero? ? "\nall build-migration-report tests passed" : "\n#{$failures} FAILED")
exit($failures.zero? ? 0 : 1)
