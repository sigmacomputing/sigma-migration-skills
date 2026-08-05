#!/usr/bin/env ruby
# 🚧 GATE — proves the Phase 1d SOURCE dashboard-read actually happened.
#
# Reading the source Tableau dashboard PNG and enumerating its tiles/text/filter
# shelf BEFORE building is the most-skipped load-bearing step in the conversion:
# it produced no artifact anything required, so it silently got dropped and the
# workbook shipped with the right numbers but missing tiles. This gate requires
# the artifact of that read — png-read.json (schema in scripts/lib/dashboard_read.rb).
#
# It fires at two points:
#   - Phase 5 build (build-charts-from-signals.rb) calls the same validator and
#     refuses to build without it — point-of-use enforcement.
#   - This standalone script is the safety net for the hand-written-spec path,
#     and is what the orchestrator / manual runs invoke explicitly.
#
# Usage:
#   ruby scripts/assert-dashboard-read.rb --tableau /tmp/<name>
#     [--workdir DIR]                  # alias of --tableau
#     [--skip-dashboard-read REASON]   # waive — REQUIRED reason; name it in your report
#
# Exit codes:
#   0  png-read.json present + well-formed (or waived) — build may proceed
#   1  png-read.json missing or malformed — the Phase 1d read was skipped
#   2  usage error

require 'json'
require 'optparse'
require_relative 'lib/dashboard_read'

opts = {}
OptionParser.new do |p|
  p.on('--tableau DIR')       { |v| opts[:dir] = v }
  p.on('--workdir DIR', 'alias of --tableau') { |v| opts[:dir] = v }
  p.on('--skip-dashboard-read REASON',
       'waive the Phase 1d dashboard-read gate — REQUIRED reason string; name it in your migration report') do |v|
    opts[:skip] = v
  end
end.parse!

unless opts[:dir]
  warn '--workdir (or --tableau) required'
  exit 2
end

if opts[:skip]
  puts "[SKIP] dashboard-read gate WAIVED via --skip-dashboard-read (#{opts[:skip]})."
  puts '       Name this waiver in your migration report — the workbook was built WITHOUT'
  puts '       confirming its tiles/text/filters against the source dashboard PNG.'
  # PR-14: every honored --skip-* leaves a record on the off-ramp trail.
  begin
    $LOAD_PATH.unshift File.expand_path('lib', __dir__)
    require 'offramp'
    Offramp.log(opts[:dir], kind: 'skip-flag-waived', reason: opts[:skip],
                detail: '--skip-dashboard-read')
  rescue LoadError
    warn '       WARN: lib/offramp.rb not vendored — the waiver could not be recorded to offramps.jsonl.'
  end
  exit 0
end

ok, errs = DashboardRead.validate(opts[:dir])
if ok
  n = DashboardRead.tile_count(opts[:dir])
  src = (JSON.parse(File.read(DashboardRead.path(opts[:dir])))['source_png'] rescue nil) || 'the dashboard PNG'
  puts "[PASS] dashboard-read gate: #{n} tile(s) enumerated from #{src}."
  exit 0
end

warn "[FAIL] Phase 1d dashboard-read gate — #{DashboardRead.path(opts[:dir])}"
errs.each { |e| warn "       - #{e}" }
warn ''
warn '       Read the SOURCE Tableau dashboard PNG (get-view-image, solo) and write'
warn '       png-read.json enumerating EVERY tile with its Sigma `kind`, plus text_elements'
warn '       and filter_shelf. See SKILL.md Phase 1d. This is the hard gate that stops'
warn '       shipping a workbook with the right numbers but missing tiles the source rendered.'
warn '       Genuinely cannot read it? Waive with --skip-dashboard-read "<reason>".'
exit 1
