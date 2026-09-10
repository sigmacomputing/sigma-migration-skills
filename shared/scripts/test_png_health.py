#!/usr/bin/env python3
"""Offline tests for png_health.py."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "png_health.py")


def _load_module():
    spec = importlib.util.spec_from_file_location("png_health", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PNG = _load_module()


class FixtureMixin:
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.mkdtemp(prefix="png-health-test-")
        cls.paths = {}

        def save(name, image, image_format="PNG"):
            path = os.path.join(cls.directory, name + ".png")
            image.save(path, format=image_format)
            cls.paths[name] = path

        save("white", Image.new("RGB", (800, 600), "white"))
        save("solid", Image.new("RGB", (800, 600), (34, 78, 122)))

        healthy = Image.new("RGB", (800, 600), "white")
        draw = ImageDraw.Draw(healthy)
        draw.rectangle((40, 30, 760, 90), fill=(40, 70, 130))
        for index in range(8):
            x = 60 + index * 85
            draw.rectangle((x, 500 - index * 35, x + 45, 540), fill=(30, 90, 180))
        save("healthy", healthy)

        tiny = Image.new("RGB", (1000, 1000), "white")
        ImageDraw.Draw(tiny).rectangle((500, 500, 504, 504), fill="black")
        save("tiny", tiny)

        transparent = Image.new("RGBA", (800, 600), (0, 0, 0, 0))
        ImageDraw.Draw(transparent).rectangle(
            (50, 50, 750, 550), fill=(20, 80, 160, 255)
        )
        save("transparent", transparent)

        jpeg = os.path.join(cls.directory, "jpeg.png")
        healthy.save(jpeg, format="JPEG")
        cls.paths["jpeg"] = jpeg

        corrupt = os.path.join(cls.directory, "corrupt.png")
        with open(corrupt, "wb") as output:
            output.write(b"not a PNG")
        cls.paths["corrupt"] = corrupt

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.directory, ignore_errors=True)

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, SCRIPT, *args],
            capture_output=True,
            text=True,
        )


class TestAnalysis(FixtureMixin, unittest.TestCase):
    def test_healthy_png_passes_with_complete_schema(self):
        result = PNG.analyze_image(self.paths["healthy"])
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["reasons"], [])
        self.assertEqual(result["width"], 800)
        self.assertEqual(result["height"], 600)
        self.assertEqual(result["background"], [255, 255, 255])
        self.assertGreater(result["ink_ratio"], 0.01)
        self.assertGreater(result["entropy"], 0.0)
        self.assertEqual(
            list(result),
            [
                "path",
                "width",
                "height",
                "background",
                "ink_ratio",
                "entropy",
                "status",
                "reasons",
            ],
        )

    def test_all_white_and_solid_color_fail(self):
        white = PNG.analyze(self.paths["white"])
        solid = PNG.analyze_image(self.paths["solid"])
        self.assertEqual(white["status"], "FAIL")
        self.assertIn("all white", white["reasons"][0])
        self.assertEqual(solid["status"], "FAIL")
        self.assertIn("solid color", solid["reasons"][0])
        self.assertEqual(white["ink_ratio"], 0.0)
        self.assertEqual(solid["entropy"], 0.0)

    def test_tiny_ink_fails(self):
        result = PNG.analyze_image(self.paths["tiny"])
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("tiny ink", result["reasons"][0])
        self.assertEqual(result["ink_ratio"], 0.000025)

    def test_transparency_is_flattened_onto_white(self):
        result = PNG.analyze_image(self.paths["transparent"])
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["background"], [20, 80, 160])
        self.assertGreater(result["ink_ratio"], 0.2)

    def test_missing_corrupt_and_non_png_are_errors(self):
        for path in (
            os.path.join(self.directory, "missing.png"),
            self.paths["corrupt"],
            self.paths["jpeg"],
        ):
            result = PNG.analyze_image(path)
            self.assertEqual(result["status"], "ERROR", result)
            self.assertIsNone(result["width"])
            self.assertTrue(result["reasons"])


class TestCLI(FixtureMixin, unittest.TestCase):
    def test_positional_prints_json_and_uses_exit_codes(self):
        passed = self.run_cli(self.paths["healthy"])
        failed = self.run_cli(self.paths["white"])
        errored = self.run_cli(self.paths["corrupt"])
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assertEqual(json.loads(passed.stdout)["status"], "PASS")
        self.assertEqual(failed.returncode, 1)
        self.assertEqual(json.loads(failed.stdout)["status"], "FAIL")
        self.assertEqual(errored.returncode, 2)
        self.assertEqual(json.loads(errored.stdout)["status"], "ERROR")

    def test_image_flag_and_json_out(self):
        output = os.path.join(self.directory, "nested", "health.json")
        process = self.run_cli(
            "--image", self.paths["healthy"], "--json-out", output
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stdout, "")
        with open(output) as result_file:
            self.assertEqual(json.load(result_file)["status"], "PASS")

    def test_output_is_deterministic(self):
        first = self.run_cli(self.paths["healthy"])
        second = self.run_cli("--image", self.paths["healthy"])
        self.assertEqual(first.stdout, second.stdout)

    def test_requires_exactly_one_image_argument(self):
        neither = self.run_cli()
        both = self.run_cli(self.paths["healthy"], "--image", self.paths["healthy"])
        self.assertEqual(neither.returncode, 2)
        self.assertEqual(both.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
