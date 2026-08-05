#!/usr/bin/env bash
# objectmodel-noodle — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. scan-workbook-gaps.rb on the ADVERSE-orientation workbook: the noodle
#      shape is DETECTED (no more reassuring "Datasources: 1" silence), the
#      fully-wired graph lands in ✅ Fully auto-translated (a wired noodle
#      must NOT stop — false-trip budget), and object-graph-plan.json names
#      FACT_VISITS the degree-based fact candidate with all 4 edges wired.
#   2. scan-workbook-gaps.rb on the NO-KEYS workbook: the disconnected-tables
#      outcome is a ❌ Not-yet-handled row (drives migrate-tableau's exit-11
#      stop, same rigor as multi-datasource) with the per-pair punch list and
#      the patch-then-reenter route (--reuse-dm, never hand-POST).
#   3. (node present only) the vendored converter reconverts both goldens
#      byte-identically after id normalization — pinning fact election +
#      edge orientation onto the fact, the announced election warning, the
#      single-DS controlId dedupe, the refused cross-grain helpers, and the
#      kind:rls-entitlement-table structural detection in security[].
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"
CONVERTER="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/tableau.mjs"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the skill-script checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# -- 1. gap scan: fully-wired noodle detected, auto, plan names the fact -----
ruby "$SCRIPTS/scan-workbook-gaps.rb" "$CASE_DIR/workbook-fact-election.twb" "$TMP/gaps.md" >"$TMP/gaps.out" 2>&1 || fail=1
ruby -rjson -e '
  plan = JSON.parse(File.read(File.join(ARGV[0], "object-graph-plan.json")))
  abort "plan lacks object_model marker" unless plan["object_model"] == true
  ds = plan["datasources"]
  abort "expected 1 noodle datasource, got #{ds.length}" unless ds.length == 1
  d = ds[0]
  abort "expected 5 logical objects, got #{d["objects"].inspect}" unless d["objects"].sort == %w[DIM_DATES DIM_PROVIDERS DIM_SITES ENTITLEMENTS FACT_VISITS]
  abort "fact candidate should be FACT_VISITS (degree), got #{d["fact_candidate"].inspect}" unless d["fact_candidate"] == "FACT_VISITS"
  st = d["relationships"].map { |r| r["status"] }
  abort "all 4 edges should be wired, got #{st.inspect}" unless st == %w[wired wired wired wired]
  abort "untouched objects should be empty" unless d["untouched_objects"] == []
  gaps = JSON.parse(File.read(File.join(ARGV[0], "gaps.json")))
  abort "gaps JSON lacks object_model detail" unless gaps["object_model"].is_a?(Array) && gaps["object_model"].length == 1
' "$TMP" \
  && grep -q 'Relationship (object-model / noodle) datasource — keys serialized' "$TMP/gaps.md" \
  && ! grep -q 'disconnected tables' "$TMP/gaps.md" \
  && note "ok: wired noodle detected as ✅-auto (no stop), plan sidecar names FACT_VISITS + 4 wired edges" \
  || { note "FAIL: wired-noodle gap-scan expectations"; fail=1; }

# -- 2. gap scan: keyless noodle is a ❌ stop class with the punch list -------
ruby "$SCRIPTS/scan-workbook-gaps.rb" "$CASE_DIR/workbook-nokeys.twb" "$TMP/gaps-nokeys.md" >"$TMP/gaps-nokeys.out" 2>&1 || fail=1
ruby -rjson -e '
  plan = JSON.parse(File.read(File.join(ARGV[0], "object-graph-plan.json")))
  d = plan["datasources"][0]
  st = d["relationships"].map { |r| r["status"] }
  abort "expected 2 no-serialized-key edges, got #{st.inspect}" unless st == %w[no-serialized-key no-serialized-key]
' "$TMP" \
  && grep -q 'Object-model relationships missing serialized join keys (disconnected tables)' "$TMP/gaps-nokeys.md" \
  && grep -q 'Not yet handled' "$TMP/gaps-nokeys.md" \
  && grep -q 'reuse-dm' "$TMP/gaps-nokeys.md" \
  && note "ok: keyless noodle is a ❌ Not-yet-handled row (exit-11 class) with per-pair punch list + --reuse-dm re-entry" \
  || { note "FAIL: keyless-noodle stop expectations"; fail=1; }

# -- 3. converter goldens byte-stable (node runners only; CI may lack node) --
if command -v node >/dev/null && command -v python3 >/dev/null; then
  cat > "$TMP/conv.mjs" <<'EOF'
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [convPath, twbPath] = process.argv.slice(2);
const { convertTableauToSigma } = await import(pathToFileURL(convPath).href);
const r = convertTableauToSigma(readFileSync(twbPath, 'utf8'), { datasourceIndex: 0 });
console.log(JSON.stringify({ sigmaDataModel: r.model, stats: r.stats, warnings: r.warnings, security: r.security || [] }, null, 2));
EOF
  for pair in "workbook-fact-election.twb:data-model.json" "workbook-entitlement.twb:data-model-entitlement.json"; do
    twb="${pair%%:*}"; golden="${pair##*:}"
    if node "$TMP/conv.mjs" "$CONVERTER" "$CASE_DIR/$twb" > "$TMP/fresh.json" 2>"$TMP/conv.err" \
       && python3 "$REPO_ROOT/corpus/lib/corpus_check.py" normalize "$TMP/fresh.json" "$TMP/fresh-norm.json" >/dev/null \
       && cmp -s "$TMP/fresh-norm.json" "$CASE_DIR/golden/$golden"; then
      note "ok: $twb reconverts byte-identical to golden/$golden (fact election + orientation + RLS detection pinned)"
    else
      note "FAIL: $twb drifted from golden/$golden:"
      diff "$CASE_DIR/golden/$golden" "$TMP/fresh-norm.json" 2>/dev/null | head -15
      fail=1
    fi
  done
else
  note "skip: node not on PATH — golden reconvert diff skipped (structural check still ran)"
fi

exit "$fail"
