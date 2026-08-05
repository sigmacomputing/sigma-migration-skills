#!/usr/bin/env bash
# Offline test for hygiene.yml's "Resolve push/PR diff range" step (F5 range
# fix, 2026-07-25). test-hygiene-sweep.sh style.
#
# The step feeds BASE..HEAD to the server-side commit-message backstop and the
# converter-provenance guard. The old resolution — `git rev-parse HEAD^1 ||
# base.sha` — silently collapsed the range to ONE commit whenever github.sha
# was the PR head instead of the test-merge commit (`<sha>^1` succeeds for any
# non-root commit, so the fallback never fired and no guard printed anything
# unusual). This test EXTRACTS the step's actual run-block from hygiene.yml
# (never a forked copy of its logic) and drives it against a fixture repo
# with a 4-commit PR whose base drifted after PR creation:
#   Part A — extraction sanity + string-pins: merge-base resolution present,
#            the old `rev-parse "${HEAD_SHA}^1"` form gone, PR_COMMITS wired
#   Part B — SHAPE A (github.sha = PR HEAD): old logic covers 1 commit (the
#            bug, reproduced from first principles); the real step covers all
#            4 and excludes the base-drift commit
#   Part C — SHAPE B (github.sha = test-merge commit): the real step resolves
#            the byte-identical BASE the old logic did (no behavior change on
#            the previously-working shape)
#   Part D — coverage assertion: fed the old under-scanning BASE it refuses
#            (::error:: + exit 1); fed the correct BASE it passes; push-event
#            shape still resolves through the unchanged else-branch; and an
#            UNRESOLVABLE PR range (dead origin + frozen base.sha object
#            absent, so every fallback fails) is refused loudly instead of
#            reaching the fail-open "no diff range" skip — zero-commit
#            under-scan is the extreme case of what the assertion exists to
#            refuse, and the assertion itself sits inside [ -n "$BASE" ].
#            The silent skip stays push-only.
#
# Fixture-only git repos, creds-free, network-free (origin is a local path).
# Runs standalone:  bash tools/test-hygiene-range.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YML="$HERE/../.github/workflows/hygiene.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

# Extract the resolve step's run-block (10-space YAML indent stripped) so the
# fixture drives the TEXT that ships, not a copy that can drift from it.
awk '
  /^      - name: Resolve push\/PR diff range/ { instep=1; next }
  instep && /^        run: \|/ { inrun=1; next }
  inrun && /^      - name:/ { exit }
  inrun { sub(/^          /, ""); print }
' "$YML" > "$TMP/resolve.sh"
# The coverage-assertion tail alone, for feeding it a hostile BASE in Part D.
awk '
  /^      - name: Resolve push\/PR diff range/ { instep=1; next }
  instep && /^          # Coverage assertion/ { incov=1 }
  incov && /^      - name:/ { exit }
  incov { sub(/^          /, ""); print }
' "$YML" > "$TMP/coverage.sh"

echo "Part A — extraction sanity + string-pins on the shipped step"
[ -s "$TMP/resolve.sh" ]; check $? "resolve run-block extracted from hygiene.yml"
grep -qF 'git merge-base "refs/remotes/origin/${PR_BASE_REF}"' "$TMP/resolve.sh"
check $? "PR shape resolves via merge-base against the CURRENT base ref"
! grep -qF 'rev-parse "${HEAD_SHA}^1"' "$TMP/resolve.sh"
check $? "the old HEAD^1 resolution (silent 1-commit collapse) is gone"
[ -s "$TMP/coverage.sh" ]; check $? "coverage-assertion tail extracted"
grep -q 'UNDER-SCAN' "$TMP/coverage.sh"
check $? "coverage assertion names the failure mode"
awk '/- name: Resolve push\/PR diff range/,/^        run: \|/' "$YML" | grep -q 'PR_COMMITS:'
check $? "PR_COMMITS is wired into the step env (assertion has its denominator)"

# --- fixture: 4-commit PR, base drifts by one commit after PR creation -------
UP="$TMP/upstream"
mkdir -p "$UP"
gitu() { git -C "$UP" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }
git -C "$UP" init -q -b main
printf 'base\n' > "$UP/m1.txt"
gitu add m1.txt && gitu commit -q -m base
C0="$(git -C "$UP" rev-parse HEAD)"          # frozen base.sha at PR creation
gitu checkout -q -b pr
for i in 1 2 3 4; do
  printf 'p%s\n' "$i" > "$UP/p$i.txt"
  gitu add "p$i.txt" && gitu commit -q -m "p$i"
done
P4="$(git -C "$UP" rev-parse HEAD)"          # PR head
gitu checkout -q main
printf 'drift\n' > "$UP/m2.txt"
gitu add m2.txt && gitu commit -q -m drift   # base moves AFTER the PR exists
C1="$(git -C "$UP" rev-parse main)"
CI="$TMP/ci"
git clone -q "$UP" "$CI"                     # what actions/checkout produces
gitc() { git -C "$CI" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }

run_resolve() { # <event> <head-sha> <before-sha> -> RANGE_BASE/RANGE_OUT/RANGE_RC
  GE="$TMP/github.env"; : > "$GE"
  ( cd "$CI" && EVENT_NAME="$1" HEAD_SHA="$2" PUSH_BEFORE_SHA="$3" \
      PR_BASE_SHA="$C0" PR_BASE_REF="main" PR_COMMITS="4" \
      DEFAULT_BRANCH="main" GITHUB_ENV="$GE" \
      bash -e -o pipefail "$TMP/resolve.sh" ) > "$TMP/resolve.out" 2>&1
  RANGE_RC=$?
  RANGE_BASE="$(grep '^RANGE_BASE=' "$GE" | tail -1 | cut -d= -f2)"
  RANGE_OUT="$TMP/resolve.out"
}

echo "Part B — SHAPE A: github.sha is the PR HEAD (unmergeable/head-shaped event)"
gitc checkout -q "$P4"
OLD_A="$(git -C "$CI" rev-parse "${P4}^1" 2>/dev/null || echo "$C0")"
N_OLD_A="$(git -C "$CI" rev-list --count "$OLD_A..$P4")"
[ "$N_OLD_A" -eq 1 ]; check $? "old HEAD^1 logic really under-scans this shape (covers $N_OLD_A of 4)"
run_resolve pull_request "$P4" ""
[ "$RANGE_RC" -eq 0 ]; check $? "shipped step exits 0 on the head shape (got $RANGE_RC)"
N_NEW_A="$(git -C "$CI" rev-list --count "$RANGE_BASE..$P4")"
[ "$N_NEW_A" -eq 4 ]; check $? "shipped step covers all 4 PR commits (got $N_NEW_A)"
! git -C "$CI" rev-list "$RANGE_BASE..$P4" | grep -q "$C1"
check $? "base-drift commit stays excluded (drift must never be scanned as PR content)"
grep -q "covers 4 commit(s)" "$RANGE_OUT"
check $? "step SAYS how many commits it covers (silence is what hid the bug)"

echo "Part C — SHAPE B: github.sha is the test-merge commit (mergeable PR)"
gitc checkout -q "$C1"
gitc merge -q --no-ff -m testmerge "$P4" >/dev/null 2>&1
M="$(git -C "$CI" rev-parse HEAD)"
OLD_B="$(git -C "$CI" rev-parse "${M}^1")"
run_resolve pull_request "$M" ""
[ "$RANGE_RC" -eq 0 ]; check $? "shipped step exits 0 on the merge shape (got $RANGE_RC)"
[ "$RANGE_BASE" = "$OLD_B" ]
check $? "merge shape resolves the byte-identical BASE the old logic did"
N_NEW_B="$(git -C "$CI" rev-list --count "$RANGE_BASE..$M")"
[ "$N_NEW_B" -eq 5 ]; check $? "merge shape covers the 4 PR commits + the merge (got $N_NEW_B)"

echo "Part D — coverage assertion refuses an under-scanning range"
( cd "$CI" && EVENT_NAME=pull_request HEAD_SHA="$P4" PR_COMMITS=4 BASE="$OLD_A" \
    bash -e -o pipefail "$TMP/coverage.sh" ) > "$TMP/cov.out" 2>&1
RC=$?
[ "$RC" -eq 1 ]; check $? "old under-scanning BASE is refused with exit 1 (got $RC)"
grep -q "::error::range covers 1 commit(s) but this PR has 4" "$TMP/cov.out"
check $? "refusal is loud and names the shortfall"
( cd "$CI" && EVENT_NAME=pull_request HEAD_SHA="$P4" PR_COMMITS=4 BASE="$C0" \
    bash -e -o pipefail "$TMP/coverage.sh" ) > "$TMP/cov.out" 2>&1
RC=$?
[ "$RC" -eq 0 ]; check $? "correct BASE passes the assertion (got $RC)"
run_resolve push "$P4" "$C0"
[ "$RANGE_RC" -eq 0 ] && [ "$RANGE_BASE" = "$C0" ]
check $? "push events still resolve through the unchanged before-sha branch"

# Unresolvable-range shape: shallow single-branch clone (PR head only, so the
# frozen base.sha OBJECT is absent and origin/main was never fetched) with a
# dead origin (both in-step fetches fail). file:// keeps it network-free while
# letting --depth work (git ignores --depth on plain-path local clones).
DEAD="$TMP/dead"
git clone -q --depth 1 --branch pr "file://$UP" "$DEAD" 2>/dev/null
git -C "$DEAD" remote set-url origin "file://$TMP/no-such-origin"
run_resolve_dead() { # <event> <before-sha> -> RANGE_RC/RANGE_OUT + $GE env file
  GE="$TMP/github.env"; : > "$GE"
  ( cd "$DEAD" && EVENT_NAME="$1" HEAD_SHA="$P4" PUSH_BEFORE_SHA="$2" \
      PR_BASE_SHA="$C0" PR_BASE_REF="main" PR_COMMITS="4" \
      DEFAULT_BRANCH="main" GITHUB_ENV="$GE" \
      bash -e -o pipefail "$TMP/resolve.sh" ) > "$TMP/resolve.out" 2>&1
  RANGE_RC=$?
  RANGE_OUT="$TMP/resolve.out"
}
git -C "$DEAD" cat-file -e "$C0" 2>/dev/null
[ $? -ne 0 ]; check $? "fixture sanity: frozen base.sha object really is absent from the shallow clone"
run_resolve_dead pull_request ""
[ "$RANGE_RC" -eq 1 ]; check $? "unresolvable PR range is REFUSED, never skipped (got rc $RANGE_RC)"
grep -q "::error::could not resolve a PR diff range" "$RANGE_OUT"
check $? "refusal is loud (::error::) and says it refuses to skip the guards"
! grep -q '^RANGE_BASE=' "$GE"
check $? "refused step exports no RANGE_BASE for the guards to consume"
run_resolve_dead push ""
[ "$RANGE_RC" -eq 0 ] && grep -q "no diff range to check" "$RANGE_OUT"
check $? "same dead fixture on a PUSH event still skips green (silent skip is push-only)"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
