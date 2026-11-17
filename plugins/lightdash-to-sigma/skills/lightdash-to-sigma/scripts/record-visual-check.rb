#!/usr/bin/env ruby
# frozen_string_literal: true
#
# record-visual-check.rb — record the outcome of the MANDATORY Phase 6f
# full-dashboard source-vs-target visual comparison into parity-final.json, so
# assert-phase6-ran.rb gate 8b (--require-visual-comparison) can confirm the
# comparison actually happened instead of trusting a prose "I looked at it".
#
# Run this AFTER you have rendered the Sigma page (sigma-export-png.py) AND read
# it side-by-side against the source dashboard PNG captured in discovery (Tableau MCP
# get-view-image, Power BI page export, QuickSight StartDashboardSnapshotJob,
# MicroStrategy export-dossier-pdf.py, … — whatever this plugin's Phase-1d step
# writes; a customer screenshot dropped at the same path is equally valid):
#
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision true \
#     --verdict pass            --notes "matches source; KPI row + 3 trend tiles aligned"
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision true \
#     --verdict divergent       --notes "Region bar truncated vs source — fixing"  [--screenshot <png>]
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision false \
#     --verdict not-executable  --notes "driving agent has no image input"
#
# It does NOT judge for you — it records the verdict YOU reached. `pass` stamps
# visual_checked:true; `divergent` records the gap (visual_checked stays false).
# A recorded divergent verdict passes gate 8b as RECORDED. It is NOT a waiver
# (it does not spend the 2-waiver budget) but it forfeits GREEN: the degradation
# ledger records it as a fidelity-residual, so the run is at most YELLOW — fix
# the gaps and re-record `pass`, or accept YELLOW.
#
# BLIND-GRADE v2 (score-based rule; refs/blind-grader-brief.md writes it): when
# --blind-grade is a `blind-grade/v2` grade the verdict is COMPUTED, not chosen:
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision true \
#     --blind-grade /tmp/<name>/blind-grade.json [--blind-grade-2 .../blind-grade-2.json] \
#     [--notes "..."] [--screenshot <png>]
#   * `pass` when BlindGrade.faithful (mean overall_score >= 75, chart_shapes_match +
#     numbers_formatted pass, no major `fixable` gap), else `divergent`. --verdict is
#     optional; a --verdict that disagrees with the computed one is REFUSED (exit 2).
#     --checklist is optional (derived from the grade's dimensions); an explicit one
#     that contradicts the grade's dimensions is REFUSED (exit 2). --verdict
#     not-executable takes NO grade (refused, exit 2).
#   * A single grade scoring within +-5 of 75 is REFUSED (exit 2): "second blind grader
#     required (score within +-5 of 75)" -- re-run the same brief with
#     OUT_JSON=blind-grade-2.json and pass --blind-grade-2; the mean decides. Both
#     grades must carry the same source/target sha256 and the same schema, must be
#     DIFFERENT files with different bytes, and --blind-grade-2 is REFUSED (exit 2)
#     unless grade 1 ALONE is borderline (a second grade is not a retry button).
#   * The only catalog is the SHIPPED ../refs/sigma-platform-differences.json (there
#     is no --catalog option: a self-authored catalog would launder gaps). A grade
#     whose catalog_sha256 is neither the shipped catalog nor an unchanged ANCESTOR
#     of it (refs/sigma-platform-differences-history.json: an earlier catalog whose
#     every entry is still shipped with identical content), that cites an id not in
#     it, or that cites an id on a different dimension than the entry's, is refused.
#     An ancestor grade is kept exactly as graded (never re-mapped onto a new id);
#     the output offers an optional re-grade to pick up the new entries.
#   * Run it AFTER the first finalize (it records onto parity-final.json); a run
#     before that is refused with the exact finalize command and this command to
#     re-run. With an RCF ledger, an omitted --screenshot is the ledger's latest
#     render (the only value it may take).
#   * Writes <workdir>/visual-residuals.json (visual-residuals/v1: score, faithful,
#     platform_differences, residuals [fixable minor], fixable_major [fixable major,
#     named in the report when the run is divergent], reasons, per-grade
#     path+sha256) and stamps parity-final.json blind_grade with schema/score/
#     faithful/catalog_sha256/catalog_path/grades[] so gate 8b can re-hash every
#     file and re-derive visual-residuals.json. Recording a v1 grade,
#     not-executable or a no-vision waiver DELETES a stale visual-residuals.json
#     (and the v2 path deletes a stale blind_grade_waiver; the waiver path a stale
#     blind_grade).
# v1 / schema-less grades keep the all-six-dimensions-pass rule described above.
#
# VISION PRECONDITION (SKILL_IMPROVEMENT_PLAN_V3 §D5): a pixel-fidelity verdict
# requires an agent that actually READ the render. --agent-vision true|false is
# required (env AGENT_VISION accepted as a fallback source):
#   --agent-vision false + --verdict pass  → REFUSED (exit 2, nothing written).
#     Record --verdict not-executable instead, or re-run the visual loop from a
#     vision-capable session (Claude Code with image input).
#   --verdict not-executable (--notes mandatory) → stamps visual_checked:false,
#     visual_verdict:"not-executable", agent_vision:false — gate 8b then fails
#     with the named degradation instead of accepting a blind attestation.
#   Every verdict stamps `agent_vision` into parity-final.json.
# Back-compat: omitting --agent-vision entirely warns LOUDLY and assumes true
# (existing callers keep working) — that default is deprecated; pass the flag.
#
# BLIND-GRADER PRECONDITION (PLAN-v3 PR-9): a `pass` verdict additionally
# REQUIRES `--blind-grade <path>` — a blind-grade.json written by a FRESH,
# CONTEXT-FREE subagent that received ONLY the source PNG + render PNG + the
# rubric (refs/blind-grader-brief.md). Field failure: the builder self-graded
# its own workbook 6/6 PASS on visuals the customer rejected — the builder's
# eye is not the verdict. The grade is validated here (parses, every checklist
# dimension present, sha256-BOUND to the actual image files on disk — hashes
# recomputed, never trusted) and its per-tile chart-family readings are
# cross-checked against the mechanical kind census (wb-readback.json /
# png-read.json) so a fabricated grade is refused as inconsistent. A builder
# `pass` over a FAILING blind grade is refused. The ONLY escape, for sessions
# that cannot spawn a vision-capable context-free grader: --no-vision-waiver
# "<reason>" — recorded into parity-final.json and COUNTED against the gate's
# waiver budget (never silent).
require 'json'
require_relative 'lib/cli_encoding'
require_relative 'lib/blind_grade'
require 'optparse'
require 'fileutils'
require 'shellwords'

# The command line as typed (before the --no-vision-waiver scan and optparse
# consume ARGV) — echoed back verbatim when the run is refused for ordering.
ORIGINAL_ARGV = ARGV.dup.freeze

VERDICTS = %w[pass divergent not-executable].freeze
# v5.3 STYLE CHECKLIST (round-5 owner-eye consensus dimensions). A gestalt
# "pass" repeatedly shipped exposed chrome, broken palettes, and decomposed
# layouts that an exacting owner rejected — the verdict must now attest each
# dimension separately, judged against the SOURCE image, not the intent.
CHECKLIST_KEYS = %w[element_titles_hidden palette_match composition_match
                    chart_shapes_match labels_legible numbers_formatted].freeze
CHECKLIST_VALS = %w[pass fail na].freeze

# W1.4 contradiction guard: a PASS must not contradict the machine signal. If
# verify-anchors measured empty DISPLAYED tiles (charts return no rows), a
# "pass" is a false attestation over a "No data" render — the exact 2026-07
# move (record-visual-check PASS + 6x-pass checklist over a dataless render).
def anchors_guard!(dir)
  av_path = File.join(dir, 'anchors-verdict.json')
  if File.exist?(av_path)
    av = (JSON.parse(File.read(av_path)) rescue nil)
    if av.is_a?(Hash) && av.key?('tiles_all_nonempty') && av['tiles_all_nonempty'] != true
      empty = Array(av['dashboard_tiles_empty'])
      warn "REFUSED: cannot record a visual PASS — verify-anchors measured #{empty.length} displayed tile(s)"
      warn '         that export ZERO data rows (the charts render "No data"):'
      empty.first(8).each { |t| warn "           #{t['id']} #{t['name'].inspect} [#{t['kind']}]" }
      warn '         A visual "pass" over a dataless render is a false attestation. Fix the data path'
      warn '         (filter literal / calc types), re-run verify-anchors.rb, then re-judge. A genuinely'
      warn '         empty SOURCE chart is waived at the gate (--allow-empty-tiles), never by a pass here.'
      exit 2
    end
  end
end

# A blind grade is evidence for exactly ONE rendered image. When the RCF
# ledger exists, require that image to be both the explicitly selected final
# screenshot and the latest budgeted fidelity render. Returns the stamp (or nil
# when no ledger exists); aborts (exit 1) on any binding failure.
def bind_fidelity!(opts, grade)
  fidelity_stamp = nil
  fidelity_path = File.join(opts[:dir], 'fidelity-ledger.json')
  if File.file?(fidelity_path)
    fidelity = begin
      JSON.parse(File.read(fidelity_path))
    rescue JSON::ParserError => e
      abort "REFUSED: fidelity-ledger.json is malformed (#{e.message}) — cannot bind the visual grade."
    end
    latest = Array(fidelity['renders']).last
    abort 'REFUSED: fidelity-ledger.json has no budgeted render — run fidelity-loop.rb render first.' \
      unless latest.is_a?(Hash) && !latest['path'].to_s.empty?
    latest_path = File.expand_path(latest['path'].to_s, opts[:dir])
    abort "REFUSED: latest fidelity render is missing: #{latest_path}" unless File.file?(latest_path)
    if opts[:shot].to_s.empty?
      # Safe to infer: the screenshot MUST be the ledger's latest budgeted render
      # (checked below against the grade's target sha), so there is exactly one
      # valid value. Field-caught: both 2026-11-09 regression runs were refused
      # here for omitting it.
      opts[:shot] = latest['path'].to_s
      puts "NOTE: --screenshot not given — using the latest budgeted RCF render from fidelity-ledger.json " \
           "(pass #{latest['pass']}): #{opts[:shot]}"
    end
    shot_path = File.expand_path(opts[:shot], opts[:dir])
    abort "REFUSED: --screenshot file is missing: #{shot_path}" unless File.file?(shot_path)
    target_sha = grade['target_sha256'].to_s.downcase
    latest_sha = BlindGrade.sha256(latest_path)
    shot_sha = BlindGrade.sha256(shot_path)
    if target_sha != latest_sha || target_sha != shot_sha
      abort "REFUSED: blind grade / screenshot / latest RCF render do not identify the same pixels " \
            "(grade=#{target_sha[0, 12]}…, screenshot=#{shot_sha[0, 12]}…, " \
            "latest_pass=#{latest['pass']} #{latest_sha[0, 12]}…). Re-grade the latest budgeted render."
    end
    fidelity_stamp = {
      'pass' => latest['pass'],
      'path' => latest['path'],
      'sha256' => latest_sha
    }
  end
  fidelity_stamp
end

# Anti-gaming cross-check: the grader's per-tile family readings must agree
# with the mechanical kind census. >MAX_FAMILY_MISMATCHES contradictions on
# either side = the families were not read off the images → fabricated grade.
# Returns the {side => status} stamp; exits 2 on contradiction.
def census_cross_check!(dir, grade)
  cross = {}
  { 'target' => BlindGrade.census_from_readback(File.join(dir, 'wb-readback.json')),
    'source' => BlindGrade.census_from_png_read(File.join(dir, 'png-read.json')) }.each do |side, census|
    if census.nil? || census.empty?
      cross[side] = 'skipped (no mechanical census artifact)'
      next
    end
    cc = BlindGrade.cross_check(grade['per_tile'], census, side)
    if cc['mismatches'] > BlindGrade::MAX_FAMILY_MISMATCHES
      warn "REFUSED: blind grade INCONSISTENT with the mechanical kind census — its #{side}_family readings"
      warn "         contradict #{side == 'target' ? 'wb-readback.json' : 'png-read.json'} on #{cc['mismatches']} tile(s) " \
           "(tolerance: #{BlindGrade::MAX_FAMILY_MISMATCHES})."
      warn "         blind:  #{cc['blind'].sort.map { |f, n| "#{n}x#{f}" }.join(', ')}"
      warn "         census: #{cc['census'].sort.map { |f, n| "#{n}x#{f}" }.join(', ')}"
      warn '         A grade whose chart families do not match what is mechanically on the page was not'
      warn '         read off these images (fabricated or stale). Re-run the context-free grader against'
      warn '         the CURRENT render. Nothing was written.'
      exit 2
    end
    cross[side] = "ok (#{cc['mismatches']} of #{census.length} tile(s) tolerated-mismatch#{cc['kpi_band'] ? '; KPI strip read as a band' : ''}#{cc['cant_tell'] ? "; #{cc['cant_tell']} tile(s) the grader could not tell (other/unknown)" : ''})"
  end
  cross
end

# The plugin's exact finalize command for this workdir, or nil. An orchestrator
# that knows it (tableau: migrate-tableau.rb pass 1) writes
# <workdir>/finalize-command.json {"schema":"finalize-command/v1","argv":[...]}.
FINALIZE_HINT = 'finalize-command.json'
def finalize_argv(dir)
  hint = (JSON.parse(File.read(File.join(dir, FINALIZE_HINT))) rescue nil)
  argv = hint.is_a?(Hash) ? hint['argv'] : nil
  argv.is_a?(Array) && !argv.empty? && argv.all? { |a| a.is_a?(String) && !a.empty? } ? argv : nil
end

# This exact record command, to re-run after finalize. --screenshot is added
# from the ledger when it was omitted (it may only be the latest render).
def rerun_argv(dir, argv)
  args = argv.dup
  if args.none? { |a| a == '--screenshot' || a.start_with?('--screenshot=') }
    led = (JSON.parse(File.read(File.join(dir, 'fidelity-ledger.json'))) rescue nil)
    latest = led.is_a?(Hash) ? Array(led['renders']).last : nil
    args += ['--screenshot', latest['path'].to_s] if latest.is_a?(Hash) && !latest['path'].to_s.empty?
  end
  ['ruby', 'scripts/record-visual-check.rb', *args]
end

def parity_path!(dir, argv = ORIGINAL_ARGV)
  path = File.join(dir, 'parity-final.json')
  return path if File.exist?(path)

  # Not "REFUSED:" — record-blind-grade.rb archives a grade on REFUSED output,
  # and nothing is wrong with the grade here, only the order.
  warn "NOT YET RECORDED: #{path} does not exist yet — the visual verdict is recorded ONTO the parity result,"
  warn '         so record runs AFTER the first finalize, never before it. Nothing was written.'
  warn '         Working order: finalize (writes parity-final.json; with an RCF ledger it then stops with'
  warn '         exit 29 asking for this record) -> record-visual-check -> finalize again.'
  if (fin = finalize_argv(dir))
    warn '  Next command (finalize first):'
    warn "    #{Shellwords.join(fin)}"
  else
    # Each converter names its own parity script (phase6-parity.rb,
    # phase6-parity-quicksight.rb, …) and source flag; no orchestrator left a
    # finalize-command.json, so name what this plugin ships.
    scripts = Dir[File.join(__dir__, 'phase6-parity*.rb')].map { |f| File.basename(f) }.reject { |f| f.start_with?('test') }.sort
    warn '  Next command (finalize first): this plugin\'s Phase-6/7 finalize step, e.g.'
    warn "    ruby scripts/#{scripts.first || 'phase6-parity.rb'} --finalize ...   (with this workdir: #{dir})"
  end
  warn '  Then re-run this record command:'
  warn "    #{Shellwords.join(rerun_argv(dir, argv))}"
  exit 1
end

# Path as stamped into parity-final.json: relative to the workdir when inside
# it, else absolute (gate 8b re-hashes whatever is stamped).
def stamp_path(path, dir)
  full = File.expand_path(path.to_s, dir)
  root = File.join(File.expand_path(dir), '')
  full.start_with?(root) ? full[root.length..-1] : full
end

def peek_schema(path)
  doc = JSON.parse(File.read(path.to_s))
  doc.is_a?(Hash) ? doc['schema'].to_s : nil
rescue StandardError
  nil
end

opts = {}
# optparse special-cases any long flag starting with "--no-" as the boolean
# negation of the bare flag (value false, argument dropped) — extract the
# no-vision waiver + its REQUIRED reason from ARGV before parsing. The p.on
# entry below stays for --help; its callback is a no-op after this scan.
if (_nv_i = ARGV.index('--no-vision-waiver'))
  _nv_reason = ARGV[_nv_i + 1]
  if _nv_reason.nil? || _nv_reason.start_with?('--')
    abort 'FATAL: --no-vision-waiver requires a reason argument (WHY could no vision-capable grader be spawned?).'
  end
  opts[:no_vision_waiver] = _nv_reason
  ARGV.slice!(_nv_i, 2)
elsif (_nv_kv = ARGV.find { |a| a.start_with?('--no-vision-waiver=') })
  opts[:no_vision_waiver] = _nv_kv.split('=', 2)[1]
  ARGV.delete(_nv_kv)
end
if ARGV.any? { |a| a == '--catalog' || a.start_with?('--catalog=') }
  warn 'REFUSED: --catalog was removed — the only platform-difference catalog is the shipped'
  warn '         ../refs/sigma-platform-differences.json (a self-authored catalog would launder gaps). Nothing was written.'
  exit 2
end
OptionParser.new do |p|
  p.on('--workdir DIR')   { |v| opts[:dir] = v }
  p.on('--verdict V', VERDICTS, 'pass = render matches the source; divergent = a gap remains (gate stays blocked); not-executable = the visual loop could not run (vision-less agent) — --notes required, gate 8b fails with a named degradation') { |v| opts[:verdict] = v }
  p.on('--notes S')       { |v| opts[:notes] = v }
  p.on('--screenshot P')  { |v| opts[:shot] = v }
  p.on('--blind-grade P', 'REQUIRED with --verdict pass: path to blind-grade.json written by a FRESH context-free ' \
                          'grader subagent (refs/blind-grader-brief.md) that received ONLY the two image paths + ' \
                          'the rubric. Validated + sha256-bound here; a failing blind grade refuses a builder pass.') { |v| opts[:blind_grade] = v }
  p.on('--blind-grade-2 P', 'blind-grade/v2 only: path to a SECOND independent blind grade (same brief, OUT_JSON=' \
                            'blind-grade-2.json). Required when the first grade is within 5 of the pass bar (75); ' \
                            'the decision is then made on the mean score. Same image shas required.') { |v| opts[:blind_grade_2] = v }
  p.on('--no-vision-waiver R', 'escape ONLY for sessions that cannot spawn a vision-capable context-free grader ' \
                               '(Agent tool unavailable / subagents lack image input): records a blind_grade_waiver ' \
                               'into parity-final.json that COUNTS against the gate waiver budget — never silent. ' \
                               'The driving agent must still have read the render itself (--agent-vision true).') { |v| opts[:no_vision_waiver] = v if v.is_a?(String) }
  p.on('--agent-vision B', %w[true false], 'REQUIRED: can the driving agent actually read images? (env AGENT_VISION accepted as fallback)') { |v| opts[:vision] = (v == 'true') }
  p.on('--checklist S', "REQUIRED with --verdict pass: 'k=pass|fail|na,...' covering #{CHECKLIST_KEYS.join(', ')} — " \
                        'each judged against the SOURCE image (element_titles_hidden = no exposed/truncated element-title ' \
                        'chrome the source hides; palette_match = series/background/accent colors match the source swatches; ' \
                        'composition_match = same canvas grid/proportions, section headers adjacent to their charts, no dead ' \
                        'zones; chart_shapes_match = every tile same chart family + encoding; labels_legible = no truncated/' \
                        'clipped labels or leaked control stubs; numbers_formatted = value formats as printed in the source)') do |v|
    pairs = v.split(',').map(&:strip).reject(&:empty?)
    bad = pairs.reject { |kv| kv.include?('=') }
    abort "FATAL: --checklist entries need key=value (bad: #{bad.join(', ')})" if bad.any?
    opts[:checklist] = pairs.map { |kv| kv.split('=', 2).map(&:strip) }.to_h
  end
end.parse!

# checklist keys/values are validated for EVERY verdict that carries one — a
# divergent record feeds the fix loop and must not stamp junk (v5.3.1).
if opts[:checklist]
  missing_v = opts[:checklist].reject { |_k, v| CHECKLIST_VALS.include?(v) }
  abort "FATAL: --checklist value(s) must be pass|fail|na: #{missing_v.keys.join(', ')}" if missing_v.any?
  unknown_k = opts[:checklist].keys - CHECKLIST_KEYS
  abort "FATAL: --checklist unknown key(s): #{unknown_k.join(', ')} (want: #{CHECKLIST_KEYS.join(', ')})" if unknown_k.any?
end

abort 'FATAL: --workdir required' unless opts[:dir]
# Ordering first: with no parity-final.json there is nothing to record onto,
# whatever else this invocation gets right — say so before any other refusal.
parity_path!(opts[:dir])
# blind-grade/v2 (score-based rule): the verdict is COMPUTED from the grade(s);
# --verdict is optional and, when given, must agree. Schema-less grades and
# blind-grade/v1 follow the original all-six-pass path below, unchanged.
v2_mode = opts[:verdict] != 'not-executable' && !opts[:blind_grade].nil? &&
          peek_schema(opts[:blind_grade]) == BlindGrade::SCHEMA_V2
if opts[:blind_grade_2] && !v2_mode
  warn 'REFUSED: --blind-grade-2 only applies when --blind-grade is a blind-grade/v2 grade (and the verdict is not'
  warn '         not-executable). A v1 grade has no score to average. Nothing was written.'
  exit 2
end
if opts[:verdict] == 'not-executable' && opts[:blind_grade]
  warn 'REFUSED: --verdict not-executable takes no blind grade — nothing was graded because the visual loop could'
  warn '         not run. Drop --blind-grade (and --blind-grade-2), or record the grade-computed verdict. Nothing was written.'
  exit 2
end
abort "FATAL: --verdict #{VERDICTS.join('|')} required" unless opts[:verdict] || v2_mode

# --agent-vision: flag > env AGENT_VISION > (deprecated) assume-true.
if opts[:vision].nil? && !ENV['AGENT_VISION'].to_s.strip.empty?
  ev = ENV['AGENT_VISION'].to_s.strip.downcase
  abort "FATAL: AGENT_VISION must be true|false (got #{ENV['AGENT_VISION'].inspect})" unless %w[true false].include?(ev)
  opts[:vision] = (ev == 'true')
end
if opts[:vision].nil?
  warn '=' * 74
  warn 'WARN: --agent-vision not given (and AGENT_VISION unset) — ASSUMING true so'
  warn '      existing callers keep working. This default is DEPRECATED: a visual'
  warn '      verdict from an agent that cannot read images is a blind attestation.'
  warn '      Pass --agent-vision true|false explicitly (SKILL_IMPROVEMENT_PLAN_V3 §D5).'
  warn '=' * 74
  opts[:vision] = true
end

# ── blind-grade/v2: computed verdict, optional second grader, catalog ────────
if v2_mode
  if opts[:no_vision_waiver]
    abort 'FATAL: --blind-grade and --no-vision-waiver are mutually exclusive — a grade exists, so no waiver applies.'
  end
  catalog_path = File.expand_path('../refs/sigma-platform-differences.json', __dir__)
  catalog = BlindGrade.load_catalog(catalog_path)
  if catalog['errors'].any?
    warn "REFUSED: blind-grade/v2 catalog #{catalog_path} is unusable:"
    catalog['errors'].each { |e| warn "         - #{e}" }
    warn '         Nothing was written.'
    exit 2
  end

  grade_paths = [opts[:blind_grade], opts[:blind_grade_2]].compact
  grades = []
  grade_paths.each do |gp|
    res = BlindGrade.load_and_validate(gp, workdir: opts[:dir], catalog: catalog)
    if res['errors'].any?
      warn "REFUSED: blind grade #{gp} is invalid — a verdict cannot rest on it:"
      res['errors'].each { |e| warn "         - #{e}" }
      warn '         Re-run the context-free grader (refs/blind-grader-brief.md) against the CURRENT images'
      warn '         and the CURRENT catalog, then re-record. Nothing was written.'
      exit 2
    end
    if res['doc']['schema'].to_s != BlindGrade::SCHEMA_V2
      warn "REFUSED: #{gp} is #{res['doc']['schema'].to_s.empty? ? 'a schema-less (v1)' : res['doc']['schema']} grade — both grades must be #{BlindGrade::SCHEMA_V2}."
      warn '         Mixed schemas cannot be averaged. Nothing was written.'
      exit 2
    end
    grades << res['doc']
  end
  docs = grades
  if docs.length == 2
    real = grade_paths.map { |gp| (File.realpath(gp) rescue File.expand_path(gp)) }
    if real[0] == real[1] || BlindGrade.sha256(grade_paths[0]) == BlindGrade.sha256(grade_paths[1])
      warn "REFUSED: --blind-grade and --blind-grade-2 are the same grade (#{real[0] == real[1] ? 'same file' : 'identical bytes'}) —"
      warn '         the second grade must be an independent run of the brief by a fresh grader. Nothing was written.'
      exit 2
    end
    unless BlindGrade.faithful([docs[0]], catalog)['needs_second']
      warn "REFUSED: --blind-grade-2 given but the first grade alone is not borderline (score #{docs[0]['overall_score']}, " \
           "outside ±#{BlindGrade::BORDERLINE} of #{BlindGrade::PASS_SCORE}) — a second grade is only taken when the first"
      warn '         is within the borderline band; it cannot rescue or sink a clear grade. Nothing was written.'
      exit 2
    end
    %w[source_sha256 target_sha256].each do |k|
      next if docs[0][k].to_s.downcase == docs[1][k].to_s.downcase
      warn "REFUSED: the two blind grades disagree on #{k} (#{docs[0][k].to_s[0, 12]}… vs #{docs[1][k].to_s[0, 12]}…) —"
      warn '         both graders must have graded the SAME image pair. Nothing was written.'
      exit 2
    end
  end
  crosses = docs.map { |d| census_cross_check!(opts[:dir], d) }
  # Stamp the first grade's cross-check, unless a later grade needed the KPI-band rule.
  cross = crosses.find { |c| c.values.any? { |v| v.to_s.include?('KPI strip read as a band') } } || crosses.first

  decision = BlindGrade.faithful(docs, catalog)
  if decision['needs_second']
    warn "REFUSED: second blind grader required (score within ±#{BlindGrade::BORDERLINE} of #{BlindGrade::PASS_SCORE}) — " \
         "the first grade scored #{decision['score']}; a pass is never recorded on one borderline grade."
    warn '         Spawn a SECOND fresh context-free grader with the SAME brief (refs/blind-grader-brief.md), giving'
    warn '         it OUT_JSON=blind-grade-2.json and no knowledge of the first grade, then re-run this exact'
    warn '         command with --blind-grade-2 <workdir>/blind-grade-2.json. The decision uses the mean score.'
    warn '         Nothing was written.'
    exit 2
  end
  computed = decision['faithful'] ? 'pass' : 'divergent'
  if opts[:verdict] && opts[:verdict] != computed
    warn "REFUSED: --verdict #{opts[:verdict]} contradicts the blind-grade/v2 rule — the computed verdict is #{computed.upcase} " \
         "(score #{decision['score']}, pass bar #{BlindGrade::PASS_SCORE})."
    decision['reasons'].each { |r| warn "         - #{r}" }
    warn '         The verdict is computed from the grade(s), not chosen. Nothing was written.'
    exit 2
  end
  opts[:verdict] = computed
  if computed == 'pass' && !opts[:vision]
    warn 'REFUSED: a pass verdict requires an agent that actually read the render. ' \
         'Record --verdict not-executable instead, or re-run the visual loop from a ' \
         'vision-capable session (Claude Code with image input).'
    exit 2
  end
  anchors_guard!(opts[:dir]) if computed == 'pass'
  fidelity_stamp = bind_fidelity!(opts, docs[0])
  derived_cl = CHECKLIST_KEYS.map do |k|
    [k, docs.all? { |d| d.dig('dimensions', k, 'verdict') == 'pass' } ? 'pass' : 'fail']
  end.to_h
  if opts[:checklist]
    bad = opts[:checklist].select { |k, v| (derived_cl[k] == 'pass' ? %w[pass na] : %w[fail]).include?(v) == false }
    if bad.any?
      warn "REFUSED: --checklist contradicts the blind grade's dimensions: " \
           "#{bad.map { |k, v| "#{k}=#{v} (grade says #{derived_cl[k]})" }.join(', ')}."
      warn '         The checklist is derived from the grade; omit --checklist or make it agree. Nothing was written.'
      exit 2
    end
    opts[:checklist] = derived_cl.merge(opts[:checklist])
  else
    opts[:checklist] = derived_cl
  end

  grade_stamps = grade_paths.zip(docs).map do |gp, d|
    { 'path' => stamp_path(gp, opts[:dir]), 'sha256' => BlindGrade.sha256(gp), 'overall_score' => d['overall_score'] }
  end
  blind_stamp = {
    'schema'         => BlindGrade::SCHEMA_V2,
    'path'           => grade_stamps[0]['path'],
    'source_sha256'  => docs[0]['source_sha256'].to_s.downcase,
    'target_sha256'  => docs[0]['target_sha256'].to_s.downcase,
    'verdict'        => decision['faithful'] ? 'pass' : 'fail',
    'score'          => decision['score'],
    'faithful'       => decision['faithful'],
    'dimensions'     => CHECKLIST_KEYS.map { |k| [k, opts[:checklist][k]] }.to_h,
    'per_tile_count' => Array(docs[0]['per_tile']).length,
    'top_gaps'       => docs.flat_map { |d| Array(d['gaps']) }
                            .select { |g| g['class'].to_s == 'fixable' }.map { |g| g['description'] }.first(3),
    'cross_check'    => cross,
    'catalog_sha256' => catalog['sha256'],
    'catalog_path'   => stamp_path(catalog_path, opts[:dir]),
    'grades'         => grade_stamps,
    'recorded_at'    => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  }
  blind_stamp['fidelity_render'] = fidelity_stamp if fidelity_stamp
  # A grade made against an ANCESTOR catalog (the catalog only gained entries
  # since) was accepted as graded: its gaps are kept exactly, never re-mapped
  # onto a new id. Name the lineage and the new entries a re-grade could use.
  compats = docs.map { |d| BlindGrade.catalog_compat(d['catalog_sha256'], catalog) }
  lineage = nil
  if compats.any? { |c| c['status'] == 'ancestor' }
    lineage = { 'graded_catalog_sha256' => compats.map { |c| c['graded_sha256'] },
                'new_ids' => compats.flat_map { |c| c['new_ids'] }.uniq,
                'regrade' => 'optional — the grade stands as graded; re-grade against the shipped catalog only to let the grader cite new_ids' }
    blind_stamp['catalog_lineage'] = lineage
  end

  path = parity_path!(opts[:dir])
  residuals = {
    'schema'               => 'visual-residuals/v1',
    'catalog_sha256'       => catalog['sha256'],
    'grades'               => grade_stamps,
    'score'                => decision['score'],
    'faithful'             => decision['faithful'],
    'platform_differences' => decision['platform_differences'],
    'residuals'            => decision['residuals'],
    'fixable_major'        => decision['fixable_major'],
    'reasons'              => decision['reasons']
  }
  residuals['catalog_lineage'] = lineage if lineage
  s = JSON.parse(File.read(path))
  s['visual_verdict']  = computed
  s['visual_notes']    = opts[:notes] if opts[:notes]
  s['visual_checked']  = (computed == 'pass')
  s['screenshot_path'] = opts[:shot] if opts[:shot]
  s['style_checklist'] = opts[:checklist]
  s['blind_grade']     = blind_stamp
  s.delete('blind_grade_waiver')
  s['agent_vision']    = opts[:vision]
  File.write(path, JSON.pretty_generate(s))
  File.write(File.join(opts[:dir], 'visual-residuals.json'), JSON.pretty_generate(residuals) + "\n")

  if computed == 'pass'
    puts "[OK] recorded visual comparison: PASS (blind-grade/v2 score #{decision['score']}, " \
         "#{docs.length} grade#{docs.length == 1 ? '' : 's'})#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
    puts "     cross-check target=#{cross['target']}, source=#{cross['source']}; catalog sha-bound #{catalog['sha256'][0, 12]}…"
    puts "     #{decision['platform_differences'].length} platform difference(s), #{decision['residuals'].length} minor polish note(s) " \
         'listed in visual-residuals.json (not degradations — they never lower the verdict)'
  else
    puts "[RECORDED] visual comparison: DIVERGENT (blind-grade/v2 score #{decision['score']})#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
    decision['reasons'].each { |r| warn "     - #{r}" }
    warn '     recorded divergent: gate 8b passes as RECORDED; fix the gaps, re-render, re-grade with a fresh'
    warn '     grader and re-record. Gaps and reasons: visual-residuals.json.'
  end
  if lineage
    puts "NOTE: graded against an earlier catalog (#{lineage['graded_catalog_sha256'].uniq.map { |x| "#{x[0, 12]}…" }.join(', ')}); " \
         "the shipped catalog (#{catalog['sha256'][0, 12]}…) has only ADDED entries since, so the grade stands exactly as graded."
    unless lineage['new_ids'].empty?
      puts "      New platform difference(s) it could not cite: #{lineage['new_ids'].join(', ')}."
      puts '      Optional: re-run the context-free grader (refs/blind-grader-brief.md) against the shipped catalog'
      puts '      and re-record, if a fixable gap may really be one of those. Nothing requires it.'
    end
  end
  exit 0
end

if opts[:verdict] == 'pass' && !opts[:vision]
  warn 'REFUSED: a pass verdict requires an agent that actually read the render. ' \
       'Record --verdict not-executable instead, or re-run the visual loop from a ' \
       'vision-capable session (Claude Code with image input).'
  exit 2
end
if opts[:verdict] == 'not-executable' && opts[:notes].to_s.strip.empty?
  abort 'FATAL: --verdict not-executable requires --notes (say WHY the visual loop could not run).'
end
# v5.3: a PASS must attest every style dimension; any 'fail' means the render
# does NOT match the source — record divergent and fix instead.
if opts[:verdict] == 'pass'
  cl = opts[:checklist]
  if cl.nil?
    warn 'REFUSED: --verdict pass now requires --checklist (round-5: gestalt passes shipped exposed'
    warn "         chrome/broken palettes an exacting owner rejected). Provide all of:"
    warn "         --checklist \"#{CHECKLIST_KEYS.map { |k| "#{k}=pass" }.join(',')}\""
    warn '         judging each against the SOURCE image; use fail/na honestly (fail ⇒ record divergent).'
    exit 2
  end
  missing = CHECKLIST_KEYS - cl.keys
  bad_vals = cl.reject { |_k, v| CHECKLIST_VALS.include?(v) }
  abort "FATAL: --checklist missing key(s): #{missing.join(', ')}" if missing.any?
  abort "FATAL: --checklist value(s) must be pass|fail|na: #{bad_vals.keys.join(', ')}" if bad_vals.any?
  fails = cl.select { |k, v| CHECKLIST_KEYS.include?(k) && v == 'fail' }.keys
  if fails.any?
    warn "REFUSED: checklist marks #{fails.join(', ')} = fail — that is a DIVERGENT render, not a pass."
    warn '         Record --verdict divergent with the same checklist, fix, re-render, re-judge.'
    exit 2
  end
  # W1.4 contradiction guard (shared with the v2 path): see anchors_guard!.
  anchors_guard!(opts[:dir])
end

# ── PR-9: blind-grader precondition for a PASS ───────────────────────────────
# The builder's own eye (the checklist above) is necessary but NOT sufficient:
# a pass verdict must be countersigned by a context-free blind grade.
blind_stamp = nil
waiver_stamp = nil
if opts[:no_vision_waiver] && opts[:verdict] != 'pass'
  abort 'FATAL: --no-vision-waiver only applies to --verdict pass (other verdicts need no blind grade).'
end
if opts[:blind_grade] && opts[:no_vision_waiver]
  abort 'FATAL: --blind-grade and --no-vision-waiver are mutually exclusive — a grade exists, so no waiver applies.'
end
if opts[:no_vision_waiver] && opts[:no_vision_waiver].to_s.strip.empty?
  abort 'FATAL: --no-vision-waiver requires a non-empty reason (WHY could no vision-capable grader be spawned?).'
end
if opts[:verdict] == 'pass' && opts[:blind_grade].nil? && opts[:no_vision_waiver].nil?
  warn 'REFUSED: --verdict pass now requires --blind-grade <path> (PLAN-v3 PR-9). The visual verdict'
  warn '         must come from a CONTEXT-FREE grader, not the builder: a field run self-graded its own'
  warn '         workbook 6/6 PASS on visuals the customer rejected. The blind flow:'
  warn '           1. Spawn a FRESH subagent with refs/blind-grader-brief.md as its prompt, giving it'
  warn '              ONLY the source dashboard PNG path, the Sigma render PNG path, the rubric path'
  warn '              (refs/fidelity-rubric.md), and an output path — NO wb-spec, NO run history, NO'
  warn '              builder context.'
  warn '           2. It Reads both images and writes blind-grade.json (sha256-bound, per-dimension'
  warn '              verdicts, per-tile chart families, top gaps).'
  warn '           3. Re-run this exact command with --blind-grade <workdir>/blind-grade.json.'
  warn '         If the blind grade FAILS, the render diverges — record --verdict divergent and fix.'
  warn '         Escape ONLY when no vision-capable context-free grader can be spawned in this session:'
  warn '         --no-vision-waiver "<reason>" (recorded + counted against the waiver budget, never silent).'
  exit 2
end
if opts[:blind_grade]
  res = BlindGrade.load_and_validate(opts[:blind_grade], workdir: opts[:dir])
  if res['errors'].any?
    warn "REFUSED: blind grade #{opts[:blind_grade]} is invalid — a pass cannot rest on it:"
    res['errors'].each { |e| warn "         - #{e}" }
    warn '         Re-run the context-free grader (refs/blind-grader-brief.md) against the CURRENT images'
    warn '         and re-record. Nothing was written.'
    exit 2
  end
  grade = res['doc']
  # A blind grade is evidence for exactly ONE rendered image. When the RCF
  # ledger exists, require that image to be both the explicitly selected final
  # screenshot and the latest budgeted fidelity render. This closes two field
  # escapes: grading an intermediate PNG and then exporting a different
  # "final" image, and bypassing the RCF pass budget with direct PNG exports.
  fidelity_stamp = bind_fidelity!(opts, grade)
  dim_fails = grade['dimensions'].select { |_k, v| v['verdict'].to_s == 'fail' }.keys
  if opts[:verdict] == 'pass' && (grade['verdict'] != 'pass' || dim_fails.any?)
    warn "REFUSED: the blind grader's verdict is FAIL#{dim_fails.any? ? " (failing: #{dim_fails.join(', ')})" : ''} —"
    warn '         a builder pass over a failing blind grade is exactly the self-grading escape this'
    warn '         flow closes. Top gaps from the blind grade:'
    Array(grade['top_gaps']).first(3).each { |g| warn "           - #{g}" }
    warn '         Record --verdict divergent, fix the gaps, re-render, re-run the blind grader, then'
    warn '         re-record pass with the new grade. Nothing was written.'
    exit 2
  end
  # Anti-gaming cross-check: the grader's per-tile family readings must agree
  # with the mechanical kind census. >MAX_FAMILY_MISMATCHES contradictions on
  # either side = the families were not read off the images → fabricated grade.
  cross = census_cross_check!(opts[:dir], grade)
  bg_path = opts[:blind_grade]
  bg_rel  = bg_path.start_with?(File.join(opts[:dir], '')) ? bg_path[(File.join(opts[:dir], '').length)..-1] : bg_path
  blind_stamp = {
    'path'           => bg_rel,
    'source_sha256'  => grade['source_sha256'].to_s.downcase,
    'target_sha256'  => grade['target_sha256'].to_s.downcase,
    'verdict'        => grade['verdict'],
    'dimensions'     => grade['dimensions'].map { |k, v| [k, v['verdict']] }.to_h,
    'per_tile_count' => Array(grade['per_tile']).length,
    'top_gaps'       => Array(grade['top_gaps']).first(3),
    'cross_check'    => cross,
    'recorded_at'    => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  }
  blind_stamp['fidelity_render'] = fidelity_stamp if fidelity_stamp
elsif opts[:no_vision_waiver]
  waiver_stamp = { 'kind' => 'no-vision-grader', 'reason' => opts[:no_vision_waiver].strip,
                   'recorded_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
end

path = parity_path!(opts[:dir])

s = JSON.parse(File.read(path))
s['visual_verdict']  = opts[:verdict]
s['visual_notes']    = opts[:notes] if opts[:notes]
s['visual_checked']  = (opts[:verdict] == 'pass')
s['screenshot_path'] = opts[:shot] if opts[:shot]
s['style_checklist'] = opts[:checklist] if opts[:checklist]
s['blind_grade'] = blind_stamp if blind_stamp
s['blind_grade_waiver'] = waiver_stamp if waiver_stamp
s.delete('blind_grade') if waiver_stamp && !blind_stamp
s.delete('blind_grade_waiver') if blind_stamp && !waiver_stamp
# not-executable means the driving agent could not read the render — stamp
# agent_vision:false regardless of the flag so gate 8b sees the degradation.
s['agent_vision']    = opts[:verdict] == 'not-executable' ? false : opts[:vision]
File.write(path, JSON.pretty_generate(s))
# A v1 grade / not-executable / waiver is not a v2 computation: a visual-residuals.json
# left by an earlier v2 record would be stale evidence the ledger still reads.
FileUtils.rm_f(File.join(opts[:dir], 'visual-residuals.json'))

case opts[:verdict]
when 'pass'
  puts "[OK] recorded visual comparison: PASS#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
  if blind_stamp
    puts "     blind grade: PASS (#{blind_stamp['path']}; sha-bound src=#{blind_stamp['source_sha256'][0, 12]}… " \
         "tgt=#{blind_stamp['target_sha256'][0, 12]}…; cross-check target=#{blind_stamp['cross_check']['target']}, " \
         "source=#{blind_stamp['cross_check']['source']})"
  else
    warn '=' * 74
    warn 'WARN: pass recorded under a NO-VISION-GRADER WAIVER — no context-free blind'
    warn "      grade backs this verdict (reason: #{waiver_stamp['reason']})."
    warn '      This waiver COUNTS against the gate waiver budget and MUST be named in'
    warn '      the migration report. Prefer re-running from a session that can spawn a'
    warn '      vision-capable grader (refs/blind-grader-brief.md).'
    warn '=' * 74
  end
  puts "     parity-final.json now satisfies assert-phase6-ran.rb gate 8b."
when 'divergent'
  puts "[RECORDED] visual comparison: DIVERGENT#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
  warn '     recorded divergent: gate 8b passes as RECORDED; it is not a waiver (no waiver-budget cost)'
  warn '     but it forfeits GREEN — the degradation ledger records a fidelity-residual, so the run is'
  warn '     at most YELLOW. Fix the gaps, re-render, re-read, then re-record --verdict pass — or'
  warn '     accept YELLOW with the divergence named in the report.'
else # not-executable
  puts "[RECORDED] visual comparison: NOT-EXECUTABLE — #{opts[:notes]}"
  warn '     visual_checked stays FALSE, agent_vision=false — gate 8b will fail with'
  warn '     "visual gate not executable" until the RCF/visual loop is re-run from a'
  warn '     vision-capable session (Claude Code with image input) and a pass verdict'
  warn '     is recorded, or the gate is explicitly waived (--skip-visual-comparison "<reason>").'
end
