#!/usr/bin/env bash
# logical-model-objectgraph — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
# This fixture's workbook-content.twb is GENUINE Tableau Server output (see
# MANIFEST.md's Provenance section) — published to a real Tableau site with a
# real Snowflake connection, then downloaded back. These checks are still
# offline/creds-free: they run the converter and the skill's own contract test
# against the vendored, already-served .twb; they do NOT re-publish or re-probe
# the live warehouse (that live-only evidence — M1 pagination, gate 16 —
# lives in MANIFEST.md's live validation section, not here, since it needs a
# live Sigma connection + warehouse this offline check suite deliberately does
# not have).
#
#   1. converter/tableau.mjs's object-graph relationship-derivation ladder
#      (PR2a) on this genuinely-served .twb produces EXACTLY the pinned
#      relationshipCoverage ledger: 5 serialized relationships, 4 wired (plain
#      physical key + mixed serialized/partial + computed-only-but-
#      name-inferred/partial + a 5th plain physical key), 1
#      recorded-but-unwired (computed-only, no shared key-shaped name) —
#      never silently dropped from the report.
#   2. The four WIRED join-key columns (CUSTOMER_KEY, PRODUCT_KEY, STORE_KEY,
#      REGION_KEY) on FACT_WIDE sit past metadata-record ordinal 50 (54, 57,
#      62, 63 of 64) — see MANIFEST.md's "Ordinal placement" note for what
#      this does and does not prove offline (the live M1 pagination proof
#      against the real warehouse table is documented there, not here).
#   3. plugins/tableau-to-sigma/skills/tableau-to-sigma's own
#      test-relationship-derivation.rb (the Task 2 contract test) passes
#      against this fixture at its default (no-override) path.
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma"
CONVERTER="$SKILL/converter/tableau.mjs"

command -v node >/dev/null || { echo "checks: node not found (required to run the converter)"; exit 1; }
command -v ruby >/dev/null || { echo "checks: ruby not found (required for the skill-script + comparison checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# Any absolute path baked as a literal string into the generated .mjs below
# is at risk on Windows: under Git Bash, `pwd`/`mktemp -d` (used to build
# CONVERTER/CASE_DIR/TMP) yield POSIX-looking paths like /d/a/... with no
# drive letter. Node/Windows treats a leading-slash-no-drive path as
# "rooted" — relative to the CURRENT drive — so /d/a/foo silently becomes
# D:\d\a\foo (the exact mangled path in this job's failure) instead of
# D:\a\foo. That corruption hits both the `import` specifier AND plain
# fs.readFileSync/writeFileSync arguments, since it's Windows' own path
# parsing, not something specific to ESM. (Paths passed as CLI arguments,
# e.g. `node "$TMP/_convert.mjs"` below, are fine — Git Bash auto-translates
# those before exec'ing the native node.exe; only paths embedded *inside*
# the file content are exposed.)
#
# Node ESM additionally rejects a bare drive-letter specifier
# (`import ... from "D:/path/tableau.mjs"` → ERR_UNSUPPORTED_ESM_URL_SCHEME,
# protocol 'd:') — import specifiers must be file:// URLs there, not just
# drive-qualified. Plain fs calls don't have that extra requirement; they
# just need a real drive letter.
#
# cygpath -m (present in Git Bash, absent on macOS/Linux) gives the mixed
# Windows form (D:/a/...) both fixes build on. Same guard as
# mechanical-specs.rb's run_converter and test-relationship-derivation.rb's
# shim — this is the bash twin of that Ruby fix.
if command -v cygpath >/dev/null 2>&1; then
  CONVERTER_URL="file:///$(cygpath -m "$CONVERTER")"
  CASE_DIR_NODE="$(cygpath -m "$CASE_DIR")"
  TMP_NODE="$(cygpath -m "$TMP")"
else
  CONVERTER_URL="$CONVERTER"
  CASE_DIR_NODE="$CASE_DIR"
  TMP_NODE="$TMP"
fi

# -- 1. relationshipCoverage ledger matches the pin exactly -------------------
cat > "$TMP/_convert.mjs" <<JS
import { readFileSync, writeFileSync } from 'node:fs';
import { convertTableauToSigma } from '$CONVERTER_URL';
const xml = readFileSync('$CASE_DIR_NODE/workbook-content.twb', 'utf8');
const out = convertTableauToSigma(xml, {
  connectionId: 'test-conn', database: 'TESTDB', schema: 'TESTSCHEMA', tableMapping: {},
});
writeFileSync('$TMP_NODE/coverage.json', JSON.stringify(out.relationshipCoverage, null, 2) + '\n');
JS
node "$TMP/_convert.mjs" 2>"$TMP/convert.err" || { note "FAIL: converter invocation failed"; sed -n '1,20p' "$TMP/convert.err"; fail=1; }

if [ -f "$TMP/coverage.json" ] && cmp -s <(tr -d "\r" < "$TMP/coverage.json") <(tr -d "\r" < "$CASE_DIR/relationship-coverage.expected.json"); then
  note "ok: relationshipCoverage matches relationship-coverage.expected.json (5 serialized, 4 wired, DIM_DATE recorded unwired)"
else
  note "FAIL: relationshipCoverage drifted from relationship-coverage.expected.json:"
  diff <(tr -d "\r" < "$CASE_DIR/relationship-coverage.expected.json") <(tr -d "\r" < "$TMP/coverage.json") 2>/dev/null | head -40
  fail=1
fi

# -- 2. the four wired join keys sit past metadata-record ordinal 50 ---------
ruby -e '
  raw = File.read(ARGV[0], encoding: "utf-8")
  records = raw.scan(%r{<metadata-record\b[^>]*>.*?</metadata-record>}m)
  bad = []
  { "CUSTOMER_KEY" => "Customer Key", "PRODUCT_KEY" => "Product Key",
    "STORE_KEY" => "Store Key", "REGION_KEY" => "Region Key" }.each do |key, caption|
    rec = records.find { |r| r.include?("<caption>#{caption}</caption>") }
    unless rec
      bad << "#{key}: metadata-record with caption #{caption.inspect} not found"
      next
    end
    ord = rec[/<ordinal>(\d+)<\/ordinal>/, 1]
    if ord.nil?
      bad << "#{key}: no <ordinal> found on its metadata-record"
    elsif ord.to_i <= 50
      bad << "#{key}: ordinal #{ord} is not past 50"
    end
  end
  abort bad.join("; ") unless bad.empty?
' "$CASE_DIR/workbook-content.twb" \
  && note "ok: CUSTOMER_KEY, PRODUCT_KEY, STORE_KEY, and REGION_KEY metadata-records sit past ordinal 50 on the 64-column FACT_WIDE" \
  || { note "FAIL: join-key ordinal placement check"; fail=1; }

# -- 3. the skill's own contract test passes against this fixture directly ---
( cd "$SKILL" && ruby scripts/test-relationship-derivation.rb ) > "$TMP/contract.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'ALL PASS' "$TMP/contract.out"; then
  note "ok: test-relationship-derivation.rb passes against this fixture at its default path"
else
  note "FAIL: test-relationship-derivation.rb did not pass (got exit $rc)"; sed -n '1,20p' "$TMP/contract.out"; fail=1
fi

exit "$fail"
