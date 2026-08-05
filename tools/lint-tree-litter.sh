#!/usr/bin/env bash
# tools/lint-tree-litter.sh — no run-state litter may ever be TRACKED inside a
# skill tree: `workdir-*/` directories (field-run state: connection/intake/
# doctor json carry customer identifiers), `*.log` files (hyperd and friends),
# the cross-run registries (probe-artifacts/posted-workbooks/offramps .jsonl —
# run/environment fingerprints and customer-derived rule text) at any depth,
# and any other skill-ROOT `*.jsonl`, all under `plugins/*/skills/*/`. The
# skill-local .gitignore keeps them untracked; this lint is the backstop for a
# careless `git add -f` / ignore-rule regression, mirroring those ignore rules.
#
#   bash tools/lint-tree-litter.sh          # exit 0 clean, exit 1 with named paths
#
# Wired into .githooks/run-governance-checks.sh alongside the hygiene sweep.
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "lint-tree-litter: not a git repo" >&2; exit 2; }
cd "$root" || exit 2

# Paths only — never file contents (a litter path may sit next to sensitive
# run state; the hygiene sweep owns content scanning).
hits="$(git ls-files | grep -E '^plugins/[^/]+/skills/[^/]+/((.*/)?workdir-[^/]+/|.*\.log$|(.*/)?(probe-artifacts|posted-workbooks|offramps)\.jsonl$|[^/]+\.jsonl$)')"

if [ -n "$hits" ]; then
  echo "TREE-LITTER LINT FAILED — run-state litter is tracked inside a skill tree:" >&2
  printf '%s\n' "$hits" | head -40 >&2
  echo "Untrack it (git rm --cached) — run workdirs and logs never enter the repo" >&2
  echo "(see CONTRIBUTING.md \"Run state stays local\")." >&2
  exit 1
fi

echo "lint-tree-litter: clean (no tracked workdir-*/, *.log, run registry, or skill-root *.jsonl under plugins/*/skills/*/)."
exit 0
