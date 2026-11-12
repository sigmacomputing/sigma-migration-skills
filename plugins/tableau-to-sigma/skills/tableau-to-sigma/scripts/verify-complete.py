#!/usr/bin/env python3
"""Fail-closed completion gate for the Tableau Python migration path."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import workdir_guard  # noqa: E402
import relationship_coverage as relationship_coverage_lib  # noqa: E402
import relationship_map as relationship_map_lib  # noqa: E402
import relationship_route as relationship_route_lib  # noqa: E402
import dashboard_coverage as dashboard_coverage_lib  # noqa: E402
import sql_provenance as sql_provenance_lib  # noqa: E402
import blind_grade_v2 as blind_grade_v2_lib  # noqa: E402
from migration_diagnostics import Span  # noqa: E402


def load(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def evaluate(workdir: Path, blind_grade: Path) -> dict:
    failures = []
    required = {
        "mission": workdir / "mission.json",
        "data_model_readback": workdir / "datamodel-readback-verdict.json",
        "workbook_readback": workdir / "workbook-readback-verdict.json",
        "parity": workdir / "parity-final.json",
        "anchors": workdir / "anchors-verdict.json",
        "visual_similarity": workdir / "visual-similarity-final.json",
        "semantic_edits": workdir / "semantic-edits.json",
        "relationship_coverage": workdir / "relationship-coverage.json",
        "dashboard_coverage": workdir / "dashboard-coverage.json",
        "sql_provenance": workdir / "sql-provenance.json",
        "reconstruction_integrity": workdir / "reconstruction-integrity.json",
        "source_census": workdir / "source-object-census.json",
        "security_decision": workdir / "security-decision.json",
        "data_model_ids": workdir / "dm-ids.json",
        "workbook_ids": workdir / "wb-ids.json",
        "blind_grade": blind_grade,
    }
    # Reused-DM evidence route: relationship-map.json replaces
    # relationship-coverage.json (judged below).
    relationship_evidence = relationship_route_lib.current(workdir) is not None
    if relationship_evidence:
        required.pop("relationship_coverage")
    verification_path = workdir / "verification-result.json"
    if verification_path.exists() or verification_path.is_symlink():
        required["independent_verification"] = verification_path
    documents = {}
    for name, path in required.items():
        if not path.is_file():
            failures.append(f"{name}: missing {path.name}")
            continue
        try:
            documents[name] = load(path)
        except (OSError, ValueError, RecursionError) as exc:
            failures.append(f"{name}: unreadable ({exc})")

    verification = documents.get("independent_verification", {})
    divergences = verification.get("divergences", [])
    verification_pass = verification.get("verdict") == "GREEN" and isinstance(divergences, list) and all(
        isinstance(entry, dict) and entry.get("severity") == "cosmetic" for entry in divergences
    )
    if "independent_verification" in required and not verification_pass:
        failures.append("independent_verification: current verifier result is not GREEN; earlier passing evidence cannot override it")

    mission = documents.get("mission") or {}
    inferred = [
        key
        for key, value in mission.items()
        if isinstance(value, dict) and value.get("provenance") != "stated"
    ]
    if inferred:
        failures.append("mission has unstated field(s): " + ", ".join(inferred))

    for key in ("data_model_readback", "workbook_readback"):
        if documents.get(key, {}).get("pass") is not True:
            failures.append(f"{key}: readback verdict is not pass")
    if documents.get("parity", {}).get("match") is not True:
        failures.append("parity: numeric source/target comparison failed")
    if documents.get("anchors", {}).get("pass") is not True:
        failures.append("anchors: source values or displayed-tile health failed")
    visual = documents.get("visual_similarity") or {}
    visual_pass = visual.get("pass") is True or visual.get("status") == "PASS"
    if not visual_pass:
        failures.append("visual_similarity: machine floor failed")
    if documents.get("semantic_edits", {}).get("match") is not True:
        failures.append("semantic_edits: structural proof missing or failed")
    relationship_gate_pass = False
    relationship_doc = documents.get("relationship_coverage")
    metadata_path = workdir / "conv-meta.json"
    source_path = workdir / "workbook-content.twb"
    relationship_model = next(
        (
            path
            for path in (
                workdir / "datamodel-readback.json",
                workdir / "dm-remapped.json",
                workdir / "dm-raw.json",
                workdir / "dm-spec.json",
            )
            if path.is_file()
        ),
        None,
    )
    if relationship_evidence:
        relationship_result = relationship_map_lib.evaluate_workdir(workdir, final=True)
        relationship_gate_pass = relationship_result["status"] == "pass"
        if not relationship_gate_pass:
            failures.append(
                "relationship_coverage: reused-dm evidence unproven — "
                + "; ".join(f"{b['kind']}: {b['reason']}" for b in relationship_result["blockers"])
            )
            relationship_gate_pass = None
    elif relationship_doc is not None:
        try:
            expected_relationships = relationship_coverage_lib.from_files(
                metadata_path, source_path, relationship_model
            )
            relationship_gate_pass = (
                relationship_doc == expected_relationships
                and expected_relationships.get("status") != "fail"
            )
        except (OSError, ValueError, json.JSONDecodeError):
            relationship_gate_pass = False
    if relationship_gate_pass is False:
        failures.append(
            "relationship_coverage: artifact is stale, unwired, partial, or unreadable"
        )
    dashboard_gate_pass = False
    dashboard_doc = documents.get("dashboard_coverage")
    dashboard_spec = next(
        (
            path
            for path in (
                workdir / "workbook-readback.json",
                workdir / "wb-spec-python.json",
                workdir / "wb-spec.resolved.json",
                workdir / "wb-spec.json",
            )
            if path.is_file()
        ),
        None,
    )
    try:
        dashboard_scope = load(workdir / "dashboard-scope.json")
        expected_dashboards = dashboard_coverage_lib.evaluate(
            workdir / "workbook-content.twb",
            dashboard_spec,
            dashboard_scope,
            workdir / "story-plan.json",
        )
        dashboard_gate_pass = (
            dashboard_doc == expected_dashboards
            and expected_dashboards.get("status") == "pass"
        )
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        dashboard_gate_pass = False
    if not dashboard_gate_pass:
        failures.append(
            "dashboard_coverage: visible in-scope Tableau dashboard is missing "
            "or the artifact is stale"
        )
    sql_gate_pass = False
    sql_doc = documents.get("sql_provenance")
    try:
        sql_spec = sql_provenance_lib.active_spec_path(workdir)
        expected_sql = sql_provenance_lib.evaluate(
            sql_spec,
            workdir / "conv-meta.json",
            workdir / "workbook-content.twb",
            workdir / "custom-sql.json",
            workdir / "sql-provenance-overrides.json",
        )
        sql_gate_pass = sql_doc == expected_sql and expected_sql.get("status") == "pass"
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        sql_gate_pass = False
    if not sql_gate_pass:
        failures.append(
            "sql_provenance: a data-model SQL element is unattributed or the artifact is stale"
        )
    reconstruction_pass = (
        documents.get("reconstruction_integrity", {}).get("status") == "PASS"
    )
    if not reconstruction_pass:
        failures.append(
            "reconstruction_integrity: unfinished controls or renamed chart-family "
            "substitutions remain"
        )
    census = documents.get("source_census") or {}
    census_summary = census.get("summary") or {}
    source_objects = census.get("objects") or []
    if (
        census_summary.get("complete") is not True
        or census_summary.get("total") != len(source_objects)
    ):
        failures.append("source_census: accounting is incomplete")
    security = documents.get("security_decision") or {}
    if security.get("decision") not in {"not-required", "port", "customize", "skip"}:
        failures.append("security_decision: missing or invalid")
    blind = documents.get("blind_grade") or {}
    graded = (
        blind_grade_v2_lib.evaluate_grade_set(blind_grade)
        if "blind_grade" in documents
        else {"v2": False}
    )
    v2 = graded["v2"]
    bind_docs = list(zip(graded["docs"], graded["paths"])) if v2 else [(blind, blind_grade)]
    for doc, doc_path in bind_docs:
        label = "" if doc_path == blind_grade else f"{doc_path.name} "
        for path_key, hash_key, health_key in (
            ("source_png", "source_sha256", "source_health"),
            ("target_png", "target_sha256", "render_health"),
        ):
            image_path = Path(str(doc.get(path_key) or ""))
            expected_hash = doc.get(hash_key)
            measured_path = Path(str((visual.get(health_key) or {}).get("path") or ""))
            if not image_path.is_file() or not expected_hash:
                failures.append(f"blind_grade: {label}missing bound {path_key}")
            elif sha256(image_path) != expected_hash:
                failures.append(f"blind_grade: {label}stale {path_key} hash")
            elif not measured_path.is_file() or image_path.resolve() != measured_path.resolve():
                failures.append(
                    f"blind_grade: {label}{path_key} does not match visual-similarity input"
                )
    failed_dimensions: list[str] = []
    visual_fidelity = None
    degradations: list[dict] = []
    platform_differences: list[dict] = []
    polish_notes: list[dict] = []
    blind_gate_pass = False
    if v2:
        # blind-grade/v2: an INVALID grade (catalog/sha/borderline/second-grade rules)
        # blocks; a VALID but unfaithful grade only forfeits GREEN (YELLOW).
        for problem in graded["errors"]:
            failures.append(f"blind_grade: {problem}")
        decision = graded["decision"]
        if decision is not None:
            blind_gate_pass = True
            artifact = blind_grade.name
            visual_fidelity = {
                "schema": blind_grade_v2_lib.SCHEMA_V2,
                "faithful": decision["faithful"],
                "score": decision["score"],
                "grades": len(graded["docs"]),
                "reasons": decision["reasons"],
                "fixable_major": decision["fixable_major"],
                "residuals": decision["residuals"],
            }
            degradations.extend(blind_grade_v2_lib.v2_degradations(decision, artifact))
            polish_notes = blind_grade_v2_lib.v2_polish_notes(decision, artifact)
            for gap in decision["platform_differences"]:
                platform_differences.append(
                    {
                        "item": f"{gap.get('tile')}: {gap.get('description')}",
                        "catalog_id": str(gap.get("class")),
                        "source_artifact": artifact,
                    }
                )
    else:
        failed_dimensions = [
            name
            for name, value in (blind.get("dimensions") or {}).items()
            if value.get("verdict") != "pass"
        ]
        if blind.get("verdict") != "pass" or failed_dimensions:
            failures.append(
                "blind_grade: visual fidelity failed"
                + (f" ({', '.join(failed_dimensions)})" if failed_dimensions else "")
            )
        blind_gate_pass = blind.get("verdict") == "pass" and not failed_dimensions

    dm_ids = documents.get("data_model_ids") or {}
    wb_ids = documents.get("workbook_ids") or {}
    yellow = (
        security.get("decision") == "skip"
        or bool(degradations)
        or (visual_fidelity is not None and not visual_fidelity["faithful"])
    ) or any(
        item.get("status") in {"approximated", "needs-review", "skipped"}
        for item in source_objects
        if isinstance(item, dict)
    )
    verdict = "BLOCKED" if failures else ("YELLOW" if yellow else "GREEN")
    counts = {
        status: sum(item.get("status") == status for item in source_objects)
        for status in (
            "migrated",
            "approximated",
            "needs-review",
            "skipped",
            "not-applicable",
        )
    }
    gates = {
        "mission": not inferred and "mission" in documents,
        "data_model_readback": documents.get("data_model_readback", {}).get("pass") is True,
        "workbook_readback": documents.get("workbook_readback", {}).get("pass") is True,
        "source_accounting": census_summary.get("complete") is True,
        "numeric_parity": documents.get("parity", {}).get("match") is True,
        "source_anchors": documents.get("anchors", {}).get("pass") is True,
        "visual_floor": visual_pass,
        "blind_visual_grade": blind_gate_pass,
        "semantic_edit_proof": documents.get("semantic_edits", {}).get("match") is True,
        "relationship_coverage": relationship_gate_pass,
        "dashboard_coverage": dashboard_gate_pass,
        "sql_provenance": sql_gate_pass,
        "reconstruction_integrity": reconstruction_pass,
        "security_decision": security.get("decision") in {"not-required", "port", "customize", "skip"},
    }
    if "independent_verification" in required:
        gates["independent_verification"] = verification_pass
    result = {
        "schema_version": 1,
        "status": verdict,
        "verdict": verdict,
        "complete": not failures,
        "dataModelId": dm_ids.get("dataModelId"),
        "workbookId": wb_ids.get("workbookId"),
        "summary": {
            "complete": not failures and census_summary.get("complete") is True,
            "total": len(source_objects),
            "accounted": len(source_objects),
            "counts": counts,
        },
        "source_objects": source_objects,
        "checks": [
            {"name": "source-accounting", "status": "PASS" if gates["source_accounting"] else "FAIL"},
            {"name": "parity", "status": "PASS" if gates["numeric_parity"] else "FAIL"},
            {
                "name": "render",
                "status": (
                    "PASS"
                    if gates["visual_floor"] and gates["blind_visual_grade"]
                    else "FAIL"
                ),
            },
        ],
        "failures": failures,
        "gates": gates,
    }
    if visual_fidelity is not None:
        result["visual_fidelity"] = visual_fidelity
        result["degradations"] = degradations
        result["platform_differences"] = platform_differences
        result["polish_notes"] = polish_notes
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument(
        "--blind-grade",
        required=True,
        help="blind grade JSON; an optional second grade is taken from blind-grade-2.json "
        "in the same directory (sibling-file convention, borderline first grade only)",
    )
    args = parser.parse_args()
    workdir_guard.check(args.workdir, "--workdir")
    workdir = Path(args.workdir).expanduser().resolve()
    if (workdir / "repair-pending.json").exists() or (workdir / "repair-pending.json").is_symlink():
        print("NOT DONE: repair-pending.json records an unverified write outcome; recover and reverify.", file=sys.stderr)
        return 1
    span = Span(workdir, "completion", "verify-complete.py")
    try:
        output = workdir / "migration-result.json"
        if output.exists() or output.is_symlink():
            history = workdir / "report-history"
            if history.is_symlink():
                raise ValueError("report history must not be a symlink")
            history.mkdir(mode=0o700, exist_ok=True)
            output.rename(history / ("migration-result-" + uuid.uuid4().hex + ".json"))
        result = evaluate(workdir, Path(args.blind_grade).expanduser().resolve())
        (workdir / "migration-result.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, RecursionError) as exc:
        span.finish(2)
        print(f"FATAL: completion gate could not run: {exc}", file=sys.stderr)
        return 2
    if not result["complete"]:
        span.finish(1)
        print("BLOCKED: Tableau Python migration is not complete", file=sys.stderr)
        for failure in result["failures"]:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"DONE: {result['verdict']} dataModelId={result['dataModelId']} "
        f"workbookId={result['workbookId']}"
    )
    span.finish(0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
