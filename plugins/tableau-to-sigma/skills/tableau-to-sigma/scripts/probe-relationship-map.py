#!/usr/bin/env python3
"""Prove the DM edges a reused-DM relationship deviation relies on.

Python twin of `probe-join-keys.rb --relationship-map`. Per edge in
<workdir>/relationship-map.json that a non-matched entry requires: the target
is unique on its key, and 0 non-null source keys have no target match. Queries
run through a one-shot Custom SQL probe workbook on the Sigma connection
(created, exported as CSV, deleted); every identifier passes the same legality
rules as lib/sql_ident_check.rb. join-plan.json is never read or written.

  python3 scripts/probe-relationship-map.py --workdir <WORK> \
    (--connection-id <id> [--folder-id <id>] | --fixture DIR)
  Fixture: DIR/edge-<edge_id with -> as __>.json {"total":N,"distinct":M,"unmatched":K}

Exit codes: 0 all proven; 1 bad invocation; 2 any edge failed; 3 any edge errored.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import secrets
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import workdir_guard  # noqa: E402
import relationship_map  # noqa: E402

BARE_IDENT_RE = re.compile(r"\A[A-Za-z_][A-Za-z0-9_$]*\Z")
GUID_RE = re.compile(r"\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z")
EXPORT_TIMEOUT_S = int(os.environ.get("PROBE_EXPORT_TIMEOUT_S", "180"))


def illegal_reason(name: str):
    s = str(name)
    if BARE_IDENT_RE.match(s):
        return None
    if not s.strip():
        return "empty identifier"
    if re.search(r"[\x00-\x1F\x7F]", s):
        return "contains control characters"
    if '"' in s:
        return "contains a double quote"
    if re.search(r"[()]", s):
        return "parenthesis residue — a Tableau role-disambiguation display label folded into the identifier"
    if GUID_RE.match(s) or (re.fullmatch(r"[0-9A-Fa-f-]{20,}", s) and "-" in s):
        return "GUID-shaped Tableau field id, not a physical column (caption resolution failed)"
    return None


def sql_ident(name: str):
    s = str(name)
    if BARE_IDENT_RE.match(s):
        return s
    return None if illegal_reason(s) else f'"{s}"'


def emit(names, refused):
    out = []
    for name in names:
        form = sql_ident(name)
        if form is None:
            refused.append((name, illegal_reason(name)))
        out.append(form)
    return out


def element_from(element, refused):
    if not element:
        return None
    source = element.get("source") or {}
    if source.get("kind") == "sql":
        # caller adds the alias; drop a trailing ';' and close a trailing line comment
        statement = re.sub(r";\s*(--[^\n]*)?\s*\Z", lambda m: (" " + (m.group(1) or "")).rstrip(),
                           str(source.get("statement") or "").strip())
        return f"({statement}\n)"
    parts = emit([str(p) for p in source.get("path") or []], refused)
    return None if not parts or None in parts else ".".join(parts)


def totals_sql(table, keys):
    concat = keys[0] if len(keys) == 1 else " || '|' || ".join(f"COALESCE(TO_VARCHAR({k}), '')" for k in keys)
    return f"SELECT COUNT(*) AS TOTAL_ROWS, COUNT(DISTINCT {concat}) AS DISTINCT_KEYS FROM {table}"


def unmatched_sql(source, source_keys, target, target_keys):
    not_null = " AND ".join(f"s.{k} IS NOT NULL" for k in source_keys)
    on = " AND ".join(f"t.{t} = s.{s}" for s, t in zip(source_keys, target_keys))
    return (f"SELECT COUNT(*) AS UNMATCHED FROM {source} s WHERE {not_null} "
            f"AND NOT EXISTS (SELECT 1 FROM {target} t WHERE {on})")


def strict_count(value):
    """A whole number the warehouse returned, else None (never a default 0)."""
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    text = str(value if value is not None else "").strip().replace(",", "")
    return int(float(text)) if re.fullmatch(r"-?\d+(\.0+)?", text) else None


def usable_counts(res: dict) -> dict:
    counts = {k: strict_count(res.get(k)) for k in ("total", "distinct", "unmatched")}
    missing = [k for k, v in counts.items() if v is None]
    if missing:
        return {"error": f"probe returned no usable {'/'.join(missing)} count — not proof; re-run the probe"}
    return counts


def live_counts(totals_rows, unmatched_rows) -> dict:
    """Counts from the two probe exports; an empty export or a missing column
    is an error, never a silent zero."""
    tot = totals_rows[0] if totals_rows else {}
    unm = unmatched_rows[0] if unmatched_rows else {}
    return usable_counts({"total": tot.get("TOTAL_ROWS"), "distinct": tot.get("DISTINCT_KEYS"),
                          "unmatched": unm.get("UNMATCHED")})


def resolve_folder(work: Path, explicit):
    """--folder-id, else the first folderId in the workdir's specs (same order
    as probe-join-keys.rb, plus the Python profile's wb-spec-python.json)."""
    if explicit:
        return explicit
    for name in ("wb-spec.json", "wb-spec-python.json", "dm-spec.json", "dm-spec-reused.json"):
        path = work / name
        if not path.is_file():
            continue
        try:
            folder = json.loads(path.read_text(encoding="utf-8-sig")).get("folderId")
        except (ValueError, AttributeError):
            continue
        if folder:
            return str(folder)
    return None


def edge_fixture(directory: Path, edge_id: str) -> dict:
    path = directory / f"edge-{edge_id.replace('->', '__', 1)}.json"
    if not path.is_file():
        return {"error": f"no fixture {path.name} in {directory}"}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return {"error": f"fixture unparseable: {str(exc)[:80]}"}


def probe_workbook_body(conn_id, folder_id, sql, columns):
    """The one-shot probe workbook in canonical code-rep form (flat elements +
    page layout), the shape Ruby's WorkbookCode.canonicalize sends; the API
    rejects a pages[].elements body with no layout."""
    return {
        "name": f"_probe_relmap_{secrets.token_hex(4)}", "folderId": folder_id,
        "document": {
            "schemaVersion": 1, "kind": "workbook", "pages": [{"id": "p1", "name": "p1"}],
            "elements": [{
                "id": "probe", "kind": "table", "name": "Probe",
                "source": {"kind": "sql", "connectionId": conn_id, "statement": sql},
                "columns": [{"id": "c-" + re.sub(r"[^a-z0-9]+", "-", c.lower()), "name": c,
                             "formula": f"[Custom SQL/{c}]"} for c in columns],
            }],
            "layout": ('<?xml version="1.0" encoding="utf-8"?>\n<Page type="grid" '
                       'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">\n'
                       '  <Element elementId="probe" gridColumn="1 / 25" gridRow="1 / 11"/>\n</Page>'),
        },
    }


def sql_rows(conn_id, folder_id, sql, columns, workdir=None):
    import code_rep
    import probe_registry
    import sigma_rest

    spec = probe_workbook_body(conn_id, folder_id, sql, columns)
    created = sigma_rest.request("post", code_rep.create_path(), body=json.dumps(code_rep.create_body(spec)))
    wb_id = created.get("workbookId") if isinstance(created, dict) else None
    if not wb_id:
        raise RuntimeError(f"probe workbook POST failed: {str(created)[:160]}")
    # registered before the first readback so sweep-run-artifacts.rb can delete
    # it if this process is killed or times out (twin of probe-join-keys.rb)
    probe_registry.created(wb_id, name=spec["name"], workdir=workdir, script="probe-relationship-map.py")
    try:
        export = sigma_rest.request("post", f"/v2/workbooks/{wb_id}/export",
                                    body=json.dumps({"elementId": "probe", "format": {"type": "csv"}}))
        query_id = export.get("queryId") if isinstance(export, dict) else None
        if not query_id:
            raise RuntimeError(f"export POST returned no queryId: {str(export)[:160]}")
        started = time.time()
        body = None
        while time.time() - started < EXPORT_TIMEOUT_S:
            time.sleep(1)
            try:
                body = sigma_rest.request("get", f"/v2/query/{query_id}/download", accept="text/csv", binary=True)
            except sigma_rest.SigmaError as exc:
                if "404" not in str(exc).splitlines()[0]:
                    raise
                continue
            if body:
                break
        if not body:
            raise RuntimeError(f"export did not complete in {EXPORT_TIMEOUT_S}s (PROBE_EXPORT_TIMEOUT_S raises this)")
        text = body.decode("utf-8-sig") if isinstance(body, bytes) else str(body)
        return list(csv.DictReader(io.StringIO(text)))
    finally:
        try:
            sigma_rest.request("delete", f"/v2/files/{wb_id}")
            probe_registry.cleaned(wb_id, workdir=workdir, via="ensure")
        except Exception as exc:  # noqa: BLE001 - cleanup is best effort; the registry keeps it for the sweep
            gone = re.search(r"\b404\b", (str(exc).splitlines() or [""])[0])
            probe_registry.cleaned(wb_id, workdir=workdir, via="ensure", outcome="404" if gone else "failed")
            if not gone:
                print(f"WARN: probe workbook {wb_id} could not be deleted — "
                      "ruby scripts/sweep-run-artifacts.rb removes it from probe-artifacts.jsonl", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--relationship-map")
    parser.add_argument("--connection-id")
    parser.add_argument("--folder-id")
    parser.add_argument("--fixture")
    args = parser.parse_args()
    workdir_guard.check(args.workdir, "--workdir")
    work = Path(args.workdir).expanduser().resolve()
    map_path = Path(args.relationship_map).expanduser().resolve() if args.relationship_map else work / "relationship-map.json"
    if not map_path.is_file():
        print(f"FATAL: {map_path} not found — run emit-relationship-map.py first", file=sys.stderr)
        return 1
    if not (args.fixture or args.connection_id):
        print("provide --fixture DIR (offline) or --connection-id <id> (live probe)", file=sys.stderr)
        return 1
    dm_path = work / "dm-spec-reused.json"
    dm_spec = json.loads(dm_path.read_text(encoding="utf-8-sig")) if dm_path.is_file() else {}
    folder = resolve_folder(work, args.folder_id)
    if args.connection_id and not folder:
        print("FATAL: live probes require --folder-id <UUID> (or a workdir wb-spec.json/dm-spec.json carrying folderId)",
              file=sys.stderr)
        return 1
    by_id = {e.get("id"): e for p in dm_spec.get("pages") or [] for e in p.get("elements") or []}
    doc = json.loads(map_path.read_text(encoding="utf-8"))
    needed = list(dict.fromkeys(
        edge_id for e in doc.get("entries") or [] if "key_probe" in (e.get("requires") or [])
        for edge_id in e.get("dm_path") or []
    ))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    results = []
    for edge in doc.get("dm_edges") or []:
        if edge.get("edge_id") not in needed:
            continue
        if edge.get("probe") and edge["probe"].get("status") == "pass":
            results.append("pass")  # only a passing probe is kept; failed/errored edges are re-run
            continue
        refused: list = []
        source = element_from(by_id.get(edge.get("source_element")), refused)
        target = element_from(by_id.get(edge.get("target_element")), refused)
        source_keys = emit([k["source"] for k in edge.get("keys") or []], refused)
        target_keys = emit([k["target"] for k in edge.get("keys") or []], refused)
        probe = {"probed_at": now}
        if refused or source is None or target is None or not edge.get("keys"):
            detail = "; ".join(f"{n!r}: {r}" for n, r in refused)
            probe["status"] = "error"
            probe["error"] = (f"identifier(s) not legal to send to the warehouse — {detail}" if refused
                              else "edge has no keys or an element is missing from dm-spec-reused.json")
        else:
            totals_from = f"{target} t" if target.startswith("(") else target
            sql = {"totals": totals_sql(totals_from, target_keys),
                   "unmatched": unmatched_sql(source, source_keys, target, target_keys)}
            probe["sql"] = sql
            if args.fixture:
                res = edge_fixture(Path(args.fixture), edge["edge_id"])
                if not res.get("error"):
                    res = usable_counts(res)
            else:
                try:
                    res = live_counts(
                        sql_rows(args.connection_id, folder, sql["totals"], ["TOTAL_ROWS", "DISTINCT_KEYS"], workdir=work),
                        sql_rows(args.connection_id, folder, sql["unmatched"], ["UNMATCHED"], workdir=work))
                except Exception as exc:  # noqa: BLE001 - a probe failure is recorded, never raised
                    res = {"error": re.sub(r"\s+", " ", str(exc)).strip()[:300]}
            if res.get("error"):
                probe["status"] = "error"
                probe["error"] = res["error"]
            else:
                probe["unique"] = {"total": res.get("total"), "distinct": res.get("distinct")}
                probe["unmatched"] = res.get("unmatched")
                ok = (isinstance(res.get("total"), int) and res.get("total") == res.get("distinct")
                      and res.get("unmatched") == 0)
                probe["status"] = "pass" if ok else "fail"
        edge["probe"] = probe
        results.append(probe["status"])
        label = f"{edge['edge_id']} ({edge.get('source_table')} -> {edge.get('target_table')})"
        if probe["status"] == "pass":
            print(f"  PASS   {label}: target unique ({probe['unique']['total']} rows), 0 unmatched keys")
        elif probe["status"] == "fail":
            print(f"  FAIL   {label}: {probe['unique']['total']} rows over {probe['unique']['distinct']} keys, "
                  f"{probe['unmatched']} unmatched source key(s)")
        else:
            print(f"  ERROR  {label}: {probe['error']}")
    relationship_map.write(map_path, doc)
    if "fail" in results:
        print(f"probe-relationship-map: {results.count('fail')} edge(s) failed — the relationship gate blocks.", file=sys.stderr)
        return 2
    if "error" in results:
        print(f"probe-relationship-map: {results.count('error')} edge(s) could not be probed — fix and re-run.", file=sys.stderr)
        return 3
    print(f"probe-relationship-map: {len(results)} edge(s) proven. Map: {map_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
