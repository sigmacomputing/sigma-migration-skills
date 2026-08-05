#!/usr/bin/env ruby
# frozen_string_literal: true
# PR-18 — probe-int-dim-cardinality.rb OPTIONAL confirmation, fixture (offline) mode.
#
# The .twb detection is primary; this probe adds a bounded COUNT(DISTINCT col)
# warehouse confirmation via PR-4's one-shot probe-workbook seam. Offline it
# reads DIR/entry-<i>.json {"distinct": N}. Asserts: a low distinct count
# confirms (integer-coded dimension), a high one does not, an errored entry is
# recorded but the run still exits 0 (confirmation NEVER gates), and a candidate
# with no {table, warehouse_column} is skipped (detection still holds).
#
# Usage:  ruby scripts/test-int-dim-cardinality-probe.rb
require 'json'
require 'tmpdir'

DIR   = __dir__
PROBE = File.join(DIR, 'probe-int-dim-cardinality.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

status = nil
ledger = nil
log = ''
Dir.mktmpdir do |d|
  File.write(File.join(d, 'integer-dim-decode.json'), JSON.pretty_generate(
    'version' => 1, 'source' => 'tableau',
    'candidates' => [
      { 'controlId' => 'ctl-store-key', 'name' => 'Store Key', 'column' => 'Store Key',
        'table' => 'DEMO_DB.ANALYTICS.STORE_DIM', 'warehouse_column' => 'STORE_KEY' },
      { 'controlId' => 'ctl-txn-id', 'name' => 'Txn Id', 'column' => 'Txn Id',
        'table' => 'DEMO_DB.ANALYTICS.SALE_FACT', 'warehouse_column' => 'TXN_ID' },
      { 'controlId' => 'ctl-bad', 'name' => 'Bad', 'column' => 'Bad',
        'table' => 'DEMO_DB.ANALYTICS.X', 'warehouse_column' => 'Y' },
      { 'controlId' => 'ctl-no-target', 'name' => 'No Target', 'column' => 'No Target' }
    ]
  ))
  fx = File.join(d, 'fixture')
  Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'), JSON.dump('distinct' => 42))     # low → confirmed
  File.write(File.join(fx, 'entry-1.json'), JSON.dump('distinct' => 90_000)) # high → not confirmed
  File.write(File.join(fx, 'entry-2.json'), JSON.dump('error' => 'table not found')) # error
  # entry-3 has no {table, warehouse_column}; in fixture mode it probes by index
  # anyway, so provide a fixture for it too (a low count).
  File.write(File.join(fx, 'entry-3.json'), JSON.dump('distinct' => 8))

  log = IO.popen(['ruby', PROBE, '--workdir', d, '--fixture', fx, '--max-cardinality', '1000'], err: %i[child out], &:read).force_encoding('UTF-8')
  status = $?.exitstatus
  ledger = JSON.parse(File.read(File.join(d, 'integer-dim-decode.json')))
end

check(status.zero?, "probe exits 0 (confirmation never gates; got #{status})", fails)
c = ->(name) { Array(ledger['candidates']).find { |x| x['name'] == name } }

sk = c.call('Store Key')
check(sk && sk['cardinality'] == 42 && sk['confirmed'] == true && sk['cardinality_status'] == 'confirmed-low-cardinality',
      "low distinct → confirmed integer-coded dimension (got #{sk && sk.slice('cardinality', 'confirmed').inspect})", fails)
check(sk && sk['probe_sql'] =~ /COUNT\(DISTINCT STORE_KEY\).*FROM DEMO_DB\.ANALYTICS\.STORE_DIM/,
      'records the bounded COUNT(DISTINCT ...) SQL it ran', fails)

txn = c.call('Txn Id')
check(txn && txn['cardinality'] == 90_000 && txn['confirmed'] == false && txn['cardinality_status'] == 'high-cardinality',
      "high distinct → NOT confirmed (got #{txn && txn.slice('cardinality', 'confirmed').inspect})", fails)

bad = c.call('Bad')
check(bad && bad['cardinality_status'] == 'error' && bad['probe_error'].to_s.include?('table not found'),
      'an errored probe is recorded but never crashes the run', fails)

check(log =~ /CONFIRM.*Store Key/ && log =~ /HICARD.*Txn Id/,
      'log summarizes each candidate (CONFIRM / HICARD)', fails)

# No-ledger run is a clean no-op (no integer-dim control on the workbook).
Dir.mktmpdir do |d|
  o = IO.popen(['ruby', PROBE, '--workdir', d, '--fixture', d], err: %i[child out], &:read).force_encoding('UTF-8')
  check($?.exitstatus.zero? && o =~ /nothing to confirm/i,
        'no ledger → clean no-op exit 0', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — cardinality probe confirms low-cardinality integer dims (fixture mode), never gates'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- probe log ---\n#{log}"
  exit 1
end
