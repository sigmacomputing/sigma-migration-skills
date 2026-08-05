#!/usr/bin/env bash
# Offline no-drift guard for the KEEP-IN-LOCKSTEP blocks bootstrap duplicates
# from doctor (a sourced helper was considered; doctor's standalone structure
# predates it, so this test is the mechanical guarantee that the duplicated
# probes cannot drift silently):
#   Part A — the version-manager node candidate lists: doctor.sh's "G1" check
#            (for cand in …) vs bootstrap.sh's NODE_DIR latest_bindir call.
#            Bootstrap may activate ADDITIONAL brew opt dirs (an explicit
#            allowlist below) — never fewer dirs, and the shared entries must
#            keep doctor's order (last match wins = newest preference).
#   Part B — the py_real probe body (bash twins), ignoring only the success
#            line (doctor records PY_DESC/PY_VER/PY_ARGV; bootstrap PY_RUN)
#   Part C — Test-RealPython (ps1 twins), ignoring comments/blank lines
#
# Usage:  bash scripts/test-bootstrap-lockstep.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

norm() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

echo "Part A — node version-manager candidate lists (bootstrap.sh vs doctor.sh)"
# doctor: the for-loop glob list.  bootstrap: the NODE_DIR latest_bindir args.
doctor_globs() {
  awk '/for cand in/,/; do/' "$1" | sed 's/\\$//; s/for cand in//; s/; do$//' | norm
}
bootstrap_globs() {
  awk '/NODE_DIR="\$\(latest_bindir/,/)"$/' "$1" \
    | sed 's/NODE_DIR="\$(latest_bindir//; s/\\$//; s/)"$//' | norm
}
bootstrap_globs "$HERE/bootstrap.sh" > "$TMP/globs.bootstrap"
doctor_globs    "$HERE/doctor.sh"    > "$TMP/globs.doctor"
[ -s "$TMP/globs.bootstrap" ] && [ -s "$TMP/globs.doctor" ]
check $? "both candidate lists extracted (non-empty)"
# (1) every doctor glob must appear in bootstrap's list, in the same order:
grep -F -x -f "$TMP/globs.doctor" "$TMP/globs.bootstrap" > "$TMP/globs.shared" 2>/dev/null || true
diff -u "$TMP/globs.doctor" "$TMP/globs.shared" > "$TMP/globs.diff"
check $? "doctor's candidate list is a prefix-ordered subset of bootstrap's"
[ -s "$TMP/globs.diff" ] && sed 's/^/    /' "$TMP/globs.diff"
# (2) bootstrap extras are ONLY the sanctioned brew opt dirs:
extras_bad=0
while IFS= read -r line; do
  grep -F -x -q "$line" "$TMP/globs.doctor" && continue
  case "$line" in
    /opt/homebrew/opt/node/bin/node|/usr/local/opt/node/bin/node) : ;;
    *) extras_bad=1; printf '    unsanctioned bootstrap-only glob: %s\n' "$line" ;;
  esac
done < "$TMP/globs.bootstrap"
check $extras_bad "bootstrap-only extras are limited to the brew opt allowlist"

echo "Part B — py_real probe body (bootstrap.sh vs doctor.sh)"
pyreal() { # file -> py_real body minus the success line (the twins' only
  # sanctioned difference: which PY_* vars the caller needs recorded)
  awk '/^py_real\(\) \{/,/^\}/' "$1" | grep -vE 'PY_RUN=|PY_DESC=' | norm
}
pyreal "$HERE/bootstrap.sh" > "$TMP/pyreal.bootstrap"
pyreal "$HERE/doctor.sh"    > "$TMP/pyreal.doctor"
[ -s "$TMP/pyreal.bootstrap" ] && [ -s "$TMP/pyreal.doctor" ]
check $? "both py_real bodies extracted (non-empty)"
diff -u "$TMP/pyreal.bootstrap" "$TMP/pyreal.doctor" > "$TMP/pyreal.diff"
check $? "py_real probe bodies are identical"
[ -s "$TMP/pyreal.diff" ] && sed 's/^/    /' "$TMP/pyreal.diff"

echo "Part C — Test-RealPython (bootstrap.ps1 vs doctor.ps1)"
psfunc() { # file -> Test-RealPython body minus comment-only/blank lines
  awk '/^function Test-RealPython/,/^\}/' "$1" | grep -v '^[[:space:]]*#' | norm
}
psfunc "$HERE/bootstrap.ps1" > "$TMP/ps.bootstrap"
psfunc "$HERE/doctor.ps1"    > "$TMP/ps.doctor"
[ -s "$TMP/ps.bootstrap" ] && [ -s "$TMP/ps.doctor" ]
check $? "both Test-RealPython bodies extracted (non-empty)"
diff -u "$TMP/ps.bootstrap" "$TMP/ps.doctor" > "$TMP/ps.diff"
check $? "Test-RealPython bodies are identical"
[ -s "$TMP/ps.diff" ] && sed 's/^/    /' "$TMP/ps.diff"

echo
if [ "$fails" -eq 0 ]; then
  echo "test-bootstrap-lockstep: ALL PASS"
else
  echo "test-bootstrap-lockstep: $fails FAILURE(S) — bootstrap and doctor probes drifted; re-sync the KEEP-IN-LOCKSTEP blocks"
  exit 1
fi
