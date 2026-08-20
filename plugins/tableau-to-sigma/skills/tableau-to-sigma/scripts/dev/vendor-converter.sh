#!/usr/bin/env bash
# vendor-converter.sh — refresh the COMMITTED, zero-config Tableau→Sigma converter
# that ships inside this skill at converter/tableau.mjs.
#
# Unlike fetch-converter.sh (which clones+builds into a gitignored vendor/ dir for
# devs), this BUNDLES the built converter into a single self-contained ESM file and
# commits it, so local conversion works for everyone with NO clone, NO npm install,
# and NO network — the guaranteed local fallback migrate-tableau.rb auto-discovers
# last. A single bundled file (esbuild) means no node_modules to commit and no
# .gitignore fight; its only runtime requirement is `node` on PATH.
#
# The vendored snapshot can drift from the live converter. That is the accepted
# trade for a zero-setup, no-data-egress default; a dev's own local checkout (or
# TABLEAU_MCP_BUILD / SIGMA_CONVERTER_SRC / fetch-converter.sh) still WINS over the
# vendored copy, so the floor only kicks in when nothing fresher exists. Re-run this
# after the converter source changes and commit the result.
#
#   SIGMA_CONVERTER_SRC=/path/to/converter-source ./scripts/dev/vendor-converter.sh
#   ./scripts/dev/vendor-converter.sh /path/to/converter-source   # or pass it explicitly
#
# Requires: a converter-source checkout with esbuild installed (its devDep) +
# git for provenance stamping.
set -euo pipefail

SRC="${1:-${SIGMA_CONVERTER_SRC:-}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # skill root
DEST="$HERE/converter"
ENTRY="$SRC/build/tableau.js"
OUT="$DEST/tableau.mjs"

[ -n "$SRC" ] || { echo "FATAL: no converter source — pass a checkout path or set SIGMA_CONVERTER_SRC"; exit 1; }
[ -d "$SRC" ] || { echo "FATAL: converter source not found: $SRC (pass a path to a converter-source checkout)"; exit 1; }

# Build the converter if its entry artifact is missing.
if [ ! -f "$ENTRY" ]; then
  echo "→ $ENTRY missing — building (npm ci && npm run build)"
  ( cd "$SRC" && { npm ci --silent || npm install --silent; } && npm run build --silent )
fi
[ -f "$ENTRY" ] || { echo "FATAL: $ENTRY still missing after build"; exit 1; }

ESBUILD="$SRC/node_modules/.bin/esbuild"
[ -x "$ESBUILD" ] || { echo "FATAL: esbuild not found at $ESBUILD — run 'npm install' in $SRC first"; exit 1; }

echo "→ bundling converter closure into $OUT (single self-contained ESM file)"
mkdir -p "$DEST"
"$ESBUILD" "$ENTRY" --bundle --format=esm --platform=node --outfile="$OUT" >/dev/null

# Sanity: the bundle must export convertTableauToSigma and pull in NO external module.
node --input-type=module -e "import { convertTableauToSigma } from '$OUT'; if (typeof convertTableauToSigma !== 'function') { console.error('FATAL: bundle does not export convertTableauToSigma'); process.exit(1); }"

# Record provenance for the committed bundle (self-contained artifact, not source).
cat > "$DEST/PROVENANCE.json" <<EOF
{
  "bundler": "esbuild --bundle --format=esm --platform=node",
  "vendored_modules": "tableau.mjs",
  "note": "Self-contained generated bundle; not source — do not hand-edit."
}
EOF

echo "✓ vendored converter ready: $OUT"
echo "  migrate-tableau.rb auto-discovers it as the guaranteed local fallback — commit the diff."
