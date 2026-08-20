#!/usr/bin/env python3
"""Normalize a corectl ``unbuild`` folder into qlik-to-sigma discovery files.

corectl writes sheets as full property trees. Their visual objects are nested
under ``qChildren`` rather than emitted as separate top-level files. This
normalizer recursively flattens those trees and emits the same artifact contract
as qlik-discover.py, allowing the standard migration pipeline to consume an
offline export without Qlik CLI, MCP, or hand-authored workbook JSON.
"""
import argparse
import json
import os
import re
import shutil

from qlik_load_script import parse_tables
from qlik_object_props import effective_chart_properties


def write_json(path, value):
    with open(path, "w") as handle:
        json.dump(value, handle, indent=2)


def property_of(node):
    if not isinstance(node, dict):
        return {}
    return node.get("qProperty") if isinstance(node.get("qProperty"), dict) else node


def flatten_tree(node, sheet_id=None, parent_id=None):
    """Yield (properties, sheet id, parent id, direct child ids) recursively."""
    props = property_of(node)
    info = props.get("qInfo") or {}
    object_id = info.get("qId")
    object_type = info.get("qType")
    current_sheet = object_id if object_type == "sheet" else sheet_id
    children = node.get("qChildren") or [] if isinstance(node, dict) else []
    child_ids = []
    for child in children:
        child_id = (property_of(child).get("qInfo") or {}).get("qId")
        if child_id:
            child_ids.append(child_id)
    if object_id:
        yield props, current_sheet, parent_id, child_ids
    for child in children:
        yield from flatten_tree(child, current_sheet, object_id)


def normalize_measure(raw):
    body = raw.get("qMeasure") or {}
    info = raw.get("qInfo") or {}
    meta = raw.get("qMetaDef") or {}
    object_id = info.get("qId")
    title = meta.get("title") or body.get("qLabel") or object_id
    return {"id": object_id, "title": title, "expr": body.get("qDef") or ""}


def normalize_dimension(raw):
    body = raw.get("qDim") or {}
    info = raw.get("qInfo") or {}
    meta = raw.get("qMetaDef") or {}
    defs = body.get("qFieldDefs") or []
    object_id = info.get("qId")
    title = meta.get("title") or body.get("title") or object_id
    return {"id": object_id, "title": title, "expr": defs[0] if defs else ""}


def static_title(props):
    for value in ((props.get("qMetaDef") or {}).get("title"), props.get("title")):
        if isinstance(value, str) and value.strip():
            return value
    return None


def normalize_chart(props, sheet_id, child_ids):
    info = props.get("qInfo") or {}
    effective, effective_type = effective_chart_properties(props, info.get("qType"))
    hypercube = effective.get("qHyperCubeDef") or {}
    dimensions = hypercube.get("qDimensions") or []
    measures = hypercube.get("qMeasures") or []
    visualization = effective.get("visualization")
    qtype = info.get("qType") or (visualization if isinstance(visualization, str) else None) or "unknown"
    viz_type = effective_type or (visualization if isinstance(visualization, str) and visualization else qtype)
    record = {
        "id": info.get("qId"),
        "vizType": viz_type,
        "title": static_title(effective) or static_title(props),
        "sheet": sheet_id,
        "dimensions": [
            (dimension.get("qDef") or {}).get("qFieldDefs")
            or [dimension.get("qLibraryId")]
            for dimension in dimensions
        ],
        "dimLabels": [
            (((dimension.get("qDef") or {}).get("qFieldLabels") or [None]) or [None])[0]
            for dimension in dimensions
        ],
        "dimNullSuppression": [bool(dimension.get("qNullSuppression")) for dimension in dimensions],
        "measures": [
            (measure.get("qDef") or {}).get("qDef") or measure.get("qLibraryId")
            for measure in measures
        ],
        "measureLabels": [(measure.get("qDef") or {}).get("qLabel") for measure in measures],
        "measureFmts": [
            (measure.get("qNumFormat") or (measure.get("qDef") or {}).get("qNumFormat") or {}).get("qFmt")
            for measure in measures
        ],
        "sort": {
            "interColumnSortOrder": hypercube.get("qInterColumnSortOrder") or [],
            "dimensions": [
                (dimension.get("qDef") or {}).get("qSortCriterias") or []
                for dimension in dimensions
            ],
            "measures": [measure.get("qSortBy") or {} for measure in measures],
        },
    }
    if effective.get("color") is not None:
        record["color"] = effective["color"]
    if viz_type == "filterpane":
        record["children"] = child_ids
        record["state"] = props.get("qStateName")
    elif viz_type == "listbox":
        list_def = props.get("qListObjectDef") or {}
        definition = list_def.get("qDef") or {}
        record["listbox"] = {
            "field": (definition.get("qFieldDefs") or [None])[0] or list_def.get("qLibraryId"),
            "label": (definition.get("qFieldLabels") or [None])[0] or record["title"],
            "state": list_def.get("qStateName") or props.get("qStateName"),
            "tags": [],
            "numFmt": None,
        }
    elif viz_type == "container":
        raw_children = props.get("children") or props.get("cells") or []
        embedded_ids, labels = [], []
        for child in raw_children:
            if isinstance(child, str):
                embedded_ids.append(child)
                labels.append(None)
            elif isinstance(child, dict):
                child_info = child.get("qInfo") or {}
                child_meta = child.get("qMeta") or child.get("qMetaDef") or {}
                child_id = child.get("name") or child.get("id") or child.get("qId") or child_info.get("qId")
                if child_id:
                    embedded_ids.append(child_id)
                    labels.append(child.get("label") or child.get("title") or child_meta.get("title"))
        record["children"] = embedded_ids or child_ids
        record["childLabels"] = labels
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--unbuild", required=True, help="corectl unbuild directory")
    parser.add_argument("--out", required=True, help="normalized discovery directory")
    args = parser.parse_args()
    source = os.path.abspath(args.unbuild)
    output = os.path.abspath(args.out)
    if os.path.realpath(source) == os.path.realpath(output):
        raise SystemExit("FATAL: --out must differ from --unbuild; normalization never overwrites the source export")
    script_path = os.path.join(source, "script.qvs")
    objects_path = os.path.join(source, "objects")
    if not os.path.isfile(script_path):
        raise SystemExit(f"FATAL: corectl unbuild folder has no script.qvs: {source}")
    if not os.path.isdir(objects_path):
        raise SystemExit(f"FATAL: corectl unbuild folder has no objects directory: {source}")
    os.makedirs(output, exist_ok=True)

    script = open(script_path).read()
    shutil.copyfile(script_path, os.path.join(output, "script.qvs"))
    raw_measures_path = os.path.join(source, "measures.json")
    raw_dimensions_path = os.path.join(source, "dimensions.json")
    raw_measures = json.load(open(raw_measures_path)) if os.path.exists(raw_measures_path) else []
    raw_dimensions = json.load(open(raw_dimensions_path)) if os.path.exists(raw_dimensions_path) else []
    measures = [normalize_measure(item) for item in raw_measures]
    dimensions = [normalize_dimension(item) for item in raw_dimensions]

    object_rows = []
    for name in sorted(os.listdir(objects_path)):
        if not name.lower().endswith(".json"):
            continue
        tree = json.load(open(os.path.join(objects_path, name)))
        object_rows.extend(flatten_tree(tree))

    # A malformed/hand-edited export can repeat a child as both a standalone
    # file and a sheet-tree node. Prefer the occurrence carrying sheet ownership
    # so filename order can never detach a visual from its page.
    rows_by_id = {}
    for row in object_rows:
        object_id = (row[0].get("qInfo") or {}).get("qId")
        if not object_id:
            continue
        prior = rows_by_id.get(object_id)
        if prior is None or (prior[1] is None and row[1] is not None):
            rows_by_id[object_id] = row

    sheets, charts = [], []
    for props, sheet_id, _parent_id, child_ids in rows_by_id.values():
        info = props.get("qInfo") or {}
        object_id, object_type = info.get("qId"), info.get("qType")
        if object_type == "sheet":
            cells = [
                {
                    "objectId": cell.get("name"),
                    "type": cell.get("type"),
                    "col": cell.get("col", 0),
                    "row": cell.get("row", 0),
                    "colspan": cell.get("colspan", 1),
                    "rowspan": cell.get("rowspan", 1),
                }
                for cell in (props.get("cells") or [])
                if cell.get("name")
            ]
            sheets.append(
                {
                    "sheetId": object_id,
                    "title": (props.get("qMetaDef") or {}).get("title") or object_id,
                    "rank": props.get("rank", 0),
                    "columns": props.get("columns", 24),
                    "rows": props.get("rows", 12),
                    "cells": cells,
                }
            )
        else:
            charts.append(normalize_chart(props, sheet_id, child_ids))
    sheets.sort(key=lambda sheet: (sheet.get("rank") is None, sheet.get("rank") or 0))

    app_props_path = os.path.join(source, "app-properties.json")
    app_props = json.load(open(app_props_path)) if os.path.exists(app_props_path) else {}
    app_name = app_props.get("qTitle") or app_props.get("title") or os.path.basename(source)
    app_meta = {
        "name": app_name,
        "lastReloadTime": app_props.get("qLastReloadTime") or app_props.get("lastReloadTime"),
        "hasSectionAccess": bool(re.search(r"^\s*SECTION\s+ACCESS\b", script, re.I | re.M)),
        "isDirectQueryMode": bool(app_props.get("isDirectQueryMode", False)),
        "source": "corectl-unbuild",
    }
    calc_dimension = re.compile(
        r"^=|\b(If|Sum|Count|Avg|Concat|Year|Month|Day|Left|Right|Upper|Lower|Trim)\s*\(", re.I
    )
    converter_input = {
        "appName": app_name,
        "tables": parse_tables(script),
        "masterMeasures": [{"title": item["title"], "qDef": item["expr"]} for item in measures],
        "masterDimensions": [
            {"title": item["title"], "fieldDef": item["expr"]}
            for item in dimensions
            if calc_dimension.search(item.get("expr") or "")
        ],
    }
    write_json(os.path.join(output, "measures.json"), measures)
    write_json(os.path.join(output, "dimensions.json"), dimensions)
    write_json(os.path.join(output, "charts.json"), charts)
    write_json(os.path.join(output, "layout.json"), sheets)
    write_json(os.path.join(output, "app-meta.json"), app_meta)
    write_json(os.path.join(output, "snapshot.json"), {"kpis": [], "maxDates": [], "buckets": []})
    write_json(os.path.join(output, "converter-input.json"), converter_input)
    write_json(
        os.path.join(output, "unbuild-normalization.json"),
        {
            "source": source,
            "objectFiles": len([name for name in os.listdir(objects_path) if name.lower().endswith(".json")]),
            "flattenedObjects": len(object_rows),
            "sheets": len(sheets),
            "charts": len(charts),
            "masterMeasures": len(measures),
            "masterDimensions": len(dimensions),
        },
    )
    print(
        f"corectl unbuild normalized: tables={len(converter_input['tables'])} "
        f"masterMeasures={len(measures)} masterDimensions={len(dimensions)} "
        f"charts={len(charts)} sheets={len(sheets)} -> {output}"
    )


if __name__ == "__main__":
    main()
