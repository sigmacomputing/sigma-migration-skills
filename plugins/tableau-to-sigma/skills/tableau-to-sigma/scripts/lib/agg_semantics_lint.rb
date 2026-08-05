# frozen_string_literal: true
#
# agg_semantics_lint.rb — derive the AGGREGATION-SEMANTICS LEDGER
# (<workdir>/agg-semantics.json): the "wrong-looking-right numbers" lint
# (PLAN-v3 PR-7).
#
# WHY: additive aggregation over a PRE-AGGREGATED column compiles clean in
# every existing gate and ships numbers that look plausible and are wrong.
# Field root cause #3 (2026-07-17): a KPI printed 103.3% "% entities with
# value" — a {FIXED day: COUNTD(...)} pre-aggregate consumed with SUM() at
# any grain other than day double-counts every entity that appears on more
# than one day. Three live runs proved nothing flags this: the formula is
# valid, the spec POSTs clean, parity buckets can even pass. The corpus twin
# is corpus/tableau/preagg-kpi (three SUM(preagg)/SUM(preagg) KPIs).
#
# One ledger entry per hit, class ∈:
#
#   additive-over-preagg  Sum()/Avg() applied to a column that is itself an
#                         LOD pre-aggregate ({FIXED/INCLUDE/EXCLUDE} output —
#                         cross-referenced against the LOD census the lod_audit
#                         module derives), in a SOURCE calc or an EMITTED
#                         dm-spec/wb-spec formula. Also raised (evidence kind
#                         "landing-grain") when a landed table declares a
#                         `grain` in landing-manifest.json and an emitted
#                         element additively aggregates its columns while
#                         grouping by a dimension OUTSIDE that grain — the
#                         landed rows are already aggregates; re-summing them
#                         across a different grain double-counts.
#   countd-as-sum         COUNTD translated to Sum anywhere: a source
#                         COUNTD(...) measure whose emitted same-name
#                         translation aggregates with Sum(), or an emitted
#                         Sum() whose argument references a COUNTD-derived
#                         column. A distinct count is not additive.
#   preagg-ratio          a ratio formula (KPI numerator/denominator shape —
#                         the formula divides) consuming a column whose NAME
#                         says it is already an aggregate (DISTINCT_*, *_PCT,
#                         *_RATE, AVG_*, *_COUNT, *_RATIO patterns, matched
#                         on word tokens so "Daily Distinct Buyers" counts).
#
# SEVERITY: WARN-WITH-REQUIRED-RESOLUTION. Every hit blocks GREEN
# (assert-phase6-ran.rb gate 19, exit 26) until the run records ONE of:
#
#   reaggregated       — the consumer was rebuilt to aggregate at the correct
#                        grain (grouped helper re-aggregation, Max/Min over
#                        the pre-aggregate at its own grain, CountDistinct
#                        over the base column). Name the element/column.
#   n/a                — the hit does not apply here (e.g. the tile's group-by
#                        IS the pre-aggregate's grain, so the additive sum is
#                        exact; or the name-heuristic misread a raw column).
#                        The n/a path is FIRST-CLASS: the lint must NEVER
#                        force fabricated metadata to get past it (PLAN-v3
#                        field failure 17 — the invented point_in_time stub).
#   faithful-to-source — the SOURCE workbook itself mixes grains and the
#                        migration reproduces it faithfully; the resolution
#                        documents the hazard instead of silently shipping it
#                        (the live-twin 103.3% KPI case).
#
# An EMPTY ledger is still written — its presence is the gate's evidence the
# lint ran. Re-derivation preserves recorded resolutions (matched on
# class + context + consumer + pre-aggregate + formula).
#
# Ruby 2.6-compatible. Offline, deterministic (no network).

require 'json'
require_relative 'calc_coverage'
require_relative 'lod_audit'

module AggSemanticsLint
  NOTE = 'Additive aggregation (Sum/Avg) over a pre-aggregated column compiles clean and ships ' \
         'wrong-looking-right numbers (mixed-grain double counting). Every hit needs a recorded ' \
         'resolution: reaggregated (rebuilt at the correct grain), n/a(reason) (the hit does not ' \
         'apply — never fabricate metadata to satisfy the lint), or faithful-to-source(reason) ' \
         '(the source itself mixes grains; the migration reproduces it and documents the hazard).'

  CLASSES         = %w[additive-over-preagg countd-as-sum preagg-ratio].freeze
  RESOLUTION_HOWS = %w[reaggregated n/a faithful-to-source].freeze

  ADDITIVE_CALL_RE = /\b(SUM|AVG)\s*\(/i
  COUNTD_RE        = /\bCOUNTD\s*\(/i

  module_function

  # Case/punctuation-insensitive normalization (same key space as LodAudit).
  def norm(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # ---- name heuristic -------------------------------------------------------

  # Token-wise pre-aggregate name patterns: DISTINCT_* / *_PCT / *_RATE /
  # AVG_* / *_COUNT / *_RATIO — matched on WORD TOKENS (snake, spaces, camel),
  # so "Daily Distinct Buyers", "DISTINCT_ORDERS" and "conversionRate" all
  # read as pre-aggregated. Single-token names ("Count", "Rate") do NOT match:
  # too generic to accuse.
  def preagg_name?(name)
    toks = name.to_s.gsub(/([a-z0-9])([A-Z])/, '\1 \2')
               .upcase.split(/[^A-Z0-9]+/).reject(&:empty?)
    return false if toks.length < 2
    return true if toks.include?('DISTINCT')
    return true if %w[PCT RATE COUNT RATIO].include?(toks.last)
    return true if toks.first == 'AVG'
    false
  end

  # ---- source calc census ---------------------------------------------------

  # Every calc (LOD or not) from a calc-fields.json doc ({'calcs'=>[...]}) or
  # a bare array. Dedup by [name, formula] (worksheet-local copies repeat).
  def calc_census(doc)
    calcs = doc.is_a?(Hash) ? Array(doc['calcs']) : Array(doc)
    seen = {}
    out = []
    calcs.each do |c|
      next unless c.is_a?(Hash)
      f = fetch(c, 'formula').to_s
      next if f.empty?
      name = fetch(c, 'name').to_s
      name = fetch(c, 'internal_name').to_s if name.empty?
      key = [name, f]
      next if seen[key]
      seen[key] = true
      out << { 'name' => name, 'internal_name' => fetch(c, 'internal_name').to_s, 'formula' => f }
    end
    out
  end

  # Fallback census straight from .twb XML (same seam as LodAudit).
  def calc_census_from_twb(twb_text)
    require_relative 'twb_xml'
    xml = twb_text.to_s.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
    doc = begin
      TwbXml.parse(xml)
    rescue StandardError
      return []
    end
    recs = []
    doc.elements.each('//column') do |col|
      calc = col.elements['calculation']
      next unless calc && calc.attributes['class'] == 'tableau'
      f = calc.attributes['formula'].to_s
      next if f.empty?
      recs << { 'name' => (col.attributes['caption'] || col.attributes['name']).to_s.gsub(/\A\[|\]\z/, ''),
                'internal_name' => col.attributes['name'].to_s,
                'formula' => f }
    end
    calc_census(recs)
  end

  # ---- formula dissection (masked — string/comment content never counts) ----

  # [['SUM'|'AVG', [raw field refs inside that call]], ...] for one formula.
  # Balanced-paren walk over the MASKED text (placeholders carry no parens).
  def additive_arg_refs(masked, tokens)
    out = []
    pos = 0
    while (m = masked.match(ADDITIVE_CALL_RE, pos))
      j = m.end(0)
      depth = 1
      while j < masked.length && depth.positive?
        depth += 1 if masked[j] == '('
        depth -= 1 if masked[j] == ')'
        j += 1
      end
      arg = masked[m.end(0)...(depth.zero? ? j - 1 : j)].to_s
      refs = arg.scan(/\x00F(\d+)\x00/).map { |(i)| tokens[:fields][i.to_i] }.compact
      out << [m[1].upcase, refs]
      pos = m.end(0)
    end
    out
  end

  # Terminal segment of a bracket ref: '[Master/Daily Buyers]' -> 'Daily
  # Buyers', '[Calculation_DDB]' -> 'Calculation_DDB'. Parameters/control refs
  # return nil.
  def terminal(ref)
    seg = ref.to_s.gsub(/\A\[|\]\z/, '').split('/').last.to_s.strip
    return nil if seg.empty? || seg =~ /\Actl-/ || seg == 'Parameters' || seg.start_with?('Parameters.')
    seg
  end

  # A masked formula divides iff a '/' survives masking (comments '//', '/*'
  # and any '/' inside strings/brackets are already tokenized away).
  def ratio?(masked)
    masked.include?('/')
  end

  # ---- derivation -----------------------------------------------------------

  # calcs: calc_census output. dm_spec/wb_spec: parsed spec Hashes (or nil).
  # landing_manifest: parsed landing-manifest.json (bare array or
  # {'entries'=>[...]}; only entries carrying a `grain` array participate).
  # prior: previously written ledger — recorded resolutions carry forward.
  def derive(calcs, dm_spec: nil, wb_spec: nil, landing_manifest: nil, prior: nil)
    calcs = Array(calcs)
    lods = LodAudit.lod_calcs('calcs' => calcs)

    # pre-aggregate lookup: LOD calc by caption AND internal name.
    lod_by_key = {}
    lods.each do |l|
      [l['calc'], l['internal_name'].to_s.gsub(/\A\[|\]\z/, '')].each do |k|
        lod_by_key[norm(k)] = l['calc'] unless norm(k).empty?
      end
    end
    # COUNTD-derived calcs (masked scan), keyed the same way. LODs whose inner
    # aggregate is COUNTD are in BOTH sets — class (a) wins for those.
    countd_by_key = {}
    countd_names = {}
    calcs.each do |c|
      masked, = CalcCoverage.mask(c['formula'])
      next unless masked =~ COUNTD_RE
      countd_names[c['name']] = true
      [c['name'], c['internal_name'].to_s.gsub(/\A\[|\]\z/, '')].each do |k|
        countd_by_key[norm(k)] = c['name'] unless norm(k).empty?
      end
    end
    # internal name -> caption, for resolving Tableau refs to display names.
    name_map = {}
    calcs.each do |c|
      [c['internal_name'].to_s.gsub(/\A\[|\]\z/, ''), c['name']].each do |k|
        name_map[norm(k)] ||= c['name'] unless norm(k).empty?
      end
    end
    resolve_cap = lambda do |ref|
      t = terminal(ref)
      t && (name_map[norm(t)] || t)
    end

    entries = []
    seen = {}
    push = lambda do |e|
      key = [e['class'], e['context'], e['element'], e['consumer'], e['preagg']].map(&:to_s).join(" ")
      unless seen[key]
        seen[key] = true
        entries << e
      end
    end

    # -- source calcs: (a) additive over LOD pre-aggregate, (c) preagg ratio --
    calcs.each do |c|
      masked, tokens = CalcCoverage.mask(c['formula'])
      additive_arg_refs(masked, tokens).each do |fn, refs|
        refs.each do |ref|
          cap = resolve_cap.call(ref)
          next unless cap
          preagg = lod_by_key[norm(cap)]
          next unless preagg
          next if norm(c['name']) == norm(preagg) # the LOD's own formula
          lod = lods.find { |l| l['calc'] == preagg }
          push.call('class' => 'additive-over-preagg', 'context' => 'source-calc',
                    'consumer' => c['name'], 'preagg' => preagg, 'formula' => c['formula'],
                    'evidence' => { 'kind' => 'lod-census', 'aggregate' => fn,
                                    'preagg_formula' => (lod ? lod['formula'] : nil) },
                    'detail' => "#{fn}([#{preagg}]) — the column is a {#{lod ? lod['lod_kind'] : 'FIXED'} ...} " \
                                'pre-aggregate; summing it at any other grain double-counts (mixed-grain consumption)',
                    'status' => 'unresolved')
        end
      end
      next unless ratio?(masked)
      Array(tokens[:fields]).each do |ref|
        cap = resolve_cap.call(ref)
        next unless cap && preagg_name?(cap)
        push.call('class' => 'preagg-ratio', 'context' => 'source-calc',
                  'consumer' => c['name'], 'preagg' => cap, 'formula' => c['formula'],
                  'evidence' => { 'kind' => 'name-heuristic' },
                  'detail' => "ratio formula consumes #{cap.inspect} — the name says it is already an " \
                              'aggregate; using it as a KPI numerator/denominator re-aggregates an aggregate',
                  'status' => 'unresolved')
      end
    end

    # -- emitted specs --------------------------------------------------------
    cols = LodAudit.emitted_columns(dm_spec, 'dm-spec') + LodAudit.emitted_columns(wb_spec, 'wb-spec')

    # (b) same-name translation degradation: source COUNTD -> emitted Sum.
    calcs.each do |c|
      next unless countd_names[c['name']]
      cols.each do |col|
        next unless norm(col['name']) == norm(c['name'])
        f = col['formula'].to_s
        next unless f =~ /\bSUM\s*\(/i
        next if f =~ /\bCountDistinct\s*\(/i
        push.call('class' => 'countd-as-sum', 'context' => col['spec'],
                  'element' => col['element'], 'consumer' => col['name'],
                  'preagg' => c['name'], 'formula' => f,
                  'evidence' => { 'kind' => 'translation', 'source_formula' => c['formula'] },
                  'detail' => "source calc #{c['name'].inspect} is COUNTD(...) but the emitted translation " \
                              'aggregates with Sum() — a distinct count is not additive',
                  'status' => 'unresolved')
      end
    end

    # emitted formulas: (a)/(b) additive consumption + (c) ratio consumption.
    cols.each do |col|
      masked, tokens = CalcCoverage.mask(col['formula'])
      additive_arg_refs(masked, tokens).each do |fn, refs|
        refs.each do |ref|
          t = terminal(ref)
          next unless t
          if (preagg = lod_by_key[norm(t)])
            next if norm(col['name']) == norm(preagg) && col['grouped'] # grouped re-stage = the sanctioned helper
            push.call('class' => 'additive-over-preagg', 'context' => col['spec'],
                      'element' => col['element'], 'consumer' => col['name'],
                      'preagg' => preagg, 'formula' => col['formula'],
                      'evidence' => { 'kind' => 'lod-census', 'aggregate' => fn },
                      'detail' => "#{fn}() over #{preagg.inspect} — an LOD pre-aggregate consumed additively " \
                                  'in the emitted spec (mixed-grain consumption)',
                      'status' => 'unresolved')
          elsif (src = countd_by_key[norm(t)]) && fn == 'SUM'
            push.call('class' => 'countd-as-sum', 'context' => col['spec'],
                      'element' => col['element'], 'consumer' => col['name'],
                      'preagg' => src, 'formula' => col['formula'],
                      'evidence' => { 'kind' => 'consumption' },
                      'detail' => "Sum() over #{src.inspect} — a COUNTD-derived column consumed additively; " \
                                  'a distinct count is not additive',
                      'status' => 'unresolved')
          end
        end
      end
      next unless ratio?(masked)
      Array(tokens[:fields]).each do |ref|
        t = terminal(ref)
        next unless t && preagg_name?(t)
        push.call('class' => 'preagg-ratio', 'context' => col['spec'],
                  'element' => col['element'], 'consumer' => col['name'],
                  'preagg' => t, 'formula' => col['formula'],
                  'evidence' => { 'kind' => 'name-heuristic' },
                  'detail' => "emitted ratio formula consumes #{t.inspect} — pre-aggregate-named column " \
                              'in a KPI numerator/denominator position',
                  'status' => 'unresolved')
      end
    end

    # -- landing-manifest grain check (only when grain info EXISTS) -----------
    grain_by_table = {}
    lm_entries = landing_manifest.is_a?(Hash) ? (landing_manifest['entries'] || landing_manifest['tables']) : landing_manifest
    Array(lm_entries).each do |e|
      next unless e.is_a?(Hash) && e['grain'].is_a?(Array) && !e['grain'].empty?
      keys = []
      keys << e['sf_table'].to_s.gsub(/"/, '').split('.').last
      keys << e['hyper_table']
      keys << e['caption']
      keys.each { |k| grain_by_table[norm(k)] = e['grain'] unless norm(k).empty? }
    end
    unless grain_by_table.empty?
      [[dm_spec, 'dm-spec'], [wb_spec, 'wb-spec']].each do |spec, label|
        next unless spec.is_a?(Hash)
        (spec['pages'] || []).each do |pg|
          (pg['elements'] || []).each do |el|
            src = el['source']
            next unless src.is_a?(Hash) && src['kind'] == 'warehouse-table'
            table = Array(src['path']).last.to_s
            grain = grain_by_table[norm(table)]
            next unless grain
            el_cols = Array(el['columns'])
            by_id = {}
            el_cols.each { |c| by_id[c['id']] = c if c.is_a?(Hash) }
            group_names = Array(el['groupings']).flat_map { |g| Array(g.is_a?(Hash) ? g['groupBy'] : nil) }
                                                .map { |cid| (by_id[cid] || {})['name'].to_s }.reject(&:empty?)
            next if group_names.empty?
            grain_n = grain.map { |g| norm(g) }
            outside = group_names.reject { |g| grain_n.include?(norm(g)) }
            next if outside.empty?
            el_cols.each do |c|
              next unless c.is_a?(Hash) && c['formula'].to_s =~ ADDITIVE_CALL_RE
              push.call('class' => 'additive-over-preagg', 'context' => label,
                        'element' => (el['name'] || el['id']).to_s, 'consumer' => c['name'].to_s,
                        'preagg' => table, 'formula' => c['formula'].to_s,
                        'evidence' => { 'kind' => 'landing-grain', 'grain' => grain, 'group_by' => group_names,
                                        'outside_grain' => outside },
                        'detail' => "landed table #{table} declares grain (#{grain.join(', ')}) but the tile " \
                                    "groups by #{outside.join(', ')} while additively aggregating — the landed " \
                                    'rows are already aggregates at a coarser grain',
                        'status' => 'unresolved')
            end
          end
        end
      end
    end

    carry_resolutions(entries, prior)
    entries
  end

  # ---- resolutions ----------------------------------------------------------

  def carry_resolutions(entries, prior)
    prior_entries = prior.is_a?(Hash) ? prior['entries'] : prior
    return entries unless prior_entries.is_a?(Array)
    by_key = {}
    prior_entries.each do |e|
      next unless e.is_a?(Hash) && e['resolution'].is_a?(Hash)
      k = %w[class context element consumer preagg formula].map { |f| e[f].to_s }.join(" ")
      by_key[k] ||= e['resolution']
    end
    entries.each do |e|
      k = %w[class context element consumer preagg formula].map { |f| e[f].to_s }.join(" ")
      res = by_key[k]
      e['resolution'] = res if res
    end
    entries
  end

  def resolved?(entry)
    entry['resolution'].is_a?(Hash) && RESOLUTION_HOWS.include?(entry['resolution']['how'].to_s)
  end

  def write(path, entries)
    File.write(path, JSON.pretty_generate(
                       'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                       'note'         => NOTE,
                       'entries'      => entries
                     ))
    path
  end

  # Hash access tolerant of string/symbol keys (calc-fields.json is written
  # with symbol keys in-process and read back with string keys).
  def fetch(h, key)
    return nil unless h.is_a?(Hash)
    h[key] || h[key.to_sym]
  end
end
