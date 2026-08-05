#!/usr/bin/env python3
"""Offline tests for the --tiles per-tile blank detector in visual-similarity.py.

Run: python3 scripts/test_visual_similarity_tiles.py

Covers W1.7: a render where every chart shows "No data" can clear the GLOBAL
ink floor because titles/headers/placeholders carry page-level ink (field
case: 9/9 blank charts passed at ink 0.401 vs floor 0.40). The per-tile
detector measures each chart tile's interior and fails the verdict when more
than half are blank. Synthetic fixtures only; the all-blank fixture is tuned
so the GLOBAL floors pass on it — proving the tile sub-check, not the global
score, is what catches the failure.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "visual-similarity.py")

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.stderr.write("tests require Pillow/numpy: pip install pillow numpy\n")
    sys.exit(2)


def _load_module():
    spec = importlib.util.spec_from_file_location("visual_similarity", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


VS = _load_module()

# --- synthetic 3x3 tile dashboard --------------------------------------------
#
# Chrome-heavy on purpose: header band, nav blocks, footer, and per-tile
# title/subtitle/axis-label chrome that all survive a blank render (as in the
# field failure). Tile chrome sits inside the 8% interior-shrink margins
# (21px of a 263px tile) with >=3px of slack for downsample blur, so a blank
# tile's interior carries only its small centered "No data" lump.

W, H = 1200, 900
MARGIN, GUTTER, GRID_TOP = 20, 10, 70
COLS = ROWS = 3
TILE_W = (W - 2 * MARGIN - (COLS - 1) * GUTTER) // COLS            # 380
TILE_H = (H - GRID_TOP - MARGIN - (ROWS - 1) * GUTTER) // ROWS     # 263

INK = (40, 40, 60)
ACCENT = (46, 84, 158)
CHROME = (60, 60, 80)
FAINT = (150, 150, 160)

BAR_HEIGHTS = [0.55, 0.8, 0.35, 0.95]


def tile_origin(r, c):
    return (MARGIN + c * (TILE_W + GUTTER), GRID_TOP + r * (TILE_H + GUTTER))


def make_tiled_dashboard(blank=frozenset()):
    """Header + footer + 3x3 chart grid; tiles in `blank` keep chrome only."""
    im = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([MARGIN, 12, W - MARGIN, 40], fill=ACCENT)          # header
    for k in range(6):                                              # nav row
        x = MARGIN + k * 190
        d.rectangle([x, 46, x + 120, 58], fill=CHROME)
    d.rectangle([MARGIN, H - 14, W - MARGIN, H - 6], fill=CHROME)   # footer
    for r in range(ROWS):
        for c in range(COLS):
            x0, y0 = tile_origin(r, c)
            x1, y1 = x0 + TILE_W, y0 + TILE_H
            d.rectangle([x0, y0, x1, y1], outline=(246, 246, 246), width=1)
            # title + subtitle chrome, kept above y0+16 (interior starts y0+21)
            d.rectangle([x0 + 8, y0 + 2, x1 - 60, y0 + 9], fill=CHROME)
            d.rectangle([x0 + 8, y0 + 11, x0 + 170, y0 + 15], fill=FAINT)
            # x-axis label chrome in the BOTTOM shrink margin (category labels
            # render even when a tile has no data)
            d.rectangle([x0 + 30, y1 - 14, x1 - 40, y1 - 10], fill=FAINT)
            body_top, body_bot = y0 + 40, y1 - 26
            if (r, c) in blank:
                cx, cy = (x0 + x1) // 2, (body_top + body_bot) // 2
                d.rectangle([cx - 15, cy - 2, cx + 15, cy + 2], fill=FAINT)
                continue
            d.line([x0 + 30, body_bot, x1 - 20, body_bot], fill=INK, width=2)
            span = (TILE_W - 60) / 4.0
            for i in range(4):
                bh = BAR_HEIGHTS[i] * (body_bot - body_top)
                bx0 = x0 + 34 + i * span
                d.rectangle([bx0, body_bot - bh, bx0 + span * 0.6, body_bot - 2],
                            fill=ACCENT)
            d.rectangle([x0 + 34, body_top + 4, x0 + 90, body_top + 10], fill=INK)
    return im


def tile_box_pct(r, c):
    x0, y0 = tile_origin(r, c)
    return {"x_pct": x0 / W * 100, "y_pct": y0 / H * 100,
            "w_pct": TILE_W / W * 100, "h_pct": TILE_H / H * 100}


def plain_tiles_list():
    """Shape (b): plain [{name, x_pct, y_pct, w_pct, h_pct}] list."""
    return [dict(tile_box_pct(r, c), name="tile-%d-%d" % (r, c))
            for r in range(ROWS) for c in range(COLS)]


def layout_dict():
    """Shape (a): parse-twb-layout dashboard-layout.json — dict with zones,
    chart-ish kinds mixed with chrome zones that must be skipped."""
    kinds = ["chart", "table", "pivot", "viz"]
    zones = [
        {"id": "1", "kind": "text", "caption": "Dashboard Title",
         "x_pct": 1.7, "y_pct": 1.3, "w_pct": 96.7, "h_pct": 3.1},
        {"id": "2", "kind": "filter", "caption": "Region",
         "x_pct": 1.7, "y_pct": 5.1, "w_pct": 20.0, "h_pct": 1.3},
        {"id": "3", "kind": "container"},  # layout node, no geometry
        # chart-kind sliver (a divider-ish strip): area 1.45% < 2% -> skipped
        {"id": "4", "kind": "chart", "caption": "Sliver",
         "x_pct": 1.7, "y_pct": 6.5, "w_pct": 96.7, "h_pct": 1.5},
    ]
    for i, (r, c) in enumerate((r, c) for r in range(ROWS) for c in range(COLS)):
        zone = dict(tile_box_pct(r, c), id=str(10 + i), kind=kinds[i % 4])
        # one zone with a null caption -> name falls back to the id
        zone["caption"] = None if i == 4 else "Chart %d-%d" % (r, c)
        zones.append(zone)
    return {"dashboard": "Test Dash", "zones": zones}


ALL_TILES = frozenset((r, c) for r in range(ROWS) for c in range(COLS))
FOUR_TILES = frozenset(((0, 0), (0, 2), (1, 1), (2, 1)))
FIVE_TILES = FOUR_TILES | {(2, 0)}

LEGACY_KEYS = {"score_layout", "score_ink", "score_overall", "pass",
               "threshold", "notes", "components"}
TILE_KEYS = {"tiles_measured", "tiles_blank", "per_tile_ink"}


class FixtureMixin:
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="vissim-tiles-test-")
        cls.paths = {}

        def save(name, im):
            p = os.path.join(cls.dir, name + ".png")
            im.save(p)
            cls.paths[name] = p
            return p

        save("source", make_tiled_dashboard())
        save("healthy", make_tiled_dashboard())
        save("allblank", make_tiled_dashboard(blank=ALL_TILES))
        save("oneblank", make_tiled_dashboard(blank=frozenset({(1, 1)})))
        save("fourblank", make_tiled_dashboard(blank=FOUR_TILES))
        save("fiveblank", make_tiled_dashboard(blank=FIVE_TILES))
        # same all-blank page exported at half size (render dims differ from
        # source dims; pct boxes must scale onto the render's own pixels)
        halfsize = make_tiled_dashboard(blank=ALL_TILES).resize(
            (W // 2, H // 2), Image.BILINEAR)
        save("allblank_half", halfsize)

        def save_json(name, obj):
            p = os.path.join(cls.dir, name + ".json")
            with open(p, "w") as fh:
                json.dump(obj, fh)
            cls.paths[name] = p
            return p

        save_json("tiles_plain", plain_tiles_list())
        save_json("tiles_layout", layout_dict())
        save_json("tiles_bad_shape", {"foo": 1})
        corrupt = os.path.join(cls.dir, "tiles_corrupt.json")
        with open(corrupt, "w") as fh:
            fh.write("{not json")
        cls.paths["tiles_corrupt"] = corrupt

        cls.tiles = VS.parse_tiles(plain_tiles_list())

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def run_cli(self, source, render, tiles=None, json_out=None):
        json_out = json_out or os.path.join(self.dir, "out.json")
        cmd = [sys.executable, SCRIPT, "--source", source, "--render", render,
               "--json-out", json_out]
        if tiles:
            cmd += ["--tiles", tiles]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        data = None
        if os.path.isfile(json_out) and proc.returncode in (0, 1):
            with open(json_out) as fh:
                data = json.load(fh)
        return proc, data


class TestTileParsing(FixtureMixin, unittest.TestCase):
    def test_layout_dict_keeps_only_chartish_zones(self):
        tiles = VS.parse_tiles(layout_dict())
        # 9 grid zones + the chart-kind sliver survive the KIND filter (the
        # sliver is dropped later by the 2%-area rule); text/filter/container
        # zones are chrome, not chart tiles
        self.assertEqual(len(tiles), 10)
        names = [name for name, _ in tiles]
        self.assertIn("Sliver", names)
        self.assertIn("Chart 0-0", names)
        self.assertIn("14", names, "null caption must fall back to the id")
        self.assertNotIn("Dashboard Title", names)
        self.assertNotIn("Region", names)

    def test_bare_zone_list_accepted(self):
        tiles = VS.parse_tiles(layout_dict()["zones"])
        self.assertEqual(len(tiles), 10)

    def test_plain_list_uses_name(self):
        tiles = VS.parse_tiles(plain_tiles_list())
        self.assertEqual(len(tiles), 9)
        self.assertEqual(tiles[0][0], "tile-0-0")

    def test_duplicate_captions_disambiguated(self):
        box = tile_box_pct(0, 0)
        tiles = VS.parse_tiles([dict(box, name="Sales"), dict(box, name="Sales")])
        self.assertEqual([n for n, _ in tiles], ["Sales", "Sales#2"])

    def test_unusable_payloads_raise(self):
        for bad in ({"foo": 1}, "not tiles", 42, {"zones": "nope"}):
            with self.assertRaises(ValueError):
                VS.parse_tiles(bad)


class TestTileScoring(FixtureMixin, unittest.TestCase):
    def test_healthy_render_zero_blank_and_passes(self):
        res = VS.compare(self.paths["source"], self.paths["healthy"],
                         tiles=self.tiles)
        self.assertTrue(res["pass"], res)
        self.assertEqual(res["tiles_measured"], 9)
        self.assertEqual(res["tiles_blank"], [])
        self.assertEqual(len(res["per_tile_ink"]), 9)
        for name, dens in res["per_tile_ink"].items():
            self.assertGreater(dens, 0.008, name)

    def test_all_blank_fails_even_though_global_floors_pass(self):
        # THE W1.7 failure: global floors pass on chrome ink alone...
        res_global = VS.compare(self.paths["source"], self.paths["allblank"])
        self.assertTrue(
            res_global["pass"],
            "fixture drift: the all-blank render must PASS the global floors "
            "(that false-GREEN is what the tile detector exists for): %r"
            % res_global,
        )
        self.assertGreaterEqual(res_global["score_ink"], VS.INK_FLOOR)
        # ...and the per-tile detector is what catches it
        res = VS.compare(self.paths["source"], self.paths["allblank"],
                         tiles=self.tiles)
        self.assertFalse(res["pass"], res)
        self.assertEqual(res["tiles_measured"], 9)
        self.assertEqual(len(res["tiles_blank"]), 9)
        note = " ".join(res["notes"])
        self.assertIn("blank interiors", note)
        self.assertIn("tile-1-1", note, "failure note must name the tiles")

    def test_one_blank_of_nine_does_not_fail(self):
        res = VS.compare(self.paths["source"], self.paths["oneblank"],
                         tiles=self.tiles)
        self.assertTrue(res["pass"], res)
        self.assertEqual(res["tiles_blank"], ["tile-1-1"],
                         "the blank tile is still REPORTED, just not fatal")

    def test_majority_boundary_four_no_five_yes(self):
        four = VS.compare(self.paths["source"], self.paths["fourblank"],
                          tiles=self.tiles)
        self.assertEqual(len(four["tiles_blank"]), 4)
        self.assertTrue(four["pass"],
                        "4 of 9 is not MORE THAN HALF — must not fail: %r" % four)
        five = VS.compare(self.paths["source"], self.paths["fiveblank"],
                          tiles=self.tiles)
        self.assertEqual(len(five["tiles_blank"]), 5)
        self.assertFalse(five["pass"], five)

    def test_fewer_than_three_measured_never_fails(self):
        box = tile_box_pct(1, 1)  # the blank tile of the oneblank render
        tiles = VS.parse_tiles([dict(box, name="a"), dict(box, name="b")])
        res = VS.compare(self.paths["source"], self.paths["oneblank"],
                         tiles=tiles)
        self.assertEqual(res["tiles_measured"], 2)
        self.assertEqual(len(res["tiles_blank"]), 2)
        self.assertTrue(res["pass"],
                        "sub-check must stay unarmed below 3 tiles: %r" % res)

    def test_layout_and_plain_shapes_measure_identically(self):
        res_a = VS.compare(self.paths["source"], self.paths["allblank"],
                           tiles=VS.parse_tiles(layout_dict()))
        res_b = VS.compare(self.paths["source"], self.paths["allblank"],
                           tiles=VS.parse_tiles(plain_tiles_list()))
        self.assertEqual(res_a["tiles_measured"], 9,
                         "chart-kind sliver must be dropped by the area rule")
        self.assertEqual(res_a["tiles_measured"], res_b["tiles_measured"])
        self.assertEqual(sorted(res_a["per_tile_ink"].values()),
                         sorted(res_b["per_tile_ink"].values()))
        self.assertEqual(res_a["pass"], res_b["pass"])

    def test_render_dims_differ_from_source(self):
        res = VS.compare(self.paths["source"], self.paths["allblank_half"],
                         tiles=self.tiles)
        self.assertEqual(res["tiles_measured"], 9)
        self.assertEqual(len(res["tiles_blank"]), 9,
                         "pct boxes must scale onto the render's own dims")
        self.assertFalse(res["pass"], res)


class TestCLIContract(FixtureMixin, unittest.TestCase):
    def test_no_tiles_flag_keeps_legacy_output(self):
        proc, data = self.run_cli(self.paths["source"], self.paths["allblank"])
        self.assertEqual(proc.returncode, 0, proc.stderr)  # the false-GREEN
        self.assertEqual(set(data.keys()), LEGACY_KEYS,
                         "no --tiles => exactly the legacy JSON keys")
        self.assertNotIn("tiles", proc.stdout)

    def test_tiles_flag_adds_keys_and_fails_all_blank(self):
        proc, data = self.run_cli(self.paths["source"], self.paths["allblank"],
                                  tiles=self.paths["tiles_plain"])
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertEqual(set(data.keys()), LEGACY_KEYS | TILE_KEYS)
        self.assertFalse(data["pass"])
        self.assertEqual(data["tiles_measured"], 9)
        self.assertEqual(len(data["tiles_blank"]), 9)
        self.assertIn("tiles: 9 measured, 9 blank", proc.stdout)

    def test_tiles_flag_healthy_pass_exit_0(self):
        proc, data = self.run_cli(self.paths["source"], self.paths["healthy"],
                                  tiles=self.paths["tiles_layout"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(data["pass"])
        self.assertEqual(data["tiles_blank"], [])
        self.assertIn("tiles: 9 measured, 0 blank", proc.stdout)

    def test_tiles_deterministic_output(self):
        out1 = os.path.join(self.dir, "det1.json")
        out2 = os.path.join(self.dir, "det2.json")
        self.run_cli(self.paths["source"], self.paths["oneblank"],
                     tiles=self.paths["tiles_plain"], json_out=out1)
        self.run_cli(self.paths["source"], self.paths["oneblank"],
                     tiles=self.paths["tiles_plain"], json_out=out2)
        with open(out1, "rb") as a, open(out2, "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_missing_tiles_file_exit_2(self):
        proc, _ = self.run_cli(self.paths["source"], self.paths["healthy"],
                               tiles=os.path.join(self.dir, "nope.json"))
        self.assertEqual(proc.returncode, 2)
        self.assertIn("tiles JSON not found", proc.stderr)

    def test_corrupt_or_wrong_shape_tiles_exit_2(self):
        for key in ("tiles_corrupt", "tiles_bad_shape"):
            proc, _ = self.run_cli(self.paths["source"], self.paths["healthy"],
                                   tiles=self.paths[key])
            self.assertEqual(proc.returncode, 2, key)
            self.assertIn("could not parse tiles JSON", proc.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
