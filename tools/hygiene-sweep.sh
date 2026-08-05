#!/usr/bin/env bash
# tools/hygiene-sweep.sh — mechanical hygiene sweep: NO test-org or customer
# identifiers (connections, workbooks, customers, datasources, field/value
# literals, object ids) may appear in the repo or in anything about to enter it.
#
#   bash tools/hygiene-sweep.sh    # exit 0 clean, exit 1 named hits,
#                                  # exit 2 unusable setup (bad pattern, no repo)
#
# Six passes:
#   1) every tracked file (grep -I text scan), plus 1b) the INDEX blobs of
#      tracked files ABSENT from the worktree — a leak deleted with plain `rm`
#      instead of `git rm` stays committed while every worktree-shaped scan
#      goes blind to it
#   2) the staged diff — including the staged BLOBS of files whose gitattributes
#      unset `diff` (the `binary` macro / a bare `-diff` makes `git diff` emit
#      only "Binary files differ", zero greppable +lines)
#   3) every untracked, not-ignored file (litter is a leak the moment it is
#      staged — catch it while it is still only sitting in the tree)
#   4) encoding-aware: fixture files (.twb/.tds/.hyper), anything grep
#      classified as binary, AND every diff-unset tracked or untracked file
#      (gitattributes makes git grep -I skip those as "binary" even when their
#      bytes are plain text — one `* -diff` line must not excuse a file from
#      every content pass). Each candidate is scanned as UTF-16LE + UTF-16BE +
#      UTF-32LE + UTF-32BE + a NUL-stripped view + a strings view — never
#      trusting any single decoding or BOM.
#      NOT covered: members of DEFLATED zip containers (.twbx/.tdsx) — DEFLATE
#      defeats every text layer above, so a clean exit makes NO claim about
#      container contents. Keep containers out of the repo until a member
#      extractor lands here.
#   5) PATHS: tracked + untracked + staged file/directory NAMES against the
#      same patterns — a corpus dir or fixture named after a real workbook/org
#      has perfectly neutral content, which the content passes never see.
#   6) SYMLINK TARGETS: git stores a symlink as a mode-120000 blob whose
#      content is the target PATH — `git grep` skips link entries, `[ -f ]`
#      is false for them, and the path pass sees only the link's own name, so
#      a target path naming a customer would otherwise survive every pass.
# Passes 1–2 print committed-pattern hits verbatim (those patterns are public)
# but report private-guard hits redacted — file + pattern line number, never
# matched text; passes 1b and 3–6 redact to path + pattern line. Same
# convention as hygiene.yml (a private-guard hit printed verbatim would itself
# disclose what the guard protects).
#
# Run this before EVERY commit, alongside tools/check-shared.rb (both are wired
# into .githooks/run-governance-checks.sh). Patterns live in
# tools/hygiene-patterns.txt — one case-insensitive extended regex per line,
# '#' lines are comments. When a new test-specific identifier enters the
# vocabulary (a new field org, workbook, warehouse, or customer transcript),
# add its STABLE identifier there first, then write code/docs against the
# neutral replacement. Customer-derived guards live in the gitignored
# tools/hygiene-patterns.local.txt (CI injects the same set from the
# HYGIENE_PRIVATE_PATTERNS secret); without it the sweep WARNs — a clean exit
# with committed patterns only proves nothing about customer identifiers.
# Works on macOS bash 3.2 + BSD grep/iconv and on GNU (CI ubuntu).
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "hygiene-sweep: not a git repo" >&2; exit 2; }
cd "$root" || exit 2

patfile="tools/hygiene-patterns.txt"
localfile="tools/hygiene-patterns.local.txt"
[ -f "$patfile" ] || { echo "hygiene-sweep: $patfile missing" >&2; exit 2; }

# Strip comments/blank lines into per-source pattern files (committed and local
# hits get different reporting) plus the combined set; keep a numbered manifest
# ("<source> line <N>" per active pattern) for redacted reporting.
tmp="$(mktemp)"; tmpc="$(mktemp)"; tmpl="$(mktemp)"; tmpnum="$(mktemp)"; tmptxt="$(mktemp)"
tmpblob0="$(mktemp)"
trap 'rm -f "$tmp" "$tmpc" "$tmpl" "$tmpnum" "$tmptxt" "$tmpblob0"' EXIT
grep -vE '^\s*(#|$)' "$patfile" > "$tmpc"
committed_n="$(grep -c . "$tmpc" 2>/dev/null || true)"
awk 'NF && $0 !~ /^[[:space:]]*#/ {printf "committed line %d\t%s\n", FNR, $0}' "$patfile" > "$tmpnum"
local_n=0
# Private customer-derived guards (gitignored) — loaded when present.
if [ -f "$localfile" ]; then
  grep -vE '^\s*(#|$)' "$localfile" > "$tmpl"
  awk 'NF && $0 !~ /^[[:space:]]*#/ {printf "local line %d\t%s\n", FNR, $0}' "$localfile" >> "$tmpnum"
  local_n="$(grep -c . "$tmpl" 2>/dev/null || true)"
else
  echo "hygiene-sweep: WARN — $localfile not found; running with committed patterns only — customer guards inactive." >&2
fi
cat "$tmpc" "$tmpl" > "$tmp"
if ! [ -s "$tmp" ]; then
  echo "hygiene-sweep: no active patterns in $patfile" >&2
  exit 2
fi

# A pattern that fails to compile makes grep exit 2 — indistinguishable from
# "no hits" in every check below, so one typo in a pattern file would print a
# false clean. Refuse to run instead, naming only the pattern's source + line
# (its text may be a private guard).
while IFS="$(printf '\t')" read -r label rx; do
  printf '' | grep -qiE -- "$rx" 2>/dev/null
  if [ $? -gt 1 ]; then
    echo "hygiene-sweep: pattern does not compile ($label) — fix it before trusting this sweep" >&2
    exit 2
  fi
done < "$tmpnum"

fail=0
missing_n=0
sym_n=0

# NUL-separated file lists minus the pattern/sweep files themselves (they
# legitimately contain the patterns). Plain bash loops — avoids grep -z, which
# the macOS man page does not document.
list_tracked() {
  git ls-files -z | while IFS= read -r -d '' f; do
    case "$f" in
      tools/hygiene-patterns.txt|tools/hygiene-sweep.sh) ;;
      *) printf '%s\0' "$f" ;;
    esac
  done
}
list_untracked() {
  git ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do
    case "$f" in
      tools/hygiene-patterns.txt|tools/hygiene-sweep.sh|tools/hygiene-patterns.local.txt) ;;
      *) printf '%s\0' "$f" ;;
    esac
  done
}

# Tracked files ABSENT from the worktree (deleted with plain `rm`, or never
# checked out). git grep reads WORKTREE bytes, so pass 1 silently skips them;
# once index==HEAD the staged diff is empty too, and pass 4's `[ -f "$f" ]`
# drops them. Their INDEX/HEAD blob still carries whatever was committed.
list_missing_tracked() {
  git ls-files -z | while IFS= read -r -d '' f; do
    case "$f" in
      tools/hygiene-patterns.txt|tools/hygiene-sweep.sh) continue ;;
    esac
    [ -e "$f" ] || [ -L "$f" ] || printf '%s\0' "$f"
  done
}

# Report which pattern(s) hit, without the matched text (hygiene.yml redaction
# convention): "<path>: pattern <source> line <N>".
report_hits_redacted() { # <display-path> <scannable-text-file>
  p="$1"; scan="$2"
  while IFS="$(printf '\t')" read -r label rx; do
    grep -qiE -- "$rx" "$scan" 2>/dev/null && echo "$p: pattern $label" >&2
  done < "$tmpnum"
  return 0
}

# Minimal text layering for pass 1b (runs before extract_text is defined):
# raw bytes, NUL-stripped, both UTF-16 orders. Enough to see a committed leak
# in an index blob without duplicating the full encoding pass.
extract_text_lite() {
  local f; f="$1"
  cat "$f" 2>/dev/null; printf '\n'
  LC_ALL=C tr -d '\000' < "$f" 2>/dev/null; printf '\n'
  iconv -f UTF-16LE -t UTF-8 < "$f" 2>/dev/null; printf '\n'
  iconv -f UTF-16BE -t UTF-8 < "$f" 2>/dev/null; printf '\n'
  return 0
}

# Tracked-file scan, run once per pattern source in pass 1.
#   Fast path: git grep -P (multithreaded; PCRE covers the \b/\s classes the
#   patterns use — git's default ERE does NOT, it would silently drop \b).
#   Portable fallback: per-file BSD/GNU grep when this git lacks PCRE (the
#   probe dies — exit 128, "cannot use Perl-compatible regexes when not
#   compiled with USE_LIBPCRE" — on such builds). A PCRE fatal on the real
#   scan (rc >1) must never read as no-hits either: fall back the same way.
git grep -qP 'zz9hygiene_pcre_probe' -- . >/dev/null 2>&1
if [ $? -le 1 ]; then have_pcre=1; else have_pcre=0; fi
scan_tracked() { # <pattern-file> <n|l>   n: path:line:text, l: path only
  if [ "$have_pcre" -eq 1 ]; then
    out="$(git grep "-${2}IiP" -f "$1" -- . ':(exclude)tools/hygiene-patterns.txt' ':(exclude)tools/hygiene-sweep.sh' 2>/dev/null)"
    if [ $? -le 1 ]; then printf '%s\n' "$out"; return 0; fi
    echo "hygiene-sweep: git grep -P failed — falling back to portable ERE" >&2
  fi
  list_tracked | xargs -0 grep "-${2}IiE" -f "$1" -- 2>/dev/null
  return 0
}

# 1) Every tracked file. Binary files are skipped (-I) — pass 4 covers them.
hits="$(scan_tracked "$tmpc" n)"
if [ -n "$hits" ]; then
  echo "HYGIENE SWEEP FAILED — test-org identifiers in tracked files:" >&2
  printf '%s\n' "$hits" | head -100 >&2
  n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  [ "$n" -gt 100 ] && echo "  … and $((n - 100)) more hit(s)" >&2
  fail=1
fi
if [ "$local_n" -gt 0 ]; then
  l_hits="$(scan_tracked "$tmpl" l)"
  if [ -n "$l_hits" ]; then
    echo "HYGIENE SWEEP FAILED — private-guard hits in tracked files (redacted):" >&2
    printf '%s\n' "$l_hits" | while IFS= read -r f; do
      report_hits_redacted "$f" "$f"
    done
    fail=1
  fi
fi

# 1b) Tracked files ABSENT from the worktree: scan their INDEX blobs. Every
#     other pass is worktree- or diff-shaped and cannot see these.
miss_list="$(list_missing_tracked | tr '\0' '\n' | sed '/^$/d')"
if [ -n "$miss_list" ]; then
  missing_n="$(printf '%s\n' "$miss_list" | grep -c . || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git cat-file blob ":$f" > "$tmpblob0" 2>/dev/null || continue
    extract_text_lite "$tmpblob0" > "$tmptxt"
    if grep -qiE -f "$tmp" "$tmptxt" 2>/dev/null; then
      echo "HYGIENE SWEEP FAILED — identifiers in a TRACKED file MISSING from the worktree (its index/HEAD blob still carries them; use 'git rm', not 'rm'):" >&2
      report_hits_redacted "index:$f" "$tmptxt"
      fail=1
    fi
  done <<EOF0
$miss_list
EOF0
fi

# 2) The staged diff (catches leaks in files not yet tracked at HEAD, and in
#    hunks about to be committed) — same committed/private reporting split.
staged_src="$(git diff --cached -U0 -- . ':(exclude)tools/hygiene-patterns.txt' ':(exclude)tools/hygiene-sweep.sh' \
  | grep -E '^\+' | grep -viE '^\+\+\+')"
staged="$(printf '%s\n' "$staged_src" | grep -niIE -f "$tmpc" 2>/dev/null)"
if [ -n "$staged" ]; then
  echo "HYGIENE SWEEP FAILED — test-org identifiers in the STAGED diff:" >&2
  printf '%s\n' "$staged" | head -50 >&2
  fail=1
fi
if [ "$local_n" -gt 0 ] && [ -n "$staged_src" ]; then
  printf '%s\n' "$staged_src" > "$tmptxt"
  if grep -qiE -f "$tmpl" "$tmptxt" 2>/dev/null; then
    echo "HYGIENE SWEEP FAILED — private-guard hits in the STAGED diff (redacted):" >&2
    report_hits_redacted "staged diff" "$tmptxt"
    fail=1
  fi
fi

# 3) Untracked, not-ignored files — the litter class. Invisible to passes 1–2
#    until staged, at which point the leak has already happened. Redacted.
u_hits="$(list_untracked | xargs -0 grep -liIE -f "$tmp" -- 2>/dev/null)"
if [ -n "$u_hits" ]; then
  echo "HYGIENE SWEEP FAILED — identifiers in UNTRACKED files (delete or neutralize; never stage):" >&2
  printf '%s\n' "$u_hits" | while IFS= read -r f; do
    report_hits_redacted "$f" "$f"
  done
  fail=1
fi

# 4) Encoding-aware pass: fixture-format files (.twb/.twbx/.tds/.tdsx/.hyper),
#    anything grep -I classified as binary, and every diff-unset file (see
#    below), across tracked AND untracked. Every candidate gets both-endian
#    UTF-16 + UTF-32 iconv scans plus a strings scan. Redacted output.
all_list="$(mktemp)"; text_list="$(mktemp)"; path_list="$(mktemp)"; tmpblob="$(mktemp)"
trap 'rm -f "$tmp" "$tmpc" "$tmpl" "$tmpnum" "$tmptxt" "$tmpblob0" "$all_list" "$text_list" "$path_list" "$tmpblob"' EXIT
{ list_tracked; list_untracked; } | tr '\0' '\n' | sed '/^$/d' | sort -u > "$all_list"
{ list_tracked; list_untracked; } | xargs -0 grep -lI -e '' -- 2>/dev/null | sort -u > "$text_list"

extract_text() { # emit EVERY plausible text layer of one candidate on stdout
  # Never trust a single decoding or a BOM: UTF-32LE's BOM (ff fe 00 00)
  # STARTS WITH UTF-16LE's (ff fe), so a 2-byte sniff mis-decodes UTF-32 as
  # UTF-16 and finds nothing; BOM-less files have no marker at all, on any
  # extension. Emit both UTF-16 byte orders, both UTF-32 byte orders, and the
  # strings view for every candidate — grep scans the union, and a wrong
  # decoding is just noise that doesn't match.
  # `local`: callers pass paths like $tmpblob while looping over a global $f —
  # without it this assignment clobbers the caller's loop variable and the
  # staged-blob report names the mktemp file instead of the real path.
  local f
  f="$1"
  # printf '\n' between layers: a decode with no trailing newline glues its
  # last line to the next layer's first — BSD grep in a UTF-8 locale then
  # skips the merged line as invalid UTF-8 and a real hit goes unreported.
  iconv -f UTF-16LE -t UTF-8 < "$f" 2>/dev/null; printf '\n'
  iconv -f UTF-16BE -t UTF-8 < "$f" 2>/dev/null; printf '\n'
  iconv -f UTF-32LE -t UTF-8 < "$f" 2>/dev/null; printf '\n'
  iconv -f UTF-32BE -t UTF-8 < "$f" 2>/dev/null; printf '\n'
  # NUL-stripped view: a NUL planted INSIDE an identifier splits it across two
  # `strings` lines, so no regex can match either half. Deleting NULs rejoins
  # the token. (A NUL is never meaningful inside an identifier we guard.)
  LC_ALL=C tr -d '\000' < "$f" 2>/dev/null; printf '\n'
  if command -v strings >/dev/null 2>&1; then
    strings < "$f" 2>/dev/null
  else
    LC_ALL=C tr -c '[:print:]\n' '\n' < "$f" 2>/dev/null
  fi
  return 0
}

# gitattributes-aware coverage: an entry that unsets `diff` (the `binary`
# macro, or a bare `-diff`) makes git grep -I skip a file as "binary" even
# when its bytes are plain text — silently excusing it from pass 1 — while
# grep's own content heuristic still calls it text, so the comm -23 below
# would exclude it from this pass too. One .gitattributes line must never
# excuse a file from every content pass: force all diff-unset files through
# the encoding-aware scan. (Parses `git check-attr -z` NUL triplets:
# path/attr/value.)
diff_unset() { # <NUL-separated path producer on stdin> -> newline paths
  git check-attr --stdin -z diff 2>/dev/null \
    | while IFS= read -r -d '' p && IFS= read -r -d '' _a && IFS= read -r -d '' v; do
        [ "$v" = "unset" ] && printf '%s\n' "$p"
      done
  return 0
}

enc_candidates="$(
  {
    # .twbx/.tdsx (DEFLATED zip containers) are deliberately NOT routed here
    # by name: no text layer in extract_text can see through DEFLATE, so
    # listing them would advertise coverage this pass does not have. Committed
    # containers still arrive via the binary-classification rung below for the
    # (weak) strings scan — see the header for the explicit non-claim.
    grep -iE '\.(twb|tds|hyper)$' "$all_list" || true
    comm -23 "$all_list" "$text_list"   # binary-classified (or empty) files
    { list_tracked; list_untracked; } | diff_unset
  } | sort -u
)"
enc_scanned=0
enc_header=0
if [ -n "$enc_candidates" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    enc_scanned=$((enc_scanned + 1))
    extract_text "$f" > "$tmptxt"
    if grep -qiE -f "$tmp" "$tmptxt" 2>/dev/null; then
      if [ "$enc_header" -eq 0 ]; then
        echo "HYGIENE SWEEP FAILED — identifiers inside binary/non-UTF-8 files (encoding-aware pass):" >&2
        enc_header=1
      fi
      report_hits_redacted "$f" "$tmptxt"
      fail=1
    fi
  done <<EOF
$enc_candidates
EOF
fi

# 2b) Staged BLOBS of diff-unset files (pass-2 completion): for these,
#     `git diff --cached` prints only "Binary files differ" — zero +lines —
#     so the staged-diff greps above never see their content. Scan the staged
#     blob itself (not the worktree copy: they can differ). Redacted.
staged_unset="$(git diff --cached --name-only --diff-filter=ACM -z 2>/dev/null | diff_unset)"
if [ -n "$staged_unset" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git cat-file blob ":$f" > "$tmpblob" 2>/dev/null || continue
    extract_text "$tmpblob" > "$tmptxt"
    if grep -qiE -f "$tmp" "$tmptxt" 2>/dev/null; then
      echo "HYGIENE SWEEP FAILED — identifiers in a STAGED diff-unset file (gitattributes hid it from the diff pass; redacted):" >&2
      report_hits_redacted "staged:$f" "$tmptxt"
      fail=1
    fi
  done <<EOF2
$staged_unset
EOF2
fi

# 5) PATH scan: tracked + untracked + staged file/directory NAMES against the
#    same pattern set. A corpus case, view file, or fixture NAMED after a real
#    workbook/customer/LUID has perfectly neutral content — the content passes
#    above never look at names, and naming a fixture after its source is the
#    natural mistake. Reported as path + pattern source/line (the matched
#    span itself is never echoed separately).
{ list_tracked; list_untracked; git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null; } \
  | tr '\0' '\n' | sed '/^$/d' | sort -u > "$path_list"
p_hits="$(grep -iE -f "$tmp" "$path_list" 2>/dev/null)"
if [ -n "$p_hits" ]; then
  echo "HYGIENE SWEEP FAILED — identifiers in file/directory PATHS (rename them; content scans never see names):" >&2
  printf '%s\n' "$p_hits" | head -40 | while IFS= read -r p; do
    printf '%s' "$p" > "$tmptxt"
    report_hits_redacted "$p" "$tmptxt"
  done
  fail=1
fi

# 6) SYMLINK TARGETS: git stores a symlink as a mode-120000 blob whose CONTENT
#    is the target PATH. `git grep` skips those entries in both worktree and
#    blob mode, pass 4's `[ -f ]` is false for a link, and pass 5 sees the
#    link's own name — so a link pointing at a customer-named directory is
#    invisible to every pass above once committed. (Pass 2 catches it only in
#    the one commit that introduces it.)
SWTAB="$(printf '\t')"
sym_txt="$(mktemp)"
: > "$sym_txt"
git ls-files -s -z 2>/dev/null | while IFS= read -r -d '' e; do
  case "$e" in
    120000\ *) p="${e#*$SWTAB}"
      case "$p" in tools/hygiene-patterns.txt|tools/hygiene-sweep.sh) continue ;; esac
      printf '%s\t%s\n' "$p" "$(git cat-file blob ":$p" 2>/dev/null | tr -d '\n')" ;;
  esac
done >> "$sym_txt"
list_untracked | while IFS= read -r -d '' p; do
  [ -L "$p" ] && printf '%s\t%s\n' "$p" "$(readlink "$p" 2>/dev/null)"
done >> "$sym_txt"
sym_n="$(grep -c . "$sym_txt" 2>/dev/null || true)"
if [ -s "$sym_txt" ] && grep -qiE -f "$tmp" "$sym_txt" 2>/dev/null; then
  echo "HYGIENE SWEEP FAILED — identifiers in SYMLINK TARGET paths (git stores the target path as the blob; content scans never see it):" >&2
  grep -iE -f "$tmp" "$sym_txt" 2>/dev/null | cut -f1 | sort -u | while IFS= read -r p; do
    grep -iE -f "$tmp" "$sym_txt" 2>/dev/null | grep -F "$p$SWTAB" > "$tmptxt"
    report_hits_redacted "symlink:$p" "$tmptxt"
  done
  fail=1
fi
rm -f "$sym_txt"

if [ "$fail" -eq 0 ]; then
  total_n=$((committed_n + local_n))
  tracked_n="$(git ls-files | wc -l | tr -d ' ')"
  untracked_n="$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')"
  # tracked_n counts INDEX entries; missing_n of them are absent from the
  # worktree and were covered by the index-blob pass, not the worktree pass.
  # Say so — an unqualified "over N tracked" overstated the scan.
  echo "hygiene-sweep: clean ($total_n pattern(s) [$committed_n committed + $local_n local] over $tracked_n tracked ($missing_n via index blob) + $untracked_n untracked + $enc_scanned encoding-scanned + $sym_n symlink target(s) + all paths + staged diff)."
fi
exit "$fail"
