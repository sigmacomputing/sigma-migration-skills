#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-twb-encoding.rb — F5 crash-class gate (beads tt3z.24 + tt3z.17).
#
# `File.read(path)` uses the locale's default external encoding; on a US-ASCII CI
# runner (and on Windows) it raises Encoding::CompatibilityError the moment the
# file holds a non-ASCII byte — which has silently crashed migrations 3+ times on
# real .twb/XML/layout content ("F5 crash class"). Any read of a .twb / xml /
# layout file MUST pass `encoding: 'UTF-8'`.
#
# This is the single source of truth for that gate: CI (corpus-check.yml) and the
# local pre-push hook (.githooks/run-governance-checks.sh) both call it, so the
# regex can't drift between them. Scans BOTH `plugins/` and `shared/` — the old
# inline CI grep only scanned plugins/tableau-to-sigma, so a #388-class unencoded
# read in shared/ or another plugin was invisible until it hit a non-ASCII file.
#
# RULE 2 (issue #752) — the .twb-token rule above could not see the crash that
# actually shipped. assert-phase6-ran.rb did `File.read(jp_dm)` on a dm-spec.JSON
# and then `.scan`'d the raw string: `jp_dm` matches no .twb token, and RULE 1's
# EXCLUDE drops `.json` outright, so the site was never even a candidate. Under an
# unset locale one em-dash in that file made the gate exit 1 instead of its real
# verdict.
#
# What actually distinguishes a crash from a false alarm is NOT the extension —
# it is whether the raw string gets pattern-matched. `JSON.parse(File.read(x))` is
# safe at any locale (verified: JSON.parse re-tags and returns UTF-8), which is
# why RULE 1 was right to exclude it. But a RAW read whose result is later
# regex'd/`scan`'d raises `invalid byte sequence in US-ASCII (ArgumentError)`.
# So RULE 2 ignores the path entirely and asks: raw read -> assigned -> matched?
#
# Exit 0 = clean; exit 1 = at least one offending read (prints each site).
# RULE 1 is a faithful port of the former inline grep pipeline:
#   grep -rnE "File\.read\(([^)]*\b(twb|INP|disc_log)\b[^)]*)\)"  (case-sensitive)
#     | grep -v "encoding:"                                       (case-sensitive)
#     | grep -viE "JSON\.parse|\.json|\.rb'|File\.write"          (case-insensitive)

# LINT_ROOT lets tools/test-lint-twb-encoding.rb drive this against throwaway
# fixture trees offline, the same way check-plugin-version-bump.sh is
# range-parameterized. Unset in CI and in the hook — they lint the real repo.
ROOT = ENV['LINT_ROOT'] || File.expand_path('..', __dir__)
Dir.chdir(ROOT)

# File.read(...) whose argument mentions a .twb-ish path token. Matches `twb` as a
# whole word AND as an identifier suffix (`rank_twb`, `wb_twb`) — the CI grep's
# `\btwb\b` silently skipped the `_twb` suffix form, which is exactly how half of
# the #388 unencoded read (opts[:rank_twb]) slipped past the gate.
TOKEN     = /File\.read\(([^)]*(?:\btwb\b|_twb\b|\bINP\b|\bdisc_log\b)[^)]*)\)/
# Already-safe or not-a-.twb reads to skip (case-insensitive, mirrors grep -vi).
EXCLUDE   = /JSON\.parse|\.json|\.rb'|File\.write/i

# RULE 2: `<var> = ... File.read(...) ...` with no `encoding:` on that line and no
# JSON.parse wrapping it. Captures the assigned variable so we can ask whether the
# raw string is later pattern-matched.
RAW_ASSIGN = /^\s*(?:@|\$)?([a-z_][a-zA-Z_0-9]*)\s*(?:\|\|)?=\s*(.*File\.read\(.*)$/
# Operations that run a REGEXP over the string — these are what raise on a
# locale-tagged string with a high byte. Plain equality, include?, length, and
# byte-oriented work are all safe, so they are deliberately not listed.
MATCH_OPS = /\.(?:scan|match\??|gsub!?|sub!?|slice|index|rindex|partition|rpartition|split|start_with\?|end_with\?|count)\(\s*[%\/]|\.(?:scan|match\??|gsub!?|sub!?)\(|=~|!~/

# Reads of SOURCE text rather than migration data. A test asserting on its own
# script's body, or a renderer slurping a committed .md template, is a far lower
# risk than a workdir artifact carrying customer prose — and if it does trip, it
# fails loudly in CI rather than mid-migration. RULE 1 already excludes `.rb'` for
# exactly this reason; RULE 2 keeps the same scope so the two rules agree.
SOURCE_READ = /\.(?:rb|mjs|js|py|md|ps1|sh|txt|tpl|erb)['"]|__FILE__|__dir__\s*,\s*['"][^'"]*\.(?:rb|mjs|py|md)/
# Test files: the gate exists to protect migration RUNS. A locale-fragile
# assertion helper is a CI problem, not a field crash, and sweeping 75 of them
# into this gate would bury the one site that actually shipped broken.
TEST_FILE   = %r{(?:^|/)(?:test[-_][^/]*|[^/]*[-_]test)\.rb$|/tests?/}

def rule2_hits(file, src)
  return [] if file =~ TEST_FILE
  out = []
  lines = src.lines
  lines.each_with_index do |line, i|
    next unless (m = line.match(RAW_ASSIGN))
    var, rhs = m[1], m[2]
    next if rhs.include?('encoding:')          # already safe
    next if rhs =~ /JSON\.parse/               # parsed, not pattern-matched — safe
    next if rhs =~ SOURCE_READ                 # reading source/template text, not migration data
    # Does anything after this line run a regexp over `var`?
    used = lines[(i + 1)..]&.each_with_index&.find do |l, _|
      l =~ /(?<![a-zA-Z_0-9])#{Regexp.escape(var)}\s*(?:\.[a-z_]+\s*)*?#{MATCH_OPS}/ ||
        l =~ /(?<![a-zA-Z_0-9])#{Regexp.escape(var)}\s*(?:=~|!~)/ ||
        l =~ /(?<![a-zA-Z_0-9])#{Regexp.escape(var)}\.(?:scan|match\??|gsub!?|sub!?|split)\(/
    end
    next unless used
    out << "#{file}:#{i + 1}: #{line.strip}\n" \
            "      -> raw string pattern-matched at #{file}:#{i + 2 + used[1]}: #{used[0].strip}"
  end
  out
end

hits = []
rule2 = []
%w[plugins shared].each do |dir|
  next unless Dir.exist?(dir)
  Dir.glob(File.join(dir, '**', '*.rb')).sort.each do |f|
    src = File.read(f, encoding: 'UTF-8')
    src.each_line.with_index(1) do |line, n|
      next unless line =~ TOKEN
      next if line.include?('encoding:')   # already sets an encoding — safe
      next if line =~ EXCLUDE
      hits << "#{f}:#{n}: #{line.strip}"
    end
    rule2.concat(rule2_hits(f, src))
  end
end

if hits.empty? && rule2.empty?
  puts 'OK: no unencoded .twb/XML File.read sites, and no raw read feeding a regexp (plugins/ + shared/).'
  exit 0
end

unless hits.empty?
  warn "::error::File.read on a .twb without encoding: 'UTF-8' (F5 crash class):"
  hits.each { |h| warn "  #{h}" }
  warn ''
end

unless rule2.empty?
  warn '::error::raw File.read whose result is later regexp-matched (F5 crash class, #752).'
  warn "Under an unset/C locale the string is tagged US-ASCII and the match raises"
  warn '`invalid byte sequence in US-ASCII (ArgumentError)` on the first non-ASCII byte:'
  rule2.each { |h| warn "  #{h}" }
  warn ''
end

warn "Fix: add `encoding: 'UTF-8'` — e.g. File.read(path, encoding: 'UTF-8')."
exit 1
