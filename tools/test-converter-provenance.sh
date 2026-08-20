#!/usr/bin/env bash
# Offline test for tools/check-converter-provenance.sh (converter-provenance
# guard, 2026-07-18). test-hygiene-sweep.sh style.
#
# Drives the guard against throwaway fixture git repos and asserts:
#   Part A — an unpaired converter/*.mjs change fails; the same diff plus the
#            sibling PROVENANCE.json change passes (and a PROVENANCE-only
#            change passes the schema pin)
#   Part B — schema pin: a local_patches entry missing upstream_pr fails;
#            malformed JSON fails; deleting PROVENANCE.json while the bundle
#            remains fails; a restored schema-complete file passes again
#   Part C — in-skill converters ("source" key: the static
#            provenance a rebuild rewrites byte-identical): bundle + .ts
#            source passes; bundle alone fails naming the achievable
#            remediation; bundle + PROVENANCE change still passes
#   Part D — string-pin: the real tableau converter PROVENANCE.json records
#            the d8a049a in-place patch with the commit/summary/upstream_pr
#            entry schema and carries the upstream-and-re-vendor task block
#
# All fixture names are synthetic (toolx) — no field-derived identifiers.
# Runs standalone:  bash tools/test-converter-provenance.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/check-converter-provenance.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

RC=0
run_guard() { bash "$GUARD" "$1" "$2" >"$TMP/out" 2>&1; RC=$?; }

new_repo() { # dir
  mkdir -p "$1" && cd "$1" || exit 1
  git init -q
  git config user.email provenance-test@example.invalid
  git config user.name provenance-test
  git config commit.gpgsign false
}
commit_all() { git add -A && git commit -q --no-verify -m "$1" && git rev-parse HEAD; }

CONV="plugins/toolx-to-sigma/skills/toolx-to-sigma/converter"

echo "Part A — diff pairing on a vendored (source_repo) converter"
new_repo "$TMP/vendored"
mkdir -p "$CONV"
echo "export const v = 1;" > "$CONV/toolx.mjs"
cat > "$CONV/PROVENANCE.json" <<'EOF'
{
  "source_commit": "0000000",
  "vendored_modules": "toolx.mjs",
  "local_patches": [
    { "commit": "1111111", "summary": "fixture patch", "upstream_pr": null }
  ]
}
EOF
A0="$(commit_all base)"
echo "export const v = 2;" > "$CONV/toolx.mjs"
A1="$(commit_all unpaired)"
run_guard "$A0" "$A1"
[ "$RC" -eq 1 ]; check $? "unpaired bundle change fails (got $RC)"
grep -q "toolx.mjs" "$TMP/out"; check $? "failure names the bundle"
grep -q "sibling PROVENANCE.json" "$TMP/out"; check $? "failure names the missing pairing"
sed -i.bak 's/"source_commit": "0000000"/"source_commit": "0000001"/' "$CONV/PROVENANCE.json" && rm -f "$CONV/PROVENANCE.json.bak"
A2="$(commit_all paired)"
run_guard "$A0" "$A2"
[ "$RC" -eq 0 ]; check $? "same bundle diff plus sibling PROVENANCE change passes (got $RC)"
grep -q "guard OK" "$TMP/out"; check $? "paired range reports guard OK"
run_guard "$A1" "$A2"
[ "$RC" -eq 0 ]; check $? "PROVENANCE-only change passes the schema pin (got $RC)"

echo "Part B — local_patches schema pin + deleted-provenance backstop"
python3 - "$CONV/PROVENANCE.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
del d["local_patches"][0]["upstream_pr"]
json.dump(d, open(p, "w"), indent=2)
PYEOF
B1="$(commit_all drop-key)"
run_guard "$A2" "$B1"
[ "$RC" -eq 1 ]; check $? "entry missing upstream_pr fails (got $RC)"
grep -q "upstream_pr" "$TMP/out"; check $? "failure names the missing key"
echo '{ not json' > "$CONV/PROVENANCE.json"
B2="$(commit_all bad-json)"
run_guard "$B1" "$B2"
[ "$RC" -eq 1 ]; check $? "malformed JSON fails (got $RC)"
grep -q "not valid JSON" "$TMP/out"; check $? "failure says the file no longer parses"
cat > "$CONV/PROVENANCE.json" <<'EOF'
{
  "source_commit": "0000002",
  "vendored_modules": "toolx.mjs",
  "local_patches": [
    { "commit": "1111111", "summary": "fixture patch", "upstream_pr": "example/fixture-converters#1" }
  ]
}
EOF
B3="$(commit_all restore)"
run_guard "$B2" "$B3"
[ "$RC" -eq 0 ]; check $? "restored schema-complete file passes (got $RC)"
git rm -q "$CONV/PROVENANCE.json"
B4="$(commit_all delete)"
run_guard "$B3" "$B4"
[ "$RC" -eq 1 ]; check $? "deleting PROVENANCE.json while the bundle remains fails (got $RC)"
grep -q "deleted while the vendored bundle remains" "$TMP/out"; check $? "failure names the deletion"

echo "Part C — in-skill converter pairs bundle with its .ts source"
new_repo "$TMP/inskill"
mkdir -p "$CONV"
echo "export const cli = 1;" > "$CONV/cli.ts"
echo "export const cli = 1;" > "$CONV/cli.mjs"
cat > "$CONV/PROVENANCE.json" <<'EOF'
{
  "source": "in-skill converter/cli.ts",
  "vendored_modules": "cli.mjs",
  "note": "static body — a rebuild rewrites this file byte-identical"
}
EOF
C0="$(commit_all base)"
echo "export const cli = 2;" > "$CONV/cli.ts"
echo "export const cli = 2;" > "$CONV/cli.mjs"
C1="$(commit_all ts-paired)"
run_guard "$C0" "$C1"
[ "$RC" -eq 0 ]; check $? "bundle + .ts source (PROVENANCE byte-identical) passes (got $RC)"
echo "export const cli = 3;" > "$CONV/cli.mjs"
C2="$(commit_all bundle-alone)"
run_guard "$C1" "$C2"
[ "$RC" -eq 1 ]; check $? "in-skill bundle change without .ts or PROVENANCE fails (got $RC)"
grep -q 'converter/\*\.ts source' "$TMP/out"; check $? "failure names the achievable remediation (.ts pairing)"
echo "export const cli = 4;" > "$CONV/cli.mjs"
sed -i.bak 's/static body/static provenance body/' "$CONV/PROVENANCE.json" && rm -f "$CONV/PROVENANCE.json.bak"
C3="$(commit_all prov-paired)"
run_guard "$C2" "$C3"
[ "$RC" -eq 0 ]; check $? "in-skill bundle + PROVENANCE change still passes (got $RC)"

echo "Part D — string-pin the real tableau PROVENANCE.json entry schema"
REAL="$ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/PROVENANCE.json"
[ -f "$REAL" ]; check $? "real PROVENANCE.json exists"
grep -q '"local_patches"' "$REAL"; check $? "carries a local_patches array"
python3 - "$REAL" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
lp = d["local_patches"]
assert isinstance(lp, list) and lp, "local_patches must be a non-empty array"
first = lp[0]
for k in ("commit", "summary", "upstream_pr"):
    assert k in first, "local_patches[0] missing %s" % k
assert first["commit"] == "d8a049a", "first entry must record the d8a049a in-place patch"
PYEOF
check $? "local_patches[0] records d8a049a with commit/summary/upstream_pr"
grep -q '"_upstream_and_revendor_tasks"' "$REAL"; check $? "carries the upstream-and-re-vendor task block"
for t in "TASK 1 —" "TASK 2 —" "TASK 3 —" "TASK 4 —"; do
  grep -q "$t" "$REAL"; check $? "task block lists ${t% —}"
done
grep -q "scripts/dev/vendor-converter.sh" "$REAL"
check $? "TASK 3 names the second (skill-local) regenerator"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
