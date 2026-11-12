#!/usr/bin/env python3
"""crop-source-visuals.py — cut a Power BI page screenshot into one PNG per VISIBLE visual.

  python3 scripts/crop-source-visuals.py --signals signals.json --page <page id or name> \
      --screenshot page.png --out-dir DIR [--offset X,Y] [--scale S]

The crops are what an agent reads for source-anchor values (gate 13) and per-visual compare.

Geometry. signals carry ABSOLUTE canvas boxes (x, y, w, h; extract-pbir resolves visualGroup
offsets) and the page canvas (page_w x page_h). The default scale is
screenshot width / page_w with the canvas origin at the screenshot's top-left. When the screenshot's
aspect ratio does not match the canvas (a cropped screenshot) that default is only a guess, so pass
--scale (px per canvas unit) and --offset X,Y (screenshot px of the canvas origin; may be negative);
every choice is recorded as "assumption" in each manifest entry.

Visible = not hidden and not occluded (>= 95% of its area under ONE higher-z visible visual, the
view-toggle design). Group containers get no crop. Writes <out-dir>/<visual_id>.png per visual and
<out-dir>/crops.json [{visual_id, title, kind, box_canvas, box_px, file, assumption}].

Stdlib + Pillow (the same image library visual-similarity.py uses); no new dependency.
"""
import argparse
import json
import os
import re
import sys

OCCLUDE_MIN = 0.95


def _hidden(v):
    return v.get("hidden") is True or v.get("is_hidden") is True


def _is_group(v):
    return str(v.get("visual_type", "")) == "unknown"


def _covered(a, b):
    aw, ah = float(a.get("w", 0)), float(a.get("h", 0))
    if aw <= 0 or ah <= 0:
        return 0.0
    ix = max(min(a["x"] + aw, b["x"] + b["w"]) - max(a["x"], b["x"]), 0)
    iy = max(min(a["y"] + ah, b["y"] + b["h"]) - max(a["y"], b["y"]), 0)
    return (ix * iy) / (aw * ah)


def occluded_ids(visuals):
    """Visual ids fully (>= 95%) covered by one higher-z visible visual. Mirrors
    PbiReportBuild.occluded_visuals: text, image, decoration and group containers neither
    get held nor count as occluders."""
    cand = [v for v in visuals
            if not _hidden(v) and not _is_group(v) and v.get("role_class") != "decoration"
            and v.get("sigma_kind") not in ("text", "image")]
    # PBIR z is RELATIVE within a group: the stacking key is the z chain from the top-level
    # ancestor down to the visual, compared lexicographically (a shorter prefix sorts lower).
    by_id = {str(v.get("visual_id")): v for v in visuals}

    def zkey(v):
        chain, seen, cur = [], set(), v
        while cur is not None and str(cur.get("visual_id")) not in seen:
            seen.add(str(cur.get("visual_id")))
            chain.insert(0, float(cur.get("z") or 0))
            cur = by_id.get(str(cur.get("parent_group")))
        return chain

    keys = {id(v): zkey(v) for v in cand}
    out = set()
    for a in cand:
        for b in sorted((o for o in cand if o is not a and keys[id(o)] > keys[id(a)]),
                        key=lambda o: keys[id(o)], reverse=True):
            if _covered(a, b) >= OCCLUDE_MIN:
                out.add(a["visual_id"])
                break
    return out


def find_page(signals, key):
    k = str(key).strip().lower()
    for p in signals.get("pages", []):
        if k in (str(p.get("page_id", "")).lower(), str(p.get("page_title", "")).lower()):
            return p
    return None


def plan(page, img_w, img_h, offset, scale):
    """-> (scale, (ox, oy), assumption text)."""
    pw, ph = float(page.get("page_w") or 1280), float(page.get("page_h") or 720)
    notes = []
    if scale is None:
        scale = img_w / pw
        aspect_off = abs((img_w / img_h) - (pw / ph)) / (pw / ph) > 0.02
        notes.append(f"scale={scale:.4f} = screenshot width {img_w} / page_w {pw:g}")
        if aspect_off:
            notes.append(f"WARNING aspect ratio {img_w}x{img_h} does not match canvas {pw:g}x{ph:g}: "
                         "assumed the full canvas width at the top-left; pass --scale/--offset for a cropped screenshot")
    else:
        notes.append(f"scale={scale:g} given explicitly")
    if offset is None:
        offset = (0.0, 0.0)
        notes.append("offset=0,0 (canvas origin at the screenshot's top-left)")
    else:
        notes.append(f"offset={offset[0]:g},{offset[1]:g} given explicitly")
    return scale, offset, "; ".join(notes)


def crop_all(signals, page_key, screenshot, out_dir, offset=None, scale=None):
    from PIL import Image
    page = find_page(signals, page_key)
    if page is None:
        raise SystemExit(f"page {page_key!r} not found in signals (have: "
                         f"{[p.get('page_id') for p in signals.get('pages', [])]})")
    img = Image.open(screenshot)
    img.load()
    img = img.convert("RGBA") if img.mode in ("P", "LA") else img
    w, h = img.size
    sc, (ox, oy), assumption = plan(page, w, h, offset, scale)
    visuals = page.get("visuals", [])
    occ = occluded_ids(visuals)
    os.makedirs(out_dir, exist_ok=True)
    manifest = []
    for v in visuals:
        if _hidden(v) or _is_group(v) or v["visual_id"] in occ:
            continue
        bx, by, bw, bh = (float(v.get(k, 0)) for k in ("x", "y", "w", "h"))
        left, top = round(ox + bx * sc), round(oy + by * sc)
        right, bottom = round(ox + (bx + bw) * sc), round(oy + (by + bh) * sc)
        left, top, right, bottom = max(left, 0), max(top, 0), min(right, w), min(bottom, h)
        if right <= left or bottom <= top:
            continue  # entirely outside the screenshot
        fname = re.sub(r"[^A-Za-z0-9_.-]", "_", str(v["visual_id"])) + ".png"
        img.crop((left, top, right, bottom)).save(os.path.join(out_dir, fname))
        manifest.append({"visual_id": v["visual_id"], "title": v.get("title"),
                         "kind": v.get("sigma_kind") or v.get("visual_type"),
                         "box_canvas": [bx, by, bw, bh], "box_px": [left, top, right, bottom],
                         "file": fname, "assumption": assumption})
    with open(os.path.join(out_dir, "crops.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    return manifest, assumption


def _pair(s):
    try:
        a, b = s.split(",")
        return float(a), float(b)
    except Exception:
        raise argparse.ArgumentTypeError("expected X,Y")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--signals", required=True)
    ap.add_argument("--page", required=True, help="page_id or page_title")
    ap.add_argument("--screenshot", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--offset", type=_pair, help="X,Y screenshot px of the canvas origin (cropped screenshots)")
    ap.add_argument("--scale", type=float, help="screenshot px per canvas unit (cropped screenshots)")
    a = ap.parse_args(argv)
    with open(a.signals) as f:
        signals = json.load(f)
    manifest, assumption = crop_all(signals, a.page, a.screenshot, a.out_dir, a.offset, a.scale)
    print(f"[crop-source-visuals] {len(manifest)} crop(s) -> {a.out_dir}/crops.json ({assumption})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
