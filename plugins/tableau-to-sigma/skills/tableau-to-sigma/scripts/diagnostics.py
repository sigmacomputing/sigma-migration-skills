#!/usr/bin/env python3
"""Explicit local diagnostic ZIP export and timers for otherwise unmeasured work.

No upload command exists. Only typed projections of named artifacts are packaged;
source data, images, formulas, raw logs, credentials and environment files are not.
"""

import argparse
import hashlib
import json
import math
import os
import re
import stat
import sys
import zipfile
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from migration_diagnostics import ARTIFACTS, Span, emit, timestamp

MAX_BYTES = 5 * 1024 * 1024
MAX_EVENTS = 10000
MANUAL_OPERATIONS = ("mcp-source", "mcp-query", "manual-spec-edit", "visual-review", "runtime-repair")
OPERATIONS = {p.name for p in Path(__file__).parent.iterdir() if p.suffix in (".rb", ".py", ".sh")}
OPERATIONS.update("fidelity-loop.rb:" + cmd for cmd in ("init", "render", "record", "resolve", "apply-patch", "status"))
OPERATIONS.update(MANUAL_OPERATIONS)
OPERATIONS.add("external-command")
ENUMS = {
    "event": {"start", "end"},
    "kind": {"invocation", "script", "render", "repair", "review", "mcp", "completion",
             "cred-gate-waived", "doctor-gate-waived", "pass1-stop", "converter-stop",
             "workbook-handoff", "degraded-fastpath", "gate-waived", "stale-skill-waived",
             "loop-stop", "mission-scope", "scope-mismatch-stop", "gap-out-of-scope",
             "png-read-stale", "png-wait-timeout", "finalize-chained", "tier-assigned",
             "punchlist-emitted", "manual-spec", "decisions-stop", "gap-scan-stop"},
    "clock": {"monotonic", "wall"},
    "effort": {"unknown", "low", "medium", "high", "max", "minimal", "none", "xhigh"},
    "error_category": {"missing-reference", "authentication", "timeout-or-rate-limit", "command-failed", "launch-failed"},
    "status": {"PASS", "FAIL", "pass", "fail", "running", "exited", "unknown"},
    "visual_verdict": {"pass", "fail", "not-executable", "unknown"},
    "verdict": {"GREEN", "YELLOW", "RED", "PARTIAL", "PARTIAL+YELLOW"},
    "cls": {"spec-fixable", "ui-only", "sigma-capability", "data"},
    "source_mode": {"local-twb-mcp", "tableau-rest"},
    "backend": {"local", "hosted"},
}
NUMBERS = set("elapsed_s wall_s exit_code child_exit charts_total charts_pass charts_fail pass max_passes total accounted turn".split())
BOOLEANS = set("match visual_checked resolved complete implementation_changed".split())
DATES = {"at", "recorded_at", "started_at", "finished_at"}
HASHES = {"git_revision", "implementation_sha256", "bundled_converter_sha256", "sha256"}
EVENT_FIELDS = "id event at kind operation runtime model effort elapsed_s clock exit_code error_category changed_artifacts"
FILES = {
    "phase-metrics.jsonl": "phase wall_s at inv turn",
    "execution-history.jsonl": "recorded_at entrypoint runtime plugin_version source_mode git_revision implementation_sha256 bundled_converter_sha256 implementation_changed model effort converter",
    "offramps.jsonl": "kind at reason detail",
    "migration-process.json": "started_at finished_at status exit_code",
    "workbook-handoff.json": "stage error child_exit fields reason",
    "fidelity-ledger.json": "pass max_passes entries renders",
    "parity-final.json": "status match visual_checked visual_verdict charts_total charts_pass charts_fail",
    "anchors-verdict.json": "pass status",
    "migration-result.json": "verdict summary complete",
    "completion-verdict.json": "pass status",
    "degradation-ledger.json": "entries verdict",
}


def read_regular(path, limit=MAX_BYTES):
    # Refuse symlinks and nonregular files, including FIFOs. Recheck the opened
    # inode to avoid a final-component replacement between lstat and open.
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
        raise ValueError("unsafe-or-oversized")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    with os.fdopen(fd, "rb") as handle:
        current = os.fstat(handle.fileno())
        if not stat.S_ISREG(current.st_mode) or (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise ValueError("changed-during-read")
        content = handle.read(limit + 1)
        if len(content) > limit:
            raise ValueError("oversized")
    return content.decode("utf-8-sig")


def date(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)", value):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, OverflowError, OSError):
        return None


class Projection:
    def __init__(self):
        self.aliases = {}

    def opaque(self, value):
        # No hashes of customer strings or reversible redaction map are exported.
        key = json.dumps(value, sort_keys=True, ensure_ascii=True)
        if key not in self.aliases:
            self.aliases[key] = f"redacted-{len(self.aliases) + 1}"
        return self.aliases[key]

    def project(self, row, fields):
        if not isinstance(row, dict):
            raise ValueError("expected-object")
        return {key: self.value(key, row[key]) for key in fields.split() if key in row}

    def value(self, key, value):
        if key == "pass" and isinstance(value, bool):
            return value
        if key in NUMBERS:
            minimum = -255 if key in ("exit_code", "child_exit") else 0
            return value if type(value) in (int, float) and minimum <= value <= 1e9 and math.isfinite(value) else None
        if key in BOOLEANS:
            return value if isinstance(value, bool) else None
        if key in DATES:
            return value if date(value) is not None else None
        if key in ENUMS:
            return value if isinstance(value, str) and value in ENUMS[key] else "unknown"
        if key in ("operation", "entrypoint", "stage"):
            return value if isinstance(value, str) and value in OPERATIONS else self.opaque(value)
        if key in HASHES:
            return value if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value) else None
        if key == "plugin_version":
            return value if isinstance(value, str) and re.fullmatch(r"\d{1,4}\.\d{1,4}\.\d{1,4}", value) else "unknown"
        if key == "runtime":
            return value if isinstance(value, str) and re.fullmatch(r"(?:ruby|python) \d{1,2}\.\d{1,2}\.\d{1,3}", value) else "unknown"
        if key == "model":
            # Model is explicitly supplied by the host, never guessed from doctor.
            return value if isinstance(value, str) and re.fullmatch(r"(?:(?:openai|anthropic|google)/)?(?:gpt|claude|gemini)[a-z0-9.-]{1,64}", value) else "unknown"
        if key == "changed_artifacts":
            return [name for name in ARTIFACTS if isinstance(value, list) and name in value]
        if key == "summary":
            return self.project(value, "total accounted complete") if isinstance(value, dict) else None
        if key == "converter":
            return self.project(value, "backend sha256") if isinstance(value, dict) else None
        if key == "entries":
            if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
                raise ValueError("malformed-entries")
            return [self.project(row, "id cls dimension delta fix resolved") for row in value]
        if key == "renders":
            return len(value) if isinstance(value, list) else None
        if key == "fields":
            return [self.opaque(item) for item in value] if isinstance(value, list) else None
        return self.opaque(value) if value is not None else None


def collect(workdir):
    projection, inventory, payload = Projection(), {}, {}
    for name, fields in FILES.items():
        try:
            content = read_regular(workdir / name)
            if name.endswith(".jsonl"):
                rows, rejected = [], 0
                for line in content.splitlines():
                    if not line.strip():
                        continue
                    try:
                        rows.append(projection.project(json.loads(line), fields))
                    except (ValueError, TypeError, RecursionError):
                        rejected += 1
                payload[name] = rows
                inventory[name] = {"status": "partial" if rejected else "included", "rejected_records": rejected}
            else:
                payload[name] = projection.project(json.loads(content), fields)
                inventory[name] = {"status": "included"}
        except FileNotFoundError:
            inventory[name] = {"status": "missing"}
        except (OSError, ValueError, TypeError, RecursionError):
            inventory[name] = {"status": "unreadable-or-unsafe"}

    events, rejected = [], 0
    directory = workdir / "diagnostic-events"
    if directory.is_symlink():
        inventory["diagnostic-events"] = {"status": "unreadable-or-unsafe"}
    elif directory.is_dir():
        paths = []
        for path in directory.iterdir():
            if re.fullmatch(r"[0-9a-f]{32}-(start|end)\.json", path.name):
                paths.append(path)
                if len(paths) > MAX_EVENTS:
                    raise ValueError("too many diagnostic events; export refused, nothing packaged")
        for path in sorted(paths):
            try:
                events.append(projection.project(json.loads(read_regular(path, 16384)), EVENT_FIELDS))
            except (OSError, ValueError, TypeError, RecursionError):
                rejected += 1
        inventory["diagnostic-events"] = {"status": "partial" if rejected else "included", "rejected_records": rejected}
    else:
        inventory["diagnostic-events"] = {"status": "missing"}
    payload["diagnostic-events.json"] = events
    payload["collection.json"] = inventory
    return payload


def summarize(payload):
    events = payload.get("diagnostic-events.json", [])
    grouped = defaultdict(list)
    for row in events:
        grouped[row.get("id")].append(row)
    intervals, pairs, incomplete = [], [], 0
    for activity_id, rows in grouped.items():
        starts = [row for row in rows if row.get("event") == "start"]
        ends = [row for row in rows if row.get("event") == "end"]
        if not activity_id or len(starts) != 1 or len(ends) != 1:
            incomplete += 1
            continue
        start, end = starts[0], ends[0]
        a, b = date(start.get("at")), date(end.get("at"))
        elapsed = end.get("elapsed_s")
        if (a is None or b is None or b < a or elapsed is None or elapsed < 0
                or abs(b - a - elapsed) > 2
                or start.get("kind") not in ("invocation", "script", "render", "repair", "review", "mcp", "completion")
                or end.get("clock") not in ("monotonic", "wall")
                or not start.get("operation")
                or any(start.get(key) != end.get(key) for key in ("operation", "kind"))):
            incomplete += 1
            continue
        intervals.append((a, b))
        pairs.append((start, end))
    source = "diagnostic-events"
    phases = payload.get("phase-metrics.jsonl", [])
    phase_durations = [row["wall_s"] for row in phases if row.get("wall_s") is not None and row["wall_s"] >= 0]
    if not events:
        source = "phase-metrics-reconstructed"
        for row in phases:
            end, wall = date(row.get("at")), row.get("wall_s")
            if end is not None and wall is not None and wall >= 0:
                intervals.append((end - wall, end))
    merged = []
    for a, b in sorted(intervals):
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    gaps = [(left[1], right[0]) for left, right in zip(merged, merged[1:])]
    span = merged[-1][1] - merged[0][0] if merged else None
    union = sum(b - a for a, b in merged) if merged else None
    ends = [end for _, end in pairs]
    completions = [end for end in ends if end.get("kind") == "completion" and end.get("operation") in ("verify-complete.rb", "verify-complete.py")]
    latest = max(completions, key=lambda row: date(row["at"])) if completions else None
    ledger = payload.get("fidelity-ledger.json", {})
    entries = ledger.get("entries")
    return {
        "schema_version": 1,
        "timing": {
            "source": source, "span_s": span, "measured_union_s": union,
            "unmeasured_s": span - union if span is not None else None,
            "summed_activity_s": sum(end["elapsed_s"] for end in ends) if ends else None,
            "summed_phase_s": sum(phase_durations) if phase_durations else None,
            "incomplete_or_invalid_activities": incomplete,
            "largest_unmeasured_intervals": [{"start": datetime.fromtimestamp(a, timezone.utc).isoformat(), "end": datetime.fromtimestamp(b, timezone.utc).isoformat(), "seconds": b - a} for a, b in sorted(gaps, key=lambda gap: gap[1] - gap[0], reverse=True)[:10]],
        },
        "observed_activity_counts": dict(Counter(end.get("kind", "unknown") for end in ends)),
        "observed_command_counts": dict(Counter(end.get("operation", "unknown") for end in ends)),
        "recorded_offramp_counts": dict(Counter(row.get("kind", "unknown") for row in payload.get("offramps.jsonl", []))),
        "nonzero_exits": [dict(operation=end.get("operation"), exit_code=end["exit_code"], at=end["at"], error_category=end.get("error_category")) for end in ends if end.get("exit_code") not in (None, 0)],
        "last_observed_completion_check": latest or "unknown",
        "reported_numeric_and_visual": payload.get("parity-final.json", "unknown"),
        "reported_migration_result": payload.get("migration-result.json", "unknown"),
        "unresolved_fidelity_entries": sum(row.get("resolved") is not True for row in entries) if isinstance(entries, list) else None,
        "recorded_fidelity_renders": ledger.get("renders"),
        "coverage": [
            "Local evidence only, not a fresh verification or a completion certificate.",
            "Nonzero exits include designed handoffs, not just failures.",
            "Nested/parallel durations overlap; use the interval union, not the sum, for covered wall time.",
            "Gaps and unmatched starts are unmeasured, never model thinking or idle time.",
            "Clock jumps, missing events, pre-start and post-last-event time are not reconstructed.",
            "MCP/manual work is measured only when explicitly timed. Model/effort may be unknown.",
            "Raw errors, formulas, customer rows, images, IDs, paths and prose are excluded or replaced; targeted reviewed evidence may still be needed.",
        ],
    }


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode("utf-8")


def export_bundle(workdir, output):
    payload = collect(workdir)
    # Freeze the sanitized bytes first. Both summary and manifest consume only
    # these exact bytes; no second reads of changing source artifacts.
    packaged = {name.replace(".jsonl", ".json"): encoded(value) for name, value in payload.items()}
    frozen = {name: json.loads(packaged[name.replace(".jsonl", ".json")]) for name in payload}
    packaged["SUMMARY.json"] = encoded(summarize(frozen))
    packaged["README.txt"] = (
        "LOCAL DIAGNOSTICS - REVIEW BEFORE SHARING\n"
        "Nothing has been uploaded. This ZIP contains typed, sanitized projections, not raw artifacts.\n"
        "Review every member before explicitly sharing it. Treat remaining timing/build metadata as private.\n"
        "MANIFEST.json hashes final packaged bytes, including SUMMARY.json; it does not hash itself.\n"
        "Missing or partial evidence is listed in collection.json. This is not a completion certificate.\n"
    ).encode("utf-8")
    packaged["MANIFEST.json"] = encoded({"schema_version": 1, "files": {name: {"sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)} for name, content in packaged.items()}})
    # Exclusive creation refuses existing files and symlinks, including inputs.
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            with zipfile.ZipFile(handle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, content in packaged.items():
                    archive.writestr(name, content)
    except BaseException:
        Path(output).unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    bundle = sub.add_parser("bundle", help="create a local sanitized ZIP; never upload")
    bundle.add_argument("--workdir", type=Path, required=True)
    bundle.add_argument("--out", type=Path, required=True)
    begin = sub.add_parser("begin", help="start timing MCP/manual work; prints the activity ID")
    begin.add_argument("--workdir", type=Path, required=True)
    begin.add_argument("--kind", choices=("mcp", "repair", "review"), required=True)
    begin.add_argument("--operation", choices=MANUAL_OPERATIONS, required=True)
    end = sub.add_parser("end", help="finish an explicit timer (elapsed wall time, not model thinking)")
    end.add_argument("--workdir", type=Path, required=True)
    end.add_argument("--id", required=True)
    end.add_argument("--exit-code", type=int, required=True)
    args = parser.parse_args()
    if not args.workdir.is_dir():
        parser.error("workdir must already exist")
    try:
        if args.command == "bundle":
            export_bundle(args.workdir.resolve(), args.out)
            print("Local ZIP created. Review its contents before explicitly sharing; nothing was uploaded.")
        elif args.command == "begin":
            span = Span(args.workdir, args.kind, args.operation)
            if not (args.workdir / "diagnostic-events" / (span.event["id"] + "-start.json")).is_file():
                raise ValueError("timer could not be recorded")
            print(span.event["id"])
        else:
            if not re.fullmatch(r"[0-9a-f]{32}", args.id) or (args.workdir / "diagnostic-events").is_symlink():
                raise ValueError("invalid timer")
            start = json.loads(read_regular(args.workdir / "diagnostic-events" / (args.id + "-start.json"), 16384))
            if (not isinstance(start, dict) or start.get("id") != args.id or start.get("event") != "start"
                    or start.get("operation") not in MANUAL_OPERATIONS or date(start.get("at")) is None
                    or start.get("kind") not in ("mcp", "repair", "review") or not -255 <= args.exit_code <= 65535):
                raise ValueError("not an explicit timer")
            at = timestamp()
            event = {key: start[key] for key in ("id", "kind", "operation")}
            event.update(event="end", at=at, elapsed_s=date(at) - date(start["at"]), clock="wall", exit_code=args.exit_code)
            if not emit(args.workdir, event):
                raise ValueError("timer already ended or could not be recorded")
    except (OSError, ValueError, TypeError, RecursionError):
        print("Diagnostics failed: invalid, unreadable, unsafe or oversized input, or output already exists. No upload attempted.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
