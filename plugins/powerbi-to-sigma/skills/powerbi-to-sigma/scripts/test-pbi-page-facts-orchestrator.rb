#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline test of the page-fact wiring in migrate-powerbi.rb (--page-facts, --page-facts-update-dm,
# --allow-page-fact-todo) through the REAL orchestrator, stopped with --stop-before-post. A stub
# required into every ruby subprocess replaces Net::HTTP (logs each request, answers canned JSON),
# so a stray POST/PUT is caught; no network, no credentials. Section 0 unit-checks the builder's
# page-scoped bindings (PbiReportBuild.page_scoped_fields).
#
#   1. build-new: the completed page fact lands in dm-spec.json as a Custom SQL element on the
#      run's connection, the DM spec validates, and nothing is written to Sigma
#   2. a page fact with TODO measures is refused unless --allow-page-fact-todo
#   3. DM reuse: a reused DM without the page fact stops with an OPEN QUESTION (exit 10); with
#      --page-facts-update-dm and --stop-before-post it reports the PUT it would make, and makes none
#
# Synthetic names only. Run: ruby scripts/test-pbi-page-facts-orchestrator.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative 'lib/pbi_reportbuild'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

MIGRATE = File.join(__dir__, 'migrate-powerbi.rb')
CONN = '12345678-1234-1234-1234-123456789012'
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'

puts "\n0. builder: page-scoped bindings"
fields = { 'Orders.Total Amount' => { 'master' => 'Orders', 'ref' => 'Sum([m/Amount])' } }
pf = { 'Sales Page' => { 'Orders.Total Amount' => { 'master' => 'PF', 'ref' => 'Sum([mpf/X])' } } }
check(PbiReportBuild.page_scoped_fields(fields, pf, { 'page_title' => 'Other' }).equal?(fields), 'a page without entries keeps the global fields object')
got = PbiReportBuild.page_scoped_fields(fields, pf, { 'page_title' => 'sales  page' })
check(got['Orders.Total Amount']['master'] == 'PF', 'page entries win, matched case- and space-insensitively')
check(fields['Orders.Total Amount']['master'] == 'Orders', 'the global fields are not mutated')
check(PbiReportBuild.page_scoped_fields(fields, nil, { 'page_title' => 'Sales Page' }).equal?(fields), 'no page_fields at all is a no-op')

def native_m(sql)
  ['let', "  Source = Value.NativeQuery(Snowflake.Databases(\"acct\"){[Name=\"DB\"]}[Data], \"#{sql}\", null, [EnableFolding=true])", 'in', '  Source']
end

COLS = [%w[Order\ Id ORDER_ID int64], %w[Amount AMOUNT decimal], %w[Region REGION string]]
       .map { |n, s, t| { 'name' => n, 'sourceColumn' => s, 'dataType' => t } }
MODEL = { 'model' => { 'name' => 'T', 'tables' => [{
  'name' => 'Orders', 'columns' => COLS,
  'measures' => [{ 'name' => 'Total Amount', 'expression' => 'SUM(Orders[Amount])' }],
  'partitions' => [{ 'name' => 'Orders', 'mode' => 'import',
                     'source' => { 'type' => 'm', 'expression' => native_m('SELECT ORDER_ID, AMOUNT, REGION FROM SALES.ORDERS') } }]
}] } }.freeze
VIS = JSON.generate('name' => 'v1', 'singleVisual' => { 'visualType' => 'card', 'projections' => { 'Values' => [{ 'queryRef' => 'Orders.Total Amount' }] } })
BUNDLE = JSON.generate('report.json' => JSON.generate('sections' => [{ 'name' => 'S1', 'displayName' => 'Sales Page', 'width' => 1280, 'height' => 720,
                                                                         'visualContainers' => [{ 'x' => 0, 'y' => 0, 'width' => 200, 'height' => 100, 'z' => 0, 'config' => VIS }] }]))

def page_fact(todo: false)
  pf = { 'version' => 1, 'page' => 'Sales Page', 'page_id' => 'S1', 'name' => 'Sales Page Page Fact',
         'sql' => "WITH s AS (SELECT ORDER_ID, AMOUNT FROM SALES.ORDERS)\nSELECT SUM(f.AMOUNT) AS \"SUM_AMOUNT\" FROM s f WHERE 1 = 1\n" \
                  '  /*@slicers fact="Orders" alias="f"*/',
         'columns' => [{ 'name' => 'Sum Amount', 'out' => 'SUM_AMOUNT', 'role' => 'component', 'fact' => 'Orders', 'aggregate' => 'SUM' }],
         'fields' => { 'Orders.Total Amount' => { 'ref' => 'Sum({C:Sum Amount})' } }, 'dims' => {}, 'facts' => ['Orders'],
         'todo' => [], 'slicers' => [] }
  if todo
    pf['todo'] = [{ 'measure' => 'Orders Count', 'query_ref' => 'Orders.Orders Count', 'reason' => 'DISTINCTCOUNT' }]
    pf['fields']['Orders.Orders Count'] = { 'ref' => 'Sum({C:Todo Orders Count})', 'todo' => true }
  end
  pf
end

Dir.mktmpdir('pbi-page-facts-orch') do |dir|
  stub = File.join(dir, 'fake_sigma_http.rb')
  log = File.join(dir, 'http.log')
  File.write(stub, <<~'RUBY')
    require 'net/http'
    require 'json'
    class FakeSigmaConn
      SPEC = { 'dataModelId' => 'dm-fake-1', 'name' => 'Reused DM', 'pages' => [{ 'id' => 'p1', 'name' => 'Data', 'elements' => [
        { 'id' => 'e1', 'name' => 'Orders', 'kind' => 'table',
          'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB SALES ORDERS] },
          'columns' => %w[ORDER_ID AMOUNT REGION].each_with_index.map { |c, i| { 'id' => "c#{i}", 'formula' => "[ORDERS/#{c}]", 'name' => c } } }] }] }.freeze
      def request(req)
        File.open(ENV.fetch('FAKE_SIGMA_LOG'), 'a') { |f| f.flock(File::LOCK_EX); f.puts("#{req.method} #{req.path}") }
        body = if req.path =~ %r{/v2/dataModels/[^/]+/spec}
                 JSON.generate(SPEC)
               elsif req.path =~ %r{\A/v2/dataModels\?}
                 JSON.generate('entries' => [], 'nextPage' => nil)
               elsif req.path.start_with?('/v2/whoami')
                 JSON.generate('userId' => 'user-1')
               else
                 '{}'
               end
        res = Net::HTTPOK.new('1.1', '200', 'OK')
        res.instance_variable_set(:@body, body)
        res.instance_variable_set(:@read, true)
        res
      end
    end
    class Net::HTTP
      def self.start(*_args, **_opts)
        conn = FakeSigmaConn.new
        block_given? ? yield(conn) : conn
      end
    end
  RUBY
  env = { 'RUBYOPT' => "-r#{stub}", 'FAKE_SIGMA_LOG' => log, 'HOME' => dir, 'SIGMA_API_TOKEN' => 'tok',
          'SIGMA_BASE_URL' => 'https://api.sigmacomputing.com', 'SIGMA_ALLOW_INSECURE_BASE_URL' => '' }
  File.write(File.join(dir, 'model.bim'), JSON.pretty_generate(MODEL))
  File.write(File.join(dir, 'bundle.json'), BUNDLE)
  pfd = File.join(dir, 'page-facts', 'sales-page')
  FileUtils.mkdir_p(pfd)
  File.write(File.join(pfd, 'page-fact.json'), JSON.pretty_generate(page_fact))
  todo_dir = File.join(dir, 'page-facts-todo', 'sales-page')
  FileUtils.mkdir_p(todo_dir)
  File.write(File.join(todo_dir, 'page-fact.json'), JSON.pretty_generate(page_fact(todo: true)))
  run = lambda do |work, *extra|
    File.delete(log) if File.exist?(log)
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    Open3.capture2e(env, RbConfig.ruby, MIGRATE, '--tmsl', File.join(dir, 'model.bim'), '--pbir', File.join(dir, 'bundle.json'),
                    '--out', File.join(dir, work), '--connection', CONN, '--database', 'DB', '--schema', 'SALES',
                    '--folder', 'f1', '--yes', '--stop-before-post', *extra)
  end
  writes = -> { (File.exist?(log) ? File.readlines(log) : []).map(&:strip).grep(/\A(POST|PUT|PATCH|DELETE) /) }

  puts "\n1. build-new: the page fact is folded into the DM spec before validation"
  out, st = run.call('w1', '--no-reuse', '--page-facts', File.join(dir, 'page-facts'))
  check(st.exitstatus.zero? && out.include?('STOP BEFORE POST: data model spec is ready'),
        "stops after DM validation (exit #{st.exitstatus})#{st.exitstatus.zero? ? '' : "\n#{out.lines.last(12).join}"}")
  dm = File.exist?(File.join(dir, 'w1', 'dm-spec.json')) ? JSON.parse(File.read(File.join(dir, 'w1', 'dm-spec.json'))) : {}
  el = (dm['pages'] || []).flat_map { |p| p['elements'] || [] }.find { |e| e['name'] == 'Sales Page Page Fact' }
  check(el && el.dig('source', 'kind') == 'sql' && el.dig('source', 'connectionId') == CONN, 'dm-spec.json carries the page-fact SQL element on --connection')
  check(el && el['columns'].map { |c| c['formula'] } == ['[Custom SQL/SUM_AMOUNT]'], 'its columns bind the SQL output names')
  check(out.include?('data model: add Sales Page Page Fact'), 'the integration is reported')
  check(writes.call.empty?, "zero writes reached Sigma (got #{writes.call.inspect})")

  puts "\n2. TODO page facts are refused unless --allow-page-fact-todo"
  out, st = run.call('w2', '--no-reuse', '--page-facts', File.join(dir, 'page-facts-todo'))
  check(!st.success? && out.include?('TODO') && out.include?('page-fact integration failed'), "refused (exit #{st.exitstatus})")
  check(writes.call.empty?, 'nothing written on refusal')
  out, st = run.call('w2b', '--no-reuse', '--page-facts', File.join(dir, 'page-facts-todo'), '--allow-page-fact-todo')
  check(st.exitstatus.zero? && out.include?('add Sales Page Page Fact'), "--allow-page-fact-todo integrates it (exit #{st.exitstatus})")

  puts "\n2b. --scaffold-page-facts with --stop-before-post is a draft-only run"
  out, st = run.call('w2c', '--no-reuse', '--scaffold-page-facts', 'Sales Page')
  draft = File.join(dir, 'w2c', 'page-facts-draft')
  check(st.exitstatus.zero? && File.exist?(File.join(draft, 'sales-page', 'page-fact.sql')) && out.include?('PAGE FACTS (draft)'),
        "the draft is written before the stop (exit #{st.exitstatus})#{st.exitstatus.zero? ? '' : "\n#{out.lines.last(12).join}"}")
  check(writes.call.empty?, "a draft-only run writes nothing to Sigma (got #{writes.call.inspect})")

  puts "\n3. DM reuse: changing the reused DM is the user's call"
  out, st = run.call('w3', '--reuse-dm', 'dm-fake-1', '--page-facts', File.join(dir, 'page-facts'))
  check(st.exitstatus == 10 && out.include?('page_facts_reused_dm'), "stops with an OPEN QUESTION (exit #{st.exitstatus})")
  check(writes.call.empty?, 'no PUT without --page-facts-update-dm')
  out, st = run.call('w4', '--reuse-dm', 'dm-fake-1', '--page-facts', File.join(dir, 'page-facts'), '--page-facts-update-dm')
  check(st.exitstatus.zero? && out.include?('would PUT them into reused data model dm-fake-1'),
        "--page-facts-update-dm with --stop-before-post reports the PUT (exit #{st.exitstatus})#{st.exitstatus.zero? ? '' : "\n#{out.lines.last(12).join}"}")
  check(writes.call.empty?, "--stop-before-post still writes nothing (got #{writes.call.inspect})")
  rspec = File.exist?(File.join(dir, 'w4', 'dm-spec.json')) ? JSON.parse(File.read(File.join(dir, 'w4', 'dm-spec.json'))) : {}
  check((rspec['pages'] || []).flat_map { |p| p['elements'] || [] }.any? { |e| e['name'] == 'Sales Page Page Fact' },
        'the reused spec on disk carries the page fact it would PUT')
end

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "#{FAILS.size} FAILED:"
  FAILS.each { |x| puts "  - #{x}" }
  exit 1
end
