#!/usr/bin/env python3
"""Detect complex Looker→Sigma grain hazards before a workbook is posted.

The checks are intentionally conservative and evidence-based:
* relationships/joins whose two endpoints are already grouped/windowed SQL;
* additive consumption of rate/ratio/average-like columns from grouped SQL;
* rolling/window calculations without a date grain and stable sort.

Findings are written both to ``modeling-hazards.json`` and to the shared
``agg-semantics.json`` contract consumed by assert-phase6-ran.rb gate 19.
"""

import argparse
import datetime as dt
import json
import os
import re
import sys


RESOLUTIONS = {"reaggregated", "n/a", "faithful-to-source"}
NON_ADDITIVE_NAME = re.compile(
    r"(?:rate|ratio|pct|percent|average|avg|completion|stability|stddev|variance|coefficient)",
    re.I,
)
WINDOW_FN = re.compile(
    r"\b(?:running_total|cumulative(?:sum)?|moving_?(?:avg|average|sum|stddev|variance)|rolling|offset|lag)\s*\(",
    re.I,
)
DATE_NAME = re.compile(r"(?:date|day|week|month|quarter|year|period|time)", re.I)


def read_json(path, default=None):
    if not path or not os.path.exists(path):
        return default
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def elements(spec):
    if not isinstance(spec, dict):
        return []
    doc = spec.get("document") or spec
    flat = doc.get("elements")
    if isinstance(flat, list):
        return flat
    return [
        element
        for page in (doc.get("pages") or [])
        for element in (page.get("elements") or [])
    ]


def is_preaggregated(element):
    source = element.get("source") or {}
    sql = source.get("statement") if source.get("kind") == "sql" else ""
    return bool(re.search(r"\bGROUP\s+BY\b|\bOVER\s*\(", sql or "", re.I))


def preserve_resolutions(entries, prior):
    old = (prior or {}).get("entries") if isinstance(prior, dict) else prior
    old = old if isinstance(old, list) else []
    for entry in entries:
        match = next(
            (
                candidate
                for candidate in old
                if all(
                    candidate.get(key) == entry.get(key)
                    for key in ("class", "consumer", "preagg", "formula")
                )
            ),
            None,
        )
        if match and isinstance(match.get("resolution"), dict):
            entry["resolution"] = match["resolution"]
    return entries


def derive(contract, dm_spec, wb_spec):
    hazards = []
    dm_elements = elements(dm_spec)
    dm_by_id = {element.get("id"): element for element in dm_elements if element.get("id")}
    preagg_ids = {element["id"] for element in dm_elements if element.get("id") and is_preaggregated(element)}

    for source in dm_elements:
        if source.get("id") not in preagg_ids:
            continue
        for relationship in source.get("relationships") or []:
            target = dm_by_id.get(relationship.get("targetElementId"))
            if not target or target.get("id") not in preagg_ids:
                continue
            hazards.append(
                {
                    "class": "additive-over-preagg",
                    "hazard": "preaggregated-relationship",
                    "consumer": relationship.get("name") or source.get("name"),
                    "preagg": f"{source.get('name')} → {target.get('name')}",
                    "context": "relationship joins two already-grouped/windowed SQL elements",
                    "formula": json.dumps(relationship.get("keys") or [], sort_keys=True),
                    "detail": (
                        "Sigma accepted this shape in dashboard 7405 but returned NULL related "
                        "columns. Rebuild at one explicit grain or use one Custom SQL window query."
                    ),
                    "recommendation": "custom-sql-handoff",
                }
            )
        for join in source.get("joins") or []:
            target = dm_by_id.get(join.get("targetElementId") or (join.get("source") or {}).get("elementId"))
            if target and target.get("id") in preagg_ids:
                hazards.append(
                    {
                        "class": "additive-over-preagg",
                        "hazard": "preaggregated-join",
                        "consumer": join.get("name") or source.get("name"),
                        "preagg": f"{source.get('name')} ⋈ {target.get('name')}",
                        "context": "physical join combines two already-grouped/windowed SQL elements",
                        "formula": json.dumps(join, sort_keys=True),
                        "detail": (
                            "This shape timed out in dashboard 7405 independent of row count. "
                            "Prefer one warehouse query at the declared grain."
                        ),
                        "recommendation": "custom-sql-handoff",
                    }
                )

    wb_elements = elements(wb_spec)
    wb_by_id = {element.get("id"): element for element in wb_elements if element.get("id")}

    def root_dm_id(element):
        seen = set()
        current = element
        while isinstance(current, dict) and current.get("id") not in seen:
            if current.get("id"):
                seen.add(current["id"])
            source = current.get("source") or {}
            if source.get("kind") == "data-model":
                return source.get("elementId")
            current = wb_by_id.get(source.get("elementId"))
        return None

    for element in wb_elements:
        dm_id = root_dm_id(element)
        if dm_id not in preagg_ids:
            continue
        for column in element.get("columns") or []:
            formula = str(column.get("formula") or "")
            aggregate = re.match(r"\s*(Sum|Avg|Average)\s*\(\s*\[([^\]]+)\]\s*\)", formula, re.I)
            if not aggregate:
                continue
            referenced_name = aggregate.group(2).split("/")[-1]
            if not NON_ADDITIVE_NAME.search(column.get("name") or referenced_name):
                continue
            hazards.append(
                {
                    "class": "additive-over-preagg",
                    "hazard": "broadcast-additive",
                    "consumer": f"{element.get('name')}: {column.get('name') or referenced_name}",
                    "preagg": referenced_name,
                    "context": "Sum/Avg consumes a non-additive value from grouped SQL",
                    "formula": formula,
                    "detail": (
                        "The grouped value can be broadcast over hidden detail rows; Sum multiplies "
                        "identical copies. Prove the grain and use Max only when copies are identical."
                    ),
                    "recommendation": "max-at-own-grain-or-reaggregate",
                }
            )

    for element in (contract or {}).get("elements") or []:
        dynamic = element.get("dynamicFields") or []
        expressions = [
            str(field.get("expression") or field.get("calculation") or "")
            for field in dynamic
            if isinstance(field, dict)
        ]
        expressions += [
            str(field)
            for field in (element.get("fields") or [])
            if isinstance(field, str) and WINDOW_FN.search(field)
        ]
        for expression in expressions:
            if not WINDOW_FN.search(expression):
                continue
            fields = element.get("fields") or []
            sorts = element.get("sorts") or []
            date_fields = [field for field in fields if DATE_NAME.search(str(field))]
            sorted_date = any(
                any(str(sort).split()[0] == date_field for sort in sorts)
                for date_field in date_fields
            )
            if date_fields and sorted_date:
                continue
            hazards.append(
                {
                    "class": "additive-over-preagg",
                    "hazard": "unsafe-window-grain",
                    "consumer": element.get("name"),
                    "preagg": expression,
                    "context": "rolling/window calculation lacks a stable sorted date grain",
                    "formula": expression,
                    "detail": (
                        "Moving and cumulative functions are row-order dependent. Add a date group, "
                        "ascending sort, and explicit partition grain or push the window into SQL."
                    ),
                    "recommendation": "declare-grain-sort-partition",
                }
            )
    return hazards


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--contract")
    parser.add_argument("--dm-spec")
    parser.add_argument("--wb-spec")
    parser.add_argument("--resolve", type=int)
    parser.add_argument("--how", choices=sorted(RESOLUTIONS))
    parser.add_argument("--reason")
    args = parser.parse_args()

    os.makedirs(args.workdir, exist_ok=True)
    hazard_path = os.path.join(args.workdir, "modeling-hazards.json")
    agg_path = os.path.join(args.workdir, "agg-semantics.json")
    if args.resolve is not None:
        if not args.how or not (args.reason or "").strip():
            parser.error("--resolve requires --how and a non-empty --reason")
        document = read_json(agg_path, {"version": 1, "entries": []})
        entries = document.get("entries") or []
        if args.resolve < 0 or args.resolve >= len(entries):
            parser.error(f"no aggregation entry at index {args.resolve}")
        entries[args.resolve]["resolution"] = {
            "how": args.how,
            "reason": args.reason.strip(),
            "recorded_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        }
        with open(agg_path, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2)
        print(f"resolved aggregation hazard #{args.resolve}: {args.how}")
        return 0

    contract_path = args.contract or os.path.join(args.workdir, "dashboard.contract.json")
    dm_path = args.dm_spec or os.path.join(args.workdir, "dm-spec.json")
    wb_path = args.wb_spec or os.path.join(args.workdir, "wb-spec.json")
    hazards = derive(
        read_json(contract_path, {}),
        read_json(dm_path, {}),
        read_json(wb_path, {}),
    )
    hazards = preserve_resolutions(hazards, read_json(agg_path, {}))
    document = {
        "version": 1,
        "source": "looker",
        "entries": hazards,
    }
    with open(hazard_path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
    with open(agg_path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)

    unresolved = [entry for entry in hazards if not isinstance(entry.get("resolution"), dict)]
    for index, entry in enumerate(hazards):
        state = "BLOCK" if entry in unresolved else "ok"
        print(f"{state:5} #{index} [{entry['hazard']}] {entry['consumer']}")
    print(f"modeling hazards: {len(hazards)} total, {len(unresolved)} unresolved")
    return 2 if unresolved else 0


if __name__ == "__main__":
    sys.exit(main())
