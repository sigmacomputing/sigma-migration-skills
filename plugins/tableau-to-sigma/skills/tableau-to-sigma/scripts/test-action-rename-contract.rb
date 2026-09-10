#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-action-rename-contract.rb — the 2026-08-26 Sigma action field rename.
#
# Sigma renamed action identifier fields to an explicit *Id shape. Every old name
# now hard-400s EXCEPT ONE: `clear-control` `scope:{type:page, page:}` returns
# 200 OK and SILENTLY DROPS the key, so the button persists and clears nothing.
# Status codes are not evidence for that one; only the emitted shape is.
#
# The rename is also SELECTIVE. Three fields were probed and deliberately NOT
# renamed, so "fixing" them to *Id is itself a 400. Half of this file exists to
# assert we do NOT over-rename them:
#   set-control-value.control                       stays `control`
#   navigate         target{type:page}.page         stays `page`
#   refresh-element  target{type:element}.element   stays `element`
#
# Every expectation below is derived from the canonical OpenAPI asset
# (assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json)
# read on 2026-08-26, cross-checked against the live probe recorded in the
# reference docs. Offline, creds-free, no network.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_ledger'

fails = 0

def check(desc, cond)
  puts(cond ? "  ok  #{desc}" : "  FAIL #{desc}")
  cond
end

# expect: a substring the errors must contain, or '' meaning "must be clean"
def expect_error(desc, effects, expect)
  action = { 'id' => 'a1', 'trigger' => 'on-click', 'effects' => effects }
  errs = ActionLedger.validate_action(action)
  ok = expect.empty? ? errs.empty? : errs.any? { |e| e.include?(expect) }
  res = check(desc, ok)
  puts "        got: #{errs.inspect}" unless res
  res
end

puts 'RENAMED — the old key must be rejected (top level)'
[
  ['insert-rows `table`',      [{ 'effect' => 'insert-rows', 'table' => 't', 'values' => [] }],                    'renamed to `tableElementId`'],
  ['update-rows `table`',      [{ 'effect' => 'update-rows', 'table' => 't', 'whichRows' => {}, 'values' => [] }],  'renamed to `tableElementId`'],
  ['delete-rows `table`',      [{ 'effect' => 'delete-rows', 'table' => 't', 'whichRows' => {} }],                  'renamed to `tableElementId`'],
  ['set-form-values `form`',   [{ 'effect' => 'set-form-values', 'form' => 'f', 'values' => [] }],                  'renamed to `formElementId`'],
  ['select-tab `tabbedContainer`', [{ 'effect' => 'select-tab', 'tabbedContainer' => 'tc', 'selectedTab' => { 'type' => 'tab', 'index' => 0 } }], 'renamed to `tabbedContainerElementId`'],
  ['open-document `document`', [{ 'effect' => 'open-document', 'document' => 'd', 'documentType' => 'workbook', 'openTarget' => 'new-tab' }], 'renamed to `documentId`'],
  ['trigger-plugin `pluginElement`', [{ 'effect' => 'trigger-plugin', 'pluginElement' => 'p', 'pluginEffect' => 'e' }], 'renamed to `pluginElementId`']
].each { |d, e, x| fails += 1 unless expect_error(d, e, x) }

puts
puts 'RENAMED — nested paths (these had NO validator coverage before)'
[
  ['value source {type:column} `column`',  [{ 'effect' => 'set-control-value', 'control' => 'c', 'value' => { 'type' => 'column', 'column' => 'col' } }], 'renamed to `columnId`'],
  ['whichRows {type:column-match} `column`', [{ 'effect' => 'delete-rows', 'tableElementId' => 't', 'whichRows' => { 'type' => 'column-match', 'column' => 'c' } }], 'renamed to `columnId`'],
  ['custom-sort sort.`column`',            [{ 'effect' => 'custom-sort', 'elementId' => 'e', 'sort' => { 'type' => 'column', 'column' => 'c', 'direction' => 'asc' } }], 'renamed to `columnId`'],
  ['column-range `min`/`max`',             [{ 'effect' => 'insert-rows', 'tableElementId' => 't', 'values' => [{ 'type' => 'column-range', 'min' => 'a', 'max' => 'b' }] }], 'renamed to `minColumnId`']
].each { |d, e, x| fails += 1 unless expect_error(d, e, x) }

puts
puts 'SCHEMA-VALID BUT INERT — the API accepts these and they do nothing'
fails += 1 unless expect_error('clear-control scope `page` is the SILENT drop',
                               [{ 'effect' => 'clear-control', 'scope' => { 'type' => 'page', 'page' => 'p' } }], 'SILENTLY')
fails += 1 unless expect_error('column-range with neither bound matches everything',
                               [{ 'effect' => 'insert-rows', 'tableElementId' => 't', 'values' => [{ 'type' => 'column-range' }] }], 'silently matches everything')
fails += 1 unless expect_error('open-url with no url persists and does nothing',
                               [{ 'effect' => 'open-url', 'openTarget' => 'new-tab' }], 'missing required property `url`')

puts
puts 'NOT RENAMED — the bare name is still the ONLY accepted form; do not "fix" these'
[
  ['set-control-value keeps bare `control`',    [{ 'effect' => 'set-control-value', 'control' => 'ctl', 'value' => { 'type' => 'constant', 'value' => { 'type' => 'text', 'value' => 'x' } } }]],
  ['navigate keeps bare target.`page`',         [{ 'effect' => 'navigate', 'target' => { 'type' => 'page', 'page' => 'p1' } }]],
  ['refresh-element keeps bare target.`element`', [{ 'effect' => 'refresh-element', 'target' => { 'type' => 'element', 'element' => 'e1' } }]]
].each { |d, e| fails += 1 unless expect_error(d, e, '') }

puts
puts 'ALL 23 spec effects are known (the old table had 12, so 11 were rejected as "unknown")'
known = %w[call-agent call-api call-stored-procedure clear-chat-element-messages clear-control
           close-overlay custom-sort delete-rows export if-else insert-rows navigate open-document
           open-overlay open-url refresh-element reset-form run-python-element select-tab
           set-control-value set-form-values trigger-plugin update-rows]
missing = known.reject { |k| ActionLedger::EFFECT_REQUIRED.key?(k) }
fails += 1 unless check("every spec effect is in EFFECT_REQUIRED (missing: #{missing.inspect})", missing.empty?)
fails += 1 unless check('and no invented effects beyond the spec',
                        (ActionLedger::EFFECT_REQUIRED.keys - known).empty?)

puts
puts 'CORRECT new shapes must pass cleanly'
fails += 1 unless expect_error('post-rename shapes validate',
                               [{ 'effect' => 'clear-control', 'scope' => { 'type' => 'page', 'pageId' => 'p' } },
                                { 'effect' => 'delete-rows', 'tableElementId' => 't', 'whichRows' => { 'type' => 'column-match', 'columnId' => 'c' } },
                                { 'effect' => 'custom-sort', 'elementId' => 'e', 'sort' => { 'type' => 'column', 'columnId' => 'c', 'direction' => 'asc' } }], '')

puts
if fails.zero?
  puts 'all action-rename contract tests passed'
  exit 0
end
puts "#{fails} check(s) FAILED"
exit 1
