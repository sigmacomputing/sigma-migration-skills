#!/usr/bin/env python3
"""Opt-in Snowflake DAX-context workbook builder using converted DM sources.

This is deliberately fail-closed, not a generic DAX interpreter. See the
compiler's supported expression grammar before using it for another report.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).parent / "lib"))
from pbi_semantic_sql import Compiler, Unsupported, expression, ident
from pbi_semantic_layout import apply_layout


def uid(text):
    return "pbi-" + hashlib.sha256(text.encode()).hexdigest()[:16]


def field(qr):
    if "." not in qr:
        raise Unsupported("Unqualified report field " + qr)
    return tuple(qr.split(".", 1))


def normalized(text):
    return re.sub(r"[_\s]", "", text).casefold()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--signals", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--master-map", required=True)
    ap.add_argument("--connection", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument(
        "--warehouse-type",
        choices=["snowflake"],
        required=True,
        help="This constrained compiler currently supports Snowflake only",
    )
    ap.add_argument(
        "--reviewed-no-rls-cls",
        action="store_true",
        required=True,
        help="Confirm converted source elements have no RLS/CLS; SQL element references are not a security bypass",
    )
    ap.add_argument(
        "--accept-ui-adaptations",
        action="store_true",
        help="Explicitly accept level dropdowns, drill switcher and initially expanded pivots",
    )
    args = ap.parse_args()
    model = json.loads(Path(args.model).read_text())
    model = model.get("model", model)
    signals = json.loads(Path(args.signals).read_text())
    mmap = json.loads(Path(args.master_map).read_text())
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    sources, elements, pages, controls, mapped = {}, [], [], {}, []
    security = model.get("roles") or []
    if security:
        raise Unsupported(
            "SQL context path requires explicit RLS/CLS review before use"
        )
    for table in model["tables"]:
        name = table["name"]
        candidates = [
            m
            for key, m in mmap["masters"].items()
            if normalized(key) == normalized(name)
        ]
        if len(candidates) != 1:
            raise Unsupported("Cannot identify converted base element for " + name)
        master = candidates[0]
        srcid = uid("source/" + name)
        srcname = "Source " + name
        columns = {}
        for column in table["columns"]:
            matches = [
                c
                for c in master["columns"]
                if normalized(c["name"]) == normalized(column["name"])
            ]
            if len(matches) != 1:
                raise Unsupported(
                    "Cannot resolve source column " + name + "." + column["name"]
                )
            columns[column["name"]] = matches[0]["name"]
        sources[name] = {"name": srcname, "columns": columns, "id": srcid}
        elements.append(
            {
                "id": srcid,
                "kind": "table",
                "name": srcname,
                "source": {
                    "kind": "data-model",
                    "dataModelId": master["data_model"],
                    "elementId": master["element_id"],
                },
                "columns": master["columns"],
            }
        )
    compiler = Compiler(model, sources)
    column_types = {
        (t["name"], c["name"]): c.get("dataType")
        for t in model["tables"]
        for c in t["columns"]
    }
    measure_refs = {
        t["name"] + "." + m["name"]
        for t in model["tables"]
        for m in t.get("measures", [])
    }
    # Build all controls before any SQL, preserving one state per sync group.
    page_filters = {p["page_id"]: [] for p in signals["pages"]}
    for page in signals["pages"]:
        pid = page["page_id"]
        if page.get("interactions"):
            raise Unsupported(
                "Edited visual interactions require a reviewed context mapping"
            )
        for v in page["visuals"]:
            if v["visual_type"] != "slicer":
                continue
            refs = list(
                dict.fromkeys(q for values in v["bindings"].values() for q in values)
            )
            if not refs:
                raise Unsupported("Slicer has no fields")
            state = v.get("slicer_state") or {}
            selected = state.get("selection") or {}
            saved_filter = state.get("has_saved_filter") or (
                selected and selected.get("predicate") != "none"
            )
            if saved_filter and (
                len(refs) != 1
                or selected.get("type") != "list"
                or selected.get("unsupported")
                or selected.get("mode") == "exclude"
            ):
                raise Unsupported("Saved slicer filter requires an explicit mapping")
            if len(refs) > 1 and not args.accept_ui_adaptations:
                raise Unsupported(
                    "Hierarchy dropdown adaptation requires --accept-ui-adaptations"
                )
            for i, qr in enumerate(refs):
                table, col = field(qr)
                key = (v.get("sync_group") or pid + "/" + v["visual_id"]) + "/" + qr
                ctl = controls.get(key)
                eid = uid(pid + "/" + v["visual_id"] + "/" + str(i))
                is_date = column_types.get((table, col)) == "dateTime"
                is_number_range = state.get("mode") == "Between" and not is_date
                kind = (
                    "date-range"
                    if is_date
                    else "number-range" if is_number_range else "list"
                )
                defaults = selected.get("values", []) if len(refs) == 1 else []
                if kind != "list" and saved_filter:
                    raise Unsupported(
                        "Saved range slicer filter requires an explicit mapping"
                    )
                if ctl:
                    if ctl["kind"] != kind or ctl["defaults"] != defaults:
                        raise Unsupported(
                            "Synced slicers disagree on type or saved defaults"
                        )
                    element = {
                        "id": eid,
                        "kind": "control",
                        "controlId": ctl["control"],
                        "controlType": "synced",
                    }
                else:
                    handle = "ctl" + hashlib.sha256(key.encode()).hexdigest()[:12]
                    ctl = {
                        "field": (table, col),
                        "control": handle,
                        "pages": [],
                        "kind": kind,
                        "defaults": defaults,
                    }
                    element = {
                        "id": eid,
                        "kind": "control",
                        "controlId": handle,
                        "name": col if len(refs) > 1 else v.get("title") or col,
                        "controlType": kind,
                    }
                    if kind == "list":
                        source = sources[table]
                        master_el = next(e for e in elements if e["id"] == source["id"])
                        cid = next(
                            c["id"]
                            for c in master_el["columns"]
                            if c["name"] == source["columns"][col]
                        )
                        element.update(
                            mode="include",
                            selectionMode="multiple",
                            values=defaults,
                            source={
                                "kind": "source",
                                "source": {"kind": "table", "elementId": source["id"]},
                                "columnId": cid,
                            },
                        )
                    else:
                        ctl["range"] = "date" if is_date else "number"
                        element["includeNulls"] = "when-no-value-is-selected"
                        if is_date:
                            element["mode"] = "between"
                    controls[key] = ctl
                ctl["pages"].append(pid)
                page_filters[pid].append(ctl)
                elements.append(element)
            mapped.append(
                {
                    "page": pid,
                    "visual": v["visual_id"],
                    "elementIds": [
                        uid(pid + "/" + v["visual_id"] + "/" + str(i))
                        for i in range(len(refs))
                    ],
                    "adaptation": (
                        "hierarchy represented by level dropdowns"
                        if len(refs) > 1
                        else None
                    ),
                }
            )

    def static_filters(items):
        result = []
        for item in items or []:
            if item.get("predicate") == "none":
                continue
            if item["type"] != "list" or item.get("unsupported"):
                raise Unsupported("Unsupported static filter " + str(item))
            result.append(
                {
                    "field": field(item["target"]),
                    "values": item["values"],
                    "exclude": item.get("mode") == "exclude",
                }
            )
        return result

    report_filters = static_filters(signals.get("filters"))
    for page in signals["pages"]:
        pid = page["page_id"]
        pages.append({"id": uid(pid), "name": page["page_title"]})
        for v in page["visuals"]:
            if v["visual_type"] == "slicer":
                continue
            if v.get("sigma_kind") not in (
                "kpi",
                "bar",
                "line",
                "table",
                "pivot-table",
            ):
                raise Unsupported("Unsupported visual " + v["visual_type"])
            if (
                v["sigma_kind"] == "pivot-table" or v.get("drill")
            ) and not args.accept_ui_adaptations:
                raise Unsupported(
                    "Pivot/drill adaptation requires --accept-ui-adaptations"
                )
            bindings = {k: list(values) for k, values in v["bindings"].items()}
            if (
                v["sigma_kind"] == "pivot-table"
                and (v.get("drill") or {}).get("role") == "Rows"
            ):
                bindings["Rows"] = v["drill"]["levels"]
            all_refs = list(
                dict.fromkeys(q for values in bindings.values() for q in values)
            )
            measures = [q.split(".", 1)[1] for q in all_refs if q in measure_refs]
            if v["sigma_kind"] == "pivot-table":
                row_refs = [q for q in bindings.get("Rows", []) if q not in measure_refs]
                column_refs = [
                    q for q in bindings.get("Columns", []) if q not in measure_refs
                ]
                groups = [field(q) for q in row_refs + column_refs]
                pivot_row_count = len(row_refs)
            else:
                groups = [field(q) for q in all_refs if q not in measure_refs]
            if v["sigma_kind"] == "kpi" and (len(measures) != 1 or groups):
                raise Unsupported("KPI must bind exactly one explicit measure")
            if v["sigma_kind"] in ("bar", "line") and (
                len(groups) != 1 or not measures
            ):
                raise Unsupported(
                    "Chart requires one dimension and explicit measures; series and facets need another implementation"
                )
            if v["sigma_kind"] == "pivot-table" and any(
                not compiler.additive(m, groups) for m in measures
            ):
                raise Unsupported(
                    "Non-additive pivot totals require measure re-evaluation at subtotal grain"
                )
            filters = (
                report_filters + static_filters(page.get("filters")) + page_filters[pid]
            )
            visual_filters = [
                f for f in v.get("filters") or [] if f.get("predicate") != "none"
            ]
            top = [f for f in visual_filters if f["type"] == "top-n"]
            filters += static_filters(
                [f for f in visual_filters if f["type"] != "top-n"]
            )
            eid = uid(pid + "/" + v["visual_id"])
            # Explicit switcher restores both drill directions. It chooses a
            # known grouping expression, never interpolates an SQL identifier.
            drill = v.get("drill") if v.get("sigma_kind") == "bar" else None
            drill_control = None
            group_variants = [groups]
            if drill and len(drill["levels"]) > 1:
                if measures == []:
                    raise Unsupported("Drill chart needs a measure")
                drill_control = "drill" + hashlib.sha256(eid.encode()).hexdigest()[:12]
                levels = drill["levels"]
                group_variants = [[field(q)] for q in levels]
                control = {
                    "id": eid + "-drill",
                    "kind": "control",
                    "controlType": "list",
                    "controlId": drill_control,
                    "name": "Drill level",
                    "mode": "include",
                    "selectionMode": "single",
                    "value": drill["active"],
                }
                helper = {
                    "id": eid + "-levels",
                    "kind": "table",
                    "name": "Levels " + v["visual_id"],
                    "source": {
                        "kind": "sql",
                        "connectionId": args.connection,
                        "statement": " UNION ALL ".join(
                            "SELECT '" + q.replace("'", "''") + "' AS level"
                            for q in levels
                        ),
                    },
                    "columns": [
                        {
                            "id": eid + "-level",
                            "name": "Level",
                            "formula": "[Custom SQL/LEVEL]",
                        }
                    ],
                }
                elements.append(helper)
                control["source"] = {
                    "kind": "source",
                    "source": {"kind": "table", "elementId": helper["id"]},
                    "columnId": eid + "-level",
                }
                elements.append(control)
            queries = []
            for variant in group_variants:
                if measures:
                    query = compiler.query(variant, measures, filters)
                else:
                    tables = {t for t, c in variant}
                    if len(tables) != 1:
                        raise Unsupported("Detail table spanning multiple facts")
                    table = next(iter(tables))
                    source, aliases = compiler.joins(table)
                    query = (
                        "SELECT "
                        + ",".join(
                            compiler.value_ref(t, c, aliases)
                            + " AS "
                            + ident("g" + str(i))
                            for i, (t, c) in enumerate(variant)
                        )
                        + " FROM "
                        + source
                        + " WHERE "
                        + (
                            " AND ".join(compiler.predicates(filters, aliases))
                            or "TRUE"
                        )
                    )
                if drill_control:
                    query = (
                        'SELECT TO_VARCHAR("g0") AS "g0",'
                        + ",".join(ident("v" + str(i)) for i in range(len(measures)))
                        + " FROM ("
                        + query
                        + ") WHERE {{#formula ["
                        + drill_control
                        + "]}}="
                        + "'"
                        + (variant[0][0] + "." + variant[0][1]).replace("'", "''")
                        + "'"
                    )
                queries.append(query)
            query = (
                " UNION ALL ".join("(" + q + ")" for q in queries)
                if len(queries) > 1
                else queries[0]
            )
            cols = []
            for i, (t, c) in enumerate(groups):
                col = {
                    "id": eid + "-g" + str(i),
                    "name": c,
                    "formula": "[Custom SQL/g" + str(i) + "]",
                }
                if column_types.get((t, c)) == "dateTime" and not drill_control:
                    source_col = next(
                        x for x in compiler.tables[t]["columns"] if x["name"] == c
                    )
                    fmt = (
                        "%Y-%m-%d %H:%M:%S"
                        if "h" in source_col.get("formatString", "").lower()
                        else "%Y-%m-%d"
                    )
                    col["format"] = {"kind": "datetime", "formatString": fmt}
                cols.append(col)
            if drill_control:
                cols = [
                    {"id": eid + "-g0", "name": "Period", "formula": "[Custom SQL/g0]"}
                ]
            for i, m in enumerate(measures):
                formula = "Sum([Custom SQL/v" + str(i) + "])"
                # One SQL row per visual group: Sum is identity at that grain.
                # Non-additive pivot rollups are rejected above instead of guessed.
                if v["sigma_kind"] == "kpi":
                    formula = "Max([Custom SQL/v" + str(i) + "])"
                fmt = (
                    ".1%"
                    if "%"
                    in next(
                        (
                            x.get("formatString", "")
                            for t in model["tables"]
                            for x in t.get("measures", [])
                            if x["name"] == m
                        ),
                        "",
                    )
                    else ",.2f"
                )
                cols.append(
                    {
                        "id": eid + "-v" + str(i),
                        "name": m,
                        "formula": formula,
                        "format": {"kind": "number", "formatString": fmt},
                    }
                )
            element = {
                "id": eid,
                "name": v.get("title") or v["visual_id"],
                "kind": {
                    "kpi": "kpi-chart",
                    "bar": "bar-chart",
                    "line": "line-chart",
                    "table": "table",
                    "pivot-table": "pivot-table",
                }[v["sigma_kind"]],
                "source": {
                    "kind": "sql",
                    "connectionId": args.connection,
                    "statement": query,
                },
                "columns": cols,
            }
            group_ids = [c["id"] for c in cols[: len(groups)]]
            value_ids = [eid + "-v" + str(i) for i in range(len(measures))]
            if v["sigma_kind"] == "kpi":
                element.update(
                    value={"columnId": value_ids[0]},
                    layout={"anchor": "center", "titleOrient": "top"},
                )
            elif v["sigma_kind"] in ("bar", "line"):
                element.update(
                    xAxis={"columnId": group_ids[0]}, yAxis={"columnIds": value_ids}
                )
                if v.get("orientation") == "horizontal":
                    element["orientation"] = "horizontal"
            elif v["sigma_kind"] == "pivot-table":
                element.update(
                    rowsBy=[
                        {"columnId": c} for c in group_ids[:pivot_row_count]
                    ],
                    columnsBy=[
                        {"columnId": c} for c in group_ids[pivot_row_count:]
                    ],
                    values=value_ids,
                    totals={"showGrandTotals": "shown", "totalPosition": "last"},
                )
                formats = []
                for cf in v.get("conditional_formats") or []:
                    measure = cf["target"].split(".", 1)[-1]
                    if cf["mode"] != "rules" or measure not in measures:
                        raise Unsupported(
                            "Conditional formatting shape requires a reviewed mapping"
                        )
                    for rule in cf["rules"]:
                        comparisons = rule["comparisons"]
                        if (
                            len(comparisons) != 1
                            or comparisons[0]["driver"] != cf["target"]
                        ):
                            raise Unsupported(
                                "Conditional formatting needs one same-measure comparison"
                            )
                        comparison = comparisons[0]
                        formats.append(
                            {
                                "type": "single",
                                "columnIds": [value_ids[measures.index(measure)]],
                                "condition": comparison["op"],
                                "value": float(comparison["value"]),
                                "style": {"backgroundColor": rule["color"]},
                                "includeValues": True,
                                "includeSubtotals": True,
                                "includeGrandTotals": True,
                            }
                        )
                    if cf.get("default"):
                        formats.append(
                            {
                                "type": "single",
                                "columnIds": [value_ids[measures.index(measure)]],
                                "condition": "IsNotNull",
                                "style": {"backgroundColor": cf["default"]},
                                "includeValues": True,
                                "includeSubtotals": True,
                                "includeGrandTotals": True,
                            }
                        )
                if formats:
                    element["conditionalFormats"] = formats
            elif measures:
                element["groupings"] = [
                    {
                        "id": eid + "-group",
                        "groupBy": group_ids,
                        "calculations": value_ids,
                    }
                ]
            if top:
                if len(top) != 1:
                    raise Unsupported("Multiple Top-N filters")
                rank = top[0]["rankBy"].split(".", 1)[-1]
                if rank not in measures:
                    raise Unsupported("Top-N ranking measure not projected")
                element["filters"] = [
                    {
                        "id": eid + "-top",
                        "kind": "top-n",
                        "columnId": value_ids[measures.index(rank)],
                        "rankingFunction": "rank",
                        "mode": (
                            "top-n" if top[0]["direction"] == "desc" else "bottom-n"
                        ),
                        "rowCount": top[0]["n"],
                    }
                ]
            elements.append(element)
            mapped.append(
                {
                    "page": pid,
                    "visual": v["visual_id"],
                    "elementIds": [eid],
                    "groups": groups,
                    "measures": measures,
                }
            )
    data_id = uid("data")
    pages.insert(0, {"id": data_id, "name": "Data", "visibility": "hidden"})
    spec = {
        "name": args.name,
        "folderId": args.folder_id,
        "document": {
            "schemaVersion": 1,
            "kind": "workbook",
            "pages": pages,
            "elements": elements,
        },
    }
    apply_layout(spec["document"], signals, mapped, data_id)
    out.write_text(json.dumps(spec, indent=2))
    (out.parent / "semantic-visual-map.json").write_text(json.dumps(mapped, indent=2))
    (out.parent / "semantic-controls.json").write_text(json.dumps(controls, indent=2))
    scope = []
    for e in elements:
        if e.get("kind") != "control" or e.get("controlType") == "synced":
            continue
        handle = e["controlId"]
        targets = [
            v["id"]
            for v in elements
            if v.get("source", {}).get("kind") == "sql"
            and "[" + handle + "]" in v["source"]["statement"]
        ]
        scope.append(
            {
                "controlId": handle,
                "sourceName": e.get("name", handle),
                "scope": targets,
                "reason": "DAX context controls only its modeled page/fact; explicit REMOVEFILTERS and replacement predicates are excluded.",
            }
        )
    (out.parent / "control-scope.json").write_text(
        json.dumps(
            {
                "version": 1,
                "source": "powerbi-semantic-context",
                "sourceFilterSignals": sum(
                    v["visual_type"] == "slicer"
                    for p in signals["pages"]
                    for v in p["visuals"]
                ),
                "controls": scope,
            },
            indent=2,
        )
    )
    print(
        f"Built {len(mapped)} source visuals on {len(pages)-1} pages; constrained SQL context path"
    )


if __name__ == "__main__":
    main()
