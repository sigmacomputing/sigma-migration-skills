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
# Exit 0 = clean; exit 1 = at least one unencoded .twb/XML read (prints each site).
# Faithful port of the former inline grep pipeline:
#   grep -rnE "File\.read\(([^)]*\b(twb|INP|disc_log)\b[^)]*)\)"  (case-sensitive)
#     | grep -v "encoding:"                                       (case-sensitive)
#     | grep -viE "JSON\.parse|\.json|\.rb'|File\.write"          (case-insensitive)

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

# File.read(...) whose argument mentions a .twb-ish path token. Matches `twb` as a
# whole word AND as an identifier suffix (`rank_twb`, `wb_twb`) — the CI grep's
# `\btwb\b` silently skipped the `_twb` suffix form, which is exactly how half of
# the #388 unencoded read (opts[:rank_twb]) slipped past the gate.
TOKEN     = /File\.read\(([^)]*(?:\btwb\b|_twb\b|\bINP\b|\bdisc_log\b)[^)]*)\)/
# Already-safe or not-a-.twb reads to skip (case-insensitive, mirrors grep -vi).
EXCLUDE   = /JSON\.parse|\.json|\.rb'|File\.write/i

hits = []
%w[plugins shared].each do |dir|
  next unless Dir.exist?(dir)
  Dir.glob(File.join(dir, '**', '*.rb')).sort.each do |f|
    File.foreach(f, encoding: 'UTF-8').with_index(1) do |line, n|
      next unless line =~ TOKEN
      next if line.include?('encoding:')   # already sets an encoding — safe
      next if line =~ EXCLUDE
      hits << "#{f}:#{n}: #{line.strip}"
    end
  end
end

if hits.empty?
  puts 'OK: no unencoded .twb/XML File.read sites (plugins/ + shared/).'
  exit 0
end

warn "::error::File.read on a .twb without encoding: 'UTF-8' (F5 crash class):"
hits.each { |h| warn "  #{h}" }
warn ''
warn "Fix: add `encoding: 'UTF-8'` — e.g. File.read(path, encoding: 'UTF-8')."
exit 1
