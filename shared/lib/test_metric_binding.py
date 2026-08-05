#!/usr/bin/env python3
"""Unit test for metric_binding.py — the shared workbook↔DM-metric binder.
Stdlib only; run directly:  python3 shared/lib/test_metric_binding.py

Semantics mirror the looker reference (PR #484) that this helper was extracted
from: a measure whose inline aggregate matches a metric on (or inherited by) the
source element binds to [Metrics/<name>]; everything else — ratios, filtered,
custom, no match, empty metrics, non-string input — falls back to inline.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metric_binding as mb  # noqa: E402


class MetricRefOrInlineTest(unittest.TestCase):
    METRICS = [
        {"name": "Net Revenue", "formula": "Sum([Net Revenue])"},
        {"name": "Orders", "formula": "CountDistinct([Order Id])"},
    ]

    def test_matched_aggregate_binds_to_metric(self):
        self.assertEqual(
            mb.metric_ref_or_inline("Sum([Data/Net Revenue])", "Data", self.METRICS),
            "[Metrics/Net Revenue]")
        self.assertEqual(
            mb.metric_ref_or_inline("CountDistinct([Data/Order Id])", "Data", self.METRICS),
            "[Metrics/Orders]")

    def test_whitespace_insensitive_match(self):
        # extra whitespace on either side must not defeat the match
        self.assertEqual(
            mb.metric_ref_or_inline("Sum( [Data/Net Revenue] )", "Data", self.METRICS),
            "[Metrics/Net Revenue]")

    def test_strips_every_master_prefix(self):
        # a ratio of two master refs, matched against a metric with no prefix
        mets = [{"name": "AOV", "formula": "Sum([Net Revenue]) / Sum([Order Id])"}]
        self.assertEqual(
            mb.metric_ref_or_inline("Sum([Data/Net Revenue]) / Sum([Data/Order Id])", "Data", mets),
            "[Metrics/AOV]")

    def test_ratio_without_metric_falls_back(self):
        got = mb.metric_ref_or_inline("1.0 * Sum([Data/Net Revenue]) / Count([Data/Order Id])",
                                      "Data", self.METRICS)
        self.assertEqual(got, "1.0 * Sum([Data/Net Revenue]) / Count([Data/Order Id])")

    def test_nonmatching_metric_ignored(self):
        mets = [{"name": "Unrelated", "formula": "Sum([Something Else])"}]
        self.assertEqual(
            mb.metric_ref_or_inline("Sum([Data/Net Revenue])", "Data", mets),
            "Sum([Data/Net Revenue])")

    def test_empty_metrics_is_noop(self):
        self.assertEqual(mb.metric_ref_or_inline("Sum([Data/x])", "Data", []),
                         "Sum([Data/x])")
        self.assertEqual(mb.metric_ref_or_inline("Sum([Data/x])", "Data", None),
                         "Sum([Data/x])")

    def test_non_string_inline_passthrough(self):
        self.assertIsNone(mb.metric_ref_or_inline(None, "Data", self.METRICS))
        self.assertEqual(mb.metric_ref_or_inline(42, "Data", self.METRICS), 42)

    def test_metric_missing_formula_or_name_skipped(self):
        mets = [{"name": "NoFormula"}, {"formula": "Sum([Data/x])"},
                {"name": "Good", "formula": "Sum([x])"}]
        self.assertEqual(mb.metric_ref_or_inline("Sum([Data/x])", "Data", mets),
                         "[Metrics/Good]")


class AvailableMetricsTest(unittest.TestCase):
    def test_own_metrics(self):
        els = {"a": {"metrics": [{"name": "M1", "formula": "Sum([x])"}]}}
        got = mb.available_metrics("a", els)
        self.assertEqual(got, [{"name": "M1", "formula": "Sum([x])"}])

    def test_inherited_via_source_chain(self):
        # denorm 'View' element carries 0 own metrics but inherits its base fact's
        els = {
            "view": {"metrics": [], "source": {"elementId": "fact"}},
            "fact": {"metrics": [{"name": "Net Revenue", "formula": "Sum([Net Revenue])"}]},
        }
        got = mb.available_metrics("view", els)
        self.assertEqual(got, [{"name": "Net Revenue", "formula": "Sum([Net Revenue])"}])

    def test_nearest_wins_on_name_collision(self):
        els = {
            "view": {"metrics": [{"name": "M", "formula": "OWN"}], "source": {"elementId": "fact"}},
            "fact": {"metrics": [{"name": "M", "formula": "INHERITED"}]},
        }
        got = mb.available_metrics("view", els)
        self.assertEqual(got, [{"name": "M", "formula": "OWN"}])

    def test_skips_metrics_missing_fields(self):
        els = {"a": {"metrics": [{"name": "OnlyName"}, {"formula": "OnlyFormula"},
                                 {"name": "Ok", "formula": "Sum([x])"}]}}
        self.assertEqual(mb.available_metrics("a", els),
                         [{"name": "Ok", "formula": "Sum([x])"}])

    def test_cycle_safe(self):
        els = {"a": {"metrics": [{"name": "A", "formula": "f"}], "source": {"elementId": "b"}},
               "b": {"metrics": [{"name": "B", "formula": "g"}], "source": {"elementId": "a"}}}
        got = mb.available_metrics("a", els)
        self.assertEqual([m["name"] for m in got], ["A", "B"])

    def test_missing_element_and_none(self):
        self.assertEqual(mb.available_metrics("nope", {"a": {}}), [])
        self.assertEqual(mb.available_metrics(None, {"a": {}}), [])


class CollisionShapeTest(unittest.TestCase):
    """F4 collision shape: a same-element column/metric name pair makes the
    element's metrics non-referenceable (live readback omits them wholesale)."""

    def test_clean_element_no_collisions(self):
        el = {"columns": [{"name": "Carton Count"}],
              "metrics": [{"name": "Total Cartons", "formula": "Sum([Carton Count])"}]}
        self.assertEqual(mb.column_metric_collisions(el), [])
        self.assertEqual(mb.column_metric_collisions(None), [])
        self.assertEqual(mb.column_metric_collisions("not an element"), [])

    def test_same_element_pair_collides_exact_names_only(self):
        el = {"columns": [{"name": "Freight Cost"}, {"name": "Lane"}],
              "metrics": [{"name": "Freight Cost", "formula": "Sum([Freight Cost])"}]}
        self.assertEqual(mb.column_metric_collisions(el), ["Freight Cost"])
        self.assertEqual(mb.column_metric_collisions(
            {"columns": [{"name": "freight cost"}],
             "metrics": [{"name": "Freight Cost", "formula": "x"}]}), [])

    def test_formula_less_metric_still_collides(self):
        # the POSTed shape is what live Sigma drops on
        el = {"columns": [{"name": "Pallet Count"}], "metrics": [{"name": "Pallet Count"}]}
        self.assertEqual(mb.column_metric_collisions(el), ["Pallet Count"])

    def test_collision_shaped_element_contributes_no_metrics(self):
        els = {"fact": {
            "columns": [{"name": "Freight Cost"}, {"name": "Shipment Id"}],
            "metrics": [{"name": "Freight Cost", "formula": "Sum([Freight Cost])"},
                        {"name": "Fill Rate Pct",
                         "formula": "Sum([Filled Lines]) / Count([Order Lines])"}],
        }}
        self.assertEqual(mb.available_metrics("fact", els), [])

    def test_collision_exclusions_reports_the_withheld_element(self):
        els = {"view": {"source": {"elementId": "fact"}},
               "fact": {"name": "Freight Fact",
                        "columns": [{"name": "Freight Cost"}],
                        "metrics": [{"name": "Freight Cost", "formula": "Sum([Freight Cost])"},
                                    {"name": "Fill Rate Pct",
                                     "formula": "Sum([Filled Lines]) / Count([Order Lines])"}]}}
        ex = mb.collision_exclusions("view", els)
        self.assertEqual(len(ex), 1)
        self.assertEqual(ex[0]["element_id"], "fact")
        self.assertEqual(ex[0]["element_name"], "Freight Fact")
        self.assertEqual(ex[0]["collisions"], ["Freight Cost"])
        self.assertEqual(ex[0]["excluded_metrics"], ["Freight Cost", "Fill Rate Pct"])
        self.assertEqual(mb.available_metrics("view", els), [])
        self.assertEqual(mb.collision_exclusions(
            "solo", {"solo": {"metrics": [{"name": "M", "formula": "f"}]}}), [])

    def test_unnamed_element_audit_label_falls_back_to_id(self):
        # Converter-model BASE elements carry no "name" key (field-caught: the
        # run NOTE + decision ledger otherwise render "DM element ''"). "" too.
        els = {"view": {"source": {"elementId": "el-77fq02"}},
               "el-77fq02": {"columns": [{"name": "Freight Cost"}],
                             "metrics": [{"name": "Freight Cost",
                                          "formula": "Sum([Freight Cost])"}]}}
        ex = mb.collision_exclusions("view", els)
        self.assertEqual(len(ex), 1)
        self.assertEqual(ex[0]["element_id"], "el-77fq02")
        self.assertEqual(ex[0]["element_name"], "el-77fq02")
        blank = mb.collision_exclusions(
            "b1", {"b1": {"name": "", "columns": [{"name": "Lane"}],
                          "metrics": [{"name": "Lane"}]}})
        self.assertEqual(len(blank), 1)
        self.assertEqual(blank[0]["element_name"], "b1")

    def test_clean_chain_element_contributes_past_a_collision(self):
        els = {"view": {"metrics": [{"name": "Depot Count", "formula": "CountDistinct([Depot])"}],
                        "source": {"elementId": "fact"}},
               "fact": {"columns": [{"name": "Freight Cost"}],
                        "metrics": [{"name": "Freight Cost", "formula": "Sum([Freight Cost])"}]}}
        self.assertEqual(mb.available_metrics("view", els),
                         [{"name": "Depot Count", "formula": "CountDistinct([Depot])"}])


if __name__ == "__main__":
    unittest.main(verbosity=2)
