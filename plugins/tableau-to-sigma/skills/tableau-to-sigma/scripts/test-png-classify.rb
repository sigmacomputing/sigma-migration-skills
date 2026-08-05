#!/usr/bin/env ruby
# Offline unit test for lib/png_classify.rb — the rounded-card PNG classifier.
#
# WHY this test synthesizes its own PNGs: the classifier's thresholds are
# FIXTURE-calibrated (no real Tableau card PNG exists in the corpus yet), so
# the contract to pin is the geometry math itself — the corner/edge/interior
# gates, fill + radius extraction, zone-geometry overrides, and the fail-open
# decode contract (nil -> art, never raise: a wrongly-kept image is cosmetic,
# a crash kills the migration run). A tiny pure-Ruby PNG writer below (color
# type 6, filter-0 rows, IDAT via Zlib::Deflate) keeps the test hermetic:
# no network, no dependence on files under ~/tableau-migration.
#
# When real field-workbook assets ARE present (PNG_CLASSIFY_ASSETS dir), Part 4 re-verifies
# the P1 spec's expected verdicts on them (those files exercise row filters
# 1/2/4 and multi-IDAT streams the synthetic fixtures don't). Skipped with a
# note when absent so the test stays green on other machines.
#
# Usage:  ruby scripts/test-png-classify.rb
require 'zlib'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/png_classify'

TMP = Dir.mktmpdir('png-classify-test')
at_exit { FileUtils.remove_entry(TMP) if File.directory?(TMP) }

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- tiny PNG writer (the ONLY encoder in the skill; test-local on purpose:
# production code never needs to WRITE PNGs, so this stays out of lib/).
# Filter byte 0 on every row; ct selects the IHDR color type so the test can
# also emit an RGB (2) fixture and an unsupported palette (3) header.
def write_png(path, w, h, ct, idat_chunks: 1)
  raw = ''.b
  h.times do |y|
    raw << "\x00".b # filter type 0 (None)
    w.times { |x| yield(x, y).each { |v| raw << v.chr } }
  end
  z = Zlib::Deflate.deflate(raw)
  chunks = ''.b
  add = lambda do |type, body|
    chunks << [body.bytesize].pack('N') << type.b << body << [Zlib.crc32(type.b + body)].pack('N')
  end
  add.call('IHDR', [w, h, 8, ct, 0, 0, 0].pack('NNC5'))
  if idat_chunks > 1 # real Tableau PNGs carry up to 6 IDATs — decoder must concat
    per = (z.bytesize / idat_chunks.to_f).ceil
    off = 0
    while off < z.bytesize
      add.call('IDAT', z[off, per])
      off += per
    end
  else
    add.call('IDAT', z)
  end
  add.call('IEND', ''.b)
  File.binwrite(path, "\x89PNG\r\n\x1a\n".b + chunks)
end

# Rounded-card pixel function: 400x300, radius 24, fill #1b2432, hard-edged
# transparent corners (mirrors the fixture the spec's thresholds were
# calibrated on).
R = 24
CARD_W = 400
CARD_H = 300
CARD_PX = lambda do |x, y|
  cx = x < R ? R : (x >= CARD_W - R ? CARD_W - R - 1 : nil)
  cy = y < R ? R : (y >= CARD_H - R ? CARD_H - R - 1 : nil)
  inside = cx && cy ? ((x - cx)**2 + (y - cy)**2 <= R * R) : true
  inside ? [27, 36, 50, 255] : [0, 0, 0, 0]
end

puts 'Part 1 — synthesized fixture verdicts'
card = File.join(TMP, 'card.png')
write_png(card, CARD_W, CARD_H, 6, &CARD_PX)
res = PngClassify.classify(card)
check(res['kind'] == 'rounded_card', "rounded-card fixture -> rounded_card (got #{res['kind']})", fails)
check(res['fill'] == '#1b2432', "card fill extracted exactly (got #{res['fill'].inspect})", fails)
check(res['radius_px'].is_a?(Integer) && (res['radius_px'] - 24).abs <= 3,
      "card radius within 24 +/- 3 (got #{res['radius_px'].inspect})", fails)
check(res['signals'].is_a?(Hash) && !res['signals']['opaque_frac'].nil?,
      'card result carries measured signals for re-calibration', fails)

card_multi = File.join(TMP, 'card-multi-idat.png')
write_png(card_multi, CARD_W, CARD_H, 6, idat_chunks: 3, &CARD_PX)
res = PngClassify.classify(card_multi)
check(res['kind'] == 'rounded_card' && res['fill'] == '#1b2432',
      "multi-IDAT card still decodes -> rounded_card #1b2432 (got #{res['kind']} #{res['fill'].inspect})", fails)

banner = File.join(TMP, 'banner.png')
write_png(banner, 1400, 100, 6) { |x, _y| [(x * 255) / 1399, 60, 120, 255] }
res = PngClassify.classify(banner)
check(res['kind'] == 'background', "opaque 1400x100 banner -> background (got #{res['kind']})", fails)

icon = File.join(TMP, 'icon.png')
write_png(icon, 64, 64, 6) { |x, y| (x / 8 + y / 8).even? ? [200, 60, 60, 255] : [240, 240, 240, 255] }
res = PngClassify.classify(icon)
check(res['kind'] == 'art', "small 64x64 opaque-corner icon -> art (got #{res['kind']})", fails)

# Text-like sparse alpha: transparent corners AND transparent edges — the
# case that mandates the edge-mid gate (corner test alone would misfire).
wordmark = File.join(TMP, 'wordmark.png')
write_png(wordmark, 300, 40, 6) do |x, y|
  glyph = x >= 20 && x <= 280 && y >= 12 && y <= 28 && (x / 6).odd?
  glyph ? [30, 60, 200, 255] : [0, 0, 0, 0]
end
res = PngClassify.classify(wordmark)
check(res['kind'] == 'art', "sparse-alpha wordmark -> art (got #{res['kind']})", fails)
check(res['signals']['opaque_frac'] < 0.98, 'wordmark opaque_frac below the 0.98 gate', fails)

rgb_band = File.join(TMP, 'rgb-band.png')
write_png(rgb_band, 1300, 80, 2) { |x, _y| [x % 255, 128, 200] }
res = PngClassify.classify(rgb_band)
check(res['kind'] == 'background', "RGB (color type 2) 1300x80 band -> background (got #{res['kind']})", fails)

puts
puts 'Part 2 — fail-open decode contract (nil -> art, never raise)'
truncated = File.join(TMP, 'truncated.png')
File.binwrite(truncated, File.binread(card)[0, 100]) # cut mid-IDAT
res = PngClassify.classify(truncated)
check(res['kind'] == 'art', "truncated PNG fails open -> art (got #{res['kind']})", fails)
check(res['signals']['reason'] == 'decode-failed', 'truncated PNG signals decode-failed', fails)

palette = File.join(TMP, 'palette.png')
write_png(palette, 8, 8, 3) { |_x, _y| [0] } # ct 3 header: unsupported color type
res = PngClassify.classify(palette)
check(res['kind'] == 'art' && res['signals']['reason'] == 'decode-failed',
      "palette (color-type-3) PNG fails open -> art (got #{res['kind']})", fails)

res = PngClassify.classify(File.join(TMP, 'does-not-exist.png'))
check(res['kind'] == 'art', "nonexistent path fails open -> art (got #{res['kind']})", fails)

puts
puts 'Part 3 — optional zone-geometry gates'
res = PngClassify.classify(card, zone_w_pct: 40, zone_h_pct: 30, canvas_w: 1000, canvas_h: 1000)
check(res['kind'] == 'rounded_card', "card + matching zone aspect stays rounded_card (got #{res['kind']})", fails)
res = PngClassify.classify(card, zone_w_pct: 80, zone_h_pct: 10, canvas_w: 1000, canvas_h: 1000)
check(res['kind'] == 'art', "card + mismatched zone aspect (8.0 vs 1.33) -> art (got #{res['kind']})", fails)
res = PngClassify.classify(banner, zone_w_pct: 80, zone_h_pct: 8)
check(res['kind'] == 'background', "opaque banner in a >=75%-width zone -> background (got #{res['kind']})", fails)
res = PngClassify.classify(banner, zone_w_pct: 20, zone_h_pct: 10)
check(res['kind'] == 'art', "opaque banner in a small zone -> art (zone info beats pixel fallback, got #{res['kind']})", fails)

puts
puts 'Part 4 — real field assets (spec expected verdicts; skipped when absent)'
ASSETS = ENV.fetch('PNG_CLASSIFY_ASSETS', '/nonexistent/png-classify-assets').freeze
if File.directory?(ASSETS)
  # The three twbx-embedded PNGs are all art (wordmark / icon / tagline) —
  # and their FILENAMES lie, which is why classification is pixel-only.
  ['wordmark.png', 'icon.png', 'tagline.png'].each do |f|
    p = File.join(ASSETS, f)
    if File.exist?(p)
      res = PngClassify.classify(p)
      check(res['kind'] == 'art', "real asset #{f} -> art (got #{res['kind']})", fails)
    else
      puts "  SKIP  #{f} not present"
    end
  end
  tb = File.join(ASSETS, 'title-band.png')
  if File.exist?(tb)
    # 2280x320 ct2: pixel fallback (w >= 1200, aspect ~7.1) — no zone dims needed.
    res = PngClassify.classify(tb)
    check(res['kind'] == 'background', "real asset title-band.png -> background (got #{res['kind']})", fails)
  else
    puts '  SKIP  title-band.png not present'
  end
else
  puts "  SKIP  #{ASSETS} not present — real-asset verdicts not exercised on this machine"
end

puts
if fails.empty?
  puts 'OK — png classifier verdicts, extraction, and fail-open contract all hold'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
