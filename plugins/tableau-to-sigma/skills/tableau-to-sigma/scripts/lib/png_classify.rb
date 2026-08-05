# frozen_string_literal: true
#
# PngClassify — deterministic classifier for PNGs pulled out of a Tableau
# .twbx Image/ directory (P1 spec: p1-spec-png). Verdicts:
#
#   rounded_card — transparent corners + opaque near-uniform interior +
#                  (optionally) aspect matching its dashboard zone: a Tableau
#                  "card" background. Downstream synthesizes a styled Sigma
#                  container from the extracted fill + corner radius instead
#                  of embedding the bitmap.
#   background   — large opaque banner/backdrop: keep as a data-URI image
#                  element layered behind content.
#   art          — icon / wordmark / illustration. Default AND fail-open
#                  class: every decode problem lands here, because a
#                  wrongly-kept image is cosmetically fine while a raise
#                  kills the whole migration run.
#
# Decoder scope is deliberately narrow: 8-bit color types 6 (RGBA) and 2
# (RGB), non-interlaced only. That is everything the .twbx corpus survey
# found — Tableau (libpng) emits 8-bit type-6 non-interlaced for dashboard
# images, and type 2 appears only in bands this skill itself synthesized.
# Palette / grayscale / 16-bit / interlaced PNGs fail open to art rather
# than dragging in a full decoder for inputs that never occur.
#
# Thresholds are FIXTURE-calibrated (no real Tableau card PNG exists in the
# corpus yet), so classify() always returns a 'signals' hash of the measured
# values — future workbooks can be re-calibrated from logged signals alone.
#
# NEVER classify by filename: in the real corpus "four paths icon.png" is an
# icon but "title AS D2 i8.png" is tagline text — names lie.
#
# Pure stdlib (zlib only), Ruby 2.6-compatible: no gems, no filter_map, no
# tally, no pattern matching.
require 'zlib'

module PngClassify
  SIG        = "\x89PNG\r\n\x1a\n".b.freeze
  MAX_PIXELS = 12_000_000 # perf guard (~3 s decode ceiling on 2.6) -> fail open

  # Classifier gates. Head-room on the real corpus is >= 2x on every one
  # (nearest miss: tagline opaque_frac 0.40 vs the 0.98 gate).
  CORNER_T   = 64.0   # all four 3x3 corner patches >= 75% transparent
  EDGE_T     = 224.0  # all four edge midpoints essentially opaque
  OPAQUE_MIN = 0.98   # interior solid — a HARD gate: solid-color tagline text
                      #   measured std 0.0 with opaque_frac 0.40, so the
                      #   uniformity gate alone would misfire
  STD_MAX    = 8.0    # near-uniform fill (card fixture: 0.0; banner art: 41.8)
  ASPECT_TOL = 0.25   # |img_aspect / zone_aspect - 1| tolerance
  OPAQUE_T   = 250.0  # "fully opaque" for the background gate

  # Background size gates: zone geometry when supplied, else pixel fallbacks.
  BG_ZONE_AREA_FRAC = 0.30 # zone covers >= 30% of the dashboard canvas...
  BG_ZONE_W_FRAC    = 0.75 # ...or >= 75% of its width
  BG_W_MIN          = 1200
  BG_AREA_MIN       = 500_000
  BG_ASPECT_MIN     = 4.0

  DEFAULT_RADIUS  = 8  # when the row-0 scan finds no opaque pixel in range
  RADIUS_SCAN_MAX = 64 # radius scan clamp: min(w/2, 64)

  module_function

  # Classify one PNG. zone_w_pct / zone_h_pct are the dashboard zone's size
  # as a PERCENT (0-100) of the dashboard canvas; canvas_w / canvas_h are the
  # canvas pixel dims. All geometry is optional — the zone pcts alone drive
  # the background size gate, and the rounded-card aspect gate additionally
  # needs the canvas dims to turn pcts into a zone aspect ratio. Missing
  # geometry never blocks a verdict.
  #
  # Returns a Hash (string keys) and NEVER raises:
  #   { 'kind'      => 'rounded_card' | 'background' | 'art',
  #     'fill'      => '#rrggbb',  (rounded_card only)
  #     'radius_px' => Integer,    (rounded_card only)
  #     'signals'   => { ...measured values for debug / re-calibration... } }
  def classify(path, zone_w_pct: nil, zone_h_pct: nil, canvas_w: nil, canvas_h: nil)
    img = decode_png(path)
    return { 'kind' => 'art', 'signals' => { 'reason' => 'decode-failed' } } if img.nil?

    w = img[:w]
    h = img[:h]
    corners  = corner_alphas(img)
    edges    = edge_mid_alphas(img)
    interior = interior_stats(img)
    aspect   = w.to_f / h # h >= 1 guaranteed by decode_png

    zone_aspect = nil
    if zone_w_pct && zone_h_pct && canvas_w && canvas_h &&
       zone_w_pct.to_f > 0 && zone_h_pct.to_f > 0 && canvas_w.to_f > 0 && canvas_h.to_f > 0
      zone_aspect = (zone_w_pct.to_f * canvas_w.to_f) / (zone_h_pct.to_f * canvas_h.to_f)
    end

    corners_clear = corners.values.all? { |a| a <= CORNER_T }
    edges_solid   = edges.values.all? { |a| a >= EDGE_T }
    aspect_ok     = zone_aspect.nil? || (aspect / zone_aspect - 1.0).abs <= ASPECT_TOL

    signals = {
      'w' => w, 'h' => h, 'color_type' => img[:ct], 'aspect' => aspect.round(3),
      'corner_alpha' => { 'tl' => corners[:tl].round(1), 'tr' => corners[:tr].round(1),
                          'bl' => corners[:bl].round(1), 'br' => corners[:br].round(1) },
      'edge_alpha' => { 'top' => edges[:top].round(1), 'bottom' => edges[:bottom].round(1),
                        'left' => edges[:left].round(1), 'right' => edges[:right].round(1) },
      'opaque_frac'   => interior[:opaque_frac].round(3),
      'interior_std'  => interior[:std] ? interior[:std].round(2) : nil,
      'interior_mean' => interior[:mean] ? interior[:mean].map { |m| m.round(1) } : nil,
      'zone_aspect'   => zone_aspect ? zone_aspect.round(3) : nil,
      'corners_clear' => corners_clear, 'edges_solid' => edges_solid, 'aspect_ok' => aspect_ok
    }

    # (a) rounded card — every gate must pass. Order matters: most specific
    # verdict first, background second, art as the default.
    # interior[:std] is nil when zero interior samples are opaque (e.g. the
    # brush-X icon) — the `interior[:std] &&` guard drops that through.
    if img[:ct] == 6 && corners_clear && edges_solid &&
       interior[:opaque_frac] >= OPAQUE_MIN &&
       interior[:std] && interior[:std] <= STD_MAX && aspect_ok
      return { 'kind'      => 'rounded_card',
               'fill'      => format('#%02x%02x%02x', *interior[:mean].map { |m| m.round }),
               'radius_px' => estimate_radius(img) || DEFAULT_RADIUS,
               'signals'   => signals }
    end

    # (b) background — opaque (RGB, or RGBA with fully opaque corners AND
    # edges) and banner/backdrop sized. Zone geometry beats pixel fallbacks.
    is_opaque = img[:ct] == 2 ||
                (corners.values.all? { |a| a >= OPAQUE_T } &&
                 edges.values.all? { |a| a >= OPAQUE_T })
    is_big = if zone_w_pct && zone_h_pct
               (zone_w_pct.to_f / 100.0) * (zone_h_pct.to_f / 100.0) >= BG_ZONE_AREA_FRAC ||
                 zone_w_pct.to_f / 100.0 >= BG_ZONE_W_FRAC
             else
               w >= BG_W_MIN || w * h >= BG_AREA_MIN || aspect >= BG_ASPECT_MIN
             end
    return { 'kind' => 'background', 'signals' => signals } if is_opaque && is_big

    # (c) everything else.
    { 'kind' => 'art', 'signals' => signals }
  rescue StandardError
    # Same fail-open contract as the decoder: a classifier bug (bad geometry
    # input, arithmetic edge case) must not kill a migration run.
    { 'kind' => 'art', 'signals' => { 'reason' => 'classify-error' } }
  end

  # Minimal PNG decoder. Returns
  #   { w:, h:, ct: 2|6, bpp: 3|4, rows: Array<Array<Integer>> }
  # where rows[y] is the unfiltered scanline as a flat byte array
  # (stride = w * bpp), or nil. NEVER raises — every unsupported or broken
  # input (bad signature, truncated chunk/stream, unsupported depth/color/
  # interlace, oversized image, inflate error, bad filter byte) returns nil
  # and the caller maps nil -> art.
  def decode_png(path)
    data = File.binread(path)
    return nil unless data[0, 8] == SIG

    pos  = 8
    ihdr = nil
    idat = ''.b
    while pos + 8 <= data.bytesize
      len  = data[pos, 4].unpack('N')[0]
      type = data[pos + 4, 4]
      body = data[pos + 8, len]
      return nil if body.nil? || body.bytesize != len # truncated chunk

      case type
      when 'IHDR'
        w, h, bd, ct, comp, filt, il = body.unpack('NNC5')
        return nil unless comp == 0 && filt == 0
        ihdr = { w: w, h: h, bd: bd, ct: ct, il: il }
      when 'IDAT'
        idat << body # multiple IDATs are normal (up to 6 observed) — concat all
      when 'IEND'
        break
      end # ancillary chunks (iCCP, pHYs, tEXt, ...) skipped; CRCs not verified
      pos += 12 + len # 4 len + 4 type + len body + 4 crc
    end
    return nil if ihdr.nil? || idat.empty?

    # Support matrix (see header comment) — anything else fails open.
    return nil unless ihdr[:bd] == 8 && [2, 6].include?(ihdr[:ct]) && ihdr[:il] == 0

    w = ihdr[:w]
    h = ihdr[:h]
    return nil if w.nil? || h.nil? || w < 1 || h < 1
    return nil if w * h > MAX_PIXELS

    bpp    = ihdr[:ct] == 6 ? 4 : 3
    raw    = Zlib::Inflate.inflate(idat)
    stride = w * bpp
    return nil if raw.bytesize < (stride + 1) * h # truncated pixel stream

    # Unfilter (PNG spec section 9, filters 0-4). Filters chain row-to-row,
    # so every row must be processed sequentially even though the classifier
    # only samples a few pixels.
    prev = Array.new(stride, 0) # virtual all-zero row above row 0
    rows = Array.new(h)
    rp   = 0
    h.times do |y|
      ft = raw.getbyte(rp)
      rp += 1
      cur = raw[rp, stride].unpack('C*')
      rp += stride
      case ft
      when 0 # None
      when 1 # Sub
        bpp.upto(stride - 1) { |i| cur[i] = (cur[i] + cur[i - bpp]) & 0xFF }
      when 2 # Up
        stride.times { |i| cur[i] = (cur[i] + prev[i]) & 0xFF }
      when 3 # Average
        stride.times do |i|
          left = i >= bpp ? cur[i - bpp] : 0
          cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 0xFF
        end
      when 4 # Paeth
        stride.times do |i|
          a = i >= bpp ? cur[i - bpp] : 0 # left
          b = prev[i]                     # up
          c = i >= bpp ? prev[i - bpp] : 0 # up-left
          p = a + b - c
          pa = (p - a).abs
          pb = (p - b).abs
          pc = (p - c).abs
          pr = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
          cur[i] = (cur[i] + pr) & 0xFF
        end
      else
        return nil # invalid filter byte
      end
      rows[y] = cur
      prev = cur
    end
    { w: w, h: h, ct: ihdr[:ct], bpp: bpp, rows: rows }
  rescue StandardError, Zlib::Error
    # Zlib::Error < StandardError; listed explicitly for clarity.
    nil
  end

  # Pixel accessor: [r, g, b, a]. RGB (type 2) images report alpha 255.
  def px(img, x, y)
    row = img[:rows][y]
    o = x * img[:bpp]
    if img[:bpp] == 4
      [row[o], row[o + 1], row[o + 2], row[o + 3]]
    else
      [row[o], row[o + 1], row[o + 2], 255]
    end
  end

  # Mean alpha of the fixed 3x3 patch at each exact corner. K=3 fixed means
  # the minimum reliably detectable corner radius is ~6 px; smaller radii
  # classify as art — acceptable, container synthesis is a styling
  # optimization. Patch size clamps down on sub-3px images.
  def corner_alphas(img)
    w = img[:w]
    h = img[:h]
    kx = [3, w].min
    ky = [3, h].min
    out = {}
    { tl: [0, 0], tr: [w - kx, 0], bl: [0, h - ky], br: [w - kx, h - ky] }.each do |key, (cx, cy)|
      sum = 0
      ky.times { |dy| kx.times { |dx| sum += px(img, cx + dx, cy + dy)[3] } }
      out[key] = sum.to_f / (kx * ky)
    end
    out
  end

  # Mean alpha of 5 px centered at each edge midpoint. This is what separates
  # a rounded card (opaque straight edges between the corner radii) from
  # transparent-background art whose corners are ALSO empty (wordmarks, icons
  # — the brush-X icon is the case that mandates this gate).
  def edge_mid_alphas(img)
    w = img[:w]
    h = img[:h]
    out = {}
    { top: [w / 2, 0], bottom: [w / 2, h - 1], left: [0, h / 2], right: [w - 1, h / 2] }.each do |key, (x, y)|
      sum = 0
      cnt = 0
      (-2..2).each do |d|
        xx = key == :top || key == :bottom ? (x + d).clamp(0, w - 1) : x
        yy = key == :left || key == :right ? (y + d).clamp(0, h - 1) : y
        sum += px(img, xx, yy)[3]
        cnt += 1
      end
      out[key] = sum.to_f / cnt
    end
    out
  end

  # 16x16 sample grid over the central 60% box — resolution-independent, no
  # full histogram. Stats are computed over samples with alpha >= 128 only:
  #   opaque_frac : opaque samples / 256
  #   std         : pooled per-channel stddev (nil when nothing is opaque)
  #   mean        : per-channel means -> the card fill color
  def interior_stats(img)
    w = img[:w]
    h = img[:h]
    x0 = (w * 0.2).to_i
    x1 = (w * 0.8).to_i - 1
    y0 = (h * 0.2).to_i
    y1 = (h * 0.8).to_i - 1
    x1 = x0 if x1 < x0 # degenerate box on tiny images
    y1 = y0 if y1 < y0
    vals   = []
    opaque = 0
    total  = 0
    16.times do |j|
      16.times do |i|
        x = x0 + ((x1 - x0) * i) / 15
        y = y0 + ((y1 - y0) * j) / 15
        r, g, b, a = px(img, x, y)
        total += 1
        next if a < 128
        opaque += 1
        vals << [r, g, b]
      end
    end
    return { opaque_frac: 0.0, std: nil, mean: nil } if vals.empty?

    means = [0, 1, 2].map { |c| vals.inject(0.0) { |s, v| s + v[c] } / vals.size }
    var = 0.0
    vals.each { |v| 3.times { |c| var += (v[c] - means[c])**2 } }
    { opaque_frac: opaque.to_f / total,
      std: Math.sqrt(var / (vals.size * 3)),
      mean: means }
  end

  # Corner-radius estimate: scan row 0 left-to-right for the first x with
  # alpha >= 128 — the top edge of a rounded rect starts exactly at x = r,
  # so that x IS the radius. nil when nothing opaque within the clamp.
  def estimate_radius(img)
    limit = [img[:w] / 2, RADIUS_SCAN_MAX].min
    0.upto(limit) do |x|
      break if x >= img[:w]
      return x if px(img, x, 0)[3] >= 128
    end
    nil
  end
end
