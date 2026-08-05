#!/usr/bin/env ruby
# frozen_string_literal: true
#
# emit-relationship-coverage.rb — translate the converter's relationshipCoverage
# report (converter/tableau.mjs, PR2a) into <workdir>/relationship-coverage.json,
# the artifact PR2b's gate 22 will read.
#
# WHY: converter/tableau.mjs now infers a join key by column name when Tableau
# serialized none for a 2020.2+ logical (object-graph) relationship, and it
# records EVERY relationship it considered — wired or not — in a top-level
# `relationshipCoverage: { serialized, wired, entries: [...] }` object
# (camelCase: derivedVia, keyCount, droppedConditions — the converter's native
# JS convention). scripts/lib/join_plan.rb (this same task) already threads a
# WIRED relationship's derivedVia/partial/droppedConditions into
# join-plan.json, so gate 16's warehouse probe validates an inferred key's
# uniqueness. That is a DIFFERENT question from what this script answers:
# gate 16 only ever sees relationships that got wired (nothing to probe
# otherwise) — it has no way to notice a relationship the converter recorded
# but never wired at all (a star quietly going disconnected again). This
# script keeps that full count around, coverage="every relationship
# considered", not just the wired subset.
#
# CONSUMER (a later PR, deliberately NOT this one): PR2b's gate 22 lives in
# assert-phase6-ran.rb, a SHARED file synced across every converter plugin
# (see the repo's shared/ governance) — changing it here would spill this
# single-converter change across every other migration skill, so it ships in
# its own PR. That gate reads relationship-coverage.json and HARD-FAILS the
# run when wired < serialized: every relationship the converter recorded but
# never wired is a potential fan-out or a silently flattened star schema, and
# gate 22 refuses GREEN until an operator has looked at it.
#
# NAMING CONVENTION / this script's actual job: Ruby/JSON-on-disk artifacts in
# this skill use snake_case (join-plan.json already has key_pairs, probe_keys,
# grain_assumption); the converter's JS output is camelCase. This script is
# the translation point — it walks relationshipCoverage and renames every
# camelCase KEY to snake_case (derivedVia -> derived_via, keyCount ->
# key_count, droppedConditions -> dropped_conditions, ...). It does NOT
# invent, normalize, or default any field the converter did not compute: a
# non-partial wired entry has no dropped_conditions key here either, exactly
# as the converter never set droppedConditions on it (see
# converter/tableau.mjs's conditional `...skippedComputed > 0 ? {...} : {}`
# spread) — this script renames keys, it does not reshape values.
#
# MISSING relationshipCoverage (no object-graph datasource in this workbook —
# a legitimate, common case: classic joins and Custom-SQL-only sources never
# set it): this script still WRITES relationship-coverage.json, as
# { "serialized": 0, "wired": 0, "entries": [] }, rather than writing nothing.
# Decision + rationale: 0 < 0 is false, so gate 22 never hard-fails a workbook
# that simply has no object-graph relationships to report — but the file's
# EXISTENCE is what lets gate 22 (or an earlier wiring check) tell "ran, found
# nothing" apart from "this script never ran at all" (a MISSING file is then
# a distinct, and arguably more suspicious, failure signal — the same
# convention scripts/lib/join_plan.rb already documents for join-plan.json:
# "An EMPTY ledger is still written — its presence is the gate's evidence
# that the derivation ran and found nothing.").
#
# Usage:
#   ruby scripts/emit-relationship-coverage.rb --converter-out <PATH> --out <PATH>
#
# --converter-out reads any JSON document with a top-level "relationshipCoverage"
# key — both the shape test-relationship-derivation.rb's node shim writes
# ({model, relationshipCoverage, warnings}) and the converter's own raw return
# value (relationshipCoverage alongside whatever key the model itself is
# nested under) satisfy that, so no separate unwrapping convention is needed.
#
# Exit codes: 0 = relationship-coverage.json written; 2 = usage / missing/malformed input.

require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--converter-out PATH') { |v| opts[:converter_out] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
end.parse!
unless opts[:converter_out] && opts[:out]
  warn 'usage: emit-relationship-coverage.rb --converter-out <PATH> --out <PATH>'
  exit 2
end

unless File.exist?(opts[:converter_out])
  warn "FATAL: required input missing: #{opts[:converter_out]}"
  exit 2
end

doc = begin
  JSON.parse(File.read(opts[:converter_out]))
rescue JSON::ParserError => e
  warn "FATAL: #{opts[:converter_out]} is malformed JSON: #{e.message.lines.first.to_s.strip[0, 120]}"
  exit 2
end

# camelCase -> snake_case, recursively, over Hash keys only — Array elements
# are walked (entries is an array of per-relationship Hashes) but a String
# VALUE (e.g. a derivedVia value like "name-inference", already hyphenated by
# the converter) is left exactly as the converter wrote it. Only key NAMES are
# a Ruby-vs-JS naming-convention difference; values are not renamed at all.
def snakeize(obj)
  case obj
  when Hash
    obj.each_with_object({}) do |(k, v), h|
      h[k.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase] = snakeize(v)
    end
  when Array
    obj.map { |v| snakeize(v) }
  else
    obj
  end
end

coverage = doc.is_a?(Hash) ? doc['relationshipCoverage'] : nil
result = coverage ? snakeize(coverage) : { 'serialized' => 0, 'wired' => 0, 'entries' => [] }

File.write(opts[:out], "#{JSON.pretty_generate(result)}\n")
note = coverage ? '' : ' (no relationshipCoverage in converter output — no object-graph datasource)'
puts "emit-relationship-coverage: #{result['serialized']} serialized, #{result['wired']} wired, " \
     "#{Array(result['entries']).size} entr(y/ies) -> #{opts[:out]}#{note}"
exit 0
