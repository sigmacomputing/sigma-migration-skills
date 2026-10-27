#!/usr/bin/env python3
"""Offline regression for the conformed-SQL multi-fact recovery path."""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
CONVERT = os.path.join(SKILL, "scripts", "convert.py")
PLANNER = os.path.join(SKILL, "scripts", "plan_multifact.py")
FIXTURE = os.path.join(SKILL, "fixtures", "bundle.json")


def run(*args, cwd=None):
    return subprocess.run(
        [sys.executable, *args], cwd=cwd, capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as work:
        base = json.load(open(FIXTURE, encoding="utf-8"))
        original_fact_tid = next(
            table["objectId"]
            for fact in base["facts"].values()
            for expression in fact["expressions"]
            for table in expression["tables"]
        )

        # MSTR fact-expression table arrays are candidate mappings, not proof
        # that all mapped tables participate. A unique lower logical size is
        # elected when every report can resolve from it.
        alternate = json.loads(json.dumps(base))
        alternate_tid = "ALTERNATE_FACT_TABLE"
        alternate["tables"][alternate_tid] = json.loads(json.dumps(
            alternate["tables"][original_fact_tid]))
        alternate["tables"][alternate_tid]["information"]["name"] = "ALT_FACT"
        alternate["tables"][alternate_tid]["physicalTable"]["tableName"] = "ALT_FACT"
        alternate["tables"][alternate_tid]["logicalSize"] = (
            alternate["tables"][original_fact_tid]["logicalSize"] + 100
        )
        for fact in alternate["facts"].values():
            for expression in fact["expressions"]:
                if any(table["objectId"] == original_fact_tid
                       for table in expression["tables"]):
                    expression["tables"].append({
                        "objectId": alternate_tid,
                        "subType": "logical_table",
                    })
        alternate_path = os.path.join(work, "alternate.json")
        json.dump(alternate, open(alternate_path, "w", encoding="utf-8"))
        alternate_plan_path = os.path.join(work, "alternate-plan.json")
        elected = run(
            PLANNER, alternate_path, "--out", alternate_plan_path, cwd=work)
        assert elected.returncode == 0, elected.stderr
        alternate_plan = json.load(open(
            alternate_plan_path, encoding="utf-8"))
        assert alternate_plan["factTableCount"] == 2
        assert alternate_plan["automaticTableId"] == original_fact_tid
        assert alternate_plan["requiresConformedSource"] is False

        alternate_dm = os.path.join(work, "alternate-dm.json")
        alternate_convert = run(
            CONVERT, "--bundle", alternate_path, "--connection-id", "conn-x",
            "--database", "DB", "--folder-id", "folder-x",
            "--out-dm", alternate_dm,
            "--out-wb", os.path.join(work, "alternate-wb.json"),
            "--out-layout", os.path.join(work, "alternate-layout.xml"),
            "--control-scope-out", os.path.join(work, "alternate-controls.json"),
            "--feature-gaps-out", os.path.join(work, "alternate-gaps.json"),
            cwd=work)
        assert alternate_convert.returncode == 0, alternate_convert.stderr
        elected_dm = json.load(open(alternate_dm, encoding="utf-8"))
        assert any(
            element.get("source", {}).get("path", [])[-1:] == ["ORDER_FACT"]
            for element in elected_dm["pages"][0]["elements"])

        bundle_path = os.path.join(work, "bundle.json")
        bundle = json.loads(json.dumps(base))
        table_ids = list(bundle["tables"])
        first_fact = next(iter(bundle["facts"].values()))
        first_fact["expressions"][0]["tables"][0]["objectId"] = table_ids[1]
        json.dump(bundle, open(bundle_path, "w", encoding="utf-8"))

        plan_path = os.path.join(work, "plan.json")
        planned = run(PLANNER, bundle_path, "--out", plan_path, cwd=work)
        assert planned.returncode == 0, planned.stderr
        plan = json.load(open(plan_path, encoding="utf-8"))
        assert plan["factTableCount"] == 2, plan
        assert plan["requiresConformedSource"] is True
        assert plan["conformedSqlContract"]["requiredColumns"]

        common = [
            CONVERT, "--bundle", bundle_path, "--connection-id", "conn-x",
            "--database", "DB", "--folder-id", "folder-x",
            "--out-dm", os.path.join(work, "dm.json"),
            "--out-wb", os.path.join(work, "wb.json"),
            "--out-layout", os.path.join(work, "layout.xml"),
            "--control-scope-out", os.path.join(work, "controls.json"),
            "--feature-gaps-out", os.path.join(work, "gaps.json"),
        ]
        blocked = run(*common, cwd=work)
        assert blocked.returncode != 0
        assert "plan_multifact.py" in blocked.stderr
        assert "--multi-fact-sql" in blocked.stderr

        sql_path = os.path.join(work, "conformed.sql")
        open(sql_path, "w", encoding="utf-8").write(
            "CREATE VOLATILE TABLE x AS SELECT 1; SELECT * FROM x")
        unsafe = run(*common, "--multi-fact-sql", sql_path, cwd=work)
        assert unsafe.returncode != 0
        assert "one SELECT/CTE" in unsafe.stderr

        projections = [
            f'NULL AS "{name.replace(chr(34), chr(34) * 2)}"'
            for name in plan["conformedSqlContract"]["requiredColumns"]
        ]
        open(sql_path, "w", encoding="utf-8").write(
            "SELECT\n  " + ",\n  ".join(projections) + "\n")
        converted = run(*common, "--multi-fact-sql", sql_path, cwd=work)
        assert converted.returncode == 0, converted.stderr

        dm = json.load(open(os.path.join(work, "dm.json"), encoding="utf-8"))
        elements = dm["pages"][0]["elements"]
        assert len(elements) == 1, elements
        assert elements[0]["source"]["kind"] == "sql", elements[0]
        assert elements[0]["source"]["statement"].startswith("SELECT")
        assert {column["name"] for column in elements[0]["columns"]} == set(
            plan["conformedSqlContract"]["requiredColumns"])
        json.load(open(os.path.join(work, "wb.json"), encoding="utf-8"))

    print("ALL PASS: alternate-table election, multi-pass fail-closed "
          "diagnostic, and SQL recovery")


if __name__ == "__main__":
    main()
