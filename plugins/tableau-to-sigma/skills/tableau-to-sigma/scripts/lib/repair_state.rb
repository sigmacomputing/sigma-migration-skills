# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'time'
require 'timeout'
require_relative 'code_rep'

module RepairState
  class Error < StandardError; end
  EVIDENCE = %w[phase6-success.json parity-final.json anchors-verdict.json numeric-parity.json
                verification-result.json migration-result.json MIGRATION_REPORT.md PUNCHLIST.md
                punchlist.json parity-actuals.json parity-plan.json ground-truth-plan.json ground-truth-actuals.json
                sigma-render.png blind-grade.json visual-similarity.json visual-similarity-final.json render-health.json
                visual-qa visual-verify wb-readback.json evidence-ledger.json].freeze

  def self.check_budget!(ledger, now: Time.now)
    unless ledger['started_at'].is_a?(String) && ledger['max_seconds'].is_a?(Numeric) &&
           ledger['max_seconds'].finite? && ledger['max_seconds'].positive?
      raise Error, 'repair elapsed-time budget is incomplete or invalid'
    end
    elapsed = now - Time.iso8601(ledger['started_at'])
    raise Error, 'repair clock moved backwards; timing is unverified' if elapsed.negative?
    raise Error, 'repair elapsed-time budget exhausted; obtain an explicit extension before another write/render' if elapsed >= ledger['max_seconds']
    ledger['max_seconds'] - elapsed
  rescue ArgumentError
    raise Error, 'repair start timestamp is invalid'
  end

  # Actionable text appended to a budget-exhausted refusal: the exact `extend`
  # command with the ledger's current values filled in (new caps = current +
  # one default allotment), plus the no-extension alternative. Extending needs
  # the USER's approval — never run it on your own.
  def self.extend_hint(ledger, workdir)
    passes = ledger['max_passes'].to_i
    secs = ledger['max_seconds'].to_i
    "\n  To continue (ONLY after the user approves more repair time):\n" \
      "    ruby scripts/fidelity-loop.rb extend --workdir #{workdir.inspect} --max-passes #{passes + 3} " \
      "--max-seconds #{secs + 1800} --reason \"<specific hypothesis for the extra time>\" --approved-by \"<user name>\"\n" \
      "  (current caps: #{passes} passes / #{secs}s; an extension must raise BOTH.)\n" \
      "  Alternative: stop repairing — record the remaining deltas as ui-only / sigma-capability, or waive " \
      "residual spec-fixable ids with `status --accept-residuals`, and proceed to the gates."
  end

  def self.with_budget(ledger)
    result = Timeout.timeout(check_budget!(ledger), Error, 'repair elapsed-time budget exhausted during operation') { yield }
    check_budget!(ledger)
    result
  end

  def self.render(ledger, command)
    windows = RUBY_PLATFORM.match?(/mswin|mingw/)
    pid = nil
    finished = false
    with_budget(ledger) do
      pid = Process.spawn(*command, **(windows ? {} : { pgroup: true }))
      _, status = Process.wait2(pid)
      finished = true
      status.success?
    end
  ensure
    if pid && !finished
      # The renderer is read-only. Kill its owned process tree on cancellation;
      # an abandoned child must not finish and leave apparently current evidence.
      if windows
        system('taskkill', '/PID', pid.to_s, '/T', '/F', out: File::NULL, err: File::NULL)
      else
        Process.kill('KILL', -pid) rescue Errno::ESRCH
      end
      Process.wait(pid) rescue Errno::ECHILD
    end
  end

  def self.checkpoint(workdir, workbook_id, spec)
    latest = spec['latestDocumentVersion'] || spec['latestVersion']
    if spec['documentVersion'] && latest && spec['documentVersion'] != latest
      raise Error, 'checkpoint is not the latest document version'
    end
    version = latest || spec['documentVersion']
    raise Error, 'live workbook version is missing; refusing an unbound repair checkpoint' if version.to_s.empty?
    root = File.join(workdir, 'repair-checkpoints')
    raise Error, 'repair checkpoint directory must not be a symlink' if File.symlink?(root)
    FileUtils.mkdir_p(root, mode: 0o700)
    directory = File.join(root, SecureRandom.hex(16))
    Dir.mkdir(directory, 0o700)
    bytes = JSON.pretty_generate(spec) + "\n"
    File.open(File.join(directory, 'workbook-spec.json'), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    files = { 'workbook-spec.json' => Digest::SHA256.hexdigest(bytes) }
    %w[wb-spec.json fidelity-ledger.json sigma-render.png blind-grade.json].each do |name|
      source = File.join(workdir, name)
      next unless File.file?(source) && !File.symlink?(source)
      FileUtils.cp(source, File.join(directory, name))
      files[name] = Digest::SHA256.file(File.join(directory, name)).hexdigest
    end
    manifest = { 'workbook_id' => workbook_id, 'document_version' => version.to_s,
                 'created_at' => Time.now.utc.iso8601, 'status' => 'checkpoint-not-a-pass', 'files' => files }
    File.open(File.join(directory, 'manifest.json'), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(manifest)) }
    directory
  end

  def self.begin_write(workdir, checkpoint, replace_checkpoint: nil)
    marker = File.join(workdir, 'repair-pending.json')
    raise Error, 'pending repair marker must not be a symlink' if File.symlink?(marker)
    exists = File.exist?(marker)
    if exists && (!replace_checkpoint || JSON.parse(File.read(marker))['checkpoint'] != replace_checkpoint)
      raise Error, 'previous repair has an incomplete outcome; reconcile it before another write'
    end
    path = exists ? File.join(workdir, ".repair-pending-#{SecureRandom.hex(16)}") : marker
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate('checkpoint' => File.basename(checkpoint), 'started_at' => Time.now.utc.iso8601))
    end
    File.rename(path, marker) if exists
  end

  def self.invalidate(workdir, checkpoint)
    archive = File.join(checkpoint, 'prior-evidence')
    raise Error, 'repair evidence archive must not be a symlink' if File.symlink?(archive)
    FileUtils.mkdir_p(archive, mode: 0o700)
    # Move the completion marker first. If any later filesystem operation fails,
    # repair-pending.json still blocks completion; the prior evidence is retained.
    (EVIDENCE + Dir.glob(File.join(workdir, 'rcf-pass-*.png')).map { |path| File.basename(path) }).each do |name|
      path = File.join(workdir, name)
      raise Error, "refusing symlink evidence: #{name}" if File.symlink?(path)
      next unless File.exist?(path)
      destination = File.join(archive, name)
      destination = File.join(archive, "#{SecureRandom.hex(8)}-#{name}") if File.exist?(destination)
      File.rename(path, destination)
    end
    File.delete(File.join(workdir, 'repair-pending.json'))
  end

  # Newest repair-checkpoints/<id>/prior-evidence/<name> copy (invalidate()
  # archives verification there), or nil. That copy describes the PRE-repair
  # workbook: recollect it, never restore it.
  def self.archived_by_repair(workdir, name)
    Dir.glob(File.join(workdir, 'repair-checkpoints', '*', 'prior-evidence', name))
       .select { |path| File.file?(path) && !File.symlink?(path) }
       .max_by { |path| File.mtime(path) }
  end

  # Re-entry after a repair recollects parity against the LIVE (patched)
  # workbook. migrate-tableau.rb pass 1 rebuilds charts from the source signals
  # and reverts RCF fixes (2026-11-03 live run).
  REENTRY_WARNING = 'do NOT re-run migrate-tableau.rb pass 1 — it rebuilds the charts from the source ' \
                    'signals and reverts the RCF fixes now live in the workbook'

  # parity-plan.json is a derived PLAN (element-id mappings + expected values),
  # not evidence of a pass — but it is bound to the live document version and to
  # element ids a patch can change, so it cannot simply survive invalidation.
  # `invalidate` archives it (operator waives/edits stay recoverable under the
  # checkpoint's prior-evidence/); this rebuilds a fresh one against the patched
  # workbook by re-running phase6-parity.rb PASS 1 with the args recoverable
  # from the prior plan (dashboard scope, extract flag). Returns
  # [ok, command_string]; on failure the caller prints the command for the user.
  # `runner` is injectable: ->(argv) { [success_bool, output_string] }.
  def self.regen_parity_plan(workdir, workbook_id, prior_plan, script:, runner: nil)
    argv = ['ruby', script, '--tableau', workdir, '--workbook-id', workbook_id.to_s, '--regen-plan']
    if prior_plan.is_a?(Hash)
      argv << '--extract-mode' if prior_plan['extract'] == true
      Array(prior_plan['dashboards_scope']).each { |d| argv.concat(['--dashboard', d.to_s]) }
    end
    command = argv.map { |a| a.match?(/\A[\w@%+=:,.\/-]+\z/) ? a : a.inspect }.join(' ')
    runner ||= lambda do |av|
      require 'open3'
      out, status = Open3.capture2e(*av)
      [status.success?, out]
    end
    ok, _out = begin
      runner.call(argv)
    rescue StandardError => e
      [false, e.message]
    end
    ok &&= File.file?(File.join(workdir, 'parity-plan.json'))
    [ok ? true : false, command]
  end

  def self.recover(workdir)
    marker_path = File.join(workdir, 'repair-pending.json')
    raise Error, 'pending repair marker must not be a symlink' if File.symlink?(marker_path)
    marker = JSON.parse(File.read(marker_path))
    id = marker['checkpoint'].to_s
    raise Error, 'invalid checkpoint reference' unless id.match?(/\A[0-9a-f]{32}\z/)
    directory = File.join(workdir, 'repair-checkpoints', id)
    paths = [File.dirname(directory), directory, File.join(directory, 'manifest.json'), File.join(directory, 'workbook-spec.json')]
    raise Error, 'repair checkpoint must not contain symlinks' if paths.any? { |path| File.symlink?(path) }
    manifest = JSON.parse(File.read(File.join(directory, 'manifest.json')))
    actual = Digest::SHA256.file(File.join(directory, 'workbook-spec.json')).hexdigest
    raise Error, 'checkpoint content changed; refusing recovery' unless manifest.dig('files', 'workbook-spec.json') == actual
    invalidate(workdir, directory)
  end

  def self.record_candidate(checkpoint, spec)
    path = File.join(checkpoint, 'candidate-spec.json')
    raw = JSON.generate(spec)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(raw) }
    File.open(File.join(checkpoint, 'candidate.sha256'), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(Digest::SHA256.hexdigest(raw)) }
  end

  # Restore only the candidate this repair produced, never a later user's edit.
  # The restored document gets a new version, so all previous verdicts stay stale.
  def self.rollback(workdir, workbook_id, checkpoint_id, request:)
    raise Error, 'invalid checkpoint reference' unless checkpoint_id.to_s.match?(/\A[0-9a-f]{32}\z/)
    directory = File.join(workdir, 'repair-checkpoints', checkpoint_id)
    paths = [File.dirname(directory), directory] + %w[manifest.json workbook-spec.json candidate-spec.json candidate.sha256].map { |name| File.join(directory, name) }
    raise Error, 'rollback checkpoint must not contain symlinks' if paths.any? { |path| File.symlink?(path) }
    manifest = JSON.parse(File.read(File.join(directory, 'manifest.json')))
    raise Error, 'checkpoint belongs to another workbook' unless manifest['workbook_id'] == workbook_id
    manifest.fetch('files').each do |name, sha|
      raise Error, 'invalid checkpoint member' unless File.basename(name) == name
      path = File.join(directory, name)
      raise Error, 'checkpoint content changed' if File.symlink?(path) || Digest::SHA256.file(path).hexdigest != sha
    end
    original = JSON.parse(File.read(File.join(directory, 'workbook-spec.json')))
    candidate_raw = File.binread(File.join(directory, 'candidate-spec.json'))
    raise Error, 'repair candidate changed or lacks a checksum; refusing rollback' unless
      File.read(File.join(directory, 'candidate.sha256')) == Digest::SHA256.hexdigest(candidate_raw)
    candidate = JSON.parse(candidate_raw)
    pending = File.join(workdir, 'repair-pending.json')
    raise Error, 'pending repair marker must not be a symlink' if File.symlink?(pending)
    if File.exist?(pending) && JSON.parse(File.read(pending))['checkpoint'] != checkpoint_id
      raise Error, 'a different repair is pending; refusing rollback'
    end
    # Checkpoints are saved live readbacks: `contents` on the current endpoint,
    # `document` on ones captured from the retired /spec endpoint. CodeRep.document
    # reads either.
    read_endpoint = Sigma::CodeRep.read_path(workbook_id)
    current = request.call(:get, read_endpoint)
    expected_version = candidate['documentVersion'] || candidate['latestVersion'] || candidate['latestDocumentVersion']
    current_version = current['documentVersion'] || current['latestVersion'] || current['latestDocumentVersion']
    unless expected_version.to_s.match?(/\A\d+\z/) && current_version.to_s == expected_version.to_s &&
           Sigma::CodeRep.document(current) == Sigma::CodeRep.document(candidate)
      raise Error, 'live workbook no longer matches this repair candidate; refusing rollback'
    end
    undo = checkpoint(workdir, workbook_id, current)
    begin_write(workdir, undo, replace_checkpoint: checkpoint_id)
    written = request.call(:put, Sigma::CodeRep.update_path(workbook_id),
                           body: JSON.generate(Sigma::CodeRep.update_body(original, document_version: expected_version.to_i)))
    restored = request.call(:get, read_endpoint)
    version = restored['documentVersion'] || restored['latestVersion'] || restored['latestDocumentVersion']
    # The contents PUT returns the workbook envelope (no `success` key).
    unless written.is_a?(Hash) && written['workbookId'] == workbook_id &&
           version.to_s.match?(/\A\d+\z/) && version.to_i == expected_version.to_i + 1 &&
           Sigma::CodeRep.document(restored) == Sigma::CodeRep.document(original)
      raise Error, 'rollback readback differs or changed concurrently; pending marker retained'
    end
    local = File.join(workdir, 'wb-spec.json')
    ledger_path = File.join(workdir, 'fidelity-ledger.json')
    raise Error, 'rollback local state must not contain symlinks' if [local, ledger_path].any? { |path| File.symlink?(path) }
    File.write(local, JSON.pretty_generate(restored) + "\n")
    if manifest.fetch('files').key?('fidelity-ledger.json')
      previous = JSON.parse(File.read(File.join(directory, 'fidelity-ledger.json')))
      ledger = JSON.parse(File.read(ledger_path))
      ledger['entries'] = previous.fetch('entries')
      (ledger['rollbacks'] ||= []) << { 'checkpoint' => checkpoint_id, 'document_version' => version, 'at' => Time.now.utc.iso8601 }
      File.write(ledger_path, JSON.pretty_generate(ledger) + "\n")
    end
    invalidate(workdir, undo)
    restored
  end
end
