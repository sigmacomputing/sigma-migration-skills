#!/usr/bin/env ruby
# frozen_string_literal: true
# Guards the --workbook-target PUT-append GET against the workbook code-rep
# `document` wrapper (live since 2026-08).
#
# migrate-tableau.rb's --workbook-target flow GETs the live spec of an
# EXISTING workbook to merge the newly-built page(s) into it before handing
# the merged spec to post-and-readback.rb --update-id. That GET now nests
# `pages`/`schemaVersion` under a top-level `document` key — a bare
# `existing['pages']` read is always nil, so the very next line's guard
# ("workbook spec readback is not a page-bearing spec") FATAL-aborts EVERY
# --workbook-target append, even against a perfectly valid workbook.
#
# migrate-tableau.rb is the monolithic ~5800-line orchestrator (this block
# depends on ~4700 lines of prior CLI/discovery/build state, so it can't be
# isolated into a runnable unit without a full TWB fixture + pipeline run) —
# source-level assertions, mirroring test-reuse-workbook.rb's approach to the
# same file, rather than a live/subprocess run.
#
# Usage: ruby scripts/test-workbook-target-coderep-unwrap.rb

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

mig = File.read(File.join(__dir__, 'migrate-tableau.rb'))

check(mig.include?("require_relative 'lib/workbook_code'"),
      'migrate-tableau.rb requires lib/workbook_code', fails)

# Isolate the --workbook-target append block for a scoped check (don't just
# grep the whole 5800-line file — a Sigma::CodeRep call anywhere wouldn't
# prove THIS GET is unwrapped).
block = mig[/if opts\[:wb_target\].*?^end\n/m]
check(!block.nil?, 'the `if opts[:wb_target]` PUT-append block is present', fails)

if block
  get_idx    = block.index(/Sigma\.request\(:get,.*workbooks.*spec/)
  unwrap_idx = block.index(/WorkbookCode\.legacy_view\(raw_existing\)/)
  guard_idx  = block.index(/unless existing\.is_a\?\(Hash\) && existing\['pages'\]\.is_a\?\(Array\)/)

  check(!get_idx.nil?, 'the existing-workbook spec GET is present', fails)
  check(!unwrap_idx.nil?, 'the layout-aware workbook compatibility view is present', fails)
  check(!guard_idx.nil?, "the page-bearing-spec FATAL guard is present", fails)
  if get_idx && unwrap_idx && guard_idx
    check(get_idx < unwrap_idx && unwrap_idx < guard_idx,
          'unwrap runs AFTER the GET and BEFORE the pages-Array guard (so `existing[\'pages\']` sees the flattened shape, not the raw nested GET)',
          fails)
  end
  check(block.match?(/existing\s*=\s*begin.*raw_existing\s*=\s*Sigma\.request/m),
        'the GET result is captured as `raw_existing`, not assigned directly to `existing` (the unwrap runs on the raw nested response, not a pre-flattened one)',
        fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
