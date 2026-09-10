#!/usr/bin/env python3
"""Reconcile every Sisense source object to one terminal migration outcome."""
import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path


TERMINAL = ("migrated", "approximated", "needs-review", "skipped", "not-applicable")
PROVENANCE = ("live", "rest-export", "inferred")


class AccountingError(Exception):
    pass


def read_json(path, required=False):
    if not path:
        if required:
            raise AccountingError("required artifact path was not supplied")
        return None
    candidate = Path(path)
    if not candidate.is_file():
        if required:
            raise AccountingError("required artifact not found: %s" % candidate)
        return None
    try:
        return json.loads(candidate.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise AccountingError("malformed JSON %s: %s" % (candidate, exc)) from exc


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def folded(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def document(value):
    return value.get("document", value) if isinstance(value, dict) else {}


def structural_elements(value):
    root = document(value)
    rows = [row for row in root.get("elements") or [] if isinstance(row, dict)]
    for page in root.get("pages") or []:
        if isinstance(page, dict):
            rows.extend(row for row in page.get("elements") or [] if isinstance(row, dict))
    return rows


def artifact(workdir, explicit, names):
    if explicit:
        path = Path(explicit)
        return path if path.is_absolute() else workdir / path
    for name in names:
        path = workdir / name
        if path.is_file():
            return path
    return None


def evidence(path, detail):
    return {"artifact": Path(path).name if path else "accounting", "detail": detail}


class Accountant:
    def __init__(self, args, paths, docs):
        self.args = args
        self.paths = paths
        self.docs = docs
        self.errors = []
        self.rows = []
        self.controls = []
        self.dm_elements = structural_elements(docs.get("dm"))
        self.wb_elements = structural_elements(docs.get("wb"))
        self.wb_pages = document(docs.get("wb")).get("pages") or []
        parity = docs.get("parity") or {}
        self.parity_pass = {
            folded(value)
            for row in parity.get("detail") or []
            if isinstance(row, dict) and str(row.get("status") or "").upper() == "PASS"
            for value in (row.get("name"), row.get("widget_id"))
            if value not in (None, "")
        }
        if not self.parity_pass:
            self.parity_pass = {folded(name) for name in parity.get("pass_names") or []}
        self.mapping_text = folded(json.dumps(docs.get("jaql") or {}, sort_keys=True))

    def validate_scan(self):
        scan = self.docs["gap"]
        if not isinstance(scan, dict) or not isinstance(scan.get("objects"), list):
            raise AccountingError("gap report must contain an objects array")
        identities = Counter()
        pointers = Counter()
        for index, source in enumerate(scan["objects"]):
            if not isinstance(source, dict):
                self.errors.append("gap object %d is not an object" % index)
                continue
            identity = (str(source.get("type") or ""), str(source.get("id") or ""))
            identities[identity] += 1
            pointer = (source.get("source") or {}).get("json_pointer")
            if pointer is not None:
                pointers[(identity[0], pointer)] += 1
            if not all(source.get(key) not in (None, "") for key in ("type", "id", "name", "status")):
                self.errors.append("gap object %d lacks type/id/name/status" % index)
            if source.get("status") not in ("auto", "hint", "manual", "unhandled", "not-applicable"):
                self.errors.append("%s has unknown scan status %r" %
                                   (source.get("id"), source.get("status")))
            if not source.get("evidence") or not isinstance(source.get("source"), dict):
                self.errors.append("%s lacks source evidence/provenance" % source.get("id"))
        for identity, count in identities.items():
            if count != 1:
                self.errors.append("source identity %s:%s occurs %d times" %
                                   (identity[0], identity[1], count))
        for pointer, count in pointers.items():
            if count != 1:
                self.errors.append("source pointer %s:%s occurs %d times" %
                                   (pointer[0], pointer[1], count))
        declared = (scan.get("summary") or {}).get("objects")
        if declared is not None and int(declared) != len(scan["objects"]):
            self.errors.append("gap summary objects=%s but detail has %d" %
                               (declared, len(scan["objects"])))
        actual_pointers = {
            (row.get("type"), (row.get("source") or {}).get("json_pointer"))
            for row in scan["objects"] if isinstance(row, dict)
        }
        expected_pointers = self.source_pointers()
        if expected_pointers:
            for missing in sorted(expected_pointers - actual_pointers):
                self.errors.append("source object absent from structured scan: %s %s" % missing)
            for extra in sorted(actual_pointers - expected_pointers):
                self.errors.append("structured scan object absent from source artifacts: %s %s" % extra)

    def source_pointers(self):
        expected = set()
        model = self.docs.get("model")
        if isinstance(model, dict):
            for dataset_index, dataset in enumerate(model.get("datasets") or []):
                for table_index, table in enumerate((dataset.get("schema") or {}).get("tables") or []):
                    base = "/datasets/%d/schema/tables/%d" % (dataset_index, table_index)
                    expected.add(("model-table", base))
                    expected.update(
                        ("model-column", "%s/columns/%d" % (base, column_index))
                        for column_index, _column in enumerate(table.get("columns") or [])
                    )
                expected.update(
                    ("model-transformation", "/datasets/%d/modelingTransformations/%d" %
                     (dataset_index, index))
                    for index, _row in enumerate(dataset.get("modelingTransformations") or [])
                )
            expected.update(
                ("model-relation", "/relations/%d" % index)
                for index, _row in enumerate(model.get("relations") or [])
            )
            expected.update(
                ("model-transformation", "/modelingTransformations/%d" % index)
                for index, _row in enumerate(model.get("modelingTransformations") or [])
            )
        dashboards = self.docs.get("dashboards")
        if isinstance(dashboards, dict):
            dashboards = [dashboards]
        for dashboard_index, dashboard in enumerate(dashboards or []):
            expected.add(("dashboard", "/%d" % dashboard_index))
            expected.update(
                ("filter", "/%d/filters/%d" % (dashboard_index, index))
                for index, _row in enumerate(dashboard.get("filters") or [])
            )
            for widget_index, widget in enumerate(dashboard.get("widgets") or []):
                widget_pointer = "/%d/widgets/%d" % (dashboard_index, widget_index)
                expected.add(("widget", widget_pointer))
                for panel_index, panel in enumerate(
                        (widget.get("metadata") or {}).get("panels") or []):
                    for item_index, item in enumerate(panel.get("items") or []):
                        if "filter" in (item.get("jaql") or {}):
                            expected.add((
                                "filter",
                                "%s/metadata/panels/%d/items/%d/jaql/filter" %
                                (widget_pointer, panel_index, item_index),
                            ))
                expected.update(
                    ("filter", "%s/filters/%d" % (widget_pointer, index))
                    for index, _row in enumerate(widget.get("filters") or [])
                )
        return expected

    def target_names(self, rows):
        names = set()
        for row in rows:
            names.add(folded(row.get("name")))
            names.add(folded(row.get("id")))
            source = row.get("source") or {}
            path = source.get("path")
            if isinstance(path, list) and path:
                names.add(folded(path[-1]))
        names.discard("")
        return names

    def dm_column_names(self):
        names = set()
        for element in self.dm_elements:
            for column in element.get("columns") or []:
                if isinstance(column, dict):
                    names.update((folded(column.get("name")), folded(column.get("id"))))
                    names.update(folded(ref.split("/")[-1])
                                 for ref in re.findall(r"\[([^\]]+)\]",
                                                       str(column.get("formula") or "")))
        names.discard("")
        return names

    def relation_names(self):
        names = set()
        for element in self.dm_elements:
            for row in element.get("relationships") or []:
                if isinstance(row, dict):
                    names.update((folded(row.get("name")), folded(row.get("id"))))
        names.discard("")
        return names

    def parity_for(self, source):
        return any(
            folded(value) in self.parity_pass
            for value in (source.get("name"), source.get("id"))
            if value not in (None, "")
        )

    def built(self, source):
        kind = source["type"]
        name = source["name"]
        source_meta = source.get("source") or {}
        if kind == "dashboard":
            return bool(self.wb_elements) and (
                folded(name) in self.target_names(self.wb_pages) or len(self.wb_pages) > 1
            )
        if kind == "widget":
            return folded(name) in self.target_names(self.wb_elements)
        if kind == "filter":
            return folded(name) in {
                folded(row.get("name")) for row in self.wb_elements
                if row.get("kind") == "control" or row.get("controlType")
            }
        if kind == "model-table":
            return folded(name) in self.target_names(self.dm_elements)
        if kind == "model-column":
            return folded(name) in self.dm_column_names()
        if kind == "model-relation":
            relation_id = source.get("id")
            return folded(relation_id) in self.relation_names() or any(
                token and token in folded(name) for token in self.relation_names()
            )
        if kind == "model-transformation":
            return False
        return False

    def disposition(self, source, built):
        scan_status = source["status"]
        kind = source["type"]
        if scan_status == "not-applicable":
            return "not-applicable"
        if scan_status == "unhandled":
            return "skipped" if kind == "widget" else "needs-review"
        if scan_status == "manual":
            return "needs-review"
        if scan_status == "hint":
            if built and (kind not in ("widget", "filter") or self.parity_for(source)):
                return "approximated"
            return "needs-review"
        if scan_status == "auto":
            if not built:
                return "needs-review"
            if kind == "widget" and not self.parity_for(source):
                return "needs-review"
            return "migrated"
        raise AccountingError("unreachable scan status %r" % scan_status)

    def run(self):
        self.validate_scan()
        for source in self.docs["gap"].get("objects") or []:
            if not isinstance(source, dict) or not source.get("id"):
                continue
            built = self.built(source)
            status = self.disposition(source, built)
            row_evidence = [
                evidence(self.paths["gap"],
                         "structured scan status=%s" % source.get("status"))
            ]
            for item in source.get("evidence") or []:
                row_evidence.append(evidence(self.paths["gap"], str(item)))
            if built:
                row_evidence.append(evidence(
                    self.paths["wb"] if source["type"] in ("dashboard", "widget", "filter")
                    else self.paths["dm"],
                    "matching target object found",
                ))
            elif source["status"] in ("auto", "hint"):
                row_evidence.append(evidence("accounting", "matching target object not found"))
            if source["type"] == "widget":
                row_evidence.append(evidence(
                    self.paths.get("parity"),
                    "widget parity passed" if self.parity_for(source)
                    else "widget does not have passing final parity",
                ))
            if self.mapping_text and folded(source["name"]) in self.mapping_text:
                row_evidence.append(evidence(self.paths.get("jaql"),
                                             "JAQL mapping names this source object"))
            row = {
                "type": source["type"],
                "id": str(source["id"]),
                "name": str(source["name"]),
                "status": status,
                "source_provenance": self.args.provenance,
                "source": source.get("source"),
                "evidence": sorted(
                    {json.dumps(item, sort_keys=True): item for item in row_evidence}.values(),
                    key=lambda item: (item["artifact"], item["detail"]),
                ),
            }
            self.rows.append(row)
            source_pointer = (source.get("source") or {}).get("json_pointer") or ""
            interactive_filter = (
                source["type"] == "filter"
                and re.fullmatch(r"/\d+/filters/\d+", source_pointer) is not None
            )
            if interactive_filter:
                control_status = {
                    "migrated": "emitted", "approximated": "emitted",
                    "skipped": "dropped",
                }.get(status, "needs-wiring")
                self.controls.append({
                    "type": "filter", "id": row["id"], "name": row["name"],
                    "status": control_status, "terminal_status": status,
                    "source_provenance": self.args.provenance,
                    "evidence": row["evidence"],
                })
        self.rows.sort(key=lambda row: (row["type"], row["id"], row["name"]))
        if any(row["status"] not in TERMINAL for row in self.rows):
            self.errors.append("one or more rows lacks exactly one terminal status")

    def outputs(self):
        counts = {status: sum(row["status"] == status for row in self.rows)
                  for status in TERMINAL}
        complete = not self.errors and len(self.rows) == len(self.docs["gap"].get("objects") or [])
        diagnostics = {"errors": sorted(set(self.errors))}
        census = {
            "schema_version": 1,
            "source": "sisense",
            "source_provenance": self.args.provenance,
            "summary": {
                "total": len(self.rows), "accounted": len(self.rows),
                "complete": complete, "counts": counts,
            },
            "objects": self.rows,
            "diagnostics": diagnostics,
        }
        unresolved = []
        for row in self.rows:
            if row["status"] in ("migrated", "not-applicable"):
                continue
            unresolved.append({
                "type": row["type"], "source_object_id": row["id"],
                "name": row["name"], "status": row["status"],
                "severity": {
                    "approximated": "approximated", "needs-review": "degraded",
                    "skipped": "dropped",
                }.get(row["status"], "degraded"),
                "detail": row["evidence"][-1]["detail"] if row["evidence"] else "recorded",
            })
        widgets = [row for row in self.rows if row["type"] == "widget"]
        coverage = {
            "version": 1,
            "source": "sisense",
            "summary": {
                "sourceVisuals": len(widgets),
                "builtElements": sum(self.built(source) for source in
                                     self.docs["gap"].get("objects") or []
                                     if source.get("type") == "widget"),
                "dropped": sum(row["severity"] == "dropped" for row in unresolved),
                "degraded": sum(row["severity"] == "degraded" for row in unresolved),
                "approximated": sum(row["severity"] == "approximated" for row in unresolved),
            },
            "unresolved": unresolved,
            "objects": [
                {"type": row["type"], "source_object_id": row["id"],
                 "name": row["name"], "status": row["status"]}
                for row in self.rows
            ],
            "diagnostics": diagnostics,
        }
        controls = {
            "version": 1,
            "source": "sisense",
            "summary": {
                "sourceFilters": len(self.controls),
                "emitted": sum(row["status"] == "emitted" for row in self.controls),
                "dropped": sum(row["status"] == "dropped" for row in self.controls),
                "needsWiring": sum(row["status"] == "needs-wiring" for row in self.controls),
            },
            "detail": sorted(self.controls, key=lambda row: (row["id"], row["name"])),
            "runtime_probe": self.probe_summary(),
            "security": self.security_summary(),
            "diagnostics": diagnostics,
        }
        return census, coverage, controls

    def probe_summary(self):
        probe = self.docs.get("controls")
        if not isinstance(probe, list):
            return {
                "status": "not-run",
                "checks": 0,
                "evidence": evidence(self.paths.get("controls"), "runtime control probe absent"),
            }
        failed = sum(
            str(row.get("result") or "").upper() not in ("OK", "PASS")
            for row in probe if isinstance(row, dict)
        )
        return {
            "status": "PASS" if probe and failed == 0 else "FAIL",
            "checks": len(probe),
            "failed": failed,
            "evidence": evidence(self.paths.get("controls"), "runtime control probe results"),
        }

    def security_summary(self):
        security = self.docs.get("security")
        if isinstance(security, dict):
            security = security.get("security") or security.get("findings") or []
        findings = security if isinstance(security, list) else []
        decision = self.docs.get("rls_decision") or {}
        decision_value = decision.get("decision") if isinstance(decision, dict) else None
        return {
            "status": (
                "not-applicable" if not findings
                else "recorded" if decision_value in ("port", "omit")
                else "needs-decision"
            ),
            "findings": len(findings),
            "mapped_rls": sum(
                isinstance(row, dict) and row.get("kind") == "rls"
                for row in findings
            ),
            "decision": decision_value,
            "evidence": evidence(self.paths.get("security"), "Sisense security scan"),
        }


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--gap-report")
    parser.add_argument("--model")
    parser.add_argument("--dashboards")
    parser.add_argument("--jaql-mapping")
    parser.add_argument("--dm-spec")
    parser.add_argument("--dm-readback")
    parser.add_argument("--wb-spec")
    parser.add_argument("--wb-readback")
    parser.add_argument("--parity-final")
    parser.add_argument("--security")
    parser.add_argument("--rls-decision")
    parser.add_argument("--controls")
    parser.add_argument("--provenance", choices=PROVENANCE, default="inferred")
    parser.add_argument("--census-out", default="source-object-census.json")
    parser.add_argument("--coverage-out", default="coverage.json")
    parser.add_argument("--controls-out", default="sisense-controls-coverage.json")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    workdir = Path(args.workdir).expanduser().resolve()
    if not workdir.is_dir():
        raise AccountingError("--workdir is not a directory: %s" % workdir)
    paths = {
        "gap": artifact(workdir, args.gap_report, ("gap-report.json",)),
        "model": artifact(workdir, args.model, ("discovery/model.json",)),
        "dashboards": artifact(workdir, args.dashboards, ("discovery/dashboards.json",)),
        "jaql": artifact(workdir, args.jaql_mapping, ("parity-plan.json", "jaql-mapping.json")),
        "dm": artifact(workdir, args.dm_readback or args.dm_spec,
                       ("dm-readback.json", "sigma_dm_spec.json")),
        "wb": artifact(workdir, args.wb_readback or args.wb_spec,
                       ("wb-readback.json", "sigma_workbook_spec.json")),
        "parity": artifact(workdir, args.parity_final, ("parity-final.json",)),
        "security": artifact(workdir, args.security, ("security.json", "rls-findings.json")),
        "rls_decision": artifact(workdir, args.rls_decision, ("rls-decision.json",)),
        "controls": artifact(workdir, args.controls, ("probe-controls/probe-results.json",)),
    }
    docs = {
        "gap": read_json(paths["gap"], required=True),
        "model": read_json(paths["model"]),
        "dashboards": read_json(paths["dashboards"]),
        "jaql": read_json(paths["jaql"]),
        "dm": read_json(paths["dm"]),
        "wb": read_json(paths["wb"]),
        "parity": read_json(paths["parity"]),
        "security": read_json(paths["security"]),
        "rls_decision": read_json(paths["rls_decision"]),
        "controls": read_json(paths["controls"]),
    }
    accountant = Accountant(args, paths, docs)
    accountant.run()
    census, coverage, controls = accountant.outputs()
    for name, value in (
        (args.census_out, census),
        (args.coverage_out, coverage),
        (args.controls_out, controls),
    ):
        output = Path(name)
        write_json(output if output.is_absolute() else workdir / output, value)
    print("Sisense accounting: %d/%d objects, %d filter(s), complete=%s" %
          (census["summary"]["accounted"], census["summary"]["total"],
           controls["summary"]["sourceFilters"], census["summary"]["complete"]))
    if accountant.errors:
        for error in sorted(set(accountant.errors)):
            print("ERROR: " + error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AccountingError as error:
        print("build-sisense-accounting: %s" % error, file=sys.stderr)
        sys.exit(2)
