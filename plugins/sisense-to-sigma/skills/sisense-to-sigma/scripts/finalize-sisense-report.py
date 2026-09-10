#!/usr/bin/env python3
"""Finalize Sisense visual evidence, degradation ledger, and migration report."""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import png_health

HERE = Path(__file__).resolve().parent


class FinalizeError(Exception):
    pass


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def named_paths(values):
    result = {}
    for raw in values or []:
        if "=" in raw:
            name, path = raw.split("=", 1)
        else:
            path = raw
            name = Path(path).stem
        name = name.strip()
        if not name or name in result:
            raise FinalizeError("PNG page names must be non-empty and unique: %s" % raw)
        candidate = Path(path).expanduser().resolve()
        if not candidate.is_file():
            raise FinalizeError("PNG does not exist: %s" % candidate)
        result[name] = candidate
    return result


def waivers(values):
    result = {}
    for raw in values or []:
        if "=" not in raw:
            raise FinalizeError(
                "--waive-source-page requires PAGE=REASON (a page name and explicit reason)"
            )
        page, reason = raw.split("=", 1)
        if not page.strip() or not reason.strip():
            raise FinalizeError("--waive-source-page requires non-empty PAGE=REASON")
        result[page.strip()] = reason.strip()
    return result


def tile_paths(values):
    result = {}
    for raw in values or []:
        if "=" in raw:
            page, path = raw.split("=", 1)
            page = page.strip()
        else:
            page, path = "*", raw
        if not page or page in result:
            raise FinalizeError("--tiles page names must be non-empty and unique")
        candidate = Path(path).expanduser().resolve()
        if not candidate.is_file():
            raise FinalizeError("--tiles does not exist: %s" % candidate)
        result[page] = candidate
    if "*" in result and len(result) > 1:
        raise FinalizeError("an unnamed --tiles PATH cannot be combined with PAGE=PATH entries")
    return result


def run(command, cwd=None):
    process = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if process.stdout:
        print(process.stdout.rstrip())
    if process.stderr:
        print(process.stderr.rstrip(), file=sys.stderr)
    return process.returncode


def visual_phase(workdir, sources, targets, source_waivers, tiles):
    all_health = []
    failures = []
    for side, pages in (("source", sources), ("target", targets)):
        for page, path in sorted(pages.items()):
            health = png_health.analyze_image(path)
            health.update({"side": side, "page": page})
            all_health.append(health)
            if health.get("status") != "PASS":
                failures.append("%s page %s is %s" % (side, page, health.get("status")))

    if not targets:
        failures.append("no target PNGs were supplied")
    similarities = []
    for page, target in sorted(targets.items()):
        source = sources.get(page)
        if source is None:
            if page not in source_waivers:
                failures.append(
                    "target page %s has no source PNG and no --waive-source-page %s=REASON" %
                    (page, page)
                )
            continue
        output = workdir / "visual-similarity-%s.json" % page.replace("/", "_")
        command = [
            sys.executable, str(HERE / "visual-similarity.py"),
            "--source", str(source), "--render", str(target),
            "--json-out", str(output),
        ]
        page_tiles = tiles.get(page) or tiles.get("*")
        if page_tiles:
            command += ["--tiles", str(page_tiles)]
        rc = run(command)
        result = {}
        try:
            result = json.loads(output.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            result = {"pass": False, "notes": ["visual-similarity output missing"]}
        result.update({"page": page, "artifact": output.name})
        similarities.append(result)
        if rc != 0 or result.get("pass") is not True:
            failures.append("visual similarity failed for page %s" % page)

    unused_sources = sorted(set(sources) - set(targets))
    for page in unused_sources:
        failures.append("source page %s has no target PNG pair" % page)
    unknown_waivers = sorted(set(source_waivers) - set(targets))
    if unknown_waivers:
        failures.append("source-page waiver names no target page: %s" %
                        ", ".join(unknown_waivers))

    render_health = {
        "schema_version": 1,
        "status": "PASS" if not failures else "FAIL",
        "images": all_health,
        "similarity": similarities,
        "source_page_waivers": [
            {"page": page, "reason": reason}
            for page, reason in sorted(source_waivers.items())
        ],
        "reasons": failures,
        "checked_at_epoch": int(time.time()),
    }
    write_json(workdir / "render-health.json", render_health)
    # The shared gate consumes the singular conventional artifact when one
    # comparison exists. Preserve per-page detail separately.
    if len(similarities) == 1:
        write_json(workdir / "visual-similarity.json", similarities[0])
    elif similarities:
        write_json(workdir / "visual-similarity.json", {
            "pass": all(row.get("pass") is True for row in similarities),
            "pages": similarities,
        })
    return render_health


def finalize_report(workdir):
    ledger_code = (
        "entries=DegradationLedger.derive(ARGV.fetch(0));"
        "exit(DegradationLedger.write(ARGV.fetch(0),entries) ? 0 : 1)"
    )
    ledger_rc = run([
        "ruby", "-I", str(HERE / "lib"), "-rdegradation_ledger",
        "-e", ledger_code, str(workdir),
    ])
    report_command = [
        "ruby", str(HERE / "build-migration-report.rb"),
        "--workdir", str(workdir),
        "--inventory", str(workdir / "source-object-census.json"),
    ]
    report_rc = run(report_command)
    check_rc = run(report_command + ["--check"])
    report = {}
    try:
        report = json.loads((workdir / "migration-result.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
    failures = []
    if ledger_rc:
        failures.append("degradation ledger generation failed")
    if report_rc:
        failures.append("migration report is contradictory or RED")
    if check_rc:
        failures.append("migration report freshness check failed")
    if str(report.get("verdict") or "").upper() == "RED":
        failures.append("migration-result.json verdict is RED")
    completion = {
        "schema_version": 1,
        "status": "PASS" if not failures else "FAIL",
        "report_verdict": report.get("verdict"),
        "failures": failures,
        "finalized_at_epoch": int(time.time()),
    }
    write_json(workdir / "sisense-report-finalization.json", completion)
    return completion


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--source-png", action="append", default=[],
                        metavar="PAGE=PATH")
    parser.add_argument("--target-png", action="append", default=[],
                        metavar="PAGE=PATH")
    parser.add_argument("--waive-source-page", action="append", default=[],
                        metavar="PAGE=REASON")
    parser.add_argument("--tiles", action="append", default=[], metavar="PAGE=PATH")
    parser.add_argument("--visual-only", action="store_true")
    args = parser.parse_args(argv)

    workdir = Path(args.workdir).expanduser().resolve()
    if not workdir.is_dir():
        raise FinalizeError("--workdir is not a directory: %s" % workdir)
    sources = named_paths(args.source_png)
    targets = named_paths(args.target_png)
    source_waivers = waivers(args.waive_source_page)
    tiles = tile_paths(args.tiles)

    visual = visual_phase(workdir, sources, targets, source_waivers, tiles)
    if args.visual_only:
        print("Sisense visual evidence: %s" % visual["status"])
        return 0 if visual["status"] == "PASS" else 1
    report = finalize_report(workdir)
    ok = visual["status"] == "PASS" and report["status"] == "PASS"
    print("Sisense report finalization: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except FinalizeError as error:
        print("finalize-sisense-report: %s" % error, file=sys.stderr)
        sys.exit(2)
