#!/usr/bin/env python3
"""Build the non-mutating Sigma DM-reuse signature for a Sisense model."""
import argparse
import json
import os
import re
import sys
from pathlib import Path


AGGREGATIONS = {
    "sum": "Sum",
    "avg": "Avg",
    "average": "Avg",
    "min": "Min",
    "max": "Max",
    "count": "Count",
    "countdistinct": "CountDistinct",
    "distinctcount": "CountDistinct",
    "median": "Median",
}


class SignatureError(Exception):
    pass


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SignatureError("cannot read %s: %s" % (path, exc)) from exc


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def dm_elements(spec):
    root = spec.get("document", spec) if isinstance(spec, dict) else {}
    elements = [row for row in root.get("elements") or [] if isinstance(row, dict)]
    for page in root.get("pages") or []:
        if isinstance(page, dict):
            elements.extend(row for row in page.get("elements") or []
                            if isinstance(row, dict))
    return elements


def source_tables(model):
    rows = []
    for dataset in model.get("datasets") or []:
        dataset_db = dataset.get("database")
        dataset_schema = dataset.get("schemaName")
        for table in (dataset.get("schema") or {}).get("tables") or []:
            rows.append((dataset_db, dataset_schema,
                         table.get("name") or table.get("id")))
    for table in model.get("tables") or []:
        rows.append((table.get("database"), table.get("schema"),
                     table.get("name") or table.get("id")))
    return rows


def extract_measures(elements):
    measures = []
    seen = set()
    aggregate = re.compile(
        r"\b(Sum|Avg|Average|Min|Max|Count|CountDistinct|DistinctCount|Median)"
        r"\s*\(\s*\[([^\]]+)\]",
        re.IGNORECASE,
    )
    for element in elements:
        for metric in element.get("metrics") or []:
            if not isinstance(metric, dict):
                continue
            formula = str(metric.get("formula") or "")
            matches = aggregate.findall(formula)
            if matches:
                candidates = [
                    (reference.rsplit("/", 1)[-1], AGGREGATIONS[function.lower()])
                    for function, reference in matches
                ]
            else:
                column = metric.get("column") or metric.get("col")
                derivation = metric.get("aggregation") or metric.get("derivation")
                candidates = [(column, AGGREGATIONS.get(str(derivation).lower(),
                                                        derivation))]
            for column, derivation in candidates:
                if not column or not derivation:
                    continue
                key = (str(column).upper(), str(derivation))
                if key not in seen:
                    seen.add(key)
                    measures.append({"col": key[0], "derivation": key[1]})
    return sorted(measures, key=lambda row: (row["col"], row["derivation"]))


def build(model, dm_spec, database=None, schema=None):
    elements = dm_elements(dm_spec)
    tables = set()
    columns = set()
    for element in elements:
        source = element.get("source") or {}
        kind = str(source.get("kind") or "")
        if kind in ("warehouse-table", "table"):
            raw_path = source.get("path")
            if isinstance(raw_path, list):
                path = raw_path
            elif raw_path:
                path = str(raw_path).split(".")
            else:
                path = [source.get("database"), source.get("schema"),
                        source.get("name")]
            fqn = ".".join(str(part) for part in path if part)
            if fqn:
                tables.add(fqn.upper())
        elif kind == "sql":
            tables.add("CUSTOM_SQL")
        for column in element.get("columns") or []:
            if isinstance(column, dict):
                name = column.get("name")
                if name:
                    columns.add(str(name).upper())

    # The converted DM is authoritative because it records the target warehouse
    # paths. Source-model fallback keeps the helper independently runnable on
    # partial/older converted specs.
    if not tables:
        for source_db, source_schema, table in source_tables(model):
            if not table:
                continue
            path = [
                database or source_db,
                schema or source_schema,
                table,
            ]
            tables.add(".".join(str(part) for part in path if part).upper())
    if not columns:
        for dataset in model.get("datasets") or []:
            for table in (dataset.get("schema") or {}).get("tables") or []:
                for column in table.get("columns") or []:
                    name = column.get("name") or column.get("id")
                    if name:
                        columns.add(str(name).upper())

    return {
        # find-or-pick-dm.rb retains this historical label key.
        "tableau_workbook": (
            model.get("title") or model.get("name") or "Sisense model"
        ),
        "warehouse_tables": sorted(tables),
        "referenced_columns": sorted(columns),
        "measures": extract_measures(elements),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--dm-spec", required=True)
    parser.add_argument("--database")
    parser.add_argument("--schema")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    signature = build(
        read_json(args.model), read_json(args.dm_spec),
        database=args.database, schema=args.schema,
    )
    write_json(args.out, signature)
    print("Sisense DM signature: %d table(s), %d column(s), %d measure(s) -> %s" % (
        len(signature["warehouse_tables"]),
        len(signature["referenced_columns"]),
        len(signature["measures"]),
        args.out,
    ))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SignatureError as error:
        print("sisense-dm-signature: %s" % error, file=sys.stderr)
        sys.exit(2)
