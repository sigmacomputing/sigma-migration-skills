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
  def stored_zip(members)
    local, central = +''.b, +''.b
    members.each do |name, bytes|
      name, bytes = name.b, bytes.b
      offset = local.bytesize
      crc = Zlib.crc32(bytes)
      local << ["PK\x03\x04".b, 20, 0, 0, 0, 0, crc, bytes.bytesize, bytes.bytesize, name.bytesize, 0].pack('a4vvvvvVVVvv') << name << bytes
      central << ["PK\x01\x02".b, 20, 20, 0, 0, 0, 0, crc, bytes.bytesize, bytes.bytesize, name.bytesize, 0, 0, 0, 0, 0, offset].pack('a4vvvvvvVVVvvvvvVV') << name
    end
    local + central + ["PK\x05\x06".b, 0, 0, members.size, members.size, central.bytesize, local.bytesize, 0].pack('a4vvvvVVv')
  end

  def test_local_package_reads_only_the_selected_workbook_and_never_extracts_members
    Dir.mktmpdir do |dir|
      build(dir)
      path = File.join(dir, 'local.twbx')
      File.binwrite(path, stored_zip('Nested/source.twb' => Wave1Fixture::TWB, '../escape.txt' => 'synthetic payload', 'Data/source.hyper' => 'not read'))
      result = McpSource.prepare(dir, twb: path, workbook_id: 'wb-fixture', seal: true)
      assert_equal 'wb-fixture', result['id']
      refute Dir.exist?(File.join(dir, 'Data'))
      refute Dir.exist?(File.join(dir, 'Nested'))
      assert_equal Wave1Fixture::TWB, File.read(File.join(dir, 'workbook-content.twb'), encoding: 'UTF-8')
      File.binwrite(path, stored_zip('one.twb' => Wave1Fixture::TWB, 'two.twb' => Wave1Fixture::TWB))
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, twb: path) }
    end
  end

  def test_embedded_worksheet_uses_parent_dashboard_and_sealed_csv_without_fake_view_id
    Dir.mktmpdir do |dir|
      metadata = build(dir)
      views = metadata['workbook']['views']['view']
      parent = views.find { |view| view['name'] == 'Alpha Overview' }
      views.reject! { |view| view['name'] == 'Alpha Sales' }
      File.write(File.join(dir, 'get-workbook.json'), JSON.generate(metadata))
      mapping = [{ 'worksheet' => 'Alpha Sales', 'dashboard_view_id' => parent['id'], 'path' => 'views/view-0.csv' }]
      File.write(File.join(dir, 'mcp-worksheet-files.json'), JSON.generate(mapping))
      McpSource.prepare(dir, dashboards: ['Alpha Overview'], seal: true)
      records = McpSource.views_for(dir, metadata)
      worksheet = records.find { |view| view['name'] == 'Alpha Sales' }
      assert_nil worksheet['id']
      assert_equal parent['id'], worksheet['dashboard_view_id']
      assert_equal File.join(dir, 'views/view-0.csv'), McpSource.csv_path(dir, worksheet)
      request = JSON.parse(File.read(File.join(dir, 'mcp-evidence-request.json')))
      capture = request['requests'].find { |entry| entry['worksheet'] == 'Alpha Sales' }
      assert_equal parent['id'], capture['view_id']
      File.write(File.join(dir, 'views/view-0.csv'), "Region,Sales\nEast,999\n")
      assert_raises(McpSource::Incomplete) { McpSource.views_for(dir, metadata) }
    end
  end

  def test_missing_hidden_worksheet_requests_real_parent_without_inventing_an_id
    Dir.mktmpdir do |dir|
      metadata = build(dir)
      views = metadata['workbook']['views']['view']
      parent = views.find { |view| view['name'] == 'Alpha Overview' }
      views.reject! { |view| view['name'] == 'Alpha Sales' }
      File.write(File.join(dir, 'get-workbook.json'), JSON.generate(metadata))
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, dashboards: ['Alpha Overview'], seal: true) }
      request = JSON.parse(File.read(File.join(dir, 'mcp-evidence-request.json')))
      capture = request['requests'].find { |entry| entry['worksheet'] == 'Alpha Sales' }
      assert_equal parent['id'], capture['view_id']
      assert_equal 'get-view-data', capture['tool']
      assert_equal 'saved-defaults', capture['state']
      assert_equal 'mcp-worksheet-files.json', capture['mapping_file']
      assert_match %r{\Aviews/worksheet-[0-9a-f]{16}\.csv\z}, capture['output']
      refute File.exist?(File.join(dir, 'source-evidence.json'))

      File.write(File.join(dir, capture['output']), "Region,Sales\nEast,10\n")
      File.write(File.join(dir, capture['mapping_file']), JSON.generate([
        { 'worksheet' => capture['worksheet'], 'dashboard_view_id' => capture['view_id'], 'path' => capture['output'] }
      ]))
      McpSource.prepare(dir, dashboards: ['Alpha Overview'], seal: true)
      assert_equal 'ready', JSON.parse(File.read(File.join(dir, 'mcp-evidence-request.json')))['status']
    end
  end

  def test_shared_hidden_worksheet_does_not_guess_which_dashboard_defaults_to_use
    Dir.mktmpdir do |dir|
      metadata = build(dir)
      metadata['workbook']['views']['view'].reject! { |view| view['name'] == 'Alpha Sales' }
      File.write(File.join(dir, 'get-workbook.json'), JSON.generate(metadata))
      File.write(File.join(dir, 'workbook-content.twb'), Wave1Fixture::TWB.sub("name='Beta Trend' x=", "name='Alpha Sales' x="))
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, seal: true) }
      request = JSON.parse(File.read(File.join(dir, 'mcp-evidence-request.json')))
      capture = request['requests'].find { |entry| entry['view_name'] == 'Alpha Sales' }
      assert_nil capture['view_id']
      refute File.exist?(File.join(dir, 'source-evidence.json'))
    end
  end

  def test_embedded_mapping_rejects_a_wrong_parent_and_path_escape
    Dir.mktmpdir do |dir|
      metadata = build(dir)
      parent = metadata['workbook']['views']['view'].find { |view| view['name'] == 'Beta Detail' }
      mapping = [{ 'worksheet' => 'Alpha Sales', 'dashboard_view_id' => parent['id'], 'path' => 'views/view-0.csv' }]
      File.write(File.join(dir, 'mcp-worksheet-files.json'), JSON.generate(mapping))
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, seal: true) }
      mapping[0]['path'] = 'views/../../outside.csv'
      File.write(File.join(dir, 'mcp-worksheet-files.json'), JSON.generate(mapping))
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, seal: true) }
    end
  end
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
    # Complete synthetic PNG bytes, not a visual attestation.
    chunk = ->(type, data) { [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N') }
    png = "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', [1, 1, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
          chunk.call('IDAT', Zlib::Deflate.deflate("\0\0\0\0")) + chunk.call('IEND', '')
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

  def test_flat_nested_and_split_metadata_preserve_the_same_view_inventory
    Dir.mktmpdir do |dir|
      nested = build(dir)
      flat = nested['workbook']
      split = { 'workbook' => flat.reject { |key, _| key == 'views' }, 'views' => flat['views'] }
      [nested, flat, split].each do |metadata|
        assert_equal flat['views']['view'], McpSource.views_for(dir, metadata)
        File.write(File.join(dir, 'get-workbook.json'), JSON.generate(metadata))
        assert_equal 'wb-fixture', McpSource.prepare(dir, seal: true)['id']
      end
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

  def test_valid_header_does_not_hide_truncation_or_corrupt_image_data
    Dir.mktmpdir do |dir|
      build(dir)
      path = File.join(dir, 'dashboards/Alpha_Overview.png')
      complete = File.binread(path)
      assert McpSource.complete_png?(path)
      File.binwrite(path, complete[0, 33])
      refute McpSource.complete_png?(path)
      assert_raises(McpSource::Incomplete) { McpSource.prepare(dir, seal: true) }
      corrupt = complete.dup
      corrupt.setbyte(44, corrupt.getbyte(44) ^ 1)
      File.binwrite(path, corrupt)
      refute McpSource.complete_png?(path)
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
