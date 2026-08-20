#!/usr/bin/env python3
"""Parse Qlik LOAD/SQL table blocks into final warehouse-backed tables."""
import copy
import re

from qlik_load_expr import referenced_columns


LABEL = re.compile(r"(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t]*(?:\r?\n|$)")
DROP_TABLE = re.compile(r"(?im)^\s*DROP\s+TABLE\s+([A-Za-z_][A-Za-z0-9_]*)\s*;")
SQL_SELECT = re.compile(
    r'\b(?:SQL\s+)?SELECT\b(.*?)\bFROM\s+([A-Za-z0-9_."`]+)', re.IGNORECASE | re.DOTALL)


def split_fields(text):
    parts, current, depth, quote = [], [], 0, None
    for char in text:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
        elif char in "'\"`":
            quote = char
            current.append(char)
        elif char in "([":
            depth += 1
            current.append(char)
        elif char in ")]":
            depth = max(0, depth - 1)
            current.append(char)
        elif char == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
    if current:
        parts.append("".join(current))
    return parts


def clean_source(source):
    return ".".join(part.strip('"`[]') for part in source.split("."))


def field_record(token, sql=False):
    token = token.strip().strip(";").strip()
    token = re.sub(r"^DISTINCT\s+", "", token, flags=re.IGNORECASE)
    if not token:
        return None
    alias = re.search(
        r'^(.*?)\s+AS\s+["`]?([A-Za-z_][A-Za-z0-9_$]*)["`]?$',
        token,
        re.IGNORECASE | re.DOTALL,
    )
    real = alias.group(1).strip() if alias else token
    qlik = alias.group(2) if alias else None
    identifier = re.fullmatch(
        r'(?:["`\[]?[A-Za-z_][A-Za-z0-9_$]*["`\]]?\.)*["`\[]?([A-Za-z_][A-Za-z0-9_$]*|\*)["`\]]?',
        real,
    )
    if identifier:
        physical = identifier.group(1)
        qlik = qlik or physical
        return {
            "qlikField": qlik,
            "realColumn": physical,
            "renamed": physical.upper() != qlik.upper(),
            "isExpression": False,
        }
    if sql or not qlik:
        return None
    dual = re.match(
        r'^Dual\s*\(\s*"?([A-Za-z0-9_]+)"?\s*,\s*"?([A-Za-z0-9_]+)"?\s*\)$',
        real,
        re.IGNORECASE,
    )
    if dual:
        physical = dual.group(2)
        return {
            "qlikField": qlik,
            "realColumn": physical,
            "renamed": physical.upper() != qlik.upper(),
            "isExpression": False,
        }
    return {
        "qlikField": qlik,
        "realColumn": real.strip('"'),
        "renamed": True,
        "isExpression": True,
        "loadExpression": real.strip('"'),
        "expressionColumns": referenced_columns(real),
    }


def table_blocks(qvs):
    labels = list(LABEL.finditer(qvs))
    for index, match in enumerate(labels):
        end = labels[index + 1].start() if index + 1 < len(labels) else len(qvs)
        yield match.group(1), qvs[match.end():end]


def parse_raw(qvs):
    records = []
    for name, block in table_blocks(qvs):
        sql_match = SQL_SELECT.search(block)
        load_match = re.search(
            r'^\s*LOAD\b(.*?)(?=\bRESIDENT\b|\bFROM\s+\[|\bAUTOGENERATE\b|\bINLINE\b|;)',
            block,
            re.IGNORECASE | re.DOTALL,
        )
        if load_match:
            fields = [field_record(token) for token in split_fields(load_match.group(1))]
            resident = re.search(r"\bRESIDENT\s+([A-Za-z_][A-Za-z0-9_]*)", block, re.IGNORECASE)
            lib_file = re.search(r"\bFROM\s+\[lib://[^/]+/([^]]+)\]", block, re.IGNORECASE)
            special = re.search(r"\b(INLINE|AUTOGENERATE)\b", block, re.IGNORECASE)
            if sql_match:
                source = clean_source(sql_match.group(2))
            elif resident:
                source = f"RESIDENT {resident.group(1)}"
            elif lib_file:
                source = re.sub(
                    r"\.(qvd|qvx|csv|txt|xlsx?)$", "", lib_file.group(1).split("/")[-1], flags=re.IGNORECASE)
            else:
                source = special.group(1).upper() if special else "?"
        elif sql_match and not block[:sql_match.start()].strip():
            fields = [field_record(token, sql=True) for token in split_fields(sql_match.group(1))]
            source = clean_source(sql_match.group(2))
        else:
            continue
        fields = [field for field in fields if field]
        if fields:
            records.append({"qlikTable": name, "sourceTable": source, "fields": fields})
    return records


def parse_reconcile(qvs):
    raw = parse_raw(qvs)
    by_name = {record["qlikTable"].upper(): record for record in raw}

    def resolve(record, seen=None):
        result = copy.deepcopy(record)
        match = re.match(r"^RESIDENT\s+(.+)$", result["sourceTable"], re.IGNORECASE)
        if not match:
            return result
        seen = set(seen or ())
        source_name = match.group(1).upper()
        if source_name in seen or source_name not in by_name:
            return result
        seen.add(source_name)
        base = resolve(by_name[source_name], seen)
        base_fields = {field["qlikField"].upper(): field for field in base["fields"]}
        result["sourceTable"] = base["sourceTable"]
        for field in result["fields"]:
            if field["isExpression"]:
                continue
            inherited = base_fields.get(field["realColumn"].upper())
            if not inherited:
                continue
            field["realColumn"] = inherited["realColumn"]
            field["renamed"] = field["realColumn"].upper() != field["qlikField"].upper()
            if inherited["isExpression"]:
                field["isExpression"] = True
                field["loadExpression"] = inherited["loadExpression"]
                field["expressionColumns"] = inherited["expressionColumns"]
        return result

    dropped = {name.upper() for name in DROP_TABLE.findall(qvs)}
    return [resolve(record) for record in raw if record["qlikTable"].upper() not in dropped]


def parse_tables(qvs):
    return [
        {
            "name": record["qlikTable"],
            "noOfRows": 0,
            "fields": [{"name": field["qlikField"]} for field in record["fields"]],
        }
        for record in parse_reconcile(qvs)
    ]
