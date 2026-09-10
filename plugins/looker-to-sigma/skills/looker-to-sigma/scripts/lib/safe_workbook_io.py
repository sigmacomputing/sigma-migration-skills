"""Safety helpers for Looker workbook preflight/readback/update paths."""

import hashlib
import json
import re
import urllib.parse


READ_ONLY_KEYS = {
    "workbookId",
    "latestDocumentVersion",
    "latestVersion",
    "createdAt",
    "updatedAt",
}
REF = re.compile(r"\[([^\]/]+)/([^\]]+)\]")


def canonical_document_hash(spec):
    """Stable content hash excluding server-owned envelope fields."""
    document = spec.get("document") if isinstance(spec, dict) else None
    payload = document if isinstance(document, dict) else spec

    def clean(value):
        if isinstance(value, dict):
            return {
                key: clean(item)
                for key, item in sorted(value.items())
                if key not in READ_ONLY_KEYS
            }
        if isinstance(value, list):
            return [clean(item) for item in value]
        return value

    encoded = json.dumps(clean(payload), sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def list_entries(fetch_json, path, limit=500):
    """Fetch every Sigma list page, supporting both cursor conventions."""
    entries = []
    cursor = None
    cursor_param = None
    seen = set()
    while True:
        separator = "&" if "?" in path else "?"
        request_path = f"{path}{separator}limit={int(limit)}"
        if cursor is not None:
            request_path += "&" + urllib.parse.urlencode({cursor_param: cursor})
        page = fetch_json(request_path)
        if not isinstance(page, dict):
            raise ValueError(f"{path}: expected JSON object page")
        entries.extend(page.get("entries") or [])
        if page.get("nextPage") not in (None, ""):
            cursor, cursor_param = page["nextPage"], "page"
        elif page.get("nextPageToken") not in (None, ""):
            cursor, cursor_param = page["nextPageToken"], "pageToken"
        else:
            break
        marker = (cursor_param, str(cursor))
        if marker in seen:
            raise ValueError(f"{path}: server repeated {cursor_param} cursor {cursor!r}")
        seen.add(marker)
    return entries


def _elements(spec):
    if not isinstance(spec, dict):
        return []
    document = spec.get("document") or spec
    if isinstance(document.get("elements"), list):
        return document["elements"]
    return [
        element
        for page in (document.get("pages") or [])
        for element in (page.get("elements") or [])
    ]


def _norm(value):
    value = re.sub(r"\s*\([^)]*\)\s*$", "", str(value or "").strip().casefold())
    return re.sub(r"\s+", " ", value)


def validate_workbook_refs(workbook, dm_spec, live_columns):
    """Return every unresolved/stale workbook dependency in one report."""
    failures = []
    workbook_elements = _elements(workbook)
    dm_elements = _elements(dm_spec)
    dm_ids = {element.get("id") for element in dm_elements if element.get("id")}
    clean_labels, error_labels = set(), set()
    for column in live_columns:
        label = _norm(column.get("label") or column.get("name"))
        if not label:
            continue
        if ((column.get("type") or {}).get("type") == "error"):
            error_labels.add(label)
        else:
            clean_labels.add(label)
    error_labels -= clean_labels

    metrics = {
        str(metric.get("name", "")).strip()
        for element in dm_elements
        for metric in (element.get("metrics") or [])
        if metric.get("name")
    }
    order = {element.get("id"): index for index, element in enumerate(workbook_elements)}
    internal = {
        element.get("name"): {
            _norm(column.get("name"))
            for column in (element.get("columns") or []) + (element.get("metrics") or [])
            if column.get("name")
        }
        for element in workbook_elements
        if element.get("name")
    }

    def walk(value):
        if isinstance(value, dict):
            for item in value.values():
                yield from walk(item)
        elif isinstance(value, list):
            for item in value:
                yield from walk(item)
        elif isinstance(value, str):
            yield from REF.findall(value)

    for index, element in enumerate(workbook_elements):
        label = element.get("name") or element.get("id") or "?"
        source = element.get("source") or {}
        if source.get("kind") == "table" and source.get("elementId"):
            target_index = order.get(source["elementId"])
            if target_index is None:
                failures.append(f"{label}: source element {source['elementId']!r} is missing")
            elif target_index > index:
                failures.append(f"{label}: source element is defined later in document order")
        if source.get("kind") == "data-model" and source.get("elementId") not in dm_ids:
            failures.append(
                f"{label}: data-model element {source.get('elementId')!r} is absent from readback"
            )

        for prefix, tail in walk(element):
            final = tail.split("/")[-1]
            if prefix == "Metrics":
                if final not in metrics:
                    failures.append(f"{label}: metric [{prefix}/{tail}] is absent from the data model")
                continue
            if prefix in internal:
                target_index = next(
                    (
                        idx
                        for idx, candidate in enumerate(workbook_elements)
                        if candidate.get("name") == prefix
                    ),
                    None,
                )
                if target_index is not None and target_index > index:
                    failures.append(f"{label}: [{prefix}/{tail}] is a forward reference")
                if _norm(final) not in internal[prefix]:
                    failures.append(f"{label}: internal reference [{prefix}/{tail}] is stale")
                continue
            normalized = _norm(final)
            if normalized in error_labels:
                failures.append(f"{label}: [{prefix}/{tail}] resolves only to an error-typed column")
            elif normalized not in clean_labels:
                failures.append(f"{label}: [{prefix}/{tail}] is absent from live DM columns")
    return sorted(set(failures))


def fingerprint(spec):
    return {
        "latestDocumentVersion": spec.get("latestDocumentVersion") or spec.get("latestVersion"),
        "sha256": canonical_document_hash(spec),
    }


def remote_drifted(saved, current):
    """Version and hash evidence must both agree before an unattended PUT."""
    if not saved:
        return False
    now = fingerprint(current)
    return (
        str(saved.get("latestDocumentVersion")) != str(now.get("latestDocumentVersion"))
        or saved.get("sha256") != now.get("sha256")
    )
