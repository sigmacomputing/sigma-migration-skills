#!/usr/bin/env python3
"""Focused offline regression for the Aug-2026 workbook code release."""
import copy
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
BUILDER = os.path.join(SKILL, "scripts", "build_workbook.py")
CONVERTER = os.path.join(SKILL, "scripts", "convert.py")
FIXTURE = os.path.join(SKILL, "fixtures", "test_workspace_orders.json")
sys.path.insert(0, os.path.join(SKILL, "scripts", "lib"))
import code_rep  # noqa: E402


def measure(mid, title):
    return {
        "measure": {
            "localIdentifier": mid,
            "title": title,
            "definition": {
                "measureDefinition": {
                    "item": {"identifier": {"id": mid, "type": "metric"}}
                }
            },
        }
    }


def attribute(aid):
    return {
        "attribute": {
            "localIdentifier": aid,
            "displayForm": {
                "identifier": {"id": aid + ".name", "type": "label"}
            },
        }
    }


def widget(iid, width=6):
    return {
        "size": {"xl": {"gridWidth": width}},
        "widget": {
            "insight": {"identifier": {"id": iid, "type": "visualizationObject"}}
        },
    }


def release_workspace():
    ws = copy.deepcopy(json.load(open(FIXTURE)))
    ws["analytics"]["visualizationObjects"] = [
        {
            "id": "wf", "title": "Revenue Change",
            "content": {
                "visualizationUrl": "local:waterfall",
                "properties": {
                    "controls": {
                        "legend": {"enabled": True, "position": "bottom"},
                        "style": {"backgroundColor": "#F8FAFC"},
                    }
                },
                "buckets": [
                    {"localIdentifier": "measures",
                     "items": [measure("m_net_revenue", "Net Revenue")]},
                    {"localIdentifier": "view",
                     "items": [attribute("order_channel")]},
                ],
            },
        },
        {
            "id": "rep", "title": "Revenue by Acquisition",
            "content": {
                "visualizationUrl": "local:repeater",
                "buckets": [
                    {"localIdentifier": "rows",
                     "items": [attribute("acquisition_channel")]},
                    {"localIdentifier": "columns",
                     "items": [measure("m_net_revenue", "Net Revenue")]},
                ],
            },
        },
        {
            "id": "box", "title": "Gated Distribution",
            "content": {
                "visualizationUrl": "local:boxplot",
                "buckets": [
                    {"localIdentifier": "measures",
                     "items": [measure("m_net_revenue", "Net Revenue")]},
                    {"localIdentifier": "view",
                     "items": [attribute("order_channel")]},
                ],
            },
        },
    ]
    ws["analytics"]["attributeHierarchies"] = [{
        "id": "sales_path", "title": "Sales Path",
        "attributes": ["acquisition_channel", "order_channel"],
    }]
    ws["analytics"]["analyticalDashboards"] = [{
        "id": "release_dashboard", "title": "Release Dashboard",
        "content": {
            "tabs": [
                {"localIdentifier": "overview", "title": "Overview",
                 "sections": [{"items": [widget("wf", 12)]}]},
                {"localIdentifier": "detail", "title": "Detail",
                 "sections": [{"items": [widget("rep", 12)]}]},
            ]
        },
    }]
    return ws


def test_released_workbook_shape_and_features():
    with tempfile.TemporaryDirectory() as d:
        workspace = os.path.join(d, "workspace.json")
        output = os.path.join(d, "workbook.json")
        gaps = os.path.join(d, "feature-gaps.json")
        json.dump(release_workspace(), open(workspace, "w"))
        run = subprocess.run(
            [sys.executable, BUILDER, "--workspace", workspace,
             "--data-model-id", "dm-x", "--fact-element", "el-x",
             "--fact-name", "ORDER_FACT", "--rel-name", "EL_CUSTOMER",
             "--fact-dataset", "order", "--folder-id", "folder-x",
             "--feature-gaps-out", gaps, "--out", output],
            capture_output=True, text=True,
        )
        assert run.returncode == 0, run.stdout + run.stderr
        envelope = json.load(open(output))
        gap_ledger = json.load(open(gaps))

    assert set(envelope) == {"name", "folderId", "document"}
    doc = code_rep.document(envelope)
    assert doc["kind"] == "workbook" and doc["schemaVersion"] == 1
    assert doc["layout"] and all("elements" not in page for page in doc["pages"])
    assert "<Element " in doc["layout"]
    assert not re.search(r"</?(?:LayoutElement|GridContainer)\b", doc["layout"])
    assert [page["name"] for page in doc["pages"]] == [
        "Data", "Overview", "Detail"]
    assert doc["panels"] == [] and doc["overlays"] == []
    assert doc["settings"]["navigation"]["pageTabsInViewMode"] == "shown"

    elements = code_rep.workbook_elements(envelope)
    ids = [element["id"] for element in elements]
    placed = [
        element_id
        for page_ids in code_rep.workbook_page_element_ids(envelope).values()
        for element_id in page_ids
    ]
    assert sorted(ids) == sorted(placed)
    assert len(ids) == len(set(ids)) == len(placed)

    waterfall = next(element for element in elements if element.get("id") == "wf")
    assert waterfall["kind"] == "waterfall-chart"
    assert waterfall["waterfallShape"] == {
        "calculation": "sum", "connectorLine": "shown"}
    assert waterfall["startPoint"]["value"] == {"type": "constant", "value": 0}
    assert waterfall["legend"] == {
        "visibility": "shown", "position": "bottom"}
    assert waterfall["style"] == {"backgroundColor": "#F8FAFC"}

    repeater = next(element for element in elements if element.get("id") == "rep")
    assert repeater["kind"] == "repeated-container"
    assert repeater["source"]["kind"] == "table"
    assert "<Container " in doc["layout"]
    assert any("repeated container/Net Revenue" in element.get("body", "")
               for element in elements)
    assert len([element for element in elements
                if element.get("kind") == "navigation"]) == 2
    assert not any(element.get("kind") in ("box-chart", "box-plot")
                   for element in elements)
    assert any(gap.get("feature") == "drill"
               for gap in gap_ledger["gaps"])
    assert any(gap.get("url") == "local:boxplot"
               for gap in gap_ledger["gaps"])


def test_data_model_keeps_page_nesting():
    with tempfile.TemporaryDirectory() as d:
        output = os.path.join(d, "dm.json")
        flags = os.path.join(d, "flags.json")
        run = subprocess.run(
            [sys.executable, CONVERTER, "--workspace", FIXTURE,
             "--connection-id", "conn-x", "--db", "DEMO_DB",
             "--schema", "PUBLIC", "--folder-id", "folder-x",
             "--out", output, "--flags", flags],
            capture_output=True, text=True,
        )
        assert run.returncode == 0, run.stdout + run.stderr
        dm = json.load(open(output))
    assert "document" not in dm
    assert dm["pages"][0]["elements"]
    assert "elements" not in dm


if __name__ == "__main__":
    test_released_workbook_shape_and_features()
    test_data_model_keeps_page_nesting()
    print("ALL PASS")
