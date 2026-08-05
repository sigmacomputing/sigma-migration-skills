#!/usr/bin/env ruby
# Regression test for control_lint's "missing control" gate (#259).
#
# A control-scope entry flagged as an ALREADY-SURFACED gap — needs-wiring (an
# orphan/unreferenced parameter the builder intentionally does not place as a
# dead control) or needs-materialization (a calc-bound filter whose column isn't
# on the model yet) — is recorded in the controls-coverage ledger, NOT silently
# dropped. So its absence from the spec must NOT be reported as "missing control"
# (which hard-fails the migration gate). Only an EMITTED-status entry that's
# absent from the spec is a real "the source filter was not migrated" failure.
#
# The bug this guards: a stray Tableau parameter (referenced by no calc) blocked
# the whole control gate — very common, would have broken most migrations.
#
# Usage:  ruby scripts/test-control-lint.rb   (run from a vendored plugin copy)
require 'json'
require 'set'
require_relative 'lib/control_lint'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Minimal non-degenerate spec: one page, one non-control element, NO controls —
# so any "missing control" comes purely from the scope↔spec reconciliation.
SPEC = { 'pages' => [{ 'name' => 'P1', 'elements' => [
  { 'id' => 'tbl-1', 'kind' => 'table', 'name' => 'T' }
] }] }.freeze

def scope_with(status)
  ctl = { 'controlId' => 'ctl-orphan', 'name' => 'Orphan', 'sourceName' => "param 'Orphan'" }
  ctl['status'] = status unless status.nil?
  { 'sourceFilterSignals' => 0, 'controls' => [ctl] }
end

missing = ->(vs) { vs.any? { |v| v.include?('missing control') && v.include?('ctl-orphan') } }

# needs-wiring (orphan/unreferenced param) → NOT a missing-control failure
v1 = ControlLint.lint(SPEC, scope: scope_with('needs-wiring'))
check(!missing.call(v1), "needs-wiring scope entry absent from spec → NO 'missing control' (got #{v1.inspect})", fails)

# needs-materialization (calc-bound filter, column not yet on the model) → likewise
v2 = ControlLint.lint(SPEC, scope: scope_with('needs-materialization'))
check(!missing.call(v2), 'needs-materialization scope entry absent from spec → NO missing-control', fails)

# emitted status but absent from spec → this IS a real failure (guard against over-suppression)
v3 = ControlLint.lint(SPEC, scope: scope_with('emitted'))
check(missing.call(v3), 'emitted scope entry absent from spec → DOES flag missing-control (regression guard)', fails)

# no status → defaults to emitted → still flags (a bare scope entry must not slip through)
v4 = ControlLint.lint(SPEC, scope: scope_with(nil))
check(missing.call(v4), 'missing status defaults to emitted → flags missing-control', fails)

# --- "no controls built" (Qlik-class) must also honor surfaced gaps -----------
no_built = ->(vs) { vs.any? { |v| v.include?('no controls built') } }
# 1 filter signal, ZERO controls, but the only scope entry is a needs-wiring
# orphan param → the signal is accounted for as a surfaced gap → NOT a failure.
sig_gap = { 'sourceFilterSignals' => 1,
            'controls' => [{ 'controlId' => 'ctl-orphan', 'name' => 'Orphan', 'status' => 'needs-wiring' }] }
check(!no_built.call(ControlLint.lint(SPEC, scope: sig_gap)),
      'signals>0 + zero controls but all scope entries needs-wiring → NO "no controls built" (the ComplexPivot case)', fails)
# genuine silent miss: signals but NO scope entries explaining them → still fails.
sig_silent = { 'sourceFilterSignals' => 1, 'controls' => [] }
check(no_built.call(ControlLint.lint(SPEC, scope: sig_silent)),
      'signals>0 + zero controls + NO scope entries → DOES flag "no controls built" (Qlik silent-miss preserved)', fails)

# --- wholesale controlId DRIFT (from-scratch rewrite) → ONE hint, not N misses -
# Spec has controls, but NONE of their ids match the sidecar's (kebab auto-build
# ids vs hand-authored ids) — the exact 14-violation field episode.
SPEC_CTLS = { 'pages' => [{ 'name' => 'P1', 'elements' => [
  { 'id' => 'tbl-1', 'kind' => 'table', 'name' => 'T',
    'columns' => [{ 'id' => 'c-dim', 'name' => 'Region', 'formula' => '[Region]' }] },
  { 'id' => 'el-c1', 'kind' => 'control', 'controlId' => 'RankFunction', 'name' => 'Rank',
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'tbl-1' }, 'columnId' => 'c-dim' }] },
  { 'id' => 'el-c2', 'kind' => 'control', 'controlId' => 'UnifiedPersonkey', 'name' => 'User',
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'tbl-1' }, 'columnId' => 'c-dim' }] }
] }] }.freeze
drift_msg = ->(vs) { vs.any? { |v| v.include?('control-scope drift') } }
drift_scope = { 'sourceFilterSignals' => 2, 'controls' => [
  { 'controlId' => 'ctl-param-rank-function-dashboard-1', 'name' => 'Rank', 'status' => 'emitted' },
  { 'controlId' => 'ctl-unified-personkey-dashboard-1', 'name' => 'User', 'status' => 'emitted' }
] }
vd = ControlLint.lint(SPEC_CTLS, scope: drift_scope)
check(drift_msg.call(vd), "wholesale controlId drift → ONE 'control-scope drift' hint (got #{vd.inspect})", fails)
check(vd.count { |v| v.include?('missing control') }.zero?, 'drift case does NOT emit per-entry "missing control"', fails)

# one sidecar id MATCHES a spec control + one genuine drop → per-entry, NOT drift.
partial_scope = { 'sourceFilterSignals' => 2, 'controls' => [
  { 'controlId' => 'RankFunction', 'name' => 'Rank', 'status' => 'emitted' },       # matches el-c1
  { 'controlId' => 'ctl-dropped', 'name' => 'Gone', 'sourceName' => "param 'Gone'", 'status' => 'emitted' }
] }
vp = ControlLint.lint(SPEC_CTLS, scope: partial_scope)
check(!drift_msg.call(vp), 'a matched control present → NOT treated as wholesale drift', fails)
check(vp.any? { |v| v.include?('missing control') && v.include?('ctl-dropped') },
      'genuine single dropped filter still flagged per-entry (not swallowed by drift)', fails)

puts
if fails.empty?
  puts 'ALL PASS — control_lint honors needs-wiring/needs-materialization coverage gaps'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
