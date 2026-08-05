#!/usr/bin/env ruby
# Regression test: the agent-path offramp must name the STAGE that actually failed.
#
# THE BUG (hit during a live E2E, 2026-07-30). A run built its workbook, POSTED it
# successfully, and then failed LAYOUT LINT on a tile-height violation. The offramp
# reported:
#
#     Mechanical path: data model built OK (dataModelId=...). The WORKBOOK layer hit
#     some field(s) the mechanical path can't translate (one or more fields).
#     Falling back to the agent path...
#
# There was no untranslatable field. `run_wb!` captures the real error into
# WorkbookBuildError#captured_output, but the handler printed only its own guess: when
# `cull_failed_fields` finds no field name it falls back to the phrase "one or more
# fields" REGARDLESS of what actually failed. So a one-line tile-height fix was
# reported as a field-translation failure, and the operator was sent to rebuild the
# whole workbook via the agent path.
#
# That is the same class of misleading diagnostic as the coverage headline that said
# "0 dropped" while dropping half the bindings — the run reports a cause it did not
# establish. This asserts the offramp either names the real stage or admits it does not
# know, and never asserts a field-translation failure it cannot evidence.
#
# Usage:  ruby scripts/test-offramp-attribution.rb
require 'json'
require_relative 'lib/pbi_offramp_reason'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# The verbatim shape of the real failure: POST succeeded, layout lint then failed.
LAYOUT_LINT_OUTPUT = <<~OUT
     POST ok: workbookId=7f9dcae5-26a3-4a46-a3a9-edf58337e5a0
     column-type guard: 97 columns clean (no `error` types)
     ========================================
     FAIL — layout lint: 1 violation(s):
       - tile below minimum height: element el-ustere20ada9 (bar-chart) on page page-pg1
         spans 6 grid row(s) (< 8 required for bar-chart) — Sigma renders sub-minimum
         tiles BLANK in the page and in PNG exports; grow the tile.
     Fix the spec/layout and re-PUT before continuing.
     The workbook DID post — fix with PUT /v2/workbooks/<id>/spec
     ========================================
OUT

VALIDATE_OUTPUT = <<~OUT
     --- 3 errors
     element el-x column c1: Dependency not found: [FOO/Bar]
OUT

POST_OUTPUT = <<~OUT
     POST /v2/workbooks/spec -> 400
     {"message":"Invalid value: undefined at pages[0].elements[2].source"}
OUT

puts "\n1. a LAYOUT-LINT failure is named as such, and NOT as untranslatable fields"
r = PbiOfframp.classify(LAYOUT_LINT_OUTPUT, [])
check(r['stage'] == 'layout-lint', "stage == layout-lint (got #{r['stage'].inspect})", fails)
check(r['message'] =~ /layout/i, 'the message says layout', fails)
check(r['message'] !~ /can't translate|cannot translate/i,
      "the message does NOT claim a translation failure (got: #{r['message'][0, 90]})", fails)
check(r['message'] !~ /one or more fields/,
      'the message does NOT fall back to "one or more fields"', fails)
check(r['posted'] == true, 'it records that the workbook DID post', fails)
check(r['message'] =~ /PUT/,
      'and points at PUT /v2/workbooks/<id>/spec rather than the agent path', fails)
check(r['salient'].to_s =~ /tile below minimum height/,
      "it surfaces the actual violation line (got #{r['salient'].to_s[0, 60].inspect})", fails)

puts "\n2. a genuine FIELD failure is still attributed to fields"
r2 = PbiOfframp.classify(VALIDATE_OUTPUT, ['Net Revenue PY', 'YoY %'])
check(r2['stage'] == 'validate-spec', "stage == validate-spec (got #{r2['stage'].inspect})", fails)
check(r2['message'] =~ /Net Revenue PY/, 'the named fields are reported', fails)
check(r2['posted'] == false, 'and it does NOT claim the workbook posted', fails)

puts "\n3. a POST rejection is named as a POST failure"
r3 = PbiOfframp.classify(POST_OUTPUT, [])
check(r3['stage'] == 'post', "stage == post (got #{r3['stage'].inspect})", fails)
check(r3['salient'].to_s =~ /Invalid value|400/, 'the API error is surfaced', fails)
check(r3['message'] !~ /one or more fields/, 'no invented field-translation claim', fails)

puts "\n4. when nothing can be determined it says SO — it never invents a cause"
r4 = PbiOfframp.classify("something inscrutable happened\n", [])
check(r4['stage'] == 'unknown', "stage == unknown (got #{r4['stage'].inspect})", fails)
check(r4['message'] !~ /can't translate|cannot translate/i,
      'an unknown failure is NOT reported as a translation failure', fails)
check(r4['message'] =~ /could not determine|unknown/i,
      "it admits it could not determine the cause (got: #{r4['message'][0, 80]})", fails)
check(r4['salient'].to_s.length.positive?,
      'and still surfaces the captured output so the operator can see it', fails)

puts "\n5. empty/nil output is handled without raising"
[nil, '', "\n"].each do |blank|
  r5 = PbiOfframp.classify(blank, [])
  check(r5.is_a?(Hash) && r5['stage'] == 'unknown', "blank output #{blank.inspect} -> unknown", fails)
end

puts "\n6. the orchestrator USES the classifier (no hand-rolled message left behind)"
src = File.read(File.join(__dir__, 'migrate-powerbi.rb'))
check(src.include?('PbiOfframp'), 'migrate-powerbi.rb uses PbiOfframp', fails)
check(src !~ /layer hit #\{n\} field\(s\) the mechanical path can't translate/,
      'the old unconditional "can\'t translate" sentence is gone', fails)

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
