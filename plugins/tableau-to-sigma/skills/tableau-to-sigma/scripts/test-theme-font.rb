#!/usr/bin/env ruby
# Plan C13 (verdict font-family): workbook font from the source, mapped to a
# font Sigma actually renders. Tableau's bundled families (Tableau Book ...)
# and any unsupported name silently fall back in Sigma, so they map to Lato;
# Arial/Georgia keep their name. A TWB with no font rule gets Tableau's
# documented default (Tableau Book) -> Lato. The fonts key MERGES into any
# existing settings.theme (name, palette overrides kept).
# Usage: LANG=en_US.UTF-8 ruby scripts/test-theme-font.rb
require 'json'
require_relative 'lib/theme_derive'

fails = []
check = lambda do |cond, msg|
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def layout_with(rules)
  [{ 'dashboard' => 'D', 'style_rules' => rules,
     'zone_tree' => [{ 'id' => 'root', 'kind' => 'container', 'children' => [] }] }]
end

# 1. Tableau Book -> Lato on both slots.
t = ThemeDerive.derive(layout_with('workbook' => { 'all' => { 'font-family' => 'Tableau Book' } }))
check.call(t['fonts'] == { 'textFont' => 'Lato', 'dataFont' => 'Lato' }, "Tableau Book -> Lato/Lato (got #{t['fonts'].inspect})")

# 2. Other Tableau bundled families.
%w[Tableau\ Regular Tableau\ Light Tableau\ Medium Tableau\ Semibold Tableau\ Bold].each do |f|
  r = ThemeDerive.derive(layout_with('workbook' => { 'all' => { 'font-family' => f } }))
  check.call(r['fonts'] == { 'textFont' => 'Lato', 'dataFont' => 'Lato' }, "#{f} -> Lato")
end

# 3. Arial / Georgia keep their name (case-insensitive, quotes stripped).
t = ThemeDerive.derive(layout_with('workbook' => { 'all' => { 'font-family' => "'Arial'" } }))
check.call(t['fonts'] == { 'textFont' => 'Arial', 'dataFont' => 'Arial' }, "Arial -> Arial (got #{t['fonts'].inspect})")
t = ThemeDerive.derive(layout_with('workbook' => { 'all' => { 'font-family' => 'georgia' } }))
check.call(t['fonts'] == { 'textFont' => 'Georgia', 'dataFont' => 'Georgia' }, "georgia -> Georgia (got #{t['fonts'].inspect})")

# 4. Unknown / unsupported source font -> Lato (Sigma would silently fall back).
t = ThemeDerive.derive(layout_with('workbook' => { 'all' => { 'font-family' => 'Papyrus' } }))
check.call(t['fonts'] == { 'textFont' => 'Lato', 'dataFont' => 'Lato' }, "unknown font Papyrus -> Lato (got #{t['fonts'].inspect})")

# 5. No font rule at all -> Tableau default (Tableau Book) -> Lato.
t = ThemeDerive.derive(layout_with({}))
check.call(t['fonts'] == { 'textFont' => 'Lato', 'dataFont' => 'Lato' }, "no font rule -> Lato default (got #{t['fonts'].inspect})")

# 6. Mixed slots map independently (title Georgia, worksheet Arial).
t = ThemeDerive.derive(layout_with('workbook' => { 'worksheet' => { 'font-family' => 'Arial' } },
                                   'dashboard' => { 'dash-title' => { 'font-family' => 'Georgia' } }))
check.call(t['fonts'] == { 'textFont' => 'Georgia', 'dataFont' => 'Arial' }, "slots map independently (got #{t['fonts'].inspect})")

# 7. apply! emits settings.theme.overrides.fonts and keeps the other overrides.
spec = {}
ThemeDerive.apply!(spec, ThemeDerive.derive(layout_with({})))
check.call(spec.dig('settings', 'theme', 'overrides', 'fonts') == { 'textFont' => 'Lato', 'dataFont' => 'Lato' },
           'apply! emits settings.theme.overrides.fonts')
check.call(spec.dig('settings', 'theme', 'name') == 'Light', 'apply! keeps theme name Light')

# 8. apply! MERGES into an existing theme (name + palette kept, never replaced).
spec = { 'settings' => { 'navigation' => { 'pageTabsInViewMode' => 'hidden' },
                         'theme' => { 'name' => 'Dark', 'overrides' => { 'categoricalScheme' => %w[#111111 #222222],
                                                                           'fonts' => { 'dataFont' => 'Roboto' } } } } }
ThemeDerive.apply!(spec, { 'fonts' => { 'textFont' => 'Lato', 'dataFont' => 'Lato' } })
th = spec['settings']['theme']
check.call(th['name'] == 'Dark', "existing theme name kept (got #{th['name'].inspect})")
check.call(th['overrides']['categoricalScheme'] == %w[#111111 #222222], 'existing palette override kept')
check.call(th['overrides']['fonts'] == { 'textFont' => 'Lato', 'dataFont' => 'Lato' }, 'fonts merged (source font wins over stale)')
check.call(spec['settings']['navigation'] == { 'pageTabsInViewMode' => 'hidden' }, 'sibling settings.navigation (C7) kept')

abort("\n#{fails.length} FAIL") unless fails.empty?
puts 'ALL PASS'
