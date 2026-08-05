#!/usr/bin/env ruby
# frozen_string_literal: true
# test-sweep-run-artifacts.rb — E7.1 acceptance for the crash-recovery sweep.
#
# Pins the BINDING containment contract: the sweep deletes ONLY ids from the
# local probe registry (created-but-not-cleaned), dry-runs by default (zero
# DELETE traffic), honors the ~/.tableau-to-sigma home fallback, treats a
# DELETE 404 as already-cleaned and a failure as still-outstanding, and in
# opt-in --folder-id mode enumerates ONLY that folder (cursor-paged, every
# listing request carries parentId — NEVER an org-wide /v2/files page) and
# deletes only type=workbook children (folders/workspaces hard-refused).
#
# Offline: stubbed sigma_rest (same -I <stub> -r sigma_rest + SIGMA_STUB_LOG
# seam as test-probe-join-keys.rb). Run: ruby scripts/test-sweep-run-artifacts.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'

SCRIPT = File.join(__dir__, 'sweep-run-artifacts.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)

SIGMA_STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if ENV['SIGMA_STUB_LOG']
        File.open(ENV['SIGMA_STUB_LOG'], 'a') { |f| f.puts JSON.generate('method' => method.to_s, 'path' => path) }
      end
      if method == :get && path.start_with?('/v2/files')
        # Two cursor pages for the dedicated probe folder; anything else is empty.
        if path.include?('parentId=fld-probe')
          return { 'entries' => [
            { 'id' => 'wb-orphan-1', 'type' => 'workbook', 'name' => '_probe_leftover_a' },
            { 'id' => 'fld-inner',   'type' => 'folder',   'name' => 'inner folder' }
          ], 'nextPage' => 'p2' } unless path.include?('page=')
          return { 'entries' => [
            { 'id' => 'wb-orphan-2', 'type' => 'workbook',  'name' => '_probe_leftover_b' },
            { 'id' => 'ws-1',        'type' => 'workspace', 'name' => 'Customer Workspace' },
            { 'id' => 'ds-1',        'type' => 'dataset',   'name' => 'Customer Dataset' }
          ] }
        end
        return { 'entries' => [] }
      end
      if method == :delete
        id = path.split('/').last
        fail_ids = ENV['SIGMA_STUB_DELETE_FAIL_IDS'].to_s.split(',')
        gone_ids = ENV['SIGMA_STUB_DELETE_404_IDS'].to_s.split(',')
        raise Error, "DELETE #{path} -> 500 Internal Server Error\nboom" if fail_ids.include?(id)
        raise Error, "DELETE #{path} -> 404 Not Found\ngone" if gone_ids.include?(id)
        return nil
      end
      raise Error, "stub: unexpected #{method} #{path}"
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

def seed_registry(dir, *recs)
  File.open(File.join(dir, 'probe-artifacts.jsonl'), 'a') { |f| recs.each { |r| f.puts(JSON.generate(r)) } }
end

def created_rec(id, name)
  { 'id' => id, 'name' => name, 'created_at' => '2026-07-27T00:00:00Z', 'script' => 'test' }
end

def run_sweep(dir, env, *args)
  stub_dir = File.join(dir, 'stub')
  FileUtils.mkdir_p(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), SIGMA_STUB)
  home = File.join(dir, 'sigma-home')
  FileUtils.mkdir_p(home)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub', 'TABLEAU_TO_SIGMA_HOME' => home,
      'SIGMA_STUB_LOG' => File.join(dir, 'stub.log') }.merge(env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', SCRIPT, *args)
end

def stub_calls(dir)
  log = File.join(dir, 'stub.log')
  return [] unless File.exist?(log)
  File.readlines(log).map { |l| JSON.parse(l) }
end

def deletes(dir)
  stub_calls(dir).select { |r| r['method'] == 'delete' }.map { |r| r['path'] }
end

puts '== dry-run (default): plan printed, ZERO delete traffic =='
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  seed_registry(wd, created_rec('wb-a', '_probe_a'), created_rec('wb-b', '_probe_b'),
                { 'id' => 'wb-b', 'deleted_at' => '2026-07-27T00:01:00Z', 'outcome' => 'deleted', 'via' => 'ensure' })
  out, _err, st = run_sweep(dir, {}, '--workdir', wd)
  check(st.exitstatus == 0, "dry-run exits 0 (got #{st.exitstatus})", fails)
  check(out.include?('wb-a') && !out.include?('wb-b'), 'plan lists the outstanding id only (cleaned id excluded)', fails)
  check(out.include?('DRY-RUN') && out.include?('--delete'), 'dry-run banner names the --delete arm', fails)
  check(out.include?("Trash"), 'Trash-recoverable note printed', fails)
  check(stub_calls(dir).empty?, 'ZERO Sigma API traffic on a registry dry-run', fails)
end

puts "\n== --delete: deletes ONLY registry-outstanding ids, appends cleaned records =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  seed_registry(wd, created_rec('wb-a', '_probe_a'), created_rec('wb-b', '_probe_b'),
                { 'id' => 'wb-b', 'deleted_at' => '2026-07-27T00:01:00Z', 'outcome' => 'deleted', 'via' => 'ensure' })
  out, _err, st = run_sweep(dir, {}, '--workdir', wd, '--delete')
  check(st.exitstatus == 0, "delete run exits 0 (got #{st.exitstatus})", fails)
  check(deletes(dir) == ['/v2/files/wb-a'], "exactly one DELETE, for the registry entry (got #{deletes(dir).inspect})", fails)
  check(out.include?('DELETED wb-a'), 'delete echoed', fails)
  recs = File.readlines(File.join(wd, 'probe-artifacts.jsonl')).map { |l| JSON.parse(l) }
  check(recs.any? { |r| r['id'] == 'wb-a' && r['deleted_at'] && r['via'] == 'sweep' }, 'cleaned-via-sweep record appended', fails)
  # convergence: a second sweep finds nothing
  out2, _err2, st2 = run_sweep(dir, { 'SIGMA_STUB_LOG' => File.join(dir, 'stub2.log') }, '--workdir', wd, '--delete')
  check(st2.exitstatus == 0 && out2.include?('nothing outstanding'), 'second sweep converges to nothing outstanding', fails)
end

puts "\n== DELETE 404 → already-gone, exit 0; DELETE failure → outstanding, exit 1 =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  seed_registry(wd, created_rec('wb-gone', '_probe_gone'), created_rec('wb-bad', '_probe_bad'))
  out, _err, st = run_sweep(dir, { 'SIGMA_STUB_DELETE_404_IDS' => 'wb-gone',
                                   'SIGMA_STUB_DELETE_FAIL_IDS' => 'wb-bad' }, '--workdir', wd, '--delete')
  check(st.exitstatus == 1, "a failed delete → exit 1 (got #{st.exitstatus})", fails)
  check(out.include?('GONE    wb-gone'), '404 reported as already cleaned', fails)
  check(out.include?('1 deleted, 1 already gone, 1 failed') || out.include?('0 deleted, 1 already gone, 1 failed'),
        'summary counts the outcomes', fails)
  # the failed id stays outstanding; the 404 one does not
  out2, _err2, _st2 = run_sweep(dir, { 'SIGMA_STUB_LOG' => File.join(dir, 'stub2.log') }, '--workdir', wd)
  check(out2.include?('wb-bad') && !out2.include?('wb-gone'), 'failed id still outstanding on the next dry-run; 404 id cleaned', fails)
end

puts "\n== home-registry fallback (no --workdir) is swept too =="
Dir.mktmpdir do |dir|
  home = File.join(dir, 'sigma-home'); FileUtils.mkdir_p(home)
  seed_registry(home, created_rec('wb-dev', 'ZZ probe-window-contexts (throwaway)'))
  out, _err, st = run_sweep(dir, {}, '--delete')
  check(st.exitstatus == 0, 'home sweep exits 0', fails)
  check(deletes(dir) == ['/v2/files/wb-dev'], 'dev-probe id from the home registry deleted', fails)
  check(out.include?('registry(home)') || out.include?('wb-dev'), 'home source named in the plan', fails)
end

puts "\n== --folder-id: cursor-paged, parentId-scoped, workbooks only =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  out, err, st = run_sweep(dir, {}, '--workdir', wd, '--folder-id', 'fld-probe', '--delete')
  check(st.exitstatus == 0, "folder sweep exits 0 (got #{st.exitstatus})", fails)
  gets = stub_calls(dir).select { |r| r['method'] == 'get' }.map { |r| r['path'] }
  check(gets.size == 2 && gets.all? { |p| p.include?('parentId=fld-probe') },
        "every listing request is parentId-scoped (got #{gets.inspect})", fails)
  check(gets.last.include?('page=p2'), 'nextPage cursor followed', fails)
  check(deletes(dir).sort == ['/v2/files/wb-orphan-1', '/v2/files/wb-orphan-2'],
        "both folder workbooks deleted, nothing else (got #{deletes(dir).inspect})", fails)
  check(err.include?('REFUSE') && err.include?('fld-inner') && err.include?('ws-1'),
        'folder + workspace children hard-refused by name', fails)
  check(err.include?('SKIP') && err.include?('ds-1'), 'non-workbook types skipped with a named line', fails)
end

puts "\n== empty registry, no folder → nothing outstanding, exit 0, zero traffic =="
Dir.mktmpdir do |dir|
  wd = File.join(dir, 'wd'); FileUtils.mkdir_p(wd)
  out, _err, st = run_sweep(dir, {}, '--workdir', wd)
  check(st.exitstatus == 0 && out.include?('nothing outstanding'), 'clean exit on nothing to do', fails)
  check(stub_calls(dir).empty?, 'zero API traffic', fails)
end

puts "\n== usage error: missing --workdir dir =="
Dir.mktmpdir do |dir|
  _out, err, st = run_sweep(dir, {}, '--workdir', File.join(dir, 'nope'))
  check(st.exitstatus == 2 && err.include?('does not exist'), 'bad --workdir → exit 2', fails)
end

puts
if fails.empty?
  puts 'test-sweep-run-artifacts: ALL PASS'
else
  puts "test-sweep-run-artifacts: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
