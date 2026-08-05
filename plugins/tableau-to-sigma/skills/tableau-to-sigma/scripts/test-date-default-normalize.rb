#!/usr/bin/env ruby
# Regression test for the #415 date-range default normalization.
#
# POST/PUT /v2/workbooks/spec ACCEPTS a date-range control with bare-date
# `startDate`/`endDate` defaults ("2026-01-01") and SILENTLY DROPS them on
# readback — the live control shows the "Select date range" placeholder and
# every element it filters opens unfiltered. Full ISO-8601 UTC timestamps
# ("2026-01-01T00:00:00Z") are the only string form observed to round-trip
# (refs/workbook-layout.md). The builder therefore normalizes every emitted
# default through iso_utc_datestamp; unrecognized inputs pass through AS-IS so
# the A2 preflight WARN + the post-POST control-field audit can surface them
# (never a silent mangle).
#
# Extracts the pure helper straight from build-charts-from-signals.rb (same
# technique as test-relative-date-filter.rb) — offline, creds-free.
#
# Usage:  ruby scripts/test-date-default-normalize.rb

SRC = File.join(__dir__, 'build-charts-from-signals.rb')
src = File.read(SRC)
m = src[/def iso_utc_datestamp.*?\nend/m]
abort "could not extract iso_utc_datestamp from #{SRC} — did it move/rename?" unless m
eval(m) # rubocop:disable Security/Eval — trusted first-party source, test-only

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# bare date → persisting UTC form (start-of-day / end-of-day)
check(iso_utc_datestamp('2026-01-01') == '2026-01-01T00:00:00Z',
      'bare date → T00:00:00Z (the form the API round-trips)', fails)
check(iso_utc_datestamp('2026-03-31', end_of_day: true) == '2026-03-31T23:59:59Z',
      'end bound → T23:59:59Z', fails)

# Tableau attribute forms
check(iso_utc_datestamp('#2026-01-01#') == '2026-01-01T00:00:00Z',
      'Tableau #date# literal unwrapped + normalized', fails)
check(iso_utc_datestamp('2026-01-01 14:30:00') == '2026-01-01T14:30:00Z',
      'zoneless datetime gets the UTC Z suffix (space separator)', fails)

# already-persisting forms pass through unchanged
check(iso_utc_datestamp('2026-01-01T00:00:00Z') == '2026-01-01T00:00:00Z',
      'Z-suffixed timestamp unchanged', fails)
check(iso_utc_datestamp('2026-01-01T00:00:00+05:30') == '2026-01-01T00:00:00+05:30',
      'offset timestamp unchanged', fails)

# unrecognized input is returned AS-IS (lint + readback audit surface it)
check(iso_utc_datestamp('last month') == 'last month',
      'unparseable input passes through untouched (no silent mangle)', fails)
check(iso_utc_datestamp('') == '', 'empty string untouched', fails)

puts
if fails.empty?
  puts 'ALL PASS — date-range defaults normalize to the persisting ISO-8601 UTC form (#415)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
