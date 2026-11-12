#!/usr/bin/env python3
"""test-extract-visual-fidelity.py — extract-pbir.py visual-fidelity signals (synthetic Sales names).

  1  display names      projection displayName / columnProperties -> rec["display_names"]
  2  slicer header      objects.header text (when shown) -> rec["header_title"]
  11 literal escaping   'O''Brien' -> O'Brien in saved_selection and selection
  12 group offsets      child x/y are group-relative; absolute = sum of ancestor offsets (nested groups),
                        raw kept as x_rel / y_rel; a hidden ancestor hides the member

Usage: python3 scripts/test-extract-visual-fidelity.py
"""
import importlib.util, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        fails.append(msg)


spec = importlib.util.spec_from_file_location("pbir_x", os.path.join(HERE, "extract-pbir.py"))
pbir = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pbir)


def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f)


def col(ent, prop):
    return {"Column": {"Expression": {"SourceRef": {"Entity": ent}}, "Property": prop}}


def meas(ent, prop):
    return {"Measure": {"Expression": {"SourceRef": {"Entity": ent}}, "Property": prop}}


def lit(v):
    return {"expr": {"Literal": {"Value": v}}}


def vis(name, vtype, projs, x=0, y=0, w=100, h=50, z=0, group=None, hidden=None, objects=None):
    v = {"name": name, "position": {"x": x, "y": y, "width": w, "height": h, "z": z},
         "visual": {"visualType": vtype, "query": {"queryState": projs}}}
    if objects:
        v["visual"]["objects"] = objects
    if group:
        v["parentGroupName"] = group
    if hidden is not None:
        v["isHidden"] = hidden
    return v


def grp(name, x, y, parent=None, hidden=None):
    g = {"name": name, "position": {"x": x, "y": y, "width": 400, "height": 100, "z": 0},
         "visualGroup": {"displayName": name}}
    if parent:
        g["parentGroupName"] = parent
    if hidden is not None:
        g["isHidden"] = hidden
    return g


CARD = {"Values": {"projections": [{"field": meas("Sales", "Total"), "queryRef": "Sales.Total"}]}}


def build(root):
    d = os.path.join(root, "definition")
    write(os.path.join(d, "pages", "pages.json"), {"pageOrder": ["p1"]})
    write(os.path.join(d, "pages", "p1", "page.json"),
          {"name": "p1", "displayName": "Overview", "width": 1280, "height": 720})
    pv = os.path.join(d, "pages", "p1", "visuals")

    def put(n, o):
        write(os.path.join(pv, n, "visual.json"), o)

    put("tbl", vis("tbl", "tableEx", {"Values": {"projections": [
        {"field": col("Sales", "Region"), "queryRef": "Sales.Region", "displayName": "Sales Region"},
        {"field": meas("Sales", "Total"), "queryRef": "Sales.Total", "nativeQueryRef": "Total"},
        {"field": col("Sales", "Units"), "queryRef": "Sales.Units"}]}},
        objects={"columnProperties": [{"selector": {"metadata": "Sales.Total"},
                                       "properties": {"displayName": lit("'Revenue'")}}]}))
    sl = {"Values": {"projections": [{"field": col("Sales", "Region"), "queryRef": "Sales.Region"}]}}
    put("s_hdr", vis("s_hdr", "slicer", sl, objects={"header": [{"properties": {
        "show": lit("true"), "text": lit("'Pick a Region'")}}]}))
    put("s_off", vis("s_off", "slicer", sl, x=200, objects={"header": [{"properties": {
        "show": lit("false"), "text": lit("'Hidden Title'")}}]}))
    put("s_none", vis("s_none", "slicer", sl, x=400))
    flt = {"Version": 2, "From": [{"Name": "s", "Entity": "Sales", "Type": 0}],
           "Where": [{"Condition": {"In": {"Expressions": [
               {"Column": {"Expression": {"SourceRef": {"Source": "s"}}, "Property": "Rep"}}],
               "Values": [[{"Literal": {"Value": "'O''Brien'"}}], [{"Literal": {"Value": "'Smith'"}}]]}}}]}
    put("s_rep", vis("s_rep", "slicer",
                     {"Values": {"projections": [{"field": col("Sales", "Rep"), "queryRef": "Sales.Rep"}]}},
                     x=600, objects={"general": [{"properties": {"filter": {"filter": flt}}}]}))
    put("g1", grp("g1", 439, 129))
    for i, name in enumerate(["c0", "c1", "c2"]):
        put(name, vis(name, "card", CARD, x=125 * i, y=0, group="g1"))
    put("g2", grp("g2", 10, 20, parent="g1"))
    put("cn", vis("cn", "card", CARD, x=5, y=7, group="g2"))
    put("gh", grp("gh", 100, 100, hidden=True))
    put("gh2", grp("gh2", 50, 50, parent="gh"))
    put("ch", vis("ch", "card", CARD, x=1, y=2, group="gh2"))


with tempfile.TemporaryDirectory() as root:
    build(root)
    out = pbir.extract(root)
    by = {v["visual_id"]: v for v in out["pages"][0]["visuals"]}

    dn = by["tbl"].get("display_names") or {}
    check(dn.get("Sales.Region") == "Sales Region", "1 projection displayName captured")
    check(dn.get("Sales.Total") == "Revenue", "1 columnProperties displayName captured")
    check("Sales.Units" not in dn, "1 un-renamed field carries no display name")

    check(by["s_hdr"].get("header_title") == "Pick a Region", "2 shown slicer header title captured")
    check("header_title" not in by["s_off"], "2 header with show:false is not captured")
    check("header_title" not in by["s_none"], "2 no header -> no header_title")

    ss = (by["s_rep"]["slicer_state"] or {}).get("saved_selection") or {}
    check(ss.get("values") == ["O'Brien", "Smith"], f"11 saved_selection unescaped: {ss.get('values')}")
    sel = (by["s_rep"]["slicer_state"] or {}).get("selection") or {}
    check(sel.get("values") == ["O'Brien", "Smith"], f"11 selection unescaped: {sel.get('values')}")

    check([(by[n]["x"], by[n]["y"]) for n in ("c0", "c1", "c2")] == [(439, 129), (564, 129), (689, 129)],
          "12 grouped cards resolve to absolute coordinates")
    check((by["c1"].get("x_rel"), by["c1"].get("y_rel")) == (125, 0), "12 raw relative coordinates kept as x_rel/y_rel")
    check((by["cn"]["x"], by["cn"]["y"]) == (439 + 10 + 5, 129 + 20 + 7), "12 nested group offsets are summed")
    check((by["g2"]["x"], by["g2"]["y"]) == (449, 149), "12 a nested group's own box is absolute too")
    check("x_rel" not in by["tbl"], "12 ungrouped visuals carry no x_rel")
    check(by["ch"].get("hidden") is True, "12 a member of a nested group under a hidden ancestor is hidden")
    check((by["ch"]["x"], by["ch"]["y"]) == (151, 152), "12 hidden ancestor offsets still resolve")
    check(not by["c0"].get("hidden"), "12 a visible group's member is not hidden")

if fails:
    print(f"\n{len(fails)} FAILED")
    sys.exit(1)
print("\nall passed")
