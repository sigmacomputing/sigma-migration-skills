#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative 'lib/mcp_source'
require_relative 'test-wave1-support'

class McpSourceTest < Minitest::Test
  def build(dir)
    Wave1Fixture.build(dir, empty_views: [], has_extracts: false)
    gw = JSON.parse(File.read(File.join(dir, 'get-workbook.json')))
    gw['workbook']['id'] = 'wb-fixture'
    gw['workbook']['updatedAt'] = '2025-01-01T00:00:00Z'
    views = gw['workbook']['views']['view']
    views.each_with_index { |v, i| v['id'] = "view-#{i}" }
    File.write(File.join(dir, 'get-workbook.json'), JSON.generate(gw))
    File.write(File.join(dir, 'views/view-0.csv'), "Region,Sales\nEast,10\nWest,20\n")
    File.write(File.join(dir, 'views/view-1.csv'), "Month,Sales\n2025-01-01,10\n")
    FileUtils.mkdir_p(File.join(dir, 'dashboards'))
    # Minimal header for the local ingestion check, not a visual attestation.
    png = "\x89PNG\r\n\x1a\n".b + [13].pack('N') + 'IHDR' + [10, 10].pack('NN')
    %w[Alpha_Overview Beta_Detail].each { |n| File.binwrite(File.join(dir, 'dashboards', "#{n}.png"), png) }
    gw
  end

  def test_missing_evidence_returns_scoped_mcp_requests_without_deleting_source
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'local.twb'), Wave1Fixture::TWB)
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, twb: File.join(dir, 'local.twb'), dashboards: ['Alpha Overview']) }
      request = JSON.parse(File.read(File.join(dir, 'mcp-evidence-request.json')))
      assert_equal ['Alpha Sales'], request['worksheets']
      assert_equal ['Alpha Overview'], request['dashboards']
      assert_equal Wave1Fixture::TWB, File.read(File.join(dir, 'local.twb'), encoding: 'UTF-8')
      assert_equal Wave1Fixture::TWB, File.read(File.join(dir, 'workbook-content.twb'), encoding: 'UTF-8')
      refute File.exist?(File.join(dir, 'discovery-stamp.json'))
    end
  end

  def test_utf16_twb_is_snapshotted_as_utf8
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'windows.twb')
      File.binwrite(source, "\xFF\xFE".b + Wave1Fixture::TWB.encode('UTF-16LE').b)
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, twb: source) }
      assert_equal Wave1Fixture::TWB, File.binread(File.join(dir, 'workbook-content.twb')).force_encoding('UTF-8')
    end
  end

  def test_matching_utf16_workdir_snapshot_is_rewritten_as_utf8
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'windows.twb')
      canonical = File.join(dir, 'workbook-content.twb')
      utf16 = "\xFF\xFE".b + Wave1Fixture::TWB.encode('UTF-16LE').b
      File.binwrite(source, utf16)
      File.binwrite(canonical, utf16)
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, twb: source) }
      assert_equal Wave1Fixture::TWB, File.binread(canonical).force_encoding('UTF-8')
    end
  end

  def test_sealed_evidence_reuses_and_refuses_modified_csv_or_wrong_identity
    Dir.mktmpdir do |dir|
      build(dir)
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir) }
      McpSource.prepare(dir, workbook_id: 'wb-fixture', seal: true)
      assert_equal 'wb-fixture', McpSource.prepare(dir)['id']
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, workbook_id: 'another-workbook') }
      File.write(File.join(dir, 'views/view-0.csv'), "Region,Sales\nEast,999\n")
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir) }
      assert_includes File.read(File.join(dir, 'views/view-0.csv')), '999'
    end
  end

  def test_changed_twb_preserves_existing_snapshot
    Dir.mktmpdir do |dir|
      build(dir)
      changed = File.join(dir, 'changed.twb')
      File.write(changed, Wave1Fixture::TWB.sub('Alpha Sales', 'Changed Sales'))
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, twb: changed) }
      assert_equal Wave1Fixture::TWB, File.read(File.join(dir, 'workbook-content.twb'), encoding: 'UTF-8')
    end
  end

  def test_malformed_metadata_and_truncated_images_are_named_stops
    Dir.mktmpdir do |dir|
      metadata = build(dir)
      File.write(File.join(dir, 'get-workbook.json'), '[]')
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, seal: true) }
      File.write(File.join(dir, 'get-workbook.json'), JSON.generate(metadata))
      File.binwrite(File.join(dir, 'dashboards/Alpha_Overview.png'), "\x89PNG\r\n\x1a\n".b)
      error = assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, seal: true) }
      assert_includes error.message, 'not a PNG image'
      refute File.exist?(File.join(dir, 'source-evidence.json'))
    end
  end

  def test_real_orchestrator_never_calls_tableau_on_no_pat_route
    Dir.mktmpdir do |dir|
      build(dir)
      # No discovery stamp/timing trick is needed on the explicit file route.
      File.delete(File.join(dir, 'discovery-stamp.json'))
      File.delete(File.join(dir, 'timings.json'))
      McpSource.prepare(dir, workbook_id: 'wb-fixture', seal: true)
      Wave1Fixture.verified_png_read(dir)
      guard = File.join(dir, 'forbid-tableau.rb')
      File.write(guard, <<~RUBY)
        require #{File.join(__dir__, 'lib/tableau_rest.rb').inspect}
        module Tableau
          class << self
            def request(*); abort 'FORBIDDEN TABLEAU REQUEST'; end
            def refresh_token!(*); abort 'FORBIDDEN TABLEAU SIGNIN'; end
            def graphql(*); abort 'FORBIDDEN TABLEAU GRAPHQL'; end
          end
        end
      RUBY
      env = Wave1Fixture.hermetic_env(dir).merge(
        'TABLEAU_PAT_NAME' => nil, 'TABLEAU_PAT_SECRET' => nil, 'TABLEAU_AUTH_TOKEN' => nil,
        'TABLEAU_SITE_ID' => nil, 'TABLEAU_SERVER_URL' => nil, 'TABLEAU_SITE_CONTENT_URL' => nil,
        'RUBYOPT' => "-r#{guard}"
      )
      out, status = Open3.capture2e(env, RbConfig.ruby, Wave1Fixture::ORCH,
                                   *Wave1Fixture::BASE_ARGS, '--out', dir,
                                   '--twb', File.join(dir, 'workbook-content.twb'), '--folder', 'fold-x', '--yes')
      refute_includes out, 'FORBIDDEN TABLEAU'
      refute_includes out, 'no Tableau credentials'
      assert_includes out, 'sealed local TWB + MCP exports'
      assert_includes out, 'Phase 3/6'
      # Sigma deliberately points at a refused localhost endpoint in this test.
      refute_equal 0, status.exitstatus
      assert File.exist?(File.join(dir, 'views/view-0.csv'))
    end
  end

  def test_default_workdir_evidence_keeps_the_mcp_route
    Dir.mktmpdir do |home|
      workbook = 'https://tableau.example/#/site/demo/views/DefaultResume/View'
      slug = workbook.gsub(/[^A-Za-z0-9_-]/, '-').squeeze('-')
      workdir = File.join(home, 'tableau-migration', slug)
      FileUtils.mkdir_p(workdir)
      File.write(File.join(workdir, 'source-evidence.json'), '{}')
      guard = File.join(home, 'forbid-tableau.rb')
      File.write(guard, <<~RUBY)
        require #{File.join(__dir__, 'lib/tableau_rest.rb').inspect}
        module Tableau
          class << self
            def request(*); abort 'FORBIDDEN TABLEAU REQUEST'; end
            def refresh_token!(*); abort 'FORBIDDEN TABLEAU SIGNIN'; end
          end
        end
      RUBY
      env = { 'HOME' => home, 'SIGMA_TABLEAU_VIA_MCP' => nil, 'RUBYOPT' => "-r#{guard}" }
      out, status = Open3.capture2e(env, RbConfig.ruby, Wave1Fixture::ORCH, '--workbook', workbook)
      refute status.success?
      assert_includes out, 'missing --connection'
      refute_includes out, 'FORBIDDEN TABLEAU'
    end
  end
end
