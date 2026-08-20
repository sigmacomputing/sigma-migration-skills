#!/usr/bin/env ruby
# frozen_string_literal: true
# test-verify-interaction-fetch-spec.rb — regression test for the workbook
# code-rep `document` unwrap in scripts/verify-interaction.rb's `fetch_spec`.
#
# (A separate file from test-verify-interaction.rb, which `require_relative`s
# the script to unit-test the pure InteractionOracle module offline — that
# require path is CLI-guarded OUT before `fetch_spec` is even defined
# (`return if $PROGRAM_NAME != __FILE__ ...` sits above it), so it cannot
# exercise fetch_spec at all. This test instead runs the real CLI as a
# subprocess.)
#
# fetch_spec GETs the live workbook spec; ControlLint.elements/controls_report
# need flat document elements plus layout-derived page membership. Workbook
# code-rep GETs nest the workbook document under a top-level `document` key
# (live since 2026-08) — pre-fix, a control that IS
# correctly wired (filters a same-page queryable element) would silently read
# as "control not present in the live workbook spec" on every probe, because
# ControlLint never saw the nested pages.
#
# Minimal workdir: only control-scope.json is hard-required by the script;
# dashboard-layout.json / get-workbook.json / parity-plan.json / wb-ids.json
# are all read with a `rescue nil`/`rescue {}` fallback, so omitting them
# just means "no pairable element" — a SKIP reached only once `fetch_spec`
# has correctly resolved the control via ControlLint, which is exactly the
# signal this test needs (proves the unwrap without needing a full
# Tableau-side flip, which is unrelated to this fix).
#
# Tableau creds are left unset (and HOME redirected to an empty scratch dir)
# so `lib/tableau_rest.rb`'s neutral-env bootstrap can't leak in real
# dev-box creds, and the Tableau PAT auto-refresh block (guarded on
# TABLEAU_PAT_NAME/SECRET both present) never fires — no Tableau network is
# ever attempted on this path.
#
# Same `sigma_rest.rb` load-path-shadow convention as
# test-probe-control-formula.rb / test-probe-window-contexts.rb.
#
# Run: ruby scripts/test-verify-interaction-fetch-spec.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'verify-interaction.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)

# The live (wrapped) readback: a `filters`-mechanism control ("Region") wired
# to a same-page queryable table element.
ELEMENTS = [
  { 'id' => 'ctl1', 'kind' => 'control', 'controlType' => 'list',
    'controlId' => 'c-cid', 'name' => 'Region',
    'filters' => [{ 'source' => { 'elementId' => 'tbl1' } }] },
  { 'id' => 'tbl1', 'kind' => 'table', 'name' => 'Revenue Table' }
].freeze
NESTED_SPEC = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'p1', 'name' => 'Dashboard' }],
    'elements' => ELEMENTS,
    'layout' => '<Page id="p1"><Element elementId="ctl1"/><Element elementId="tbl1"/></Page>'
  }
}.freeze

SIGMA_STUB = <<~RUBY
  require 'json'
  module Sigma
    class Error < StandardError; end
    NESTED_SPEC = #{NESTED_SPEC.to_json}
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if ENV['SIGMA_STUB_LOG']
        File.open(ENV['SIGMA_STUB_LOG'], 'a') { |f| f.puts JSON.generate('method' => method.to_s, 'path' => path) }
      end
      case
      when method == :get && path == '/v2/workbooks/wb-test/spec'
        JSON.parse(JSON.generate(NESTED_SPEC))
      else
        raise Error, "stub: unexpected \#{method} \#{path}"
      end
    end
    def self.base_url; 'https://stub.invalid'; end
    def self.auth_token; 'stub-token'; end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_verify(dir, extra_env = {})
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir) unless Dir.exist?(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), SIGMA_STUB)

  work = File.join(dir, 'work')
  Dir.mkdir(work)
  File.write(File.join(work, 'control-scope.json'), JSON.generate(
    'controls' => [
      { 'controlId' => 'c-cid', 'name' => 'Region', 'mechanism' => 'filters',
        'status' => 'emitted', 'targets' => ['tbl1'] }
    ]
  ))

  # Empty HOME so lib/tableau_rest.rb's ~/.sigma-migration/env neutral bootstrap
  # can't leak real dev-box Tableau creds into this subprocess.
  empty_home = File.join(dir, 'home')
  Dir.mkdir(empty_home)

  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub-token', 'HOME' => empty_home,
      'TABLEAU_PAT_NAME' => nil, 'TABLEAU_PAT_SECRET' => nil, 'TABLEAU_AUTH_TOKEN' => nil }.merge(extra_env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', SCRIPT,
    '--workdir', work, '--workbook-id', 'wb-test', '--no-renders'
  )
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts "== verify-interaction fetch_spec: wrapped spec GET must resolve the control's reach =="
Dir.mktmpdir do |dir|
  log = File.join(dir, 'stub.log')
  _out, err, st = run_verify(dir, { 'SIGMA_STUB_LOG' => log })

  check(!err.include?('control not present in the live workbook spec'),
        "control IS found via ControlLint on the unwrapped spec (got stderr: #{err.inspect})", fails)
  check(err.include?('no pairable element'),
        "reaches the (unrelated) pairing step -- proves fetch_spec + ControlLint saw the control and its reach (got: #{err.inspect})", fails)
  check(st.exitstatus == 2,
        "exits 2 (nothing PROBEABLE for Tableau pairing -- expected; unrelated to this fix) (got #{st.exitstatus})", fails)

  reqs = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  check(reqs.any? { |r| r['method'] == 'get' && r['path'] == '/v2/workbooks/wb-test/spec' },
        'spec GET issued', fails)
end

puts
if fails.empty?
  puts 'test-verify-interaction-fetch-spec: ALL PASS'
else
  puts "test-verify-interaction-fetch-spec: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
