#!/usr/bin/env python3
"""Regression test for scout-validate.py's workbook code-rep POST body
(Task 3.8).

Live POST /v2/workbooks/spec now REJECTS the old flat body with HTTP 400
(verified 2026-08-03/04) -- every non-metadata field must nest under a
top-level `document` key. scout-validate.py builds a throwaway "SCOUT TEST"
workbook and POSTs it to validate a candidate formula; this checks that POST
body is built via the vendored code_rep.wrap() adapter rather than the old
flat {name, folderId, schemaVersion, pages} dict.

Run: python3 scripts/tests/test_scout_validate_shape.py
"""
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scout-validate.py")
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import code_rep  # noqa: E402  (vendored adapter; sys.path set above)


class TestScoutValidateShape(unittest.TestCase):
    # Sanity-checks the shared adapter itself. Already shipped (Task 3.x), so
    # this alone would NOT fail pre-fix -- it documents the expected shape
    # that the real regression test below actually enforces against the script.
    def test_wrap_nests_document(self):
        doc = {"schemaVersion": 1, "pages": []}
        body = code_rep.wrap(doc, {"name": "n", "folderId": "f"})
        self.assertEqual(body["document"],
                         {"schemaVersion": 1, "pages": [], "elements": []})
        self.assertNotIn("pages", body)

    def test_document_resolves_nested_readback(self):
        nested = {"workbookId": "w", "document": {"schemaVersion": 1, "pages": [{"id": "p"}]}}
        self.assertEqual(code_rep.document(nested)["pages"], [{"id": "p"}])
        self.assertIsNone(nested.get("pages"), "proves the old flat read was nil")

    # Real regression signal: scout-validate.py's own POST body must be built
    # via code_rep.wrap(...), not a flat dict with name/folderId/schemaVersion/
    # pages all at the top level (the shape the live API now 400s on).
    def test_post_body_uses_code_rep_wrap(self):
        with open(SCRIPT) as fh:
            src = fh.read()
        m = re.search(r'api\("POST",\s*"/v2/workbooks/spec",\s*(\w+)\)', src)
        self.assertIsNotNone(m, "expected a POST /v2/workbooks/spec call in scout-validate.py")
        var = m.group(1)
        assign = re.search(rf"\b{re.escape(var)}\s*=\s*code_rep\.wrap\(", src)
        self.assertIsNotNone(assign, f"{var} (the POST body) must be built via code_rep.wrap(...)")

    def test_layout_uses_canonical_tags(self):
        with open(SCRIPT) as fh:
            src = fh.read()
        self.assertRegex(src, r"<Element elementId=")
        self.assertNotRegex(src, r"</?(?:LayoutElement|GridContainer)\b")


if __name__ == "__main__":
    unittest.main()
