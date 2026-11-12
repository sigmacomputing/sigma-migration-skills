#!/usr/bin/env python3
"""Derive <workdir>/relationship-map.json for the reused-DM evidence route.

Python twin of emit-relationship-map.rb. Re-running keeps reasons and every
probe whose edge is unchanged. Inputs (from the workdir): workbook-content.twb,
dm-spec-reused.json, dashboard-scope.json (optional), parity-final.json +
parity-expected.json (optional, summary only).

  python3 scripts/emit-relationship-map.py --workdir <WORK> [--out PATH]
  python3 scripts/emit-relationship-map.py --workdir <WORK> --annotate <INDEX> --reason "<why>"
    (a reason is shown in the report; it never satisfies evidence)

Exit codes: 0 = written; 2 = bad input.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import workdir_guard  # noqa: E402
import relationship_map  # noqa: E402


class BadInput(Exception):
    pass


def read_json(path: Path, required: bool):
    if not path.is_file():
        if required:
            raise BadInput(f"required input missing: {path}")
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except ValueError as exc:
        raise BadInput(f"{path} is malformed JSON: {exc}") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--out")
    parser.add_argument("--annotate", type=int)
    parser.add_argument("--reason")
    parser.add_argument("--db")
    parser.add_argument("--schema")
    parser.add_argument("--table-mapping", action="append", default=[], help="SRC=TABLE (repeatable)")
    args = parser.parse_args()
    workdir_guard.check(args.workdir, "--workdir")
    work = Path(args.workdir).expanduser().resolve()
    out = Path(args.out).expanduser().resolve() if args.out else work / "relationship-map.json"
    try:
        if args.annotate is not None:
            if not (args.reason or "").strip():
                raise BadInput("--annotate requires a non-empty --reason")
            doc = read_json(out, True)
            entry = next((e for e in doc.get("entries") or [] if e.get("index") == args.annotate), None)
            if entry is None:
                raise BadInput(f"no relationship-map entry at index {args.annotate}")
            entry["reason"] = args.reason.strip()
            relationship_map.write(out, doc)
            print(f"relationship-map: entry {args.annotate} ({entry['left']} ↔ {entry['right']}, "
                  f"{entry['disposition']}) — reason recorded")
            return 0
        twb = work / "workbook-content.twb"
        if not twb.is_file():
            raise BadInput(f"required input missing: {twb}")
        twb_xml = twb.read_text(encoding="utf-8-sig")
        dm_spec = read_json(work / "dm-spec-reused.json", True)
        dashboards = relationship_map.scoped_dashboards(read_json(work / "dashboard-scope.json", False))
        if args.db or args.schema or args.table_mapping:
            mapping = dict(pair.split("=", 1) for pair in args.table_mapping if "=" in pair)
            resolution = {"db": args.db, "schema": args.schema, "table_mapping": mapping}
        else:
            resolution = (read_json(work / "migrate-state-python.json", False) or {}).get("relationship_resolution")
        parity = relationship_map.normalize_parity(
            read_json(work / "parity-final.json", False), read_json(work / "parity-expected.json", False)
        )
        try:
            fresh = relationship_map.derive(twb_xml=twb_xml, dm_spec=dm_spec, dashboards=dashboards, resolution=resolution)
        except Exception as exc:  # noqa: BLE001 - report any derivation failure as bad input
            raise BadInput(f"relationship map could not be derived: {type(exc).__name__}: {str(exc)[:160]}") from exc
    except BadInput as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 2
    try:
        prior = json.loads(out.read_text(encoding="utf-8")) if out.is_file() else None
    except ValueError:
        prior = None
    doc = relationship_map.merge_prior(fresh, prior)
    relationship_map.write(out, doc)
    result = relationship_map.evaluate(doc, twb_xml=twb_xml, dm_spec=dm_spec, dashboards=dashboards,
                                       parity=parity, final=False, resolution=resolution)
    print(f"relationship-map: {relationship_map.summary_line(result)} — {result['status'].upper()} -> {out}")
    for blocker in result["blockers"]:
        print(f"  - {blocker['kind']}: {blocker['reason']}")
    if any(b["kind"] == "unprobed" for b in result["blockers"]):
        print(f"  prove the edges: python3 scripts/probe-relationship-map.py --workdir {work} --connection-id <id>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
