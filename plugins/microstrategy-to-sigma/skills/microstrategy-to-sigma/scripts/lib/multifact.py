#!/usr/bin/env python3
"""Multi-fact topology analysis shared by the planner and converter."""

import re


def friendly(column):
    return " ".join(part.capitalize() for part in str(column).split("_"))


def slug(value):
    return re.sub(r"[^a-z0-9]+", "-", str(value).lower()).strip("-")


def fact_alias(fact_id, fact):
    """Stable SQL projection alias for a fact in a conformed fallback query."""
    name = (fact.get("information") or {}).get("name") or fact_id
    return f"MSTR Fact - {name}"


def _simple_column(expression):
    return bool(re.fullmatch(
        r'(?:[A-Za-z_][A-Za-z0-9_$]*|"(?:[^"]|"")+")',
        str(expression or "").strip()))


def _metric_fact_ids(metric_id, metrics, seen=None):
    seen = set(seen or ())
    if metric_id in seen or metric_id not in metrics:
        return set()
    seen.add(metric_id)
    result = set()
    for token in (metrics[metric_id].get("expression") or {}).get("tokens") or []:
        target = token.get("target") or {}
        subtype = target.get("subType")
        object_id = target.get("objectId")
        if subtype == "fact" and object_id:
            result.add(object_id)
        elif subtype == "metric" and object_id:
            result.update(_metric_fact_ids(object_id, metrics, seen))
    return result


def analyze_bundle(raw):
    facts = raw.get("facts") or {}
    metrics = raw.get("metrics") or {}
    tables = raw.get("tables") or {}

    fact_rows = []
    all_table_ids = set()
    for fact_id, fact in facts.items():
        table_ids = {
            table.get("objectId")
            for expression in fact.get("expressions") or []
            for table in expression.get("tables") or []
            if table.get("objectId")
        }
        all_table_ids.update(table_ids)
        fact_rows.append({
            "id": fact_id,
            "name": (fact.get("information") or {}).get("name") or fact_id,
            "sqlAlias": fact_alias(fact_id, fact),
            "tableIds": sorted(table_ids),
            "tableNames": sorted(
                ((tables.get(tid) or {}).get("physicalTable") or {}).get("tableName")
                or ((tables.get(tid) or {}).get("information") or {}).get("name")
                or tid
                for tid in table_ids
            ),
            "expressions": [{
                "text": (expression.get("expression") or {}).get("text"),
                "simpleColumn": _simple_column(
                    (expression.get("expression") or {}).get("text")),
                "tableIds": sorted(
                    table.get("objectId")
                    for table in expression.get("tables") or []
                    if table.get("objectId")
                ),
            } for expression in fact.get("expressions") or []],
        })

    fact_tables_by_id = {
        row["id"]: set(row["tableIds"])
        for row in fact_rows
    }
    report_rows = []
    for report_id, report in (raw.get("reports") or {}).items():
        units = (((report.get("dataSource") or {}).get("dataTemplate") or {})
                 .get("units") or [])
        metric_ids = [
            element.get("id")
            for unit in units
            if unit.get("type") == "metrics"
            for element in unit.get("elements") or []
            if element.get("id")
        ]
        attribute_ids = [
            unit.get("id") for unit in units
            if unit.get("type") == "attribute" and unit.get("id")
        ]
        report_fact_ids = set()
        for metric_id in metric_ids:
            report_fact_ids.update(_metric_fact_ids(metric_id, metrics))
        report_table_ids = {
            table_id
            for row in fact_rows if row["id"] in report_fact_ids
            for table_id in row["tableIds"]
        }
        candidate_sets = [
            fact_tables_by_id[fact_id]
            for fact_id in report_fact_ids if fact_id in fact_tables_by_id
        ]
        eligible = set.intersection(*candidate_sets) if candidate_sets else set()

        # Higher-level report attributes often resolve through hierarchy joins,
        # so requiring those IDs directly on a fact table is too strict. We can
        # safely compare alternate candidates when their embedded attribute-key
        # signatures are identical; differing signatures need sqlView evidence.
        attribute_signatures = {
            table_id: sorted({
                (attribute.get("information") or {}).get("objectId")
                for attribute in (tables.get(table_id) or {}).get("attributes") or []
                if (attribute.get("information") or {}).get("objectId")
            })
            for table_id in eligible
        }
        comparable_candidates = (
            len({tuple(signature)
                 for signature in attribute_signatures.values()}) <= 1
        )

        logical_sizes = {
            table_id: (tables.get(table_id) or {}).get("logicalSize")
            for table_id in eligible
        }
        numeric_sizes = {
            table_id: size for table_id, size in logical_sizes.items()
            if isinstance(size, (int, float))
        }
        selected_table_id = None
        if len(eligible) == 1:
            selected_table_id = next(iter(eligible))
        elif (eligible and comparable_candidates
              and len(numeric_sizes) == len(eligible)):
            minimum = min(numeric_sizes.values())
            smallest = [
                table_id for table_id, size in numeric_sizes.items()
                if size == minimum
            ]
            if len(smallest) == 1:
                selected_table_id = smallest[0]

        if len(report_table_ids) <= 1:
            classification = "single-fact-table"
        elif selected_table_id:
            classification = "alternate-table-mappings"
        elif eligible:
            classification = "ambiguous-alternate-mappings"
        else:
            classification = "multi-pass"
        report_rows.append({
            "id": report_id,
            "name": (report.get("information") or {}).get("name") or report_id,
            "metricIds": metric_ids,
            "factIds": sorted(report_fact_ids),
            "tableIds": sorted(report_table_ids),
            "tableNames": sorted(
                ((tables.get(tid) or {}).get("physicalTable") or {}).get("tableName")
                or ((tables.get(tid) or {}).get("information") or {}).get("name")
                or tid
                for tid in report_table_ids
            ),
            "attributeIds": attribute_ids,
            "candidateAttributeSignatures": attribute_signatures,
            "eligibleTableIds": sorted(eligible),
            "logicalSizes": logical_sizes,
            "selectedTableId": selected_table_id,
            "classification": classification,
            "metricSemantics": [{
                "id": metric_id,
                "name": ((metrics.get(metric_id) or {}).get("information") or {})
                        .get("name") or metric_id,
                "formulaJoinType": (metrics.get(metric_id) or {})
                                   .get("formulaJoinType"),
                "dimensionality": (metrics.get(metric_id) or {}).get("dimty"),
            } for metric_id in metric_ids],
        })

    selected = {
        report["selectedTableId"] for report in report_rows
        if report["factIds"] and report["selectedTableId"]
    }
    unresolved_reports = [
        report for report in report_rows
        if report["factIds"] and not report["selectedTableId"]
    ]
    automatic_table_id = (
        next(iter(selected))
        if len(selected) == 1 and not unresolved_reports else None
    )
    complex_fact_expressions = [
        {
            "factId": row["id"],
            "factName": row["name"],
            "expression": expression["text"],
            "tableIds": expression["tableIds"],
        }
        for row in fact_rows
        for expression in row["expressions"]
        if not expression["simpleColumn"]
    ]
    active_complex_fact_expressions = [
        row for row in complex_fact_expressions
        if not automatic_table_id
        or automatic_table_id in row["tableIds"]
    ]
    if active_complex_fact_expressions:
        automatic_table_id = None

    required_columns = set()
    for attribute in (raw.get("attributes") or {}).values():
        forms = attribute.get("forms") or []
        key = next((form for form in forms if form.get("category") == "ID"),
                   forms[0] if forms else None)
        desc = next((form for form in forms if form.get("category") == "DESC"), None)
        for form in (key, desc):
            expressions = (form or {}).get("expressions") or []
            if expressions:
                text = (expressions[0].get("expression") or {}).get("text")
                if text:
                    required_columns.add(friendly(text))
    required_columns.update(row["sqlAlias"] for row in fact_rows)

    return {
        "version": 1,
        "retrievedAtUtc": (raw.get("_extraction") or {}).get("retrievedAtUtc"),
        "factTableCount": len(all_table_ids),
        "factTables": [{
            "id": tid,
            "name": ((tables.get(tid) or {}).get("physicalTable") or {}).get("tableName")
                    or ((tables.get(tid) or {}).get("information") or {}).get("name")
                    or tid,
        } for tid in sorted(all_table_ids)],
        "facts": fact_rows,
        "reports": report_rows,
        "automaticTableId": automatic_table_id,
        "requiresConformedSource": (
            bool(active_complex_fact_expressions)
            or (len(all_table_ids) != 1 and automatic_table_id is None)
        ),
        "risks": {
            "complexFactExpressions": active_complex_fact_expressions,
            "logicalSizeElectionRequiresSqlViewVerification": bool(
                automatic_table_id and len(all_table_ids) > 1),
            "reportMetricJoinTypeNotCaptured": len(all_table_ids) > 1,
        },
        "conformedSqlContract": {
            "requiredColumns": sorted(required_columns),
            "requirements": [
                "one SELECT or WITH query; no temporary/volatile-table statements",
                "one row at the grain required by the migrated reports",
                "project every required column with the exact alias shown",
                "preserve MicroStrategy multipass and outer-join semantics",
            ],
        },
    }
