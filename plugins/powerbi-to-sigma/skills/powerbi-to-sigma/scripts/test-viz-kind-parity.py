#!/usr/bin/env python3
"""test-viz-kind-parity.py — the Ruby resolver and the Python resolver MUST agree.

lib/pbi_viz_kind.rb (builder) and lib/pbi_viz_kind.py (extractors) read the same
two catalogs, but they are two implementations. If they disagree, the extractor
emits one kind and the builder records another — which is exactly the class of
drift that produced the original bug (a Python `VISUAL_KIND` dict that had silently
diverged from the Ruby `SIGMA_KIND` catalog).

This asserts field-by-field agreement across every native visualType in
viz-kind.json, every custom-visual pattern's representative token, the
slicer/date heuristic, and unknown tokens.

Usage:  python3 scripts/test-viz-kind-parity.py
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import pbi_viz_kind  # noqa: E402

CAT_DIR = pbi_viz_kind.default_catalog_dir(__file__)
PY = pbi_viz_kind.load(CAT_DIR)

# Tokens to compare: every native type, a representative token per custom-visual
# row, heuristic hits, and unknowns.
with open(os.path.join(CAT_DIR, "viz-kind.json")) as f:
    NATIVE = [t for r in json.load(f)["rows"] for t in (r.get("pbi_visual_types") or [])]
REPRESENTATIVE = [
    "Datepicker_1687358625_Powerviz_OrgStore",   # measured in customer report R1/R2/R3
    "iconMapProE938B1CED4834168A55864E1F8E7242E",  # measured in R1
    "ChicletSlicer1455240051538", "HierarchySlicer1658301220291",
    "Timeline1447991079480", "TextFilter1234", "PlayAxis99", "ZebraBICharts1",
    "Inforiver5", "ZoomChartsDrillDownCombo", "bulletChart42", "GanttChartX",
    "SankeyDiagram1446581161online", "WordCloud1447958479074",
    "InfographicDesigner1", "CalendarHeatmap7",
    # heuristic-only (deliberately not in the catalog)
    "AcmeSuperSlicer_v2", "FancyDateRangePicker_9", "MyToggleThing",
    # unknown, no hint
    "TotallyMadeUpVisual_9999_Vendor_Store", "WidgetOfDoom",
]
TOKENS = NATIVE + REPRESENTATIVE

RUBY = r'''
require 'json'
require File.join(Dir.pwd, 'lib', 'pbi_viz_kind')
cat = PbiVizKind.load(ARGV[0])
out = {}
JSON.parse(ARGV[1]).each do |t|
  r = cat.resolve_or_guidance(t)
  out[t] = { 'role_class' => r['role_class'], 'sigma' => r['sigma'],
             'builder_kind' => r['builder_kind'], 'catalog' => r['catalog'],
             'approximate' => (r['approximate'] ? true : false),
             'has_guidance' => !r['guidance'].to_s.strip.empty? }
end
puts JSON.generate(out)
'''

res = subprocess.run(["ruby", "-e", RUBY, CAT_DIR, json.dumps(TOKENS)],
                     cwd=HERE, capture_output=True, text=True)
if res.returncode != 0:
    print("FAIL  ruby resolver errored:\n" + res.stderr)
    sys.exit(1)
rb = json.loads(res.stdout)

fails = []
for t in TOKENS:
    r = PY.resolve_or_guidance(t)
    mine = {"role_class": r["role_class"], "sigma": r["sigma"],
            "builder_kind": r["builder_kind"], "catalog": r["catalog"],
            "approximate": bool(r["approximate"]),
            "has_guidance": bool((r["guidance"] or "").strip())}
    theirs = rb.get(t)
    if mine != theirs:
        fails.append(f"{t}: python={mine} ruby={theirs}")

print(f"compared {len(TOKENS)} visualType tokens across both resolvers")
for f in fails:
    print("  FAIL  " + f)

# Guard the specific regressions this work exists to prevent.
def expect(token, key, want):
    got = PY.resolve_or_guidance(token)[key]
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {token} {key}={got!r} (want {want!r})")
    if not ok:
        fails.append(f"{token} {key}={got!r} want {want!r}")

print("\nregression guards:")
expect("Datepicker_1687358625_Powerviz_OrgStore", "role_class", "control")
expect("Datepicker_1687358625_Powerviz_OrgStore", "sigma", "date-range")
expect("cardVisual", "role_class", "kpi")
expect("shape", "role_class", "decoration")
expect("shape", "sigma", None)
expect("AcmeSuperSlicer_v2", "role_class", "control")
expect("TotallyMadeUpVisual_9999_Vendor_Store", "role_class", "unsupported")
expect("TotallyMadeUpVisual_9999_Vendor_Store", "sigma", None)

print(f"\n{'ALL PASS' if not fails else f'{len(fails)} FAILURE(S)'}")
sys.exit(0 if not fails else 1)
