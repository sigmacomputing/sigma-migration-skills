# frozen_string_literal: true
#
# CalcCoverage — masking tokenizer + calc-coverage lint for Tableau formulas.
#
# Provenance: ported from tflex's masking pass
# (src/utilities/FormatCalculations.js, lines 3-102) against the function
# catalog vendored at lib/tableau_functions.json (from tflex
# src/utilities/TableauFunctions.json, normalized 2026-07-11). Faithful to the
# JS on: nested block comments (depth counter), line comments exclusive of the
# trailing newline, unterminated comment/quote/bracket running to end-of-string,
# same-quote-char closing with NO escape handling (no '' or ]] escapes), and
# the "[Parameters]." prefix test for parameter refs.
#
# Two DELIBERATE deviations from the JS (both flagged as risks in the P1 spec):
#
#   1. UNIFIED SINGLE-PASS SCAN (spec 2.4.1). The JS masks comments BEFORE
#      quotes, so `//` inside a string literal is eaten as a line comment:
#      `'http://x' + [A]` loses `//x'...` to a comment and the orphaned
#      leading `'` then swallows the rest of the formula as a "string".
#      Here comment, quote, and bracket openers live in ONE cursor loop, so
#      whichever construct starts at the cursor wins and `//` inside a
#      masked string is never rescanned. This only ever masks LESS text as
#      comments and never unmasks string content — strictly safer for
#      function extraction.
#
#   2. \x00 PLACEHOLDER TOKENS (spec 2.4.2). The JS uses HTML-comment tokens
#      (`<!--QUOTE_0-->`); a formula containing that literal text corrupts
#      unmasking. We use "\x00Q0\x00"-style tokens instead — NUL bytes are
#      illegal in .twb XML content, so no real formula can collide. As a
#      belt-and-braces guard, mask() strips any pre-existing NUL bytes from
#      degenerate input (round-trip may normalize such input; it cannot
#      corrupt the token machinery).
#
# Why this module exists: tflex's ExpressionToSql only truly handles ~14
# functions and silently passes everything else through (and, unmasked, it
# mangles strings containing "if" — spec fixture F15). Classifying coverage
# BEFORE building turns untranslated functions into named residue up front
# instead of silent formula errors later.
#
# Ruby 2.6 — no filter_map, no tally, no pattern matching.

require 'json'

module CalcCoverage
  module_function

  # Keyword lists mirror tableau_functions.json "keywords" (tflex logicals +
  # lod word-keywords). These are KEYWORDS, not functions: `IF(` / `CASE(` /
  # `FIXED(` never appear in Tableau syntax, but `IF ([Sales] > 100)` does —
  # extracting IF as an "unknown function" would be a false gap.
  KEYWORDS     = %w[AND OR NOT IF CASE WHEN THEN ELSE END IN ELSEIF].freeze
  LOD_KEYWORDS = %w[FIXED INCLUDE EXCLUDE].freeze

  CATALOG_PATH = File.join(__dir__, 'tableau_functions.json')

  SAMPLE_LIMIT = 3 # formulas_sample entries kept per uncovered function

  # ---------------------------------------------------------------- masking

  # mask(formula) -> [masked_string, tokens]
  #
  # tokens is {comments: [...], quotes: [...], fields: [...]}; placeholders in
  # the masked string are "\x00C<i>\x00", "\x00Q<i>\x00", "\x00F<i>\x00"
  # (0-based, same index spaces as the JS COMMENT_/QUOTE_/FIELD_ tokens).
  # Unified single-pass cursor scan — deviation 1 above.
  def mask(formula)
    text = formula.to_s.delete("\x00") # deviation 2 guard: NUL never legal in .twb
    tokens = { comments: [], quotes: [], fields: [] }
    out = ''.dup
    i = 0
    n = text.length
    while i < n
      ch  = text[i]
      two = text[i, 2]
      if ch == '"' || ch == "'"
        # Next IDENTICAL quote char closes; no escapes ('it''s' = two
        # literals); unterminated masks to end-of-string.
        j = text.index(ch, i + 1)
        j = n if j.nil?
        tokens[:quotes] << text[i..j] # inclusive of both quote chars (clamped at EOS)
        out << "\x00Q#{tokens[:quotes].length - 1}\x00"
        i = j + 1
      elsif ch == '['
        # No ]] escape handling (faithful to the JS): [a]]b] masks as [a],
        # leaving ]b] behind — harmless, the leftover contains no "(".
        j = text.index(']', i + 1)
        j = n if j.nil?
        tokens[:fields] << text[i..j]
        out << "\x00F#{tokens[:fields].length - 1}\x00"
        i = j + 1
      elsif two == '//'
        # Line comment, EXCLUSIVE of the newline (the \n survives in the
        # masked text), or to end-of-string.
        j = text.index("\n", i)
        j = n if j.nil?
        tokens[:comments] << text[i...j]
        out << "\x00C#{tokens[:comments].length - 1}\x00"
        i = j
      elsif two == '/*'
        # Block comment, NESTING supported: /* a /* b */ c */ is ONE comment.
        # Unterminated /* swallows to end-of-string.
        j = i + 2
        depth = 1
        while depth > 0 && j < n
          if    text[j, 2] == '/*' then depth += 1; j += 2
          elsif text[j, 2] == '*/' then depth -= 1; j += 2
          else  j += 1
          end
        end
        tokens[:comments] << text[i...j]
        out << "\x00C#{tokens[:comments].length - 1}\x00"
        i = j
      else
        out << ch
        i += 1
      end
    end
    [out, tokens]
  end

  # unmask(masked, tokens) -> original text (exact round-trip; degenerate
  # NUL-bearing input is normalized by mask(), see deviation 2).
  def unmask(masked, tokens)
    masked.gsub(/\x00([CQF])(\d+)\x00/) do
      idx = Regexp.last_match(2).to_i
      case Regexp.last_match(1)
      when 'C' then tokens[:comments][idx]
      when 'Q' then tokens[:quotes][idx]
      else          tokens[:fields][idx]
      end
    end
  end

  # ------------------------------------------------------------- extraction

  # Non-unique, uppercased identifiers immediately (mod whitespace) followed
  # by "(" in MASKED text. Zero-arg Tableau functions (NOW, TODAY, PI,
  # INDEX...) still use (), so this catches all calls. Keywords NOT excluded
  # here — this is the raw counting primitive.
  def function_calls(masked)
    masked.scan(/\b([A-Za-z][A-Za-z0-9_]*)\s*\(/).map { |m| m[0].upcase }
  end

  # extract_function_names(formula) -> sorted unique UPPERCASE names, with the
  # logical/LOD keyword lists excluded (IF/CASE/WHEN/FIXED... are keywords —
  # `IF ([Sales] > 100)` must not surface IF as a function).
  def extract_function_names(formula)
    masked, = mask(formula)
    (function_calls(masked).uniq - KEYWORDS - LOD_KEYWORDS).sort
  end

  # LOD kind of a masked formula: "FIXED" | "INCLUDE" | "EXCLUDE" | nil.
  # (Bare "{...}" — FIXED over the whole table — returns nil here; callers
  # that care can test for a leading "{" themselves.)
  def lod_kind(masked)
    m = masked.match(/\{\s*(FIXED|INCLUDE|EXCLUDE)\b/i)
    m && m[1].upcase
  end

  # Split field refs into columns vs parameters — a ref is a parameter iff it
  # carries the "[Parameters]." prefix (FormatCalculations.js:52-55).
  # Parameters map to Sigma controls, not data-model columns.
  #
  # Note the cursor scan (faithfully, per spec 2.2) closes a bracket ref at
  # the FIRST "]", so "[Parameters].[Target]" tokenizes as TWO field tokens
  # joined by "." — the JS prefix test can never fire on a single token.
  # Rejoin adjacent "[Parameters].[X]" pairs here before classifying.
  def field_refs(masked, tokens)
    fields = []
    parameters = []
    consumed = {}
    masked.scan(/\x00F(\d+)\x00\.\x00F(\d+)\x00/) do
      a = Regexp.last_match(1).to_i
      b = Regexp.last_match(2).to_i
      next unless tokens[:fields][a] == '[Parameters]'
      parameters << "#{tokens[:fields][a]}.#{tokens[:fields][b]}"
      consumed[a] = true
      consumed[b] = true
    end
    tokens[:fields].each_with_index do |ref, idx|
      next if consumed[idx]
      (ref.start_with?('[Parameters].') ? parameters : fields) << ref
    end
    { fields: fields, parameters: parameters }
  end

  # --------------------------------------------------------------- coverage

  # Lazy-loaded catalog wrapper: {"provenance", "functions" => [187 entries],
  # "keywords" => {"logicals", "lod"}}.
  def catalog
    @catalog ||= JSON.parse(File.read(CATALOG_PATH))
  end

  # {name => entry} over the 187-entry catalog, keyed by uppercase name.
  def catalog_index
    @catalog_index ||= begin
      idx = {}
      catalog['functions'].each { |e| idx[e['name'].upcase] = e }
      idx
    end
  end

  # ------------------------------------------- generated translation table
  # W2.13: THE one generated table (refs/functions.json, emitted by
  # scripts/dev/gen-translation-table.mjs from the vendored converter bundle +
  # this catalog). One row per catalog function with the translator's REAL
  # verdict: status ∈ spec|verify|chart_only|rls|not_converted|unmapped.
  # refs/coverage-manifest.json is a generated compat view of the same data —
  # never hand-edit either; regenerate and commit (drift is CI-diffed by
  # scripts/test-translation-table.rb).

  TRANSLATION_TABLE_PATH = File.expand_path('../../refs/functions.json', __dir__)
  TRANSLATION_STATUSES = %w[spec verify chart_only rls not_converted unmapped].freeze
  # Statuses whose formulas the converter genuinely translates (chart_only is
  # translated but chart-context-only; rls translates to CurrentUser*).
  TRANSLATED_STATUSES = %w[spec verify chart_only rls].freeze

  def translation_table
    @translation_table ||= JSON.parse(File.read(TRANSLATION_TABLE_PATH))
  end

  # {UPPERCASE tableau_fn => row} over the generated table.
  def translation_index
    @translation_index ||= begin
      idx = {}
      translation_table['functions'].each { |r| idx[r['tableau_fn'].upcase] = r }
      idx
    end
  end

  # Sorted UPPERCASE Tableau function names the converter translates — the
  # `translated:` set for coverage(), served from the ONE generated table
  # instead of a hand-maintained list.
  def translated_names(statuses: TRANSLATED_STATUSES)
    want = {}
    Array(statuses).each { |s| want[s.to_s] = true }
    translation_table['functions']
      .select { |r| want[r['status']] }
      .map { |r| r['tableau_fn'].upcase }
      .sort
  end

  # coverage(formulas, translated:) -> {covered:, uncovered:, unknown:}
  #
  #   formulas   — Array of formula strings, or Hash {calc_name => formula}
  #                (hash form samples calc names; array form samples the
  #                formula text, truncated).
  #   translated — the set (any Enumerable) of Tableau function names the
  #                skill's converter actually handles; case-insensitive.
  #
  #   covered    — sorted names seen in formulas AND in `translated`.
  #   uncovered  — [{name:, count:, formulas_sample: [...]}] for names in the
  #                187-entry catalog but NOT in `translated` (named residue —
  #                the whole point of classifying before building). Sorted by
  #                count desc, then name.
  #   unknown    — sorted names not in the catalog at all (typos, extensions,
  #                or already-SQL text).
  def coverage(formulas, translated:)
    translated_set = {}
    (translated || []).each { |t| translated_set[t.to_s.upcase] = true }

    counts  = Hash.new(0)
    samples = Hash.new { |h, k| h[k] = [] }

    each_formula(formulas) do |label, formula|
      masked, = mask(formula)
      names = function_calls(masked).reject do |n|
        KEYWORDS.include?(n) || LOD_KEYWORDS.include?(n)
      end
      names.each { |n| counts[n] += 1 }
      names.uniq.each do |n|
        samples[n] << label if samples[n].length < SAMPLE_LIMIT
      end
    end

    covered   = []
    uncovered = []
    unknown   = []
    counts.keys.sort.each do |name|
      if translated_set[name]
        covered << name
      elsif catalog_index.key?(name)
        uncovered << { name: name, count: counts[name], formulas_sample: samples[name] }
      else
        unknown << name
      end
    end
    uncovered = uncovered.sort_by { |u| [-u[:count], u[:name]] }

    { covered: covered, uncovered: uncovered, unknown: unknown }
  end

  # Yields [label, formula] for Hash {name => formula} or Array of formulas.
  def each_formula(formulas)
    if formulas.is_a?(Hash)
      formulas.each { |name, formula| yield name.to_s, formula }
    else
      Array(formulas).each do |formula|
        text = formula.to_s
        label = text.length > 80 ? "#{text[0, 77]}..." : text
        yield label, formula
      end
    end
  end
end
