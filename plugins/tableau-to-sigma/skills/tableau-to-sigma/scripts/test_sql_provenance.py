#!/usr/bin/env python3

import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import sql_provenance


def element(element_id, name, statement):
    return {
        "id": element_id,
        "name": name,
        "kind": "table",
        "source": {"kind": "sql", "connectionId": "conn", "statement": statement},
    }


class SqlProvenanceTest(unittest.TestCase):
    def test_source_generated_and_unattributed_sql(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            twb = root / "source.twb"
            dm = root / "dm.json"
            metadata = root / "conv-meta.json"
            twb.write_text(
                """
                <workbook><datasources><datasource><connection>
                  <relation type="text">SELECT order_id, amount FROM orders</relation>
                </connection></datasource></datasources></workbook>
                """,
                encoding="utf-8",
            )
            dm.write_text(
                json.dumps(
                    {
                        "pages": [
                            {
                                "elements": [
                                    element(
                                        "source-sql",
                                        "Source SQL",
                                        "SELECT order_id, amount FROM orders",
                                    ),
                                    element(
                                        "lod",
                                        "Revenue LOD Helper",
                                        "SELECT region, SUM(amount) FROM orders GROUP BY region",
                                    ),
                                    element(
                                        "mystery",
                                        "Mystery",
                                        (
                                            "SELECT secret, COUNT(*) FROM nowhere "
                                            "GROUP BY secret"
                                        ),
                                    ),
                                ]
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            metadata.write_text(
                json.dumps(
                    {
                        "sqlProvenance": [
                            {
                                "elementId": "lod",
                                "originType": "generated-lod",
                                "statement": (
                                    "SELECT region, SUM(amount) FROM orders "
                                    "GROUP BY region"
                                ),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            result = sql_provenance.evaluate(
                dm, metadata_path=metadata, twb_path=twb
            )
            by_id = {row["element_id"]: row for row in result["sql_elements"]}
            self.assertEqual("source-custom-sql", by_id["source-sql"]["origin_type"])
            self.assertEqual("generated-lod", by_id["lod"]["origin_type"])
            self.assertEqual("fail", result["status"])

            overrides = root / "sql-provenance-overrides.json"
            proof = root / "semantic-proof.json"
            proof.write_text(
                json.dumps({"match": True, "checks": [{"name": "row-count", "match": True}]}),
                encoding="utf-8",
            )
            overrides.write_text(
                json.dumps(
                    {
                        "entries": [
                            {
                                "element_id": "mystery",
                                "origin_type": "generated-manual",
                                "reason": "operator-proven semantic rewrite",
                                "proof": str(proof),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            result = sql_provenance.evaluate(
                dm,
                metadata_path=metadata,
                twb_path=twb,
                overrides_path=overrides,
            )
            self.assertEqual("pass", result["status"])

    def test_readback_ids_fall_back_to_a_unique_ledger_name(self):
        lod_sql = "SELECT region, SUM(amount) FROM orders GROUP BY region"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            readback = root / "dm-readback.json"
            metadata = root / "conv-meta.json"
            readback.write_text(
                json.dumps(
                    {
                        "pages": [
                            {
                                "elements": [
                                    element("srv-1", "Revenue LOD Helper", lod_sql),
                                    element(
                                        "srv-2",
                                        "Edited Helper",
                                        "SELECT region, MAX(amount) FROM orders GROUP BY region",
                                    ),
                                ]
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            def ledger(*rows):
                metadata.write_text(
                    json.dumps(
                        {
                            "sqlProvenance": [
                                {
                                    "elementId": row_id,
                                    "elementName": name,
                                    "originType": "generated-lod",
                                    "statement": lod_sql,
                                }
                                for row_id, name in rows
                            ]
                        }
                    ),
                    encoding="utf-8",
                )

            ledger(("lod", "Revenue LOD Helper"), ("edit", "Edited Helper"))
            rows = {
                row["element_id"]: row
                for row in sql_provenance.evaluate(readback, metadata_path=metadata)[
                    "sql_elements"
                ]
            }
            self.assertEqual("generated-lod", rows["srv-1"]["origin_type"])
            self.assertEqual("fail", rows["srv-2"]["status"])

            ledger(("a", "Revenue LOD Helper"), ("b", "Revenue LOD Helper"))
            rows = {
                row["element_id"]: row
                for row in sql_provenance.evaluate(readback, metadata_path=metadata)[
                    "sql_elements"
                ]
            }
            self.assertEqual("fail", rows["srv-1"]["status"])

    def test_pass_one_override_survives_the_readback(self):
        mystery_sql = "SELECT secret, COUNT(*) FROM nowhere GROUP BY secret"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            readback = root / "dm-readback.json"
            metadata = root / "conv-meta.json"
            overrides = root / "sql-provenance-overrides.json"
            proof = root / "semantic-proof.json"
            readback.write_text(
                json.dumps({"pages": [{"elements": [element("srv-7", "Mystery", mystery_sql)]}]}),
                encoding="utf-8",
            )
            metadata.write_text(
                json.dumps(
                    {
                        "sqlProvenance": [
                            {
                                "elementId": "mystery",
                                "elementName": "Mystery",
                                "originType": "unattributed",
                                "statement": mystery_sql,
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            proof.write_text(json.dumps({"match": True}), encoding="utf-8")
            entry = {
                "element_id": "mystery",
                "origin_type": "generated-manual",
                "reason": "operator-proven semantic rewrite",
                "proof": str(proof),
            }
            for row in ({**entry, "element_name": "Mystery"}, entry):
                overrides.write_text(json.dumps({"entries": [row]}), encoding="utf-8")
                result = sql_provenance.evaluate(
                    readback, metadata_path=metadata, overrides_path=overrides
                )
                self.assertEqual("pass", result["status"], row)

            readback.write_text(
                json.dumps(
                    {
                        "pages": [
                            {
                                "elements": [
                                    element("srv-7", "Mystery", mystery_sql),
                                    element("srv-8", "Mystery", mystery_sql),
                                ]
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            metadata.write_text(
                json.dumps(
                    {
                        "sqlProvenance": [
                            {
                                "elementId": "mystery",
                                "elementName": "Mystery",
                                "originType": "unattributed",
                                "statement": mystery_sql,
                            },
                            {
                                "elementId": "other",
                                "elementName": "Mystery",
                                "originType": "unattributed",
                                "statement": mystery_sql,
                            },
                        ]
                    }
                ),
                encoding="utf-8",
            )
            overrides.write_text(
                json.dumps({"entries": [{**entry, "element_name": "Mystery"}]}),
                encoding="utf-8",
            )
            result = sql_provenance.evaluate(
                readback, metadata_path=metadata, overrides_path=overrides
            )
            self.assertEqual("fail", result["status"])
            self.assertTrue(
                all(row["status"] == "fail" for row in result["sql_elements"])
            )

            # One ledger entry, two same-named readback elements: neither the
            # ledger's converter id nor a name-keyed override may pick one.
            single = {
                "elementId": "mystery",
                "elementName": "Mystery",
                "originType": "unattributed",
                "statement": mystery_sql,
            }
            name_only = {**entry, "element_id": None, "element_name": "Mystery"}
            for ledger, row in (([single], entry), ([], name_only)):
                metadata.write_text(json.dumps({"sqlProvenance": ledger}), encoding="utf-8")
                overrides.write_text(json.dumps({"entries": [row]}), encoding="utf-8")
                result = sql_provenance.evaluate(
                    readback, metadata_path=metadata, overrides_path=overrides
                )
                self.assertTrue(
                    all(r["status"] == "fail" for r in result["sql_elements"]), row
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
