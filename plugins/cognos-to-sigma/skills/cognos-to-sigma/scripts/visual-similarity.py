#!/usr/bin/env python3
"""Deterministic visual-similarity floor for Phase 6 parity verification.

Compares a source dashboard screenshot against a Sigma render and decides
whether the render is structurally in the same universe as the source. This
is a FLOOR, not a match-scorer: it exists so a passing "visual verdict" can
never be recorded over a render that is structurally nothing like the source
(blank/mostly-empty pages, one-bar-vs-six-bars panels, missing whole
columns/sections, single-column stacks). It deliberately tolerates font,
color, padding, spacing, and aspect-ratio differences, and even wholesale
panel rearrangement, as long as the render carries a comparable amount of
content distributed across the whole page.

Contract (consumed by the Phase 6 gate):

    python3 scripts/visual-similarity.py \
        --source <src.png> --render <render.png> --json-out <out.json> \
        [--tiles <tiles.json>] [--composite-pages N|WxH,WxH,...]

Writes JSON: {"source_health": object, "render_health": object,
              "score_layout": float, "score_ink": float,
              "score_overall": float, "pass": bool, "threshold": float,
              "notes": [str, ...]}
With --tiles, three keys are ADDED (absent otherwise — the no-tiles output
is byte-identical to the pre-tiles contract):
              {"tiles_measured": int, "tiles_blank": [str, ...],
               "per_tile_ink": {name: float, ...}}
plus "tiles_unmapped": int ONLY when a multi-dashboard layout could not be
placed on the render (see --tiles (c) below) — the detector did not arm.
Exit codes: 0 = pass, 1 = fail, 2 = deps missing or unreadable input.
Exit 2 must NEVER be treated as a pass.

--tiles (optional, render-side blank-tile detector): a JSON file of tile
bounding boxes as PERCENTAGES (0-100) of the source canvas. Two shapes are
accepted: (a) the skill's dashboard-layout.json (parse-twb-layout output) —
a dict with "zones" (or a bare zone list) of {id/caption, kind, x_pct,
y_pct, w_pct, h_pct}, where only chart-ish kinds (chart/table/pivot/viz)
are measured; (b) a plain list of {name, x_pct, y_pct, w_pct, h_pct};
(c) parse-twb-layout's REAL file shape — a top-level LIST of per-dashboard
objects ({dashboard, zones, canvas_px, ...}); story and emit_page:false
entries build no Sigma page and are dropped. One dashboard measures as (a).
With N > 1 dashboards the render is expected to be fidelity-loop's
--all-pages composite (lib/png_stack.rb: pages top to bottom, separated by a
16px rgb(229,231,235) band, narrower pages padded with white on the right):
dashboard k's boxes are measured inside page band k (layout order =
composite page order; the gate reorders), at single-page resolution, and
tile names are prefixed "<dashboard>: ". --composite-pages WxH,WxH,... (the
gate passes the per-page render sizes) places each band exactly at its own
width; without it bands come from the separators and every page is taken
as full width (a width guessed from trailing white would hide a right-hand
column that never rendered). --composite-pages N alone says the render is
an N-page composite, so a layout with a different page count is never
spread over the whole stack. Whenever tiles cannot be placed, none is
measured and "tiles_unmapped" + a note say so — never a silent "0 tiles
measured". (Until 2026-11-10 shape (c) was skipped entry by entry, so
every Tableau run measured 0 tiles.)
Each box is shrunk ~8% per side (drops tile borders/title chrome) and its
interior edge-ink density is measured on the UNTRIMMED render. A tile is
blank when its density < max(0.008, 12% of the median tile density). When
>= 3 chart tiles were measured and MORE THAN HALF are blank, the verdict
fails regardless of the global scores. Rationale: a render where every
chart shows "No data" can still clear the global ink floor because titles,
headers, and placeholder chrome carry page-level ink (observed in the
field: 9/9 blank charts passed at ink 0.401 vs floor 0.40); a blank tile
is blank no matter how its export was classified. The >1/2 rule is
deliberately conservative — one legitimately-empty chart must never fail a
healthy dashboard; the all-blank false-GREEN is the target.

Method (fully deterministic — no randomness, no model calls):
  1. Normalize: flatten alpha onto white, grayscale, downsample to <=384px.
  2. Two binary "ink" maps per image: deviation from the page background
     (histogram mode) and local gradient (catches light-on-light text).
  3. Trim outer margins (capped at 12% per side, so real emptiness survives).
  4. Signals, each in 0..1:
       cov  - render edge-ink density as a fraction of the source's
              (missing marks; asymmetric: extra ink is not penalized)
       bal  - worst-band ink share ratio over row/column thirds
              (an entire source-inked region empty in the render -> 0)
       patt - Pearson correlation of 12x12 ink-density grids
       prof - best of row/column 48-bin edge-ink profile correlations
       asp  - soft penalty only for extreme aspect-ratio mismatch (>2.2x),
              the page-geometry signature of a single-column stack
  5. score_ink = cov;  score_layout = (0.46*bal + 0.06*patt + 0.06*prof)/0.58
     score_overall = asp * (0.42*score_ink + 0.58*score_layout)
     pass = score_overall >= 0.45  AND  score_ink >= 0.40  AND  bal >= 0.10

Threshold provenance: calibrated on 20 verified-faithful migration pairs
from the skills-test corpus plus 17 failure-mode negatives (1 real failed
field migration + synthesized blank / half-empty / quarter-content /
single-column-stack pages). Do NOT tune the threshold to make a failing
render pass — a failure means STRUCTURE diverges; re-run the RCF loop.

# ---------------------------------------------------------------------------
# CALIBRATION SUMMARY (2026-07: 20 positives, 17 negatives; threshold 0.45)
# All positives >= threshold + 0.05; all negatives <= threshold - 0.05.
#
# POSITIVES (must pass)            overall   NEGATIVES (must fail)      overall
#   call-center                      0.780     field-failure (1-bar-vs-6) 0.311
#   dynamic-zoning-kpi               0.702     blank-page x4              0.000
#   ecommerce-admin                  0.534     single-column-stack x4  <= 0.001
#   er-visits                        0.872     half-page-empty x4      <= 0.343
#   social-media-campaign            0.692     quarter-content x4      <= 0.199
#   supermart-sales                  0.554
#   superstore-perf-overview         0.731   min positive 0.534 (+0.084)
#   superstore-perf-order-detail     0.834   max negative 0.343 (-0.107)
#   superstore-viz-extensions        0.629
#   course-analytics (field wb)      0.774   Sub-floors also verified:
#   chart-gallery wb x10 pages    >= 0.553     min positive cov 0.506
#                                              (ink floor 0.40, +0.106)
#                                              min positive bal 0.234
#                                              (bal floor 0.10, +0.134)
#
# TILE THRESHOLDS (0.008 abs / 12% rel / >1/2 majority): validated against
# synthetic fixtures only (test_visual_similarity_tiles.py), NOT yet against
# real corpus renders — if a real healthy dashboard ever trips the majority
# rule, capture the render+layout as a fixture before touching the numbers.
# ---------------------------------------------------------------------------
"""

import argparse
import json
import os
import sys

# Keep the sibling import reliable when this script is loaded via
# importlib.util.spec_from_file_location by another tool.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)
import png_health

REMEDIATION = (
    "visual-similarity.py requires Pillow and numpy. "
    "Install with: pip install pillow numpy"
)

try:
    import numpy as np
    from PIL import Image
except ImportError:
    sys.stderr.write(REMEDIATION + "\n")
    sys.exit(2)

# --- tunables (calibrated; see module docstring — do not tune per-run) ------
WORK = 384          # max working dimension after downsample
COARSE = 12         # coarse occupancy/pattern grid
FINE = 48           # fine profile grid
TRIM_CAP = 0.12     # max fraction of each side trimmed as outer margin
LUM_DELTA = 24      # luminance deviation from page background counted as ink
EDGE_DELTA = 20     # local gradient magnitude counted as edge ink
BAND_N = 3          # row/column bands for the balance signal
BAND_MIN_SHARE = 0.05   # source band must hold >=5% of ink to be scored
ASPECT_SOFT = 2.2   # aspect-ratio mismatch tolerated up to this factor
ASPECT_RAMP = 1.8   # penalty ramp width beyond ASPECT_SOFT

W_INK = 0.42
W_BAL = 0.46
W_PATT = 0.06
W_PROF = 0.06
W_LAYOUT = W_BAL + W_PATT + W_PROF   # 0.58

THRESHOLD = 0.45
INK_FLOOR = 0.40    # hard sub-floor on score_ink (mark coverage)
BAL_FLOOR = 0.10    # hard sub-floor on band balance

# --- per-tile blank detector (--tiles) --------------------------------------
# Zone kinds measured as chart tiles; everything else (control/text/divider/
# image/container/button/filter/title/...) is chrome, not content.
TILE_KINDS = frozenset(("chart", "table", "pivot", "viz"))
TILE_SHRINK = 0.08        # interior crop: fraction of box shaved per side
TILE_MIN_AREA_PCT = 2.0   # skip slivers/dividers below this % of canvas area
TILE_BLANK_ABS = 0.008    # absolute interior edge-ink density floor: catches
                          # the all-blank page where the median itself is ~0
                          # (a small centered "No data" label stays below it)
TILE_BLANK_REL = 0.12     # relative floor as a fraction of the median tile
                          # density — kept LOW so a healthy sparse tile (one
                          # KPI number) on an ink-rich dashboard never trips
TILE_MIN_MEASURED = 3     # majority-blank sub-check arms at this many tiles
STACK_GAP = 16            # lib/png_stack.rb PngStack::GAP (page separator rows)


def _open_flat(path):
    """Open an image with any alpha flattened onto white."""
    im = Image.open(path)
    im.load()
    if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
        rgba = im.convert("RGBA")
        flat = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        im = Image.alpha_composite(flat, rgba)
    return im


def _load_gray(path):
    """Return (grayscale float array downsampled to <=WORK, aspect ratio)."""
    return _gray_of(_open_flat(path))


def _gray_of(im):
    """_load_gray on an already-open (flattened) PIL image."""
    im = im.convert("L")
    w, h = im.size
    if w < 4 or h < 4:
        raise ValueError("image too small to analyze (%dx%d)" % (w, h))
    aspect = w / h
    scale = WORK / max(w, h)
    if scale < 1:
        im = im.resize(
            (max(1, round(w * scale)), max(1, round(h * scale))), Image.BILINEAR
        )
    return np.asarray(im, dtype=np.float32), aspect


def _ink_maps(gray):
    """Return (combined ink map, edge-only ink map) as float 0/1 arrays."""
    # explicit float64 edges: np.histogram(x, bins=16, range=(0,256)) hits a
    # broadcast regression on numpy 2.2.x with real image arrays (A/B-report
    # reproduced; fine on 2.3+). Edges are version-robust on both.
    hist, edges = np.histogram(np.asarray(gray, dtype=np.float64).ravel(),
                               bins=np.linspace(0.0, 256.0, 17))
    mode = int(np.argmax(hist))
    background = (edges[mode] + edges[mode + 1]) / 2.0
    deviation = np.abs(gray - background) > LUM_DELTA
    gx = np.abs(np.diff(gray, axis=1, prepend=gray[:, :1]))
    gy = np.abs(np.diff(gray, axis=0, prepend=gray[:1, :]))
    edge = (gx + gy) > EDGE_DELTA
    return (deviation | edge).astype(np.float32), edge.astype(np.float32)


def _capped_trim(ink, edge):
    """Trim near-empty outer margins, at most TRIM_CAP per side.

    The cap matters: it normalizes letterboxing/browser chrome without
    letting a half-empty page crop itself back into looking complete.
    """
    h, w = ink.shape
    rows = ink.sum(axis=1)
    cols = ink.sum(axis=0)
    rnz = np.nonzero(rows > w * 0.005)[0]
    cnz = np.nonzero(cols > h * 0.005)[0]
    if len(rnz) == 0 or len(cnz) == 0:
        return ink, edge
    r0 = min(int(rnz[0]), int(h * TRIM_CAP))
    r1 = max(int(rnz[-1]) + 1, h - int(h * TRIM_CAP))
    c0 = min(int(cnz[0]), int(w * TRIM_CAP))
    c1 = max(int(cnz[-1]) + 1, w - int(w * TRIM_CAP))
    return ink[r0:r1, c0:c1], edge[r0:r1, c0:c1]


def _grid(m, n):
    """Reduce a 2-D map to an n x n grid of cell means (stretch-normalized)."""
    h, w = m.shape
    ys = np.linspace(0, h, n + 1).astype(int)
    xs = np.linspace(0, w, n + 1).astype(int)
    out = np.zeros((n, n), dtype=np.float64)
    for i in range(n):
        for j in range(n):
            cell = m[ys[i]:ys[i + 1], xs[j]:xs[j + 1]]
            if cell.size:
                out[i, j] = float(cell.mean())
    return out


def _corr(a, b):
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    if a.std() < 1e-9 or b.std() < 1e-9:
        return 0.0
    return float(np.corrcoef(a, b)[0, 1])


def _band_shares(ink, n=BAND_N):
    """Fraction of total ink in each of n row bands and n column bands."""
    h, w = ink.shape
    total = float(ink.sum()) or 1.0
    shares = []
    for i in range(n):
        shares.append(float(ink[i * h // n:(i + 1) * h // n, :].sum()) / total)
    for j in range(n):
        shares.append(float(ink[:, j * w // n:(j + 1) * w // n].sum()) / total)
    return shares


def _band_balance(src_map, ren_map):
    """Worst-case render/source ink-share ratio over row+column bands."""
    src_shares = _band_shares(src_map)
    ren_shares = _band_shares(ren_map)
    worst = 1.0
    for s, r in zip(src_shares, ren_shares):
        if s > BAND_MIN_SHARE:
            worst = min(worst, min(1.0, r / s))
    return worst


def _is_dashboard_entry(entry):
    return isinstance(entry, dict) and isinstance(entry.get("zones"), list)


def _parse_zone_list(entries):
    """[(name, (x, y, w, h) pct), ...] for one dashboard's zone list."""
    tiles = []
    used = {}
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            continue
        kind = entry.get("kind")
        if kind is not None and str(kind).strip().lower() not in TILE_KINDS:
            continue
        try:
            box = tuple(
                float(entry[k]) for k in ("x_pct", "y_pct", "w_pct", "h_pct")
            )
        except (KeyError, TypeError, ValueError):
            continue  # no usable geometry on this zone
        name = entry.get("name") or entry.get("caption") or entry.get("id")
        name = str(name) if name is not None else "tile-%d" % i
        if name in used:  # duplicate captions: keep both, disambiguated
            used[name] += 1
            name = "%s#%d" % (name, used[name])
        used.setdefault(name, 1)
        tiles.append((name, box))
    return tiles


def parse_tile_pages(data):
    """Normalize a --tiles JSON payload to one tile list PER PAGE:
    [[(name, (x, y, w, h) pct), ...], ...].

    Accepts (a) a dashboard dict with "zones" (or a bare zone list) where
    entries carry a "kind"; only TILE_KINDS are chart tiles — (b) a plain
    list of {name, x_pct, y_pct, w_pct, h_pct} (no "kind" key -> measured
    as-is) — and (c) parse-twb-layout's dashboard-layout.json, a LIST of
    dashboard dicts: one page per dashboard that builds a Sigma page (story
    and emit_page:false entries are dropped), names prefixed
    "<dashboard>: " when there is more than one. (a) and (b) are a single page. Entries
    without usable geometry are skipped (containers/rows in layout trees
    legitimately lack boxes). Raises ValueError on a shape that is not a
    tiles payload at all — the caller maps that to exit 2.
    """
    if isinstance(data, dict):
        if not isinstance(data.get("zones"), list):
            raise ValueError('tiles JSON dict carries no "zones" list')
        return [_parse_zone_list(data["zones"])]
    if not isinstance(data, list):
        raise ValueError('tiles JSON must be a dict with "zones" or a list')
    dashes = [e for e in data if _is_dashboard_entry(e)]
    if not dashes:
        return [_parse_zone_list(data)]
    # Storyboards and emit_page:false (hidden parameter-host) dashboards build
    # no ordinary Sigma page (build-charts-from-signals drops them), so they
    # are never a page band of the render.
    pages_only = [e for e in dashes if not e.get("is_story") and e.get("emit_page") is not False]
    dashes = pages_only or dashes[:1]
    if len(dashes) == 1:
        return [_parse_zone_list(dashes[0]["zones"])]
    pages, seen = [], set()
    for k, dash in enumerate(dashes):
        label = dash.get("dashboard") or dash.get("name") or "page-%d" % (k + 1)
        page = []
        for name, box in _parse_zone_list(dash["zones"]):
            full = "%s: %s" % (label, name)
            if full in seen:  # two dashboards with the same caption
                full = "%s (page %d): %s" % (label, k + 1, name)
            seen.add(full)
            page.append((full, box))
        pages.append(page)
    return pages


def parse_tiles(data):
    """Flat [(name, (x, y, w, h) pct), ...] over every page of the payload
    (see parse_tile_pages). Boxes stay page-relative; compare() needs the
    per-page form (tile_pages=) to place a multi-page layout on a composite.
    """
    return [t for page in parse_tile_pages(data) for t in page]


def _measurable(box):
    """A page-relative box big enough to be a chart body (not a sliver)."""
    _, _, tw, th = box
    return tw > 0 and th > 0 and (tw * th) / 100.0 >= TILE_MIN_AREA_PCT


def parse_composite_spec(spec):
    """--composite-pages SPEC -> (n_pages, [(w, h), ...] or None).

    SPEC is either a page count ("2") or the per-page render sizes in stack
    order ("1200x900,600x450"), which the phase-6 gate reads from
    fidelity-loop's per-page PNGs. Raises ValueError on anything else."""
    text = str(spec or "").strip()
    if text.isdigit() and int(text) >= 1:
        return int(text), None
    sizes = []
    for part in text.split(","):
        bits = part.strip().lower().split("x")
        if len(bits) != 2 or not all(b.strip().isdigit() for b in bits):
            raise ValueError("--composite-pages wants N or WxH,WxH,... (got %r)" % spec)
        w, h = int(bits[0]), int(bits[1])
        if w < 1 or h < 1:
            raise ValueError("--composite-pages page size must be positive (got %r)" % part)
        sizes.append((w, h))
    if not sizes:
        raise ValueError("--composite-pages is empty")
    return len(sizes), sizes


def _composite_bands(render_path, n_pages, sizes=None):
    """Page bands of a PngStack composite: [(y0, y1, page_w), ...] in render
    pixels, or None when the render does not hold exactly n_pages bands.

    Per-page render dims are required: gap-colored content is indistinguishable
    from a PngStack separator. The exact sizes must reproduce the render's own
    dimensions; PngStack pads narrower pages with white on the right."""
    im = _open_flat(render_path)
    w, h = im.size
    if sizes is None or len(sizes) != n_pages:
        return None
    if max(pw for pw, _ in sizes) != w or \
            sum(ph for _, ph in sizes) + STACK_GAP * (n_pages - 1) != h:
        return None
    bands, y = [], 0
    for pw, ph in sizes:
        bands.append((y, y + ph, pw))
        y += ph + STACK_GAP
    return bands


def _band_tile_ink(render_path, bands, tile_pages):
    """Per-tile interior ink for a composite: each page band is cropped out
    and measured exactly like a single-page render (its own <=WORK
    downsample and ink maps), so a page's tiles keep single-page resolution
    however many pages the composite stacks."""
    im = _open_flat(render_path)
    per = {}
    for (y0, y1, pw), page in zip(bands, tile_pages):
        if pw < 4 or y1 - y0 < 4:  # degenerate band: nothing drawn there
            per.update({name: 0.0 for name, box in page if _measurable(box)})
            continue
        gray, _ = _gray_of(im.crop((0, y0, pw, y1)))
        _, edge = _ink_maps(gray)
        per.update(_tile_ink(edge, page))
    return per


def _tile_ink(edge_full, tiles):
    """Interior edge-ink density per tile, on the UNTRIMMED render map.

    Percent boxes address the full source canvas, so they are scaled onto
    the render's untrimmed pixel dims (_capped_trim would shift them).
    Each box is shrunk TILE_SHRINK per side to drop the tile's own border
    and title chrome — a blank tile's title still carries ink; its
    interior does not. The edge-only map is used deliberately: a card
    background fill that differs from the page background inks the whole
    deviation map even when the tile is empty, while flat fill has no
    gradient — an empty tinted card still reads blank.
    """
    h, w = edge_full.shape
    per = {}
    for name, (x, y, tw, th) in tiles:
        if not _measurable((x, y, tw, th)):
            continue  # divider/sliver, not a chart body
        sx, sy = tw * TILE_SHRINK, th * TILE_SHRINK
        x0 = max(0, int(round((x + sx) / 100.0 * w)))
        x1 = min(w, int(round((x + tw - sx) / 100.0 * w)))
        y0 = max(0, int(round((y + sy) / 100.0 * h)))
        y1 = min(h, int(round((y + th - sy) / 100.0 * h)))
        if x1 - x0 < 2 or y1 - y0 < 2:
            continue  # off-canvas or degenerate after scaling
        per[name] = float(edge_full[y0:y1, x0:x1].mean())
    return per


def _blank_tile_names(per_tile):
    """Tiles whose interior density sits under the blank floor.

    floor = max(TILE_BLANK_ABS, TILE_BLANK_REL * median): the relative arm
    scales with an ink-rich dashboard yet stays low enough that a sparse
    healthy tile clears it; the absolute arm catches the all-blank page
    where the median itself is ~0 and the relative floor collapses.
    """
    if not per_tile:
        return []
    med = float(np.median(np.asarray(list(per_tile.values()), dtype=np.float64)))
    floor = max(TILE_BLANK_ABS, TILE_BLANK_REL * med)
    return [name for name, dens in per_tile.items() if dens < floor]


def compare(source_path, render_path, tiles=None, tile_pages=None, composite=None):
    """Compute the similarity-floor verdict for one source/render pair.

    tiles: optional single-page tile list (parse_tiles()); tile_pages:
    optional per-page lists (parse_tile_pages()) — a multi-page layout is
    placed on the render's composite page bands. composite: optional
    parse_composite_spec() result — the render IS an N-page composite (and,
    with sizes, exactly where each page sits). Both tile args None omits only
    the tile-specific verdict keys. Source/render health objects are always
    included.
    """
    if tile_pages is None and tiles is not None:
        tile_pages = [tiles]
    source_health = png_health.analyze_image(source_path)
    render_health = png_health.analyze_image(render_path)
    health_errors = [
        "%s: %s" % (label, "; ".join(health["reasons"]))
        for label, health in (
            ("source", source_health),
            ("render", render_health),
        )
        if health["status"] == "ERROR"
    ]
    if health_errors:
        raise ValueError("image health check failed (%s)" % "; ".join(health_errors))

    gray_s, aspect_s = _load_gray(source_path)
    gray_r, aspect_r = _load_gray(render_path)
    ink_s, edge_s = _ink_maps(gray_s)
    ink_r, edge_r = _ink_maps(gray_r)
    edge_r_full = edge_r  # untrimmed: tile pct boxes address the full canvas
    ink_s, edge_s = _capped_trim(ink_s, edge_s)
    ink_r, edge_r = _capped_trim(ink_r, edge_r)

    notes = []

    # -- ink coverage (asymmetric: only missing marks are penalized) --------
    dens_s = float(edge_s.mean())
    dens_r = float(edge_r.mean())
    if dens_s > 1e-6:
        cov = min(1.0, dens_r / dens_s)
    else:
        cov = 1.0 if dens_r <= 1e-6 else 0.0
        notes.append("source appears blank — verify the source export")

    # -- band balance: is any whole page region emptied out? ----------------
    bal = min(_band_balance(ink_s, ink_r), _band_balance(edge_s, edge_r))

    # -- structure agreement -------------------------------------------------
    coarse_s, coarse_r = _grid(ink_s, COARSE), _grid(ink_r, COARSE)
    fine_s, fine_r = _grid(edge_s, FINE), _grid(edge_r, FINE)
    patt = max(0.0, _corr(coarse_s, coarse_r))
    prof = max(
        max(0.0, _corr(fine_s.sum(axis=1), fine_r.sum(axis=1))),
        max(0.0, _corr(fine_s.sum(axis=0), fine_r.sum(axis=0))),
    )

    # -- aspect-ratio sanity (single-column-stack page geometry) ------------
    ratio = max(aspect_s, aspect_r) / min(aspect_s, aspect_r)
    if ratio <= ASPECT_SOFT:
        asp = 1.0
    else:
        asp = max(0.0, 1.0 - (ratio - ASPECT_SOFT) / ASPECT_RAMP)
        notes.append(
            "extreme aspect-ratio mismatch (x%.1f): render page geometry "
            "suggests content collapsed into a single column" % ratio
        )

    score_ink = round(cov, 4)
    score_layout = round((W_BAL * bal + W_PATT * patt + W_PROF * prof) / W_LAYOUT, 4)
    score_overall = round(asp * (W_INK * score_ink + W_LAYOUT * score_layout), 4)

    passed = score_overall >= THRESHOLD
    if score_ink < INK_FLOOR:
        passed = False
        notes.append(
            "render draws only %.0f%% of the source's mark density "
            "(floor %.0f%%): charts/text are likely missing or degenerate"
            % (score_ink * 100, INK_FLOOR * 100)
        )
    if bal < BAL_FLOOR:
        passed = False
        notes.append(
            "band balance %.2f (floor %.2f): a page region that holds "
            "content in the source is (near-)empty in the render" % (bal, BAL_FLOOR)
        )

    # -- per-tile blank detector (only when --tiles was supplied) -----------
    per_tile = blank_tiles = unmapped = None
    if tile_pages is not None:
        n_pages, sizes = composite if composite else (None, None)
        n_tile_pages = len(tile_pages)
        if n_pages is None and n_tile_pages <= 1:
            per_tile = _tile_ink(edge_r_full, tile_pages[0] if tile_pages else [])
        else:
            n = n_pages or n_tile_pages
            bands = None if n != n_tile_pages else (
                [(0, gray_r.shape[0], gray_r.shape[1])] if n == 1 and not sizes
                else _composite_bands(render_path, n, sizes))
            if bands is None:
                per_tile = {}
                unmapped = sum(1 for p in tile_pages for _, b in p if _measurable(b))
                if n != n_tile_pages:
                    why = ("the layout has %d dashboard page(s) but the render "
                           "is a %d-page composite" % (n_tile_pages, n))
                elif sizes:
                    why = ("the given page sizes do not reproduce the %d-page "
                           "composite's dimensions" % n)
                else:
                    why = ("exact page sizes were not given for the %d-page "
                           "composite (--composite-pages WxH,...)" % n)
                notes.append(
                    "per-tile blank detector NOT armed: %s, so %d tile box(es) "
                    "could not be placed" % (why, unmapped)
                )
            elif n == 1 and not sizes:
                per_tile = _tile_ink(edge_r_full, tile_pages[0])
            else:
                per_tile = _band_tile_ink(render_path, bands, tile_pages)
        blank_tiles = _blank_tile_names(per_tile)
        if (
            len(per_tile) >= TILE_MIN_MEASURED
            and 2 * len(blank_tiles) > len(per_tile)
        ):
            passed = False
            notes.append(
                "%d of %d chart tiles have (near-)blank interiors (%s): "
                "the render's ink sits in titles/headers/chrome, not in "
                "marks — the all-'No data' failure mode that global floors "
                "cannot see" % (
                    len(blank_tiles), len(per_tile), ", ".join(blank_tiles)
                )
            )

    if not passed and score_overall < THRESHOLD:
        notes.append(
            "overall %.3f below threshold %.2f: render structure diverges "
            "from the source — re-run the RCF loop; do not tune the threshold"
            % (score_overall, THRESHOLD)
        )

    for label, health in (
        ("source", source_health),
        ("render", render_health),
    ):
        if health["status"] != "PASS":
            passed = False
            notes.append(
                "%s image health %s: %s"
                % (label, health["status"], "; ".join(health["reasons"]))
            )

    result = {
        "score_layout": score_layout,
        "score_ink": score_ink,
        "score_overall": score_overall,
        "pass": passed,
        "threshold": THRESHOLD,
        "notes": notes,
        "source_health": source_health,
        "render_health": render_health,
        "components": {
            "coverage": round(cov, 4),
            "band_balance": round(bal, 4),
            "pattern_corr": round(patt, 4),
            "profile_corr": round(prof, 4),
            "aspect_factor": round(asp, 4),
        },
    }
    if tile_pages is not None:  # keys ADDED only with --tiles: no-tiles JSON
        result["tiles_measured"] = len(per_tile)      # is byte-identical
        result["tiles_blank"] = blank_tiles
        result["per_tile_ink"] = {
            name: round(dens, 4) for name, dens in per_tile.items()
        }
        if unmapped is not None:
            result["tiles_unmapped"] = unmapped
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Deterministic visual-similarity floor (source vs render)."
    )
    parser.add_argument("--source", required=True, help="source dashboard PNG")
    parser.add_argument("--render", required=True, help="Sigma render PNG")
    parser.add_argument("--json-out", required=True, help="verdict JSON path")
    parser.add_argument(
        "--tiles",
        default=None,
        help="optional tile boxes JSON (pct of source canvas): the skill's "
        "dashboard-layout.json (a list of dashboards, or one dashboard's "
        "zones with kind/x_pct/y_pct/w_pct/h_pct) or a plain "
        "[{name, x_pct, y_pct, w_pct, h_pct}] list — enables the per-tile "
        "blank detector; a multi-dashboard layout is placed on a "
        "--all-pages composite render",
    )
    parser.add_argument(
        "--composite-pages",
        default=None,
        help="the render is an N-page --all-pages composite: N, or the "
        "per-page render sizes in stack order (WxH,WxH,...) so each page's "
        "tiles land on its own band at its own width",
    )
    args = parser.parse_args(argv)

    for label, path in (("source", args.source), ("render", args.render)):
        if not os.path.isfile(path):
            sys.stderr.write("%s image not found: %s\n" % (label, path))
            return 2

    tile_pages = None
    if args.tiles:
        if not os.path.isfile(args.tiles):
            sys.stderr.write("tiles JSON not found: %s\n" % args.tiles)
            return 2
        try:
            with open(args.tiles) as fh:
                tile_pages = parse_tile_pages(json.load(fh))
        except ValueError as exc:  # covers json.JSONDecodeError
            sys.stderr.write("could not parse tiles JSON: %s\n" % exc)
            return 2

    composite = None
    if args.composite_pages is not None:
        try:
            composite = parse_composite_spec(args.composite_pages)
        except ValueError as exc:
            sys.stderr.write("%s\n" % exc)
            return 2

    try:
        result = compare(args.source, args.render, tile_pages=tile_pages,
                         composite=composite)
    except Exception as exc:  # unreadable/corrupt input — never a pass
        sys.stderr.write("could not analyze images: %s\n" % exc)
        return 2

    out_dir = os.path.dirname(os.path.abspath(args.json_out))
    os.makedirs(out_dir, exist_ok=True)
    with open(args.json_out, "w") as fh:
        json.dump(result, fh, indent=2)
        fh.write("\n")

    verdict = "PASS" if result["pass"] else "FAIL"
    print(
        "visual-similarity: %s  overall=%.3f (threshold %.2f)  "
        "ink=%.3f layout=%.3f"
        % (
            verdict,
            result["score_overall"],
            result["threshold"],
            result["score_ink"],
            result["score_layout"],
        )
    )
    if tile_pages is not None:
        print(
            "  tiles: %d measured, %d blank%s"
            % (result["tiles_measured"], len(result["tiles_blank"]),
               ", %d unmapped" % result["tiles_unmapped"]
               if "tiles_unmapped" in result else "")
        )
    for note in result["notes"]:
        print("  note: %s" % note)
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
