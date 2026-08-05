#!/usr/bin/env ruby
# frozen_string_literal: true
# Wiring guard for the DM-reuse SELF-HEAL (2026-07-09).
#
# When a DM is AUTO-PICKED for reuse (opts[:reuse_dm] == :recommended) and the
# workbook build fails (e.g. the reused DM is a full column-superset but lacks a
# role-playing dimension alias the master needs — the KNOWN RESIDUAL of the
# auto-pick column-superset gate), the orchestrator must rebuild a FRESH DM
# automatically (re-invoke self + --skip-reuse-scan) instead of the exit-4
# handoff — and ONLY for auto-picked reuse (an explicit --reuse-dm <id> is the
# user's choice), ONCE (SIGMA_SELFHEAL_RETRIED guard). Behavioral proof is the
# live E2E; this guards the wiring against silent removal/regression.
#
# Usage: ruby scripts/test-reuse-selfheal.rb

DIR = __dir__
src = File.read(File.join(DIR, 'migrate-tableau.rb'))
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# Locate the WorkbookBuildError rescue and the self-heal block within it.
rescue_idx = src.index('rescue WorkbookBuildError')
check(!rescue_idx.nil?, 'WorkbookBuildError rescue present', fails)
block = rescue_idx ? src[rescue_idx, 2800] : '' # self-heal block + reach the exit-4 handoff

check(src.include?('ORIGINAL_ARGV = ARGV.dup'), 'ARGV snapshotted before OptionParser consumes it', fails)
check(block.include?("opts[:reuse_dm] == :recommended"),
      'self-heal gates on AUTO-PICKED reuse (:recommended), not an explicit --reuse-dm id', fails)
check(block.include?("SIGMA_SELFHEAL_RETRIED"), 'self-heal is guarded against re-entry (fires once)', fails)
check(block.include?("--skip-reuse-scan"), 'self-heal re-invokes with --skip-reuse-scan (fresh DM)', fails)
check(block.include?('ORIGINAL_ARGV'), 'self-heal replays the original args', fails)
check(block.include?('reuse-selfheal'), 'self-heal records an off-ramp event', fails)
# The self-heal must come BEFORE the exit-4 handoff in the rescue body (search
# the full source from the rescue, not the truncated window).
heal_at = rescue_idx && src.index('SIGMA_SELFHEAL_RETRIED', rescue_idx)
exit4_at = rescue_idx && src.index('exit 4', rescue_idx)
check(heal_at && exit4_at && heal_at < exit4_at, 'self-heal branch precedes the exit-4 handoff', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
