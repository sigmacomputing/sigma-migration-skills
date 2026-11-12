#!/usr/bin/env ruby
# frozen_string_literal: true
#
# fidelity-loop.rb — Phase 5g Render-Compare-Fix (RCF) loop MECHANICS.
#
# The exemplar hand migrations reached near-exact parity by iterating a
# render → compare → classify → fix loop that the one-shot builder never runs.
# This script is the mechanical spine of that loop; the JUDGMENT stays with the
# agent (it reads the render vs the source and decides what's wrong). Per pass:
#
#   RENDER   `fidelity-loop.rb render`   → export the live page to rcf-pass-N.png,
#            bump the pass counter, print the scored rubric (refs/fidelity-rubric.md)
#            + the source image path for the agent to compare against, enforce the
#            pass budget.
#   COMPARE  (agent) Reads rcf-pass-N.png against the source dashboard PNG, scores
#            each rubric dimension.
#   CLASSIFY (agent) `fidelity-loop.rb record` each delta as
#            spec-fixable | ui-only | sigma-capability | data.
#   FIX      `fidelity-loop.rb apply-patch` → a SINGLE layout-preserving PUT (GET
#            the full live spec, deep-merge the agent's patch, PUT the whole spec
#            back so the layout is never wiped — the PUT-wipes-layout trap), then
#            re-run the column-type guard + layout/control lint. Marks the resolved
#            deltas.
#   LOOP     until zero unresolved spec-fixable deltas remain, or max_passes.
#   EXIT     the ledger (fidelity-ledger.json) is the gate input: assert-phase6-ran.rb
#            --require-fidelity-ledger blocks GREEN while any spec-fixable delta is
#            unresolved and not named in --accept-residuals.
#
# DATA-CLASS deltas are special: `data` means the rendered VALUES diverge from
# the source — the numbers are wrong. Unresolved data-class entries block the
# gate whenever the ledger exists (no --require-fidelity-ledger needed), and
# --accept-residuals does NOT apply to them. Fix the spec/data and `resolve`
# the entry, or — only after PROVING the values match — re-record it under its
# true class with the evidence.
#
# Recipes for each delta→fix live in refs/fidelity-recipes.md. See SKILL.md Phase 5g.
#
# Subcommands
#   init        --workdir DIR --workbook-id ID [--page-id ID] [--source-image PNG]
#               [--max-passes N (default 5)]
#               --page-id omitted → auto-pick the page with the most VISIBLE
#               (non-hidden) elements from <workdir>/wb-ids.json + wb-spec.json
#               (#422: first-by-order picked a helper-table data page); ties
#               warn. An explicit --page-id also OVERRIDES the page on an
#               existing same-workbook ledger (entries preserved).
#   render      --workdir DIR [--width W --height H; default sized by lib/export_viewport.rb]   (needs a live workbook)
#               [--page-id ID] that page only | [--single-page] the ledger page only |
#               default on a multi-dashboard workbook (or --all-pages): every
#               dashboard page stacked into ONE composite rcf-pass-N.png (one pass)
#   record      --workdir DIR --dimension D --delta "..." --class C
#               [--fix "..."] [--resolved] [--catalog-id ID]
#               --class sigma-capability (and ui-only, which is stored as
#               sigma-capability) REQUIRES --catalog-id ID, an id in the SHIPPED
#               catalog refs/sigma-platform-differences.json (no override). A
#               missing/unknown id exits 6 listing the valid ids. An entry with
#               no valid catalog_id (e.g. a legacy ledger) counts as spec-fixable,
#               exactly as gate 8d treats it.
#   resolve     --workdir DIR (--entry N | --dimension D)    mark entry(ies) resolved
#   apply-patch --workdir DIR --patch patch.json             GET→merge→normalize→PUT→guard→lint
#               Patch document keys flat or as {"document":{...}}; non-document
#               keys are refused (exit 4), and every patched path must reach the
#               PUT body (exit 4) and the readback (exit 5, --resolves withheld).
#               Persists the complete live candidate into <workdir>/wb-spec.json
#               so stale local state cannot erase untouched elements on re-entry.
#               Dry runs only merge the local preview.
#               [--full-spec spec.json]  replace the whole spec instead of merging
#               [--skip-style-normalize REASON]  waive the v5.1 style contract (named)
#               [--resolves 0,2,3]       mark these ledger entries resolved on success
#               [--dry-run --live-spec f.json --out merged.json]  no network (tests)
#   status      --workdir DIR [--accept-residuals id,id]     print ledger + gate verdict
#               Prints `YELLOW-ready` and exits 0 when the fix budget is spent
#               (rcf-exhausted.json, pass >= max_passes, or elapsed >= max_seconds
#               - same logic as gate 8d) and only spec-fixable entries / visual
#               residuals remain (no unresolved data-class entry). Minor gaps on a
#               PASSING v2 grade are polish notes, not residuals: they never make
#               it YELLOW-ready (it prints "GREEN, optional polish: N notes").
#   green-offer --workdir DIR    print JSON {realistic, gaps[{id|tile, dimension,
#               description, route}], est_passes, why_not}: is a push to GREEN
#               realistic? Gaps = unresolved spec-fixable RCF entries (incl.
#               uncatalogued sigma-capability/ui-only) + visual-residuals.json
#               `residuals` and `fixable_major` — minus the minor gaps of a PASSING
#               v2 grade, which are polish notes (TJ 2026-11-09: "minor = notes";
#               when only those remain, why_not is "GREEN, optional polish: N notes"
#               and polish_notes lists them). Catalogued platform differences are
#               never offered. A gap routes to a refs/fidelity-recipes.md heading
#               (`recipe:<anchor>`) or `sdk` (top-level ledger "route": "sdk", PR #939); any unrouted gap,
#               or any unresolved data-class entry, makes it not realistic.
#               est_passes = ceil(gaps / 3). Exits 0 (2 on malformed residuals).
#
# HYBRID route (refs/phase-5g-sdk-hybrid.md) — the fix loop and later edits run
# through the Sigma MCP Code Mode SDK (build_workbook) instead of apply-patch;
# the gated code-rep build is untouched. Every SDK write is ledgered, and the
# session ends with an export-back + re-gate before --finalize:
#   sdk-begin   --workdir DIR --mcp-server NAME   version-bound checkpoint + repair-pending.json
#   sdk-write   --workdir DIR --program FILE --summary "..." [--status ok|failed]
#               [--result FILE] [--error "..."] [--claims e0,e2]
#               record ONE build_workbook call (program kept under sdk-writes/, sha-bound,
#               bound to the live document version); a failed write requires sdk-reread
#   sdk-reread  --workdir DIR --evidence FILE     page re-read after a failed write
#   sdk-export  --workdir DIR                     GET live spec → wb-spec.json, column guard,
#               layout/control lint, resolve claims, then phase-6 parity on the export
#   sdk-regate  --workdir DIR [--actuals FILE]    re-run only the parity step of the last export
#
# Exit codes: 0 ok; 2 usage; 3 pass budget exhausted; 4 apply/PUT failed;
#             5 post-fix guard/lint failed (sdk-export: guards failed or parity unverified);
#             6 status: unresolved spec-fixable remain / the SDK route blocks finalize /
#               record: sigma-capability without a valid --catalog-id;
#             7 sdk-export/sdk-regate: phase-6 parity diverged (data-class entry recorded).

require 'json'
require_relative 'lib/cli_encoding'
require_relative 'lib/code_rep'
require_relative 'lib/workbook_code'
require 'optparse'
require 'time'
require_relative 'lib/blind_grade'
require_relative 'lib/degradation_ledger' # green-offer: what else forfeits GREEN
require_relative 'lib/workdir_guard' # refuse a workdir inside the installed plugin

# ---------------------------------------------------------------------------
# Pure, IO-free core — unit-tested in test-fidelity-loop.rb.
# ---------------------------------------------------------------------------
module FidelityLoop
  CLASSES = %w[spec-fixable ui-only sigma-capability data].freeze
  # Keys tried, in order, to merge two arrays of Hashes element-by-element
  # rather than replacing the whole array. Covers Sigma spec shapes (pages have
  # `id`; elements `elementId`/`id`; controls `id`).
  MERGE_KEYS = %w[elementId id nodeId name].freeze
  # Classes that are platform differences ONLY when they cite a shipped catalog id.
  CATALOG_CLASSES = %w[sigma-capability ui-only].freeze
  CATALOG_PATH = File.expand_path('../refs/sigma-platform-differences.json', __dir__)
  RECIPES_PATH = File.expand_path('../refs/fidelity-recipes.md', __dir__)

  # RCF / rubric dimension key (downcased, `_` and spaces -> `-`) -> heading
  # prefix(es) in refs/fidelity-recipes.md, in preference order. Keys cover the
  # BlindGrade::DIMENSION_KEYS plus the free-form RCF vocabulary the loop uses.
  # A heading that no longer exists drops the route at runtime.
  RECIPE_HEADINGS = {
    'element-titles-hidden' => ['Text, chips & legends'],
    'palette-match'         => ['Canvas, theme & palette'],
    'composition-match'     => ['Containers, cards & bands', 'Layout composition'],
    'chart-shapes-match'    => ['Chart kind, marks & axes'],
    'labels-legible'        => ['Text, chips & legends'],
    'numbers-formatted'     => ['Number & date formats'],
    'palette'               => ['Canvas, theme & palette'],
    'theme'                 => ['Canvas, theme & palette'],
    'canvas'                => ['Canvas, theme & palette'],
    'background'            => ['Canvas, theme & palette'],
    'containers'            => ['Containers, cards & bands'],
    'cards'                 => ['Containers, cards & bands'],
    'layout'                => ['Layout composition', 'Containers, cards & bands'],
    'composition'           => ['Layout composition', 'Containers, cards & bands'],
    'typography'            => ['Text, chips & legends'],
    'text'                  => ['Text, chips & legends'],
    'font'                  => ['Text, chips & legends'],
    'legend'                => ['Text, chips & legends'],
    'labels'                => ['Text, chips & legends'],
    'chart-kind'            => ['Chart kind, marks & axes'],
    'chart-shapes'          => ['Chart kind, marks & axes'],
    'marks'                 => ['Chart kind, marks & axes'],
    'axes'                  => ['Chart kind, marks & axes'],
    'number-format'         => ['Number & date formats'],
    'number-formats'        => ['Number & date formats'],
    'formats'               => ['Number & date formats'],
    'kpi'                   => ['KPIs & hero numbers'],
    'kpis'                  => ['KPIs & hero numbers'],
    'kpi-spark'             => ['KPIs & hero numbers'],
    'status'                => ['Status, thresholds & tables'],
    'thresholds'            => ['Status, thresholds & tables'],
    'table'                 => ['Status, thresholds & tables'],
    'tables'                => ['Status, thresholds & tables'],
    'controls'              => ['Controls & parameters'],
    'parameters'            => ['Controls & parameters'],
    'filters'               => ['Controls & parameters']
  }.freeze
  # Free-form RCF dimension (normalized) -> BlindGrade rubric key, for the
  # `record --catalog-id` consistency check. Rubric keys map to themselves
  # (see rubric_dimension); anything not listed here is unmapped (accepted).
  FREE_FORM_RUBRIC = {
    'palette' => 'palette_match', 'theme' => 'palette_match', 'canvas' => 'palette_match',
    'background' => 'palette_match',
    'containers' => 'composition_match', 'cards' => 'composition_match',
    'layout' => 'composition_match', 'composition' => 'composition_match',
    'typography' => 'labels_legible', 'text' => 'labels_legible', 'font' => 'labels_legible',
    'legend' => 'labels_legible', 'labels' => 'labels_legible',
    'chart-kind' => 'chart_shapes_match', 'chart-shapes' => 'chart_shapes_match',
    'marks' => 'chart_shapes_match',
    'number-format' => 'numbers_formatted', 'number-formats' => 'numbers_formatted',
    'formats' => 'numbers_formatted'
  }.freeze
  # Dimensions whose gap means the VALUES are wrong: never a fix-loop route.
  DATA_DIMENSIONS = %w[data accuracy values parity numbers-wrong].freeze

  module_function

  def new_ledger(workbook_id:, page_id:, source_image: nil, max_passes: 5, max_seconds: 1800)
    {
      'workbook_id'  => workbook_id,
      'page_id'      => page_id,
      'source_image' => source_image,
      'max_passes'   => max_passes,
      'max_seconds'  => max_seconds,
      'started_at'   => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
      'pass'         => 0,
      'renders'      => [],
      'entries'      => []
    }
  end

  # Deep-merge `patch` INTO `base`, returning a new object. Hashes merge
  # recursively; arrays-of-hashes that share a stable id key merge per-element
  # (so an agent can patch one element's style without re-listing the array);
  # everything else (scalars, keyless arrays) is REPLACED by the patch value.
  #
  # DELETE semantics: a JSON `null` patch value DELETES that key from the merged
  # result (Sigma rejects an empty axis-title text, so removal needs a delete).
  # null for a key absent in base is a no-op (never inserted). Applies at any
  # depth, including inside id-keyed array elements.
  def deep_merge(base, patch)
    return strip_nulls(patch) unless base.is_a?(Hash) && patch.is_a?(Hash)
    out = base.dup
    patch.each do |k, v|
      if v.nil?
        out.delete(k)
        next
      end
      if k == 'legend' && v.is_a?(Hash)
        merged = merge_legend(out[k].is_a?(Hash) ? out[k] : {}, v)
        merged.nil? ? out.delete(k) : out[k] = merged
        next
      end
      # Name's hidden and shown title schemas are mutually exclusive.
      out[k] = if k == 'name' && v.is_a?(Hash) && (v['visibility'] == 'hidden' ||
                    (out[k].is_a?(Hash) && out[k]['visibility'] == 'hidden' && v.key?('text')))
                 v.dup
               elsif out.key?(k) && out[k].is_a?(Hash) && v.is_a?(Hash)
                 deep_merge(out[k], v)
               elsif out.key?(k) && out[k].is_a?(Array) && v.is_a?(Array)
                 merge_arrays(out[k], v)
               else
                 strip_nulls(v)
               end
    end
    out
  end

  # A chart legend is EITHER {visibility:"hidden"} alone OR shown config (position/color/fontSize/...):
  # Sigma rejects the two mixed ("cannot mix hidden with content") and has no visibility "visible".
  # Hiding replaces the legend wholesale; showing (config over a hidden base, or an explicit
  # visibility other than hidden) drops the hidden marker and the invalid "visible"; shown-over-shown
  # stays an ordinary deep merge. nil = nothing left to set (legend absent = Sigma's default).
  def merge_legend(base, patch)
    return { 'visibility' => 'hidden' } if patch['visibility'] == 'hidden' # hidden carries no content

    cfg = patch.reject { |lk, _| lk == 'visibility' }
    base_cfg = base['visibility'] == 'hidden' ? {} : base
    merged = deep_merge(base_cfg, cfg)
    merged.empty? ? nil : merged
  end

  # Drop nil-valued Hash keys (recursively, through arrays of hashes) from a
  # patch fragment that is being inserted wholesale — null means "delete", and
  # there is nothing to delete in a fresh insert.
  def strip_nulls(v)
    case v
    when Hash then v.each_with_object({}) { |(k, x), h| h[k] = strip_nulls(x) unless x.nil? }
    when Array then v.map { |x| strip_nulls(x) }
    else v
    end
  end

  def merge_arrays(base, patch)
    key = MERGE_KEYS.find { |mk| base.all? { |e| e.is_a?(Hash) && e.key?(mk) } && patch.all? { |e| e.is_a?(Hash) && e.key?(mk) } }
    return strip_nulls(patch) unless key # keyless / mixed arrays → replace wholesale
    merged = base.map(&:dup)
    index = {}
    merged.each_with_index { |e, i| index[e[key]] = i }
    patch.each do |pe|
      if (i = index[pe[key]])
        merged[i] = deep_merge(merged[i], pe)
      else
        index[pe[key]] = merged.length
        merged << strip_nulls(pe)
      end
    end
    merged
  end

  # Ids in the SHIPPED catalog ([] when it cannot be loaded - gate 8d does the
  # same, so an unreadable catalog never turns an entry into a waiver).
  def catalog_ids(path = CATALOG_PATH)
    cat = BlindGrade.load_catalog(path)
    cat['errors'].empty? ? Array(cat['ids']) : []
  end

  # DUPLICATED LOGIC (keep in step): the same predicate lives in the vendored
  # scripts/assert-phase6-ran.rb gate 8d (`specfix8d`) and, for what ships as a
  # residual, scripts/lib/degradation_ledger.rb (platform_difference_entry?).
  # test-assert-phase6-gates.rb runs gate 8d and `status` over one fixture
  # matrix and fails if they ever disagree.
  # Spec-fixable in gate 8d's sense: class spec-fixable, OR a sigma-capability /
  # ui-only entry that does not cite a shipped catalog_id (incl. legacy entries).
  def specfixable_entry?(entry, ids = catalog_ids)
    return true if entry['cls'] == 'spec-fixable'
    CATALOG_CLASSES.include?(entry['cls']) && !ids.include?(entry['catalog_id'].to_s)
  end

  # Bring an agent-authored patch onto the flat merge namespace apply-patch
  # uses (metadata + document keys at top level). 2026-11-03 live run: a patch
  # in the release shape {"document":{"elements":[...],"settings":{...}}} was
  # merged into a nested `document` copy that canonicalize() then discarded —
  # the PUT reported OK and nothing changed. Hoists document/contents wrappers,
  # folds legacy themeName/themeOverrides into settings.theme, and moves
  # page-nested elements onto the flat elements collection (canonicalize()
  # keeps the existing flat record over a page-nested one with the same id).
  def normalize_patch(patch)
    raise ArgumentError, 'patch must be a JSON object' unless patch.is_a?(Hash)
    out = patch.reject { |k, _| %w[document contents].include?(k) }
    %w[document contents].each do |wrapper|
      next unless patch.key?(wrapper)
      raise ArgumentError, "patch `#{wrapper}` must be an object" unless patch[wrapper].is_a?(Hash)
      out = deep_merge(out, patch[wrapper])
    end
    # document() keeps only document keys (folding the legacy theme pair);
    # carry the rest through so foreign_patch_keys can refuse them.
    out = out.reject { |k, _| Sigma::CodeRep::DOC_KEYS.include?(k) || Sigma::CodeRep::LEGACY_THEME_KEYS.include?(k) }
             .merge(Sigma::CodeRep.document(out))
    if out['pages'].is_a?(Array) && out['pages'].any? { |p| p.is_a?(Hash) && p.key?('elements') }
      nested = out['pages'].flat_map { |p| p.is_a?(Hash) ? Array(p['elements']) : [] }
      pages = out['pages'].map { |p| p.is_a?(Hash) ? p.reject { |k, _| k == 'elements' } : p }
                          .reject { |p| p.is_a?(Hash) && (p.keys - ['id']).empty? }
      pages.empty? ? out.delete('pages') : out['pages'] = pages
      out['elements'] = out['elements'].is_a?(Array) ? merge_arrays(out['elements'], nested) : nested
    end
    out
  end

  # Top-level patch keys the document PUT cannot carry (it sends only the
  # workbook document): workbook metadata and typos alike would be dropped.
  def foreign_patch_keys(patch, document_keys)
    patch.keys - (Sigma::CodeRep::DOC_KEYS + Array(document_keys))
  end

  # Leaf paths of `patch` that are ABSENT from `doc` (a workbook document).
  # Presence only: values may be legitimately rewritten (style-normalize,
  # server coercion). Arrays of id-keyed records match by that key.
  def unlanded_paths(patch, doc, prefix = nil)
    missing = []
    return missing unless patch.is_a?(Hash)
    patch.each do |k, v|
      next if v.nil?
      path = prefix ? "#{prefix}.#{k}" : k.to_s
      unless doc.is_a?(Hash) && doc.key?(k)
        missing << path
        next
      end
      have = doc[k]
      if v.is_a?(Hash) && have.is_a?(Hash)
        missing.concat(unlanded_paths(v, have, path))
      elsif v.is_a?(Array) && have.is_a?(Array)
        v.each do |pe|
          next unless pe.is_a?(Hash) && (key = MERGE_KEYS.find { |mk| pe.key?(mk) })
          label = "#{path}[#{key}=#{pe[key]}]"
          target = have.find { |e| e.is_a?(Hash) && e[key] == pe[key] }
          target ? missing.concat(unlanded_paths(pe.reject { |pk, _| pk == key }, target, label)) : missing << label
        end
      end
    end
    missing
  end

  # Entries that still BLOCK the gate: spec-fixable, not resolved, not named in
  # `accepted` (residual ids the operator explicitly waived).
  def unresolved_specfixable(ledger, accepted = [])
    accepted = Array(accepted).map(&:to_s)
    ids = catalog_ids
    (ledger['entries'] || []).each_with_index.select do |e, i|
      specfixable_entry?(e, ids) && !e['resolved'] &&
        !accepted.include?(i.to_s) && !accepted.include?(e['id'].to_s)
    end.map(&:last)
  end

  # Unresolved data-class entries — the numbers are wrong. These block the
  # gate UNCONDITIONALLY: no accepted-residual list applies (see file header).
  def unresolved_data(ledger)
    (ledger['entries'] || []).each_with_index
                             .select { |e, _i| e['cls'] == 'data' && !e['resolved'] }
                             .map(&:last)
  end

  def ledger_ok?(ledger, accepted = [])
    unresolved_specfixable(ledger, accepted).empty?
  end

  def add_entry(ledger, dimension:, delta:, cls:, fix: nil, resolved: false, pass: nil, evidence: nil, catalog_id: nil)
    raise ArgumentError, "class must be one of #{CLASSES.join('/')}" unless CLASSES.include?(cls)
    entry = {
      'id'        => "e#{(ledger['entries'] || []).length}",
      'pass'      => pass || ledger['pass'],
      'dimension' => dimension,
      'delta'     => delta,
      'cls'       => cls,
      'fix'       => fix,
      'resolved'  => !!resolved
    }
    entry['evidence'] = evidence if evidence
    entry['catalog_id'] = catalog_id if catalog_id
    (ledger['entries'] ||= []) << entry
    entry
  end

  # DUPLICATED LOGIC (keep in step): mirrors `budget_spent` in the vendored
  # scripts/assert-phase6-ran.rb gate 8d and RepairState.check_budget!
  # (lib/repair_state.rb); covered by the gate-8d/status agreement test in
  # test-assert-phase6-gates.rb.
  # Same budget semantics as gate 8d / repair_state.rb: rcf-exhausted.json with
  # status exhausted, pass >= max_passes, or elapsed >= max_seconds.
  def budget_spent?(ledger, workdir, now: Time.now)
    marker = File.join(workdir.to_s, 'rcf-exhausted.json')
    if File.file?(marker)
      doc = (JSON.parse(File.read(marker)) rescue nil)
      return true if doc.is_a?(Hash) && doc['status'].to_s == 'exhausted'
    end
    return false unless ledger.is_a?(Hash)
    max_p = ledger['max_passes'].to_i
    return true if ledger['max_passes'].is_a?(Numeric) && max_p.positive? && ledger['pass'].to_i >= max_p
    ms = ledger['max_seconds']
    if ledger['started_at'].is_a?(String) && ms.is_a?(Numeric) && ms.finite? && ms.positive?
      begin
        return true if now - Time.iso8601(ledger['started_at']) >= ms
      rescue ArgumentError
        return false
      end
    end
    false
  end

  def norm_dimension(dim)
    dim.to_s.strip.downcase.gsub(/[\s_]+/, '-')
  end

  # The rubric key an RCF --dimension stands for, or nil when it is free-form
  # vocabulary with no rubric equivalent.
  def rubric_dimension(dim)
    n = norm_dimension(dim)
    BlindGrade::DIMENSION_KEYS.find { |k| norm_dimension(k) == n } || FREE_FORM_RUBRIC[n]
  end

  # The shipped-catalog entry for `id`, or nil.
  def catalog_entry(id, path = CATALOG_PATH)
    cat = BlindGrade.load_catalog(path)
    return nil unless cat['errors'].empty?
    Array(cat['entries']).find { |e| e['id'].to_s == id.to_s }
  end

  def data_dimension?(dim)
    DATA_DIMENSIONS.include?(norm_dimension(dim))
  end

  # GitHub-style heading slug.
  def slug(heading)
    heading.to_s.strip.downcase.delete('`').gsub(/[^\p{Word}\- ]/, '').tr(' ', '-')
  end

  # Headings (## .. ####) present in the recipes file.
  def recipe_headings(path = RECIPES_PATH)
    return [] unless File.file?(path)
    fenced = false
    File.readlines(path, encoding: 'UTF-8').map do |l|
      if l =~ /\A\s*```/
        fenced = !fenced
        next nil
      end
      fenced ? nil : l[/\A\#{2,4}\s+(.+?)\s*\z/, 1]
    end.compact
  end

  # 'recipe:<anchor>' when the dimension maps to a heading that exists, else nil.
  def recipe_route(dim, headings)
    Array(RECIPE_HEADINGS[norm_dimension(dim)]).each do |prefix|
      h = headings.find { |x| x.downcase.start_with?(prefix.downcase) }
      return "recipe:#{slug(h)}" if h
    end
    nil
  end

  # visual-residuals.json gaps: `residuals` (minor fixable) + `fixable_major`.
  # On a PASSING v2 grade (DegradationLedger.visual_pass?) the minor residuals
  # are polish notes, not gaps, and are left out — exactly the entries the
  # degradation ledger also leaves out. Raises ArgumentError on a malformed
  # file; [] when absent.
  def visual_gaps(workdir)
    path = File.join(workdir, 'visual-residuals.json')
    return [] unless File.file?(path)
    doc = begin
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise ArgumentError, "visual-residuals.json is not valid JSON (#{e.message.lines.first.to_s.strip})"
    end
    raise ArgumentError, 'visual-residuals.json must be a JSON object' unless doc.is_a?(Hash)
    passed = DegradationLedger.respond_to?(:visual_pass?) && DegradationLedger.visual_pass?(workdir)
    %w[residuals fixable_major].flat_map do |k|
      v = doc[k]
      next [] if v.nil?
      unless v.is_a?(Array) && v.all? { |g| g.is_a?(Hash) }
        raise ArgumentError, "visual-residuals.json #{k} must be an array of gap objects"
      end
      next v.reject { |g| DegradationLedger.minor_gap?(g) } if passed && k == 'residuals'
      v
    end
  end

  # GREEN forfeits only the report sees (see green_blockers): source objects
  # migration-result.json marks approximated / needs-review / skipped, and
  # waivers.json entries. Tolerant: absent/unreadable files add nothing.
  def report_blockers(workdir)
    out = []
    mr = (JSON.parse(File.read(File.join(workdir, 'migration-result.json'))) rescue nil)
    Array(mr.is_a?(Hash) ? mr['source_objects'] : nil).each do |o|
      next unless o.is_a?(Hash) && %w[approximated needs-review skipped].include?(o['status'].to_s)
      out << { 'class' => "object-#{o['status']}", 'item' => [o['type'], o['name'] || o['id']].compact.join(' ') }
    end
    wv = (JSON.parse(File.read(File.join(workdir, 'waivers.json'))) rescue nil)
    wv = wv['waivers'] if wv.is_a?(Hash)
    Array(wv).each do |w|
      out << { 'class' => 'waiver', 'item' => w.is_a?(Hash) ? (w['flag'] || w['reason'] || w.to_json).to_s : w.to_s }
    end
    out
  end

  # Minor polish notes (DegradationLedger.polish_notes): the minor gaps of a
  # PASSING v2 grade. Optional polish — never a GREEN forfeit, never offered.
  def polish_notes(workdir)
    DegradationLedger.respond_to?(:polish_notes) ? DegradationLedger.polish_notes(workdir) : []
  end

  # visual-residuals.json top-level verdict: {'faithful'=>bool|nil, 'reasons'=>[..]}.
  # Tolerant (the malformed case is visual_gaps' job): {} when absent/unreadable.
  def visual_verdict(workdir)
    path = File.join(workdir, 'visual-residuals.json')
    doc = File.file?(path) ? (JSON.parse(File.read(path)) rescue nil) : nil
    return {} unless doc.is_a?(Hash)
    { 'faithful' => doc['faithful'], 'reasons' => Array(doc['reasons']).map(&:to_s) }
  end

  # Degradation-ledger entries the green-offer itself covers (fixing the gaps it
  # lists clears them): RCF residuals, the visual-residuals.json gaps, and the
  # divergent visual verdict. Everything else forfeits GREEN and cannot be fixed
  # by the loop. Source artifacts are the ones DegradationLedger.fidelity_residuals
  # stamps.
  OFFER_COVERED_SOURCES = ['fidelity-ledger.json', 'visual-residuals.json'].freeze
  def offer_covered?(entry)
    return false unless entry['class'] == 'fidelity-residual'
    OFFER_COVERED_SOURCES.include?(entry['source_artifact']) ||
      entry['item'] == 'visual verdict: divergent'
  end

  # Entries (derived ledger + extras) that forfeit GREEN regardless of the loop.
  # report_blockers: GREEN forfeits only the migration report sees (it goes
  # YELLOW on approximated / needs-review / skipped source objects and on
  # waivers.json entries, none of which are degradation-ledger entries).
  def green_blockers(derived, accepted_entries = [], security_skip: false, report_blockers: [])
    out = Array(derived).reject { |e| offer_covered?(e) }
                        .map { |e| { 'class' => e['class'], 'item' => e['item'] } }
    out.concat(Array(accepted_entries).map { |e| { 'class' => 'accepted-residual', 'item' => "#{e['id']} [#{e['dimension']}] #{e['delta']}" } })
    out << { 'class' => 'security-skip', 'item' => 'security-decision.json decision=skip' } if security_skip
    out.concat(Array(report_blockers))
    out.uniq
  end

  # The green-offer decision (pure). See the file header.
  #   derived  - DegradationLedger.derive(workdir) entries (what else forfeits GREEN)
  #   accepted - --accept-residuals ids: dropped from gaps, but a waiver => blocker
  #   verdict  - visual_verdict(workdir)
  def green_offer(ledger, visual, headings: recipe_headings, ids: catalog_ids,
                  derived: [], accepted: [], verdict: {}, security_skip: false, polish: [],
                  report_blockers: [])
    entries = ledger['entries'] || []
    accepted = Array(accepted).map(&:to_s)
    sdk_ledger = ledger['route'].to_s == 'sdk' # PR #939 hybrid loop: top-level ledger route
    data_open = entries.select { |e| e['cls'] == 'data' && !e['resolved'] }
    gaps = []
    accepted_entries = []
    entries.each_with_index do |e, i|
      next if e['resolved'] || !specfixable_entry?(e, ids)
      if accepted.include?(i.to_s) || accepted.include?(e['id'].to_s)
        accepted_entries << e
        next
      end
      gaps << { 'id' => e['id'], 'dimension' => e['dimension'], 'description' => e['delta'] }
    end
    visual_gaps_named = Array(visual).length
    Array(visual).each do |g|
      gaps << { 'tile' => g['tile'], 'dimension' => g['dimension'], 'description' => g['description'] }
    end
    data_gaps = gaps.select { |g| data_dimension?(g['dimension']) }
    gaps -= data_gaps
    gaps.each do |g|
      g['route'] = recipe_route(g['dimension'], headings) || (sdk_ledger ? 'sdk' : nil)
    end
    data_ids = (data_open.map { |e| e['id'] } + data_gaps.map { |g| g['id'] || g['tile'] }).compact
    blockers = green_blockers(derived, accepted_entries, security_skip: security_skip,
                                                         report_blockers: report_blockers)
    why = nil
    if blockers.any?
      b = blockers.first
      why = "GREEN is forfeited by #{b['class']}: #{b['item']}"
    elsif data_ids.any?
      why = "data-class gap(s) #{data_ids.join(', ')}: the values are wrong, which is a data fix and not a fidelity-loop fix"
    elsif verdict['faithful'] == false && visual_gaps_named.zero?
      reasons = verdict['reasons'].to_a.reject { |r| r.include?('second blind grader') }
      why = "unfaithful (#{reasons.join('; ')}) but the grade named no fixable gap"
    elsif gaps.empty?
      n = Array(polish).length
      # "GREEN" only when nothing else forfeits it: no blockers (checked above)
      # and an empty derived degradation ledger.
      green = DegradationLedger.verdict(Array(derived)) == 'GREEN'
      why = if n.positive? && green then "GREEN, optional polish: #{n} note#{n == 1 ? '' : 's'}"
            elsif n.positive? then "no fixable gaps remain; #{n} polish note#{n == 1 ? '' : 's'} (not degradations)"
            else 'no fixable gaps remain'
            end
    elsif (bad = gaps.select { |g| g['route'].nil? }).any?
      why = "no recipe or sdk route for: #{bad.map { |g| "#{g['id'] || g['tile']} (#{g['dimension']})" }.join(', ')}"
    end
    { 'realistic' => why.nil?, 'gaps' => gaps, 'est_passes' => (gaps.size / 3.0).ceil, 'why_not' => why,
      'blockers' => blockers.map { |x| "#{x['class']}: #{x['item']}" },
      'polish_notes' => Array(polish).map { |n| n['item'] } }
  end

  # A delta describing a chart that renders no data / is empty. Such a delta means
  # the ROWS ARE MISSING — a data-class defect — and must NEVER be laundered as
  # a cosmetic (sigma-capability / ui-only) residual to dodge the data-class hard
  # block. (2026-07 field failure: exactly this delta was classed sigma-capability
  # on the FALSE theory "Sigma's export API doesn't run queries," and a dataless
  # dashboard shipped GREEN.)
  #
  # Match the rendered-EMPTY state precisely, NOT any mention of "data"/"blank"
  # (review-caught false positives: "no data LABELS", "no data-label PADDING",
  # "no data TICKS", "BLANK CHART BACKGROUND color" are cosmetic, not empty-state).
  # A viz noun that can carry data (so "legend"/"axis"/"background" don't trigger).
  _NOUN = '(?:chart|charts|tile|tiles|dashboard|panel|viz|pivot|table|render|element)'
  NO_DATA_RX = Regexp.new(
    '\bno[\s-]?data\b(?![\s-]*(?:label|point|tick|marker|mark|pad|value|ink|axis|grid|legend|colou?r|background|border|title))' \
    "|\\b#{_NOUN}s?\\s+(?:is|are|was|were|came\\s+back|comes?\\s+back|returned?|renders?|shows?|displays?)\\s+(?:empty|blank|no\\s+data)\\b" \
    '|\bempty\s+(?:data\s+)?(?:export|result)s?\b' \
    '|\b(?:zero|no)\s+rows?\b' \
    '|renders?\s+nothing',
    Regexp::IGNORECASE)
  def no_data_delta?(delta)
    delta.to_s =~ NO_DATA_RX ? true : false
  end

  # ---- RCF page picking (#422) ---------------------------------------------
  # Elements that actually RENDER content on the page: hidden helpers carry
  # visibleAsSource:false (the master + LOD/window helper tables), and a
  # hidden:true element/page never renders. Everything else counts.
  def visible_count(page)
    (page['elements'] || []).count do |e|
      e.is_a?(Hash) && e['visibleAsSource'] != false && e['hidden'] != true
    end
  end

  # A data/helper page: named "Data" (the converter's source-table page), or
  # carrying only table elements (no charts/KPIs/text/controls to review).
  def data_page?(page)
    return true if page['name'].to_s.strip.match?(/\AData\z/i)
    els = (page['elements'] || []).select { |e| e.is_a?(Hash) && e['hidden'] != true }
    !els.empty? && els.all? { |e| e['kind'] == 'table' }
  end

  # Pick the RCF page from an array of page hashes ({'id','name','elements'}).
  # Preference tiers: (1) a page whose name matches a SOURCE dashboard name
  # (`dashboard_names:`, from dashboard-scope.json / dashboard-layout.json),
  # (2) any non-data page, (3) data/helper pages. Within a tier: the page with
  # the MOST visible elements — not first-by-order, which picked a second data
  # page carrying only hidden helper tables (#422 live run) — and the Data page
  # (many tables) no longer outranks the dashboard page.
  # Returns [picked_page_or_nil, tied_pages] — tied_pages has >1 entry when
  # several pages share the top tier+count (caller warns; pick is first-by-order
  # among the ties, deterministic).
  # The pages a multi-dashboard render covers, in SOURCE dashboard order: the
  # live pages named like every source dashboard; otherwise every non-data
  # page that shows something. Returns [] when there is <= 1.
  def dashboard_pages(pages, dashboard_names: [])
    cands = Array(pages).select { |p| p.is_a?(Hash) && p['id'] }
    names = Array(dashboard_names).map { |n| n.to_s.strip.downcase }.reject(&:empty?).uniq
    hit = names.map { |n| cands.find { |p| p['name'].to_s.strip.downcase == n } }.compact.uniq
    eligible = cands.reject { |p| data_page?(p) || visible_count(p).zero? }
    selected = names.any? && hit.size == names.size ? hit : eligible
    selected.size > 1 ? selected : []
  end

  def pick_rcf_page(pages, dashboard_names: [])
    cands = Array(pages).select { |p| p.is_a?(Hash) && p['id'] }
    return [nil, []] if cands.empty?
    names = Array(dashboard_names).map { |n| n.to_s.strip.downcase }.reject(&:empty?)
    scored = cands.map do |p|
      tier = if names.include?(p['name'].to_s.strip.downcase) then 2
             elsif data_page?(p) then 0
             else 1
             end
      [[tier, visible_count(p)], p]
    end
    best = scored.map { |s, _| s }.max
    top = scored.select { |s, _| s == best }.map { |_, p| p }
    [top.first, top]
  end
end

# ---------------------------------------------------------------------------
# CLI (IO / REST / subprocess) — thin wrapper around the pure core above.
# ---------------------------------------------------------------------------
return if $PROGRAM_NAME != __FILE__ && !ENV['FIDELITY_LOOP_CLI'] # allow `require` in tests

HERE = __dir__
LEDGER_NAME = 'fidelity-ledger.json'
EXHAUSTED_NAME = 'rcf-exhausted.json'

def die(msg, code = 2)
  warn "FATAL: #{msg}"
  exit code
end

# A budget-exhausted refusal carries the exact `extend` command to run.
def budget_message(error, ledger, dir)
  msg = error.message
  msg += RepairState.extend_hint(ledger, dir) if msg.include?('budget exhausted')
  msg
end

def ledger_path(dir)
  File.join(dir, LEDGER_NAME)
end

def exhausted_path(dir)
  File.join(dir, EXHAUSTED_NAME)
end

def write_exhausted(dir, ledger)
  latest = Array(ledger['renders']).last
  File.write(
    exhausted_path(dir),
    JSON.pretty_generate(
      'status' => 'exhausted',
      'workbook_id' => ledger['workbook_id'],
      'page_id' => ledger['page_id'],
      'pass' => ledger['pass'],
      'max_passes' => ledger['max_passes'],
      'latest_render' => latest,
      'recorded_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    )
  )
end

def load_ledger(dir)
  p = ledger_path(dir)
  die "no #{p} — run `fidelity-loop.rb init` first", 2 unless File.exist?(p)
  JSON.parse(File.read(p))
end

def save_ledger(dir, ledger)
  File.write(ledger_path(dir), JSON.pretty_generate(ledger))
end

# #422: --page-id omitted at init → pick the page with the most VISIBLE
# (non-hidden) elements. Live page ids come from wb-ids.json (the readback);
# element visibility (visibleAsSource:false hidden helpers) only lives in
# wb-spec.json — join the two by page name. Dies (usage) when neither file
# yields a page.
def source_dashboard_names(dir)
  names = []
  %w[dashboard-scope.json dashboard-layout.json dashboard-coverage.json].each do |f|
    j = (JSON.parse(File.read(File.join(dir, f))) rescue nil)
    next unless j
    list = j.is_a?(Array) ? j : (j['dashboards'] || j['names'] || [])
    list = list.keys if list.is_a?(Hash)
    Array(list).each do |d|
      names << (d.is_a?(Hash) ? (d['name'] || d['dashboard']) : d).to_s
    end
  end
  names.reject(&:empty?).uniq
end

def workdir_pages(dir)
  wb_ids  = (JSON.parse(File.read(File.join(dir, 'wb-ids.json'))) rescue nil)
  wb_spec = (JSON.parse(File.read(File.join(dir, 'wb-spec.json'))) rescue nil)
  wb_ids = WorkbookCode.legacy_view(wb_ids) if wb_ids
  wb_spec = WorkbookCode.legacy_view(wb_spec) if wb_spec
  spec_by_name = {}
  ((wb_spec && wb_spec['pages']) || []).each { |p| spec_by_name[p['name']] = p if p.is_a?(Hash) }
  (((wb_ids && wb_ids['pages']) || (wb_spec && wb_spec['pages'])) || []).map do |p|
    next nil unless p.is_a?(Hash) && p['id']
    sp = spec_by_name[p['name']]
    { 'id' => p['id'], 'name' => p['name'],
      'elements' => ((sp && sp['elements']) || p['elements']) || [] }
  end.compact
end

def auto_pick_rcf_page(dir)
  pages = workdir_pages(dir)
  pick, top = FidelityLoop.pick_rcf_page(pages, dashboard_names: source_dashboard_names(dir))
  die 'no --page-id given and no pages found in <workdir>/wb-ids.json or wb-spec.json to auto-pick from', 2 unless pick
  if top.length > 1
    warn "WARN: #{top.length} pages tie at #{FidelityLoop.visible_count(pick)} visible element(s) " \
         "(#{top.map { |p| p['name'] || p['id'] }.join(', ')}) — picked #{pick['name'] || pick['id']} " \
         '(first-by-order); pass --page-id to override'
  end
  puts "auto-picked RCF page #{(pick['name'] || pick['id']).inspect} (#{pick['id']}) — " \
       "most visible elements (#{FidelityLoop.visible_count(pick)}); --page-id overrides"
  pick['id']
end

def print_rubric
  rubric = File.join(HERE, '..', 'refs', 'fidelity-rubric.md')
  puts
  if File.exist?(rubric)
    puts "───── SCORE THIS PASS against refs/fidelity-rubric.md ─────"
    # Print just the dimension headers so the agent has the checklist inline.
    File.foreach(rubric, encoding: 'UTF-8') do |l|
      puts "  #{l.rstrip}" if l =~ /^\s*[-*]\s*\*\*/ || l =~ /^#{'#'}{2,4}\s/
    end
  else
    puts '───── SCORE THIS PASS (rubric dimensions) ─────'
    %w[layout/containers typography/text palette/theme chart-kinds+marks
       labels/number-formats controls/parameters filters-wired
       KPI/table-values accuracy].each { |d| puts "  - #{d}" }
  end
  puts '───────────────────────────────────────────────────────────'
end

# #422: a live-only apply-patch was REVERTED by the next re-entry full-spec
# PUT (post-and-readback PUTs the workdir wb-spec.json wholesale) — the
# operator had to hand-persist every RCF fix. Live writes retain the complete
# candidate and fail closed on persistence errors. Dry-run previews retain the
# older best-effort local merge behavior without making live-state claims.
def persist_patch_to_wb_spec(dir, patch, live_spec: nil)
  path = File.join(dir, 'wb-spec.json')
  if live_spec
    raise RepairState::Error, 'local workbook spec must not be a symlink' if File.symlink?(path)
    File.write(path, JSON.pretty_generate(WorkbookCode.canonicalize(live_spec)) + "\n")
    puts "[OK] complete live candidate persisted into #{path}"
    return
  end
  unless File.exist?(path)
    puts "     (no #{path} — patch applied live only; a re-entry full-spec PUT will not carry it)"
    return
  end
  begin
    spec = JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    warn "WARN: #{path} does not parse (#{e.message}) — patch NOT persisted; a re-entry full-spec PUT will revert this fix"
    return
  end
  canonical_spec = WorkbookCode.canonicalize(spec)
  merge_base = WorkbookCode.metadata(canonical_spec).merge(WorkbookCode.document(canonical_spec))
  merge_base[WorkbookCode::LEGACY_DOCUMENT_KEY] = WorkbookCode.document(canonical_spec)
  merge_base[WorkbookCode::LEGACY_METADATA_KEY] = WorkbookCode.metadata(canonical_spec)
  merged = FidelityLoop.deep_merge(merge_base, patch)
  File.write(path, JSON.pretty_generate(WorkbookCode.canonicalize(merged)) + "\n")
  puts "[OK] patch persisted into #{path} (re-entry full-spec PUTs carry this fix)"
rescue StandardError => e
  raise if live_spec
  warn "WARN: could not persist patch into #{path}: #{e.class}: #{e.message}"
end

def with_optional_budget(ledger, &block)
  ledger ? RepairState.with_budget(ledger, &block) : yield
end

def request_with_budget(ledger, *args, **options)
  with_optional_budget(ledger) { Sigma.request(*args, **options) }
end

# ---- Hybrid SDK route helpers (refs/phase-5g-sdk-hybrid.md) ----------------
def doc_version(spec)
  return nil unless spec.is_a?(Hash)
  (spec['latestDocumentVersion'] || spec['latestVersion'] || spec['documentVersion'])&.to_s
end

def deep_dup(obj)
  JSON.parse(JSON.generate(obj))
end

# The open session must still own repair-pending.json — anything else means the
# session was reconciled (recover/rollback) or another repair is in flight.
def sdk_pending_matches!(dir, session, ledger = nil)
  marker = File.join(dir, 'repair-pending.json')
  die 'repair-pending.json must not be a symlink', 4 if File.symlink?(marker)
  # Self-heal the one crash window sdk-export leaves: an export that passed its
  # guards was interrupted before it re-held the marker. recover/rollback leave
  # other states, so a parity-unverified session without a marker is only that.
  if !File.exist?(marker) && ledger && SdkRoute.state(ledger) == 'parity-unverified' &&
     Array(session['exports']).last&.fetch('guards', nil) == 'pass'
    RepairState.begin_write(dir, sdk_checkpoint_dir(dir, session))
    warn "[NOTE] re-held repair-pending.json for SDK session #{session['id']} (an interrupted sdk-export)."
  end
  unless File.exist?(marker)
    die "SDK session #{session['id']} is open but repair-pending.json is gone — it was reconciled " \
        'elsewhere; read back the live workbook and rollback/re-open a session', 4
  end
  owner = (JSON.parse(File.read(marker))['checkpoint'] rescue nil)
  die 'repair-pending.json belongs to a different repair; reconcile it before SDK work', 4 unless owner == session['checkpoint']
end

# control-scope.json for ControlLint: one loader for every lint site
# (apply-patch and sdk-export); nil when absent or unparseable, which
# ControlLint treats as "no scope narrowing".
def load_control_scope(dir)
  JSON.parse(File.read(File.join(dir, 'control-scope.json')))
rescue StandardError
  nil
end

# The refusal for render / apply-patch / sdk-begin while repair-pending.json
# exists: when it belongs to an open SDK session, say which command releases
# it instead of the generic "unverified write outcome" (live proof, edge 3).
def pending_refusal(dir, generic)
  ledger = (JSON.parse(File.read(ledger_path(dir))) rescue nil)
  session = ledger.is_a?(Hash) ? SdkRoute.open_session(ledger) : nil
  owner = (JSON.parse(File.read(File.join(dir, 'repair-pending.json')))['checkpoint'] rescue nil)
  session && owner == session['checkpoint'] ? SdkRoute.open_block_message(ledger, session) : generic
end

def sdk_checkpoint_dir(dir, session)
  File.join(dir, 'repair-checkpoints', session['checkpoint'].to_s)
end

# Copy an agent-supplied file into the write's local evidence folder (0600).
# These can carry customer metadata: they stay in the workdir, never committed.
def sdk_keep(src, dest_dir, name)
  die "#{src} is not a readable file", 2 unless src && File.file?(src) && !File.symlink?(src)
  FileUtils.mkdir_p(dest_dir, mode: 0o700)
  dest = File.join(dest_dir, name)
  die "refusing to overwrite #{dest}", 2 if File.exist?(dest) || File.symlink?(dest)
  File.open(dest, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(File.binread(src)) }
  [dest, Digest::SHA256.file(dest).hexdigest]
end

# Each export attempt rebinds the session checkpoint's rollback candidate to the
# live state it read (RepairState.record_candidate is create-only).
def sdk_replace_candidate(checkpoint, spec)
  %w[candidate-spec.json candidate.sha256].each do |name|
    path = File.join(checkpoint, name)
    die "rollback candidate #{name} must not be a symlink", 4 if File.symlink?(path)
    File.delete(path) if File.exist?(path)
  end
  RepairState.record_candidate(checkpoint, spec)
end

def element_ids(spec)
  return [] unless spec.is_a?(Hash)
  Sigma::CodeRep.workbook_elements(spec).map { |e| e['id'] || e['elementId'] }.compact.sort
rescue StandardError
  []
end

# Phase-6 parity on the exported spec: pass 1 (plan + REST actuals), the same
# completeness check finalize's chain predicate uses, then pass 2. Returns
# [result ('pass'|'fail'|'unverified'), exit_code, detail].
def sdk_parity(dir, wb, actuals: nil)
  require 'rbconfig'
  require 'open3'
  p6 = File.join(HERE, 'phase6-parity.rb')
  state = (JSON.parse(File.read(File.join(dir, 'migrate-state.json'))) rescue {})
  extract = state.is_a?(Hash) && state['extract_mode'] ? ['--extract-mode', '--extract-tol', '0.30'] : []
  actuals_path = actuals ? File.expand_path(actuals) : File.join(dir, 'parity-actuals.json')
  unless actuals
    argv = [RbConfig.ruby, p6, '--tableau', dir, '--workbook-id', wb, *extract]
    puts "sdk parity: #{File.basename(p6)} pass 1 (plan rebuilt from the exported spec)"
    # Runs this skill's own phase6-parity.rb as an argument list (no shell); dir and workbook id are the run's own arguments.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, st = Open3.capture2e(*argv)
    puts out
    return ['unverified', st.exitstatus, "phase6-parity pass 1 exited #{st.exitstatus}"] unless st.success?
  end
  plan = (JSON.parse(File.read(File.join(dir, 'parity-plan.json'))) rescue nil)
  actuals_doc = (JSON.parse(File.read(actuals_path)) rescue nil)
  complete, why = SdkRoute.actuals_complete?(plan, actuals_doc)
  return ['unverified', nil, why] unless complete
  puts "sdk parity: #{File.basename(p6)} --finalize (#{why})"
  # Runs this skill's own phase6-parity.rb as an argument list (no shell); dir and workbook id are the run's own arguments.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, st = Open3.capture2e(RbConfig.ruby, p6, '--tableau', dir, '--finalize', '--actuals', actuals_path, *extract)
  puts out
  case st.exitstatus
  when 0 then ['pass', 0, nil]
  when 2 then ['fail', 2, out.lines.grep(/^DIVERGE/).first(3).map(&:strip).join('; ')]
  else ['unverified', st.exitstatus, "phase6-parity --finalize exited #{st.exitstatus}"]
  end
end

def sdk_finish_parity(dir, ledger, session, result)
  res, code, detail = result
  marker = File.join(dir, 'repair-pending.json')
  die 'repair-pending.json must not be a symlink', 4 if File.symlink?(marker)
  # Unverified parity keeps the session OPEN (marker held, like a guard
  # failure) so the next fix is a recorded sdk-write; pass / fail close it.
  RepairState.begin_write(dir, sdk_checkpoint_dir(dir, session)) if res == 'unverified' && !File.exist?(marker)
  SdkRoute.record_parity!(ledger, session, result: res, exit_code: code, detail: detail)
  save_ledger(dir, ledger)
  if res != 'unverified' && File.exist?(marker) &&
     (JSON.parse(File.read(marker))['checkpoint'] rescue nil) == session['checkpoint']
    File.delete(marker)
  end
  case res
  when 'pass'
    puts '[OK] phase-6 parity PASS on the SDK-exported spec. NEXT: one budgeted REST render'
    puts "     (fidelity-loop.rb render --workdir #{dir}) → blind grader → record-visual-check.rb → --finalize."
    exit 0
  when 'fail'
    warn "[FAIL] phase-6 parity DIVERGED on the SDK-exported spec#{detail.to_s.empty? ? '' : ": #{detail}"}"
    warn '       A data-class ledger entry now blocks gate 8d. Fix in a new SDK session (sdk-begin), or rollback.'
    exit 7
  else
    warn "[INCOMPLETE] phase-6 parity on the SDK-exported spec is unverified: #{detail}"
    warn "       The session stays OPEN (repair-pending.json kept). Either supply the missing actuals:"
    warn "         ruby scripts/fidelity-loop.rb sdk-regate --workdir #{dir} --actuals FILE"
    warn '       or fix the workbook with more SDK writes (sdk-write each), then sdk-export again.'
    exit 5
  end
end

cmd = ARGV.shift
opts = {}
parser = OptionParser.new do |p|
  p.on('--workdir DIR')       { |v| opts[:dir] = WorkdirGuard.check!(v, '--workdir') }
  p.on('--workbook-id ID')    { |v| opts[:wb] = v }
  p.on('--page-id ID')        { |v| opts[:page] = v }
  p.on('--source-image PNG')  { |v| opts[:src] = v }
  p.on('--max-passes N', Integer) { |v| opts[:max] = v }
  p.on('--max-seconds N', Integer, 'total wall-clock repair budget, default 1800 for new ledgers') { |v| opts[:max_seconds] = v }
  p.on('--reason TEXT', 'specific reason/hypothesis for a user-approved budget extension') { |v| opts[:reason] = v }
  p.on('--approved-by NAME', 'attribution for an actual user-approved extension') { |v| opts[:approved_by] = v }
  p.on('--all-pages', 'render: every dashboard page into ONE composite pass (default for a multi-dashboard workbook)') { opts[:all_pages] = true }
  p.on('--single-page', 'render: only the ledger page even on a multi-dashboard workbook') { opts[:single_page] = true }
  p.on('--width N', Integer)  { |v| opts[:width] = v }
  p.on('--height N', Integer) { |v| opts[:height] = v }
  p.on('--dimension D')       { |v| opts[:dim] = v }
  p.on('--delta S')           { |v| opts[:delta] = v }
  p.on('--class C')           { |v| opts[:cls] = v }
  p.on('--probe PATH', 'a "no data / empty" delta may only be classed sigma-capability/ui-only WITH a probe artifact (JSON) proving the emptiness is a genuine platform-render issue and the element export DOES return rows — never to launder a broken data path') { |v| opts[:probe] = v }
  p.on('--catalog-id ID', 'sigma-capability/ui-only: id in the shipped refs/sigma-platform-differences.json (required; no override)') { |v| opts[:catalog_id] = v }
  p.on('--fix S')             { |v| opts[:fix] = v }
  p.on('--resolved')          { opts[:resolved] = true }
  p.on('--entry N', Integer)  { |v| opts[:entry] = v }
  p.on('--patch P')           { |v| opts[:patch] = v }
  p.on('--full-spec P')       { |v| opts[:full] = v }
  p.on('--checkpoint ID', 'rollback a recorded repair candidate; refuses later external edits') { |v| opts[:checkpoint] = v }
  p.on('--resolves LIST')     { |v| opts[:resolves] = v.split(',').map(&:strip) }
  p.on('--accept-residuals L'){ |v| opts[:accept] = v.split(',').map(&:strip) }
  p.on('--dry-run')           { opts[:dry] = true }
  p.on('--live-spec P')       { |v| opts[:live] = v }
  p.on('--out P')             { |v| opts[:out] = v }
  p.on('--skip-style-normalize REASON', 'skip the v5.1 style contract on apply-patch (quality waiver — name it in your report)') { |v| opts[:skip_style_normalize] = v }
  # Hybrid SDK route (refs/phase-5g-sdk-hybrid.md)
  p.on('--mcp-server NAME', 'sdk-begin: the Sigma MCP server the SDK writes go through') { |v| opts[:mcp_server] = v }
  p.on('--program FILE', 'sdk-write: the Code Mode program sent to build_workbook') { |v| opts[:program] = v }
  p.on('--result FILE', 'sdk-write: the build_workbook output text') { |v| opts[:result] = v }
  p.on('--status S', 'sdk-write: ok | failed (default ok)') { |v| opts[:sdk_status] = v }
  p.on('--error TEXT', 'sdk-write: the failure message for --status failed') { |v| opts[:error] = v }
  p.on('--summary TEXT', 'sdk-write: what the write changed') { |v| opts[:summary] = v }
  p.on('--claims LIST', 'sdk-write: ledger entry ids this write fixes (resolved only after sdk-export re-gates)') { |v| opts[:claims] = v.split(',').map(&:strip).reject(&:empty?) }
  p.on('--evidence FILE', 'sdk-reread: the describe/get_table output of the page re-read') { |v| opts[:evidence] = v }
  p.on('--actuals FILE', 'sdk-regate: completed parity actuals (skips the phase-6 pass-1 collection)') { |v| opts[:actuals] = v }
end
parser.parse!(ARGV)
die 'missing --workdir' unless opts[:dir]
die '--max-seconds must be positive' if opts[:max_seconds] && opts[:max_seconds] <= 0
require_relative 'lib/repair_state'
require_relative 'lib/sdk_route'
require 'fileutils'
pending_repair = File.join(opts[:dir], 'repair-pending.json')
if %w[apply-patch render].include?(cmd) && !opts[:dry] && (File.exist?(pending_repair) || File.symlink?(pending_repair))
  die pending_refusal(opts[:dir], 'repair-pending.json records an unverified write outcome; recover and read back live state before continuing'), 4
end
SDK_CMDS = %w[sdk-begin sdk-write sdk-reread sdk-export sdk-regate].freeze
if (%w[apply-patch recover render extend rollback] + SDK_CMDS).include?(cmd) && !opts[:dry]
  require_relative 'lib/migration_process'
  begin
    MigrationProcess.acquire(opts[:dir])
  rescue MigrationProcess::Busy => error
    die error.message, 28
  end
  if %w[apply-patch render].include?(cmd) && (File.exist?(pending_repair) || File.symlink?(pending_repair))
    die 'repair-pending.json appeared before lock acquisition; reconcile before continuing', 4
  end
end
require_relative 'lib/migration_diagnostics'
diagnostic_kind = cmd == 'render' ? 'render' : ((%w[record resolve apply-patch] + SDK_CMDS).include?(cmd) ? 'repair' : 'script')
MigrationDiagnostics.process(opts[:dir], kind: diagnostic_kind, operation: "fidelity-loop.rb:#{cmd}")

case cmd
when 'init'
  die '--workbook-id required for init' unless opts[:wb]
  # PRESERVE an existing ledger for the same workbook (field-caught: every
  # FAST PATH orchestrator re-entry re-ran init and WIPED the recorded deltas
  # — the natural fix-and-re-run loop destroyed its own audit trail). Only a
  # DIFFERENT workbook id starts fresh; same-workbook re-init is a no-op —
  # except an explicit --page-id, which OVERRIDES the recorded page in place
  # (#422: init used to offer no way to repoint an existing ledger at the
  # right page). (direct file check — load_ledger die()s with SystemExit on a
  # missing file, which `rescue nil` does NOT catch; a fresh init would exit 2)
  existing = File.exist?(ledger_path(opts[:dir])) ? (JSON.parse(File.read(ledger_path(opts[:dir]))) rescue nil) : nil
  if existing.is_a?(Hash) && existing['workbook_id'] == opts[:wb]
    if opts[:page] && existing['page_id'] != opts[:page]
      old = existing['page_id']
      existing['page_id'] = opts[:page]
      existing['source_image'] = opts[:src] if opts[:src]
      save_ledger(opts[:dir], existing)
      puts "[OK] fidelity ledger page OVERRIDDEN: #{old} → #{opts[:page]} " \
           "(#{(existing['entries'] || []).length} entries preserved, pass #{existing['pass']}/#{existing['max_passes']})"
    else
      puts "[OK] fidelity ledger already initialized for #{opts[:wb]} " \
           "(#{(existing['entries'] || []).length} entries, pass #{existing['pass']}/#{existing['max_passes']}) — preserved."
    end
  else
    page = opts[:page] || auto_pick_rcf_page(opts[:dir])
    ledger = FidelityLoop.new_ledger(
      workbook_id: opts[:wb], page_id: page,
      source_image: opts[:src], max_passes: opts[:max] || 5, max_seconds: opts[:max_seconds] || 1800
    )
    save_ledger(opts[:dir], ledger)
    File.delete(exhausted_path(opts[:dir])) if File.exist?(exhausted_path(opts[:dir]))
    puts "[OK] initialized #{ledger_path(opts[:dir])} (page #{page}, max_passes=#{ledger['max_passes']})"
  end

when 'render'
  ledger = load_ledger(opts[:dir])
  begin
    RepairState.check_budget!(ledger)
  rescue RepairState::Error => error
    die budget_message(error, ledger, opts[:dir]), 3
  end
  max = ledger['max_passes'].to_i
  if ledger['pass'] >= max && max.positive?
    write_exhausted(opts[:dir], ledger)
    warn "[STOP] pass budget exhausted (#{ledger['pass']}/#{max} passes run)."
    warn '       Record any remaining deltas as ui-only / sigma-capability / accepted residuals'
    warn '       and exit — do not keep rendering. See refs/fidelity-rubric.md.'
    exit 3
  end
  ledger['pass'] += 1
  n = ledger['pass']
  save_ledger(opts[:dir], ledger) # Failed attempts consume time and render budget too.
  write_exhausted(opts[:dir], ledger) if max.positive? && n >= max
  require_relative 'lib/sigma_rest'
  before_render = request_with_budget(ledger, :get, Sigma::CodeRep.read_path(ledger['workbook_id']))
  render_version = before_render['latestDocumentVersion'] || before_render['latestVersion'] || before_render['documentVersion']
  die 'render cannot be bound to a live workbook version', 4 if render_version.to_s.empty?
  out_png = File.join(opts[:dir], "rcf-pass-#{n}.png")
  renderer = File.join(HERE, 'sigma-export-png.py')
  require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)
  require_relative 'lib/export_viewport'
  # Which page(s): an explicit --page-id renders THAT page (it used to be
  # ignored — always the ledger page); a multi-dashboard workbook renders every
  # dashboard page into one composite pass (the blind grade + visual record
  # judge the workbook as a whole) unless --single-page.
  dash_pages = opts[:page] || opts[:single_page] ? [] : FidelityLoop.dashboard_pages(workdir_pages(opts[:dir]), dashboard_names: source_dashboard_names(opts[:dir]))
  if opts[:all_pages] && dash_pages.empty?
    warn 'WARN: --all-pages: fewer than 2 dashboard pages found in wb-ids.json / wb-spec.json — rendering one page'
  end
  render_ids = if opts[:page] then [opts[:page]]
               elsif dash_pages.any? then dash_pages.map { |p| p['id'] }
               else [ledger['page_id']]
               end
  page_pngs = render_ids.each_with_index.map do |pid, idx|
    vp_w, vp_h = ExportViewport.for(workdir: opts[:dir], page_id: pid)
    vp_w = opts[:width] if opts[:width]
    vp_h = opts[:height] if opts[:height]
    target = render_ids.size == 1 ? out_png : File.join(opts[:dir], "rcf-pass-#{n}-p#{idx + 1}-#{pid.to_s.gsub(/[^\w-]/, '_')}.png")
    puts "render page #{pid} viewport #{vp_w}x#{vp_h}#{opts[:width] || opts[:height] ? ' (--width/--height override)' : ' (ExportViewport: source PNG / layout)'}"
    cmd_r = [*PyResolve.argv, PyResolve.winpath(renderer), '--workbook', ledger['workbook_id'],
             '--page', pid, '--out', PyResolve.winpath(target),
             '--w', vp_w.to_s, '--h', vp_h.to_s]
    ok = RepairState.render(ledger, cmd_r)
    unless ok && File.exist?(target) && File.size(target) > 5_000
      die "render failed — sigma-export-png.py did not produce a valid #{target}", 4
    end
    target
  end
  comparison_source = ledger['source_image']
  if page_pngs.size == 1
    rendered_page = workdir_pages(opts[:dir]).find { |p| p['id'] == render_ids.first }
    require_relative 'lib/source_png'
    page_source = SourcePng.path(opts[:dir], rendered_page['name']) if rendered_page
    comparison_source = page_source if page_source && File.file?(page_source)
  end
  if page_pngs.size > 1
    require_relative 'lib/png_stack'
    begin
      cw, ch = PngStack.stack(page_pngs, out_png)
    rescue PngStack::Error => e
      die "composite render failed: #{e.message} (per-page renders kept: #{page_pngs.map { |x| File.basename(x) }.join(', ')})", 4
    end
    puts "composite of #{page_pngs.size} dashboard page(s) → #{File.basename(out_png)} (#{cw}x#{ch}; --single-page renders the ledger page only)"
    # The matching SOURCE composite, same page order, when every dashboard PNG exists.
    names = dash_pages.map { |p| p['name'].to_s }
    require_relative 'lib/source_png'
    srcs = names.map { |nm| SourcePng.path(opts[:dir], nm) || File.join(opts[:dir], 'dashboards', "#{nm}.png") }
    src_out = File.join(opts[:dir], 'source-composite.png')
    if names.all? { |nm| !nm.empty? } && srcs.all? { |x| File.file?(x) }
      begin
        PngStack.stack(srcs, src_out)
        comparison_source = src_out
        puts "source composite (same page order) → #{File.basename(src_out)}"
      rescue PngStack::Error => e
        warn "WARN: source composite not written: #{e.message}"
      end
    end
  end
  after_render = request_with_budget(ledger, :get, Sigma::CodeRep.read_path(ledger['workbook_id']))
  after_version = after_render['latestDocumentVersion'] || after_render['latestVersion'] || after_render['documentVersion']
  die 'workbook changed during render; image retained for diagnosis but not accepted as current evidence', 4 unless after_version.to_s == render_version.to_s
  RepairState.check_budget!(ledger)
  ledger['source_image'] = comparison_source if comparison_source
  ledger['renders'] << { 'pass' => n, 'path' => out_png, 'document_version' => render_version.to_s,
                         'sha256' => Digest::SHA256.file(out_png).hexdigest,
                         'pages' => render_ids, 'composite' => page_pngs.size > 1 }
  save_ledger(opts[:dir], ledger)
  exhausted = max.positive? && n >= max
  write_exhausted(opts[:dir], ledger) if exhausted
  puts "[OK] pass #{n}/#{max}: rendered #{out_png} (#{(File.size(out_png) / 1024.0).round} KB)"
  puts "     SOURCE to compare against: #{ledger['source_image'] || '(set --source-image at init; else use visual-qa/<dash>.source.png)'}"
  print_rubric
  if exhausted
    warn "[STOP] this was the final budgeted render (#{n}/#{max}). #{EXHAUSTED_NAME} written."
    warn '       Record residuals and stop; do not patch or export another fidelity render.'
  else
    puts "NEXT: Read both PNGs, then `record` each delta (classify spec-fixable/ui-only/sigma-capability/data),"
    puts "      `apply-patch` the spec-fixable ones (recipes: refs/fidelity-recipes.md), then `render` again."
  end

when 'record'
  die '--dimension, --delta, --class required' unless opts[:dim] && opts[:delta] && opts[:cls]
  die "--class must be one of #{FidelityLoop::CLASSES.join('/')}" unless FidelityLoop::CLASSES.include?(opts[:cls])
  # W1.5: a "no data / empty" delta is a data-class defect. It may not be recorded
  # as a cosmetic residual (sigma-capability / ui-only) unless a probe artifact
  # proves the emptiness is a genuine platform-render issue AND the data is present.
  if FidelityLoop.no_data_delta?(opts[:delta]) && %w[sigma-capability ui-only].include?(opts[:cls])
    probe_ok = opts[:probe] && File.exist?(opts[:probe]) && File.size(opts[:probe]).to_i.positive?
    unless probe_ok
      die <<~MSG, 6
        --class #{opts[:cls]} REJECTED for a "no data / empty" delta:
          #{opts[:delta]}
        A chart that renders no data means the ROWS ARE MISSING — a data-class defect
        (the numbers are wrong), not a cosmetic gap. Record it as --class data (which
        blocks the gate unconditionally) and FIX the data path.
        PRODUCT FACT: Sigma's export endpoints DO execute live warehouse queries. An
        empty export is empty DATA — never "the export doesn't run queries." (Field-
        proven 2026-07: that exact false theory laundered a dataless dashboard to GREEN.)
        Only if you can PROVE the element export returns rows while the RENDER is blank
        (a real platform-render artifact) may you keep this class — attach the proof:
          --probe <workdir>/render-vs-export-<element>.json   (must exist and be non-empty)
      MSG
    end
  end
  cls = opts[:cls] == 'ui-only' ? 'sigma-capability' : opts[:cls]
  if cls == 'sigma-capability'
    valid = FidelityLoop.catalog_ids
    unless opts[:catalog_id] && valid.include?(opts[:catalog_id])
      problem = opts[:catalog_id] ? "unknown catalog id #{opts[:catalog_id].inspect}" : 'missing --catalog-id'
      die <<~MSG, 6
        --class #{opts[:cls]} REJECTED: #{problem}.
        A sigma-capability / ui-only delta is a platform difference ONLY when it matches an entry in
        the shipped catalog refs/sigma-platform-differences.json. Valid ids: #{valid.empty? ? '(catalog unreadable)' : valid.join(', ')}
        If none fits it is fixable: record it as --class spec-fixable and fix it.
      MSG
    end
    entry = FidelityLoop.catalog_entry(opts[:catalog_id])
    rubric = FidelityLoop.rubric_dimension(opts[:dim])
    if entry && rubric && rubric != entry['dimension'].to_s
      die <<~MSG, 6
        --catalog-id #{opts[:catalog_id].inspect} REJECTED: it describes the #{entry['dimension']} dimension
        (#{entry['description']}) but --dimension #{opts[:dim].inspect} is the #{rubric} dimension.
        A platform difference must sit on the dimension its catalog entry describes: fix --dimension,
        pick the catalog id that matches this delta, or record it as --class spec-fixable.
      MSG
    elsif entry && rubric.nil?
      puts "[NOTE] --dimension #{opts[:dim].inspect} is free-form; catalog entry #{opts[:catalog_id].inspect} is on " \
           "#{entry['dimension']}: #{entry['description']}"
    end
  end
  ledger = load_ledger(opts[:dir])
  e = FidelityLoop.add_entry(ledger, dimension: opts[:dim], delta: opts[:delta],
                             cls: cls, fix: opts[:fix], resolved: !!opts[:resolved],
                             evidence: opts[:probe], catalog_id: cls == 'sigma-capability' ? opts[:catalog_id] : nil)
  save_ledger(opts[:dir], ledger)
  puts "[OK] recorded #{e['id']} pass=#{e['pass']} [#{e['cls']}] #{e['dimension']}: #{e['delta']}"
  puts "     (spec-fixable + unresolved → blocks the gate until apply-patch/resolve)" if e['cls'] == 'spec-fixable' && !e['resolved']
  if e['cls'] == 'data' && !e['resolved']
    puts '     (data-class = the NUMBERS are wrong → blocks the gate unconditionally; no'
    puts '      --accept-residuals waiver exists. Fix + resolve, or reclassify with evidence.)'
  end

when 'resolve'
  ledger = load_ledger(opts[:dir])
  entries = ledger['entries'] || []
  targets =
    if opts[:entry]
      [entries[opts[:entry]]].compact
    elsif opts[:dim]
      entries.select { |x| x['dimension'] == opts[:dim] }
    else
      die '--entry N or --dimension D required'
    end
  die 'no matching ledger entry', 2 if targets.empty?
  targets.each { |x| x['resolved'] = true }
  save_ledger(opts[:dir], ledger)
  puts "[OK] resolved #{targets.length} entr#{targets.length == 1 ? 'y' : 'ies'}"

when 'apply-patch'
  ledger = load_ledger(opts[:dir])
  require_relative 'lib/rcf_revert'
  # Re-applying a patch this workdir ALREADY applied (a pass-1 re-run reverted
  # it) is not a new repair: allowed past an exhausted render or wall budget.
  reapply = opts[:patch] && File.file?(opts[:patch]) && RcfRevert.applied_sha?(opts[:dir], File.read(opts[:patch]))
  budget_ledger = reapply ? nil : ledger
  begin
    RepairState.check_budget!(budget_ledger) if budget_ledger && !opts[:dry]
  rescue RepairState::Error => error
    die budget_message(error, ledger, opts[:dir]), 3
  end
  if File.exist?(exhausted_path(opts[:dir])) && !reapply
    die "RCF pass budget is exhausted (#{ledger['pass']}/#{ledger['max_passes']}); " \
        "#{EXHAUSTED_NAME} blocks further patches. Record residuals and stop.", 3
  end
  puts '[OK] re-applying a recorded RCF patch (reverted by a pass-1 re-run) — not a new repair' if reapply
  wb = ledger['workbook_id']
  die '--patch or --full-spec required' unless opts[:patch] || opts[:full]

  merged =
    if opts[:full]
      JSON.parse(File.read(opts[:full]))
    else
      begin
        patch = FidelityLoop.normalize_patch(JSON.parse(File.read(opts[:patch])))
      rescue ArgumentError, JSON::ParserError => e
        die "patch #{opts[:patch]} rejected: #{e.message}", 4
      end
      # GET the FULL live spec (or --live-spec in dry-run) and deep-merge the
      # patch into it so the layout — part of that spec — is carried through the
      # PUT untouched. This is the single-PUT that avoids the PUT-wipes-layout trap.
      live =
        if opts[:dry]
          die '--dry-run needs --live-spec', 2 unless opts[:live]
          JSON.parse(File.read(opts[:live]))
        else
          require_relative 'lib/sigma_rest'
          body = request_with_budget(budget_ledger, :get, Sigma::CodeRep.read_path(wb))
          # The contents GET defaults to JSON (parsed by Sigma.request); keep a
          # String fallback for a stubbed/YAML body.
          if body.is_a?(Hash)
            body
          else
            begin
              JSON.parse(body.to_s)
            rescue JSON::ParserError
              require 'yaml'; require 'date'
              YAML.safe_load(body.to_s, permitted_classes: [Date, Time]) || {}
            end
          end
        end
      # Workbook code-rep GETs carry flat document.elements. Keep that canonical
      # flat shape while merging a partial fidelity patch: converting the live
      # spec to pages[].elements first would make a flat patch.elements array a
      # second namespace, and canonicalize() would let those partial records
      # (id/style but no kind) shadow the complete page-owned records.
      canonical_live = WorkbookCode.canonicalize(live)
      live = WorkbookCode.metadata(canonical_live).merge(WorkbookCode.document(canonical_live))
      live[WorkbookCode::LEGACY_DOCUMENT_KEY] = WorkbookCode.document(canonical_live)
      live[WorkbookCode::LEGACY_METADATA_KEY] = WorkbookCode.metadata(canonical_live)
      unless live['pages'].is_a?(Array) && live['pages'].any?
        die 'live spec has no `pages` — refusing to PUT a spec that would blank the workbook', 4
      end
      foreign = FidelityLoop.foreign_patch_keys(patch, WorkbookCode.document(canonical_live).keys)
      if foreign.any?
        die "patch key(s) #{foreign.join(', ')} are not workbook document keys — the PUT sends only " \
            "the document, so they would be silently dropped. Patch document keys " \
            "(#{Sigma::CodeRep::DOC_KEYS.join('/')}), flat or wrapped in {\"document\": {...}}.", 4
      end
      FidelityLoop.deep_merge(live, patch)
    end

  # RCF transforms still use a transient page-assigned view. Every artifact and
  # PUT crosses back through the release representation: metadata outside,
  # flat document.elements, metadata-only pages, and authoritative layout.
  merged = WorkbookCode.legacy_view(WorkbookCode.canonicalize(merged))
  die 'merged spec has no `pages`', 4 unless merged['pages'].is_a?(Array) && merged['pages'].any?
  if patch
    # Every patched leaf must survive the canonical round-trip, or the PUT
    # would report OK with the fix silently gone.
    dropped = FidelityLoop.unlanded_paths(patch, WorkbookCode.document(WorkbookCode.canonicalize(merged)))
    die "patch path(s) would not reach the PUT body: #{dropped.join(', ')} — nothing written", 4 if dropped.any?
  end

  # Plan C R7: a patch / full spec must not widen a pivot's uniform widths past its cell (Sigma then
  # discards ALL widths) nor put a squeezed pivot on illegible cellSpacing. Rejected before any PUT.
  # Baseline: the live spec on the --patch path; for --full-spec, --live-spec else <workdir>/wb-spec.json.
  require_relative 'lib/pivot_patch_guard'
  guard_base =
    if patch && live then live
    elsif opts[:live] then (JSON.parse(File.read(opts[:live])) rescue nil)
    else (JSON.parse(File.read(File.join(opts[:dir], 'wb-spec.json'))) rescue nil)
    end
  if guard_base
    pivot_errors = PivotPatchGuard.check(guard_base, merged, dir: opts[:dir])
    die "patch rejected (pivot widths): #{pivot_errors.join(' | ')}", 4 if pivot_errors.any?
  elsif PivotPatchGuard.pivots(merged).values.any? { |e| PivotPatchGuard.width(e, 'bodyWidths') }
    warn 'WARN: pivot width guard not applied: no baseline spec (no --live-spec, no wb-spec.json) and the ' \
         'value-column count is not derivable from the spec; check pivot widths fit the cell (n_hdr x header + ' \
         'value cols x body <= cell - 8) or Sigma discards them all.'
  end

  # v5.1.1: the SAME style contract post-and-readback enforces (pivot totals,
  # format grammar, scheme defaults) — a fidelity patch PUT was the one write
  # path that bypassed it (review-caught), so a patch could silently
  # reintroduce what style-normalize had repaired. --skip-style-normalize
  # waives (named), matching the post-and-readback flag.
  if opts[:skip_style_normalize]
    warn "WARN: style-normalize SKIPPED (--skip-style-normalize: #{opts[:skip_style_normalize]}) — quality waiver."
    # PR-14: every honored --skip-* leaves a record on the off-ramp trail.
    begin
      require_relative 'lib/offramp'
      Offramp.log(opts[:dir], kind: 'skip-flag-waived', reason: opts[:skip_style_normalize],
                  detail: '--skip-style-normalize')
    rescue LoadError
      warn 'WARN: lib/offramp.rb not vendored — the waiver could not be recorded to offramps.jsonl.'
    end
  else
    begin
      require_relative 'lib/style_normalize'
      changes = StyleNormalize.normalize!(merged)
      if changes.any?
        File.write(File.join(opts[:dir], 'style-normalize.json'), JSON.pretty_generate(changes)) rescue nil
        puts "style-normalize: #{changes.size} change(s) applied (#{changes.map { |c| c['rule'] }.uniq.join(', ')}) — style-normalize.json"
      end
    rescue LoadError
      warn 'WARN: lib/style_normalize unavailable — patch PUT proceeds un-normalized.'
    end
  end

  if opts[:dry]
    out = opts[:out] || File.join(opts[:dir], 'rcf-merged-spec.json')
    File.write(out, JSON.pretty_generate(WorkbookCode.canonicalize(merged)))
    puts "[DRY] merged spec → #{out} (no PUT, no lint)"
    persist_patch_to_wb_spec(opts[:dir], patch) if opts[:patch] && patch
  else
    require_relative 'lib/sigma_rest'
    layout_was = merged['layout'].to_s
    # One load, shared by the pre-PUT and post-patch control lints so an
    # intentionally narrow control-scope.json is honored in both.
    control_scope = (JSON.parse(File.read(File.join(opts[:dir], 'control-scope.json'))) rescue nil)
    begin
      put_body = WorkbookCode.canonicalize(merged)
      shape_errors = WorkbookCode.validate(put_body)
      die "merged workbook code representation is invalid: #{shape_errors.join('; ')}", 4 if shape_errors.any?
      require_relative 'lib/layout_lint'
      require_relative 'lib/control_lint'
      preflight_errors = LayoutLint.lint(put_body) + ControlLint.lint(put_body, scope: control_scope)
      die "repair preflight failed before any PUT: #{preflight_errors.join('; ')}", 4 if preflight_errors.any?
      # A local checkpoint precedes every repair write. Never let an unknown
      # write outcome leave a previously passing completion marker authoritative.
      before = request_with_budget(budget_ledger, :get, Sigma::CodeRep.read_path(wb))
      base_spec = live || merged
      old_version = base_spec['latestDocumentVersion'] || base_spec['latestVersion'] || base_spec['documentVersion']
      current_version = before['latestDocumentVersion'] || before['latestVersion'] || before['documentVersion']
      die 'repair base spec has no version; obtain a fresh version-bound readback before writing', 4 if old_version.to_s.empty?
      die 'workbook changed while preparing repair; rebase the patch on fresh readback', 4 if old_version.to_s != current_version.to_s
      die 'repair base version must be an integer', 4 unless old_version.to_s.match?(/\A\d+\z/)
      RepairState.check_budget!(budget_ledger) if budget_ledger
      checkpoint = RepairState.checkpoint(opts[:dir], wb, before)
      RepairState.begin_write(opts[:dir], checkpoint)
      written = request_with_budget(budget_ledger, :put, Sigma::CodeRep.update_path(wb), body: JSON.generate(
        Sigma::CodeRep.update_body(WorkbookCode.document(put_body), document_version: old_version.to_i)))
      written_version = written['latestDocumentVersion'] || written['latestVersion'] || written['documentVersion'] if written.is_a?(Hash)
    rescue StandardError => e
      msg = e.is_a?(RepairState::Error) ? budget_message(e, ledger, opts[:dir]) : e.message
      die "repair did not complete: #{msg}. If repair-pending.json exists, reconcile via recover before continuing.", 4
    end
    puts "[OK] PUT merged spec to #{wb} (layout preserved: #{layout_was.empty? ? 'NONE' : "#{layout_was.scan(/<Element\b/).length} elements"})"
    # Persist BEFORE the post-PUT guards: the fix is live either way, and an
    # exit-5 guard failure must not leave wb-spec.json behind the live state.
    persist_patch_to_wb_spec(opts[:dir], nil, live_spec: put_body)

    spec = request_with_budget(budget_ledger, :get, Sigma::CodeRep.read_path(wb))
    readback_version = spec['latestDocumentVersion'] || spec['latestVersion'] || spec['documentVersion']
    if readback_version.to_s.empty? || readback_version.to_s == old_version.to_s ||
       (!written_version && readback_version.to_s != (old_version.to_i + 1).to_s) ||
       (written_version && readback_version.to_s != written_version.to_s)
      die 'repair readback version is missing, stale, or changed by another writer; recover and reverify', 4
    end
    # Capture our bound candidate even if a subsequent column/layout guard fails.
    # A later user's version is never eligible for this repair's rollback.
    RepairState.record_candidate(checkpoint, WorkbookCode.canonicalize(spec))
    bound_document = WorkbookCode.document(spec)
    unlanded = patch ? FidelityLoop.unlanded_paths(patch, bound_document) : []

    # Re-run the same guards post-and-readback runs on the initial POST.
    # PAGINATED: re-runs the same error-column guard post-and-readback runs on the
    # initial POST, so it needs the same exhaustive read — otherwise a wide
    # workbook's error columns past 50 pass this guard too.
    cols = (with_optional_budget(budget_ledger) { Sigma.list_entries("/v2/workbooks/#{wb}/columns") } rescue nil)
    # A nil read means the guard never ran. Track it so the success message below
    # cannot claim "no type=error columns" on a check that did not happen — the
    # same hardening post-and-readback.rb applies to its census.
    cols_unread = cols.nil?
    err = (cols || []).select { |c| c.dig('type', 'type') == 'error' }
    if err.any?
      warn "[FAIL] column-type guard: #{err.length} column(s) compiled to type=error after the patch:"
      err.first(10).each { |c| warn "         element=#{c['elementId']} col=#{c['columnId']} #{c['formula']}" }
      exit 5
    elsif cols_unread
      die 'column-type guard: live columns could not be read; repair remains unverified', 5
    end
    # Same nested-`document` unwrap as the live GET above — the post-patch
    # lints below need flat `pages`/`layout`.
    spec = Sigma::CodeRep.metadata(spec).merge(Sigma::CodeRep.document(spec))
    combo_errors = WorkbookCode.combo_readback_errors(put_body, spec)
    die "combo chart readback changed source bindings: #{combo_errors.join('; ')}", 5 if combo_errors.any?
    lint_fail = false
    begin
      require_relative 'lib/layout_lint'
      v = LayoutLint.lint(spec)
      if v.any?
        warn "[FAIL] layout lint after patch: #{v.length} violation(s):"; v.each { |x| warn "         - #{x}" }
        lint_fail = true
      end
    rescue LoadError; end
    begin
      require_relative 'lib/control_lint'
      v = ControlLint.lint(spec, scope: control_scope)
      if v.any?
        warn "[FAIL] control lint after patch: #{v.length} violation(s):"; v.each { |x| warn "         - #{x}" }
        lint_fail = true
      end
    rescue LoadError; end
    exit 5 if lint_fail
    final_readback = request_with_budget(budget_ledger, :get, Sigma::CodeRep.read_path(wb))
    unless WorkbookCode.document(final_readback) == bound_document &&
           (final_readback['latestDocumentVersion'] || final_readback['latestVersion'] || final_readback['documentVersion']).to_s == readback_version.to_s
      die 'workbook changed during post-write guards; pending repair retained', 4
    end
    RepairState.check_budget!(budget_ledger) if budget_ledger
    prior_plan = (JSON.parse(File.read(File.join(opts[:dir], 'parity-plan.json'))) rescue nil)
    RepairState.invalidate(opts[:dir], checkpoint)
    puts "[OK] previous version preserved at #{checkpoint}; prior verification must be recollected"
    # parity-plan.json is a derived plan (not pass evidence): rebuild it against
    # the patched workbook so --finalize is not left without one.
    if prior_plan
      plan_ok, plan_cmd = RepairState.regen_parity_plan(opts[:dir], wb, prior_plan,
                                                        script: File.join(HERE, 'phase6-parity.rb'))
      if plan_ok
        puts "[OK] parity-plan.json regenerated for the patched workbook (prior plan + operator waives archived under #{File.join(checkpoint, 'prior-evidence')}; re-apply waives if needed, then re-collect actuals)"
      else
        warn '[WARN] parity-plan.json was archived by the patch and could NOT be regenerated automatically. Run, then re-collect actuals:'
        warn "         #{plan_cmd}"
      end
    end
    puts '[OK] post-patch guards clean (no type=error columns; layout + control lint pass)'
    if unlanded.any?
      # The write is complete and verified as a version, but the fix is not in
      # it: leave the ledger entries unresolved so the gate keeps blocking.
      warn "[FAIL] #{unlanded.length} patched path(s) absent from the live readback — the fix did not land:"
      unlanded.first(20).each { |x| warn "         - #{x}" }
      warn '       --resolves NOT applied. Re-author the patch against the readback shape (Sigma may also'
      warn '       drop a value equal to its default — then record the delta with that evidence).'
      exit 5
    end
    # Saved verbatim so a later pass-1 re-run (which re-PUTs the rebuilt spec)
    # can reopen the entries it resolved and print the exact re-apply command.
    if opts[:patch] && !reapply
      rec = RcfRevert.record_patch!(opts[:dir], File.read(opts[:patch]), resolves: opts[:resolves],
                                    document_version: readback_version)
      puts "[OK] patch recorded for re-apply → #{rec['path']}"
    end
  end

  # Mark resolved entries (safe in dry-run too, so tests exercise the codepath).
  if opts[:resolves]
    entries = ledger['entries'] || []
    opts[:resolves].each do |ref|
      idx = (ref =~ /\A\d+\z/ ? ref.to_i : entries.index { |x| x['id'] == ref })
      entries[idx]['resolved'] = true if idx && entries[idx]
    end
    save_ledger(opts[:dir], ledger)
    puts "[OK] marked resolved: #{opts[:resolves].join(', ')}"
  end

when 'rollback'
  die 'rollback requires --checkpoint and does not support --dry-run' unless opts[:checkpoint] && !opts[:dry]
  ledger = load_ledger(opts[:dir])
  require_relative 'lib/sigma_rest'
  # Hybrid route: the rollback candidate must be the CURRENT live state of the
  # session's own recorded writes (it is otherwise only written by sdk-export).
  sdk_open = SdkRoute.open_session(ledger)
  if sdk_open && sdk_open['checkpoint'] == opts[:checkpoint]
    live = Sigma.request(:get, Sigma::CodeRep.read_path(ledger.fetch('workbook_id')))
    unless doc_version(live) == SdkRoute.expected_live_version(sdk_open)
      die "live document version #{doc_version(live).inspect} != #{SdkRoute.expected_live_version(sdk_open)} (the last " \
          'recorded SDK write) — record the unrecorded write with sdk-write first; rollback only undoes recorded writes', 4
    end
    sdk_replace_candidate(sdk_checkpoint_dir(opts[:dir], sdk_open), WorkbookCode.canonicalize(live))
  end
  begin
    RepairState.rollback(opts[:dir], ledger.fetch('workbook_id'), opts[:checkpoint], request: Sigma.method(:request))
  rescue StandardError => error
    die "rollback failed: #{error.message}", 4
  end
  puts '[OK] checkpoint restored as a new workbook version; local spec and unresolved entries restored. Recollect all verification.'
  # Hybrid route: rolling back an SDK session's checkpoint closes that session.
  ledger = load_ledger(opts[:dir])
  last = SdkRoute.last_session(ledger)
  if last && last['checkpoint'] == opts[:checkpoint]
    last['rolled_back_at'] = SdkRoute.now
    ledger['sdk']['state'] = 'rolled-back'
    save_ledger(opts[:dir], ledger)
    puts "[OK] SDK session #{last['id']} rolled back — its writes are undone; re-open a session to fix again."
  end

when 'recover'
  begin
    RepairState.recover(opts[:dir])
  rescue StandardError => error
    die "repair recovery failed: #{error.message}", 4
  end
  puts '[OK] incomplete repair evidence archived. Live state has NOT been restored or certified; read it back and reverify.'
  # Hybrid route: recovering an open SDK session's marker closes that session
  # WITHOUT an export — finalize stays blocked until a new session exports.
  ledger = (JSON.parse(File.read(ledger_path(opts[:dir]))) rescue nil)
  if ledger.is_a?(Hash) && (session = SdkRoute.open_session(ledger))
    session['reconciled_at'] = SdkRoute.now
    ledger['sdk']['state'] = 'reconciled'
    save_ledger(opts[:dir], ledger)
    warn "[NOTE] SDK session #{session['id']} reconciled without an export; open a new session (sdk-begin) and sdk-export it before --finalize."
  end

when 'extend'
  ledger = load_ledger(opts[:dir])
  die 'extend requires --max-passes, --max-seconds, --reason and --approved-by after actual user approval' unless
    opts[:max] && opts[:max_seconds] && !opts[:reason].to_s.strip.empty? && !opts[:approved_by].to_s.strip.empty?
  die 'extension must increase both budgets' unless opts[:max] > ledger['max_passes'].to_i && opts[:max_seconds] > ledger['max_seconds'].to_i
  (ledger['budget_authorizations'] ||= []) << { 'at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'approved_by' => opts[:approved_by], 'reason' => opts[:reason], 'max_passes' => opts[:max], 'max_seconds' => opts[:max_seconds] }
  ledger['max_passes'], ledger['max_seconds'] = opts[:max], opts[:max_seconds]
  ledger['started_at'] ||= Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  save_ledger(opts[:dir], ledger)
  File.delete(exhausted_path(opts[:dir])) if File.exist?(exhausted_path(opts[:dir]))
  puts '[OK] attributed repair budget extension recorded; fidelity requirements unchanged.'

when 'sdk-begin'
  ledger = load_ledger(opts[:dir])
  begin
    RepairState.check_budget!(ledger)
  rescue RepairState::Error => error
    die error.message, 3
  end
  die "#{EXHAUSTED_NAME} blocks further repairs (pass budget spent); obtain an attributed `extend` first", 3 if File.exist?(exhausted_path(opts[:dir]))
  if File.exist?(pending_repair) || File.symlink?(pending_repair)
    die pending_refusal(opts[:dir], 'repair-pending.json records an unverified write outcome; recover or rollback before opening an SDK session'), 4
  end
  begin
    # Preflight every refusal before any checkpoint/marker is written.
    SdkRoute.begin_session!(deep_dup(ledger), checkpoint: 'preflight', base_version: '0', mcp_server: opts[:mcp_server])
  rescue SdkRoute::Error => error
    die error.message, 2
  end
  require_relative 'lib/sigma_rest'
  wb = ledger['workbook_id']
  live = request_with_budget(ledger, :get, Sigma::CodeRep.read_path(wb))
  base_version = doc_version(live)
  die 'live workbook has no document version; refusing an unbound SDK session', 4 if base_version.to_s.empty?
  checkpoint = RepairState.checkpoint(opts[:dir], wb, live)
  RepairState.begin_write(opts[:dir], checkpoint)
  session = SdkRoute.begin_session!(ledger, checkpoint: File.basename(checkpoint),
                                    base_version: base_version, mcp_server: opts[:mcp_server])
  save_ledger(opts[:dir], ledger)
  puts "[OK] SDK session #{session['id']} open on #{wb} at document version #{base_version} " \
       "(checkpoint #{File.basename(checkpoint)}; repair-pending.json now blocks render/apply-patch/completion)."
  puts '     Before writing, read refs/sdk-gotchas.md. After EVERY build_workbook call:'
  puts "       ruby scripts/fidelity-loop.rb sdk-write --workdir #{opts[:dir]} --program prog.py --result out.txt \\"
  puts '         --summary "<what changed>" [--claims e0,e2] [--status failed --error "<message>"]'
  puts "     When the page matches: ruby scripts/fidelity-loop.rb sdk-export --workdir #{opts[:dir]}"

when 'sdk-write'
  ledger = load_ledger(opts[:dir])
  session = SdkRoute.open_session(ledger) or die SdkRoute.closed_session_message(ledger), 2
  sdk_pending_matches!(opts[:dir], session, ledger)
  # The build_workbook call has already run: past the repair clock the write is
  # still RECORDED (an unrecorded write is drift), then the command exits 3 and
  # sdk-export refuses until an attributed `extend` (or the session is rolled back).
  over_budget = begin
    RepairState.check_budget!(ledger)
    nil
  rescue RepairState::Error => error
    error.message
  end
  status = opts[:sdk_status] || 'ok'
  die '--program FILE required (the Code Mode program sent to build_workbook)', 2 unless opts[:program]
  begin
    SdkRoute.add_write!(deep_dup(ledger), status: status, summary: opts[:summary], program_sha256: 'preflight',
                        program_path: 'preflight', document_version: '0', claims: opts[:claims] || [], error: opts[:error])
  rescue SdkRoute::Error => error
    die error.message, 2
  end
  die '--status failed requires --error "<the failure message>"', 2 if status == 'failed' && opts[:error].to_s.strip.empty?
  require_relative 'lib/sigma_rest'
  live = if over_budget
           Sigma.request(:get, Sigma::CodeRep.read_path(ledger['workbook_id']))
         else
           request_with_budget(ledger, :get, Sigma::CodeRep.read_path(ledger['workbook_id']))
         end
  version = doc_version(live)
  die 'live workbook has no document version after the write; re-run sdk-write once the read succeeds', 4 if version.to_s.empty?
  write_dir = File.join(opts[:dir], 'sdk-writes', "#{session['id']}-w#{session['writes'].length + 1}")
  die "#{write_dir} already exists — refusing to overwrite recorded SDK evidence", 2 if File.exist?(write_dir) || File.symlink?(write_dir)
  prog_path, prog_sha = sdk_keep(opts[:program], write_dir, "program#{File.extname(opts[:program])}")
  _res_path, res_sha = opts[:result] ? sdk_keep(opts[:result], write_dir, 'result.txt') : [nil, nil]
  write = SdkRoute.add_write!(ledger, status: status, summary: opts[:summary], program_sha256: prog_sha,
                              program_path: prog_path.sub("#{opts[:dir]}/", ''), result_sha256: res_sha,
                              document_version: version, claims: opts[:claims] || [], error: opts[:error],
                              over_budget: !over_budget.nil?)
  save_ledger(opts[:dir], ledger)
  puts "[OK] recorded SDK write #{session['id']}/#{write['id']} [#{status}] at document version #{version}: #{write['summary']}"
  puts "     claims #{write['claims'].join(', ')} — resolved only after sdk-export re-gates the exported spec" if write['claims'].any?
  if status == 'failed'
    warn '[REREAD] a failed SDK run can persist PARTIAL state. Re-read the page (describe / get_table with'
    warn '         model.list_tables() ids), save the output, then: fidelity-loop.rb sdk-reread --evidence FILE'
  end
  if over_budget
    warn "[STOP] #{over_budget}. The write above IS recorded, but make no further SDK writes:"
    warn '       obtain an attributed `extend` to sdk-export it, or roll the session back:'
    warn "       ruby scripts/fidelity-loop.rb rollback --workdir #{opts[:dir]} --checkpoint #{session['checkpoint']}"
    exit 3
  end

when 'sdk-reread'
  ledger = load_ledger(opts[:dir])
  session = SdkRoute.open_session(ledger) or die SdkRoute.closed_session_message(ledger), 2
  sdk_pending_matches!(opts[:dir], session, ledger)
  die '--evidence FILE required (the describe/get_table output of the re-read page)', 2 unless opts[:evidence]
  last = session['writes'].last
  die 'no failed write is awaiting a re-read', 2 unless session['needs_reread'] && last
  _path, sha = sdk_keep(opts[:evidence], File.join(opts[:dir], 'sdk-writes', "#{session['id']}-#{last['id']}"),
                        "reread-#{session['rereads'].length + 1}.txt")
  SdkRoute.add_reread!(ledger, evidence_sha256: sha)
  save_ledger(opts[:dir], ledger)
  puts "[OK] page re-read recorded after #{last['id']}; SDK writes and export are unblocked."

when 'sdk-export'
  ledger = load_ledger(opts[:dir])
  session = SdkRoute.open_session(ledger) or die SdkRoute.closed_session_message(ledger), 2
  sdk_pending_matches!(opts[:dir], session, ledger)
  begin
    RepairState.check_budget!(ledger)
  rescue RepairState::Error => error
    die error.message, 3
  end
  die 'the last SDK write failed and the page was not re-read — run sdk-reread first', 2 if session['needs_reread']
  require_relative 'lib/sigma_rest'
  require_relative 'lib/layout_lint'
  require_relative 'lib/control_lint'
  wb = ledger['workbook_id']
  live = request_with_budget(ledger, :get, Sigma::CodeRep.read_path(wb))
  live_version = doc_version(live)
  expected = SdkRoute.expected_live_version(session)
  if live_version.to_s.empty? || live_version != expected
    die "live document version #{live_version.inspect} != #{expected} (the last recorded SDK write) — an UNRECORDED " \
        'write happened in this session. Record it with sdk-write before exporting (rollback needs it recorded too).', 4
  end
  wb_spec_path = File.join(opts[:dir], 'wb-spec.json')
  prior_ids = element_ids((JSON.parse(File.read(wb_spec_path)) rescue nil))
  canonical = WorkbookCode.canonicalize(live)
  export = { 'at' => SdkRoute.now, 'document_version' => live_version, 'guards' => 'pending', 'failures' => [] }
  session['exports'] << export
  failures = WorkbookCode.validate(canonical).map { |m| "shape: #{m}" }
  sdk_replace_candidate(sdk_checkpoint_dir(opts[:dir], session), canonical)
  # The exported live spec becomes the authoritative local code representation.
  persist_patch_to_wb_spec(opts[:dir], nil, live_spec: live)
  export['wb_spec_sha256'] = Digest::SHA256.file(wb_spec_path).hexdigest
  new_ids = element_ids(canonical)
  export['elements_added'] = new_ids - prior_ids
  export['elements_removed'] = prior_ids - new_ids
  # Column-type guard (paginated; an unread column list fails closed).
  cols = (RepairState.with_budget(ledger) { Sigma.list_entries("/v2/workbooks/#{wb}/columns") } rescue nil)
  if cols.nil?
    failures << 'columns: live columns could not be read — the column-type guard did not run'
  else
    cols.select { |c| c.dig('type', 'type') == 'error' }.first(10).each do |c|
      failures << "columns: element=#{c['elementId']} col=#{c['columnId']} compiled to type=error #{c['formula']}"
    end
  end
  flat = Sigma::CodeRep.metadata(live).merge(Sigma::CodeRep.document(live))
  LayoutLint.lint(flat).each { |v| failures << "layout-lint: #{v}" }
  ControlLint.lint(flat, scope: load_control_scope(opts[:dir])).each { |v| failures << "control-lint: #{v}" }
  after = request_with_budget(ledger, :get, Sigma::CodeRep.read_path(wb))
  unless doc_version(after) == live_version && Sigma::CodeRep.document(after) == Sigma::CodeRep.document(live)
    failures << "version: the workbook changed during the export guards (#{live_version} → #{doc_version(after)})"
  end
  if failures.any?
    export['guards'] = 'fail'
    export['failures'] = failures
    ledger['sdk']['state'] = 'export-failed'
    save_ledger(opts[:dir], ledger)
    warn "[FAIL] sdk-export guards failed on document version #{live_version} (#{failures.length}):"
    failures.each { |f| warn "         - #{f}" }
    warn '       The session stays OPEN (repair-pending.json kept). Fix via SDK writes (sdk-write each),'
    warn '       then sdk-export again — or restore the pre-session workbook:'
    warn "       ruby scripts/fidelity-loop.rb rollback --workdir #{opts[:dir]} --checkpoint #{session['checkpoint']}"
    exit 5
  end
  export['guards'] = 'pass'
  # Guards clean: close the session. Prior parity / render / blind-grade /
  # completion evidence is archived — it described an older document.
  RepairState.invalidate(opts[:dir], sdk_checkpoint_dir(opts[:dir], session))
  # Re-hold the marker at once: parity-unverified is an OPEN state, and the
  # parity step below is a long subprocess. sdk_finish_parity releases it on a
  # pass or a divergence.
  RepairState.begin_write(opts[:dir], sdk_checkpoint_dir(opts[:dir], session))
  File.write(File.join(opts[:dir], 'wb-readback.json'), JSON.pretty_generate(live))
  resolved = SdkRoute.resolve_claims!(ledger, session)
  export['resolved'] = resolved
  ledger['sdk']['state'] = 'parity-unverified' # until the parity step below records its result
  save_ledger(opts[:dir], ledger)
  puts "[OK] exported document version #{live_version} → #{wb_spec_path} " \
       "(#{session['writes'].length} SDK write(s); +#{export['elements_added'].length}/-#{export['elements_removed'].length} elements)"
  puts '[OK] export guards clean (shape, no type=error columns, layout + control lint, version stable)'
  puts "[OK] resolved via SDK: #{resolved.empty? ? '(none claimed)' : resolved.join(', ')}"
  # invalidate() archived parity-plan.json, so pass 1 always rebuilds the plan
  # from the exported spec (the same as after a REST apply-patch).
  sdk_finish_parity(opts[:dir], ledger, session, sdk_parity(opts[:dir], wb))

when 'sdk-regate'
  ledger = load_ledger(opts[:dir])
  st = SdkRoute.state(ledger)
  die "sdk-regate needs an exported SDK session (state is #{st.inspect})", 2 unless %w[exported parity-failed parity-unverified].include?(st)
  session = SdkRoute.last_session(ledger)
  sdk_pending_matches!(opts[:dir], session, ledger) if st == 'parity-unverified'
  export = Array(session['exports']).last
  die 'the last SDK export did not pass its guards', 2 unless export && export['guards'] == 'pass'
  require_relative 'lib/sigma_rest'
  wb = ledger['workbook_id']
  live = Sigma.request(:get, Sigma::CodeRep.read_path(wb))
  unless doc_version(live) == export['document_version'].to_s
    die "the workbook changed since the SDK export (#{export['document_version']} → #{doc_version(live)}); " \
        'open a new SDK session and export again', 4
  end
  sdk_finish_parity(opts[:dir], ledger, session, sdk_parity(opts[:dir], wb, actuals: opts[:actuals]))

when 'status'
  ledger = load_ledger(opts[:dir])
  entries = ledger['entries'] || []
  by_class = entries.group_by { |e| e['cls'] }
  puts "fidelity-ledger.json — workbook #{ledger['workbook_id']} page #{ledger['page_id']}"
  puts "  passes run: #{ledger['pass']}/#{ledger['max_passes']}   entries: #{entries.length}"
  puts "  elapsed-time budget: #{ledger['max_seconds']} seconds from #{ledger['started_at']}" if ledger['max_seconds'] && ledger['started_at']
  FidelityLoop::CLASSES.each do |c|
    grp = by_class[c] || []
    next if grp.empty?
    unresolved = grp.count { |e| !e['resolved'] }
    puts "  #{c}: #{grp.length} (#{unresolved} unresolved)"
  end
  if ledger['sdk'].is_a?(Hash)
    sdk_last = SdkRoute.last_session(ledger) || {}
    sdk_export = Array(sdk_last['exports']).last
    puts "  route: sdk — state #{SdkRoute.state(ledger)}, #{SdkRoute.sessions(ledger).length} session(s), " \
         "#{Array(sdk_last['writes']).length} write(s) in #{sdk_last['id'] || '-'}" \
         "#{sdk_export ? ", last export v#{sdk_export['document_version']} guards=#{sdk_export['guards']} parity=#{sdk_export['parity'] || '-'}" : ''}"
  end
  sdk_block = SdkRoute.finalize_block_reason(ledger)
  # An exported SDK route is only current while the live workbook is still the
  # exported version — the same check --finalize makes (live proof, edge 2).
  if sdk_block.nil? && SdkRoute.state(ledger) == 'exported'
    read_error = nil
    live_version = if ledger['workbook_id'].to_s.empty?
                     read_error = 'the ledger has no workbook_id'
                     nil
                   else
                     begin
                       require_relative 'lib/sigma_rest'
                       doc_version(Sigma.request(:get, Sigma::CodeRep.read_path(ledger['workbook_id'])))
                     rescue StandardError, SystemExit => error
                       read_error = "#{error.class}: #{error.message.to_s.lines.first.to_s.strip}"[0, 200]
                       nil
                     end
                   end
    sdk_block = SdkRoute.live_version_block_reason(ledger, live_version)
    sdk_block = "#{sdk_block} (#{read_error}; check Sigma auth/network and re-run status)" if sdk_block && read_error
  end
  blocking = FidelityLoop.unresolved_specfixable(ledger, opts[:accept] || [])
  data_blocking = FidelityLoop.unresolved_data(ledger)
  spent = FidelityLoop.budget_spent?(ledger, opts[:dir])
  visual = begin
    FidelityLoop.visual_gaps(opts[:dir])
  rescue ArgumentError => e
    warn "WARN: #{e.message} - visual residuals ignored for status"
    []
  end
  if blocking.empty? && data_blocking.empty? && sdk_block.nil?
    divergent = FidelityLoop.visual_verdict(opts[:dir])['faithful'] == false
    if spent && (visual.any? || divergent)
      puts "[OK] YELLOW-ready: fix budget spent; #{visual.any? ? "#{visual.length} visual residual(s) remain (visual-residuals.json)" : 'the blind grade is unfaithful (visual-divergent)'} — they ship as YELLOW fidelity-residuals."
    else
      puts '[OK] no unresolved spec-fixable or data-class deltas — RCF ledger satisfies the gate.'
      polish = FidelityLoop.polish_notes(opts[:dir])
      if polish.any?
        # status sees only the RCF ledger: say GREEN only when the derived
        # degradation ledger and the report-level forfeits are empty too.
        derived = (DegradationLedger.derive(opts[:dir]) rescue nil)
        green = derived && DegradationLedger.verdict(derived) == 'GREEN' && FidelityLoop.report_blockers(opts[:dir]).empty?
        n = "#{polish.length} note#{polish.length == 1 ? '' : 's'}"
        puts(green ? "     GREEN, optional polish: #{n} (minor gaps on a passing blind grade; not degradations)."
                   : "     #{n.sub('note', 'polish note')} (minor gaps on a passing blind grade; not degradations) — the run is not GREEN for other reasons; see the degradation ledger / migration report.")
      end
    end
    exit 0
  elsif data_blocking.empty? && sdk_block.nil? && spent
    puts "[OK] YELLOW-ready: fix budget spent (#{ledger['pass']}/#{ledger['max_passes']} pass(es)); #{blocking.length} unresolved spec-fixable delta(s) no longer block (gate 8d) — they ship as YELLOW fidelity-residuals:"
    blocking.each do |i|
      e = entries[i]
      puts "         #{e['id']} [#{e['dimension']}] #{e['delta']}"
    end
    exit 0
  else
    warn "[BLOCK] SDK route: #{sdk_block}" if sdk_block
    if data_blocking.any?
      warn "[BLOCK] #{data_blocking.length} unresolved DATA-class delta(s) — the numbers are wrong:"
      data_blocking.each do |i|
        e = entries[i]
        warn "         #{e['id']} [#{e['dimension']}] #{e['delta']}"
      end
      warn '       data-class residuals can never be waved through (--accept-residuals does not apply).'
      warn '       Fix + resolve, or reclassify with evidence.'
    end
    if blocking.any?
      warn "[BLOCK] #{blocking.length} unresolved spec-fixable delta(s) remain:"
      blocking.each do |i|
        e = entries[i]
        warn "         #{e['id']} [#{e['dimension']}] #{e['delta']}  (fix: #{e['fix'] || 'see refs/fidelity-recipes.md'})"
      end
      warn '       apply-patch/resolve them, or waive with --accept-residuals <id,id> and NAME them in the report.'
    end
    exit 6
  end

when 'green-offer'
  ledger = load_ledger(opts[:dir])
  visual = begin
    FidelityLoop.visual_gaps(opts[:dir])
  rescue ArgumentError => e
    die "green-offer: #{e.message}", 2
  end
  derived = begin
    DegradationLedger.derive(opts[:dir])
  rescue StandardError => e
    die "green-offer: could not derive the degradation ledger (#{e.message})", 2
  end
  sec = begin
    JSON.parse(File.read(File.join(opts[:dir], 'security-decision.json')))
  rescue StandardError
    nil
  end
  puts JSON.pretty_generate(FidelityLoop.green_offer(
                              ledger, visual, derived: derived, accepted: opts[:accept] || [],
                              verdict: FidelityLoop.visual_verdict(opts[:dir]),
                              security_skip: sec.is_a?(Hash) && sec['decision'] == 'skip',
                              polish: FidelityLoop.polish_notes(opts[:dir]),
                              report_blockers: FidelityLoop.report_blockers(opts[:dir])))

else
  warn "usage: fidelity-loop.rb {init|render|record|resolve|apply-patch|recover|extend|status|green-offer} --workdir DIR ..."
  warn '(run with no subcommand shows this; see the file header for full flags)'
  exit 2
end
