#!/usr/bin/env ruby
# frozen_string_literal: true
# test-validate-sigma-formula-wrap.rb — regression test for the workbook
# code-rep `document` wrap in scripts/validate-sigma-formula.rb (the
# singleton probe POST — this plugin's copy has no --batch mode).
#
# This is a PLUGIN-LOCAL test (not the shared/scripts canonical
# test-validate-sigma-formula-cleanup.rb, which this repo syncs byte-identical
# across plugins per the shared-file manifest and which this fix does not
# touch) — it exists specifically to prove the `document` envelope on the
# `POST /v2/workbooks/spec` call site this fix wraps. Mirrors
# tableau-to-sigma's test-validate-sigma-formula-wrap.rb (bead task-3.9).
#
# Same offline seam convention as test-validate-sigma-formula-cleanup.rb:
# stub sigma_rest.rb, run the real script via `ruby -I <stub> -r sigma_rest`,
# no live network.
#
# Run: ruby scripts/test-validate-sigma-formula-wrap.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'

SCRIPT = File.join(__dir__, 'validate-sigma-formula.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)

SIGMA_STUB = <<~RUBY
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if ENV['SIGMA_STUB_LOG']
        File.open(ENV['SIGMA_STUB_LOG'], 'a') { |f| f.puts JSON.generate('method' => method.to_s, 'path' => path, 'body' => body) }
      end
      case
      when method == :post && path == '/v2/workbooks/spec'
        { 'workbookId' => 'wb-scout-1' }
      when method == :get && path.include?('/dataModels/')
        { 'schemaVersion' => 1, 'pages' => [{ 'elements' => [
          { 'id' => 'el-1', 'name' => 'Data',
            'columns' => [{ 'name' => 'Gross Revenue', 'formula' => '[SRC/Gross Revenue]' }] }] }] }
      when method == :get && path.include?('/columns')
        { 'entries' => [{ 'label' => 'scout-test-col', 'type' => { 'type' => 'number' } }] }
      when method == :delete
        nil
      else
        raise Error, "stub: unexpected \#{method} \#{path}"
      end
    end
    def self.list_entries(path, limit: 1000, http: nil)
      (request(:get, path, http: http) || {})['entries'] || []
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_validate(dir, log, *args)
  stub_dir = File.join(dir, 'stub')
  FileUtils.mkdir_p(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), SIGMA_STUB)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub', 'HOME' => dir, 'SIGMA_STUB_LOG' => log,
      'QUICKSIGHT_TO_SIGMA_HOME' => dir },
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', SCRIPT,
    '--data-model-id', 'dm-1', '--master-element-id', 'el-1', '--keep-workbook', *args
  )
end

def posts(log)
  return [] unless File.exist?(log)
  File.readlines(log).map { |l| JSON.parse(l) }
      .select { |r| r['method'] == 'post' && r['path'] == '/v2/workbooks/spec' }
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== validate-sigma-formula (singleton): probe POST must carry the `document` envelope =='
Dir.mktmpdir do |dir|
  log = File.join(dir, 'stub.log')
  _out, err, st = run_validate(dir, log, '--formula', 'Sum([Master/Gross Revenue])')
  check(st.exitstatus.zero?, "singleton run exits 0 (got #{st.exitstatus}; err=#{err.inspect})", fails)
  p = posts(log)
  check(p.size == 1, "exactly one probe POST (got #{p.size})", fails)
  if p.size == 1
    body = JSON.parse(p.first['body'])
    check(body.key?('document') && body['document'].is_a?(Hash), 'POST body carries a top-level `document` key', fails)
    check(!body.key?('pages') && !body.key?('schemaVersion'),
          'POST body has NO top-level pages/schemaVersion (must be nested)', fails)
    doc = body['document'].is_a?(Hash) ? body['document'] : {}
    check(doc['pages'].is_a?(Array) && !doc['pages'].empty?, 'wrapped document carries pages', fails)
    check(body['name'].to_s.start_with?('[scout-test]'), 'name stays OUTSIDE document as metadata', fails)
  end
end

puts
if fails.empty?
  puts 'test-validate-sigma-formula-wrap: ALL PASS'
else
  puts "test-validate-sigma-formula-wrap: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
