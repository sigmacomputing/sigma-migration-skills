#!/usr/bin/env ruby
# frozen_string_literal: true
#
# render-baseline.rb — EXACT-SIZE Tableau render baseline (P2 deliverable A).
#
# WHY. Sigma renders are exact-size controllable (sigma-export-png.py takes
# pixelWidth/pixelHeight); Tableau's /image endpoint is NOT (resolution=high
# caps ~1568px on the larger dimension — it has no size params at all; the old
# vf_width/vf_height args were silent no-ops). Every visual gate therefore
# compared a ~1568px Tableau PNG against an arbitrary-size Sigma render. This
# script produces the honest side: one Tableau PNG per dashboard at the
# AUTHORED canvas size (dashboard-layout.json canvas_px, sizing-mode=fixed),
# via the only REST path that honors caller-chosen pixel dims — the /pdf
# export (vizWidth/vizHeight + type=Unspecified), rasterized to PNG.
#
# Method ladder per dashboard (recorded in the sidecar):
#   pdf                    — view_pdf at canvas dims → rasterized page 1 to
#                            exactly canvas_px (needs pypdfium2 or PyMuPDF,
#                            plus Pillow — probed, NEVER a hard dependency)
#   image-scaled           — view_image resolution=high, Pillow-resized to
#                            canvas_px (aspects agree within 2%)
#   image-aspect-mismatch  — native high-res image kept UNSTRETCHED (source
#                            aspect diverges >2% from canvas — stale layout or
#                            device-layout variant; stretching would lie)
#   image-native           — native high-res image kept as-is because no
#                            resize tooling is importable; the sidecar records
#                            the scale factor instead of resizing blind
#   native-fallback        — canvas_px is nil (automatic/range sizing or
#                            synthetic dashboard): no exact size exists — the
#                            best native PNG is copied and recorded
#
# Outputs:
#   <wd>/render-baseline/<slug>.png     one per dashboard
#   <wd>/render-baseline.png            copy of the PRIMARY dashboard's PNG
#                                       (first non-synthetic in layout order)
#   <wd>/render-baseline.json           the dims contract (per-dashboard
#                                       method/status/actual_px/source_px)
#
# ADVISORY CONTRACT: render problems NEVER exit non-zero — each dashboard's
# status lands in the sidecar and the run continues. Exit 2 only for missing
# inputs (no dashboard-layout.json / no dashboards at all).
#
# Usage:
#   eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/render-baseline.rb --tableau-dir <workdir> \
#     [--dashboard NAME]         # only this dashboard (repeatable)
#     [--method auto|pdf|image]  # default auto: pdf when a rasterizer imports
#     [--force]                  # refetch even if the sidecar says fresh
#
# Tableau image/pdf fetches stay SEQUENTIAL (VizQL session contention 401s —
# same solo rule tableau-discover.rb's dashboard-PNG loop follows).

require 'json'
require 'optparse'
require 'fileutils'
require 'tempfile'
require 'open3'
require_relative 'lib/tableau_rest'
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)

opts = { method: 'auto', dashboards: [] }
OptionParser.new do |p|
  p.on('--tableau-dir DIR')  { |v| opts[:tab] = v }
  p.on('--dashboard NAME')   { |v| opts[:dashboards] << v }
  p.on('--method M', %w[auto pdf image]) { |v| opts[:method] = v }
  p.on('--force')            { opts[:force] = true }
end.parse!
abort('missing --tableau-dir') unless opts[:tab]

layout_path = File.join(opts[:tab], 'dashboard-layout.json')
gw_path     = File.join(opts[:tab], 'get-workbook.json')
unless File.exist?(layout_path)
  warn "no dashboard-layout.json in #{opts[:tab]} — run parse-twb-layout.rb first"
  exit 2
end
layout = (JSON.parse(File.read(layout_path)) rescue nil) || []
gw     = (JSON.parse(File.read(gw_path)) rescue {})

# Neutral-env bootstrap: when only PAT creds are present (no eval'd
# get-tableau-token.sh session), mint one up front — site_id/auth_token
# otherwise raise before the 401-refresh path can engage.
if ENV['TABLEAU_AUTH_TOKEN'].to_s.empty? && ENV['TABLEAU_PAT_NAME'] && ENV['TABLEAU_PAT_SECRET']
  begin
    Tableau.refresh_token!
  rescue StandardError => e
    warn "WARN: PAT signin failed (#{e.class}: #{e.message.to_s.lines.first.to_s.strip[0, 120]}) — live fetches will fail"
  end
end
views  = gw.dig('views', 'view') || []
views  = [views] unless views.is_a?(Array)

# View id resolution — SAME source + convention as tableau-discover.rb's
# dashboard-PNG loop (view name == dashboard name; exact then case-insensitive).
view_for_dash = lambda do |dname|
  views.find { |vv| (vv['name'] || '').strip == dname.to_s.strip } ||
    views.find { |vv| (vv['name'] || '').strip.casecmp?(dname.to_s.strip) }
end

# Slug convention IDENTICAL to verify-dashboard-visual.rb (compare-manifest keys).
slugify = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')[0..50] }

# dashboards/<name>.png filename convention from tableau-discover.rb 3b.
dash_png_name = ->(dname) { dname.to_s.strip.gsub(/[^\w.-]+/, '_').gsub(/\A_+|_+\z/, '') }

# ---------------------------------------------------------------------------
# Tooling probe — which optional Python modules import? (pypdfium2 / fitz for
# PDF rasterization, PIL for resizing). NO new hard dependency: absence just
# lowers the method ladder.
# ---------------------------------------------------------------------------
PROBE_PY = <<~PY
  import json
  have = {}
  for m in ('pypdfium2', 'fitz', 'PIL'):
      try:
          __import__(m)
          have[m] = True
      except Exception:
          have[m] = False
  print(json.dumps(have))
PY
have = {}
begin
  out, st = Open3.capture2(*PyResolve.argv, '-c', PROBE_PY)
  have = JSON.parse(out) if st.success?
rescue StandardError
  have = {}
end
pil_ok = have['PIL'] == true
pdf_ok = pil_ok && (have['pypdfium2'] == true || have['fitz'] == true)
puts "tooling: pypdfium2=#{have['pypdfium2'] ? 'yes' : 'no'} PyMuPDF=#{have['fitz'] ? 'yes' : 'no'} Pillow=#{pil_ok ? 'yes' : 'no'}" \
     " → pdf path #{pdf_ok ? 'AVAILABLE' : 'unavailable (image fallback)'}"

# Rasterize page 1 of a PDF to EXACTLY w×h px.
#
# LIVE-VERIFIED (Skills-Test site, 2026-07-11): for a FIXED-size dashboard the
# /pdf export IGNORES vizWidth/vizHeight — the page is always the AUTHORED
# canvas at 0.75 pt/px (CSS px → pt) plus uniform ~36pt margins (1200×2070px
# → MediaBox 972×1624pt for ANY requested size). Since the pdf path only runs
# when canvas_px exists (fixed sizing), that's exactly what we want: detect
# the margin structure DETERMINISTICALLY (page_pt == canvas*0.75 + 2×margin,
# margin_x ≈ margin_y), render at 4/3 scale and crop the centered canvas rect
# — a native-resolution authored-size render, sharper than any image resize.
# Falls back to whole-page anisotropic render when the page IS the viz
# (margin ≈ 0), and refuses (aspect_mismatch) when the page fits neither
# model — then the caller drops to the image path rather than distort.
RASTER_PY = <<~PY
  import sys, json
  src, out = sys.argv[1], sys.argv[2]
  w, h, tol = int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
  info = {"engine": None, "page_pt": None, "margins_pt": None,
          "aspect_mismatch": False, "written": False}
  def render(scale):
      try:
          import pypdfium2 as pdfium
          page = pdfium.PdfDocument(src)[0]
          info["engine"] = "pypdfium2"
          return page.render(scale=scale).to_pil(), page.get_size()
      except ImportError:
          import fitz, io
          from PIL import Image
          page = fitz.open(src)[0]
          info["engine"] = "fitz"
          pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
          return Image.open(io.BytesIO(pix.tobytes("png"))), (page.rect.width, page.rect.height)
  def page_size():
      try:
          import pypdfium2 as pdfium
          return pdfium.PdfDocument(src)[0].get_size()
      except ImportError:
          import fitz
          r = fitz.open(src)[0].rect
          return (r.width, r.height)
  pw, ph = page_size()
  info["page_pt"] = [pw, ph]
  PT_PER_PX = 0.75  # Tableau PDF renders the viz at CSS px -> pt
  mx = (pw - w * PT_PER_PX) / 2.0
  my = (ph - h * PT_PER_PX) / 2.0
  img = None
  if abs(mx - my) <= 2.0 and -1.0 <= mx <= 100.0:
      # Margin model: page = canvas*0.75 + uniform margins. Render at 1/0.75
      # so the content region is exactly w x h px, then crop it out.
      info["margins_pt"] = [round(mx, 2), round(my, 2)]
      scale = 1.0 / PT_PER_PX
      img, _ = render(scale)
      x0 = int(round(max(mx, 0) * scale)); y0 = int(round(max(my, 0) * scale))
      x0 = min(x0, max(img.size[0] - w, 0)); y0 = min(y0, max(img.size[1] - h, 0))
      info["source_px"] = list(img.size)
      img = img.crop((x0, y0, min(x0 + w, img.size[0]), min(y0 + h, img.size[1])))
  elif abs((pw / ph) / (float(w) / h) - 1) <= tol:
      # Page IS the viz (no margins): anisotropic render straight to w x h.
      img, _ = render(max(w / pw, h / ph))
      info["source_px"] = list(img.size)
  else:
      info["aspect_mismatch"] = True
      print(json.dumps(info)); sys.exit(0)
  if img.size != (w, h):
      img = img.resize((w, h))
  img.save(out)
  info["written"] = True
  print(json.dumps(info))
PY

RESIZE_PY = <<~PY
  import sys, json
  from PIL import Image
  src, out, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
  im = Image.open(src)
  info = {"source_px": list(im.size)}
  im.resize((w, h)).save(out)
  info["written"] = True
  print(json.dumps(info))
PY

# PNG header dims (pure Ruby — IHDR width/height, big-endian at offset 16).
def png_dims(path)
  return nil unless File.size?(path)
  head = File.binread(path, 24)
  return nil unless head && head.bytesize == 24 && head[0, 8] == "\x89PNG\r\n\x1a\n".b
  head[16, 8].unpack('N2')
rescue StandardError
  nil
end

def run_py(code, *args)
  out, st = Open3.capture2(*PyResolve.argv, '-c', code, *args.map { |a| PyResolve.winpath(a.to_s) })
  return nil unless st.success?
  JSON.parse(out)
rescue StandardError
  nil
end

# ---------------------------------------------------------------------------
# Baseline loop
# ---------------------------------------------------------------------------
outdir = File.join(opts[:tab], 'render-baseline')
FileUtils.mkdir_p(outdir)
sidecar_path = File.join(opts[:tab], 'render-baseline.json')
prior = ((JSON.parse(File.read(sidecar_path)) rescue nil) || {})['dashboards'] || []
prior_by_dash = prior.each_with_object({}) { |r, h| h[r['dashboard']] = r }

records = []
primary_slug = nil
layout.each do |d|
  name = d['dashboard']
  next if opts[:dashboards].any? && !opts[:dashboards].any? { |x| x.strip.casecmp?(name.to_s.strip) }
  synthetic = name.to_s.start_with?('[synthetic]')
  slug = slugify.call(name)
  png  = File.join(outdir, "#{slug}.png")
  canvas = d['canvas_px']
  rec = { 'dashboard' => name, 'slug' => slug, 'view_id' => nil,
          'canvas_px' => canvas && { 'w' => canvas['w'], 'h' => canvas['h'] },
          'sizing_mode' => canvas && canvas['sizing_mode'],
          'method' => nil, 'png' => "render-baseline/#{slug}.png",
          'actual_px' => nil, 'source_px' => nil, 'status' => 'ok', 'note' => nil }
  primary_slug ||= slug unless synthetic

  # Freshness: reuse the prior baseline unless --force (same canvas, png on disk,
  # prior status ok).
  old = prior_by_dash[name]
  if !opts[:force] && old && old['status'] == 'ok' && old['canvas_px'] == rec['canvas_px'] &&
     File.size?(File.join(opts[:tab], old['png'].to_s))
    records << old
    puts "  #{name}  → fresh (#{old['method']}, #{(old['actual_px'] || {}).values_at('w', 'h').join('x')}) — reuse (--force to refetch)"
    next
  end

  # Synthetic sheet-only "dashboards" ARE worksheets — resolve the view by the
  # worksheet name (prefix stripped); they never have canvas_px → native path.
  v = view_for_dash.call(synthetic ? name.sub(/\A\[synthetic\]\s*/, '') : name)
  rec['view_id'] = v && v['id']

  begin
    if canvas && canvas['w'].to_i.positive? && canvas['h'].to_i.positive? && v
      w, h = canvas['w'].to_i, canvas['h'].to_i
      done = false

      # -- pdf path: the only exact-size Tableau render --------------------
      if pdf_ok && opts[:method] != 'image'
        begin
          pdf_bytes = Tableau.view_pdf(v['id'], viz_width: w, viz_height: h, type: 'Unspecified')
          tmp = Tempfile.new(['render-baseline', '.pdf'])
          begin
            tmp.binmode
            tmp.write(pdf_bytes)
            tmp.close
            info = run_py(RASTER_PY, tmp.path, png, w, h, 0.02)
            if info && info['written']
              rec['method'] = 'pdf'
              rec['source_px'] = info['source_px'] && { 'w' => info['source_px'][0], 'h' => info['source_px'][1] }
              rec['note'] = "rasterized via #{info['engine']} (page #{Array(info['page_pt']).map { |x| x.round(1) }.join('x')}pt)"
              done = true
            elsif info && info['aspect_mismatch']
              rec['note'] = "pdf page aspect #{Array(info['page_pt']).map { |x| x.round(1) }.join('x')}pt diverges >2% from canvas — vizWidth/vizHeight not honored; image fallback"
            else
              rec['note'] = 'pdf rasterization failed — image fallback'
            end
          ensure
            tmp.unlink
          end
        rescue StandardError => e
          rec['note'] = "view_pdf failed (#{e.class}: #{e.message.to_s.lines.first.to_s.strip[0, 120]}) — image fallback"
        end
      elsif opts[:method] == 'pdf' && !pdf_ok
        rec['note'] = 'no PDF rasterizer importable (pypdfium2/PyMuPDF + Pillow) — image fallback despite --method pdf'
      end

      # -- image path: resolution=high, resized (or kept native) -----------
      unless done
        bytes = Tableau.view_image(v['id'], resolution: 'high')
        native = "#{png}.native.tmp"
        File.binwrite(native, bytes)
        begin
          sw, sh = png_dims(native)
          raise "view_image returned a non-PNG (#{bytes.bytesize} bytes)" unless sw
          rec['source_px'] = { 'w' => sw, 'h' => sh }
          src_aspect = sw.to_f / sh
          canvas_aspect = w.to_f / h
          if (src_aspect / canvas_aspect - 1).abs > 0.02
            # Do NOT stretch across an aspect divergence — stale layout or a
            # device-layout variant. Keep the native pixels, say so.
            FileUtils.mv(native, png)
            rec['method'] = 'image-aspect-mismatch'
            rec['note'] = [rec['note'], "source aspect #{sw}x#{sh} vs canvas #{w}x#{h} diverges >2% — kept native, NOT stretched"].compact.join('; ')
          elsif pil_ok
            info = run_py(RESIZE_PY, native, png, w, h)
            if info && info['written']
              rec['method'] = 'image-scaled'
              rec['note'] = [rec['note'], "Pillow-resized #{sw}x#{sh} → #{w}x#{h}"].compact.join('; ')
            else
              FileUtils.mv(native, png)
              rec['method'] = 'image-native'
              rec['scale'] = { 'x' => (w.to_f / sw).round(4), 'y' => (h.to_f / sh).round(4) }
              rec['note'] = [rec['note'], 'Pillow resize failed — kept native; scale factor recorded'].compact.join('; ')
            end
          else
            # No resize tooling importable: record the scale factor instead of
            # resizing blind (consumers apply it; the sidecar is the contract).
            FileUtils.mv(native, png)
            rec['method'] = 'image-native'
            rec['scale'] = { 'x' => (w.to_f / sw).round(4), 'y' => (h.to_f / sh).round(4) }
            rec['note'] = [rec['note'], 'no Pillow — kept native at resolution=high; scale factor recorded'].compact.join('; ')
          end
        ensure
          FileUtils.rm_f(native)
        end
      end
    else
      # -- native fallback: no exact size exists ---------------------------
      rec['method'] = 'native-fallback'
      reason = if canvas.nil?
                 synthetic ? 'synthetic sheet-only dashboard' : 'no canvas_px (automatic/range sizing)'
               else
                 'no matching server view for this dashboard'
               end
      src = File.join(opts[:tab], 'dashboards', "#{dash_png_name.call(name)}.png")
      src = (v && File.join(opts[:tab], 'views', "#{v['id']}.png")) unless File.size?(src)
      if src && File.size?(src)
        FileUtils.cp(src, png)
        rec['note'] = "#{reason} — copied #{src.sub(%r{\A#{Regexp.escape(opts[:tab])}/?}, '')}"
      elsif v
        File.binwrite(png, Tableau.view_image(v['id'], resolution: 'high'))
        rec['note'] = "#{reason} — fetched live view_image resolution=high"
      else
        raise 'no cached PNG and no server view to fetch'
      end
    end

    aw, ah = png_dims(png)
    rec['actual_px'] = aw && { 'w' => aw, 'h' => ah }
    raise 'output PNG missing/unreadable' unless rec['actual_px']
  rescue StandardError => e
    # ADVISORY: a render problem never kills the run — status lands here.
    rec['status'] = 'error'
    rec['method'] ||= 'none'
    rec['note'] = [rec['note'], "#{e.class}: #{e.message.to_s.lines.first.to_s.strip[0, 160]}"].compact.join('; ')
    FileUtils.rm_f(png)
    rec['png'] = nil
  end

  exact = rec['canvas_px'] && rec['actual_px'] == rec['canvas_px']
  puts format('  %s  → %-22s %-9s %s%s', name, rec['method'], rec['status'],
              rec['actual_px'] ? "#{rec['actual_px']['w']}x#{rec['actual_px']['h']}" : '-',
              exact ? ' (exact)' : '')
  records << rec
end

if records.empty?
  warn 'no dashboards matched — nothing to baseline'
  exit 2
end

# Primary copy — the file the gates consume (find_source_png unshift target).
primary = records.find { |r| r['slug'] == primary_slug && r['status'] == 'ok' && r['png'] } ||
          records.find { |r| r['status'] == 'ok' && r['png'] }
if primary
  primary_slug = primary['slug']
  FileUtils.cp(File.join(opts[:tab], primary['png']), File.join(opts[:tab], 'render-baseline.png'))
end

sidecar = { 'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'primary' => primary && primary_slug,
            'tooling' => { 'pypdfium2' => have['pypdfium2'] == true, 'pymupdf' => have['fitz'] == true,
                           'pillow' => pil_ok },
            'dashboards' => records }
File.write(sidecar_path, JSON.pretty_generate(sidecar))

exact_n = records.count { |r| r['status'] == 'ok' && r['canvas_px'] && r['actual_px'] == r['canvas_px'] }
ok_n    = records.count { |r| r['status'] == 'ok' }
puts
puts "wrote #{sidecar_path} (#{ok_n}/#{records.size} baselined; #{exact_n} at exact authored size)" \
     "#{primary ? "; primary=#{primary_slug} → render-baseline.png" : '; NO primary PNG produced'}"
records.reject { |r| r['status'] == 'ok' }.each { |r| warn "  WARN #{r['dashboard']}: #{r['note']}" }

# ADVISORY: render problems are sidecar statuses, not exit codes.
exit 0
