#!/usr/bin/env python3
"""test-extract-hidden-bookmarks.py — G30: the extractors must carry visual
visibility and report bookmarks into signals.json so the builder can tell a
PERMANENTLY hidden visual (authoring scaffolding, never shown) from one a
bookmark toggles (a real, reachable view).

  PBIR    visual.json top-level `isHidden`            -> visual["hidden"] = true
  PBIR    a hidden visual GROUP                        -> its members are hidden too
  PBIR    definition/bookmarks/*.bookmark.json         -> signals["bookmarks"]
  classic config.singleVisual.display.mode == hidden   -> visual["hidden"] = true
  classic visualContainer.hidden                       -> visual["hidden"] = true

The `hidden` key is emitted ONLY when true, so every signal for a report with no
hidden visuals is byte-identical to before this change.

100% synthetic (Sales / Orders names). Usage:  python3 scripts/test-extract-hidden-bookmarks.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

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


pbir = load("pbir_x", os.path.join(HERE, "extract-pbir.py"))
erc = load("erc_x", os.path.join(HERE, "extract-report-classic.py"))


def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f)


def visual(name, vtype="card", hidden=None, group=None, x=0):
    v = {"name": name, "position": {"x": x, "y": 0, "width": 100, "height": 50, "z": 0},
         "visual": {"visualType": vtype,
                    "query": {"queryState": {"Values": {"projections": [
                        {"field": {"Measure": {"Expression": {"SourceRef": {"Entity": "Sales"}},
                                               "Property": "Total Sales"}},
                         "queryRef": "Sales.Total Sales"}]}}}}}
    if hidden is not None:
        v["isHidden"] = hidden
    if group:
        v["parentGroupName"] = group
    return v


def make_report(root):
    d = os.path.join(root, "definition")
    write(os.path.join(d, "pages", "pages.json"), {"pageOrder": ["p1", "p2"], "activePageName": "p1"})
    write(os.path.join(d, "pages", "p1", "page.json"), {"name": "p1", "displayName": "Overview"})
    write(os.path.join(d, "pages", "p2", "page.json"), {"name": "p2", "displayName": "Detail"})
    pv = os.path.join(d, "pages", "p1", "visuals")
    write(os.path.join(pv, "vShown", "visual.json"), visual("vShown", x=0))
    write(os.path.join(pv, "vFalse", "visual.json"), visual("vFalse", hidden=False, x=10))
    write(os.path.join(pv, "vScaffold", "visual.json"), visual("vScaffold", hidden=True, x=20))
    write(os.path.join(pv, "vToggled", "visual.json"), visual("vToggled", hidden=True, x=30))
    write(os.path.join(pv, "vBmHides", "visual.json"), visual("vBmHides", x=40))
    # a hidden visual group + two members, and a visible group + a member
    write(os.path.join(pv, "gHidden", "visual.json"),
          {"name": "gHidden", "position": {"x": 0, "y": 60, "width": 200, "height": 100, "z": 1},
           "visualGroup": {"displayName": "Hidden group"}, "isHidden": True})
    write(os.path.join(pv, "vInHidden", "visual.json"), visual("vInHidden", group="gHidden", x=50))
    write(os.path.join(pv, "vInHidden2", "visual.json"), visual("vInHidden2", group="gHidden", x=60))
    write(os.path.join(pv, "gOpen", "visual.json"),
          {"name": "gOpen", "position": {"x": 0, "y": 70, "width": 200, "height": 100, "z": 2},
           "visualGroup": {"displayName": "Open group"}})
    write(os.path.join(pv, "vInOpen", "visual.json"), visual("vInOpen", group="gOpen", x=70))
    # nested: member of a group that is itself inside a hidden group
    write(os.path.join(pv, "gInner", "visual.json"),
          {"name": "gInner", "position": {"x": 0, "y": 80, "width": 100, "height": 50, "z": 3},
           "visualGroup": {"displayName": "Inner"}, "parentGroupName": "gHidden"})
    write(os.path.join(pv, "vNested", "visual.json"), visual("vNested", group="gInner", x=80))
    write(os.path.join(d, "pages", "p2", "visuals", "vP2", "visual.json"), visual("vP2"))

    bm = os.path.join(d, "bookmarks")
    write(os.path.join(bm, "bookmarks.json"),
          {"items": [{"name": "bmDetail"}, {"name": "bmGroupFolder", "children": [{"name": "bmGroup"}]},
                     {"name": "bmMissing"}]})
    write(os.path.join(bm, "bmZ.bookmark.json"),  # not in the index: appended after, name-sorted
          {"name": "bmZ", "displayName": "Z extra",
           "explorationState": {"activeSection": "p2", "sections": {"p2": {"visualContainers": {}}}}})
    write(os.path.join(bm, "bmDetail.bookmark.json"),
          {"name": "bmDetail", "displayName": "Show toggled",
           "explorationState": {"version": "1.0", "activeSection": "p1", "sections": {"p1": {
               "visualContainers": {
                   "vToggled": {"singleVisual": {"visualType": "card"}},          # listed, no mode -> shown
                   "vBmHides": {"singleVisual": {"display": {"mode": "hidden"}}},
                   "vFocus": {"singleVisual": {"display": {"mode": "spotlight"}}}}}}}})
    write(os.path.join(bm, "bmGroup.bookmark.json"),
          {"name": "bmGroup", "displayName": "Open the group",
           "explorationState": {"activeSection": "p1", "sections": {"p1": {
               "visualContainers": {},
               "visualContainerGroups": {"gHidden": {"isHidden": False, "children": {
                   "vInHidden": {"singleVisual": {"visualType": "card"}}}}}}}}})
    write(os.path.join(bm, "bmTargets.bookmark.json"),
          {"name": "bmTargets", "displayName": "Targets only",
           "options": {"applyOnlyToTargetVisuals": True, "targetVisualNames": ["vBmHides"]},
           "explorationState": {"activeSection": "p1", "sections": {"p1": {"visualContainers": {
               "vBmHides": {"singleVisual": {"display": {"mode": "hidden"}}},
               "vToggled": {"singleVisual": {"visualType": "card"}}}}}}})
    write(os.path.join(bm, "bmNoDisplay.bookmark.json"),
          {"name": "bmNoDisplay", "displayName": "Data only",
           "options": {"suppressDisplay": True},
           "explorationState": {"activeSection": "p1", "sections": {"p1": {"visualContainers": {
               "vBmHides": {"singleVisual": {"display": {"mode": "hidden"}}}}}}}})
    # a shown group whose member the SAME bookmark hides explicitly (fidelity-2)
    write(os.path.join(bm, "bmMixed.bookmark.json"),
          {"name": "bmMixed", "displayName": "Group minus one",
           "explorationState": {"activeSection": "p1", "sections": {"p1": {
               "visualContainers": {"vInOpen": {"singleVisual": {"display": {"mode": "hidden"}}}},
               "visualContainerGroups": {"gOpen": {"isHidden": False}}}}}})
    with open(os.path.join(bm, "broken.bookmark.json"), "w") as f:
        f.write("{not json")
    return root


tmp = tempfile.mkdtemp()
root = make_report(os.path.join(tmp, "Sales.Report"))
sig = pbir.extract(root)
vis = {v["visual_id"]: v for pg in sig["pages"] for v in pg["visuals"]}

print("\n1. PBIR visual.json isHidden -> hidden: true")
check(vis["vScaffold"].get("hidden") is True, "isHidden:true -> hidden: true")
check(vis["vToggled"].get("hidden") is True, "a bookmark-toggled hidden visual is still flagged hidden")
check("hidden" not in vis["vShown"], "no isHidden -> no `hidden` key (output unchanged)")
check("hidden" not in vis["vFalse"], "isHidden:false -> no `hidden` key")
check(vis["gHidden"].get("hidden") is True, "a hidden visual group is itself flagged")
check(vis["vInHidden"].get("hidden") is True and vis["vInHidden2"].get("hidden") is True,
      "members of a hidden group are hidden")
check(vis["vNested"].get("hidden") is True, "a member of a group nested inside a hidden group is hidden")
check("hidden" not in vis["vInOpen"] and "hidden" not in vis["gOpen"],
      "an open group and its member stay un-flagged")
check("hidden" not in vis["vP2"], "other pages unaffected")

print("\n2. PBIR bookmarks -> signals['bookmarks']")
bms = sig.get("bookmarks")
check(isinstance(bms, list), "signals carries a bookmarks list")
names = [b["name"] for b in bms]
check(names == ["bmDetail", "bmGroup", "bmMixed", "bmNoDisplay", "bmTargets", "bmZ"],
      f"order = bookmarks.json order (folders flattened, missing files skipped), then the rest sorted: {names}")
by = {b["name"]: b for b in bms}
d = by["bmDetail"]
check(d["display_name"] == "Show toggled" and d["page_id"] == "p1", "display name and target page carried")
check(d["shows"] == ["vToggled"], f"a listed container with no hidden mode is SHOWN: {d['shows']}")
check(d["hides"] == ["vBmHides"], f"display.mode hidden -> hides: {d['hides']}")
check(d["spotlight"] == ["vFocus"], f"spotlight/maximize recorded separately: {d['spotlight']}")
g = by["bmGroup"]
check("gHidden" in g["shows"] and "vInHidden" in g["shows"] and "vInHidden2" in g["shows"],
      f"showing a group shows the group and every member: {g['shows']}")
check("vNested" in g["shows"], "group show expands through nested groups")
check(g["hides"] == [], "nothing hidden by the group-open bookmark")
mx = by["bmMixed"]
check(mx["hides"] == ["vInOpen"] and "vInOpen" not in mx["shows"] and "gOpen" in mx["shows"],
      f"a bookmark never shows a visual it also hides (group member): hides={mx['hides']} shows={mx['shows']}")
t = by["bmTargets"]
check(t["applies_to"] == ["vBmHides"] and t["hides"] == ["vBmHides"] and t["shows"] == [],
      f"applyOnlyToTargetVisuals restricts the effect to the targets: {t}")
n = by["bmNoDisplay"]
check(n["suppress_display"] is True and n["hides"] == [] and n["shows"] == [],
      "suppressDisplay -> the bookmark changes no visibility")
check(by["bmZ"]["page_id"] == "p2" and by["bmZ"]["applies_to"] is None, "page / applies_to defaults")
check(all(k in b for b in bms for k in
          ("name", "display_name", "page_id", "shows", "hides", "spotlight", "applies_to", "suppress_display")),
      "every bookmark record has the full key set")

# the permanent-vs-toggled rule the builder applies
shown_somewhere = {v for b in bms for v in b["shows"]}
permanent = sorted(v for v, r in vis.items() if r.get("hidden") and v not in shown_somewhere)
check(permanent == ["vScaffold"], f"permanently hidden = hidden and never shown by a bookmark: {permanent}")

print("\n3. no bookmarks folder -> empty list; no regression")
root2 = os.path.join(tmp, "Plain.Report")
d2 = os.path.join(root2, "definition")
write(os.path.join(d2, "pages", "pages.json"), {"pageOrder": ["p1"]})
write(os.path.join(d2, "pages", "p1", "page.json"), {"name": "p1"})
write(os.path.join(d2, "pages", "p1", "visuals", "v1", "visual.json"), visual("v1"))
sig2 = pbir.extract(root2)
check(sig2["bookmarks"] == [], "no bookmarks -> bookmarks: []")
check("hidden" not in sig2["pages"][0]["visuals"][0], "plain report: no hidden key")

print("\n4. classic Layout")


def cvc(name, vtype="card", mode=None, vc_hidden=None, x=0):
    sv = {"visualType": vtype, "projections": {"Values": [{"queryRef": "Orders.Total"}]}}
    if mode:
        sv["display"] = {"mode": mode}
    c = {"x": x, "y": 0, "width": 100, "height": 50, "z": 0,
         "config": json.dumps({"name": name, "singleVisual": sv})}
    if vc_hidden is not None:
        c["hidden"] = vc_hidden
    return c


img_cfg = {"name": "logo", "singleVisual": {"visualType": "image", "display": {"mode": "hidden"}}}
layout = {"sections": [{"name": "s1", "displayName": "S1", "visualContainers": [
    cvc("a", x=0), cvc("b", mode="hidden", x=10), cvc("c", vc_hidden=True, x=20),
    cvc("d", mode="visible", x=30), cvc("e", vc_hidden=False, x=40),
    {"x": 50, "y": 0, "width": 10, "height": 10, "z": 0, "config": json.dumps(img_cfg)}]}]}
csig = erc.extract(layout)
cv = csig["pages"][0]["visuals"]
check(len(cv) == 6, "six classic visuals extracted")
flags = [bool(v.get("hidden")) for v in sorted(cv, key=lambda r: r["x"])]
check(flags == [False, True, True, False, False, True],
      f"display.mode hidden / container hidden / hidden image -> hidden; others not: {flags}")
check(all("hidden" not in v for v in cv if not v.get("hidden")), "un-hidden visuals carry no `hidden` key")

print("\n5. CLI end to end")
out = os.path.join(tmp, "signals.json")
r = subprocess.run([sys.executable, os.path.join(HERE, "extract-pbir.py"), "--pbir-dir", root, "--out", out],
                   capture_output=True, text=True)
check(r.returncode == 0, f"extract-pbir.py exits 0 ({r.stderr[-200:]})")
disk = json.load(open(out))
check([b["name"] for b in disk["bookmarks"]] == names, "bookmarks survive the JSON round trip")

print()
if fails:
    print(f"{len(fails)} FAILED")
    sys.exit(1)
print("all passed")
