"""relationship-map.json — the reused-DM relationship evidence route.

Python twin of lib/relationship_map.rb (see that file for the WHY). A data
model the customer built themselves and reused by explicit id is judged by
how each Tableau relationship is carried — matched / replaced / disconnected /
dropped, plus model edges with no Tableau counterpart (extra) — and the
evidence each deviation needs, instead of an exact count against the
converter draft. Held to the Ruby derivation by the committed
expected-map.json goldens (scripts/test-fixtures/relationship-map/).
"""

from __future__ import annotations

import copy
import hashlib
import itertools
import json
import re
# Parses the workbook being migrated; xml.etree resolves no external entities and fetches no DTDs.
import xml.etree.ElementTree as ET  # nosemgrep: python.lang.security.use-defused-xml.use-defused-xml
from collections import deque
from pathlib import Path
from typing import Any, Optional

SCHEMA_VERSION = 1
ROUTE = "reused-dm-evidence"
COUNT_KINDS = ("matched", "replaced", "disconnected", "dropped", "extra")
PENDING_KINDS = ("unprobed", "parity-missing")
UNRESOLVED = "?unresolved-field"  # a worksheet field no table could be traced for: fails field use
# Worksheet usage also records the Tableau object each field reads, under this
# prefix (never a table id): a self-join's ends are one table, so only the
# objects tell the table from its aliased copy (see relationship_map.rb OBJECT).
OBJECT = "?object:"

FCP_TRUE_RE = re.compile(r"(</?)_\.fcp\.[A-Za-z0-9_]+\.true\.\.\.")
FCP_FALSE_OPEN_RE = re.compile(r"<_\.fcp\.([A-Za-z0-9_]+)\.false\.\.\.([A-Za-z0-9_-]+)")
GRAIN_COLLAPSING_KEY_FN = re.compile(r"\b(?:DateTrunc|Int)\s*\(", re.I)


def _dumps(value: Any) -> str:
    """Ruby JSON.generate's compact form (used for hashes)."""
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def scoped_dashboards(scope: Any) -> Optional[list]:
    if not isinstance(scope, dict) or str(scope.get("mode") or "") != "selected":
        return None
    return [str(d) for d in scope.get("dashboards") or [] if str(d)]


def derive(twb_xml: str, dm_spec: Any, dashboards: Optional[list] = None, resolution: Any = None) -> dict:
    """resolution: the converter's table resolution for this run —
    {"db", "schema", "table_mapping"}; None = the .twb's own connection."""
    root = _parse(twb_xml)
    resolution = _normalize_resolution(resolution)
    source = _tableau_model(root, resolution)
    model = _dm_model(dm_spec)
    blockers: list = []
    tables = _map_tables(source["tables"], model["elements"], blockers)
    el_table: dict = {}
    for t in tables:
        for element_id in t["dm_element_ids"]:
            el_table.setdefault(element_id, t["table"])
    edges = [
        dict(edge, source_table=el_table.get(edge["source_element"]), target_table=el_table.get(edge["target_element"]))
        for edge in model["edges"]
    ]
    usage = _worksheet_tables(root, source, dashboards)
    mapped = list(dict.fromkeys(t["table"] for t in tables if t["dm_element_ids"]))

    def elements_of(table):
        return list(dict.fromkeys(i for t in tables if t["table"] == table for i in t["dm_element_ids"]))

    used_edges: dict = {}
    entries = [_classify(rel, edges, elements_of, mapped, usage, used_edges) for rel in source["relationships"]]
    for pair in _bridge_pairs(source, mapped, usage):
        rel = {"datasource": None, "left": pair["left"], "right": pair["right"], "tableau_keys": []}
        entry = _classify(rel, edges, elements_of, mapped, usage, used_edges)
        entry["bridge_for"] = pair["via"]
        entries.append(entry)
    for edge in edges:
        if used_edges.get(edge["edge_id"]):
            continue
        entries.append({
            "kind": "extra", "datasource": None,
            "left": edge["source_table"], "right": edge["target_table"], "tableau_keys": [],
            "disposition": "extra", "dm_path": [edge["edge_id"]], "requires": ["key_probe", "parity"],
            "field_use": None, "affected_worksheets": _affected(usage, [edge["source_table"], edge["target_table"]]),
            "reason": None,
        })
    entries = [{"index": i, "kind": e["kind"], **e, "index": i} for i, e in enumerate(entries)]

    inputs = {"twb_sha256": _sha(str(twb_xml or "")), "dm_sha256": _sha(_dumps(dm_spec))}
    if resolution:
        inputs["resolution"] = resolution
    return {
        "schema_version": SCHEMA_VERSION,
        "route": ROUTE,
        "inputs": inputs,
        "tables": tables,
        "dm_edges": [
            {
                "edge_id": edge["edge_id"], "edge_sha": _edge_sha(edge),
                "source_element": edge["source_element"], "target_element": edge["target_element"],
                "source_table": edge["source_table"], "target_table": edge["target_table"],
                "keys": edge["keys"], "probe": None,
            }
            for edge in edges
        ],
        "entries": entries,
        "blockers": blockers,
    }


def write(path, doc: dict) -> None:
    Path(path).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def merge_prior(fresh: dict, prior: Any) -> dict:
    """Carry reasons (by entry identity) and probes (by edge_id, only while
    edge_sha is unchanged) from a prior map onto a fresh one."""
    if not isinstance(prior, dict):
        return fresh
    out = copy.deepcopy(fresh)
    reasons = {
        (e.get("kind"), e.get("left"), e.get("right")): e.get("reason")
        for e in prior.get("entries") or [] if e.get("reason") is not None
    }
    probes = {d.get("edge_id"): d for d in prior.get("dm_edges") or []}
    for e in out["entries"]:
        key = (e["kind"], e["left"], e["right"])
        if key in reasons:
            e["reason"] = reasons[key]
    for d in out["dm_edges"]:
        old = probes.get(d["edge_id"])
        if old and old.get("edge_sha") == d["edge_sha"]:
            d["probe"] = old.get("probe")
    return out


def evaluate(map_doc: Any, twb_xml: str, dm_spec: Any, dashboards: Optional[list] = None,
             parity: Any = None, final: bool = True, resolution: Any = None) -> dict:
    blockers: list = []
    entries = map_doc.get("entries") or [] if isinstance(map_doc, dict) else []
    fresh = derive(twb_xml=twb_xml, dm_spec=dm_spec, dashboards=dashboards, resolution=resolution)
    if _facts(map_doc) != _facts(fresh):
        blockers.append({
            "kind": "stale-map",
            "reason": "relationship-map.json does not match the current .twb and data model; re-run emit-relationship-map",
        })
    blockers.extend(fresh["blockers"])
    edges = {d.get("edge_id"): d for d in (map_doc.get("dm_edges") or [] if isinstance(map_doc, dict) else [])}
    passed = [str(n).strip().lower() for n in (parity.get("pass_names") or [] if isinstance(parity, dict) else [])]
    failed = [str(n).strip().lower() for n in (parity.get("fail_names") or [] if isinstance(parity, dict) else [])]
    for e in entries:
        req = e.get("requires") or []
        if "key_probe" in req:
            for edge_id in e.get("dm_path") or []:
                kind = probe_problem((edges.get(edge_id) or {}).get("probe"))
                if kind:
                    blockers.append({"kind": kind, "index": e.get("index"), "edge_id": edge_id,
                                     "reason": f"{e.get('left')} ↔ {e.get('right')}: edge {edge_id} {kind}"})
        if "parity" in req:
            for ws in e.get("affected_worksheets") or []:
                key = str(ws).strip().lower()
                if key in failed:
                    kind = "parity-failed"
                elif key in passed:
                    continue
                else:
                    kind = "parity-missing"
                blockers.append({"kind": kind, "index": e.get("index"), "worksheet": ws,
                                 "reason": f"{e.get('left')} ↔ {e.get('right')}: worksheet {ws} {kind}"})
        if "field_use" in req and (e.get("field_use") or {}).get("status") != "pass":
            sheets = ", ".join((e.get("field_use") or {}).get("worksheets") or [])
            blockers.append({"kind": "field-use", "index": e.get("index"),
                             "reason": f"{e.get('left')} ↔ {e.get('right')} ({e.get('disposition')}): used together by {sheets}"})
    counts = {k: sum(1 for e in entries if e.get("disposition") == k) for k in COUNT_KINDS}
    if not blockers:
        status = "pass"
    elif not final and all(b["kind"] in PENDING_KINDS for b in blockers):
        status = "pending"
    else:
        status = "fail"
    return {"status": status, "counts": counts, "blockers": blockers}


def evaluate_workdir(workdir, final: bool = True, state_file: str = "migrate-state-python.json") -> dict:
    """The final gates' entry point: judge <workdir>/relationship-map.json."""
    work = Path(workdir)
    missing = [n for n in ("relationship-map.json", "workbook-content.twb", "dm-spec-reused.json") if not (work / n).is_file()]
    if missing:
        return {"status": "fail", "counts": {k: 0 for k in COUNT_KINDS},
                "blockers": [{"kind": "input-missing", "reason": f"{work / n} is missing"} for n in missing]}

    def read(name):
        path = work / name
        return json.loads(path.read_text(encoding="utf-8-sig")) if path.is_file() else None

    try:
        return evaluate(
            read("relationship-map.json"),
            twb_xml=(work / "workbook-content.twb").read_text(encoding="utf-8-sig"),
            dm_spec=read("dm-spec-reused.json"),
            dashboards=scoped_dashboards(read("dashboard-scope.json")),
            parity=normalize_parity(read("parity-final.json"), read("parity-expected.json"), read("parity-plan.json")),
            final=final,
            resolution=(read(state_file) or {}).get("relationship_resolution"),
        )
    except (OSError, ValueError) as exc:
        return {"status": "fail", "counts": {}, "blockers": [{"kind": "input-unreadable", "reason": str(exc)[:200]}]}


def normalize_parity(parity: Any, expected: Any, plan: Any = None) -> Any:
    """See relationship_map.rb normalize_parity: pass/fail chart names, aliased
    to their Tableau worksheet via parity-plan.json charts[].tableau_view."""
    if not isinstance(parity, dict):
        return parity
    if "pass_names" in parity:
        passed = list(parity.get("pass_names") or [])
        failed = list(parity.get("fail_names") or [])
    elif isinstance(expected, dict):
        paths = [str(d.get("path") or "") if isinstance(d, dict) else "" for d in parity.get("differences") or []]
        if any(not p.startswith("$.") for p in paths):
            failed = list(expected)
        else:
            failed = [
                name for name in expected
                if any(p == f"$.{name}" or p.startswith(f"$.{name}.") or p.startswith(f"$.{name}[") for p in paths)
            ]
        passed = [n for n in expected if n not in failed]
    else:
        return parity
    views = {}
    for chart in (plan.get("charts") or [] if isinstance(plan, dict) else []):
        if isinstance(chart, dict) and str(chart.get("tableau_view") or ""):
            views[str(chart.get("chart"))] = str(chart["tableau_view"])

    def with_views(names):
        return list(dict.fromkeys([*names, *(views[str(n)] for n in names if str(n) in views)]))

    return {"pass_names": with_views(passed), "fail_names": with_views(failed)}


def summary_line(result: dict) -> str:
    c = result.get("counts") or {}
    return (f"{c.get('matched')} matched, {c.get('replaced')} replaced, {c.get('dropped')} dropped, "
            f"{c.get('disconnected')} disconnected, {c.get('extra')} extra")


def probe_problem(probe: Any) -> Optional[str]:
    """Probe evidence is re-checked from its numbers; a 'pass' status alone is not trusted."""
    if probe is None:
        return "unprobed"
    if probe.get("status") == "error":
        return "probe-error"
    unique = probe.get("unique") or {}
    total = unique.get("total")
    ok = (probe.get("status") == "pass" and isinstance(total, int) and not isinstance(total, bool)
          and total == unique.get("distinct") and probe.get("unmatched") == 0)
    return None if ok else "probe-failed"


def _facts(doc: Any) -> Any:
    out = copy.deepcopy(doc)
    if not isinstance(out, dict):
        return out
    for e in out.get("entries") or []:
        e.pop("reason", None)
    for d in out.get("dm_edges") or []:
        d.pop("probe", None)
    return out


# ---- classification ---------------------------------------------------------

def _classify(rel, edges, elements_of, mapped, usage, used_edges) -> dict:
    left, right = rel["left"], rel["right"]
    base = {"kind": "tableau", "datasource": rel["datasource"], "left": left, "right": right,
            "tableau_keys": rel["tableau_keys"]}
    if rel.get("computed_conditions"):
        base["computed_conditions"] = rel["computed_conditions"]
    if left not in mapped or right not in mapped:
        dropped = [t for t in (left, right) if t not in mapped]
        return {**base, "disposition": "dropped", "dm_path": [], "requires": ["field_use", "not_a_bridge"],
                "field_use": _field_use(usage, lambda used: bool(set(used) & set(dropped + [UNRESOLVED]))),
                "affected_worksheets": [], "reason": None}
    matchable = bool(rel["tableau_keys"]) and not rel.get("computed_conditions")
    direct = next((e for e in edges if _same_join(e, rel)), None) if matchable else None
    if direct:
        used_edges[direct["edge_id"]] = True
        return {**base, "disposition": "matched", "dm_path": [direct["edge_id"]], "requires": [],
                "field_use": None, "affected_worksheets": [], "reason": None}
    path = _shortest_path(edges, elements_of(left), elements_of(right))
    if path:
        for edge in path:
            used_edges[edge["edge_id"]] = True
        path_tables = list(dict.fromkeys(t for edge in path for t in (edge["source_table"], edge["target_table"]) if t is not None))
        return {**base, "disposition": "replaced", "dm_path": [e["edge_id"] for e in path],
                "requires": ["key_probe", "parity"], "field_use": None,
                "affected_worksheets": _affected(usage, path_tables, rel.get("objects") if left == right else None),
                "reason": None}
    # A self-join is used only by a worksheet reading both of its objects.
    objects = rel.get("objects") or []
    ends = objects if left == right and len(set(objects)) == 2 else [left, right]
    return {**base, "disposition": "disconnected", "dm_path": [], "requires": ["field_use"],
            "field_use": _field_use(usage, lambda used: all(e in used for e in ends) or UNRESOLVED in used),
            "affected_worksheets": [], "reason": None}


def _same_join(edge, rel) -> bool:
    pairs = sorted([k["left"], k["right"]] for k in rel["tableau_keys"])
    keys = [[k["source"], k["target"]] for k in edge["keys"]]
    forward = edge["source_table"] == rel["left"] and edge["target_table"] == rel["right"]
    reverse = edge["source_table"] == rel["right"] and edge["target_table"] == rel["left"]
    # a self-join satisfies both orientations, so either key order matches
    return (forward and sorted(keys) == pairs) or (reverse and sorted([list(reversed(k)) for k in keys]) == pairs)


def _shortest_path(edges, from_ids, to_ids):
    if not from_ids or not to_ids:
        return None
    adjacency: dict = {}
    for edge in sorted(edges, key=lambda e: e["edge_id"]):
        adjacency.setdefault(edge["source_element"], []).append((edge["target_element"], edge))
        adjacency.setdefault(edge["target_element"], []).append((edge["source_element"], edge))
    from_ids, to_ids = set(from_ids), set(to_ids)
    if not from_ids & to_ids:
        return _bfs_path(adjacency, sorted(from_ids), to_ids)
    # self-join: the path must leave its start (see relationship_map.rb)
    paths = [p for p in (_bfs_path(adjacency, [start], to_ids - {start}, start) for start in sorted(from_ids)) if p]
    return min(paths, key=len) if paths else None


def _bfs_path(adjacency, starts, to_ids, loop_at=None):
    if loop_at is not None:
        self_loop = next((edge for nxt, edge in adjacency.get(loop_at, []) if nxt == loop_at), None)
        if self_loop:
            return [self_loop]
    queue = deque(starts)
    back = {node: None for node in queue}
    while queue:
        node = queue.popleft()
        if node in to_ids:
            path = []
            while back[node]:
                prev, edge = back[node]
                path.insert(0, edge)
                node = prev
            return path or None
        for nxt, edge in adjacency.get(node, []):
            if nxt in back:
                continue
            back[nxt] = (node, edge)
            queue.append(nxt)
    return None


def _affected(usage, tables, objects=None) -> list:
    """See relationship_map.rb affected: single-table deviations need a worksheet
    reading both self-join objects, or any worksheet reading the table."""
    wanted = {t for t in tables if t is not None}

    def hit(used):
        used = set(used)
        if UNRESOLVED in used:
            return True
        if len(wanted) >= 2:
            return len(used & wanted) >= 2
        if objects and len(set(objects)) == 2:
            return set(objects) <= used
        return bool(used & wanted)

    return sorted(ws for ws, used in usage.items() if hit(used))


def _field_use(usage, hit) -> dict:
    hits = sorted(ws for ws, used in usage.items() if hit(used))
    return {"status": "fail" if hits else "pass", "worksheets": hits}


def _bridge_pairs(source, mapped, usage) -> list:
    adjacency: dict = {}
    direct = set()
    for rel in source["relationships"]:
        adjacency.setdefault(rel["left"], []).append(rel["right"])
        adjacency.setdefault(rel["right"], []).append(rel["left"])
        direct.add(tuple(sorted((rel["left"], rel["right"]))))
    pairs = sorted({
        pair
        for used in usage.values()
        for pair in itertools.combinations(sorted(set(t for t in used if t in mapped)), 2)
    })
    out = []
    for a, b in pairs:
        if (a, b) in direct:
            continue
        full = _tableau_path(adjacency, a, b, None)
        if not full or _tableau_path(adjacency, a, b, mapped):
            continue
        out.append({"left": a, "right": b, "via": sorted(t for t in full if t not in (a, b) and t not in mapped)})
    return out


def _tableau_path(adjacency, start, goal, allowed):
    back = {start: None}
    queue = deque([start])
    while queue:
        node = queue.popleft()
        if node == goal:
            path = [node]
            while back[node] is not None:
                node = back[node]
                path.insert(0, node)
            return path
        for nxt in sorted(adjacency.get(node, [])):
            if nxt in back or (allowed is not None and nxt not in allowed):
                continue
            back[nxt] = node
            queue.append(nxt)
    return None


def _edge_sha(edge) -> str:
    return _sha(_dumps([edge["source_element"], edge["target_element"], edge["source_table"],
                        edge["target_table"], edge["keys"]]))


# ---- table identity ---------------------------------------------------------

def _object_table_key(name: str) -> str:
    raw = str(name or "")
    parenthesized = re.findall(r"\(([^()]*)\)", raw)
    last = parenthesized[-1] if parenthesized else ""
    token = last.split(".")[-1] if "." in last else raw
    # one trailing "$" is a Tableau extract suffix (JoinPlan.object_table_key)
    return re.sub(r"\s+", "_", re.sub(r"\$\Z", "", token.strip()).upper())


def _suffix_match(parts, path) -> bool:
    if not parts or not path or len(parts) > len(path):
        return False
    tail = [p.upper() for p in path[-len(parts):]]
    return (tail[:-1] == [p.upper() for p in parts[:-1]]
            and _object_table_key(tail[-1]) == _object_table_key(parts[-1]))


def _map_tables(source_tables, elements, blockers) -> list:
    """See relationship_map.rb map_tables: full FQN when both sides have one,
    otherwise every part the Tableau name has must agree; ambiguity blocks."""
    def ambiguous(table, reason):
        if not any(b.get("table") == table for b in blockers):
            blockers.append({"kind": "ambiguous-table", "table": table, "reason": reason})

    rows = []
    for t in source_tables:
        if t["sql"]:
            ids = [e["id"] for e in elements if e["sql"] and e["sql"] == t["sql"]]
        elif len(t["parts"]) == 3 and any(len(e["path"]) == 3 for e in elements):
            ids = [e["id"] for e in elements if len(e["path"]) == 3 and e["fqn"] == t["id"]]
        else:
            hits = [e for e in elements if _suffix_match(t["parts"], e["path"])]
            fqns = sorted(set(e["fqn"] for e in hits))
            if len(fqns) > 1:
                ambiguous(t["id"], f"{t['id']} matches {', '.join(fqns)} by name only")
                ids = []
            else:
                ids = [e["id"] for e in hits]
        rows.append({"table": t["id"], "datasource": t["datasource"], "dm_element_ids": sorted(ids)})
    claims: dict = {}
    for r in rows:
        for element_id in r["dm_element_ids"]:
            claims.setdefault(element_id, []).append(r["table"])
    for element_id, tables in claims.items():
        distinct = sorted(set(tables))
        if len(distinct) > 1:
            for table in distinct:
                ambiguous(table, f"{' and '.join(distinct)} both resolve to model element {element_id}")
    blocked = {b["table"] for b in blockers if b.get("kind") == "ambiguous-table"}
    for r in rows:
        if r["table"] in blocked:
            r["dm_element_ids"] = []
    return rows


# ---- Tableau side -----------------------------------------------------------

def _fcp_normalize(xml: str) -> str:
    if "_.fcp." not in xml:
        return xml
    s = xml
    while True:
        m = FCP_FALSE_OPEN_RE.search(s)
        if not m:
            break
        feature, name = m.group(1), m.group(2)
        open_tag = f"<_.fcp.{feature}.false...{name}"
        close_tag = f"</_.fcp.{feature}.false...{name}>"
        start = m.start()
        tag_end = s.find(">", start)
        if tag_end < 0:
            break
        if s[tag_end - 1] == "/":
            s = s[:start] + s[tag_end + 1:]
            continue
        depth, pos = 1, tag_end + 1
        while depth > 0:
            nxt_open = s.find(open_tag, pos)
            nxt_close = s.find(close_tag, pos)
            if nxt_close < 0:
                break
            if 0 <= nxt_open < nxt_close:
                depth += 1
                pos = s.find(">", nxt_open) + 1
            else:
                depth -= 1
                pos = nxt_close + len(close_tag)
        if depth > 0:
            break
        s = s[:start] + s[pos:]
    return FCP_TRUE_RE.sub(r"\1", s)


def _parse(twb_xml: str):
    return ET.fromstring(_fcp_normalize(str(twb_xml or "")))


def _normalize_sql(sql) -> str:
    text = re.sub(r";\s*\Z", "", str(sql or "").strip())
    return re.sub(r"\s+", " ", text).lower()


def _twb_table_fqn(root, rel) -> str:
    parts = re.findall(r"\[([^\]]+)\]", rel.get("table") or "")
    if not parts:
        parts = [rel.get("name") or ""]
    if len(parts) == 3:
        return ".".join(parts)
    if len(parts) > 3:
        return ""
    db = None
    conn_name = rel.get("connection") or ""
    if conn_name:
        for named in root.iter("named-connection"):
            if named.get("name") != conn_name:
                continue
            for conn in named.iter("connection"):
                if db is None:
                    db = conn.get("dbname")
    return ".".join(p for p in [db, *parts] if p)


GUID_PART = re.compile(r"\A[0-9A-F]{8}-[0-9A-F]{4}-", re.I)


def _normalize_resolution(resolution):
    if not isinstance(resolution, dict):
        return None
    mapping = resolution.get("table_mapping") if isinstance(resolution.get("table_mapping"), dict) else {}
    out = {"db": str(resolution.get("db") or "").strip() or None,
           "schema": str(resolution.get("schema") or "").strip() or None,
           "table_mapping": {str(k): str(v) for k, v in mapping.items()}}
    return out if out["db"] or out["schema"] or out["table_mapping"] else None


def _connection_db(root, rel):
    conn_name = rel.get("connection") or ""
    if not conn_name:
        return None
    db = None
    for named in root.iter("named-connection"):
        if named.get("name") != conn_name:
            continue
        for conn in named.iter("connection"):
            if db is None:
                db = conn.get("dbname")
    return None if not db or GUID_PART.match(db) else db.upper()


def _resolve_table_name(table, mapping):
    stripped = re.sub(r"\$+\Z", "", table)
    for key, value in mapping.items():
        ku = str(key).upper()
        if ku in (table, stripped) or re.sub(r"\$+\Z", "", ku) in (table, stripped):
            return str(value).upper()
    return stripped


def _warehouse_path(root, rel, resolution):
    """See relationship_map.rb warehouse_path (converter extractPath)."""
    raw = rel.get("table") or rel.get("name") or ""
    cleaned = re.sub(r"\s*\([^)]*\)", "", re.sub(r"[\[\]]", "", raw))
    parts = [p.strip().upper() for p in cleaned.split(".")]
    parts = [p for p in parts if p and not GUID_PART.match(p)]
    if not parts:
        parts = [(rel.get("name") or "").upper()]
    mapping = resolution["table_mapping"] if resolution else {}
    parts[-1] = _resolve_table_name(re.sub(r"_[0-9A-Fa-f]{16,}\Z", "", parts[-1]), mapping)
    db = resolution["db"].upper() if resolution and resolution["db"] else _connection_db(root, rel)
    schema = resolution["schema"].upper() if resolution and resolution["schema"] else None
    if schema and len(parts) == 1:
        parts = [schema] + parts
    if db:
        if len(parts) >= 3:
            parts[0] = db
        else:
            parts.insert(0, db)
    if schema:
        if len(parts) >= 3:
            parts[1] = schema
        elif len(parts) == 2 and not db:
            parts[0] = schema
    return parts


def _relation_table(root, rel, resolution=None) -> dict:
    if rel.get("type") == "text":
        return {"id": f"SQL:{rel.get('name')}", "parts": [], "sql": _normalize_sql(rel.text)}
    parts = _warehouse_path(root, rel, resolution)
    return {"id": ".".join(parts), "parts": parts, "sql": None}


def _unwrap_fn(op) -> str:
    m = re.fullmatch(r"\w+\((\[.+\])\)", str(op or ""))
    return m.group(1) if m else str(op or "")


def _strip_brackets(value) -> str:
    return re.sub(r"\]\Z", "", re.sub(r"\A\[", "", str(value or "")))


def _first(node, xpath):
    found = node.find(xpath)
    return found


def _tableau_model(root, resolution=None) -> dict:
    tables: list = []
    relationships: list = []
    columns: dict = {}
    calcs: dict = {}
    for ds in root.iter("datasource"):
        graph = ds.find(".//object-graph")
        if graph is None:
            continue
        ds_name = ds.get("name") or ""
        caption = ds.get("caption") or ds_name
        objects: dict = {}
        by_relation: dict = {}
        for obj in graph.findall(".//objects/object"):
            rel = obj.find(".//relation[@type='table']")
            if rel is None:
                rel = obj.find(".//relation[@type='text']")
            if rel is None:
                continue
            objects[obj.get("id") or ""] = _relation_table(root, rel, resolution)
            by_relation[rel.get("name") or ""] = obj.get("id") or ""

        def object_token(oid, ds_name=ds_name):
            return f"{OBJECT}{ds_name}|{oid}"
        seen_ids = set()
        for t in objects.values():
            if t["id"] in seen_ids:
                continue
            seen_ids.add(t["id"])
            if not any(x["id"] == t["id"] and x["datasource"] == caption for x in tables):
                tables.append({**t, "datasource": caption})
        local: dict = {}
        for record in ds.iter("metadata-record"):
            if record.get("class") != "column":
                continue
            name = _strip_brackets((record.findtext("local-name") or ""))
            oid = _strip_brackets((record.findtext("object-id") or ""))
            parent = _strip_brackets((record.findtext("parent-name") or ""))
            if oid not in objects:
                oid = by_relation.get(parent) or ""
            table = objects.get(oid)
            if not name or table is None:
                continue
            local[name] = {"table": table["id"], "physical": (record.findtext("remote-name") or "").upper(),
                           "object": object_token(oid)}
        columns[ds_name] = local
        calcs[ds_name] = {}
        for col in ds.findall("column"):
            calc = col.find("calculation")
            if calc is None:
                continue
            calcs[ds_name][_strip_brackets(col.get("name"))] = _calc_formula(calc)
        for group in ds.findall("group"):
            levels = [gf.get("level") for gf in group.iter("groupfilter") if gf.get("level")]
            calcs[ds_name][_strip_brackets(group.get("name"))] = " ".join(
                dict.fromkeys(f"[{_field_ref(level)}]" for level in levels))
        for r in graph.findall(".//relationships/relationship"):
            first_end = r.find("first-end-point")
            second_end = r.find("second-end-point")
            first_id = (first_end.get("object-id") if first_end is not None else "") or ""
            second_id = (second_end.get("object-id") if second_end is not None else "") or ""
            first = objects.get(first_id)
            second = objects.get(second_id)
            if not first or not second:
                continue
            keys: list = []
            computed = _relationship_conditions(r.find("expression"), local, keys)
            rel_row = {"datasource": caption, "left": first["id"], "right": second["id"], "tableau_keys": keys}
            if computed:
                rel_row["computed_conditions"] = computed
            if first["id"] == second["id"]:
                rel_row["objects"] = [object_token(first_id), object_token(second_id)]
            relationships.append(rel_row)
    return {"tables": tables, "relationships": relationships, "columns": columns, "calcs": calcs}


def _relationship_conditions(expr, local, keys) -> int:
    """AND of conditions: plain field = field is a physical key pair; anything
    else is a computed condition (counted; never matchable by keys alone)."""
    if expr is None:
        return 1
    op = expr.get("op") or ""
    children = expr.findall("expression")
    if op.upper() == "AND":
        return sum(_relationship_conditions(child, local, keys) for child in children)
    sides = []
    for child in children:
        m = re.fullmatch(r"\[([^\]]+)\]", child.get("op") or "")
        sides.append(m.group(1) if m else None)
    if op == "=" and len(sides) == 2 and all(sides):
        keys.append({"left": _physical_key(local, sides[0]), "right": _physical_key(local, sides[1])})
        return 0
    return 1


def _calc_formula(calc) -> str:
    formula = calc.get("formula") or ""
    if formula:
        return formula
    column = calc.get("column") or ""
    return f"[{_field_ref(column)}]" if column else ""


def _field_ref(token) -> str:
    name = _strip_brackets(token)
    m = re.fullmatch(r"[a-z]+:(.+):[a-z]+", name)
    return m.group(1) if m else name


def _physical_key(local, name) -> str:
    hit = local.get(name)
    if hit and hit["physical"]:
        return hit["physical"]
    return re.sub(r"\s+", "_", re.sub(r"\s*\([^)]*\)\s*\Z", "", name).strip()).upper()


def _worksheet_tables(root, source, dashboards) -> dict:
    sheets = _migrated_worksheets(root, dashboards)
    out: dict = {}
    for ws in root.iter("worksheet"):
        name = ws.get("name") or ""
        if name not in sheets:
            continue
        used: list = []
        for dd in ws.iter("datasource-dependencies"):
            ds_name = dd.get("datasource") or ""
            if ds_name not in source["columns"]:
                continue  # Parameters / datasources outside the object-graph model
            for col in dd.findall("column"):
                ref = _strip_brackets(col.get("name"))
                calc = col.find("calculation")
                inline = _calc_formula(calc) if calc is not None else None
                used.extend(_field_tables(source, ds_name, ref, inline, frozenset()))
        out[name] = sorted(set(used))
    return out


def _field_tables(source, ds_name, ref, formula, seen) -> list:
    hit = (source["columns"].get(ds_name) or {}).get(ref)
    if hit:
        return [hit["table"], hit["object"]]
    if ref in seen or ref.startswith(":"):
        return []
    if formula is None:
        formula = (source["calcs"].get(ds_name) or {}).get(ref)
    # an empty formula (or a group naming no field) is unknown usage too
    if formula is None or not formula.strip():
        return [UNRESOLVED]
    seen = seen | {ref}
    out = []
    for qualifier, inner in dict.fromkeys(re.findall(r"(?:\[([^\]]+)\]\.)?\[([^\]]+)\]", formula)):
        if not qualifier:
            out.extend(_field_tables(source, ds_name, inner, None, seen))
        elif qualifier in source["columns"]:
            out.extend(_field_tables(source, qualifier, inner, None, seen))
    return out


def _migrated_worksheets(root, dashboards) -> list:
    worksheets = [ws.get("name") or "" for ws in root.iter("worksheet")]
    boards = root.findall("./dashboards/dashboard")
    if not boards:
        return worksheets
    names = []
    for d in boards:
        if dashboards is not None and (d.get("name") or "") not in dashboards:
            continue
        for zone in d.iter("zone"):
            n = zone.get("name") or ""
            if n in worksheets and n not in names:
                names.append(n)
    return names


# ---- model side -------------------------------------------------------------

def _physical_name(display) -> str:
    return re.sub(r"\s+", "_", str(display or "").strip()).upper()


def _strip_role_paren(display):
    s = str(display or "").rstrip()
    if not s.endswith(")"):
        return display
    depth = 0
    i = len(s) - 1
    while i >= 0:
        if s[i] == ")":
            depth += 1
        elif s[i] == "(":
            depth -= 1
        if depth == 0:
            break
        i -= 1
    if i <= 0:
        return display
    rest = s[:i].rstrip()
    return rest or display


def _column(el, col_id):
    return next((c for c in (el or {}).get("columns") or [] if c.get("id") == col_id), None)


def _dm_column_physical_name(el, col_id):
    col = _column(el, col_id) if el and col_id else None
    if not col:
        return None
    disp = col.get("name")
    if not disp and isinstance(col.get("formula"), str):
        m = re.search(r"/([^\]]+)\]\Z", col["formula"])
        disp = m.group(1) if m else None
    return _physical_name(disp) if disp else None


def _dm_column_probe_keys(el, col_id, seen=frozenset()) -> list:
    if not el or not col_id or col_id in seen:
        return []
    col = _column(el, col_id)
    if not col:
        return []
    formula = str(col.get("formula") or "")
    passthrough = re.fullmatch(r"\[[^/\]]+/([^\]]+)\]", formula)
    if passthrough:
        return [_physical_name(_strip_role_paren(passthrough.group(1)))]
    if GRAIN_COLLAPSING_KEY_FN.search(formula):
        name = _dm_column_physical_name(el, col_id)
        return [name] if name else []
    seen = seen | {col_id}
    resolved = []
    for ref in dict.fromkeys(re.findall(r"\[([^\]/]+)\]", formula)):
        ref_col = None
        for candidate in el.get("columns") or []:
            disp = candidate.get("name")
            if not disp:
                m = re.fullmatch(r"\[[^/\]]+/([^\]]+)\]", str(candidate.get("formula") or ""))
                disp = m.group(1) if m else ""
            if str(disp).lower() == ref.lower():
                ref_col = candidate
                break
        if ref_col:
            resolved.extend(_dm_column_probe_keys(el, ref_col.get("id"), seen))
        else:
            resolved.append(_physical_name(_strip_role_paren(ref)))
    if not resolved:
        name = _dm_column_physical_name(el, col_id)
        return [name] if name else []
    return resolved


def _key_column(el, col_id) -> str:
    keys = _dm_column_probe_keys(el, col_id)
    if len(keys) == 1:
        return str(keys[0])
    return str(_dm_column_physical_name(el, col_id) or "")


def _dm_model(dm_spec) -> dict:
    pages = dm_spec.get("pages") if isinstance(dm_spec, dict) else None
    els = [e for p in pages or [] for e in p.get("elements") or []]
    by_id = {e.get("id"): e for e in els}
    elements = []
    for e in els:
        source = e.get("source") or {}
        if source.get("kind") not in ("warehouse-table", "sql"):
            continue
        path = [str(p) for p in source.get("path") or []]
        elements.append({
            "id": str(e.get("id")), "path": path, "fqn": ".".join(path).upper(),
            "sql": _normalize_sql(source.get("statement")) if source.get("kind") == "sql" else None,
        })
    counts: dict = {}
    edges = []
    for el in els:
        for rel in el.get("relationships") or []:
            target = by_id.get(rel.get("targetElementId"))
            if not target:
                continue
            keys = [
                {"source": _key_column(el, k.get("sourceColumnId")), "target": _key_column(target, k.get("targetColumnId"))}
                for k in rel.get("keys") or []
            ]
            edge_id = f"{el.get('id')}->{target.get('id')}"
            counts[edge_id] = counts.get(edge_id, 0) + 1
            edges.append({
                "edge_id": f"{edge_id}#{counts[edge_id]}" if counts[edge_id] > 1 else edge_id,
                "source_element": str(el.get("id")), "target_element": str(target.get("id")), "keys": keys,
            })
    return {"elements": elements, "edges": edges}
