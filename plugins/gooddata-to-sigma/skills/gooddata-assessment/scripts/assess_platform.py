#!/usr/bin/env python3
"""assess_platform.py — legacy GoodData *Platform* estate readout (read-only).

The Platform twin of assess.py. assess.py scores GoodData *Cloud* workspaces
(Bearer token, /api/v1). This scores classic *Platform* projects (SST/TT flow,
/gdc metadata API) and — crucially — sweeps EVERY project the logged-in user can
access from ONE host + ONE identity. That is the multi-"instance" answer for
Platform customers: classic instances are projects under a single domain, so a
user with access to all of them is assessed in a single `--all` run. (Contrast
Cloud, where each org is a separate host+token; there you loop credentials.)

Scoring reuses the SAME MAQL translator as the converter (via
discover_platform.normalize_maql -> maql.translate), so classic-dialect coverage
is measured with real logic, not guessed.

Usage:
  export GOODDATA_PLATFORM_HOST=https://acme.on.gooddata.com
  export GOODDATA_PLATFORM_USER=...   GOODDATA_PLATFORM_PASSWORD=...
  python3 assess_platform.py --all                 # every accessible project
  python3 assess_platform.py --project <pid>       # one project

Status: built from docs, NOT yet run against a live Platform org. Classic reports
/ dashboards do not carry Cloud `visualizationUrl`, so the viz-type histogram
that assess.py prints for Cloud is replaced here by report / dashboard COUNTS;
per-object widget-type tagging is a documented fast-follow once we see a live
report definition.
"""
import argparse, os, sys

# reuse the Platform client + normalizing extractor + shared MAQL translator
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "gooddata-to-sigma", "scripts"))
from platform_auth import PlatformClient          # noqa: E402
from discover_platform import discover_project     # noqa: E402
from maql import translate                          # noqa: E402


def assess_project(c, pid):
    layout = discover_project(c, pid)
    an = layout["analytics"]
    ds = layout["ldm"]["datasets"]
    syms = layout["symbols"]

    cats = {}
    for m in an["metrics"]:
        cat = translate(m["content"]["maql"], syms).get("category", "UNHANDLED")
        cats[cat] = cats.get(cat, 0) + 1

    nattr = sum(len(d["attributes"]) for d in ds)
    nfact = sum(len(d["facts"]) for d in ds)
    reports, legacy_dash, kpi_dash = (len(an["reports"]),
                                      len(an["projectDashboards"]),
                                      len(an["analyticalDashboards"]))

    # per-project tag: hardest MAQL construct present drives the tag.
    tag = ("MANUAL" if (cats.get("UNHANDLED")) else
           "MANUAL" if (cats.get("CONTEXT") or cats.get("TIME_INTEL")) else
           "HINT" if cats.get("WHERE") else
           "AUTO")

    print(f"\n=== {layout['project']['id']}  {layout['project']['title']} ===")
    print(f"  datasets {len(ds)} | attributes {nattr} | facts {nfact} | metrics {len(an['metrics'])}")
    print(f"  reports {reports} | legacy dashboards {legacy_dash} | KPI dashboards {kpi_dash}")
    print(f"  MAQL coverage: {cats}")
    print(f"  project tag: {tag}")
    return {"id": pid, "title": layout["project"]["title"], "tag": tag,
            "metrics": len(an["metrics"]), "cats": cats,
            "reports": reports, "legacy_dash": legacy_dash, "kpi_dash": kpi_dash}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", help="assess a single project id")
    ap.add_argument("--all", action="store_true", help="assess every accessible project")
    a = ap.parse_args()

    c = PlatformClient()
    if a.project:
        assess_project(c, a.project)
        return
    if not a.all:
        sys.exit("--project <id> or --all required")

    projects = c.projects()
    print(f"Platform host {c.host}: {len(projects)} accessible project(s) — one identity, one sweep.")
    rows = []
    for p in projects:
        try:
            rows.append(assess_project(c, p["id"]))
        except SystemExit as e:               # one project failing must not abort the estate
            print(f"\n=== {p['id']}  {p['title']} ===\n  SKIPPED: {e}")

    # estate roll-up
    if rows:
        by_tag = {}
        for r in rows:
            by_tag[r["tag"]] = by_tag.get(r["tag"], 0) + 1
        tot_metrics = sum(r["metrics"] for r in rows)
        print("\n" + "=" * 48)
        print(f"ESTATE: {len(rows)} projects | {tot_metrics} metrics total")
        print(f"  project tags: {by_tag}")
        print("  migration order (AUTO first, then HINT, MANUAL):")
        order = {"AUTO": 0, "HINT": 1, "MANUAL": 2}
        for r in sorted(rows, key=lambda r: (order.get(r["tag"], 3), -r["metrics"])):
            print(f"    [{r['tag']:6}] {r['id']:12} {r['title']}  "
                  f"({r['metrics']} metrics, {r['reports']} reports)")


if __name__ == "__main__":
    main()
