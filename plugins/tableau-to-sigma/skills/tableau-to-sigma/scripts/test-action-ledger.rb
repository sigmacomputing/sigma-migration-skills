#!/usr/bin/env ruby
# Unit tests for lib/action_ledger.rb — the single source of truth for which
# Tableau actions became real Sigma actions and which remain manual residue.
require 'json'
require 'tmpdir'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_ledger'

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'action id uniqueness'
reg = {}
a = ActionLedger.new_id(reg, 'el-bar')
b = ActionLedger.new_id(reg, 'el-bar')
c = ActionLedger.new_id(reg, 'el-kpi')
check(a == 'act-el-bar-1', "first id for an element is act-el-bar-1 (got #{a})")
check(b == 'act-el-bar-2', "second id on the SAME element increments (got #{b})")
check(c == 'act-el-kpi-1', "a different element restarts at 1 (got #{c})")
check([a, b, c].uniq.size == 3, 'all ids unique workbook-wide')

puts 'validate_action'
good = { 'id' => 'act-1', 'trigger' => 'on-select',
         'effects' => [{ 'effect' => 'navigate',
                         'target' => { 'type' => 'page', 'page' => 'page-detail' } }] }
check(ActionLedger.validate_action(good).empty?, 'a well-formed navigate action validates')

no_id = good.reject { |k, _| k == 'id' }
check(ActionLedger.validate_action(no_id).any? { |e| e =~ /id/ },
      'MISSING id is rejected (this is the shipping bug)')

bad_trigger = good.merge('trigger' => 'on-hover')
check(ActionLedger.validate_action(bad_trigger).any? { |e| e =~ /trigger/ },
      'on-hover is not a valid trigger')

no_effects = good.merge('effects' => [])
check(ActionLedger.validate_action(no_effects).any?, 'empty effects[] is rejected')

url_no_url = { 'id' => 'a', 'trigger' => 'on-click',
               'effects' => [{ 'effect' => 'open-url', 'openTarget' => '_blank' }] }
check(ActionLedger.validate_action(url_no_url).any? { |e| e =~ /url/ },
      'open-url WITHOUT url is rejected (schema-valid but a silent no-op)')

nav_no_target = { 'id' => 'a', 'trigger' => 'on-select',
                  'effects' => [{ 'effect' => 'navigate' }] }
check(ActionLedger.validate_action(nav_no_target).any?, 'navigate without target is rejected')

scv = { 'id' => 'a', 'trigger' => 'on-select',
        'effects' => [{ 'effect' => 'set-control-value', 'control' => 'RegionCtl',
                        'value' => { 'type' => 'column', 'column' => 'c-region' } }] }
check(ActionLedger.validate_action(scv).empty?, 'a well-formed set-control-value validates')
check(ActionLedger.validate_action(
  scv.merge('effects' => [scv['effects'][0].reject { |k, _| k == 'control' }])
).any?, 'set-control-value without control is rejected')

puts 'join'
detected = [{ 'kind' => 'nav-action', 'caption' => 'Go' },
            { 'kind' => 'highlight-action', 'caption' => 'Brush' }]
emitted  = [{ 'actionId' => 'act-el-1-1',
              'source' => { 'kind' => 'nav-action', 'caption' => 'Go' } }]
led = ActionLedger.join(detected: detected, emitted: emitted)
check(led['detectedCount'] == 2, 'detectedCount counts everything detected')
check(led['emitted'].size == 1, 'emitted carries the manifest entry')
check(led['residue'].size == 1, 'residue is detected minus emitted')
check(led['residue'][0]['kind'] == 'highlight-action', 'the right one is residue')
check(led['detectedCount'] == led['emitted'].size + led['residue'].size,
      'CONSERVATION: detected == emitted + residue')

puts 'key_of'
check(ActionLedger.key_of(nil).nil?, 'key_of(nil) is nil')
check(ActionLedger.key_of('kind' => 'nav-action', 'caption' => 'Go') == ['nav-action', 'Go'],
      'key_of falls back to [kind, caption] when actionName is absent')
check(ActionLedger.key_of('kind' => 'nav-action', 'caption' => 'Go', 'actionName' => '[Action4_DDDD]') ==
      ['nav-action', '[Action4_DDDD]'],
      'key_of prefers actionName over caption when present')
check(ActionLedger.key_of('kind' => 'nav-action', 'caption' => 'Go', 'actionName' => '').is_a?(Array) &&
      ActionLedger.key_of('kind' => 'nav-action', 'caption' => 'Go', 'actionName' => '') == ['nav-action', 'Go'],
      'an EMPTY actionName is treated as absent, not as the key')
check(ActionLedger.key_of('kind' => 'nav-action', 'caption' => 'Go').is_a?(Array),
      'key_of always returns an Array, never a concatenated string')

puts 'join — the known collision defect (two same-kind/same-caption actions, only one emitted)'
# THE SHIPPING BUG this proves fixed: two DIFFERENT Tableau actions share a
# kind+caption (e.g. two "Home" nav-buttons on different dashboards). Only
# ONE of them was actually auto-wired (has a manifest entry). Under the old
# key_of == [kind, caption], BOTH detected entries match the ONE claimed key,
# so BOTH vanish from residue — the unemitted one is silently dropped and
# nobody is told to wire it by hand. detectedCount == emitted.size +
# residue.size then breaks (2 != 1 + 0).
home_a = { 'kind' => 'nav-button', 'caption' => 'Home', 'actionName' => 'Overview::zone-11' }
home_b = { 'kind' => 'nav-button', 'caption' => 'Home', 'actionName' => 'Detail Page::zone-9' }
emitted_one = [{ 'actionId' => 'act-btn-11-1',
                 'source' => { 'kind' => 'nav-button', 'caption' => 'Home',
                               'actionName' => 'Overview::zone-11' } }]
led_collide = ActionLedger.join(detected: [home_a, home_b], emitted: emitted_one)
check(led_collide['detectedCount'] == 2, 'both same-caption actions are counted as detected')
check(led_collide['emitted'].size == 1, 'exactly one manifest entry was emitted')
check(led_collide['residue'].size == 1,
      "exactly ONE of the two survives as residue, not zero and not both (got #{led_collide['residue'].size})")
check((led_collide['residue'].map { |e| e['actionName'] }) == ['Detail Page::zone-9'],
      'the UNEMITTED action (home_b) is the one that lands in residue, not home_a')
check(led_collide['detectedCount'] == led_collide['emitted'].size + led_collide['residue'].size,
      'CONSERVATION holds even when kind+caption collide (this is what the old key_of broke)')

puts 'round-trip'
Dir.mktmpdir do |d|
  p = File.join(d, 'm.json')
  ActionLedger.write_manifest(p, emitted)
  check(ActionLedger.read_manifest(p) == emitted, 'manifest round-trips')
  check(ActionLedger.read_manifest(File.join(d, 'nope.json')) == [],
        'a missing manifest reads as empty, not an exception')
end

puts($fails.empty? ? "\nALL PASS" : "\n#{$fails.size} FAILURES")
exit($fails.empty? ? 0 : 1)
