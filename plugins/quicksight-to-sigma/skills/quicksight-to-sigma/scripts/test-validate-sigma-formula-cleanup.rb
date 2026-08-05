#!/usr/bin/env ruby
# frozen_string_literal: true
# test-validate-sigma-formula-cleanup.rb — E7.1 acceptance for the scout
# validation primitive: the throwaway workbook is REGISTERED in the local
# probe registry BEFORE the first readback and DELETED on every exit path,
# not just the success path (the old shape orphaned it whenever the columns
# readback returned non-JSON or raised).
#
# Offline: stubbed sigma_rest (same -I <stub> -r sigma_rest + SIGMA_STUB_LOG
# seam as test-probe-join-keys.rb). The stub's columns-GET also records
# whether the registry file already carried the created line at readback time
# (CHECK_REGISTRY_AT_GET), which pins the registered-BEFORE-readback ordering.
#
# Covers: ok verdict → one DELETE + created/cleaned registry pair; formula
# error → exit 2, still cleaned; readback non-JSON body and readback raise
# (the two field crash shapes) → DELETE still issued via at_exit + registry
# marked cleaned; --keep-workbook → NO delete, entry left outstanding for
# the crash-recovery sweep; POST failure → no registry line, no DELETE; no
# --workdir → registry falls back to <SKILL>_HOME.
#
# Canonical in shared/scripts; synced to the tableau AND quicksight plugin
# copies (E7.1 acceptance: run against BOTH — the fix must survive in the
# twin). Plugin-agnostic: the script under test and the home env var
# (TABLEAU_TO_SIGMA_HOME / QUICKSIGHT_TO_SIGMA_HOME) are derived from the
# copy's own location.
#
# Run (from a plugin copy): ruby scripts/test-validate-sigma-formula-cleanup.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'

SCRIPT = File.join(__dir__, 'validate-sigma-formula.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)
# tableau-to-sigma → TABLEAU_TO_SIGMA_HOME (same convention as learned-rules.rb).
SKILL    = File.basename(File.expand_path('..', __dir__))
HOME_ENV = "#{SKILL.tr('-', '_').upcase}_HOME"

unless File.exist?(SCRIPT)
  # The shared/scripts canonical has no validate-sigma-formula.rb beside it —
  # the runnable copies live in the plugin twins (manifest-synced).
  puts "test-validate-sigma-formula-cleanup: SKIP — no #{File.basename(SCRIPT)} beside this copy; run a plugin twin (tableau-to-sigma / quicksight-to-sigma)"
  exit 0
end

SIGMA_STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if ENV['SIGMA_STUB_LOG']
        rec = { 'method' => method.to_s, 'path' => path }
        if method == :get && path.include?('/columns') && ENV['CHECK_REGISTRY_AT_GET']
          reg = ENV['CHECK_REGISTRY_AT_GET']
          rec['registry_has_created'] = File.exist?(reg) &&
            File.readlines(reg).any? { |l| (JSON.parse(l)['created_at'] rescue nil) }
        end
        File.open(ENV['SIGMA_STUB_LOG'], 'a') { |f| f.puts JSON.generate(rec) }
      end
      if method == :post && path == '/v2/workbooks/spec'
        if ENV['SIGMA_STUB_POST_FAIL']
          raise Error, "POST /v2/workbooks/spec -> 400 Bad Request\n{\"message\":\"invalid spec\"}"
        end
        return { 'workbookId' => 'wb-scout-1' }
      end
      if method == :get && path.include?('/dataModels/')
        return { 'schemaVersion' => 1, 'pages' => [{ 'elements' => [
          { 'id' => 'el-1', 'name' => 'Data',
            'columns' => [{ 'name' => 'Gross Revenue', 'formula' => '[SRC/Gross Revenue]' }] }] }] }
      end
      if method == :get && path.include?('/columns')
        case ENV['SIGMA_STUB_COLS']
        when 'raw'   then return 'schemaVersion: 1 # not json'
        when 'raise' then raise Error, "GET #{path} -> 500 Internal Server Error\nboom"
        when 'err-col'
          return { 'entries' => [
            { 'label' => 'scout-test-col', 'formula' => 'Nope()', 'type' => { 'type' => 'error', 'message' => 'unknown fn' } }] }
        else
          return { 'entries' => [{ 'label' => 'scout-test-col', 'type' => { 'type' => 'number' } }] }
        end
      end
      if method == :delete
        raise Error, "DELETE #{path} -> 404 Not Found\ngone" if ENV['SIGMA_STUB_DELETE_404']
        return nil
      end
      raise Error, "stub: unexpected #{method} #{path}"
    end
    def self.list_entries(path, limit: 1000, http: nil)
      (request(:get, path, http: http) || {})['entries'] || []
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def run_validate(dir, env, *args)
  stub_dir = File.join(dir, 'stub')
  FileUtils.mkdir_p(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), SIGMA_STUB)
  home = File.join(dir, 'sigma-home')
  FileUtils.mkdir_p(home)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub', HOME_ENV => home,
      'SIGMA_STUB_LOG' => File.join(dir, 'stub.log') }.merge(env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', SCRIPT,
    '--formula', 'Sum([Master/Gross Revenue])',
    '--data-model-id', 'dm-1', '--master-element-id', 'el-1', *args)
end

def stub_calls(dir)
  log = File.join(dir, 'stub.log')
  return [] unless File.exist?(log)
  File.readlines(log).map { |l| JSON.parse(l) }
end

def deletes(dir)
  stub_calls(dir).select { |r| r['method'] == 'delete' }
end

def registry(path)
  return [] unless File.exist?(path)
  File.readlines(path).map { |l| JSON.parse(l) }
end

puts "== #{SKILL}: ok verdict → exit 0, ONE delete, created+cleaned registry pair =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  reg = File.join(wd, 'probe-artifacts.jsonl')
  out, _err, st = run_validate(dir, { 'CHECK_REGISTRY_AT_GET' => reg }, '--workdir', wd)
  check(st.exitstatus == 0, "exit 0 (got #{st.exitstatus})", fails)
  j = JSON.parse(out)
  check(j['status'] == 'ok' && j['workbook_id'] == 'wb-scout-1', 'verdict JSON intact (status ok, workbook_id)', fails)
  check(j['workbook_cleaned'] == true, 'workbook_cleaned true in the verdict JSON', fails)
  check(deletes(dir).map { |r| r['path'] } == ['/v2/files/wb-scout-1'], 'exactly ONE DELETE, for the scout workbook', fails)
  cols_get = stub_calls(dir).find { |r| r['path'].to_s.include?('/columns') }
  check(cols_get && cols_get['registry_has_created'] == true,
        'registry line written BEFORE the columns readback', fails)
  recs = registry(reg)
  check(recs.any? { |r| r['id'] == 'wb-scout-1' && r['created_at'] && r['script'] == 'validate-sigma-formula.rb' },
        'created record in <workdir>/probe-artifacts.jsonl', fails)
  check(recs.any? { |r| r['id'] == 'wb-scout-1' && r['deleted_at'] && r['outcome'] == 'deleted' },
        'cleaned record appended after the delete', fails)
end

puts "\n== formula error → exit 2, still cleaned =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  out, _err, st = run_validate(dir, { 'SIGMA_STUB_COLS' => 'err-col' }, '--workdir', wd)
  check(st.exitstatus == 2, "exit 2 (got #{st.exitstatus})", fails)
  j = JSON.parse(out)
  check(j['status'] == 'error' && j['error_columns'].length == 1, 'error columns surfaced', fails)
  check(deletes(dir).size == 1, 'formula-error path still deletes the workbook', fails)
end

puts "\n== readback returns NON-JSON → crash path still cleans (at_exit) =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  _out, _err, st = run_validate(dir, { 'SIGMA_STUB_COLS' => 'raw' }, '--workdir', wd)
  check(!st.success?, 'non-JSON readback → nonzero exit', fails)
  check(deletes(dir).map { |r| r['path'] } == ['/v2/files/wb-scout-1'],
        'DELETE issued anyway (at_exit) on the non-JSON readback', fails)
  recs = registry(File.join(wd, 'probe-artifacts.jsonl'))
  check(recs.any? { |r| r['deleted_at'] && r['via'] == 'at_exit' }, 'registry marked cleaned via at_exit', fails)
end

puts "\n== readback RAISES → crash path still cleans (at_exit) =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  _out, _err, st = run_validate(dir, { 'SIGMA_STUB_COLS' => 'raise' }, '--workdir', wd)
  check(!st.success?, 'raising readback → nonzero exit', fails)
  check(deletes(dir).map { |r| r['path'] } == ['/v2/files/wb-scout-1'],
        'DELETE issued anyway (at_exit) on the raising readback', fails)
end

puts "\n== --keep-workbook → NO delete; registry entry left outstanding =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  out, _err, st = run_validate(dir, {}, '--workdir', wd, '--keep-workbook')
  check(st.exitstatus == 0, 'keep run exits 0', fails)
  check(JSON.parse(out)['workbook_cleaned'] == false, 'workbook_cleaned false when kept', fails)
  check(deletes(dir).empty?, 'no DELETE issued with --keep-workbook', fails)
  recs = registry(File.join(wd, 'probe-artifacts.jsonl'))
  check(recs.any? { |r| r['created_at'] } && recs.none? { |r| r['deleted_at'] },
        'created-but-not-cleaned → outstanding for the sweep', fails)
end

puts "\n== POST fails → no workbook, no registry line, no DELETE =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  out, _err, st = run_validate(dir, { 'SIGMA_STUB_POST_FAIL' => '1' }, '--workdir', wd)
  check(st.exitstatus == 1, "POST failure → exit 1 (got #{st.exitstatus})", fails)
  j = JSON.parse(out)
  check(j['status'] == 'error' && j['phase'] == 'post', 'post-phase error JSON intact', fails)
  check(deletes(dir).empty?, 'nothing to delete after a failed POST', fails)
  check(!File.exist?(File.join(wd, 'probe-artifacts.jsonl')), 'no registry line for an uncreated workbook', fails)
end

puts "\n== no --workdir → registry falls back to #{HOME_ENV} =="
Dir.mktmpdir do |dir|
  _out, _err, st = run_validate(dir, {})
  check(st.exitstatus == 0, 'workdir-less run exits 0', fails)
  recs = registry(File.join(dir, 'sigma-home', 'probe-artifacts.jsonl'))
  check(recs.any? { |r| r['created_at'] } && recs.any? { |r| r['deleted_at'] },
        'home registry carries the created+cleaned pair', fails)
end

puts "\n== DELETE 404 → recorded as already-gone (outcome 404), verdict still ok =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  out, _err, st = run_validate(dir, { 'SIGMA_STUB_DELETE_404' => '1' }, '--workdir', wd)
  check(st.exitstatus == 0, '404 on delete does not fail the verdict', fails)
  check(JSON.parse(out)['workbook_cleaned'] == true, '404 counts as cleaned (already gone)', fails)
  recs = registry(File.join(wd, 'probe-artifacts.jsonl'))
  check(recs.any? { |r| r['deleted_at'] && r['outcome'] == '404' }, "registry outcome '404'", fails)
end

puts
if fails.empty?
  puts "test-validate-sigma-formula-cleanup (#{SKILL}): ALL PASS"
else
  puts "test-validate-sigma-formula-cleanup (#{SKILL}): #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
