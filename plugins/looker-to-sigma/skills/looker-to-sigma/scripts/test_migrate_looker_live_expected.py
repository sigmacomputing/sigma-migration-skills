#!/usr/bin/env python3
"""Offline test: expected_live() (live parity's Looker ground truth) sends the
tile's dynamic_fields as a JSON string, refuses a result in which Looker silently
dropped a requested field, and warns about filters on unknown fields."""
import importlib.util
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "lib"))
spec = importlib.util.spec_from_file_location("migrate_looker", HERE / "migrate-looker.py")
ml = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ml)
import looker_api  # noqa: E402

DYN = [{"measure": "avg_weight_per_stop", "based_on": "shipments.total_weight", "type": "average",
        "label": "Avg Weight Per Stop", "_kind_hint": "measure", "_type_hint": "number"}]


class ExpectedLiveTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.rows = []
        self._orig = looker_api.call
        looker_api.call = self._fake
        self.addCleanup(lambda: setattr(looker_api, "call", self._orig))

    def _fake(self, method, path, body=None, **kw):
        self.calls.append((method, path, body))
        return 200, self.rows

    def tile(self, **over):
        t = {"name": "Weight by depot", "model": "logistics", "explore": "shipments",
             "fields": ["depots.depot_name", "shipments.total_weight"], "filters": {}}
        t.update(over)
        return t

    def test_no_dynamic_fields_key_when_absent(self):
        self.rows = [{"depots.depot_name": "North", "shipments.total_weight": 10}]
        ml.expected_live(self.tile(dynamicFields=[]), {"shipments.total_weight": 1})
        self.assertNotIn("dynamic_fields", self.calls[0][2])
        ml.expected_live(self.tile(), {"shipments.total_weight": 1})
        self.assertNotIn("dynamic_fields", self.calls[1][2])

    def test_dynamic_fields_sent_as_json_string(self):
        self.rows = [{"depots.depot_name": "North", "avg_weight_per_stop": 4.5}]
        t = self.tile(fields=["depots.depot_name", "avg_weight_per_stop"], dynamicFields=DYN)
        out = ml.expected_live(t, {})
        body = self.calls[0][2]
        self.assertIsInstance(body["dynamic_fields"], str)
        sent = json.loads(body["dynamic_fields"])
        self.assertEqual(sent[0]["measure"], "avg_weight_per_stop")
        self.assertNotIn("_kind_hint", sent[0])  # contract-internal hint is not a Looker property
        self.assertEqual(out, [["North", 4.5]])

    def test_string_dynamic_fields_pass_through(self):
        self.rows = [{"shipments.total_weight": 3}]
        raw = json.dumps(DYN)
        ml.expected_live(self.tile(fields=["shipments.total_weight"], dynamicFields=raw), {})
        self.assertEqual(self.calls[0][2]["dynamic_fields"], raw)

    def test_dropped_field_raises(self):
        self.rows = [{"depots.depot_name": "North"}]  # custom field silently ignored
        t = self.tile(fields=["depots.depot_name", "avg_weight_per_stop"])
        with self.assertRaises(RuntimeError) as cm:
            ml.expected_live(t, {})
        msg = str(cm.exception)
        self.assertIn("dropped", msg)
        self.assertIn("avg_weight_per_stop", msg)

    def test_missing_table_calc_warns_not_raises(self):
        self.rows = [{"depots.depot_name": "North", "shipments.total_weight": 4}]
        tc = [{"table_calculation": "pct_of_total", "label": "% of total",
               "expression": "${shipments.total_weight} / sum(${shipments.total_weight})"}]
        t = self.tile(fields=["depots.depot_name", "shipments.total_weight", "pct_of_total"],
                      dynamicFields=tc)
        warns = []
        out = ml.expected_live(t, {"shipments.total_weight": 1}, warn=warns.append)
        self.assertEqual(out, [["North", 4]])
        self.assertEqual(len(warns), 1)
        self.assertIn("pct_of_total", warns[0])

    def test_string_dynamic_fields_classify_table_calc_and_filter(self):
        self.rows = [{"depots.depot_name": "North", "shipments.total_weight": 4}]
        tc = [{"table_calculation": "pct_of_total", "label": "% of total",
               "expression": "${shipments.total_weight} / sum(${shipments.total_weight})"}]
        t = self.tile(fields=["depots.depot_name", "shipments.total_weight", "pct_of_total"],
                      filters={"pct_of_total": ">0"}, dynamicFields=json.dumps(tc))
        warns = []
        out = ml.expected_live(t, {"shipments.total_weight": 1}, known_fields=set(),
                               warn=warns.append)
        self.assertEqual(out, [["North", 4]])
        self.assertEqual(len(warns), 1)
        self.assertIn("table calculation", warns[0])

    def test_empty_result_is_not_a_drop(self):
        self.rows = []
        ml.expected_live(self.tile(), {"shipments.total_weight": 1})  # must not raise

    def test_unknown_filter_warns(self):
        self.rows = [{"depots.depot_name": "North", "shipments.total_weight": 10}]
        warns = []
        known = {"shipments.total_weight", "depots.depot_name", "shipments.shipped"}  # dims hold the dimension_group name
        t = self.tile(filters={"depots.depot_name": "North",            # requested field
                               "shipments.shipped_month": "7 days",     # frame of a known dim group
                               "shipments.shipped_day_of_week": "2",    # compound timeframe
                               "shipments.shipped_month_name": "July",  # compound timeframe
                               "avg_weight_per_stop": ">3",             # dynamic field name
                               "shipments.typo_field": "x"},            # unknown
                      dynamicFields=DYN)
        self.rows[0]["avg_weight_per_stop"] = 1
        t["fields"] = t["fields"] + ["avg_weight_per_stop"]
        ml.expected_live(t, {"shipments.total_weight": 1}, known_fields=known,
                         dimension_groups={"shipments.shipped"}, warn=warns.append)
        self.assertEqual(len(warns), 1)
        self.assertIn("shipments.typo_field", warns[0])


if __name__ == "__main__":
    unittest.main()
