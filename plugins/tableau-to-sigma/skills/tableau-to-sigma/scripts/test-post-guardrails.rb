#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for post-and-readback.rb's v4.2 guardrails:
#
#   P1.1 — standalone manual-path gate (exit 7): a COLD standalone invocation
#     against an orchestrator-driven workdir (migrate-state.json present, no
#     SIGMA_ORCHESTRATED_RUN marker) is refused unless an orchestrator STOP is
#     on record (manual-path-authorized.json) or --allow-manual-spec is passed
#     (recorded to offramps.jsonl as a quality waiver).
#
#   P1.2 — same-workbook PUT discipline: when the workdir already recorded a
#     workbook id (posted-workbooks.jsonl OR migrate-state.json), PUT is the
#     forced default; --force-new-workbook "<reason>" is the only way to POST a
#     new one (waiver-counted). Source-level pins for the network-adjacent parts
#     (a live POST/PUT can't be unit-tested), behavioral for the refusal path,
#     which exits BEFORE any network or env lookup.
#
# Usage: ruby scripts/test-post-guardrails.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

DIR = __dir__
PAR = File.join(DIR, 'post-and-readback.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# Fresh HOME per suite: lib/sigma_rest.rb auto-sources ~/.sigma-migration/env at
# require time, so a developer machine's real creds would leak into the child
# and the past-the-gate cases would hit the live API instead of failing at the
# (deliberately unset) SIGMA_BASE_URL fetch.
FAKE_HOME = Dir.mktmpdir
def run_par(work, spec, args = [], env_extra = {})
  env = { 'HOME' => FAKE_HOME,
          'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil, 'SIGMA_CLIENT_ID' => nil,
          'SIGMA_ORCHESTRATED_RUN' => nil }.merge(env_extra)
  out, st = Open3.capture2e(env, RbConfig.ruby, PAR, '--type', 'workbook',
                            '--spec', spec, '--out', File.join(work, 'ids.json'),
                            '--workdir', work, *args)
  [out, st.exitstatus]
end

Dir.mktmpdir do |work|
  spec = File.join(work, 'wb-spec.json')
  File.write(spec, JSON.generate('pages' => []))
  File.write(File.join(work, 'migrate-state.json'),
             JSON.generate('workbook_id' => 'wb-prior-1', 'route' => 'orchestrated', 'run_id' => 'r1'))

  # (1) cold standalone on an orchestrated workdir => exit 7 + routed message,
  #     BEFORE any env/network use (SIGMA_BASE_URL is unset here on purpose).
  out, code = run_par(work, spec)
  check(code == 7, "cold standalone run refused with exit 7 (got #{code})", fails)
  check(out.include?('entered via an orchestrator STOP, not cold'), 'refusal states the contract', fails)
  check(out.include?('migrate-tableau.rb'), 'refusal routes back to the orchestrator', fails)
  check(out.include?('--allow-manual-spec'), 'refusal names the deliberate escape', fails)

  # (2) the orchestrator's child marker admits the run (fails later on the
  #     MISSING SIGMA_BASE_URL — i.e., past the gate, at the env fetch).
  out, code = run_par(work, spec, [], 'SIGMA_ORCHESTRATED_RUN' => '1')
  check(code != 7 && !out.include?('not cold'), 'orchestrated child invocation passes the gate', fails)
  check(out.include?('SIGMA_BASE_URL'), 'orchestrated run proceeded to the env fetch (past the gate)', fails)

  # (3) an orchestrator STOP token admits a standalone run.
  File.write(File.join(work, 'manual-path-authorized.json'),
             JSON.generate('via' => 'workbook-handoff', 'exit_code' => 4))
  out, code = run_par(work, spec)
  check(code != 7 && out.include?('SIGMA_BASE_URL'), 'manual-path-authorized.json admits a standalone run', fails)
  File.delete(File.join(work, 'manual-path-authorized.json'))

  # (4) --allow-manual-spec admits AND records the waiver off-ramp.
  out, code = run_par(work, spec, ['--allow-manual-spec', 'deliberate standalone fix'])
  check(code != 7 && out.include?('quality waiver'), '--allow-manual-spec admits with a loud waiver line', fails)
  trail = File.exist?(File.join(work, 'offramps.jsonl')) ?
            File.readlines(File.join(work, 'offramps.jsonl')).map { |l| JSON.parse(l) rescue nil }.compact : []
  check(trail.any? { |r| r['kind'] == 'manual-spec' && r['reason'].to_s.start_with?('waiver:') },
        'waiver recorded to offramps.jsonl (assert-phase6-ran counts it)', fails)

  # (5) a NON-orchestrated workdir (no migrate-state.json) is never gated.
  Dir.mktmpdir do |free|
    spec2 = File.join(free, 'wb-spec.json')
    File.write(spec2, JSON.generate('pages' => []))
    out, code = run_par(free, spec2)
    check(code != 7 && out.include?('SIGMA_BASE_URL'), 'workdir without migrate-state.json is not gated', fails)
  end
end

# ---- source-level pins: PUT discipline (network paths can't be unit-driven) ----
par = File.read(PAR)
check(par.match?(/migrate-state\.json.*workbook_id/), 'migrate-state.json is a workbook-id source for the PUT default', fails)
check(par.include?('prior_ids.last || state_id'), 'PUT is the forced default whenever an id is known', fails)
check(par.include?('--force-new-workbook'), 'the only plain-POST escape is --force-new-workbook', fails)
check(par.match?(/force-new-workbook.*contradicts.*--update-id/m), 'contradictory flags abort', fails)
check(par.match?(/Offramp\.log\(.*force-new-workbook/m), 'forced new workbook records the waiver off-ramp', fails)
check(par.match?(/same-.*PUT discipline/), 'auto-PUT announces itself + the escape', fails)
# DM twin of the discipline: posted DMs are recorded and auto-PUT on re-run
# (the duplicate-DM-per-iteration field failure).
check(par.include?('posted-datamodels.jsonl'), 'posted DMs are recorded per-workdir', fails)
check(par.match?(/dataModelId.*rescue nil/), 'prior dm-ids id-map is a DM id source for the PUT default', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
