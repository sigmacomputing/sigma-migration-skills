#!/usr/bin/env ruby
# frozen_string_literal: true
# One-command orchestrator, aborting on the first gate failure:
#   discover (live) -> convert-dm -> RLS gate -> reuse-check -> post DM + readback -> build workbook
#   (layout last) -> POST workbook -> parity (oracle + verify) -> assert-phase6-ran.rb
# (convert-dm runs before reuse-check because the reuse signature is convert-dm's output.)
# Live paths (discover, oracle, Sigma writes) are UNVALIDATED against a real Lightdash instance.
#
#   Offline source (dbt project + `lightdash download` dir):
#     ruby scripts/migrate-lightdash.rb --source-dir <dir> --dashboard <slug> --explore orders \
#       --connection-id <id> --folder-id <id> [--workdir DIR] [--dialect bigquery] [--ack-rls]
#   Live source (LIGHTDASH_URL + LIGHTDASH_API_KEY):
#     ruby scripts/migrate-lightdash.rb --project <uuid> --dashboard <slug|uuid> --explore orders ...
#   --dry-run  runs only the offline steps (convert-dm, RLS plan, workbook build with a placeholder
#              data-model id) and prints the Sigma/Lightdash calls it would make; nothing is posted.
#
# RLS gate: security in the Lightdash model stops the run until --ack-rls (plan reviewed/accepted);
# an untranslatable sql_filter additionally needs --ack-rls-complex REASON. Planned-but-unapplied RLS is recorded as a
# pending escape (verdict never GREEN) until the filters are applied on the data model and the run / apply-sigma-rls.rb
# is repeated with --rls-applied "<evidence>".
# Reuse check: when an existing data model already covers the model the run STOPS (reuse-check) unless you choose
#   --reuse-dm <id>   build the workbook on that DM (nothing is POSTed to it; authored items are read back by name)
#   --new-dm [REASON] create a new DM anyway (recorded as a waiver in the verdict)
# Re-running a live migration creates a NEW data model and workbook each time unless --reuse-dm is given.

require 'optparse'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'yaml'
require 'date'
require_relative 'lib/lightdash_rest'
require_relative 'lib/lightdash_ledger'

class MigrationFailed < StandardError; end

def fail_phase!(phase, msg)
  raise MigrationFailed, "#{phase}: #{msg}"
end

def run_script!(name, *args)
  # Fixed sibling scripts run as an argv list (no shell); names are literals in this file.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, err, status = Open3.capture3(RbConfig.ruby, File.expand_path(name, __dir__), *args)
  warn out unless out.empty?
  warn err unless err.empty?
  [status.success?, status.exitstatus]
end

def pick_dashboard(dir, ref)
  files = Dir.glob(File.join(dir, '*.{yml,yaml}')).sort
  fail_phase!('discover', "no dashboard YAML under #{dir}") if files.empty?
  return files.first if ref.to_s.empty? && files.length == 1
  fail_phase!('discover', "--dashboard is required (found #{files.length} dashboards in #{dir})") if ref.to_s.empty?
  docs = files.map { |f| [f, YAML.safe_load(File.read(f, encoding: 'UTF-8'), permitted_classes: [Date, Time], aliases: true) || {}] }
  hit = docs.find { |f, _| File.basename(f).sub(/\.ya?ml\z/, '') == ref } ||
        docs.find { |_, d| d['slug'].to_s == ref } ||
        docs.find { |_, d| d['uuid'].to_s == ref || d['dashboardUuid'].to_s == ref } ||
        docs.find { |_, d| d['name'].to_s.casecmp?(ref.to_s) }
  hit ? hit[0] : fail_phase!('discover', "dashboard #{ref.inspect} not found in #{dir}")
end

# The reference to pick the dashboard by. Live discovery matched the user's slug|uuid|name against Lightdash and
# wrote the dashboard under its resolved slug (discovery/manifest.json), so use that: the raw ref (a uuid or a
# display name) does not match the file basename.
def resolved_dashboard_ref(src, ref, live)
  return ref unless live
  m = begin
    JSON.parse(File.read(File.join(src, 'manifest.json'), encoding: 'UTF-8'))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end
  m['dashboard'].to_s.empty? ? ref : m['dashboard']
end

# Data-model reuse check. Returns the dm-mode.json hash ({"mode":"create"} or {"mode":"reuse","dataModelId":...}).
# find-or-pick-dm.rb exits 0 with a recommendation and 1 with none, always writing dm-match.json first; any other
# outcome (no fresh file) is a failed scan and stops the run. A recommended/auto-picked match STOPS the run: the
# operator chooses --reuse-dm <id> or --new-dm (never a silent POST of a duplicate DM, never a silent reuse).
def reuse_check!(opts)
  # A previous run's dm-mode.json ({"mode":"create"}) must not survive a match-stop: a standalone
  # post-lightdash-dm.rb would honor it and POST the duplicate this gate blocks. The caller rewrites it on success.
  FileUtils.rm_f('dm-mode.json')
  if opts[:reuse_dm]
    warn "reuse-check: --reuse-dm #{opts[:reuse_dm]}: nothing is written to that data model; its columns/metrics/security are inherited."
    LightdashLedger.replace_offramps(Dir.pwd, 'lightdash-new-dm', [])
    return { 'mode' => 'reuse', 'dataModelId' => opts[:reuse_dm], 'chosen_by' => '--reuse-dm' }
  end
  FileUtils.rm_f('dm-match.json') # a stale answer must never stand in for a failed scan
  ok, code = run_script!('find-or-pick-dm.rb', '--workbook-signature', 'lightdash-signature.json', '--auto-pick', '--refresh', '--out', 'dm-match.json')
  match = File.file?('dm-match.json') ? (JSON.parse(File.read('dm-match.json', encoding: 'UTF-8')) rescue nil) : nil
  fail_phase!('reuse-check', "find-or-pick-dm.rb exit #{code} without a result file (scan failed; check Sigma credentials)") unless match.is_a?(Hash) && [0, 1].include?(code)
  rec = match['recommended_dm_id'].to_s
  if rec.empty?
    warn "reuse-check: no reusable data model (#{match['rationale']}); creating a new one"
    LightdashLedger.replace_offramps(Dir.pwd, 'lightdash-new-dm', [])
    return { 'mode' => 'create' }
  end
  name = Array(match['candidates']).find { |c| c['dm_id'] == rec }&.fetch('dm_name', nil)
  if opts[:new_dm]
    reason = opts[:new_dm].is_a?(String) && !opts[:new_dm].empty? ? opts[:new_dm] : 'operator chose a new data model over the reuse candidate'
    LightdashLedger.replace_offramps(Dir.pwd, 'lightdash-new-dm',
                                     [{ 'kind' => 'skip-flag-waived', 'origin' => 'lightdash-new-dm',
                                        'detail' => "--new-dm: data-model reuse declined (candidate #{rec}#{name ? " #{name.inspect}" : ''})",
                                        'reason' => reason }])
    return { 'mode' => 'create', 'declined_reuse' => rec }
  end
  fail_phase!('reuse-check', "data model #{rec}#{name ? " (#{name.inspect})" : ''} already covers this model (#{match['rationale']}). " \
                             "Re-run with --reuse-dm #{rec} to build the workbook on it (nothing is posted to the data model), or " \
                             '--new-dm [REASON] to create a new one anyway (recorded as a waiver in the verdict).')
end

PLANNED = [
  ['reuse-check', 'GET /v2/dataModels (+ /spec) via find-or-pick-dm.rb --auto-pick --refresh; a match stops the run (--reuse-dm ID | --new-dm)'],
  ['post-dm', 'POST /v2/dataModels/spec (none with --reuse-dm), then GET /v2/dataModels/{id}/spec readback gate'],
  ['post-workbook', 'POST /v2/workbooks (dryRun:true validation first, then the real CodeRep create), then GET /v2/workbooks/{id}?includeContents=true'],
  ['parity', 'Lightdash POST .../explores/{explore}/runQuery + compileQuery per chart (live), or Sigma element export checks (offline)'],
  ['assert-phase6', 'scripts/assert-phase6-ran.rb --workdir <workdir> (reads parity-final.json, wb-readback.json, ledger)']
].freeze

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--source-dir DIR')        { |v| opts[:source_dir] = v }
    o.on('--explores-dir DIR')      { |v| opts[:explores_dir] = v }
    o.on('--project UUID')          { |v| opts[:project] = v }
    o.on('--dashboard REF')         { |v| opts[:dashboard] = v }
    o.on('--explore NAME')          { |v| opts[:explore] = v }
    o.on('--dialect D')             { |v| opts[:dialect] = v }
    o.on('--default-database D')    { |v| opts[:default_database] = v }
    o.on('--default-schema S')      { |v| opts[:default_schema] = v }
    o.on('--connection-id ID')      { |v| opts[:connection_id] = v }
    o.on('--folder-id ID')          { |v| opts[:folder_id] = v }
    o.on('--workdir DIR')           { |v| opts[:workdir] = v }
    o.on('--ack-rls')               { opts[:ack_rls] = true }
    o.on('--ack-rls-complex REASON') { |v| opts[:ack_complex] = v }
    o.on('--rls-applied NOTE')      { |v| opts[:rls_applied] = v }
    o.on('--reuse-dm ID')           { |v| opts[:reuse_dm] = v }
    o.on('--new-dm [REASON]')       { |v| opts[:new_dm] = v || true }
    o.on('--dry-run')               { opts[:dry_run] = true }
  end.parse!(ARGV)

  abort 'missing --explore' if opts[:explore].to_s.empty?
  live = opts[:source_dir].to_s.empty? && opts[:explores_dir].to_s.empty?
  abort 'pass --source-dir <dir> / --explores-dir <dir> (offline) or --project <uuid> (live)' if live && opts[:project].to_s.empty?
  abort '--dry-run is offline: pass --source-dir or --explores-dir' if live && opts[:dry_run]
  unless opts[:dry_run]
    abort 'missing --connection-id' if opts[:connection_id].to_s.empty?
    abort 'missing --folder-id' if opts[:folder_id].to_s.empty?
    if LightdashRest::Client.configured? && opts[:project].to_s.empty?
      abort 'LIGHTDASH_URL/LIGHTDASH_API_KEY are set but --project is missing: pass --project <uuid> so parity runs against ' \
            'Lightdash (refusing to silently downgrade to warehouse-only verification; unset the variables to accept that)'
    end
  end

  workdir = File.expand_path(opts[:workdir] || Dir.pwd)
  FileUtils.mkdir_p(workdir)
  src = opts[:source_dir] && File.expand_path(opts[:source_dir])
  explores = opts[:explores_dir] && File.expand_path(opts[:explores_dir])
  src ||= File.dirname(explores) if explores # discovery layout: <dir>/explores + <dir>/lightdash

  begin
    Dir.chdir(workdir) do
      if live
        disc = File.join(workdir, 'discovery')
        ok, code = run_script!('lightdash-discover.rb', '--project', opts[:project], '--dashboard', opts[:dashboard].to_s, '--out-dir', disc)
        fail_phase!('discover', "exit #{code}") unless ok
        src = disc
        explores = File.join(disc, 'explores')
      end
      lightdash_dir = File.join(src, 'lightdash')
      dash_path = pick_dashboard(File.join(lightdash_dir, 'dashboards'), resolved_dashboard_ref(src, opts[:dashboard], live))
      charts_dir = File.join(lightdash_dir, 'charts')

      conv = ['--explore', opts[:explore], '--connection-id', opts[:connection_id] || '<CONNECTION_ID>', '--out', 'dm.json',
              '--signature-out', 'lightdash-signature.json', '--field-map-out', 'field-map.json']
      conv += (opts[:source_dir].to_s.empty? ? ['--explores-dir', explores] : ['--source-dir', src])
      conv += ['--folder-id', opts[:folder_id]] if opts[:folder_id]
      { '--dialect' => opts[:dialect], '--default-database' => opts[:default_database], '--default-schema' => opts[:default_schema] }
        .each { |f, v| conv += [f, v] unless v.to_s.empty? }
      ok, code = run_script!('convert-dm.rb', *conv)
      fail_phase!('convert-dm', "exit #{code}") unless ok

      rls = ['--envelope', 'dm.json', '--out', 'rls-plan.json']
      rls += ['--no-gate'] if opts[:dry_run]
      rls += ['--ack'] if opts[:ack_rls]
      rls += ['--ack-complex', opts[:ack_complex]] if opts[:ack_complex]
      ok, code = run_script!('detect-rls.rb', *rls)
      fail_phase!('rls-gate', "exit #{code} (review rls-plan.json; re-run with --ack-rls once applied/accepted)") unless ok
      apply = ['--plan', 'rls-plan.json', '--out', 'rls-steps.json']
      apply += ['--applied', opts[:rls_applied]] if opts[:rls_applied]
      ok, code = run_script!('apply-sigma-rls.rb', *apply)
      fail_phase!('rls-gate', "apply-sigma-rls exit #{code}") unless ok || opts[:dry_run]

      dm_id = '<DM_ID>'
      unless opts[:dry_run]
        File.write('dm-mode.json', JSON.pretty_generate(reuse_check!(opts)) + "\n")
        ok, code = run_script!('post-lightdash-dm.rb', '--spec', 'dm.json', '--mode', 'dm-mode.json', '--out', 'dm-elements.json')
        fail_phase!('post-dm', "exit #{code} (readback gate)") unless ok
        dm_id = JSON.parse(File.read('dm-elements.json', encoding: 'UTF-8')).values.map { |e| e['dataModelId'] }.compact.first
        fail_phase!('post-dm', 'no dataModelId in dm-elements.json') unless dm_id
      end

      build = ['--dashboard', dash_path, '--charts-dir', charts_dir, '--dm-envelope', 'dm.json', '--field-map', 'field-map.json',
               '--dm-id', dm_id, '--out', 'wb.json', '--workbook-map-out', 'workbook-map.json']
      build += ['--dm-lookup', 'dm-elements.json'] unless opts[:dry_run]
      build += ['--folder-id', opts[:folder_id]] if opts[:folder_id]
      ok, code = run_script!('build-lightdash-workbook.rb', *build)
      fail_phase!('build-workbook', "exit #{code}") unless ok

      if opts[:dry_run]
        run_script!('post-lightdash-workbook.rb', '--spec', 'wb.json', '--out', 'wb-ids.json', '--dry-run')
        PLANNED.each { |phase, call| warn "DRY-RUN (not performed) #{phase}: #{call}" }
        File.write('migrate-plan.json', JSON.pretty_generate(PLANNED.map { |p, c| { 'phase' => p, 'call' => c } }) + "\n")
        warn "migrate-lightdash --dry-run: wrote dm.json, field-map.json, wb.json, workbook-map.json, rls-plan.json in #{workdir}"
        next
      end

      ok, code = run_script!('post-lightdash-workbook.rb', '--spec', 'wb.json', '--out', 'wb-ids.json')
      fail_phase!('post-workbook', "exit #{code}") unless ok
      workbook_id = JSON.parse(File.read('wb-ids.json', encoding: 'UTF-8')).fetch('workbookId')

      verify = ['--workbook-id', workbook_id, '--workbook-map', 'workbook-map.json', '--expected-dir', 'expected',
               '--out', 'parity-report.json', '--final-out', 'parity-final.json', '--workbook-spec', 'wb-spec.json']
      if LightdashRest::Client.configured? && !opts[:project].to_s.empty?
        ok, code = run_script!('lightdash-query-oracle.rb', '--project', opts[:project], '--workbook-map', 'workbook-map.json',
                               '--charts-dir', charts_dir, '--field-map', 'field-map.json', '--out-dir', 'expected')
        fail_phase!('oracle', "exit #{code}") unless ok
      else
        warn '*** PARITY WARNING: no Lightdash credentials -- parity is verified against the WAREHOUSE ONLY (elements evaluate and ' \
             'return data); values are NOT compared with Lightdash. ***'
        verify << '--warehouse-only'
      end
      ok, code = run_script!('verify-lightdash-parity.rb', *verify)
      fail_phase!('verify-parity', "exit #{code}") unless ok

      ok, code = run_script!('assert-phase6-ran.rb', '--workdir', workdir, '--workbook-id', workbook_id,
                             '--skip-visual-gate', 'lightdash-to-sigma v1 - no Lightdash UI render capability')
      fail_phase!('assert-phase6', "exit #{code}") unless ok
      warn "migrate-lightdash: workbook #{workbook_id} passed assert-phase6-ran"
    end
  rescue MigrationFailed => e
    warn "FATAL: #{e.message}"
    exit 1
  end
end
