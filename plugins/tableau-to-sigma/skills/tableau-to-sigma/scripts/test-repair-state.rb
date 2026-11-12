#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/repair_state'

class RepairStateTest < Minitest::Test
  TRANSPORT = <<~'RUBY'
    require 'json'
    module Kernel
      def system(*)
        raise 'subprocess renderer forbidden in this offline fixture'
      end
    end
    module Sigma
      class Error < StandardError; end
      def self.list_entries(*)
        raise Error, 'synthetic unreadable columns' if ENV['REPAIR_FAILURE'] == 'columns'
        []
      end
      def self.request(method, path, body: nil, **options)
        state = ENV.fetch('REPAIR_FIXTURE') + '.live'
        @spec ||= JSON.parse(File.read(File.file?(state) ? state : ENV.fetch('REPAIR_FIXTURE')))
        File.open(ENV.fetch('REPAIR_REQUESTS'), 'a') { |file| file.puts(method) }
        if method == :get && path.include?('?includeContents=true')
          if @written
            @spec['latestVersion'] = 9 if ENV['REPAIR_FAILURE'] == 'changed-version'
            @spec.delete('latestVersion') if ENV['REPAIR_FAILURE'] == 'unversioned'
          end
          return @spec
        elsif method == :put && path.end_with?('/contents')
          payload = JSON.parse(body)
          raise Error, 'update must carry only contents and numeric version precondition' unless
            payload.keys.sort == %w[contents documentVersion] && payload['documentVersion'] == @spec['latestVersion']
          @spec = { 'latestVersion' => @spec['latestVersion'] + 1, 'contents' => payload['contents'] }
          File.write(state, JSON.generate(@spec))
          @written = true
          raise Error, 'synthetic lost response after write' if ENV['REPAIR_FAILURE'] == 'lost-response'
          return { 'workbookId' => 'wb-fixture' }
        end
        raise Error, 'unexpected operation; live access forbidden'
      end
    end
    $LOADED_FEATURES << ENV.fetch('REPAIR_REAL_CLIENT')
  RUBY

  def test_real_repair_entrypoint_checkpoints_and_blocks_an_unknown_write_outcome
    [nil, 'lost-response', 'changed-version', 'unversioned', 'columns'].each do |failure|
      Dir.mktmpdir do |work|
        script = File.join(__dir__, 'fidelity-loop.rb')
        guard = File.join(work, 'transport.rb')
        File.write(guard, TRANSPORT)
        File.write(File.join(work, 'fixture.json'), JSON.generate('latestVersion' => 7, 'contents' => {
          'schemaVersion' => 4, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p', 'name' => 'Overview' }],
          'futureSetting' => { 'preserve' => true },
          'elements' => [{ 'id' => 'heading', 'kind' => 'text', 'name' => 'Heading', 'body' => 'Before' }],
          'layout' => '<Page id="p"><Element elementId="heading" gridColumn="1 / 25" gridRow="1 / 3"/></Page>'
        }))
        File.write(File.join(work, 'fidelity-ledger.json'), JSON.generate('workbook_id' => 'wb-fixture', 'page_id' => 'p',
          'max_passes' => 5, 'pass' => 0, 'entries' => [], 'renders' => [], 'started_at' => Time.now.utc.iso8601, 'max_seconds' => 60))
        File.write(File.join(work, 'patch.json'), JSON.generate('elements' => [{ 'id' => 'heading', 'body' => 'After' }]))
        File.write(File.join(work, 'wb-spec.json'), JSON.generate('document' => {
          'schemaVersion' => 4, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p', 'name' => 'Overview' }],
          'elements' => [], 'layout' => '<Page id="p"/>'
        }))
        File.write(File.join(work, 'phase6-success.json'), '{"verdict":"GREEN"}')
        env = { 'HOME' => work, 'REPAIR_FIXTURE' => File.join(work, 'fixture.json'), 'REPAIR_REQUESTS' => File.join(work, 'requests'),
                'REPAIR_REAL_CLIENT' => File.join(__dir__, 'lib/sigma_rest.rb'), 'REPAIR_FAILURE' => failure }
        output, status = Open3.capture2e(env, RbConfig.ruby, '-r', guard, script, 'apply-patch', '--workdir', work,
                                       '--patch', File.join(work, 'patch.json'))
        assert_equal(failure == 'columns' ? 5 : (failure ? 4 : 0), status.exitstatus, output)
        assert_equal 1, File.readlines(File.join(work, 'requests')).count { |line| line.strip == 'put' }
        checkpoints = Dir.glob(File.join(work, 'repair-checkpoints', '*', 'manifest.json'))
        assert_equal 1, checkpoints.size
        assert_equal '7', JSON.parse(File.read(checkpoints.first))['document_version']
        if failure
          assert File.exist?(File.join(work, 'repair-pending.json'))
          count_before = File.readlines(File.join(work, 'requests')).size
          output, status = Open3.capture2e(env, RbConfig.ruby, '-r', guard, script, 'render', '--workdir', work)
          assert_equal 4, status.exitstatus, output
          assert_equal count_before, File.readlines(File.join(work, 'requests')).size
          output, status = Open3.capture2e(env, RbConfig.ruby, File.join(__dir__, 'verify-complete.rb'), '--workdir', work)
          assert_equal 12, status.exitstatus, output
          if failure == 'columns'
            checkpoint_id = File.basename(File.dirname(checkpoints.first))
            output, status = Open3.capture2e(env, RbConfig.ruby, '-r', guard, script, 'rollback', '--workdir', work, '--checkpoint', checkpoint_id)
            assert_equal 'Before', JSON.parse(File.read(File.join(work, 'fixture.json.live'))).dig('contents', 'elements', 0, 'body')
          else
            output, status = Open3.capture2e(env, RbConfig.ruby, script, 'recover', '--workdir', work)
          end
          assert status.success?, output
        end
        refute File.exist?(File.join(work, 'phase6-success.json'))
        refute File.exist?(File.join(work, 'repair-pending.json'))
        unless failure
          local = JSON.parse(File.read(File.join(work, 'wb-spec.json')))
          assert_equal 'text', local.fetch('document').fetch('elements').first['kind'], 'persist the complete live candidate, not a partial patch over stale local state'
          assert_equal({ 'preserve' => true }, local.dig('document', 'futureSetting'))
          unbound = JSON.parse(File.read(File.join(work, 'fixture.json')))
          unbound.delete('latestVersion')
          File.write(File.join(work, 'full-spec.json'), JSON.generate(unbound))
          output, status = Open3.capture2e(env, RbConfig.ruby, '-r', guard, script, 'apply-patch', '--workdir', work,
                                         '--full-spec', File.join(work, 'full-spec.json'))
          assert_equal 4, status.exitstatus, output
          assert_includes output, 'base spec has no version'
          assert_equal 1, File.readlines(File.join(work, 'requests')).count { |line| line.strip == 'put' }
        end
      end
    end
  end

  def test_checkpoint_is_version_bound_and_stale_evidence_is_preserved_not_reused
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'phase6-success.json'), '{"verdict":"GREEN"}')
      File.write(File.join(work, 'PUNCHLIST.md'), 'old report')
      File.write(File.join(work, 'auth.json'), 'synthetic-private-auth')
      File.write(File.join(work, 'wb-spec.json'), '{"local":"before"}')
      original = { 'latestVersion' => 7, 'contents' => { 'elements' => [] } }
      directory = RepairState.checkpoint(work, 'synthetic-workbook', original)
      manifest = JSON.parse(File.read(File.join(directory, 'manifest.json')))
      assert_equal '7', manifest['document_version']
      assert_equal 'checkpoint-not-a-pass', manifest['status']
      assert_equal Digest::SHA256.file(File.join(directory, 'workbook-spec.json')).hexdigest, manifest['files']['workbook-spec.json']
      refute File.exist?(File.join(directory, 'auth.json'))
      assert_equal '{"local":"before"}', File.read(File.join(directory, 'wb-spec.json'))
      RepairState.begin_write(work, directory)
      assert File.exist?(File.join(work, 'repair-pending.json'))
      assert_raises(RepairState::Error) { RepairState.begin_write(work, directory) }
      RepairState.invalidate(work, directory)
      refute File.exist?(File.join(work, 'phase6-success.json'))
      refute File.exist?(File.join(work, 'PUNCHLIST.md'))
      assert_equal 'old report', File.read(File.join(directory, 'prior-evidence/PUNCHLIST.md'))
      refute File.exist?(File.join(work, 'repair-pending.json'))
      assert_equal original, JSON.parse(File.read(File.join(directory, 'workbook-spec.json')))
    end
  end

  def test_missing_version_and_exhausted_time_fail_closed
    Dir.mktmpdir do |work|
      assert_raises(RepairState::Error) { RepairState.checkpoint(work, 'wb', {}) }
      assert_raises(RepairState::Error) { RepairState.checkpoint(work, 'wb', { 'documentVersion' => 2, 'latestVersion' => 3 }) }
    end
    start = Time.utc(2025, 1, 1)
    ledger = { 'started_at' => start.iso8601, 'max_seconds' => 60 }
    RepairState.check_budget!(ledger, now: start + 59)
    assert_raises(RepairState::Error) { RepairState.check_budget!(ledger, now: start + 60) }
    assert_raises(RepairState::Error) { RepairState.check_budget!(ledger, now: start - 1) }
    assert_raises(RepairState::Error) { RepairState.check_budget!({}) }
    [{ 'started_at' => start.iso8601 }, { 'max_seconds' => 60 },
     { 'started_at' => 'invalid', 'max_seconds' => 60 },
     { 'started_at' => start.iso8601, 'max_seconds' => -1 },
     { 'started_at' => start.iso8601, 'max_seconds' => '60' }].each do |invalid|
      assert_raises(RepairState::Error) { RepairState.check_budget!(invalid, now: start) }
    end
  end

  def test_deadline_interrupts_requests_and_reaps_renderer
    ledger = { 'started_at' => Time.now.utc.iso8601(6), 'max_seconds' => 0.05 }
    assert_raises(RepairState::Error) { RepairState.with_budget(ledger) { sleep 5 } }
    Dir.mktmpdir do |work|
      pid_path = File.join(work, 'renderer.pid')
      ledger = { 'started_at' => Time.now.utc.iso8601(6), 'max_seconds' => 2 }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(RepairState::Error) do
        RepairState.render(ledger, [RbConfig.ruby, '-e', 'File.write(ARGV[0], Process.pid); sleep 20', pid_path])
      end
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 6
      pid = Integer(File.read(pid_path))
      assert_raises(Errno::ECHILD) { Process.wait(pid, Process::WNOHANG) }
    end
  end

  def test_candidate_mutation_and_unrelated_pending_repair_block_before_network
    Dir.mktmpdir do |work|
      original = { 'latestVersion' => 7, 'contents' => { 'elements' => [] } }
      checkpoint = RepairState.checkpoint(work, 'wb', original)
      RepairState.record_candidate(checkpoint, original.merge('latestVersion' => 8))
      no_network = ->(*) { flunk 'invalid candidate must be refused before network' }
      File.write(File.join(work, 'repair-pending.json'), JSON.generate('checkpoint' => 'another'))
      assert_raises(RepairState::Error) { RepairState.rollback(work, 'wb', File.basename(checkpoint), request: no_network) }
      File.delete(File.join(work, 'repair-pending.json'))
      File.write(File.join(checkpoint, 'candidate-spec.json'), JSON.generate(original.merge('latestVersion' => 9)))
      assert_raises(RepairState::Error) { RepairState.rollback(work, 'wb', File.basename(checkpoint), request: no_network) }
    end
  end

  def test_rollback_restores_live_and_local_state_without_resetting_budgets
    %w[success external-edit lost-response changed-readback].each do |scenario|
      Dir.mktmpdir do |work|
        original = { 'latestVersion' => 7, 'contents' => { 'elements' => [{ 'id' => 'title', 'body' => 'Before' }] } }
        candidate = { 'latestVersion' => 8, 'contents' => { 'elements' => [{ 'id' => 'title', 'body' => 'After' }] } }
        ledger = { 'workbook_id' => 'wb', 'pass' => 1, 'max_passes' => 5,
                   'entries' => [{ 'id' => 'e0', 'resolved' => false }], 'renders' => [] }
        File.write(File.join(work, 'wb-spec.json'), JSON.generate(original))
        File.write(File.join(work, 'fidelity-ledger.json'), JSON.generate(ledger))
        checkpoint = RepairState.checkpoint(work, 'wb', original)
        RepairState.record_candidate(checkpoint, candidate)
        ledger['pass'] = 3
        ledger['entries'][0]['resolved'] = true
        File.write(File.join(work, 'wb-spec.json'), JSON.generate(candidate))
        File.write(File.join(work, 'fidelity-ledger.json'), JSON.generate(ledger))
        File.write(File.join(work, 'phase6-success.json'), 'stale success')
        File.write(File.join(work, 'rcf-pass-3.png'), 'stale image')
        Dir.mkdir(File.join(work, 'visual-qa'))
        File.write(File.join(work, 'visual-qa/page.png'), 'stale page')
        current = Marshal.load(Marshal.dump(candidate))
        current['latestVersion'] = 9 if scenario == 'external-edit'
        calls = []
        request = lambda do |method, _path, body: nil|
          calls << method
          if method == :put
            payload = JSON.parse(body)
            assert_equal %w[contents documentVersion], payload.keys.sort
            assert_equal 8, payload['documentVersion']
            current = { 'latestVersion' => 9, 'contents' => payload['contents'] }
            raise RepairState::Error, 'lost response' if scenario == 'lost-response'
            current['latestVersion'] = 10 if scenario == 'changed-readback'
            { 'workbookId' => 'wb' }
          else
            Marshal.load(Marshal.dump(current))
          end
        end
        if scenario == 'success'
          restored = RepairState.rollback(work, 'wb', File.basename(checkpoint), request: request)
          assert_equal original['contents'], restored['contents']
          assert_equal restored, JSON.parse(File.read(File.join(work, 'wb-spec.json')))
          result_ledger = JSON.parse(File.read(File.join(work, 'fidelity-ledger.json')))
          refute result_ledger['entries'][0]['resolved']
          assert_equal 3, result_ledger['pass']
          assert_equal 5, result_ledger['max_passes']
          refute File.exist?(File.join(work, 'phase6-success.json'))
          refute File.exist?(File.join(work, 'rcf-pass-3.png'))
          refute File.exist?(File.join(work, 'visual-qa'))
          refute File.exist?(File.join(work, 'repair-pending.json'))
        else
          assert_raises(RepairState::Error) { RepairState.rollback(work, 'wb', File.basename(checkpoint), request: request) }
          assert_equal candidate, JSON.parse(File.read(File.join(work, 'wb-spec.json')))
          assert_equal(scenario == 'external-edit' ? 0 : 1, calls.count(:put))
          assert_equal(scenario != 'external-edit', File.exist?(File.join(work, 'repair-pending.json')))
        end
      end
    end
  end

  def test_recovery_refuses_symlink_checkpoints_without_moving_evidence
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'phase6-success.json'), 'old verdict')
      checkpoint = RepairState.checkpoint(work, 'wb', { 'latestVersion' => 7 })
      RepairState.begin_write(work, checkpoint)
      File.rename(checkpoint, "#{checkpoint}-moved")
      File.symlink("#{checkpoint}-moved", checkpoint)
      assert_raises(RepairState::Error) { RepairState.recover(work) }
      assert File.exist?(File.join(work, 'repair-pending.json'))
      assert_equal 'old verdict', File.read(File.join(work, 'phase6-success.json'))
    end
  end

  def test_evidence_archive_cannot_be_redirected_via_symlink
    Dir.mktmpdir do |work|
      checkpoint = RepairState.checkpoint(work, 'wb', { 'latestVersion' => 7 })
      RepairState.begin_write(work, checkpoint)
      File.write(File.join(work, 'phase6-success.json'), 'old verdict')
      Dir.mktmpdir do |outside|
        File.symlink(outside, File.join(checkpoint, 'prior-evidence'))
        assert_raises(RepairState::Error) { RepairState.invalidate(work, checkpoint) }
        assert File.exist?(File.join(work, 'repair-pending.json'))
        assert_empty Dir.children(outside)
      end
    end
  end
end
