#!/usr/bin/env bash
# vendor-converters.sh — the ONE consistent way to refresh the committed,
# zero-config converters that ship inside every migration skill.
#
# Each converter (convert<Tool>ToSigma) is bundled by esbuild into a single
# self-contained ESM file committed at
#   plugins/<skill>/skills/<skill>/converter/<module>.mjs
# so conversion runs locally via `node` with NO clone, NO npm install, NO network,
# and NO MCP. The vendored bundle is the shipped, guaranteed floor; a maintainer
# regenerates it from a converter-source checkout with this tool.
#
#   SIGMA_CONVERTER_SRC=/path/to/converter-source tools/vendor-converters.sh [converter ...]
#   tools/vendor-converters.sh /path/to/converter-source [converter ...]
#
#   # all converters:
#   tools/vendor-converters.sh /path/to/converter-source
#   # a subset:
#   tools/vendor-converters.sh /path/to/converter-source lookml thoughtspot cognos
#
# Re-run after the converter source changes and commit the bundles. Requires a
# converter-source checkout with esbuild installed (its devDep).
# Portable to macOS bash 3.2 (no associative arrays).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${SIGMA_CONVERTER_SRC:-}}"; [ $# -gt 0 ] && shift || true

# module (in build/) -> skill plugin dir under plugins/ that owns it.
skill_for() {
  case "$1" in
    tableau) echo tableau-to-sigma ;;
    lookml) echo looker-to-sigma ;;
    thoughtspot) echo thoughtspot-to-sigma ;;
    qlik) echo qlik-to-sigma ;;
    powerbi) echo powerbi-to-sigma ;;
    quicksight) echo quicksight-to-sigma ;;
    cognos|cognos-report) echo cognos-to-sigma ;;
    domo) echo domo-to-sigma ;;
    *) echo "" ;;
  esac
}

WANT=("$@"); [ ${#WANT[@]} -eq 0 ] && WANT=(tableau lookml thoughtspot qlik powerbi quicksight cognos domo)

[ -n "$SRC" ] || { echo "FATAL: no converter source — pass a checkout path or set SIGMA_CONVERTER_SRC"; exit 1; }
[ -d "$SRC" ] || { echo "FATAL: converter source not found: $SRC"; exit 1; }
ESBUILD="$SRC/node_modules/.bin/esbuild"
[ -x "$ESBUILD" ] || { echo "FATAL: esbuild not at $ESBUILD — run 'npm install' in $SRC"; exit 1; }

# build the converter repo if its artifacts are missing
if ! ls "$SRC"/build/*.js >/dev/null 2>&1; then
  echo "→ building converter repo (npm run build)"
  ( cd "$SRC" && { npm ci --silent || npm install --silent; } && npm run build --silent )
fi

SHA="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DATE="$(git -C "$SRC" log -1 --format=%cd --date=short 2>/dev/null || echo unknown)"
STAMPED_DIRS=""

for mod in "${WANT[@]}"; do
  skill="$(skill_for "$mod")"
  [ -n "$skill" ] || { echo "WARN: unknown converter '$mod' — skipping"; continue; }
  dest="$ROOT/plugins/$skill/skills/$skill/converter"
  mkdir -p "$dest"

  # Cognos is special: its converter is vendored as TS source IN the skill
  # (converter/cli.ts → cognos.ts/cognos-report.ts), not from the converter
  # source repo. Bundle that pinned CLI into a self-contained converter/cli.mjs
  # (npm install in the skill's converter/ once for fast-xml-parser;
  # node_modules stays gitignored).
  if [ "$mod" = "cognos" ]; then
    entry="$dest/cli.ts"
    out="$dest/cli.mjs"
    [ -f "$entry" ] || { echo "FATAL: $entry missing (cognos vendors its own TS converter)"; exit 1; }
    [ -d "$dest/node_modules/fast-xml-parser" ] || ( cd "$dest" && npm install --silent )
    "$ESBUILD" "$entry" --bundle --format=esm --platform=node --outfile="$out" >/dev/null
    echo "✓ $skill/converter/cli.mjs  ($(du -h "$out" | cut -f1))  [bundled from in-skill cli.ts]"
    # cognos provenance tracks the in-repo TS source. Writing the source_sha256
    # here (single owner: tools/check-cognos-bundle.rb) is what lets that gate
    # detect a converter/*.ts edit that skipped this re-bundle.
    ruby "$ROOT/tools/check-cognos-bundle.rb" --write
    continue
  fi

  # Domo is a third flavor: same regenerate-from-source relationship as the
  # mainline 6, but its source module doesn't follow the convert<Tool>ToSigma
  # naming convention. It vendors formulas.ts, a shared low-level SQL-formula
  # toolkit already used internally by lookml/dbt/snowflake/tableau's own
  # converters — not a top-level converter — so the entry file and the export
  # sanity-check are both custom.
  if [ "$mod" = "domo" ]; then
    entry="$SRC/build/formulas.js"
    out="$dest/sql.mjs"
    [ -f "$entry" ] || { echo "FATAL: $entry missing (build the converter repo first)"; exit 1; }
    "$ESBUILD" "$entry" --bundle --format=esm --platform=node --outfile="$out" >/dev/null
    node --input-type=module -e "
      import * as m from '$out';
      const need = ['lookSqlToSigmaRules','lookConvertExpression','hasResidualCaseKeyword','hasResidualInfixOperator','lookUnknownFunctions'];
      const missing = need.filter(k => typeof m[k] !== 'function');
      if (missing.length) { console.error('FATAL: $out missing exports: ' + missing.join(', ')); process.exit(1); }
    "
    echo "✓ $skill/converter/sql.mjs  ($(du -h "$out" | cut -f1))  [vendored from formulas.ts, custom export check]"
    # Domo is NOT added to STAMPED_DIRS: the shared post-loop block below writes
    # a PROVENANCE.json whose vendored_modules basename ("sql") differs from the
    # bundled source name ("formulas"). Write domo's own PROVENANCE.json here.
    cat > "$dest/PROVENANCE.json" <<EOF
{
  "bundler": "esbuild --bundle --format=esm --platform=node",
  "vendored_modules": "sql.mjs",
  "note": "Self-contained generated bundle; not source — do not hand-edit."
}
EOF
    echo "✓ $skill/converter/PROVENANCE.json  [domo's own — vendored_modules=sql.mjs]"
    continue
  fi

  entry="$SRC/build/$mod.js"
  [ -f "$entry" ] || { echo "FATAL: $entry missing (build the converter repo first)"; exit 1; }
  out="$dest/$mod.mjs"
  "$ESBUILD" "$entry" --bundle --format=esm --platform=node --outfile="$out" >/dev/null
  # sanity: the bundle must export a convert<Tool>ToSigma symbol
  node --input-type=module -e "
    import * as m from '$out';
    const fn = Object.keys(m).find(k => /^convert.*ToSigma\$/.test(k));
    if (!fn) { console.error('FATAL: $out exports no convert*ToSigma'); process.exit(1); }
  "
  echo "✓ $skill/converter/$mod.mjs  ($(du -h "$out" | cut -f1))"
  case "$STAMPED_DIRS" in *"|$dest|"*) : ;; *) STAMPED_DIRS="$STAMPED_DIRS|$dest|" ;; esac
done

# one PROVENANCE.json per touched skill converter dir (generic shape — domo
# is deliberately never added to STAMPED_DIRS; it writes its own complete
# PROVENANCE.json above, right after its bundle is built). A domo-only run
# leaves STAMPED_DIRS empty — guard the pipeline so `grep -v '^$'` finding no
# lines (exit 1) doesn't abort the script under `set -euo pipefail`.
if [ -n "$STAMPED_DIRS" ]; then
  echo "$STAMPED_DIRS" | tr '|' '\n' | grep -v '^$' | sort -u | while read -r dest; do
    [ -d "$dest" ] || continue
    mods=$(ls "$dest"/*.mjs 2>/dev/null | xargs -n1 basename | paste -sd, -)
    cat > "$dest/PROVENANCE.json" <<EOF
{
  "bundler": "esbuild --bundle --format=esm --platform=node",
  "vendored_modules": "$mods",
  "note": "Self-contained generated bundle; not source — do not hand-edit."
}
EOF
  done
fi

echo "Done — source $SHA ($DATE). Commit the converter/ diffs."
