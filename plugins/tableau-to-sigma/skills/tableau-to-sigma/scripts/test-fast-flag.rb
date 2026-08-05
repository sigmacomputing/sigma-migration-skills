#!/usr/bin/env ruby
# Wiring/drift test (bead tt3z.23): the opt-in --fast flag must, at --finalize,
# waive the two VISUAL gates and NOT require the recorded comparison. This is a
# deterministic source-structure guard (network-free, creds-free) — it proves the
# flag is defined and wired into the assert-phase6-ran gate array exactly as
# intended, so a future refactor can't silently drop the opt-in or, worse, make it
# implicit. Behavioral end-to-end is covered by a live pivot-only migration run.
require 'set'
MT = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
$fail = 0
def ok(d); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{d}"; $fail += 1 unless r; end

ok('--fast REASON option is defined and sets opts[:fast]') do
  MT =~ /o\.on\('--fast REASON'.*\)\s*\{\s*\|v\|\s*opts\[:fast\]\s*=\s*v\s*\}/m
end
ok('--fast REASON is mandatory (REASON arg → recorded reason, not a bare flag)') do
  MT.include?("o.on('--fast REASON'")
end
ok('--require-visual-comparison (gate 8b) is SUPPRESSED under --fast') do
  MT =~ /gate \+= \['--require-visual-comparison'\]\s+unless opts\[:fast\]/
end
ok('--fast appends BOTH visual waivers with the operator reason') do
  MT =~ /gate \+= \['--skip-visual-gate', opts\[:fast\], '--skip-visual-comparison', opts\[:fast\]\] if opts\[:fast\]/
end
ok('the waiver append lands BEFORE the gate actually runs (sigma_run!)') do
  wi = MT.index("--skip-visual-gate', opts[:fast]")
  ri = MT.index('_, gst = sigma_run!(gate')
  wi && ri && wi < ri
end
ok('OFF by default: no code path sets opts[:fast] without the flag') do
  # opts[:fast] is only ever ASSIGNED in the --fast option block (never defaulted truthy)
  MT.scan(/opts\[:fast\]\s*=/).length == 1
end
# Downstream contract: assert-phase6-ran.rb actually accepts the two waivers --fast passes.
GATE = File.read(File.join(__dir__, 'assert-phase6-ran.rb'), encoding: 'UTF-8')
ok('assert-phase6-ran.rb accepts --skip-visual-gate (gate 8 escape)') { GATE.include?('--skip-visual-gate') }
ok('assert-phase6-ran.rb accepts --skip-visual-comparison (gate 8b escape)') { GATE.include?('--skip-visual-comparison') }

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
