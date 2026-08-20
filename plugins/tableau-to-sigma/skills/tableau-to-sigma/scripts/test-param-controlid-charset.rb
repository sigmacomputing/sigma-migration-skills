#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression pin for the illegal parameter-derived controlId bug found by the
# 2026-08-08 regression bisect (see
# .superpowers/sdd/2026-08-08-pr-queue-drain/regression-bisect-report.md):
#
# converter/tableau.mjs's parameter -> control loop built
# `controlId = sigmaDisplayName(p.name).replace(/\s+/g, "-")`, which only
# collapses WHITESPACE — it never strips other characters. A real Executive
# Dashboard workbook had two parameters captioned with Tableau's own
# pipe-delimited multi-value convention ("MultiParam | Category" /
# "MultiParam | Segment", the auto-name Tableau gives a duplicated
# parameter), producing `controlId = "Multi-Param-|-Category"`. The live DM
# POST rejected that id (observed: a `|` in a controlId is rejected).
#
# NOTE ON CHARSET: the canonical Sigma OpenAPI declares `controlId` as a bare
# `string` with no `pattern` constraint — there is no DOCUMENTED charset to
# cite. This test (and the fix it pins) instead sanitizes to a conservative
# SAFE SUBSET (`[a-zA-Z0-9_-]`, <=64 chars) chosen because restricting to a
# narrower charset than the API actually requires can never cause a
# rejection, whereas the observed live rejection of `|` proves the charset is
# narrower than "any string". Do not upgrade this into a documented-charset
# claim elsewhere.
#
# This also pins the COLLISION case: sanitizing away more characters makes it
# MORE likely that two distinct captions normalize to the same id (e.g. a
# '|'-caption and an '@'-caption can both collapse to the same dashes). The
# fixture's third parameter is deliberately crafted to collide with the
# first after sanitization, so this test proves the existing controlId-dedupe
# loop (converter/tableau.mjs, "controlId dedupe" comment) still catches it
# post-fix — no two controls may share an id.
#
# Fixture: scripts/test-fixtures/param-controlid-charset.twb — a Parameters
# datasource with 3 parameters (2 realistic pipe-captioned + 1 crafted
# collision) plus one minimal connected datasource/worksheet so the converter
# runs its normal single-datasource path.
#
# Usage: ruby scripts/test-param-controlid-charset.rb

require 'json'
require 'tmpdir'
require_relative 'mechanical-specs'

HERE = __dir__
VENDORED = File.expand_path('../converter/tableau.mjs', HERE)
FIXTURE  = File.join(HERE, 'test-fixtures', 'param-controlid-charset.twb')

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

abort "vendored converter missing: #{VENDORED}" unless File.exist?(VENDORED)
abort "fixture missing: #{FIXTURE}" unless File.exist?(FIXTURE)

model = nil
Dir.mktmpdir do |dir|
  conv = MechanicalSpecs.run_converter(
    twb_path: FIXTURE, conn: 'conn-test-1', db: 'ANALYTICS', schema: 'SALES',
    mcp_build: VENDORED, workdir: dir)
  model = conv['model']
end

els = (model['pages'] || []).flat_map { |p| p['elements'] || [] }
controls = els.select { |e| e['kind'] == 'control' }

puts 'Part A — structure: parameter controls are emitted'
check(controls.size >= 2, "at least 2 controls emitted (got #{controls.size})", fails)
exit 1 unless fails.empty?

CHARSET = /\A[a-zA-Z0-9_-]{1,64}\z/

puts 'Part B — every controlId is within the conservative safe-subset charset'
controls.each do |c|
  id = c['controlId'].to_s
  check(id =~ CHARSET, "controlId #{id.inspect} matches the safe subset [a-zA-Z0-9_-]{1,64} (no '|', no other punctuation, <=64 chars)", fails)
end
# The exact bug signature: '|' must never survive into a controlId.
check(controls.none? { |c| c['controlId'].to_s.include?('|') },
      "no controlId contains the raw '|' from the Tableau multi-value caption convention", fails)

puts 'Part C — collision safety: two captions that sanitize to the same id do not both survive'
ids = controls.map { |c| c['controlId'] }
check(ids.uniq.size == ids.size,
      "every emitted control has a UNIQUE controlId (got #{ids.inspect})", fails)
# The fixture's 1st and 3rd parameters ("MultiParam | Category" and
# "Multi Param @ Category") sanitize to the SAME id once '|' and '@' both
# collapse to '-'. Confirm the collision actually happened (fixture still
# guards the real risk) and that dedupe left exactly one control for it.
category_ids = ids.select { |id| id.to_s =~ /Category/i }
check(category_ids.size == 1,
      "the deliberately-colliding 'Category' captions produced exactly ONE surviving control (dedupe fired), not #{category_ids.size}", fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
