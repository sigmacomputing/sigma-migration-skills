"""Which relationship rule a workdir is judged by (twin of relationship_route.rb).

The reused-DM evidence route (relationship-map.json) applies only to a data
model someone deliberately named by explicit id that this workdir did not post
itself. The orchestrator persists the route in its state file; the gates read
it from there, never from the presence of a map file.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

EVIDENCE = "reused-dm-evidence"


def posted_ids(workdir) -> list:
    path = Path(workdir) / "posted-datamodels.jsonl"
    if not path.is_file():
        return []
    ids = []
    for row in path.read_text(encoding="utf-8").splitlines():
        try:
            value = json.loads(row)
        except ValueError:
            continue
        if isinstance(value, dict) and value.get("id") is not None:
            ids.append(str(value["id"]))
    return ids


def eligible(workdir, reuse_dm) -> bool:
    if not isinstance(reuse_dm, str) or not reuse_dm.strip():
        return False
    return reuse_dm.strip() not in posted_ids(workdir)


def explicit_reuse_id(arg_id, state) -> Optional[str]:
    """The data model reused by explicit id: --data-model-id, or on re-entry the
    model a prior pass already took on the evidence route (reuse discovery falls
    back to the state's data_model_id, so the route must follow it too)."""
    if isinstance(arg_id, str) and arg_id.strip():
        return arg_id.strip()
    if isinstance(state, dict) and state.get("relationship_route") == EVIDENCE:
        dm_id = str(state.get("data_model_id") or "").strip()
        return dm_id or None
    return None


def current(workdir, state_file: str = "migrate-state-python.json") -> Optional[str]:
    """Re-checked at gate time: the route stands only while the state records
    the shipped model and this workdir never posted that model id itself."""
    path = Path(workdir) / state_file
    if not path.is_file():
        return None
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict) or state.get("relationship_route") != EVIDENCE:
        return None
    dm_id = str(state.get("data_model_id") or "")
    if not dm_id or state.get("reused_dm") is False or dm_id in posted_ids(workdir):
        return None
    return EVIDENCE


def refresh_reused_model(workdir, fetch):
    """Re-read the LIVE reused model into dm-spec-reused.json before the gate
    (twin of relationship_route.rb). On failure the old copy is removed so the
    gate blocks instead of judging evidence against an unconfirmed model."""
    path = Path(workdir) / "dm-spec-reused.json"
    try:
        live = fetch()
        if not isinstance(live, dict) or not isinstance(live.get("pages"), list):
            raise ValueError("readback has no pages")
        path.write_text(json.dumps(live, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return True, f"re-read the live reused model into {path}"
    except Exception as exc:  # noqa: BLE001 - any failure must block, never pass on the stale copy
        if path.exists():
            path.unlink()
        return False, f"{type(exc).__name__}: {str(exc)[:160]}"


def resolution(db, schema, remap_mappings) -> dict:
    """The run's table resolution for the map. The Python path has no
    --table-mapping; landed extract tables are renamed by the manifest remap
    (old_table -> new_name), so those renames are the table mapping."""
    mapping = {}
    for row in remap_mappings or []:
        old, new = str(row.get("old_table") or ""), str(row.get("new_name") or "")
        if old and new:
            mapping[old] = new
    return {"db": db, "schema": schema, "table_mapping": mapping}


def settle(route, reused: bool, coverage_deferred: bool) -> dict:
    """Once the reuse decision is final: abandoned reuse clears the route and
    fires the strict relationship STOP that was deferred for it."""
    if route is None:
        return {"route": None, "stop": False}
    if reused:
        return {"route": route, "stop": False}
    return {"route": None, "stop": bool(coverage_deferred)}
