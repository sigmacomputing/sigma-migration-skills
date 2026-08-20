#!/usr/bin/env ruby
# frozen_string_literal: true
# test-probe-join-keys.rb — unit test for scripts/probe-join-keys.rb in
# --fixture mode (canned per-entry JSON results, the same offline seam
# convention as test-verify-warehouse.rb). No warehouse, no network.
#
# Covers: unique → status unique + exit 0; a Custom-SQL target (right_table
# null, right_sql set) probed as a FROM (<right_sql>) t subquery; non-unique →
# FATAL block naming the entry + sample duplicate keys + both sanctioned
# resolutions + exit 2; --resolve records evidence and clears the failure;
# missing fixture → status error + exit 3; probe SQL recorded on the entry.
#
# Live-path coverage (stubbed sigma_rest, same -I <stub> -r sigma_rest seam as
# test-parity-render-verify-fallback.rb): no --folder-id → infer the required
# UUID from the migration workdir's wb-spec.json; no flag or artifact refuses
# before a POST; the body uses the current nested document envelope with flat
# elements; --folder-id supplied → stamped; a POST 400 → probe_error records
# the HTTP status + response-body excerpt and the console prints a --folder-id
# hint when the error mentions the folder.
#
# W2.9 identifier-legality gate — six-trajectory matrix (the oracle itself is
# unit-covered in test-sql-ident-check.rb Part J; derivation stripping in
# test-join-plan.rb's W2.9 section):
#   T1 trip:     role-paren residue key → clean status 'error', probe_error
#                names the class + --resolve route; NO probe_sql, fixture
#                never consulted
#   T2 trip:     GUID field-id key / garbled VC FQN → refused, named reasons
#   T3 no-trip:  plain upper-snake keys + FQN → byte-identical SQL (the
#                exact-string pins in the sections above)
#   T4 clear:    spaced physical key + spaced FQN part → QUOTED, probeable
#   T5 escape:   refused entry takes --resolve --how waived (same path as any
#                blocked entry)
#   T6 contract: live path sends ZERO POSTs on refusal (never-live-SQL red
#                line); mixed ledger still probes the legal sibling, exit 3
#
# Run: ruby scripts/test-probe-join-keys.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'probe-join-keys.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)

# Stub sigma_rest for the live-probe path: records every request to
# SIGMA_STUB_LOG (JSON lines), then marks the real lib path as already
# required so the script's own `require 'sigma_rest'` no-ops instead of
# overriding the stub. SIGMA_STUB_400=1 makes the probe-workbook POST raise
# the same "<METHOD> <path> -> <code> <message>\n<body>" Sigma::Error shape
# the real lib raises.
SIGMA_STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    @spec_posts = 0
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if ENV['SIGMA_STUB_LOG']
        File.open(ENV['SIGMA_STUB_LOG'], 'a') { |f| f.puts JSON.generate('method' => method.to_s, 'path' => path, 'body' => body) }
      end
      if method == :post && path == '/v2/workbooks/spec'
        if ENV['SIGMA_STUB_400']
          raise Error, "POST /v2/workbooks/spec -> 400 Bad Request\n" \
                       '{"code":"bad_request","message":"invalid folderId: must be a valid folder UUID"}'
        end
        @spec_posts += 1
        return { 'workbookId' => "wb-#{@spec_posts}" }
      end
      return { 'queryId' => "q-#{path[/wb-(\d+)/, 1]}" } if method == :post && path.include?('/export')
      if method == :get && path.start_with?('/v2/query/')
        # wb-1/q-1 = the duplicate-sample query (no dup rows), wb-2/q-2 = totals.
        return path.include?('q-1') ? "ENTITY_ID,C\n" : "TOTAL_ROWS,DISTINCT_KEYS\n100,100\n"
      end
      return nil if method == :delete
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_probe_live(dir, env, *args)
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir) unless Dir.exist?(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), SIGMA_STUB)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub' }.merge(env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', SCRIPT, '--workdir', dir, *args)
end

def spec_posts(log)
  File.readlines(log).map { |l| JSON.parse(l) }
      .select { |r| r['method'] == 'post' && r['path'] == '/v2/workbooks/spec' }
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def entry(over = {})
  {
    'kind' => 'lookup-synthesis', 'left' => 'Rev Primary', 'right' => 'Rev Contra',
    'keys' => ['Entity Id'], 'probe_keys' => ['ENTITY_ID'],
    'right_table' => 'ANALYTICS.PUBLIC.REV_CONTRA',
    'grain_assumption' => 'right unique on keys', 'status' => 'unprobed'
  }.merge(over)
end

def workdir_with(dir, entries)
  File.write(File.join(dir, 'join-plan.json'), JSON.pretty_generate('entries' => entries))
end

def run_probe(dir, *args)
  Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
end

def ledger(dir)
  JSON.parse(File.read(File.join(dir, 'join-plan.json')))['entries']
end

puts '== unique fixture → status unique, exit 0 =='
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'), JSON.generate('total' => 100, 'distinct' => 100, 'duplicates' => []))
  out, _err, st = run_probe(dir, '--fixture', fx)
  check(st.success?, "exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('UNIQUE'), 'prints the UNIQUE verdict', fails)
  e = ledger(dir)[0]
  check(e['status'] == 'unique', "ledger status unique (got #{e['status']})", fails)
  check(e['counts'] == { 'total' => 100, 'distinct' => 100 }, 'counts recorded as evidence', fails)
  check(e['probe_sql']['duplicates'] ==
        'SELECT ENTITY_ID, COUNT(*) AS C FROM ANALYTICS.PUBLIC.REV_CONTRA GROUP BY ENTITY_ID HAVING COUNT(*) > 1 ORDER BY C DESC LIMIT 5',
        "duplicate-sample SQL recorded (got #{e['probe_sql']['duplicates'].inspect})", fails)
  check(e['probe_sql']['totals'] ==
        'SELECT COUNT(*) AS TOTAL_ROWS, COUNT(DISTINCT ENTITY_ID) AS DISTINCT_KEYS FROM ANALYTICS.PUBLIC.REV_CONTRA',
        'totals SQL recorded', fails)
  check(e['probed_at'].is_a?(String) && !e['probed_at'].empty?, 'probed_at stamped', fails)
end

puts "\n== multi-key totals SQL concatenates the keys =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('probe_keys' => %w[ENTITY_ID ACTIVITY_DATE])])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'), JSON.generate('total' => 5, 'distinct' => 5, 'duplicates' => []))
  _out, _err, st = run_probe(dir, '--fixture', fx)
  check(st.success?, 'multi-key unique → exit 0', fails)
  sqls = ledger(dir)[0]['probe_sql']
  check(sqls['totals'].include?("COALESCE(TO_VARCHAR(ENTITY_ID), '') || '|' || COALESCE(TO_VARCHAR(ACTIVITY_DATE), '')"),
        "totals SQL concatenates multi-key (got #{sqls['totals'].inspect})", fails)
  check(sqls['duplicates'].include?('GROUP BY ENTITY_ID, ACTIVITY_DATE'), 'dup SQL groups by both keys', fails)
end

puts "\n== Custom-SQL target (right_table null, right_sql set) probes as a subquery =="
Dir.mktmpdir do |dir|
  stmt = 'SELECT ENTITY_ID, REGION FROM ANALYTICS.PUBLIC.REV_OFFSET WHERE REGION IS NOT NULL'
  workdir_with(dir, [entry('right_table' => nil, 'right_sql' => stmt)])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'), JSON.generate('total' => 42, 'distinct' => 42, 'duplicates' => []))
  _out, _err, st = run_probe(dir, '--fixture', fx)
  check(st.success?, "sql-target unique → exit 0 (got #{st.exitstatus})", fails)
  e = ledger(dir)[0]
  check(e['status'] == 'unique', 'sql-target ledger status unique', fails)
  check(e['probe_sql']['duplicates'] ==
        "SELECT ENTITY_ID, COUNT(*) AS C FROM (#{stmt}) t GROUP BY ENTITY_ID HAVING COUNT(*) > 1 ORDER BY C DESC LIMIT 5",
        "dup SQL wraps the statement as a subquery (got #{e['probe_sql']['duplicates'].inspect})", fails)
  check(e['probe_sql']['totals'] ==
        "SELECT COUNT(*) AS TOTAL_ROWS, COUNT(DISTINCT ENTITY_ID) AS DISTINCT_KEYS FROM (#{stmt}) t",
        "totals SQL wraps the statement as a subquery (got #{e['probe_sql']['totals'].inspect})", fails)
end

puts "\n== W2.9: spaced physical key + spaced FQN part emit QUOTED (still probeable) =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('probe_keys' => ['Order Key'], 'right_table' => 'ANALYTICS.MY SCHEMA.REV_CONTRA')])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'), JSON.generate('total' => 10, 'distinct' => 10, 'duplicates' => []))
  _out, _err, st = run_probe(dir, '--fixture', fx)
  check(st.success?, "quoted-key unique → exit 0 (got #{st.exitstatus})", fails)
  e = ledger(dir)[0]
  check(e['status'] == 'unique', 'quoted-key ledger status unique', fails)
  check(e['probe_sql']['duplicates'] ==
        'SELECT "Order Key", COUNT(*) AS C FROM ANALYTICS."MY SCHEMA".REV_CONTRA GROUP BY "Order Key" HAVING COUNT(*) > 1 ORDER BY C DESC LIMIT 5',
        "dup SQL quotes the spaced key + FQN part (got #{e['probe_sql']['duplicates'].inspect})", fails)
  check(e['probe_sql']['totals'] ==
        'SELECT COUNT(*) AS TOTAL_ROWS, COUNT(DISTINCT "Order Key") AS DISTINCT_KEYS FROM ANALYTICS."MY SCHEMA".REV_CONTRA',
        'totals SQL quotes the spaced key', fails)
end

puts "\n== W2.9: role-paren residue key → clean 'error', fixture NEVER consulted, no probe_sql =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('probe_keys' => ['PRODUCT_KEY_(PRODUCT_DIM)'])])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  # A fixture with clean results EXISTS — proving refusal preempts acquisition.
  File.write(File.join(fx, 'entry-0.json'), JSON.generate('total' => 10, 'distinct' => 10, 'duplicates' => []))
  out, err, st = run_probe(dir, '--fixture', fx)
  check(st.exitstatus == 3, "refused identifier → exit 3 (got #{st.exitstatus})", fails)
  check(err.include?('could not be probed'), 'error summary printed (gate keeps blocking)', fails)
  e = ledger(dir)[0]
  check(e['status'] == 'error', 'ledger status error', fails)
  check(e['probe_error'].to_s.include?('not legal to send to the warehouse'), 'probe_error names the refusal', fails)
  check(e['probe_error'].to_s.include?('parenthesis residue'), 'probe_error names the parenthesis-residue class', fails)
  check(e['probe_error'].to_s.include?('--resolve 0 --how waived'), 'probe_error routes to the --resolve path', fails)
  check(!e.key?('probe_sql'), 'NO probe_sql recorded — garbled SQL never built', fails)
  check(!e.key?('counts'), 'fixture result never consulted (no counts)', fails)
  check(out.include?('no SQL sent'), 'console states no SQL was sent', fails)
  # The SAME --resolve path clears it (operator escalation).
  _out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'waived',
                             '--reason', 'operator: key is display-only; join probed by hand')
  check(st.success?, 'refused entry takes a waived resolution → exit 0', fails)
end

puts "\n== W2.9: GUID field-id key + garbled VC FQN → refused with named reasons =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [
                 entry('probe_keys' => ['AB12CD34-0000-1111-2222-333344445555']),
                 entry('right_table' => 'abcdef0123456789-abcdef01.ORDERS (X.TABLE)')
               ])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  _out, _err, st = run_probe(dir, '--fixture', fx)
  check(st.exitstatus == 3, "refused entries → exit 3 (got #{st.exitstatus})", fails)
  e0, e1 = ledger(dir)
  check(e0['status'] == 'error' && e0['probe_error'].to_s.include?('GUID-shaped'),
        'GUID key refused with the GUID reason', fails)
  check(e1['status'] == 'error' && e1['probe_error'].to_s.include?('not legal'),
        'garbled VC FQN refused (parts fail the oracle)', fails)
  check(!e1.key?('probe_sql'), 'garbled FQN: no probe_sql recorded', fails)
end

puts "\n== W2.9: mixed ledger — legal entry probed, refused entry errored, exit 3 =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry, entry('probe_keys' => ['PRODUCT_KEY_(PRODUCT_DIM)'])])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'), JSON.generate('total' => 7, 'distinct' => 7, 'duplicates' => []))
  _out, _err, st = run_probe(dir, '--fixture', fx)
  check(st.exitstatus == 3, "mixed → exit 3 (got #{st.exitstatus})", fails)
  e0, e1 = ledger(dir)
  check(e0['status'] == 'unique', 'legal sibling entry still probed to unique', fails)
  check(e1['status'] == 'error', 'refused sibling entry errored', fails)
end

puts "\n== W2.9: live path — refused identifier sends NOTHING (zero POSTs) =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('probe_keys' => ['PRODUCT_KEY_(PRODUCT_DIM)'])])
  log = File.join(dir, 'stub.log')
  _out, _err, st = run_probe_live(dir, { 'SIGMA_STUB_LOG' => log },
                                  '--connection-id', 'conn-1', '--folder-id', 'fld-123')
  check(st.exitstatus == 3, "live refused → exit 3 (got #{st.exitstatus})", fails)
  check(!File.exist?(log) || spec_posts(log).empty?,
        'refused identifier → ZERO probe-workbook POSTs (never live SQL)', fails)
  check(ledger(dir)[0]['status'] == 'error', 'live refused entry recorded as error', fails)
end

puts "\n== non-unique fixture → FATAL block + exit 2 =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'),
             JSON.generate('total' => 120, 'distinct' => 100,
                           'duplicates' => [{ 'keys' => { 'ENTITY_ID' => '17' }, 'count' => 3 },
                                            { 'keys' => { 'ENTITY_ID' => '42' }, 'count' => 2 }]))
  _out, err, st = run_probe(dir, '--fixture', fx)
  check(st.exitstatus == 2, "exit 2 (got #{st.exitstatus})", fails)
  check(err.include?('JOIN-CARDINALITY FATAL'), 'FATAL block printed', fails)
  check(err.include?("entry #0 (lookup-synthesis): Rev Primary -> Rev Contra on (ENTITY_ID)"),
        'FATAL names the exact entry', fails)
  check(err.include?('ENTITY_ID=17  -> 3 rows'), 'sample duplicate keys + counts shown', fails)
  check(err.include?('120 row(s) over 100 distinct key(s)'), 'totals evidence shown', fails)
  check(err.include?('PRE-AGGREGATE the target to the key grain') && err.include?('grouped helper element'),
        'resolution (a): pre-aggregate + repoint described', fails)
  check(err.include?('OPERATOR ESCALATION'), 'resolution (b): operator escalation named', fails)
  check(err.include?('--resolve 0 --how preaggregated') && err.include?('--resolve 0 --how waived'),
        'both --resolve commands printed with the entry index', fails)
  e = ledger(dir)[0]
  check(e['status'] == 'non-unique', 'ledger status non-unique', fails)
  check(e['duplicates'].length == 2 && e['duplicates'][0]['count'] == 3, 'sample duplicates persisted in the ledger', fails)
end

puts "\n== --resolve records evidence and clears the failure =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('status' => 'non-unique',
                           'counts' => { 'total' => 120, 'distinct' => 100 },
                           'duplicates' => [{ 'keys' => { 'ENTITY_ID' => '17' }, 'count' => 3 }])])
  # unresolved non-unique blocks even with no probing flags
  _out, err, st = run_probe(dir, '--fixture', File.join(dir, 'nofx'))
  check(st.exitstatus == 2, 'unresolved non-unique blocks a re-run too', fails)
  check(err.include?('JOIN-CARDINALITY FATAL'), 're-run reprints the FATAL block', fails)
  # bad --resolve invocations
  _out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'preaggregated')
  check(!st.success?, '--resolve without --reason refuses', fails)
  _out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'shrugged', '--reason', 'x')
  check(!st.success?, '--resolve with an unsanctioned --how refuses', fails)
  # sanctioned resolution
  out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'preaggregated',
                            '--reason', 'grouped helper "Rev Contra by Entity" added; Lookup repointed')
  check(st.success?, "--resolve preaggregated → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('resolved: preaggregated'), 'resolution echoed', fails)
  e = ledger(dir)[0]
  check(e['resolution']['how'] == 'preaggregated' &&
        e['resolution']['reason'].include?('Rev Contra by Entity') &&
        e['resolution']['recorded_at'].is_a?(String),
        'resolution evidence {how, reason, recorded_at} persisted in the ledger', fails)
end

puts "\n== --resolve waived (operator escalation) also clears =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('status' => 'non-unique', 'counts' => { 'total' => 9, 'distinct' => 8 },
                           'duplicates' => [{ 'keys' => { 'ENTITY_ID' => '1' }, 'count' => 2 }])])
  _out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'waived', '--reason', 'operator accepted: contra rows are exact duplicates')
  check(st.success?, 'waived resolution → exit 0', fails)
  check(ledger(dir)[0]['resolution']['how'] == 'waived', 'waived evidence persisted', fails)
end

puts "\n== missing fixture → status error, exit 3 =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  _out, err, st = run_probe(dir, '--fixture', fx)
  check(st.exitstatus == 3, "exit 3 (got #{st.exitstatus})", fails)
  check(err.include?('could not be probed'), 'error summary printed', fails)
  check(ledger(dir)[0]['status'] == 'error', 'ledger status error (gate still blocks)', fails)
end

puts "\n== live probe, no --folder-id → infer required folderId from wb-spec.json =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  File.write(File.join(dir, 'wb-spec.json'), JSON.generate('folderId' => 'fld-inferred'))
  log = File.join(dir, 'stub.log')
  _out, err, st = run_probe_live(dir, { 'SIGMA_STUB_LOG' => log }, '--connection-id', 'conn-1')
  check(st.success?, "live-stub unique → exit 0 (got #{st.exitstatus}: #{err.lines.first})", fails)
  check(ledger(dir)[0]['status'] == 'unique', 'live-stub ledger status unique', fails)
  posts = spec_posts(log)
  check(posts.size == 2, "two probe-workbook POSTs (dup sample + totals; got #{posts.size})", fails)
  bodies = posts.map { |r| JSON.parse(r['body']) }
  check(bodies.all? { |b| b['folderId'] == 'fld-inferred' },
        'no --folder-id → POST body carries the workdir-inferred destination UUID', fails)
  check(bodies.all? { |b|
          doc = b['document']
          doc.is_a?(Hash) && doc['schemaVersion'] == 1 && doc['kind'] == 'workbook' &&
            doc['pages'].is_a?(Array) && doc['pages'].none? { |page| page.key?('elements') } &&
            doc['elements'].is_a?(Array) && doc['elements'].one? &&
            doc['elements'][0]['id'] == 'probe' && !doc['layout'].to_s.empty? &&
            !b.key?('schemaVersion') && !b.key?('pages')
        },
        'probe POST uses nested document, flat elements, and layout-owned page membership', fails)
end

puts "\n== live probe, no --folder-id and no workdir destination → refuse before POST =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  log = File.join(dir, 'stub.log')
  _out, err, st = run_probe_live(dir, { 'SIGMA_STUB_LOG' => log }, '--connection-id', 'conn-1')
  check(!st.success?, 'missing required destination exits nonzero', fails)
  check(err.include?('require --folder-id') && err.include?('wb-spec.json/dm-spec.json'),
        'failure names both the explicit flag and workdir inference path', fails)
  check(!File.exist?(log) || spec_posts(log).empty?,
        'missing destination refuses before any live probe-workbook POST', fails)
end

puts "\n== live probe, --folder-id supplied → folderId stamped on the POST body =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  log = File.join(dir, 'stub.log')
  _out, _err, st = run_probe_live(dir, { 'SIGMA_STUB_LOG' => log }, '--connection-id', 'conn-1', '--folder-id', 'fld-123')
  check(st.success?, "live-stub with --folder-id → exit 0 (got #{st.exitstatus})", fails)
  bodies = spec_posts(log).map { |r| JSON.parse(r['body']) }
  check(!bodies.empty? && bodies.all? { |b| b['folderId'] == 'fld-123' },
        '--folder-id fld-123 → every POST body carries folderId fld-123', fails)
end

puts "\n== live probe POST 400 → probe_error carries status + body excerpt + --folder-id hint =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  out, _err, st = run_probe_live(dir, { 'SIGMA_STUB_400' => '1' },
                                 '--connection-id', 'conn-1', '--folder-id', 'fld-bad')
  check(st.exitstatus == 3, "probe error → exit 3 (got #{st.exitstatus})", fails)
  e = ledger(dir)[0]
  check(e['status'] == 'error', 'ledger status error (gate still blocks)', fails)
  check(e['probe_error'].to_s.include?('400 Bad Request'),
        "probe_error records the HTTP status (got #{e['probe_error'].inspect})", fails)
  check(e['probe_error'].to_s.include?('must be a valid folder UUID'),
        'probe_error records the response-body excerpt, not a bare 400', fails)
  check(out.include?('400 Bad Request') && out.include?('must be a valid folder UUID'),
        'console ERROR line surfaces status + body excerpt', fails)
  check(out.include?('--folder-id'), 'console prints the --folder-id hint (error mentions the folder)', fails)
end

puts "\n== bad invocations =="
Dir.mktmpdir do |dir|
  _out, _err, st = run_probe(dir, '--fixture', dir) # no join-plan.json
  check(!st.success?, 'missing join-plan.json refuses', fails)
  workdir_with(dir, [entry])
  _out, _err, st = run_probe(dir) # neither --fixture nor --connection-id
  check(!st.success?, 'neither --fixture nor --connection-id refuses', fails)
end

puts
if fails.empty?
  puts 'test-probe-join-keys: ALL PASS'
else
  puts "test-probe-join-keys: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
