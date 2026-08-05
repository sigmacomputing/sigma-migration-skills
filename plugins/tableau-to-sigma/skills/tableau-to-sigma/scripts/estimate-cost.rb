#!/usr/bin/env ruby
# frozen_string_literal: true
#
# estimate-cost.rb — scope + agent-cost estimate for a Tableau→Sigma conversion
# (PLAN-v3 PR-3: the scope/cost SIGN-OFF artifact).
#
# Two modes:
#
#   WORKDIR MODE (the orchestrator seam — migrate-tableau.rb runs this right
#   after the Phase-1 join, i.e. once discovery metadata + the gap scan exist
#   and BEFORE any DM build/POST):
#     ruby scripts/estimate-cost.rb --workdir <WORK> [--out <path>]
#   Reads whatever scoping artifacts the workdir has (each one optional — a
#   missing input degrades the estimate and is NAMED in inputs.missing, never
#   a crash):
#     get-workbook.json       view inventory            (tableau-discover.rb)
#     dashboard-layout.json   zone tree → tile count    (parse-twb-layout.rb)
#     calc-fields.json        calc classes              (extract-calc-fields.rb)
#     *-gaps-report.json      gap classes / ❌-unhandled (scan-workbook-gaps.rb)
#     custom-sql.json         custom-SQL blocks         (extract-custom-sql.rb)
#   Writes <WORK>/cost-estimate.json (default) and prints a one-line summary.
#
#   LEGACY PRE-SCOPING MODE (Phase 0, before any discovery — refs/phase-0-scope.md):
#     ruby scripts/estimate-cost.rb --workbook <get-workbook.json> [--datasource <metadata.json>]
#   Same estimator over the thinner pre-fetch signals (tile count proxied by
#   the sheet count); JSON to stdout, or to --out when given.
#
# ── CALIBRATION (2026-07 · n=3 clean e2e runs + 3 field sessions) ───────────
# Anchors — three recent clean end-to-end runs (orchestrated spine, manual DM
# path, measured turn counts):
#   run A: 7 tiles → ~60 agent turns, ~48 min wall   (0.80 min/turn)
#   run B: 5 tiles → ~75 agent turns, ~40 min wall   (0.53 min/turn)
#   run C: 6 tiles → ~80 agent turns, ~71 min wall   (0.89 min/turn)
#   → mean ≈ 72 turns / ≈ 53 min for a clean 5–7-tile workbook.
# The three field sessions (2026-07-17, heavy-failure runs — docs/PLAN-v3.md)
# each ran ~4 h, ≈ 4–5× the clean-run wall clock, dominated by ❌-unhandled
# features, scout loops, and rework. That multiplier is carried as a LARGE
# per-unhandled-gap-class turn penalty (PER_UNHANDLED_CLASS_TURNS), not as a
# fitted coefficient.
#
# HONESTY NOTE: with n=3 the tile count does not identify a slope — turns vs
# tiles is flat-to-negative in the sample (7→60, 5→75, 6→80). So the model
# deliberately centers on the anchor MEAN: a large BASE_TURNS plus small
# per-feature increments that are stated PRIORS, not regression fits. Treat
# every coefficient as ±30% at best; every estimate is emitted with
# confidence: "rough". The PLAN-v3 PR-3 goal is a recorded sign-off artifact,
# not precision — re-fit once per-run telemetry accumulates ~10 measured
# conversions.
#
# Tokens-per-turn ASSUMPTION (no per-turn token telemetry exists yet): an
# orchestrated migration turn replays conversation + tool results in a
# mid-size context, assumed ≈ 12,000 input tokens and ≈ 900 output tokens per
# turn on average. Wall clock: measured 0.80 / 0.53 / 0.89 min per turn →
# 0.75 min/turn assumed.
#
# ── W2.22: MEASURED REFIT (--from-metrics) ──────────────────────────────────
# The calibration loop closes here: pass measured-run workdirs (each carrying
# a <WORK>/phase-metrics.jsonl written by the orchestrator's mark() hook) and
# the estimator re-fits its rate/phase-split coefficients from data instead of
# the n=3 priors above. Every output then carries a PROVENANCE header naming
# which coefficients are measured (with n + range) and which stayed priors.
# Refit refuses low-n per coefficient (< MIN_FIT_RUNS): a refused refit keeps
# priors and NAMES the refusal — never a fit from a single flattering run.
# Runs whose metrics predate turn capture (no `turn` keys) contribute wall
# clock only; a min/turn rate is never derived from them (nil ≠ 0).
#
# Standalone (no --workdir/--workbook): prints + optionally writes the
# calibration/band report — per-tier bands published ONLY at n ≥ MIN_FIT_RUNS
# per tier, as {n, range, rate}; below that the band is REFUSED by name.
# Hygiene: run stats are keyed run-1..run-N; workdir paths are NOT written
# into the report (numbers + neutral labels only).
#
# Usage:
#   ruby scripts/estimate-cost.rb --workdir <WORK> [--out <path>]
#     [--from-metrics <dir1,dir2,…>]     # refit coefficients, then estimate
#   ruby scripts/estimate-cost.rb --workbook <get-workbook.json> [--datasource <metadata.json>]
#   ruby scripts/estimate-cost.rb --from-metrics <dir1,dir2,…> [--out <path>]
#     # standalone: fit + per-tier measured bands (repeatable / comma-separated)

require 'json'
require 'optparse'
require 'time'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
begin
  require 'phase_metrics'
rescue LoadError
  nil # measured refit degrades to priors (named in provenance); estimation unaffected
end

module EstimateCost
  # Turn-model coefficients — see the CALIBRATION block above for provenance.
  BASE_TURNS                = 62.0   # anchor-mean centering (clean 5–7-tile run ≈ 72 turns)
  PER_TILE_TURNS            = 1.6    # prior, NOT a fit — the n=3 sample shows no tile slope
  PER_CALC_SIMPLE_TURNS     = 0.3    # mechanically translated; near-zero marginal cost
  PER_CALC_COMPLEX_TURNS    = 1.2    # LOD / multi-branch: verify + occasional rework
  PER_CUSTOM_SQL_TURNS      = 2.5    # each custom-SQL block / window residue is hand-built
  PER_UNHANDLED_CLASS_TURNS = 25.0   # per ❌-unhandled gap class (field sessions ≈ 4–5× clean)
  TOKENS_IN_PER_TURN        = 12_000 # stated assumption — no measured per-turn telemetry yet
  TOKENS_OUT_PER_TURN       = 900    # stated assumption
  MINUTES_PER_TURN          = 0.75   # measured 0.80 / 0.53 / 0.89 min per turn
  MIN_FIT_RUNS              = 3      # W2.22: a coefficient refit / published band needs ≥ this n

  # Rough phase split of a clean orchestrated run (fractions of total turns).
  PHASE_SPLIT = {
    'phase-0-scope'            => 0.05,
    'phase-1-discover'         => 0.15,
    'phase-2-3-data-model'     => 0.20,
    'phase-4-5-workbook-layout' => 0.35,
    'phase-6-parity-verify'    => 0.25
  }.freeze

  CALIBRATION_NOTE =
    'Anchors: 3 clean e2e runs 2026-07 (~60 turns/48 min/7 tiles, ~75/40/5, ~80/71/6; manual DM ' \
    'path) + 3 field sessions ~4 h heavy-failure (docs/PLAN-v3.md). n=3: coefficients are ' \
    'anchor-centered priors, not fits. Assumed 12k input / 0.9k output tokens per turn.'

  # ── W2.22: measured-run ingestion + coefficient refit ──────────────────────
  # Coarse map from the orchestrator's PHASE_T keys (phase-metrics.jsonl
  # `phase` values) onto the estimator's PHASE_SPLIT buckets. Coarse on
  # purpose; unmapped keys land in 'other' rather than being guessed.
  PHASE_BUCKET_RULES = [
    [/\Aphase0|\Adecisions\z|\Afolder-resolve\z/, 'phase-0-scope'],
    [/\Aphase1|\Ajoin-wait\z/,                    'phase-1-discover'],
    [/\Aphase2|\Aphase3/,                         'phase-2-3-data-model'],
    [/\Aphase4|\Aphase5/,                         'phase-4-5-workbook-layout'],
    [/\Aphase6|\Aassert|\Acleanup|\AphaseE\z|\Apivot/, 'phase-6-parity-verify']
  ].freeze

  def self.bucket_for_phase(key)
    rule = PHASE_BUCKET_RULES.find { |(re, _)| key.to_s =~ re }
    rule ? rule[1] : 'other'
  end

  def self.median(arr)
    s = arr.sort
    return nil if s.empty?
    m = s.size / 2
    s.size.odd? ? s[m] : ((s[m - 1] + s[m]) / 2.0)
  end

  # One measured run's mechanical stats (nil where a capture is absent —
  # never guessed). Returns {'error' => reason} when the dir yields nothing.
  # Hygiene: the returned hash carries NO paths/names — numbers + tier only.
  def self.measured_run(dir)
    return { 'error' => 'workdir not found' } unless File.directory?(dir.to_s)
    return { 'error' => 'phase_metrics lib unavailable' } unless defined?(PhaseMetrics)
    stats = PhaseMetrics.run_stats(dir)
    return { 'error' => 'no phase-metrics.jsonl records' } if stats['records'].to_i.zero?
    tier = begin
      JSON.parse(File.read(File.join(dir, 'migrate-state.json')))['tier']
    rescue StandardError
      nil
    end
    wall_min = (stats['wall_s_total'].to_f / 60.0).round(2)
    turns = stats['turn_events']
    phase_wall = Hash.new(0.0)
    PhaseMetrics.aggregate(dir).each { |k, a| phase_wall[bucket_for_phase(k)] += a['wall_s'].to_f }
    {
      'tier'             => (tier || 'untagged').to_s,
      'wall_minutes'     => wall_min,
      'turn_events'      => turns,
      'invocations'      => stats['invocations'],
      're_entries'       => stats['re_entries'],
      'tokens_total'     => stats['tokens_total'],
      'minutes_per_turn' => (turns && turns.positive? ? (wall_min / turns).round(3) : nil),
      'phase_wall_s'     => phase_wall.transform_values { |v| v.round(1) }
    }
  end

  # dirs → [run stats] keyed run-1..run-N in argument order (no paths kept).
  def self.measured_runs(dirs)
    Array(dirs).each_with_index.map do |d, i|
      measured_run(d).merge('run' => "run-#{i + 1}")
    end
  end

  # Refit: median rate + mean phase split, each refused by name below
  # MIN_FIT_RUNS. Returns { 'minutes_per_turn' => {...}, 'phase_split' => {...},
  # 'tokens_per_turn_total' => {...}|nil, 'refused' => [...] }.
  def self.fit_from_runs(runs)
    ok = runs.reject { |r| r['error'] }
    refused = runs.select { |r| r['error'] }.map { |r| "#{r['run']}: #{r['error']}" }
    fit = { 'refused' => refused }

    rates = ok.map { |r| r['minutes_per_turn'] }.compact
    fit['minutes_per_turn'] =
      if rates.size >= MIN_FIT_RUNS
        { 'value' => median(rates).round(3), 'n' => rates.size,
          'min' => rates.min, 'max' => rates.max, 'source' => 'measured' }
      else
        refused << "minutes_per_turn: low-n (#{rates.size} turn-capturing run(s) < #{MIN_FIT_RUNS}) — priors retained"
        { 'value' => MINUTES_PER_TURN, 'n' => rates.size, 'source' => 'priors' }
      end

    splits = ok.map { |r| r['phase_wall_s'] }.select { |pw| pw.values.sum.positive? }
    fit['phase_split'] =
      if splits.size >= MIN_FIT_RUNS
        buckets = splits.flat_map(&:keys).uniq
        mean = buckets.to_h do |b|
          [b, splits.map { |pw| pw[b].to_f / pw.values.sum }.sum / splits.size]
        end
        norm = mean.values.sum
        { 'value' => mean.transform_values { |v| (v / norm).round(3) },
          'n' => splits.size, 'source' => 'measured' }
      else
        refused << "phase_split: low-n (#{splits.size} run(s) with phase walls < #{MIN_FIT_RUNS}) — priors retained"
        { 'value' => PHASE_SPLIT, 'n' => splits.size, 'source' => 'priors' }
      end

    # Token totals are captured per-run but not split in/out — reported as
    # measured INFO, never silently substituted into the in/out assumption.
    tok = ok.select { |r| r['tokens_total'] && r['turn_events'].to_i.positive? }
    if tok.size >= MIN_FIT_RUNS
      per = tok.map { |r| (r['tokens_total'].to_f / r['turn_events']).round(0) }
      fit['tokens_per_turn_total'] =
        { 'value' => median(per).round(0), 'n' => per.size, 'min' => per.min, 'max' => per.max,
          'source' => 'measured', 'note' => 'total per turn — in/out split remains the stated assumption' }
    end
    fit
  end

  # Per-tier measured bands. A band is PUBLISHED only at n ≥ MIN_FIT_RUNS for
  # that tier; below that it is refused BY NAME (observations stated, never
  # banded — "a single flattering minute is not a band").
  def self.tier_bands(runs)
    runs.reject { |r| r['error'] }.group_by { |r| r['tier'] }.to_h do |tier, rs|
      walls = rs.map { |r| r['wall_minutes'] }
      turns = rs.map { |r| r['turn_events'] }.compact
      rates = rs.map { |r| r['minutes_per_turn'] }.compact
      band =
        if rs.size < MIN_FIT_RUNS
          { 'refused' => "low-n (n=#{rs.size} < #{MIN_FIT_RUNS}) — no band published",
            'n' => rs.size, 'observed_wall_minutes' => walls.sort }
        else
          { 'n' => rs.size,
            'wall_minutes' => { 'min' => walls.min, 'median' => median(walls).round(2), 'max' => walls.max },
            'turns' => (turns.size >= MIN_FIT_RUNS ?
              { 'n' => turns.size, 'min' => turns.min, 'median' => median(turns).round(1), 'max' => turns.max } :
              { 'refused' => "low-n (#{turns.size} turn-capturing run(s) < #{MIN_FIT_RUNS})" }),
            'rate_min_per_turn' => (rates.size >= MIN_FIT_RUNS ?
              { 'n' => rates.size, 'min' => rates.min, 'median' => median(rates).round(3), 'max' => rates.max } :
              { 'refused' => "low-n (#{rates.size} turn-capturing run(s) < #{MIN_FIT_RUNS})" }) }
        end
      [tier, band]
    end
  end

  # One-line provenance header for stdout — states measured-vs-priors + n.
  def self.provenance_line(fit)
    mpt = fit && fit['minutes_per_turn']
    if mpt && mpt['source'] == 'measured'
      "[calibration] coefficients: MEASURED — minutes_per_turn #{mpt['value']} " \
      "(median, n=#{mpt['n']}, range #{mpt['min']}–#{mpt['max']}) · fitted from phase-metrics.jsonl"
    else
      n = mpt ? mpt['n'] : 0
      "[calibration] coefficients: PRIORS (n=3 anchors, ±30%)" +
        (fit ? " — measured refit refused: #{n} usable turn-capturing run(s) < #{MIN_FIT_RUNS}" :
               ' — no measured runs supplied (--from-metrics)')
    end
  end

  # "Complex" = an LOD, or a multi-branch IF chain (≥2 ELSEIF, counted directly
  # — O(n); the old two-bridge regex catastrophically backtracked on real formulas).
  def self.complex_formula?(fml)
    f = fml.to_s
    f.match?(/\{\s*(FIXED|INCLUDE|EXCLUDE)/i) ||
      (f.match?(/\bIF\b/i) && f.scan(/\bELSEIF\b/i).length >= 2)
  end

  def self.read_json(path)
    JSON.parse(File.read(path))
  rescue StandardError
    nil
  end

  # ── Scope collection: workdir mode ─────────────────────────────────────────
  # Returns { 'scope' => {...}, 'present' => [...], 'missing' => [{artifact, provides}] }.
  # Every input is optional; a missing one is named, and its scope fields stay nil.
  def self.scope_from_workdir(dir)
    present = []
    missing = []
    scope = {}
    workbook_name = nil

    gw_path = File.join(dir, 'get-workbook.json')
    gw = File.exist?(gw_path) ? read_json(gw_path) : nil
    if gw
      wb = gw['workbook'] || gw
      workbook_name = wb['name']
      views = wb.dig('views', 'view') || wb['views'] || []
      views = [views] unless views.is_a?(Array)
      scope['dashboards'] = views.count { |v| (v['sheetType'] || '').to_s.downcase.include?('dashboard') }
      scope['sheets']     = views.size - scope['dashboards']
      present << 'get-workbook.json'
    else
      missing << { 'artifact' => 'get-workbook.json',
                   'provides' => 'view inventory (tableau-discover.rb)' }
    end

    dl_path = File.join(dir, 'dashboard-layout.json')
    dl = File.exist?(dl_path) ? read_json(dl_path) : nil
    if dl
      zones = dl.is_a?(Array) ? dl.flat_map { |d| d['zones'] || [] } : (dl['zones'] || [])
      scope['tiles']       = zones.count { |z| z['kind'] == 'chart' }
      scope['zones_total'] = zones.size
      present << 'dashboard-layout.json'
    else
      missing << { 'artifact' => 'dashboard-layout.json',
                   'provides' => 'zone tree / tile count (parse-twb-layout.rb)' }
    end

    cf_path = File.join(dir, 'calc-fields.json')
    cf = File.exist?(cf_path) ? read_json(cf_path) : nil
    if cf
      calcs = cf['calcs'] || []
      residue = calcs.count { |c| c['requires_custom_sql'] }
      complex = calcs.count { |c| !c['requires_custom_sql'] && (c['is_lod'] || complex_formula?(c['formula'])) }
      scope['calcs'] = {
        'total'               => calcs.size,
        'simple'              => calcs.size - complex - residue,
        'complex'             => complex,
        'requires_custom_sql' => residue
      }
      present << 'calc-fields.json'
    else
      missing << { 'artifact' => 'calc-fields.json',
                   'provides' => 'calc-field classes (extract-calc-fields.rb)' }
    end

    gj_path = Dir[File.join(dir, '*gaps*report*.json')].first || Dir[File.join(dir, '*gaps*.json')].first
    gj = gj_path ? read_json(gj_path) : nil
    if gj
      feats = gj['detected_features'] || []
      scope['gap_classes'] = feats.group_by { |f| f['status'].to_s }
                                  .each_with_object({}) { |(k, v), h| h[k] = v.size }
      scope['untranslatable_classes'] = feats.select { |f| f['status'].to_s == 'unhandled' }
                                             .map { |f| f['name'].to_s }
      present << File.basename(gj_path)
    else
      missing << { 'artifact' => '*-gaps-report.json',
                   'provides' => 'gap classes / untranslatable features (scan-workbook-gaps.rb)' }
    end

    cs_path = File.join(dir, 'custom-sql.json')
    cs = File.exist?(cs_path) ? read_json(cs_path) : nil
    if cs.is_a?(Array)
      scope['custom_sql_blocks'] = cs.size
      present << 'custom-sql.json'
    else
      missing << { 'artifact' => 'custom-sql.json',
                   'provides' => 'custom-SQL block count (extract-custom-sql.rb)' }
    end

    { 'workbook' => workbook_name, 'scope' => scope,
      'present' => present, 'missing' => missing }
  end

  # ── Scope collection: legacy pre-scoping mode ──────────────────────────────
  def self.scope_from_prefetch(wb_json, ds_json)
    wb = wb_json['workbook'] || wb_json
    views = wb.dig('views', 'view') || wb['views'] || []
    views = [views] unless views.is_a?(Array)
    dashboards = views.count { |v| (v['sheetType'] || '').to_s.downcase.include?('dashboard') }
    sheets = views.size - dashboards
    scope = { 'dashboards' => dashboards, 'sheets' => sheets,
              # Pre-discovery there is no zone tree — the sheet count is the
              # best available tile proxy (each worksheet ≈ one plotted tile).
              'tiles' => sheets, 'tiles_proxied_from' => 'sheet count (no dashboard-layout.json yet)' }
    if ds_json
      fields = if ds_json['fieldGroups']
                 ds_json['fieldGroups'].flat_map { |g| g['fields'] || [] }
               else
                 ds_json['data'] || []
               end
      calcs = fields.select { |f| f['columnClass'] == 'CALCULATION' }
      complex = calcs.count { |f| complex_formula?(f['formula']) }
      scope['calcs'] = { 'total' => calcs.size, 'simple' => calcs.size - complex,
                         'complex' => complex, 'requires_custom_sql' => 0 }
      scope['custom_sql_blocks'] = (ds_json['customSql'].to_s.empty? ? 0 : 1)
    end
    { 'workbook' => wb['name'], 'scope' => scope, 'present' => [], 'missing' => [] }
  end

  # ── The estimator: scope → turns → tokens (+ per-phase breakdown) ──────────
  # minutes_per_turn / phase_split default to the priors; a W2.22 measured
  # refit passes fitted values in. Callers without a refit are byte-unchanged.
  def self.estimate(scope, minutes_per_turn: MINUTES_PER_TURN, phase_split: PHASE_SPLIT)
    calcs = scope['calcs'] || {}
    turns = BASE_TURNS +
            (scope['tiles'].to_i * PER_TILE_TURNS) +
            (calcs['simple'].to_i * PER_CALC_SIMPLE_TURNS) +
            (calcs['complex'].to_i * PER_CALC_COMPLEX_TURNS) +
            ((calcs['requires_custom_sql'].to_i + scope['custom_sql_blocks'].to_i) * PER_CUSTOM_SQL_TURNS) +
            ((scope['untranslatable_classes'] || []).size * PER_UNHANDLED_CLASS_TURNS)
    turns = turns.round
    input_tokens  = turns * TOKENS_IN_PER_TURN
    output_tokens = turns * TOKENS_OUT_PER_TURN
    per_phase = {}
    phase_split.each do |phase, frac|
      per_phase[phase] = {
        'turns'         => (turns * frac).round,
        'input_tokens'  => (input_tokens * frac).round,
        'output_tokens' => (output_tokens * frac).round
      }
    end
    {
      'agent_turns'       => turns,
      'input_tokens'      => input_tokens,
      'output_tokens'     => output_tokens,
      'total_tokens'      => input_tokens + output_tokens,
      'estimated_minutes' => (turns * minutes_per_turn).round,
      'complexity'        => bucket(turns),
      'per_phase'         => per_phase
    }
  end

  # Buckets feed the model-fit checkpoint (refs/model-fit.md) — keep the names.
  def self.bucket(turns)
    if turns < 50 then 'small'
    elsif turns < 110 then 'medium'
    elsif turns < 220 then 'large'
    else 'very-large'
    end
  end

  # refit: optional {'fit' =>, 'runs' =>} from --from-metrics (W2.22). When a
  # measured fit is present its coefficients drive the estimate, and the
  # calibration block carries a provenance record naming what was measured
  # (n + range per coefficient) and every refusal. Without a refit the report
  # is the priors artifact plus an explicit priors provenance stanza.
  def self.build_report(collected, source, refit: nil)
    fit = refit && refit['fit']
    est = estimate(collected['scope'],
                   minutes_per_turn: fit ? fit['minutes_per_turn']['value'] : MINUTES_PER_TURN,
                   phase_split: fit ? fit['phase_split']['value'] : PHASE_SPLIT)
    measured = fit && fit['minutes_per_turn']['source'] == 'measured'
    provenance =
      if fit
        {
          'coefficients' => (measured ? 'measured' : 'priors'),
          'fitted_from'  => "phase-metrics.jsonl of #{refit['runs'].size} run workdir(s) (paths omitted — hygiene)",
          'fitted_at'    => Time.now.utc.iso8601,
          'fit'          => fit.reject { |k, _| k == 'refused' },
          'runs'         => refit['runs'],
          'refused'      => fit['refused']
        }
      else
        { 'coefficients' => 'priors',
          'note' => 'no measured runs supplied (--from-metrics) — anchors-centered priors, see calibration.note' }
      end
    {
      'workbook'     => collected['workbook'],
      'generated_at' => Time.now.utc.iso8601,
      'confidence'   => (measured ? 'measured-rate' : 'rough'),
      'inputs'       => { 'source' => source,
                          'present' => collected['present'],
                          'missing' => collected['missing'] },
      'scope'        => collected['scope'],
      'estimate'     => est,
      'calibration'  => {
        'anchors'         => 3,
        'tokens_per_turn' => { 'input' => TOKENS_IN_PER_TURN, 'output' => TOKENS_OUT_PER_TURN },
        'note'            => CALIBRATION_NOTE,
        'provenance'      => provenance
      },
      'note' => 'Rough scope/cost sign-off artifact (PLAN-v3 PR-3) — not a quote. ' \
                'Missing inputs (inputs.missing) degrade the estimate and are named, never fatal.'
    }
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |p|
    p.on('--workdir DIR', 'estimate from a migration workdir (orchestrator seam)') { |v| opts[:dir] = v }
    p.on('--out PATH', 'write the JSON report here (workdir default: <workdir>/cost-estimate.json)') { |v| opts[:out] = v }
    p.on('--workbook PATH', 'legacy pre-scoping: get-workbook.json') { |v| opts[:wb] = v }
    p.on('--datasource PATH', 'legacy pre-scoping: datasource metadata JSON') { |v| opts[:ds] = v }
    p.on('--from-metrics DIRS', Array,
         'measured-run workdirs (comma-separated, repeatable) — W2.22 coefficient refit; ' \
         'alone: print/write the calibration + per-tier band report') { |v| (opts[:metrics] ||= []).concat(v) }
  end.parse!

  refit = nil
  if opts[:metrics]
    runs = EstimateCost.measured_runs(opts[:metrics])
    refit = { 'fit' => EstimateCost.fit_from_runs(runs), 'runs' => runs }
  end

  if opts[:dir]
    abort("[FAIL] estimate-cost: workdir not found: #{opts[:dir]}") unless File.directory?(opts[:dir])
    collected = EstimateCost.scope_from_workdir(opts[:dir])
    report = EstimateCost.build_report(collected, opts[:dir], refit: refit)
    out = opts[:out] || File.join(opts[:dir], 'cost-estimate.json')
    tmp = "#{out}.tmp"
    File.write(tmp, JSON.pretty_generate(report) + "\n")
    File.rename(tmp, out)
    puts EstimateCost.provenance_line(refit && refit['fit']) if refit
    est = report['estimate']
    puts "[OK] estimate-cost: ~#{est['agent_turns']} turns ≈ #{est['input_tokens']} in / " \
         "#{est['output_tokens']} out tokens, ~#{est['estimated_minutes']} min " \
         "(#{est['complexity']}; confidence: #{report['confidence']}) → #{out}"
    (refit ? refit['fit']['refused'] : []).each { |r| puts "     refit refused: #{r}" }
    collected['missing'].each do |m|
      puts "     degraded: missing #{m['artifact']} — #{m['provides']}"
    end
  elsif opts[:wb]
    wb_json = JSON.parse(File.read(opts[:wb]))
    ds_json = opts[:ds] ? JSON.parse(File.read(opts[:ds])) : nil
    collected = EstimateCost.scope_from_prefetch(wb_json, ds_json)
    collected['workbook'] ||= File.basename(opts[:wb], '.json')
    report = EstimateCost.build_report(collected, opts[:wb], refit: refit)
    if opts[:out]
      File.write(opts[:out], JSON.pretty_generate(report) + "\n")
      puts "[OK] estimate-cost → #{opts[:out]}"
    else
      puts JSON.pretty_generate(report)
    end
  elsif opts[:metrics]
    # ── W2.22 standalone: calibration refit + per-tier measured bands ────────
    fit  = refit['fit']
    runs = refit['runs']
    doc = {
      'kind'             => 'calibration-refit',
      'generated_at'     => Time.now.utc.iso8601,
      'runs'             => runs,
      'fit'              => fit.reject { |k, _| k == 'refused' },
      'refused'          => fit['refused'],
      'bands'            => EstimateCost.tier_bands(runs),
      'publication_rule' => "a per-tier band is published only from >= #{EstimateCost::MIN_FIT_RUNS} " \
                            'measured runs of that tier, stated as {n, range, rate} — ' \
                            'never a single run, never the projection'
    }
    puts EstimateCost.provenance_line(fit)
    doc['bands'].each do |tier, b|
      if b['refused']
        puts "  band[#{tier}]: REFUSED — #{b['refused']} (observed wall min: #{b['observed_wall_minutes'].join(', ')})"
      else
        w = b['wall_minutes']
        t = b['turns']
        puts "  band[#{tier}]: n=#{b['n']} wall #{w['min']}–#{w['max']} min (median #{w['median']})" +
             (t['refused'] ? " · turns: #{t['refused']}" : " · turns #{t['min']}–#{t['max']} (median #{t['median']})")
      end
    end
    fit['refused'].each { |r| puts "  refit refused: #{r}" }
    if opts[:out]
      File.write(opts[:out], JSON.pretty_generate(doc) + "\n")
      puts "[OK] calibration-refit → #{opts[:out]}"
    else
      puts JSON.pretty_generate(doc)
    end
  else
    abort('usage: estimate-cost.rb --workdir <dir> [--out <path>] [--from-metrics <dirs>] | ' \
          '--workbook <get-workbook.json> [--datasource <metadata.json>] | --from-metrics <dirs> [--out <path>]')
  end
end
