#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline test for resolve-project.rb — the no-guessing vizportal-project-id
# resolver. Creds-free, network-free: pure module functions are exercised
# directly and the CLI runs against fixture GraphQL/REST JSON.
#
# Usage: ruby scripts/test-resolve-project.rb

require 'json'
require 'tmpdir'
require 'open3'

DIR      = __dir__
SCRIPT   = File.join(DIR, 'resolve-project.rb')
FX_GQL   = File.join(DIR, 'test-fixtures', 'resolve-project-graphql.json')
FX_REST  = File.join(DIR, 'test-fixtures', 'resolve-project-rest.json')

# Load the module (the CLI block is guarded by $PROGRAM_NAME == __FILE__).
load SCRIPT

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'test-resolve-project.rb — URL parse + grouping + CLI exit contract'

# --- 1. numeric-id URL parsing (several URL forms) --------------------------
{
  'https://prod-useast-b.online.tableau.com/#/site/examplecorp/projects/1234567' => '1234567',
  'https://prod-useast-b.online.tableau.com/#/site/examplecorp/projects/1234567/workbooks' => '1234567',
  'https://prod-useast-b.online.tableau.com/#/site/examplecorp/projects/1234567?order=name' => '1234567',
  'https://tableau.example.com/#/projects/42' => '42',                       # default site
  'https://tableau.example.com/#/projects/42#anchor' => '42',
  'https://tableau.example.com/#/site/x/workbooks/999' => nil,               # not a project URL
  'https://tableau.example.com/#/site/x/projects/abc' => nil,                # non-numeric
  '' => nil,
  nil => nil
}.each do |url, want|
  got = ResolveProject.parse_vizportal_id(url)
  check(got == want, "parse #{url.inspect[0, 80]} → #{want.inspect} (got #{got.inspect})", fails)
end

# --- 1b. workbook-URL parsing (v4.2 — the direct-workbook-link fix) ----------
{
  'https://prod-useast-b.online.tableau.com/#/site/examplecorp/workbooks/4242001' => '4242001',
  'https://prod-useast-b.online.tableau.com/#/site/examplecorp/workbooks/4242001/views' => '4242001',
  'https://tableau.example.com/#/workbooks/999?:origin=card_share_link' => '999', # default site + query
  'https://tableau.example.com/#/site/x/projects/1234567/workbooks' => nil,       # project URL, not workbook
  'https://tableau.example.com/#/site/x/workbooks/SalesWB' => nil,                # non-numeric
  '' => nil,
  nil => nil
}.each do |url, want|
  got = ResolveProject.parse_workbook_vizportal_id(url)
  check(got == want, "wb-parse #{url.inspect[0, 80]} → #{want.inspect} (got #{got.inspect})", fails)
end

# --- 1c. workbook exact-match lookup (pure function) -------------------------
wb_fixture_rows = JSON.parse(File.read(FX_GQL)).dig('workbooks_response', 'data', 'workbooks')
whit = ResolveProject.resolve_workbook(wb_fixture_rows, '4242001')
check(!whit.nil? && whit[:workbook_luid] == 'wb-aaaa-1111' && whit[:name] == 'Sales Overview' &&
        whit[:project_luid] == 'proj-luid-finance' && whit[:project_name] == 'Finance Analytics',
      'workbook vizportal id resolves {workbook_luid, name, project_luid, project_name}', fails)
check(ResolveProject.resolve_workbook(wb_fixture_rows, 2233445)[:name] == 'Churn Deep Dive',
      'Integer workbook vizportal ids from the API resolve too (canonicalized)', fails)
check(ResolveProject.resolve_workbook(wb_fixture_rows, '424242').nil?,
      'unknown workbook id resolves to nil (never a guess)', fails)

# --- 2. grouping + exact-match lookup (pure functions) -----------------------
fx = JSON.parse(File.read(FX_GQL))
wb_rows = fx.dig('workbooks_response', 'data', 'workbooks')
ds_rows = fx.dig('datasources_response', 'data', 'publishedDatasources')
groups = ResolveProject.group_by_project(wb_rows, ds_rows)

check(groups.keys.sort == %w[1234567 7654321],
      "grouping keys canonicalized to String (got #{groups.keys.sort.inspect})", fails)
hit = ResolveProject.resolve(groups, '1234567')
check(!hit.nil? && hit[:project_luid] == 'proj-luid-finance' && hit[:project_name] == 'Finance Analytics',
      'exact match resolves project luid + name', fails)
check(hit[:workbooks].map { |w| w[:name] }.sort == ['Churn Deep Dive', 'Sales Overview'],
      'match carries the project\'s workbooks', fails)
check(hit[:datasources].map { |d| d[:name] } == ['Orders DS'],
      'match carries the project\'s published datasources', fails)
check(ResolveProject.resolve(groups, 7654321)[:project_name] == 'Operations',
      'Integer vizportal ids from the API resolve too (canonicalized)', fails)
check(ResolveProject.resolve(groups, '9999999').nil?,
      'unknown id resolves to nil (never a guess)', fails)
check(groups.values.none? { |g| g[:workbooks].any? { |w| w[:name] == 'Orphan Sheet' } },
      'rows with nil projectVizportalUrlId are excluded from grouping', fails)

# --- 3. candidates from REST Query Projects ---------------------------------
rows = ResolveProject.candidate_rows(JSON.parse(File.read(FX_REST)))
check(rows.length == 3, 'candidate_rows flattens every project', fails)
fin = rows.find { |r| r[:name] == 'Finance Analytics' }
check(fin && fin[:luid] == 'proj-luid-finance' && fin[:workbooks] == 2 && fin[:datasources] == 1,
      'candidate row carries luid + contentCounts', fails)
check(rows.find { |r| r[:name] == 'Empty Sandbox' }[:workbooks].nil?,
      'missing contentCounts renders as unknown, not 0', fails)
table = ResolveProject.format_candidates_table(rows)
check(table.include?('NEVER assume') && table.include?('proj-luid-ops'),
      'candidates table carries the ask-the-user instruction', fails)

# --- 4. CLI end-to-end (fixtures; exit codes are the contract) --------------
run = lambda do |*args|
  out, err, st = Open3.capture3('ruby', SCRIPT, *args)
  [out, err, st.exitstatus]
end

Dir.mktmpdir do |d|
  out_path = File.join(d, 'resolved.json')

  # happy path: URL with trailing segment → exit 0 + JSON artifact
  out, _err, st = run.call('--url', 'https://prod-useast-b.online.tableau.com/#/site/examplecorp/projects/1234567/workbooks',
                           '--fixture-graphql', FX_GQL, '--fixture-rest', FX_REST,
                           '--out', out_path)
  check(st == 0, "happy path exits 0 (got #{st})", fails)
  doc = File.exist?(out_path) ? JSON.parse(File.read(out_path)) : {}
  check(doc['vizportal_id'] == 1234567 && doc['project_luid'] == 'proj-luid-finance' &&
          doc['project_name'] == 'Finance Analytics',
        '--out JSON carries {vizportal_id, project_luid, project_name}', fails)
  check(doc['workbooks'].is_a?(Array) && doc['workbooks'].length == 2 &&
          doc['workbooks'].all? { |w| w['luid'] && w['name'] },
        '--out JSON workbooks: [{luid,name}]', fails)
  check(out.include?('proj-luid-finance'), 'happy path prints the resolved luid', fails)

  # no match → exit 2 + candidates table + never-assume instruction
  _out, err, st = run.call('--vizportal-id', '9999999',
                           '--fixture-graphql', FX_GQL, '--fixture-rest', FX_REST)
  check(st == 2, "unknown id exits 2 (got #{st})", fails)
  check(err.include?('Finance Analytics') && err.include?('Operations') && err.include?('NEVER assume'),
        'exit-2 output lists candidates + the ask-the-user instruction', fails)

  # empty metadata graph (Metadata API off / empty project) → same exit-2 shape
  empty_fx = File.join(d, 'empty-graphql.json')
  File.write(empty_fx, JSON.generate('workbooks_response' => { 'data' => { 'workbooks' => [] } }))
  _out, err, st = run.call('--vizportal-id', '1234567',
                           '--fixture-graphql', empty_fx, '--fixture-rest', FX_REST)
  check(st == 2 && err.include?('NEVER assume'),
        "empty metadata graph → exit 2 with candidates (got #{st})", fails)

  # WORKBOOK URL happy path (v4.2): /workbooks/<N> resolves the workbook itself
  wb_out_path = File.join(d, 'resolved-wb.json')
  out, _err, st = run.call('--url', 'https://prod-useast-b.online.tableau.com/#/site/examplecorp/workbooks/4242001/views',
                           '--fixture-graphql', FX_GQL, '--fixture-rest', FX_REST,
                           '--out', wb_out_path)
  check(st == 0, "workbook URL happy path exits 0 (got #{st})", fails)
  wdoc = File.exist?(wb_out_path) ? JSON.parse(File.read(wb_out_path)) : {}
  check(wdoc['workbook_vizportal_id'] == 4242001 && wdoc['workbook_luid'] == 'wb-aaaa-1111' &&
          wdoc['name'] == 'Sales Overview' && wdoc['project_luid'] == 'proj-luid-finance' &&
          wdoc['project_name'] == 'Finance Analytics',
        '--out JSON carries {workbook_vizportal_id, workbook_luid, name, project_luid, project_name}', fails)
  check(out.include?('wb-aaaa-1111'), 'workbook happy path prints the resolved workbook luid', fails)

  # WORKBOOK URL, unknown id → exit 2 + workbook candidates + never-assume
  _out, err, st = run.call('--url', 'https://tableau.example.com/#/site/x/workbooks/424242',
                           '--fixture-graphql', FX_GQL, '--fixture-rest', FX_REST)
  check(st == 2, "unknown workbook id exits 2 (got #{st})", fails)
  check(err.include?('Sales Overview') && err.include?('Ops Monitor') && err.include?('NEVER assume'),
        'workbook exit-2 output lists candidates + the ask-the-user instruction', fails)

  # URL with NEITHER /projects/<N> nor /workbooks/<N> → exit 2 with usage
  _out, err, st = run.call('--url', 'https://tableau.example.com/#/site/x/views/SalesWB/Dash',
                           '--fixture-graphql', FX_GQL, '--fixture-rest', FX_REST)
  check(st == 2 && err.include?('no numeric /projects/<id> or /workbooks/<id>'),
        "URL without any numeric id → exit 2 usage error (got #{st})", fails)

  # --help works with no creds, no fixtures, no network
  out, _err, st = run.call('--help')
  check(st == 0 && out.include?('--vizportal-id'), '--help exits 0 without creds', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — resolve-project resolver + CLI contract behave correctly'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
