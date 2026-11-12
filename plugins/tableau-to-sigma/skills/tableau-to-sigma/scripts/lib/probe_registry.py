"""Append-only LOCAL registry of throwaway Sigma artifacts (twin of probe_registry.rb).

Register a probe workbook at creation time, before the first readback, so a
killed or timed-out probe can never orphan an id untraceably:
scripts/sweep-run-artifacts.rb deletes leftovers from this registry. Cleanup
appends a matching record. LOCAL state only (<workdir>/probe-artifacts.jsonl,
else ~/.tableau-to-sigma/probe-artifacts.jsonl); registry I/O is never fatal.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

FILE_BASENAME = "probe-artifacts.jsonl"


def home_dir() -> str:
    return os.environ.get("TABLEAU_TO_SIGMA_HOME") or os.path.expanduser("~/.tableau-to-sigma")


def path(workdir=None) -> Path:
    return Path(home_dir() if not str(workdir or "") else workdir) / FILE_BASENAME


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def created(id, name=None, workdir=None, script=None) -> bool:  # noqa: A002 - mirrors the Ruby keyword
    """Record a just-created artifact, immediately after the create response."""
    if not str(id or ""):
        return False
    rec = {"id": id, "name": name, "created_at": _now()}
    if script:
        rec["script"] = script
    return append(rec, workdir)


def cleaned(id, workdir=None, via=None, outcome="deleted") -> bool:  # noqa: A002
    """Record a delete attempt's outcome ('deleted' | '404' | 'failed')."""
    if not str(id or ""):
        return False
    rec = {"id": id, "deleted_at": _now(), "outcome": outcome}
    if via:
        rec["via"] = via
    return append(rec, workdir)


def entries(workdir=None) -> list:
    """Parsed records, oldest first ([] on any error; a torn line never poisons)."""
    p = path(workdir)
    try:
        if not p.is_file():
            return []
        out = []
        for line in p.read_text(encoding="utf-8").splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict) and rec.get("id"):
                out.append(rec)
        return out
    except OSError:
        return []


def outstanding(workdir=None) -> list:
    """Created-but-not-cleaned records; a 404 counts as cleaned, 'failed' does not."""
    recs = entries(workdir)
    done = {r["id"] for r in recs if r.get("deleted_at") and str(r.get("outcome")) in ("deleted", "404")}
    return [r for r in recs if r.get("created_at") and r["id"] not in done]


def append(rec, workdir) -> bool:
    p = path(workdir)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
        return True
    except OSError:
        return False  # bookkeeping only; never fail a probe on registry I/O
