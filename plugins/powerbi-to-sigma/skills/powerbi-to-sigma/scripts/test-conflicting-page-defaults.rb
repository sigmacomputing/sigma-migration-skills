#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression test for control_lint check (d): conflicting cross-page control
# defaults (issue #485 — the severe D11 special case).
#
# A single shared master (source:{kind:data-model}) with per-page list controls
# that default to DISJOINT, non-empty values on the same logical column makes
# Sigma AND-compose both filters against the one master -> impossible filter ->
# ZERO rows for the master and therefore every element on every page, silently.
# Check (d) must hard-fail that shape while NOT flagging any of the legitimate
# arrangements (independent per-page masters, overlapping/default-all defaults,
# a single page), and it must see through the id-duplication workaround (the
# same logical column emitted under two ids with the same formula).
#
# Usage:  ruby scripts/test-conflicting-page-defaults.rb   (run from a vendored plugin copy)
require 'json'
require 'set'
require_relative 'lib/control_lint'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A list control whose `filters` target {source:{elementId:target}, columnId:col}
# and whose own default selected values are `values`.
def ctl(id, cid, values, target: 'm', col: 'c-type')
  { 'id' => id, 'kind' => 'control', 'controlId' => cid, 'controlType' => 'list',
    'mode' => 'include', 'selectionMode' => 'multiple', 'values' => values,
    'source'  => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => target }, 'columnId' => col },
    'filters' => [{ 'source' => { 'elementId' => target }, 'columnId' => col }] }
end

# A master TABLE element carrying two columnIds that share ONE formula — so the
# alias grouping collapses the id-dup workaround (c-type / c-type-ovw) to one key.
def master(id = 'm')
  { 'id' => id, 'kind' => 'table', 'name' => 'Master', 'columns' => [
    { 'id' => 'c-type',     'formula' => '[Custom SQL/Website Type]' },
    { 'id' => 'c-type-ovw', 'formula' => '[Custom SQL/Website Type]' }
  ] }
end

def spec_of(*pages)
  { 'pages' => pages.map.with_index { |els, i| { 'name' => "P#{i + 1}", 'elements' => els } } }
end

fires = ->(vs) { vs.any? { |v| v.include?('conflicting cross-page control defaults') } }

# 1. THE CONFLICT — two pages, one shared master, disjoint non-empty defaults.
v1 = ControlLint.lint(spec_of(
  [master, ctl('a', 'ctl-a', ['Agent Website'])],
  [ctl('b', 'ctl-b', ['Brokerage Website'])]
))
check(fires.call(v1), "conflict fires: shared master + disjoint per-page defaults (got #{v1.grep(/conflicting/).inspect})", fails)

# 2. id-duplication workaround — page B binds to a DIFFERENT columnId (c-type-ovw)
#    that shares the same formula. Formula-alias grouping must still fire.
v2 = ControlLint.lint(spec_of(
  [master, ctl('a', 'ctl-a', ['Agent Website'])],
  [ctl('b', 'ctl-b', ['Brokerage Website'], col: 'c-type-ovw')]
))
check(fires.call(v2), 'id-dup workaround still fires via formula-alias grouping', fails)

# 3. Independent per-page masters (the real fix) — distinct target elements per
#    page -> the controls no longer compose against one source -> NO conflict.
v3 = ControlLint.lint(spec_of(
  [master('m-a'), ctl('a', 'ctl-a', ['Agent Website'],    target: 'm-a')],
  [master('m-b'), ctl('b', 'ctl-b', ['Brokerage Website'], target: 'm-b')]
))
check(!fires.call(v3), "independent per-page masters do NOT fire (got #{v3.grep(/conflicting/).inspect})", fails)

# 4. Same master, identical defaults (the overlap fix) — satisfiable -> NO conflict.
v4 = ControlLint.lint(spec_of(
  [master, ctl('a', 'ctl-a', ['Agent Website'])],
  [ctl('b', 'ctl-b', ['Agent Website'])]
))
check(!fires.call(v4), 'same master + identical defaults do NOT fire', fails)

# 5. Partial (non-disjoint) overlap -> intersection non-empty -> NO conflict.
v5 = ControlLint.lint(spec_of(
  [master, ctl('a', 'ctl-a', %w[A B])],
  [ctl('b', 'ctl-b', %w[B C])]
))
check(!fires.call(v5), 'partial (non-disjoint) overlap does NOT fire', fails)

# 6. Single page — both disjoint controls on ONE page (page uniq < 2) -> NO conflict.
v6 = ControlLint.lint(spec_of(
  [master, ctl('a', 'ctl-a', ['Agent Website']), ctl('b', 'ctl-b', ['Brokerage Website'])]
))
check(!fires.call(v6), 'single-page spec stays clean (page uniq < 2)', fails)

# 7. Default-all both pages (values: []) — the common case, empty defaults -> NO conflict.
v7 = ControlLint.lint(spec_of(
  [master, ctl('a', 'ctl-a', [])],
  [ctl('b', 'ctl-b', [])]
))
check(!fires.call(v7), 'default-all (values: []) both pages do NOT fire (false-positive guard)', fails)

puts
if fails.empty?
  puts 'ALL PASS — control_lint check (d) flags the impossible-filter shape and only that'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
