"""Local, best-effort activity timing. No argv, output, or network collection."""

import hashlib
import json
import os
import platform
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

ARTIFACTS = ("wb-spec.json", "dm-spec.json", "dashboard-layout.json", "fidelity-ledger.json")


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def emit(workdir, event):
    try:
        if not re.fullmatch(r"[0-9a-f]{32}", str(event.get("id", ""))) or event.get("event") not in ("start", "end"):
            return False
        directory = Path(workdir) / "diagnostic-events"
        if directory.is_symlink():
            return False
        directory.mkdir(mode=0o700, exist_ok=True)
        path = directory / f"{event['id']}-{event['event']}.json"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(event, handle, allow_nan=False)
            handle.write("\n")
        return True
    except (OSError, ValueError, TypeError):
        return False


def fingerprints(workdir):
    result = {}
    for name in ARTIFACTS:
        try:
            path = Path(workdir) / name
            result[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() and not path.is_symlink() else None
        except OSError:
            result[name] = None
    return result


class Span:
    def __init__(self, workdir, kind, operation):
        self.workdir = workdir
        self.started = time.monotonic()
        self.finished = False
        self.before = fingerprints(workdir) if kind in ("invocation", "repair") else None
        model = os.environ.get("SIGMA_DIAGNOSTICS_MODEL", "unknown")
        if not re.fullmatch(r"(?:(?:openai|anthropic|google)/)?(?:gpt|claude|gemini)[a-z0-9.-]{1,64}", model):
            model = "unknown"
        effort = os.environ.get("SIGMA_DIAGNOSTICS_EFFORT", "unknown")
        if effort not in ("unknown", "low", "medium", "high", "max", "minimal", "none", "xhigh"):
            effort = "unknown"
        self.event = {
            "schema_version": 1, "id": uuid.uuid4().hex, "kind": kind,
            "operation": operation, "event": "start", "at": timestamp(),
            "runtime": "python " + platform.python_version(),
            "model": model, "effort": effort,
        }
        emit(workdir, self.event)

    def finish(self, code):
        if self.finished:
            return
        self.finished = True
        event = dict(self.event, event="end", at=timestamp(), exit_code=code,
                     elapsed_s=round(time.monotonic() - self.started, 6), clock="monotonic")
        if self.before is not None:
            after = fingerprints(self.workdir)
            event["changed_artifacts"] = [name for name in ARTIFACTS if self.before[name] != after[name]]
        emit(self.workdir, event)
