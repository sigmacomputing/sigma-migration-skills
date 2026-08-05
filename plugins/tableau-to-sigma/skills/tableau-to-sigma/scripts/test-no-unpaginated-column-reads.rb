#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Lint: every Sigma `/columns` endpoint read in this skill's scripts must be
# exhaustively paginated.
#
# THE RULE: a script that issues an HTTP GET to a path containing `/columns`
# must also contain either `list_entries` or `nextPage` somewhere in its
# source. `Sigma.list_entries` (shared/lib/sigma_rest.rb) is the correct,
# exhaustive reader — it sends `limit=1000` (the documented API maximum) and
# follows `nextPage` tokens until the list is exhausted. Sigma's server
# DEFAULT page size is 50, so a bare first-page GET silently truncates any
# table, workbook, or data model with more than 50 columns. Unpaginated
# single-page reads reached END OF SUPPORT on 2026-06-02 (see the
# `list_entries` doc comment in shared/lib/sigma_rest.rb) — a script that
# still reads only page one is relying on a shape Sigma no longer guarantees.
#
# WHY THIS LINT EXISTS: `Sigma.list_entries` has existed since 2026-06, and
# its own comment records this exact bug class, but the fix drifted to only
# two of eleven callers (migrate-tableau.rb and assert-wb-refs-resolve.rb).
# The other nine scripts in this directory independently grew their own
# first-page-only `/columns` GETs and silently truncated wide tables at the
# 50-column server default until PRs #560 and #565 routed all nine through
# `list_entries` (or, for assert-phase6-ran.rb, a local `nextPage` loop — see
# below). Nothing stopped a twelfth script from doing the same thing again
# except this lint.
#
# KNOWN LIMIT — this check is FILE-level, not line-level: it is satisfied the
# moment a file contains `list_entries` or `nextPage` ANYWHERE in its source.
# An already-compliant file (say, migrate-tableau.rb, which correctly
# paginates its existing `/columns` calls) could grow a brand-new, unrelated,
# unpaginated `/columns` GET elsewhere in that same file, and this lint would
# NOT catch it — the file as a whole still contains `list_entries` from its
# existing, correct call site. Tightening this to line-level (matching each
# `/columns` GET to the pagination construct that actually wraps IT) needs
# real data-flow analysis, not a text scan. Until that exists, a green run
# here means "no new file introduced an unpaginated read," not "every
# `/columns` read in every file is individually proven to paginate."
#
# Usage: ruby scripts/test-no-unpaginated-column-reads.rb
#        (the directory scanned is derived from this file's own location, so
#        it works whether invoked from the skill directory or elsewhere)

SCRIPTS_DIR = File.expand_path(__dir__)

# In-scope path pattern: a REAL `/columns` request path, not a prose mention
# of the word "columns" (e.g. "rowsBy/columnsBy", "the /columns endpoint").
# Matches only where `/columns` is immediately followed by the closing quote
# of a string literal or a `?` opening a query string — i.e. `.../columns"`
# or `.../columns?...` — which is how every actual GET path in this
# directory is written.
COLUMNS_PATH_RE = %r{/columns["?]}.freeze

# Files exempt from this rule, keyed by basename, valued by the reason the
# exemption is justified.
#
# EXPECTED EMPTY. An entry here is only justified after tracing a flagged
# file's receiver and proving the `entries` it reads come from a local JSON
# ledger already written to disk by a prior phase — NOT a live REST
# response — i.e. the `/columns` text matched but no HTTP GET actually hits
# Sigma's API at that call site. An allowlist entry added for a genuine,
# un-paginated REST `/columns` read is not a decision — it is a silencer. It
# hides the exact defect this lint exists to catch.
ALLOWLIST = {}.freeze

files = Dir.glob(File.join(SCRIPTS_DIR, '*.rb')).sort
checked = 0
failures = []

files.each do |path|
  base = File.basename(path)
  next if base.start_with?('test-')
  next if ALLOWLIST.key?(base)

  src = File.read(path)
  next unless src =~ COLUMNS_PATH_RE

  checked += 1
  next if src.include?('list_entries') || src.include?('nextPage')

  offending_lines = []
  src.each_line.with_index(1) { |line, n| offending_lines << n if line =~ COLUMNS_PATH_RE }
  failures << [base, offending_lines]
end

puts "test-no-unpaginated-column-reads.rb — every /columns read must paginate"
puts ''
puts "Allowlist (#{ALLOWLIST.length} entr#{ALLOWLIST.length == 1 ? 'y' : 'ies'}):"
if ALLOWLIST.empty?
  puts '  (none)'
else
  ALLOWLIST.each { |name, reason| puts "  #{name}: #{reason}" }
end
puts ''

if failures.any?
  failures.each do |base, lines|
    warn "[FAIL] #{base}: unpaginated /columns read at line(s) #{lines.join(', ')}"
    warn "       Route this through Sigma.list_entries (shared/lib/sigma_rest.rb) — or, only for a"
    warn "       file that deliberately carries no sigma_rest dependency (assert-phase6-ran.rb does"
    warn "       this for its final gate), a local `limit=1000` GET loop that follows `nextPage` to"
    warn "       exhaustion."
  end
  warn ''
  warn "SUMMARY: #{checked} in-scope file(s) checked, #{ALLOWLIST.length} allowlisted, #{failures.length} failing."
  exit 1
end

puts "SUMMARY: #{checked} in-scope file(s) checked, #{ALLOWLIST.length} allowlisted, 0 failing."
exit 0
