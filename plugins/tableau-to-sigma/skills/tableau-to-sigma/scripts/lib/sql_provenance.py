"""Account every Tableau data-model SQL element by source or generated purpose."""

from __future__ import annotations

import hashlib
import html
import json
import os
import re
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from typing import Any

ALLOWED_ORIGINS = {
    "source-custom-sql",
    "generated-lod",
    "generated-top-n",
    "generated-window",
    "generated-blend",
    "generated-manual",
}


def normalize_sql(value: Any) -> str:
    text = html.unescape(str(value or "")).strip()
    text = re.sub(r"^\s*<!\[CDATA\[", "", text)
    text = re.sub(r"\]\]>\s*$", "", text)
    return re.sub(r"\s+", " ", text).strip().rstrip(";").lower()


def source_queries(twb_path: Path | None, custom_sql_path: Path | None) -> list[str]:
    queries = []
    if twb_path is not None and twb_path.is_file():
        root = ET.fromstring(twb_path.read_text(encoding="utf-8-sig"))
        for node in root.iter():
            if node.tag.rsplit("}", 1)[-1].split(".")[-1] == "relation" and node.attrib.get("type") == "text":
                queries.append(normalize_sql("".join(node.itertext())))
    if custom_sql_path is not None and custom_sql_path.is_file():
        document = json.loads(custom_sql_path.read_text(encoding="utf-8-sig"))

        def walk(value):
            if isinstance(value, dict):
                for key in ("query", "sql", "statement"):
                    if isinstance(value.get(key), str):
                        queries.append(normalize_sql(value[key]))
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)

        walk(document)
    return list(dict.fromkeys(query for query in queries if query))


def load_overrides(path: Path | None) -> dict[str, dict]:
    if path is None or not path.is_file():
        return {}
    document = json.loads(path.read_text(encoding="utf-8-sig"))
    rows = document.get("entries") if isinstance(document, dict) else document
    result = {}
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        key = str(row.get("element_id") or row.get("element_name") or "")
        proof_path = str(row.get("proof") or "")
        proof_file = (
            (path.parent / proof_path).resolve()
            if proof_path and not Path(proof_path).is_absolute()
            else Path(proof_path)
        )
        try:
            proof = (
                json.loads(proof_file.read_text(encoding="utf-8-sig"))
                if proof_path
                else None
            )
        except (OSError, ValueError, json.JSONDecodeError):
            proof = None
        if (
            key
            and row.get("origin_type") in ALLOWED_ORIGINS
            and str(row.get("reason") or "").strip()
            and isinstance(proof, dict)
            and proof.get("match") is True
        ):
            result[key] = row
    return result


def evaluate(
    dm_spec_path: Path,
    metadata_path: Path | None = None,
    twb_path: Path | None = None,
    custom_sql_path: Path | None = None,
    overrides_path: Path | None = None,
) -> dict:
    spec_raw = dm_spec_path.read_bytes()
    spec = json.loads(spec_raw.decode("utf-8-sig"))
    metadata = (
        json.loads(metadata_path.read_text(encoding="utf-8-sig"))
        if metadata_path is not None and metadata_path.is_file()
        else {}
    )
    source_sql = source_queries(twb_path, custom_sql_path)
    overrides = load_overrides(overrides_path)
    converter_entries = metadata.get("sqlProvenance") or []
    elements = [
        element
        for page in spec.get("pages") or []
        for element in page.get("elements") or []
        if isinstance(element, dict)
    ]
    # Name matching only identifies an element whose name no other SQL element shares.
    name_counts = Counter(
        str(element.get("name") or "")
        for element in elements
        if (element.get("source") or {}).get("kind") == "sql"
    )
    entries = []
    for element in elements:
        if (element.get("source") or {}).get("kind") != "sql":
            continue
        statement = str((element.get("source") or {}).get("statement") or "")
        normalized = normalize_sql(statement)
        name = str(element.get("name") or "")
        unique_name = bool(name) and name_counts[name] == 1
        converter_entry = next(
            (
                row
                for row in converter_entries
                if isinstance(row, dict)
                and str(row.get("elementId") or "") == str(element.get("id") or "")
            ),
            None,
        )
        # A live readback carries server-assigned ids; fall back to a unique
        # ledger name (the statement must still match below).
        if converter_entry is None and unique_name:
            named = [
                row
                for row in converter_entries
                if isinstance(row, dict)
                and str(row.get("elementName") or "")
                and str(row.get("elementName") or "") == str(element.get("name") or "")
            ]
            if len(named) == 1:
                converter_entry = named[0]
        # A pass-1 override may be keyed by the converter id the readback lost.
        override = (
            overrides.get(str(element.get("id") or ""))
            or (overrides.get(name) if unique_name else None)
            or (
                overrides.get(str(converter_entry.get("elementId") or ""))
                if converter_entry is not None
                else None
            )
        )
        converter_origin = (
            str(converter_entry.get("originType") or "")
            if converter_entry is not None
            else ""
        )
        converter_statement_matches = (
            converter_entry is not None
            and normalize_sql(converter_entry.get("statement")) == normalized
        )
        if override:
            origin = str(override["origin_type"])
            evidence = f"override: {override['reason']}"
        elif (
            converter_statement_matches and converter_origin in ALLOWED_ORIGINS
        ):
            origin, evidence = (
                converter_origin,
                "converter-emitted SQL provenance ledger",
            )
        elif any(normalized == query for query in source_sql):
            origin, evidence = (
                "source-custom-sql",
                "statement matches Tableau source Custom SQL",
            )
        else:
            origin, evidence = (
                "unattributed",
                "no exact source-SQL match, statement-bound converter ledger, or proven override",
            )
        entries.append(
            {
                "element_id": element.get("id"),
                "element_name": element.get("name"),
                "origin_type": origin,
                "status": "fail" if origin == "unattributed" else "attributed",
                "evidence": evidence,
                "statement_sha256": hashlib.sha256(
                    normalized.encode("utf-8")
                ).hexdigest(),
            }
        )
    blockers = [entry for entry in entries if entry["status"] == "fail"]
    return {
        "schema_version": 1,
        "status": "pass" if not blockers else "fail",
        "sql_elements": entries,
        "blockers": blockers,
        "dm_spec_sha256": hashlib.sha256(spec_raw).hexdigest(),
    }
def record_active_spec(workdir, path, model_id):
    root, source = Path(workdir).resolve(), Path(path).resolve()
    if source.parent != root or not isinstance(model_id, str) or not model_id:
        raise ValueError("active data-model spec must be inside the workdir with a model id")
    destination = root / "active-dm-spec.json"
    if destination.is_symlink():
        raise ValueError("active binding must not be a symlink")
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump({"path": source.name, "data_model_id": model_id,
                   "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}, handle)


def active_spec_path(workdir):
    root = Path(workdir)
    binding = root / "active-dm-spec.json"
    if binding.is_symlink():
        raise ValueError("active binding must not be a symlink")
    if binding.is_file():
        record = json.loads(binding.read_text(encoding="utf-8"))
        if not isinstance(record, dict) or not isinstance(record.get("data_model_id"), str) or not record["data_model_id"]:
            raise ValueError("invalid active data-model binding")
        name = record.get("path", "")
        if not isinstance(name, str) or not name or Path(name).name != name or "\\" in name:
            raise ValueError("invalid active data-model spec path")
        path = root / name
        if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != record.get("sha256"):
            raise ValueError("active data-model spec is missing or stale")
        ids = json.loads((root / "dm-ids.json").read_text(encoding="utf-8"))
        if not isinstance(ids, dict) or ids.get("dataModelId") != record.get("data_model_id"):
            raise ValueError("active data-model binding belongs to another model")
        return path
    paths = [root / name for name in ("dm-spec.json", "dm-spec-reused.json", "dm-remapped.json", "dm-raw.json") if (root / name).is_file()]
    if len(paths) > 1:
        raise ValueError("ambiguous data-model source; rerun the gated pass to record the active spec")
    return paths[0] if paths else None
