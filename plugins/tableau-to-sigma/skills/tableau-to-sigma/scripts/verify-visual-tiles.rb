#!/usr/bin/env ruby
# Phase 6f-visual — IMAGE-based parity for tiles whose Tableau data export came
# back EMPTY (action-filter-gated sheets etc.). Those tiles are BUILT from the
# .twb shelf signals (so the viz is never dropped) but can't be value-diffed —
# there are no exportable actuals. Instead of letting them pass parity silently,
# this fetches the TABLEAU VIEW IMAGE (which always renders) and the SIGMA
# ELEMENT render side-by-side so the agent can confirm the migrated tile matches.
#
# Reads  <tableau-dir>/visual-verify-tiles.json  (written by build-charts-from-
# signals.rb) and writes, per tile, two PNGs + a manifest the hard gate checks:
#   <tableau-dir>/visual-verify/<slug>.tableau.png
#   <tableau-dir>/visual-verify/<slug>.sigma.png
#   <tableau-dir>/visual-verify/manifest.json
#
# Usage:
#   eval "$(scripts/get-token.sh)"; eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/verify-visual-tiles.rb --workbook <sigmaWorkbookId> --tableau-dir <dir>
#
# After it runs: READ each pair with the Read tool and compare (shape, trend,
# axis, magnitudes). Mark reviewed tiles by setting "visual_verified": true in
# the manifest, then the hard gate (assert-phase6-ran.rb) treats them as passed.

require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require_relative 'lib/tableau_rest'
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)

opts = {}
OptionParser.new do |p|
  p.on('--workbook ID')     { |v| opts[:wb] = v }
  p.on('--tableau-dir DIR') { |v| opts[:tab] = v }
  p.on('--w N', Integer)    { |v| opts[:w] = v }
  p.on('--h N', Integer)    { |v| opts[:h] = v }
  p.on('--layout PATH')     { |v| opts[:layout] = v }
  p.on('--dash-dir DIR')    { |v| opts[:dash_dir] = v }
end.parse!
%i[wb tab].each { |k| abort("missing --#{k.to_s.tr('_', '-')}") unless opts[k] }
opts[:w] ||= 1400
opts[:h] ||= 900
opts[:layout]   ||= File.join(opts[:tab], 'dashboard-layout.json')
opts[:dash_dir] ||= File.join(opts[:tab], 'dashboards')

# Dashboard-crop fallback: a "signal-only-…" view id is a PLACEHOLDER (the
# worksheet is dashboard-embedded with no standalone REST view — fetching it can
# only 404). The tile's ground truth still exists: the FULL-DASHBOARD render from
# discovery + the zone rect from the .twb layout. Crop it out. Also used when a
# real view-image fetch fails (perms, stale token) — a crop beats no image.
zone_rects = {}
if File.exist?(opts[:layout])
  ((JSON.parse(File.read(opts[:layout])) rescue nil) || []).each do |dash|
    (dash['zones'] || []).each do |z|
      cap = z['caption'].to_s
      next if cap.empty? || z['x_pct'].nil?
      zone_rects[cap] ||= [dash['dashboard'], z.values_at('x_pct', 'y_pct', 'w_pct', 'h_pct')]
    end
  end
end
CROP_PY = <<~PY
  from PIL import Image
  import sys
  src, out = sys.argv[1], sys.argv[2]
  x, y, w, h = [float(a) for a in sys.argv[3:7]]
  im = Image.open(src); W, H = im.size
  im.crop((round(W*x/100), round(H*y/100), round(W*(x+w)/100), round(H*(y+h)/100))).save(out)
PY
crop_from_dashboard = lambda do |ws, out_png|
  dash, rect = zone_rects[ws]
  return false unless dash && rect
  src = File.join(opts[:dash_dir], "#{dash}.png")
  src = Dir[File.join(opts[:dash_dir], '*.png')].first unless File.exist?(src)
  return false unless src && File.exist?(src)
  system(*PyResolve.argv, '-c', CROP_PY, PyResolve.winpath(src), PyResolve.winpath(out_png), *rect.map(&:to_s),
         out: File::NULL, err: File::NULL) && File.size?(out_png)
end

sidecar = File.join(opts[:tab], 'visual-verify-tiles.json')
unless File.exist?(sidecar)
  puts "no visual-verify-tiles.json in #{opts[:tab]} — nothing to verify (no empty-export tiles). OK."
  exit 0
end
tiles = JSON.parse(File.read(sidecar))
if tiles.empty?
  puts 'visual-verify-tiles.json is empty — no empty-export tiles. OK.'
  exit 0
end

outdir = File.join(opts[:tab], 'visual-verify')
FileUtils.mkdir_p(outdir)
png_script = File.join(__dir__, 'sigma-export-png.py')

slugify = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')[0..50] }
# Source chart kind per worksheet (from the parsed .twb zones) — context for the
# SHAPE-IDENTITY attestation below.
expected_kind_for = {}
begin
  ((JSON.parse(File.read(opts[:layout])) rescue nil) || []).each do |dash|
    (dash['zones'] || []).each do |z|
      cap = z['caption'].to_s
      expected_kind_for[cap] = z['chart_kind'] if !cap.empty? && z['chart_kind']
    end
  end
rescue StandardError
  nil
end
manifest = []
# v5.2 (speed): tiles render CONCURRENTLY (pool 3) — each tile is a Tableau
# image fetch + a 30-90s server-bound Sigma export, and the serial loop cost
# ~2min per tile on the round-4 timeline. Every iteration writes its own
# files and spawns its own child process; the manifest append is mutexed.
require 'thread'
# Pre-warm the Tableau token SERIALLY and UNCONDITIONALLY — three threads
# lazily minting at once is the concurrent-PAT-signin race, and an inherited
# env token can be STALE (review-caught: skipping the refresh when a token
# was set let all three threads 401 concurrently). A refresh failure is fine
# when the env token is actually valid — per-tile fetches report their own.
begin
  Tableau.refresh_token!
rescue StandardError
  nil
end
# Slug collisions (punctuation folding + truncation) would make two threads
# write the SAME png paths concurrently (review-caught) — dedup up front.
seen_slugs = {}
tiles.each do |t|
  s = slugify.call(t['worksheet'])
  n = (seen_slugs[s] = (seen_slugs[s] || 0) + 1)
  t['_slug'] = n == 1 ? s : "#{s}-#{n}"
end
tile_q = Queue.new
tiles.each { |t| tile_q << t }
mani_mx = Mutex.new
Array.new([3, tiles.size].min.clamp(1, 3)) do
  Thread.new do
    loop do
      t = begin
        tile_q.pop(true)
      rescue ThreadError
        break
      end
  ws   = t['worksheet']
  slug = t['_slug'] || slugify.call(ws)
  tab_png   = File.join(outdir, "#{slug}.tableau.png")
  sigma_png = File.join(outdir, "#{slug}.sigma.png")
  rec = { 'worksheet' => ws, 'element_id' => t['element_id'], 'view_id' => t['view_id'],
          'reason' => t['reason'], 'tableau_png' => nil, 'sigma_png' => nil,
          'visual_verified' => false,
          # SHAPE IDENTITY is a separate attestation from visual_verified
          # (field-caught: a run marked reshaped tiles "verified" because the
          # DATA matched — a ranked bar-table shipped as a wall of grouped
          # bars and passed). shape_match means: the Sigma tile is
          # RECOGNIZABLY THE SAME VISUALIZATION as the source zone — same
          # chart family, same encoding (bars/dots/cells), same per-row/column
          # structure. Right data in a different viz is shape_match: false.
          'expected_kind' => expected_kind_for[ws],
          'shape_match' => false }

  # 1) Tableau view image (renders fine even though its data export was empty).
  #    "signal-only-…" ids are placeholders (no standalone view) — skip straight
  #    to the dashboard-crop fallback instead of a guaranteed 404.
  begin
    if t['view_id'] && !t['view_id'].to_s.start_with?('signal-only-')
      bytes = Tableau.view_image(t['view_id'])
      File.binwrite(tab_png, bytes)
      rec['tableau_png'] = tab_png if File.size?(tab_png)
    end
  rescue StandardError => e
    warn "  WARN  Tableau image fetch failed for #{ws.inspect}: #{e.class}: #{e.message}"
  end
  if rec['tableau_png'].nil? && crop_from_dashboard.call(ws, tab_png)
    rec['tableau_png'] = tab_png
    rec['tableau_source'] = 'dashboard-crop'
  end

  # 2) Sigma element render
  render_out = nil
  if t['element_id']
    render_out, render_st = Open3.capture2e(*PyResolve.argv, PyResolve.winpath(png_script), '--workbook', opts[:wb], '--element', t['element_id'],
                                            '--out', PyResolve.winpath(sigma_png), '--w', opts[:w].to_s, '--h', opts[:h].to_s)
    rec['sigma_png'] = sigma_png if render_st.success? && File.size?(sigma_png)
  end

  status = (rec['tableau_png'] && rec['sigma_png']) ? 'READY for review' : 'INCOMPLETE'
  mani_mx.synchronize do
    puts "  #{ws}  → #{status}  (tableau=#{rec['tableau_png'] ? 'ok' : 'MISSING'}, sigma=#{rec['sigma_png'] ? 'ok' : 'MISSING'})"
    # NAME the ceiling instead of an opaque MISSING: a tile render that 500s is
    # usually the pivot's own `totals` key (probe-isolated v5.4 as the CSV-500
    # trigger; can also sink a render). Verification runs totals-free; put-layout
    # --apply-pivot-totals re-hides grand totals at ship. See refs/layout-visual-qa.md.
    if rec['sigma_png'].nil? && render_out.to_s =~ /HTTP 500/i
      puts "     [PIVOT-TOTALS/RENDER CEILING] #{ws} tile render 500'd — if it is a pivot-table, a `totals` " \
           'key is the likely cause; run the render-500 bisect in refs/layout-visual-qa.md.'
    end
    manifest << rec
  end
    end
  end
end.each(&:join)
# deterministic manifest order regardless of which render finished first
manifest.sort_by! { |m| tiles.index { |t| t['worksheet'] == m['worksheet'] } || 999 }

man_path = File.join(outdir, 'manifest.json')
File.write(man_path, JSON.pretty_generate(manifest))
ready = manifest.count { |m| m['tableau_png'] && m['sigma_png'] }
puts
puts "wrote #{man_path} (#{ready}/#{manifest.size} tile(s) ready for visual review)"
puts 'NEXT: READ each tableau_png / sigma_png pair and compare (trend, axis, magnitudes).'
puts '      Set "visual_verified": true per reviewed tile so assert-phase6-ran.rb counts it as passed.'
puts '      ALSO set "shape_match": true ONLY if the Sigma tile is RECOGNIZABLY THE SAME'
puts '      VISUALIZATION as the source (same chart family + encoding + row/column structure).'
puts '      Right data rendered as a different viz is shape_match: false — the gate fails it;'
puts '      rebuild the tile to the source shape (see refs/fidelity-recipes.md) instead.'
# Non-zero exit if any tile could not be staged for review — the orchestrator
# surfaces it rather than declaring parity done with an unverifiable tile.
exit(ready == manifest.size ? 0 : 7)
