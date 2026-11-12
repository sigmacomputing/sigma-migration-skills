#!/usr/bin/env python3
"""Build deterministic Qlik migration reports from completion artifacts."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

try:  # optional: the report stays runnable standalone without the ledger module
    sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
    import degradation_ledger
except ImportError:  # pragma: no cover - standalone fallback
    degradation_ledger = None

TERMINAL = (
    "migrated",
    "approximated",
    "needs-review",
    "skipped",
    "not-applicable",
)
STATUS_ALIASES = {
    **{value: "migrated" for value in (
        "migrated", "complete", "completed", "converted", "built", "emitted",
        "resolved", "pass", "passed",
    )},
    **{value: "approximated" for value in (
        "approximated", "approximate", "approximation", "substituted",
    )},
    **{value: "needs-review" for value in (
        "needs-review", "review", "pending-review", "unresolved", "needs-wiring",
        "needs-materialization", "degraded", "partial",
    )},
    **{value: "skipped" for value in (
        "skipped", "skip", "dropped", "omitted", "excluded", "not-emitted",
    )},
    **{value: "not-applicable" for value in ("not-applicable", "n-a", "na")},
}
STATUS_KEYS = (
    "terminal_status", "terminalStatus", "migration_status", "migrationStatus",
    "accounting_status", "accountingStatus", "status", "outcome", "disposition",
    "result", "severity",
)
RECORD_KEYS = (
    "objects", "source_objects", "accounting", "statuses", "records", "coverage",
    "detail", "unresolved", "items",
)
ID_KEYS = (
    "id", "object_id", "objectId", "source_object_id", "sourceObjectId",
    "source_id", "sourceId", "luid", "guid", "key",
)
NAME_KEYS = (
    "name", "object_name", "objectName", "source_object_name", "sourceObjectName",
    "title", "visual", "control",
)
TYPE_KEYS = ("type", "object_type", "objectType", "source_type", "sourceType", "kind")
INVENTORY_NAMES = (
    "source-inventory.json",
    "source-object-census.json",
    "inventory.json",
)
FAIL_WORDS = {
    "fail", "failed", "failure", "error", "red", "unhealthy", "blank",
    "divergent", "not-executable", "high-risk", "risky",
}
PASS_WORDS = {
    "pass", "passed", "ok", "green", "healthy", "clear", "no-risk", "success",
    "successful",
}


class ReportError(RuntimeError):
    pass


def fold(value: Any) -> str:
    return str(value or "").strip().casefold()


def status_key(value: Any) -> str:
    return re.sub(r"[/_\s]+", "-", fold(value))


def normalize_status(value: Any) -> str | None:
    return STATUS_ALIASES.get(status_key(value)) if isinstance(value, str) else None


def read_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise ReportError(f"missing JSON artifact: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ReportError(f"malformed JSON artifact {path}: {exc}") from exc
    except OSError as exc:
        raise ReportError(f"cannot read JSON artifact {path}: {exc}") from exc


def first_value(row: dict[str, Any], keys: Iterable[str]) -> Any:
    for key in keys:
        value = row.get(key)
        if value is not None and str(value).strip():
            return value
    return None


def number(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        return int(float(value))
    except (TypeError, ValueError, OverflowError):
        return None


def first_numeric(row: dict[str, Any], keys: Iterable[str]) -> int | None:
    for key in keys:
        if key in row:
            value = number(row[key])
            if value is not None:
                return value
    return None


def singularize(value: Any) -> str:
    word = str(value or "").strip()
    if word.casefold().endswith("ies"):
        return word[:-3] + "y"
    return word[:-1] if word.casefold().endswith("s") else word


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


class MigrationReport:
    def __init__(self, workdir: Path, inventory_path: Path):
        self.workdir = workdir.resolve()
        self.inventory_path = inventory_path.resolve()
        self.artifacts: list[dict[str, Any]] = []
        self.artifact_docs: dict[Path, Any] = {}
        self.input_errors: list[str] = []
        self.unknown_records: list[str] = []
        self.duplicate_inventory: list[str] = []
        self.objects: list[dict[str, Any]] = []
        self.document: dict[str, Any] | None = None

    def display_path(self, path: Path) -> str:
        try:
            return str(path.resolve().relative_to(self.workdir))
        except ValueError:
            return str(path.resolve())

    def add_artifact(self, kind: str, path: Path, present: bool) -> None:
        self.artifacts.append(
            {"kind": kind, "path": self.display_path(path), "present": present}
        )

    def load_artifact(self, kind: str, path: Path) -> None:
        if not path.is_file():
            if kind not in {"controls-coverage", "render-health", "blank-risk"}:
                self.add_artifact(kind, path, False)
            return
        self.artifact_docs[path.resolve()] = read_json(path)
        self.add_artifact(kind, path, True)

    def load_optional_artifacts(self) -> None:
        for kind, name in (
            ("coverage", "coverage.json"),
            ("degradation-ledger", "degradation-ledger.json"),
            ("parity", "parity-final.json"),
            ("waivers", "waivers.json"),
        ):
            self.load_artifact(kind, self.workdir / name)
        for path in sorted(self.workdir.glob("*-controls-coverage.json")):
            self.load_artifact("controls-coverage", path)
        for kind, patterns in (
            (
                "render-health",
                ("*render-health*.json", "*render_health*.json",
                 "render-health/**/*.json", "render_health/**/*.json"),
            ),
            (
                "blank-risk",
                ("*blank-risk*.json", "*blank_risk*.json",
                 "blank-risk/**/*.json", "blank_risk/**/*.json"),
            ),
        ):
            found: set[Path] = set()
            for pattern in patterns:
                found.update(path for path in self.workdir.glob(pattern) if path.is_file())
            for path in sorted(found):
                self.load_artifact(kind, path)
            if not any(row["kind"] == kind for row in self.artifacts):
                self.add_artifact(kind, self.workdir / f"{kind}.json", False)
        # Machine render evidence written by the gates themselves; recorded
        # only when present, like the health artifacts above.
        for kind in ("visual-similarity", "anchors-verdict", "finalize-gates"):
            path = self.workdir / f"{kind}.json"
            if path.is_file():
                self.load_artifact(kind, path)

    def inventory_rows(self, document: Any) -> list[tuple[Any, str]]:
        if isinstance(document, list):
            return [(row, "object") for row in document]
        if not isinstance(document, dict):
            raise ReportError("source inventory must be a JSON object or array")
        for key in ("objects", "source_objects", "sourceObjects", "inventory", "items"):
            value = document.get(key)
            if isinstance(value, (list, dict)):
                return self.rows_from_container(value, key)
        ignored = {
            "summary", "metadata", "accounting", "statuses", "records", "coverage",
            "checks", "artifacts", "waivers",
        }
        result: list[tuple[Any, str]] = []
        for key in sorted(document):
            value = document[key]
            if key not in ignored and isinstance(value, list):
                result.extend((row, key) for row in value)
        return result

    def rows_from_container(self, container: Any, default_type: str) -> list[tuple[Any, str]]:
        if isinstance(container, list):
            return [(row, default_type) for row in container]
        result: list[tuple[Any, str]] = []
        if not isinstance(container, dict):
            return result
        for kind in sorted(container):
            value = container[kind]
            if isinstance(value, list):
                result.extend((row, kind) for row in value)
            elif isinstance(value, dict) and self.status_from(value):
                result.append(({**value, "id": kind}, default_type))
        return result

    def object_key(self, kind: str, object_id: str, name: str) -> str:
        identity = fold(object_id) if object_id else f"name:{fold(name)}"
        return f"{fold(kind)}:{identity}"

    def normalize_inventory(self, document: Any) -> None:
        rows = self.inventory_rows(document)
        if not rows:
            raise ReportError("source inventory contains no recognizable objects")
        seen: dict[str, dict[str, Any]] = {}
        for index, (raw, inferred_type) in enumerate(rows):
            if not isinstance(raw, dict):
                self.input_errors.append(f"inventory object {index} is not a JSON object")
                continue
            kind = str(first_value(raw, TYPE_KEYS) or "").strip()
            kind = kind or singularize(inferred_type) or "object"
            object_id = str(first_value(raw, ID_KEYS) or "").strip()
            name = str(first_value(raw, NAME_KEYS) or "").strip()
            if not object_id and not name:
                self.input_errors.append(f"inventory object {index} has neither id nor name")
                continue
            key = self.object_key(kind, object_id, name)
            if key in seen:
                self.duplicate_inventory.append(key)
                continue
            row = {
                "key": key,
                "type": kind,
                "id": object_id,
                "name": name,
                "status": "missing",
                "status_sources": [],
                "_raw": raw,
            }
            seen[key] = row
            self.objects.append(row)
        if self.input_errors:
            raise ReportError("; ".join(self.input_errors))
        self.objects.sort(key=lambda row: (fold(row["type"]), fold(row["id"]), fold(row["name"])))

    def status_from(self, record: Any) -> str | None:
        if not isinstance(record, dict):
            return None
        for key in STATUS_KEYS:
            status = normalize_status(record.get(key))
            if status:
                return status
        return None

    def records_from_container(
        self, container: Any, inferred_type: str | None
    ) -> list[tuple[dict[str, Any], str | None]]:
        if isinstance(container, list):
            return [(row, inferred_type) for row in container if isinstance(row, dict)]
        if not isinstance(container, dict):
            return []
        if self.status_from(container) and (
            first_value(container, ID_KEYS) is not None
            or first_value(container, NAME_KEYS) is not None
        ):
            return [(container, inferred_type)]
        result: list[tuple[dict[str, Any], str | None]] = []
        for key in sorted(container):
            value = container[key]
            if isinstance(value, list):
                result.extend((row, key) for row in value if isinstance(row, dict))
            elif isinstance(value, dict):
                result.append(({**value, "id": key}, inferred_type))
            elif normalize_status(value):
                result.append(({"id": key, "status": value}, inferred_type))
        return result

    def records_from_document(
        self, document: Any, external: bool
    ) -> list[tuple[dict[str, Any], str | None]]:
        if isinstance(document, list):
            return [(row, None) for row in document if isinstance(row, dict)]
        if not isinstance(document, dict):
            return []
        keys = RECORD_KEYS if external else ("accounting", "statuses", "records", "coverage")
        result: list[tuple[dict[str, Any], str | None]] = []
        for key in keys:
            if key in document:
                result.extend(self.records_from_container(document[key], None))
        return result

    def add_status(
        self, obj: dict[str, Any], status: str, source: str, record: dict[str, Any]
    ) -> None:
        detail = (
            record.get("reason")
            or record.get("detail")
            or record.get("notes")
            or record.get("evidence")
        )
        evidence: dict[str, Any] = {"status": status, "artifact": source}
        if detail is not None and str(detail):
            evidence["detail"] = str(detail)
        if evidence not in obj["status_sources"]:
            obj["status_sources"].append(evidence)

    def add_status_from_record(
        self, obj: dict[str, Any], record: dict[str, Any], source: str
    ) -> None:
        status = self.status_from(record)
        if status:
            self.add_status(obj, status, source, record)
        accounting = record.get("accounting")
        direct = normalize_status(accounting)
        if direct:
            self.add_status(obj, direct, f"{source}#object-accounting", record)
        if isinstance(accounting, dict):
            nested = self.status_from(accounting)
            if nested:
                self.add_status(obj, nested, f"{source}#object-accounting", accounting)
        elif isinstance(accounting, list):
            for index, row in enumerate(accounting):
                nested = self.status_from(row)
                if nested and isinstance(row, dict):
                    self.add_status(
                        obj, nested, f"{source}#object-accounting[{index}]", row
                    )

    def match_object(self, kind: str, object_id: str, name: str) -> dict[str, Any] | None:
        if object_id:
            candidates = [row for row in self.objects if fold(row["id"]) == fold(object_id)]
            typed = [row for row in candidates if fold(row["type"]) == fold(kind)] if kind else []
            if len(typed) == 1:
                return typed[0]
            if len(candidates) == 1:
                return candidates[0]
        if name:
            candidates = [row for row in self.objects if fold(row["name"]) == fold(name)]
            typed = [row for row in candidates if fold(row["type"]) == fold(kind)] if kind else []
            if len(typed) == 1:
                return typed[0]
            if len(candidates) == 1:
                return candidates[0]
        return None

    def apply_record(self, record: dict[str, Any], inferred: str | None, source: str) -> None:
        status = self.status_from(record)
        if not status:
            return
        reference = (
            record.get("source_object")
            if isinstance(record.get("source_object"), dict)
            else record.get("object")
            if isinstance(record.get("object"), dict)
            else record
        )
        kind = str(first_value(reference, TYPE_KEYS) or "").strip()
        kind = kind or singularize(inferred)
        object_id = str(first_value(reference, ID_KEYS) or "").strip()
        name = str(first_value(reference, NAME_KEYS) or "").strip()
        obj = self.match_object(kind, object_id, name)
        if obj:
            self.add_status(obj, status, source, record)
        elif object_id or name:
            self.unknown_records.append(
                f"{source} refers to unknown {kind or 'object'} {object_id or name}"
            )

    def collect_accounting(self, inventory: Any) -> None:
        source = self.display_path(self.inventory_path)
        for obj in self.objects:
            self.add_status_from_record(obj, obj.pop("_raw"), source)
        for index, (record, inferred) in enumerate(
            self.records_from_document(inventory, False)
        ):
            self.apply_record(record, inferred, f"{source}#accounting[{index}]")
        for path in sorted(self.artifact_docs):
            artifact = next(
                (
                    row
                    for row in self.artifacts
                    if row["present"]
                    and (self.workdir / row["path"]).resolve() == path
                ),
                None,
            )
            if not artifact or artifact["kind"] not in {"coverage", "controls-coverage"}:
                continue
            for index, (record, inferred) in enumerate(
                self.records_from_document(self.artifact_docs[path], True)
            ):
                self.apply_record(
                    record,
                    inferred,
                    f"{self.display_path(path)}#record[{index}]",
                )
        for obj in self.objects:
            statuses = list(dict.fromkeys(row["status"] for row in obj["status_sources"]))
            obj["status"] = (
                "missing" if not statuses else statuses[0] if len(statuses) == 1 else "contradictory"
            )

    @staticmethod
    def check(name: str, status: str, message: str) -> dict[str, str]:
        return {"name": name, "status": status, "message": message}

    def accounting_check(self) -> dict[str, str]:
        missing = [row for row in self.objects if row["status"] == "missing"]
        contradictory = [row for row in self.objects if row["status"] == "contradictory"]
        if not missing and not contradictory:
            return self.check(
                "source-accounting",
                "PASS",
                f"{len(self.objects)}/{len(self.objects)} source objects accounted for",
            )
        details = []
        if missing:
            details.append("missing: " + ", ".join(row["key"] for row in missing))
        if contradictory:
            details.append(
                "contradictory: " + ", ".join(row["key"] for row in contradictory)
            )
        return self.check("source-accounting", "FAIL", "; ".join(details))

    def status_consistency_check(self) -> dict[str, str]:
        errors = []
        if self.duplicate_inventory:
            errors.append(
                "duplicate inventory identities: "
                + ", ".join(sorted(set(self.duplicate_inventory)))
            )
        errors.extend(sorted(self.unknown_records))
        for obj in self.objects:
            if obj["status"] == "contradictory":
                statuses = sorted({row["status"] for row in obj["status_sources"]})
                errors.append(f"{obj['key']} has statuses {' and '.join(statuses)}")
        return self.check(
            "status-consistency",
            "FAIL" if errors else "PASS",
            "; ".join(errors) if errors else "no duplicate contradictory status records",
        )

    def artifact_consistency_check(self, inventory: Any) -> dict[str, str]:
        errors = []
        summary = inventory.get("summary") if isinstance(inventory, dict) else None
        if isinstance(summary, dict):
            declared = first_numeric(
                summary,
                ("total", "total_objects", "totalObjects", "source_objects",
                 "sourceObjects", "object_count", "objectCount", "count"),
            )
            if declared is not None and declared != len(self.objects):
                errors.append(f"inventory summary total {declared} != {len(self.objects)}")
            for status in TERMINAL:
                declared_status = first_numeric(summary, (status, status.replace("-", "_")))
                actual = sum(row["status"] == status for row in self.objects)
                if declared_status is not None and declared_status != actual:
                    errors.append(
                        f"inventory summary {status}={declared_status} != {actual}"
                    )
        ledger = self.artifact_docs.get((self.workdir / "degradation-ledger.json").resolve())
        if isinstance(ledger, dict) and isinstance(ledger.get("counts"), dict):
            actual = Counter(
                str(row.get("class") or "")
                for row in ledger.get("entries") or []
                if isinstance(row, dict)
            )
            for kind in sorted(set(map(str, ledger["counts"])) | set(actual)):
                if number(ledger["counts"].get(kind, 0)) != actual.get(kind, 0):
                    errors.append(
                        f"degradation ledger {kind}={ledger['counts'].get(kind, 0)} "
                        f"!= {actual.get(kind, 0)}"
                    )
        waivers = self.artifact_docs.get((self.workdir / "waivers.json").resolve())
        if isinstance(waivers, dict):
            declared = first_numeric(waivers, ("count", "waiver_count", "waiverCount"))
            entries = waivers.get("waivers") or []
            if declared is not None and declared != len(entries):
                errors.append(f"waivers count {declared} != {len(entries)}")
        parity = self.artifact_docs.get((self.workdir / "parity-final.json").resolve())
        if isinstance(parity, dict):
            declared = first_numeric(parity, ("waiver_count", "waiverCount"))
            entries = parity.get("waivers") or []
            if declared is not None and declared != len(entries):
                errors.append(f"parity waiver_count {declared} != {len(entries)}")
        return self.check(
            "artifact-consistency",
            "FAIL" if errors else "PASS",
            "; ".join(errors) if errors else "artifact summaries agree with detail records",
        )

    def paths_for_kind(self, kind: str) -> list[Path]:
        return [
            (self.workdir / row["path"]).resolve()
            for row in self.artifacts
            if row["kind"] == kind and row["present"]
        ]

    def controls_check(self) -> dict[str, str]:
        paths = self.paths_for_kind("controls-coverage")
        if not paths:
            return self.check(
                "controls-coverage", "PASS", "no controls coverage artifact supplied"
            )
        malformed = [
            path
            for path in paths
            if not isinstance(self.artifact_docs.get(path), dict)
            or not isinstance(self.artifact_docs[path].get("detail"), list)
        ]
        if malformed:
            return self.check(
                "controls-coverage",
                "FAIL",
                "malformed detail rows: "
                + ", ".join(self.display_path(path) for path in malformed),
            )
        rows = sum(len(self.artifact_docs[path]["detail"]) for path in paths)
        return self.check(
            "controls-coverage", "PASS", f"{rows} source control records consumed"
        )

    def parity_check(self) -> dict[str, str]:
        parity = self.artifact_docs.get((self.workdir / "parity-final.json").resolve())
        if not isinstance(parity, dict):
            return self.check("parity", "FAIL", "parity-final.json is missing")
        state = fold(parity.get("status") or parity.get("verdict") or parity.get("result"))
        errors = []
        if state not in PASS_WORDS:
            errors.append(f"parity status is {state or 'not recorded'}")
        passed = first_numeric(parity, ("charts_pass", "passed", "pass"))
        total = first_numeric(parity, ("charts_total", "total"))
        if passed is not None and total is not None and passed != total:
            errors.append(f"charts_pass {passed} != charts_total {total}")
        return self.check(
            "parity", "FAIL" if errors else "PASS", "; ".join(errors) if errors else state
        )

    def health_state(self, document: Any) -> str:
        signals: list[str] = []

        def walk(value: Any) -> None:
            if isinstance(value, list):
                for item in value:
                    walk(item)
            elif isinstance(value, dict):
                for key, item in value.items():
                    normalized = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", str(key)).casefold().replace("-", "_")
                    word = fold(item)
                    if normalized in {"status", "verdict", "result", "health", "state"}:
                        if word in FAIL_WORDS:
                            signals.append("fail")
                        if word in PASS_WORDS:
                            signals.append("pass")
                    elif (
                        normalized.endswith("healthy")
                        or normalized.endswith("health_ok")
                        or normalized in {"healthy", "ok", "passed", "success", "rendered",
                                          "render_success", "valid"}
                    ) and isinstance(item, bool):
                        signals.append("pass" if item else "fail")
                    elif normalized == "risk" and isinstance(item, bool):
                        signals.append("fail" if item else "pass")
                    elif "risk" in normalized and isinstance(item, str):
                        if word in {"high", "high-risk", "risky", "red"}:
                            signals.append("fail")
                        if word in {"none", "low", "clear", "no-risk", "green"}:
                            signals.append("pass")
                    elif re.search(r"(?:blank|failure|failed|error).*count", normalized):
                        numeric = number(item)
                        if numeric is not None:
                            signals.append("fail" if numeric > 0 else "pass")
                    elif normalized in {"failures", "errors"} and isinstance(item, list):
                        signals.append("pass" if not item else "fail")
                    elif re.search(r"(?:blank_risk|at_risk|is_blank)", normalized) and isinstance(item, bool):
                        signals.append("fail" if item else "pass")
                    walk(item)

        walk(document)
        return "fail" if "fail" in signals else "pass" if "pass" in signals else "unknown"

    def visual_similarity_evidence(self) -> tuple[str, str | None] | None:
        """visual-similarity.json is render evidence only through its
        render_health record. None = nothing to vouch with; else (state,
        reason). A missing render image or non-PASS status fails. A majority of
        measured tiles being blank is also a render-health failure (the same
        majority rule as visual-similarity.py, but armed at any measured count
        (> 0) on purpose: png_health's whole-image check only catches
        all-white, solid or near-empty images, so a page with chrome but 1-of-1
        or 2-of-2 blank tiles passes it; visual-similarity.py's
        TILE_MIN_MEASURED = 3 only guards the composite score against noise.
        Otherwise the artifact's composite pass flag is visual-fidelity
        evidence, not render-health evidence."""
        doc = self.artifact_docs.get((self.workdir / "visual-similarity.json").resolve())
        if not isinstance(doc, dict) or not isinstance(doc.get("render_health"), dict):
            return None
        health = doc["render_health"]
        image = health.get("path")
        if isinstance(image, str) and image.strip() and not (self.workdir / image).is_file():
            return ("fail", f"render image missing: {image}")
        blank = doc.get("tiles_blank")
        raw_measured = doc.get("tiles_measured")
        if isinstance(raw_measured, bool):
            measured = 0
        elif isinstance(raw_measured, int):
            measured = raw_measured
        elif isinstance(raw_measured, str) and re.fullmatch(r"[0-9]+", raw_measured):
            measured = int(raw_measured)
        else:
            measured = 0
        if isinstance(blank, list) and measured > 0 and 2 * len(blank) > measured:
            return ("fail", f"{len(blank)} of {measured} tiles blank")
        status = fold(health.get("status"))
        if status and status != "pass":
            return ("fail", f"render_health status {health.get('status')}")
        if not status:
            return None
        return ("pass", None)

    def anchors_tile_census(self) -> bool | None:
        doc = self.artifact_docs.get((self.workdir / "anchors-verdict.json").resolve())
        if not isinstance(doc, dict):
            return None
        value = doc.get("tiles_all_nonempty")
        return value if isinstance(value, bool) else None

    def empty_tiles_waived(self) -> bool:
        return any(
            row.get("flag") == "--allow-empty-tiles"
            or row.get("reason") == "--allow-empty-tiles"
            for row in self.waiver_entries()
        )

    def render_check(self) -> dict[str, str]:
        results: list[tuple[Path, str, str | None]] = [
            (path, self.health_state(self.artifact_docs[path]), None)
            for path in self.paths_for_kind("render-health")
        ]
        similarity = self.visual_similarity_evidence()
        if similarity:
            results.append((self.workdir / "visual-similarity.json", similarity[0], similarity[1]))
        parity = self.artifact_docs.get((self.workdir / "parity-final.json").resolve())
        if isinstance(parity, dict) and (
            "visual_checked" in parity or "visual_verdict" in parity
        ):
            verdict = fold(parity.get("visual_verdict"))
            visual_pass = (
                parity.get("visual_checked") is True and (not verdict or verdict == "pass")
            ) if "visual_checked" in parity else verdict == "pass"
            # Only a positive visual pass is render evidence; divergent /
            # not-executable is a fidelity residual (YELLOW via
            # visual_degradation), never an unhealthy render.
            if visual_pass:
                results.append((self.workdir / "parity-final.json", "pass", None))
        if not results:
            return self.check("render-health", "FAIL", "no healthy render evidence found")
        failed = [
            f"{self.display_path(path)} ({reason})" if reason else self.display_path(path)
            for path, state, reason in results
            if state != "pass"
        ]
        return self.check(
            "render-health",
            "FAIL" if failed else "PASS",
            (
                "unhealthy or indeterminate: "
                + ", ".join(failed)
                if failed
                else f"{len(results)} render health record(s) healthy"
            ),
        )

    def finalize_gates_check(self) -> dict[str, str] | None:
        """A converter finalize battery's recorded gate statuses: a failed gate
        makes the report RED (mirrors build-migration-report.rb)."""
        document = self.artifact_docs.get((self.workdir / "finalize-gates.json").resolve())
        if document is None:
            return None
        gates = document.get("gates") if isinstance(document, dict) else None
        if not isinstance(gates, dict) or not gates:
            return self.check("finalize-gates", "FAIL", "finalize-gates.json is malformed (no gates object)")
        failed = [
            (name, row) for name, row in gates.items()
            if fold(row.get("status") if isinstance(row, dict) else row) != "pass"
        ]
        if not failed:
            return self.check("finalize-gates", "PASS", f"{len(gates)} finalize gate(s) passed")
        names = [
            f"{name} (exit {row['exit']})" if isinstance(row, dict) and row.get("exit") else str(name)
            for name, row in failed
        ]
        return self.check("finalize-gates", "FAIL", "finalize gate(s) failed: " + ", ".join(names))

    def blank_check(self) -> dict[str, str]:
        paths = self.paths_for_kind("blank-risk")
        results = [(path, self.health_state(self.artifact_docs[path])) for path in paths]
        failed = [path for path, state in results if state == "fail"]
        unknown = [path for path, state in results if state == "unknown"]
        if failed:
            return self.check(
                "blank-risk",
                "FAIL",
                "blank risk detected: " + ", ".join(self.display_path(path) for path in failed),
            )
        if unknown:
            return self.check(
                "blank-risk",
                "FAIL",
                "blank risk indeterminate: "
                + ", ".join(self.display_path(path) for path in unknown),
            )
        # Any unwaived explicit FAIL signal wins, even over a clear blank-risk
        # artifact: the tile census saw empty displayed tiles.
        census = self.anchors_tile_census()
        if census is False:
            if self.empty_tiles_waived():
                return self.check(
                    "blank-risk",
                    "PASS",
                    "empty displayed tiles accepted via --allow-empty-tiles",
                )
            return self.check(
                "blank-risk", "FAIL", "anchors tile census found empty displayed tiles"
            )
        similarity = self.visual_similarity_evidence()
        if not paths:
            if self.paths_for_kind("render-health"):
                return self.check(
                    "blank-risk", "PASS", "covered by healthy render evidence"
                )
            if census is True:
                return self.check("blank-risk", "PASS", "covered by anchors tile census")
            if similarity and similarity[0] == "pass":
                return self.check(
                    "blank-risk", "PASS", "covered by healthy render evidence"
                )
            parity = self.artifact_docs.get((self.workdir / "parity-final.json").resolve())
            # A recorded blind comparison (pass, or divergent with its
            # screenshot) looked at the rendered page, so it covers blank risk.
            verdict = fold(parity.get("visual_verdict")) if isinstance(parity, dict) else ""
            shot = parity.get("screenshot_path") if isinstance(parity, dict) else None
            has_shot = isinstance(shot, str) and bool(shot.strip())
            compared = isinstance(parity, dict) and (
                parity.get("visual_checked") is True
                or verdict == "pass"
                or (verdict == "divergent" and has_shot)
            )
            return self.check(
                "blank-risk",
                "PASS" if compared else "FAIL",
                "covered by recorded visual comparison" if compared else "no blank-risk evidence found",
            )
        return self.check("blank-risk", "PASS", f"{len(paths)} blank-risk record(s) clear")

    def degradation_entries(self) -> list[dict[str, Any]]:
        document = self.artifact_docs.get((self.workdir / "degradation-ledger.json").resolve())
        rows = document.get("entries") if isinstance(document, dict) else []
        return [row for row in rows or [] if isinstance(row, dict)]

    def visual_degradation(self) -> dict[str, Any] | None:
        """A divergent / not-executable blind visual verdict is a fidelity
        residual that caps the run at YELLOW; it is not RED. Divergent mirrors
        DegradationLedger#fidelity_residuals exactly; not-executable uses the
        recorded notes."""
        parity = self.artifact_docs.get((self.workdir / "parity-final.json").resolve())
        if not isinstance(parity, dict):
            return None
        verdict = fold(parity.get("visual_verdict"))
        if verdict not in {"divergent", "not-executable"}:
            return None
        notes = parity.get("visual_notes")
        notes = (
            str(notes)
            if notes is not None and str(notes).strip()
            else f"blind visual verdict {verdict} recorded in parity-final.json"
        )
        if verdict == "divergent":
            notes = "recorded source-vs-target visual gaps ship in the render"
        return {
            "class": "fidelity-residual",
            "item": f"visual verdict: {verdict}",
            "reason": notes,
            "source_artifact": "parity-final.json",
        }

    def document_degradations(self) -> list[dict[str, Any]]:
        entries = self.degradation_entries()
        visual = self.visual_degradation()
        ledger_absent = self.artifact_docs.get(
            (self.workdir / "degradation-ledger.json").resolve()
        ) is None
        if (
            visual
            and ledger_absent
            and not any(row.get("item") == visual["item"] for row in entries)
        ):
            entries = entries + [visual]
        return entries

    def platform_difference_entries(self) -> list[dict[str, Any]]:
        """Recorded, never degradations; they never change the verdict."""
        fn = getattr(degradation_ledger, "platform_differences", None)
        return fn(self.workdir) if fn else []

    def polish_note_entries(self) -> list[dict[str, Any]]:
        """Minor gaps on a PASSING blind grade: notes, never degradations."""
        fn = getattr(degradation_ledger, "polish_notes", None)
        if not fn:
            return []
        # A ledger written before the polish rule still lists these minors as
        # degradations; never show one gap in both sections (re-run the gate).
        listed = {row.get("item") for row in self.degradation_entries()}
        return [
            note for note in fn(self.workdir)
            if f"visual residual (minor): {note['item']}" not in listed
        ]

    def waiver_entries(self) -> list[dict[str, Any]]:
        values: list[Any] = []
        document = self.artifact_docs.get((self.workdir / "waivers.json").resolve())
        if isinstance(document, dict):
            values.extend(document.get("waivers") or [])
        elif isinstance(document, list):
            values.extend(document)
        parity = self.artifact_docs.get((self.workdir / "parity-final.json").resolve())
        if isinstance(parity, dict):
            values.extend(parity.get("waivers") or [])
        normalized = [
            row if isinstance(row, dict) else {"reason": str(row)}
            for row in values
        ]
        unique = {canonical_json(row): row for row in normalized}
        return [unique[key] for key in sorted(unique)]

    def build(self) -> dict[str, Any]:
        inventory = read_json(self.inventory_path)
        self.artifact_docs[self.inventory_path] = inventory
        self.add_artifact("inventory", self.inventory_path, True)
        self.load_optional_artifacts()
        self.normalize_inventory(inventory)
        self.collect_accounting(inventory)
        checks = [
            self.accounting_check(),
            self.status_consistency_check(),
            self.artifact_consistency_check(inventory),
            self.controls_check(),
            self.parity_check(),
            self.render_check(),
            self.blank_check(),
        ]
        gates_check = self.finalize_gates_check()
        if gates_check:
            checks.append(gates_check)
        hard_failure = any(row["status"] == "FAIL" for row in checks)
        degradations = self.document_degradations()
        waivers = self.waiver_entries()
        yellow = any(
            row["status"] in {"approximated", "needs-review", "skipped"}
            for row in self.objects
        ) or bool(degradations or waivers) or self.visual_degradation() is not None
        verdict = "RED" if hard_failure else "YELLOW" if yellow else "GREEN"
        counts = {status: sum(row["status"] == status for row in self.objects) for status in TERMINAL}
        accounted = sum(row["status"] in TERMINAL for row in self.objects)
        self.document = {
            "schema_version": 1,
            "verdict": verdict,
            "summary": {
                "total": len(self.objects),
                "accounted": accounted,
                "complete": accounted == len(self.objects)
                and not any(row["status"] == "contradictory" for row in self.objects),
                "counts": counts,
            },
            "source_objects": self.objects,
            "checks": checks,
            "artifacts": sorted(self.artifacts, key=lambda row: (row["kind"], row["path"])),
            "degradations": degradations,
            "platform_differences": self.platform_difference_entries(),
            "polish_notes": self.polish_note_entries(),
            "waivers": waivers,
        }
        if "SOURCE_DATE_EPOCH" in os.environ:
            try:
                epoch = int(os.environ["SOURCE_DATE_EPOCH"])
            except ValueError as exc:
                raise ReportError("SOURCE_DATE_EPOCH must be an integer") from exc
            self.document["generated_at"] = (
                datetime.fromtimestamp(epoch, timezone.utc)
                .replace(microsecond=0)
                .isoformat()
                .replace("+00:00", "Z")
            )
        return self.document

    @staticmethod
    def md(value: Any) -> str:
        return str(value or "").replace("|", "\\|").replace("\r", " ").replace("\n", " ")

    def markdown(self) -> str:
        document = self.document or self.build()
        counts = document["summary"]["counts"]
        lines = [
            "# Migration Report",
            "",
            f"Verdict: **{document['verdict']}**",
            "",
            f"Accounting: **{document['summary']['accounted']}/{document['summary']['total']}** "
            "source objects have exactly one terminal status.",
            "",
            "## Summary",
            "",
            "| Status | Count |",
            "| --- | ---: |",
        ]
        lines.extend(f"| {status} | {counts[status]} |" for status in TERMINAL)
        lines.extend(
            [
                "",
                "## Checks",
                "",
                "| Check | Result | Detail |",
                "| --- | --- | --- |",
            ]
        )
        lines.extend(
            f"| {self.md(row['name'])} | {row['status']} | {self.md(row['message'])} |"
            for row in document["checks"]
        )
        lines.extend(
            [
                "",
                "## Source object accounting",
                "",
                "| Type | ID | Name | Terminal status | Evidence |",
                "| --- | --- | --- | --- | --- |",
            ]
        )
        for row in document["source_objects"]:
            evidence = ", ".join(dict.fromkeys(
                source["artifact"] for source in row["status_sources"]
            ))
            lines.append(
                f"| {self.md(row['type'])} | {self.md(row['id'])} | "
                f"{self.md(row['name'])} | {self.md(row['status'])} | "
                f"{self.md(evidence)} |"
            )
        lines.extend(
            [
                "",
                "## Artifacts",
                "",
                "| Kind | Path | Present |",
                "| --- | --- | --- |",
            ]
        )
        lines.extend(
            f"| {self.md(row['kind'])} | {self.md(row['path'])} | "
            f"{'yes' if row['present'] else 'no'} |"
            for row in document["artifacts"]
        )
        for heading, entries in (
            ("Degradations", document["degradations"]),
            ("Platform differences", document["platform_differences"]),
            ("Minor polish notes", document["polish_notes"]),
            ("Waivers", document["waivers"]),
        ):
            if not entries:
                continue
            if heading == "Platform differences":
                lines.extend([
                    "", f"## {heading}", "",
                    "Recorded, not degradations: Sigma renders these differently from the "
                    "source and a build cannot change it. They do not affect the verdict.",
                    "",
                ])
                lines.extend(
                    f"- **{self.md(row.get('catalog_id'))}** — {self.md(row.get('item'))}"
                    for row in entries
                )
                continue
            if heading == "Minor polish notes":
                lines.extend([
                    "", f"## {heading}", "",
                    "Not degradations: the blind visual grade passed, and these minor "
                    "differences are optional polish. They do not affect the verdict.",
                    "",
                ])
                for row in entries:
                    dim = (
                        f" [{self.md(row.get('dimension'))}]"
                        if str(row.get("dimension") or "")
                        else ""
                    )
                    lines.append(f"- {self.md(row.get('item'))}{dim}")
                continue
            lines.extend(["", f"## {heading}", ""])
            for row in entries:
                item = (
                    row.get("item")
                    or row.get("flag")
                    or row.get("control")
                    or row.get("name")
                    or heading.rstrip("s")
                )
                reason = (
                    row.get("reason")
                    or row.get("detail")
                    or row.get("evidence")
                    or "recorded"
                )
                lines.append(f"- **{self.md(item)}** — {self.md(reason)}")
        return "\n".join(lines) + "\n"


def write_atomic(path: Path, content: str) -> None:
    if not path.parent.is_dir():
        raise ReportError(f"output directory does not exist: {path.parent}")
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    try:
        temporary.write_bytes(content.encode("utf-8"))
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--inventory")
    parser.add_argument("--markdown")
    parser.add_argument("--json-out")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        workdir = Path(args.workdir).expanduser().resolve()
        if not workdir.is_dir():
            raise ReportError(f"--workdir is not a directory: {workdir}")
        if args.inventory:
            inventory = Path(args.inventory).expanduser().resolve()
        else:
            inventory = next(
                (workdir / name for name in INVENTORY_NAMES if (workdir / name).is_file()),
                None,
            )
            if inventory is None:
                raise ReportError(
                    "no source inventory found (tried " + ", ".join(INVENTORY_NAMES) + ")"
                )
        markdown_path = (
            Path(args.markdown).expanduser().resolve()
            if args.markdown
            else workdir / "MIGRATION_REPORT.md"
        )
        json_path = (
            Path(args.json_out).expanduser().resolve()
            if args.json_out
            else workdir / "migration-result.json"
        )
        builder = MigrationReport(workdir, inventory)
        document = builder.build()
        json_text = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
        markdown = builder.markdown()
        if args.check:
            stale = []
            try:
                current_json = read_json(json_path)
            except ReportError:
                current_json = None
            if current_json != document:
                stale.append(str(json_path))
            try:
                current_markdown = markdown_path.read_text(encoding="utf-8").replace(
                    "\r\n", "\n"
                ).replace("\r", "\n")
            except OSError:
                current_markdown = None
            if current_markdown != markdown:
                stale.append(str(markdown_path))
            if stale:
                print(
                    "migration report check failed; stale or missing output(s): "
                    + ", ".join(stale),
                    file=sys.stderr,
                )
                return 1
        else:
            write_atomic(json_path, json_text)
            write_atomic(markdown_path, markdown)
            print(
                f"migration report: {document['verdict']} "
                f"({document['summary']['accounted']}/{document['summary']['total']} accounted)"
            )
        return 1 if document["verdict"] == "RED" else 0
    except ReportError as exc:
        print(f"build-migration-report: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"build-migration-report: {exc}", file=sys.stderr)
        return 2
    except (TypeError, ValueError) as exc:
        print(f"build-migration-report: invalid input: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
