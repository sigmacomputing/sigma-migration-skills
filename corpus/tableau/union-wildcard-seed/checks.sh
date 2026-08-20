#!/usr/bin/env bash
# union-wildcard-seed — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. Converter↔golden lockstep (node-guarded): the vendored bundle re-run on
#      the fixture .twb, id-normalized, must byte-match golden/data-model.json.
#      Structural spec pins: elementId-based union sources; NO name on the
#      union element; bracketed friendly sourceColumns; "Union of N Sources"
#      column-formula prefix; the auto-metric attached to the UNION element
#      (factEl preference), not a member.
#   2. Refusal stopgap (node-guarded): a single-member variant of the same
#      .twb converts to ZERO elements + the loud named "NOT converted" warning
#      (silent loss is dead — W2.16's floor). Fix-pass variants join it:
#      a custom-SQL `text` member inside the root union (previously a SILENT
#      SUBSET — the union emitted from the table members alone) and the union
#      nested inside a join tree (previously silently flattened away with
#      elements still emitted) both refuse: ZERO elements + named warning.
#   3. Gap-scan class (ruby): the fixture trips the ⚠️-hint
#      "converter-emitted" row and NOT the ❌ row; the single-member,
#      text-member, and union-in-join variants trip the ❌-unhandled row;
#      a no-union workbook (param-default-controls twin case) trips neither.
#      Trip + no-false-trip, per the wave discipline.
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma"
BUNDLE="$SKILL/converter/tableau.mjs"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the gap-scan checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# Single-member (underivable) variant of the fixture, shared by checks 2 + 3.
ruby -e '
  twb = File.read(ARGV[0])
  v = twb.sub(%r{<relation connection=.snowflake\.1demo9. name=.SALES_2024.[^>]*/>\s*}, "")
  abort "variant sub failed (fixture drifted?)" if v == twb
  File.write(ARGV[1], v)
' "$CASE_DIR/workbook-content.twb" "$TMP/single-member.twb" || fail=1

# Fix-pass variants, shared by checks 2 + 3: a custom-SQL text member inside
# the root union (silent-SUBSET repro) and the union nested inside a join
# tree (silent-flatten repro).
ruby - "$CASE_DIR/workbook-content.twb" "$TMP" <<'RB' || fail=1
twb = File.read(ARGV[0])
tmp = ARGV[1]

ins = "          <relation connection='snowflake.1demo9' name='SALES_LEGACY' type='text'>SELECT ORDER_ID, NET_REVENUE, REGION_NAME FROM DEMO.SALES_LEGACY</relation>\n        </relation>"
a = twb.sub("        </relation>", ins)
abort "text-member variant sub failed (fixture drifted?)" if a == twb
File.write(File.join(tmp, "text-member.twb"), a)

join = <<~XML.gsub(/^/, "        ").chomp
  <relation join='inner' type='join'>
    <clause type='join'>
      <expression op='='>
        <expression op='[REGIONS].[REGION_NAME]' />
        <expression op='[SALES_2023+ (Union)].[REGION_NAME]' />
      </expression>
    </clause>
    <relation connection='snowflake.1demo9' name='REGIONS' table='[DEMO].[REGIONS]' type='table' />
    <relation name='SALES_2023+ (Union)' type='union'>
      <relation connection='snowflake.1demo9' name='SALES_2023' table='[DEMO].[SALES_2023]' type='table' />
      <relation connection='snowflake.1demo9' name='SALES_2024' table='[DEMO].[SALES_2024]' type='table' />
    </relation>
  </relation>
XML
b = twb.sub(%r{        <relation name='SALES_2023\+ \(Union\)' type='union'>.*?\n        </relation>}m, join)
abort "union-in-join variant sub failed (fixture drifted?)" if b == twb
File.write(File.join(tmp, "union-in-join.twb"), b)
RB

# -- 1 + 2. converter lockstep + refusal (need node) -------------------------
if command -v node >/dev/null; then
  cat >"$TMP/convert.mjs" <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [bundle, twb, out] = process.argv.slice(2);
const { convertTableauToSigma } = await import(pathToFileURL(bundle).href);
const r = convertTableauToSigma(readFileSync(twb, "utf8"), { connectionId: "", database: "", schema: "", datasourceIndex: 0 });
writeFileSync(out, JSON.stringify({ sigmaDataModel: r.model, stats: r.stats, warnings: r.warnings }, null, 2) + "\n");
MJS
  if node "$TMP/convert.mjs" "$BUNDLE" "$CASE_DIR/workbook-content.twb" "$TMP/fresh.json" \
     && python3 "$REPO_ROOT/corpus/lib/corpus_check.py" diff "$CASE_DIR/golden/data-model.json" "$TMP/fresh.json" >/dev/null; then
    note "OK converter↔golden byte-identical after id-normalization"
  else
    echo "FAIL: fresh conversion diverges from golden/data-model.json"; fail=1
  fi
  python3 - "$TMP/fresh.json" <<'PY' && note "OK union spec shape (elementId sources, nameless union, friendly sourceColumns, metric on union)" || { echo "FAIL: union spec shape pins"; fail=1; }
import json, sys
d = json.load(open(sys.argv[1]))
els = d["sigmaDataModel"]["pages"][0]["elements"]
unions = [e for e in els if e.get("source", {}).get("kind") == "union"]
assert len(unions) == 1 and len(els) == 3, (len(unions), len(els))
u = unions[0]
assert "name" not in u, "union element must NOT carry a name (breaks column validation)"
assert all(s.get("kind") == "table" and s.get("elementId") for s in u["source"]["sources"]), "sources must be elementId-based"
member_ids = {e["id"] for e in els if e is not u}
assert {s["elementId"] for s in u["source"]["sources"]} <= member_ids, "elementId refs must point at the member elements"
for m in u["source"]["matches"]:
    assert all(c.startswith("[") and c.endswith("]") for c in m["sourceColumns"]), m
    assert m["outputColumnName"] and m["outputColumnName"] == m["outputColumnName"].strip()
assert all(c["formula"].startswith("[Union of 2 Sources/") for c in u["columns"]), u["columns"]
assert not any(m.get("outputColumnName") == "Sheet" for m in u["source"]["matches"]), "bookkeeping column leaked"
assert [m["name"] for m in u.get("metrics", [])] == ["Total Net Revenue"], "collision-safe metric must attach to the union element"
assert not any(e.get("metrics") for e in els if e is not u), "no metric may attach to a member"
PY
  if node "$TMP/convert.mjs" "$BUNDLE" "$TMP/single-member.twb" "$TMP/refused.json"; then
    python3 - "$TMP/refused.json" <<'PY' && note "OK refusal: 0 elements + loud named NOT-converted warning" || { echo "FAIL: refusal pins"; fail=1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["sigmaDataModel"]["pages"][0]["elements"] == [], "underivable union must emit NO elements"
assert any("NOT converted" in w and "Union datasource" in w for w in d["warnings"]), d["warnings"]
PY
  else
    echo "FAIL: single-member conversion crashed"; fail=1
  fi
  # Fix-pass refusals: previously SILENT partial loss — the text-member union
  # emitted a subset union, the union-in-join flattened the join and dropped
  # the union subtree while still emitting elements.
  for v in text-member union-in-join; do
    if node "$TMP/convert.mjs" "$BUNDLE" "$TMP/$v.twb" "$TMP/$v.json"; then
      python3 - "$TMP/$v.json" "$v" <<'PY' && note "OK refusal ($v): 0 elements + loud named warning (silent subset dead)" || { echo "FAIL: $v refusal pins"; fail=1; }
import json, sys
d = json.load(open(sys.argv[1]))
v = sys.argv[2]
assert d["sigmaDataModel"]["pages"][0]["elements"] == [], f"{v} must emit NO elements"
if v == "text-member":
    assert any("Union datasource" in w and "NOT converted" in w and "not plain tables" in w and "SALES_LEGACY" in w for w in d["warnings"]), d["warnings"]
else:
    assert any("NOT converted" in w and "nested union" in w and "NO ELEMENTS EMITTED" in w for w in d["warnings"]), d["warnings"]
PY
    else
      echo "FAIL: $v conversion crashed"; fail=1
    fi
  done
else
  note "SKIP converter lockstep + refusal (node not on PATH — structural golden check still ran)"
fi

# -- 3. gap-scan class: trip / ❌-trip / no-false-trip (ruby) ----------------
scan() { ruby "$SKILL/scripts/scan-workbook-gaps.rb" "$1" "$2" >/dev/null 2>&1; }
rows() { python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for f in d["detected_features"]:
    if "Union datasource" in f["name"]:
        print(f["status"])
' "$1"; }

if scan "$CASE_DIR/workbook-content.twb" "$TMP/fixture-gaps.md"; then
  got="$(rows "$TMP/fixture-gaps.json")"
  if [ "$got" = "hint" ]; then
    note "OK gap-scan: wildcard fixture → hint row only (no false ❌)"
  else
    echo "FAIL: wildcard fixture gap rows = '$got' (want exactly 'hint')"; fail=1
  fi
else
  echo "FAIL: gap-scan crashed on the fixture"; fail=1
fi

if scan "$TMP/single-member.twb" "$TMP/single-gaps.md"; then
  got="$(rows "$TMP/single-gaps.json")"
  if [ "$got" = "unhandled" ]; then
    note "OK gap-scan: single-member variant → ❌-unhandled row"
  else
    echo "FAIL: single-member variant gap rows = '$got' (want exactly 'unhandled')"; fail=1
  fi
else
  echo "FAIL: gap-scan crashed on the single-member variant"; fail=1
fi

# Fix-pass ❌ trips: non-table union member + union nested in a join tree.
for v in text-member union-in-join; do
  if scan "$TMP/$v.twb" "$TMP/$v-gaps.md"; then
    got="$(rows "$TMP/$v-gaps.json")"
    if [ "$got" = "unhandled" ]; then
      note "OK gap-scan: $v variant → ❌-unhandled row (never the silent hint)"
    else
      echo "FAIL: $v variant gap rows = '$got' (want exactly 'unhandled')"; fail=1
    fi
  else
    echo "FAIL: gap-scan crashed on the $v variant"; fail=1
  fi
done

if scan "$CASE_DIR/../param-default-controls/workbook-content.twb" "$TMP/nounion-gaps.md"; then
  got="$(rows "$TMP/nounion-gaps.json")"
  if [ -z "$got" ]; then
    note "OK gap-scan: no-union workbook → no union rows (no false trip)"
  else
    echo "FAIL: no-union workbook tripped union rows: '$got'"; fail=1
  fi
else
  echo "FAIL: gap-scan crashed on the no-union workbook"; fail=1
fi

exit "$fail"
