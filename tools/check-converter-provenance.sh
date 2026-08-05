#!/usr/bin/env bash
# tools/check-converter-provenance.sh — converter-provenance diff-pairing guard
# (the standing vendoring rule made mechanical, 2026-07-18).
#
#   bash tools/check-converter-provenance.sh <BASE> <HEAD>
#   bash tools/check-converter-provenance.sh --freshness [REF]
#   bash tools/check-converter-provenance.sh --online <sigma-data-model-mcp checkout>
#
# Fails (exit 1) when the BASE..HEAD range:
#   1) changes a vendored converter bundle (plugins/**/converter/*.mjs) without
#      its sibling PROVENANCE.json changing in the same range — a re-vendor
#      bumps source_commit; an in-place patch records itself in local_patches.
#      In-skill converters (PROVENANCE has "source", no "source_repo" — a
#      static body their rebuild rewrites byte-identical, so it can never
#      diff) may pair the bundle with a changed converter/*.ts source instead.
#   2) changes a converter PROVENANCE.json that no longer parses as JSON, or
#      whose local_patches entries drop the commit/summary/upstream_pr schema.
#   3) deletes a converter PROVENANCE.json while its bundle remains at HEAD.
#
# Callers resolve the range (hygiene.yml derives it from the CI event); the
# check itself is range-parameterized so tools/test-converter-provenance.sh
# can drive it against throwaway fixture repos offline.
#
# --freshness [REF] (default REF=HEAD) — STANDING gate, state-based rather
# than diff-based: a merge to sigma-data-model-mcp changes nothing for any
# operator until someone runs tools/vendor-converters.sh and commits the
# regenerated bundle, and nothing else in this repo notices when that hasn't
# happened. Pass 1/2 above only look at what changed in a push/PR range, so a
# bundle nobody has touched in months (pre-existing drift, not a regression in
# this diff) sails through clean forever. --freshness instead re-reads every
# plugins/**/converter/PROVENANCE.json at REF on EVERY run, independent of
# what changed, and flags any vendored (source_repo-bearing) entry whose
# source_commit_date is more than CONVERTER_STALENESS_DAYS (default 14) old.
#
#   Design trade-off (deliberate): CI cannot assume network access to the
#   private sigma-data-model-mcp repo, so this cannot ask upstream
#   "is there anything new" — the honest options were (a) a recorded
#   expected-latest-commit ledger a human bumps by hand, (b) an online mode
#   that soft-passes when unreachable, or (c) grading staleness by the AGE of
#   the recorded source_commit_date. Chosen: (c) as the default/CI-wired
#   gate, with (b) available locally (see --online below) for a human who
#   does have a checkout. Age needs no separate file to keep in sync (the
#   date is already written by vendor-converters.sh on every re-vendor) and
#   it catches BOTH failure modes from the same signal: a merge that missed
#   its follow-up vendor, and pre-existing drift nobody flagged. The honest
#   cost: age is a proxy, not proof — a converter whose upstream genuinely
#   hasn't changed in 14 days false-positives as "stale" (a human glance,
#   confirms nothing to do, no code changes needed); conversely a bundle
#   re-vendored yesterday against an upstream that merged something an hour
#   later won't be flagged until the window elapses. That is the accepted
#   latency of an offline check — --online below trades the "always
#   available" property back for a real comparison when a checkout exists.
#
#   cognos-to-sigma is not a false-flagged case: its PROVENANCE.json has no
#   source_repo/source_commit at all by design (converter/cli.ts is vendored
#   IN this repo, not from sigma-data-model-mcp — see tools/check-cognos-bundle.rb,
#   which is the freshness gate for THAT vendoring path). --freshness detects
#   this shape (no "source_repo" key, same test check-converter-provenance's
#   diff-pairing pass already uses) and reports it explicitly as
#   "in-skill, not applicable" rather than silently omitting the plugin or
#   miscounting its absent source_commit as staleness.
#
#   A STALE verdict also never implies "just re-vendor blindly": when the
#   flagged PROVENANCE.json carries a non-empty local_patches array (e.g.
#   tableau-to-sigma today), the report appends a note pointing at those
#   entries / _upstream_and_revendor_tasks instead — a naive re-vendor
#   overwrites PROVENANCE.json wholesale and drops any patch not yet landed
#   upstream (see TASK 3 in that file).
#
# --online <checkout> — OPTIONAL, NOT wired into CI (needs a local
# sigma-data-model-mcp clone + network to fetch it current). Compares each
# vendored plugin's recorded source_commit against the checkout's actual HEAD
# and reports whether the module's own src file changed since. Soft-passes
# (exit 0, warning only) when the checkout path is missing/not a git repo —
# this mode exists for a human doing a manual audit, not as a hard gate.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "python3 missing — provenance guard cannot run"; exit 1; }

# --freshness [REF] — standing staleness report, independent of any diff
# range (see header comment for the design/trade-off). Enumerates every
# plugins/**/converter/PROVENANCE.json at REF, classifies each as vendored
# (source_repo present) or in-skill (cognos-style — no source_repo), and for
# vendored entries flags source_commit_date older than CONVERTER_STALENESS_DAYS.
if [ "${1:-}" = "--freshness" ]; then
  REF="${2:-HEAD}"
  STALE_DAYS="${CONVERTER_STALENESS_DAYS:-14}"
  files="$(git ls-tree -r --name-only "$REF" -- plugins 2>/dev/null | grep -E '^plugins/.+/converter/PROVENANCE\.json$' | sort || true)"
  [ -n "$files" ] || { echo "no plugins/**/converter/PROVENANCE.json found at $REF"; exit 1; }
  printf '%s\n' "$files" | python3 -c "
import json, sys, datetime
ref = sys.argv[1]
stale_days = int(sys.argv[2])
paths = [l.strip() for l in sys.stdin if l.strip()]
today = datetime.date.today()
fail = False
print('%-24s %-12s %-12s %-6s  %s' % ('PLUGIN', 'SOURCE_COMMIT', 'PINNED', 'AGE_D', 'STATUS'))
for p in paths:
    plugin = p.split('/')[1]
    raw = __import__('subprocess').run(['git', 'show', '%s:%s' % (ref, p)], capture_output=True, text=True)
    if raw.returncode != 0:
        print('::error file=%s::cannot read PROVENANCE.json at %s' % (p, ref))
        fail = True
        continue
    try:
        d = json.loads(raw.stdout)
    except Exception as exc:
        print('::error file=%s::not valid JSON (%s) — freshness cannot be assessed' % (p, exc))
        fail = True
        continue
    if 'source_repo' not in d:
        # in-skill converter (cognos-style): vendors converter/*.ts IN this
        # repo, never from sigma-data-model-mcp. NONE/absent source_commit is
        # legitimate here — reported explicitly, not silently skipped, and
        # not counted as stale. Its own freshness gate is check-cognos-bundle.rb.
        print('%-24s %-12s %-12s %-6s  %s' % (plugin, 'n/a', 'n/a', 'n/a',
              'OK (in-skill converter, not vendored from sigma-data-model-mcp — '
              'see tools/check-cognos-bundle.rb)'))
        continue
    commit = d.get('source_commit')
    date_str = d.get('source_commit_date')
    if not commit or not date_str:
        print('::error file=%s::vendored converter (source_repo present) missing source_commit/source_commit_date — re-vendor via tools/vendor-converters.sh <sigma-data-model-mcp checkout> to record real provenance' % p)
        fail = True
        continue
    try:
        pinned = datetime.date.fromisoformat(date_str)
    except ValueError:
        print('::error file=%s::source_commit_date %r is not ISO YYYY-MM-DD' % (p, date_str))
        fail = True
        continue
    age = (today - pinned).days
    # vendor_arg (when present) is the RECORDED tools/vendor-converters.sh arg
    # for this plugin — needed because domo's module basename ("sql") is NOT
    # its vendor arg ("domo"); vendored_modules alone would suggest running
    # tools/vendor-converters.sh with the arg "sql", a silent no-op (not a
    # registered converter). NOTE: this comment intentionally avoids backticks
    # — this whole block is embedded in a bash python3 -c "..." DOUBLE-quoted
    # string, where a backtick pair triggers bash command substitution before
    # python ever sees the text (a real bug this exact comment tripped over).
    # Falls back to the vendored_modules-derived guess for the mainline 6,
    # which have no vendor_arg field and where the guess is correct (module
    # basename == vendor arg == upstream src file basename).
    vendor_arg = d.get('vendor_arg')
    if vendor_arg:
        mod = vendor_arg
    else:
        mod = (d.get('vendored_modules') or '').split(',')[0].strip()
        mod = mod[:-4] if mod.endswith('.mjs') else (mod or '<module>')
    if age > stale_days:
        # A bundle carrying an OPEN local_patches entry (not yet landed upstream) is
        # pinned ON PURPOSE — re-vendoring drops the patch. Hard-failing it demanded
        # exactly the action the note warns against. Measured live on quicksight, whose
        # UNDOCUMENTED native window-fn lowering was destroyed by a re-vendor:
        # rank/denseRank/percentileRank/percentOfTotal all fell to Null and broke
        # scripts/test-window-native.rb. So warn, don't block, and name what actually
        # unblocks it — porting the entry upstream.
        #
        # The gate keeps its teeth: stale with NO open entry still hard-fails, which is
        # the case it exists for (a bundle nobody remembered to refresh). "Open" means an
        # entry not describing itself as SUPERSEDED; a superseded entry has landed
        # upstream and no longer pins anything, so a re-vendor is safe and wanted.
        lp = d.get('local_patches')
        open_lp = [x for x in (lp or []) if isinstance(x, dict)
                   and 'SUPERSEDED' not in str(x.get('summary', '')).upper()]
        if open_lp:
            print('::warning file=%s::STALE BUT PINNED — %s at %s (%s, %dd old, exceeds %dd) '
                  'with %d OPEN local_patches entr%s. Do NOT re-vendor blind: it would drop '
                  'patches not yet landed upstream. Port each open entry upstream, retire it '
                  'here, then re-vendor. Not failing the build — the pin is deliberate.'
                  % (p, plugin, commit, date_str, age, stale_days,
                     len(open_lp), 'y' if len(open_lp) == 1 else 'ies'))
        else:
            note = ''
            if isinstance(lp, list) and lp:
                note = (' NOTE: local_patches entries are all SUPERSEDED (landed upstream), so a '
                        're-vendor is safe here and should also retire them.')
            print('::error file=%s::STALE — %s pinned at %s (%s, %dd old, exceeds %dd) — run: tools/vendor-converters.sh <sigma-data-model-mcp checkout> %s%s' % (p, plugin, commit, date_str, age, stale_days, mod, note))
            fail = True
    else:
        print('%-24s %-12s %-12s %-6d  %s' % (plugin, commit, date_str, age, 'OK — within %dd freshness window' % stale_days))
sys.exit(1 if fail else 0)
" "$REF" "$STALE_DAYS"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "converter-freshness guard FAILED (a bundle is stale, or its provenance is unreadable/incomplete)."
  else
    echo "converter-freshness guard OK ($REF, threshold ${STALE_DAYS}d)"
  fi
  exit $rc
fi

# --online <checkout> — optional, human-driven, NOT wired into CI (needs a
# local sigma-data-model-mcp clone; soft-passes when it's not there so it can
# never become a silent hard requirement). Compares each vendored plugin's
# recorded source_commit against the checkout's actual HEAD and reports
# whether the module's own src/<mod>.ts changed since that commit.
if [ "${1:-}" = "--online" ]; then
  CHECKOUT="${2:?usage: check-converter-provenance.sh --online <sigma-data-model-mcp checkout>}"
  if [ ! -d "$CHECKOUT/.git" ]; then
    echo "WARN: $CHECKOUT is not a git checkout — --online cannot compare; soft-passing (offline --freshness is the hard gate)"
    exit 0
  fi
  UP_HEAD="$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)" || {
    echo "WARN: could not resolve HEAD in $CHECKOUT — soft-passing"
    exit 0
  }
  files="$(git ls-tree -r --name-only HEAD -- plugins 2>/dev/null | grep -E '^plugins/.+/converter/PROVENANCE\.json$' | sort || true)"
  fail=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    d="$(git show "HEAD:$p" 2>/dev/null)"
    kind="$(printf '%s' "$d" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print("in-skill" if "source_repo" not in d else "vendored")')"
    [ "$kind" = "vendored" ] || continue
    commit="$(printf '%s' "$d" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("source_commit") or "")')"
    mod="$(printf '%s' "$d" | python3 -c 'import json,sys; m=(json.load(sys.stdin).get("vendored_modules") or "").split(",")[0].strip(); print(m[:-4] if m.endswith(".mjs") else m)')"
    # source_file (when present) is the RECORDED upstream path — needed
    # because domo vendors src/formulas.ts, not src/sql.ts (module basename
    # "sql" is unrelated to its real upstream source file). Falls back to the
    # src/<mod>.ts guess for the mainline 6, which have no source_file field
    # and where the guess is correct.
    recorded_srcfile="$(printf '%s' "$d" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("source_file") or "")')"
    [ -n "$commit" ] || continue
    srcfile="${recorded_srcfile:-src/$mod.ts}"
    if ! git -C "$CHECKOUT" cat-file -e "$UP_HEAD:$srcfile" 2>/dev/null; then
      echo "  ? $p: $srcfile not found at $CHECKOUT HEAD ($UP_HEAD) — skipping live compare for this module"
      continue
    fi
    if ! git -C "$CHECKOUT" cat-file -e "$commit" 2>/dev/null; then
      echo "  ? $p: recorded source_commit $commit not found in $CHECKOUT — cannot compute upstream delta"
      continue
    fi
    behind="$(git -C "$CHECKOUT" rev-list --count "$commit..$UP_HEAD" -- "$srcfile" 2>/dev/null || echo '?')"
    if [ "$behind" != "0" ] && [ "$behind" != "?" ]; then
      echo "  BEHIND $p: pinned $commit, upstream $UP_HEAD is $behind commit(s) ahead on $srcfile — re-vendor"
      fail=1
    else
      echo "  OK     $p: pinned $commit matches upstream $srcfile as of $UP_HEAD"
    fi
  done < <(printf '%s\n' "$files")
  [ "$fail" -eq 0 ] && echo "converter --online check: no live drift found vs $CHECKOUT ($UP_HEAD)" || echo "converter --online check: live drift found vs $CHECKOUT ($UP_HEAD) — see BEHIND lines above"
  exit $fail
fi

BASE="${1:?usage: check-converter-provenance.sh <BASE> <HEAD>}"
HEAD="${2:?usage: check-converter-provenance.sh <BASE> <HEAD>}"

# (python3 already checked above — the schema pin below needs it too.)

# An unresolvable range must fail, not read as an empty (green) change list.
changed="$(git diff --name-only "$BASE" "$HEAD")" || { echo "git diff $BASE..$HEAD failed — cannot check provenance pairing"; exit 1; }
fail=0

changed_has() { printf '%s\n' "$changed" | grep -qxF "$1"; }
at_head() { git cat-file -e "$HEAD:$1" 2>/dev/null; }
prov_kind() { # reads the HEAD copy; anything unparsable counts as vendored
  git show "$HEAD:$1" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("in-skill" if ("source" in d and "source_repo" not in d) else "vendored")
'
}

# Pass 1 — every changed bundle pairs with its provenance (or in-skill source).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  dir="$(dirname "$f")"
  sib="$dir/PROVENANCE.json"
  if changed_has "$sib" && at_head "$sib"; then
    continue
  fi
  if at_head "$sib" && [ "$(prov_kind "$sib")" = "in-skill" ]; then
    ts_paired=0
    while IFS= read -r c; do
      case "$c" in "$dir"/*.ts) ts_paired=1 ;; esac
    done <<< "$changed"
    [ "$ts_paired" -eq 1 ] && continue
    echo "::error file=$f::in-skill converter bundle changed without its converter/*.ts source (or PROVENANCE.json) changing — rebuild via tools/vendor-converters.sh from the edited TS source so bundle and source land together"
    fail=1
    continue
  fi
  echo "::error file=$f::vendored converter changed without its sibling PROVENANCE.json — re-vendor via tools/vendor-converters.sh (bumps source_commit) or record the in-place patch in local_patches"
  fail=1
done < <(printf '%s\n' "$changed" | grep -E '^plugins/.+/converter/[^/]+\.mjs$' || true)

# Pass 2 — schema-pin every changed converter PROVENANCE.json at HEAD.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! at_head "$p"; then
    if git ls-tree --name-only "$HEAD" "$(dirname "$p")/" 2>/dev/null | grep -q '\.mjs$'; then
      echo "::error file=$p::converter PROVENANCE.json deleted while the vendored bundle remains — restore it (the bundle's origin must stay recorded)"
      fail=1
    fi
    continue
  fi
  err="$(git show "$HEAD:$p" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as exc:
    print("not valid JSON (%s)" % exc); sys.exit(0)
lp = d.get("local_patches")
if lp is None:
    sys.exit(0)
if not isinstance(lp, list):
    print("local_patches must be an array"); sys.exit(0)
for i, entry in enumerate(lp):
    if not isinstance(entry, dict):
        print("local_patches[%d] must be an object" % i); sys.exit(0)
    missing = [k for k in ("commit", "summary", "upstream_pr") if k not in entry]
    if missing:
        print("local_patches[%d] missing key(s): %s" % (i, ", ".join(missing))); sys.exit(0)
')"
  if [ -n "$err" ]; then
    echo "::error file=$p::provenance schema pin failed — $err (every local_patches entry records commit, summary, upstream_pr)"
    fail=1
  fi
done < <(printf '%s\n' "$changed" | grep -E '^plugins/.+/converter/PROVENANCE\.json$' || true)

if [ "$fail" -ne 0 ]; then
  echo "converter-provenance guard FAILED (pair every converter/*.mjs change with its PROVENANCE.json)."
  exit 1
fi
echo "converter-provenance guard OK ($BASE..$HEAD)"
