#!/usr/bin/env python3
"""Pure-Python Tableau datasource classification and extract-manifest remapping."""

from __future__ import annotations

import argparse
import json
import os
import re
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from typing import Any

EMBEDDED_CLASSES = {
    "excel-direct",
    "textscan",
    "hyper",
    "ogrdirect",
    "csv",
    "msexcel",
}
NONDATA_CLASSES = {"mapbox", "tableau-map", "wms", "wms-server"}
WRAPPER_CLASSES = {"federated"}
PUBLISHED_CLASSES = {"sqlproxy"}


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _descendants(node: ET.Element, name: str):
    return (item for item in node.iter() if _local_name(item.tag) == name)


def _real_relations(connection: ET.Element) -> list[dict]:
    relations = []
    for relation in _descendants(connection, "relation"):
        relation_type = str(relation.get("type") or "table").lower()
        table = str(relation.get("table") or "")
        text = str(relation.text or "").strip()
        real = (
            relation_type == "text"
            and bool(text)
            or relation_type == "table"
            and bool(table)
            and table not in {"[sqlproxy]", "[Extract].[Extract]"}
        )
        relations.append(
            {
                "type": relation_type,
                "table": table or None,
                "has_text": bool(text),
                "real": real,
            }
        )
    return relations


def classify_datasource(datasource: ET.Element, index: int) -> dict:
    """Classify one top-level datasource without consulting any sibling."""
    name = str(datasource.get("name") or datasource.get("caption") or f"datasource-{index}")
    caption = str(datasource.get("caption") or name)
    connections = list(_descendants(datasource, "connection"))
    classes = [
        str(connection.get("class") or "").lower()
        for connection in connections
        if connection.get("class")
    ]
    ignored = sorted(
        {value for value in classes if value in NONDATA_CLASSES | WRAPPER_CLASSES}
    )
    effective = [
        value
        for value in classes
        if value not in NONDATA_CLASSES and value not in WRAPPER_CLASSES
    ]
    top_connection = next(
        (item for item in datasource if _local_name(item.tag) == "connection"),
        connections[0] if connections else None,
    )
    top_class = str(top_connection.get("class") or "").lower() if top_connection is not None else ""
    relations = _real_relations(top_connection) if top_connection is not None else []
    has_real_relation = any(item["real"] for item in relations)
    embedded = sorted({value for value in effective if value in EMBEDDED_CLASSES})
    published = sorted({value for value in effective if value in PUBLISHED_CLASSES})
    live = sorted(
        {
            value
            for value in effective
            if value not in EMBEDDED_CLASSES and value not in PUBLISHED_CLASSES
        }
    )

    is_parameter = name.lower().startswith("parameters") or caption.lower().startswith(
        "parameters"
    )
    if is_parameter or (not effective and classes and set(classes) <= NONDATA_CLASSES):
        classification = "ignored"
    elif top_class == "sqlproxy":
        classification = "published-sqlproxy"
    elif embedded and not live and not published:
        classification = "embedded-file-extract"
    elif live and not embedded and not published:
        classification = "live-warehouse"
    elif sum(bool(group) for group in (embedded, live, published)) > 1:
        classification = "mixed"
    else:
        classification = "unsupported"

    hyper_files = sorted(
        {
            os.path.basename(str(connection.get("dbname") or ""))
            for connection in connections
            if str(connection.get("dbname") or "").lower().endswith(".hyper")
        }
    )
    return {
        "index": index,
        "name": name,
        "caption": caption,
        "classification": classification,
        "connection_classes": classes,
        "effective_classes": effective,
        "ignored_classes": ignored,
        "embedded_classes": embedded,
        "live_classes": live,
        "published_classes": published,
        "hyper_files": hyper_files,
        "relations": relations,
        "evidence": {
            "top_connection_class": top_class or None,
            "has_real_relation": has_real_relation,
            "dbname_values": [
                connection.get("dbname")
                for connection in connections
                if connection.get("dbname")
            ],
            "server_values": [
                connection.get("server")
                for connection in connections
                if connection.get("server")
            ],
        },
    }


def classify_workbook(path: str | Path) -> dict:
    root = ET.parse(path).getroot()
    parent = next(
        (item for item in root.iter() if _local_name(item.tag) == "datasources"),
        None,
    )
    datasources = []
    if parent is not None:
        datasources = [
            classify_datasource(item, index)
            for index, item in enumerate(parent, 1)
            if _local_name(item.tag) == "datasource"
        ]
    active = [
        item["classification"]
        for item in datasources
        if item["classification"] != "ignored"
    ]
    unique = set(active)
    if not active:
        classification = "unsupported"
    elif len(unique) == 1:
        classification = active[0]
    else:
        classification = "mixed"
    counts = Counter(active)
    return {
        "contract_version": 1,
        "classification": classification,
        "datasources": datasources,
        "summary": {
            "total": len(datasources),
            "active": len(active),
            "ignored": len(datasources) - len(active),
            "by_classification": dict(sorted(counts.items())),
        },
    }


def embedded_datasources(classification: dict) -> list[dict]:
    """Include embedded members of datasource- or workbook-level mixed shapes."""
    return [
        item
        for item in classification.get("datasources") or []
        if item.get("classification") == "embedded-file-extract"
        or item.get("embedded_classes")
    ]


def _manifest_matches(datasource: dict, entry: dict) -> bool:
    identity = {
        str(datasource.get("name") or "").strip().casefold(),
        str(datasource.get("caption") or "").strip().casefold(),
    }
    identity.discard("")
    entry_identity = {
        str(entry.get("datasource") or "").strip().casefold(),
        str(entry.get("caption") or "").strip().casefold(),
    }
    entry_identity.discard("")
    if identity & entry_identity:
        return True
    hyper = str(entry.get("hyper") or "").strip().casefold()
    return bool(
        hyper
        and hyper
        in {
            str(value).strip().casefold()
            for value in datasource.get("hyper_files") or []
        }
    )


def validate_manifest_coverage(classification: dict, manifest: Any) -> dict:
    entries = [item for item in manifest or [] if isinstance(item, dict)] if isinstance(manifest, list) else []
    required = embedded_datasources(classification)
    coverage = []
    for datasource in required:
        matched = [
            entry
            for entry in entries
            if _manifest_matches(datasource, entry)
            and str(entry.get("sf_table") or "").strip()
            and isinstance(entry.get("columns"), dict)
            and bool(entry["columns"])
        ]
        coverage.append(
            {
                "datasource": datasource.get("name"),
                "caption": datasource.get("caption"),
                "covered": bool(matched),
                "tables": sorted(
                    str(entry["sf_table"]) for entry in matched
                ),
            }
        )
    return {
        "valid": bool(entries) and all(item["covered"] for item in coverage),
        "manifest_entries": len(entries),
        "embedded_datasources": len(required),
        "coverage": coverage,
        "missing_datasources": [
            item["datasource"] for item in coverage if not item["covered"]
        ],
    }


def _normalize(value: Any) -> str:
    return re.sub(r"[^0-9A-Za-z]", "", str(value or "")).upper()


def _elements(model: dict) -> list[dict]:
    top = model.get("elements")
    if isinstance(top, list):
        return [item for item in top if isinstance(item, dict)]
    return [
        item
        for page in model.get("pages") or []
        if isinstance(page, dict)
        for item in page.get("elements") or []
        if isinstance(item, dict)
    ]


def _rewrite_formulas(
    element: dict,
    old_values: list[str],
    new_value: str,
    column_mapping: dict[str, str] | None = None,
) -> None:
    for item in list(element.get("columns") or []) + list(element.get("metrics") or []):
        formula = item.get("formula") if isinstance(item, dict) else None
        if not isinstance(formula, str):
            continue
        for old in old_values:
            if old:
                formula = re.sub(
                    rf"\[{re.escape(old)}/", f"[{new_value}/", formula
                )
        for original, landed in (column_mapping or {}).items():
            formula = formula.replace(
                f"[{new_value}/{original}]",
                f"[{new_value}/{landed}]",
            )
        item["formula"] = formula


def _rewrite_single_table_sql(statement: str, entry: dict) -> str | None:
    from_count = len(re.findall(r"\bFROM\b", statement, re.I))
    join_count = len(re.findall(r"\bJOIN\b", statement, re.I))
    from_match = re.search(
        r"\bFROM\b(.*?)(?=\b(?:WHERE|GROUP\s+BY|ORDER\s+BY|HAVING|QUALIFY|LIMIT|UNION)\b|;|\Z)",
        statement,
        re.I | re.S,
    )
    from_clause = re.sub(r"\([^()]*\)", "", from_match.group(1)) if from_match else ""
    if from_count + join_count > 1 or "," in from_clause:
        return None
    ident = r'(?:"[^"]+"|\[[^\]]+\]|\'[^\']+\'|[A-Za-z0-9_$#]+)'
    rewritten = re.sub(
        rf"\bFROM\s+{ident}(?:\s*\.\s*{ident})*",
        f"FROM {entry['sf_table']}",
        statement,
        count=1,
        flags=re.I,
    )
    for original, landed in (entry.get("columns") or {}).items():
        if original == landed:
            continue
        rewritten = rewritten.replace(f'"{original}"', str(landed))
        rewritten = rewritten.replace(f"[{original}]", str(landed))
    return rewritten


def remap_from_manifest(model: dict, manifest: list[dict]) -> dict:
    """Port the Ruby manifest mapper's conservative overlap attribution."""
    entries = [
        entry
        for entry in manifest
        if isinstance(entry, dict)
        and entry.get("sf_table")
        and isinstance(entry.get("columns"), dict)
        and entry["columns"]
    ]
    warehouse_elements = [
        element
        for element in _elements(model)
        if (element.get("source") or {}).get("kind") == "warehouse-table"
    ]
    scored = []
    for element_index, element in enumerate(warehouse_elements):
        captions = {
            _normalize(column.get("name") or column.get("label"))
            for column in element.get("columns") or []
            if isinstance(column, dict)
        }
        captions.discard("")
        for entry_index, entry in enumerate(entries):
            keys = {_normalize(value) for value in entry["columns"]}
            overlap = len(captions & keys)
            if overlap:
                scored.append(
                    (overlap, element_index, entry_index, element, entry)
                )
    scored.sort(key=lambda row: (-row[0], row[1], row[2]))

    claimed_elements: set[int] = set()
    claimed_entries: set[int] = set()
    mappings = []
    colmap: dict[str, str] = {}
    for overlap, element_index, entry_index, element, entry in scored:
        if element_index in claimed_elements or entry_index in claimed_entries:
            continue
        path = [part for part in str(entry["sf_table"]).split(".") if part]
        if not path:
            continue
        source = element.setdefault("source", {})
        old_last = str((source.get("path") or [""])[-1])
        old_name = str(element.get("name") or "")
        new_last = path[-1]
        source["path"] = path
        element["name"] = new_last
        _rewrite_formulas(element, [old_last], new_last, entry["columns"])
        mappings.append(
            {
                "element_id": element.get("id"),
                "old_name": old_name,
                "old_table": old_last,
                "new_name": new_last,
                "sf_table": entry["sf_table"],
                "datasource": entry.get("datasource"),
                "manifest_entry_index": entry_index,
                "manifest_entry": entry,
                "overlap": overlap,
                "column_count": len(element.get("columns") or []),
            }
        )
        colmap.update(entry["columns"])
        claimed_elements.add(element_index)
        claimed_entries.add(entry_index)

    # Derived tables with an elementId pointer can be rewritten precisely.
    by_id = {element.get("id"): element for element in _elements(model)}
    mapping_by_id = {
        row["element_id"]: row for row in mappings if row.get("element_id")
    }
    precisely_repaired: set[int] = set()
    for element in _elements(model):
        source = element.get("source") or {}
        base = by_id.get(source.get("elementId"))
        mapping = mapping_by_id.get(base.get("id")) if base else None
        if source.get("kind") == "table" and mapping:
            _rewrite_formulas(
                element,
                [mapping["old_table"], mapping["old_name"]],
                mapping["new_name"],
                mapping["manifest_entry"]["columns"],
            )
            precisely_repaired.add(id(element))

    # String-only rewrites are safe only when one old identifier maps one way.
    for key in ("old_table", "old_name"):
        grouped: dict[str, set[str]] = {}
        grouped_mappings: dict[str, list[dict]] = {}
        for mapping in mappings:
            old = mapping[key]
            if old:
                grouped.setdefault(old, set()).add(mapping["new_name"])
                grouped_mappings.setdefault(old, []).append(mapping)
        for old, new_values in grouped.items():
            if len(new_values) != 1:
                continue
            new_value = next(iter(new_values))
            physical_columns = {}
            for mapping in grouped_mappings[old]:
                physical_columns.update(mapping["manifest_entry"]["columns"])
            for element in _elements(model):
                if id(element) in precisely_repaired or any(
                    element is candidate for candidate in warehouse_elements
                ):
                    continue
                _rewrite_formulas(
                    element, [old], new_value, physical_columns
                )

    sql_remapped = 0
    for element in _elements(model):
        source = element.get("source") or {}
        statement = source.get("statement")
        if source.get("kind") != "sql" or not isinstance(statement, str):
            continue
        identifiers = {
            _normalize(left or right)
            for left, right in re.findall(r'"([^"]+)"|\[([^\]]+)\]', statement)
        }
        best = None
        for entry in entries:
            overlap = len(identifiers & {_normalize(value) for value in entry["columns"]})
            if overlap and (best is None or overlap > best[0]):
                best = (overlap, entry)
        if not best:
            continue
        rewritten = _rewrite_single_table_sql(statement, best[1])
        if rewritten and rewritten != statement:
            source["statement"] = rewritten
            sql_remapped += 1

    return {
        "elements": len(mappings),
        "manifest_entries": len(entries),
        "manifest_entry_indices": sorted(
            mapping["manifest_entry_index"] for mapping in mappings
        ),
        "used_manifest_entries": [
            mapping["manifest_entry"] for mapping in mappings
        ],
        "unmatched_manifest_entries": len(entries) - len(claimed_entries),
        "tables": [mapping["sf_table"] for mapping in mappings],
        "column_mapping": colmap,
        "sql_elements": sql_remapped,
        "mappings": mappings,
    }


BRACKET_PATH_SPECIAL = re.compile(r"[/\[\]]")


def sigma_safe_column_name(name: object) -> str:
    """Twin of MechanicalSpecs.sigma_safe_column_name (Ruby).

    "/" "[" "]" cannot appear in a column name Sigma can reference (it reads "/"
    inside a bracketed reference as a path separator), so each becomes a space
    (Sigma's own friendly-names convention) and space runs squeeze. A hyphen is
    subtraction only outside brackets, so it stays.
    """
    safe = re.sub(r"\s+", " ", BRACKET_PATH_SPECIAL.sub(" ", str(name or ""))).strip()
    return safe or "Column"


def sanitize_bracket_path_captions(model: dict) -> int:
    """Twin of MechanicalSpecs.sanitize_bracket_path_captions! (#685-B).

    A warehouse passthrough formula embeds the Tableau caption raw inside a
    `[Table/Column]` bracket path; a caption holding "/" "[" "]" reads as a
    multi-segment path and the column compiles to type="error". Fold the caption
    segment to the UPPER_SNAKE physical form and keep the caption as the name.
    """
    rewritten = 0
    for element in _elements(model):
        source = element.get("source") or {}
        path = source.get("path") or []
        if source.get("kind") != "warehouse-table" or not path:
            continue
        table = str(path[-1])
        prefix = re.compile(r"\A\[" + re.escape(table) + r"/(.+)\]\Z", re.DOTALL)
        for column in element.get("columns") or []:
            match = prefix.match(str(column.get("formula") or ""))
            if not match or not BRACKET_PATH_SPECIAL.search(match.group(1)):
                continue
            caption = match.group(1)
            physical = re.sub(r"\A_+|_+\Z", "", re.sub(r"[^0-9A-Za-z]+", "_", caption)).upper()
            if not column.get("name"):
                column["name"] = caption
            column["formula"] = f"[{table}/{physical}]"
            rewritten += 1
    return rewritten


def sanitize_slash_column_names(model: dict) -> dict:
    """Twin of MechanicalSpecs.sanitize_slash_column_names! (Ruby).

    Every column and metric whose NAME holds "/" "[" "]" is renamed to its
    referenceable form and every formula that reads the old name is rewritten.
    Such a column can never be referenced (the master's `[Elem/Region - East/West]`
    exports as 'Unknown column'; a list control over it POSTs as 'Invalid value
    source for list control' — live-probed). Collisions take a numeric suffix.
    Run sanitize_bracket_path_captions first. Returns
    {"renamed": [...], "map": {old: new}}; idempotent.
    """
    elements = _elements(model)
    holders = [
        (element, item, kind)
        for element in elements
        for kind, items in (("column", element.get("columns")), ("metric", element.get("metrics")))
        for item in items or []
        if isinstance(item, dict)
    ]
    bad = [
        entry
        for entry in holders
        if isinstance(entry[1].get("name"), str) and BRACKET_PATH_SPECIAL.search(entry[1]["name"])
    ]
    if not bad:
        return {"renamed": [], "map": {}}

    def display(item: dict) -> str | None:
        if item.get("name"):
            return str(item["name"])
        match = re.search(r"\[([^\]]+)\]\s*$", str(item.get("formula") or ""))
        return match.group(1).split("/")[-1] if match else None

    taken = {name.lower() for _e, item, _k in holders for name in [display(item)] if name}
    mapping: dict[str, str] = {}
    for _element, item, _kind in bad:
        old = item["name"]
        if old in mapping:
            continue
        base = sigma_safe_column_name(old)
        candidate, n = base, 2
        while candidate.lower() in taken:
            candidate = f"{base} {n}"
            n += 1
        taken.add(candidate.lower())
        mapping[old] = candidate
    ordered = sorted(mapping.items(), key=lambda pair: -len(pair[0]))

    def rewrite(node: object) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "formula" and isinstance(value, str):
                    for old, new in ordered:
                        value = re.sub(
                            r"(?<=[\[/])" + re.escape(old) + r"(?=\])", lambda _m, n=new: n, value
                        )
                    node[key] = value
                else:
                    rewrite(value)
        elif isinstance(node, list):
            for value in node:
                rewrite(value)

    rewrite(model)
    renamed = []
    for element, item, kind in bad:
        old = item["name"]
        item["name"] = mapping[old]
        label = element.get("name") or element.get("id")
        renamed.append(
            {
                "element": str(label),
                "kind": kind,
                "from": old,
                "to": mapping[old],
                "warning": (
                    "renamed for Sigma: '/' cannot appear in a referenced column name — "
                    f"{kind} '{old}' on '{label}' is now '{mapping[old]}'"
                ),
            }
        )
    return {"renamed": renamed, "map": mapping}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--twb", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        result = classify_workbook(args.twb)
        Path(args.out).write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, ET.ParseError) as exc:
        print(f"FATAL: {exc}", file=os.sys.stderr)
        return 1
    print(f"{result['classification']}: wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
