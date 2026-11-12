#!/usr/bin/env python3
"""test-crop-source-visuals.py — crop-source-visuals.py on a synthetic PNG (Sales names only).

Usage: python3 scripts/test-crop-source-visuals.py
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "crop-source-visuals.py")
fails = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        fails.append(msg)


try:
    from PIL import Image
except ImportError:
    print("SKIP  Pillow not installed")
    sys.exit(0)


def v(vid, x, y, w, h, z=0, **kw):
    r = {"visual_id": vid, "visual_type": "card", "sigma_kind": "kpi", "title": vid.upper(),
         "x": x, "y": y, "w": w, "h": h, "z": z}
    r.update(kw)
    return r


SIGNALS = {"pages": [{"page_id": "p1", "page_title": "Overview", "page_w": 1280, "page_h": 720, "visuals": [
    v("sales", 0, 0, 400, 200),
    v("units", 640, 360, 320, 180),
    v("gone", 0, 400, 100, 100, hidden=True),
    v("under", 0, 560, 300, 100, z=1),
    v("over", 0, 560, 300, 100, z=5),
    v("grp", 0, 0, 10, 10, visual_type="unknown"),
]}]}

with tempfile.TemporaryDirectory() as d:
    sig = os.path.join(d, "signals.json")
    json.dump(SIGNALS, open(sig, "w"))

    # 640x360 screenshot of the 1280x720 canvas (scale 0.5): paint the units box red, sales box green
    shot = Image.new("RGB", (640, 360), (255, 255, 255))
    shot.paste((200, 0, 0), (320, 180, 480, 270))
    shot.paste((0, 160, 0), (0, 0, 200, 100))
    sp = os.path.join(d, "page.png")
    shot.save(sp)
    out = os.path.join(d, "crops")
    r = subprocess.run([sys.executable, SCRIPT, "--signals", sig, "--page", "Overview", "--screenshot", sp,
                        "--out-dir", out], capture_output=True, text=True)
    check(r.returncode == 0, f"exits 0 ({r.stderr.strip()[-120:]})")
    man = json.load(open(os.path.join(out, "crops.json")))
    ids = sorted(m["visual_id"] for m in man)
    check(ids == ["over", "sales", "units"], f"only VISIBLE visuals are cropped (not hidden, occluded or group): {ids}")
    by = {m["visual_id"]: m for m in man}
    check(by["units"]["box_px"] == [320, 180, 480, 270], f"scale = screenshot width / page_w: {by['units']['box_px']}")
    check(by["units"]["box_canvas"] == [640, 360, 320, 180], "manifest keeps the canvas box")
    check({"visual_id", "title", "kind", "box_canvas", "box_px"} <= set(by["units"]), "manifest entry shape")
    im = Image.open(os.path.join(out, by["units"]["file"]))
    check(im.size == (160, 90) and im.getpixel((5, 5)) == (200, 0, 0), "crop pixels come from the right region")
    check(Image.open(os.path.join(out, by["sales"]["file"])).getpixel((5, 5)) == (0, 160, 0), "second crop pixels")

    # a cropped screenshot (canvas origin at -100,-50 px, scale 1.0): aspect mismatch needs --offset/--scale
    shot2 = Image.new("RGB", (800, 500), (255, 255, 255))
    shot2.paste((0, 0, 200), (640 - 100, 360 - 50, 640 - 100 + 320, 360 - 50 + 180))
    sp2 = os.path.join(d, "cropped.png")
    shot2.save(sp2)
    out2 = os.path.join(d, "crops2")
    r2 = subprocess.run([sys.executable, SCRIPT, "--signals", sig, "--page", "p1", "--screenshot", sp2,
                         "--out-dir", out2], capture_output=True, text=True)
    man2 = json.load(open(os.path.join(out2, "crops.json")))
    check(any("aspect" in m["assumption"] for m in man2), "aspect mismatch without --offset/--scale is flagged in the manifest")
    out3 = os.path.join(d, "crops3")
    subprocess.run([sys.executable, SCRIPT, "--signals", sig, "--page", "p1", "--screenshot", sp2, "--out-dir", out3,
                    "--offset=-100,-50", "--scale", "1"], capture_output=True, text=True, check=True)
    man3 = {m["visual_id"]: m for m in json.load(open(os.path.join(out3, "crops.json")))}
    check(man3["units"]["box_px"] == [540, 310, 800, 490],
          f"--offset/--scale place the crop (clamped to the image): {man3['units']['box_px']}")
    check("offset=-100,-50 given explicitly" in man3["units"]["assumption"], "explicit offset/scale recorded as the assumption")
    check(Image.open(os.path.join(out3, man3["units"]["file"])).getpixel((5, 5)) == (0, 0, 200), "offset crop pixels")

# occlusion must use the group-chain z exactly like PbiReportBuild.occluded_visuals
# (fidelity-3 / whole-9): a member's z is relative to its group.
import importlib.util
_spec = importlib.util.spec_from_file_location("crop_source_visuals", SCRIPT)
_crop = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_crop)
GROUPED = [
    v("g1", 0, 0, 10, 10, z=1, visual_type="unknown"),            # group, z=1
    v("a", 0, 0, 400, 300, z=50, parent_group="g1"),               # chain [1, 50]
    v("b", 0, 0, 400, 300, z=10),                                  # chain [10]  -> above a
    v("g2", 0, 0, 10, 10, z=5000, visual_type="unknown"),
    v("c", 500, 0, 400, 300, z=0, parent_group="g2"),              # chain [5000, 0]
    v("d", 500, 0, 400, 300, z=1000),                              # chain [1000] -> below c
]
check(_crop.occluded_ids(GROUPED) == {"a", "d"},
      f"crop occlusion uses the z chain through parent_group: {_crop.occluded_ids(GROUPED)}")
_ruby = (
    "require 'json'; require_relative 'lib/pbi_reportbuild'; "
    "vs = JSON.parse(STDIN.read); "
    "puts JSON.generate(PbiReportBuild.occluded_visuals(vs).keys.sort)"
)
_r = subprocess.run(["ruby", "-e", _ruby], input=json.dumps(GROUPED), capture_output=True, text=True, cwd=HERE)
if _r.returncode == 0:
    check(json.loads(_r.stdout) == sorted(_crop.occluded_ids(GROUPED)),
          f"crop-source-visuals and PbiReportBuild.occluded_visuals agree on a grouped fixture: ruby={_r.stdout.strip()}")
else:
    print("  SKIP  ruby unavailable for the cross-check")

if fails:
    print(f"\n{len(fails)} FAILED")
    sys.exit(1)
print("\nall passed")
