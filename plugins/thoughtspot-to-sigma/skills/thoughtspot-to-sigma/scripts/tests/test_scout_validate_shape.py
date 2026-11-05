#!/usr/bin/env python3
"""Regression test for scout-validate.py's workbook code-rep POST body
(Task 3.8).

Live POST /v2/workbooks REJECTS a flat body with HTTP 400 -- every
non-metadata field must nest under a top-level `contents` key.
scout-validate.py builds a throwaway "SCOUT TEST" workbook and POSTs it to
validate a candidate formula; this checks that POST target and body come from
the vendored code_rep adapter (create_path / create_body) rather than a flat
{name, folderId, schemaVersion, pages} dict.

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
    def test_create_body_nests_contents(self):
        doc = {
            "schemaVersion": 1,
            "kind": "workbook",
            "pages": [],
            "elements": [],
            "layout": "",
        }
        body = code_rep.create_body(doc, {"name": "n", "folderId": "f"})
        self.assertEqual(body["contents"]["pages"], doc["pages"])
        self.assertEqual(body["name"], "n")
        self.assertNotIn("pages", body)
        self.assertNotIn("document", body)

    def test_document_resolves_nested_readback(self):
        nested = {"workbookId": "w", "contents": {"schemaVersion": 1, "pages": [{"id": "p"}]}}
        self.assertEqual(code_rep.document(nested)["pages"], [{"id": "p"}])
        self.assertIsNone(nested.get("pages"), "proves the old flat read was nil")

    # Real regression signal: scout-validate.py's own POST must target
    # code_rep.create_path() with a body built via code_rep.create_body(...),
    # not a flat dict with name/folderId/schemaVersion/pages all at the top
    # level (the shape the live API 400s on) or the deprecated /spec path.
    def test_post_body_uses_code_rep_create_body(self):
        with open(SCRIPT) as fh:
            src = fh.read()
        m = re.search(r'api\("POST",\s*code_rep\.create_path\(\),\s*(\w+)\)', src)
        self.assertIsNotNone(m, "expected api(\"POST\", code_rep.create_path(), ...) in scout-validate.py")
        var = m.group(1)
        assign = re.search(rf"\b{re.escape(var)}\s*=\s*code_rep\.create_body\(", src)
        self.assertIsNotNone(assign, f"{var} (the POST body) must be built via code_rep.create_body(...)")
        self.assertNotIn("/v2/workbooks/spec", src)


if __name__ == "__main__":
    unittest.main()
