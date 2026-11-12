# frozen_string_literal: true
#
# factory_punchlist.rb — W2.2: render the factory-mode PUNCH LIST from the
# artifacts the run ALREADY wrote. This is a RENDERER, not a ledger build
# (adjudicated: the degradation ledger shipped in wave 1) — it consumes the
# shipped degradation-ledger.json schema AS-IS (frozen; schema changes go via
# lane B), plus EvidenceLedger rows for failed-gate context. Factory default =
# one pass + measured parity + this punch list; `--certified` is the opt-in
# back to loop-to-green.
#
# Per ledger line, ONE copy-pasteable re-entry command (or, where a command
# cannot honestly be scripted — grants, upstream materialization — the steps
# are PRESENTED, never attempted). GREEN still requires an EMPTY ledger
# (shipped doctrine, assert-phase6-ran); a non-GREEN verdict with an empty
# punch list is an INVERSION and raises — the honesty backstop
# verify-complete.rb re-checks from the other side.
#
# Outputs (workdir-local, gitignored):
#   <WORK>/punchlist.json  { verdict, counts, items:[entry + 'reentry'], … }
#   <WORK>/PUNCHLIST.md    the human copy, embedded verbatim in the report
#                          (migration-notes.rb appends it).

require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require_relative 'degradation_ledger'
begin
  require_relative 'evidence_ledger'
rescue LoadError
  nil
end

module FactoryPunchlist
  VERSION = 1

  module_function

  def ledger_path(workdir)
    File.join(workdir, 'degradation-ledger.json')
  end

  def read_verification(workdir)
    path = File.join(workdir, 'verification-result.json')
    return nil unless File.exist?(path) || File.symlink?(path)
    raw = File.binread(path)
    text = raw.dup.force_encoding(Encoding::UTF_8)
    raise ArgumentError, 'verification result is not UTF-8' unless text.valid_encoding?
    doc = JSON.parse(text.sub(/\A\uFEFF/, ''))
    raise ArgumentError, 'verification result has no recognized verdict' unless doc.is_a?(Hash) && %w[GREEN YELLOW RED].include?(doc['verdict'])
    divergences = doc.fetch('divergences', [])
    raise ArgumentError, 'verification divergences must be an array of objects' unless divergences.is_a?(Array) && divergences.all? { |entry| entry.is_a?(Hash) }
    raise ArgumentError, 'verification divergence has no recognized severity' unless divergences.all? { |entry| %w[number structural cosmetic].include?(entry['severity']) }
    verdict = doc['verdict']
    verdict = 'YELLOW' if verdict == 'GREEN' && divergences.any? { |entry| entry['severity'] == 'structural' }
    verdict = 'RED' if divergences.any? { |entry| entry['severity'] == 'number' }
    { 'verdict' => verdict, 'sha256' => Digest::SHA256.hexdigest(raw),
      'divergences' => divergences }
  rescue JSON::ParserError, ArgumentError, SystemCallError
    { 'verdict' => 'RED', 'unreadable' => true, 'divergences' => [
      { 'severity' => 'unverified', 'element' => 'verification-result.json',
        'description' => 'Independent verification evidence is missing, malformed, or unreadable.',
        'suggested_fix' => 'Regenerate independent verification before claiming completion.' }
    ] }
  end

  def read_completion_report(workdir)
    path = File.join(workdir, 'migration-result.json')
    return nil unless File.exist?(path) || File.symlink?(path)
    raw = File.binread(path)
    text = raw.dup.force_encoding(Encoding::UTF_8)
    raise ArgumentError, 'completion report is not UTF-8' unless text.valid_encoding?
    doc = JSON.parse(text.sub(/\A\uFEFF/, ''))
    raise ArgumentError, 'completion report has no recognized verdict' unless doc.is_a?(Hash) && %w[GREEN YELLOW RED].include?(doc['verdict'])
    checks = doc.fetch('checks', [])
    raise ArgumentError, 'completion report checks are invalid' unless checks.is_a?(Array) && checks.all? { |check| check.is_a?(Hash) && %w[PASS WARN FAIL SKIP].include?(check['status']) }
    verdict = checks.any? { |check| check['status'] == 'FAIL' } ? 'RED' : doc['verdict']
    { 'verdict' => verdict, 'sha256' => Digest::SHA256.hexdigest(raw), 'checks' => checks }
  rescue JSON::ParserError, ArgumentError, SystemCallError
    { 'verdict' => 'RED', 'unreadable' => true, 'checks' => [
      { 'name' => 'completion-report', 'status' => 'FAIL', 'message' => 'migration-result.json is malformed or unreadable; rebuild the migration report.' }
    ] }
  end

  # The shipped ledger file when present (the gate writes it on every run that
  # reaches the verdict seam); else a fresh DegradationLedger.derive over the
  # same artifacts — IDENTICAL schema either way, consumed as-is.
  def load_entries(workdir)
    if File.exist?(ledger_path(workdir))
      doc = JSON.parse(File.read(ledger_path(workdir), encoding: 'UTF-8'))
      entries = doc.is_a?(Hash) ? doc['entries'] : nil
      raise ArgumentError, 'degradation-ledger.json: no entries array' unless entries.is_a?(Array)
      counts = doc['counts'].is_a?(Hash) ? doc['counts'] : {}
      claimed = counts.values.map(&:to_i).sum
      # INVERSION guard (corrupt/tampered input): a ledger CLAIMING degradations
      # (nonzero counts) while presenting none would render an empty punch list
      # under a non-GREEN verdict — refuse instead of understating.
      raise ArgumentError, "degradation-ledger.json INVERSION: counts claim #{claimed} entr(ies) but entries[] is empty" if claimed.positive? && entries.empty?
      [entries, 'degradation-ledger.json']
    else
      [DegradationLedger.derive(workdir), 'derived (no degradation-ledger.json on disk — pre-gate render)']
    end
  end

  # One copy-pasteable re-entry per ledger line, keyed on the entry's source
  # artifact (the plan's named shapes: probe-join-keys --resolve/--how,
  # --master-col, presented-not-attempted materialization/grant text). Every
  # branch is an EXISTING script/flag — nothing here invents a tool.
  def reentry_for(entry, workdir)
    src    = entry['source_artifact'].to_s
    item   = entry['item'].to_s
    reason = entry['reason'].to_s
    fin    = "ruby scripts/migrate-tableau.rb --workbook-id <sigma-wb> --out #{workdir} --finalize --actuals #{File.join(workdir, 'parity-actuals.json')}"
    if reason =~ /grant|permission|denied|not authorized/i
      return "grant-request (PRESENTED, not attempted): ask the warehouse admin to GRANT SELECT on the source object(s) behind '#{item}' to the Sigma service role, then: #{fin}"
    end
    case src
    when /join-plan\.json/
      "ruby scripts/probe-join-keys.rb --workdir #{workdir} --resolve '#{item}' --how <inner|left|filter|skip>   # re-probe + record, then: #{fin}"
    when /lod-audit\.json/
      "re-author '#{item}' (grouped element or Custom SQL), refresh the audit: ruby scripts/audit-lod-calcs.rb --workdir #{workdir}, then: #{fin}"
    when /manual-residues\.json/
      "build '#{item}' as a Custom SQL DM element (kind: sql, exit-16 banner steps), then: #{fin}"
    when /agg-semantics\.json/
      "reaggregation steps PRESENTED, not attempted: materialize '#{item}' at base grain upstream (or record resolution n/a), then: #{fin}"
    when /fidelity-ledger\.json/
      "ruby scripts/fidelity-loop.rb apply-patch --workdir #{workdir} --resolves <id>   # or render→record to resolution, then: #{fin}"
    when /parity-final\.json/
      if entry['class'] == 'quality-waiver'
        "re-run WITHOUT #{item} once its blocker is fixed: #{fin}"
      else
        "fix the divergence, then: ruby scripts/record-visual-check.rb --workdir #{workdir} --agent-vision true --blind-grade <blind-grade.json>, then: #{fin}"
      end
    when /coverage\.json/
      "derive the missing master column on the pass-1 re-entry: add --master-col '#{item}=<Sigma formula>' (exit-4 handoff path), then: #{fin}"
    when /deferred-elements\.json/
      "resolve the quarantined DM element '#{item}' (deferred-elements.json names the refusal), re-POST per the exit-6 flow, then: #{fin}"
    when /controls-coverage|control-scope|controls-waivers/
      "re-emit control '#{item}': fix the named signal (see #{src}) and re-run pass 1; or keep the recorded waiver and ship degraded"
    when /offramps\.jsonl/
      "close the escape '#{item}': re-run with the gate/protection restored (no skip flag), then: #{fin}"
    when /source-anchors\.json|ground-truth-plan\.json/
      "add a numeric oracle for '#{item}' (view CSV / VDS export), re-run: ruby scripts/verify-anchors.rb --workdir #{workdir}, then: #{fin}"
    when /png-read\.json/
      "recorded chart-family substitution on '#{item}' — rebuild with the native kind if required, re-render, then: #{fin}"
    else
      "address '#{item}' (#{reason[0, 80]}), then: #{fin}"
    end
  end

  # Failed/waived gate rows from the evidence ledger (context, newest last).
  def gate_context(workdir)
    return [] unless defined?(EvidenceLedger)
    EvidenceLedger.read(workdir).reject { |r| r['verdict'].to_s == 'pass' }
                  .last(20).map { |r| "#{r['gate']}=#{r['verdict']}#{r['at'] ? " @#{r['at']}" : ''}" }
  rescue StandardError
    []
  end

  # Assemble the punch list. Raises ArgumentError on inversion (non-GREEN
  # verdict + empty items) — a punch list that understates is worse than none.
  def build(workdir)
    entries, source = load_entries(workdir)
    ledger_verdict = DegradationLedger.verdict(entries)
    verdict = ledger_verdict
    verification = read_verification(workdir)
    completion_report = read_completion_report(workdir)
    external_verdicts = [verification, completion_report].compact.map { |record| record['verdict'] }
    if external_verdicts.include?('RED')
      verdict = 'RED'
    elsif external_verdicts.include?('YELLOW')
      verdict = ledger_verdict.start_with?('PARTIAL') ? 'PARTIAL+YELLOW' : 'YELLOW'
    end
    items = entries.map { |e| e.merge('reentry' => reentry_for(e, workdir)) }
    raise ArgumentError, "punch-list INVERSION: verdict #{ledger_verdict} with ZERO items" if ledger_verdict != 'GREEN' && items.empty?
    counts = Hash.new(0)
    entries.each { |e| counts[e['class']] += 1 }
    { 'version' => VERSION, 'verdict' => verdict, 'ledger_verdict' => ledger_verdict,
      'verification' => verification, 'completion_report' => completion_report, 'counts' => counts,
      'source' => source, 'items' => items, 'gate_context' => gate_context(workdir),
      'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
  end

  def render_md(built, workdir)
    md = +"# PUNCH LIST — #{built['verdict']}\n\n"
    if built['items'].empty?
      md << "Empty — the degradation ledger is EMPTY (GREEN requires exactly that; shipped doctrine).\n"
      if [built['verification'], built['completion_report']].compact.any? { |record| record['verdict'] != 'GREEN' }
        md << "An empty degradation ledger does not override the verification or completion-report findings below.\n"
      else
        md << "Nothing was cut, waived, escaped, or left unresolved on this run.\n"
      end
    else
      md << "#{built['items'].size} degradation item(s); independent verification may add findings below.\n"
      md << "One command per line; run it, then re-enter where the command says. Factory default is ONE pass +\n"
      md << "measured parity + this list; `--certified` restores the loop-to-green contract (RCF 5 + verifier).\n\n"
      built['items'].group_by { |i| i['class'] }.each do |cls, list|
        md << "## #{cls} (#{list.size})\n\n"
        list.each do |i|
          md << "- [ ] **#{i['item']}** — #{i['reason']} _(#{i['source_artifact']})_\n"
          md << "      ```\n      #{i['reentry']}\n      ```\n"
        end
        md << "\n"
      end
    end
    if (verification = built['verification'])
      md << "\n## Independent verification\n\nVerdict: **#{verification['verdict']}** (verification-result.json).\n\n"
      verification['divergences'].each do |entry|
        marker = verification['verdict'] == 'GREEN' ? 'x' : ' '
        md << "- [#{marker}] [#{entry['severity']}] **#{entry['element']}**: #{entry['description']}\n"
        md << "  Next action: #{entry['suggested_fix']}\n" unless entry['suggested_fix'].to_s.empty?
      end
      if verification['verdict'] != 'GREEN' && verification['divergences'].empty?
        md << "Verification is not GREEN. Obtain the verifier's findings and resolve them before re-verifying.\n"
      end
    end
    if (report = built['completion_report'])
      md << "\n## Completion report\n\nVerdict: **#{report['verdict']}** (migration-result.json).\n\n"
      report['checks'].reject { |check| check['status'] == 'PASS' }.each do |check|
        md << "- [ ] [#{check['status']}] **#{check['name']}**: #{check['message']}\n"
      end
      md << "The completion report cannot be promoted by the degradation ledger or a separate verifier.\n" if report['verdict'] != 'GREEN'
    end
    unless Array(built['gate_context']).empty?
      md << "---\nGate context (non-pass evidence rows, newest last): #{built['gate_context'].join(' · ')}\n"
    end
    md << "\n_Rendered from #{built['source']} at #{built['generated_at']} (workdir: #{workdir})._\n"
    md
  end

  # Render + write both artifacts. Returns the built Hash.
  def write(workdir)
    # A failed rebuild must not leave an earlier report at its authoritative path.
    previous = %w[punchlist.json PUNCHLIST.md].map { |name| File.join(workdir, name) }.select { |path| File.exist?(path) || File.symlink?(path) }
    unless previous.empty?
      root = File.join(workdir, 'report-history')
      raise ArgumentError, 'report history must not be a symlink' if File.symlink?(root)
      archive = File.join(root, SecureRandom.hex(16))
      FileUtils.mkdir_p(archive, mode: 0o700)
      previous.each { |path| File.rename(path, File.join(archive, File.basename(path))) }
    end
    built = build(workdir)
    File.write(File.join(workdir, 'punchlist.json'), JSON.pretty_generate(built))
    File.write(File.join(workdir, 'PUNCHLIST.md'), render_md(built, workdir))
    built
  end
end
