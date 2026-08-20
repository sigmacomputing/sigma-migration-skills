#!/usr/bin/env ruby
# frozen_string_literal: true
# Guards the gate-6/6e live-spec readback in migrate-qlik.rb against the
# workbook code-rep `document` wrapper (live since 2026-08).
#
# migrate-qlik.rb GETs the live posted-workbook spec before running the
# layout-quality lint (LayoutLint) and the control-wiring lint (ControlLint).
# That GET now nests `pages`/`schemaVersion` under a top-level `document` key.
# The pre-existing `live['spec'] || live` fallback predates that shape (it
# never matched a real envelope key — 'spec' was a guess, not an observed
# shape) and always fell through to the bare (still-nested) `live` hash, so
# both lints would silently see 0 pages/controls and both gates would pass
# VACUOUSLY on every run instead of actually linting anything.
#
# migrate-qlik.rb is the monolithic ~1080-line orchestrator (this block
# depends on prior CLI/discovery/build state — WB_ID, HERE — so it can't be
# isolated into a runnable unit offline) — source-level assertions, mirroring
# tableau-to-sigma's test-workbook-target-coderep-unwrap.rb approach to the
# same "can't isolate a god-script" problem, rather than a live/subprocess run.
#
# Usage: ruby scripts/test-migrate-qlik-coderep-unwrap.rb

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

mig = File.read(File.join(__dir__, 'migrate-qlik.rb'))

check(mig.include?("require 'code_rep'"), "migrate-qlik.rb requires code_rep", fails)
check(!mig.include?("live['spec'] || live"),
      "the old `live['spec'] || live` fallback (never matched a real envelope key) is gone", fails)

get_idx    = mig.index(/live\s*=\s*Sigma\.request\(:get,\s*"\/v2\/workbooks\/#\{WB_ID\}\/spec"\)/)
unwrap_idx = mig.index(/live_spec\s*=\s*live\.is_a\?\(Hash\)\s*\?\s*Sigma::CodeRep\.metadata\(live\)\.merge\(Sigma::CodeRep\.document\(live\)\)\s*:\s*\{\}/)
layout_idx = mig.index(/LayoutLint\.lint\(live_spec\)/)
ctl_idx    = mig.index(/ControlLint\.lint\(live_spec,\s*scope:\s*ctl_scope\)/)

check(!get_idx.nil?, 'the live workbook spec GET is present', fails)
check(!unwrap_idx.nil?, 'the `document` unwrap (metadata+document merge) assigns live_spec', fails)
check(!layout_idx.nil?, 'LayoutLint.lint(live_spec) is present', fails)
check(!ctl_idx.nil?, 'ControlLint.lint(live_spec, scope: ctl_scope) is present', fails)

if get_idx && unwrap_idx && layout_idx && ctl_idx
  check(get_idx < unwrap_idx && unwrap_idx < layout_idx && layout_idx < ctl_idx,
        'unwrap runs AFTER the GET and BEFORE both lints (so they see the flattened shape, not the raw nested GET)',
        fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
