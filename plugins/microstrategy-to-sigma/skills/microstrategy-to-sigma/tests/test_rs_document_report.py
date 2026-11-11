#!/usr/bin/env python3
"""Offline regression for scripts/convert-rs-document.py (Report Services
document -> Sigma Report contents).

  1. GOLDEN       — the hand-built tutorial invoice converts byte-for-byte to
     fixtures/rs-documents/golden/ (report body + feature gaps).
  2. STRUCTURE    — every element is placed exactly once; page/panel roots match
     pages[]/panels[]; boxes sit inside their page or panel; no workbook grid syntax.
  3. GEOMETRY     — inches -> px at 96 dpi, margin offset, points -> px, the 24px
     minimum text line box.
  4. SEMANTICS    — detail columns ordered by Left and named by the aligned Detail
     Header label; footer metrics are Sum() subtotals with the control's own format;
     the group control drives the detail table from a hidden page.
  5. LOUD GAPS    — an unmapped control type and a missing default group value are
     BLOCKING (exit 2, --allow-gaps -> 0); a bad format id is exit 1.
  6. BANDED MODE  — a grouping without page breaks becomes table groupings.

Run: python3 tests/test_rs_document_report.py   (exit 0 = pass)
Regenerate goldens after an intended change: add --update-golden.
"""
import copy
import importlib.util
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPT = os.path.join(SKILL, "scripts", "convert-rs-document.py")
FIXTURE = os.path.join(SKILL, "fixtures", "rs-documents", "tutorial-invoice.rs-document.json")
GOLDEN_DIR = os.path.join(SKILL, "fixtures", "rs-documents", "golden")
CONN = "00000000-0000-0000-0000-000000000000"

_spec = importlib.util.spec_from_file_location("convert_rs_document", SCRIPT)
crd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(crd)


def convert(doc, *extra):
    """Run main() on an in-memory document; return (rc, spec, gaps, cmap)."""
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "doc.json")
        with open(src, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
        outs = [os.path.join(td, n) for n in ("spec.json", "gaps.json", "map.json")]
        argv = ["--document", src, "--connection-id", CONN, "--out", outs[0],
                "--gaps-out", outs[1], "--map-out", outs[2]] + list(extra)
        devnull = open(os.devnull, "w")
        saved = sys.stdout, sys.stderr
        sys.stdout = sys.stderr = devnull
        try:
            rc = crd.main(argv)
        finally:
            sys.stdout, sys.stderr = saved
            devnull.close()
        loaded = [json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None for p in outs]
        if loaded[0] is not None:
            loaded[0]["_raw"] = open(outs[0], encoding="utf-8").read()
            loaded[1]["_raw"] = open(outs[1], encoding="utf-8").read()
    return (rc,) + tuple(loaded)


def fixture():
    return json.load(open(FIXTURE, encoding="utf-8"))


def layout_roots(contents):
    return list(ET.fromstring("<root>%s</root>" % re.sub(r"<\?xml[^>]*\?>", "", contents["layout"])))


def test_golden(update):
    rc, spec, gaps, _ = convert(fixture())
    assert rc == 0, rc
    for name, obj in (("tutorial-invoice.report.json", spec), ("tutorial-invoice.feature-gaps.json", gaps)):
        path = os.path.join(GOLDEN_DIR, name)
        if update:
            os.makedirs(GOLDEN_DIR, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(obj["_raw"])
            continue
        assert os.path.exists(path), "missing golden %s (run with --update-golden)" % path
        assert open(path, encoding="utf-8").read() == obj["_raw"], \
            "%s drifted from golden; rerun with --update-golden if intended" % name
    print("[ok] golden: tutorial invoice report body + feature gaps match%s" % (" (updated)" if update else ""))


def test_structure():
    _, spec, _, _ = convert(fixture())
    c = spec["contents"]
    assert c["kind"] == "report" and c["schemaVersion"] == 1
    assert "/v2/" not in spec["folderId"] and spec["folderId"] == "{{FOLDER_ID}}"
    W, H = c["config"]["pageWidth"], c["config"]["pageHeight"]
    page_ids = {p["id"] for p in c["pages"]}
    panel_h = {p["id"]: p["config"]["height"] for p in c.get("panels", [])}
    placed = []
    for root in layout_roots(c):
        rid = root.get("id")
        if root.tag == "Page":
            assert rid in page_ids, rid
            bw, bh = W, H
        else:
            assert root.tag == "Panel" and rid in panel_h, (root.tag, rid)
            assert root.get("type") in ("header", "footer")
            bw, bh = W, panel_h[rid]
        for el in root:
            assert el.tag == "Element", el.tag
            assert not set(el.attrib) & {"gridColumn", "gridRow"}, el.attrib
            x, y, w, h = (int(el.get(k)) for k in ("x", "y", "width", "height"))
            assert x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= bw and y + h <= bh, (rid, el.attrib)
            placed.append(el.get("elementId"))
    ids = [e["id"] for e in c["elements"]]
    assert len(ids) == len(set(ids)), "duplicate element ids"
    assert sorted(placed) == sorted(ids), "every element must be placed exactly once"
    print("[ok] structure: %d elements placed once inside %d page(s) + %d panel(s)"
          % (len(ids), len(page_ids), len(panel_h)))


def test_geometry():
    assert crd.px(8.5) == 816 and crd.px(11) == 1056 and crd.px(0.5) == 48
    _, spec, _, cmap = convert(fixture())
    c = spec["contents"]
    assert c["config"] == {"pageWidth": 816, "pageHeight": 1056, "margin": 48}
    box = {m["source_control"]: m["bbox_px"] for m in cmap["controls"] if "bbox_px" in m}
    # Customer Header starts at margin (48) + page-header panel (0.45 in = 43 px) = 91.
    assert box["customer-name"]["x"] == 48 + crd.px(0.11) and box["customer-name"]["y"] == 91 + crd.px(0.37)
    assert box["title"] == {"x": 48 + crd.px(4.34), "y": crd.px(0.03), "width": crd.px(2.4), "height": 24}
    assert box["remit-to-address"]["height"] == 3 * crd.MIN_LINE_PX
    bodies = {e["id"]: e.get("body", "") for e in c["elements"]}
    assert "font-size: 24px" in bodies["rs-title"] and bodies["rs-title"].count("***") == 2  # 18pt bold italic
    assert "font-size: 11px" in bodies["rs-terms"]                                        # 8pt
    print("[ok] geometry: 96 dpi, margin + panel offsets, pt->px, 24px line box")


def test_semantics():
    _, spec, gaps, _ = convert(fixture())
    els = {e["id"]: e for e in spec["contents"]["elements"]}
    table = els["rs-detail"]
    visible = [c["name"] for c in table["columns"] if not c.get("hidden")]
    assert visible == ["Date", "Item #", "Item Description", "Amount"], visible
    assert table["order"][:4] == ["col-day", "col-item-id", "col-item", "col-cost"]
    cost = next(c for c in table["columns"] if c["id"] == "col-cost")
    assert cost["format"] == {"kind": "number", "formatString": "$,.2f"} and cost["formula"] == "[INVOICE_LINES/Cost]"
    assert table["tableStyle"]["textStyles"]["columnHeader"]["backgroundColor"] == "#C0C0C0"
    assert {f["kind"] for f in table["filters"]} == {"list", "date-range"}
    assert els["rs-total-charge"]["body"].endswith("**{{Sum([Invoice Lines/Amount]) | $,.2f}}**</span>")
    assert "{{Sum([Invoice Lines/Amount])}}" in els["rs-total-due"]["body"]   # default format kept
    assert "{{First([Invoice Lines/Customer City])}}, {{First([Invoice Lines/Customer State])}}" \
        in els["rs-customer-city-state"]["body"]
    ctl = els["rs-ctl-customer"]
    assert ctl["selectionMode"] == "single" and ctl["value"] == "Aaronson Maxwell" and "values" not in ctl
    assert ctl["filters"] == [{"source": {"kind": "table", "elementId": "rs-detail"}, "columnId": "col-customer"}]
    hidden = next(p for p in spec["contents"]["pages"] if p.get("visibility") == "hidden")
    roots = {r.get("id"): [e.get("elementId") for e in r] for r in layout_roots(spec["contents"])}
    assert roots[hidden["id"]] == ["rs-ctl-customer"]
    review = {g["control"] for g in gaps["gaps"] if g["severity"] == "review"}
    assert {"invoice-date", "due-date"} <= review          # Ship Date is not group-dependent
    assert gaps["mode"] == "invoice" and gaps["blocking"] == 0
    print("[ok] semantics: Left-ordered labelled columns, Sum subtotals, hidden-page group control")


def test_tokens_and_escaping():
    runs = crd.parse_text("{[Customer City]}, {Customer@ID} {Cost} p{&PAGE}/{&NPAGES}")
    assert runs == [("field", "Customer City"), ("lit", ", "), ("field", "Customer@ID"), ("lit", " "),
                    ("field", "Cost"), ("lit", " p"), ("auto", "&page"), ("lit", "/"), ("auto", "&npages")], runs
    assert crd.parse_text("{Item@DESC}") == [("field", "Item")]
    assert crd.md_escape("a*b_{{x}}") == "a\\*b\\_{\\{x}}"
    doc = fixture()
    doc["sections"].append({"kind": "page-footer", "height_in": 0.3, "controls": [
        {"id": "pager", "type": "text", "text": "Page {&PAGE} of {&NPAGES}", "left_in": 6, "top_in": 0.05,
         "width_in": 1.4, "height_in": 0.2}]})
    rc, spec, _, _ = convert(doc)
    pager = next(e for e in spec["contents"]["elements"] if e["id"] == "rs-pager")
    assert rc == 0 and "Page {{CurrentPageNumber()}} of {{TotalPageCount()}}" in pager["body"]
    assert any(p["type"] == "footer" for p in spec["contents"]["panels"])
    print("[ok] tokens: fields/forms/auto-text parse; literals escaped; page footer panel")


def test_loud_gaps():
    doc = fixture()
    doc["sections"][1]["controls"].append({"id": "spark", "type": "graph", "left_in": 1, "top_in": 0.1,
                                           "width_in": 1, "height_in": 0.5})
    rc, _, gaps, _ = convert(doc)
    assert rc == 2 and any(g["construct"] == "control:graph" and g["severity"] == "blocking" for g in gaps["gaps"])
    rc, _, _, _ = convert(doc, "--allow-gaps")
    assert rc == 0
    doc = fixture()
    del doc["grouping"][0]["sample_value"]
    rc, _, gaps, _ = convert(doc)
    assert rc == 2 and any(g["construct"] == "no default group value" for g in gaps["gaps"])
    rc, _, _, _ = convert(doc, "--default-group-value", "Ballin Stephen")
    assert rc == 0
    doc = fixture()
    doc["sections"][3]["controls"][0]["text"] = "Day: {Day}"
    rc, _, gaps, _ = convert(doc)
    assert rc == 2 and any(g["construct"] == "composite detail text" for g in gaps["gaps"])
    doc = fixture()
    doc["format"] = "mstr-rs-document/0"
    assert convert(doc)[0] == 1
    print("[ok] loud gaps: unmapped control, missing group value, composite detail -> exit 2; bad format -> 1")


def test_banded_mode():
    doc = copy.deepcopy(fixture())
    doc["grouping"][0]["page_break_between_groups"] = False
    rc, spec, gaps, _ = convert(doc)
    assert rc == 0 and gaps["mode"] == "banded"
    table = next(e for e in spec["contents"]["elements"] if e["kind"] == "table")
    grp = table["groupings"][0]
    cols = {c["id"]: c for c in table["columns"]}
    assert grp["groupBy"][0] == "col-customer" and "col-customer-city" in grp["groupBy"]
    assert "col-ship-date" not in grp["groupBy"]
    calcs = [cols[i] for i in grp["calculations"]]
    assert [c["name"] for c in calcs] == ["Total Charge", "Total Due"], [c["name"] for c in calcs]
    assert all(c["formula"] == "Sum([Amount])" for c in calcs)
    # Sigma rejects a base-level sort on a grouping key ("Sort column not in level").
    assert all(s["columnId"] not in grp["groupBy"] for s in table.get("sort", [])), table.get("sort")
    assert not any(e["kind"] == "control" for e in spec["contents"]["elements"])
    assert any(g["construct"].startswith("group furniture") for g in gaps["gaps"])
    assert any(g["construct"] == "group-level attribute Ship Date" for g in gaps["gaps"])
    print("[ok] banded mode: groupBy keys + Sum calculations named by their footer labels")


def test_detail_without_header():
    doc = fixture()
    doc["sections"] = [s for s in doc["sections"] if s["kind"] != "detail-header"]
    _, spec, _, _ = convert(doc)
    roots = layout_roots(spec["contents"])
    placed = [e.get("elementId") for root in roots for e in root]
    assert placed.count("rs-detail") == 1
    print("[ok] headerless detail: paginated table is placed exactly once")


if __name__ == "__main__":
    update = "--update-golden" in sys.argv
    test_golden(update)
    test_structure()
    test_geometry()
    test_semantics()
    test_tokens_and_escaping()
    test_loud_gaps()
    test_banded_mode()
    test_detail_without_header()
    print("ALL PASS")
