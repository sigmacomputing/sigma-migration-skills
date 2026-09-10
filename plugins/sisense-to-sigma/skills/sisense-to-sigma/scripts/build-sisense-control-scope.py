#!/usr/bin/env python3
"""Build the durable source-to-live Sigma control-scope sidecar."""
import argparse
import json
import os
import re
import sys
from pathlib import Path

QUERYABLE = {
    "table", "pivot-table", "input-table", "bar-chart", "line-chart",
    "pie-chart", "donut-chart", "area-chart", "scatter-chart", "combo-chart",
    "kpi-chart", "box-chart", "funnel-chart", "gauge-chart",
    "waterfall-chart", "sankey-chart", "region-map", "point-map", "viz",
    "chart", "treemap-chart", "heatmap-chart", "word-cloud",
}


class ScopeError(Exception):
    pass


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ScopeError("cannot read %s: %s" % (path, exc)) from exc


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def normalized(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def workbook_root(value):
    return value.get("document", value) if isinstance(value, dict) else {}


def workbook_elements(value):
    root = workbook_root(value)
    rows = [row for row in root.get("elements") or [] if isinstance(row, dict)]
    for page in root.get("pages") or []:
        if isinstance(page, dict):
            rows.extend(row for row in page.get("elements") or [] if isinstance(row, dict))
    return rows


def page_membership(value):
    root = workbook_root(value)
    layout = str(root.get("layout") or "")
    membership = {}
    for page_id, body in re.findall(
            r'<Page\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</Page>', layout, re.DOTALL):
        for element_id in re.findall(r'\belementId="([^"]+)"', body):
            membership[element_id] = page_id
    return membership


def source_filters(dashboards):
    dashboards = dashboards if isinstance(dashboards, list) else [dashboards]
    rows = []
    dropped = []
    for dashboard_index, dashboard in enumerate(dashboards):
        dashboard_name = dashboard.get("title") or dashboard.get("_id") or str(dashboard_index)
        for filter_index, source_filter in enumerate(dashboard.get("filters") or []):
            jaql = source_filter.get("jaql") or {}
            name = (
                jaql.get("title") or jaql.get("dim") or source_filter.get("title")
                or "Filter %d" % (filter_index + 1)
            )
            rows.append({
                "id": str(source_filter.get("oid") or source_filter.get("_id")
                          or "dashboard-%d-filter-%d" % (dashboard_index, filter_index)),
                "name": str(name),
                "dashboard": str(dashboard_name),
                "source": {
                    "artifact": "dashboards.json",
                    "json_pointer": "/%d/filters/%d" % (dashboard_index, filter_index),
                },
            })
        # Widget-local predicates are query semantics, not interactive controls.
        # Record them explicitly so they are not mistaken for lost user controls.
        for widget_index, widget in enumerate(dashboard.get("widgets") or []):
            for panel_index, panel in enumerate((widget.get("metadata") or {}).get("panels") or []):
                for item_index, item in enumerate(panel.get("items") or []):
                    jaql = item.get("jaql") or {}
                    if "filter" not in jaql:
                        continue
                    dropped.append({
                        "name": jaql.get("title") or jaql.get("dim") or "widget predicate",
                        "status": "not-interactive",
                        "reason": "widget-local JAQL predicate is query semantics, not a source control",
                        "source": {
                            "artifact": "dashboards.json",
                            "json_pointer": (
                                "/%d/widgets/%d/metadata/panels/%d/items/%d/jaql/filter" %
                                (dashboard_index, widget_index, panel_index, item_index)
                            ),
                        },
                    })
    return rows, dropped


def build(dashboards, workbook):
    filters, dropped = source_filters(dashboards)
    elements = workbook_elements(workbook)
    pages = page_membership(workbook)
    controls = [
        row for row in elements
        if row.get("controlType") or "control" in str(row.get("kind") or row.get("type"))
    ]
    available = list(controls)
    scope_rows = []
    unbound = []
    for source_filter in filters:
        match_index = next((
            index for index, control in enumerate(available)
            if normalized(control.get("name")) == normalized(source_filter["name"])
            or normalized(control.get("controlId")) == normalized(source_filter["name"])
        ), None)
        if match_index is None:
            row = {
                "controlId": "unbound-%s" % normalized(source_filter["id"]),
                "sourceName": source_filter["name"],
                "status": "unbound",
                "scope": "page",
                "mustReach": [],
                "source": source_filter["source"],
            }
            scope_rows.append(row)
            unbound.append({
                "sourceName": source_filter["name"],
                "sourceId": source_filter["id"],
                "reason": "no live workbook control matched this source dashboard filter",
                "source": source_filter["source"],
            })
            continue
        control = available.pop(match_index)
        control_page = pages.get(str(control.get("id")))
        must_reach = sorted({
            str(element.get("id"))
            for element in elements
            if element.get("id") and pages.get(str(element.get("id"))) == control_page
            and str(element.get("kind") or element.get("type")) in QUERYABLE
        })
        scope_rows.append({
            "controlId": control.get("controlId"),
            "sourceName": source_filter["name"],
            "status": "emitted",
            "scope": "page",
            "mustReach": must_reach,
            "source": source_filter["source"],
            "liveElementId": control.get("id"),
        })
    for control in available:
        dropped.append({
            "name": control.get("name") or control.get("controlId"),
            "status": "target-only",
            "reason": "live workbook control has no matching source dashboard filter",
            "liveElementId": control.get("id"),
        })
    return {
        "version": 1,
        "source": "sisense",
        "sourceFilterSignals": len(filters),
        "controls": scope_rows,
        "unbound": unbound,
        "dropped": dropped,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dashboards", required=True)
    parser.add_argument("--workbook", required=True,
                        help="live wb-readback.json (or an equivalent workbook spec)")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    output = build(read_json(args.dashboards), read_json(args.workbook))
    write_json(args.out, output)
    print("Sisense control scope: %d source signal(s), %d emitted, %d unbound" % (
        output["sourceFilterSignals"],
        sum(row["status"] == "emitted" for row in output["controls"]),
        len(output["unbound"]),
    ))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ScopeError as error:
        print("build-sisense-control-scope: %s" % error, file=sys.stderr)
        sys.exit(2)
