#!/usr/bin/env ruby
# Orchestrator: discover -> build-dm -> post-dm -> build-workbook -> post
# workbook -> verify-parity -> assert-phase6-ran.rb (C2 -> C8), aborting on the
# first hard-gate failure. Mirrors migrate-domo.rb's fail_phase! discipline —
# never hand-chain these scripts manually (that's how domo's layout
# regression shipped: see project_domo_to_sigma memory, "no orchestrator").
#
#   ruby scripts/migrate-mode.rb --report <token> --connection-id <id> \
#     --folder-id <id> [--workdir DIR]
#
# Each phase shells out to its own already-committed sibling script (Tasks
# 2-8) with an argv array (never a shell string), so this file adds no new
# conversion logic of its own — it only sequences what already exists and
# stops at the first phase that fails, instead of leaving a human to notice a
# skipped gate. The one phase with no dedicated script is post-workbook: POST
# /v2/workbooks/spec directly via Sigma.request, since build-mode-workbook.rb
# (Task 7) already assembled the full spec (data page + report page +
# notebook-flow layout) and there is nothing left to build — only to post.
require 'optparse'
require 'json'
require 'fileutils'
require 'open3'
require_relative 'lib/sigma_rest'

class MigrationFailed < StandardError; end

PHASE_ORDER = %w[discover build-dm post-dm build-workbook post-workbook verify-parity assert-phase6].freeze

def fail_phase!(phase, msg)
  raise MigrationFailed, "#{phase}: #{msg}"
end

# Shells out to a sibling script in THIS script's own directory (never the
# post-chdir cwd) with an argv array — Windows-safe, no shell-string
# injection. `env:` is merged into the child's environment (mirrors
# migrate-domo.rb's BASE_ENV pattern) so a phase script that resolves its own
# output location from an ENV var (e.g. mode-discover.rb's MODE_DISCOVERY_DIR)
# writes into THIS run's workdir instead of a fixed path under the plugin's
# own skill directory. Returns [success?, exitstatus].
def run_script!(name, *args, env: {})
  out, err, status = Open3.capture3(env, 'ruby', File.expand_path(name, __dir__), *args)
  warn out unless out.empty?
  warn err unless err.empty?
  [status.success?, status.exitstatus]
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--report TOKEN')     { |v| opts[:report] = v }
    o.on('--connection-id ID') { |v| opts[:connection_id] = v }
    o.on('--folder-id ID')     { |v| opts[:folder_id] = v }
    o.on('--workdir DIR')      { |v| opts[:workdir] = v }
  end.parse!(ARGV)
  # Required-opt validation, matching build-dm.rb / build-mode-workbook.rb's
  # own convention (`abort` on a missing required flag) instead of handing the
  # first phase a nil and letting it fail with an unrelated-looking error deep
  # in a subprocess.
  { report: '--report', connection_id: '--connection-id', folder_id: '--folder-id' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end

  # Absolutized so a relative --workdir doesn't get re-passed, still relative,
  # to a child (assert-phase6-ran.rb) whose cwd is already inside it — that
  # would double the path (out/run1/out/run1/...).
  workdir = File.expand_path(opts[:workdir] || Dir.pwd)
  FileUtils.mkdir_p(workdir)

  begin
    Dir.chdir(workdir) do
      # mode-discover.rb defaults its OUT dir to a FIXED path under the
      # plugin's own skill directory (lexical __dir__, not cwd-relative)
      # unless MODE_DISCOVERY_DIR is set — without this, report-<token>.json
      # never lands at the relative path ("discovery/report-...json") the
      # rest of this pipeline assumes, and build-dm.rb's File.read raises
      # Errno::ENOENT on every real run. Mirrors migrate-domo.rb's BASE_ENV /
      # DOMO_DISCOVERY_DIR threading.
      discovery_dir = File.join(workdir, 'discovery')
      ok, code = run_script!('mode-discover.rb', '--report', opts[:report],
                              env: { 'MODE_DISCOVERY_DIR' => discovery_dir })
      fail_phase!('discover', "exit #{code}") unless ok

      report_json = "discovery/report-#{opts[:report]}.json"
      ok, code = run_script!('build-dm.rb', '--report-json', report_json,
                              '--connection-id', opts[:connection_id], '--folder-id', opts[:folder_id], '--out', 'dm-spec.json')
      fail_phase!('build-dm', "exit #{code}") unless ok

      ok, code = run_script!('post-dm.rb', '--spec', 'dm-spec.json', '--mode', 'dm-mode.json', '--out', 'dm-elements.json')
      fail_phase!('post-dm', "exit #{code}") unless ok

      ok, code = run_script!('build-mode-workbook.rb', '--report-json', report_json,
                              '--dm-elements', 'dm-elements.json', '--folder-id', opts[:folder_id], '--out', 'wb-spec.json')
      fail_phase!('build-workbook', "exit #{code}") unless ok

      wb_spec = JSON.parse(File.read('wb-spec.json'))
      # body: JSON string, not the raw Hash — Sigma.request writes `body`
      # verbatim as the HTTP request body (see lib/sigma_rest.rb's own usage
      # docstring and every sibling converter's post-and-readback.rb); a bare
      # Hash here blows up inside Net::HTTP with a NoMethodError on
      # Hash#bytesize instead of ever reaching the network.
      posted = Sigma.request(:post, '/v2/workbooks/spec', body: wb_spec.to_json)
      workbook_id = posted.fetch('workbookId') { fail_phase!('post-workbook', "no workbookId in response: #{posted.inspect}") }
      File.write('wb-ids.json', JSON.pretty_generate({ 'workbookId' => workbook_id }))

      ok, code = run_script!('verify-parity.rb', '--workbook-id', workbook_id, '--report', opts[:report],
                              '--plan', 'parity-plan.json', '--out', 'parity-final.json')
      fail_phase!('verify-parity', "exit #{code}") unless ok || code == 2 # 2 = ran, reported FAIL — still writes parity-final.json for gate 1 to see

      # gate 8 (Phase 6f visual render) is MANDATORY in assert-phase6-ran.rb —
      # a real render PNG or an explicit --skip-visual-gate REASON is the only
      # way past it (exit 10 otherwise). This converter has no browser access
      # to Mode's UI and no render step in PHASE_ORDER, so a render can never
      # be produced in v1; waive honestly, matching migrate-domo.rb's Tier B
      # '--skip-visual-gate' precedent rather than silently bypassing it.
      ok, code = run_script!('assert-phase6-ran.rb', '--workdir', workdir, '--workbook-id', workbook_id,
                              '--skip-visual-gate', 'mode-to-sigma v1 — no Mode UI render capability')
      fail_phase!('assert-phase6', "exit #{code}") unless ok

      warn "migrate-mode: workbook #{workbook_id} passed assert-phase6-ran"
    end
  rescue MigrationFailed => e
    warn "FATAL: #{e.message}"
    exit 1
  end
end
