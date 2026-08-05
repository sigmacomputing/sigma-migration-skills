#!/usr/bin/env bash
# Offline test for tools/hygiene-sweep.sh (E0.1 local-guard activation + E0.3
# untracked/encoding blind spots, 2026-07-18). test-doctor-json.sh style.
#
# Builds a throwaway fixture git repo (the real committed pattern file + the
# sweep under test copied in) and asserts:
#   Part A — clean fixture exits 0; WARN fires when no local pattern file exists
#   Part B — a synthetic local pattern raises the reported pattern count (WARN
#            gone) and a planted hit on it fails the sweep with the matched
#            text withheld (private-guard hits are redacted even in pass 1)
#   Part B2 — a malformed local pattern makes the sweep refuse to run (exit 2)
#            instead of printing a false clean while a tracked hit is present
#   Part C — generic secret shapes: colon-delimited tokens (credential-named
#            and bare *_PAT vars) and a bare 64-hex client-id literal fail;
#            short / assembled-at-runtime values and *_PATH path lists pass
#   Part D — a committed-pattern string in an UNTRACKED file fails the sweep,
#            naming the file with matched text withheld (redaction)
#   Part D2 — PATH identifiers: a tracked file NAMED with a blocked string
#            (content clean) fails the path pass; so does an untracked
#            directory name; a clean tree passes the path pass
#   Part E — the same string inside a tracked UTF-16LE .twb fails via the
#            encoding-aware pass, naming the file (redacted); BOM-less
#            fixtures (LE .twb, BE .tds) fail the same way — no BOM to trust,
#            either byte order; UTF-32LE (whose BOM starts with UTF-16LE's)
#            and BOM-less UTF-16 on NON-fixture extensions (.md) fail too
#   Part E2 — a `* -diff` .gitattributes line must not excuse a plain-text
#            tracked file (or a staged-only blob) from the sweep; the restore
#            is then ROUND-TRIPPED (re-plant must fail again) because "clean"
#            is a negative result a gutted sweep also produces
#   Part F — gitignored files are NOT swept (--exclude-standard respected)
#   Part G — restored-clean fixture exits 0 again (idempotence), and the clean
#            line attributes a plain-rm'd clean tracked file to the index-blob
#            pass instead of silently counting it as worktree-scanned
#   Part H — a tracked file DELETED with plain rm (leak lives only in the
#            index/HEAD blob) is still swept, named index:<file>, redacted
#   Part I — symlink TARGET paths are swept: committed mode-120000 blob and
#            untracked readlink, named symlink:<link>, redacted
#   Part J — a NUL planted INSIDE an identifier is rejoined by the sweep's
#            NUL-stripped view instead of splitting past every regex
# Between parts, part_boundary() asserts the fixture is exactly as clean as
# the next part assumes — a fixture-mutation command that fails silently must
# fail THERE, loudly, not corrupt every downstream assertion.
#
# Every planted string is assembled at runtime, so this test file itself never
# contains a blocked literal (the real repo's sweep scans this file too).
# Runs standalone:  bash tools/test-hygiene-sweep.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

# Fixture-integrity guard (per-part). A fixture-mutation command that fails
# SILENTLY corrupts every downstream assertion in this file — that is exactly
# how Part E2's `git rm --cached` failure came to bake a blocked string into
# the fixture's HEAD and make four "clean" assertions certify the sweep's
# blind spot. Assert at each part boundary that (a) nothing unexpected is
# staged/modified and (b) no part's plant survives in HEAD.
part_boundary() { # <label>
  _pb_dirty="$(git status --porcelain | grep -vE 'tools/hygiene-patterns.local.txt|ignored-litter.txt' || true)"
  [ -z "$_pb_dirty" ]
  check $? "fixture worktree/index is clean entering $1${_pb_dirty:+ [$_pb_dirty]}"
  _pb_res="$(git grep -lI -- "$blocked" HEAD -- . ':(exclude)tools/hygiene-patterns.txt' ':(exclude)tools/hygiene-sweep.sh' 2>/dev/null || true)"
  [ -z "$_pb_res" ]
  check $? "no planted string survives in HEAD entering $1${_pb_res:+ [$_pb_res]}"
}

# --- fixture repo ------------------------------------------------------------
FIX="$TMP/fixture"
mkdir -p "$FIX/tools"
cp "$HERE/hygiene-patterns.txt" "$FIX/tools/"
cp "$HERE/hygiene-sweep.sh" "$FIX/tools/"
cd "$FIX" || exit 1
git init -q
git config user.email hygiene-test@example.invalid
git config user.name hygiene-test
git config commit.gpgsign false
echo "a clean fixture file" > README.md
git add -A && git commit -q --no-verify -m fixture

RC=0
run_sweep() { bash tools/hygiene-sweep.sh >"$TMP/out" 2>"$TMP/err"; RC=$?; }
clean_count() { grep -oE '[0-9]+ pattern' "$TMP/out" | grep -oE '[0-9]+' | head -1; }

# A committed-pattern string, derived at runtime (a plain-lowercase-word pattern
# is its own matching literal — never write one into this file's source).
blocked="$(grep -m1 -E '^[a-z]+$' tools/hygiene-patterns.txt)"
[ -n "$blocked" ]; check $? "derived a plain-word committed pattern to plant (len ${#blocked})"

echo "Part A — clean fixture + WARN when the local guard file is absent"
run_sweep
[ "$RC" -eq 0 ]; check $? "clean fixture repo exits 0 (got $RC)"
grep -q "customer guards inactive" "$TMP/err"
check $? "WARN names inactive customer guards when local file is absent"
grep -q "0 local" "$TMP/out"; check $? "clean line reports 0 local patterns"
N1="$(clean_count)"
[ -n "$N1" ] && [ "$N1" -gt 0 ]; check $? "clean line reports the active pattern count ($N1)"

part_boundary "Part B"
echo "Part B — synthetic local pattern raises the count and flags a planted hit"
printf '# synthetic local guard for the test\nzz9synthguard[0-9]+\n' > tools/hygiene-patterns.local.txt
run_sweep
[ "$RC" -eq 0 ]; check $? "local file alone keeps the sweep clean (got $RC)"
! grep -q "customer guards inactive" "$TMP/err"
check $? "WARN is gone once the local file exists"
N2="$(clean_count)"
[ "$N2" = "$((N1 + 1))" ]; check $? "reported pattern count raised by the local pattern ($N1 -> $N2)"
grep -q "1 local" "$TMP/out"; check $? "clean line attributes the raise to local patterns"
echo "data zz9synthguard42 data" > data.txt
git add data.txt && git commit -q --no-verify -m plant
run_sweep
[ "$RC" -eq 1 ]; check $? "planted local-pattern hit fails the sweep (got $RC)"
grep -q "data.txt" "$TMP/err"; check $? "failure names the tracked file carrying the hit"
! grep -q "zz9synthguard42" "$TMP/err"
check $? "tracked private-guard hit withholds the matched text"
grep -q "pattern local line" "$TMP/err"
check $? "tracked private-guard hit cites the pattern's source + line instead"
git rm -q data.txt && git commit -q --no-verify -m unplant

part_boundary "Part B2"
echo "Part B2 — malformed local pattern refuses to run (exit 2, never a false clean)"
printf 'bad state: %s\n' "$blocked" > bad-state.txt
git add bad-state.txt && git commit -q --no-verify -m badstate
printf 'zz9unclosed[\n' >> tools/hygiene-patterns.local.txt
run_sweep
[ "$RC" -eq 2 ]; check $? "malformed local pattern exits 2 while a tracked hit exists (got $RC)"
! grep -q "clean" "$TMP/out"; check $? "no clean line is printed for the unusable pattern set"
grep -q "does not compile" "$TMP/err"; check $? "refusal says the pattern does not compile"
grep -q "local line 3" "$TMP/err"; check $? "refusal cites the pattern's source + line"
! grep -q "zz9unclosed" "$TMP/err" && ! grep -q "zz9unclosed" "$TMP/out"
check $? "refusal withholds the pattern text"
printf '# synthetic local guard for the test\nzz9synthguard[0-9]+\n' > tools/hygiene-patterns.local.txt
git rm -q bad-state.txt && git commit -q --no-verify -m nobadstate

part_boundary "Part C"
echo "Part C — generic secret shapes (committed patterns)"
# colon-delimited token: 18-char segments (each below the 32-char single-run rule)
s="$(printf 'Ab9%.0s' 1 2 3 4 5 6)"
printf 'TABLEAU_PAT_SECRET=%s:%s\n' "$s" "$s" > creds.txt
git add creds.txt && git commit -q --no-verify -m creds
run_sweep
[ "$RC" -eq 1 ]; check $? "colon-delimited token shape in credential context fails (got $RC)"
# bare *_PAT var (no SECRET suffix) exercises the anchored _PAT arm on its own
printf 'TABLEAU_PAT=%s:%s\n' "$s" "$s" > creds.txt
git add creds.txt && git commit -q --no-verify -m credspat
run_sweep
[ "$RC" -eq 1 ]; check $? "bare *_PAT assignment matches the anchored _PAT arm (got $RC)"
# bare 64-hex under an ID-suffixed var name
hex64="$(printf '0123456789abcdef%.0s' 1 2 3 4)"
printf 'SIGMA_CLIENT_ID=%s\n' "$hex64" > creds.txt
git add creds.txt && git commit -q --no-verify -m creds2
run_sweep
[ "$RC" -eq 1 ]; check $? "bare 64-hex literal adjacent to a client-id key fails (got $RC)"
# short / assembled-at-runtime values must pass
{
  printf 'TOKEN=short123\n'
  printf 'TABLEAU_PAT_SECRET="$(ruby scripts/get-token.rb)"\n'
  printf 'SIGMA_CLIENT_ID=$SIGMA_CLIENT_ID_FROM_ENV\n'
  # _PATH must never read as _PAT: a colon path list is not a credential
  printf 'export LD_LIBRARY_PATH=/opt/homebrewlonglib:/usr/local/verylonglib\n'
} > creds.txt
git add creds.txt && git commit -q --no-verify -m creds3
run_sweep
[ "$RC" -eq 0 ]; check $? "short / assembled-at-runtime / *_PATH-list values pass (got $RC)"
git rm -q creds.txt && git commit -q --no-verify -m nocreds

part_boundary "Part D"
echo "Part D — untracked litter is swept (and reported redacted)"
printf 'workdir state: %s\n' "$blocked" > untracked-litter.txt
run_sweep
[ "$RC" -eq 1 ]; check $? "committed-pattern string in an UNTRACKED file fails (got $RC)"
grep -q "UNTRACKED" "$TMP/err"; check $? "untracked failure uses its distinct header"
grep -q "untracked-litter.txt" "$TMP/err"; check $? "untracked failure names the file"
! grep -q "$blocked" "$TMP/err"
check $? "untracked report withholds the matched text (pattern line numbers only)"
rm -f untracked-litter.txt

part_boundary "Part D2"
echo "Part D2 — PATH identifiers: names are scanned even when content is clean"
# A corpus dir or fixture NAMED after a real workbook/org has perfectly
# neutral content — only the path pass can see it.
mkdir -p sub
printf 'perfectly neutral content\n' > "sub/${blocked}-case.md"
git add "sub/${blocked}-case.md" && git commit -q --no-verify -m plantpath
run_sweep
[ "$RC" -eq 1 ]; check $? "tracked file NAMED with a blocked string fails (got $RC)"
grep -q "PATHS" "$TMP/err"; check $? "failure uses the path-pass header"
grep -q "pattern committed line" "$TMP/err"
check $? "path hit cites the pattern source + line"
git rm -q "sub/${blocked}-case.md" && git commit -q --no-verify -m unplantpath
mkdir -p "${blocked}-workdir"
printf 'neutral notes\n' > "${blocked}-workdir/notes.txt"
run_sweep
[ "$RC" -eq 1 ]; check $? "untracked directory NAMED with a blocked string fails (got $RC)"
rm -rf "${blocked}-workdir"
run_sweep
[ "$RC" -eq 0 ]; check $? "path pass is clean again after the renames (got $RC)"

part_boundary "Part D3"
echo "Part D3 — run-state registry litter under corpus/fixture trees (E7.1)"
# The LOCAL probe registry must never enter a corpus or fixture tree. The
# planted path is assembled at runtime so this test file never contains the
# blocked path literal (the real repo's sweep scans this file too); the
# registry CONTENT is neutral by design — only the path pass can see it.
regbase="probe-artifacts"
mkdir -p corpus/wb1
printf '{"id":"wb-zz9probe1"}\n' > "corpus/wb1/${regbase}.jsonl"
git add -f "corpus/wb1/${regbase}.jsonl" && git commit -q --no-verify -m regplant
run_sweep
[ "$RC" -eq 1 ]; check $? "tracked corpus registry litter fails the sweep (got $RC)"
grep -q "PATHS" "$TMP/err"; check $? "registry-litter hit comes from the path pass"
git rm -q "corpus/wb1/${regbase}.jsonl" && git commit -q --no-verify -m unregplant
rmdir corpus/wb1 corpus 2>/dev/null
mkdir -p fixtures/case-a
printf '{"id":"wb-zz9probe2"}\n' > "fixtures/case-a/${regbase}.jsonl"
run_sweep
[ "$RC" -eq 1 ]; check $? "untracked fixture-tree registry litter fails too (got $RC)"
rm -rf fixtures
# No-false-trip side: a workdir-homed registry OUTSIDE corpus/fixture trees is
# legitimate local state (gitignored in the real repo) — the path guard must
# not fire on the filename alone.
mkdir -p workdir-demo
printf '{"id":"wb-zz9probe3"}\n' > "workdir-demo/${regbase}.jsonl"
run_sweep
[ "$RC" -eq 0 ]; check $? "registry outside corpus/fixture trees does NOT trip (got $RC)"
rm -rf workdir-demo
run_sweep
[ "$RC" -eq 0 ]; check $? "clean again with the planted registries gone (got $RC)"

part_boundary "Part E"
echo "Part E — UTF-16LE .twb is swept via the encoding-aware pass"
{ printf '\377\376'; printf '<workbook name="%s"/>\n' "$blocked" | iconv -f UTF-8 -t UTF-16LE; } > fixture-utf16.twb
git add fixture-utf16.twb && git commit -q --no-verify -m twb
run_sweep
[ "$RC" -eq 1 ]; check $? "planted string inside a UTF-16LE .twb fails (got $RC)"
grep -q "fixture-utf16.twb" "$TMP/err"; check $? "encoding-pass failure names the .twb"
grep -q "encoding-aware" "$TMP/err"; check $? "failure uses the encoding-pass header"
! grep -q "$blocked" "$TMP/err"
check $? "encoding-pass report withholds the matched text"
git rm -q fixture-utf16.twb && git commit -q --no-verify -m notwb
# BOM-less variants: iconv's byte-order-explicit UTF-16LE/BE encoders emit no
# BOM (one is "neither necessary nor permitted" there), so these exercise the
# extension branch that must trust neither byte order.
printf '<workbook name="%s"/>\n' "$blocked" | iconv -f UTF-8 -t UTF-16LE > fixture-nobom.twb
git add fixture-nobom.twb && git commit -q --no-verify -m twbnobom
run_sweep
[ "$RC" -eq 1 ]; check $? "planted string inside a BOM-less UTF-16LE .twb fails (got $RC)"
grep -q "fixture-nobom.twb" "$TMP/err"; check $? "BOM-less LE failure names the .twb"
! grep -q "$blocked" "$TMP/err"
check $? "BOM-less LE report withholds the matched text"
git rm -q fixture-nobom.twb && git commit -q --no-verify -m notwbnobom
printf '<datasource name="%s"/>\n' "$blocked" | iconv -f UTF-8 -t UTF-16BE > fixture-nobom.tds
git add fixture-nobom.tds && git commit -q --no-verify -m tdsnobom
run_sweep
[ "$RC" -eq 1 ]; check $? "planted string inside a BOM-less UTF-16BE .tds fails (got $RC)"
grep -q "fixture-nobom.tds" "$TMP/err"; check $? "BOM-less BE failure names the .tds"
grep -q "encoding-aware" "$TMP/err"; check $? "BOM-less BE failure comes from the encoding pass"
! grep -q "$blocked" "$TMP/err"
check $? "BOM-less BE report withholds the matched text"
git rm -q fixture-nobom.tds && git commit -q --no-verify -m notdsnobom
# UTF-32LE with BOM: its BOM (ff fe 00 00) STARTS WITH UTF-16LE's (ff fe) — a
# 2-byte BOM sniff would decode it as UTF-16LE, find nothing, and stop. Use a
# NON-fixture extension so no extension branch can rescue the scan either.
{ printf '\377\376\000\000'; printf 'notes org %s end\n' "$blocked" | iconv -f UTF-8 -t UTF-32LE; } > fixture-utf32.md
git add fixture-utf32.md && git commit -q --no-verify -m utf32
run_sweep
[ "$RC" -eq 1 ]; check $? "planted string inside a BOM'd UTF-32LE .md fails (got $RC)"
grep -q "fixture-utf32.md" "$TMP/err"; check $? "UTF-32 failure names the file"
! grep -q "$blocked" "$TMP/err"
check $? "UTF-32 report withholds the matched text"
git rm -q fixture-utf32.md && git commit -q --no-verify -m noutf32
# BOM-less UTF-16LE on a NON-fixture extension: neither a BOM nor the
# .twb/.tds extension list can route this one — only decode-everything does.
printf 'plain notes %s end\n' "$blocked" | iconv -f UTF-8 -t UTF-16LE > fixture-nobom.md
git add fixture-nobom.md && git commit -q --no-verify -m mdnobom
run_sweep
[ "$RC" -eq 1 ]; check $? "planted string inside a BOM-less UTF-16LE .md fails (got $RC)"
grep -q "fixture-nobom.md" "$TMP/err"; check $? "BOM-less .md failure names the file"
git rm -q fixture-nobom.md && git commit -q --no-verify -m nomdnobom

part_boundary "Part E2"
echo "Part E2 — a '* -diff' .gitattributes line must not excuse text files"
# gitattributes that unset `diff` (the `binary` macro / bare `-diff`) make
# git grep -I skip a plain-text file and `git diff --cached` print only
# "Binary files differ" — one line must never excuse a file from every pass.
printf '* -diff\n' > .gitattributes
printf 'attr smuggle: %s\n' "$blocked" > smuggled.md
git add .gitattributes smuggled.md && git commit -q --no-verify -m smuggle
run_sweep
[ "$RC" -eq 1 ]; check $? "plain-text tracked file under '* -diff' still fails (got $RC)"
grep -q "smuggled.md" "$TMP/err"; check $? "failure names the diff-unset file"
git rm -q smuggled.md && git commit -q --no-verify -m unsmuggle
# Staged-only: the leak exists ONLY in the staged blob (worktree neutralized) —
# the diff pass sees zero +lines, so the staged-blob scan must catch it.
printf 'staged smuggle: %s\n' "$blocked" > staged-smuggle.md
git add staged-smuggle.md
printf 'worktree copy is neutral\n' > staged-smuggle.md
run_sweep
[ "$RC" -eq 1 ]; check $? "STAGED blob of a diff-unset file is scanned (got $RC)"
grep -q "staged:staged-smuggle.md" "$TMP/err"; check $? "failure names the staged blob"
# `git rm --cached` (no -f) REFUSES here: the staged blob differs from BOTH
# the worktree copy and HEAD. Unchecked, it left the leak staged, the next
# commit baked it into the fixture's HEAD, and every downstream "clean"
# assertion (this one, Part F, both Part G checks) then asserted that the
# sweep MISSES a committed leak. `-f` with `--cached` does not touch the
# worktree file, so the `rm -f` below is still required.
git rm -q -f --cached staged-smuggle.md
check $? "staged-only plant is unstaged cleanly (git rm --cached -f)"
rm -f staged-smuggle.md
# Positive restore assertion: a bare `[ $RC -eq 0 ]` cannot tell "the fixture
# is clean" from "the sweep is blind". Prove the plant left no trace FIRST.
[ -z "$(git ls-files -- staged-smuggle.md)" ] && ! git cat-file -e HEAD:staged-smuggle.md 2>/dev/null
check $? "staged-only plant left no tracked/HEAD trace before the clean-again assertion"
git rm -q .gitattributes && git commit -q --no-verify -m unattr
run_sweep
[ "$RC" -eq 0 ]; check $? "fixture clean again with the attribute gone (got $RC)"
# Round-trip the restore: "clean" is a NEGATIVE result that a broken sweep
# also produces, so prove detection SURVIVED the restore by re-planting the
# same string and requiring the failure back. A gutted sweep passes the
# clean-again check above and fails this one.
printf 'replant probe: %s\n' "$blocked" > replant-probe.md
git add replant-probe.md && git commit -q --no-verify -m replant
run_sweep
[ "$RC" -eq 1 ]; check $? "sweep still DETECTS after the restore (re-plant round-trip, got $RC)"
git rm -q replant-probe.md && git commit -q --no-verify -m unreplant
run_sweep
[ "$RC" -eq 0 ]; check $? "fixture clean again after the re-plant round-trip (got $RC)"

part_boundary "Part F"
echo "Part F — gitignored files are not swept"
echo "ignored-litter.txt" > .gitignore
git add .gitignore && git commit -q --no-verify -m ignore
printf 'ignored: %s\n' "$blocked" > ignored-litter.txt
run_sweep
[ "$RC" -eq 0 ]; check $? "pattern hit in a gitignored file stays exempt (got $RC)"
rm -f ignored-litter.txt

part_boundary "Part G"
echo "Part G — restored fixture is clean again (idempotence)"
run_sweep
[ "$RC" -eq 0 ]; check $? "fixture repo sweeps clean after all plants removed (got $RC)"
grep -q "encoding-scanned" "$TMP/out"
check $? "clean line reports the encoding-scanned file count"
grep -q "0 symlink target(s)" "$TMP/out"
check $? "clean line reports the symlink-target count"
# Honest accounting: `git ls-files | wc -l` counts INDEX entries, so a
# plain-rm'd CLEAN tracked file used to be reported as scanned when no pass
# ever opened it. The clean line must attribute it to the index-blob pass.
rm -f README.md
run_sweep
[ "$RC" -eq 0 ]; check $? "clean tracked file deleted with plain rm still sweeps clean (got $RC)"
grep -q "(1 via index blob)" "$TMP/out"
check $? "clean line attributes the worktree-absent file to the index-blob pass"
git checkout -q -- README.md
check $? "plain-rm'd clean file is restored for the parts below"

part_boundary "Part H"
echo "Part H — a tracked file DELETED with plain rm is still swept (index blob)"
printf 'rm-not-git-rm: %s\n' "$blocked" > vanished.md
git add vanished.md && git commit -q --no-verify -m vanish
rm -f vanished.md                               # plain rm, NOT git rm
run_sweep
[ "$RC" -eq 1 ]; check $? "tracked-but-missing file is scanned via its index blob (got $RC)"
grep -q "index:vanished.md" "$TMP/err"; check $? "failure names the index blob and the file"
! grep -q "$blocked" "$TMP/err"; check $? "index-blob report withholds the matched text"
git rm -q vanished.md && git commit -q --no-verify -m unvanish

part_boundary "Part I"
echo "Part I — symlink TARGET paths are swept (committed and untracked)"
ln -s "/var/data/${blocked}-prod/rep.twb" symref
git add symref && git commit -q --no-verify -m symplant
run_sweep
[ "$RC" -eq 1 ]; check $? "COMMITTED symlink whose target names a blocked string fails (got $RC)"
grep -q "symlink:symref" "$TMP/err"; check $? "failure names the link (not its target text)"
! grep -q "$blocked" "$TMP/err"; check $? "symlink report withholds the matched text"
git rm -q symref && git commit -q --no-verify -m unsymplant
ln -s "/var/data/${blocked}-prod/rep.twb" symref2
run_sweep
[ "$RC" -eq 1 ]; check $? "UNTRACKED symlink target is swept too (got $RC)"
rm -f symref2

part_boundary "Part J"
echo "Part J — a NUL planted INSIDE an identifier does not split it past the sweep"
h="$(printf '%s' "$blocked" | cut -c1-4)"; t="$(printf '%s' "$blocked" | cut -c5-)"
[ -n "$t" ]; check $? "split point falls INSIDE the planted word (len ${#blocked} > 4, else this part is vacuous)"
printf 'owner: %s\000%s internal\n' "$h" "$t" > nul-split.txt
git add nul-split.txt && git commit -q --no-verify -m nulplant
run_sweep
[ "$RC" -eq 1 ]; check $? "NUL-split identifier is rejoined and caught (got $RC)"
git rm -q nul-split.txt && git commit -q --no-verify -m unnulplant
printf 'owner: %s\000%s internal\n' "$h" "$t" > nul-split.txt
run_sweep
[ "$RC" -eq 1 ]; check $? "NUL-split identifier in an UNTRACKED file is caught (got $RC)"
rm -f nul-split.txt

part_boundary "end of suite"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
