# frozen_string_literal: true

# finalize_preflight.rb — ONE preflight of every prerequisite artifact the
# final gate (assert-phase6-ran.rb) reads, computed at the START of
# migrate-tableau.rb --finalize, BEFORE any gate that can count toward the
# loop-log.jsonl attempt cap (Offramp ATTEMPT_CAP).
#
# WHY: --finalize used to run only phase6 finalize + the gate battery. The
# anchors verdict (gate 13), join probe (16), LOD audit (17) and the
# ground-truth derive/run/verify trio (18) were separate manual commands, so an
# agent re-ran --finalize to clear the gates ONE AT A TIME — each NOT-GREEN
# re-run appended a loop-log attempt and tripped the cap on a run that was
# converging. The preflight runs every step that can run non-interactively
# with what is in the workdir, and for the rest prints ONE ordered list of
# exactly what is missing (exact command each) and stops with a distinct exit
# status WITHOUT touching loop-log.jsonl.
#
# Pure: file inspection + an injected runner (lambda(cmd) -> [ok, output]) so
# the builder is testable offline. Nothing here appends to loop-log.jsonl.

require 'json'
require 'digest'
require_relative 'repair_state'

module FinalizePreflight
  # Distinct from every cap-counting terminal: a preflight stop never records
  # a loop-log attempt. (Orchestrator namespace; see refs/gates.md.)
  EXIT_PREFLIGHT_STOP = 29

  LOD_RE = /\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b/i.freeze

  module_function

  def read_json(path)
    JSON.parse(File.read(path, encoding: 'UTF-8'))
  rescue StandardError
    nil
  end

  # Connection id: explicit flag, else connection.json, else the first
  # connectionId in dm-spec.json. nil when unknown (live probes then become
  # manual items with a <connection-id> placeholder).
  def connection_id(workdir, explicit = nil)
    return explicit.to_s unless explicit.to_s.empty?
    cj = read_json(File.join(workdir, 'connection.json'))
    return cj['connection_id'].to_s if cj.is_a?(Hash) && !cj['connection_id'].to_s.empty?
    dm = File.join(workdir, 'dm-spec.json')
    if File.file?(dm)
      m = File.read(dm, encoding: 'UTF-8').match(/"connectionId"\s*:\s*"([^"]+)"/)
      return m[1] if m
    end
    nil
  rescue StandardError
    nil
  end

  def entries_of(doc)
    list = doc.is_a?(Hash) ? doc['entries'] : doc
    list.is_a?(Array) ? list.select { |e| e.is_a?(Hash) } : nil
  end

  # Each check returns nil (satisfied / not applicable) or an item:
  #   { id:, auto: bool, cmd: [..] (for auto or the manual hint), why: String }
  # `auto` items are runnable non-interactively right now.

  def check_parity_plan(wd, wb_id = nil)
    return nil if File.file?(File.join(wd, 'parity-plan.json'))
    cmd = ['ruby', 'scripts/phase6-parity.rb', '--tableau', wd]
    cmd += ['--workbook-id', wb_id.to_s] unless wb_id.to_s.empty?
    archived = RepairState.archived_by_repair(wd, 'parity-plan.json')
    why = if archived
            "parity-plan.json was archived by an RCF repair (#{archived}) and not regenerated — rebuild it " \
              "against the patched workbook with phase6-parity pass 1 (it also collects actuals); #{RepairState::REENTRY_WARNING}"
          else
            'parity-plan.json missing — pass 1 never built the parity plan (run phase6-parity pass 1, collect actuals)'
          end
    { id: 'parity-plan', auto: false, cmd: cmd, why: why }
  end

  # Parity actuals collected BEFORE the workbook last changed (an RCF patch /
  # apply-patch rewrote wb-spec.json) or before the parity plan was rebuilt
  # compare the OLD workbook: the finalize fails parity and burns an attempt
  # (Stress 4: "first finalize attempt used stale actuals"). Re-collect first.
  #
  # A MISSING actuals file is this check only when an RCF repair archived it
  # (repair-checkpoints/<id>/prior-evidence/): re-collect against the patched
  # workbook rather than send the operator back to a pass 1 that reverts the fix.
  def check_actuals(wd, actuals, wb_id)
    return nil if actuals.to_s.empty?
    archived = File.file?(actuals.to_s) ? nil : RepairState.archived_by_repair(wd, File.basename(actuals.to_s))
    return nil unless File.file?(actuals.to_s) || archived
    unless archived
      newer = %w[wb-spec.json parity-plan.json].map { |f| File.join(wd, f) }
                                                .select { |p| File.file?(p) && File.mtime(p) > File.mtime(actuals.to_s) }
      return nil if newer.empty?
    end
    spec = File.join(wd, 'wb-spec.json')
    spec = File.join(wd, 'wb-readback.json') unless File.file?(spec)
    cmd = ['ruby', 'scripts/collect-parity-actuals.rb', '--plan', File.join(wd, 'parity-plan.json'),
           '--workbook-id', wb_id.to_s, '--workbook-spec', spec, '--out', actuals.to_s]
    why = if archived
            "#{File.basename(actuals.to_s)} was archived by an RCF repair (#{archived}) — it describes the " \
              'pre-repair workbook; re-collect it against the patched workbook (charts the REST export cannot ' \
              "serve still need their MCP/warehouse values re-supplied); #{RepairState::REENTRY_WARNING}"
          else
            "#{File.basename(actuals.to_s)} is older than #{newer.map { |p| File.basename(p) }.join(' and ')} — " \
              'the actuals describe the workbook before its last change; re-collect them (charts the REST export ' \
              'cannot serve still need their MCP/warehouse values re-supplied)'
          end
    { id: 'parity-actuals', auto: !wb_id.to_s.empty? && File.file?(File.join(wd, 'parity-plan.json')), cmd: cmd,
      why: why }
  end

  # Tiles with a view CSV but no valued anchor (gate 18), or — before the
  # anchors lock — over-precise view-csv anchors: seed / normalize them
  # (lib/anchor_seed.rb). Runs BEFORE the anchors verdict so verify-anchors
  # re-runs over the complete set.
  def check_anchor_seed(wd)
    return nil unless File.file?(File.join(wd, 'source-anchors.json')) && File.file?(File.join(wd, 'dashboard-layout.json'))
    require_relative 'anchor_seed'
    plan = AnchorSeed.apply!(wd, write: false)
    return nil if plan[:seeded].empty? && plan[:normalized].empty?
    { id: 'anchors-seed', auto: true, cmd: ['ruby', 'scripts/seed-source-anchors.rb', '--workdir', wd],
      why: "#{plan[:seeded].size} tile(s) have a view CSV but no valued anchor (gate 18)" \
           "#{plan[:normalized].any? ? "; #{plan[:normalized].size} anchor(s) above the source's display precision" : ''}" }
  end

  def check_anchors(wd, wb_id)
    src = File.join(wd, 'source-anchors.json')
    unless File.file?(src)
      return { id: 'anchors-transcribe', auto: false,
               cmd: ['(agent step)', 'read the source dashboard PNG and write', src, '— schema in refs/source-anchors.md'],
               why: 'source-anchors.json missing — gate 13 needs the printed values transcribed from the source image' }
    end
    anchors = read_json(src)
    n = anchors.is_a?(Hash) ? Array(anchors['anchors']).length : 0
    verdict = read_json(File.join(wd, 'anchors-verdict.json'))
    fresh = verdict.is_a?(Hash) && [true, false].include?(verdict['pass']) && verdict['checked'].to_i == n
    # verify-anchors (shared) stamps no input digest: a verdict OLDER than the
    # anchors it judged or the live spec it exported is stale (anchors added /
    # normalized, apply-patch or a pass-1 rebuild changed the workbook).
    vpath = File.join(wd, 'anchors-verdict.json')
    newer = [src, File.join(wd, 'wb-spec.json')].select { |p| File.file?(p) && File.file?(vpath) && File.mtime(p) > File.mtime(vpath) }
    fresh &&= newer.empty?
    return nil if fresh
    cmd = ['ruby', 'scripts/verify-anchors.rb', '--workdir', wd]
    cmd += ['--workbook-id', wb_id.to_s] unless wb_id.to_s.empty?
    { id: 'anchors-verdict', auto: true, cmd: cmd,
      why: 'anchors-verdict.json missing, stale (anchor count changed) or not passing — gate 13' }
  end

  def check_join_plan(wd, conn)
    path = File.join(wd, 'join-plan.json')
    return nil unless File.file?(path)
    entries = entries_of(read_json(path))
    return nil if entries.nil? # malformed: the gate reports it
    resolved = lambda do |e|
      e['resolution'].is_a?(Hash) && %w[preaggregated waived].include?(e['resolution']['how'].to_s)
    end
    unprobed = entries.select { |e| %w[unprobed error].include?(e['status'].to_s) || e['status'].to_s.empty? }
    if unprobed.any?
      cmd = ['ruby', 'scripts/probe-join-keys.rb', '--workdir', wd, '--connection-id', conn || '<connection-id>']
      return { id: 'join-probe', auto: !conn.nil?, cmd: cmd,
               why: "#{unprobed.length} join-plan.json entr#{unprobed.length == 1 ? 'y' : 'ies'} unprobed — gate 16" }
    end
    blocking = entries.each_with_index.select { |e, _| e['status'].to_s == 'non-unique' && !resolved.call(e) }
    return nil if blocking.empty?
    i = blocking.first[1]
    { id: 'join-resolve', auto: false,
      cmd: ['ruby', 'scripts/probe-join-keys.rb', '--workdir', wd, '--resolve', i.to_s, '--how', '<preaggregated|waived>', '--reason', '"..."'],
      why: "#{blocking.length} non-unique join-plan entr#{blocking.length == 1 ? 'y' : 'ies'} need a decision (pre-aggregate the target or waive with evidence) — gate 16" }
  end

  def check_lod(wd)
    path = File.join(wd, 'lod-audit.json')
    if File.file?(path)
      entries = entries_of(read_json(path))
      return nil if entries.nil?
      unresolved = entries.each_with_index.select do |e, _|
        %w[suspect-alias silently-dropped].include?(e['class'].to_s) &&
          !(e['resolution'].is_a?(Hash) && %w[manual waived].include?(e['resolution']['how'].to_s))
      end
      return nil if unresolved.empty?
      return { id: 'lod-resolve', auto: false,
               cmd: ['ruby', 'scripts/audit-lod-calcs.rb', '--workdir', wd, '--resolve', unresolved.first[1].to_s,
                     '--how', '<manual|waived>', '--reason', '"..."'],
               why: "#{unresolved.length} unresolved LOD ledger entr#{unresolved.length == 1 ? 'y' : 'ies'} (suspect-alias / silently-dropped) — gate 17" }
    end
    cf = File.join(wd, 'calc-fields.json')
    has_lod = File.file?(cf) && File.read(cf, encoding: 'UTF-8').match?(LOD_RE)
    has_lod ||= Dir.glob(File.join(wd, '*.twb')).any? { |t| File.read(t, encoding: 'UTF-8').match?(LOD_RE) rescue false } unless File.file?(cf)
    return nil unless has_lod
    { id: 'lod-audit', auto: true, cmd: ['ruby', 'scripts/audit-lod-calcs.rb', '--workdir', wd],
      why: 'workdir carries LOD calcs but no lod-audit.json — gate 17' }
  end

  # Ground-truth trio (gate 18). Applies only with a .twb + parity-plan.json.
  # Tier-S runs skip it (the gate evaluates the valued-anchors oracle itself).
  def check_ground_truth(wd, conn, actuals, tier)
    return [] if tier.to_s == 'S'
    return [] unless Dir.glob(File.join(wd, '*.twb')).any? && File.file?(File.join(wd, 'parity-plan.json'))
    items = []
    plan = read_json(File.join(wd, 'ground-truth-plan.json'))
    plan_ok = plan.is_a?(Hash) && plan['entries'].is_a?(Array)
    gen = plan_ok ? plan['generated_at'].to_s : nil
    items << { id: 'gt-derive', auto: true, cmd: ['ruby', 'scripts/derive-ground-truth.rb', '--workdir', wd],
               why: 'ground-truth-plan.json missing — gate 18' } unless plan_ok
    ga = read_json(File.join(wd, 'ground-truth-actuals.json'))
    run_fresh = plan_ok && ga.is_a?(Hash) && ga['plan_generated_at'].to_s == gen
    run_needed = !plan_ok || !run_fresh
    if run_needed
      items << { id: 'gt-run', auto: !conn.nil?,
                 cmd: ['ruby', 'scripts/run-ground-truth.rb', '--workdir', wd, '--connection-id', conn || '<connection-id>'],
                 why: 'ground-truth-actuals.json missing/stale vs ground-truth-plan.json — gate 18 (needs the Sigma connection id)' }
    end
    np = read_json(File.join(wd, 'numeric-parity.json'))
    require_relative 'evidence_inputs'
    changed = np.is_a?(Hash) ? EvidenceInputs.changed(np['inputs'], EvidenceInputs.gt_fingerprint(wd, sigma_actuals: actuals)) : []
    verify_fresh = plan_ok && np.is_a?(Hash) && np['plan_generated_at'].to_s == gen && run_fresh && changed.empty?
    unless verify_fresh && !run_needed
      cmd = ['ruby', 'scripts/verify-ground-truth.rb', '--workdir', wd]
      cmd += ['--sigma-actuals', actuals.to_s] unless actuals.to_s.empty?
      items << { id: 'gt-verify', auto: true, cmd: cmd,
                 why: "numeric-parity.json missing/stale — gate 18 numeric comparison never ran against the current plan" \
                      "#{changed.any? ? " (inputs changed since: #{changed.join(', ')})" : ''}" }
    end
    items
  end

  # A blind grade sits on disk but was never recorded onto parity-final.json
  # (live re-proof: record-visual-check refused it for a missing --screenshot,
  # and the repeated --finalize then tripped the loop breaker before anyone
  # noticed). With an RCF ledger the screenshot MUST be the ledger's latest
  # budgeted render — name it, and the grade it must match, up front.
  # The latest budgeted RCF render (the only screenshot record-visual-check
  # accepts when fidelity-ledger.json exists), or nil.
  def latest_render(wd)
    led = read_json(File.join(wd, 'fidelity-ledger.json'))
    latest = led.is_a?(Hash) ? Array(led['renders']).last : nil
    latest.is_a?(Hash) && !latest['path'].to_s.empty? ? latest : nil
  end

  # The full record command (plugin-local wrapper: fills --screenshot from the
  # ledger and archives a REFUSED grade so it can never deadlock the preflight).
  #
  # `verdict:` omitted        -> derive pass|divergent from the grade on disk
  #                              (legacy v1 shape: --verdict + --checklist/--notes).
  # `verdict: 'pass'|'divergent'` -> that verdict, same shape.
  # `verdict: nil` (explicit)  -> a v2 grade: the verdict is COMPUTED from the
  #                              grade, so --verdict/--checklist are omitted.
  def record_command(wd, verdict: :derive)
    grade_path = File.join(wd, 'blind-grade.json')
    cmd = ['ruby', 'scripts/record-blind-grade.rb', '--workdir', wd]
    # A v2 grade computes its own verdict: derive -> the v2 command shape.
    if verdict == :derive
      grade = read_json(grade_path)
      verdict = nil if grade.is_a?(Hash) && grade['schema'].to_s == 'blind-grade/v2'
    end
    if verdict.nil?
      cmd += ['--blind-grade', grade_path]
    else
      if verdict == :derive
        grade = read_json(grade_path)
        verdict = !grade.is_a?(Hash) || grade['verdict'].to_s.casecmp?('pass') ? 'pass' : 'divergent'
      end
      cmd += ['--verdict', verdict]
    end
    if (latest = latest_render(wd))
      cmd += ['--screenshot', latest['path'].to_s]
    end
    if verdict.nil?
      cmd += ['--notes', "'<what you compared>'"]
    else
      cmd += verdict == 'pass' ? ['--checklist', "'<k=pass|fail|na,...>'"] : ['--notes', "'<what diverges>'"]
    end
    cmd
  end

  # Visual-record precondition. A blind grade on disk that is not recorded
  # (live re-proof: the first --finalize ran everything and burned a loop-log
  # attempt; the second finally stopped), or — after Phase 6 has written
  # parity-final.json (post_phase6: true) — no visual verdict at all on an RCF
  # run. Never a deadlock:
  #   * before parity-final.json exists there is nothing to record onto: the
  #     orchestrator re-checks right after Phase 6 writes it (post_phase6);
  #   * a recorded `divergent` verdict already covers a FAILING grade (a
  #     refused or merely failing blind-grade.json left on disk adds nothing);
  #   * refused grades are archived by record-blind-grade.rb (blind-grade.refused-<n>.json).
  def check_visual_record(wd, post_phase6: false)
    led = read_json(File.join(wd, 'fidelity-ledger.json'))
    return nil unless led.is_a?(Hash)
    pf = read_json(File.join(wd, 'parity-final.json'))
    return nil unless pf.is_a?(Hash)
    return nil if pf['blind_grade_waiver']
    grade_path = File.join(wd, 'blind-grade.json')
    grade = File.file?(grade_path) ? read_json(grade_path) : nil
    recorded = pf['visual_verdict'].to_s
    if grade.nil?
      return nil unless post_phase6 && recorded.empty?
      latest = latest_render(wd)
      shot = latest ? latest['path'].to_s : '<run fidelity-loop.rb render first>'
      return { id: 'visual-record', auto: false, cmd: record_command(wd),
               why: "no visual verdict is recorded (gate 8b) — have a fresh context-free grader grade #{shot} " \
                    "(refs/blind-grader-brief.md, writes #{grade_path}), then record it" }
    end
    return nil unless grade.is_a?(Hash)
    rec_sha = pf.dig('blind_grade', 'target_sha256').to_s.downcase
    return nil if !rec_sha.empty? && rec_sha == grade['target_sha256'].to_s.downcase # recorded
    # A failing grade adds nothing over an already-recorded divergent verdict.
    return nil if recorded == 'divergent' && !grade['verdict'].to_s.casecmp?('pass')
    latest = latest_render(wd)
    unless latest
      return { id: 'visual-record', auto: false, cmd: ['ruby', 'scripts/fidelity-loop.rb', 'render', '--workdir', wd],
               why: 'blind-grade.json exists but fidelity-ledger.json has no budgeted render to bind it to' }
    end
    shot = latest['path'].to_s
    shot_abs = File.expand_path(shot, wd)
    sha = File.file?(shot_abs) ? Digest::SHA256.file(shot_abs).hexdigest : ''
    if sha != grade['target_sha256'].to_s.downcase
      return { id: 'visual-record', auto: false,
               cmd: ['(agent step)', 're-grade', shot, 'with a fresh context-free grader per refs/blind-grader-brief.md;',
                     'overwrite', grade_path, 'then re-run --finalize to record it'],
               why: "blind-grade.json grades different pixels than the latest RCF render (pass #{latest['pass']}, #{shot}) — " \
                    're-grade that render with a fresh context-free grader, then record it' }
    end
    { id: 'visual-record', auto: false, cmd: record_command(wd),
      why: "blind-grade.json (#{grade['verdict']}) is not recorded onto parity-final.json — record it with --screenshot " \
           "set to the latest RCF render (#{shot}); finalize cannot judge the visual gate without it" }
  end

  # Full ordered item list (anchors first only when the workdir has them; GT
  # chain keeps derive -> run -> verify order).
  def analyze(workdir, conn_id: nil, actuals: nil, wb_id: nil, tier: nil)
    conn = connection_id(workdir, conn_id)
    items = []
    items << check_parity_plan(workdir, wb_id)
    items << check_join_plan(workdir, conn)
    items << check_lod(workdir)
    items << check_anchor_seed(workdir)
    items << check_anchors(workdir, wb_id)
    items << check_actuals(workdir, actuals, wb_id)
    items.concat(check_ground_truth(workdir, conn, actuals, tier))
    items << check_visual_record(workdir)
    items.compact
  end

  # Run every auto item (in order, once), re-analyze, and return
  #   { ran: [[id, ok, tail]], missing: [items] }
  # An auto item that still reports missing after its run is demoted to a
  # manual item carrying the run's output tail. `runner` is
  # lambda(cmd) -> [ok(bool), output(String)]. Never writes loop-log.jsonl.
  def resolve(workdir, runner:, conn_id: nil, actuals: nil, wb_id: nil, tier: nil)
    ran = []
    # Rounds: an auto step can make a later one due (seeding anchors makes the
    # anchors verdict stale; a fresh verdict makes numeric-parity stale). Each
    # item runs at most once; bounded by the item count.
    4.times do
      due = analyze(workdir, conn_id: conn_id, actuals: actuals, wb_id: wb_id, tier: tier)
              .select { |i| i[:auto] && ran.none? { |r| r.first == i[:id] } }
      break if due.empty?
      due.each do |it|
        ok, out = runner.call(it[:cmd])
        ran << [it[:id], ok, out.to_s.lines.last(3).join.strip]
      end
    end
    after = analyze(workdir, conn_id: conn_id, actuals: actuals, wb_id: wb_id, tier: tier)
    ran_ids = ran.map(&:first)
    missing = after.map do |it|
      if it[:auto] && ran_ids.include?(it[:id])
        tail = ran.find { |r| r.first == it[:id] }&.last
        it.merge(auto: false, why: "#{it[:why]} — the automatic run did not clear it#{tail.to_s.empty? ? '' : " (last output: #{tail})"}")
      else
        it
      end
    end
    # An auto item with no connection id is manual by construction; keep it.
    # verify-ground-truth exit 2 (divergence) legitimately leaves artifacts
    # written, so it never lands here; the gate reports the divergence.
    { ran: ran, missing: missing }
  end

  # Printable ordered list (strings), one numbered entry per missing item.
  def render_missing(missing)
    missing.each_with_index.map do |it, i|
      "  #{i + 1}. #{it[:why]}\n     #{Array(it[:cmd]).join(' ')}"
    end
  end
end
