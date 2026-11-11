#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline regression tests for build-migration-report.rb.

require 'digest'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../lib/degradation_ledger'

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

# A source-inert control is an approximation even when the census calls the
# built object migrated or unproven needs-review.
Dir.mktmpdir('migration-report-source-inert') do |dir|
  unproven = 'matching built object exists, but final parity does not prove this source object'
  write_json(File.join(dir, 'source-object-census.json'),
             'summary' => { 'total' => 2, 'migrated' => 1, 'needs-review' => 1 },
             'objects' => [
               { 'type' => 'parameter', 'id' => 'p1', 'name' => 'Green', 'status' => 'migrated' },
               {
                 'type' => 'parameter', 'id' => 'p2', 'name' => 'Unproven',
                 'status' => 'needs-review', 'evidence' => [{ 'detail' => unproven }]
               }
             ])
  write_json(File.join(dir, 'tableau-controls-coverage.json'),
             'detail' => [
               { 'kind' => 'parameter', 'id' => 'p1', 'status' => 'source-inert' },
               { 'kind' => 'parameter', 'id' => 'p2', 'status' => 'source-inert' }
             ])
  write_health_artifacts(dir)

  _stdout, _stderr, status = run_builder(dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  ok('source-inert census aliases exit 0', status.exitstatus == 0)
  ok('source-inert census aliases are YELLOW', result['verdict'] == 'YELLOW')
  ok('source-inert census aliases remain approximated',
     result.dig('summary', 'counts', 'approximated') == 2)
  ok('source-inert census summary remains consistent',
     result['checks'].any? do |check|
       check['name'] == 'artifact-consistency' && check['status'] == 'PASS'
     end)
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

# Every worksheet hidden: no exportable view CSVs, so phase6-parity writes an
# empty FAIL pool and the hard gate's anchors oracle stands in. The report
# follows the gate's stamp only while the anchors verdict it accepted is intact.
Dir.mktmpdir('migration-report-anchors-oracle') do |dir|
  write_json(File.join(dir, 'inventory.json'),
             'objects' => [
               { 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }
             ])
  write_health_artifacts(dir)
  verdict_path = File.join(dir, 'anchors-verdict.json')
  write_json(verdict_path, 'pass' => true, 'checked' => 6, 'matched' => 6)
  empty_pool = { 'status' => 'FAIL', 'charts_pass' => 0, 'charts_total' => 0,
                 'visual_checked' => true, 'visual_verdict' => 'pass', 'waivers' => [] }
  parity_check = lambda do
    result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
    [result, result['checks'].find { |check| check['name'] == 'parity' }]
  end

  write_json(File.join(dir, 'parity-final.json'), empty_pool)
  run_builder(dir)
  result, parity = parity_check.call
  ok('empty parity pool without a gate stamp stays RED', result['verdict'] == 'RED' && parity['status'] == 'FAIL')

  stamp = { 'kind' => 'anchors', 'anchors_matched' => 6, 'anchors_checked' => 6,
            'tiles_covered' => 4, 'tiles_displayed' => 4,
            'anchors_verdict_sha256' => Digest::SHA256.file(verdict_path).hexdigest }
  write_json(File.join(dir, 'parity-final.json'), empty_pool.merge('parity_oracle' => stamp))
  _stdout, _stderr, status = run_builder(dir)
  result, parity = parity_check.call
  ok('gate-stamped anchors oracle passes parity', status.exitstatus.zero? && parity['status'] == 'PASS')
  ok('anchors-oracle parity names the stand-in', parity['message'].include?('anchors oracle'))
  ok('anchors-oracle route can be GREEN', result['verdict'] == 'GREEN')

  write_json(verdict_path, 'pass' => true, 'checked' => 6, 'matched' => 5)
  run_builder(dir)
  _result, parity = parity_check.call
  ok('a changed anchors verdict invalidates the stamp', parity['status'] == 'FAIL')

  write_json(verdict_path, 'pass' => true, 'checked' => 6, 'matched' => 6)
  write_json(File.join(dir, 'parity-final.json'),
             empty_pool.merge('charts_total' => 3, 'parity_oracle' => stamp))
  run_builder(dir)
  _result, parity = parity_check.call
  ok('the stamp never covers a non-empty failing chart pool', parity['status'] == 'FAIL')
end

# A recorded non-pass visual verdict never poisons render health; divergent and
# not-executable cap the run at YELLOW (gate doctrine), real render failures
# stay RED.
def check_named(result, name)
  result['checks'].find { |c| c['name'] == name }
end

def visual_case(prefix, parity_extra, health: true, ledger: true, render: true, blank: true)
  Dir.mktmpdir(prefix) do |dir|
    write_json(File.join(dir, 'inventory.json'),
               'objects' => [
                 { 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }
               ])
    write_health_artifacts(dir)
    write_json(File.join(dir, 'parity-final.json'),
               { 'status' => 'PASS', 'charts_pass' => 2, 'charts_total' => 2,
                 'waivers' => [] }.merge(parity_extra))
    File.delete(File.join(dir, 'degradation-ledger.json')) unless ledger
    File.delete(File.join(dir, 'dashboard-render-health.json')) unless render
    File.delete(File.join(dir, 'dashboard-blank-risk.json')) unless blank
    unless health
      write_json(File.join(dir, 'dashboard-render-health.json'),
                 'status' => 'failed', 'errors' => ['blank page'])
    end
    _stdout, _stderr, status = run_builder(dir)
    result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
    yield result, status
  end
end

divergent = { 'visual_checked' => false, 'visual_verdict' => 'divergent',
              'visual_notes' => 'legend differs', 'screenshot_path' => 'shot.png' }

visual_case('migration-report-divergent', divergent) do |result, status|
  ok('divergent visual is YELLOW not RED', result['verdict'] == 'YELLOW' && status.exitstatus == 0)
  ok('render-health passes with divergent visual', check_named(result, 'render-health')['status'] == 'PASS')
end

visual_case('migration-report-not-executable',
            { 'visual_checked' => false, 'visual_verdict' => 'not-executable' }) do |result, status|
  ok('not-executable visual is YELLOW', result['verdict'] == 'YELLOW' && status.exitstatus == 0)
end

visual_case('migration-report-broken-render',
            { 'visual_checked' => true, 'visual_verdict' => 'pass' }, health: false) do |result, _status|
  ok('broken render stays RED despite visual pass', result['verdict'] == 'RED')
end

visual_case('migration-report-no-render-evidence',
            divergent.reject { |k, _| k == 'visual_checked' }, render: false, blank: false) do |result, _status|
  ok('recorded comparison covers blank risk', check_named(result, 'blank-risk')['status'] == 'PASS')
  ok('divergent is not render evidence',
     check_named(result, 'render-health')['message'] =~ /no healthy render evidence/)
end

visual_case('migration-report-divergent-no-ledger', divergent, ledger: false) do |result, _status|
  ok('divergent YELLOW without ledger file', result['verdict'] == 'YELLOW')
  ok('degradation listed once without ledger',
     result['degradations'].count { |d| d['item'] == 'visual verdict: divergent' } == 1)
  ok('degradation carries the recorded visual notes',
     result['degradations'].any? { |d| d['class'] == 'fidelity-residual' && d['item'] == 'visual verdict: divergent' })
  # Must equal DegradationLedger's derivation exactly (verify-complete equality).
  Dir.mktmpdir('ledger-twin') do |wd|
    write_json(File.join(wd, 'parity-final.json'), divergent.merge('status' => 'PASS'))
    derived = DegradationLedger.derive(wd)
    ok('fallback entry equals DegradationLedger derivation',
       result['degradations'].select { |d| d['item'] == 'visual verdict: divergent' } == derived)
  end
end

visual_case('migration-report-not-exec-notes',
            { 'visual_checked' => false, 'visual_verdict' => 'not-executable',
              'visual_notes' => 'no browser' }, ledger: false) do |result, _status|
  ok('not-executable entry uses recorded notes, no extra keys',
     result['degradations'].include?('class' => 'fidelity-residual',
                                     'item' => 'visual verdict: not-executable',
                                     'reason' => 'no browser',
                                     'source_artifact' => 'parity-final.json'))
end

visual_case('migration-report-pass-no-shot',
            { 'visual_checked' => false, 'visual_verdict' => 'pass' }, render: false, blank: false) do |result, _status|
  ok('pass without screenshot still covers blank risk', check_named(result, 'blank-risk')['status'] == 'PASS')
end

visual_case('migration-report-divergent-no-shot',
            divergent.reject { |k, _| k == 'screenshot_path' }, render: false, blank: false) do |result, _status|
  ok('divergent without screenshot does not cover blank risk', check_named(result, 'blank-risk')['status'] == 'FAIL')
end

visual_case('migration-report-pass-clean', { 'visual_checked' => true, 'visual_verdict' => 'pass' }) do |result, _status|
  ok('visual pass stays GREEN', result['verdict'] == 'GREEN')
end

Dir.mktmpdir('migration-report-platform') do |dir|
  write_json(File.join(dir, 'inventory.json'),
             'objects' => [{ 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }])
  write_health_artifacts(dir)
  write_json(File.join(dir, 'degradation-ledger.json'), 'version' => 1, 'entries' => [])
  write_json(File.join(dir, 'visual-residuals.json'),
             'platform_differences' => [{ 'tile' => 'Region filter', 'severity' => 'minor',
                                          'description' => 'All placeholder is grey',
                                          'class' => 'list-control-all-placeholder' }],
             'residuals' => [])
  write_json(File.join(dir, 'fidelity-ledger.json'),
             'entries' => [{ 'id' => 'p1', 'cls' => 'sigma-capability', 'catalog_id' => 'map-basemap-labels',
                             'delta' => 'basemap labels on map', 'resolved' => false }])
  run_builder(dir, '--markdown', File.join(dir, 'report.md'))
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  ok('report lists platform differences', result['platform_differences'].size == 2)
  ok('platform differences are not degradations', result['degradations'].empty?)
  ok('platform-only run stays GREEN', result['verdict'] == 'GREEN')
  md = File.read(File.join(dir, 'report.md'))
  ok('markdown renders a Platform differences section',
     md.include?('## Platform differences') && md.include?('map-basemap-labels'))
end

# minor = notes (TJ 2026-11-09): on a PASSING v2 blind grade every minor
# residual is a polish note (report section + `polish_notes`), not a
# degradation. Majors, divergent grades, waivers and parity misses keep the
# verdict where it was. The ledger file is derived by DegradationLedger, as
# assert-phase6-ran writes it.
POLISH_MINORS = [
  { 'tile' => 'r3c1', 'dimension' => 'palette_match', 'description' => 'Trend line stroke is thinner',
    'severity' => 'minor', 'class' => 'fixable' },
  { 'tile' => 'r2c1', 'dimension' => 'composition_match', 'description' => 'KPI cards are boxed',
    'severity' => 'minor', 'class' => 'fixable' }
].freeze
POLISH_MAJOR = { 'tile' => 'r1c1', 'dimension' => 'composition_match', 'description' => 'KPI row missing',
                 'severity' => 'major', 'class' => 'fixable' }.freeze

def polish_case(prefix, verdict: 'pass', faithful: true, major: [], parity: {}, waivers: [])
  Dir.mktmpdir(prefix) do |dir|
    write_json(File.join(dir, 'inventory.json'),
               'objects' => [{ 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }])
    write_health_artifacts(dir)
    write_json(File.join(dir, 'parity-final.json'),
               { 'status' => 'PASS', 'charts_pass' => 2, 'charts_total' => 2, 'waivers' => waivers,
                 'visual_checked' => verdict == 'pass', 'visual_verdict' => verdict }.merge(parity))
    write_json(File.join(dir, 'visual-residuals.json'),
               'schema' => 'visual-residuals/v1', 'faithful' => faithful, 'score' => faithful ? 85.0 : 70.0,
               'platform_differences' => [], 'residuals' => POLISH_MINORS, 'fixable_major' => major, 'reasons' => [])
    DegradationLedger.write(dir, DegradationLedger.derive(dir))
    _o, _e, status = run_builder(dir, '--markdown', File.join(dir, 'report.md'))
    result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
    yield result, File.read(File.join(dir, 'report.md')), status
  end
end

polish_case('polish-pass-minor') do |result, md, _status|
  ok('pass grade + minor-only: GREEN', result['verdict'] == 'GREEN')
  ok('pass grade + minor-only: no degradations', result['degradations'].empty?)
  ok('pass grade + minor-only: both minors are polish_notes',
     result['polish_notes'].map { |n| n['item'] } == ['r3c1: Trend line stroke is thinner', 'r2c1: KPI cards are boxed'])
  ok('polish notes carry their dimension', result['polish_notes'].map { |n| n['dimension'] } == %w[palette_match composition_match])
  ok('markdown renders a Minor polish notes section',
     md.include?('## Minor polish notes') && md.include?('Trend line stroke is thinner [palette_match]'))
end

polish_case('polish-pass-major', faithful: false, major: [POLISH_MAJOR]) do |result, md, _status|
  ok('recorded pass + one major gap: YELLOW', result['verdict'] == 'YELLOW')
  ok('recorded pass + one major gap: the major is a degradation',
     result['degradations'].any? { |d| d['item'] == 'visual residual (major): r1c1: KPI row missing' })
  ok('recorded pass + one major gap: minors stay degradations, no polish notes',
     result['degradations'].count { |d| d['item'].start_with?('visual residual (minor)') } == 2 && result['polish_notes'].empty?)
  ok('no polish section when there are no polish notes', !md.include?('## Minor polish notes'))
end

polish_case('polish-divergent-minor', verdict: 'divergent', faithful: false) do |result, _md, _status|
  ok('divergent grade + minor: YELLOW', result['verdict'] == 'YELLOW')
  ok('divergent grade + minor: minors are degradations',
     result['degradations'].count { |d| d['item'].start_with?('visual residual (minor)') } == 2)
  ok('divergent grade + minor: no polish notes', result['polish_notes'].empty?)
end

polish_case('polish-pass-waiver', waivers: ['--skip-layout-check']) do |result, _md, _status|
  ok('pass grade + minor + waiver: YELLOW', result['verdict'] == 'YELLOW')
  ok('pass grade + minor + waiver: the minors are still polish notes, not degradations',
     result['polish_notes'].length == 2 &&
     result['degradations'].none? { |d| d['item'].to_s.start_with?('visual residual') })
end

polish_case('polish-pass-parity-miss', parity: { 'status' => 'FAIL', 'charts_pass' => 1 }) do |result, _md, _status|
  ok('pass grade + minor + parity miss: RED, as today', result['verdict'] == 'RED')
end

Dir.mktmpdir('polish-stale') do |dir|
  write_json(File.join(dir, 'inventory.json'),
             'objects' => [{ 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }])
  write_health_artifacts(dir)
  write_json(File.join(dir, 'visual-residuals.json'),
             'faithful' => true, 'residuals' => POLISH_MINORS, 'fixable_major' => [], 'platform_differences' => [])
  # a ledger written by the gate BEFORE the polish rule: the minors are entries
  stale = POLISH_MINORS.map do |g|
    { 'class' => 'fidelity-residual', 'item' => "visual residual (minor): #{g['tile']}: #{g['description']}",
      'reason' => 'fixable gap recorded by the blind visual grade and left in the render', 'source_artifact' => 'visual-residuals.json' }
  end
  write_json(File.join(dir, 'degradation-ledger.json'), 'version' => 1, 'entries' => stale)
  run_builder(dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  ok('pre-rule ledger: a gap is never listed as both a degradation and a polish note',
     result['degradations'].length == 2 && result['polish_notes'].empty?)
end

# finalize-gates.json (tableau --finalize): a failed finalize gate means the
# report can never say GREEN (2026-11-09 Complex Pivot: gate 14 failed, report
# GREEN). All gates PASS keeps the verdict; no file adds no check.
polish_case('finalize-gates-none') do |result, _md, _status|
  ok('no finalize-gates.json: no finalize-gates check', result['checks'].none? { |c| c['name'] == 'finalize-gates' })
end
[[{ 'assert-phase6-ran' => { 'status' => 'FAIL', 'exit' => 20 }, 'cleanup' => { 'status' => 'PASS' } }, 'RED',
  'a failed finalize gate (assert-phase6-ran exit 20) makes a would-be GREEN report RED'],
 [{ 'assert-phase6-ran' => { 'status' => 'PASS' }, 'cleanup' => { 'status' => 'PASS' } }, 'GREEN',
  'all finalize gates PASS keeps GREEN'],
 [{}, 'RED', 'a malformed (empty) finalize-gates.json fails closed']].each do |gates, want, name|
  Dir.mktmpdir('finalize-gates') do |dir|
    write_json(File.join(dir, 'inventory.json'),
               'objects' => [{ 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }])
    write_health_artifacts(dir)
    write_json(File.join(dir, 'finalize-gates.json'), 'schema' => 'finalize-gates/v1', 'gates' => gates)
    _o, _e, st = run_builder(dir, '--markdown', File.join(dir, 'report.md'))
    result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
    chk = result['checks'].find { |c| c['name'] == 'finalize-gates' }
    ok("#{name} (verdict #{result['verdict']})", result['verdict'] == want && chk)
    ok('the failed gate is named in the check', chk['message'].include?('assert-phase6-ran (exit 20)')) if gates.dig('assert-phase6-ran', 'status') == 'FAIL'
    ok('a RED report exits 1', st.exitstatus == 1) if want == 'RED'
  end
end

Dir.mktmpdir('polish-v1') do |dir|
  write_json(File.join(dir, 'parity-final.json'), 'status' => 'PASS', 'visual_verdict' => 'pass')
  ok('v1 run (no visual-residuals.json): no polish notes', DegradationLedger.polish_notes(dir).empty?)
  write_json(File.join(dir, 'visual-residuals.json'), 'faithful' => true, 'residuals' => POLISH_MINORS, 'fixable_major' => [])
  write_json(File.join(dir, 'parity-final.json'), 'status' => 'PASS', 'visual_verdict' => 'not-executable')
  ok('not-executable verdict: no polish notes, minors stay residuals',
     DegradationLedger.polish_notes(dir).empty? &&
     DegradationLedger.derive(dir).count { |e| e['item'].start_with?('visual residual (minor)') } == 2)
end

# Real-run shape: NO render-health / blank-risk artifacts. Machine render
# evidence comes from visual-similarity.json (gate-14 floor) and the anchors
# tile census; the blind verdict is divergent.
def evidence_case(prefix, similarity: {}, anchors: { 'tiles_all_nonempty' => true },
                  blank_artifact: nil, png: true, waivers: [])
  Dir.mktmpdir(prefix) do |dir|
    write_json(File.join(dir, 'inventory.json'),
               'objects' => [{ 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Sales', 'status' => 'migrated' }])
    File.binwrite(File.join(dir, 'rcf-pass-3.png'), 'png') if png
    write_json(File.join(dir, 'parity-final.json'),
               'status' => 'PASS', 'charts_pass' => 2, 'charts_total' => 2, 'waivers' => waivers,
               'visual_checked' => false, 'visual_verdict' => 'divergent',
               'visual_notes' => 'legend differs',
               'screenshot_path' => File.join(dir, 'rcf-pass-3.png'))
    write_json(File.join(dir, 'degradation-ledger.json'), 'version' => 1, 'counts' => {}, 'entries' => [])
    write_json(File.join(dir, 'waivers.json'), 'waivers' => [])
    base = { 'pass' => true, 'tiles_measured' => 0, 'tiles_blank' => [],
             'render_health' => { 'path' => File.join(dir, 'rcf-pass-3.png'), 'status' => 'PASS', 'reasons' => [] },
             'source_health' => { 'status' => 'PASS' } }
    unless similarity == :absent
      sim = base.merge(similarity)
      sim['render_health'] = base['render_health'].merge(similarity['render_health']) if similarity['render_health'].is_a?(Hash)
      write_json(File.join(dir, 'visual-similarity.json'), sim)
    end
    write_json(File.join(dir, 'anchors-verdict.json'), anchors) if anchors
    write_json(File.join(dir, 'blank-risk-elements.json'), blank_artifact) if blank_artifact
    _stdout, _stderr, status = run_builder(dir)
    result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
    yield result, status
  end
end

evidence_case('migration-report-evidence-yellow') do |result, status|
  ok('tile census run is YELLOW exit 0', result['verdict'] == 'YELLOW' && status.exitstatus == 0)
  ok('visual-similarity is render evidence', check_named(result, 'render-health')['status'] == 'PASS')
  ok('anchors census covers blank risk', check_named(result, 'blank-risk')['status'] == 'PASS')
  ok('anchors census message', check_named(result, 'blank-risk')['message'] =~ /anchors tile census/)
  ok('visual-similarity recorded in artifacts',
     result['artifacts'].any? { |a| a['kind'] == 'visual-similarity' && a['present'] })
end

evidence_case('migration-report-evidence-blank-elements',
              blank_artifact: { 'status' => 'PASS', 'elements_checked' => 13, 'blank_risk_count' => 0, 'elements' => [] }) do |result, status|
  ok('clear blank-risk-elements composes to YELLOW', result['verdict'] == 'YELLOW' && status.exitstatus == 0)
  ok('explicit clear blank-risk record passes', check_named(result, 'blank-risk')['status'] == 'PASS')
end

evidence_case('migration-report-evidence-render-fail',
              similarity: { 'render_health' => { 'status' => 'FAIL', 'reasons' => ['blank'] } }) do |result, _status|
  ok('failed render_health is RED', result['verdict'] == 'RED')
  ok('failed render_health fails render-health', check_named(result, 'render-health')['status'] == 'FAIL')
end

evidence_case('migration-report-evidence-render-error',
              similarity: { 'render_health' => { 'status' => 'ERROR' } }) do |result, _status|
  ok('ERROR render_health is RED', result['verdict'] == 'RED')
end

evidence_case('migration-report-evidence-tiles-blank',
              similarity: { 'tiles_blank' => ['t1'], 'pass' => true }) do |result, _status|
  ok('minority blank tiles remain YELLOW', result['verdict'] == 'YELLOW')
  ok('artifact pass threshold controls render health', check_named(result, 'render-health')['status'] == 'PASS')
end

evidence_case('migration-report-evidence-composite-fail',
              similarity: { 'tiles_blank' => ['t1'], 'pass' => false }) do |result, _status|
  ok('composite visual failure remains YELLOW', result['verdict'] == 'YELLOW')
  ok('composite pass does not control render health', check_named(result, 'render-health')['status'] == 'PASS')
end

evidence_case('migration-report-evidence-majority-blank',
              similarity: { 'tiles_blank' => %w[t1 t2 t3], 'tiles_measured' => 4, 'pass' => false }) do |result, _status|
  ok('majority blank tiles is RED', result['verdict'] == 'RED')
  ok('majority blank tiles fails render health', check_named(result, 'render-health')['status'] == 'FAIL')
  ok('majority blank tiles message', check_named(result, 'render-health')['message'].to_s =~ /3 of 4 tiles blank/)
end

# The majority rule is armed at any measured count on purpose: png_health only
# fails all-white/solid/near-empty images, so a page with chrome but 1-of-1 or
# 2-of-2 blank tiles passes it.
evidence_case('migration-report-evidence-two-of-two-blank',
              similarity: { 'tiles_blank' => %w[t1 t2], 'tiles_measured' => 2, 'pass' => true }) do |result, _status|
  ok('2-of-2 blank tiles fail render health', check_named(result, 'render-health')['status'] == 'FAIL')
  ok('2-of-2 blank tiles message', check_named(result, 'render-health')['message'].to_s =~ /2 of 2 tiles blank/)
  ok('2-of-2 blank tiles verdict RED', result['verdict'] == 'RED')
end

evidence_case('migration-report-evidence-one-of-one-blank',
              similarity: { 'tiles_blank' => %w[t1], 'tiles_measured' => 1, 'pass' => true }) do |result, _status|
  ok('1-of-1 blank tile fails render health', check_named(result, 'render-health')['status'] == 'FAIL')
  ok('1-of-1 blank tile message', check_named(result, 'render-health')['message'].to_s =~ /1 of 1 tiles blank/)
  ok('1-of-1 blank tile verdict RED', result['verdict'] == 'RED')
end

evidence_case('migration-report-evidence-minority-blank',
              similarity: { 'tiles_blank' => ['t1'], 'tiles_measured' => 4 }) do |result, _status|
  ok('minority blank tiles remains YELLOW', result['verdict'] == 'YELLOW')
  ok('minority blank tiles passes render health', check_named(result, 'render-health')['status'] == 'PASS')
end

evidence_case('migration-report-evidence-half-blank',
              similarity: { 'tiles_blank' => %w[t1 t2], 'tiles_measured' => 4 }) do |result, _status|
  ok('exactly half blank is not a majority', check_named(result, 'render-health')['status'] == 'PASS')
end

evidence_case('migration-report-evidence-census-empty',
              anchors: { 'tiles_all_nonempty' => false }) do |result, _status|
  ok('empty anchors census is RED', result['verdict'] == 'RED')
  ok('empty anchors census fails blank-risk', check_named(result, 'blank-risk')['status'] == 'FAIL')
  ok('empty anchors census message',
     check_named(result, 'blank-risk')['message'] =~ /anchors tile census found empty displayed tiles/)
end

evidence_case('migration-report-evidence-census-empty-waived',
              anchors: { 'tiles_all_nonempty' => false },
              waivers: ['--allow-empty-tiles']) do |result, status|
  ok('waived empty anchors census is YELLOW exit 0',
     result['verdict'] == 'YELLOW' && status.exitstatus == 0)
  ok('empty-tile waiver passes blank-risk', check_named(result, 'blank-risk')['status'] == 'PASS')
end

evidence_case('migration-report-evidence-census-beats-clear-artifact',
              anchors: { 'tiles_all_nonempty' => false },
              blank_artifact: { 'status' => 'PASS', 'blank_risk_count' => 0 }) do |result, _status|
  ok('explicit FAIL census wins over a clear blank-risk artifact',
     check_named(result, 'blank-risk')['status'] == 'FAIL')
end

evidence_case('migration-report-evidence-stale', png: false) do |result, _status|
  ok('missing render image is RED', result['verdict'] == 'RED')
  ok('stale render explained',
     check_named(result, 'render-health')['message'] =~ /visual-similarity\.json.*missing/)
end

evidence_case('migration-report-evidence-similarity-pass-no-anchors', anchors: nil) do |result, _status|
  ok('healthy similarity alone covers blank risk', check_named(result, 'blank-risk')['status'] == 'PASS')
  ok('healthy similarity alone is YELLOW', result['verdict'] == 'YELLOW')
end

evidence_case('migration-report-evidence-no-similarity', similarity: :absent, anchors: nil) do |result, _status|
  ok('no similarity file keeps no-evidence FAIL',
     check_named(result, 'render-health')['message'] =~ /no healthy render evidence/)
end

evidence_case('migration-report-evidence-no-render-hash',
              similarity: { 'render_health' => nil }) do |result, _status|
  ok('similarity without render_health contributes nothing',
     check_named(result, 'render-health')['message'] =~ /no healthy render evidence/)
end

builder_source = File.read(BUILDER)
ok('report outputs use binary writes so --check is byte-stable on Windows',
   builder_source.include?('File.binwrite(temporary, content)') &&
     !builder_source.include?('File.write(temporary, content)'))

puts($failures.zero? ? "\nall build-migration-report tests passed" : "\n#{$failures} FAILED")
exit($failures.zero? ? 0 : 1)
