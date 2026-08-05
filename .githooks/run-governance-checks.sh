#!/usr/bin/env bash
# Shared local gate run by the pre-commit and pre-push hooks. Runs the same
# creds-free governance checks CI runs (shared-lib drift + skill conformance),
# so violations are caught locally in ~1s instead of after a push. Bypass with
# `git commit --no-verify` / `git push --no-verify` if you must.
set -uo pipefail

# repo root (works from a normal clone or a linked worktree)
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$root" || exit 0

# Nothing to check if the governance tools aren't present (older checkout).
[ -f tools/check-shared.rb ] || exit 0

if ! command -v ruby >/dev/null 2>&1; then
  echo "governance hook: ruby not found — skipping local checks (CI still enforces)." >&2
  exit 0
fi

fail=0
ruby tools/check-shared.rb || fail=1
ruby tools/lint-skills.rb   || fail=1
if [ "${GOVERNANCE_SKIP_SWEEP:-}" = "1" ]; then
  # hygiene.yml's dedicated Sweep step (redacted output) already swept this
  # tree; skip the redundant raw-output inner sweep in CI. Local hooks never
  # set this knob — they keep sweeping.
  echo "governance: inner hygiene sweep skipped (GOVERNANCE_SKIP_SWEEP=1 — CI's redacted Sweep step owns it)."
else
  [ -f tools/hygiene-sweep.sh ] && { bash tools/hygiene-sweep.sh || fail=1; }
fi
[ -f tools/lint-tree-litter.sh ] && { bash tools/lint-tree-litter.sh || fail=1; }
[ -f tools/lint-esm-imports.rb ] && { ruby tools/lint-esm-imports.rb || fail=1; }
[ -f tools/lint-twb-encoding.rb ] && { ruby tools/lint-twb-encoding.rb || fail=1; }
[ -f tools/check-agent-variants.rb ] && { ruby tools/check-agent-variants.rb || fail=1; }
[ -f tools/check-cognos-bundle.rb ] && { ruby tools/check-cognos-bundle.rb || fail=1; }
# bootstrap<->doctor KEEP-IN-LOCKSTEP guard (E2.1): bootstrap.sh duplicates
# doctor.sh's probes (py_real, the vm-node candidate globs, Test-RealPython)
# under KEEP-IN-LOCKSTEP comments that name this test as the mechanical
# no-drift guard. check-shared.rb only proves twins match canonical — NOT that
# bootstrap's probes match doctor's — and a guard with no automated executor
# regresses silently. Fixture-free and sub-second (~60ms), so it runs in the
# local hook too; quiet on success.
lockstep="plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-bootstrap-lockstep.sh"
if [ -f "$lockstep" ]; then
  lockstep_out="$(bash "$lockstep" 2>&1)" || { printf '%s\n' "$lockstep_out" >&2; fail=1; }
fi
# Fixture self-test suites run in CI only (hygiene.yml calls this script;
# GitHub Actions sets CI=true): they spin throwaway git repos and would blow
# the ~1s local-hook budget, but the litter/guard contracts must not regress
# with no automated executor.
if [ "${CI:-}" = "true" ]; then
  [ -f tools/test-tree-litter.sh ] && { bash tools/test-tree-litter.sh || fail=1; }
  [ -f tools/test-commit-msg-guard.sh ] && { bash tools/test-commit-msg-guard.sh || fail=1; }
fi
if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "governance checks failed — fix above, or bypass with --no-verify (CI will still gate)." >&2
  exit 1
fi
