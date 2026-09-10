#!/usr/bin/env python3
"""Structured gap scout for Sisense -> Sigma converter coverage.

The positional dashboards argument and human-readable stdout are retained for
existing callers. ``--model`` adds a complete model census and ``--out`` writes
the deterministic, machine-readable report used by migration hard gates.
"""
import argparse
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import convert as C

SCHEMA_VERSION = 1
STATUS_ORDER = ("auto", "hint", "manual", "unhandled", "not-applicable")
TYPE_ORDER = (
    "model-table", "model-column", "model-relation", "model-transformation",
    "dashboard", "widget", "filter",
)
CATEGORY_NOTE = {
    "AUTO":      "widget + JAQL map cleanly to a Sigma element",
    "HINT":      "near-equivalent Sigma element — review the substitution",
    "MANUAL":    "no native Sigma element — rebuild by hand",
    "UNHANDLED": "unknown widget type — not converted",
}


def _read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def _stable_fallback(prefix, value):
    body = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return "%s-%s" % (prefix, hashlib.sha256(body.encode("utf-8")).hexdigest()[:16])


def _source(artifact, pointer, **extra):
    provenance = {"artifact": os.path.basename(artifact), "json_pointer": pointer}
    provenance.update({key: value for key, value in extra.items() if value is not None})
    return provenance


def _object(kind, object_id, name, status, evidence, source):
    if status not in STATUS_ORDER:
        raise ValueError("invalid gap-scan status: %s" % status)
    return {
        "type": kind,
        "id": str(object_id),
        "name": str(name or object_id),
        "status": status,
        "evidence": list(evidence),
        "source": source,
    }


def _gap(obj, category, reason, evidence=None):
    return {
        "object_type": obj["type"],
        "object_id": obj["id"],
        "object_name": obj["name"],
        "category": category,
        "reason": reason,
        "evidence": list(evidence or obj["evidence"]),
        "source": obj["source"],
    }


def _model_objects(model, model_path):
    objects, gaps = [], []
    table_ref, column_ref = {}, {}

    for dataset_index, dataset in enumerate(model.get("datasets") or []):
        tables = ((dataset.get("schema") or {}).get("tables") or [])
        for table_index, table in enumerate(tables):
            pointer = "/datasets/%d/schema/tables/%d" % (dataset_index, table_index)
            table_id = table.get("oid") or table.get("id") or _stable_fallback("table", table)
            table_name = table.get("displayName") or table.get("name") or table.get("id") or table_id
            expression = (table.get("expression") or {}).get("expression")
            status = "hint" if expression else "auto"
            evidence = (
                ["ElastiCube SQL is emitted as reviewed Sigma Custom SQL"]
                if expression else
                ["physical source table maps to a Sigma warehouse-table element"]
            )
            obj = _object(
                "model-table", table_id, table_name, status, evidence,
                _source(model_path, pointer, model_id=model.get("oid"),
                        dataset_id=dataset.get("oid")),
            )
            objects.append(obj)
            table_ref[table.get("oid") or table.get("id")] = table_name
            if expression:
                gaps.append(_gap(
                    obj, "flagged",
                    "ElastiCube Custom SQL requires warehouse-dialect and result verification",
                ))

            for column_index, column in enumerate(table.get("columns") or []):
                column_pointer = "%s/columns/%d" % (pointer, column_index)
                column_key = column.get("id") or column.get("name")
                column_id = column.get("oid") or (
                    "%s/%s" % (table_id, column_key)
                    if column_key else _stable_fallback("column", column)
                )
                column_name = column.get("displayName") or column.get("name") or column.get("id") or column_id
                type_code = column.get("type")
                column_expression = column.get("expression")
                if type_code not in C.TYPE:
                    column_status = "unhandled"
                    column_evidence = ["Sisense type code %r has no converter mapping" % type_code]
                elif column_expression or column.get("import") or column.get("isCustom"):
                    column_status = "manual"
                    column_evidence = ["column-level transform metadata is not converted"]
                else:
                    column_status = "auto"
                    column_evidence = [
                        "Sisense type code %s maps to Sigma %s" % (type_code, C.TYPE[type_code])
                    ]
                column_obj = _object(
                    "model-column", column_id, column_name, column_status,
                    column_evidence,
                    _source(model_path, column_pointer, model_id=model.get("oid"),
                            dataset_id=dataset.get("oid"), table_id=table_id),
                )
                objects.append(column_obj)
                column_ref[(table.get("oid"), column.get("oid"))] = (
                    table_name, column_name
                )
                if column_status in ("manual", "unhandled"):
                    gaps.append(_gap(
                        column_obj, column_status,
                        column_evidence[0],
                    ))

        for transformation_index, transformation in enumerate(
                dataset.get("modelingTransformations") or []):
            pointer = "/datasets/%d/modelingTransformations/%d" % (
                dataset_index, transformation_index
            )
            transform_id = (
                transformation.get("oid") or transformation.get("id")
                if isinstance(transformation, dict) else None
            ) or _stable_fallback("transformation", transformation)
            transform_name = (
                transformation.get("name") or transformation.get("type")
                if isinstance(transformation, dict) else None
            ) or "Dataset transformation %d" % (transformation_index + 1)
            obj = _object(
                "model-transformation", transform_id, transform_name, "unhandled",
                ["import-time modeling transformation is not converted"],
                _source(model_path, pointer, model_id=model.get("oid"),
                        dataset_id=dataset.get("oid")),
            )
            objects.append(obj)
            gaps.append(_gap(
                obj, "unhandled",
                "modelingTransformations must be rebuilt upstream or accepted explicitly",
            ))

    for relation_index, relation in enumerate(model.get("relations") or []):
        pointer = "/relations/%d" % relation_index
        relation_id = relation.get("oid") or relation.get("id") or _stable_fallback(
            "relation", relation
        )
        endpoints = []
        for endpoint in relation.get("columns") or []:
            ref = column_ref.get((endpoint.get("table"), endpoint.get("column")))
            endpoints.append(
                "%s.%s" % ref if ref else "%s.%s" % (
                    endpoint.get("table", "?"), endpoint.get("column", "?")
                )
            )
        relation_name = " <-> ".join(endpoints) or str(relation_id)
        valid = len(endpoints) == 2 and all("?" not in endpoint for endpoint in endpoints)
        status = "hint" if valid else "unhandled"
        evidence = (
            ["relationship maps after cardinality verifies fact/dimension direction"]
            if valid else
            ["relationship endpoints are incomplete or cannot be resolved"]
        )
        obj = _object(
            "model-relation", relation_id, relation_name, status, evidence,
            _source(model_path, pointer, model_id=model.get("oid")),
        )
        objects.append(obj)
        if not valid:
            gaps.append(_gap(obj, "unhandled", evidence[0]))

    for transformation_index, transformation in enumerate(
            model.get("modelingTransformations") or []):
        pointer = "/modelingTransformations/%d" % transformation_index
        transform_id = (
            transformation.get("oid") or transformation.get("id")
            if isinstance(transformation, dict) else None
        ) or _stable_fallback("transformation", transformation)
        transform_name = (
            transformation.get("name") or transformation.get("type")
            if isinstance(transformation, dict) else None
        ) or "Model transformation %d" % (transformation_index + 1)
        obj = _object(
            "model-transformation", transform_id, transform_name, "unhandled",
            ["model-level import transformation is not converted"],
            _source(model_path, pointer, model_id=model.get("oid")),
        )
        objects.append(obj)
        gaps.append(_gap(
            obj, "unhandled",
            "modelingTransformations must be rebuilt upstream or accepted explicitly",
        ))

    return objects, gaps


def _filter_object(parent_id, filter_value, dashboard_path, pointer,
                   filter_index, dashboard_id, widget_id=None):
    jaql = filter_value.get("jaql") or {}
    dim = jaql.get("dim")
    name = jaql.get("title") or jaql.get("column") or dim or "Filter %d" % (filter_index + 1)
    filter_id = "%s/filter/%s/%d" % (
        parent_id,
        re.sub(r"[^A-Za-z0-9_.-]+", "-", dim or name).strip("-") or "unnamed",
        filter_index,
    )
    filter_shape = jaql.get("filter") or {}
    top = filter_shape.get("top") if isinstance(filter_shape, dict) else None
    if top:
        by = top.get("by") or {}
        valid = (
            bool(top.get("count")) and
            bool(re.match(r"^\[[^.\]]+\.[^\]]+\]$", dim or "")) and
            bool(by.get("dim")) and bool(by.get("agg"))
        )
        status = "auto" if valid else "manual"
        evidence = [
            "JAQL top-N maps to a Sigma top-n filter"
            if valid else
            "top-N filter lacks count, ranking dimension, or aggregation"
        ]
    elif widget_id:
        status = "unhandled"
        evidence = ["non-top-N widget field filter is not emitted by the converter"]
    elif re.match(r"^\[[^.\]]+\.[^\]]+\]$", dim or ""):
        status = "auto"
        evidence = ["dashboard filter has a table/column JAQL binding"]
    else:
        status = "unhandled"
        evidence = ["filter has no resolvable [Table.Column] JAQL dimension"]
    return _object(
        "filter", filter_id, name, status, evidence,
        _source(dashboard_path, pointer, dashboard_id=dashboard_id,
                widget_id=widget_id),
    )


def _dashboard_objects(dashboards, dashboard_path):
    objects, gaps, legacy_gaps = [], [], []
    for dashboard_index, dashboard in enumerate(dashboards):
        pointer = "/%d" % dashboard_index
        dashboard_id = (
            dashboard.get("_id") or dashboard.get("oid") or
            _stable_fallback("dashboard", dashboard)
        )
        dashboard_name = dashboard.get("title") or dashboard_id
        dashboard_obj = _object(
            "dashboard", dashboard_id, dashboard_name, "not-applicable",
            ["dashboard is a source container; widgets and filters are classified separately"],
            _source(dashboard_path, pointer),
        )
        objects.append(dashboard_obj)

        for filter_index, filter_value in enumerate(dashboard.get("filters") or []):
            filter_obj = _filter_object(
                dashboard_id, filter_value, dashboard_path,
                "/%d/filters/%d" % (dashboard_index, filter_index),
                filter_index, dashboard_id,
            )
            objects.append(filter_obj)
            if filter_obj["status"] in ("manual", "unhandled"):
                gaps.append(_gap(
                    filter_obj, filter_obj["status"], filter_obj["evidence"][0]
                ))

        for widget_index, widget in enumerate(dashboard.get("widgets") or []):
            widget_pointer = "%s/widgets/%d" % (pointer, widget_index)
            widget_id = (
                widget.get("_id") or widget.get("oid") or
                _stable_fallback("widget", widget)
            )
            row = C.classify_dashboard([{"widgets": [widget]}])[0]
            status = row["tag"].lower()
            widget_type = row.get("sisense_type")
            evidence = [
                "%s maps to %s (%s)" % (
                    widget_type or "<missing type>",
                    row.get("sigma_element") or "no Sigma element",
                    CATEGORY_NOTE[row["tag"]],
                )
            ]
            obj = _object(
                "widget", widget_id, row.get("title") or widget_id, status,
                evidence,
                _source(dashboard_path, widget_pointer, dashboard_id=dashboard_id),
            )
            objects.append(obj)

            nested_filter_index = 0
            for panel_index, panel in enumerate(
                    (widget.get("metadata") or {}).get("panels") or []):
                for item_index, item in enumerate(panel.get("items") or []):
                    jaql = item.get("jaql") or {}
                    if "filter" not in jaql:
                        continue
                    filter_pointer = (
                        "%s/metadata/panels/%d/items/%d/jaql/filter" %
                        (widget_pointer, panel_index, item_index)
                    )
                    filter_obj = _filter_object(
                        widget_id, {"jaql": jaql}, dashboard_path,
                        filter_pointer, nested_filter_index, dashboard_id,
                        widget_id=widget_id,
                    )
                    nested_filter_index += 1
                    objects.append(filter_obj)
                    if filter_obj["status"] in ("manual", "unhandled"):
                        gaps.append(_gap(
                            filter_obj, filter_obj["status"],
                            filter_obj["evidence"][0],
                        ))
            for filter_index, filter_value in enumerate(widget.get("filters") or []):
                filter_pointer = "%s/filters/%d" % (widget_pointer, filter_index)
                filter_obj = _filter_object(
                    widget_id, filter_value, dashboard_path, filter_pointer,
                    nested_filter_index + filter_index, dashboard_id,
                    widget_id=widget_id,
                )
                objects.append(filter_obj)
                if filter_obj["status"] in ("manual", "unhandled"):
                    gaps.append(_gap(
                        filter_obj, filter_obj["status"],
                        filter_obj["evidence"][0],
                    ))

            if row["tag"] in ("MANUAL", "UNHANDLED"):
                reason = CATEGORY_NOTE[row["tag"]]
                gaps.append(_gap(obj, status, reason))
                legacy_gaps.append({
                    "widget": row["title"],
                    "sisense_type": widget_type,
                    "category": row["tag"],
                    "reason": reason,
                })
            elif row.get("sigma_element") is not None and widget_type not in C.SIGMA_KIND:
                reason = "classifier suggests a near-equivalent but the converter emits no element"
                gaps.append(_gap(obj, "flagged", reason))

            for field_flag in row.get("field_flags") or []:
                gaps.append(_gap(obj, "flagged", field_flag, [field_flag]))
                legacy_gaps.append({
                    "widget": row["title"],
                    "sisense_type": widget_type,
                    "category": "JAQL",
                    "reason": field_flag,
                })
    return objects, gaps, legacy_gaps


def build_report(dashboards, dashboard_path, model=None, model_path=None):
    dashboard_objects, dashboard_gaps, legacy_gaps = _dashboard_objects(
        dashboards, dashboard_path
    )
    model_objects, model_gaps = (
        _model_objects(model, model_path) if model is not None else ([], [])
    )
    objects = model_objects + dashboard_objects
    type_rank = {name: index for index, name in enumerate(TYPE_ORDER)}
    objects.sort(key=lambda obj: (
        type_rank.get(obj["type"], len(TYPE_ORDER)), obj["id"], obj["name"]
    ))
    gaps = model_gaps + dashboard_gaps
    gaps.sort(key=lambda gap: (
        type_rank.get(gap["object_type"], len(TYPE_ORDER)),
        gap["object_id"], gap["category"], gap["reason"],
    ))

    by_type = {kind: 0 for kind in TYPE_ORDER}
    by_status = {status: 0 for status in STATUS_ORDER}
    for obj in objects:
        by_type[obj["type"]] = by_type.get(obj["type"], 0) + 1
        by_status[obj["status"]] += 1
    by_type = {key: value for key, value in by_type.items() if value}
    gap_categories = {"manual": 0, "unhandled": 0, "flagged": 0}
    for gap in gaps:
        gap_categories[gap["category"]] = gap_categories.get(gap["category"], 0) + 1

    report = {
        "schema_version": SCHEMA_VERSION,
        "source": {
            "dashboards": {
                "artifact": os.path.basename(dashboard_path),
                "dashboard_count": len(dashboards),
            },
            "model": ({
                "artifact": os.path.basename(model_path),
                "model_id": model.get("oid"),
                "model_name": model.get("title"),
            } if model is not None else None),
        },
        "summary": {
            "objects": len(objects),
            "by_type": by_type,
            "by_status": by_status,
            "gaps": len(gaps),
            "gap_categories": gap_categories,
        },
        "objects": objects,
        "gaps": gaps,
    }
    return report, legacy_gaps


def _write_report(path, report):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(report, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")


def _append_rules(path, gaps):
    if not gaps:
        return 0
    previous = _read_json(path) if os.path.exists(path) else []
    seen = {(gap.get("widget"), gap.get("reason")) for gap in previous}
    fresh = [
        gap for gap in gaps
        if (gap.get("widget"), gap.get("reason")) not in seen
    ]
    if fresh:
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(previous + fresh, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
    return len(fresh)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dashboards", help="discover.py dashboards JSON")
    ap.add_argument("--model", help="optional discover.py model JSON")
    ap.add_argument("--out", help="write deterministic structured gap JSON")
    ap.add_argument("--rules", default="learned-rules.json")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any MANUAL/UNHANDLED/flagged gap remains (done-gate)")
    a = ap.parse_args()

    dashboards = _read_json(a.dashboards)
    dashboards = dashboards if isinstance(dashboards, list) else [dashboards]
    model = _read_json(a.model) if a.model else None
    rows = C.classify_dashboard(dashboards)
    report, legacy_gaps = build_report(
        dashboards, a.dashboards, model=model, model_path=a.model
    )
    if a.out:
        _write_report(a.out, report)

    by_cat = {}
    for r in rows:
        by_cat.setdefault(r["tag"], []).append(r)

    total = len(rows) or 1
    auto = len(by_cat.get("AUTO", []))
    print(f"=== Sisense->Sigma coverage: {len(rows)} widgets ===")
    for cat in ("AUTO", "HINT", "MANUAL", "UNHANDLED"):
        grp = by_cat.get(cat, [])
        if grp:
            print(f"  {cat:10} {len(grp):3}  ({CATEGORY_NOTE[cat]})")
            for r in grp:
                fl = f"  FLAGS={r['field_flags']}" if r.get("field_flags") else ""
                print(f"       - {r['title']:34} {r['sisense_type']:14} -> {r['sigma_element']}{fl}")
    flagged = report["summary"]["gap_categories"]["flagged"]
    print(f"  ---\n  AUTO: {auto}/{len(rows)} ({100*auto//total}%); "
          f"hint: {len(by_cat.get('HINT', []))}; "
          f"manual/unhandled: {len(by_cat.get('MANUAL', []))+len(by_cat.get('UNHANDLED', []))}; "
          f"flagged: {flagged}")
    print(f"  structured census: {report['summary']['objects']} objects; "
          f"{report['summary']['gaps']} unresolved gap(s)")
    if a.out:
        print(f"  wrote structured report -> {a.out}")

    if report["gaps"]:
        fresh_count = _append_rules(a.rules, legacy_gaps)
        if fresh_count:
            print(f"  appended {fresh_count} new gap(s) -> {a.rules}")
        print("  -> flag, never fake: port each gap, accept it knowingly, or "
              "escalate-gap.py to file a tracking issue (opt-in).")

    if a.strict and report["gaps"]:
        sys.exit(
            f"\nRED: {len(report['gaps'])} unresolved manual/unhandled/flagged "
            "gap(s) — not done until ported or accepted."
        )
    print("\nGREEN" if not report["gaps"] else
          "\n(reported — re-run with the gaps resolved for a clean scan)")


if __name__ == "__main__":
    main()
