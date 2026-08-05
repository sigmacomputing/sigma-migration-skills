#!/usr/bin/env ruby
# Offline test for lib/calc_coverage.rb — the calc-coverage lint's masking
# tokenizer (ported from tflex src/utilities/FormatCalculations.js) and the
# covered/uncovered/unknown classifier over lib/tableau_functions.json.
#
# The P1-spec fixtures F1-F20 appear here as MASK ROUND-TRIP cases only:
# their tflex outputs are SQL-translation behavior (ExpressionToSql.js) that
# calc_coverage.rb deliberately does not reproduce — several are documented
# quirks (F4 DATEDIFF arg-swap parity, F15 "Pacific" mangling, F16 PARTITION
# drop) that the classifier exists to prevent. Two deliberate deviations from
# the JS are asserted below: the unified single-pass scan (so `//` inside a
# string is NOT eaten as a comment) and \x00 placeholder tokens (so a formula
# containing HTML-comment-lookalike text cannot corrupt unmasking).
#
# Usage:  ruby scripts/test-calc-coverage.rb

require_relative 'lib/calc_coverage'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# P1-spec fixtures F1-F20 (inputs only — SQL outputs are tflex's business).
FIXTURES = {
  'F1'  => 'IFNULL([Sales], 0)',
  'F2'  => 'ISNULL([Discount])',
  'F3'  => 'ZN([Profit])',
  'F4a' => "DATEDIFF('x', [Start], [Finish])",
  'F4b' => "DATEDIFF('day', [Order Date], [Ship Date])",
  'F5'  => "DATEADD('month', 3, [Order Date])",
  'F6'  => 'LEN([Customer Name])',
  'F7'  => 'RIGHT([Order ID], 4)',
  'F8'  => 'CONTAINS([Segment], "Corp")',
  'F9'  => 'TRIM([City])',
  'F10' => 'SPLIT([Name], "-", 1)',
  'F11' => 'SPLIT([Name], "-", 2)',
  'F12' => 'SPLIT([Name], "-", -1)',
  'F13' => 'IF [Sales] > 100 THEN "High" ELSE "Low" END',
  'F14' => "IF [A] = 1 THEN \"one\"\nELSEIF [A] = 2 THEN \"two\"\nELSE \"other\"\nEND",
  'F15' => 'IF [Region] = "Pacific" THEN 1 ELSE 0 END',
  'F16' => '{{ PARTITION [Region]: { ORDERBY [Sales] DESC: RANK()}}}',
  'F17' => '{ ORDERBY [Sales] ASC: RANK_DENSE()}',
  'F18' => '[Profit Ratio] * 100',
  'F19' => 'UPPER([City])',
  'F20' => 'TRIM(SPLIT([Name], "-", 1))'
}.freeze

puts 'Part 0 — catalog integrity (lib/tableau_functions.json)'
cat = CalcCoverage.catalog
check(cat.is_a?(Hash) && cat['provenance'].to_s.include?('tflex'),
      'catalog wrapper carries tflex provenance', fails)
# 187 = tflex's 185 + REGEXP_REPLACE + MODEL_EXTENSION_STR (added 2026-07-25 —
# real Tableau functions whose absence bucketed field workbooks as unknown/typo).
check(cat['functions'].is_a?(Array) && cat['functions'].size == 187,
      "catalog has 187 function entries (got #{cat['functions'] ? cat['functions'].size : 'none'})", fails)
names = cat['functions'].map { |e| e['name'] }
check(names.uniq.size == 187, 'catalog names are unique', fails)
check(cat['functions'].all? { |e| e.key?('minArgs') && e.key?('maxArgs') && e.key?('category') && e.key?('sigmaEquivalent') },
      'every entry carries minArgs/maxArgs/category/sigmaEquivalent', fails)
check(cat['keywords'] == { 'logicals' => CalcCoverage::KEYWORDS, 'lod' => CalcCoverage::LOD_KEYWORDS },
      'JSON keyword lists match the Ruby constants (logicals + lod)', fails)
check(((CalcCoverage::KEYWORDS + CalcCoverage::LOD_KEYWORDS) & names).empty?,
      'keywords are not also catalog functions', fails)

puts
puts 'Part 1 — mask/unmask round-trips exactly on every P1 fixture'
FIXTURES.each do |id, formula|
  masked, tokens = CalcCoverage.mask(formula)
  check(CalcCoverage.unmask(masked, tokens) == formula, "#{id} round-trips exactly", fails)
  check(!masked.include?('[') && !masked.include?("'") && !masked.include?('"'),
        "#{id} masked text carries no raw quote/bracket delimiters", fails)
end

puts
puts 'Part 2 — deliberate deviation 1: unified single-pass scan'
# The JS masks comments BEFORE quotes, so `//` inside 'http://x' is eaten as a
# line comment and the orphaned quote swallows the rest of the formula. The
# single-pass scan must keep the string a string.
f = "'http://x' + [A]"
masked, tokens = CalcCoverage.mask(f)
check(tokens[:comments].empty?, "`//` inside a string literal is NOT treated as a comment", fails)
check(tokens[:quotes] == ["'http://x'"], 'the URL string masks as one intact quote token', fails)
check(tokens[:fields] == ['[A]'], '[A] after the URL string still masks as a field', fails)
check(CalcCoverage.unmask(masked, tokens) == f, 'URL-string formula round-trips exactly', fails)

f = "// real comment\nZN([x]) + 'a // b'"
masked, tokens = CalcCoverage.mask(f)
check(tokens[:comments] == ['// real comment'],
      'real line comment masked, EXCLUSIVE of the newline', fails)
check(masked.include?("\n"), 'the newline itself survives in the masked text', fails)
check(tokens[:quotes] == ["'a // b'"], "`//` inside a later string stays in the string", fails)
check(CalcCoverage.unmask(masked, tokens) == f, 'comment+string formula round-trips exactly', fails)

f = "ZN([x]) // trailing, no newline"
masked, tokens = CalcCoverage.mask(f)
check(tokens[:comments] == ['// trailing, no newline'] && CalcCoverage.unmask(masked, tokens) == f,
      'line comment at end-of-string (no newline) round-trips', fails)

puts
puts 'Part 3 — block comments: nesting + unterminated -> EOF'
f = '/* a /* b */ c */ ZN([x])'
masked, tokens = CalcCoverage.mask(f)
check(tokens[:comments] == ['/* a /* b */ c */'],
      'nested block comment is ONE comment (depth counter)', fails)
check(CalcCoverage.extract_function_names(f) == ['ZN'],
      'extraction still sees ZN after the nested comment', fails)
check(CalcCoverage.unmask(masked, tokens) == f, 'nested-comment formula round-trips exactly', fails)

f = 'SUM([Sales]) /* unterminated /* inner */'
masked, tokens = CalcCoverage.mask(f)
check(tokens[:comments] == ['/* unterminated /* inner */'],
      'unterminated (still-nested) block comment swallows to end-of-string', fails)
check(CalcCoverage.unmask(masked, tokens) == f, 'unterminated-comment formula round-trips exactly', fails)

puts
puts 'Part 4 — unterminated string / bracket -> EOF, no crash'
f = "IF [x] = 'oops THEN 1 END"
masked, tokens = CalcCoverage.mask(f)
check(tokens[:quotes] == ["'oops THEN 1 END"], 'unterminated quote masks to end-of-string', fails)
check(CalcCoverage.unmask(masked, tokens) == f, 'unterminated-quote formula round-trips exactly', fails)

f = 'SUM([Sales'
masked, tokens = CalcCoverage.mask(f)
check(tokens[:fields] == ['[Sales'], 'unterminated bracket masks to end-of-string', fails)
check(CalcCoverage.unmask(masked, tokens) == f, 'unterminated-bracket formula round-trips exactly', fails)

# Same-quote-char closing, no escape handling: 'it''s' = TWO literals (spec 2.2).
f = "'it''s'"
masked, tokens = CalcCoverage.mask(f)
check(tokens[:quotes] == ["'it'", "'s'"], "no-escape scanning: 'it''s' masks as two literals", fails)
check(CalcCoverage.unmask(masked, tokens) == f, 'double-apostrophe formula still round-trips exactly', fails)

puts
puts 'Part 5 — function extraction: keywords out, canonical uppercase back'
f = "IF DATEDIFF('day', [Start], [Finish]) > 0 THEN ZN([Profit]) ELSEIF [x] THEN 0 ELSE 1 END"
got = CalcCoverage.extract_function_names(f)
check(got == %w[DATEDIFF ZN],
      "IF/THEN/ELSEIF/ELSE/END excluded; DATEDIFF+ZN returned (got #{got.inspect})", fails)
# Parenthesized condition puts a literal "IF (" in the text — only the keyword
# exclusion keeps IF from surfacing as a function.
got = CalcCoverage.extract_function_names('IF ([Sales] > 100) THEN 1 ELSE 0 END')
check(got == [], "keyword followed by '(' (IF (...)) is not extracted as a function", fails)
got = CalcCoverage.extract_function_names('{ FIXED [Region] : SUM([Sales]) }')
check(got == ['SUM'], 'LOD keywords (FIXED) excluded; SUM extracted', fails)
got = CalcCoverage.extract_function_names("datediff('day', [A], [B]) + zn([C]) + Zn([D])")
check(got == %w[DATEDIFF ZN],
      "extraction is case-insensitive, returns canonical uppercase, deduped (got #{got.inspect})", fails)
check(CalcCoverage.extract_function_names(FIXTURES['F20']) == %w[SPLIT TRIM],
      'nested calls (F20) surface both TRIM and SPLIT, sorted', fails)
check(CalcCoverage.extract_function_names(FIXTURES['F16']) == ['RANK'],
      'window serialization (F16) surfaces RANK, not PARTITION/ORDERBY', fails)
check(CalcCoverage.extract_function_names("CONTAINS([N], 'ZN(') ") == ['CONTAINS'],
      'function-looking text inside a string literal is not extracted', fails)

puts
puts 'Part 6 — deliberate deviation 2: \\x00 tokens, degenerate input'
# A formula containing the JS placeholder text must not corrupt unmasking.
f = 'ZN([x]) + "<!--QUOTE_0-->"'
masked, tokens = CalcCoverage.mask(f)
check(CalcCoverage.unmask(masked, tokens) == f,
      'HTML-comment-lookalike text round-trips exactly (the reason for \\x00 tokens)', fails)
# Degenerate: input already contains \x00. mask() strips NUL bytes (illegal in
# .twb XML) so the token machinery cannot be spoofed — no crash; round-trip is
# ALLOWED to normalize (documented deviation-2 guard).
f = "\x00Q0\x00 + ZN([x])"
crashed = false
begin
  masked, tokens = CalcCoverage.mask(f)
  round = CalcCoverage.unmask(masked, tokens)
rescue StandardError
  crashed = true
end
check(!crashed, 'NUL-bearing degenerate input does not crash', fails)
check(!crashed && round == f.delete("\x00"),
      'degenerate round-trip normalizes to the NUL-stripped input, nothing else', fails)
check(!crashed && CalcCoverage.function_calls(masked).include?('ZN'),
      'extraction still works on the degenerate input', fails)

puts
puts 'Part 7 — parameter/field split + LOD kind'
masked, tokens = CalcCoverage.mask('[Sales] * [Parameters].[Target %]')
refs = CalcCoverage.field_refs(masked, tokens)
check(refs == { fields: ['[Sales]'], parameters: ['[Parameters].[Target %]'] },
      '"[Parameters]." split works despite first-"]" tokenization (rejoined pair)', fails)
check(CalcCoverage.unmask(masked, tokens) == '[Sales] * [Parameters].[Target %]',
      'parameter-bearing formula still round-trips exactly', fails)
masked, = CalcCoverage.mask('{ FIXED [Region] : SUM([Sales]) }')
check(CalcCoverage.lod_kind(masked) == 'FIXED', 'lod_kind reads FIXED', fails)
masked, = CalcCoverage.mask('SUM([Sales])')
check(CalcCoverage.lod_kind(masked).nil?, 'lod_kind nil for non-LOD formulas', fails)

puts
puts 'Part 8 — coverage(): covered / uncovered / unknown classification'
translated = %w[ifnull ZN DateDiff] # deliberately mixed case
formulas = {
  'Safe Sales'  => 'IFNULL([Sales], 0)',
  'City Upper'  => 'UPPER([City])',
  'Mystery'     => 'FOOBAR([x]) + UPPER([y])',
  'Days To Ship' => "DATEDIFF('day', [Order Date], [Ship Date])",
  'Flag'        => 'IF [Sales] > 100 THEN 1 ELSE 0 END'
}
cov = CalcCoverage.coverage(formulas, translated: translated)
check(cov[:covered] == %w[DATEDIFF IFNULL],
      "covered = translated-set hits, sorted (got #{cov[:covered].inspect})", fails)
check(cov[:unknown] == ['FOOBAR'],
      "unknown = names absent from the catalog (got #{cov[:unknown].inspect})", fails)
check(cov[:uncovered].map { |u| u[:name] } == ['UPPER'],
      'uncovered = in-catalog but untranslated (UPPER, spec F19)', fails)
upper = cov[:uncovered][0]
check(upper && upper[:count] == 2, "uncovered count is per-occurrence (UPPER x2, got #{upper && upper[:count]})", fails)
check(upper && upper[:formulas_sample] == ['City Upper', 'Mystery'],
      'formulas_sample names the offending calcs (hash form)', fails)
check(cov[:covered].include?('IF') == false && cov[:unknown].include?('IF') == false,
      'keywords never appear in any coverage bucket', fails)

# Array form: samples are the (truncated) formula text; empty translated set.
cov = CalcCoverage.coverage(['UPPER([City])', 'UPPER([State])'], translated: [])
u = cov[:uncovered][0]
check(cov[:covered] == [] && u && u[:name] == 'UPPER' && u[:count] == 2 &&
        u[:formulas_sample] == ['UPPER([City])', 'UPPER([State])'],
      'array form: empty translated set, per-formula text samples', fails)

# formulas_sample is capped at SAMPLE_LIMIT.
many = (1..5).map { |i| "UPPER([C#{i}])" }
cov = CalcCoverage.coverage(many, translated: [])
check(cov[:uncovered][0][:formulas_sample].size == CalcCoverage::SAMPLE_LIMIT &&
        cov[:uncovered][0][:count] == 5,
      "formulas_sample capped at #{CalcCoverage::SAMPLE_LIMIT}, count stays exact", fails)

# uncovered ordering: count desc, then name.
cov = CalcCoverage.coverage(['UPPER([a]) + UPPER([b]) + LOWER([c])'], translated: [])
check(cov[:uncovered].map { |x| x[:name] } == %w[UPPER LOWER],
      'uncovered sorted by count desc, then name', fails)

if fails.empty?
  puts
  puts "OK — calc-coverage lint holds (#{FIXTURES.size} spec fixtures round-trip; " \
       "#{cat['functions'].size}-function catalog; keywords excluded)"
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
