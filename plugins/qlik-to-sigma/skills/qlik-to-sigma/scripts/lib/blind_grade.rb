# frozen_string_literal: true
#
# blind_grade.rb — validation + anti-gaming cross-check for the PR-9 blind
# visual grade (blind-grade.json, written by a CONTEXT-FREE subagent driven by
# refs/blind-grader-brief.md).
#
# WHY. The field failure this closes: the builder agent self-graded its own
# workbook 6/6 PASS on visuals the customer rejected. The visual verdict must
# come from a grader with no run context — this module is the mechanical side
# of that contract:
#
#   * load_and_validate — the grade file parses, carries every checklist
#     dimension, and is HASH-BOUND: the sha256s it records must equal the
#     sha256s of the actual image files on disk (computed here, never trusted).
#     A grade whose hashes don't match the pixels graded is no evidence at all.
#   * cross_check — the grader's per-tile chart-family readings are compared
#     against the mechanical kind census (wb-readback.json for the target,
#     png-read.json for the source). A "grade" fabricated without reading the
#     images gets the families wrong; contradiction on more than
#     MAX_FAMILY_MISMATCHES tiles refuses the grade as inconsistent.
#
# Consumed by scripts/record-visual-check.rb (--blind-grade) and mirrored in
# spirit by assert-phase6-ran.rb gate 8b (shared canonical — it inlines the
# same checks because shared/ cannot require a plugin lib).

require 'json'
require 'digest'
require_relative 'code_rep'
# Ruby 2.6 floor (macOS system ruby): this file uses Enumerable#tally (2.7+).
# Polyfilled rather than rewritten -- see shared/lib/ruby_compat.rb.
require_relative 'ruby_compat'

module BlindGrade
  # The six checklist dimensions a visual verdict attests (kept in lockstep
  # with record-visual-check.rb CHECKLIST_KEYS / gate 8b).
  DIMENSION_KEYS = %w[element_titles_hidden palette_match composition_match
                      chart_shapes_match labels_legible numbers_formatted].freeze

  # Canonical chart families the grader may read off an image.
  CHART_FAMILIES = %w[bar line area combo scatter pie kpi map table].freeze
  # Sigma navigation / button / control / layout-only element kinds are never
  # charts: a Tableau source has no counterpart tile for them in the grader's
  # per_tile, so counting them as 'other' (chart-ish) produced phantom census
  # mismatches (9 nav buttons > MAX_FAMILY_MISMATCHES).
  NON_CHART_FAMILIES = %w[text control image container divider missing
                          button navigation spacer].freeze

  SCHEMA_V1 = 'blind-grade/v1'
  SCHEMA_V2 = 'blind-grade/v2'
  PASS_SCORE = 75
  BORDERLINE = 5
  GAP_SEVERITIES = %w[major minor].freeze

  # Element/tile "kind" strings (Sigma element kinds, png-read kinds, or the
  # grader's own vocabulary) → canonical family. Unknown chart-ish strings
  # normalize to 'other' (which matches nothing — an honest mismatch).
  FAMILY_SYNONYMS = {
    'bar' => 'bar', 'bar-chart' => 'bar', 'column' => 'bar', 'column-chart' => 'bar',
    'line' => 'line', 'line-chart' => 'line', 'sparkline' => 'line',
    'area' => 'area', 'area-chart' => 'area',
    'combo' => 'combo', 'combo-chart' => 'combo', 'dual-axis' => 'combo',
    'scatter' => 'scatter', 'scatter-chart' => 'scatter', 'bubble' => 'scatter',
    'pie' => 'pie', 'pie-chart' => 'pie', 'donut' => 'pie', 'donut-chart' => 'pie',
    'kpi' => 'kpi', 'kpi-chart' => 'kpi', 'single-value' => 'kpi', 'big-number' => 'kpi',
    'map' => 'map', 'region-map' => 'map', 'point-map' => 'map',
    'table' => 'table', 'pivot-table' => 'table', 'pivot' => 'table',
    'crosstab' => 'table', 'text-table' => 'table', 'grid' => 'table',
    'text' => 'text', 'control' => 'control', 'image' => 'image',
    'container' => 'container', 'divider' => 'divider', 'missing' => 'missing',
    # Sigma button / navigation / control / layout element kinds (see
    # sigma-workbooks reference: content-elements.md, controls.md, layout.md).
    'button' => 'button', 'navigation' => 'navigation', 'tabs' => 'navigation',
    'tab' => 'navigation', 'spacer' => 'spacer',
    'tabbed-container' => 'container', 'repeated-container' => 'container',
    'page-break' => 'divider', 'form' => 'control', 'embed' => 'container',
    'chat' => 'control', 'filter' => 'control', 'param-filter' => 'control',
    'dashboard-filter' => 'control', 'chapter-filter' => 'control'
  }.freeze

  # A blind grade may honestly disagree with the census on ONE tile (census
  # granularity vs visual reading, e.g. a combo read as line). Two or more
  # contradictions = the families were not read off the image → refuse.
  MAX_FAMILY_MISMATCHES = 1

  # A grader that cannot tell a tile's family may say so: a per_tile family of
  # literally "other" or "unknown" is CAN'T-TELL, not a reading. Such tiles are
  # left out of the family comparison and may stand in for census tiles the
  # grader did not name; they never count as a contradiction (live: Stress 4,
  # 2026-11-09). An unrecognised kind string (e.g. "treemap") still normalises
  # to 'other' and stays an honest mismatch, and a named family swap (bar read
  # as line) is still a contradiction. Can't-tell may account for at most HALF
  # the census (a grade that files every tile "other" read nothing and stays
  # refused).
  CANT_TELL_FAMILIES = %w[other unknown].freeze

  module_function

  def family(kind)
    k = kind.to_s.strip.downcase
    return FAMILY_SYNONYMS[k] if FAMILY_SYNONYMS[k]
    return 'control' if k.end_with?('-control') # list-control, date-control, ...
    NON_CHART_FAMILIES.include?(k) ? k : 'other'
  end

  def chart_family?(fam)
    CHART_FAMILIES.include?(fam) || fam == 'other'
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def resolve(path, workdir)
    return nil if path.to_s.empty?
    File.expand_path(path.to_s, workdir)
  end

  # → { doc:, errors: [..], source_path:, target_path: }
  # errors empty ⇔ the grade parses, is complete, and is hash-bound to the
  # image files on disk. Does NOT judge pass/fail — the caller does.
  def load_and_validate(path, workdir:, catalog: nil)
    errors = []
    unless File.file?(path.to_s)
      return { 'doc' => nil, 'errors' => ["blind grade file not found: #{path}"] }
    end
    doc = begin
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      return { 'doc' => nil, 'errors' => ["blind grade is not valid JSON: #{e.message}"] }
    end
    return { 'doc' => nil, 'errors' => ['blind grade must be a JSON object'] } unless doc.is_a?(Hash)

    schema = doc['schema'].to_s
    v2 = schema == SCHEMA_V2
    unless schema.empty? || schema == SCHEMA_V1 || v2
      errors << "unknown schema #{doc['schema'].inspect} (expected #{SCHEMA_V1} or #{SCHEMA_V2})"
    end

    src = resolve(doc['source_png'], workdir)
    tgt = resolve(doc['target_png'], workdir)
    errors << 'source_png missing from the grade (the grader must record both image paths)' if src.nil?
    errors << 'target_png missing from the grade (the grader must record both image paths)' if tgt.nil?
    %w[source_sha256 target_sha256].each do |k|
      errors << "#{k} missing/malformed (need 64-hex sha256)" unless doc[k].to_s =~ /\A[0-9a-f]{64}\z/i
    end

    if src && !File.file?(src)
      errors << "source image not on disk: #{src}"
    elsif src && doc['source_sha256'].to_s =~ /\A[0-9a-f]{64}\z/i && sha256(src) != doc['source_sha256'].to_s.downcase
      errors << "source_sha256 does NOT match #{src} — the grade is not bound to this image " \
                '(image changed since grading, or the hash was not computed from the file)'
    end
    if tgt && !File.file?(tgt)
      errors << "target image not on disk: #{tgt}"
    elsif tgt && doc['target_sha256'].to_s =~ /\A[0-9a-f]{64}\z/i && sha256(tgt) != doc['target_sha256'].to_s.downcase
      errors << "target_sha256 does NOT match #{tgt} — the grade is not bound to this image " \
                '(image changed since grading, or the hash was not computed from the file)'
    end

    dims = doc['dimensions']
    if dims.is_a?(Hash)
      missing = DIMENSION_KEYS.reject { |k| dims[k].is_a?(Hash) && %w[pass fail].include?(dims[k]['verdict'].to_s) }
      errors << "dimensions missing/invalid (need {verdict: pass|fail}): #{missing.join(', ')}" if missing.any?
    else
      errors << "dimensions missing — the grade must cover: #{DIMENSION_KEYS.join(', ')}"
    end

    pt = doc['per_tile']
    if !pt.is_a?(Array) || pt.empty? ||
       pt.any? { |t| !t.is_a?(Hash) || t['source_family'].to_s.empty? || t['target_family'].to_s.empty? }
      errors << 'per_tile missing/invalid — the grader must record {position, source_family, target_family} for every tile'
    end

    if v2
      # v2: the code computes the verdict from scores; a recorded one is optional.
      if doc.key?('verdict') && !%w[pass fail].include?(doc['verdict'].to_s)
        errors << "verdict must be pass|fail when present (got #{doc['verdict'].inspect})"
      end
      if catalog.nil?
        errors << 'catalog required for blind-grade/v2'
      else
        errors.concat(validate_v2(doc, catalog))
      end
    else
      errors << "verdict must be pass|fail (got #{doc['verdict'].inspect})" unless %w[pass fail].include?(doc['verdict'].to_s)
    end

    { 'doc' => doc, 'errors' => errors, 'source_path' => src, 'target_path' => tgt }
  end

  # --- blind-grade/v2: score-based rule + Sigma platform-difference catalog ---

  # → {'ids'=>[..], 'entries'=>[..], 'sha256'=>String|nil, 'errors'=>[..],
  #    'entry_hashes'=>{id=>sha}, 'history'=>{sha=>{id=>sha}},
  #    'history_errors'=>[..], 'history_path'=>String}
  # sha256 is the digest of the catalog FILE BYTES (== `shasum -a 256`), so a
  # grade stamped with it is bound to exactly this catalog. The sibling
  # <name>-history.json (tools/gen-catalog-history.rb) lists every earlier
  # catalog by sha with per-entry content hashes; catalog_compat uses it to
  # accept a grade made against an ANCESTOR catalog (see there).
  def load_catalog(path, history_path: nil)
    hist_path = history_path || history_path_for(path)
    out = parse_catalog_bytes(File.file?(path.to_s) ? File.binread(path) : nil, path)
    hist = load_history(hist_path)
    out.merge('history' => hist['records'], 'history_errors' => hist['errors'], 'history_path' => hist_path.to_s)
  end

  # The catalog-history file that sits next to a catalog file.
  def history_path_for(catalog_path)
    "#{catalog_path.to_s.sub(/\.json\z/, '')}-history.json"
  end

  # Parse catalog FILE BYTES (nil = file missing). Shared by load_catalog and
  # tools/gen-catalog-history.rb (which reads past revisions out of git).
  def parse_catalog_bytes(bytes, path = '(catalog)')
    empty = { 'ids' => [], 'entries' => [], 'sha256' => nil, 'entry_hashes' => {} }
    return empty.merge('errors' => ["catalog file not found: #{path}"]) if bytes.nil?
    digest = Digest::SHA256.hexdigest(bytes)
    doc = begin
      JSON.parse(bytes)
    rescue JSON::ParserError => e
      return empty.merge('sha256' => digest, 'errors' => ["catalog is not valid JSON: #{e.message}"])
    end
    errors = []
    unless doc.is_a?(Hash)
      return empty.merge('sha256' => digest, 'errors' => ['catalog must be a JSON object'])
    end
    errors << "catalog version must be 1 (got #{doc['version'].inspect})" unless doc['version'] == 1
    entries = doc['entries']
    unless entries.is_a?(Array)
      errors << 'catalog entries must be an Array'
      entries = []
    end
    seen = {}
    hashes = {}
    entries.each_with_index do |e, i|
      unless e.is_a?(Hash)
        errors << "catalog entry ##{i} must be an object"
        next
      end
      id = e['id'].to_s
      label = id.empty? ? "##{i}" : id.inspect
      errors << "catalog entry #{label}: id missing" if id.empty?
      errors << "catalog entry #{label}: id must be a string (got #{e['id'].class})" if !id.empty? && !e['id'].is_a?(String)
      errors << "catalog entry #{label}: duplicate id" if !id.empty? && seen[id]
      seen[id] = true unless id.empty?
      unless DIMENSION_KEYS.include?(e['dimension'].to_s)
        errors << "catalog entry #{label}: dimension #{e['dimension'].inspect} not one of #{DIMENSION_KEYS.join(', ')}"
      end
      %w[description evidence].each do |k|
        errors << "catalog entry #{label}: #{k} missing/empty" if e[k].to_s.strip.empty?
      end
      unless e['last_verified'].to_s =~ /\A\d{4}-\d{2}-\d{2}\z/
        errors << "catalog entry #{label}: last_verified must be YYYY-MM-DD (got #{e['last_verified'].inspect})"
      end
      if e.key?('source_tools') && !(e['source_tools'].is_a?(Array) && e['source_tools'].all? { |t| t.is_a?(String) })
        errors << "catalog entry #{label}: source_tools must be an Array of strings"
      end
      begin
        hashes[id] = entry_hash(e)
      rescue ArgumentError => ex
        errors << "catalog entry #{label}: #{ex.message}"
      end
    end
    ok = errors.empty?
    { 'ids' => ok ? entries.map { |e| e['id'].to_s } : [], 'entries' => entries, 'sha256' => digest,
      'entry_hashes' => ok ? hashes : {}, 'errors' => errors }
  end

  # ── catalog history (ancestor rule) ─────────────────────────────────────────
  HISTORY_SCHEMA = 'sigma-platform-differences-history/v1'
  HEX64 = /\A[0-9a-f]{64}\z/.freeze

  # Canonical JSON of one catalog entry, for its content hash. The Python twin
  # (tableau scripts/lib/blind_grade_v2.py) produces the same bytes: object keys
  # sorted by code point, no whitespace, every char outside printable ASCII
  # written as a lowercase \uXXXX (UTF-16 surrogate pairs above U+FFFF).
  # Floats are refused: Ruby and Python print them differently.
  def canonical_json(v)
    case v
    when Hash then "{#{v.keys.map(&:to_s).sort.map { |k| "#{canonical_str(k)}:#{canonical_json(v[k])}" }.join(',')}}"
    when Array then "[#{v.map { |x| canonical_json(x) }.join(',')}]"
    when String then canonical_str(v)
    when Integer then v.to_s
    when true then 'true'
    when false then 'false'
    when nil then 'null'
    else raise ArgumentError, "unsupported value #{v.class} in a catalog entry (strings, integers, booleans, null, arrays and objects only)"
    end
  end

  def canonical_str(str)
    out = +'"'
    str.to_s.each_codepoint do |cp|
      if cp == 0x22 then out << '\\"'
      elsif cp == 0x5c then out << '\\\\'
      elsif cp >= 0x20 && cp <= 0x7e then out << cp.chr
      elsif cp > 0xffff
        c = cp - 0x10000
        out << format('\\u%04x\\u%04x', 0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff))
      else out << format('\\u%04x', cp)
      end
    end
    out << '"'
  end

  def entry_hash(entry)
    Digest::SHA256.hexdigest(canonical_json(entry))
  end

  # → {'records'=>{sha=>{id=>entry_hash}}, 'errors'=>[..]}. Fails closed: any
  # malformed record empties the records, so no ancestor is accepted (the
  # exact current-sha match still works).
  def load_history(path)
    return { 'records' => {}, 'errors' => ["catalog history not found: #{path}"] } unless File.file?(path.to_s)
    doc = begin
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      return { 'records' => {}, 'errors' => ["catalog history is not valid JSON: #{e.message}"] }
    end
    errors = []
    errors << "catalog history schema must be #{HISTORY_SCHEMA}" unless doc.is_a?(Hash) && doc['schema'] == HISTORY_SCHEMA
    cats = doc.is_a?(Hash) ? doc['catalogs'] : nil
    errors << 'catalog history catalogs must be an Array' unless cats.is_a?(Array)
    records = {}
    Array(cats).each_with_index do |c, i|
      sha = c.is_a?(Hash) ? c['sha256'].to_s : ''
      ents = c.is_a?(Hash) ? c['entries'] : nil
      if sha !~ HEX64 || !ents.is_a?(Hash) || ents.any? { |id, h| id.to_s.empty? || h.to_s !~ HEX64 }
        errors << "catalog history record ##{i} is malformed (need {sha256: 64-hex, entries: {id: 64-hex}})"
      elsif records.key?(sha)
        errors << "catalog history lists #{sha} twice"
      else
        records[sha] = ents.map { |id, h| [id.to_s, h.to_s] }.to_h
      end
    end
    errors.empty? ? { 'records' => records, 'errors' => [] } : { 'records' => {}, 'errors' => errors }
  end

  # Is a grade stamped with catalog sha `graded_sha` still valid against the
  # shipped `catalog` (a load_catalog result)?
  #   * the current sha → ok, status 'current';
  #   * an ANCESTOR (a sha in the catalog history) whose every entry is still in
  #     the current catalog with identical content → ok, status 'ancestor',
  #     new_ids = entries added since. The grade's gaps stay exactly as graded
  #     (never re-mapped onto a new id); a re-grade to pick up new_ids is optional;
  #   * an ancestor that had an entry REMOVED or CHANGED since, or a sha the
  #     history does not know → refused (ok false, error names why).
  # → {'ok','status','error','reason','graded_sha256','current_sha256','graded_ids','new_ids'}
  def catalog_compat(graded_sha, catalog)
    g = graded_sha.to_s.strip.downcase
    cur = catalog['sha256'].to_s
    base = { 'graded_sha256' => g, 'current_sha256' => cur, 'graded_ids' => Array(catalog['ids']), 'new_ids' => [] }
    return base.merge('ok' => true, 'status' => 'current', 'error' => nil, 'reason' => nil) if !g.empty? && g == cur

    refused = lambda do |why|
      base.merge('ok' => false, 'status' => 'refused', 'graded_ids' => [], 'reason' => why,
                 'error' => "catalog_sha256 mismatch — grade stamped #{graded_sha.inspect} but the catalog on disk is " \
                            "#{catalog['sha256'].inspect}; #{why}")
    end
    rec = (catalog['history'] || {})[g]
    if rec.nil?
      hist = File.basename(catalog['history_path'].to_s)
      herr = Array(catalog['history_errors'])
      why = if herr.any?
              "the catalog history (#{hist}) is unusable (#{herr.join('; ')}), so no earlier catalog can be accepted"
            else
              "that sha is not an earlier catalog in #{hist.empty? ? 'the catalog history' : hist} (unknown catalog)"
            end
      return refused.call("#{why}. Re-grade against the shipped catalog")
    end
    cur_h = catalog['entry_hashes'] || {}
    removed = rec.keys.reject { |id| cur_h.key?(id) }
    changed = rec.keys.select { |id| cur_h.key?(id) && cur_h[id] != rec[id] }
    if removed.any? || changed.any?
      parts = []
      say = ->(ids, what) { "#{ids.length == 1 ? 'entry' : 'entries'} #{ids.join(', ')} #{ids.length == 1 ? 'was' : 'were'} #{what}" }
      parts << say.call(removed, 'REMOVED') if removed.any?
      parts << say.call(changed, 'CHANGED') if changed.any?
      return refused.call("that is an earlier catalog, but since then #{parts.join(' and ')} — a grade made against a " \
                          'retired or reworded platform difference must be re-graded against the shipped catalog')
    end
    base.merge('ok' => true, 'status' => 'ancestor', 'error' => nil, 'reason' => nil, 'graded_ids' => rec.keys,
               'new_ids' => Array(catalog['ids']).reject { |id| rec.key?(id) })
  end

  # → Array<String> errors for the v2-only fields of a grade doc.
  def validate_v2(doc, catalog)
    errors = []
    cat_ids = Array(catalog['ids'])
    compat = catalog_compat(doc['catalog_sha256'], catalog)
    scores = doc['scores']
    if scores.is_a?(Hash)
      DIMENSION_KEYS.each do |k|
        v = scores[k]
        unless v.is_a?(Integer) && v >= 0 && v <= 10
          errors << "scores.#{k} must be an integer 0..10 (got #{v.inspect})"
        end
      end
    else
      errors << "scores missing — v2 needs an integer 0..10 for each of: #{DIMENSION_KEYS.join(', ')}"
    end
    os = doc['overall_score']
    unless os.is_a?(Integer) && os >= 0 && os <= 100
      errors << "overall_score must be an integer 0..100 (got #{os.inspect})"
    end
    gaps = doc['gaps']
    if gaps.is_a?(Array)
      gaps.each_with_index do |g, i|
        unless g.is_a?(Hash)
          errors << "gaps[#{i}] must be an object"
          next
        end
        %w[tile description].each do |k|
          errors << "gaps[#{i}].#{k} missing" if g[k].to_s.strip.empty?
        end
        errors << "gaps[#{i}].dimension must be one of #{DIMENSION_KEYS.join(', ')} (got #{g['dimension'].inspect})" unless DIMENSION_KEYS.include?(g['dimension'].to_s)
        errors << "gaps[#{i}].severity must be major|minor (got #{g['severity'].inspect})" unless GAP_SEVERITIES.include?(g['severity'].to_s)
        cls = g['class'].to_s
        if cls.empty?
          errors << "gaps[#{i}].class missing (need \"fixable\" or a catalog id)"
        elsif cls != 'fixable' && !cat_ids.include?(cls)
          errors << "gaps[#{i}] cites unknown catalog id #{cls.inspect} — a platform difference must be a catalog entry (never invent one)"
        elsif cls != 'fixable' && compat['status'] == 'ancestor' && !compat['graded_ids'].include?(cls)
          errors << "gaps[#{i}] cites catalog id #{cls.inspect}, which was added AFTER the catalog this grade names " \
                    "(#{compat['graded_sha256'][0, 12]}…) — its grader could not have cited it; re-grade against the shipped catalog"
        elsif cls != 'fixable'
          entry = Array(catalog['entries']).find { |ce| ce.is_a?(Hash) && ce['id'].to_s == cls }
          if entry && g['dimension'].to_s != entry['dimension'].to_s
            errors << "gaps[#{i}] cites catalog id #{cls.inspect} (dimension #{entry['dimension'].inspect}) but the gap's dimension is #{g['dimension'].inspect} — a platform difference must sit on the dimension the catalog entry describes"
          end
        end
      end
    else
      errors << 'gaps must be an Array (use [] when there are none)'
    end
    errors << compat['error'] unless compat['ok']
    errors
  end

  # docs: ONE or TWO v2 docs already accepted by load_and_validate (this does
  # not re-validate them). Score = mean overall_score (Float).
  # needs_second: a single doc within BORDERLINE of PASS_SCORE (callers refuse a
  # pass on it). Platform differences (catalog-id gaps) never affect the result.
  # residuals = fixable MINOR gaps; fixable_major = fixable MAJOR gaps (the ones
  # that made the run divergent — named in the report). Gaps are de-duplicated
  # across graders on (tile, dimension, description, severity, class).
  def faithful(docs, catalog = nil)
    docs = Array(docs)
    raise ArgumentError, "faithful takes 1 or 2 grade docs (got #{docs.length})" unless [1, 2].include?(docs.length)
    score = docs.map { |d| d['overall_score'].to_i }.sum.to_f / docs.length
    needs_second = docs.length == 1 && (score - PASS_SCORE).abs <= BORDERLINE
    # Two graders often name the same gap: de-duplicate on the full identity.
    gaps = docs.flat_map { |d| Array(d['gaps']) }
               .uniq { |g| %w[tile dimension description severity class].map { |k| g[k].to_s } }
    platform = gaps.reject { |g| g['class'].to_s == 'fixable' }
    fixable = gaps.select { |g| g['class'].to_s == 'fixable' }
    residuals = fixable.select { |g| g['severity'].to_s == 'minor' }
    reasons = []
    %w[chart_shapes_match numbers_formatted].each do |dim|
      next if docs.all? { |d| d.dig('dimensions', dim, 'verdict') == 'pass' }
      reasons << "#{dim} did not pass (a hard requirement regardless of score)"
    end
    major = fixable.select { |g| g['severity'].to_s == 'major' }
    major.each do |g|
      reasons << "major fixable gap on #{g['tile']} (#{g['dimension']}): #{g['description']}"
    end
    reasons << "score #{score} is below the pass bar #{PASS_SCORE}" if score < PASS_SCORE
    reasons << "score #{score} is within #{BORDERLINE} of #{PASS_SCORE}; a second blind grader is required" if needs_second
    { 'faithful' => reasons.reject { |r| r.include?('second blind grader') }.empty?, 'score' => score,
      'reasons' => reasons, 'needs_second' => needs_second,
      'platform_differences' => platform, 'residuals' => residuals, 'fixable_major' => major }
  end

  # Chart-family census of the BUILT workbook, from the wb-readback spec.
  # Workbook elements are the flat document.elements collection; data-model
  # pages[*].elements semantics are intentionally outside this workbook helper.
  # Returns an array of families (chart elements only), or nil when absent.
  def census_from_readback(path)
    return nil unless File.file?(path.to_s)
    doc = (JSON.parse(File.read(path)) rescue nil)
    return nil unless doc.is_a?(Hash)
    inner = Sigma::CodeRep.document(doc)
    return nil unless inner['elements'].is_a?(Array)
    fams = []
    page_by_element = Sigma::CodeRep.workbook_page_by_element(inner)
    Sigma::CodeRep.workbook_elements(inner).each do |el|
      owner = page_by_element[el['id'].to_s]
      data_page = owner && (owner['name'].to_s.strip.casecmp?('Data') ||
                            owner['id'].to_s.downcase.include?('data'))
      # Elements placed on a hidden page never render, so they are not tiles.
      # visibleAsSource is data-model-only (the live workbook API 400s on it),
      # so page visibility is the workbook's real "hidden data page" signal.
      hidden_page = owner && owner['visibility'].to_s == 'hidden'
      next if data_page || hidden_page || el['visibleAsSource'] == false
      f = family(el['kind'])
      fams << f if chart_family?(f)
    end
    fams
  end

  # Chart-family census of the SOURCE dashboard, from the Phase 1d read
  # artifact (png-read.json tiles[].kind). Returns families or nil when absent.
  def census_from_png_read(path)
    return nil unless File.file?(path.to_s)
    doc = (JSON.parse(File.read(path)) rescue nil)
    tiles = doc.is_a?(Hash) ? Array(doc['tiles']) : nil
    return nil unless tiles
    fams = []
    tiles.each do |t|
      next unless t.is_a?(Hash)
      f = family(t['kind'])
      fams << f if chart_family?(f)
    end
    fams
  end

  # Compare the grader's per-tile family readings (one side) against a
  # mechanical census, as multisets: every census tile must find a matching
  # blind reading of the same family. → {mismatches:, blind:, census:}
  def cross_check(per_tile, census, side)
    raw = Array(per_tile).map { |t| (t.is_a?(Hash) ? t["#{side}_family"] : nil).to_s.strip.downcase }
    cant_tell = raw.count { |k| CANT_TELL_FAMILIES.include?(k) }
    blind = raw.reject { |k| CANT_TELL_FAMILIES.include?(k) }.map { |k| family(k) }
               .select { |f| chart_family?(f) }
    b_counts = blind.tally
    c_counts = Array(census).tally
    # KPI band rule: adjacent single-value KPIs legitimately read as one band
    # (or as N tiles). When BOTH sides have a kpi, the kpi COUNT difference is
    # not a contradiction. Zero-vs-some stays a mismatch. Not scoped by page.
    kpi_band = (b_counts['kpi'] || 0).positive? && (c_counts['kpi'] || 0).positive? &&
               b_counts['kpi'] != c_counts['kpi']
    b_adj = b_counts.dup
    b_adj['kpi'] = c_counts['kpi'] if kpi_band
    matched = c_counts.sum { |f, n| [n, b_adj[f] || 0].min }
    # Named blind tiles with no census partner, and census tiles no named blind
    # tile matched — less those the can't-tell tiles may account for. With no
    # can't-tell tile this is exactly [blind, census].max - matched.
    blind_extra = b_adj.values.sum - matched
    excused = [cant_tell, census.length / 2].min
    census_left = [census.length - matched - excused, 0].max
    mismatches = [blind_extra, census_left].max
    out = { 'mismatches' => mismatches, 'blind' => b_counts, 'census' => c_counts }
    out['kpi_band'] = true if kpi_band
    out['cant_tell'] = cant_tell if cant_tell.positive?
    out
  end
end

# Ruby 2.6 back-compat: Enumerable#tally landed in 2.7.
unless [].respond_to?(:tally)
  module Enumerable
    def tally
      each_with_object(Hash.new(0)) { |x, h| h[x] += 1 }
    end
  end
end
