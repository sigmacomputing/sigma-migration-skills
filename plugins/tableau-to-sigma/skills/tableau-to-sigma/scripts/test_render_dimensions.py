"""migrate-tableau.py visual_render_dimensions: a Sigma page taller than the
default 900px render covers its last grid row instead of being cropped (twin of
the Ruby helper exercised in test-render-once.rb). Offline, creds-free."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE))
_spec = importlib.util.spec_from_file_location("migrate_tableau_py", HERE / "migrate-tableau.py")
mt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mt)

LAYOUT = ('<Page type="grid" id="page-data"><Element elementId="m" gridRow="1 / 90"/></Page>'
          '<Page type="grid" id="p1"><Element elementId="a" gridRow="1 / 4"/>'
          '<Element elementId="b" gridRow="23 / 42"/></Page>')


class RenderDimensionsTest(unittest.TestCase):
    def write_spec(self, layout):
        path = pathlib.Path(tempfile.mkdtemp()) / "wb-spec-python.json"
        path.write_text(json.dumps({"document": {"layout": layout}}))
        return path

    def test_tall_page_covers_last_row(self):
        self.assertEqual(mt.visual_render_dimensions(self.write_spec(LAYOUT), "p1"), (1600, 41 * 28 + 64))

    def test_short_page_and_other_pages_keep_default(self):
        spec = self.write_spec(LAYOUT.replace("23 / 42", "23 / 25"))
        self.assertEqual(mt.visual_render_dimensions(spec, "p1"), (1600, 900))

    def test_missing_spec_or_page_falls_back(self):
        self.assertEqual(mt.visual_render_dimensions(pathlib.Path("/nonexistent/wb.json"), "p1"), (1600, 900))
        self.assertEqual(mt.visual_render_dimensions(self.write_spec(LAYOUT), "nope"), (1600, 900))


if __name__ == "__main__":
    unittest.main()
