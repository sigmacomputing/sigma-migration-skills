#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the header-band height clamp (2026-07-09).
#
# A short single-line TEXT LABEL (section/column header) that the source zone
# geometry maps to a TALL region must render as a THIN banner, not a tall empty
# colored block. Drives build-dashboard-layout.rb on a VENDORED, trimmed copy of
# the REAL Metric Series layout (fixtures below) — an earlier version
# of this test was a FALSE GREEN because a hand-built fixture (a) gave the readback
# text element a `body` the real /columns readback DROPS, and (b) didn't reproduce
# the multi-column NESTED band (tc-49[ tc-60[ tc-45 + tc-61 ] + tc-50 ]). Both are
# what actually broke the clamp, so the fixture must be the real structure.
#
# Guards: (1) each column-header label (text-46/47/48 = YEAR ON YEAR / TREND /
# TOP COUNTRIES) clamps to <= HEADER_BAND_MAX_ROWS; (2) the OUTER tinted band
# container shrinks too (the band_max propagation reaches it, not just the leaf).
#
# Usage:  ruby scripts/test-header-band-clamp.rb

require 'json'
require 'tmpdir'

DIR      = __dir__
BUILD    = File.join(DIR, 'build-dashboard-layout.rb')
LAYOUT   = File.join(DIR, 'test-fixtures', 'wb-header-band-layout.json')
WBIDS    = File.join(DIR, 'test-fixtures', 'wb-header-band-wbids.json')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

require_relative 'lib/layout'
maxrows = SigmaLayout::HEADER_BAND_MAX_ROWS

xml = nil
Dir.mktmpdir do |d|
  out = File.join(d, 'layout.xml')
  log = IO.popen(['ruby', BUILD, '--layout', LAYOUT, '--wb-ids', WBIDS, '--out', out],
                 err: %i[child out], &:read)
  abort "build produced no layout\n#{log}" unless File.exist?(out)
  xml = File.read(out)
end

def span_of(xml, id)
  m = xml.match(/elementId="#{Regexp.escape(id)}"[^>]*gridRow="(\d+)\s*\/\s*(\d+)"/)
  m && (m[2].to_i - m[1].to_i)
end

# 1) Each column-header LABEL is clamped thin (guards the body→text_runs bug).
%w[text-46 text-47 text-48].each do |id|
  s = span_of(xml, id)
  check(s && s <= maxrows, "header label #{id} clamped to <= #{maxrows} rows (got #{s.inspect})", fails)
end

# 2) The OUTER tinted band container (the horizontal header row wrapping the 3
# labels) shrinks too — band_max propagated up the nested containers. Its id is
# the container built for the header band's zone-tree node (…-49 in the source).
band = xml.match(/<GridContainer elementId="(tc-[^"]*-49)"[^>]*gridRow="(\d+)\s*\/\s*(\d+)"/)
check(band, 'outer header band container present', fails)
check(band && (band[3].to_i - band[2].to_i) <= maxrows + 1,
      "outer band container shrank to ~#{maxrows} rows (got #{band && (band[3].to_i - band[2].to_i)}) — propagation reached it", fails)

# 3) Title dedup: the source top-banner text (text-28) is the TITLE in the header
# band — used ONCE, and no fabricated page-name H1 ("hdrtext") banner alongside it.
check(xml.scan('elementId="text-28"').size == 1, 'source title (text-28) placed once — no duplicate title', fails)
check(!xml.include?('hdrtext'), 'no fabricated page-name H1 banner (source title used instead)', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
