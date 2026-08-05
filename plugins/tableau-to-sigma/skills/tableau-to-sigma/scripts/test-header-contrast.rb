#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for header/title CONTRAST (cold-migration bug: the migrated
# "Superstore KEY PERFORMANCE INDICATORS" title rendered as DARK text (#1b1b1b)
# inside a WHITE background-color span sitting in a header container whose
# style.backgroundColor was #000000 — an unreadable dark-on-black title in a
# white box on a black band).
#
# The fix has ONE source of truth (ZoneCensus.dark_header_fill) that BOTH the
# layout container bg (build-dashboard-layout#header_from_source) and the title
# text colour (build-charts#text_body_from_runs force_color) derive from, so
# they can never disagree. This test asserts:
#   1. text_body_from_runs(force_color:) forces the title light + drops the
#      background-color span (the exact buggy shape → fixed shape).
#   2. ZoneCensus.dark_header_fill flags a dark band, not a light/bright one.
#   3. dark_header_fill AGREES with header_from_source's `dark` flag (drift guard).
#
# Usage:  ruby scripts/test-header-contrast.rb
require 'json'
require_relative 'lib/zone_census'

DIR = __dir__
CHARTS = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
LAYOUT = File.read(File.join(DIR, 'build-dashboard-layout.rb'))

m = CHARTS.match(/^def text_body_from_runs\b.*?\n^end$/m) or abort 'could not extract text_body_from_runs'
eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
%w[band_like_fill? header_from_source].each do |fn|
  mm = LAYOUT.match(/^def #{Regexp.escape(fn)}.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(mm[0]) # rubocop:disable Security/Eval
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

TITLE_RUNS = [{ 'text' => 'SUPERSTORE KEY PERFORMANCE INDICATORS', 'color' => '#1b1b1b', 'font_size' => 24 }].freeze

# ---- 1. the buggy shape, then the fixed shape -------------------------------
buggy = text_body_from_runs(TITLE_RUNS, bg: '#ffffff')
check(buggy.include?('color: #1b1b1b') && buggy.downcase.include?('background-color: #ffffff'),
      "baseline reproduces the bug shape (dark #1b1b1b text + white bg span) (got #{buggy.inspect})", fails)

fixed = text_body_from_runs(TITLE_RUNS, bg: '#ffffff', force_color: '#FFFFFF')
check(fixed.include?('color: #FFFFFF'), "dark-band title forced to LIGHT (white) text (got #{fixed.inspect})", fails)
check(!fixed.include?('#1b1b1b'), 'the source dark colour is overridden (not #1b1b1b)', fails)
check(!fixed.downcase.include?('background-color'),
      'NO white background-color span survives on a dark band (dropped)', fails)

# A run with NO explicit colour still gets the forced light colour.
nc = text_body_from_runs([{ 'text' => 'Header' }], force_color: '#FFFFFF')
check(nc.include?('color: #FFFFFF'), 'a colourless run is still forced light on a dark band', fails)

# ---- 2. dark_header_fill: dark band → hex; light/bright/none → nil ----------
strip = ->(zones) { { 'zone_tree' => zones } }
DARK   = [{ 'kind' => 'container', 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 8, 'fill_color' => '#000000ff' }].freeze
LIGHT  = [{ 'kind' => 'container', 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 8, 'fill_color' => '#f5f5f5' }].freeze
YELLOW = [{ 'kind' => 'container', 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 8, 'fill_color' => '#ffd400' }].freeze
CANVAS = [{ 'kind' => 'bitmap',    'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100, 'fill_color' => '#000000' }].freeze
NONE   = [{ 'kind' => 'title',     'y_pct' => 1, 'w_pct' => 98,  'h_pct' => 7 }].freeze

check(ZoneCensus.dark_header_fill(DARK) == '#000000', 'black header strip → dark_header_fill returns #000000', fails)
check(ZoneCensus.dark_header_fill(LIGHT).nil?, 'light-grey strip → nil (dark title is fine there)', fails)
check(ZoneCensus.dark_header_fill(YELLOW).nil?, 'bright saturated yellow strip → nil (light band, dark title reads)', fails)
check(ZoneCensus.dark_header_fill(CANVAS).nil?, 'full-page background (h≈100) is the canvas, not a dark header', fails)
check(ZoneCensus.dark_header_fill(NONE).nil?, 'no header fill → nil', fails)

# ---- 3. drift guard: dark_header_fill agrees with header_from_source[dark] --
[DARK, LIGHT, YELLOW, CANVAS, NONE].each_with_index do |tree, i|
  _style, dark = header_from_source(strip.call(tree))
  agree = (!ZoneCensus.dark_header_fill(tree).nil?) == (dark == true)
  check(agree, "fixture #{i}: dark_header_fill agrees with header_from_source's dark flag (single source of truth)", fails)
end

puts
if fails.empty?
  puts 'ALL PASS — header/title contrast: dark band ⇒ light title + no white bg span (one source of truth)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
