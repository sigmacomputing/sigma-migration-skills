#!/usr/bin/env ruby
# frozen_string_literal: true
# test-nav-target-resolve.rb — a native navigate button's target page must be a
# REAL page id in the assembled workbook spec. build-charts-from-signals.rb emits
# a provisional "page-<slug>" target; MechanicalSpecs.build_wb_spec assigns the
# page ids ("page-dash-N") and must resolve the target by page name before the
# POST. Sigma rejects the whole write otherwise ("references unknown page"),
# so put-layout.rb's post-publish repair never runs. Offline, creds-free.
require 'json'
require_relative 'mechanical-specs'

fails = []
check = lambda do |cond, msg|
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

nav = lambda do |id, page|
  { 'id' => id, 'kind' => 'button', 'text' => 'Go',
    'actions' => [{ 'id' => "a-#{id}", 'trigger' => 'on-click',
                    'effects' => [{ 'effect' => 'navigate', 'target' => { 'type' => 'page', 'page' => page } }] }] }
end

pages = [
  { 'name' => 'Store Operations: Fulfillment', 'elements' => [nav.call('btn-6', 'page-store-network')] },
  { 'name' => 'Store Network', 'elements' => [nav.call('btn-29', 'page-store-operations-fulfillment'),
                                              nav.call('btn-30', 'page-dash-1'),
                                              nav.call('btn-31', 'page-no-such-dashboard')] }
]
spec = MechanicalSpecs.build_wb_spec(name: 'T', dm_id: 'dm', fact_eid: 'e1', master_columns: [],
                                     chart_elements: pages)
doc = spec['document'] || spec
check.call(doc['pages'].map { |p| p['id'] }.include?('page-dash-2'), 'the assembled spec names its pages page-dash-N')
target = lambda do |id|
  el = (doc['elements'] || doc['pages'].flat_map { |p| p['elements'] || [] }).find { |e| e['id'] == id }
  el.dig('actions', 0, 'effects', 0, 'target', 'page')
end

puts 'navigate targets resolve to the assembled page ids'
check.call(target.call('btn-6') == 'page-dash-2', "provisional slug -> page id (got #{target.call('btn-6').inspect})")
check.call(target.call('btn-29') == 'page-dash-1',
           "punctuation in the dashboard name slugs the same way as the builder (got #{target.call('btn-29').inspect})")
check.call(target.call('btn-30') == 'page-dash-1', 'a target that is already a real page id is left alone')
check.call(target.call('btn-31') == 'page-no-such-dashboard',
           'an unmatched target is left for put-layout.rb (and the API) to report, never guessed')

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILED")
exit(fails.empty? ? 0 : 1)
