import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plugin_embed

def _sort(o):
    if isinstance(o, dict):
        return {k: _sort(o[k]) for k in sorted(o)}
    if isinstance(o, list):
        return [_sort(e) for e in o]
    return o

class PluginEmbedTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(os.path.dirname(__file__), "testdata", "plugin_embed_golden.json")) as f:
            self.golden = json.load(f)

    def test_gauge_matches_golden(self):
        el = plugin_embed.build(id="gauge-el", plugin_id="pl-1", source_element_id="tbl-1",
                                 bindings={"value": "actual", "target": "target"},
                                 extra_config={"format": "$.3~s"})
        self.assertEqual(json.dumps(_sort(el)), json.dumps(_sort(self.golden)))

    def test_numeric_extra_config_coerced_to_string(self):
        el = plugin_embed.build(id="gauge-el", plugin_id="pl-1", source_element_id="tbl-1",
                                 bindings={"value": "actual"},
                                 extra_config={"decimals": 2})
        self.assertEqual(el["config"]["decimals"], "2")
        self.assertIsInstance(el["config"]["decimals"], str)

    def test_empty_id_raises(self):
        with self.assertRaises(ValueError):
            plugin_embed.build(id="", plugin_id="pl-1", source_element_id="tbl-1", bindings={})

    def test_empty_plugin_id_raises(self):
        with self.assertRaises(ValueError):
            plugin_embed.build(id="gauge-el", plugin_id="", source_element_id="tbl-1", bindings={})

    def test_empty_source_element_id_raises(self):
        with self.assertRaises(ValueError):
            plugin_embed.build(id="gauge-el", plugin_id="pl-1", source_element_id="", bindings={})

if __name__ == "__main__":
    unittest.main(verbosity=2)
