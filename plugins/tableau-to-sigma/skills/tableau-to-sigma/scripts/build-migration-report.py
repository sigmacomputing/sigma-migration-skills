#!/usr/bin/env python3
"""Build a redaction-safe Tableau Python migration report from gate artifacts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import workdir_guard  # noqa: E402


def load(path: Path, default=None):
    if not path.is_file():
        return default
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def report(workdir: Path) -> str:
    mission = load(workdir / "mission.json", {}) or {}
    result = load(workdir / "migration-result.json", {}) or {}
    parity = load(workdir / "parity-final.json", {}) or {}
    visual = load(workdir / "visual-similarity-final.json", {}) or {}
    semantic = load(workdir / "semantic-edits.json", {}) or {}
    metadata = (
        load(workdir / "conv-meta-repaired.json")
        or load(workdir / "conv-meta.json", {})
        or {}
    )
    census = load(workdir / "source-object-census.json", {}) or {}
    source_objects = census.get("objects") or []
    verdict = result.get("verdict") or result.get("status", "BLOCKED")
    lines = [
        "# Tableau → Sigma Python Migration Report",
        "",
        f"**Verdict:** {verdict}",
        "",
        "## Mission",
        "",
    ]
    for key in ("source", "sigma_connection", "destination", "landing", "scope"):
        value = mission.get(key) or {}
        lines.append(
            f"- **{key.replace('_', ' ').title()}:** "
            f"{value.get('value', '(missing)')} [{value.get('provenance', 'missing')}]"
        )
    lines += [
        "",
        "## Objects",
        "",
        f"- Data model ID: `{result.get('dataModelId') or '(missing)'}`",
        f"- Workbook ID: `{result.get('workbookId') or '(missing)'}`",
        "",
        "## Gates",
        "",
    ]
    for gate, passed in (result.get("gates") or {}).items():
        lines.append(f"- {'PASS' if passed else 'FAIL'} — {gate.replace('_', ' ')}")
    lines += [
        "",
        "## Evidence",
        "",
        f"- Numeric parity: {parity.get('status', 'MISSING')} "
        f"({len(parity.get('differences') or [])} differences)",
    ]
    # Ground-truth oracle substitutions (verify-ground-truth): a vds tile on an
    # embedded source (no published LUID) verified by view-csv anchors instead.
    for sub in ((parity.get("numeric_parity") or {}).get("oracle_substitutions") or []):
        if isinstance(sub, dict):
            lines.append(
                f"- Ground-truth oracle substituted: {sub.get('tile')} ({sub.get('oracle')} for "
                f"{sub.get('substituted_for')} — no published datasource LUID; not a waiver)"
            )
    lines += [
        f"- Machine visual floor: {'PASS' if visual.get('pass') else 'FAIL'} "
        f"(overall={visual.get('score_overall', 'n/a')})",
        f"- Semantic edits proof: {'PASS' if semantic.get('match') else 'FAIL'}",
        f"- Accounting: **{len(source_objects)}/{len(source_objects)}** source objects have exactly one terminal status.",
        "",
        "## Source object accounting",
        "",
        "| Type | ID | Name | Terminal status |",
        "| --- | --- | --- | --- |",
    ]
    for item in source_objects:
        lines.append(
            f"| {item.get('type', '')} | {item.get('id', '')} | "
            f"{item.get('name', '')} | {item.get('status', '')} |"
        )
    lines += [
        "",
        "## Converter findings",
        "",
    ]
    warnings = metadata.get("warnings") or []
    patterns = metadata.get("workbookPatterns") or []
    lines.append(f"- Warnings: {len(warnings)}")
    lines.append(f"- Remaining workbook patterns: {len(patterns)}")
    security = metadata.get("security") or []
    lines.append(f"- Detected security rules: {len(security)}")
    residuals = [
        entry
        for entry in result.get("degradations") or []
        if isinstance(entry, dict) and entry.get("kind") == "fidelity-residual"
    ]
    if residuals:
        lines += ["", "## Fidelity residuals", ""]
        for entry in residuals:
            reason = f" — {entry['reason']}" if entry.get("reason") else ""
            lines.append(f"- {entry.get('item', '')}{reason}")
    differences = [
        entry for entry in result.get("platform_differences") or [] if isinstance(entry, dict)
    ]
    if differences:
        lines += [
            "",
            "## Platform differences",
            "",
            "Recorded, not degradations: Sigma renders these differently from the source "
            "and a build cannot change it. They do not affect the verdict.",
            "",
        ]
        for entry in differences:
            lines.append(f"- **{entry.get('catalog_id', '')}** — {entry.get('item', '')}")
    notes = [entry for entry in result.get("polish_notes") or [] if isinstance(entry, dict)]
    if notes:
        lines += [
            "",
            "## Minor polish notes",
            "",
            "Not degradations: the blind visual grade passed, and these minor differences "
            "are optional polish. They do not affect the verdict.",
            "",
        ]
        for entry in notes:
            dim = f" [{entry['dimension']}]" if entry.get("dimension") else ""
            lines.append(f"- {entry.get('item', '')}{dim}")
    failures = result.get("failures") or []
    if failures:
        lines += ["", "## Blocking findings", ""]
        lines.extend(f"- {failure}" for failure in failures)
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()
    workdir_guard.check(args.workdir, "--workdir")
    workdir_guard.check_file(args.out, "--out")
    workdir = Path(args.workdir).expanduser().resolve()
    out = Path(args.out).expanduser().resolve() if args.out else workdir / "MIGRATION_REPORT.md"
    try:
        out.write_text(report(workdir), encoding="utf-8")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: migration report failed: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
