#!/usr/bin/env bash
# Offline test for the E9.2/E9.3 byte budgets in tools/lint-skills.rb
# (successor to tools/test-lint-ref-budget.sh — the standalone lint + allowlist
# were folded into lint-skills.rb + tools/skill-lint-baseline.json per the
# E9.2-spec'd mechanism: one lint, ONE exception registry).
#
# Verifies (fixture repos, synthetic content only — no customer data):
#   Part A — the lint passes the REAL tree (post-diet tableau-to-sigma inside
#            budget; pre-diet skills covered by justified baseline entries)
#   Part B — trip tests in a fixture tree: SKILL.md > 20480B fails BY NAME;
#            a refs/*.md > 32768B fails BY NAME; a marked mandatory-pre-read
#            block naming 4 refs fails; a legacy "Read ALL of the following"
#            block naming 4 refs fails
#   Part C — no-false-trip tests (guards carry the ratified <=5% false-stop
#            budget): SKILL.md at EXACTLY 20480B passes; a ref at EXACTLY
#            32768B passes; a marked block naming exactly 3 refs passes; a
#            skill with NO pre-read block passes (nothing to enforce); refs
#            named outside any block are not counted
#   Part D — baseline semantics: a justified entry downgrades the failure to a
#            tracked WARN; an entry with an EMPTY justification fails (schema
#            pin); an unrelated entry exempts nothing
#   Part E — the real baseline parses, every entry carries a non-empty
#            justification, and post-diet tableau-to-sigma has NO
#            'skill-md-bytes' entry (it must fit the budget for real)
#
# The fixture runs the REAL tools/lint-skills.rb (copied into the fixture's
# tools/ dir — the script roots itself at its own parent dir), so the tested
# code path is the shipped one, not a fork.
#
# Usage:  bash tools/test-lint-skills-budgets.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/tools/lint-skills.rb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

# fixture helpers ------------------------------------------------------------
# Skill dir basename 'y' is deliberately NOT *-to-sigma so the converter
# ruleset (which needs docs/phase-schema.md) stays out of the budget tests.
new_fixture() { # dir
  mkdir -p "$1/plugins/x/skills/y/refs" "$1/tools"
  cp "$LINT" "$1/tools/lint-skills.rb"
  printf '# tiny skill\n' > "$1/plugins/x/skills/y/SKILL.md"
  printf '# tiny ref\n' > "$1/plugins/x/skills/y/refs/small.md"
}
fill() { # path bytes  — write exactly N bytes
  python3 - "$1" "$2" <<'PY'
import sys
open(sys.argv[1], 'w').write('x' * int(sys.argv[2]))
PY
}
run_fix() { # fixture-dir
  ruby "$1/tools/lint-skills.rb"
}

cd "$ROOT"

echo "Part A — real tree"
ruby "$LINT" >"$TMP/real.out" 2>&1
check $? "lint-skills exits 0 on the real tree"
grep -q 'byte budgets clean' "$TMP/real.out"
check $? "byte-budgets-clean summary line printed"

echo "Part B — trip tests (fixture tree)"
FIX="$TMP/fix-trip"; new_fixture "$FIX"
fill "$FIX/plugins/x/skills/y/SKILL.md" 20481
run_fix "$FIX" >"$TMP/trip-skill.out" 2>&1
[ $? -ne 0 ]; check $? "SKILL.md at 20481 bytes fails"
grep -q 'plugins/x/skills/y/SKILL.md: 20481 bytes' "$TMP/trip-skill.out"
check $? "failure names the oversized SKILL.md"

fill "$FIX/plugins/x/skills/y/SKILL.md" 100
fill "$FIX/plugins/x/skills/y/refs/big.md" 32769
run_fix "$FIX" >"$TMP/trip-ref.out" 2>&1
[ $? -ne 0 ]; check $? "refs/big.md at 32769 bytes fails"
grep -q 'refs/big.md: 32769 bytes' "$TMP/trip-ref.out"
check $? "failure names the oversized ref"
rm "$FIX/plugins/x/skills/y/refs/big.md"

cat > "$FIX/plugins/x/skills/y/SKILL.md" <<'EOF'
# skill
<!-- mandatory-pre-read -->
Read `refs/a.md`, `refs/b.md`, `refs/c.md`, `refs/d.md` first.
<!-- /mandatory-pre-read -->
EOF
run_fix "$FIX" >"$TMP/trip-pre.out" 2>&1
[ $? -ne 0 ]; check $? "marked pre-read block naming 4 refs fails"
grep -q 'mandatory pre-read names 4 refs' "$TMP/trip-pre.out"
check $? "failure reports the 4-ref count"

cat > "$FIX/plugins/x/skills/y/SKILL.md" <<'EOF'
# skill
**Read ALL of the following before replying:**
- `refs/a.md`
- `refs/b.md`
- `refs/c.md`
- `refs/d.md`

## Next heading
EOF
run_fix "$FIX" >"$TMP/trip-legacy.out" 2>&1
[ $? -ne 0 ]; check $? "legacy Read-ALL block naming 4 refs fails"

echo "Part C — no-false-trip tests (boundaries + absent block)"
FIX2="$TMP/fix-pass"; new_fixture "$FIX2"
fill "$FIX2/plugins/x/skills/y/SKILL.md" 20480
fill "$FIX2/plugins/x/skills/y/refs/edge.md" 32768
run_fix "$FIX2" >"$TMP/pass-edge.out" 2>&1
check $? "SKILL.md at exactly 20480 and ref at exactly 32768 pass"

cat > "$FIX2/plugins/x/skills/y/SKILL.md" <<'EOF'
# skill
<!-- mandatory-pre-read -->
Read `refs/a.md`, `refs/b.md`, `refs/c.md` first (and `refs/a.md` twice is one).
<!-- /mandatory-pre-read -->
Elsewhere the body may cite `refs/d.md`, `refs/e.md`, `refs/f.md`, `refs/g.md`
freely — per-phase pointers are the point, only the BLOCK is counted.
EOF
run_fix "$FIX2" >"$TMP/pass-3.out" 2>&1
check $? "marked block naming exactly 3 refs passes; outside-block refs not counted"

printf '# skill with no pre-read block at all\nSee `refs/a.md` at phase 1.\n' > "$FIX2/plugins/x/skills/y/SKILL.md"
run_fix "$FIX2" >"$TMP/pass-none.out" 2>&1
check $? "skill with no pre-read block passes (nothing to enforce)"

echo "Part D — baseline semantics (fixture tree)"
FIX3="$TMP/fix-allow"; new_fixture "$FIX3"
fill "$FIX3/plugins/x/skills/y/SKILL.md" 30000
cat > "$FIX3/tools/skill-lint-baseline.json" <<'EOF'
{"y": {"skill-md-bytes": "fixture: justified oversize"}}
EOF
run_fix "$FIX3" >"$TMP/allow-ok.out" 2>&1
check $? "justified baseline entry downgrades the oversized SKILL.md to WARN"
grep -q 'Tracked byte-budget exceptions' "$TMP/allow-ok.out"
check $? "the exception is surfaced as a tracked WARN"

cat > "$FIX3/tools/skill-lint-baseline.json" <<'EOF'
{"y": {"skill-md-bytes": "  "}}
EOF
run_fix "$FIX3" >"$TMP/allow-empty.out" 2>&1
[ $? -ne 0 ]; check $? "baseline entry with EMPTY justification fails (schema pin)"
grep -q 'EMPTY justification' "$TMP/allow-empty.out"
check $? "failure names the empty-justification entry"

cat > "$FIX3/tools/skill-lint-baseline.json" <<'EOF'
{"z": {"skill-md-bytes": "unrelated entry"}}
EOF
run_fix "$FIX3" >"$TMP/allow-miss.out" 2>&1
[ $? -ne 0 ]; check $? "unrelated baseline entry exempts nothing"

echo "Part E — committed baseline schema"
python3 - "$ROOT/tools/skill-lint-baseline.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
bad = [f"{skill}/{rid}" for skill, rules in data.items() if isinstance(rules, dict)
       for rid, why in rules.items() if not str(why).strip()]
sys.exit(1 if bad else 0)
PY
check $? "committed baseline parses; every entry carries a non-empty justification"
python3 - "$ROOT/tools/skill-lint-baseline.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(1 if 'skill-md-bytes' in (data.get('tableau-to-sigma') or {}) else 0)
PY
check $? "post-diet tableau-to-sigma has NO skill-md-bytes entry (must fit the budget for real)"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
