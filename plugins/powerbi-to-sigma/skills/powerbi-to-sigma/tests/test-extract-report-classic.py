#!/usr/bin/env python3
"""test-extract-report-classic.py — synthetic regression for the LOCAL .pbix
report front door added to extract-report-classic.py.

Proves the three input modes all normalize the SAME classic report into the
SAME signals.json:
  --pbix          : unzips a synthetic .pbix's UTF-16LE `Report/Layout` member
  --report-layout : a standalone UTF-16LE (with BOM) Layout file
  --report-json   : the original UTF-8 report.json path (must still work)

100% synthetic — a tiny hand-authored classic layout with GENERIC
SALES_FACT / DATE_DIM names. No .pbix on disk, no pbixray, no network.

Run: python3 tests/test-extract-report-classic.py   (exit 0 = pass)
"""
import json, os, subprocess, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "extract-report-classic.py")


def _cfg(name, visual_type, projections=None, title=None, text=None):
    sv = {"visualType": visual_type}
    if projections:
        sv["projections"] = {role: [{"queryRef": q} for q in qs]
                             for role, qs in projections.items()}
    objects = {}
    if title:
        objects["title"] = [{"properties": {"text": {"expr": {"Literal": {"Value": f"'{title}'"}}}}}]
    if text is not None:
        objects["general"] = [{"properties": {"paragraphs": [{"textRuns": [{"value": text}]}]}}]
    if objects:
        sv["objects"] = objects
    return json.dumps({"name": name, "singleVisual": sv})


# Hand-authored CLASSIC report layout (top-level sections[]). Generic names only.
LAYOUT = {
    "sections": [
        {
            "name": "ReportSection1", "displayName": "Sales Overview",
            "width": 1280, "height": 720,
            "visualContainers": [
                {"x": 0, "y": 0, "width": 200, "height": 100, "z": 0,
                 "config": _cfg("v_kpi", "card",
                                {"Values": ["SALES_FACT.Total Sales"]}, title="Total Sales")},
                {"x": 0, "y": 120, "width": 600, "height": 300, "z": 1,
                 "config": _cfg("v_bar", "clusteredColumnChart",
                                {"Category": ["DATE_DIM.Month"], "Y": ["SALES_FACT.Total Sales"]})},
                {"x": 620, "y": 120, "width": 300, "height": 100, "z": 2,
                 "config": _cfg("v_txt", "textbox", text="Regional sales summary")},
            ],
        },
        {
            "name": "ReportSection2", "displayName": "Trend",
            "width": 1280, "height": 720,
            "visualContainers": [
                {"x": 0, "y": 0, "width": 600, "height": 300, "z": 0,
                 "config": _cfg("v_line", "lineChart",
                                {"Category": ["DATE_DIM.Month"], "Y": ["SALES_FACT.Total Sales"]})},
            ],
        },
    ]
}


def _run(args, out_path):
    r = subprocess.run([sys.executable, SCRIPT, *args, "--out", out_path],
                       capture_output=True, text=True)
    assert r.returncode == 0, f"extractor failed ({r.returncode}) args={args}\n{r.stderr}"
    with open(out_path) as f:
        return json.load(f)


def _assert_signals(sig, mode):
    assert sig["source"] == "report.json-classic", f"[{mode}] source={sig['source']}"
    assert len(sig["pages"]) == 2, f"[{mode}] pages={len(sig['pages'])}"
    p1, p2 = sig["pages"]
    assert p1["page_title"] == "Sales Overview", f"[{mode}] {p1['page_title']}"
    assert p2["page_title"] == "Trend", f"[{mode}] {p2['page_title']}"
    kinds = {v["visual_type"]: v for v in p1["visuals"]}
    assert kinds["card"]["sigma_kind"] == "kpi", f"[{mode}] card->{kinds['card']['sigma_kind']}"
    assert kinds["card"]["bindings"] == {"Values": ["SALES_FACT.Total Sales"]}, f"[{mode}] {kinds['card']['bindings']}"
    bar = kinds["clusteredColumnChart"]
    assert bar["sigma_kind"] == "bar", f"[{mode}] bar->{bar['sigma_kind']}"
    assert bar["bindings"] == {"Category": ["DATE_DIM.Month"], "Y": ["SALES_FACT.Total Sales"]}, f"[{mode}] {bar['bindings']}"
    assert bar["stacking"] == "none", f"[{mode}] stacking={bar['stacking']}"
    assert kinds["textbox"]["sigma_kind"] == "text", f"[{mode}] textbox->{kinds['textbox']['sigma_kind']}"
    line = p2["visuals"][0]
    assert line["visual_type"] == "lineChart" and line["sigma_kind"] == "line", f"[{mode}] line"
    print(f"  ok [{mode}]: 2 pages, {sum(len(p['visuals']) for p in sig['pages'])} visuals, bindings + kinds match")


def main():
    layout_json = json.dumps(LAYOUT)
    with tempfile.TemporaryDirectory() as d:
        # --pbix: a synthetic .pbix (zip) whose Report/Layout is UTF-16LE (no BOM).
        pbix = os.path.join(d, "Synthetic.pbix")
        with zipfile.ZipFile(pbix, "w") as z:
            z.writestr("Report/Layout", layout_json.encode("utf-16-le"))
            z.writestr("Version", "1.0")           # decoy members
            z.writestr("[Content_Types].xml", "<Types/>")
        _assert_signals(_run(["--pbix", pbix], os.path.join(d, "s1.json")), "pbix")

        # --report-layout: standalone UTF-16LE file WITH a BOM.
        layout_file = os.path.join(d, "Layout")
        with open(layout_file, "wb") as f:
            f.write(b"\xff\xfe" + layout_json.encode("utf-16-le"))
        _assert_signals(_run(["--report-layout", layout_file], os.path.join(d, "s2.json")), "report-layout")

        # --report-json: original UTF-8 path must still work.
        rj = os.path.join(d, "report.json")
        with open(rj, "w", encoding="utf-8") as f:
            f.write(layout_json)
        _assert_signals(_run(["--report-json", rj], os.path.join(d, "s3.json")), "report-json")

        # A .pbix with no Report/Layout member must fail with a clear message.
        bad = os.path.join(d, "NoLayout.pbix")
        with zipfile.ZipFile(bad, "w") as z:
            z.writestr("Version", "1.0")
        r = subprocess.run([sys.executable, SCRIPT, "--pbix", bad, "--out", os.path.join(d, "x.json")],
                           capture_output=True, text=True)
        assert r.returncode != 0 and "Report/Layout" in r.stderr, f"expected clear no-Layout error, got {r.returncode}: {r.stderr}"
        print("  ok [no-layout]: missing Report/Layout member fails with a clear message")

    print("PASS test-extract-report-classic.py")


if __name__ == "__main__":
    main()
