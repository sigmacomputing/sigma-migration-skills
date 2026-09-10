#!/usr/bin/env python3
"""Ground Qlik expressions after convertQlikToSigma without editing its bundle.

Reads the discovery converter input and the actual converter output, then:

* applies catalog-proven token rewrites (notably Count(DISTINCT x));
* removes converter artifacts for semantically unsafe or unknown functions;
* writes a deterministic patched converter output and formula-mapping ledger.

The normalizer is deliberately fail-closed. An uncataloged callable is never
preserved merely because the converter happened to emit it.
"""

import argparse
import copy
import hashlib
import json
import os
import re
import tempfile


VERSION = 1
STATUS_ORDER = {"exact": 0, "approximated": 1, "needs-review": 2, "skipped": 3}
STRUCTURAL_EXACT = {
    "if", "isnull", "coalesce", "null", "match", "pick",
}


def _read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def _write_atomic(path, value):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    payload = _json_bytes(value)
    fd, tmp = tempfile.mkstemp(prefix=".qlik-normalize-", dir=parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def _stable_suffix(kind, name, expression):
    raw = "\x1f".join((kind, name, expression)).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:10].upper()


def _mask_noncode(expression):
    """Replace quoted literals and [field refs] while retaining string length."""
    chars = list(expression)
    i = 0
    while i < len(chars):
        opener = chars[i]
        if opener not in ("'", '"', "["):
            i += 1
            continue
        closer = "]" if opener == "[" else opener
        chars[i] = " "
        i += 1
        while i < len(chars):
            current = chars[i]
            chars[i] = " "
            if current == closer:
                if closer in ("'", '"') and i + 1 < len(chars) and chars[i + 1] == closer:
                    chars[i + 1] = " "
                    i += 2
                    continue
                i += 1
                break
            if current == "\\" and closer in ("'", '"') and i + 1 < len(chars):
                chars[i + 1] = " "
                i += 2
            else:
                i += 1
    return "".join(chars)


def _function_names(expression):
    masked = _mask_noncode(expression)
    return [
        match.group(1)
        for match in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_$]*)\s*\(", masked)
    ]


def _matching_paren(text, opening):
    depth = 0
    quote = None
    bracket = False
    i = opening
    while i < len(text):
        char = text[i]
        if quote:
            if char == quote:
                if i + 1 < len(text) and text[i + 1] == quote:
                    i += 2
                    continue
                quote = None
            elif char == "\\":
                i += 2
                continue
        elif bracket:
            if char == "]":
                bracket = False
        elif char in ("'", '"'):
            quote = char
        elif char == "[":
            bracket = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _rewrite_count_distinct(formula):
    """Rewrite balanced Count(DISTINCT expression) calls, including nesting."""
    pattern = re.compile(r"\bCount\s*\(", re.IGNORECASE)
    cursor = 0
    pieces = []
    while True:
        masked_tail = _mask_noncode(formula[cursor:])
        match = pattern.search(masked_tail)
        if not match:
            pieces.append(formula[cursor:])
            break
        start = cursor + match.start()
        opening = cursor + match.end() - 1
        closing = _matching_paren(formula, opening)
        if closing < 0:
            pieces.append(formula[cursor:])
            break
        inner = formula[opening + 1:closing]
        distinct = re.match(r"\s*DISTINCT\b", inner, re.IGNORECASE)
        pieces.append(formula[cursor:start])
        if distinct:
            argument = inner[distinct.end():].strip()
            pieces.append("CountDistinct(%s)" % _rewrite_count_distinct(argument))
        else:
            pieces.append(formula[start:opening + 1])
            pieces.append(_rewrite_count_distinct(inner))
            pieces.append(")")
        cursor = closing + 1
    return "".join(pieces)


def _rename_functions(formula, exact_rows):
    masked = _mask_noncode(formula)
    matches = list(re.finditer(r"\b([A-Za-z_][A-Za-z0-9_$]*)\s*(?=\()", masked))
    if not matches:
        return formula
    pieces = []
    cursor = 0
    for match in matches:
        pieces.append(formula[cursor:match.start()])
        source = match.group(1)
        row = exact_rows.get(source.lower())
        target = row.get("sigma") if row else None
        pieces.append(target if target and "candidate only" not in target else source)
        cursor = match.end()
    pieces.append(formula[cursor:])
    return "".join(pieces)


def _normalize_formula(formula, exact_rows):
    return _rename_functions(_rewrite_count_distinct(formula), exact_rows)


def _catalogs(catalog_path):
    scalar = _read_json(catalog_path)
    rows = {str(row["source"]).lower(): row for row in scalar.get("rows", [])}
    aggregation_path = os.path.join(os.path.dirname(catalog_path), "aggregation.json")
    aggregation = _read_json(aggregation_path)
    aggregate_functions = {
        str(row["source"]).lower()
        for row in aggregation.get("rows", [])
        if row.get("source") != "count_distinct"
    }
    return scalar, rows, aggregate_functions


def _expressions(converter_input):
    for index, item in enumerate(converter_input.get("masterMeasures") or []):
        yield {
            "kind": "measure",
            "index": index,
            "name": str(item.get("title") or item.get("qTitle") or "Metric"),
            "expression": str(item.get("expr") or item.get("qDef") or item.get("expression") or ""),
        }
    for index, item in enumerate(converter_input.get("masterDimensions") or []):
        yield {
            "kind": "dimension",
            "index": index,
            "name": str(item.get("title") or item.get("qTitle") or "Dimension"),
            "expression": str(
                item.get("fieldDef") or item.get("qFieldDef")
                or item.get("expr") or item.get("expression") or ""
            ),
        }


def _artifact_index(converter_output):
    by_key = {}
    for page in ((converter_output.get("model") or {}).get("pages") or []):
        for element in page.get("elements") or []:
            for kind, key in (("measure", "metrics"), ("dimension", "columns")):
                for artifact in element.get(key) or []:
                    if artifact.get("name") is None:
                        continue
                    by_key.setdefault((kind, str(artifact["name"])), []).append(artifact)
    return by_key


def _warning(code, suffix, name, expression, detail, evidence):
    warning_id = "%s-%s" % (code, suffix)
    return {
        "id": warning_id,
        "code": code,
        "severity": "warning",
        "name": name,
        "sourceExpression": expression,
        "detail": detail,
        "evidence": evidence,
        "provenance": {
            "normalizer": "normalize-qlik-expressions.py",
            "normalizerVersion": VERSION,
            "catalog": "refs/catalogs/scalar-function.json",
        },
    }


def _classify(expression, scalar_rows, aggregate_functions):
    functions = _function_names(expression)
    issues = []
    approximate = []
    exact_rows = {}
    for function in functions:
        key = function.lower()
        row = scalar_rows.get(key)
        if row:
            status = row.get("translation_status")
            if status == "needs-review":
                issues.append((function, row))
            elif status == "approximated":
                approximate.append((function, row))
                exact_rows[key] = row
            elif status == "exact":
                exact_rows[key] = row
            continue
        if key in aggregate_functions or key in STRUCTURAL_EXACT:
            continue
        issues.append((function, scalar_rows["<unknown-function>"]))
    if issues:
        return "needs-review", issues, approximate, exact_rows
    if approximate:
        return "approximated", issues, approximate, exact_rows
    return "exact", issues, approximate, exact_rows


def _remove_artifacts(value, remove_object_ids, remove_column_ids):
    if isinstance(value, dict):
        for key, child in list(value.items()):
            if key in ("metrics", "columns") and isinstance(child, list):
                value[key] = [item for item in child if id(item) not in remove_object_ids]
            elif key in ("order", "items") and isinstance(child, list):
                value[key] = [item for item in child if item not in remove_column_ids]
            else:
                _remove_artifacts(child, remove_object_ids, remove_column_ids)
    elif isinstance(value, list):
        for child in value:
            _remove_artifacts(child, remove_object_ids, remove_column_ids)


def normalize(converter_input, converter_output, catalog_path):
    scalar_catalog, scalar_rows, aggregate_functions = _catalogs(catalog_path)
    patched = copy.deepcopy(converter_output)
    artifacts = _artifact_index(patched)
    used = {}
    remove_ids = set()
    remove_column_ids = set()
    warning_rows = []
    formula_rows = []
    removed_metrics = 0
    removed_columns = 0

    for source in _expressions(converter_input):
        kind = source["kind"]
        name = source["name"]
        expression = source["expression"]
        suffix = _stable_suffix(kind, name, expression)
        expression_id = "QLIK-EXPR-%s" % suffix
        candidates = artifacts.get((kind, name), [])
        artifact_position = used.get((kind, name), 0)
        artifact = candidates[artifact_position] if artifact_position < len(candidates) else None
        used[(kind, name)] = artifact_position + 1
        before = artifact.get("formula") if artifact else None

        status, issues, approximations, exact_rows = _classify(
            expression, scalar_rows, aggregate_functions
        )
        row_warning_ids = []
        evidence = []

        if status == "needs-review":
            if artifact is not None:
                remove_ids.add(id(artifact))
                if kind == "dimension" and artifact.get("id"):
                    remove_column_ids.add(artifact["id"])
                    removed_columns += 1
                elif kind == "measure":
                    removed_metrics += 1
            seen_issue = set()
            for function, row in issues:
                issue_key = (function.lower(), row.get("warning_code"))
                if issue_key in seen_issue:
                    continue
                seen_issue.add(issue_key)
                code = row.get("warning_code") or "QLIK-SCALAR-NEEDS-REVIEW"
                warning = _warning(
                    code, suffix, name, expression,
                    ("%s() is not safe for automatic scalar normalization; "
                     "the converter artifact was removed." % function),
                    {
                        "function": function,
                        "catalogSource": row["source"],
                        "catalogStatus": row.get("translation_status"),
                        "converterFormula": before,
                        "reason": row.get("notes") or row.get("on_unmapped"),
                    },
                )
                warning_rows.append(warning)
                row_warning_ids.append(warning["id"])
                evidence.append(warning["evidence"])
        elif artifact is None:
            status = "skipped"
            warning = _warning(
                "QLIK-SCALAR-CONVERTER-OMITTED", suffix, name, expression,
                "The grounded source expression had no matching converter artifact; nothing was invented.",
                {"converterFormula": None, "reason": "matching named artifact not found"},
            )
            warning_rows.append(warning)
            row_warning_ids.append(warning["id"])
            evidence.append(warning["evidence"])
        else:
            artifact["formula"] = _normalize_formula(str(before), exact_rows)
            for function, row in approximations:
                code = row.get("warning_code") or "QLIK-SCALAR-APPROXIMATION"
                warning = _warning(
                    code, suffix, name, expression,
                    "%s() was retained as an explicit approximation." % function,
                    {
                        "function": function,
                        "catalogSource": row["source"],
                        "catalogStatus": row.get("translation_status"),
                        "converterFormula": before,
                        "normalizedFormula": artifact["formula"],
                        "reason": row.get("notes") or row.get("on_unmapped"),
                    },
                )
                warning_rows.append(warning)
                row_warning_ids.append(warning["id"])
                evidence.append(warning["evidence"])

        formula_rows.append({
            "id": expression_id,
            "kind": kind,
            "sourceIndex": source["index"],
            "name": name,
            "sourceExpression": expression,
            "converterFormula": before,
            "sigmaFormula": (
                artifact.get("formula")
                if artifact is not None and id(artifact) not in remove_ids
                else None
            ),
            "status": status,
            "warningIds": row_warning_ids,
            "evidence": evidence or [{
                "catalogStatus": status,
                "converterFormula": before,
                "normalizations": (
                    ["Count(DISTINCT ...) -> CountDistinct(...)"]
                    if before and _rewrite_count_distinct(str(before)) != str(before)
                    else []
                ),
            }],
            "provenance": {
                "source": "converter-input.json",
                "converterOutput": "converter-out.json",
                "normalizer": "normalize-qlik-expressions.py",
                "normalizerVersion": VERSION,
                "catalog": "refs/catalogs/scalar-function.json",
            },
        })

    _remove_artifacts(patched, remove_ids, remove_column_ids)
    stats = patched.get("stats")
    if isinstance(stats, dict):
        if isinstance(stats.get("metrics"), int):
            stats["metrics"] = max(0, stats["metrics"] - removed_metrics)
        if isinstance(stats.get("columns"), int):
            stats["columns"] = max(0, stats["columns"] - removed_columns)
    patched_warnings = patched.setdefault("warnings", [])
    for warning in warning_rows:
        patched_warnings.append("[%s] %s" % (warning["id"], warning["detail"]))

    mapping = {
        "schemaVersion": 1,
        "sourceTool": "qlik",
        "normalizerVersion": VERSION,
        "catalog": {
            "dimension": scalar_catalog.get("dimension"),
            "path": "refs/catalogs/scalar-function.json",
        },
        "formulas": formula_rows,
        "warnings": warning_rows,
        "summary": {
            status: sum(1 for row in formula_rows if row["status"] == status)
            for status in STATUS_ORDER
        },
    }
    return patched, mapping


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_catalog = os.path.normpath(
        os.path.join(script_dir, "..", "refs", "catalogs", "scalar-function.json")
    )
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--workdir",
        help=("pipeline mode: read converter-input.json + converter-out.json, "
              "patch converter-out.json in place, and write formula-mapping.json"),
    )
    parser.add_argument("--input", help="converter-input.json")
    parser.add_argument("--converter-out", help="raw converter-out.json")
    parser.add_argument("--out", help="patched converter output")
    parser.add_argument("--formula-mapping", help="formula-mapping.json")
    parser.add_argument("--catalog", default=default_catalog)
    args = parser.parse_args()

    if args.workdir:
        workdir = os.path.abspath(args.workdir)
        args.input = args.input or os.path.join(workdir, "converter-input.json")
        args.converter_out = (
            args.converter_out or os.path.join(workdir, "converter-out.json")
        )
        args.out = args.out or os.path.join(workdir, "converter-out.json")
        args.formula_mapping = (
            args.formula_mapping or os.path.join(workdir, "formula-mapping.json")
        )
    missing = [
        flag for flag, value in (
            ("--input", args.input),
            ("--converter-out", args.converter_out),
            ("--out", args.out),
            ("--formula-mapping", args.formula_mapping),
        )
        if not value
    ]
    if missing:
        parser.error("required arguments: %s (or use --workdir)" % ", ".join(missing))

    patched, mapping = normalize(
        _read_json(args.input), _read_json(args.converter_out), args.catalog
    )
    _write_atomic(args.out, patched)
    _write_atomic(args.formula_mapping, mapping)


if __name__ == "__main__":
    main()
