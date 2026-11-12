# frozen_string_literal: true

require 'zlib'
require_relative 'png_classify'

# png_stack.rb — stack page PNGs vertically into ONE composite PNG.
#
# WHY: a multi-dashboard workbook is graded as a whole (the blind grade's
# census is workbook-wide and record-visual-check binds the grade to the
# latest RCF render's pixels), but fidelity-loop rendered one page only, so
# operators hand-stacked composites (live re-proof). Pure Ruby (no Pillow on
# the base image): decode with PngClassify.decode_png (8-bit RGB/RGBA,
# non-interlaced — what Chromium and Tableau exports produce), pad narrower
# pages with white, separate pages with a light gray band, write RGBA.
module PngStack
  module_function

  GAP = 16
  GAP_RGBA = [229, 231, 235, 255].freeze
  PAD_RGBA = [255, 255, 255, 255].freeze
  MAX_PIXELS = 3200 * 6000

  class Error < StandardError; end

  # paths → out (written). Returns [width, height].
  def stack(paths, out, gap: GAP)
    imgs = Array(paths).map do |p|
      img = PngClassify.decode_png(p, max_pixels: MAX_PIXELS)
      raise Error, "cannot decode #{File.basename(p.to_s)} (need 8-bit RGB/RGBA, non-interlaced, at most #{MAX_PIXELS} pixels)" unless img

      img
    end
    raise Error, 'no images to stack' if imgs.empty?

    width = imgs.map { |i| i[:w] }.max
    rows = []
    imgs.each_with_index do |img, idx|
      if idx.positive?
        band = GAP_RGBA * width
        gap.times { rows << band }
      end
      img[:rows].each do |row|
        rgba = img[:bpp] == 4 ? row : row.each_slice(3).flat_map { |r, g, b| [r, g, b, 255] }
        rgba += PAD_RGBA * (width - img[:w]) if img[:w] < width
        rows << rgba
      end
    end
    write_rgba(out, width, rows)
    [width, rows.size]
  end

  def write_rgba(out, width, rows)
    raw = +''.b
    rows.each { |r| raw << "\x00".b << r.pack('C*') }
    ihdr = [width, rows.size, 8, 6, 0, 0, 0].pack('NNC5')
    png = +"\x89PNG\r\n\x1a\n".b
    png << chunk('IHDR', ihdr) << chunk('IDAT', Zlib::Deflate.deflate(raw)) << chunk('IEND', ''.b)
    File.binwrite(out, png)
  end

  def chunk(type, body)
    [body.bytesize].pack('N') + type.b + body.b + [Zlib.crc32(type + body)].pack('N')
  end
end
