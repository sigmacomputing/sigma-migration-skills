#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'digest'

class ProbeControlsJsonTest < Minitest::Test
  FAKE_SIGMA = <<~'RUBY'
    require 'json'
    module Sigma
      class Error < StandardError; end
      @mutex = Mutex.new
      @queries = {}
      @reads = 0
      def self.list_entries(*)
        []
      end
      def self.request(method, path, body: nil, **_options)
        input = JSON.parse(File.read(ENV.fetch('PROBE_FIXTURE')))
        @mutex.synchronize do
          File.open(ENV.fetch('PROBE_REQUESTS'), 'a') { |f| f.puts(JSON.generate(method: method, path: path, body: body && JSON.parse(body))) }
          if method == :get && path.end_with?('/spec')
            @reads += 1
            return {'latestDocumentVersion' => input['version_change'] && @reads > 1 ? 8 : 7, 'document' => input['spec']}
          end
          if method == :post && path.end_with?('/export')
            query = JSON.parse(body)
            id = (@queries.size + 1).to_s
            @queries[id] = query
            return {'queryId' => id}
          end
          if method == :get && path.start_with?('/v2/query/')
            query = @queries.fetch(path.split('/')[-2])
            flip = query.dig('parameters', 'pick') == 'B'
            if query['elementId'] == 'pivot'
              raise Error, 'pivot CSV export is unavailable' unless query.dig('format', 'type') == 'json'
              return '{"error":"not rows"}' if input['malformed']
              rows = [{'Area' => 'North', 'Rate' => (flip && input['leak'] ? 0.2 : 0.1)}, {'Area' => 'South', 'Rate' => nil}]
              rows = rows.reverse.map { |r| r.to_a.reverse.to_h } if flip
              return JSON.generate(rows)
            end
            value = flip && !input['inert'] ? 2 : 1
            return "Area,Value\nNorth,#{value}\n"
          end
          raise Error, 'unexpected request; no live access allowed in this test'
        end
      end
    end
  RUBY

  def probe(no_pool: false, missing_pool: false, anchors: false, **scenario)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, 'lib')
      FileUtils.mkdir_p(lib)
      FileUtils.cp(File.join(__dir__, 'probe-controls.rb'), File.join(dir, 'probe-controls.rb'))
      FileUtils.cp(File.join(__dir__, 'verify-anchors.rb'), File.join(dir, 'verify-anchors.rb'))
      %w[control_lint.rb code_rep.rb export_pool.rb anchor_values.rb].each do |name|
        next if missing_pool && name == 'export_pool.rb'
        FileUtils.cp(File.expand_path("../lib/#{name}", __dir__), File.join(lib, name))
      end
      File.write(File.join(lib, 'sigma_rest.rb'), FAKE_SIGMA)
      spec = {'pages' => [{'id' => 'page', 'name' => 'Page'}], 'elements' => [
        {'id' => 'selector', 'kind' => 'control', 'controlId' => 'pick', 'name' => 'Pick',
         'controlType' => 'segmented', 'value' => 'A', 'source' => {'kind' => 'manual', 'values' => %w[A B]}},
        {'id' => 'chart', 'kind' => 'table', 'name' => 'Chart', 'columns' => [{'id' => 'v', 'name' => 'Value', 'formula' => 'If([pick] = "A", 1, 2)'}]},
        {'id' => 'pivot', 'kind' => 'pivot-table', 'name' => 'Pivot', 'columns' => [{'id' => 'rate', 'name' => 'Rate', 'formula' => '0.1'}],
         'totals' => {'showGrandTotals' => 'hidden'}}],
        'layout' => '<Page id="page"><Element elementId="selector"/><Element elementId="chart"/><Element elementId="pivot"/></Page>'}
      fixture = File.join(dir, 'fixture.json')
      File.write(fixture, JSON.generate(scenario.transform_keys(&:to_s).merge('spec' => spec)))
      log = File.join(dir, 'requests.jsonl')
      out = File.join(dir, 'evidence')
      args = [RbConfig.ruby, File.join(dir, 'probe-controls.rb'), '--workbook-id', 'wb-test', '--out', out, '--check-out-of-closure']
      args << '--no-pool' if no_pool
      if anchors
        FileUtils.mkdir_p(out)
        File.write(File.join(out, 'anchors-verdict.json'), JSON.generate('pass' => true, 'matched' => 2))
        File.write(File.join(out, 'source-anchors.json'), JSON.generate('anchors' => [
          {'id' => 'a1', 'raw' => '1', 'kind' => 'number', 'sigma_element_hint' => 'Chart', 'provenance' => 'view-csv'},
          {'id' => 'a2', 'raw' => '0.10', 'kind' => 'number', 'sigma_element_hint' => 'Pivot', 'provenance' => 'view-csv'}]))
        args = [RbConfig.ruby, File.join(dir, 'verify-anchors.rb'), '--workdir', out, '--workbook-id', 'wb-test']
      end
      output, status = Open3.capture2e({'HOME' => dir, 'PROBE_FIXTURE' => fixture, 'PROBE_REQUESTS' => log}, *args)
      result_path = File.join(out, anchors ? 'anchors-verdict.json' : 'probe-results.json')
      results = JSON.parse(File.read(result_path)) if File.file?(result_path)
      requests = File.readlines(log).map { |line| JSON.parse(line) }
      assert requests.all? { |r| r['method'] == 'get' || (r['method'] == 'post' && r['path'].end_with?('/export')) }, 'probe must never mutate the workbook'
      requests.select { |r| r.dig('body', 'elementId') == 'pivot' }.each do |r|
        assert_equal 'json', r.dig('body', 'format', 'type')
      end
      if status.success? && !anchors
        evidence = JSON.parse(File.read(File.join(out, 'probe-evidence.json')))
        assert_equal '7', evidence['doc_version']
        assert evidence['exports'].keys.any? { |name| name.end_with?('.json') }
        evidence['exports'].each do |name, sha|
          assert_equal Digest::SHA256.file(File.join(out, name)).hexdigest, sha
        end
      end
      if anchors && status.success?
        refute File.exist?(File.join(out, 'anchors-restore-pivot-totals.json'))
        first_posts = requests.count { |r| r['method'] == 'post' }
        second_output, second_status = Open3.capture2e({'HOME' => dir, 'PROBE_FIXTURE' => fixture, 'PROBE_REQUESTS' => log}, *args)
        assert second_status.success?, second_output
        all_requests = File.readlines(log).map { |line| JSON.parse(line) }
        assert_equal first_posts, all_requests.count { |r| r['method'] == 'post' }, 'second anchor check should reuse the stable-version raw cache'
      end
      if anchors && scenario[:version_change]
        assert_empty Dir[File.join(out, 'export-cache', '**', '*')], 'mixed-version payloads must not enter the shared cache'
      end
      [status.exitstatus, results, output]
    end
  end

  def test_manual_choice_and_pivot_json_in_pooled_mode
    code, results, output = probe
    assert_equal 0, code, output
    assert results.any? { |r| r['result'] == 'PASS' && r['value'] == 'B' }
    assert results.any? { |r| r['result'] == 'OK' && r['element'] == 'pivot' }
  end

  def test_serial_and_missing_pool_routes_are_equivalent
    expected = probe[1]
    assert_equal expected, probe(no_pool: true)[1]
    assert_equal expected, probe(missing_pool: true)[1]
  end

  def test_inert_control_still_fails
    code, results, = probe(inert: true)
    assert_equal 1, code
    assert results.any? { |r| r['result'] == 'FAIL' && r['element'] == 'chart' }
  end

  def test_leaking_control_still_fails
    code, results, = probe(leak: true)
    assert_equal 1, code
    assert results.any? { |r| r['result'] == 'FAIL' && r['element'] == 'pivot' }
  end

  def test_version_change_refuses_mixed_evidence
    code, results, = probe(version_change: true)
    assert_equal 1, code
    assert results.any? { |r| r['result'] == 'FAIL' && r['note'].include?('version changed') }
  end

  def test_malformed_json_is_not_a_pass
    code, = probe(malformed: true)
    refute_equal 0, code
  end

  def test_anchor_verification_is_read_only_and_cacheable_for_pivots
    code, result, output = probe(anchors: true)
    assert_equal 0, code, output
    assert_equal true, result['pass']
    assert_equal 2, result['matched']
  end

  def test_anchor_json_errors_do_not_pass
    code, result, = probe(anchors: true, malformed: true)
    refute_equal 0, code
    refute result && result['pass']
  end

  def test_anchor_version_change_invalidates_the_previous_pass
    code, result, output = probe(anchors: true, version_change: true)
    refute_equal 0, code
    assert_includes output, 'version changed'
    assert_equal false, result['pass']
    assert_equal 'incomplete', result['status']
  end
end
