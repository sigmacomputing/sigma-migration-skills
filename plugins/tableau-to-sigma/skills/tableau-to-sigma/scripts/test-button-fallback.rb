#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for lib/button_fallback.rb: in a workspace that rejects Sigma
# button elements, info-icon buttons are rewritten to text elements with the
# same words; action buttons and unrelated elements are left untouched.
require 'json'
require_relative 'lib/button_fallback'

FAILS = []
def check(cond, msg)
  puts((cond ? '  ok  ' : '  FAIL ') + msg)
  FAILS << msg unless cond
end

check(ButtonFallback.gated_error?('{"message":"`button` elements are not enabled for this workspace"}'),
      'recognizes the workspace-gate error')
check(!ButtonFallback.gated_error?('{"message":"document.elements[1]: Invalid kind: \"button\""}'),
      'does not fire on a schema error')

info = { 'id' => 'btn-20', 'kind' => 'button', 'appearance' => 'text',
         'text' => "Shows weekly revenue.\n\nKey questions:\n- Which channels grow?",
         'icon' => { 'type' => 'emoji', 'emoji' => "\u{1F4A1}", 'label' => 'hidden' } }
nav = { 'id' => 'btn-nav', 'kind' => 'button', 'text' => 'Go',
        'actions' => [{ 'id' => 'a1', 'trigger' => 'on-click', 'effects' => [] }] }
doc = { 'name' => 'W', 'document' => { 'elements' => [{ 'id' => 'master', 'kind' => 'table' }, info, nav] } }

ids = ButtonFallback.rewrite!(doc)
els = doc['document']['elements']
check(ids == ['btn-20'], "rewrites only the info-icon button (got #{ids.inspect})")
check(els[1] == { 'id' => 'btn-20', 'kind' => 'text',
                  'body' => "\u{1F4A1} Shows weekly revenue.\n\nKey questions:\n\n- Which channels grow?" },
      "info button becomes a text element with the same words and id (got #{els[1].inspect})")
check(els[2] == nav, 'an action button is left for the API to reject loudly')
check(els[0] == { 'id' => 'master', 'kind' => 'table' }, 'other elements are untouched')
check(ButtonFallback.rewrite!(doc).empty?, 'a second pass finds nothing to rewrite')

puts(FAILS.empty? ? "\nall button-fallback tests passed" : "\n#{FAILS.length} FAILED")
exit(FAILS.empty? ? 0 : 1)
