#!/usr/bin/env ruby
# test-intake.rb — unit test for the migration front-door (intake.rb): connection
# resolution precedence + intake.json run metadata. Offline — the /v2/connections
# listing is exercised via the --connections-fixture test seam, never the network.
# Canonical in shared/scripts (epic [bead]). Run: ruby scripts/test-intake.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'

INTAKE = File.join(__dir__, 'intake.rb')
RUBY   = RbConfig.ruby
UUID   = '11111111-2222-3333-4444-555555555555'
UUID2  = '66666666-2222-3333-4444-555555555555'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

def run(dir, *args, env: {})
  # returns [exit_status, connection_hash_or_nil]
  # SIGMA_SKIP_BOOTSTRAP_GATE: these cases test connection resolution, not the
  # PR-15 bootstrap gate (which has its own cases below) — waive it by default.
  base = { 'SIGMA_CONNECTION_ID' => nil, 'SIGMA_SKIP_BOOTSTRAP_GATE' => 'unit-test' }
  system(base.merge(env), RUBY, INTAKE, '--workdir', dir, *args, out: File::NULL, err: File::NULL)
  st = $?.exitstatus
  conn = (JSON.parse(File.read(File.join(dir, 'connection.json'))) rescue nil)
  [st, conn]
end

def fixture(dir, *conns)
  path = File.join(dir, 'fx.json')
  entries = conns.map { |id, name, type| { 'connectionId' => id, 'name' => name, 'type' => type } }
  File.write(path, JSON.generate('entries' => entries))
  path
end

# 1. explicit UUID wins
Dir.mktmpdir do |d|
  st, c = run(d, '--tool', 'tableau-to-sigma', '--mode', 'live', '--connection', UUID)
  ok('explicit UUID → exit 0', st == 0)
  ok('explicit UUID cached', c && c['connection_id'] == UUID && c['resolved_via'] == 'flag')
  intake = JSON.parse(File.read(File.join(d, 'intake.json')))
  ok('intake.json mode', intake['input_mode'] == 'live')
  ok('intake.json run_start present', !intake['run_start'].to_s.empty?)
end

# 2. malformed UUID → exit 2
Dir.mktmpdir { |d| st, _ = run(d, '--connection', 'nope'); ok('bad UUID → exit 2', st == 2) }

# 3. cached connection.json reused (no flag)
Dir.mktmpdir do |d|
  run(d, '--connection', UUID)
  st, c = run(d, '--mode', 'live')
  ok('cache reused → exit 0', st == 0)
  ok('resolved_via cache', c && c['resolved_via'] == 'cache')
end

# 4. fixture with a single connection → auto-pick
Dir.mktmpdir do |d|
  fx = fixture(d, [UUID, 'Snowflake Prod', 'snowflake'])
  st, c = run(d, '--mode', 'file', '--connections-fixture', fx)
  ok('single connection auto-picked', st == 0 && c['connection_id'] == UUID && c['resolved_via'] == 'only-connection')
end

# 5. fixture with multiple → exit 3 + candidates written, no connection.json
Dir.mktmpdir do |d|
  fx = fixture(d, [UUID, 'SF', 'snowflake'], [UUID2, 'BQ', 'bigquery'])
  st, c = run(d, '--connections-fixture', fx)
  ok('ambiguous → exit 3', st == 3)
  ok('no connection.json written when ambiguous', c.nil?)
  ok('candidates file written', File.exist?(File.join(d, 'connection-candidates.json')))
end

# 6. fixture multiple + unique --name match → auto-pick
Dir.mktmpdir do |d|
  fx = fixture(d, [UUID, 'SF', 'snowflake'], [UUID2, 'BigQuery', 'bigquery'])
  st, c = run(d, '--name', 'bigquery', '--connections-fixture', fx)
  ok('name-match auto-pick', st == 0 && c['connection_id'] == UUID2 && c['resolved_via'] == 'name-match')
end

# 7. ENV SIGMA_CONNECTION_ID used when no flag/cache/fixture
Dir.mktmpdir do |d|
  st, c = run(d, '--mode', 'both', env: { 'SIGMA_CONNECTION_ID' => UUID })
  ok('env connection used', st == 0 && c['connection_id'] == UUID && c['resolved_via'] == 'env')
end

# 8. PR-15 bootstrap-sentinel gate: no sentinel → exit 6, nothing resolved.
# (HOME is pointed at the empty workdir so a real ~/.sigma-migration/bootstrap.json
# on the dev machine can't satisfy the gate.)
Dir.mktmpdir do |d|
  home = File.join(d, 'home'); FileUtils.mkdir_p(home)
  st, c = run(d, '--connection', UUID,
              env: { 'SIGMA_SKIP_BOOTSTRAP_GATE' => nil, 'HOME' => home, 'USERPROFILE' => home })
  ok('no bootstrap sentinel → exit 6', st == 6)
  ok('no connection.json written when refused', c.nil?)
end

# 9. sentinel present + doctor_pass → gate opens (workdir sentinel)
Dir.mktmpdir do |d|
  home = File.join(d, 'home'); FileUtils.mkdir_p(home)
  File.write(File.join(d, 'bootstrap.json'),
             JSON.generate('bootstrap_version' => 1, 'doctor_pass' => true, 'mode' => 'full'))
  st, c = run(d, '--connection', UUID,
              env: { 'SIGMA_SKIP_BOOTSTRAP_GATE' => nil, 'HOME' => home, 'USERPROFILE' => home })
  ok('sentinel present → gate opens', st == 0 && c && c['connection_id'] == UUID)
end

# 10. sentinel present but doctor_pass:false → still refused (exit 6)
Dir.mktmpdir do |d|
  home = File.join(d, 'home'); FileUtils.mkdir_p(home)
  File.write(File.join(d, 'bootstrap.json'),
             JSON.generate('bootstrap_version' => 1, 'doctor_pass' => false, 'mode' => 'full'))
  st, = run(d, '--connection', UUID,
            env: { 'SIGMA_SKIP_BOOTSTRAP_GATE' => nil, 'HOME' => home, 'USERPROFILE' => home })
  ok('sentinel with doctor_pass:false → exit 6', st == 6)
end

# 11. home-dir sentinel (the stable location bootstrap always writes) also opens the gate
Dir.mktmpdir do |d|
  home = File.join(d, 'home')
  FileUtils.mkdir_p(File.join(home, '.sigma-migration'))
  File.write(File.join(home, '.sigma-migration', 'bootstrap.json'),
             JSON.generate('bootstrap_version' => 1, 'doctor_pass' => true, 'mode' => 'full'))
  st, c = run(d, '--connection', UUID,
              env: { 'SIGMA_SKIP_BOOTSTRAP_GATE' => nil, 'HOME' => home, 'USERPROFILE' => home })
  ok('home sentinel → gate opens', st == 0 && c && c['connection_id'] == UUID)
end

# 12. --skip-bootstrap-gate waives with a reason
Dir.mktmpdir do |d|
  home = File.join(d, 'home'); FileUtils.mkdir_p(home)
  st, c = run(d, '--connection', UUID, '--skip-bootstrap-gate', 'sandbox with no bootstrap',
              env: { 'SIGMA_SKIP_BOOTSTRAP_GATE' => nil, 'HOME' => home, 'USERPROFILE' => home })
  ok('--skip-bootstrap-gate waives', st == 0 && c && c['connection_id'] == UUID)
end

puts $fail.zero? ? "\nall intake tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
