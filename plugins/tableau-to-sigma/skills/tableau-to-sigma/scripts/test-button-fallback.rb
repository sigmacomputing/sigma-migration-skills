#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for lib/button_fallback.rb: in a workspace that rejects Sigma
# button elements, info-icon buttons are rewritten to text elements with the
# same words, and navigation buttons (one on-click navigate-to-page action)
# become the nav.invalid text pill; any other action button and unrelated
# elements are left untouched.
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


# ---- navigation buttons -> nav.invalid text pills ---------------------------
def nav_button(id, text, page, fill: nil, action_id: nil)
  el = { 'id' => id, 'kind' => 'button', 'text' => text, 'appearance' => 'filled',
         'align' => 'center', 'size' => 'small',
         'actions' => [{ 'id' => action_id || "act-#{id}", 'trigger' => 'on-click',
                         'effects' => [{ 'effect' => 'navigate',
                                         'target' => { 'type' => 'page', 'page' => page } }] }] }
  el['fillColor'] = fill if fill
  el
end

wrapped = lambda do |elements|
  { 'name' => 'W', 'folderId' => 'f1',
    'document' => { 'pages' => [{ 'id' => 'page-dash-1', 'name' => 'Overview' },
                                { 'id' => 'page-dash-2', 'name' => 'Detail View & More' }],
                    'elements' => elements } }
end

puts 'nav buttons: page-name resolution'
plain = nav_button('btn-10', 'Details', 'page-dash-2')
nav_doc = wrapped.call([{ 'id' => 'master', 'kind' => 'table' }, plain])
nav = []
ids = ButtonFallback.rewrite!(nav_doc, [], nav)
pill = nav_doc['document']['elements'][1]
check(ids == ['btn-10'], "reports the rewritten id (got #{ids.inspect})")
check(pill == ButtonFallback.nav_pill('btn-10', 'Details', 'Detail View & More'),
      "becomes the shared text pill for the RESOLVED page name (got #{pill.inspect})")
check(pill['body'] == '<p style="text-align: center">[**Details**](https://nav.invalid/#page=Detail%20View%20%26%20More)</p>',
      "pill body is a centered bold link to the url-encoded nav.invalid placeholder (got #{pill['body'].inspect})")
check(pill['kind'] == 'text' && pill['verticalAlign'] == 'middle' && !pill.key?('actions'),
      'kind:text, verticalAlign as the builder emits, no actions key')
check(nav == [{ 'id' => 'btn-10', 'action_id' => 'act-btn-10', 'page' => 'Detail View & More', 'resolved' => true }],
      "nav record names the button, its action, the page it resolved to (got #{nav.inspect})")
check(nav_doc['document']['elements'][0] == { 'id' => 'master', 'kind' => 'table' }, 'other elements untouched')

puts 'nav buttons: flat body (pages at the root) resolves too'
flat = { 'pages' => [{ 'id' => 'page-overview', 'name' => 'Overview' }],
         'elements' => [nav_button('btn-1', 'Home', 'page-overview')] }
nav = []
ButtonFallback.rewrite!(flat, [], nav)
check(flat['elements'][0] == ButtonFallback.nav_pill('btn-1', 'Home', 'Overview') && nav[0]['resolved'],
      'flat spec: page id resolved through pages[]')

puts 'nav buttons: unresolved target page id'
nav_doc = wrapped.call([nav_button('btn-11', 'Go Home', 'page-no-such-page')])
nav = []
ButtonFallback.rewrite!(nav_doc, [], nav)
check(nav_doc['document']['elements'][0] == ButtonFallback.nav_pill('btn-11', 'Go Home', 'Go Home'),
      'falls back to the button text as the page name')
check(nav[0]['resolved'] == false && nav[0]['page'] == 'Go Home',
      "record flags the fallback so the caller can log it (got #{nav.inspect})")
nav_doc = { 'document' => { 'elements' => [nav_button('btn-12', 'Back', 'page-x')] } }
nav = []
ButtonFallback.rewrite!(nav_doc, [], nav)
check(nav[0]['resolved'] == false && nav_doc['document']['elements'][0]['kind'] == 'text',
      'a body with no pages at all still rewrites (button text as the name)')

puts 'nav buttons: fill color'
nav_doc = wrapped.call([nav_button('btn-13', 'Overview', 'page-dash-1', fill: '#1a2b3c')])
ButtonFallback.rewrite!(nav_doc)
check(nav_doc['document']['elements'][0]['body'] ==
        '<p style="text-align: center"><span style="background-color: #1a2b3c">' \
        '[**Overview**](https://nav.invalid/#page=Overview)</span></p>',
      "fillColor becomes the pill's background span (got #{nav_doc['document']['elements'][0]['body'].inspect})")

puts 'buttons the fallback must NOT touch'
writeback = { 'id' => 'btn-wb', 'kind' => 'button', 'text' => 'Save',
              'actions' => [{ 'id' => 'a-wb', 'trigger' => 'on-click',
                              'effects' => [{ 'effect' => 'set-control-value', 'control' => 'ctl-1', 'value' => 'x' }] }] }
url_nav = { 'id' => 'btn-url', 'kind' => 'button', 'text' => 'Docs',
            'actions' => [{ 'id' => 'a-url', 'trigger' => 'on-click',
                            'effects' => [{ 'effect' => 'navigate', 'target' => { 'type' => 'url', 'url' => 'https://example.test' } }] }] }
two_effects = nav_button('btn-2fx', 'Both', 'page-dash-1')
two_effects['actions'][0]['effects'] << { 'effect' => 'set-control-value', 'control' => 'ctl-1', 'value' => 'x' }
two_actions = nav_button('btn-2act', 'Twice', 'page-dash-1')
two_actions['actions'] << { 'id' => 'a2', 'trigger' => 'on-click', 'effects' => [] }
on_select = nav_button('btn-sel', 'Sel', 'page-dash-1')
on_select['actions'][0]['trigger'] = 'on-select'
keep = [writeback, url_nav, two_effects, two_actions, on_select]
snapshot = Marshal.load(Marshal.dump(keep))
nav_doc = wrapped.call(keep)
nav = []
check(ButtonFallback.rewrite!(nav_doc, [], nav).empty? && nav.empty? && nav_doc['document']['elements'] == snapshot,
      'writeback, url-navigate, multi-effect, multi-action and on-select buttons are all left for the API')

puts 'mixed body: info-icon path unchanged alongside nav'
mixed = wrapped.call([info, nav_button('btn-14', 'Detail', 'page-dash-2'), writeback])
nav = []
ids = ButtonFallback.rewrite!(mixed, [], nav)
els = mixed['document']['elements']
check(ids.sort == %w[btn-14 btn-20], "both kinds rewritten in one pass (got #{ids.inspect})")
check(els[0]['body'] == "\u{1F4A1} Shows weekly revenue.\n\nKey questions:\n\n- Which channels grow?" && els[0]['id'] == 'btn-20',
      'info-icon button still becomes the same inline text')
check(els[1] == ButtonFallback.nav_pill('btn-14', 'Detail', 'Detail View & More'), 'nav button becomes the pill')
check(els[2] == writeback, 'writeback button still untouched')
check(nav.map { |n| n['id'] } == ['btn-14'], 'only nav buttons are reported in the nav records')

puts 'manifest pruning'
manifest = [{ 'actionId' => 'act-btn-10', 'source' => { 'kind' => 'nav-button' } },
            { 'actionId' => 'act-other', 'source' => { 'kind' => 'nav-action' } }]
kept, removed = ButtonFallback.prune_manifest(manifest, ['act-btn-10'])
check(kept.map { |m| m['actionId'] } == ['act-other'] && removed.map { |m| m['actionId'] } == ['act-btn-10'],
      'prune_manifest drops exactly the downgraded actionIds')
check(ButtonFallback.prune_manifest(nil, ['x']) == [[], []], 'prune_manifest tolerates a missing manifest')

puts 'flag spellings'
check(ButtonFallback.native_buttons?(nil) && ButtonFallback.native_buttons?('on') && !ButtonFallback.native_buttons?('off') &&
      !ButtonFallback.native_buttons?('0') && !ButtonFallback.native_buttons?(' False '),
      'native by default; off/0/false (any case, trimmed) opt out')

puts(FAILS.empty? ? "\nall button-fallback tests passed" : "\n#{FAILS.length} FAILED")
exit(FAILS.empty? ? 0 : 1)
