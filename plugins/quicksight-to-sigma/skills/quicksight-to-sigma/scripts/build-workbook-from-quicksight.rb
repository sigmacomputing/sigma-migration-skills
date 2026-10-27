#!/usr/bin/env ruby
# build-workbook-from-quicksight.rb
# Build a Sigma workbook that mirrors a QuickSight analysis, bound to the
# data model produced by the convert phase.
#
# Architecture (matches the Qlik/PowerBI builders):
#   - a master "table" element on a Data page, source = {dataModelId, elementId, kind:"data-model"},
#     surfacing the columns the dashboard needs via [Custom SQL/RAW] (or a translated calc-field expr);
#   - one dashboard page whose chart elements source the master via {elementId, kind:"table"}
#     and reference master columns as [<MasterName>/<Col>] with the QuickSight aggregation.
#
# Key behaviours ([bead] / woaa / 23xu):
#   - the master sources the DM element whose columns COVER the charted columns (the
#     denormalized join element), NOT a hardcoded pages[0].elements[0];
#   - QuickSight window/table-calc functions (runningSum/percentOfTotal/rank/difference/…)
#     are NOT passed through as live Sigma formulas — they are neutralized to Null (the
#     original expr goes into the column description);
#   - a dataset FilterOperation surfaced by convert-model (dm-filters.json) is APPLIED as a
#     real element-level list filter on the master, so downstream aggregates honor it;
#   - GaugeChartVisual -> native progress, WaterfallVisual -> native waterfall-chart;
#     FunnelChartVisual and TreeMapVisual remain explicit bar-chart approximations.
#
# Usage:
#   ruby scripts/build-workbook-from-quicksight.rb \
#     --analysis DISCOVER_DIR/analysis.json --dm-readback /tmp/dm-readback.json \
#     [--dm-spec /tmp/dm-spec.json] [--filters /tmp/dm-filters.json] \
#     --folder-id ID --out /tmp/wb-spec.json
require 'json'
require 'optparse'
require 'digest'
require 'set'
require_relative 'lib/coverage_catalog'
require_relative 'lib/trellis_emit' # shared native-trellis emitter (supported-kind gate + fallbacks)
require_relative 'lib/metric_binding' # shared DM-metric binder ([Metrics/<name>] over inline re-derive)
require_relative 'lib/layout'
require_relative 'lib/dm_column_index' # per-element column labels/types stamped into dm-readback.json
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

opts = {}
OptionParser.new do |o|
  o.on('--analysis F') { |v| opts[:an] = v }
  o.on('--dm-readback F') { |v| opts[:rb] = v }
  o.on('--dm-spec F') { |v| opts[:dmspec] = v }
  o.on('--filters F') { |v| opts[:filters] = v }
  o.on('--folder-id ID') { |v| opts[:folder] = v }
  o.on('--master-name NAME') { |v| opts[:mname] = v }
  o.on('--discover-dir D') { |v| opts[:discover] = v }   # datasets/*.json -> BOOLEAN_COLS (RCA #3)
  o.on('--out F') { |v| opts[:out] = v }
end.parse!
%i[an rb out].each { |k| abort "missing --#{k}" unless opts[k] }

an = JSON.parse(File.read(opts[:an]))
defn = an['Definition']
# QuickSight what-if PARAMETERS (Decimal/Integer/String/DateTime ParameterDeclaration).
# A calc field references a parameter as ${ParamName}. Sigma has no 1:1 parameter inside a
# data-model formula, so for parity we inline the parameter's DEFAULT value as a constant
# (the default-view value the QS dashboard shows on load). This is recorded as a warning so
# the (interactive) what-if control is understood to be a manual re-author in Sigma.
PARAM_DEFAULTS = {}
(defn['ParameterDeclarations'] || []).each do |pd|
  decl = pd.values.first
  next unless decl.is_a?(Hash) && decl['Name']
  dv = (decl.dig('DefaultValues', 'StaticValues') || [])[0]
  PARAM_DEFAULTS[decl['Name']] = dv unless dv.nil?
end
rb = JSON.parse(File.read(opts[:rb]))
dm_id = rb['dataModelId']

# THEME palette — QuickSight colors are theme-driven and absent from the definition export;
# discovery resolves them into signals.json (co-located with analysis.json). We apply them as
# (1) a workbook-level themeOverrides.categoricalScheme — the ONLY spec path to pie/donut slice
# colors and the palette for every categorical chart — and (2) a single-hue color on
# single-measure bar/line/area (QuickSight paints those in the theme's primary data color).
THEME = begin
  sig = File.join(File.dirname(File.expand_path(opts[:an])), 'signals.json')
  File.exist?(sig) ? JSON.parse(File.read(sig))['theme'] : nil
rescue StandardError
  nil
end
THEME_COLORS = (THEME && THEME['dataColors']).is_a?(Array) ? THEME['dataColors'].compact : []
THEME_PRIMARY = THEME && THEME['primaryColor']

def disp(raw); raw.to_s.gsub(/[_.]/, ' ').split.map { |w| w[0..0].upcase + w[1..-1].to_s.downcase }.join(' '); end

# Boolean columns (display names), derived from the discovery datasets' PhysicalTable
# InputColumns where Type==BOOLEAN. QS OutputColumns coerce booleans to INTEGER, so a
# calc-field predicate `{FLAG}=1` would emit `[Flag] = 1` and throw at query time on the
# real boolean column. qs_expr_to_sigma uses this set to rewrite the predicate to the
# bare boolean (RCA #3, bead 3goo.3). Empty (no --discover-dir) => no rewrite, no change.
BOOLEAN_COLS = Set.new
BOOLEAN_RAW = Set.new   # the same columns by RAW dataset name (a resolved label may differ from disp())
# Dataset columns from the discovery datasets' OutputColumns (the LOGICAL columns, after any
# casts): DATASET_COL_TYPES = { DataSetId => { column => 'DATETIME' } } feeds the control-kind
# decision (decision order: data-model type > dataset type > name heuristic), and
# DATASET_COLS is the candidate set for BARE identifiers in calc-field expressions.
DATASET_COL_TYPES = {}
DATASET_COLS = Set.new
if opts[:discover]
  Dir[File.join(opts[:discover], 'datasets', '*.json')].sort.each do |f|
    j = JSON.parse(File.read(f)) rescue next
    ds = j['DataSet'] || j
    (ds['PhysicalTableMap'] || {}).each_value do |pt|
      rt = pt['RelationalTable'] || pt['CustomSql'] || {}
      (rt['InputColumns'] || []).each do |c|
        next unless c['Type'].to_s.upcase == 'BOOLEAN'
        BOOLEAN_COLS << disp(c['Name'])
        BOOLEAN_RAW << c['Name']
      end
    end
    types = (DATASET_COL_TYPES[ds['DataSetId'].to_s] ||= {})
    (ds['OutputColumns'] || []).each do |c|
      next unless c.is_a?(Hash) && c['Name']
      types[c['Name']] = c['Type'].to_s.upcase
      DATASET_COLS << c['Name']
    end
  end
  STDERR.puts "boolean-cols: #{BOOLEAN_COLS.size} BOOLEAN column(s) detected from discovery datasets" unless BOOLEAN_COLS.empty?
end

# String literals / {refs} / ${params} / [refs] are tokens; only the code BETWEEN them is rewritten.
QS_EXPR_TOKEN = /(\$\{[^}]*\}|\{[^}]*\}|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|\[[^\]]*\])/.freeze

def qs_ci_name(candidates, name)
  candidates.find { |candidate| candidate.to_s.casecmp(name.to_s).zero? }
end

# Exact calc names win, but a case-insensitive physical-column match must not become a calc.
def qs_calc_name(calcs, name)
  exact = calcs.keys.find { |candidate| candidate.to_s == name.to_s }
  return exact if exact
  return nil if qs_ci_name(DATASET_COLS, name)
  qs_ci_name(calcs.keys, name)
end

# Extract the dataset/calc reads from a calculated field using the same bare-identifier
# rules as the formula translator. Routing needs these before translation chooses a master.
def qs_calc_refs(expr, calcs)
  refs = expr.to_s.scan(/\{([^}]+)\}/).flatten.map(&:strip)
  expr.to_s.split(QS_EXPR_TOKEN, -1).each_with_index do |piece, i|
    next unless i.even?
    piece.scan(/(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])(?!\s*\()/).flatten.each do |word|
      ref = qs_calc_name(calcs, word) || qs_ci_name(DATASET_COLS, word)
      refs << ref if ref
    end
  end
  refs.map { |ref| qs_calc_name(calcs, ref) || qs_ci_name(DATASET_COLS, ref) || ref }.uniq
end

# ---- derive the columns the dashboard actually references (raw col names) ----
def visual_cols(inner)
  out = []
  walk = lambda do |o|
    if o.is_a?(Hash)
      if (c = o['Column']) && c.is_a?(Hash) && c['ColumnName']
        out << c['ColumnName']
      end
      o.each_value { |v| walk.call(v) }
    elsif o.is_a?(Array)
      o.each { |v| walk.call(v) }
    end
  end
  walk.call(inner['ChartConfiguration'] || {})
  out
end

calc_names = {}
(defn['CalculatedFields'] || []).each { |c| calc_names[c['Name']] = c['Expression'] }

needed_raw = []
defn['Sheets'].each do |sh|
  (sh['Visuals'] || []).each do |v|
    _, inner = v.first
    needed_raw.concat(visual_cols(inner))
  end
end
needed_raw.uniq!
# calc fields resolve to raw columns inside their expressions; expand
needed_resolved = needed_raw.flat_map do |n|
  if (calc_name = qs_calc_name(calc_names, n))
    qs_calc_refs(calc_names[calc_name], calc_names)
  else
    [n]
  end
end.uniq

# ---- pick the DM element whose columns COVER the charted columns ----
# Use the dm-spec (has column display names) to score coverage; fall back to the
# dm-readback element list when no dm-spec is provided. ([bead] point 4)
dm_spec = opts[:dmspec] && File.exist?(opts[:dmspec]) ? JSON.parse(File.read(opts[:dmspec])) : nil
# A REUSED data model (migrate-quicksight.rb --reuse-dm stamps `reusedDataModel`) was not
# produced from any dm-spec.json in this workdir: the index pairing below would pick the
# wrong element, so ignore a --dm-spec that is paired with such a readback.
if dm_spec && rb['reusedDataModel']
  STDERR.puts "WARN ignoring --dm-spec #{opts[:dmspec]}: dm-readback is a REUSED data model, so element choice follows readback column coverage"
  dm_spec = nil
end
needed_disp = needed_resolved.map { |c| disp(c) }.to_set

best = nil
best_idx = nil
if dm_spec
  spec_els = (dm_spec['pages'] || []).flat_map { |pg| pg['elements'] || [] }
  scored = spec_els.each_with_index.map do |el, i|
    names = (el['columns'] || []).map { |c| c['name'] }.compact.to_set
    cover = needed_disp.count { |d| names.include?(d) }
    [cover, (el['columns'] || []).size, el['name'], i]
  end
  # most coverage; tie-break on more columns (the denormalized view wins)
  top = scored.max_by { |cover, ncols, _name, _i| [cover, ncols] }
  best = top && top[2]
  best_idx = top && top[3]
end

rb_els = (rb['pages'] || []).flat_map { |pg| pg['elements'] || [] }
# Display labels a readback element exposes: columnLabels (the data model's real /columns
# index, stamped by post-and-readback.rb / migrate --reuse-dm) plus any NAMED spec columns.
# A reused model's spec columns are often nameless, so the labels are the reliable source.
rb_label_set = ->(el) { DmColumnIndex.labels_of(el).to_set }
dm_el_obj =
  if best
    # DM element names can COLLIDE (e.g. two "D20 Kitchen Sink" elements: a source +
    # the denormalized join). Selecting by name alone would grab the first match and
    # miss the join element that actually covers the charted columns. The dm-spec and
    # dm-readback element lists are in the same order, so prefer the readback element at
    # the winning spec index; fall back to name match, then first.
    (best_idx && rb_els[best_idx]) || rb_els.find { |e| e['name'] == best } || rb_els.first
  elsif rb_els.any? { |e| !rb_label_set.call(e).empty? }
    # No dm-spec, but the readback carries column labels/names: score coverage directly off
    # the readback so we pick the element that actually COVERS the charted columns (handles
    # name-collision + arbitrary element ordering — beads D20). Tie-break on more columns
    # (the denormalized join wins).
    scored_rb = rb_els.map do |el|
      rs = DmColumnIndex::Resolver.new(el)
      cover = needed_resolved.count { |raw| rs.resolve(raw, prefer: disp(raw))[1] == :resolved }
      [cover, rs.labels.size, el]
    end
    top = scored_rb.max_by { |cover, ncols, _| [cover, ncols] }
    (top && top[2]) || rb_els.first
  else
    # no dm-spec and no readback columns: prefer the last (synthesized join element is
    # appended last) else first.
    rb_els.last || rb_els.first
  end
abort 'no DM elements in readback' unless dm_el_obj
dm_el = dm_el_obj['id']
DMEL = dm_el_obj['name'] || 'Custom SQL'   # DM element name — master refs cols as [DMEL/Col]
# Master element name (used in [M/Col] refs from charts). Default to the DM element's
# own name — not the fixture leftover 'Orders', which is wrong for any non-Orders
# dashboard and confused an early customer migration (RCA #10, bead 3goo.13).
M = opts[:mname] || DMEL
# DM metrics referenceable on the master (own on the host element + inherited via
# source.elementId): a measure whose inline aggregate matches one binds to a governed
# [Metrics/<name>] ref instead of re-deriving inline (bead 7bun.10 — emitted from the
# field-well aggregations by convert-model.rb --fixup). Global so the top-level
# meas_col / qs_reference_lines defs can read it; empty (or reuse-DM) → inline.
$QS_METRICS = MetricBinding.available_metrics(dm_el, rb_els.each_with_object({}) { |e, h| h[e['id']] = e })
STDERR.puts "metric-binding: #{$QS_METRICS.size} referenceable DM metric(s) for [Metrics/<name>] refs" if $QS_METRICS.any?

# ── Deterministic ids (issue #541) ───────────────────────────────────────────
# Element/column ids used to be SecureRandom, so every build minted a FRESH id
# space for the same analysis. That made a spec PUT to an existing workbook
# unsafe: the already-applied layout.xml and the control-scope.json sidecar still
# referenced the previous build's ids, so control lint reported ghost `mustReach`
# targets (32 of them, live) and — the dangerous one — a layout referencing
# elements absent from the spec renders the page N/A / blank (a field-reported
# blank-page class). It also quietly contradicted the orchestrator's idempotent-resume
# promise, since a rebuild could never reproduce the ids it had posted.
#
# Every id is now a short digest of the STABLE SOURCE IDENTITY — the QuickSight
# VisualId, the master element + column name, the QS FilterControlId — so the
# same analysis always builds the same id space and a re-PUT lines up with the
# layout and sidecars generated beside it.
#
# Uniqueness stays guaranteed WITHOUT randomness: `did` registers every id it
# returns and appends a stable first-seen ordinal (-2, -3, …) if the same
# identity is ever requested twice (two charts sharing a dimension, or a genuine
# digest collision). Build order is a deterministic walk of the analysis JSON, so
# those ordinals are reproducible too.
$ID_SEEN = Hash.new(0)
def did(prefix, *parts)
  base = "#{prefix}-#{Digest::SHA1.hexdigest([prefix, *parts.map(&:to_s)].join('|'))[0, 10]}"
  n = ($ID_SEEN[base] += 1)
  n == 1 ? base : "#{base}-#{n}"
end
NUM = ->(fs) { { 'kind' => 'number', 'formatString' => fs } }

# ── documentation-grounded mapping catalogs (SINGLE SOURCE OF TRUTH) ──────────
# Every enumerable classifier map (viz-kind KIND/QS_FALLBACK/QS_UNSUPPORTED derived at
# line ~550, aggregation AGG below, control list-vs-date-range) is LOADED from
# refs/catalogs/<dimension>.json — cited rows (QuickSight API-reference doc + Sigma
# target) with a LOUD fallback on anything unmapped: no silent Sum/Avg, no name-substring
# number-format guessing. NO inline mapping literal may bypass these catalogs (grep-
# enforced by tests/test-grounding.rb). refs/quicksight-coverage.md is GENERATED from
# them. Mirrors the merged Looker/Qlik pilot (build_workbook.py): catalog = data, code =
# thin resolver. ([bead])
CATALOGS = Coverage.load_all(Coverage.default_catalog_dir(__FILE__))
VIZ_CAT  = CATALOGS.fetch('viz-kind')
AGG_CAT  = CATALOGS.fetch('aggregation')
FMT_CAT  = CATALOGS.fetch('number-format')
CTRL_CAT = CATALOGS.fetch('control')
# QuickSight aggregation function -> Sigma aggregate, derived from aggregation.json (same
# source->target pairs the old inline hash carried). The LOUD miss-handling lives at each
# USE site (meas_col / qs_reference_lines) — never a silent `|| 'Sum'` / `|| 'Avg'` here.
AGG = AGG_CAT.rows.each_with_object({}) { |r, h| h[r['source']] = r['sigma'] if r['sigma'] }.freeze
# Loud notes raised by the top-level `def` classifiers (meas_col / fmt_for) that cannot
# see the build_warnings local; folded into build_warnings before the sidecar is written.
# Hash-shaped to match build_warnings. FMT_WARNED dedupes the per-column format notes.
CLASSIFIER_WARNINGS = []
FMT_WARNED = {}

# QuickSight window / table-calc function names (must match convert-model.rb). A
# calc field using any of these can't be a live Sigma formula — neutralize to Null.
QS_WINDOW_FUNCS = %w[
  runningSum runningAvg runningCount runningMax runningMin
  percentOfTotal percentDifference difference
  rank denseRank percentileRank
  lag lead firstValue lastValue
  windowSum windowAvg windowCount windowMax windowMin
  movingSum movingAverage
].freeze
def qs_window_func?(expr)
  e = expr.to_s
  QS_WINDOW_FUNCS.any? { |fn| e =~ /(?<![A-Za-z0-9_])#{Regexp.escape(fn)}\s*\(/ }
end

# minimal QuickSight-expr → Sigma-formula translator for calc fields referenced by visuals
# QuickSight/moment date-format tokens -> Sigma strftime (RCA #11). Longest-first.
def qs_datefmt_to_strftime(fmt)
  return nil if fmt.nil? || fmt.to_s.strip.empty?
  s = fmt.dup
  [%w[MMMM %B], %w[MMM %b], %w[MM %m], ['DD', '%d'], ['D', '%-d'],
   %w[YYYY %Y], %w[YY %y], %w[HH %H], %w[mm %M], %w[ss %S]].each { |q, c| s = s.gsub(q, c) }
  s
end

# ---- manual items ---------------------------------------------------------------------
# Things the builder could NOT migrate or resolve and a human must finish. Kept apart from
# build_warnings (which describe what WAS built with caveats): written to the `manual` list
# of <out>.warnings.json and printed at the end of the build. Deduped on (type, subject).
MANUAL_ITEMS = []
MANUAL_SEEN = {}
def manual_item!(type, subject, reason, extra = {})
  key = [type, subject]
  return if MANUAL_SEEN[key]
  MANUAL_SEEN[key] = true
  MANUAL_ITEMS << { 'type' => type, 'subject' => subject, 'reason' => reason }.merge(extra)
end

# Per-master column resolution state, keyed by the master's column hash (identity): the data
# model element it sources, and a DmColumnIndex::Resolver over that element's column index.
RESOLVERS = {}.compare_by_identity
MASTER_ELEMENTS = {}.compare_by_identity
def register_master!(master_cols, element)
  MASTER_ELEMENTS[master_cols] = element
  RESOLVERS[master_cols] = DmColumnIndex::Resolver.new(element)
end

# The label the data-model element gives dataset column `raw`. Falls back to the display-name
# guess (disp) when the element has no column index at all; when an index exists and the
# column is not in it, records a manual item and keeps the guess so the workbook stays
# structurally intact (validate-spec --dm-context then refuses to post it).
def resolve_dm_label(raw, master_cols)
  rs = RESOLVERS[master_cols]
  return disp(raw) unless rs
  label, status = rs.resolve(raw, prefer: disp(raw))
  return label if status == :resolved
  return disp(raw) if status == :unverified
  el = MASTER_ELEMENTS[master_cols] || {}
  why = status == :ambiguous ? 'matches more than one column' : 'is not a column'
  manual_item!('UnresolvedColumn', raw,
               "dataset column '#{raw}' #{why} of data-model element '#{el['name']}' (matched by source reference / column id, " \
               "then display label, ignoring case and punctuation - never fuzzy), so the master formula [#{el['name']}/#{disp(raw)}] " \
               'will not resolve. Map the column in the data model, or rewrite the master column by hand.',
               'element' => el['name'])
  disp(raw)
end

# Does master `mm` expose dataset column `raw`? Resolver-based; a master whose element has no
# column index at all falls back to the display-name set (the pre-index behaviour).
def master_covers?(mm, raw)
  r = mm[:resolver].resolve(raw, prefer: disp(raw))
  r[1] == :unverified ? mm[:labels].include?(disp(raw)) : r[1] == :resolved
end

# QuickSight scalar functions whose Sigma counterpart takes the SAME arguments, so only the
# head is renamed (every target is on the scripts/lib/sigma_functions.rb whitelist; anything
# else stays visible to validate-spec's function whitelist instead of being guessed).
# Sources: QuickSight functions https://docs.aws.amazon.com/quicksight/latest/user/functions-by-category.html ;
# Sigma functions https://help.sigmacomputing.com/docs/function-index
QS_SCALAR_FUNCS = {
  'isnull' => 'IsNull', 'coalesce' => 'Coalesce', 'concat' => 'Concat', 'replace' => 'Replace',
  'toupper' => 'Upper', 'tolower' => 'Lower', 'trim' => 'Trim', 'ltrim' => 'LTrim', 'rtrim' => 'RTrim',
  'left' => 'Left', 'right' => 'Right', 'strlen' => 'Len', 'abs' => 'Abs', 'floor' => 'Floor',
  'ceil' => 'Ceiling', 'round' => 'Round', 'sqrt' => 'Sqrt', 'exp' => 'Exp', 'ln' => 'Ln', 'mod' => 'Mod'
}.freeze
# Words that can appear bare in a QuickSight expression without being a column.
QS_EXPR_KEYWORDS = %w[and or not in like true false is pre_filter pre_agg post_agg_filter].freeze

# Translation context for qs_expr_to_sigma. `master_cols` set => MASTER context: dataset refs
# resolve against that master's data-model element and a {calc} ref is a SIBLING column.
# Without it (chart-measure context, `dmel` is the master's own name) refs use the master's
# display-name columns. `refs` collects every dataset/calc name the expression reads.
def qs_expr_ctx(calc, subject, master_cols: nil, land: nil)
  { calcs: calc, subject: subject, master_cols: master_cols, land: land, refs: [] }
end

def qs_expr_ref(nm, dmel, ctx)
  calc_name = qs_calc_name(ctx[:calcs] || {}, nm)
  ref_name = calc_name || nm
  ctx[:refs] << ref_name
  if calc_name
    ctx[:land] && ctx[:land].call(calc_name)
    return ctx[:master_cols] ? "[#{calc_name}]" : "[#{dmel}/#{calc_name}]"
  end
  label = ctx[:master_cols] ? resolve_dm_label(ref_name, ctx[:master_cols]) : disp(ref_name)
  BOOLEAN_COLS << label if ctx[:master_cols] && qs_ci_name(BOOLEAN_RAW, ref_name)
  "[#{dmel}/#{label}]"
end

def qs_expr_code(text, dmel, ctx)
  s = text.gsub('<>', '!=')
  s = s.gsub(/\bifelse\s*\(/i, 'If(')
  # QS aggregate/scalar function names -> Sigma. Only code between tokens is rewritten, so
  # substituted refs and string literals are never touched. Longest-first so
  # distinct_countIf matches before distinct_count and *If before the base. The negative
  # lookbehind + required '(' avoids touching identifiers/column names (RCA #9/#10).
  # COMPOSITIONAL, cited: this in-expression function-head substitution (incl. the
  # filtered *If variants) is NOT a flat one-key lookup, so it intentionally stays as code
  # and is NOT flattened into refs/catalogs/aggregation.json. That catalog holds only the
  # enumerable field-well AggregationFunction map (SimpleNumericalAggregation ->
  # AGG). QuickSight/moment date-format tokens are handled by qs_datefmt_to_strftime above.
  # Sources: QuickSight calc-field function reference
  # https://docs.aws.amazon.com/quicksight/latest/user/functions-and-operators.html ;
  # Sigma aggregate functions https://help.sigmacomputing.com/docs/aggregate-functions
  [%w[distinct_countIf CountDistinctIf], %w[distinct_count CountDistinct],
   %w[countIf CountIf], %w[sumIf SumIf], %w[avgIf AvgIf], %w[minIf MinIf], %w[maxIf MaxIf],
   %w[percentOfTotal PercentOfTotal], %w[count Count], %w[sum Sum], %w[avg Avg],
   %w[min Min], %w[max Max]].each do |qs, sig|
    s = s.gsub(/(?<![A-Za-z0-9_.\/])#{Regexp.escape(qs)}\s*\(/i, "#{sig}(")
  end
  QS_SCALAR_FUNCS.each do |qs, sig|
    s = s.gsub(/(?<![A-Za-z0-9_.\/])#{Regexp.escape(qs)}\s*\(/i, "#{sig}(")
  end
  # BARE identifiers (QuickSight accepts `channel = 'x'` without braces): bracket the ones
  # that name a dataset column or a calc field; NULL -> Null; leave keywords and function
  # heads alone; report anything else instead of passing it through silently.
  s.gsub(/(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])(?!\s*\()/) do
    word = Regexp.last_match(1)
    low = word.downcase
    if low == 'null'
      'Null'
    elsif QS_EXPR_KEYWORDS.include?(low)
      word
    elsif (ref_name = qs_calc_name(ctx[:calcs] || {}, word) || qs_ci_name(DATASET_COLS, word))
      qs_expr_ref(ref_name, dmel, ctx)
    else
      manual_item!('UnresolvedIdentifier', "#{ctx[:subject]}: #{word}",
                   "calc field '#{ctx[:subject]}' uses bare identifier '#{word}', which is neither a dataset column nor a calc field " \
                   '(and not a QuickSight keyword) - it is left unchanged and will not resolve in Sigma; rewrite it by hand.')
      word
    end
  end
end

def qs_expr_to_sigma(expr, dmel, params = {}, ctx = nil)
  ctx ||= qs_expr_ctx({}, '(expression)')
  out = expr.to_s.split(QS_EXPR_TOKEN, -1).each_with_index.map do |piece, i|
    next qs_expr_code(piece, dmel, ctx) if i.even?
    case piece
    when /\A\$\{/
      # ${Param} -> inlined default constant (what-if parameters have no DM-formula equivalent).
      v = params[piece[2..-2].strip]
      v.nil? ? '0' : (v.is_a?(String) ? "\"#{v}\"" : v.to_s)
    when /\A\{/
      qs_expr_ref(piece[1..-2].strip, dmel, ctx)
    when /\A'/
      "\"#{piece[1..-2].gsub("\\'", "'").gsub('"', '\\"')}\""
    else
      piece # "..." literal or an existing [ref]
    end
  end
  s = out.join
  # Boolean-flag predicates: a warehouse BOOLEAN column compared `= 1`/`= 0` (QS's idiom
  # for a flag it coerced to INTEGER) throws at query time in Sigma. Rewrite to the bare
  # boolean / Not() for columns known boolean (RCA #3, bead 3goo.3).
  if defined?(BOOLEAN_COLS) && !BOOLEAN_COLS.empty?
    s = s.gsub(/\[([^\]]+)\]\s*(=|!=)\s*(1|0|true|false)\b/i) do
      ref = Regexp.last_match(1); op = Regexp.last_match(2); val = Regexp.last_match(3).downcase
      if BOOLEAN_COLS.include?(ref.split('/').last)
        truthy = %w[1 true].include?(val)
        truthy = !truthy if op == '!='
        truthy ? "[#{ref}]" : "Not([#{ref}])"
      else
        Regexp.last_match(0)
      end
    end
  end
  s
end

calc = {}
(defn['CalculatedFields'] || []).each { |c| calc[c['Name']] = c['Expression'] }

# A QS visual title may be plain (`Title.FormatText.PlainText`) OR rich text
# (`Title.FormatText.RichText` = `<visual-title>Weekly Tasks</visual-title>` / inline
# styling spans). The builder previously read PlainText only, so every rich-text title
# fell back to the raw VisualId GUID as the element name (RCA #8, bead 3goo.8). Parse
# both, strip tags, unescape entities.
def qs_visual_title(inner, vtype, fallback = :visual_id)
  ft = (inner['Title'] || {})['FormatText'] || {}
  raw = ft['PlainText'] || ft['RichText']
  if raw && !raw.to_s.strip.empty?
    s = raw.gsub(/<[^>]+>/, '')
    { '&amp;' => '&', '&lt;' => '<', '&gt;' => '>', '&nbsp;' => ' ',
      '&#39;' => "'", '&quot;' => '"', " " => ' ' }.each { |k, val| s = s.gsub(k, val) }
    s = s.strip
    return s unless s.empty?
  end
  return nil if fallback.nil? # caller names untitled visuals itself
  (inner.is_a?(Hash) ? inner['VisualId'] : nil) || vtype
end

# QS BarsArrangement -> Sigma bar `stacking`. Sigma defaults bars to STACKED, so an
# unspecified or CLUSTERED QS arrangement must be set to 'none' to render side-by-side
# (the QS spec + screenshot show clustered bars — RCA).
def qs_bars_stacking(inner)
  case inner.dig('ChartConfiguration', 'BarsArrangement').to_s.upcase
  when 'STACKED' then 'stacked'
  when 'STACKED_PERCENT' then 'normalized'
  else 'none'
  end
end

# QuickSight exposes per-chart LegendOptions, not a standalone shared legend
# control. Preserve only the released chart-local fields and do not invent an
# interactive legend element that the source does not contain.
def apply_qs_legend!(element, inner, title, warnings)
  return unless element
  supported = %w[bar-chart line-chart area-chart combo-chart waterfall-chart
                 scatter-chart pie-chart donut-chart region-map point-map]
  return unless supported.include?(element['kind'])

  source = (inner['ChartConfiguration'] || {})['Legend']
  return unless source.is_a?(Hash)
  legend = {}
  visibility = source['Visibility'].to_s.upcase
  legend['visibility'] = 'hidden' if visibility == 'HIDDEN'
  legend['visibility'] = 'shown' if visibility == 'VISIBLE'
  position = source['Position'].to_s.downcase
  legend['position'] = position if %w[top bottom left right].include?(position)
  element['legend'] = legend unless legend.empty?

  unsupported = source.keys - %w[Visibility Position]
  unless unsupported.empty?
    warnings << { 'visual' => title, 'type' => 'LegendStyle',
                  'reason' => "QuickSight legend fields #{unsupported.join(', ')} have no grounded Sigma mapping; visibility/position were preserved and the rest omitted" }
  end
end

def field_role(f)
  if (mf = f['NumericalMeasureField'])
    [:meas, mf['Column']['ColumnName'], (mf.dig('AggregationFunction', 'SimpleNumericalAggregation') || 'SUM')]
  elsif (mf = f['CategoricalMeasureField'])
    # AggregationFunction here is a PLAIN STRING ('DISTINCT_COUNT' / 'COUNT'), not the
    # nested SimpleNumericalAggregation shape. Honor it — hardcoding COUNT silently turned
    # every QS DISTINCT_COUNT(TASK_ID) KPI into a non-distinct Count (RCA #2, bead 3goo.2).
    [:meas, mf['Column']['ColumnName'], (mf['AggregationFunction'] || 'COUNT').to_s.upcase]
  elsif (mf = f['DateMeasureField'])
    # MIN / MAX / COUNT / DISTINCT_COUNT of a date column. AggregationFunction is a PLAIN STRING
    # (DateAggregationFunction), like CategoricalMeasureField — all four are in the aggregation
    # catalog. Unread before: a "Latest order date" KPI vanished with no warning.
    [:meas, mf['Column']['ColumnName'], (mf['AggregationFunction'] || 'COUNT').to_s.upcase]
  elsif (df = f['CategoricalDimensionField'])
    [:dim, df['Column']['ColumnName'], nil]
  elsif (df = f['DateDimensionField'])
    # 4th tuple slot carries the QS DateGranularity (YEAR/QUARTER/MONTH/WEEK/DAY/...)
    # so a date x-axis can be truncated to that grain (D20 line-chart monthly).
    # QS frequently omits DateGranularity on a date dim but still renders it at DAY
    # grain; absent a default, a raw DATETIME on a pivot Columns shelf explodes into one
    # column per millisecond (RCA #6, bead 3goo.6). Default to DAY.
    [:dim, df['Column']['ColumnName'], nil, (df['DateGranularity'] || 'DAY')]
  end
end

# Generic field-well flattener for the D18 fallback path. The unsupported QS visual
# types use non-standard well names (Categories / Source / Destination / Weight /
# GroupBy / Size / Color / ...), so the named-well lambda in the dispatch cannot find
# them. This walks EVERY well in the field-well object, in document order, and returns
# [dims, measures] (each an array of field_role tuples). Used only for fallbacks.
def all_field_roles(w)
  dims = []; meas = []
  (w || {}).each do |_well, fields|
    next unless fields.is_a?(Array)
    fields.each do |f|
      r = field_role(f); next unless r
      (r[0] == :dim ? dims : meas) << r
    end
  end
  [dims, meas]
end

# The QuickSight FieldId of a single field-well entry (e.g. "f_cnt"). Needed to map a
# ConditionalFormatting rule (keyed by FieldId) back to the Sigma column we built.
def field_id(f)
  return nil unless f.is_a?(Hash)
  (f['NumericalMeasureField'] || f['CategoricalMeasureField'] || f['DateMeasureField'] ||
   f['CategoricalDimensionField'] || f['DateDimensionField'] ||
   f)['FieldId']   # an UNAGGREGATED table field is the bare {FieldId, Column} hash itself
end

# ---- QS SortConfiguration -> Sigma sort ([bead]) -------------------
# QuickSight sorts live under ChartConfiguration.SortConfiguration, e.g.
#   { "CategorySort": [ { "FieldSort":  { "FieldId": "...", "Direction": "DESC" } },
#                       { "ColumnSort": { "SortBy": { "Column": { "ColumnName": ... } },
#                                         "Direction": "ASC", "AggregationFunction": {...} } } ] }
# (bar/line/pie use CategorySort; TableVisual uses RowSort.) Resolve the sorted field
# to the Sigma column built for the visual and emit the verified Sigma shapes:
#   bar/line/area/combo/scatter : xAxis.sort  = { by: <colId>, direction: }
#   pie/donut                   : color.sort  = { by: <colId>, direction: }
#   table                       : sort        = [{ columnId:, direction: }]
# (pivot-table columnsBy/rowsBy sorts are NOT spec-supported — skipped with a warning.)

# Every FieldId -> raw ColumnName mapping in the visual's field wells.
def fid_to_colname(field_wells)
  map = {}
  walk = lambda do |o|
    if o.is_a?(Hash)
      if o['FieldId'] && (cn = o.dig('Column', 'ColumnName'))
        map[o['FieldId']] = cn
      end
      o.each_value { |v| walk.call(v) }
    elsif o.is_a?(Array)
      o.each { |v| walk.call(v) }
    end
  end
  walk.call(field_wells || {})
  map
end

# Apply a visual's SortConfiguration to the built Sigma element (mutates el).
def apply_qs_sorts(el, inner, kind, title, warnings, field_cols = nil)
  cc = inner['ChartConfiguration'] || {}
  sc = cc['SortConfiguration']
  entries = (sc.is_a?(Hash) && !sc.empty?) ? sc.values.find { |v| v.is_a?(Array) && !v.empty? } : nil
  # QuickSight renders pie/donut slices VALUE-DESCENDING by default and needs no explicit
  # CategorySort to do it; Sigma's default for an unsorted pie is dimension-ASCENDING. So an
  # unsorted QS pie otherwise migrates to an ALPHABETICAL slice order — and because
  # themeOverrides.categoricalScheme is applied POSITIONALLY in Sigma's category order, every
  # member also gets repainted with the wrong palette slot (a 0-value member can take the
  # primary color). Emit QuickSight's own default explicitly. Bar/line keep Sigma's default:
  # QuickSight sorts those by the category axis unless a CategorySort says otherwise.
  if entries.nil?
    if %w[pie-chart donut-chart].include?(kind) && (mid = el.dig('value', 'id'))
      (el['color'] ||= {})['sort'] = { 'by' => mid, 'direction' => 'descending' }
    end
    return
  end
  if kind == 'pivot-table'
    warnings << { 'visual' => title, 'type' => 'SortConfiguration',
                  'reason' => 'pivot-table sorts are not spec-expressible in Sigma (columnsBy/rowsBy sort rejected) — set in the UI' }
    return
  end
  fidmap = fid_to_colname(cc['FieldWells'])
  entries.each_with_index do |entry, i|
    fs = entry['FieldSort']; cs = entry['ColumnSort']
    raw = fs ? fidmap[fs['FieldId']] : cs&.dig('SortBy', 'Column', 'ColumnName')
    dir = ((fs || cs || {})['Direction'].to_s.upcase == 'DESC') ? 'descending' : 'ascending'
    next unless raw
    # FieldId -> column id first (a table's CustomLabel renames the column, so a NAME lookup
    # would miss it); then column names on the element: calc fields keep the raw name,
    # physical cols are disp()'d
    cid = field_cols && (fs ? field_cols[fs['FieldId']] : (fid = fidmap.key(raw)) && field_cols[fid])
    col = cid && (el['columns'] || []).find { |c| c['id'] == cid }
    col ||= (el['columns'] || []).find { |c| c['name'] == disp(raw) || c['name'] == raw }
    unless col
      warnings << { 'visual' => title, 'type' => 'SortConfiguration',
                    'reason' => "sort field '#{raw}' is not among the visual's Sigma columns — sort skipped" }
      next
    end
    case kind
    when 'bar-chart', 'line-chart', 'area-chart', 'combo-chart', 'scatter-chart'
      (el['xAxis'] ||= {})['sort'] = { 'by' => col['id'], 'direction' => dir } if i.zero?
    when 'pie-chart', 'donut-chart'
      (el['color'] ||= {})['sort'] = { 'by' => col['id'], 'direction' => dir } if i.zero?
    when 'table'
      (el['sort'] ||= []) << { 'columnId' => col['id'], 'direction' => dir }
    end
  end
end

# ---- TableVisual FieldOptions / table options -> Sigma table column props ----------------
# TableFieldOptions: SelectedFieldOptions[{FieldId, CustomLabel, Visibility, Width, URLStyling}],
# Order[FieldId...], PinnedFieldOptions. Mapped: CustomLabel -> the column NAME, Visibility
# HIDDEN -> `hidden: true`, Order -> the table's `order` (and the columns[] declaration order).
# Everything else is REPORTED, never dropped silently. `field_cols` = FieldId -> column id.
QS_TABLE_UNMAPPED_OPTIONS = %w[TableOptions TotalOptions PaginatedReportOptions TableInlineVisualizations].freeze
def apply_qs_table_field_options!(el, inner, field_cols, title, warnings)
  cc = inner['ChartConfiguration'] || {}
  present = QS_TABLE_UNMAPPED_OPTIONS.select { |k| cc.key?(k) && !(cc[k].respond_to?(:empty?) && cc[k].empty?) }
  unless present.empty?
    warnings << { 'visual' => title, 'type' => 'TableOptions',
                  'reason' => "QuickSight #{present.join(' / ')} (header/cell styling, totals, pagination, inline visuals) have no grounded Sigma mapping - not migrated" }
  end
  fo = cc['FieldOptions'].is_a?(Hash) ? cc['FieldOptions'] : {}
  sel = Array(fo['SelectedFieldOptions']).select { |o| o.is_a?(Hash) && o['FieldId'] }
  order = Array(fo['Order'])
  unmapped = []
  unmapped << 'PinnedFieldOptions' if fo['PinnedFieldOptions'].is_a?(Hash) && !fo['PinnedFieldOptions'].empty?
  sel.each { |o| %w[Width URLStyling].each { |k| unmapped << k unless o[k].nil? } }
  unless unmapped.empty?
    warnings << { 'visual' => title, 'type' => 'TableFieldOptions',
                  'reason' => "QuickSight table field option(s) #{unmapped.uniq.join(', ')} have no grounded Sigma mapping - not migrated (labels, hidden columns and order were)" }
  end
  return if sel.empty? && order.empty?
  cols = el['columns'] || []
  by_id = cols.each_with_object({}) { |c, h| h[c['id']] = c }
  # 1. resolve EVERY final name first, 2. only then de-duplicate: a swap (A->B, B->A) has
  # distinct final names and must not pick up a spurious "(2)".
  finals = cols.each_with_object({}) { |c, h| h[c['id']] = c['name'] }
  labelled = false
  sel.each do |o|
    cid = field_cols[o['FieldId']]
    next unless cid && by_id[cid]
    lbl = o['CustomLabel'].to_s.strip
    (finals[cid] = lbl; labelled = true) unless lbl.empty?
    by_id[cid]['hidden'] = true if o['Visibility'].to_s.upcase == 'HIDDEN'
  end
  if labelled
    seen = Hash.new(0)
    cols.each do |c|
      n = finals[c['id']]
      seen[n] += 1
      c['name'] = seen[n] == 1 ? n : "#{n} (#{seen[n]})"
    end
  end
  ids = order.map { |fid| field_cols[fid] }.compact.uniq.select { |cid| by_id[cid] }
  unless ids.empty?
    rest = cols.map { |c| c['id'] } - ids
    el['columns'] = (ids + rest).map { |cid| by_id[cid] }
    el['order'] = ids + rest
  end
end

# ---- QS ReferenceLines -> Sigma refMarks (B-gap: reference lines) ------------
# QuickSight reference lines live at ChartConfiguration.ReferenceLines[] on the
# cartesian visuals (bar/line/area/combo/scatter). Each entry:
#   { "Status": "ENABLED",
#     "DataConfiguration": {
#       "AxisBinding": "PRIMARY_YAXIS",          # PRIMARY_YAXIS|SECONDARY_YAXIS = series; *_XAXIS = axis
#       "StaticConfiguration": { "Value": 0.45 } # a constant; OR
#       "DynamicConfiguration": { "Calculation": {"SimpleNumericalAggregation":"AVERAGE"},
#                                 "MeasureAggregationFunction": {...}, "Column": {...} } },
#     "LabelConfiguration": { "CustomLabelConfiguration": { "CustomLabel": "Target" },
#                             "FontColor": "#ef4444" },
#     "StyleConfiguration": { "Color": "#ef4444", "Pattern": "DASHED" } }
# Sigma refMarks (verified shape, qlik_refmarks() parity, 2026-06-15): the value
# MUST be the wrapped { type:"formula", formula:"<expr>" } form (a bare number 400s);
# label.visibility must be "shown". A static value -> the literal; a dynamic
# (aggregation over a column) -> the Sigma aggregate formula over the master, so the
# line tracks the data. X-axis bindings -> axis "axis"; Y/measure bindings -> "series".
def qs_reference_lines(inner, calc, master_cols, dmel, m, title, warnings)
  cc = inner['ChartConfiguration'] || {}
  lines = cc['ReferenceLines']
  return [] unless lines.is_a?(Array) && !lines.empty?
  out = []
  lines.each do |rl|
    next if rl['Status'].to_s.upcase == 'DISABLED'
    dc = rl['DataConfiguration'] || {}
    axis = dc['AxisBinding'].to_s.upcase.include?('XAXIS') ? 'axis' : 'series'
    formula = nil
    if (sc = dc['StaticConfiguration']) && !sc['Value'].nil?
      formula = sc['Value'].to_s
    elsif (dyn = dc['DynamicConfiguration'])
      # aggregation over a column -> Agg([Master/Col]); the line follows the data.
      col = dyn.dig('Column', 'ColumnName') || dyn.dig('MeasureAggregationFunction', 'Column', 'ColumnName')
      aggk = (dyn.dig('Calculation', 'SimpleNumericalAggregation') ||
              dyn.dig('MeasureAggregationFunction', 'SimpleNumericalAggregation') || 'AVERAGE').to_s.upcase
      if col
        ref = master_ref(col, calc, master_cols, dmel)
        # aggregation is CATALOG-resolved (AGG from aggregation.json). On a miss, LOUDLY
        # warn + skip the line — NEVER a silent `|| 'Avg'` (the old default quietly drew
        # the reference line at the wrong aggregate).
        sig_agg = AGG[aggk]
        if sig_agg.nil?
          warnings << { 'visual' => title, 'type' => 'ReferenceLine',
                        'reason' => "dynamic reference-line aggregation '#{aggk}' has no documented Sigma mapping — line skipped (was silently defaulting to Avg); add a cited row to refs/catalogs/aggregation.json if it should map" }
          next
        end
        formula = MetricBinding.metric_ref_or_inline("#{sig_agg}([#{m}/#{ref['name']}])", m, $QS_METRICS || [])
      end
    end
    if formula.nil? || formula.empty?
      warnings << { 'visual' => title, 'type' => 'ReferenceLine',
                    'reason' => 'reference line has neither a static value nor a resolvable dynamic column — skipped' }
      next
    end
    color = rl.dig('StyleConfiguration', 'Color') || rl.dig('LabelConfiguration', 'FontColor') || '#ef4444'
    rm = { 'type' => 'line', 'axis' => axis,
           'value' => { 'type' => 'formula', 'formula' => formula },
           'line' => { 'color' => color, 'width' => 2 } }
    lbl = rl.dig('LabelConfiguration', 'CustomLabelConfiguration', 'CustomLabel')
    rm['label'] = { 'visibility' => 'shown', 'text' => lbl } if lbl && !lbl.to_s.empty?
    out << rm
  end
  out
end

# ---- QS chart color encoding -> Sigma `color` channel (B-gap: by-measure / by-dimension)
# QuickSight encodes series color two ways inside the aggregated field wells:
#   * by DIMENSION — a `Colors` well holding a CategoricalDimensionField (the chart is
#     split into one colored series per dimension value). -> Sigma color:{by:category}
#     on that dimension's Sigma column (added to the element if not already present).
#   * by MEASURE — a `ColorScale` (ColorFillType + Colors[] gradient stops) under the
#     visual's ColorScale/ScalarColors config, coloring marks along a measure's value.
#     A Sigma column can't sit on both yAxis and color, so (qlik_color() parity) we add
#     a DUPLICATE of the first measure column and put color:{by:scale, scheme} on it.
# Returns the color hash (and MUTATES el['columns'] for the by-scale dup / by-category
# dim) or nil. `wells` is the inner aggregated-field-wells hash; dim_ids/m_ids are the
# Sigma column ids already built for this element.
def qs_color(inner, wells, el, dim_ids, m_ids, calc, master_cols, dmel, m)
  cc = inner['ChartConfiguration'] || {}
  # by-dimension: a Colors well with a categorical dimension
  color_roles = (wells['Colors'] || []).map { |f| field_role(f) }.compact
  cdim = color_roles.find { |r| r[0] == :dim }
  if cdim
    # reuse the dim column if it's already on the element, else add it
    existing = (el['columns'] || []).find { |c| c['name'] == disp(cdim[1]) || c['name'] == cdim[1] }
    if existing
      return { 'by' => 'category', 'column' => existing['id'] }
    end
    dc, did = dim_col(cdim, calc, master_cols, dmel, m)
    (el['columns'] ||= []) << dc
    return { 'by' => 'category', 'column' => did }
  end
  # by-measure: a ColorScale gradient (ColorFillType + Colors[] stops). QS nests it
  # under the aggregated field-wells (Color/ColorScale) OR ChartConfiguration.ColorScale.
  cs = wells['ColorScale'] || cc['ColorScale']
  if cs.is_a?(Hash) && !m_ids.empty?
    stops = (cs['Colors'] || []).map { |st| st.is_a?(Hash) ? st['Color'] : st }.compact
    scheme = stops.size >= 2 ? stops : ['#ffffcc', '#fd8d3c', '#bd0026']
    base = (el['columns'] || []).find { |c| c['id'] == m_ids[0] }
    return nil unless base
    cid = did('clr', el['id'], base['id'])
    dup = { 'id' => cid, 'formula' => base['formula'], 'name' => "#{base['name']} (color)" }
    dup['format'] = base['format'] if base['format']
    (el['columns'] ||= []) << dup
    return { 'by' => 'scale', 'column' => cid, 'scheme' => scheme }
  end
  nil
end

# Translate a QuickSight TableVisual ConditionalFormatting block into Sigma
# `conditionalFormats` (D19). Supported QS -> Sigma mappings (verified spec-expressible
# + round-tripping via /v2/workbooks/spec, 2026-06-06):
#   - TextFormat.BackgroundColor.Gradient  -> type:"backgroundScale" (gradient on cell bg)
#   - TextFormat.TextColor.Gradient        -> type:"fontScale"
#   - DataBars                             -> type:"dataBars"
# The gradient Color.Stops (offset/color) become the Sigma `scheme` color-stop array.
# fieldmap maps QS FieldId -> Sigma column id (only measure cells are colored).
def qs_conditional_formats(cf_block, fieldmap)
  out = []
  (cf_block['ConditionalFormattingOptions'] || []).each do |opt|
    cell = opt['Cell'] || opt['Row'] || {}
    fid  = cell['FieldId']
    colid = fieldmap[fid]
    next unless colid
    tf = cell['TextFormat'] || {}
    if (grad = tf.dig('BackgroundColor', 'Gradient'))
      scheme = (grad.dig('Color', 'Stops') || []).map { |st| st['Color'] }.compact
      scheme = ['#FFFFFF', '#D13212'] if scheme.size < 2
      out << { 'type' => 'backgroundScale', 'columnIds' => [colid], 'scheme' => scheme }
    elsif (grad = tf.dig('TextColor', 'Gradient'))
      scheme = (grad.dig('Color', 'Stops') || []).map { |st| st['Color'] }.compact
      scheme = ['#FFFFFF', '#D13212'] if scheme.size < 2
      out << { 'type' => 'fontScale', 'columnIds' => [colid], 'scheme' => scheme }
    elsif cell['DataBars']
      db = cell['DataBars']
      pos = db['PositiveColor'] || '#1f77b4'
      out << { 'type' => 'dataBars', 'columnIds' => [colid], 'scheme' => [pos] }
    end
  end
  out
end

# QuickSight visual type -> Sigma element kind.
#
# Sigma's REAL workbook chart kinds (confirmed against the public OpenAPI element
# union — /v2/workbooks/spec): kpi-chart, bar-chart, line-chart, area-chart,
# pie-chart, donut-chart, scatter-chart, combo-chart, waterfall-chart, progress,
# table, pivot-table, AND the three geographic kinds point-map / region-map /
# geography-map. There is NO native histogram or heat-map. (CORRECTED 2026-08-26:
# treemap-chart and box-chart ARE native and live-verified; this converter has not
# been re-routed to them yet — see sigma-workbooks reference/specification/charts.md.)
# Historically also listed as unsupported: treemap, box-plot,
# radar, sankey, or word-cloud kind.
#
# Approximations (no native kind, mirror the PBI builder, [bead]):
#   funnel/treemap -> bar-chart (category+measure).
# Geographic (NEW — region-map shape verified to round-trip via live POST+readback
# + MCP query parity on the D17 DM, 2026-06-06): QuickSight FilledMapVisual and
# GeospatialMapVisual both map to Sigma region-map when their geo field is a region
# NAME (state/country/city/zip); GeospatialMapVisual maps to point-map only when it
# carries real latitude+longitude fields (handled in the dispatch). LayerMapVisual
# (multi-layer) has no clean single-element equivalent -> dropped with a warning.
# KIND / QS_FALLBACK / QS_UNSUPPORTED are DERIVED from refs/catalogs/viz-kind.json
# (loaded above as VIZ_CAT), so this dispatch and refs/quicksight-coverage.md cannot
# drift from a single cited source. Row classes (see the catalog's `description`):
#   * NATIVE (no `unsupported_reason`)      -> KIND[type] = Sigma kind. Gauge maps to
#     native progress; Funnel/TreeMap are native-dispatch approximations because Sigma
#     has no corresponding element and carry a `notes` rationale in the catalog.
#   * FALLBACK (`fallback:true`+reason)     -> QS_FALLBACK[type] = the approximation kind
#     (bar/table) AND QS_UNSUPPORTED[type] = reason. Sigma has NO native equivalent, so
#     the visual is DATA-MIGRATED from its underlying dims+measures with a loud warning
#     (query/data parity preserved; the chart KIND is the (c)-tail, not the data).
#   * DROP (`sigma:null`+reason)            -> QS_UNSUPPORTED[type] = reason only. No
#     underlying dim+measure well to migrate (Insight/CustomContent/Plugin/Empty/
#     LayerMap) -> a genuine drop with a loud warning. Reason text is surfaced to STDERR
# + a sidecar warnings file either way. Same mapping the old inline hashes held.
KIND = {}
QS_FALLBACK = {}
QS_UNSUPPORTED = {}
VIZ_CAT.rows.each do |r|
  if r['unsupported_reason']
    QS_UNSUPPORTED[r['source']] = r['unsupported_reason']
    QS_FALLBACK[r['source']] = r['sigma'] if r['fallback'] && r['sigma']
  else
    KIND[r['source']] = r['sigma']
  end
end
KIND.freeze
QS_FALLBACK.freeze
QS_UNSUPPORTED.freeze
build_warnings = []
# Hidden GROUPED source tables emitted for scatter-charts (one row per point dim),
# appended to the Data page next to the master. See the scatter branch below
# (ported from the live-verified qlik-to-sigma builder, bead ry0n): Sigma's scatter
# axis is a GROUPING axis, so an aggregate (Sum(...)) over the UNGROUPED master
# collapses every point to one x. The scatter must instead bind to a hidden grouped
# source whose groupBy is the point dimension.
scatter_sources = []
repeat_sources = []

master_cols = {}   # colname(raw or calc) -> {id, formula, name}  (PRIMARY master's columns)

# ---- Multi-master routing (RCA #4, bead 3goo.4) ----------------------------
# A QS analysis can bind visuals to DIFFERENT datasets -> different DM elements. The old
# single-master design pointed EVERY visual at one master, so a visual on a second dataset
# got broken column refs AND contaminated the master with that dataset's calc fields.
# We register one Sigma master per DM element and route each visual to the master whose DM
# element COVERS its columns. A SINGLE-dataset analysis (the common case) routes every
# visual to the primary master, so its output is byte-identical to the prior behavior.
MASTERS = {}   # dm_el_id -> { sid, name, dmel, dm_el_id, cols(hash), labels(Set), resolver }
MASTERS[dm_el] = { sid: 'master', name: M, dmel: DMEL, dm_el_id: dm_el,
                   cols: master_cols, labels: rb_label_set.call(dm_el_obj),
                   resolver: register_master!(master_cols, dm_el_obj) }
PRIMARY_MASTER = MASTERS[dm_el]
# RAW dataset column names a visual reads (calc fields expanded to the columns inside them).
visual_needed_raw = lambda do |inner|
  raw = visual_cols(inner)
  raw.flat_map do |n|
    calc_name = qs_calc_name(calc, n)
    calc_name ? qs_calc_refs(calc[calc_name], calc) : [n]
  end.uniq
end
route_master = lambda do |inner|
  needed = visual_needed_raw.call(inner)
  prim_cover = needed.count { |r| master_covers?(PRIMARY_MASTER, r) }
  return PRIMARY_MASTER if needed.empty? || prim_cover == needed.size
  # not fully covered by the primary -> pick the DM element that covers it best (tie-break
  # on FEWER columns so the focused element wins over a denormalized superset)
  cand = rb_els.map do |e|
    rs = DmColumnIndex::Resolver.new(e)
    pseudo = { resolver: rs, labels: rb_label_set.call(e) }
    [needed.count { |r| master_covers?(pseudo, r) }, -rs.labels.size, e]
  end.max_by { |cover, negn, _e| [cover, negn] }
  return PRIMARY_MASTER if cand.nil? || cand[0] <= prim_cover   # nothing covers it better -> stay primary
  e = cand[2]
  unless MASTERS[e['id']]
    sec_cols = {}
    MASTERS[e['id']] = { sid: did('ms', e['id']), name: e['name'] || 'Data',
                         dmel: e['name'] || 'Custom SQL', dm_el_id: e['id'],
                         cols: sec_cols, labels: rb_label_set.call(e),
                         resolver: register_master!(sec_cols, e) }
  end
  MASTERS[e['id']]
end

# RCA #11 / bead 3goo.11: a QS InsightVisual with a single MAX/MIN computation + a
# CustomNarrative ("Report Date: <expr>") is reproducible as a Sigma TEXT element with a
# {{Agg([master/col]) | strftime}} dynamic value — not a hard drop. Returns the text body
# or nil (skip) when the computation isn't a simple single-value one OR the column isn't
# covered by a registered master (e.g. its dataset wasn't migrated). Conservative: emits
# only when a master already covers the column, so it never emits a broken ref.
qs_insight_text = lambda do |inner|
  cfg = inner['InsightConfiguration'] || {}
  comps = cfg['Computations'] || []
  narr = cfg.dig('CustomNarrative', 'Narrative')
  return nil if comps.size != 1 || narr.nil? || narr.to_s.strip.empty?
  ckey, comp = comps.first.first
  agg = ckey == 'MaximumMinimum' ? (comp['Type'].to_s.upcase == 'MINIMUM' ? 'Min' : 'Max') : nil
  return nil unless agg
  colname = nil; datefmt = nil
  walk = lambda do |o|
    if o.is_a?(Hash)
      colname ||= o.dig('Column', 'ColumnName')
      datefmt ||= o.dig('FormatConfiguration', 'DateTimeFormat') || o['DateTimeFormat']
      o.each_value { |v| walk.call(v) }
    elsif o.is_a?(Array) then o.each { |v| walk.call(v) }
    end
  end
  walk.call(comp)
  return nil unless colname
  dname = disp(colname)
  target = MASTERS.values.find { |mm| master_covers?(mm, colname) }
  return nil unless target   # dataset not migrated (e.g. a REPORT_RUN_DATES aux table) -> skip
  master_ref(colname, {}, target[:cols], target[:dmel])  # land the column on that master
  fmt = qs_datefmt_to_strftime(datefmt)
  val = "#{agg}([#{target[:name]}/#{dname}])"
  value = fmt ? "{{#{val} | #{fmt}}}" : "{{#{val}}}"
  prefix = narr.gsub(%r{<expression>.*?</expression>}m, '').gsub(/<[^>]+>/, '')
  { '&amp;' => '&', '&nbsp;' => ' ', '&#39;' => "'", '&quot;' => '"' }
    .each { |k, v| prefix = prefix.gsub(k, v) }
  prefix = prefix.tr(" ", ' ').gsub(/\s+/, ' ').strip
  align = narr =~ /align="right"/ ? 'right' : (narr =~ /align="center"/ ? 'center' : 'left')
  "<p style=\"text-align: #{align}\"><span style=\"font-size: 16px\">#{prefix} #{value}</span></p>"
end

# number-format ([bead]): a Sigma number format may ONLY come from a real
# QuickSight FormatConfiguration — NEVER guessed from the column NAME. The old body was
# the disease: a column-NAME regex matcher that assigned a currency format to any name
# containing revenue/profit/cost/etc, a percent format to margin/pct/etc, and a hardcoded
# thousands-integer format to everything else. That name-substring guessing AND its silent
# default are REMOVED. The builder does not yet parse FormatConfiguration, so this returns
# nil (no format — Sigma applies its type default) and raises a LOUD, deduped note so a
# real Sigma format can be applied. The D3 targets a FormatConfiguration would map to are
# documented in refs/catalogs/number-format.json (Sigma data-types-and-formats).
def fmt_for(name)
  unless FMT_WARNED[name]
    FMT_WARNED[name] = true
    CLASSIFIER_WARNINGS << { 'visual' => '(format)', 'type' => 'NumberFormat',
                             'reason' => "no QuickSight source format found for measure '#{name}' — chart data labels ship UNFORMATTED (Sigma type default, which matches QuickSight's own abbreviated 3.9M labels); KPI big-numbers get a GROUPED default instead (',.2f' / ',.0f' chosen by aggregation — issue #542, because Sigma's unformatted default renders period-grouped '15.045.294.83' where QuickSight renders '15,045,294.83'). Apply a Sigma number format explicitly if a measure needs currency/percent units (documented D3 targets in refs/catalogs/number-format.json). Name-substring format guessing is intentionally disabled." }
  end
  nil
end

# KPI big-number grouping fallback (issue #542).
#
# QuickSight frequently ships NO FormatConfiguration at all (measured: zero
# occurrences across a whole 8-visual dashboard) while still RENDERING its KPI
# big-numbers comma-grouped — "15,045,294.83", "800". With no source format to
# port, fmt_for correctly returns nil and warns, but Sigma's unformatted default
# then renders period-grouped ("15.045.294.83": three dots in one number), which
# reads as broken to a customer even though the value is exactly right. Only a
# visual check catches it, so it shipped once already.
#
# Group separators are a DISPLAY convention, not a semantic guess, so defaulting
# them does not resurrect the banned name-substring guessing: the decimal choice
# below is derived from the AGGREGATION in the built formula (a Count* is integral,
# anything else may carry cents), never from the column's name. An explicit source
# format always wins — this only fills a nil. Scoped to kpi-chart because chart
# data labels already match QuickSight's own abbreviated form (3.9M / 1.83M) and
# must stay untouched.
def kpi_number_format(col)
  return {} if col['format']                       # a real QuickSight format wins
  f = col['formula'].to_s
  return {} if f =~ /\A\s*Null\s*\z/i              # neutralized window calc — nothing to format
  integral = f =~ /\A\s*Count(Distinct)?\s*\(/i
  { 'format' => NUM.(integral ? ',.0f' : ',.2f') }
end

# Infer a Sigma region-map regionType from the geo dimension's (raw) column name.
# Sigma regionType enum (OpenAPI): country, us-state, us-county, us-zipcode,
# us-cbsa, us-postal-place, ca-province. Default to us-postal-place for free
# city/place names (the most permissive name-based bucket).
def region_type_for(rawname)
  n = rawname.to_s.downcase
  return 'country'         if n =~ /country|nation/
  return 'us-state'        if n =~ /\bstate\b|province_state|^st$/
  return 'us-county'       if n =~ /county/
  return 'us-zipcode'      if n =~ /zip|postal_?code|postcode/
  return 'us-cbsa'         if n =~ /cbsa|metro/
  return 'ca-province'     if n =~ /province/
  'us-postal-place'  # city / place name
end

# Does a Geospatial field-well carry an explicit latitude / longitude pair? If so
# the QuickSight geo visual should become a Sigma point-map; otherwise (a region
# NAME like state/city) it becomes a region-map.
def latlong_pair(geo_roles)
  lat = geo_roles.find { |r| r[1].to_s =~ /lat(itude)?/i }
  lon = geo_roles.find { |r| r[1].to_s =~ /lon(g|gitude)?/i }
  (lat && lon) ? [lat, lon] : nil
end

def master_ref(colname, calc, master_cols, dmel)
  return master_cols[colname] if master_cols[colname]
  if calc.key?(colname)
    if qs_window_func?(calc[colname])
      # neutralize: a window/table-calc field can't be a live Sigma calc column.
      formula = 'Null'; nm = colname
      master_cols[colname] = { 'id' => did('m', 'master', dmel, colname), 'formula' => formula, 'name' => nm,
                               'description' => "QuickSight table-calc (neutralized — re-author in Sigma): #{calc[colname]}",
                               '_window' => true }
      return master_cols[colname]
    end
    nm = colname
    # A calc that (transitively) reads itself cannot be built: stop the recursion and say so.
    $QS_CALC_STACK ||= []
    if $QS_CALC_STACK.include?(colname)
      manual_item!('CalcCycle', colname, "calc field '#{colname}' references itself (directly or through other calc fields) - emitted as Null; rewrite it by hand")
      formula = 'Null'
    else
      $QS_CALC_STACK.push(colname)
      begin
        # MASTER context: dataset refs resolve against this master's data-model element; a
        # {calc} / bare-calc ref is a sibling column, landed on this master first.
        ctx = qs_expr_ctx(calc, colname, master_cols: master_cols,
                          land: ->(name) { master_ref(name, calc, master_cols, dmel) })
        formula = qs_expr_to_sigma(calc[colname], dmel, defined?(PARAM_DEFAULTS) ? PARAM_DEFAULTS : {}, ctx)
      ensure
        $QS_CALC_STACK.pop
      end
    end
  else
    formula = "[#{dmel}/#{resolve_dm_label(colname, master_cols)}]"; nm = disp(colname)
  end
  master_cols[colname] = { 'id' => did('m', 'master', dmel, colname), 'formula' => formula, 'name' => nm }
end

# QuickSight ColumnHierarchies are explicit source evidence for drill. Emit a
# native drill control only when every ordered hierarchy level resolves on the
# visual's routed master. DateTimeHierarchy carries no columns in the analysis
# definition and therefore remains a loud gap instead of guessed year/month/day
# levels.
def build_qs_drill_control(element, inner, calc, master_cols, dmel, master_name, master, warnings)
  hierarchies = inner['ColumnHierarchies']
  return nil unless hierarchies.is_a?(Array) && !hierarchies.empty?
  unless element && element.dig('xAxis', 'columnId') && element.dig('source', 'elementId')
    warnings << { 'visual' => element && element['name'] || inner['VisualId'],
                  'type' => 'DrillHierarchy',
                  'reason' => 'QuickSight exported ColumnHierarchies, but this Sigma element has no categorical xAxis; native drill control not emitted' }
    return nil
  end

  active_id = element.dig('xAxis', 'columnId')
  active_col = Array(element['columns']).find { |column| column['id'] == active_id }
  active_name = active_col && active_col['name']
  candidate = hierarchies.filter_map do |wrapper|
    hierarchy = wrapper['ExplicitHierarchy'] || wrapper['PredefinedHierarchy']
    next unless hierarchy.is_a?(Hash)
    names = Array(hierarchy['Columns']).map { |column| column['ColumnName'] }.compact
    [hierarchy, names] if names.length > 1
  end.find { |_hierarchy, names| active_name && names.any? { |name| disp(name) == active_name || name == active_name } }
  candidate ||= hierarchies.filter_map do |wrapper|
    hierarchy = wrapper['ExplicitHierarchy'] || wrapper['PredefinedHierarchy']
    names = hierarchy.is_a?(Hash) ? Array(hierarchy['Columns']).map { |column| column['ColumnName'] }.compact : []
    [hierarchy, names] if names.length > 1
  end.first

  unless candidate
    warnings << { 'visual' => element['name'], 'type' => 'DrillHierarchy',
                  'reason' => 'QuickSight hierarchy has no exported ordered Columns (for example DateTimeHierarchy); native drill control not emitted' }
    return nil
  end

  hierarchy, names = candidate
  source_ids = []
  target_ids = []
  missing = []
  names.each_with_index do |raw_name, index|
    unless master_covers?(master, raw_name)
      missing << raw_name
      next
    end
    ref = master_ref(raw_name, calc, master_cols, dmel)
    unless ref
      missing << raw_name
      next
    end
    source_ids << ref['id']
    if ref['name'] == active_name
      target_ids << active_id
    else
      target_id = did('drill', element['id'], raw_name)
      element['columns'] << {
        'id' => target_id,
        'name' => ref['name'],
        'formula' => "[#{master_name}/#{ref['name']}]",
        'hidden' => true
      }
      target_ids << target_id
    end
  end
  unless missing.empty? && source_ids.length == names.length
    warnings << { 'visual' => element['name'], 'type' => 'DrillHierarchy',
                  'reason' => "QuickSight drill hierarchy #{names.join(' > ')} could not resolve every master column (missing: #{missing.join(', ')}); native drill control suppressed" }
    return nil
  end

  active_index = names.index { |name| disp(name) == active_name || name == active_name } || 0
  control_id = "Drill#{Digest::SHA1.hexdigest(inner['VisualId'].to_s)[0, 10]}"
  {
    'id' => did('ctl-drill', inner['VisualId']),
    'kind' => 'control',
    'name' => "#{element['name']} Drill",
    'controlId' => control_id,
    'controlType' => 'drill',
    'source' => {
      'kind' => 'source',
      'source' => { 'kind' => 'table', 'elementId' => element.dig('source', 'elementId') },
      'columnId' => source_ids[active_index]
    },
    'categories' => source_ids.map { |column_id| { 'columnId' => column_id } },
    'targets' => [{
      'source' => { 'kind' => 'table', 'elementId' => element['id'] },
      'columnIds' => target_ids
    }],
    'value' => source_ids[active_index],
    'filters' => [{
      'source' => { 'kind' => 'table', 'elementId' => element['id'] },
      'columnId' => target_ids[active_index]
    }],
    'controlScope' => [element['id']]
  }
end

def dim_col(role, calc, mc, dmel, m)
  # A date dimension (4th tuple slot = granularity, defaulted to DAY in field_role) must
  # be truncated — a raw DATETIME on a pivot Columns shelf otherwise explodes into one
  # column per timestamp and the crosstab looks empty (RCA #6, bead 3goo.6).
  return date_dim_col(role, calc, mc, dmel, m) if role[3]
  ref = master_ref(role[1], calc, mc, dmel); id = did('d', m, ref['name'])
  [{ 'id' => id, 'formula' => "[#{m}/#{ref['name']}]", 'name' => ref['name'] }, id]
end

# QuickSight DateGranularity -> Sigma DateTrunc() part. (D20: a LineChartVisual with a
# DateDimensionField DateGranularity=MONTH must aggregate the x-axis by month, not plot
# raw datetime. Sigma truncates via DateTrunc("month", <date>).)
QS_GRAIN = { 'YEAR' => 'year', 'QUARTER' => 'quarter', 'MONTH' => 'month',
             'WEEK' => 'week', 'DAY' => 'day', 'HOUR' => 'hour',
             'MINUTE' => 'minute', 'SECOND' => 'second' }.freeze

# Date dimension column truncated to a QS DateGranularity. Returns the same
# [col, id] shape as dim_col. The truncated column gets a date format string so the
# axis renders as e.g. "Jun 2026" for month grain.
def date_dim_col(role, calc, mc, dmel, m)
  grain = QS_GRAIN[role[3].to_s.upcase]
  return dim_col(role, calc, mc, dmel, m) unless grain
  ref = master_ref(role[1], calc, mc, dmel); id = did('d', m, ref['name'], grain)
  # Sigma datetime formatStrings are strftime conventions (NOT moment.js MMM/YYYY).
  fmt = case grain
        when 'year' then '%Y'
        when 'quarter' then '%b %Y'
        when 'month' then '%b %Y'
        when 'week', 'day' then '%Y-%m-%d'
        else '%Y-%m-%d %H:%M'
        end
  [{ 'id' => id, 'name' => ref['name'],
     'formula' => "DateTrunc(\"#{grain}\", [#{m}/#{ref['name']}])",
     'format' => { 'kind' => 'datetime', 'formatString' => fmt } }, id]
end

# A calc field whose translated expression is ALREADY a top-level aggregate
# (distinct_countIf/sum/etc.) must be emitted DIRECTLY as the chart measure over the
# master's base columns — wrapping it in the well's aggregation (Sum([m/<calc>])) yields
# an invalid nested aggregate (RCA #10, bead 3goo.10).
AGG_EXPR = /\A\s*(CountDistinctIf|CountDistinct|CountIf|Count|SumIf|Sum|AvgIf|Avg|MinIf|Min|MaxIf|Max|Median|StdDev\w*|Variance\w*)\s*\(/

def meas_col(role, calc, mc, dmel, m)
  _, col, agg = role
  if calc.key?(col) && !qs_window_func?(calc[col])
    # CHART-MEASURE context (no master_cols): refs point at the master's own columns (`m` prefix).
    ctx = qs_expr_ctx(calc, col)
    expr = qs_expr_to_sigma(calc[col], m, defined?(PARAM_DEFAULTS) ? PARAM_DEFAULTS : {}, ctx)
    if expr =~ AGG_EXPR
      # land each base column the aggregate references on the master, then emit the
      # aggregate itself as the measure (refs resolve to the master via the `m` prefix).
      ctx[:refs].uniq.each { |bc| master_ref(bc, calc, mc, dmel) }
      id = did('m', 'chart', m, col, 'agg')
      # governed [Metrics/<name>] ref when this aggregate calc matches a DM metric
      col_h = { 'id' => id, 'formula' => MetricBinding.metric_ref_or_inline(expr, m, $QS_METRICS || []), 'name' => col }
      (fs = fmt_for(col)) && (col_h['format'] = NUM.(fs))
      return [col_h, id]
    end
  end
  ref = master_ref(col, calc, mc, dmel); id = did('m', 'chart', m, col)
  # a neutralized window calc field can't be aggregated as a live formula either
  if ref['_window']
    return [{ 'id' => id, 'formula' => 'Null', 'name' => ref['name'],
              'description' => ref['description'] }, id]
  end
  # aggregation is CATALOG-resolved (AGG from aggregation.json). On a miss, LOUDLY warn +
  # neutralize to Null — NEVER a silent `|| 'Sum'` (the old default quietly turned an
  # unmapped QuickSight aggregation, e.g. STDEV/VAR/PERCENTILE, into a wrong Sum number).
  sig_agg = AGG[agg]
  if sig_agg.nil?
    CLASSIFIER_WARNINGS << { 'visual' => '(measure)', 'type' => 'Aggregation',
                             'reason' => "QuickSight aggregation '#{agg}' on '#{ref['name']}' has no documented Sigma mapping — measure neutralized to Null (was silently defaulting to Sum); add a cited row to refs/catalogs/aggregation.json if it should map" }
    return [{ 'id' => id, 'formula' => 'Null', 'name' => ref['name'],
              'description' => "unmapped QuickSight aggregation '#{agg}' — re-author in Sigma" }, id]
  end
  col_h = { 'id' => id,
            'formula' => MetricBinding.metric_ref_or_inline("#{sig_agg}([#{m}/#{ref['name']}])", m, $QS_METRICS || []),
            'name' => ref['name'] }
  (fs = fmt_for(ref['name'])) && (col_h['format'] = NUM.(fs))
  [col_h, id]
end

# D12: a measure that resolves to a QuickSight window / table-calc field (runningSum,
# percentOfTotal, rank, difference, ...) is neutralized to Null in the master (it can't
# be a live Sigma formula). Surfacing those as columns in a chart/table renders BLANK
# columns that look broken. We DROP such measures from the workbook ELEMENT (they stay
# in the data model's master with their original expr in the description, so the intent
# is preserved and re-authorable) and record a per-visual warning.
def window_meas?(role, calc)
  return false unless role && role[0] == :meas
  name = role[1]
  calc.key?(name) && qs_window_func?(calc[name])
end

# ---- C-gap: QuickSight CONTROLS -> Sigma list controls ----------------------
# QuickSight interactivity lives at the SHEET level as FilterControls + ParameterControls
# (NOT inside a visual). Until now this builder emitted ZERO control elements — every QS
# dashboard migrated as a static workbook (filters inlined as constants / element-level).
# We now reconstruct them as real Sigma `kind:control` list controls so the dropdowns
# populate and drive the page (the silently-dropped class the control-scope gate exists
# to kill). Shape mirrors the live-verified qlik-to-sigma builder:
#   { kind:"control", controlId, name, controlType:"list", mode:"include",
#     selectionMode:"multiple", values:[],
#     source:{ kind:"source", source:{kind:"table", elementId:"master"}, columnId },
#     filters:[{ source:{kind:"table", elementId:"master"}, columnId }] }
# The double-nested `source` is what POPULATES the dropdown's value list from the master
# column; `filters` is what makes the control DRIVE the master (and so, via source-closure,
# every chart that sources the master). Date-typed columns become date-range controls
# (a list control on a datetime target is silently stripped by the spec API).
#
# QS -> Sigma mapping:
#   * FilterControls (Dropdown/List/...) -> resolve SourceFilterId through FilterGroups to
#     the filtered Column.ColumnName, target the master column for that name.
#   * ParameterControls (Dropdown/List/...) bound to a Column-typed parameter -> same.
#     A ParameterControl bound to a WHAT-IF numeric parameter (no column) has no list-
#     control equivalent (it feeds a calc-field constant) -> recorded UNBOUND/manual, not
#     emitted (the value is already inlined by PARAM_DEFAULTS).
QS_CONTROL_WRAPS = %w[Dropdown List Slider TextField TextArea DateTimePicker RelativeDateTime].freeze

# Every FilterId -> filtered raw ColumnName, indexed across the analysis FilterGroups.
QS_FILTER_COL = {}
QS_FILTER_DS = {}   # FilterId -> the analysis' DataSetIdentifier of the filtered column
(defn['FilterGroups'] || []).each do |fg|
  (fg['Filters'] || []).each do |flt|
    body = flt.is_a?(Hash) ? flt.values.first : nil
    next unless body.is_a?(Hash)
    fid = body['FilterId']
    col = body.dig('Column', 'ColumnName') || body.dig('ColumnName')
    QS_FILTER_COL[fid] = col if fid && col
    QS_FILTER_DS[fid] = body.dig('Column', 'DataSetIdentifier') if fid && col
  end
end

# DataSetIdentifier (the name used inside the analysis) -> DataSetId of the discovered dataset.
QS_DATASET_ID = {}
(defn['DataSetIdentifierDeclarations'] || []).each do |d|
  QS_DATASET_ID[d['Identifier']] = d['DataSetArn'].to_s.split('dataset/').last if d['Identifier']
end

# Sigma value type of a control's target column, and where it came from. Authority order:
#   1. the DATA MODEL's own column type (dm-readback columnTypes, from /columns) — the master
#      column the control binds is the data-model column, and the spec API strips a `list`
#      control on a datetime one;
#   2. the dataset OutputColumns type (--discover-dir);
#   3. nothing -> the caller falls back to the name heuristic and WARNS.
# Calc fields have no stored type anywhere -> [nil, nil].
def qs_control_column_type(raw, ds_ident, master_cols, calc)
  return [nil, nil] if calc.key?(raw)
  el = MASTER_ELEMENTS[master_cols]
  rs = RESOLVERS[master_cols]
  if el && rs
    label, status = rs.resolve(raw, prefer: disp(raw))
    label = disp(raw) if status == :unverified
    t = label && DmColumnIndex.type_of(el, label)
    return [t, :data_model] if t
  end
  ds_id = QS_DATASET_ID[ds_ident]
  t = ds_id && (DATASET_COL_TYPES[ds_id] || {})[raw]
  unless t
    all = DATASET_COL_TYPES.values.map { |h| h[raw] }.compact.uniq
    t = all.first if all.size == 1
  end
  return [nil, nil] unless t
  [t == 'DATETIME' ? 'datetime' : t.downcase, :dataset]
end

# RCA #1 / bead 3goo.1 — PER-VISUAL FilterGroups. A QS FilterGroup whose
# ScopeConfiguration scopes it to specific VisualIds (SheetVisualScopingConfigurations
# with Scope==SELECTED_VISUALS) is an ELEMENT-LEVEL filter on exactly those visuals.
# Dropping these silently produced 5 identical KPIs on the customer dashboard — each was
# DISTINCT_COUNT(TASK_ID) distinguished ONLY by a TASK_STATUS CategoryFilter. We index
# VisualId -> [{col, values, mode}] and apply them as Sigma element `filters[]` so each
# element sees the same rows QuickSight scoped it to.
#
# SCOPE OF WHAT IS MIGRATED: a group becomes element filters only when it holds exactly ONE
# static CategoryFilter on selected visuals. QuickSight ORs the filters inside one group
# (https://docs.aws.amazon.com/quicksight/latest/user/add-a-compound-filter.html) while
# Sigma's element filters AND-compose and cannot OR across columns, so a multi-filter group
# cannot be expressed. Every OTHER enabled group - 2+ filters, parameter-bounded or static
# range/relative/top-bottom filters, a sheet-wide static category filter - is reported as a
# FilterGroupNotMigrated manual item (scope, conditions, parameters + defaults) instead of
# vanishing, and the parameter controls feeding it are marked manual too. A group whose
# single filter is driven by a FilterControl is covered by that control (build_qs_control).
VISUAL_FILTERS = Hash.new { |h, k| h[k] = [] }

# Every FilterControl's SourceFilterId (the filters a control already drives).
CONTROL_FILTER_IDS = Set.new
(defn['Sheets'] || []).each do |sh|
  (sh['FilterControls'] || []).each do |w|
    b = w.is_a?(Hash) ? w.values.first : nil
    CONTROL_FILTER_IDS << b['SourceFilterId'] if b.is_a?(Hash) && b['SourceFilterId']
  end
end
SHEET_NAMES = {}
SHEET_VISUALS = {}   # SheetId -> [VisualId]
VISUAL_TITLES = {}   # VisualId -> element name
# A visual with no title text is named after its SHEET (never its VisualId, which also became its
# Phase 6 check name); a repeat gets a numeric suffix so the name stays unique in the plan.
UNTITLED_SEEN = Hash.new(0)
(defn['Sheets'] || []).each_with_index do |sh, sheet_idx|
  SHEET_NAMES[sh['SheetId']] = sh['Name'] if sh['SheetId']
  (sh['Visuals'] || []).each do |v|
    vt, inner = v.first
    next unless inner.is_a?(Hash) && inner['VisualId']
    (SHEET_VISUALS[sh['SheetId']] ||= []) << inner['VisualId']
    t = qs_visual_title(inner, vt, nil)
    unless t
      base = sh['Name'].to_s.strip.empty? ? "Sheet #{sheet_idx + 1}" : sh['Name'].to_s.strip
      UNTITLED_SEEN[base] += 1
      t = UNTITLED_SEEN[base] == 1 ? base : "#{base} (#{UNTITLED_SEEN[base]})"
    end
    VISUAL_TITLES[inner['VisualId']] = t
  end
end
ALL_VISUAL_IDS = VISUAL_TITLES.keys.to_set

# The visuals a FilterGroup applies to: :all (AllSheets, ALL_VISUALS on every sheet, or no scope
# information) or a Set of VisualIds. A FilterControl only filters what ITS group is scoped to.
def qs_filter_scope_visuals(fg)
  sc = fg && fg['ScopeConfiguration']
  return :all unless sc.is_a?(Hash) && !sc.empty?
  return :all if sc.key?('AllSheets')
  set = Set.new
  Array(sc.dig('SelectedSheets', 'SheetVisualScopingConfigurations')).each do |c|
    if c['Scope'].to_s.upcase == 'SELECTED_VISUALS'
      set.merge(Array(c['VisualIds']))
    else
      set.merge(SHEET_VISUALS[c['SheetId']] || [])
    end
  end
  set.empty? || set.superset?(ALL_VISUAL_IDS) ? :all : set
end
FILTER_GROUP_OF = {}   # FilterId -> its (enabled) FilterGroup
# parameter -> calc fields that read it (${Name}); parameter -> NOT-migrated FilterGroups it feeds
PARAM_CALCS = {}
(defn['CalculatedFields'] || []).each do |c|
  c['Expression'].to_s.scan(/\$\{([^}]+)\}/).flatten.each { |n| (PARAM_CALCS[n.strip] ||= []) << c['Name'] }
end
PARAM_FILTER_GROUPS = {}

# Static category values of a CategoryFilter body -> [column, values, mode] or nil.
def qs_static_category(body)
  return nil unless body.is_a?(Hash)
  col = body.dig('Column', 'ColumnName')
  cfg = body['Configuration'] || {}
  inner = cfg['FilterListConfiguration'] || cfg['CustomFilterListConfiguration'] ||
          cfg['CustomFilterConfiguration'] || {}
  vals = inner['CategoryValues'] || (inner['CategoryValue'] ? [inner['CategoryValue']] : [])
  return nil if col.nil? || vals.empty?
  mop  = (inner['MatchOperator'] || 'CONTAINS').to_s.upcase
  [col, vals, mop.start_with?('DOES_NOT') ? 'exclude' : 'include']
end

# Parameters a filter body reads (RangeMinimumValue.Parameter, CustomFilterConfiguration.ParameterName, ...).
def qs_filter_params(o, out = [])
  if o.is_a?(Hash)
    o.each do |k, v|
      out << v if %w[Parameter ParameterName].include?(k) && v.is_a?(String)
      qs_filter_params(v, out)
    end
  elsif o.is_a?(Array)
    o.each { |v| qs_filter_params(v, out) }
  end
  out
end

# One-line human description of a filter's condition.
def qs_filter_condition(flt)
  type, body = flt.is_a?(Hash) ? flt.first : [nil, nil]
  return type.to_s unless body.is_a?(Hash)
  c = body.dig('Column', 'ColumnName') || '?'
  bound = lambda do |v|
    next 'unbounded' unless v.is_a?(Hash)
    next "${#{v['Parameter']}}" if v['Parameter']
    next v['StaticValue'].to_s unless v['StaticValue'].nil?
    next "rolling(#{v.dig('RollingDate', 'Expression')})" if v['RollingDate']
    v.to_s
  end
  case type
  when 'TimeRangeFilter', 'NumericRangeFilter'
    "#{type} #{c} between #{bound.call(body['RangeMinimumValue'])} and #{bound.call(body['RangeMaximumValue'])}"
  when 'CategoryFilter'
    cfg = body['Configuration'] || {}
    inner = cfg['FilterListConfiguration'] || cfg['CustomFilterListConfiguration'] || cfg['CustomFilterConfiguration'] || {}
    vals = inner['CategoryValues'] || (inner['CategoryValue'] ? [inner['CategoryValue']] : [])
    "CategoryFilter #{c} #{inner['MatchOperator'] || 'CONTAINS'} #{vals.inspect}#{inner['ParameterName'] ? " (parameter ${#{inner['ParameterName']}})" : ''}"
  else
    "#{type} #{c} #{JSON.generate(body.reject { |k, _| %w[FilterId Column].include?(k) })[0, 160]}"
  end
end

def qs_filter_scope_text(fg)
  sc = fg['ScopeConfiguration'] || {}
  return 'all sheets' if sc.key?('AllSheets')
  parts = Array(sc.dig('SelectedSheets', 'SheetVisualScopingConfigurations')).map do |s|
    sheet = SHEET_NAMES[s['SheetId']] || s['SheetId']
    if s['Scope'].to_s.upcase == 'SELECTED_VISUALS'
      "sheet '#{sheet}': visual(s) #{Array(s['VisualIds']).map { |v| "'#{VISUAL_TITLES[v] || v}'" }.join(', ')}"
    else
      "sheet '#{sheet}': all visuals"
    end
  end
  parts.empty? ? 'unscoped' : parts.join('; ')
end

(defn['FilterGroups'] || []).each do |fg|
  next unless (fg['Status'] || 'ENABLED').to_s.upcase == 'ENABLED'
  gid = fg['FilterGroupId'] || '(unnamed)'
  flts = Array(fg['Filters'])
  flts.each { |f| b = f.is_a?(Hash) ? f.values.first : nil; FILTER_GROUP_OF[b['FilterId']] = fg if b.is_a?(Hash) && b['FilterId'] }
  scopes = fg.dig('ScopeConfiguration', 'SelectedSheets', 'SheetVisualScopingConfigurations') || []
  vids = scopes.select { |sc| (sc['Scope'] || '').to_s.upcase == 'SELECTED_VISUALS' }
               .flat_map { |sc| sc['VisualIds'] || [] }.uniq
  reason = nil
  if flts.size > 1
    reason = "holds #{flts.size} filters. QuickSight combines the filters inside ONE group with OR, but Sigma element filters AND-compose and cannot OR across columns, " \
             'so applying them would change which rows show'
  elsif flts.size == 1
    type, body = flts.first.first
    fid = body.is_a?(Hash) ? body['FilterId'] : nil
    static = type == 'CategoryFilter' ? qs_static_category(body) : nil
    if fid && CONTROL_FILTER_IDS.include?(fid)
      nil # driven by a FilterControl: covered by that control
    elsif static && !vids.empty?
      col, vals, mode = static
      vids.each { |vid| VISUAL_FILTERS[vid] << { 'col' => col, 'values' => vals, 'mode' => mode } }
    elsif type == 'CategoryFilter' && static.nil? &&
          (((body['Configuration'] || {}).values.first || {})['SelectAllOptions'].to_s.upcase == 'FILTER_ALL_VALUES')
      nil # explicit "select all": a no-op
    elsif static
      reason = 'is a static category filter scoped to ALL visuals of the sheet(s) with no control; Sigma has no sheet-wide static filter this builder emits ' \
               '(it would have to be an element filter on every visual)'
    elsif type == 'CategoryFilter'
      reason = 'is a category filter with no values and no control'
    else
      reason = "is a #{type} (parameter-bounded, range, relative-date or top/bottom filter), which this builder does not express as a Sigma element filter"
    end
  end
  next unless reason
  params = flts.flat_map { |f| qs_filter_params(f) }.uniq
  params.each { |pn| (PARAM_FILTER_GROUPS[pn] ||= []) << gid }
  pdesc = params.map { |pn| "#{pn} (default #{PARAM_DEFAULTS.key?(pn) ? PARAM_DEFAULTS[pn].inspect : 'none'})" }
  manual_item!('FilterGroupNotMigrated', "FilterGroup #{gid}",
               "QuickSight FilterGroup '#{gid}' (scope: #{qs_filter_scope_text(fg)}) #{reason}. Conditions: #{flts.map { |f| qs_filter_condition(f) }.join(' OR ')}." \
               "#{pdesc.empty? ? '' : " Parameters: #{pdesc.join(', ')}."} It was NOT migrated - re-create it in Sigma by hand.")
end

# Attach a visual's scoped FilterGroups (above) to its built Sigma element as element
# `filters[]`. The filtered column must exist ON the element (filter columnId references
# an element column), so we add it via dim_col (reusing one if already present, e.g. a
# pivot already grouping by that column). Filters scope rows BEFORE aggregation — so a
# KPI's CountDistinct then equals QuickSight's filtered distinct count.
def apply_visual_filters(el, vid, calc, master_cols, dmel, m)
  return unless el
  flts = VISUAL_FILTERS[vid]
  return if flts.nil? || flts.empty?
  el['columns'] ||= []
  flts.each do |f|
    dc, did = dim_col([:dim, f['col'], nil], calc, master_cols, dmel, m)
    existing = el['columns'].find { |c| c['formula'] == dc['formula'] }
    if existing
      cid = existing['id']
    else
      el['columns'] << dc
      cid = did
    end
    (el['filters'] ||= []) << { 'id' => did('flt', el['id'], cid), 'columnId' => cid,
                                'kind' => 'list', 'mode' => f['mode'], 'values' => f['values'] }
  end
end

# ---- QuickSight "Small multiples" -> Sigma NATIVE element `trellis` ----------
# QuickSight's small-multiples facet is an EXPLICIT source property, carried two
# ways on a cartesian/circular visual:
#   * a `SmallMultiples` field well (a CategoricalDimensionField / DateDimensionField
#     with the small-multiples role) = the facet DIMENSION, and
#   * `ChartConfiguration.SmallMultiplesOptions` (MaxVisibleRows / MaxVisibleColumns)
#     = the panel-grid layout.
# We map that to Sigma's native `element.trellis` (rowsBy / columnsBy) via the shared,
# converter-agnostic emitter (shared/lib/trellis_emit.rb) — the same emitter the
# Tableau/Power BI/Qlik converters use. This SUPERSEDES any "trellis is Sigma UI-only"
# belief: the rowsBy/columnsBy form binds the facet FROM SPEC on the readback-safe
# kinds (docs/sigma-trellis-chart-support.md).
#
# DETECTION is gated on the `SmallMultiples` well — a visual with NO such well takes an
# early `return nil` and is built byte-identically to origin/main (no geometry
# inference). EMISSION emits ONE Sigma element (the base viz) with the facet added as a
# real column, then TrellisEmit.apply sets element['trellis']. The emitter is the single
# source of truth for the readback-safe kinds (bar/line/area/combo/scatter/donut) and
# the fallbacks on the rest — pie->donut (flipped in place), and kpi/pivot/table left
# flat (Sigma returns 200 then SILENTLY STRIPS the key on those). Every emitted trellis
# is recorded in $native_trellis_records -> the native-trellis-emitted.json round-trip
# sidecar, which verify-trellis-survived.rb re-checks against the readback spec.
def apply_small_multiples!(el, inner, wells, calc, mc, dmel, m, eid, title, warnings)
  return nil unless el
  facet = ((wells['SmallMultiples'] || wells['smallMultiples'] || []).map { |f| field_role(f) }.compact).first
  return nil unless facet # detection-gated: no small-multiples well -> byte-identical build

  kind = el['kind']
  # Gate to the kinds whose native `trellis` survives readback. On kpi/pivot/table Sigma
  # accepts the POST (200) then drops the key and renders flat — emitting it there would
  # be a silent lie, so leave those flat and record the documented fallback.
  unless TrellisEmit.trellises?(kind)
    fallback = case TrellisEmit.disposition(kind)
               when :needs_sibling_fanout then 'fan out to N per-member KPI tiles (no native KPI trellis)'
               when :needs_pivot_shelves  then "use the pivot's own rowsBy/columnsBy cross-tab shelves"
               else 'model the facet as an extra grouping/row dimension, or build small multiples post-publish'
               end
    STDERR.puts "  ! small-multiples facet '#{facet[1]}' on a #{kind} (#{title}): Sigma strips a #{kind} trellis on readback — facet left off"
    warnings << { 'visual' => title, 'type' => 'SmallMultiples',
                  'reason' => "QuickSight small-multiples facet '#{facet[1]}' on a #{kind} — Sigma has no native trellis for that kind (silently stripped on readback); facet left off. #{fallback}." }
    return nil
  end

  # Add the facet as a real column (reuse dim_col so a DATE facet is truncated like any
  # other date dim; master_ref lands the underlying column on the routed master). Stable
  # id (#{eid}-sm) so the round-trip sidecar can match it on readback.
  fcid = "#{eid}-sm"
  dc, _did = dim_col(facet, calc, mc, dmel, m)
  dc['id'] = fcid
  (el['columns'] ||= []) << dc

  orientation = sm_orientation((inner['ChartConfiguration'] || {})['SmallMultiplesOptions'])
  was_pie = (kind == 'pie-chart')
  result  = TrellisEmit.apply(el, facet_column_id: fcid, orientation: orientation)
  axis    = el['trellis'].keys.first

  # Round-trip guard record (Sigma silently strips an unsupported trellis; the
  # post-publish verifier re-reads the spec and asserts each of these survived).
  ($native_trellis_records ||= []) << {
    'element_id' => el['id'], 'kind' => el['kind'], 'name' => title,
    'axis' => axis, 'columnId' => fcid, 'visual_id' => inner['VisualId']
  }
  if was_pie
    warnings << { 'visual' => title, 'type' => 'SmallMultiples',
                  'reason' => "QuickSight small-multiples PIE -> Sigma DONUT + trellis.#{axis} (pie silently strips the trellis key on readback; donut supports it)" }
  end
  STDERR.puts "  + small-multiples '#{facet[1]}' -> ONE #{el['kind']} element with trellis.#{axis} on \"#{title}\" (facet column #{fcid})"
  result
end

# QuickSight SmallMultiplesOptions (MaxVisibleRows / MaxVisibleColumns) -> Sigma trellis
# orientation. A QuickSight small multiple is a SINGLE dimension tiled into a panel grid;
# MaxVisibleRows / MaxVisibleColumns cap how many panels are visible per axis before
# scrolling. Map that layout hint to the facet axis:
#   rows only -> :rows  (vertical small-multiples, rowsBy)
#   cols only -> :cols  (horizontal small-multiples, columnsBy)
#   both      -> :grid — but a SINGLE facet field can't fill a true 2-D Sigma grid (that
#                needs TWO distinct facet columns), so the shared emitter degrades :grid
#                to columnsBy, the tile grid QuickSight renders for one facet.
#   neither   -> :cols  (single-axis default; Sigma wraps into a tile grid)
def sm_orientation(sm_opts)
  o = sm_opts.is_a?(Hash) ? sm_opts : {}
  has_rows = !o['MaxVisibleRows'].nil? && o['MaxVisibleRows'].to_i.positive?
  has_cols = !o['MaxVisibleColumns'].nil? && o['MaxVisibleColumns'].to_i.positive?
  return :grid if has_rows && has_cols
  return :rows if has_rows

  :cols
end

# RCA #18 / bead 3goo.15: a QS sheet-level TextBox carries HTML in `Content`. Sigma text
# `body` is Markdown + light inline HTML. Strip QS markup to plain paragraphs (the
# explanatory annotations — x-axis/metric definitions — were silently dropped because the
# builder only walked `Visuals`, never `TextBoxes`).
def qs_textbox_to_markdown(html)
  s = html.to_s.dup
  s = s.gsub(%r{<br\s*/?>}i, "\n").gsub(%r{</p>}i, "\n\n").gsub(%r{</div>}i, "\n\n")
  s = s.gsub(/<[^>]+>/, '')
  { '&amp;' => '&', '&lt;' => '<', '&gt;' => '>', '&nbsp;' => ' ',
    '&#39;' => "'", '&quot;' => '"', " " => ' ' }.each { |k, v| s = s.gsub(k, v) }
  paras = s.split("\n").map(&:strip).reject(&:empty?)
  # QS wraps each styled run (e.g. a bold word) in its own block, so a single sentence
  # fragments into several "paragraphs" ("The x-axis represents the" / "starting date" /
  # "of the timeframe..."). Re-join a SHORT fragment that doesn't end a sentence into the
  # next paragraph, so captions read as prose instead of clipped stubs (RCA #18 polish).
  merged = []
  paras.each do |p|
    if !merged.empty? && merged.last.length < 40 && merged.last !~ /[.!?:]\s*$/
      merged[-1] = "#{merged.last} #{p}".strip
    else
      merged << p
    end
  end
  merged.join("\n\n").strip
end

# Column-typed parameter? (ParameterDeclaration whose default came from a column.) We map
# a ParameterControl to a column only when the analysis associates it with one; otherwise
# it's a what-if scalar (inlined as a constant) and gets no list control.
def qs_control_target_col(wrap, kind, filter_col_map)
  body = wrap[kind] || {}
  if (sfid = body['SourceFilterId'])
    return [filter_col_map[sfid], body, :filter]
  end
  # ParameterControl: a Dropdown/List bound to a column surfaces SelectableValues or a
  # LinkToDataSetColumn { Column: { ColumnName } }. A plain what-if param has neither.
  col = body.dig('SelectableValues', 'LinkToDataSetColumn', 'ColumnName') ||
        body.dig('CascadingControlConfiguration', 'SourceControls', 0, 'ColumnToMatch', 'ColumnName')
  [col, body, :parameter]
end

# Elements a control's filters can reach through the source closure (same list the control-scope
# contract uses for mustReach).
CTL_QUERYABLE = %w[table pivot-table bar-chart waterfall-chart line-chart pie-chart donut-chart
                   area-chart scatter-chart combo-chart kpi-chart region-map point-map].to_set
CONTROL_LAYOUT = {}        # pageId -> [{ id:, row:, col:, span: }] in control order (only when QuickSight gave a control grid)
CONTROL_SCOPE_INFO = {}    # controlId -> { el:, ctl_id:, scope:, raw_col:, sig:, group: } for the scope post-pass
QS_CONTROL_ELEMENT = {}    # QuickSight FilterControlId / ParameterControlId -> Sigma control element id

# Build ONE Sigma control element for a QS FilterControl/ParameterControl wrap, or nil.
# Pushes a control-scope CONTRACT row (scope/sourceName/status) or an `unbound` row so the
# signal is NEVER silently dropped. Dedupes by target column (the same column filtered by
# two controls is one Sigma control — controlIds are unique).
def build_qs_control(wrap, master_cols, calc, dmel, scope, unbound, seen_cols, warnings, masters = {})
  ctype, body = nil, nil
  raw_col = nil; src_kind = :filter
  QS_CONTROL_WRAPS.each do |k|
    next unless wrap[k].is_a?(Hash)
    raw_col, body, src_kind = qs_control_target_col(wrap, k, QS_FILTER_COL)
    ctype = k
    break
  end
  return nil unless body
  cid_src = body['FilterControlId'] || body['ParameterControlId'] || did('ctl', src_kind, raw_col)
  label = body.dig('Title') || body['Title'] || raw_col || cid_src
  sig = "#{src_kind} control #{cid_src.inspect}#{raw_col ? " on #{raw_col}" : ''}"
  if raw_col.nil? || raw_col.to_s.empty?
    # A parameter control with no dataset column. What it MEANS depends on what reads the
    # parameter: a FilterGroup that was not migrated, a calc field (default inlined), or nothing.
    pname = body['SourceParameterName']
    groups = (PARAM_FILTER_GROUPS[pname] || []).uniq
    calcs_using = (PARAM_CALCS[pname] || []).uniq
    pdesc = "parameter '#{pname}' (default #{PARAM_DEFAULTS.key?(pname) ? PARAM_DEFAULTS[pname].inspect : 'none'})"
    if pname && !groups.empty?
      why = "#{pdesc} bounds QuickSight FilterGroup(s) #{groups.map { |g| "'#{g}'" }.join(', ')} that were NOT migrated (see FilterGroupNotMigrated), " \
            'so this control has nothing to drive - re-create the filter and its control in Sigma by hand'
      warnings << { 'visual' => '(control)', 'type' => 'ParameterControl', 'reason' => "#{sig}: #{why}" }
      manual_item!('ParameterControl', sig, "#{sig}: #{why}")
      unbound << { 'sourceName' => sig, 'status' => 'manual', 'reason' => "feeds FilterGroup(s) #{groups.join(', ')} that were not migrated" }
    elsif !calcs_using.empty?
      warnings << { 'visual' => '(control)', 'type' => 'ParameterControl',
                    'reason' => "#{sig}: not bound to a dataset column (what-if scalar) - #{pdesc} is inlined as a constant in calc field(s) #{calcs_using.join(', ')}; add a Sigma what-if control by hand if interactivity is needed" }
      unbound << { 'sourceName' => sig, 'status' => 'manual',
                   'reason' => 'what-if scalar parameter control has no Sigma list-control equivalent (value inlined as a constant)' }
    else
      warnings << { 'visual' => '(control)', 'type' => 'ParameterControl',
                    'reason' => "#{sig}: not bound to a dataset column and #{pdesc} is not read by any calc field or migrated filter in this analysis - nothing to wire" }
      unbound << { 'sourceName' => sig, 'status' => 'manual',
                   'reason' => 'parameter control with no dataset column and no reader in the analysis (nothing to wire)' }
    end
    return nil
  end
  # The QuickSight scope this control inherits from its FilterGroup (:all or a Set of VisualIds).
  # Two controls on the same column are ONE Sigma control only when their scopes are the same.
  fid = src_kind == :filter ? body['SourceFilterId'] : nil
  qs_group = fid && FILTER_GROUP_OF[fid]
  qs_scope = qs_group ? qs_filter_scope_visuals(qs_group) : :all
  scope_tag = qs_scope == :all ? nil : Digest::SHA1.hexdigest(qs_scope.to_a.sort.join('|'))[0, 6]
  dedupe_key = [raw_col, scope_tag]
  if seen_cols.key?(dedupe_key)
    unbound << { 'sourceName' => sig, 'status' => 'duplicate',
                 'reason' => "same column and scope as control '#{seen_cols[dedupe_key]}' — one Sigma control already covers it" }
    return nil
  end
  # surface the target column on the master (master_ref adds it if absent) and target it.
  ref = master_ref(raw_col, calc, master_cols, dmel)
  col_id = ref['id']
  ctl_id = 'qs-' + raw_col.to_s.gsub(/[^A-Za-z0-9]/, '') + (scope_tag ? "-#{scope_tag}" : '') + '-filter'
  seen_cols[dedupe_key] = ctl_id
  el = { 'id' => did('ctlel', ctl_id), 'kind' => 'control', 'controlId' => ctl_id,
         'name' => label.to_s }
  # control kind: the bound column's TYPE decides (see qs_control_column_type) — a `list`
  # control on a datetime column is silently stripped by the spec API, and a date-range
  # control on a text column is no more valid. Only when NO type is known does the kind fall
  # back to the QuickSight control type (refs/catalogs/control.json: DateTimePicker /
  # RelativeDateTime -> date-range, everything else -> the documented `list` default) or
  # the date-NAME heuristic — and that guess is reported (ControlKind).
  ds_ident = src_kind == :filter ? QS_FILTER_DS[body['SourceFilterId']] : body.dig('SelectableValues', 'LinkToDataSetColumn', 'DataSetIdentifier')
  col_type, type_src = qs_control_column_type(raw_col, ds_ident, master_cols, calc)
  catalog_date = CTRL_CAT.target(ctype) == 'date-range'
  if col_type
    is_date = col_type == 'datetime'
    if catalog_date && !is_date
      warnings << { 'visual' => '(control)', 'type' => 'ControlKind',
                    'reason' => "#{sig}: QuickSight #{ctype} control is bound to a #{col_type} column '#{raw_col}' (#{type_src == :data_model ? 'data-model' : 'dataset'} type) - emitted as a list control, not a date-range" }
    end
  else
    name_date = raw_col.to_s =~ /(^|_)(date|dt|timestamp)(_|$)/i
    is_date = catalog_date || name_date ? true : false
    warnings << { 'visual' => '(control)', 'type' => 'ControlKind',
                  'reason' => "#{sig}: no data-model or dataset column type is available for '#{raw_col}', so the control kind (#{is_date ? 'date-range' : 'list'}) was chosen from the QuickSight control type / column NAME - verify it: a list control on a datetime column is stripped by the spec API" }
  end
  if is_date
    # date target: a `list` control on a datetime column is silently stripped by the
    # spec API, so a date-range control is the faithful shape (needs a flat `mode`).
    el.merge!('controlType' => 'date-range', 'mode' => 'between',
              'includeNulls' => 'when-no-value-is-selected',
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => col_id }])
  else
    el.merge!('controlType' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple',
              'values' => [],
              'source' => { 'kind' => 'source',
                            'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => col_id },
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => col_id }])
  end
  # Cross-master control fan-out (RCA #4 follow-up): a QS sheet control is GLOBAL, so it
  # must also drive any SECONDARY master that carries the same column — else charts on a
  # second dataset (e.g. the Weekly Tasks combo on the aggregation table) ignore the filter
  # and render all-data instead of the controlled slice. Append a filter target per
  # secondary master that has the column.
  wired = [{ 'elementId' => 'master', 'columnId' => col_id }]
  (masters || {}).each_value do |mm|
    next if mm[:sid] == 'master' || !master_covers?(mm, raw_col)
    scol = master_ref(raw_col, calc, mm[:cols], mm[:dmel])
    el['filters'] << { 'source' => { 'kind' => 'table', 'elementId' => mm[:sid] }, 'columnId' => scol['id'] }
    wired << { 'elementId' => mm[:sid], 'columnId' => scol['id'] }
  end
  scope << { 'controlId' => ctl_id, 'sourceName' => sig, 'status' => 'wired',
             'controlType' => el['controlType'], 'scope' => 'page', 'mustReach' => [],
             'wired' => wired }
  CONTROL_SCOPE_INFO[ctl_id] = { el: el, ctl_id: ctl_id, scope: qs_scope, raw_col: raw_col, sig: sig,
                                 group: qs_group && qs_group['FilterGroupId'] }
  QS_CONTROL_ELEMENT[cid_src] = el['id']
  el
end

# control-scope + signal accounting (filled in the sheet loop, written as control-scope.json)
control_scope = []      # CONTRACT rows for control_lint.rb gate (c)
control_unbound = []     # manual/duplicate/unbound signals (loud, never silent)
control_seen_cols = {}   # raw col -> ctl_id (dedupe; QS associative = global, like qlik)
n_control_signals = 0    # QS filter/parameter control objects encountered (sourceFilterSignals)
n_textboxes = 0          # QS sheet-level TextBoxes emitted as Sigma text elements (bead 3goo.15)

# MULTI-SHEET -> MULTI-PAGE (the big fidelity fix): every QuickSight SHEET becomes its
# own Sigma PAGE (page name = sheet name), each page holding only that sheet's visuals.
# Previously ALL sheets flattened onto a single "page-dash", so the layout step (which
# only read Sheets[0]) silently lost every visual on sheet 2..N. We now collect elements
# PER SHEET and record the sheet<->page<->visual mapping for the layout step.
sheet_pages = []   # [{ "pageId"=>, "name"=>, "sheetIndex"=>, "elements"=>[...] }]
vis_map = {}       # QS VisualId -> Sigma element id (globally unique within an analysis)
defn['Sheets'].each_with_index do |sh, sheet_idx|
  elements = []
  page_repeaters = []
  (sh['Visuals'] || []).each do |v|
    built = false      # an element was emitted for this visual
    reported = false   # a warning already says why it was skipped / approximated
    vtype, inner = v.first
    title = VISUAL_TITLES[inner['VisualId']] || qs_visual_title(inner, vtype)
    kind = KIND[vtype]
    is_fallback = false
    unless kind
      # D18: a QS type with no native Sigma kind. If it has a dim+measure fallback
      # mapping, DATA-MIGRATE it (build a Sigma table/bar from the underlying fields)
      # and still warn; otherwise it is a genuine drop (Insight/CustomContent/Plugin/
      # Empty/LayerMap) and we skip it.
      fk = QS_FALLBACK[vtype]
      reason = QS_UNSUPPORTED[vtype] || "unrecognized QuickSight visual type '#{vtype}'"
      build_warnings << { 'visual' => title, 'type' => vtype, 'reason' => reason }
      reported = fk.nil?
      unless fk
        # RCA #11: a simple single-computation Insight narrative -> Sigma text element.
        if vtype == 'InsightVisual' && (ibody = qs_insight_text.call(inner))
          tid = did('txt', inner['VisualId'])
          elements << { 'id' => tid, 'kind' => 'text', 'name' => 'Insight', 'body' => ibody }
          vis_map[inner['VisualId']] = tid
          built = true
          build_warnings.pop   # supersede the generic "dropped" warning we just queued
          build_warnings << { 'visual' => title, 'type' => vtype, 'reason' => 'migrated as a dynamic text element (single-computation narrative)' }
          STDERR.puts "  ~ InsightVisual (#{title}): migrated as dynamic text"
          next
        end
        STDERR.puts "  ! skipped #{vtype} (#{title}): #{reason}"
        next
      end
      kind = fk; is_fallback = true
      STDERR.puts "  ~ #{vtype} (#{title}): no native Sigma kind -> migrated as #{fk} (#{reason})"
    end
    eid = did('el', inner['VisualId'])
    # (visualToElement is filled only once an element exists - see `built` below)
    # PieChartVisual → pie-chart by default. Map to donut-chart ONLY when QuickSight
    # is rendering a REAL donut: DonutOptions.ArcOptions.ArcThickness is present AND
    # not 'WHOLE'. QuickSight's ArcThickness enum is WHOLE|SMALL|MEDIUM|LARGE — WHOLE
    # means a solid pie (no hole), SMALL/MEDIUM/LARGE are donuts. (The QS console also
    # emits a DonutOptions block for a plain pie, so presence of the key alone is not a
    # donut signal — orders-overview "Net Revenue by Region"=MEDIUM stays a donut;
    # D3 "Revenue Mix by Channel"=WHOLE becomes a pie.)
    if vtype == 'PieChartVisual'
      arc = inner.dig('ChartConfiguration', 'DonutOptions', 'ArcOptions', 'ArcThickness')
      kind = 'donut-chart' if arc && arc.to_s.upcase != 'WHOLE'
    end
    fw = (inner['ChartConfiguration'] || {})['FieldWells'] || {}
    w = fw.values.find { |x| x.is_a?(Hash) } || fw
    rol = ->(key) { (w[key] || []).map { |f| field_role(f) }.compact }
    # route this visual to the master whose DM element covers its columns (RCA #4)
    mr = route_master.call(inner)
    mc_ = mr[:cols]; dmel_ = mr[:dmel]; m_ = mr[:name]; mid_ = mr[:sid]
    base = { 'id' => eid, 'kind' => kind, 'name' => title, 'source' => { 'elementId' => mid_, 'kind' => 'table' } }
    # value labels on bar/pie/donut (Sigma defaults them OFF); lines stay clean
    base['dataLabel'] = { 'labels' => 'shown' } if %w[bar-chart pie-chart donut-chart].include?(kind)
    el = nil
    field_col_ids = nil   # FieldId -> column id (tables), for FieldId-based sorts

    case kind
    when 'progress'
      vals = rol.('Values')
      if vals.empty?
        build_warnings << { 'visual' => title, 'type' => 'GaugeProgress',
                            'reason' => 'QuickSight gauge has no Values field; native progress not emitted' }
        next
      end
      value_col, = meas_col(vals[0], calc, mc_, dmel_, m_)
      range = inner.dig('ChartConfiguration', 'GaugeChartOptions', 'ArcAxis', 'Range') || {}
      el = {
        'id' => eid, 'kind' => 'progress', 'name' => title,
        'mode' => 'value', 'shape' => 'ring',
        'value' => value_col['formula'],
        'min' => (range.key?('Min') ? range['Min'] : 0).to_s
      }
      if range.key?('Max')
        el['max'] = range['Max'].to_s
      else
        build_warnings << { 'visual' => title, 'type' => 'GaugeProgress',
                            'reason' => 'QuickSight GaugeChartOptions.ArcAxis.Range.Max is absent; native progress emitted without a guessed maximum — review the ring scale' }
      end
    when 'kpi-chart'
      # KPI + Gauge both surface a single value. STYLE for QuickSight fidelity: QS renders
      # KPIs as prominent big-number tiles, so give the value a larger font and center it
      # (Sigma's default is a small, top-anchored number). Card chrome comes from the
      # workbook-level themeOverrides.hasCards below (theme-aware light/dark), not per-element.
      vals = rol.('Values'); (next if vals.empty?)
      c, cid = meas_col(vals[0], calc, mc_, dmel_, m_)
      el = base.merge('columns' => [c.merge('name' => title).merge(kpi_number_format(c))],
                      'value' => { 'columnId' => cid, 'fontSize' => 24 },
                      'layout' => { 'anchor' => 'middle' })
    when 'bar-chart', 'line-chart', 'area-chart', 'waterfall-chart'
      # funnel/treemap land here too: their dim is in Category/Groups, measure in Values/Sizes
      if kind == 'waterfall-chart'
        dims = rol.('Categories')
        vals = rol.('Values')
      elsif is_fallback
        # D18 non-native fallbacks (for example histogram) use the generic
        # flattener for their non-standard wells. Waterfall is native above.
        fdims, fmeas = all_field_roles(w)
        dims = fdims; vals = fmeas
      else
        dims = rol.('Category'); dims = rol.('Groups') if dims.empty?
        vals = rol.('Values'); vals = rol.('Sizes') if vals.empty?
      end
      # Histogram fallback has only a numeric measure and NO category. Use that column
      # as the (un-aggregated) x dimension and Count the rows as y, so the per-value
      # distribution still migrates as bars.
      if is_fallback && dims.empty? && !vals.empty?
        dims = [[:dim, vals[0][1], nil]]
        vals = [[:meas, vals[0][1], 'COUNT']]
      end
      # D12: drop null window/table-calc measures (they render as blank series); keep them
      # in the DM master. If none survive, the chart has nothing to plot -> skip it.
      dropped_w = vals.select { |mv| window_meas?(mv, calc) }
      dropped_w.each { |mv| build_warnings << { 'visual' => title, 'type' => 'WindowCalcColumn', 'reason' => "measure '#{mv[1]}' is a QuickSight window/table-calc - dropped from the chart (kept in the data model); re-author in Sigma" } }
      vals -= dropped_w
      if vals.empty?
        STDERR.puts "  ! skipped #{kind} (#{title}): only measure(s) were QuickSight window/table-calc (null in Sigma)"
        next
      end
      (next if dims.empty? || vals.empty?)
      # D20: a date dimension carrying a QS DateGranularity (e.g. MONTH on a line chart)
      # is truncated to that grain so the x-axis aggregates by month/quarter/year instead
      # of plotting raw datetime (otherwise the line is spiky/per-row).
      dc, did = if dims[0][3]
                  date_dim_col(dims[0], calc, mc_, dmel_, m_)
                else
                  dim_col(dims[0], calc, mc_, dmel_, m_)
                end
      cols = [dc]; ycids = []
      vals.each { |mv| c, id = meas_col(mv, calc, mc_, dmel_, m_); cols << c; ycids << id }
      el = base.merge('columns' => cols, 'xAxis' => { 'columnId' => did }, 'yAxis' => { 'columnIds' => ycids })
      # D20: honor QuickSight BarChartVisual Orientation. HORIZONTAL -> Sigma
      # orientation:"horizontal"; VERTICAL (default) is expressed by OMITTING the field
      # (Sigma rejects orientation:"vertical"). Only meaningful for bar charts.
      if kind == 'bar-chart'
        qs_orient = (inner['ChartConfiguration'] || {})['Orientation']
        el['orientation'] = 'horizontal' if qs_orient.to_s.upcase == 'HORIZONTAL'
        el['stacking'] = qs_bars_stacking(inner)   # CLUSTERED -> unstacked (Sigma defaults to stacked)
      end
      if kind == 'waterfall-chart'
        breakdowns = rol.('Breakdowns')
        if breakdowns.any?
          split_col, split_id = dim_col(breakdowns[0], calc, mc_, dmel_, m_)
          el['columns'] << split_col
          el['splitBy'] = { 'columnId' => split_id }
        end
        el['waterfallShape'] = { 'calculation' => 'sum', 'connectorLine' => 'shown' }
        el['startPoint'] = {
          'value' => { 'type' => 'constant', 'value' => 0 },
          'visibility' => 'hidden'
        }
        el['grouping'] = 'stacked'
      end
      # B-gap COLOR: by-measure (ColorScale dup column) / by-dimension (Colors well).
      cclr = qs_color(inner, w, el, [did], ycids, calc, mc_, dmel_, m_)
      el['color'] = cclr if cclr
      # THEME single-hue: a single-measure chart with NO explicit QS color encoding is
      # painted by QuickSight in the theme's PRIMARY data color. Match it (Sigma otherwise
      # picks its own default hue). Multi-measure charts keep the categorical scheme.
      if !cclr && THEME_PRIMARY && ycids.size == 1
        el['color'] = { 'by' => 'single', 'value' => THEME_PRIMARY }
      end
      # A-gap REFERENCE LINES -> refMarks (wrapped value:{type:formula}).
      rms = qs_reference_lines(inner, calc, mc_, dmel_, m_, title, build_warnings)
      el['refMarks'] = rms unless rms.empty?
    when 'pie-chart', 'donut-chart'
      dims = rol.('Category'); vals = rol.('Values'); (next if dims.empty? || vals.empty?)
      dc, did = dim_col(dims[0], calc, mc_, dmel_, m_); mc2, mid = meas_col(vals[0], calc, mc_, dmel_, m_)
      el = base.merge('columns' => [dc, mc2], 'color' => { 'columnId' => did }, 'value' => { 'columnId' => mid })
    when 'combo-chart'
      dims = rol.('Category'); bars = rol.('BarValues'); lines = rol.('LineValues')
      [bars, lines].each do |arr|
        arr.select { |mv| window_meas?(mv, calc) }.each do |mv|
          build_warnings << { 'visual' => title, 'type' => 'WindowCalcColumn', 'reason' => "measure '#{mv[1]}' is a QuickSight window/table-calc - dropped from the combo chart (kept in the data model)" }
        end
      end
      bars  = bars.reject  { |mv| window_meas?(mv, calc) }
      lines = lines.reject { |mv| window_meas?(mv, calc) }
      if bars.empty? && lines.empty?
        STDERR.puts "  ! skipped combo-chart (#{title}): only measure(s) were QuickSight window/table-calc"
        next
      end
      (next if dims.empty? || (bars.empty? && lines.empty?))
      dc, did = dim_col(dims[0], calc, mc_, dmel_, m_); cols = [dc]; ycids = []
      bars.each  { |mv| c, id = meas_col(mv, calc, mc_, dmel_, m_); cols << c; ycids << id }
      lines.each { |mv| c, id = meas_col(mv, calc, mc_, dmel_, m_); cols << c; ycids << { 'columnId' => id, 'type' => 'line' } }
      el = base.merge('columns' => cols, 'xAxis' => { 'columnId' => did }, 'yAxis' => { 'columnIds' => ycids })
      # A QS ComboChartVisual with NO LineValues (all measures in BarValues) is a clustered
      # BAR chart, not a combo — Sigma renders a combo-chart's extra series as a line, so a
      # bars-only QS combo (e.g. a "Weekly Tasks" combo: Tasks Closed + Generated) would show a
      # spurious line. Emit bar-chart when there are no line series.
      el['kind'] = 'bar-chart' if lines.empty?
      el['stacking'] = qs_bars_stacking(inner)   # QS BarsArrangement: CLUSTERED -> unstacked
      cclr = qs_color(inner, w, el, [did], [], calc, mc_, dmel_, m_)  # combo: by-dimension only
      el['color'] = cclr if cclr && cclr['by'] == 'category'
      rms = qs_reference_lines(inner, calc, mc_, dmel_, m_, title, build_warnings)
      el['refMarks'] = rms unless rms.empty?
    when 'scatter-chart'
      xs = rol.('XAxis'); ys = rol.('YAxis'); cat = rol.('Category'); sz = rol.('Size')
      (next if xs.empty? || ys.empty?)
      xc, xid = meas_col(xs[0], calc, mc_, dmel_, m_); yc, yid = meas_col(ys[0], calc, mc_, dmel_, m_)
      if cat.any?
        # A QuickSight scatter is measure-vs-measure with the Category field as the POINT
        # identity. Sigma's scatter axis is a GROUPING axis: an aggregate (Sum(...)) over
        # the UNGROUPED master evaluates per-row and every point collapses to one x — the
        # spec POSTs but renders wrong (bead ry0n; ported from the live-verified
        # qlik-to-sigma builder, 2026-06-15). Correct shape: bind the scatter to a HIDDEN
        # GROUPED source table (one row per point dim) and reference its grouped columns
        # with raw refs; the dim stays on color:{by:category} so points don't merge.
        dc, did = dim_col(cat[0], calc, mc_, dmel_, m_)
        gcols = [dc, xc, yc]          # group dim + x + y (+ size); columns live on the source
        gcids = [xid, yid]            # aggregated calculations (size appended below)
        szc = nil
        if sz.any?
          szc, szid = meas_col(sz[0], calc, mc_, dmel_, m_)
          gcols << szc; gcids << szid
        end
        src_id = "#{eid}-src"; src_name = "Scatter Source #{eid[-6..-1]}"
        grp_id = "#{src_id}-g"
        scatter_sources << { 'id' => src_id, 'kind' => 'table', 'name' => src_name,
                             'visibleAsSource' => false,
                             'source' => { 'elementId' => mid_, 'kind' => 'table' },
                             'columns' => gcols,
                             'groupings' => [{ 'id' => grp_id, 'groupBy' => [did], 'calculations' => gcids }] }
        # RAW (non-aggregating) refs into the grouped source, one per channel.
        raw = lambda do |col|
          { 'id' => "#{eid}-#{col['id']}", 'formula' => "[#{src_name}/#{col['name']}]", 'name' => col['name'] }
        end
        s_dim = raw.(dc); s_x = raw.(xc); s_y = raw.(yc)
        scols = [s_dim, s_x, s_y]
        el = base.merge('source' => { 'elementId' => src_id, 'kind' => 'table', 'groupingId' => grp_id },
                        'xAxis' => { 'columnId' => s_x['id'] }, 'yAxis' => { 'columnIds' => [s_y['id']] },
                        'color' => { 'by' => 'category', 'column' => s_dim['id'] })
        # D8 (now a real channel): QuickSight scatter Size becomes a Sigma scatter
        # size:{columnId} channel over the grouped source's size aggregate.
        if szc
          s_sz = raw.(szc); scols << s_sz; el['size'] = { 'columnId' => s_sz['id'] }
        end
        el['columns'] = scols
      else
        # No point dimension: keep the prior measure-vs-measure-on-master behavior
        # (a single ungrouped scatter point is still the faithful migration here).
        el = base.merge('columns' => [xc, yc], 'xAxis' => { 'columnId' => xid }, 'yAxis' => { 'columnIds' => [yid] })
        # D8: QuickSight scatter Size (bubble radius) with no grouping. Sigma scatter has no
        # verified ungrouped size channel, so we PROJECT the size measure as a column (data
        # migrates) and record a warning that bubble-sizing renders uniform.
        if sz.any?
          szc, _szid = meas_col(sz[0], calc, mc_, dmel_, m_); el['columns'] << szc
          build_warnings << { 'visual' => title, 'type' => 'ScatterBubbleSize', 'reason' => "QuickSight scatter bubble-size ('#{sz[0][1]}') has no Sigma scatter size channel (no point dimension to group on); the measure is projected as a column but bubbles render uniform-size (Sigma limitation)" }
        end
      end
      # A-gap REFERENCE LINES on scatter (e.g. an x=Margin-Target line).
      rms = qs_reference_lines(inner, calc, mc_, dmel_, m_, title, build_warnings)
      el['refMarks'] = rms unless rms.empty?
    when 'table'
      cf_fieldmap = {}   # QS FieldId -> Sigma column id (for D19 conditional formatting + sorts + FieldOptions)
      if !is_fallback && fw.key?('TableUnaggregatedFieldWells')
        # UNAGGREGATED table = a DETAIL table: one passthrough column per field in well order,
        # NO groupings (a Sigma table with no groupings shows raw rows). The entries are bare
        # {FieldId, Column} hashes, so field_role (aggregated wrappers only) cannot read them.
        dcols = []
        Array(w['Values']).each do |f|
          raw = f.dig('Column', 'ColumnName')
          next unless raw
          if window_meas?([:meas, raw, nil], calc)
            build_warnings << { 'visual' => title, 'type' => 'WindowCalcColumn', 'reason' => "column '#{raw}' is a QuickSight window/table-calc - dropped from the table (kept in the data model); re-author in Sigma" }
            next
          end
          ref = master_ref(raw, calc, mc_, dmel_)
          cid = did('dt', eid, f['FieldId'] || raw)
          dcols << { 'id' => cid, 'formula' => "[#{m_}/#{ref['name']}]", 'name' => ref['name'] }
          cf_fieldmap[f['FieldId']] = cid if f['FieldId']
        end
        (next if dcols.empty?)
        el = base.merge('columns' => dcols)
      else
        if is_fallback
          # D18 sankey/box-plot/word-cloud/radar/heat-map -> table. Flatten every well
          # (Source/Destination/Weight, GroupBy/Size, Category/Color/Values, ...) into a
          # grouped table: all dims become group-bys, all measures become aggregates.
          dims, vals = all_field_roles(w)
          raw_dims = []; raw_vals = []  # fallback has no CF
        else
          dims = rol.('GroupBy'); vals = rol.('Values')
          raw_dims = (w['GroupBy'] || []); raw_vals = (w['Values'] || [])
        end
        # D12: drop null window/table-calc measures from the TABLE (blank columns look broken);
        # they remain in the DM master with their original expr in the description.
        unless is_fallback
          keep_idx = vals.each_index.reject { |i| window_meas?(vals[i], calc) }
          dropped_idx = vals.each_index.to_a - keep_idx
          dropped_idx.each { |i| build_warnings << { 'visual' => title, 'type' => 'WindowCalcColumn', 'reason' => "column '#{vals[i][1]}' is a QuickSight window/table-calc - dropped from the table (kept in the data model); re-author in Sigma" } }
          vals = keep_idx.map { |i| vals[i] }
          raw_vals = keep_idx.map { |i| raw_vals[i] }
        end
        cols = []; gids = []; cids = []
        dims.each_with_index { |d, i| c, id = dim_col(d, calc, mc_, dmel_, m_); cols << c; gids << id; (fi = field_id(raw_dims[i])) && (cf_fieldmap[fi] = id) }
        vals.each_with_index { |mv, i| c, id = meas_col(mv, calc, mc_, dmel_, m_); cols << c; cids << id; (fi = field_id(raw_vals[i])) && (cf_fieldmap[fi] = id) }
        (next if cols.empty?)
        el = base.merge('columns' => cols)
        el['groupings'] = [{ 'id' => did('g', el['id']), 'groupBy' => gids, 'calculations' => cids }] unless gids.empty?
      end
      field_col_ids = cf_fieldmap
      # D19: migrate QS TableVisual ConditionalFormatting (gradient cell color / data bars)
      # into Sigma `conditionalFormats` on the table element.
      if (cfb = inner['ConditionalFormatting'])
        cfmts = qs_conditional_formats(cfb, cf_fieldmap)
        unless cfmts.empty?
          el['conditionalFormats'] = cfmts
          STDERR.puts "  + #{cfmts.size} conditional format rule(s) migrated on table \"#{title}\""
        end
      end
      # TableFieldOptions: CustomLabel / hidden / order (+ report what has no Sigma mapping)
      apply_qs_table_field_options!(el, inner, cf_fieldmap, title, build_warnings) unless is_fallback
    when 'pivot-table'
      rows = rol.('Rows'); pcols = rol.('Columns'); vals = rol.('Values'); cols = []; rids = []; coids = []; vids = []
      rows.each  { |d| c, id = dim_col(d, calc, mc_, dmel_, m_); cols << c; rids << id }
      pcols.each { |d| c, id = dim_col(d, calc, mc_, dmel_, m_); cols << c; coids << id }
      vals.each  { |mv| c, id = meas_col(mv, calc, mc_, dmel_, m_); cols << c; vids << id }
      (next if rids.empty? || vids.empty?)
      el = base.merge('columns' => cols, 'rowsBy' => rids.map { |i| { 'columnId' => i } }, 'values' => vids)
      el['columnsBy'] = coids.map { |i| { 'columnId' => i } } unless coids.empty?
    when 'region-map', 'point-map'
      # QuickSight FilledMap/GeospatialMap: Geospatial holds the geo field(s),
      # Values holds the measure that fills/sizes the map. (Colors is optional and
      # rendered automatically by Sigma from the measure, so it is not a separate well.)
      geo  = rol.('Geospatial')
      vals = rol.('Values')
      (next if geo.empty?)
      pair = latlong_pair(geo)
      cols = []
      if pair
        # real lat/long -> point-map
        latc, latid = meas_col([:meas, pair[0][1], 'AVERAGE'], calc, mc_, dmel_, m_)
        lonc, lonid = meas_col([:meas, pair[1][1], 'AVERAGE'], calc, mc_, dmel_, m_)
        # carry lat/long as dimension-style refs (no aggregation) for the point geometry
        latc = { 'id' => latid, 'formula' => latc['formula'].sub(/^Avg\(/, '').sub(/\)$/, ''), 'name' => latc['name'] }
        lonc = { 'id' => lonid, 'formula' => lonc['formula'].sub(/^Avg\(/, '').sub(/\)$/, ''), 'name' => lonc['name'] }
        cols << latc << lonc
        vals.each { |mv| c, _ = meas_col(mv, calc, mc_, dmel_, m_); cols << c }
        el = base.merge('kind' => 'point-map', 'columns' => cols,
                        'latitude' => { 'columnId' => latid }, 'longitude' => { 'columnId' => lonid })
      else
        # geo NAME (state/city/country/zip) -> region-map
        dc, did = dim_col(geo[0], calc, mc_, dmel_, m_); cols << dc
        vals.each { |mv| c, _ = meas_col(mv, calc, mc_, dmel_, m_); cols << c }
        el = base.merge('kind' => 'region-map', 'columns' => cols,
                        'region' => { 'columnId' => did, 'regionType' => region_type_for(geo[0][1]) })
      end
    end
    # Released chart-local legend visibility/position, only when QuickSight
    # exported an explicit LegendOptions object.
    apply_qs_legend!(el, inner, title, build_warnings) if el
    # QuickSight "Small multiples" field well + SmallMultiplesOptions -> Sigma native
    # element trellis (detection-gated: no SmallMultiples well -> byte-identical build).
    # Runs after the case built el+columns and BEFORE sorts/filters, so the facet joins a
    # real columns[]; a no-op on any visual without a small-multiples facet.
    apply_small_multiples!(el, inner, w, calc, mc_, dmel_, m_, eid, title, build_warnings) if el
    # carry the visual's QS SortConfiguration (CategorySort/RowSort) when present
    apply_qs_sorts(el, inner, kind, title, build_warnings, field_col_ids) if el
    # RCA #1 / bead 3goo.1: apply this visual's scoped QS FilterGroups as element filters
    apply_visual_filters(el, inner['VisualId'], calc, mc_, dmel_, m_) if el
    if el
      elements << el
      vis_map[inner['VisualId']] = eid
      built = true
      drill = build_qs_drill_control(el, inner, calc, mc_, dmel_, m_, mr, build_warnings)
      elements << drill if drill
    end
  ensure
    # Every branch above can `next` (or fall through) with no element when its field wells are
    # empty or hold a field type the builder does not read. That used to vanish silently (and
    # leave a phantom visualToElement entry). `ensure` runs on `next` too, so ONE check covers
    # every branch: a visual with no element and no existing warning becomes a manual item.
    unless built || reported || inner.nil?
      seen_fields = []
      walk_fields = lambda do |o|
        if o.is_a?(Hash)
          o.each { |k, val| seen_fields << k if k.to_s =~ /Field\z/ && val.is_a?(Hash); walk_fields.call(val) }
        elsif o.is_a?(Array)
          o.each { |val| walk_fields.call(val) }
        end
      end
      walk_fields.call((inner['ChartConfiguration'] || {})['FieldWells'] || {})
      manual_item!('VisualNotBuilt', "#{title} (#{vtype}, #{inner['VisualId']})",
                   "QuickSight #{vtype} '#{title}' produced NO Sigma element: its field wells are empty or hold only field types the builder does not read " \
                   "(field types found: #{seen_fields.empty? ? 'none' : seen_fields.uniq.join(', ')}). Re-create it in Sigma by hand.")
    end
  end
  # C-gap: QuickSight sheet-level FilterControls + ParameterControls -> Sigma list
  # controls. QS selections are GLOBAL on the sheet (and FilterGroups can scope AllSheets),
  # so a control wired to the master propagates to every chart that sources it.
  page_controls = []
  ((sh['FilterControls'] || []) + (sh['ParameterControls'] || [])).each do |wrap|
    next unless wrap.is_a?(Hash)
    n_control_signals += 1
    ctl = build_qs_control(wrap, master_cols, calc, DMEL,
                           control_scope, control_unbound, control_seen_cols, build_warnings, MASTERS)
    if ctl
      page_controls << ctl
      vis_map[ctl['controlId']] = ctl['id']   # layout step can place it if QS gives coords
    end
  end
  # Control ORDER = QuickSight's own SheetControlLayouts grid (row, then column); controls it does
  # not list keep the FilterControls-then-ParameterControls order. (They used to be unshift-ed one
  # at a time and so ended up in REVERSE order.) The grid cells ride along in the map so the
  # layout step can wrap rows by ColumnSpan.
  ctl_pos = {}
  (sh['SheetControlLayouts'] || []).each do |lay|
    Array(lay.dig('Configuration', 'GridLayout', 'Elements')).each do |e|
      eid_ = QS_CONTROL_ELEMENT[e['ElementId']]
      ctl_pos[eid_] = [e['RowIndex'].to_i, e['ColumnIndex'].to_i, e['ColumnSpan']] if eid_
    end
  end
  ordered_controls = page_controls.each_with_index.sort_by do |c, i|
    pos = ctl_pos[c['id']]
    pos ? [0, pos[0], pos[1], i] : [1, 0, 0, i]
  end.map(&:first)
  elements.unshift(*ordered_controls)   # controls render at the top of the page band
  unless ctl_pos.empty?
    CONTROL_LAYOUT[sheet_idx.zero? ? 'page-dash' : "page-sheet-#{sheet_idx}"] = ordered_controls.map do |c|
      pos = ctl_pos[c['id']]
      { 'id' => c['id'], 'row' => pos && pos[0], 'col' => pos && pos[1], 'span' => pos && pos[2] }
    end
  end
  # RCA #18 / bead 3goo.15: QS sheet-level TextBoxes -> Sigma text elements. Skip the one
  # whose text is just the sheet title (the layout header band already renders it).
  (sh['TextBoxes'] || []).each do |tb|
    body = qs_textbox_to_markdown(tb['Content'])
    next if body.empty?
    next if body.casecmp?(sh['Name'].to_s)   # title duplicate -> header band already has it
    tid = did('txt', 'textbox', tb['TextBoxId'] || body)
    elements << { 'id' => tid, 'kind' => 'text', 'name' => 'Text', 'body' => body }
    vis_map[tb['TextBoxId']] = tid if tb['TextBoxId']
    n_textboxes += 1
  end
  if defn['Sheets'].length > 1
    page_labels = defn['Sheets'].each_with_index.map do |source_sheet, index|
      target_page = index.zero? ? 'page-dash' : "page-sheet-#{index}"
      { 'pageId' => target_page, 'label' => source_sheet['Name'] || "Sheet #{index + 1}" }
    end
    elements.unshift(
      'id' => did('nav', sh['SheetId'] || sheet_idx),
      'kind' => 'navigation',
      'mode' => 'auto',
      'pageLabels' => page_labels
    )
  end

  section_layout = (sh['Layouts'] || []).map { |layout| layout.dig('Configuration', 'SectionBasedLayout') }.compact.first
  if section_layout
    Array(section_layout['BodySections']).each do |section|
      section_id = section['SectionId'] || did('section', sheet_idx, page_repeaters.length)
      section_element_ids = Array(section.dig('Content', 'Layout', 'FreeFormLayout', 'Elements'))
                            .map { |layout_element| vis_map[layout_element['ElementId']] }.compact
      repeat_cfg = section['RepeatConfiguration']
      if repeat_cfg.is_a?(Hash)
        dimensions = Array(repeat_cfg['DimensionConfigurations']).filter_map do |dimension|
          cfg = dimension['DynamicCategoryDimensionConfiguration'] ||
                dimension['DynamicNumericDimensionConfiguration']
          cfg && cfg.dig('Column', 'ColumnName')
        end
        non_repeating = Array(repeat_cfg['NonRepeatingVisuals']).filter_map { |source_id| vis_map[source_id] }
        repeating_children = section_element_ids - non_repeating
        target_master = dimensions.length == 1 &&
                        MASTERS.values.find { |candidate| master_covers?(candidate, dimensions.first) }
        if target_master && repeating_children.any?
          raw_name = dimensions.first
          ref = master_ref(raw_name, calc, target_master[:cols], target_master[:dmel])
          source_id = did('repeat-src', sh['SheetId'], section_id)
          source_col_id = did('repeat-col', source_id, raw_name)
          grouping_id = did('repeat-group', source_id)
          repeat_sources << {
            'id' => source_id,
            'kind' => 'table',
            'name' => "#{sh['Name'] || 'Sheet'} #{raw_name} Repeat Source",
            'visibleAsSource' => false,
            'source' => { 'kind' => 'table', 'elementId' => target_master[:sid] },
            'columns' => [{
              'id' => source_col_id,
              'name' => ref['name'],
              'formula' => "[#{target_master[:name]}/#{ref['name']}]"
            }],
            'groupings' => [{
              'id' => grouping_id,
              'groupBy' => [source_col_id],
              'calculations' => []
            }]
          }
          repeater_id = did('repeat', sh['SheetId'], section_id)
          elements << {
            'id' => repeater_id,
            'kind' => 'repeated-container',
            'source' => {
              'kind' => 'table',
              'elementId' => source_id,
              'groupingId' => grouping_id
            },
            'arrangement' => 'list'
          }
          repeated_break = nil
          if repeat_cfg.dig('PageBreakConfiguration', 'After', 'Status').to_s.upcase == 'ENABLED'
            repeated_break = did('page-break-repeat', sh['SheetId'], section_id)
            elements << { 'id' => repeated_break, 'kind' => 'page-break' }
            repeating_children << repeated_break
          end
          page_repeaters << {
            'containerId' => repeater_id,
            'childIds' => repeating_children,
            'sourceColumn' => raw_name,
            'pageBreakId' => repeated_break
          }
        else
          build_warnings << {
            'visual' => sh['Name'] || "Sheet #{sheet_idx + 1}",
            'type' => 'RepeatedSection',
            'reason' => "QuickSight repeating section #{section_id.inspect} was not emitted: expected one resolvable repeat dimension and at least one repeating child (dimensions=#{dimensions.inspect}, children=#{repeating_children.size})"
          }
        end
      end
      if section.dig('PageBreakConfiguration', 'After', 'Status').to_s.upcase == 'ENABLED'
        elements << { 'id' => did('page-break', sh['SheetId'], section_id), 'kind' => 'page-break' }
      end
    end
  end
  # one Sigma page per QS sheet (skip a sheet that produced zero elements)
  pid = sheet_idx.zero? ? 'page-dash' : "page-sheet-#{sheet_idx}"
  sheet_pages << { 'pageId' => pid, 'name' => (sh['Name'] || "Sheet #{sheet_idx + 1}"),
                   'sheetIndex' => sheet_idx, 'elements' => elements,
                   'repeaters' => page_repeaters }
end

# Record a (c)-tail warning for any what-if PARAMETER inlined as a constant (the
# interactive control itself is a manual Sigma re-author; the default value is what
# the migrated workbook shows).
PARAM_DEFAULTS.each do |nm, dv|
  used = (defn['CalculatedFields'] || []).any? { |c| c['Expression'].to_s.include?("${#{nm}}") }
  next unless used
  build_warnings << { 'visual' => '(parameter)', 'type' => 'WhatIfParameter',
                      'reason' => "QuickSight what-if parameter '#{nm}' inlined as its default (#{dv}); add a Sigma control to make it interactive" }
end


# ---- control SCOPE post-pass --------------------------------------------------------------------
# A FilterControl only filters what its FilterGroup is scoped to. build_qs_control wired every
# control to the shared master (so it also filtered other pages); now, once every sheet is built
# and visualToElement is complete:
#   * every in-scope element is a TABLE that can carry the control's column -> re-wire the control
#     to exactly those tables (a hidden helper column is added where a table lacks the column; the
#     value list still comes from the master) and assert the QuickSight scope in control-scope.json;
#   * a chart/KPI/pivot/map (or a grouped table without the column) is in scope -> Sigma cannot
#     target those, so the master wiring stays and a ControlScope manual item says what the control
#     still reaches that QuickSight would not filter;
#   * scope = everything -> unchanged.
# NOTE: shared/scripts/enhance-apply.rb reads a control's column from filters.first; a re-wired
# control's first target is always a table that carries the column, so no change is needed there.
def qs_control_table_target(table, raw_col, calc)
  mm = MASTERS.values.find { |m| m[:sid] == table.dig('source', 'elementId') }
  return [nil, "'#{table['name']}' does not source a known master"] unless mm
  unless calc.key?(raw_col) || master_covers?(mm, raw_col)
    return [nil, "column '#{raw_col}' is not on the master of '#{table['name']}'"]
  end
  ref = master_ref(raw_col, calc, mm[:cols], mm[:dmel])
  formula = "[#{mm[:name]}/#{ref['name']}]"
  existing = (table['columns'] || []).find { |c| c['formula'] == formula }
  return [{ table: table, column_id: existing['id'], new_column: nil }, nil] if existing
  unless Array(table['groupings']).empty?
    return [nil, "'#{table['name']}' is a grouped table that does not carry column '#{raw_col}'"]
  end
  taken = (table['columns'] || []).map { |c| c['name'] }
  nm = taken.include?(ref['name']) ? "#{ref['name']} (filter)" : ref['name']
  cid = did('ctlcol', table['id'], raw_col)   # did() registers every id it returns - call it ONCE
  [{ table: table, column_id: cid, new_column: { 'id' => cid, 'name' => nm, 'formula' => formula, 'hidden' => true } }, nil]
end

page_els_by_id = sheet_pages.flat_map { |sp| sp['elements'] }.each_with_object({}) { |e, h| h[e['id']] = e if e['id'] }
SCOPED_CONTROL_IDS = Set.new
ctl_after = {}   # re-wired control element id -> target element ids (the control must follow them)
CONTROL_SCOPE_INFO.each_value do |info|
  next if info[:scope] == :all
  ctl = info[:el]
  row = control_scope.find { |r| r['controlId'] == info[:ctl_id] }
  in_scope = info[:scope].map { |vid| vis_map[vid] }.compact.uniq.map { |id| page_els_by_id[id] }.compact
  scope_titles = info[:scope].map { |vid| "'#{VISUAL_TITLES[vid] || vid}'" }
  if in_scope.empty?
    manual_item!('ControlScope', info[:sig],
                 "#{info[:sig]} is scoped by QuickSight FilterGroup '#{info[:group]}' to #{scope_titles.join(', ')}, but none of those visuals produced a Sigma element, " \
                 'so the control keeps its shared-master wiring (it filters every element sourcing the master) - re-scope it by hand.')
    next
  end
  ids = in_scope.map { |e| e['id'] }
  SCOPED_CONTROL_IDS << info[:ctl_id]
  plan = in_scope.map { |e| e['kind'] == 'table' ? qs_control_table_target(e, info[:raw_col], calc) : [nil, "#{e['kind']} '#{e['name']}' cannot be a control filter target"] }
  if plan.all? { |pl, _| pl }
    plan.each do |pl, _|
      next unless pl[:new_column]
      pl[:table]['columns'] << pl[:new_column]
      pl[:table]['order'] << pl[:new_column]['id'] if pl[:table]['order'].is_a?(Array)
    end
    ctl['filters'] = plan.map { |pl, _| { 'source' => { 'kind' => 'table', 'elementId' => pl[:table]['id'] }, 'columnId' => pl[:column_id] } }
    if row
      row['wired'] = ctl['filters'].map { |f| { 'elementId' => f['source']['elementId'], 'columnId' => f['columnId'] } }
      row['scope'] = ids
      row['mustReach'] = ids
    end
    ctl_after[ctl['id']] = ids
  else
    why = plan.map { |pl, reason| reason unless pl }.compact.uniq
    outside = page_els_by_id.values.select { |e| CTL_QUERYABLE.include?(e['kind']) && !ids.include?(e['id']) }
    manual_item!('ControlScope', info[:sig],
                 "QuickSight scopes #{info[:sig]} (FilterGroup '#{info[:group]}') to #{scope_titles.join(', ')}. Sigma cannot narrow it: #{why.join('; ')}. " \
                 "The control stays wired to the shared master and ALSO filters #{outside.size} element(s) QuickSight would not: " \
                 "#{outside.first(8).map { |e| "'#{e['name']}'" }.join(', ')}#{outside.size > 8 ? ', ...' : ''}. Re-scope it by hand " \
                 '(e.g. source the in-scope charts from their own hidden table).')
    if row
      row['mustReach'] = ids
      row['qsScope'] = ids
    end
  end
end

# strip the private _window marker before emit

master_cols.each_value { |c| c.delete('_window'); c.delete('description') if c['formula'] != 'Null' }

master = { 'id' => 'master', 'name' => M, 'kind' => 'table', 'visibleAsSource' => false,
           'source' => { 'dataModelId' => dm_id, 'elementId' => dm_el, 'kind' => 'data-model' },
           'columns' => master_cols.values }

# ---- apply surfaced dataset filter(s) ([bead] FilterOperation) ----
# convert-model writes the QS predicate(s) to dm-filters.json. We translate a simple
# {COL}='VALUE' equality predicate into a Sigma element-level list filter on the
# master, so every downstream aggregate honors it. The filtered column is added to
# the master if it isn't already projected.
filters_path = opts[:filters] || File.join(File.dirname(File.expand_path(opts[:an])), 'dm-filters.json')
applied_filters = []
if File.exist?(filters_path)
  fdata = JSON.parse(File.read(filters_path)) rescue {}
  (fdata['filters'] || []).each do |pred|
    m = pred.to_s.match(/\{([^}]+)\}\s*=\s*'([^']*)'/) || pred.to_s.match(/\{([^}]+)\}\s*=\s*"([^"]*)"/)
    next unless m
    raw_col = m[1].strip; val = m[2]
    ref = master_ref(raw_col, calc, master_cols, DMEL)
    # master_cols may have been re-read; ensure the col is on the master
    unless master.fetch('columns').any? { |c| c['id'] == ref['id'] }
      master['columns'] << master_cols[raw_col]
    end
    applied_filters << { 'id' => did('flt', 'master', ref['id'], val), 'kind' => 'list',
                         'columnId' => ref['id'], 'values' => [val] }
  end
  master['filters'] = applied_filters unless applied_filters.empty?
end
# refresh master columns (master_ref may have added the filter column)
master['columns'] = master_cols.values

# Build one Sigma page per QS sheet. A sheet that produced zero elements is still
# emitted (named after the sheet) so the page exists — but a single dash page is the
# common case. The shared Data page (master) is always page 0.
dash_pages = sheet_pages.map do |sp|
  { 'id' => sp['pageId'], 'name' => sp['name'], 'elements' => sp['elements'] }
end
# defensive: if an analysis somehow had no sheets, keep an empty dash page so the
# workbook is still valid.
if dash_pages.empty?
  dash_pages = [{ 'id' => 'page-dash', 'name' => (an['Name'] || 'Dashboard'), 'elements' => [] }]
  sheet_pages = [{ 'pageId' => 'page-dash', 'name' => (an['Name'] || 'Dashboard'), 'sheetIndex' => 0, 'elements' => [] }]
end

# Multi-master (RCA #4): any SECONDARY master that a visual routed to (non-empty cols)
# becomes its own hidden Data-page table sourcing its DM element. The primary `master`
# above carries the dm-filters; secondaries are plain passthrough masters.
secondary_masters = MASTERS.values.reject { |mm| mm[:sid] == 'master' || mm[:cols].empty? }.map do |mm|
  mm[:cols].each_value { |c| c.delete('_window'); c.delete('description') if c['formula'] != 'Null' }
  { 'id' => mm[:sid], 'name' => mm[:name], 'kind' => 'table', 'visibleAsSource' => false,
    'source' => { 'dataModelId' => dm_id, 'elementId' => mm[:dm_el_id], 'kind' => 'data-model' },
    'columns' => mm[:cols].values }
end
STDERR.puts "multi-master: routed visuals across #{1 + secondary_masters.size} master(s) (#{secondary_masters.map { |s| s['name'] }.join(', ')})" unless secondary_masters.empty?
# Page controls fan out to every master that SHARES the control's column (build_qs_control).
# A control whose column exists ONLY on the primary still won't constrain a secondary
# master (that dataset lacks the column) — surface it so the gap is understood, not silent.
unless secondary_masters.empty?
  build_warnings << { 'visual' => '(controls)', 'type' => 'MultiMasterControlScope',
                      'reason' => "page controls fan out to secondary master(s) (#{secondary_masters.map { |s| s['name'] }.join(', ')}) for SHARED columns; a control on a column that exists only on the primary does not constrain a secondary master that lacks it — verify cross-dataset filter coverage in Sigma" }
end

# Scatter charts emit a hidden GROUPED source table (one row per point dim). Park
# them on the Data page next to the master (visibleAsSource:false, so they need no
# layout slot) — they're sourced by the scatter element via {elementId, groupingId}.
data_elements = [master] + secondary_masters + scatter_sources + repeat_sources

# The released workbook code representation is not the data-model shape:
# workbook pages are metadata only, elements are document-global, and layout is
# the sole authority for page membership. Emit a complete deterministic layout
# on the initial create so a missing/failed later fidelity pass can never leave
# the workbook with invisible or ambiguously-owned elements.
row_span = lambda do |element|
  case element['kind']
  when 'page-break' then 1
  when 'control', 'text', 'navigation', 'progress' then 3
  when 'kpi-chart' then 6
  when 'table', 'pivot-table' then 12
  else 10
  end
end
layout_pages = []
layout_pages << SigmaLayout.page_xml(
  'page-data',
  data_elements.each_with_index.map { |element, i| SigmaLayout.le(element['id'], 1, 25, i * 12 + 1, i * 12 + 11) }.join("\n")
)
dash_pages.each do |page|
  row = 1
  repeaters = (sheet_pages.find { |record| record['pageId'] == page['id'] } || {})['repeaters'] || []
  repeated_child_ids = repeaters.flat_map { |record| record['childIds'] }.to_set
  repeaters_by_id = repeaters.each_with_object({}) { |record, index| index[record['containerId']] = record }
  children = (page['elements'] || []).filter_map do |element|
    next if repeated_child_ids.include?(element['id'])
    if (repeater = repeaters_by_id[element['id']])
      inner_row = 1
      inner = repeater['childIds'].filter_map do |child_id|
        child = (page['elements'] || []).find { |candidate| candidate['id'] == child_id }
        next unless child
        height = row_span.call(child)
        xml = SigmaLayout.le(child_id, 1, 13, inner_row, inner_row + height)
        inner_row += height
        xml
      end
      height = [inner_row, 4].max
      xml = SigmaLayout.gc(element['id'], 1, 25, row, row + height, inner.join("\n"))
      row += height
      next xml
    end
    height = row_span.call(element)
    xml = SigmaLayout.le(element['id'], 1, 25, row, row + height)
    row += height
    xml
  end
  layout_pages << SigmaLayout.page_xml(page['id'], children.join("\n"))
end

document = {
  'schemaVersion' => 1,
  'kind' => 'workbook',
  'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'visibility' => 'hidden' }] +
             dash_pages.map { |page| page.reject { |key, _| key == 'elements' } },
  'elements' => data_elements + dash_pages.flat_map { |page| page['elements'] || [] },
  'layout' => SigmaLayout.assemble(*layout_pages),
  'panels' => [],
  'overlays' => []
}
# A control re-wired to table targets must come AFTER them in document element order (Sigma
# resolves filter targets in array order); layout, not array order, owns placement.
ctl_after.each do |cid, tids|
  els = document['elements']
  idx = els.index { |e| e['id'] == cid }
  next unless idx
  ctl_el = els.delete_at(idx)
  last = tids.map { |t| els.index { |e| e['id'] == t } }.compact.max
  els.insert(last ? last + 1 : idx, ctl_el)
end
if defn['Sheets'].length > 1
  document['settings'] = {
    'navigation' => { 'pageTabsInViewMode' => 'shown' }
  }
end

spec = {
  'name' => (an['Name'] || 'QuickSight Migration') + ' (from QuickSight)',
  'document' => document
}
spec['folderId'] = opts[:folder] if opts[:folder]
# THEME -> workbook themeOverrides. Two fidelity moves:
#  (1) categoricalScheme: the ONLY spec path to pie/donut slice colors (per-element
#      color.scheme is silently dropped there) + the palette for every categorical chart.
#  (2) card chrome: QuickSight renders every tile as a bordered card, so hasCards + a
#      subtle elementBorder + rounded corners mirror that look (theme-aware: the light
#      border is skipped on a dark QS theme, which also flips the base to Sigma "Dark").
unless THEME_COLORS.empty?
  ov = { 'categoricalScheme' => THEME_COLORS, 'hasCards' => 'shown', 'borderRadius' => 'round' }
  dark = THEME && THEME['isDark']
  if dark
    theme_name = 'Dark'
  else
    ov['elementBorder'] = { 'color' => '#E2E8F0', 'width' => 1 }
  end
  # Live since 2026-08: themeName/themeOverrides moved to
  # document.settings.theme.{name,overrides} (shared/lib/code_rep.rb
  # DOC_KEYS) — a flat top-level themeName/themeOverrides is invalid on
  # write and gets silently dropped by the code-rep wrapper.
  theme = { 'overrides' => ov }
  theme['name'] = theme_name if theme_name
  document['settings'] = (document['settings'] || {}).merge('theme' => theme)
  STDERR.puts "  theme: applied QuickSight palette (#{THEME_COLORS.size} colors) + card chrome via settings.theme.overrides#{dark ? ' + settings.theme.name:Dark' : ''}"
end

placed_ids = document['layout'].scan(/\belementId="([^"]+)"/).flatten
element_ids = document['elements'].map { |element| element['id'] }
duplicate_placements = placed_ids.tally.select { |_id, count| count > 1 }.keys
duplicate_elements = element_ids.tally.select { |_id, count| count > 1 }.keys
missing = element_ids - placed_ids
unknown = placed_ids - element_ids
unless duplicate_placements.empty? && duplicate_elements.empty? && missing.empty? && unknown.empty?
  abort "FATAL invalid authoritative workbook layout: duplicate placements=#{duplicate_placements.inspect}; " \
        "duplicate element ids=#{duplicate_elements.inspect}; unplaced=#{missing.inspect}; unknown=#{unknown.inspect}"
end

File.write(opts[:out], JSON.pretty_generate(spec))

# Native-trellis round-trip guard sidecar — written ONLY when a small-multiples visual
# actually emitted a native trellis (a workbook with none stays byte-identical: no
# sidecar). verify-trellis-survived.rb re-reads the readback spec and asserts each element
# still carries its `trellis` key (Sigma silently strips unsupported ones). Converter-
# neutral shape, shared with the Tableau/Power BI/Qlik paths.
if ($native_trellis_records ||= []).any?
  begin
    nt_path = File.join(File.dirname(File.expand_path(opts[:out])), 'native-trellis-emitted.json')
    File.write(nt_path, JSON.pretty_generate('version' => 1, 'elements' => $native_trellis_records))
    STDERR.puts "native-trellis: wrote #{nt_path} (#{$native_trellis_records.size} native trellis element(s) — verify survives readback with verify-trellis-survived.rb)"
  rescue StandardError => e
    STDERR.puts "WARN native-trellis sidecar not written (round-trip coverage unrecorded): #{e.message}"
  end
end

map_out = opts[:out].sub(/\.json$/, '') + '.map.json'
# Map carries: the legacy single dashPageId (= first sheet's page, for back-compat),
# the per-sheet page list (sheetIndex -> pageId/name) so the layout step lays out EACH
# page from its OWN sheet's QS layout, and the global visual->element map.
# controlElementIds: the Sigma element ids of the kind:control elements (per page).
# QS controls live in SheetControlLayouts, not the visual GridLayout, so the layout step
# can't place them by QS coords — it LIFTS them into a clean full-width top band instead
# (Sigma's grid has no z-order; floating a control over a chart renders stacked).
control_eids_by_page = {}
dash_pages.each do |pg|
  ids = (pg['elements'] || []).select { |e| e['kind'] == 'control' }.map { |e| e['id'] }
  control_eids_by_page[pg['id']] = ids unless ids.empty?
end
File.write(map_out, JSON.pretty_generate(
  'dashPageId' => (sheet_pages.first && sheet_pages.first['pageId']) || 'page-dash',
  'masterElementId' => 'master',
  'dataElementIds' => data_elements.map { |element| element['id'] },
  'sheetPages' => sheet_pages.map { |sp| { 'pageId' => sp['pageId'], 'name' => sp['name'], 'sheetIndex' => sp['sheetIndex'] } },
  'pageElementIds' => dash_pages.each_with_object({}) do |page, out|
    out[page['id']] = (page['elements'] || []).map { |element| element['id'] }
  end,
  'pageBreakElementIds' => dash_pages.flat_map { |page| page['elements'] || [] }
                                     .select { |element| element['kind'] == 'page-break' }
                                     .map { |element| element['id'] },
  'repeatedContainers' => sheet_pages.each_with_object({}) do |sheet_page, out|
    out[sheet_page['pageId']] = sheet_page['repeaters'] unless Array(sheet_page['repeaters']).empty?
  end,
  'controlElementIds' => control_eids_by_page,
  # QuickSight's control grid (row/col/ColumnSpan) per page, in control order — only when the
  # analysis has SheetControlLayouts; the layout step wraps rows by span.
  'controlLayout' => CONTROL_LAYOUT,
  # navigation elements go in the FIRST band of their page
  'navigationElementIds' => dash_pages.each_with_object({}) do |pg, out|
    ids = (pg['elements'] || []).select { |e| e['kind'] == 'navigation' }.map { |e| e['id'] }
    out[pg['id']] = ids unless ids.empty?
  end,
  'visualToElement' => vis_map))

# Persist a machine-readable per-visual warning manifest for any QuickSight visual
# Sigma can't recreate (sankey/radar/box-plot/word-cloud/histogram/heat-map/
# layer-map/insight-ML/custom-content/plugin). This is the (c)-tail record — a clear
# "dropped, here's why" rather than a silent omission.
# Fold in the loud de-silencing notes raised by the top-level `def` classifiers
# (unmapped aggregation -> neutralized; measure shipped with no source number format).
# These live in a top-level array because `def`s can't see the build_warnings local.
build_warnings.concat(CLASSIFIER_WARNINGS)
warn_out = opts[:out].sub(/\.json$/, '') + '.warnings.json'
# `manual` = what the builder could not migrate/resolve and a human must finish (see
# manual_item!); `warnings` = what WAS built, with caveats.
File.write(warn_out, JSON.pretty_generate('warnings' => build_warnings, 'manual' => MANUAL_ITEMS))

# control-scope.json — the intended-scope contract sidecar (schema: the CONTRACT block
# in scripts/lib/control_lint.rb). QuickSight sheet/AllSheets filters are GLOBAL, so every
# wired control's mustReach = every queryable element on every CONTENT page (Qlik parity).
# post-and-readback.rb (--type workbook) and assert-phase6-ran.rb gate 7 pick it up from
# <workdir>/control-scope.json automatically; we write it next to the spec (= the workdir).
# sourceFilterSignals > 0 with zero spec controls FAILS gate 7 — the silently-dropped class
# this change exists to kill.
must_reach = dash_pages.flat_map { |pg| pg['elements'] }
                       .select { |e| CTL_QUERYABLE.include?(e['kind']) }
                       .map { |e| e['id'] }
control_scope.each { |sc| sc['mustReach'] = must_reach if sc['status'] == 'wired' && !SCOPED_CONTROL_IDS.include?(sc['controlId']) }
scope_out = File.join(File.dirname(File.expand_path(opts[:out])), 'control-scope.json')
File.write(scope_out, JSON.pretty_generate(
  'version' => 1, 'source' => 'quicksight', 'sourceFilterSignals' => n_control_signals,
  'controls' => control_scope, 'unbound' => control_unbound))
STDERR.puts "control-scope: #{n_control_signals} QS control signal(s) -> #{control_scope.size} wired Sigma control(s)" \
            "#{control_unbound.empty? ? '' : ", #{control_unbound.size} unbound/manual/duplicate"} → #{scope_out}"

all_elements = sheet_pages.flat_map { |sp| sp['elements'] }
STDERR.puts "workbook spec: master sources DM element \"#{DMEL}\" (#{dm_el}); #{sheet_pages.size} page(s)/#{all_elements.size} chart elements, #{master_cols.size} master cols#{applied_filters.empty? ? '' : "; #{applied_filters.size} filter(s) applied"} → #{opts[:out]} (+ #{map_out})"
sheet_pages.each do |sp|
  STDERR.puts "  page \"#{sp['name']}\" (#{sp['pageId']}): #{sp['elements'].size} element(s)"
  sp['elements'].each { |e| STDERR.puts "    - #{e['kind']}: #{e['name']}" }
end
unless MANUAL_ITEMS.empty?
  STDERR.puts "MANUAL ITEMS (#{MANUAL_ITEMS.size}) - not migrated automatically, finish these by hand (also in #{warn_out}):"
  MANUAL_ITEMS.each { |m| STDERR.puts "  ! [#{m['type']}] #{m['subject']}: #{m['reason']}" }
end
unless build_warnings.empty?
  # build_warnings holds more than unsupported visual types (control kinds, number formats,
  # table options, ...): count each class under its own name instead of calling every
  # entry a visual "genuinely dropped".
  visual_kind = build_warnings.select { |w| QS_UNSUPPORTED.key?(w['type']) }
  fb      = visual_kind.select { |w| QS_FALLBACK.key?(w['type']) }
  dropped = visual_kind - fb
  other   = build_warnings - visual_kind
  STDERR.puts "#{build_warnings.size} warning(s) → #{warn_out}: #{visual_kind.size} visual(s) with no native Sigma kind " \
              "(#{fb.size} data-migrated as table/bar fallback, #{dropped.size} dropped), #{other.size} other note(s)"
  fb.each      { |w| STDERR.puts "  ~ #{w['type']}: #{w['reason']}" }
  dropped.each { |w| STDERR.puts "  ! #{w['type']}: #{w['reason']}" }
  other.each   { |w| STDERR.puts "  - #{w['type']}: #{w['reason']}" }
end
