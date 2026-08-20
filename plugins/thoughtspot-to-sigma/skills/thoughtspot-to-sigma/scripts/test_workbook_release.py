#!/usr/bin/env python3
"""Focused workbook-as-code release regression for the ThoughtSpot builder."""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "lib"))

import apply_layouts
import code_rep
import migrate
import ts_common


def test_tabs_flat_elements_and_exact_layout():
    specs = [
        {"name": "Overview", "chart": "COLUMN"},
        {"name": "Detail", "chart": "TABLE"},
    ]
    elements = [
        {"id": "chart-overview", "kind": "bar-chart", "name": "Overview"},
        {"id": "table-detail", "kind": "table", "name": "Detail"},
    ]
    controls = [{"id": "region-control", "kind": "control", "controlId": "RegionFilter",
                 "controlType": "list"}]
    lb = {
        "description": "Two source tabs",
        "layout": {
            "tabs": [
                {"name": "Overview", "tiles": [
                    {"visualization_id": "v1", "x": 0, "y": 0, "width": 12, "height": 6},
                ]},
                {"name": "Detail", "tiles": [
                    {"visualization_id": "v2", "x": 0, "y": 0, "width": 12, "height": 8},
                ]},
            ]
        },
    }
    pages, page_specs, nav = migrate.liveboard_pages(
        lb, [("v1", specs[0]), ("v2", specs[1])], elements, controls, "Sales"
    )
    data = {"id": "m-ofv", "kind": "table", "name": "OFV"}
    doc = apply_layouts.prepare_document(
        {
            "schemaVersion": 1,
            "kind": "workbook",
            "pages": [{"id": "p-data", "name": "Data", "visibility": "hidden"}] + pages,
            "elements": [data] + controls + nav + elements,
        },
        page_specs=page_specs,
        data_element_ids=["m-ofv"],
    )

    assert len(pages) == 2
    assert all("elements" not in page for page in doc["pages"])
    assert len(nav) == 2 and all(el["kind"] == "navigation" and el["mode"] == "auto"
                                 for el in nav)
    declared = [el["id"] for el in doc["elements"]]
    placed = apply_layouts._layout_element_ids(doc["layout"])
    assert sorted(declared) == sorted(placed)
    assert len(placed) == len(set(placed))
    assert all(doc["layout"].count(f'elementId="{eid}"') == 1 for eid in declared)
    assert set(re.findall(r"</?([A-Za-z][A-Za-z0-9]*)\b", doc["layout"])) == {
        "Page", "Element", "Container",
    }
    page_ids = code_rep.workbook_page_element_ids(doc)
    assert {"region-control", "p-tab-1-navigation", "chart-overview"}.issubset(
        page_ids["p-tab-1"]
    )
    assert "table-detail" not in page_ids["p-tab-1"]
    assert {"p-tab-2-navigation", "table-detail"}.issubset(page_ids["p-tab-2"])

    # The manifest carries page_specs back into a later layout pass. Reapplying
    # must preserve tab ownership and source tile geometry, not auto-grid all
    # flat elements onto the first page.
    reapplied = apply_layouts.prepare_document(
        doc, page_specs=page_specs, data_element_ids=["m-ofv"]
    )
    reapplied_pages = code_rep.workbook_page_element_ids(reapplied)
    assert "chart-overview" in reapplied_pages["p-tab-1"]
    assert "table-detail" in reapplied_pages["p-tab-2"]
    assert len(apply_layouts._layout_element_ids(reapplied["layout"])) == len(
        reapplied["elements"]
    )


def test_control_refs_and_grouped_scatter():
    resolver = {
        "Region": {"friendly": "Region", "ofv": "Region"},
        "Revenue": {"friendly": "Revenue", "ofv": "Revenue", "measure": True},
        "Margin": {"friendly": "Margin", "ofv": "Margin", "measure": True},
    }
    master = {
        "id": "m-ofv", "kind": "table", "name": "OFV",
        "columns": [{"id": "ofv-region", "name": "Region", "formula": "[View/Region]"}],
    }
    controls = ts_common.liveboard_controls(
        [{"col": "Region", "mode": "include", "values": ["West"], "type": "list"}],
        resolver, master, denorm_name="View",
    )
    control = controls[0]
    assert control["controlId"].endswith("Filter")
    assert control["source"]["kind"] == "source"
    assert control["source"]["source"] == {"kind": "table", "elementId": "m-ofv"}
    assert control["filters"][0]["columnId"] == "ofv-region"

    scatter = ts_common.sigma_element(
        {
            "name": "Revenue vs Margin",
            "chart": "SCATTER",
            "dims": ["Region"],
            "measures": ["Revenue", "Margin"],
            "mtypes": {},
        },
        resolver,
    )
    grouped = ts_common.drain_scatter_sources()
    assert len(grouped) == 1
    assert scatter["source"]["groupingId"] == grouped[0]["groupings"][0]["id"]
    assert grouped[0]["source"] == {"elementId": "m-ofv", "kind": "table"}


def test_release_gap_catalog_is_explicit():
    path = os.path.join(HERE, "..", "refs", "catalogs", "workbook-feature.json")
    rows = {row["source"]: row for row in json.load(open(path))["rows"]}
    for key in ("multi-level-axis-drill", "standalone-legend-control",
                "liveboard-tabs-as-tabbed-container", "repeated-container",
                "page-break", "gauge-as-progress", "workbook-panels"):
        assert rows[key]["sigma"] is None
        assert rows[key]["no_sigma_equiv"] is True
        assert (
            rows[key]["on_unmapped"] == "explicit-gap"
            or key in ("gauge-as-progress", "multi-level-axis-drill")
        )


if __name__ == "__main__":
    test_tabs_flat_elements_and_exact_layout()
    test_control_refs_and_grouped_scatter()
    test_release_gap_catalog_is_explicit()
    print("ALL PASS")
