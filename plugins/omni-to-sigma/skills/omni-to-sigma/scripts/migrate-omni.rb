#!/usr/bin/env ruby
# frozen_string_literal: true
# Orchestrator: discover -> detect-rls -> convert-dm -> find-or-pick-dm ->
# post-omni-dm -> build-omni-workbook -> post-workbook -> verify-omni-parity ->
# assert-phase6-ran.rb, aborting on the first hard-gate failure.
#
#   ruby scripts/migrate-omni.rb --document <doc-id> --connection-id <id> \
#     --folder-id <id> [--topic <topic>] [--model-dir <dir>] [--export <path>] [--workdir DIR]
#
# Reuse check (C3): every run rescans Sigma for an existing data model covering this model. When one is found the
# run STOPS (reuse-check) unless you choose
#   --reuse-dm <id>   build the workbook on that DM (nothing is POSTed or PUT to it; it is read back by name)
#   --new-dm [REASON] create a new DM anyway (recorded as a waiver in the verdict)
# A previous run's dm-mode.json / dm-match.json is never reused as the answer.

require 'optparse'
require 'json'
require 'fileutils'
require 'open3'
require_relative 'lib/sigma_rest'
require_relative 'lib/code_rep'

class MigrationFailed < StandardError; end

PHASE_ORDER = %w[
  discover
  detect-rls
  convert-dm
  reuse-check
  post-dm
  build-workbook
  post-workbook
  verify-parity
  assert-phase6
].freeze

def fail_phase!(phase, msg)
  raise MigrationFailed, "#{phase}: #{msg}"
end

OFFRAMP_ORIGIN = 'omni-new-dm'

# Replace this origin's offramps.jsonl records with `records` (an empty list just clears them), so a re-run never
# accumulates stale waivers and a later --reuse-dm / no-match run clears an earlier --new-dm waiver.
def replace_offramps(workdir, origin, records)
  path = File.join(workdir, 'offramps.jsonl')
  keep = if File.file?(path)
           File.readlines(path, encoding: 'UTF-8').reject do |l|
             (JSON.parse(l) rescue {})['origin'] == origin
           end
         else
           []
         end
  return if keep.empty? && records.empty? && !File.file?(path)
  File.write(path, keep.map { |l| l.end_with?("\n") ? l : "#{l}\n" }.join + records.map { |r| "#{JSON.generate(r)}\n" }.join)
end

# Data-model reuse check. Returns the dm-mode.json hash ({"mode":"create"} or {"mode":"reuse","dataModelId":...}).
# find-or-pick-dm.rb exits 0 with a recommendation and 1 with none, always writing dm-match.json first; any other
# outcome (no fresh file) is a failed scan and stops the run. A recommended/auto-picked match STOPS the run: the
# operator chooses --reuse-dm <id> or --new-dm (never a silent POST of a duplicate DM, never a silent reuse).
def reuse_check!(opts)
  FileUtils.rm_f('dm-mode.json') # a stale mode must never authorize a post after this check stops or fails
  if opts[:reuse_dm]
    warn "reuse-check: --reuse-dm #{opts[:reuse_dm]}: nothing is written to that data model; it is read back by name."
    replace_offramps(Dir.pwd, OFFRAMP_ORIGIN, [])
    return { 'mode' => 'reuse', 'dataModelId' => opts[:reuse_dm], 'chosen_by' => '--reuse-dm' }
  end
  FileUtils.rm_f('dm-match.json') # a stale answer must never stand in for a failed scan
  _ok, code = run_script!('find-or-pick-dm.rb', '--workbook-signature', 'omni-signature.json', '--auto-pick', '--refresh',
                          '--out', 'dm-match.json')
  match = File.file?('dm-match.json') ? (JSON.parse(File.read('dm-match.json', encoding: 'UTF-8')) rescue nil) : nil
  unless match.is_a?(Hash) && [0, 1].include?(code)
    fail_phase!('reuse-check', "find-or-pick-dm.rb exit #{code} without a result file (scan failed; check Sigma credentials)")
  end
  rec = match['recommended_dm_id'].to_s
  if rec.empty?
    warn "reuse-check: no reusable data model (#{match['rationale']}); creating a new one"
    replace_offramps(Dir.pwd, OFFRAMP_ORIGIN, [])
    return { 'mode' => 'create' }
  end
  name = Array(match['candidates']).find { |c| c['dm_id'] == rec }&.fetch('dm_name', nil)
  if opts[:new_dm]
    reason = opts[:new_dm].is_a?(String) && !opts[:new_dm].empty? ? opts[:new_dm] : 'operator chose a new data model over the reuse candidate'
    replace_offramps(Dir.pwd, OFFRAMP_ORIGIN,
                     [{ 'kind' => 'skip-flag-waived', 'origin' => OFFRAMP_ORIGIN,
                        'detail' => "--new-dm: data-model reuse declined (candidate #{rec}#{name ? " #{name.inspect}" : ''})",
                        'reason' => reason }])
    return { 'mode' => 'create', 'declined_reuse' => rec }
  end
  fail_phase!('reuse-check', "data model #{rec}#{name ? " (#{name.inspect})" : ''} already covers this model (#{match['rationale']}). " \
                             "Re-run with --reuse-dm #{rec} to build the workbook on it (nothing is posted to the data model), or " \
                             '--new-dm [REASON] to create a new one anyway (recorded as a waiver in the verdict).')
end

def run_script!(name, *args, env: {})
  # Runs a fixed phase script from this directory as an argv list (no shell);
  # the script name comes from the PHASES table, not from user input.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, err, status = Open3.capture3(env, 'ruby', File.expand_path(name, __dir__), *args)
  warn out unless out.empty?
  warn err unless err.empty?
  [status.success?, status.exitstatus]
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--document ID')      { |v| opts[:document] = v }
    o.on('--model-id ID')      { |v| opts[:model_id] = v }
    o.on('--topic NAME')       { |v| opts[:topic] = v }
    o.on('--model-dir DIR')    { |v| opts[:model_dir] = v }
    o.on('--export PATH')      { |v| opts[:export] = v }
    o.on('--connection-id ID') { |v| opts[:connection_id] = v }
    o.on('--folder-id ID')     { |v| opts[:folder_id] = v }
    o.on('--workdir DIR')      { |v| opts[:workdir] = v }
    o.on('--reuse-dm ID')      { |v| opts[:reuse_dm] = v }
    o.on('--new-dm [REASON]')  { |v| opts[:new_dm] = v || true }
  end.parse!(ARGV)

  abort 'pass at most one of --reuse-dm and --new-dm' if opts[:reuse_dm] && opts[:new_dm]

  { connection_id: '--connection-id', folder_id: '--folder-id' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end
  if opts[:document].to_s.empty? && (opts[:model_dir].to_s.empty? || opts[:export].to_s.empty?)
    abort 'pass --document <id> OR both --model-dir <dir> and --export <path>'
  end

  workdir = File.expand_path(opts[:workdir] || Dir.pwd)
  FileUtils.mkdir_p(workdir)

  begin
    Dir.chdir(workdir) do
      discovery_dir = File.join(workdir, 'discovery')
      model_dir = opts[:model_dir] && File.expand_path(opts[:model_dir])
      export_path = opts[:export] && File.expand_path(opts[:export])
      topic = opts[:topic]

      if !opts[:document].to_s.empty? && (model_dir.nil? || export_path.nil?)
        disc_args = ['--document', opts[:document], '--out-dir', discovery_dir]
        disc_args += ['--model-id', opts[:model_id]] if opts[:model_id]
        ok, code = run_script!('omni-discover.rb', *disc_args, env: { 'OMNI_DISCOVERY_DIR' => discovery_dir })
        fail_phase!('discover', "exit #{code}") unless ok
        manifest = JSON.parse(File.read(File.join(discovery_dir, 'manifest.json'), encoding: 'UTF-8'))
        model_dir ||= manifest['model_dir']
        export_path ||= manifest['export_path']
        topic ||= manifest['topic']
      end

      fail_phase!('discover', 'no topic determined; pass --topic') if topic.to_s.empty?

      ok, code = run_script!('detect-rls.rb', '--model-dir', model_dir, '--out', 'rls.json')
      fail_phase!('detect-rls', "exit #{code}") unless ok

      ok, code = run_script!('apply-sigma-rls.rb', '--detect', 'rls.json', '--out', 'rls-plan.json')
      fail_phase!('detect-rls', "exit #{code}") unless ok

      ok, code = run_script!('convert-dm.rb',
                              '--model-dir', model_dir,
                              '--topic', topic,
                              '--export', export_path,
                              '--connection-id', opts[:connection_id],
                              '--folder-id', opts[:folder_id],
                              '--out', 'dm-envelope.json',
                              '--signature-out', 'omni-signature.json')
      fail_phase!('convert-dm', "exit #{code}") unless ok

      dm_env = JSON.parse(File.read('dm-envelope.json', encoding: 'UTF-8'))
      File.write('dm-spec.json', JSON.pretty_generate(dm_env['sigmaDataModel']) + "\n")

      File.write('dm-mode.json', JSON.pretty_generate(reuse_check!(opts)) + "\n")

      ok, code = run_script!('post-omni-dm.rb', '--spec', 'dm-spec.json', '--mode', 'dm-mode.json', '--out', 'dm-elements.json')
      fail_phase!('post-dm', "exit #{code} (readback gate)") unless ok

      ok, code = run_script!('build-omni-workbook.rb',
                              '--export', export_path,
                              '--model-dir', model_dir,
                              '--topic', topic,
                              '--dm-elements', 'dm-elements.json',
                              '--folder-id', opts[:folder_id],
                              '--out', 'wb-envelope.json')
      fail_phase!('build-workbook', "exit #{code}") unless ok

      wb_env = JSON.parse(File.read('wb-envelope.json', encoding: 'UTF-8'))
      wb_spec = wb_env['workbook']
      File.write('wb-spec.json', JSON.pretty_generate(wb_spec) + "\n")

      posted = Sigma.request(:post, Sigma::CodeRep.create_path, body: Sigma::CodeRep.create_body(wb_spec).to_json)
      workbook_id = posted.fetch('workbookId') { fail_phase!('post-workbook', "no workbookId in response: #{posted.inspect}") }
      File.write('wb-ids.json', JSON.pretty_generate({ 'workbookId' => workbook_id }) + "\n")

      ok, code = run_script!('verify-omni-parity.rb',
                              '--workbook-id', workbook_id,
                              '--plan', 'parity-plan.json',
                              '--out', 'parity-final.json')
      fail_phase!('verify-parity', "exit #{code}") unless ok || code == 2

      ok, code = run_script!('assert-phase6-ran.rb',
                              '--workdir', workdir,
                              '--workbook-id', workbook_id,
                              '--skip-visual-gate', 'omni-to-sigma v1 — no Omni UI render capability')
      fail_phase!('assert-phase6', "exit #{code}") unless ok

      warn "migrate-omni: workbook #{workbook_id} passed assert-phase6-ran"
    end
  rescue MigrationFailed => e
    warn "FATAL: #{e.message}"
    exit 1
  end
end
