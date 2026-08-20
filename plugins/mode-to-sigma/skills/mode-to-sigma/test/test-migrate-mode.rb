#!/usr/bin/env ruby
#   ruby test/test-migrate-mode.rb
require_relative '../scripts/migrate-mode'
require 'tmpdir'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== phase_order =="
eq(PHASE_ORDER, %w[discover build-dm post-dm build-workbook post-workbook verify-parity assert-phase6],
   'orchestrator runs phases in the documented C2->C8 order, no skipped gates')

puts "== fail_phase! aborts with the phase name in the message =="
begin
  fail_phase!('build-dm', 'boom')
  $failures += 1; puts "  FAIL: fail_phase! should raise"
rescue MigrationFailed => e
  eq(e.message, 'build-dm: boom', 'fail_phase! message names the phase')
end

puts "== run_script! threads env: into the child process (Finding 1 regression guard) =="
# Live proof that Open3.capture3(env, ...) actually reaches the child — a stub
# script that writes its MODE_DISCOVERY_DIR env var to a file, so we can
# assert the orchestrator's env: kwarg was really threaded through rather than
# silently dropped (the exact bug that left mode-discover.rb writing to a
# fixed plugin-dir path on every real run).
#
# The stub is written into Dir.mktmpdir, NEVER into the tracked test/ tree —
# run_script!('name', ...) resolves `name` via File.expand_path(name, __dir__)
# (its OWN __dir__, i.e. scripts/), and File.expand_path leaves an already-
# absolute path untouched regardless of that base, so passing the tmpdir
# stub's absolute path works exactly the same as the old test/-relative one.
# This closes the litter risk the old version had (writing directly into
# test/ and relying on an `ensure` block to clean it up — a crash before that
# ensure ran would have left the stub committed-tree litter); Dir.mktmpdir's
# own block form guarantees cleanup even on a hard crash, with nothing ever
# touching the repo tree.
Dir.mktmpdir do |dir|
  stub = File.join(dir, 'stub-env-echo.rb')
  marker = File.join(dir, 'seen-env.txt')
  File.write(stub, <<~RUBY)
    File.write(#{marker.inspect}, ENV['MODE_DISCOVERY_DIR'].to_s)
  RUBY
  ok, code = run_script!(stub, env: { 'MODE_DISCOVERY_DIR' => dir })
  eq(ok, true, 'stub script exits 0')
  eq(code, 0, 'stub script exitstatus is 0')
  eq(File.read(marker), dir, "child process saw MODE_DISCOVERY_DIR=#{dir.inspect} via env:")
end

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
