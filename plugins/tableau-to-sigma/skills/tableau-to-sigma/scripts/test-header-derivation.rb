#!/usr/bin/env ruby
# Regression test for source-derived header chrome in build-dashboard-layout.rb.
# The skill must NOT stamp a fixed dark-navy header band on every dashboard: it
# emits a colored band ONLY when the source has a band-like fill in the header
# region, otherwise the title sits on the page canvas (transparent → no navy on
# a minimalist white source like jmackinlay's Tableau History).
#
# Exercises the pure helpers directly.  Usage: ruby scripts/test-header-derivation.rb

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-dashboard-layout.rb'))
%w[band_like_fill? header_from_source].each do |fn|
  m = SRC.match(/^def #{Regexp.escape(fn)}.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# band_like_fill?: dark OR saturated = a real band; light-neutral = blends away.
check(band_like_fill?('#8f1716'), "dark maroon is band-like", fails)
check(band_like_fill?('#0f172a'), "dark navy is band-like", fails)
check(band_like_fill?('#1e88e5'), "saturated blue is band-like", fails)
check(!band_like_fill?('#ffffff'), "white is NOT band-like", fails)
check(!band_like_fill?('#f5f5f5'), "near-white grey is NOT band-like", fails)
check(!band_like_fill?('#ececec'), "light grey card is NOT band-like", fails)

dash = ->(zones) { { 'zone_tree' => zones } }

# Minimalist source: title text on canvas, no header fill → NO band, dark title.
style, dark = header_from_source(dash.call([{ 'kind' => 'title', 'y_pct' => 1, 'w_pct' => 98, 'h_pct' => 7 }]))
check(style.nil? && dark == false, "no header fill → transparent (no fabricated navy)", fails)

# Source WITH a dark full-width header strip → reproduce it + light title.
style, dark = header_from_source(dash.call([{ 'kind' => 'container', 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 8, 'fill_color' => '#8f1716ff' }]))
check(style && style['backgroundColor'] == '#8f1716' && dark, "dark maroon strip → maroon band + light title", fails)

# A full-page background (h≈100%) is the CANVAS, not a header band.
style, = header_from_source(dash.call([{ 'kind' => 'bitmap', 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100, 'fill_color' => '#8f1716' }]))
check(style.nil?, "full-page background is the canvas, not a header band", fails)

# A light-grey top strip must NOT become a band.
style, = header_from_source(dash.call([{ 'kind' => 'container', 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 8, 'fill_color' => '#f5f5f5' }]))
check(style.nil?, "light-grey top strip blends into canvas (no band)", fails)

puts
if fails.empty?
  puts 'ALL PASS — source-derived header chrome (no fabricated navy)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
