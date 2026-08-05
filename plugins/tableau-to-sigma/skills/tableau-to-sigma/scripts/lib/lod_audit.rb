# frozen_string_literal: true
#
# lod_audit.rb — derive the LOD TRANSLATION LEDGER (<workdir>/lod-audit.json):
# the "refuse to guess" contract for Tableau Level-of-Detail calcs (#423).
#
# WHY: the calc translation path has NO row-level Sigma equivalent for
# {FIXED/INCLUDE/EXCLUDE} — the documented strategy is a grouped helper element
# (two-stage grouped element or grouped Custom SQL, surfaced through a
# FIXED-style relationship; refs/phase-3-datamodel.md, refs/window-functions.md).
# When that synthesis does NOT fire (cross-table grain, unresolved dims, no view
# context), the calc's caption can still collide with a look-alike RAW column
# via display-name/agg-prefix matching downstream — the emitted measure then
# reads an unrelated physical column (silently wrong numbers) — or the calc is
# emitted nowhere at all (silently dropped). Field failure (#423): of 12
# {FIXED company: COUNTD(...)} measures, 5 were aliased to unrelated raw flag
# columns and 7 vanished, with zero errors anywhere in the pipeline.
#
# The ledger records one entry per source calc whose formula contains a
# {FIXED/INCLUDE/EXCLUDE} block (masked scan — a '{FIXED' inside a string
# literal or comment does not count), classified against the emitted
# dm-spec/wb-spec:
#
#   lod-synth         resolved — a translation derived from the LOD machinery
#                     exists: a column on a GROUPED element (two-stage helper),
#                     a grouped Custom SQL element, a FIXED/INCLUDE/EXCLUDE
#                     relationship surfacing ref, or a window-function formula.
#   manual-residue    resolved — an explicit <workdir>/manual-residues.json
#                     entry declares the calc a manual translation (gate 15
#                     polices built/unbuilt; this ledger only requires the
#                     declaration to be EXPLICIT).
#   reference-derived resolved — the emitted formula RE-AGGREGATES the LOD
#                     expression's OWN OUTPUT field (e.g. a re-aggregation of the
#                     LOD's base measure at chart grain). A non-aggregating
#                     passthrough of a column that appears ONLY in the LOD's
#                     filter condition does NOT qualify — that is a fuzzy alias
#                     (#452), classified suspect-alias below.
#   suspect-alias     UNRESOLVED — an emitted column carries the calc's name but
#                     its formula either references a base/physical column that
#                     is NOT in the LOD expression's own reference set, OR is a
#                     non-aggregating passthrough of a column that appears only
#                     in the LOD expression's filter condition (#452): the
#                     fuzzy-alias case, numbers silently wrong.
#   silently-dropped  UNRESOLVED — no emitted translation and no manual-residue
#                     declaration anywhere.
#
# An EMPTY ledger is still written — its presence is the gate's evidence that
# the audit ran and found nothing. assert-phase6-ran.rb gate 17 (exit 24)
# refuses GREEN while any entry is unresolved. Sanctioned resolutions:
#   - record the manual translation in manual-residues.json and re-run the
#     audit (the entry re-classifies as manual-residue), or
#   - scripts/audit-lod-calcs.rb --resolve <i> --how <manual|waived> --reason
#     "..." (mirrors probe-join-keys.rb; the evidence lives in the ledger).
#
# Ruby 2.6-compatible. Offline, deterministic (no network).

require 'json'
require_relative 'calc_coverage'
require_relative 'sql_ident_check'

module LodAudit
  GRAIN_NOTE = 'A {FIXED/INCLUDE/EXCLUDE} calc must translate to the documented LOD strategy ' \
               '(grouped helper element / grouped Custom SQL / FIXED-relationship surfacing / ' \
               'window function) or be an explicit manual residue — never fuzzy-aliased to a ' \
               'look-alike raw column, never dropped silently.'

  UNRESOLVED_CLASSES = %w[suspect-alias silently-dropped].freeze
  RESOLUTION_HOWS    = %w[manual waived].freeze

  # Formula fragments that prove a column was derived by the LOD machinery
  # rather than aliased to a raw column: a relationship surfacing ref
  # ([Fact/FIXED Year/Revenue World]) or a Sigma window function.
  LOD_REL_REF_RE = %r{\[[^\]]+/\s*(?:FIXED|INCLUDE|EXCLUDE)[^/\]]*/[^\]]+\]}i
  WINDOW_FN_RE   = /\b(?:Lag|Lead|Rank|RankDense|RankPercentile|RowNumber|PercentOfTotal|
                       Cumulative\w+|Moving\w+|FirstNonNull|LastNonNull|First|Last)\s*\(/xi

  # Aggregation functions whose presence in an EMITTED formula proves it
  # RE-AGGREGATES the LOD's measure (a genuine reference-derivation) rather than
  # merely passing a raw column through. Tableau + Sigma spellings.
  AGG_FN_RE = /\b(?:COUNTDISTINCT|COUNTD|COUNT|SUM|AVG|AVERAGE|MIN|MAX|
                    MEDIAN|STDEV\w*|VAR\w*|ATTR|TOTAL)\s*\(/xi

  # Comparison operators that mark a bracket ref as a FILTER PREDICATE (the
  # IF/CASE/boolean condition that GATES an LOD aggregate — e.g. [flag] = "X").
  # Multi-char operators are listed first so the alternation matches greedily.
  COMPARATOR_RE = /(?:<=|>=|<>|!=|==|=|<|>)/.freeze

  module_function

  # Case/punctuation-insensitive normalization — one key space for display
  # names ('Enterprise Licenses') and physical names (ENTERPRISE_LICENSES).
  def norm(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # ---- source LOD calc census ----------------------------------------------

  # From a parsed calc-fields.json doc ({'calcs'=>[...]}) or a bare calc array.
  # Masked scan (CalcCoverage) so LOD keywords inside string literals/comments
  # never count. Returns [{'calc','internal_name','lod_kind','formula',
  # 'reference_set'}].
  def lod_calcs(calc_fields_doc)
    calcs = calc_fields_doc.is_a?(Hash) ? Array(calc_fields_doc['calcs']) : Array(calc_fields_doc)
    seen = {}
    out = []
    calcs.each do |c|
      next unless c.is_a?(Hash)
      f = fetch(c, 'formula').to_s
      next if f.empty?
      masked, tokens = CalcCoverage.mask(f)
      kind = CalcCoverage.lod_kind(masked)
      next unless kind
      name = fetch(c, 'name').to_s
      name = fetch(c, 'internal_name').to_s if name.empty?
      key = [name, f]
      next if seen[key]
      seen[key] = true
      out << {
        'calc'          => name,
        'internal_name' => fetch(c, 'internal_name').to_s,
        'lod_kind'      => kind,
        'formula'       => f,
        'reference_set' => reference_set(tokens, c)
      }
    end
    out
  end

  # Fallback census straight from .twb XML (no calc-fields.json): every
  # <column> carrying a tableau <calculation formula> whose masked formula is
  # an LOD. Parsing via lib/twb_xml.rb (same seam as join_plan.rb).
  def lod_calcs_from_twb(twb_text)
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
    lod_calcs('calcs' => recs)
  end

  # The LOD expression's OWN reference set: every bracket field ref in the
  # formula (parameters excluded — they are controls, not columns) plus the
  # calc record's depends_on captions (resolves GUID/internal refs to names).
  def reference_set(tokens, calc_rec = {})
    names = Array(tokens[:fields]).map { |r| r.to_s.gsub(/\A\[|\]\z/, '') }
    names = names.reject { |r| r == 'Parameters' || r.start_with?('Parameters.') }
    names += Array(fetch(calc_rec, 'depends_on')).map(&:to_s)
    names += Array(fetch(calc_rec, 'depends_on_internal')).map { |r| r.to_s.gsub(/\A\[|\]\z/, '') }
    names.map(&:strip).reject(&:empty?).uniq
  end

  # ---- emitted-spec index ---------------------------------------------------

  # Flatten every column (and converter 'metrics') of every element in a spec
  # into audit-ready records.
  def emitted_columns(spec, spec_label)
    return [] unless spec.is_a?(Hash)
    out = []
    (spec['pages'] || []).each do |pg|
      (pg['elements'] || []).each do |el|
        el_name = (el['name'] || el['id']).to_s
        grouped = el['groupings'].is_a?(Array) && !el['groupings'].empty?
        stmt = el.dig('source', 'kind') == 'sql' ? el.dig('source', 'statement').to_s : ''
        sql_grouped = stmt =~ /\bGROUP\s+BY\b/i ? true : false
        (Array(el['columns']) + Array(el['metrics'])).each do |col|
          next unless col.is_a?(Hash)
          out << {
            'spec'        => spec_label,
            'element'     => el_name,
            'name'        => col_display(col),
            'formula'     => col['formula'].to_s,
            'grouped'     => grouped,
            'sql_grouped' => sql_grouped,
            'sql_stmt'    => stmt
          }
        end
      end
    end
    out
  end

  def col_display(col)
    return col['name'].to_s if col['name'] && !col['name'].to_s.empty?
    m = col['formula'].to_s.match(/\A\s*\[([^\]]+)\]\s*\z/)
    m ? m[1].split('/').last : ''
  end

  # ---- classification -------------------------------------------------------

  # calcs: lod_calcs output. dm_spec/wb_spec: parsed spec Hashes (or nil).
  # manual_residues: parsed manual-residues.json (or nil). prior: previously
  # written ledger doc/entries — unresolved entries carry their recorded
  # resolution forward across re-derivation (same calc + formula).
  def derive(calcs, dm_spec: nil, wb_spec: nil, manual_residues: nil, prior: nil)
    cols = emitted_columns(dm_spec, 'dm-spec') + emitted_columns(wb_spec, 'wb-spec')
    residues = residue_index(manual_residues)
    tindex = spec_table_index(dm_spec, wb_spec)
    entries = Array(calcs).map { |c| classify(c, cols, residues, tindex) }
    carry_resolutions(entries, prior)
    entries
  end

  def classify(calc, cols, residues, table_index = {})
    name_n = norm(calc['calc'])
    ref_ns = Array(calc['reference_set']).map { |r| norm(r) }.reject(&:empty?)
    allowed = ref_ns + [name_n]

    matches = name_n.empty? ? [] : cols.select { |c| norm(c['name']) == name_n }
    # Wave-2 §6.6: a grouped Custom-SQL helper is synth evidence ONLY when its
    # FROM table exists among the spec's own base elements AND owns every
    # identifier the statement reads (the field failure: `SELECT DATE_MONTH,
    # SUM(VISIT_REVENUE) FROM …DIM_DATES` — a fact measure aggregated off the
    # date dim — was marked lod-synth/resolved on name match alone and sailed
    # through gate 17). Validation runs only when an ownership oracle exists
    # (>=1 warehouse-table element in the specs) — an all-Custom-SQL model has
    # nothing to verify against and keeps the legacy behavior.
    sql_problems = {}
    matches.each do |c|
      next unless c['sql_grouped']
      prob = sql_from_problem(c['sql_stmt'], table_index)
      sql_problems[c.object_id] = prob if prob
    end
    synth = matches.select do |c|
      if sql_problems.key?(c.object_id)
        false
      elsif sql_problems.any? && !c['grouped'] && !c['sql_grouped'] &&
            c['formula'].to_s =~ LOD_REL_REF_RE && c['formula'].to_s !~ WINDOW_FN_RE
        # A FIXED-relationship surfacing ref rides on the helper it surfaces —
        # when this calc's helper failed FROM/ownership validation, the ref is
        # a window onto the same wrong-FROM SQL, not independent evidence.
        false
      else
        synth_evidence(c)
      end
    end
    suspect = []
    derived = []
    # A wrong-FROM helper is an INVALID translation, not a missing one — feed
    # it to the suspect flow so the entry is unresolved with the SQL verdict.
    matches.each do |c|
      next unless (prob = sql_problems[c.object_id])
      suspect << [c, prob[:idents], :sqlfrom, prob[:reason]]
    end
    matches.each do |c|
      next if synth.include?(c)
      next if sql_problems.key?(c.object_id) # already queued with the SQL verdict
      terms = terminal_refs(c['formula'])
      next if terms.empty? || terms.all? { |t| norm(t) == name_n } # passthrough of own name — not evidence
      alien = terms.reject { |t| allowed.include?(norm(t)) }
      unless alien.empty?
        suspect << [c, alien, :alien] # reads a column OUTSIDE the LOD's reference set
        next
      end
      # Every ref is INSIDE the LOD's own reference set — but that alone is not
      # enough to call the column reference-derived (#452). "reference-derived"
      # means the emitted formula RE-AGGREGATES the LOD's OUTPUT field; an
      # emitted formula that merely NAMES a column appearing only in the LOD's
      # FILTER CONDITION (a non-aggregating passthrough of a filter-predicate
      # column) is the same silent-alias failure as #423 — flag it, don't
      # resolve it.
      if reference_derived?(c, calc, name_n)
        derived << c
      else
        suspect << [c, filter_alias_refs(c, calc, name_n), :filter]
      end
    end

    entry = {
      'calc'          => calc['calc'],
      'internal_name' => calc['internal_name'],
      'lod_kind'      => calc['lod_kind'],
      'formula'       => calc['formula'],
      'reference_set' => calc['reference_set']
    }
    if synth.any?
      entry['class']  = 'lod-synth'
      entry['status'] = 'resolved'
      entry['evidence'] = evidence(synth.first)
    elsif residues[name_n]
      entry['class']  = 'manual-residue'
      entry['status'] = 'resolved'
      entry['evidence'] = { 'kind' => 'manual-residues.json', 'calc' => residues[name_n]['calc'],
                            'residue_status' => residues[name_n]['status'].to_s }
    elsif suspect.any?
      col, refs, kind, why = suspect.first
      entry['class']  = 'suspect-alias'
      entry['status'] = 'unresolved'
      entry['evidence'] = evidence(col)
      entry['suspect_refs'] = refs
      entry['detail'] = suspect_detail(refs, kind, why)
    elsif derived.any?
      entry['class']  = 'reference-derived'
      entry['status'] = 'resolved'
      entry['evidence'] = evidence(derived.first)
    else
      entry['class']  = 'silently-dropped'
      entry['status'] = 'unresolved'
      entry['detail'] = 'no emitted dm-spec/wb-spec translation carries this calc\'s name and no ' \
                        'manual-residues.json entry declares it — the calc vanished with no signal'
    end
    # A resolved calc can STILL have a mis-aliased twin column somewhere — keep
    # that visible without blocking (the operator verifies it at Phase 6).
    if entry['status'] == 'resolved' && suspect.any?
      col, refs, = suspect.first
      entry['also_suspect'] = evidence(col).merge('suspect_refs' => refs)
    end
    entry
  end

  # Human-readable detail for a suspect-alias entry: the three shapes of the
  # same silent failure — reading a column OUTSIDE the LOD's reference set, a
  # non-aggregating passthrough of one of its FILTER-CONDITION columns (#452),
  # or a grouped Custom-SQL helper whose FROM table fails ownership validation
  # (wave-2 §6.6 — the wrong-FROM class).
  def suspect_detail(refs, kind, why = nil)
    quoted = Array(refs).map(&:inspect).join(', ')
    case kind
    when :sqlfrom
      "the grouped Custom-SQL helper is NOT a valid translation: #{why} — re-point the helper's FROM " \
        '(mis-elected fact? re-run with --fact-table NAME) or record the manual translation'
    when :filter
      "emitted formula is a non-aggregating passthrough of #{quoted} — a column named only in the " \
        "LOD expression's FILTER CONDITION, not its aggregated output (fuzzy filter-alias: the " \
        'numbers are silently wrong)'
    else
      "emitted formula reads #{quoted} — not in the LOD expression's own reference set " \
        '(fuzzy name-alias: the numbers are silently wrong)'
    end
  end

  def synth_evidence(col)
    return true if col['grouped'] || col['sql_grouped']
    f = col['formula'].to_s
    return true if f =~ LOD_REL_REF_RE
    f =~ WINDOW_FN_RE ? true : false
  end

  # ---- wrong-FROM validation for grouped Custom-SQL helpers (wave-2 §6.6) ---

  # Ownership index from the emitted specs' own base elements: warehouse table
  # tail (upcased) => identifiers the table is known to own — each base
  # column's display name, its formula bracket-tail (the physical ref when the
  # two differ), and their upper-snake normalizations (the spelling the
  # converter emits into helper SQL). Role-playing duplicates (two elements
  # over one physical table) merge into one entry.
  def spec_table_index(*specs)
    idx = {}
    specs.compact.each do |spec|
      next unless spec.is_a?(Hash)
      (spec['pages'] || []).each do |pg|
        (pg['elements'] || []).each do |el|
          next unless el.is_a?(Hash) && el.dig('source', 'kind') == 'warehouse-table'
          tail = (el.dig('source', 'path') || []).last.to_s.upcase
          next if tail.empty?
          names = (idx[tail] ||= [])
          (Array(el['columns']) + Array(el['metrics'])).each do |c|
            next unless c.is_a?(Hash)
            tailref = c['formula'].to_s[/\A\s*\[([^\]]+)\]\s*\z/, 1].to_s.split('/').last.to_s
            [c['name'].to_s, tailref].each do |n|
              n = n.strip
              next if n.empty?
              names << n unless names.include?(n)
              nn = SqlIdentCheck.normalize(n)
              names << nn unless nn.empty? || names.include?(nn)
            end
          end
        end
      end
    end
    idx
  end

  # Validate a grouped Custom-SQL helper's FROM/ownership against the spec's
  # own base elements. Returns nil when the statement verifies — or when no
  # ownership oracle exists (empty index, or no parsable base table) — else
  # {reason:, idents:} for the suspect flow. Uses the same identifier oracle
  # as the pre-POST sql-ident gate (lib/sql_ident_check).
  def sql_from_problem(stmt, table_index)
    return nil if stmt.to_s.strip.empty? || !table_index.is_a?(Hash) || table_index.empty?
    tables = begin
      SqlIdentCheck.scan(stmt)[:tables].map { |t| t[:name].to_s.upcase }
                   .reject { |t| t.empty? || t.start_with?('__') }.uniq
    rescue StandardError
      []
    end
    return nil if tables.empty?
    missing = tables.reject { |t| table_index.key?(t) }
    if missing.any?
      return { reason: "its FROM table #{missing.join(', ')} is not a base element of the emitted " \
                       'spec — the helper aggregates off a table the model does not own',
               idents: missing }
    end
    res = begin
      SqlIdentCheck.check(stmt, table_index.select { |t, _| tables.include?(t) })
    rescue StandardError
      return nil # oracle failure is never a trip — only verified findings are
    end
    return nil if res[:ok]
    bad = Array(res[:unknown]).map { |u| u[:identifier].to_s }.uniq
    { reason: "its FROM table (#{tables.join(', ')}) does not own #{bad.map(&:inspect).join(', ')} — " \
              'wrong-FROM helper SQL: the query fails at run time or silently reads the wrong table',
      idents: bad }
  end

  # Terminal name of every bracket ref in an emitted Sigma formula:
  # [Master/Net Revenue] -> 'Net Revenue', [FACT/ENTITY_FLAG] -> 'ENTITY_FLAG',
  # [Sales] -> 'Sales'. Control refs ([ctl-...]) are skipped.
  def terminal_refs(formula)
    formula.to_s.scan(/\[([^\]]+)\]/).flatten.map do |r|
      seg = r.split('/').last.to_s.strip
      seg =~ /\Actl-/ ? nil : seg
    end.compact.reject(&:empty?).uniq
  end

  # True when the emitted column is a GENUINE re-aggregation of the LOD's own
  # output: either it applies an aggregation function itself, or (non-aggregating)
  # every non-name ref it carries is one of the LOD's aggregated-output /
  # dimension refs — NOT a column that appears ONLY in the LOD's filter condition
  # (#452: a bare passthrough of a filter-predicate column is a fuzzy alias, not
  # a translation of the COUNTD/SUM output).
  def reference_derived?(col, calc, name_n)
    return true if col['formula'].to_s =~ AGG_FN_RE
    outputs = agg_output_refs(calc['formula']).map { |r| norm(r) }
    preds   = filter_predicate_refs(calc['formula']).map { |r| norm(r) }
    emitted = terminal_refs(col['formula']).map { |t| norm(t) }.reject { |t| t.empty? || t == name_n }
    # a ref used ONLY as a filter predicate (never as the aggregated output) is
    # not evidence of derivation.
    emitted.none? { |r| preds.include?(r) && !outputs.include?(r) }
  end

  # The emitted formula's terminal refs that name a filter-predicate-ONLY column
  # of the LOD — the fuzzy filter-alias evidence for #452 (original casing).
  def filter_alias_refs(col, calc, name_n)
    outputs = agg_output_refs(calc['formula']).map { |r| norm(r) }
    preds   = filter_predicate_refs(calc['formula']).map { |r| norm(r) }
    terminal_refs(col['formula']).select do |t|
      tn = norm(t)
      tn != name_n && preds.include?(tn) && !outputs.include?(tn)
    end
  end

  # Refs used as a FILTER PREDICATE inside the LOD expression: a bracket ref on
  # either side of a comparison operator — the IF/CASE/boolean condition that
  # GATES the aggregate (e.g. [flag] = "X"). These are NOT the aggregated
  # measure; a bare passthrough of one is a fuzzy alias, not a translation of the
  # LOD's aggregated output (#452).
  def filter_predicate_refs(formula)
    f = formula.to_s
    refs = []
    f.scan(/\[([^\]]+)\]\s*#{COMPARATOR_RE}/) { |m| refs << m[0] }
    f.scan(/#{COMPARATOR_RE}\s*\[([^\]]+)\]/) { |m| refs << m[0] }
    refs.map { |r| r.split('/').last.to_s.strip }.reject(&:empty?).uniq
  end

  # Bracket refs that are the AGGREGATED OUTPUT of the LOD: refs appearing inside
  # an aggregation function's argument, minus any used only as filter predicates.
  # For {FIXED d: COUNTD(IF [flag] = "X" THEN [key] END)} the output is [key],
  # not [flag].
  def agg_output_refs(formula)
    preds = filter_predicate_refs(formula).map { |r| norm(r) }
    agg_argument_refs(formula).reject { |r| preds.include?(norm(r)) }
  end

  # Terminal names of every bracket ref inside any aggregation function call.
  def agg_argument_refs(formula)
    f = formula.to_s
    refs = []
    f.scan(AGG_FN_RE) do
      m = Regexp.last_match
      refs.concat(terminal_refs(balanced_paren_slice(f, m.end(0) - 1)))
    end
    refs.uniq
  end

  # The substring inside the balanced parentheses that OPEN at open_idx (the
  # index of a '(' in str). Paren-matching is literal (string literals are not
  # treated specially) — adequate for the LOD shapes we classify.
  def balanced_paren_slice(str, open_idx)
    depth = 0
    i = open_idx
    while i < str.length
      c = str[i]
      depth += 1 if c == '('
      depth -= 1 if c == ')'
      return str[(open_idx + 1)...i] if depth.zero?
      i += 1
    end
    str[(open_idx + 1)..-1] || ''
  end

  def evidence(col)
    { 'spec' => col['spec'], 'element' => col['element'],
      'column' => col['name'], 'formula' => col['formula'] }
  end

  def residue_index(manual_residues)
    entries = manual_residues.is_a?(Hash) ? manual_residues['residues'] : manual_residues
    idx = {}
    Array(entries).each do |e|
      next unless e.is_a?(Hash)
      k = norm(e['calc'])
      idx[k] ||= e unless k.empty?
    end
    idx
  end

  def carry_resolutions(entries, prior)
    prior_entries = prior.is_a?(Hash) ? prior['entries'] : prior
    return entries unless prior_entries.is_a?(Array)
    by_key = {}
    prior_entries.each do |e|
      next unless e.is_a?(Hash) && e['resolution'].is_a?(Hash)
      by_key[[e['calc'].to_s, e['formula'].to_s]] ||= e['resolution']
    end
    entries.each do |e|
      next unless UNRESOLVED_CLASSES.include?(e['class'])
      res = by_key[[e['calc'].to_s, e['formula'].to_s]]
      e['resolution'] = res if res
    end
    entries
  end

  def resolved?(entry)
    return true unless UNRESOLVED_CLASSES.include?(entry['class'].to_s)
    entry['resolution'].is_a?(Hash) && RESOLUTION_HOWS.include?(entry['resolution']['how'].to_s)
  end

  def write(path, entries)
    File.write(path, JSON.pretty_generate(
                       'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                       'note'         => GRAIN_NOTE,
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
