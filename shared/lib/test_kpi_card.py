import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kpi_card

def _sort(o):
    if isinstance(o, dict):
        return {k: _sort(o[k]) for k in sorted(o)}
    if isinstance(o, list):
        return [_sort(e) for e in o]
    return o

class KpiCardTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(os.path.dirname(__file__), "testdata", "kpi_card_golden.json")) as f:
            self.golden = json.load(f)
        with open(os.path.join(os.path.dirname(__file__), "testdata", "kpi_card_value_style_golden.json")) as f:
            self.value_style_golden = json.load(f)

    def test_comparative_matches_golden(self):
        el = kpi_card.build(id="kpi-rev", name="Revenue", source_element_id="tbl-1",
                            columns=[{"id": "rev_cur",
                                      "format": {"kind": "number", "formatString": "$,.0f"}}],
                            value_column_id="rev_cur",
                            comparison_column_id="rev_prior",
                            good_direction="up", title_color="#FFFFFF")
        self.assertEqual(json.dumps(_sort(el)), json.dumps(_sort(self.golden)))

    def test_plain_call_no_regression(self):
        # No value_color/value_font_size => byte-identical to the pre-change golden.
        el = kpi_card.build(id="kpi-rev", name="Revenue", source_element_id="tbl-1",
                            columns=[{"id": "rev_cur",
                                      "format": {"kind": "number", "formatString": "$,.0f"}}],
                            value_column_id="rev_cur",
                            comparison_column_id="rev_prior",
                            good_direction="up", title_color="#FFFFFF")
        self.assertEqual(json.dumps(_sort(el)), json.dumps(_sort(self.golden)))
        self.assertNotIn("color", el["value"])
        self.assertNotIn("fontSize", el["value"])

    def test_value_styling_emitted_when_set(self):
        el = kpi_card.build(id="k", name="Rev", source_element_id="t",
                            columns=[{"id": "rev"}], value_column_id="rev",
                            comparison_column_id="prior",
                            value_color="#FDE047", value_font_size=44)
        self.assertEqual(el["value"], {"columnId": "rev", "color": "#FDE047", "fontSize": 44})
        self.assertEqual(json.dumps(_sort(el)), json.dumps(_sort(self.value_style_golden)))

    def test_single_value_omits_comparison(self):
        el = kpi_card.build(id="k", name="X", source_element_id="t",
                            columns=[{"id": "v"}], value_column_id="v")
        self.assertNotIn("comparison", el)
        self.assertNotIn("comparisonColumn", el)

    def test_down_inverts_colors(self):
        el = kpi_card.build(id="k", name="X", source_element_id="t",
                            columns=[{"id": "v"}], value_column_id="v",
                            comparison_column_id="p", good_direction="down")
        self.assertEqual(el["comparison"]["colorGood"], "#cf222e")
        self.assertEqual(el["comparison"]["colorBad"], "#1a7f37")

    def test_dedup_existing_comparison_column(self):
        el = kpi_card.build(id="k", name="X", source_element_id="t",
                            columns=[{"id": "v"}, {"id": "p"}], value_column_id="v",
                            comparison_column_id="p")
        self.assertEqual(len(el["columns"]), 2)
        self.assertEqual(el["comparisonColumn"]["columnId"], "p")
        self.assertEqual(el["comparison"]["display"], "delta")

    def test_empty_value_raises(self):
        with self.assertRaises(ValueError):
            kpi_card.build(id="k", name="X", source_element_id="t", columns=[], value_column_id="")

if __name__ == "__main__":
    unittest.main(verbosity=2)
