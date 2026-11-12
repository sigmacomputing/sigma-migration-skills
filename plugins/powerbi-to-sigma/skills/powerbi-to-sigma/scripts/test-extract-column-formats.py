#!/usr/bin/env python3
"""test-extract-column-formats.py — extract-pbir.py: matrix/table static column fills
(objects.columnFormatting -> rec["column_formats"]) and the report theme's own dataColors
(-> signals["theme_data_colors"]). Synthetic Sales names only.

Usage: python3 scripts/test-extract-column-formats.py
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


def solid_hex(h):
    return {"solid": {"color": {"expr": {"Literal": {"Value": f"'{h}'"}}}}}


def solid_theme(cid, pct):
    return {"solid": {"color": {"expr": {"ThemeDataColor": {"ColorId": cid, "Percent": pct}}}}}


def fmt(target, **props):
    return {"selector": {"metadata": target}, "properties": props}


def vis(name, vtype, projs, objects=None):
    v = {"name": name, "position": {"x": 0, "y": 0, "width": 100, "height": 50, "z": 0},
         "visual": {"visualType": vtype, "query": {"queryState": projs}}}
    if objects:
        v["visual"]["objects"] = objects
    return v


MATRIX = {"Rows": {"projections": [{"field": col("Sales", "Region"), "queryRef": "Sales.Region"}]},
          "Values": {"projections": [
              {"field": meas("Sales", "Net"), "queryRef": "Sales.Net"},
              {"field": meas("Sales", "Margin"), "queryRef": "Sales.Margin", "nativeQueryRef": "Margin"},
              {"field": meas("Sales", "Units"), "queryRef": "Sales.Units"}]}}


def build(root, with_theme_colors):
    d = os.path.join(root, "definition")
    rep = {"themeCollection": {"baseTheme": {"name": "CY18SU07"}}}
    if with_theme_colors == "base":
        write(os.path.join(root, "StaticResources", "SharedResources", "BaseThemes", "CY18SU07.json"),
              {"name": "CY18SU07", "dataColors": ["#111111", "#222222"]})
    if with_theme_colors == "custom":
        write(os.path.join(root, "StaticResources", "SharedResources", "BaseThemes", "CY18SU07.json"),
              {"name": "CY18SU07", "dataColors": ["#111111", "#222222"]})
        rep["themeCollection"]["customTheme"] = {"name": "Brand123.json", "type": "RegisteredResources"}
        rep["resourcePackages"] = [{"name": "RegisteredResources", "type": "RegisteredResources",
                                    "items": [{"name": "Brand123.json", "path": "Brand123.json", "type": "CustomTheme"}]}]
        write(os.path.join(root, "StaticResources", "RegisteredResources", "Brand123.json"),
              {"name": "Brand", "dataColors": ["#AA0000", "#00BB00", "#0000CC"]})
    write(os.path.join(d, "report.json"), rep)
    write(os.path.join(d, "pages", "pages.json"), {"pageOrder": ["p1"]})
    write(os.path.join(d, "pages", "p1", "page.json"),
          {"name": "p1", "displayName": "Overview", "width": 1280, "height": 720})
    pv = os.path.join(d, "pages", "p1", "visuals")
    cfmt = [
        fmt("Sales.Net", backColor=solid_hex("#99e3dd")),                      # values absent -> True
        fmt("Sales.Margin", backColor=solid_theme(5, 0.6), fontColor=solid_theme(1, 0),
            styleValues=lit("true"), styleHeader=lit("true")),
        fmt("Sales.Units", backColor=solid_hex("#112233"), styleValues=lit("false"),
            styleHeader=lit("true"), styleTotal=lit("true"), styleSubtotals=lit("false")),
        fmt("Sales.Net", dataBars={"positiveColor": solid_hex("#00FF00")}),   # no back/font -> skipped
    ]
    write(os.path.join(pv, "mx", "visual.json"), vis("mx", "pivotTable", MATRIX, {"columnFormatting": cfmt}))
    write(os.path.join(pv, "plain", "visual.json"), vis("plain", "tableEx", {"Values": MATRIX["Values"]}))
    write(os.path.join(pv, "card", "visual.json"),
          vis("card", "card", {"Values": {"projections": [{"field": meas("Sales", "Net"), "queryRef": "Sales.Net"}]}},
              {"columnFormatting": cfmt}))


with tempfile.TemporaryDirectory() as tmp:
    r1 = os.path.join(tmp, "a.Report")
    build(r1, None)
    out = pbir.extract(r1)
    by = {v["visual_id"]: v for v in out["pages"][0]["visuals"]}
    cf = by["mx"].get("column_formats") or []
    check(len(cf) == 3, f"3 matrix fills captured (dataBars-only entry skipped): {len(cf)}")
    net, mar, uni = (cf + [{}] * 3)[:3]
    check(net.get("target") == "Sales.Net" and net.get("back") == "#99e3dd" and net.get("font") is None,
          "literal hex back color")
    check(net.get("values") is True and net.get("header") is False and net.get("total") is False
          and net.get("subtotals") is True, "absent flags: values=True header=False total=False subtotals=True")
    check(mar.get("back") == {"theme": 5, "percent": 0.6} and mar.get("font") == {"theme": 1, "percent": 0.0},
          "ThemeDataColor back/font captured as {theme, percent}")
    check(mar.get("values") is True and mar.get("header") is True, "explicit styleValues/styleHeader true")
    check(uni.get("values") is False and uni.get("header") is True and uni.get("total") is True
          and uni.get("subtotals") is False, "explicit styleValues=false and header/total/subtotals flags")
    check("column_formats" not in by["plain"], "no columnFormatting -> key absent")
    check("column_formats" not in by["card"], "non-table visual -> key absent")
    check("theme_data_colors" not in out, "no theme dataColors on disk -> signals key absent")

    # card callout colour: ThemeDataColor swatch -> {theme, percent}; hex stays a hex string
    CARD_Q = {"Values": {"projections": [{"field": meas("Sales", "Net"), "queryRef": "Sales.Net"}]}}
    rc = os.path.join(tmp, "card.Report")
    build(rc, None)
    pvc = os.path.join(rc, "definition", "pages", "p1", "visuals")
    write(os.path.join(pvc, "card_theme", "visual.json"),
          vis("card_theme", "card", CARD_Q, {"labels": [{"properties": {"color": solid_theme(2, 0.4)}}]}))
    write(os.path.join(pvc, "card_hex", "visual.json"),
          vis("card_hex", "card", CARD_Q, {"labels": [{"properties": {"color": solid_hex("#123456")}}]}))
    byc = {v["visual_id"]: v for v in pbir.extract(rc)["pages"][0]["visuals"]}
    check(byc["card_theme"].get("value_color") == {"theme": 2, "percent": 0.4},
          f"card ThemeDataColor callout -> {{theme, percent}}: {byc['card_theme'].get('value_color')}")
    check(byc["card_hex"].get("value_color") == "#123456", "card hex callout unchanged")
    check(byc["card"].get("value_color") is None, "card with no callout colour -> None")

    r2 = os.path.join(tmp, "b.Report")
    build(r2, "base")
    check(pbir.extract(r2).get("theme_data_colors") == ["#111111", "#222222"], "base theme dataColors captured")

    r3 = os.path.join(tmp, "c.Report")
    build(r3, "custom")
    check(pbir.extract(r3).get("theme_data_colors") == ["#AA0000", "#00BB00", "#0000CC"],
          "custom theme dataColors override the base theme")

    # alias re-keying: selector.metadata carries the stale alias, binding is field-derived
    r4 = os.path.join(tmp, "d.Report")
    build(r4, None)
    vf = os.path.join(r4, "definition", "pages", "p1", "visuals", "mx", "visual.json")
    v = json.load(open(vf))
    projs = v["visual"]["query"]["queryState"]["Values"]["projections"]
    projs[0]["queryRef"] = "Sales.Net Old"      # cached queryRef differs from the field-derived ref
    v["visual"]["objects"]["columnFormatting"][0]["selector"]["metadata"] = "Sales.Net Old"
    write(vf, v)
    cf4 = {x["visual_id"]: x for x in pbir.extract(r4)["pages"][0]["visuals"]}["mx"]["column_formats"]
    check(cf4[0]["target"] == "Sales.Net", f"target re-keyed through binding_aliases: {cf4[0]['target']}")

if fails:
    print(f"\n{len(fails)} FAILED")
    sys.exit(1)
print("\nall passed")
