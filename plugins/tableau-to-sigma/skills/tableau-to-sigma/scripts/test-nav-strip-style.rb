#!/usr/bin/env ruby
# frozen_string_literal: true
# nav-button-style recipe items: (1) hide Sigma's page tabs only when the source
# hides its tabs AND a native nav-button strip exists; (2) unselected bordered
# light/unfilled tabs -> outline (fillColor = border colour), the current page's
# tab and strong-fill tabs stay filled.
require 'json'
require_relative 'lib/ruby_compat'
require_relative 'lib/per_page_masters'
require_relative 'lib/button_fallback'
require_relative 'mechanical-specs'

fails = []
check = lambda do |cond, msg|
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

nav_btn = { 'id' => 'btn-3', 'kind' => 'button', 'text' => 'X',
            'actions' => [{ 'id' => 'a1', 'trigger' => 'on-click',
                            'effects' => [{ 'effect' => 'navigate', 'target' => { 'type' => 'page', 'page' => 'page-b' } }] }] }
chart = { 'id' => 'c1', 'kind' => 'text', 'body' => 'hi' }
cols = [{ 'id' => 'm1', 'name' => 'M1', 'formula' => '[T/X]' }]
build = lambda do |els, hides|
  MechanicalSpecs.build_wb_spec(name: 'T', dm_id: 'dm', fact_eid: 'e1', master_columns: cols,
                                chart_elements: [{ 'name' => 'A', 'elements' => els }],
                                theme: { 'categoricalScheme' => %w[#111111 #222222] },
                                source_hides_tabs: hides, canonical: false)
end

puts '-- page tabs'
s = build.call([chart, nav_btn], true)
check.call(s.dig('settings', 'navigation', 'pageTabsInViewMode') == 'hidden', 'showTabs false + nav buttons -> tabs hidden')
check.call(s.dig('settings', 'theme', 'overrides', 'categoricalScheme') == %w[#111111 #222222], 'existing settings keys kept')
s = build.call([chart, nav_btn], false)
check.call(s.dig('settings', 'navigation').nil?, 'showTabs true/unknown + nav buttons -> tabs kept')
s = build.call([chart], true)
check.call(s.dig('settings', 'navigation').nil?, 'showTabs false + no nav buttons -> tabs kept')

puts '-- 3-tab strip styling'
dash = 'Overview'
base = ->(id, target, extra = {}) { { 'id' => id, 'button_nav_target' => target, 'button_font_color' => '#1f4e79' }.merge(extra) }
active = ButtonFallback.nav_style(base.call('3', dash, 'button_fill_color' => '#1f4e79', 'border_color' => '#1f4e79', 'border_width' => '1'), active: true)
t2 = ButtonFallback.nav_style(base.call('4', 'Customers', 'fill_color' => '#e8eef4', 'border_color' => '#999999', 'border_width' => '1'), active: false)
t3 = ButtonFallback.nav_style(base.call('5', 'Orders', 'border_color' => '#999999', 'border_width' => '1'), active: false)
check.call(active[:fields]['appearance'] == 'filled' && active[:fields]['fillColor'] == '#1f4e79', 'active tab: filled with source fill')
check.call(t2[:fields] == { 'appearance' => 'outline', 'fillColor' => '#999999', 'fontColor' => '#1f4e79' }, "light fill + border -> outline (#{t2[:fields].inspect})")
check.call(t3[:fields]['appearance'] == 'outline' && t3[:fields]['fillColor'] == '#999999', 'no fill + border -> outline')
strong = ButtonFallback.nav_style(base.call('6', 'X', 'button_fill_color' => '#1f4e79', 'border_color' => '#000000'), active: false)
check.call(strong[:fields]['appearance'] == 'filled' && strong[:residual], 'strong fill + border -> filled, border residual noted')
noborder = ButtonFallback.nav_style(base.call('7', 'X', 'button_fill_color' => '#e8eef4'), active: false)
check.call(noborder[:fields]['appearance'] == 'filled', 'no border -> filled')
nostyle = ButtonFallback.nav_style(base.call('8', 'X', 'fill_color' => '#e8eef4', 'border_color' => '#999999', 'border_style' => 'none'), active: false)
check.call(nostyle[:fields]['appearance'] == 'filled', 'border colour with style none -> stays filled')

puts
if fails.empty?
  puts 'All checks passed.'
else
  puts "#{fails.length} FAILED"
  exit 1
end
