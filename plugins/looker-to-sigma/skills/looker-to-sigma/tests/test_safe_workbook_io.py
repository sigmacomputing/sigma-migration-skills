#!/usr/bin/env python3
"""Offline tests for pagination, reference readback, and write drift guards."""

import copy
import os
import sys


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SKILL, "scripts", "lib"))

from safe_workbook_io import (  # noqa: E402
    fingerprint,
    list_entries,
    remote_drifted,
    validate_workbook_refs,
)


def test_both_sigma_pagination_conventions():
    calls = []

    def next_page(path):
        calls.append(path)
        if "page=" not in path:
            return {"entries": [{"id": 1}], "nextPage": "two"}
        return {"entries": [{"id": 2}]}

    assert [row["id"] for row in list_entries(next_page, "/v2/files")] == [1, 2]
    assert "page=two" in calls[-1]

    calls.clear()

    def token_page(path):
        calls.append(path)
        if "pageToken=" not in path:
            return {"entries": [{"id": 1}], "nextPageToken": "wide-2"}
        return {"entries": [{"id": 2}]}

    assert [row["id"] for row in list_entries(token_page, "/v2/workbooks/w/columns")] == [1, 2]
    assert "pageToken=wide-2" in calls[-1]


def valid_specs():
    dm = {
        "pages": [
            {
                "elements": [
                    {
                        "id": "dm-source",
                        "name": "Orders",
                        "columns": [{"id": "dm-revenue", "name": "Revenue"}],
                        "metrics": [{"id": "metric", "name": "Total Revenue", "formula": "Sum([Revenue])"}],
                    }
                ]
            }
        ]
    }
    wb = {
        "document": {
            "elements": [
                {
                    "id": "master",
                    "name": "Data",
                    "kind": "table",
                    "source": {"kind": "data-model", "dataModelId": "dm", "elementId": "dm-source"},
                    "columns": [{"id": "revenue", "name": "Revenue", "formula": "[Orders/Revenue]"}],
                },
                {
                    "id": "chart",
                    "name": "Revenue",
                    "kind": "bar-chart",
                    "source": {"kind": "table", "elementId": "master"},
                    "columns": [
                        {"id": "value", "name": "Revenue", "formula": "Sum([Data/Revenue])"},
                        {"id": "metric-value", "name": "Metric", "formula": "[Metrics/Total Revenue]"},
                    ],
                },
            ]
        }
    }
    columns = [{"label": "Revenue", "type": {"type": "number"}}]
    return dm, wb, columns


def test_reference_gate_catches_stale_snapshots_and_error_only_columns():
    dm, wb, columns = valid_specs()
    assert validate_workbook_refs(wb, dm, columns) == []

    stale = copy.deepcopy(wb)
    stale["document"]["elements"][1]["columns"][0]["formula"] = "Sum([Data/Old Revenue])"
    failures = validate_workbook_refs(stale, dm, columns)
    assert any("internal reference [Data/Old Revenue] is stale" in failure for failure in failures)

    failures = validate_workbook_refs(
        wb,
        dm,
        [{"label": "Revenue", "type": {"type": "error"}}],
    )
    assert any("error-typed" in failure for failure in failures)


def test_version_and_content_fingerprint_detect_remote_drift():
    base = {
        "latestDocumentVersion": 10,
        "document": {"elements": [{"id": "a", "name": "Before"}]},
    }
    saved = fingerprint(base)
    assert not remote_drifted(saved, copy.deepcopy(base))

    version_changed = copy.deepcopy(base)
    version_changed["latestDocumentVersion"] = 11
    assert remote_drifted(saved, version_changed)

    content_changed = copy.deepcopy(base)
    content_changed["document"]["elements"][0]["name"] = "Human edit"
    assert remote_drifted(saved, content_changed)


if __name__ == "__main__":
    test_both_sigma_pagination_conventions()
    test_reference_gate_catches_stale_snapshots_and_error_only_columns()
    test_version_and_content_fingerprint_detect_remote_drift()
    print("safe workbook IO: PASS")
