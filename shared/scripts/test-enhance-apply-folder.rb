#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-enhance-apply-folder.rb — offline pin for WHERE enhance-apply.rb puts the
# "<name> — Enhanced" clone. The workbook readback (GET /v2/workbooks/{id}
# ?includeContents=true) no longer returns folderId, so the clone's folder is
# resolved as: --folder-id, then a readback folderId, then the original's file
# record (GET /v2/files/{id} -> parentId), else My Documents (no folderId key).
#
# Stubbed run: enhance-apply.rb + its libs are copied beside a fake sigma_rest
# that records the clone POST body. The fake export returns no queryId, so the
# script aborts at the parity baseline right after the clone POST — which is
# all this test needs.
#
# Run: ruby shared/scripts/test-enhance-apply-folder.rb
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'

class EnhanceApplyFolderTest < Minitest::Test
  FAKE_SIGMA = <<~'RUBY'
    require 'json'
    module Sigma
      class Error < StandardError; end
      def self.request(method, path, body: nil, **_options)
        fx = JSON.parse(File.read(ENV.fetch('FAKE_FIXTURE')))
        File.open(ENV.fetch('FAKE_REQUESTS'), 'a') do |f|
          f.puts(JSON.generate('method' => method, 'path' => path, 'body' => body && JSON.parse(body)))
        end
        if method == :get && path == '/v2/workbooks/wb-orig'
          return { 'workbookId' => 'wb-orig', 'name' => 'Orig', 'updatedAt' => 't0' }
        end
        return fx['readback'] if method == :get && path == '/v2/workbooks/wb-orig?includeContents=true'
        if method == :get && path == '/v2/files/wb-orig'
          raise Error, 'GET /v2/files/wb-orig -> 403 Forbidden' if fx['files_fail']
          return { 'id' => 'wb-orig', 'type' => 'workbook', 'parentId' => 'folder-from-files' }
        end
        return { 'workbookId' => 'wb-clone' } if method == :post && path == '/v2/workbooks'
        return {} if method == :post && path.end_with?('/export')
        raise Error, "unexpected #{method} #{path}"
      end
    end
  RUBY

  ELEMENTS = [
    { 'id' => 'src', 'kind' => 'table', 'name' => 'Src' },
    { 'id' => 'chart', 'kind' => 'bar-chart', 'name' => 'Chart', 'columns' => [] }
  ].freeze
  CONTENTS = {
    'schemaVersion' => 1, 'kind' => 'workbook',
    'pages' => [{ 'id' => 'page-data', 'name' => 'Data' }, { 'id' => 'page-1', 'name' => 'Overview' }],
    'elements' => ELEMENTS,
    'layout' => '<Page id="page-data"><Element elementId="src"/></Page><Page id="page-1"><Element elementId="chart"/></Page>'
  }.freeze

  # Returns [clone POST body or nil, all recorded requests, combined output].
  def run_apply(readback_extra: {}, files_fail: false, extra_args: [])
    Dir.mktmpdir do |dir|
      lib = File.join(dir, 'lib')
      FileUtils.mkdir_p(lib)
      FileUtils.cp(File.join(__dir__, 'enhance-apply.rb'), dir)
      FileUtils.cp(File.expand_path('../lib/code_rep.rb', __dir__), lib)
      File.write(File.join(lib, 'sigma_rest.rb'), FAKE_SIGMA)
      fixture = File.join(dir, 'fixture.json')
      File.write(fixture, JSON.generate(
                            'files_fail' => files_fail,
                            'readback' => { 'workbookId' => 'wb-orig', 'name' => 'Orig', 'latestVersion' => 3,
                                            'documentVersion' => 3, 'path' => 'My Documents/Orig',
                                            'contents' => CONTENTS }.merge(readback_extra)))
      enh = File.join(dir, 'enhancements.json')
      File.write(enh, JSON.generate('candidates' => [{ 'id' => 'c1', 'risk' => 'low', 'patch' => {} }]))
      log = File.join(dir, 'requests.jsonl')
      # Test harness: runs a temp copy of enhance-apply.rb with this file's literal arguments.
      # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
      out, _status = Open3.capture2e({ 'FAKE_FIXTURE' => fixture, 'FAKE_REQUESTS' => log, 'HOME' => dir },
                                     RbConfig.ruby, File.join(dir, 'enhance-apply.rb'),
                                     '--workbook-id', 'wb-orig', '--enhancements', enh, '--accept', 'c1',
                                     '--out', File.join(dir, 'report.json'), *extra_args)
      requests = File.readlines(log).map { |l| JSON.parse(l) }
      post = requests.find { |r| r['method'] == 'post' && r['path'] == '/v2/workbooks' }
      [post && post['body'], requests, out]
    end
  end

  def test_clone_defaults_to_the_originals_folder_via_files_parent_id
    body, requests, out = run_apply
    refute_nil body, "clone was never POSTed to /v2/workbooks:\n#{out}"
    assert_equal 'folder-from-files', body['folderId']
    assert_equal 'Orig — Enhanced', body['name']
    assert_equal ['wb-orig'], requests.select { |r| r['path'] == '/v2/files/wb-orig' }.map { |r| r['path'].split('/').last }
    refute body.key?('document'), 'create body must carry `contents`, not `document`'
    assert_equal 1, body['contents']['schemaVersion']
  end

  def test_folder_id_flag_overrides_and_skips_the_lookup
    body, requests, out = run_apply(extra_args: ['--folder-id', 'folder-flag'])
    refute_nil body, out
    assert_equal 'folder-flag', body['folderId']
    assert_empty requests.select { |r| r['path'].start_with?('/v2/files/') }, 'no lookup when --folder-id is given'
  end

  def test_readback_folder_id_wins_over_the_lookup
    body, requests, out = run_apply(readback_extra: { 'folderId' => 'folder-readback' })
    refute_nil body, out
    assert_equal 'folder-readback', body['folderId']
    assert_empty requests.select { |r| r['path'].start_with?('/v2/files/') }
  end

  def test_unresolvable_folder_warns_and_omits_folder_id
    body, _requests, out = run_apply(files_fail: true)
    refute_nil body, out
    refute body.key?('folderId'), 'omitted folderId = My Documents (API default)'
    assert_match(/could not resolve wb-orig's folder/, out)
  end
end
