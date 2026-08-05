#!/usr/bin/env python3
"""test-extract-viz-signals.py — the extractors must classify every visual by ROLE
CLASS via the catalogs, and must never coerce an unknown visualType to a bar chart.

The bug this guards (measured on 4 real customer .pbix files, 2026-07-30): both
extractors carried their own `VISUAL_KIND` dict whose `.get(vtype, "bar")` default
silently turned every unrecognized visual into a bar chart. That converted 21
third-party Powerviz date-picker SLICERS into bar charts — nearly every page lost
its date filter — plus 4 modern `cardVisual` cards and 5 decorative `shape`s.

Covers BOTH front doors (classic single-file Layout and exploded PBIR) because the
duplicated dict existed in both.

Usage:  python3 scripts/test-extract-viz-signals.py
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

fails = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        fails.append(msg)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


erc = load("erc", os.path.join(HERE, "extract-report-classic.py"))

DATEPICKER = "Datepicker_1687358625_Powerviz_OrgStore"   # measured in R1/R2/R3


def vc(vtype, i):
    """A classic visualContainer with one bound field."""
    return {"x": i * 10, "y": 0, "width": 100, "height": 100, "z": 0,
            "config": json.dumps({"name": f"v{i}", "singleVisual": {
                "visualType": vtype,
                "projections": {"Values": [{"queryRef": "T.C"}]}}})}


REPORT = {"sections": [{"name": "p1", "displayName": "P1", "width": 1280, "height": 720,
                        "visualContainers": [vc(DATEPICKER, 0), vc("cardVisual", 1),
                                             vc("shape", 2), vc("sankeyDiagram", 3),
                                             vc("AcmeMysterySlicer_v3", 4),
                                             vc("clusteredColumnChart", 5)]}]}

print("\n1. classic extractor (extract-report-classic.py)")
sig = erc.extract(REPORT)
by = {v["visual_type"]: v for v in sig["pages"][0]["visuals"]}

check(by[DATEPICKER]["role_class"] == "control",
      "third-party datepicker -> role_class control")
check(by[DATEPICKER]["sigma_target"] == "date-range",
      "third-party datepicker -> sigma_target date-range")
check(by[DATEPICKER]["sigma_kind"] != "bar",
      "third-party datepicker is NOT sigma_kind bar")
check(by["cardVisual"]["role_class"] == "kpi", "cardVisual -> role_class kpi")
check(by["cardVisual"]["sigma_kind"] == "kpi", "cardVisual -> sigma_kind kpi")
check(by["shape"]["role_class"] == "decoration", "shape -> role_class decoration")
check(by["sankeyDiagram"]["role_class"] == "unsupported",
      "sankeyDiagram -> role_class unsupported (not a silent bar)")
check(by["AcmeMysterySlicer_v3"]["role_class"] == "control",
      "unlisted *Slicer* visual -> control via the heuristic")
check(by["clusteredColumnChart"]["role_class"] == "chart",
      "a real column chart is still role_class chart")
check(by["clusteredColumnChart"]["sigma_kind"] == "bar",
      "a real column chart still emits sigma_kind bar (builder contract intact)")

for vt, v in by.items():
    if v["viz_catalog"] != "viz-kind":
        check(bool(v.get("viz_guidance")),
              f"{vt} (catalog={v['viz_catalog']}) carries actionable guidance")

check(not hasattr(erc, "VISUAL_KIND"),
      "the duplicated VISUAL_KIND dict is GONE from extract-report-classic.py")

print("\n2. PBIR extractor (extract-pbir.py) — same contract, same catalogs")
epb = load("epb", os.path.join(HERE, "extract-pbir.py"))
check(not hasattr(epb, "VISUAL_KIND"),
      "the duplicated VISUAL_KIND dict is GONE from extract-pbir.py")
# Both extractors must agree on the same token.
if hasattr(epb, "_VK") and hasattr(erc, "_VK"):
    a = erc._VK.resolve_or_guidance(DATEPICKER)
    b = epb._VK.resolve_or_guidance(DATEPICKER)
    check(a["role_class"] == b["role_class"] and a["sigma"] == b["sigma"],
          "both extractors resolve the datepicker identically")
else:
    check(False, "both extractors expose a catalog resolver (_VK)")

print(f"\n{'ALL PASS' if not fails else f'{len(fails)} FAILURE(S)'}")
for f in fails:
    print(f"  - {f}")
sys.exit(0 if not fails else 1)
