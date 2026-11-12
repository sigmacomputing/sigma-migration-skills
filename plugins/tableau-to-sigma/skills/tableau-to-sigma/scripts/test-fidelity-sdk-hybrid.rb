#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for the Phase 5g HYBRID route (refs/phase-5g-sdk-hybrid.md):
# SDK writes recorded in fidelity-ledger.json, then the spec export-back into
# wb-spec.json plus the re-gate (column guard, layout/control lint, phase-6
# parity) before --finalize. Sigma REST and the phase6-parity children are
# stubbed — no network, no credentials.
#
#   ruby scripts/test-fidelity-sdk-hybrid.rb
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'json'
require 'rbconfig'
require 'time'
require 'digest'
require 'fileutils'
require_relative 'lib/sdk_route'
require_relative 'fidelity-loop' # FidelityLoop pure core (CLI guarded off)

class SdkRouteUnitTest < Minitest::Test
  def ledger
    { 'workbook_id' => 'wb', 'page_id' => 'p', 'pass' => 1, 'max_passes' => 5,
      'entries' => [{ 'id' => 'e0', 'cls' => 'spec-fixable', 'resolved' => false, 'dimension' => 'palette' },
                    { 'id' => 'e1', 'cls' => 'ui-only', 'resolved' => false, 'dimension' => 'sparkline' }] }
  end

  def test_rest_ledger_unaffected
    assert_nil SdkRoute.finalize_block_reason(ledger)
    assert_nil SdkRoute.open_session(ledger)
    assert_nil SdkRoute.state(ledger)
  end

  def test_session_lifecycle_and_claims
    l = ledger
    s = SdkRoute.begin_session!(l, checkpoint: 'c' * 32, base_version: 7, mcp_server: 'sigma')
    assert_equal 'sdk', l['route']
    assert_equal 'open', SdkRoute.state(l)
    assert_match(/session is open/, SdkRoute.finalize_block_reason(l))
    assert_raises(SdkRoute::Error) { SdkRoute.begin_session!(l, checkpoint: 'x', base_version: 7, mcp_server: 'sigma') }
    assert_equal '7', SdkRoute.expected_live_version(s)
    SdkRoute.add_write!(l, status: 'failed', summary: 'try', program_sha256: 'a', program_path: 'p', document_version: 8,
                           claims: ['e0'], error: 'boom')
    assert s['needs_reread']
    assert_raises(SdkRoute::Error) do
      SdkRoute.add_write!(l, status: 'ok', summary: 'retry', program_sha256: 'b', program_path: 'p', document_version: 9)
    end
    SdkRoute.add_reread!(l, evidence_sha256: 'e')
    refute s['needs_reread']
    assert_raises(SdkRoute::Error) do
      SdkRoute.add_write!(l, status: 'ok', summary: 'x', program_sha256: 'b', program_path: 'p', document_version: 9, claims: ['e9'])
    end
    SdkRoute.add_write!(l, status: 'ok', summary: 'palette', program_sha256: 'b', program_path: 'p', document_version: 9, claims: ['e0'])
    assert_equal '9', SdkRoute.expected_live_version(s)
    assert_equal ['e0'], SdkRoute.resolve_claims!(l, s), 'only ok writes resolve their claims (the failed w1 claim counts only via w2)'
    assert_equal({ 'route' => 'sdk', 'session' => 's1', 'writes' => ['w2'] }, l['entries'][0]['resolved_via'])
    refute l['entries'][1]['resolved']
  end

  def test_parity_fail_adds_one_data_entry_and_pass_resolves_it
    l = ledger
    s = SdkRoute.begin_session!(l, checkpoint: 'c', base_version: 7, mcp_server: 'sigma')
    s['exports'] << { 'document_version' => '7', 'guards' => 'pass' }
    SdkRoute.record_parity!(l, s, result: 'fail', exit_code: 2, detail: 'DIVERGE Sales')
    SdkRoute.record_parity!(l, s, result: 'fail', exit_code: 2)
    data = l['entries'].select { |e| e['cls'] == 'data' }
    assert_equal 1, data.length, 'a repeated divergence does not stack duplicate entries'
    assert_equal SdkRoute::PARITY_SOURCE, data[0]['source']
    assert_equal 1, FidelityLoop.unresolved_data(l).length, 'the data entry blocks gate 8d unconditionally'
    assert_equal 'parity-failed', SdkRoute.state(l)
    refute_nil SdkRoute.finalize_block_reason(l)
    SdkRoute.record_parity!(l, s, result: 'pass', exit_code: 0)
    assert data[0]['resolved']
    assert_empty FidelityLoop.unresolved_data(l)
    assert_nil SdkRoute.finalize_block_reason(l)
  end

  def test_begin_refuses_spent_pass_budget_and_missing_server
    l = ledger.merge('pass' => 5)
    assert_raises(SdkRoute::Error) { SdkRoute.begin_session!(l, checkpoint: 'c', base_version: 7, mcp_server: 'sigma') }
    assert_raises(SdkRoute::Error) { SdkRoute.begin_session!(ledger, checkpoint: 'c', base_version: 7, mcp_server: '') }
  end

  def test_actuals_complete
    plan = { 'charts' => [{ 'chart' => 'Sales', 'sigma_columns' => ['x'] }, { 'chart' => 'Text', 'sigma_columns' => [] }] }
    assert_equal true, SdkRoute.actuals_complete?(plan, { 'Sales' => [['a', 1]] })[0]
    refute SdkRoute.actuals_complete?(plan, {})[0]
    refute SdkRoute.actuals_complete?(plan, { 'Sales' => { 'status' => 'render-verify' } })[0]
    refute SdkRoute.actuals_complete?(nil, { 'Sales' => [['a', 1]] })[0]
    assert SdkRoute.actuals_complete?(plan, { 'Sales' => { 'status' => 'render-verify-required' } })[0],
           'the pivot render-verify marker counts as collected, as in phase6-parity pass 1'
    refute SdkRoute.actuals_complete?(plan, { 'Sales' => { 'status' => 'too-large-for-export' } })[0]
    anchors = { 'oracle_mode' => 'anchors-warehouse', 'charts' => [] }
    assert SdkRoute.actuals_complete?(anchors, nil)[0], 'no collectible charts defers to phase6 --finalize, never blocks forever'
  end

  def test_live_version_block_reason
    l = ledger.merge('renders' => [{ 'pass' => 2, 'document_version' => '11' }])
    s = SdkRoute.begin_session!(l, checkpoint: 'c', base_version: 7, mcp_server: 'sigma')
    s['exports'] << { 'document_version' => '9', 'guards' => 'pass' }
    SdkRoute.record_parity!(l, s, result: 'pass', exit_code: 0)
    assert_nil SdkRoute.live_version_block_reason(l, '9'), 'live == last export'
    assert_match(/unrecorded write/, SdkRoute.live_version_block_reason(l, 11),
                 'a render cannot make an unexported version authoritative')
    assert_match(/unrecorded write/, SdkRoute.live_version_block_reason(l, '12'))
    assert_match(/could not be read/, SdkRoute.live_version_block_reason(l, nil))
    assert_nil SdkRoute.live_version_block_reason(ledger, '12'), 'REST-only ledgers are never checked'
  end
end

class SdkFinalizeWiringTest < Minitest::Test
  SRC = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')

  def test_finalize_consults_the_sdk_route_before_phase6
    head = SRC[/^if opts\[:finalize\].*?hdr\(6, 'Parity \(pass 2 — finalize\)'\)/m]
    refute_nil head, 'could not locate the --finalize entry block'
    assert_includes head, 'SdkRoute.finalize_block_reason(_sdk_ledger)'
    assert_includes head, 'SdkRoute.live_version_block_reason(_sdk_ledger, _sdk_live)'
    assert_match(/if _sdk_why\n.*?exit 3/m, head)
  end

  # sdk-export's control lint reads control-scope.json through the shared
  # loader, never a second raw read (the apply-patch site uses it too).
  def test_sdk_export_lints_controls_with_the_shared_scope_loader
    loop_src = File.read(File.join(__dir__, 'fidelity-loop.rb'), encoding: 'UTF-8')
    export = loop_src[/^when 'sdk-export'\n.*?^when 'sdk-regate'/m]
    refute_nil export, 'could not locate the sdk-export arm'
    assert_includes export, 'ControlLint.lint(flat, scope: load_control_scope(opts[:dir]))'
    refute_includes export, "'control-scope.json'"
  end
end

class SdkHybridCliTest < Minitest::Test
  SCRIPT = File.join(__dir__, 'fidelity-loop.rb')
  # Sigma REST + phase6-parity children stubbed. The live workbook lives in
  # <work>/live.json so the test can play an SDK write between CLI calls.
  TRANSPORT = <<~'RUBY'
    require 'json'
    require 'open3'
    module Kernel
      def system(*)
        raise 'subprocess renderer forbidden in this offline fixture'
      end
    end
    module Sigma
      class Error < StandardError; end
      def self.live_path
        ENV.fetch('SDK_LIVE')
      end
      def self.log(entry)
        File.open(ENV.fetch('SDK_REQUESTS'), 'a') { |f| f.puts(entry) }
      end
      def self.list_entries(*)
        return nil.fetch(:x) if ENV['SDK_FAIL'] == 'columns-unread'
        ENV['SDK_FAIL'] == 'error-column' ? [{ 'elementId' => 'heading', 'columnId' => 'c', 'type' => { 'type' => 'error' } }] : []
      end
      def self.request(method, path, body: nil, **_options)
        spec = JSON.parse(File.read(live_path))
        log(method)
        if method == :get && path.include?('?includeContents=true')
          return spec.reject { |key, _value| key == 'latestVersion' } if ENV['SDK_FAIL'] == 'version-unread'
          return spec
        elsif method == :put && path.end_with?('/contents')
          payload = JSON.parse(body)
          raise Error, 'stale precondition' unless payload['documentVersion'] == spec['latestVersion']
          File.write(live_path, JSON.generate('latestVersion' => spec['latestVersion'] + 1, 'contents' => payload['contents']))
          return { 'workbookId' => 'wb-fixture' }
        end
        raise Error, "unexpected #{method} #{path}; live access forbidden"
      end
    end
    $LOADED_FEATURES << ENV.fetch('SDK_REAL_CLIENT')
    StubStatus = Struct.new(:exitstatus) do
      def success?
        exitstatus.zero?
      end
    end
    module Open3
      def self.capture2e(*argv)
        work = argv[argv.index('--tableau') + 1]
        File.open(ENV.fetch('SDK_CHILDREN'), 'a') { |f| f.puts(JSON.generate(argv.drop(2))) }
        if argv.include?('--finalize')
          code = Integer(ENV['SDK_P6_FINALIZE_EXIT'] || '0')
          return [code == 2 ? "DIVERGE [bar] Sales\n" : "PASS [bar] Sales\n", StubStatus.new(code)]
        end
        File.write(File.join(work, 'parity-plan.json'), JSON.generate('charts' => [{ 'chart' => 'Sales', 'sigma_columns' => ['x'] }]))
        actuals = ENV['SDK_P6_INCOMPLETE'] ? {} : { 'Sales' => [['East', 1]] }
        File.write(File.join(work, 'parity-actuals.json'), JSON.generate(actuals))
        ["plan built\n", StubStatus.new(0)]
      end
    end
  RUBY

  def doc(body, version)
    { 'latestVersion' => version, 'contents' => {
      'schemaVersion' => 4, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p', 'name' => 'Overview' }],
      'elements' => [{ 'id' => 'heading', 'kind' => 'text', 'name' => 'Heading', 'body' => body }],
      'layout' => '<Page id="p"><Element elementId="heading" gridColumn="1 / 25" gridRow="1 / 3"/></Page>'
    } }
  end

  def setup
    @work = Dir.mktmpdir
    @live = File.join(@work, 'live.json')
    File.write(@live, JSON.generate(doc('Before', 7)))
    File.write(File.join(@work, 'fidelity-ledger.json'), JSON.generate(
      'workbook_id' => 'wb-fixture', 'page_id' => 'p', 'max_passes' => 5, 'pass' => 1, 'renders' => [],
      'started_at' => Time.now.utc.iso8601, 'max_seconds' => 600,
      'entries' => [{ 'id' => 'e0', 'pass' => 1, 'dimension' => 'palette', 'delta' => 'blue vs teal',
                      'cls' => 'spec-fixable', 'resolved' => false }]))
    File.write(File.join(@work, 'wb-spec.json'), JSON.generate('document' => doc('Before', 7)['contents']))
    File.write(File.join(@work, 'phase6-success.json'), '{"verdict":"GREEN"}')
    File.write(File.join(@work, 'transport.rb'), TRANSPORT)
    File.write(File.join(@work, 'prog.py'), "page.get('heading').set_text('After')\n")
    File.write(File.join(@work, 'out.txt'), "ok\n")
    @env = { 'HOME' => @work, 'SDK_LIVE' => @live, 'SDK_REQUESTS' => File.join(@work, 'requests'),
             'SDK_CHILDREN' => File.join(@work, 'children'), 'SDK_REAL_CLIENT' => File.join(__dir__, 'lib/sigma_rest.rb'),
             # Belt and braces: should the transport ever miss, the real client has no credentials.
             'SIGMA_API_TOKEN' => nil, 'SIGMA_BASE_URL' => nil, 'SIGMA_CLIENT_ID' => nil, 'SIGMA_CLIENT_SECRET' => nil,
             'SIGMA_CLI_PROFILE' => nil, 'SIGMA_WORKDIR' => nil, 'SIGMA_AUTH_MODE' => 'client-credentials' }
  end

  def teardown
    FileUtils.rm_rf(@work)
  end

  def cli(*args, env: {})
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    Open3.capture2e(@env.merge(env), RbConfig.ruby, '-r', File.join(@work, 'transport.rb'), SCRIPT, *args, '--workdir', @work)
  end

  def ledger
    JSON.parse(File.read(File.join(@work, 'fidelity-ledger.json')))
  end

  def pending?
    File.exist?(File.join(@work, 'repair-pending.json'))
  end

  # Play one SDK build_workbook call against the live fixture, then record it.
  def sdk_write!(body, version, *extra, env: {})
    File.write(@live, JSON.generate(doc(body, version)))
    cli('sdk-write', '--program', File.join(@work, 'prog.py'), '--result', File.join(@work, 'out.txt'),
        '--summary', "set heading to #{body}", *extra, env: env)
  end

  def assert_ok(result, code = 0)
    output, status = result
    assert_equal code, status.exitstatus, output
    output
  end

  def test_happy_path_export_back_and_regate
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert pending?, 'an open session holds repair-pending.json'
    assert_ok sdk_write!('After', 8, '--claims', 'e0')
    refute ledger['entries'][0]['resolved'], 'claims resolve only after the export re-gates'
    out = assert_ok cli('sdk-export')
    assert_match(/parity PASS/, out)
    refute pending?
    l = ledger
    assert_equal 'exported', l.dig('sdk', 'state')
    assert l['entries'][0]['resolved']
    assert_equal({ 'route' => 'sdk', 'session' => 's1', 'writes' => ['w1'] }, l['entries'][0]['resolved_via'])
    write = l.dig('sdk', 'sessions', 0, 'writes', 0)
    assert_equal '8', write['document_version']
    assert_equal Digest::SHA256.file(File.join(@work, 'prog.py')).hexdigest, write['program_sha256']
    assert File.file?(File.join(@work, write['program_path'])), 'the program is kept locally under sdk-writes/'
    local = JSON.parse(File.read(File.join(@work, 'wb-spec.json')))
    assert_equal 'After', local.fetch('document').fetch('elements').first['body'], 'wb-spec.json is the exported live spec'
    assert_equal 'After', JSON.parse(File.read(File.join(@work, 'wb-readback.json'))).dig('contents', 'elements', 0, 'body')
    refute File.exist?(File.join(@work, 'phase6-success.json')), 'stale completion evidence archived'
    children = File.readlines(File.join(@work, 'children')).map { |l2| JSON.parse(l2) }
    assert_equal 2, children.length
    assert_includes children[0], '--workbook-id'
    assert_includes children[1], '--finalize'
    assert_ok cli('status')
    assert_empty FidelityLoop.unresolved_specfixable(l), 'gate 8d logic accepts the SDK-resolved entry'
    assert_empty FidelityLoop.unresolved_data(l)
    assert_nil SdkRoute.finalize_block_reason(l)
  end

  def test_render_and_verify_complete_blocked_while_open
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok cli('render'), 4
    assert_ok cli('apply-patch', '--patch', File.join(@work, 'prog.py')), 4
    output, status = Open3.capture2e(@env, RbConfig.ruby, File.join(__dir__, 'verify-complete.rb'), '--workdir', @work)
    assert_equal 12, status.exitstatus, output
    assert_match(/session is open/, assert_ok(cli('status'), 6))
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma'), 4
  end

  def test_failed_write_requires_reread
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('Half', 8, '--status', 'failed'), 2 # --error missing
    assert_ok sdk_write!('Half', 8, '--status', 'failed', '--error', 'ValueError: bad literal')
    assert_ok sdk_write!('After', 9, '--claims', 'e0'), 2
    assert_ok cli('sdk-export'), 2
    File.write(File.join(@work, 'describe.txt'), "heading: Half\n")
    assert_ok cli('sdk-reread', '--evidence', File.join(@work, 'describe.txt'))
    assert_ok sdk_write!('After', 9, '--claims', 'e0')
    assert_ok cli('sdk-export')
    assert_equal 1, ledger.dig('sdk', 'sessions', 0, 'rereads').length
  end

  def test_sdk_write_can_retry_after_version_read_failure
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_match(/re-run sdk-write/, assert_ok(sdk_write!('After', 8, env: { 'SDK_FAIL' => 'version-unread' }), 4))
    refute Dir.exist?(File.join(@work, 'sdk-writes', 's1-w1'))
    assert_ok sdk_write!('After', 8)
    assert_equal '8', ledger.dig('sdk', 'sessions', 0, 'writes', 0, 'document_version')
  end

  def test_export_refuses_unrecorded_write
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8, '--claims', 'e0')
    File.write(@live, JSON.generate(doc('Edited in the UI', 9)))
    assert_match(/UNRECORDED/, assert_ok(cli('sdk-export'), 4))
    assert pending?
    refute ledger['entries'][0]['resolved']
  end

  def test_export_retry_after_guard_failure
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8, '--claims', 'e0')
    assert_match(/type=error/, assert_ok(cli('sdk-export', env: { 'SDK_FAIL' => 'error-column' }), 5))
    assert pending?, 'a guard failure keeps the session open'
    assert_equal 'export-failed', ledger.dig('sdk', 'state')
    refute ledger['entries'][0]['resolved']
    assert_match(/column-type guard did not run/, assert_ok(cli('sdk-export', env: { 'SDK_FAIL' => 'columns-unread' }), 5))
    assert_ok sdk_write!('Fixed', 9)
    assert_ok cli('sdk-export')
    assert ledger['entries'][0]['resolved']
    assert_equal 3, ledger.dig('sdk', 'sessions', 0, 'exports').length
  end

  def test_parity_divergence_adds_data_entry_then_new_session_clears_it
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8, '--claims', 'e0')
    assert_ok cli('sdk-export', env: { 'SDK_P6_FINALIZE_EXIT' => '2' }), 7
    l = ledger
    assert_equal 'parity-failed', l.dig('sdk', 'state')
    data = l['entries'].select { |e| e['cls'] == 'data' && !e['resolved'] }
    assert_equal 1, data.length
    assert_equal 1, FidelityLoop.unresolved_data(l).length, 'shared gate 8d blocks a data-class entry unconditionally'
    assert_ok cli('status'), 6
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('Corrected', 9)
    assert_ok cli('sdk-export')
    assert_empty FidelityLoop.unresolved_data(ledger)
    assert_ok cli('status')
  end

  def test_parity_unverified_then_regate_with_supplied_actuals
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8)
    assert_match(/unverified/, assert_ok(cli('sdk-export', env: { 'SDK_P6_INCOMPLETE' => '1' }), 5))
    assert_equal 'parity-unverified', ledger.dig('sdk', 'state')
    assert_ok cli('status'), 6
    File.write(File.join(@work, 'agent-actuals.json'), JSON.generate('Sales' => [['East', 1]]))
    assert_ok cli('sdk-regate', '--actuals', File.join(@work, 'agent-actuals.json'))
    assert_equal 'exported', ledger.dig('sdk', 'state')
    File.write(@live, JSON.generate(doc('Later edit', 9)))
    assert_ok cli('sdk-regate'), 4
  end

  def test_rollback_closes_session
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8, '--claims', 'e0')
    assert_ok cli('sdk-export', env: { 'SDK_FAIL' => 'error-column' }), 5
    checkpoint = ledger.dig('sdk', 'sessions', 0, 'checkpoint')
    assert_ok cli('rollback', '--checkpoint', checkpoint)
    assert_equal 'Before', JSON.parse(File.read(@live)).dig('contents', 'elements', 0, 'body')
    assert_equal 'rolled-back', ledger.dig('sdk', 'state')
    refute pending?
    assert_nil SdkRoute.finalize_block_reason(ledger)
  end

  def test_rollback_without_export_and_refusing_unrecorded_write
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8, '--claims', 'e0')
    checkpoint = ledger.dig('sdk', 'sessions', 0, 'checkpoint')
    File.write(@live, JSON.generate(doc('Edited in the UI', 9)))
    assert_match(/record the unrecorded write/, assert_ok(cli('rollback', '--checkpoint', checkpoint), 4))
    File.write(@live, JSON.generate(doc('After', 8)))
    assert_ok cli('rollback', '--checkpoint', checkpoint)
    assert_equal 'Before', JSON.parse(File.read(@live)).dig('contents', 'elements', 0, 'body')
    assert_equal 'rolled-back', ledger.dig('sdk', 'state')
  end

  def test_recover_reconciles_open_session_and_a_new_session_can_export
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8)
    assert_ok cli('recover')
    assert_equal 'reconciled', ledger.dig('sdk', 'state')
    assert_match(/reconciled/, SdkRoute.finalize_block_reason(ledger))
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok cli('sdk-export')
    assert_nil SdkRoute.finalize_block_reason(ledger)
  end

  # ---- 2026-11-05 live-proof rough edges (fixtures/sdk-hybrid-live-proof) ----

  # Edge 1: an unverified parity re-gate keeps the session open, so the next
  # fix is a recorded sdk-write (the live run's v13/v14 writes went unrecorded).
  def test_parity_unverified_keeps_session_open_for_more_writes
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8, '--claims', 'e0')
    out = assert_ok cli('sdk-export', env: { 'SDK_P6_INCOMPLETE' => '1' }), 5
    assert_match(/session stays OPEN/, out)
    assert_match(/sdk-regate/, out)
    assert pending?, 'an unverified re-gate keeps repair-pending.json'
    assert_equal 'parity-unverified', ledger.dig('sdk', 'state')
    assert_match(/sdk-regate/, assert_ok(cli('render'), 4))
    assert_ok sdk_write!('Fixed', 9)
    assert_equal 'open', ledger.dig('sdk', 'state'), 'a write after the export makes the exported spec stale'
    assert_equal 1, ledger.dig('sdk', 'sessions').length, 'the same session, no fresh sdk-begin'
    assert_ok cli('sdk-export')
    refute pending?
    assert_equal 'exported', ledger.dig('sdk', 'state')
    assert_equal 'Fixed', JSON.parse(File.read(File.join(@work, 'wb-spec.json'))).dig('document', 'elements', 0, 'body')
  end

  def test_parity_unverified_regate_releases_the_session
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8)
    assert_ok cli('sdk-export', env: { 'SDK_P6_INCOMPLETE' => '1' }), 5
    File.write(File.join(@work, 'agent-actuals.json'), JSON.generate('Sales' => [['East', 1]]))
    assert_ok cli('sdk-regate', '--actuals', File.join(@work, 'agent-actuals.json'), env: { 'SDK_P6_FINALIZE_EXIT' => '2' }), 7
    refute pending?, 'a divergence closes the session (fix in a new one)'
    assert_equal 'parity-failed', ledger.dig('sdk', 'state')
  end

  # Review follow-up: an sdk-export killed during its parity subprocess leaves
  # parity-unverified without the marker; the next SDK command re-holds it.
  def test_interrupted_export_marker_self_heals
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8)
    assert_ok cli('sdk-export', env: { 'SDK_P6_INCOMPLETE' => '1' }), 5
    File.delete(File.join(@work, 'repair-pending.json'))
    File.write(File.join(@work, 'agent-actuals.json'), JSON.generate('Sales' => [['East', 1]]))
    out = assert_ok cli('sdk-regate', '--actuals', File.join(@work, 'agent-actuals.json'))
    assert_match(/re-held repair-pending.json/, out)
    assert_equal 'exported', ledger.dig('sdk', 'state')
    refute pending?
  end

  # Edge 1 (message): a closed session names the next command.
  def test_write_after_closed_session_names_next_command
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8)
    assert_ok cli('sdk-export', env: { 'SDK_P6_FINALIZE_EXIT' => '2' }), 7
    out = assert_ok sdk_write!('Again', 9), 2
    assert_match(/parity-failed/, out)
    assert_match(/sdk-begin/, out)
  end

  # Edge 2: status checks the live version against the last export.
  def test_status_refuses_version_drift_after_export
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    assert_ok sdk_write!('After', 8, '--claims', 'e0')
    assert_ok cli('sdk-export')
    assert_ok cli('status')
    File.write(@live, JSON.generate(doc('Drift probe', 9)))
    out = assert_ok cli('status'), 6
    assert_match(/document version 9, but the SDK route last exported 8/, out)
    refute_match(/satisfies the gate/, out)
    assert_match(/could not be read/, assert_ok(cli('status', env: { 'SDK_FAIL' => 'version-unread' }), 6))
    l = ledger.merge('workbook_id' => '')
    File.write(File.join(@work, 'fidelity-ledger.json'), JSON.generate(l))
    assert_match(/no workbook_id/, assert_ok(cli('status'), 6))

  end

  # Edge 3: a clean open session explains itself instead of "unverified write outcome".
  def test_render_refusal_names_the_open_sdk_session
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    out = assert_ok cli('render'), 4
    assert_match(/SDK session s1 is open/, out)
    assert_match(/sdk-export/, out)
    refute_match(/unverified write outcome/, out)
    assert_match(/SDK session s1 is open/, assert_ok(cli('sdk-begin', '--mcp-server', 'sigma'), 4))
    assert_ok sdk_write!('Half', 8, '--status', 'failed', '--error', 'ValueError')
    assert_match(/sdk-reread/, assert_ok(cli('render'), 4))
  end

  # Edge 4: the elapsed-time budget binds render and sdk-begin once expired.
  def test_expired_time_budget_blocks_render_and_begin
    l = ledger.merge('started_at' => (Time.now.utc - 3600).iso8601, 'max_seconds' => 1800)
    File.write(File.join(@work, 'fidelity-ledger.json'), JSON.generate(l))
    assert_match(/budget exhausted/, assert_ok(cli('render'), 3))
    assert_equal 1, ledger['pass'], 'a refused render consumes no pass'
    assert_match(/budget exhausted/, assert_ok(cli('sdk-begin', '--mcp-server', 'sigma'), 3))
    refute pending?
    assert_empty Dir.glob(File.join(@work, 'repair-checkpoints', '*'))
  end

  # Edge 4: an SDK call that already ran is still recorded after expiry, so the
  # ledger never loses it; the session then needs an export or a rollback.
  def test_write_after_budget_expiry_is_recorded_then_blocks
    assert_ok cli('sdk-begin', '--mcp-server', 'sigma')
    l = ledger.merge('started_at' => (Time.now.utc - 3600).iso8601, 'max_seconds' => 1800)
    File.write(File.join(@work, 'fidelity-ledger.json'), JSON.generate(l))
    out = assert_ok sdk_write!('After', 8), 3
    assert_match(/budget exhausted/, out)
    assert_equal '8', ledger.dig('sdk', 'sessions', 0, 'writes', 0, 'document_version'), 'the write is in the ledger'
    assert ledger.dig('sdk', 'sessions', 0, 'writes', 0, 'over_budget')
  end

  def test_begin_requires_render_budget
    l = ledger.merge('pass' => 5)
    File.write(File.join(@work, 'fidelity-ledger.json'), JSON.generate(l))
    assert_match(/pass budget spent/, assert_ok(cli('sdk-begin', '--mcp-server', 'sigma'), 2))
    refute pending?
    assert_empty Dir.glob(File.join(@work, 'repair-checkpoints', '*'))
  end
end
