#!/usr/bin/env python3
"""Unit test for coverage_catalog.py — the shared documentation-grounded mapping
loader. Stdlib only; run directly:  python3 shared/lib/test_coverage_catalog.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import coverage_catalog as cc  # noqa: E402


def _write_catalog(d, name, rows, **envelope):
    payload = {"rows": rows}
    payload.update(envelope)
    with open(os.path.join(d, name + ".json"), "w", encoding="utf-8") as fh:
        json.dump(payload, fh)


class CoverageCatalogTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="cc-test-")
        _write_catalog(
            self.dir, "number-format",
            [
                {"source": "usd_0", "sigma": "$,.0f",
                 "doc_ref": "https://example/usd_0",
                 "sigma_verified": {"status": "y", "date": "2026-07-13"},
                 "on_unmapped": "warn+skip"},
                {"source": "Percent_1", "sigma": ",.1%",  # mixed case -> normalized
                 "doc_ref": "https://example/percent_1",
                 "sigma_verified": {"status": "n"},
                 "on_unmapped": "warn+skip"},
            ],
            dimension="number-format", source_tool="looker",
            authoritative_doc="https://example/authority",
            on_unmapped_default="warn+skip",
        )

    def test_resolve_hit_and_normalization(self):
        cat = cc.load(self.dir, "number-format")
        self.assertEqual(cat.target("usd_0"), "$,.0f")
        # trimmed + case-insensitive
        self.assertEqual(cat.target("  USD_0 "), "$,.0f")
        self.assertEqual(cat.target("percent_1"), ",.1%")

    def test_resolve_miss_returns_none(self):
        cat = cc.load(self.dir, "number-format")
        self.assertIsNone(cat.resolve("gbp_9"))
        self.assertIsNone(cat.target("gbp_9"))
        self.assertIsNone(cat.resolve(None))

    def test_resolve_or_warn_is_loud_on_miss(self):
        cat = cc.load(self.dir, "number-format")
        warnings = []
        self.assertIsNone(cat.resolve_or_warn("gbp_9", warnings, context="tile 'X'"))
        self.assertEqual(len(warnings), 1)
        w = warnings[0]
        self.assertIn("number-format", w)
        self.assertIn("gbp_9", w)
        self.assertIn("looker", w)
        self.assertIn("tile 'X'", w)
        self.assertIn("number-format.json", w)
        # a hit adds NO warning
        self.assertIsNotNone(cat.resolve_or_warn("usd_0", warnings))
        self.assertEqual(len(warnings), 1)

    def test_metadata_and_unverified(self):
        cat = cc.load(self.dir, "number-format")
        self.assertEqual(cat.dimension, "number-format")
        self.assertEqual(cat.source_tool, "looker")
        self.assertEqual(cat.authoritative_doc, "https://example/authority")
        self.assertEqual(sorted(cat.sources()), ["percent_1", "usd_0"])
        unv = cat.unverified()
        self.assertEqual([r["source"] for r in unv], ["Percent_1"])

    def test_missing_catalog_fails_loudly(self):
        with self.assertRaises(FileNotFoundError):
            cc.load(self.dir, "does-not-exist")
        with self.assertRaises(FileNotFoundError):
            cc.load_all(os.path.join(self.dir, "nope"))

    def test_load_all(self):
        _write_catalog(self.dir, "viz-kind",
                       [{"source": "looker_bar", "sigma": "bar-chart"}],
                       dimension="viz-kind", source_tool="looker")
        cats = cc.load_all(self.dir)
        self.assertEqual(sorted(cats.keys()), ["number-format", "viz-kind"])
        self.assertEqual(cats["viz-kind"].target("looker_bar"), "bar-chart")

    def test_default_catalog_dir(self):
        fake = "/a/b/skills/x/scripts/build.py"
        got = cc.default_catalog_dir(fake)
        self.assertTrue(got.endswith(os.path.join("skills", "x", "refs", "catalogs")))

    def test_plugin_archetype(self):
        _write_catalog(
            self.dir, "viz-kind-plugin",
            [
                {"source": "GaugeChartVisual", "sigma": "kpi-chart", "plugin_archetype": "gauge"},
                {"source": "HeatMapVisual", "sigma": "plugin:heatmap"},
                {"source": "BarChartVisual", "sigma": "bar-chart"},
            ],
            dimension="viz-kind", source_tool="quicksight",
        )
        cat = cc.load(self.dir, "viz-kind-plugin")
        # explicit plugin_archetype field wins
        self.assertEqual(cat.plugin_archetype("GaugeChartVisual"), "gauge")
        # sigma "plugin:<x>" prefix -> archetype
        self.assertEqual(cat.plugin_archetype("HeatMapVisual"), "heatmap")
        # plain native row -> None
        self.assertIsNone(cat.plugin_archetype("BarChartVisual"))
        # miss -> None
        self.assertIsNone(cat.plugin_archetype("NopeVisual"))
        # non-breaking: target/resolve for the gauge row still return "kpi-chart"
        self.assertEqual(cat.target("GaugeChartVisual"), "kpi-chart")
        self.assertEqual(cat.resolve("GaugeChartVisual")["sigma"], "kpi-chart")


if __name__ == "__main__":
    unittest.main(verbosity=2)
