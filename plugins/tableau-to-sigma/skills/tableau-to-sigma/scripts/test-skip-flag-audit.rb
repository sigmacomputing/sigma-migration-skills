#!/usr/bin/env ruby
# frozen_string_literal: true
# PR-14 skip-flag audit — EVERY --skip-* flag in this plugin must leave a
# record when honored. The field failure this enforces against: a run reported
# "GREEN, 0 waivers" because --skip-ref-check exited 0 with a puts and nothing
# else — invisible to the waiver census, the off-ramp trail, and the report.
#
# Two layers:
#   1. STATIC — every `.on('--skip-…')` definition across scripts/*.rb must be
#      classified here, and its recording mechanism must be present in the
#      source. An UNCLASSIFIED flag fails: adding a new --skip-* flag without
#      deciding how it is recorded is exactly how the next invisible escape
#      ships.
#   2. RUNTIME — each standalone gate script that honors a skip flag is run
#      with it and must append a skip-flag-waived record to offramps.jsonl.
#
# Mechanisms:
#   :budget    the flag is an assert-phase6-ran.rb gate flag — counted in the
#              waiver census stamped into parity-final.json (exit-19 budget)
#   :offramp   the honoring script writes a skip-flag-waived offramps record
#   :forwards  the orchestrator forwards the flag to a script that records it
#              (ref-check → assert-wb-refs-resolve.rb --workdir)
#   :gate      the orchestrator forwards it to assert-phase6-ran.rb (census)
#   :policy    a policy exclusion, never quality — census-visible but
#              excluded from the waiver budget by doctrine
#   :mode      NOT an escape: a discovery/build mode that does not turn off a
#              verification (--skip-reuse-scan builds a FRESH DM — more work,
#              not less; --skip-images/--skip-content scope the discovery
#              fetch and the downstream gates still demand their artifacts)
#
# Usage: ruby scripts/test-skip-flag-audit.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- layer 1: static classification ------------------------------------------
CLASSIFICATION = {
  'assert-phase6-ran.rb'         => :budget, # every gate skip flag → waiver census
  'migrate-tableau.rb'           => {
    '--skip-reuse-scan'          => :mode,
    '--skip-dashboard-read'      => :offramp,
    '--skip-doctor-gate'         => :offramp, # records kind doctor-gate-waived
    '--skip-ref-check'           => :forwards, # → assert-wb-refs-resolve.rb --workdir
    '--skip-extract-landing'     => :offramp,
    '--skip-postpublish-guide'   => :gate,     # → assert-phase6-ran census
    '--skip-flip-test'           => :gate,     # → --skip-control-flip census
    '--skip-datasource-filters'  => :forwards, # → assert-datasource-filters.rb --workdir
    '--skip-anchors-gate'        => :gate,     # W2.10: → assert-phase6-ran gate 13 (waiver budget, REASON required)
    '--skip-sql-ident-gate'      => :offramp   # W2-OM: orchestrator logs kind skip-flag-waived before waiving check-sql-idents
  },
  'assert-datasource-filters.rb' => { '--skip-datasource-filters' => :offramp }, # records kind skip-flag-waived
  'intake.rb'                    => { '--skip-bootstrap-gate' => :offramp },     # records kind skip-flag-waived
  'assert-wb-refs-resolve.rb'    => { '--skip-ref-check' => :offramp },
  'assert-dashboard-read.rb'     => { '--skip-dashboard-read' => :offramp },
  'assert-doctor-ran.rb'         => { '--skip-doctor-gate' => :offramp },
  'assert-run-state.rb'          => { '--skip-run-state' => :offramp },
  'build-charts-from-signals.rb' => { '--skip-dashboard-read' => :offramp },
  'fidelity-loop.rb'             => { '--skip-style-normalize' => :offramp },
  'post-and-readback.rb'         => { '--skip-layout-lint' => :offramp,
                                      '--skip-control-lint' => :offramp,
                                      '--skip-spec-verify' => :offramp,
                                      '--skip-style-normalize' => :offramp },
  'tableau-discover.rb'          => { '--skip-images' => :mode,
                                      '--skip-content' => :mode }
}.freeze

found = Hash.new { |h, k| h[k] = [] }
Dir[File.join(DIR, '*.rb')].sort.each do |path|
  base = File.basename(path)
  next if base.start_with?('test-')
  File.read(path).scan(/\.on\(\s*'(--skip-[a-z-]+)/) { |(flag)| found[base] << flag }
  found[base].uniq!
end

found.each do |file, flags|
  spec = CLASSIFICATION[file]
  flags.each do |flag|
    mech = spec.is_a?(Symbol) ? spec : (spec.is_a?(Hash) ? spec[flag] : nil)
    if mech.nil?
      check(false, "#{file} defines #{flag} but the audit has NO classification — decide how it is " \
                   'recorded (offramp/census) and classify it here before shipping', fails)
      next
    end
    src = File.read(File.join(DIR, file))
    case mech
    when :offramp
      recorded = src.include?('skip-flag-waived') ||
                 (file == 'migrate-tableau.rb' && flag == '--skip-doctor-gate' && src.include?('doctor-gate-waived'))
      check(recorded, "#{file} #{flag} (:offramp) — source writes a recorded escape", fails)
    when :forwards
      check(src.include?("'--workdir', WORK") && File.read(File.join(DIR, 'assert-wb-refs-resolve.rb')).include?('skip-flag-waived'),
            "#{file} #{flag} (:forwards) — forwarded with --workdir to a recording script", fails)
    when :budget
      check(src.include?('waiver_flags') && src.include?('waiver_count'),
            "#{file} #{flag} (:budget) — counted in the stamped waiver census", fails)
    when :gate
      check(src.include?(flag == '--skip-flip-test' ? '--skip-control-flip' : flag),
            "#{file} #{flag} (:gate) — forwarded to the assert-phase6-ran census", fails)
    when :policy, :mode
      check(true, "#{file} #{flag} (:#{mech}) — classified non-escape (documented)", fails)
    end
  end
end

# Classification hygiene: nothing classified that no longer exists.
CLASSIFICATION.each do |file, spec|
  next unless spec.is_a?(Hash)
  spec.each_key do |flag|
    check(found[file].include?(flag),
          "classified #{file} #{flag} still exists in the source (stale audit entry otherwise)", fails)
  end
end

# ---- layer 2: runtime — each standalone honor path leaves a record -----------
def offramp_records(wd)
  path = File.join(wd, 'offramps.jsonl')
  return [] unless File.exist?(path)
  File.readlines(path).map { |l| JSON.parse(l) rescue nil }.compact
end

RUNTIME = [
  ['assert-wb-refs-resolve.rb', ['--wb-spec', 'unused.json', '--dm-ids', 'unused.json',
                                 '--skip-ref-check', 'refs pre-validated'], '--skip-ref-check'],
  ['assert-dashboard-read.rb',  ['--skip-dashboard-read', 'no source PNG obtainable'], '--skip-dashboard-read'],
  ['assert-run-state.rb',       ['--skip-run-state', 'legacy workdir'], '--skip-run-state'],
  ['assert-doctor-ran.rb',      ['--skip-doctor-gate', 'CI environment'], '--skip-doctor-gate']
].freeze

RUNTIME.each do |script, args, flag|
  Dir.mktmpdir do |wd|
    _out, _err, st = Open3.capture3(RbConfig.ruby, File.join(DIR, script), '--workdir', wd, *args)
    rec = offramp_records(wd).find { |r| r['kind'] == 'skip-flag-waived' && r['detail'] == flag }
    check(st.success? && !rec.nil?,
          "#{script} #{flag} → exit 0 AND a skip-flag-waived record in offramps.jsonl", fails)
    check(rec && !rec['reason'].to_s.empty?, "#{script} #{flag} record carries the operator's reason", fails)
  end
end

puts
if fails.empty?
  puts 'ALL PASS — every --skip-* flag is classified and leaves a record when honored (PR-14)'
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
