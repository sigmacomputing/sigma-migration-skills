#!/usr/bin/env ruby
# frozen_string_literal: true
#
# vds-oracle.rb — Phase 6w: the VDS TABLE-CALC ORACLE (ADVISORY in v1).
#
# WHY. Window calcs (RUNNING_*, WINDOW_*, RANK*, TOTAL, LOOKUP, INDEX) are
# translated to Sigma viz formulas by build-charts-from-signals.rb and then
# TRUSTED — they surface only as free-text WARN lines, and the CSV parity path
# can't see them when the view export is empty/missing. Tableau's VizQL Data
# Service executes the ORIGINAL formula server-side when the field carries a
# tableCalculation spec (live-verified 2026-07-11 against a Tableau Cloud site:
#   - a bare `calculation` with a table calc is REJECTED (400000 "Table
#     calculation functions require a tableCalculation specification");
#   - `tableCalculation: {"tableCalcType": "CUSTOM", "dimensions": [...]}`
#     works — `dimensions` = compute-using/ADDRESSING; query dims NOT listed
#     there = PARTITION (RUNNING_SUM restarts per unlisted dim);
#   - `sortDirection`/`sortPriority` on the dim fields order the accumulation;
#   - Tableau RANK defaults DESC, matching the converter's Rank(x,"desc")).
# So for every translated window calc we ask Tableau itself for ground truth
# at the chart's dims and compare it to the Sigma-side values Phase 6 already
# collects (parity-actuals.json). `diverge` on an UNfiltered chart is the
# actionable signal; everything else is bookkeeping so coverage stays honest.
#
# INPUTS (all under --workdir unless overridden):
#   window-calcs.json    structured sidecar emitted by build-charts-from-signals
#                        (entries: id/element/column ids, calc_name,
#                        tableau_formula, dims[{caption,sort}], partition_dims,
#                        date_trunc, datasource_caption, filters_present, mode).
#                        ABSENT → exit 0 "nothing to verify" (old workdirs).
#   parity-plan.json     charts[].sigma_element_id + sigma_columns (column ids —
#                        the actuals row column order).
#   parity-actuals.json  { "<chart name>": [[cell, ...], ...] } Sigma-side rows
#                        (render-verify marker Hashes → skipped-no-actuals).
#   calc-fields.json     workbook calc formulas — used to inline workbook-local
#                        calc references ONE level deep (VDS only knows the
#                        published datasource's fields).
#   pds.json             resolve-published-ds.rb descriptors (caption→pdsLuid).
#   landing-manifest.json  embedded/federated extracts that were landed — those
#                        datasources are INVISIBLE to VDS → skipped-embedded-ds.
#   intake.json / connection.json  run metadata (recorded in the output).
#
# OUTPUT <workdir>/vds-oracle.json:
#   { "version": 1, "advisory": true, "verified_at": ..., "server": ..., "site": ...,
#     "datasources": { "<caption>": "<luid>"|null },
#     "checks": [ { "id", "calc", "element_id", "element_name", "mode", "dims",
#                   "status", "n_tableau_rows", "n_joined", "n_unjoined",
#                   "max_rel_diff", "tableau_value", "sigma_value",
#                   "worst_row", "note" } ],
#     "summary": { "checked", "match", "near", "diverge", "filtered", "skipped",
#                  "error", "queries_issued", "pass" } }
#   Statuses: match | near | diverge | filtered-context (mismatch downgraded to
#   advisory because the chart carries filters the VDS query didn't replicate
#   in v1) | skipped-embedded-ds | skipped-no-luid | skipped-unsupported |
#   skipped-no-actuals | skipped-query-cap | error.
#   Also stamps a `vds_oracle` summary into parity-final.json when present
#   (same pattern as verify-anchors.rb).
#
# USAGE (live):
#   ruby scripts/vds-oracle.rb --workdir <W> \
#     [--window-calcs PATH] [--calc-fields PATH] [--actuals PATH] [--plan PATH] \
#     [--datasource-luid "<caption>=<luid>"]... [--calc NAME]... [--out PATH] \
#     [--max-queries 25] [--max-rows 50000] [--tolerance 1e-6] [--near-tol 0.01] \
#     [--max-unjoined-frac 0.1] [--timeout 60] [--verbose-rows] [--gate]
# USAGE (offline — tests):
#   ruby scripts/vds-oracle.rb --workdir <W> --offline \
#     [--vds-fixtures <dir>]   # <entry-id>.json canned VDS responses
#
# RATE CAP: VDS is capped site-wide at 100 queries/hour per Creator license and
# the budget is shared with discovery — all of one chart's calcs are batched
# into ONE query and --max-queries (default 25) hard-stops the run.
#
# EXIT CODES: 0 = ran (ADVISORY — even with diverges) or nothing to verify;
#   21 = --gate passed AND >=1 diverge (the gate slot reserved for this oracle
#        in assert-phase6-ran.rb — nothing flips it in v1);
#   2 = usage / malformed inputs / TABLEAU_* creds missing when live queries
#       were actually needed.

require 'json'
require 'optparse'
require 'timeout'

# ---------------------------------------------------------------------------
# Pure core — no IO, unit-tested offline in test-vds-oracle.rb.
# ---------------------------------------------------------------------------
module VdsOracle
  VERSION = 1
  GATE_EXIT = 21 # reserved oracle gate slot (assert-phase6-ran exit codes 7-20 are taken)

  # Constructs VDS cannot execute (vds_limitations + the translator's
  # WINDOW_MANUAL_RE class — those entries shouldn't reach the sidecar, but the
  # preflight is belt-and-braces).
  UNSUPPORTED_RE = /\b(?:WINDOW_(?:MEDIAN|PERCENTILE|CORR|COVARP?|VARP|STDEVP)|PREVIOUS_VALUE|RANK_MODIFIED|SCRIPT_\w+|RAWSQL\w*)\s*\(|\b(?:SIZE|FIRST|LAST)\s*\(\s*\)/i
  # RANK-family values compare as integers (exact), not by relative tolerance.
  RANK_RE = /\bRANK(?:_DENSE|_UNIQUE|_COMPETITION)?\s*\(/i
  # Sigma column-id channels that carry MEASURES (never join-key dims).
  MEASURE_ID_RE = /\A(?:y\d*|k|calc|val)-/i
  ISO_DT_RE  = /\A(\d{4}-\d{2}-\d{2})[T ]\d{2}:\d{2}/
  US_DATE_RE = %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}

  module_function

  def norm_caption(s)
    s.to_s.strip.downcase
  end

  # ---- formula preflight ---------------------------------------------------
  # 1. Reject VDS-unexecutable constructs and [Parameters].[X] references.
  # 2. Inline workbook-local calc references ONE level deep (calc_map:
  #    caption/internal name → formula) — VDS only knows the PUBLISHED
  #    datasource's fields, so RANK([% of total]) must become
  #    RANK(<formula of % of total>). Deeper nesting → skipped (v1).
  def preflight(formula, calc_map)
    f = formula.to_s
    return { 'ok' => false, 'reason' => 'formula uses a construct VDS cannot execute (WINDOW_MEDIAN/PERCENTILE/CORR/COVAR/VARP/STDEVP, PREVIOUS_VALUE, RANK_MODIFIED, SIZE/FIRST/LAST, SCRIPT_*, RAWSQL*)' } if f =~ UNSUPPORTED_RE
    return { 'ok' => false, 'reason' => 'formula references a parameter — VDS has no parameter binding' } if f =~ /\[Parameters\]\s*\.\s*\[/i
    inlined = f.gsub(/\[([^\[\]]+)\]/) do |ref|
      body = Regexp.last_match(1)
      calc_map[body] ? "(#{calc_map[body]})" : ref
    end
    if inlined != f
      return { 'ok' => false, 'reason' => 'inlined workbook-local calc uses a construct VDS cannot execute' } if inlined =~ UNSUPPORTED_RE
      return { 'ok' => false, 'reason' => 'inlined workbook-local calc references a parameter — VDS has no parameter binding' } if inlined =~ /\[Parameters\]\s*\.\s*\[/i
      leftover = inlined.scan(/\[([^\[\]]+)\]/).flatten.uniq.select { |n| calc_map[n] }
      unless leftover.empty?
        return { 'ok' => false, 'reason' => "workbook-local calc reference(s) nested deeper than one level: #{leftover.join(', ')}" }
      end
    end
    { 'ok' => true, 'formula' => inlined, 'inlined' => inlined != f }
  end

  def rank_family?(formula)
    formula.to_s =~ RANK_RE ? true : false
  end

  # ---- VDS query construction ------------------------------------------------
  # DATE DIMS: date_trunc maps to VDS `function: TRUNC_<PART>` — DateTrunc
  # semantics (one row per truncated date, e.g. 2022-11-01 per month PER YEAR),
  # matching the Sigma builder's DateTrunc dim formulas. Plain MONTH/YEAR would
  # return the date PART (int) and collapse years — wrong grain for a series.
  # (Spec §9.1/9.2 flag the exact enum for live verification; TRUNC_* is the
  # documented VDS FieldBase function family for truncation.)
  def date_function(part)
    p = part.to_s.strip
    p.empty? ? nil : "TRUNC_#{p.upcase}"
  end

  # Ordered union of the chart's ADDRESSING dims (sorted — accumulation order
  # must be deterministic to compare RUNNING_*/LOOKUP) then PARTITION dims
  # (query dims NOT listed in tableCalculation.dimensions — live-verified
  # partition semantics).
  def dim_fields(entries)
    fields = []
    seen = {}
    priority = 0
    entries.each do |e|
      Array(e['dims']).each_with_index do |d, i|
        cap = d['caption'].to_s
        next if cap.empty? || seen[cap]
        seen[cap] = true
        f = { 'fieldCaption' => cap }
        fn = date_function(d['date_trunc'] || (i.zero? ? e['date_trunc'] : nil))
        if fn
          f['function'] = fn
          f['fieldAlias'] = cap # stabilize the OBJECTS response key at the caption
        end
        priority += 1
        f['sortDirection'] = d['sort'].to_s.casecmp?('desc') ? 'DESC' : 'ASC'
        f['sortPriority'] = priority
        fields << f
      end
    end
    entries.each do |e|
      Array(e['partition_dims']).each do |cap|
        cap = cap.to_s
        next if cap.empty? || seen[cap]
        seen[cap] = true
        fields << { 'fieldCaption' => cap }
      end
    end
    fields
  end

  # tableCalculation.dimensions = the entry's ADDRESSING dims only (compute-
  # using). Carries the date function but never sort keys.
  def addressing_dimensions(entry)
    Array(entry['dims']).each_with_index.map do |d, i|
      h = { 'fieldCaption' => d['caption'].to_s }
      fn = date_function(d['date_trunc'] || (i.zero? ? entry['date_trunc'] : nil))
      h['function'] = fn if fn
      h
    end
  end

  # ONE query per chart: dims + every translated window calc as an ad-hoc
  # `calculation` field carrying the live-verified tableCalculation spec.
  # formulas_by_id: entry id → preflighted (inlined) Tableau formula.
  # Returns [query, { entry_id => field caption }].
  def build_query(entries, formulas_by_id)
    fields = dim_fields(entries)
    taken = {}
    fields.each { |f| taken[f['fieldCaption']] = true }
    captions = {}
    entries.each do |e|
      id = e['id'].to_s
      formula = formulas_by_id[id]
      next unless formula
      base = e['calc_name'].to_s
      base = e['column_name'].to_s if base.empty?
      base = id if base.empty?
      cap = base
      n = 1
      while taken[cap]
        n += 1
        cap = "#{base} (#{n})"
      end
      taken[cap] = true
      captions[id] = cap
      fields << { 'fieldCaption' => cap,
                  'calculation' => formula,
                  'tableCalculation' => { 'tableCalcType' => 'CUSTOM',
                                          'dimensions' => addressing_dimensions(e) } }
    end
    [{ 'fields' => fields }, captions]
  end

  # Normalize a VDS response to [{caption => value}] rows. OBJECTS format rows
  # arrive as Hashes; ARRAYS format rows are zipped against the query's field
  # order. Function-wrapped dim keys ("TRUNC_MONTH(Order Date)") are copied
  # back to the bare caption when the alias didn't take.
  def vds_rows(response, query)
    data = response.is_a?(Hash) ? (response['data'] || []) : Array(response)
    fields = query['fields'] || []
    caps = fields.map { |f| f['fieldAlias'] || f['fieldCaption'] }
    data.map do |row|
      if row.is_a?(Hash)
        out = row.dup
        fields.each do |f|
          cap = f['fieldCaption']
          next if out.key?(cap) || !f['function']
          wrapped = "#{f['function']}(#{cap})"
          out[cap] = out[wrapped] if out.key?(wrapped)
        end
        out
      else
        h = {}
        caps.each_with_index { |c, i| h[c] = Array(row)[i] }
        h
      end
    end
  end

  # ---- comparison ------------------------------------------------------------

  def number_of(v)
    return v.to_f if v.is_a?(Numeric)
    s = v.to_s
    s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
    s = s.scrub('') unless s.valid_encoding?
    s = s.strip
    return nil if s.empty?
    neg = s.start_with?('(') && s.end_with?(')')
    s = s[1..-2] if neg
    s = s.gsub(/[,$€£¥\s]/, '')
    pct = s.end_with?('%')
    s = s.chomp('%')
    f = begin
      Float(s)
    rescue ArgumentError, TypeError
      return nil
    end
    f = -f if neg
    pct ? f / 100.0 : f
  end

  # Join-key component: trimmed + case-insensitive; datetimes normalized to the
  # ISO date prefix (VDS returns "2022-11-07T00:00:00"; Sigma exports render
  # dates per format); numerics canonicalized so 2022 == "2,022" == 2022.0.
  def normalize_dim(v)
    s = v.to_s
    s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
    s = s.scrub('') unless s.valid_encoding?
    s = s.strip
    return Regexp.last_match(1) if s =~ ISO_DT_RE
    if s =~ US_DATE_RE
      return format('%04d-%02d-%02d', Regexp.last_match(3).to_i,
                    Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
    end
    f = number_of(s)
    if f
      i = f.round
      return (f - i).abs < 1e-9 ? i.to_s : format('%.10g', f)
    end
    s.downcase
  end

  # Map the entry's Sigma-side columns: the VALUE column is the plan column id
  # the sidecar recorded (column_id); every other non-measure-channel column is
  # a join-key dim. Returns [value_idx, dim_idxs] or nil when the value column
  # isn't in the plan.
  def sigma_indexes(entry, sigma_columns, n_dims)
    value_idx = sigma_columns.index(entry['column_id'].to_s)
    return nil unless value_idx
    dim_idxs = []
    sigma_columns.each_with_index do |cid, i|
      next if i == value_idx || cid.to_s =~ MEASURE_ID_RE
      dim_idxs << i
    end
    dim_idxs = dim_idxs.first(n_dims) if dim_idxs.length > n_dims
    [value_idx, dim_idxs]
  end

  # Compare Tableau's VDS rows to the Sigma-side actuals rows for one calc.
  # Rows join on the SORTED normalized dim tuple (order-insensitive — the plan
  # column order and the VDS dim order need not agree). Value tolerance:
  # rel_diff = |t - s| / max(|t|, |s|, 1e-12); RANK-family compares as
  # integers. Unjoined rows only fail when their fraction exceeds
  # max_unjoined_frac (VDS drops NULL-key rows; Sigma exports full data).
  def compare(entry, vds_rows, calc_caption, dim_captions, sigma_rows, sigma_columns,
              tolerance: 1e-6, near_tol: 0.01, max_unjoined_frac: 0.1, verbose_rows: false)
    idx = sigma_indexes(entry, sigma_columns, dim_captions.length)
    unless idx
      return { 'status' => 'skipped-no-actuals',
               'note' => "plan column #{entry['column_id'].inspect} not among sigma_columns #{sigma_columns.inspect[0, 120]}" }
    end
    value_idx, dim_idxs = idx
    notes = []
    notes << "dim-column heuristic matched #{dim_idxs.length} Sigma column(s) for #{dim_captions.length} VDS dim(s)" if dim_idxs.length != dim_captions.length

    sigma_by_key = {}
    Array(sigma_rows).each do |row|
      next unless row.is_a?(Array)
      key = dim_idxs.map { |i| normalize_dim(row[i]) }.sort
      sigma_by_key[key] = row unless sigma_by_key.key?(key)
    end
    n_sigma = sigma_by_key.length

    rank = rank_family?(entry['tableau_formula'])
    n_joined = 0
    vds_unjoined = 0
    bad = 0
    max_rel = 0.0
    worst = nil
    rows_dump = []
    vds_rows.each do |vr|
      key = dim_captions.map { |c| normalize_dim(vr[c]) }.sort
      srow = sigma_by_key.delete(key)
      if srow.nil?
        vds_unjoined += 1
        next
      end
      n_joined += 1
      t = number_of(vr[calc_caption])
      s = number_of(srow[value_idx])
      rows_dump << { 'dims' => key, 'tableau_value' => t, 'sigma_value' => s } if verbose_rows
      next if t.nil? && s.nil?
      rel = if t.nil? || s.nil?
              1.0 # value present on one side only
            elsif rank
              t.round == s.round ? 0.0 : 1.0
            else
              (t - s).abs / [t.abs, s.abs, 1e-12].max
            end
      worst = { 'dims' => key, 'tableau_value' => t, 'sigma_value' => s } if worst.nil? || rel > max_rel
      max_rel = rel if rel > max_rel
      bad += 1 if rel > near_tol
    end
    n_unjoined = vds_unjoined + sigma_by_key.length
    total = n_joined + n_unjoined
    unjoined_frac = total.zero? ? 0.0 : n_unjoined.to_f / total

    status =
      if n_joined.zero?
        notes << 'no rows joined on dim tuples — dim normalization or grain mismatch?'
        'diverge'
      elsif bad.positive?
        'diverge'
      elsif unjoined_frac > max_unjoined_frac
        notes << format('unjoined row fraction %.2f exceeds --max-unjoined-frac %.2f', unjoined_frac, max_unjoined_frac)
        'diverge'
      elsif max_rel > tolerance
        'near'
      else
        'match'
      end

    out = { 'status' => status,
            'n_tableau_rows' => vds_rows.length, 'n_sigma_rows' => n_sigma,
            'n_joined' => n_joined, 'n_unjoined' => n_unjoined,
            'max_rel_diff' => max_rel,
            'tableau_value' => worst && worst['tableau_value'],
            'sigma_value' => worst && worst['sigma_value'],
            'worst_row' => worst }
    out['rows'] = rows_dump if verbose_rows
    out['note'] = notes.join('; ') unless notes.empty?
    out
  end

  # v1 does NOT replicate the chart's element/view filters in the VDS query, so
  # a mismatch on a filtered chart is expected noise — downgraded to the
  # advisory `filtered-context` status (never gates).
  def apply_filter_context(check, entry)
    return check unless entry['filters_present'] && check['status'] == 'diverge'
    check['status'] = 'filtered-context'
    note = 'advisory: chart carries filters the VDS query did not replicate (v1) — mismatch downgraded'
    check['note'] = [check['note'], note].compact.join('; ')
    check
  end

  # ---- orchestration (still pure: all IO arrives via ctx) --------------------
  # ctx keys:
  #   'calc_map'        caption/internal name → formula (calc-fields.json)
  #   'embedded'        norm caption → federated/embedded datasource name
  #   'luids'           norm caption → published-DS luid (nil when unresolved)
  #   'plan_by_element' sigma_element_id → plan chart entry
  #   'plan_by_name'    chart name → plan chart entry
  #   'actuals'         chart name → rows (or render-verify marker Hash)
  #   'executor'        lambda(luid, query, entry_ids) → parsed VDS response
  #   'max_queries' / 'max_rows' / 'tolerance' / 'near_tol' /
  #   'max_unjoined_frac' / 'verbose_rows'
  def run(entries, ctx)
    tol   = ctx.fetch('tolerance', 1e-6)
    near  = ctx.fetch('near_tol', 0.01)
    unj   = ctx.fetch('max_unjoined_frac', 0.1)
    maxq  = ctx.fetch('max_queries', 25)
    maxr  = ctx.fetch('max_rows', 50_000)
    verbose = ctx.fetch('verbose_rows', false)
    calc_map = ctx['calc_map'] || {}
    embedded = ctx['embedded'] || {}
    luids    = ctx['luids'] || {}
    plan_el  = ctx['plan_by_element'] || {}
    plan_nm  = ctx['plan_by_name'] || {}
    actuals  = ctx['actuals'] || {}
    executor = ctx['executor']

    checks = {}
    formulas = {}
    queryable = []
    entries.each do |e|
      id = e['id'].to_s
      base = { 'id' => id, 'calc' => e['calc_name'], 'element_id' => e['element_id'],
               'element_name' => e['element_name'], 'mode' => e['mode'],
               'dims' => Array(e['dims']).map { |d| d['caption'] },
               'tableau_value' => nil, 'sigma_value' => nil }
      cap = e['datasource_caption'].to_s
      if e['mode'].to_s == 'manual'
        checks[id] = base.merge('status' => 'skipped-unsupported',
                                'note' => 'manual-mode translation — nothing comparable was emitted')
        next
      end
      if Array(e['dims']).empty?
        checks[id] = base.merge('status' => 'skipped-unsupported',
                                'note' => 'no addressing dims recorded for the chart')
        next
      end
      pf = preflight(e['tableau_formula'], calc_map)
      unless pf['ok']
        checks[id] = base.merge('status' => 'skipped-unsupported', 'note' => pf['reason'])
        next
      end
      if embedded[norm_caption(cap)]
        checks[id] = base.merge('status' => 'skipped-embedded-ds',
                                'note' => "datasource #{cap.inspect} is an embedded/federated extract " \
                                          "(#{embedded[norm_caption(cap)]}) — VDS sees published datasources only")
        next
      end
      luid = luids[norm_caption(cap)]
      if luid.to_s.empty?
        checks[id] = base.merge('status' => 'skipped-no-luid',
                                'note' => "no published-datasource luid for #{cap.inspect} " \
                                          '(pass --datasource-luid "<caption>=<luid>", or run resolve-published-ds.rb)')
        next
      end
      plan = plan_el[e['element_id'].to_s] || plan_nm[e['element_name'].to_s]
      if plan.nil?
        checks[id] = base.merge('status' => 'skipped-no-actuals',
                                'note' => 'chart not in parity-plan.json — no Sigma column mapping')
        next
      end
      rows = actuals[plan['chart'].to_s]
      rows = actuals[e['element_name'].to_s] if rows.nil?
      if rows.is_a?(Hash)
        checks[id] = base.merge('status' => 'skipped-no-actuals',
                                'note' => "Sigma actuals carry a #{rows['status'].inspect} marker — no rows to compare")
        next
      end
      unless rows.is_a?(Array) && !rows.empty?
        checks[id] = base.merge('status' => 'skipped-no-actuals',
                                'note' => 'no Sigma-side rows in parity-actuals.json for this chart')
        next
      end
      formulas[id] = pf['formula']
      queryable << { 'entry' => e, 'base' => base, 'luid' => luid, 'plan' => plan,
                     'rows' => rows, 'inlined' => pf['inlined'] }
    end

    # ONE query per chart (all its calcs batched as extra fields) — the VDS
    # rate cap (100/hr/Creator, site-wide) is the scarce resource here.
    groups = queryable.group_by { |q| [q['entry']['element_id'].to_s, q['luid']] }
    queries_issued = 0
    groups.each_with_index do |(key, grp), gi|
      luid = key[1]
      if gi >= maxq
        grp.each do |q|
          checks[q['entry']['id'].to_s] =
            q['base'].merge('status' => 'skipped-query-cap',
                            'note' => "--max-queries #{maxq} reached (VDS cap: 100 queries/hour/Creator, site-wide)")
        end
        next
      end
      ents = grp.map { |q| q['entry'] }
      ids = ents.map { |e| e['id'].to_s }
      query, captions = build_query(ents, formulas)
      response = begin
        queries_issued += 1
        executor.call(luid, query, ids)
      rescue StandardError => err
        msg = err.message.to_s.lines.first.to_s.strip[0, 200]
        grp.each { |q| checks[q['entry']['id'].to_s] = q['base'].merge('status' => 'error', 'note' => msg) }
        next
      end
      rows = vds_rows(response, query)
      truncated = rows.length > maxr
      rows = rows.first(maxr) if truncated
      dim_caps = query['fields'].reject { |f| f.key?('calculation') }.map { |f| f['fieldCaption'] }
      grp.each do |q|
        e = q['entry']
        id = e['id'].to_s
        res = compare(e, rows, captions[id], dim_caps, q['rows'],
                      Array(q['plan']['sigma_columns']).map(&:to_s),
                      tolerance: tol, near_tol: near, max_unjoined_frac: unj,
                      verbose_rows: verbose)
        check = q['base'].merge(res)
        extra = []
        extra << 'workbook-local calc reference(s) inlined one level' if q['inlined']
        extra << "VDS rows truncated at --max-rows #{maxr}" if truncated
        check['note'] = ([check['note']] + extra).compact.join('; ') unless extra.empty?
        checks[id] = apply_filter_context(check, e)
      end
    end

    ordered = entries.map { |e| checks[e['id'].to_s] }.compact
    { 'checks' => ordered, 'queries_issued' => queries_issued }
  end

  def summarize(checks, queries_issued)
    count = lambda { |st| checks.count { |c| c['status'] == st } }
    skipped = checks.count { |c| c['status'].to_s.start_with?('skipped') }
    diverge = count.call('diverge')
    { 'checked' => checks.length,
      'match' => count.call('match'),
      'near' => count.call('near'),
      'diverge' => diverge,
      'filtered' => count.call('filtered-context'),
      'skipped' => skipped,
      'error' => count.call('error'),
      'queries_issued' => queries_issued,
      'pass' => diverge.zero? }
  end
end

# ---------------------------------------------------------------------------
# CLI (IO / REST) — thin wrapper around the pure core above.
# ---------------------------------------------------------------------------
return if $PROGRAM_NAME != __FILE__ && !ENV['VDS_ORACLE_CLI'] # allow `require` in tests

opts = { max_queries: 25, max_rows: 50_000, tolerance: 1e-6, near_tol: 0.01,
         max_unjoined_frac: 0.1, timeout: 60, luid_overrides: {}, calc_filters: [] }
OptionParser.new do |p|
  p.on('--workdir DIR')                { |v| opts[:dir] = v }
  p.on('--window-calcs PATH', 'default: <workdir>/window-calcs.json') { |v| opts[:window_calcs] = v }
  p.on('--calc-fields PATH',  'default: <workdir>/calc-fields.json')  { |v| opts[:calc_fields] = v }
  p.on('--actuals PATH',      'default: <workdir>/parity-actuals.json') { |v| opts[:actuals] = v }
  p.on('--plan PATH',         'default: <workdir>/parity-plan.json')  { |v| opts[:plan] = v }
  p.on('--out PATH',          'default: <workdir>/vds-oracle.json')   { |v| opts[:out] = v }
  p.on('--datasource-luid PAIR', '"<caption>=<luid>" manual override; repeatable') do |v|
    cap, luid = v.split('=', 2)
    opts[:luid_overrides][VdsOracle.norm_caption(cap)] = luid.to_s.strip
  end
  p.on('--calc NAME', 'only verify calcs whose name/id matches (substring, case-insensitive); repeatable') { |v| opts[:calc_filters] << v }
  p.on('--max-queries N', Integer)     { |v| opts[:max_queries] = v }
  p.on('--max-rows N', Integer)        { |v| opts[:max_rows] = v }
  p.on('--tolerance F', Float)         { |v| opts[:tolerance] = v }
  p.on('--near-tol F', Float)          { |v| opts[:near_tol] = v }
  p.on('--max-unjoined-frac F', Float) { |v| opts[:max_unjoined_frac] = v }
  p.on('--timeout S', Integer)         { |v| opts[:timeout] = v }
  p.on('--verbose-rows')               { opts[:verbose_rows] = true }
  p.on('--gate', "gate mode: exit #{VdsOracle::GATE_EXIT} on any diverge (v1 default is ADVISORY)") { opts[:gate] = true }
  p.on('--offline', 'no network — serve VDS responses from --vds-fixtures') { opts[:offline] = true }
  p.on('--vds-fixtures DIR', 'offline: <entry-id>.json canned VDS responses (default: <workdir>/vds-fixtures)') { |v| opts[:fixtures] = v }
end.parse!
unless opts[:dir]
  warn 'usage: ruby scripts/vds-oracle.rb --workdir <W> [--offline] [--gate] ... (--workdir required)'
  exit 2
end

dir       = opts[:dir]
wc_path   = opts[:window_calcs] || File.join(dir, 'window-calcs.json')
out_path  = opts[:out] || File.join(dir, 'vds-oracle.json')
fixtures  = opts[:fixtures] || File.join(dir, 'vds-fixtures')

read_json = lambda do |path|
  return nil unless path && File.exist?(path)
  begin
    JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    warn "[WARN] #{path} is malformed JSON (#{e.message.lines.first.to_s.strip[0, 80]}) — ignored"
    nil
  end
end

intake = read_json.call(File.join(dir, 'intake.json')) || {}
conn   = read_json.call(File.join(dir, 'connection.json')) || {}

base_doc = lambda do
  { 'version' => VdsOracle::VERSION,
    'advisory' => !opts[:gate],
    'verified_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'server' => ENV['TABLEAU_SERVER_URL'],
    'site' => ENV['TABLEAU_SITE_CONTENT_URL'],
    'input_mode' => intake['input_mode'],
    'sigma_connection_id' => conn['connection_id'] }
end

write_out = lambda do |doc|
  File.write(out_path, JSON.pretty_generate(doc))
end

soft_exit = lambda do |note|
  doc = base_doc.call.merge(
    'datasources' => {}, 'checks' => [],
    'summary' => { 'checked' => 0, 'match' => 0, 'near' => 0, 'diverge' => 0,
                   'filtered' => 0, 'skipped' => 0, 'error' => 0,
                   'queries_issued' => 0, 'pass' => true },
    'note' => note
  )
  write_out.call(doc)
  warn "vds-oracle: #{note} — nothing to verify (advisory; exit 0) → #{out_path}"
  exit 0
end

# Missing sidecar NEVER blocks old workdirs (builders that predate it) or
# workbooks with no window calcs — that is the honest "nothing to verify".
soft_exit.call('no window-calc sidecar (builder predates it or no window calcs)') unless File.exist?(wc_path)
wc_doc = begin
  JSON.parse(File.read(wc_path))
rescue JSON::ParserError => e
  warn "FATAL: #{wc_path} is malformed JSON: #{e.message.lines.first.to_s.strip[0, 120]}"
  exit 2
end
entries = Array(wc_doc['entries']).select { |e| e.is_a?(Hash) && !e['id'].to_s.empty? }
soft_exit.call('window-calcs.json has no entries — no translated window calcs on this workbook') if entries.empty?

unless opts[:calc_filters].empty?
  wants = opts[:calc_filters].map(&:downcase)
  entries = entries.select do |e|
    wants.any? { |w| e['calc_name'].to_s.downcase.include?(w) || e['id'].to_s.downcase == w }
  end
  soft_exit.call("--calc filter #{opts[:calc_filters].inspect} matched no window-calc entries") if entries.empty?
end

# ---- reference inputs -------------------------------------------------------
calc_map = {}
cf = read_json.call(opts[:calc_fields] || File.join(dir, 'calc-fields.json'))
Array(cf && cf['calcs']).each do |c|
  next unless c.is_a?(Hash) && c['formula']
  calc_map[c['name'].to_s] = c['formula'] unless c['name'].to_s.empty?
  calc_map[c['internal_name'].to_s] ||= c['formula'] unless c['internal_name'].to_s.empty?
end

# Embedded/federated extracts (landed by land-extracts.py) are INVISIBLE to
# VDS — published datasources only. Clean SKIP, never an error.
embedded = {}
lm = read_json.call(File.join(dir, 'landing-manifest.json'))
Array(lm.is_a?(Hash) ? lm['datasources'] || lm['entries'] || [] : lm).each do |m|
  next unless m.is_a?(Hash)
  ds = m['datasource'].to_s
  [m['caption'], m['datasource']].each do |k|
    key = VdsOracle.norm_caption(k)
    embedded[key] = (ds.empty? ? 'landed extract' : ds) unless key.empty?
  end
end

plan = read_json.call(opts[:plan] || File.join(dir, 'parity-plan.json'))
plan_charts = plan.is_a?(Hash) ? Array(plan['charts']) : Array(plan)
plan_by_element = {}
plan_by_name = {}
plan_charts.each do |c|
  next unless c.is_a?(Hash)
  plan_by_element[c['sigma_element_id'].to_s] = c unless c['sigma_element_id'].to_s.empty?
  plan_by_name[c['chart'].to_s] = c unless c['chart'].to_s.empty?
end

actuals = read_json.call(opts[:actuals] || File.join(dir, 'parity-actuals.json')) || {}
actuals = {} unless actuals.is_a?(Hash)

# ---- transport: live VDS or offline fixtures --------------------------------
creds_missing = false
unless opts[:offline]
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'tableau_rest' # PAT auth + single-flight 401 refresh + neutral-env bootstrap
  pat_ok = !ENV['TABLEAU_PAT_NAME'].to_s.empty? && !ENV['TABLEAU_PAT_SECRET'].to_s.empty? &&
           !ENV['TABLEAU_SITE_CONTENT_URL'].to_s.empty?
  creds_missing = ENV['TABLEAU_SERVER_URL'].to_s.empty? ||
                  (ENV['TABLEAU_AUTH_TOKEN'].to_s.empty? && !pat_ok)
end

# The lib only auto-refreshes on a 401 — with PAT-only creds there is no token
# yet and auth_token raises BEFORE the first request. Mint one lazily (single
# signin; never retries with varied creds — PAT 4-strike lockout safe).
token_ready = opts[:offline] || !ENV['TABLEAU_AUTH_TOKEN'].to_s.empty?
ensure_token = lambda do
  unless token_ready
    Tableau.refresh_token!
    token_ready = true
  end
end

# LUID resolution per datasource caption: --datasource-luid override →
# <W>/pds.json (resolve-published-ds.rb descriptors) → live name lookup → nil.
pds = read_json.call(File.join(dir, 'pds.json'))
pds_luids = {}
Array(pds).each do |d|
  next unless d.is_a?(Hash) && !d['pdsLuid'].to_s.empty?
  [d['caption'], d['pdsName']].each do |k|
    key = VdsOracle.norm_caption(k)
    pds_luids[key] ||= d['pdsLuid'] unless key.empty?
  end
end
luids = {}
datasources = {}
# Entries WITHOUT a datasource_caption (single-datasource workbooks — the
# builder only names captions when a multi-DS plan exists) resolve through
# the workdir's published-DS descriptors / the --datasource-luid override:
# a lone pds.json entry or a lone override IS the datasource (review-caught:
# `next if key.empty?` starved the fallback and every check skipped-no-luid).
if entries.any? { |e| e['datasource_caption'].to_s.strip.empty? }
  fallback = if opts[:luid_overrides].size == 1
               opts[:luid_overrides].values.first
             elsif pds_luids.values.uniq.size == 1
               pds_luids.values.first
             end
  luids[''] = fallback if fallback
  datasources['(default)'] = fallback if fallback
end
entries.map { |e| e['datasource_caption'].to_s }.uniq.each do |cap|
  key = VdsOracle.norm_caption(cap)
  next if key.empty?
  luid = opts[:luid_overrides][key] || pds_luids[key]
  if luid.nil? && !opts[:offline] && !creds_missing && !embedded[key]
    begin
      ensure_token.call
      rec = Tableau.find_datasource_by_name(cap)
      luid = rec && rec['id']
    rescue Tableau::Error => e
      warn "[WARN] datasource lookup failed for #{cap.inspect}: #{e.message.lines.first.to_s.strip[0, 120]}"
    end
  end
  luids[key] = luid
  datasources[cap] = embedded[key] ? nil : luid
end

executor =
  if opts[:offline]
    lambda do |_luid, _query, entry_ids|
      file = entry_ids.map { |id| File.join(fixtures, "#{id}.json") }.find { |p| File.exist?(p) }
      raise "no VDS fixture for #{entry_ids.join(', ')} under #{fixtures}" unless file
      JSON.parse(File.read(file))
    end
  elsif creds_missing
    lambda do |_luid, _query, _ids|
      raise 'TABLEAU_* credentials not available — cannot query VDS (run scripts/get-tableau-token.sh or write ~/.sigma-migration/env)'
    end
  else
    lambda do |luid, query, _ids|
      attempts = 0
      begin
        attempts += 1
        ensure_token.call
        Timeout.timeout(opts[:timeout]) { Tableau.query_datasource(luid, query) }
      rescue Tableau::Error => e
        # Site-wide VDS rate cap (100/hr/Creator): back off, retry twice, then record.
        raise unless attempts < 3 && e.message =~ /\b429\b|Too Many Requests/i
        sleep(2**attempts)
        retry
      end
    end
  end

ctx = { 'calc_map' => calc_map, 'embedded' => embedded, 'luids' => luids,
        'plan_by_element' => plan_by_element, 'plan_by_name' => plan_by_name,
        'actuals' => actuals, 'executor' => executor,
        'max_queries' => opts[:max_queries], 'max_rows' => opts[:max_rows],
        'tolerance' => opts[:tolerance], 'near_tol' => opts[:near_tol],
        'max_unjoined_frac' => opts[:max_unjoined_frac],
        'verbose_rows' => opts[:verbose_rows] ? true : false }
result = VdsOracle.run(entries, ctx)
checks = result['checks']
summary = VdsOracle.summarize(checks, result['queries_issued'])

doc = base_doc.call.merge('datasources' => datasources, 'checks' => checks, 'summary' => summary)
write_out.call(doc)

# Stamp the summary into parity-final.json when Phase 6 already finalized —
# the oracle verdict travels with the parity verdict (verify-anchors pattern).
pf = File.join(dir, 'parity-final.json')
if File.exist?(pf)
  begin
    s = JSON.parse(File.read(pf))
    s['vds_oracle'] = { 'checked' => summary['checked'], 'match' => summary['match'],
                        'near' => summary['near'], 'diverge' => summary['diverge'],
                        'skipped' => summary['skipped'], 'pass' => summary['pass'],
                        'advisory' => !opts[:gate] }
    File.write(pf, JSON.pretty_generate(s))
  rescue JSON::ParserError
    warn "[WARN] #{pf} is malformed — vds_oracle summary not stamped."
  end
end

# ---- report ------------------------------------------------------------------
checks.each do |c|
  tag = case c['status']
        when 'match' then 'MATCH   '
        when 'near' then 'NEAR    '
        when 'diverge' then 'DIVERGE '
        when 'filtered-context' then 'FILTERED'
        when 'error' then 'ERROR   '
        else 'SKIP    '
        end
  detail =
    case c['status']
    when 'match', 'near'
      format('%d/%d row(s) joined, max rel diff %.3g', c['n_joined'], c['n_tableau_rows'], c['max_rel_diff'])
    when 'diverge', 'filtered-context'
      w = c['worst_row'] || {}
      "tableau=#{w['tableau_value'].inspect} sigma=#{w['sigma_value'].inspect} at #{Array(w['dims']).inspect}"
    else
      "#{c['status']}: #{c['note']}"
    end
  line = "  #{tag} #{c['id']} #{c['calc'].to_s.inspect} on #{c['element_name'].to_s.inspect} — #{detail}"
  c['status'] == 'diverge' ? warn(line) : puts(line)
end

warn "vds-oracle#{opts[:gate] ? '' : ' (advisory)'}: checked #{summary['checked']} — " \
     "match #{summary['match']}, near #{summary['near']}, diverge #{summary['diverge']}, " \
     "filtered #{summary['filtered']}, skipped #{summary['skipped']}, error #{summary['error']} " \
     "(#{summary['queries_issued']} VDS quer#{summary['queries_issued'] == 1 ? 'y' : 'ies'}) → #{out_path}"

if creds_missing && checks.any? { |c| c['status'] == 'error' }
  warn '[FAIL] live VDS queries were needed but TABLEAU_* credentials are missing —'
  warn '       run scripts/get-tableau-token.sh (or write ~/.sigma-migration/env) and re-run.'
  exit 2
end
if opts[:gate] && summary['diverge'].positive?
  warn "[GATE] #{summary['diverge']} window calc(s) DIVERGE from Tableau's own VDS values — exit #{VdsOracle::GATE_EXIT}."
  warn '       Triage: wrong addressing dim vs wrong sort vs missing partition — see refs/window-functions.md.'
  exit VdsOracle::GATE_EXIT
end
if summary['diverge'].positive?
  warn "[ADVISORY] #{summary['diverge']} diverge(s) recorded in #{out_path} — v1 never gates on the oracle."
end
exit 0
