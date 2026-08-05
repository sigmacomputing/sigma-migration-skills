#!/usr/bin/env bash
# differential-seed — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. Translator differential (node-guarded): every pair's Tableau formula
#      re-runs through the vendored bundle's OWN translator (diff-check.mjs,
#      temp-copy export shim) and must byte-match the recorded sigma_expected
#      + warnings. THE regression floor under any future engine flip (W2.19):
#      an engine change surfaces as a named per-pair diff; --record is the
#      reviewed re-baseline path.
#   2. Structural + honesty lint (python3, always runs): unique ids; required
#      keys; context in {dm, chart}; recorded sigma_expected non-empty;
#      authored SQL is SELECT-only over the neutral seed table; live-oracle
#      slots (vds / sql.rows / batch_probe) are either null (pending) or
#      recorded WITH a version key (recorded_at + source) — a bare value with
#      no provenance FAILS (red line: version-keyed raw evidence only, never
#      fabricated).
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
note() { printf '     %s\n' "$*"; }

# -- 1. translator differential (needs node) ---------------------------------
if command -v node >/dev/null; then
  if node "$CASE_DIR/diff-check.mjs" >/dev/null; then
    note "OK translator differential: all pairs match the recorded baseline"
  else
    echo "FAIL: translator output drifted from the recorded pairs (run diff-check.mjs to see; --record only as a reviewed re-baseline)"
    node "$CASE_DIR/diff-check.mjs" | grep '^FAIL' || true
    fail=1
  fi
else
  note "SKIP translator differential (node not on PATH — structural lint still ran)"
fi

# -- 2. structural + honesty lint --------------------------------------------
python3 - "$CASE_DIR/pairs.json" <<'PY' && note "OK structure: 10 unique pairs, oracle slots honest (null or version-keyed)" || { echo "FAIL: pairs.json structure/honesty lint"; fail=1; }
import json, sys
doc = json.load(open(sys.argv[1]))
pairs = doc["pairs"]
assert 8 <= len(pairs) <= 10, f"seed is {len(pairs)} pairs (scope: 8-10)"
ids = [p["id"] for p in pairs]
assert len(set(ids)) == len(ids), "duplicate pair ids"
seed_table = doc["seed_table"]
assert seed_table == "DEMO_DB.DEMO.SEED_ROWS", seed_table

def slot_ok(v):
    # pending (null) or recorded WITH provenance — never a bare fabricated value
    if v is None:
        return True
    return isinstance(v, dict) and bool(v.get("recorded_at")) and bool(v.get("source"))

for p in pairs:
    for k in ("id", "class", "context", "tableau", "sigma_expected", "warnings", "oracle"):
        assert k in p, (p.get("id"), k)
    assert p["context"] in ("dm", "chart"), p["id"]
    assert isinstance(p["sigma_expected"], str) and p["sigma_expected"].strip(), p["id"]
    assert isinstance(p["warnings"], list), p["id"]
    o = p["oracle"]
    assert set(o.keys()) == {"vds", "sql", "batch_probe"}, p["id"]
    assert slot_ok(o["vds"]), f'{p["id"]}: vds recording lacks provenance'
    assert slot_ok(o["batch_probe"]), f'{p["id"]}: batch_probe recording lacks provenance'
    sql = o["sql"]
    assert isinstance(sql, dict) and isinstance(sql["statement"], str), p["id"]
    s = sql["statement"].strip()
    assert s.upper().startswith("SELECT"), f'{p["id"]}: SQL must be SELECT-only'
    assert seed_table in s, f'{p["id"]}: SQL must target the neutral seed table'
    assert sql["rows"] is None or (isinstance(sql["rows"], dict)
                                   and sql["rows"].get("recorded_at") and sql["rows"].get("source")), \
        f'{p["id"]}: sql rows recording lacks provenance'

# the seed ships PENDING live recordings — a recorded value sneaking in
# without provenance is the failure this lint exists for
PY

exit "$fail"
