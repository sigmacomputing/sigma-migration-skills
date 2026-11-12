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
classic_hierarchy = {
    "projections": {
        "Category": [{"queryRef": "D.Year"}, {"queryRef": "D.Month"}]
    },
    "activeProjections": {"Category": [{"queryRef": "D.Month"}]},
}
check(erc._drill_signal(classic_hierarchy) == {
          "role": "Category", "levels": ["D.Year", "D.Month"], "active": "D.Month"
      }, "classic extractor preserves full hierarchy for native drill")

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
pbir_hierarchy = {
    "Category": {
        "projections": [
            {"queryRef": "D.Year"},
            {"queryRef": "D.Month", "active": True},
        ]
    }
}
check(epb._role_bindings(pbir_hierarchy) == {"Category": ["D.Month"]},
      "PBIR chart binding keeps the active hierarchy level")
check(epb._drill_signal(pbir_hierarchy) == {
          "role": "Category", "levels": ["D.Year", "D.Month"], "active": "D.Month"
      }, "PBIR extractor separately preserves full hierarchy for native drill")
# A user-defined hierarchy projection's queryRef is Table.Hierarchy.Level,
# which names no column; the level's column is Table.Level. Date-hierarchy
# variations (PropertyVariationSource) keep their queryRef.
def _level(entity, hierarchy, level, active=None):
    proj = {"field": {"HierarchyLevel": {"Expression": {"Hierarchy": {
                "Expression": {"SourceRef": {"Entity": entity}}, "Hierarchy": hierarchy}},
            "Level": level}},
            "queryRef": f"{entity}.{hierarchy}.{level}"}
    if active is not None:
        proj["active"] = active
    return proj


user_hierarchy = {"Rows": {"projections": [
    _level("Cat", "Group Hierarchy", "Level 1 - Group"),
    _level("Cat", "Group Hierarchy", "Level 2 - Subgroup", active=True),
]}}
check(epb._role_bindings(user_hierarchy) == {"Rows": ["Cat.Level 2 - Subgroup"]},
      "PBIR user-hierarchy level binds the level's column, not Table.Hierarchy.Level")
check(epb._drill_signal(user_hierarchy) == {
          "role": "Rows", "levels": ["Cat.Level 1 - Group", "Cat.Level 2 - Subgroup"], "active": "Cat.Level 2 - Subgroup"
      }, "PBIR user-hierarchy drill levels name the level columns")
check(epb._expr_queryref(user_hierarchy["Rows"]["projections"][0]["field"]) == "Cat.Level 1 - Group",
      "a HierarchyLevel field expression resolves to its level column")
date_variation = {"Category": {"projections": [{
    "field": {"HierarchyLevel": {"Expression": {"Hierarchy": {"Expression": {"PropertyVariationSource": {
        "Expression": {"SourceRef": {"Entity": "D"}}, "Name": "Variation", "Property": "Date"}},
        "Hierarchy": "Date Hierarchy"}}, "Level": "Year"}},
    "queryRef": "D.Date.Variation.Date Hierarchy.Year"}]}}
check(epb._role_bindings(date_variation) == {"Category": ["D.Date.Variation.Date Hierarchy.Year"]},
      "a date-hierarchy variation keeps its queryRef")
level_field = user_hierarchy["Rows"]["projections"][0]["field"]
sorted_matrix = {"visualType": "pivotTable", "query": {
    "queryState": user_hierarchy,
    "sortDefinition": {"sort": [{"field": level_field, "direction": "Descending"}]}}}
check(epb._sort_signal(sorted_matrix) == {"queryRef": "Cat.Level 1 - Group", "direction": "desc"},
      "a sort on a hierarchy level names the level column the binding uses")
check(epb._sort_signal({"visualType": "pivotTable", "query": {"queryState": user_hierarchy}}) ==
      {"queryRef": "Cat.Level 1 - Group", "direction": "asc", "default": True},
      "the default first-column sort of a hierarchy matrix names the level column")
# Public PBIR shape from microsoft/skills-for-fabric:
# skills/powerbi-report-authoring/references/slicers.md
check(epb._sync_group({"syncGroup": {
          "groupName": "DateSync", "fieldChanges": True, "filterChanges": True
      }}) == "DateSync", "PBIR extractor preserves the public synced-slicer groupName")
check(epb._sync_group({}) is None, "ordinary slicer has no synthetic sync group")

print("\n2b. matrices keep every Rows/Columns level; charts keep the active level only")
matrix_qs = {
    "Rows": {"projections": [{"queryRef": "Orders.Region", "active": True},
                              {"queryRef": "Orders.Category"},
                              {"queryRef": "Orders.Product"}]},
    "Columns": {"projections": [{"queryRef": "Orders.Segment", "active": True},
                                 {"queryRef": "Orders.Channel"}]},
    "Values": {"projections": [{"queryRef": "Sum(Orders.Amount)"}]},
}
for vt in ("pivotTable", "matrix"):
    mb = epb._role_bindings(matrix_qs, vt)
    check(mb["Rows"] == ["Orders.Region", "Orders.Category", "Orders.Product"],
          f"PBIR {vt}: all Rows levels kept in order despite one active flag")
    check(mb["Columns"] == ["Orders.Segment", "Orders.Channel"], f"PBIR {vt}: all Columns levels kept")
    check(mb["Values"] == ["Sum(Orders.Amount)"], f"PBIR {vt}: Values untouched")
check(epb._role_bindings(matrix_qs, "clusteredColumnChart")["Rows"] == ["Orders.Region"],
      "PBIR chart still keeps the active level only")
check(epb._role_bindings(matrix_qs)["Rows"] == ["Orders.Region"],
      "PBIR untyped visual still keeps the active level only")
no_flags = {"Rows": {"projections": [{"queryRef": "Orders.Region"}, {"queryRef": "Orders.Category"}]}}
check(epb._role_bindings(no_flags, "pivotTable") == {"Rows": ["Orders.Region", "Orders.Category"]},
      "PBIR matrix with no active flags is unchanged")

classic_matrix = {
    "projections": {"Rows": [{"queryRef": "Orders.Region"}, {"queryRef": "Orders.Category"},
                             {"queryRef": "Orders.Product"}],
                    "Columns": [{"queryRef": "Orders.Segment"}, {"queryRef": "Orders.Channel"}],
                    "Values": [{"queryRef": "Sum(Orders.Amount)"}]},
    "activeProjections": {"Rows": [{"queryRef": "Orders.Region"}],
                          "Columns": [{"queryRef": "Orders.Segment"}]},
}
check(erc._projections(classic_matrix, "pivotTable")["Rows"] ==
      ["Orders.Region", "Orders.Category", "Orders.Product"],
      "classic pivotTable keeps all Rows levels despite activeProjections")
check(erc._projections(classic_matrix, "matrix")["Rows"] ==
      ["Orders.Region", "Orders.Category", "Orders.Product"],
      "classic matrix keeps all Rows levels despite activeProjections")
check(erc._projections(classic_matrix, "pivotTable")["Columns"] == ["Orders.Segment", "Orders.Channel"],
      "classic pivotTable keeps all Columns levels despite activeProjections")
check(erc._projections(classic_matrix, "lineChart")["Rows"] == ["Orders.Region"],
      "classic chart still keeps the active level only")
check(erc._projections(classic_matrix)["Rows"] == ["Orders.Region"],
      "classic untyped visual still keeps the active level only")
classic_plain = {"projections": classic_matrix["projections"]}
check(erc._projections(classic_plain, "pivotTable")["Rows"] ==
      ["Orders.Region", "Orders.Category", "Orders.Product"],
      "classic matrix with no activeProjections is unchanged")

print("\n2c. a matrix DATE hierarchy keeps the active level only; user hierarchies keep all")
D = "Orders.OrderDate.Variation.Date Hierarchy."
date_qs = {
    "Rows": {"projections": [{"queryRef": "Orders.Region"}]},
    "Columns": {"projections": [{"queryRef": D + "Year", "active": True}, {"queryRef": D + "Quarter"},
                                 {"queryRef": D + "Month"}, {"queryRef": D + "Day"}]},
    "Values": {"projections": [{"queryRef": "Sum(Orders.Amount)"}]},
}
for vt in ("pivotTable", "matrix"):
    check(epb._role_bindings(date_qs, vt)["Columns"] == [D + "Year"],
          f"PBIR {vt}: date hierarchy on Columns keeps only the active level")
named = {"Columns": {"projections": [{"queryRef": "Orders.Year", "active": True},
                                      {"queryRef": "Orders.Month"}]}}
check(epb._role_bindings(named, "pivotTable")["Columns"] == ["Orders.Year"],
      "PBIR matrix with Year/Month-named levels is a date hierarchy: active only")
mixed = {"Rows": {"projections": [{"queryRef": "Orders.Year", "active": True}, {"queryRef": "Orders.Region"}]}}
check(epb._role_bindings(mixed, "pivotTable")["Rows"] == ["Orders.Year", "Orders.Region"],
      "PBIR Year + plain field is not a date hierarchy: all kept")
user_h = {"Rows": {"projections": [{"queryRef": "Geo Hierarchy.Country", "active": True},
                                    {"queryRef": "Geo Hierarchy.City"}]}}
check(epb._role_bindings(user_h, "pivotTable")["Rows"] == ["Geo Hierarchy.Country", "Geo Hierarchy.City"],
      "PBIR non-date user hierarchy keeps all levels")
ml = epb._matrix_levels(date_qs, "pivotTable")
check(ml["Columns"]["date"] is True and len(ml["Columns"]["levels"]) == 4 and "Rows" not in ml,
      "PBIR matrix_levels flags the date role and skips single-level roles")
check(epb._matrix_levels(date_qs, "lineChart") is None, "PBIR matrix_levels is matrix-only")

classic_date = {
    "projections": {"Columns": [{"queryRef": D + "Year"}, {"queryRef": D + "Quarter"},
                                 {"queryRef": D + "Month"}, {"queryRef": D + "Day"}],
                    "Rows": [{"queryRef": "Geo Hierarchy.Country"}, {"queryRef": "Geo Hierarchy.City"}]},
    "activeProjections": {"Columns": [{"queryRef": D + "Year"}],
                          "Rows": [{"queryRef": "Geo Hierarchy.Country"}]},
}
cp = erc._projections(classic_date, "pivotTable")
check(cp["Columns"] == [D + "Year"], "classic date hierarchy on Columns keeps only the active level")
check(cp["Rows"] == ["Geo Hierarchy.Country", "Geo Hierarchy.City"],
      "classic non-date user hierarchy keeps all levels")
cml = erc._matrix_levels(classic_date, "pivotTable")
check(cml["Columns"]["date"] is True and cml["Rows"]["date"] is False and cml["Rows"]["active"] == ["Geo Hierarchy.Country"],
      "classic matrix_levels flags date vs user hierarchy")

classic_alias_date = {
    "prototypeQuery": {
        "From": [{"Name": "d", "Entity": "Calendar"}],
        "Select": [
            {"Name": "select", "Column": {
                "Expression": {"SourceRef": {"Source": "d"}}, "Property": "Year"}},
            {"Name": "select1", "Column": {
                "Expression": {"SourceRef": {"Source": "d"}}, "Property": "Month"}},
        ],
    },
    "projections": {"Columns": [{"queryRef": "select"}, {"queryRef": "select1"}]},
    "activeProjections": {"Columns": [{"queryRef": "select"}]},
}
check(erc._projections(classic_alias_date, "pivotTable")["Columns"] == ["Calendar.Year"],
      "classic positional aliases are resolved before date hierarchy detection")
check(erc._matrix_levels(classic_alias_date, "pivotTable")["Columns"]["date"] is True,
      "classic matrix_levels detects date hierarchies behind positional aliases")

print("\n2d. user calendar hierarchies are date hierarchies; non-date user hierarchies keep all")
def _cal(levels, hier, ent="Calendar", active=0):
    return {"Columns": {"projections": [_level(ent, hier, l, active=True if i == active else None)
                                         for i, l in enumerate(levels)]}}
cal_std = _cal(["Year", "Quarter", "Month Name", "Date"], "Calendar Hierarchy")
cal_fis = _cal(["Fiscal Year", "Fiscal Month", "Date"], "Fiscal")
for label, qs, first in (("Calendar Hierarchy", cal_std, "Calendar.Year"), ("Fiscal", cal_fis, "Calendar.Fiscal Year")):
    check(epb._role_bindings(qs, "pivotTable")["Columns"] == [first],
          f"PBIR {label} calendar hierarchy keeps the active level only")
    check(epb._matrix_levels(qs, "pivotTable")["Columns"]["date"] is True,
          f"PBIR {label} calendar hierarchy is flagged date")
geo_h = _cal(["Country", "State", "City"], "Geo Hierarchy", ent="Geo")
check(epb._role_bindings(geo_h, "pivotTable")["Columns"] == ["Geo.Country", "Geo.State", "Geo.City"],
      "PBIR non-date user hierarchy keeps every level")
check(epb._matrix_levels(geo_h, "pivotTable")["Columns"]["date"] is False, "PBIR geo hierarchy is not date")
# partial-active computation: only flagged projections are active
pa = epb._matrix_levels({"Rows": {"projections": [
    {"queryRef": "Orders.Region", "active": True}, {"queryRef": "Orders.Category"},
    {"queryRef": "Orders.Product"}]}}, "pivotTable")["Rows"]
check(pa["active"] == ["Orders.Region"] and len(pa["levels"]) == 3,
      "PBIR matrix_levels active holds only the flagged level, not every projection")

def _cl(ent, hier, levels):
    return [{"queryRef": f"{ent}.{hier}.{l}"} for l in levels]
for label, ent, hier, lv in (("Calendar Hierarchy", "Calendar", "Calendar Hierarchy", ["Year", "Quarter", "Month Name", "Date"]),
                             ("Fiscal", "Calendar", "Fiscal", ["Fiscal Year", "Fiscal Month", "Date"])):
    sv = {"projections": {"Columns": _cl(ent, hier, lv)},
          "activeProjections": {"Columns": _cl(ent, hier, lv[:1])}}
    check(erc._projections(sv, "pivotTable")["Columns"] == [f"{ent}.{hier}.{lv[0]}"],
          f"classic {label} calendar hierarchy keeps the active level only")
    check(erc._matrix_levels(sv, "pivotTable")["Columns"]["date"] is True,
          f"classic {label} calendar hierarchy is flagged date")
sv = {"projections": {"Columns": _cl("Geo", "Geo Hierarchy", ["Country", "State", "City"])},
      "activeProjections": {"Columns": _cl("Geo", "Geo Hierarchy", ["Country"])}}
check(erc._projections(sv, "pivotTable")["Columns"] == ["Geo.Geo Hierarchy.Country", "Geo.Geo Hierarchy.State", "Geo.Geo Hierarchy.City"],
      "classic non-date user hierarchy keeps every level")

print("\n2e. date detection is word-based: snake/Camel/abbrev grains, scope words, no substring hits")
def _roles(refs):
    return {"Rows": {"projections": [{"queryRef": r} for r in refs]}}
def _both_date(refs):
    e = epb._matrix_levels(_roles(refs), "pivotTable")["Rows"]["date"]
    c = erc._matrix_levels({"projections": {"Rows": [{"queryRef": r} for r in refs]}},
                           "pivotTable")["Rows"]["date"]
    return e, c
for label, refs, want in (
        ("snake_case date leaves on a non-calendar table",
         ["Orders.ORDER_YEAR", "Orders.ORDER_MONTH", "Orders.ORDER_DATE"], True),
        ("CamelCase date leaves on a non-calendar table",
         ["Sales.OrderYear", "Sales.OrderMonth", "Sales.OrderDay"], True),
        ("CamelCase user hierarchy leaves",
         ["Sales.OrderHierarchy.OrderYear", "Sales.OrderHierarchy.OrderMonth",
          "Sales.OrderHierarchy.OrderDay"], True),
        ("abbreviation leaves Yr/Qtr/Mth/Day",
         ["Time.Time Hierarchy.Yr", "Time.Time Hierarchy.Qtr", "Time.Time Hierarchy.Mth",
          "Time.Time Hierarchy.Day"], True),
        ("calendar-scoped table with non-grain leaves",
         ["Calendar.Cal.FY", "Calendar.Cal.Period"], True),
        ("calendar-scoped fiscal abbreviations",
         ["Calendar.Cal.FY", "Calendar.Cal.FQ", "Calendar.Cal.FM"], True),
        ("date-scoped compact abbreviations",
         ["Date.Hierarchy.Y", "Date.Hierarchy.Q", "Date.Hierarchy.M", "Date.Hierarchy.D"], True),
        ("fiscal-scoped hierarchy with grain leaves",
         ["Calendar.Fiscal.Fiscal Year", "Calendar.Fiscal.Fiscal Month"], True),
        ("classic Year + Region is not a date hierarchy",
         ["Orders.Year", "Orders.Region"], False),
        ("compound fiscal year + calendar attribute is not a date hierarchy",
         ["Calendar.Fiscal Year", "Calendar.Holiday"], False),
        ("mixed Year + Month Name + Region is a date hierarchy",
         ["Calendar.Year", "Calendar.Month Name", "Calendar.Region"], True),
        ("mixed Year + Month Name + Region on a non-calendar table",
         ["Orders.Year", "Orders.Month Name", "Orders.Region"], True),
        ("two aging-bucket leaves are not date grains",
         ["AR.Days Overdue Bucket", "AR.Months Since Signup"], False),
        ("Consolidated GL account hierarchy is not date",
         ["Consolidated GL.Account Hierarchy.Account Class",
          "Consolidated GL.Account Hierarchy.Account Group",
          "Consolidated GL.Account Hierarchy.Account"], False),
        ("Fiscal Actuals finance table is not date (fiscal alone is not scope)",
         ["Fiscal Actuals.Account Hierarchy.Account Class",
          "Fiscal Actuals.Account Hierarchy.Account"], False),
        ("Candidates table does not match 'date'",
         ["Candidates.Stage", "Candidates.Source"], False),
        ("Status Updates does not match 'date'",
         ["Status Updates.Team", "Status Updates.Owner"], False),
        ("AR aging bucket 'Days Overdue Bucket' is not a date grain",
         ["AR.Days Overdue Bucket", "AR.Customer"], False),
        ("fiscal year + fiscal period on a fact table is a date hierarchy",
         ["FACT_GL.FISCAL_YEAR", "FACT_GL.FISCAL_PERIOD"], True),
        ("'Candidate Hierarchy' does not match the anchored 'date hierarchy' marker",
         ["Candidates.Candidate Hierarchy.Stage", "Candidates.Candidate Hierarchy.Source",
          "Candidates.Candidate Hierarchy.Recruiter"], False),
        ("a 'Product Variations' table does not match the anchored '.Variation.' marker",
         ["Product Variations.Color", "Product Variations.Size"], False),
        ("a product Variation hierarchy is not an auto-date hierarchy",
         ["Product.Variation.Color", "Product.Variation.Size"], False),
        ("independent date columns are not hierarchy grains",
         ["Orders.Order Date", "Orders.Ship Date"], False),
        ("a timesheet table is not date-scoped ('time' is not a scope word)",
         ["Time Entries.Work Hierarchy.Client", "Time Entries.Work Hierarchy.Project",
          "Time Entries.Work Hierarchy.Task"], False),
        ("auto-date variation refs are still date levels",
         ["D.Date.Variation.Date Hierarchy.Year", "D.Date.Variation.Date Hierarchy.Quarter"], True)):
    e, c = _both_date(refs)
    check(e is want, f"PBIR {label} -> date={want}")
    check(c is want, f"classic {label} -> date={want}")
check(set(epb._words("ORDER_YEAR OrderYear order-year Order.Year2")) == {"order", "year", "2"},
      "word splitter handles underscore, camelCase, hyphen, dot and digit boundaries")
# The at-least-two rule: one date-ish level next to plain fields is not a date hierarchy.
check(epb._is_date_hierarchy([{"queryRef": "Orders.ORDER_YEAR"}, {"queryRef": "Orders.Region"}]) is False
      and erc._is_date_hierarchy([{"queryRef": "Orders.ORDER_YEAR"}, {"queryRef": "Orders.Region"}]) is False,
      "a single date-ish level is not a date hierarchy (at-least-two rule)")
check(epb._role_bindings({"Rows": {"projections": [
          {"queryRef": "Consolidated GL.Account Hierarchy.Account Class", "active": True},
          {"queryRef": "Consolidated GL.Account Hierarchy.Account Group"},
          {"queryRef": "Consolidated GL.Account Hierarchy.Account"}]}}, "pivotTable")["Rows"] ==
      ["Consolidated GL.Account Hierarchy.Account Class",
       "Consolidated GL.Account Hierarchy.Account Group",
       "Consolidated GL.Account Hierarchy.Account"],
      "PBIR non-date matrix hierarchy keeps ALL levels in the binding")

print("\n3. Azure Maps roles are canonicalized without touching scatter axes")
azure_roles = {
    "X": {"projections": [{"queryRef": "G.Coordinate A"}]},
    "Y": {"projections": [{"queryRef": "G.Coordinate B"}]},
    "Size": {"projections": [{"queryRef": "G.Metric"}]},
    "Series": {"projections": [{"queryRef": "G.Group"}]},
}
expected_azure = {
    "Longitude": ["G.Coordinate A"],
    "Latitude": ["G.Coordinate B"],
    "Size": ["G.Metric"],
    "Series": ["G.Group"],
}
check(epb._role_bindings(azure_roles, "azureMap") == expected_azure,
      "PBIR azureMap maps X/Y to Longitude/Latitude and preserves Size/Series")
check(epb._role_bindings(azure_roles, "scatterChart") == {
          "X": ["G.Coordinate A"], "Y": ["G.Coordinate B"],
          "Size": ["G.Metric"], "Series": ["G.Group"]
      }, "PBIR scatter keeps genuine X/Y axes")

classic_azure = {
    "projections": {
        "X": [{"queryRef": "G.Coordinate A"}],
        "Y": [{"queryRef": "G.Coordinate B"}],
        "Size": [{"queryRef": "G.Metric"}],
        "Series": [{"queryRef": "G.Group"}],
    }
}
check(erc._projections(classic_azure, "azureMap") == expected_azure,
      "classic/PBIX azureMap uses the same canonical role contract")
check(erc._projections(classic_azure, "scatterChart") == {
          "X": ["G.Coordinate A"], "Y": ["G.Coordinate B"],
          "Size": ["G.Metric"], "Series": ["G.Group"]
      }, "classic/PBIX scatter keeps genuine X/Y axes")
rich_textbox = {
    "objects": {
        "general": [{
            "properties": {
                "paragraphs": [
                    {"textRuns": [{"value": "Retail Performance & Trends"}]},
                    {"textRuns": [{"value": "Net revenue, profitability, and order mix"}]},
                ]
            }
        }]
    }
}
check(epb._textbox_body(rich_textbox) ==
      "Retail Performance & Trends\nNet revenue, profitability, and order mix",
      "PBIR rich-text paragraphs preserve title and subtitle")


# ── F14 / G22 / G24: faithful report signals (synthetic fixtures only) ──────────
print("\n4. F14: saved slicer selections -> slicer_state.saved_selection")


def lit(v):
    return {"Literal": {"Value": v}}


def sel_filter(values, exclude=False, entity="Customer", prop="Region", via_source=True):
    """A Version-2 saved-selection query filter as PBIR stores it in
    visual.objects.general[].properties.filter.filter."""
    src = ({"Source": "c"} if via_source else {"Entity": entity})
    in_node = {"In": {"Expressions": [{"Column": {"Expression": {"SourceRef": src}, "Property": prop}}],
                      "Values": [[lit(v)] for v in values]}}
    cond = {"Not": {"Expression": in_node}} if exclude else in_node
    return {"Version": 2, "From": [{"Name": "c", "Entity": entity, "Type": 0}],
            "Where": [{"Condition": cond}]}


def slicer_visual(filter_obj, field=None, extra=None):
    proj_field = field if field is not None else {"Column": {
        "Expression": {"SourceRef": {"Entity": "Customer"}}, "Property": "Region"}}
    vis = {"visualType": "slicer",
           "query": {"queryState": {"Values": {"projections": [
               {"field": proj_field, "queryRef": "Customer.Region", "active": True}]}}},
           "objects": {"general": [{"properties": {"filter": {"filter": filter_obj}}}]}}
    vis.update(extra or {})
    return vis


def saved(values, **kw):
    v = slicer_visual(sel_filter(values, **kw))
    return epb._slicer_state(v, v["query"]["queryState"])


st = saved(["'East'", "'West'"])
check(st.get("saved_selection") == {"mode": "include", "column": "Customer.Region",
                                    "values": ["East", "West"], "has_null": False},
      "In -> include, text literals unquoted, column = Entity.Property")
check(saved(["'East'"], exclude=True)["saved_selection"]["mode"] == "exclude",
      "Not(In) -> exclude")
st = saved(["2026L", "2027L"])
check(st["saved_selection"]["values"] == [2026, 2027]
      and all(type(x) is int for x in st["saved_selection"]["values"]),
      "2026L -> int")
st = saved(["1.5D", "2D"])
check(st["saved_selection"]["values"] == [1.5, 2.0]
      and all(type(x) is float for x in st["saved_selection"]["values"]),
      "1.5D / 2D -> double")
st = saved(["true", "false"])
check(st["saved_selection"]["values"] == [True, False], "true/false -> bool")
st = saved(["'A'", "null", "'B''s'"])
check(st["saved_selection"] == {"mode": "include", "column": "Customer.Region",
                                "values": ["A", "B's"], "has_null": True},
      "null is dropped from values and flagged has_null; '' unescaped")
st = saved(["datetime'2026-03-01T00:00:00'"])
check(st["saved_selection"]["values"] == ["2026-03-01T00:00:00"],
      "datetime'...' -> ISO string")
st = saved(["null"], exclude=True)
check(st["saved_selection"] == {"mode": "exclude", "column": "Customer.Region",
                                "values": [], "has_null": True},
      "exclude-blank selection: empty values, has_null true")
v = slicer_visual(sel_filter(["'x'"], entity="Product", prop="Tier"),
                  field={"HierarchyLevel": {"Expression": {"Hierarchy": {"Expression": {
                      "PropertyVariationSource": {"Expression": {"SourceRef": {"Entity": "D"}},
                                                  "Name": "Variation", "Property": "Date"}},
                      "Hierarchy": "Date Hierarchy"}}, "Level": "Year"}})
st = epb._slicer_state(v, v["query"]["queryState"])
check(st["saved_selection"]["column"] == "Product.Tier",
      "column falls back to the filter's own column (From alias resolved) when the slicer field is a hierarchy")
check(st.get("has_saved_filter") is True and "selection" in st,
      "existing has_saved_filter / selection signals are kept")
v = slicer_visual({"Version": 2, "From": [{"Name": "c", "Entity": "Customer", "Type": 0}],
                   "Where": [{"Condition": {"Between": {"Expression": {"Column": {
                       "Expression": {"SourceRef": {"Source": "c"}}, "Property": "Day"}},
                       "LowerBound": lit("1L"), "UpperBound": lit("9L")}}}]})
st = epb._slicer_state(v, v["query"]["queryState"])
check("saved_selection" not in st and st.get("saved_selection_unsupported"),
      "a non-list saved filter is RECORDED as unsupported, never approximated")
v = slicer_visual(None)
v["objects"] = {}
check("saved_selection" not in (epb._slicer_state(v, v["query"]["queryState"]) or {}),
      "no saved filter -> no saved_selection")

print("\n5. G22: bind by field.Entity/Property; queryRef is only an alias")
renamed = {"Values": {"projections": [
    {"field": {"Measure": {"Expression": {"SourceRef": {"Entity": "KPI"}},
                           "Property": "Net Margin"}},
     "queryRef": "KPI.Net Operating Margin"},
    {"field": {"Column": {"Expression": {"SourceRef": {"Entity": "Sales"}}, "Property": "Amount"}},
     "queryRef": "Sales.Amount"},
    {"field": {"Aggregation": {"Expression": {"Column": {
        "Expression": {"SourceRef": {"Entity": "Sales"}}, "Property": "Qty"}}, "Function": 0}},
     "queryRef": "Sum(Sales.Quantity)"},
    {"field": {"Aggregation": {"Expression": {"Column": {
        "Expression": {"SourceRef": {"Entity": "Sales"}}, "Property": "Qty"}}, "Function": 99}},
     "queryRef": "Weird(Sales.Qty)"},
    {"queryRef": "NoField.Col"}]}}
check(epb._role_bindings(renamed) == {"Values": [
    "KPI.Net Margin", "Sales.Amount", "Sum(Sales.Qty)", "Weird(Sales.Qty)", "NoField.Col"]},
      "stale queryRefs bind by the field expression; unknown agg fn / no field keep queryRef")
check(epb._binding_aliases(renamed) == {
    "KPI.Net Margin": "KPI.Net Operating Margin",
    "Sum(Sales.Qty)": "Sum(Sales.Quantity)"},
      "queryRef kept as alias only where it differs from the field-derived ref")
stale_sort = {"visualType": "tableEx", "query": {"queryState": renamed, "sortDefinition": {"sort": [
    {"field": renamed["Values"]["projections"][0]["field"], "direction": "Descending"}]}}}
check(epb._sort_signal(stale_sort) == {"queryRef": "KPI.Net Margin", "direction": "desc"},
      "sort resolves to the field-derived ref")

print("\n5a. whole-3: aggregate function name comes from the queryRef; numeric enum is only the fallback")
def _agg_proj(fn, qr):
    p = {"field": {"Aggregation": {"Expression": {"Column": {
        "Expression": {"SourceRef": {"Entity": "Sales"}}, "Property": "Price"}}, "Function": fn}}}
    if qr is not None:
        p["queryRef"] = qr
    return p
check(epb._projection_ref(_agg_proj(3, "Min(Sales.Price)")) == "Min(Sales.Price)",
      "Function 3 + queryRef Min(...) binds Min, not Max")
check(epb._projection_ref(_agg_proj(4, "Max(Sales.Price)")) == "Max(Sales.Price)", "queryRef Max kept")
check(epb._projection_ref(_agg_proj(5, "CountNonNull(Sales.Price)")) == "CountNonNull(Sales.Price)",
      "queryRef CountNonNull kept")
check(epb._projection_ref(_agg_proj(3, "Min(Sales.OldName)")) == "Min(Sales.Price)",
      "queryRef supplies the function only; Entity.Property comes from the field")
want = {0: "Sum", 1: "Avg", 2: "Count", 3: "Min", 4: "Max", 5: "CountNonNull",
        6: "Median", 7: "StandardDeviation", 8: "Variance"}
check(all(epb._projection_ref(_agg_proj(c, None)) == f"{n}(Sales.Price)" for c, n in want.items()),
      "no queryRef: numeric fallback follows QueryAggregateFunction (0 Sum .. 8 Variance)")

print("\n5b. classic extractor already binds by field expression (prototypeQuery.Select)")
sv = {"visualType": "card",
      "projections": {"Values": [{"queryRef": "KPI.Net Operating Margin"}]},
      "prototypeQuery": {"From": [{"Name": "k", "Entity": "KPI"}],
                         "Select": [{"Measure": {"Expression": {"SourceRef": {"Source": "k"}},
                                                 "Property": "Net Margin"},
                                     "Name": "KPI.Net Operating Margin"}]}}
check(erc._projections(sv) == {"Values": ["KPI.Net Margin"]},
      "classic: stale projection queryRef resolves to the Select entry's Entity.Property")

print("\n6. G24: a slicer's OWN visual-level filters get scope slicer-self")
import tempfile
with tempfile.TemporaryDirectory() as d:
    pdir = os.path.join(d, "definition", "pages", "p1")
    os.makedirs(os.path.join(pdir, "visuals", "s1"))
    os.makedirs(os.path.join(pdir, "visuals", "c1"))
    json.dump({"pageOrder": ["p1"]}, open(os.path.join(d, "definition", "pages", "pages.json"), "w"))
    json.dump({"name": "p1", "displayName": "P1"}, open(os.path.join(pdir, "page.json"), "w"))
    own = {"name": "f1", "type": "Categorical", "field": {"Column": {
        "Expression": {"SourceRef": {"Entity": "Customer"}}, "Property": "Region"}},
        "filter": {"Version": 2, "From": [{"Name": "c", "Entity": "Customer", "Type": 0}],
                   "Where": [{"Condition": {"Not": {"Expression": {"In": {"Expressions": [{"Column": {
                       "Expression": {"SourceRef": {"Source": "c"}}, "Property": "Region"}}],
                       "Values": [[lit("null")]]}}}}}]}}
    json.dump({"name": "s1", "position": {"x": 0, "y": 0, "width": 10, "height": 10},
               "visual": {"visualType": "slicer",
                          "query": {"queryState": {"Values": {"projections": [{"field": {"Column": {
                              "Expression": {"SourceRef": {"Entity": "Customer"}}, "Property": "Region"}},
                              "queryRef": "Customer.Region"}]}}}},
               "filterConfig": {"filters": [own]}},
              open(os.path.join(pdir, "visuals", "s1", "visual.json"), "w"))
    json.dump({"name": "c1", "position": {"x": 0, "y": 20, "width": 10, "height": 10},
               "visual": {"visualType": "clusteredColumnChart", "query": {"queryState": {}}},
               "filterConfig": {"filters": [own]}},
              open(os.path.join(pdir, "visuals", "c1", "visual.json"), "w"))
    out = epb.extract(d)
recs = {r["visual_id"]: r for r in out["pages"][0]["visuals"]}
check([f["scope"] for f in recs["s1"]["filters"]] == ["slicer-self"],
      "slicer visual-level filter -> scope slicer-self")
check([f["scope"] for f in recs["c1"]["filters"]] == ["visual"],
      "a chart's visual-level filter keeps scope visual")
check(recs["s1"]["filters"][0].get("target") == "Customer.Region",
      "slicer-self filter keeps its target/mode payload")

# A table's implicit (default-summarization) aggregate lives ONLY in the queryRef:
# the field is a bare Column. The aggregate must survive field-bound binding.
_bare_col = lambda prop, qr: {"queryRef": qr, "field": {"Column": {
    "Expression": {"SourceRef": {"Entity": "Sales"}}, "Property": prop}}}
check(epb._projection_ref(_bare_col("Qty", "Sum(Sales.Qty)")) == "Sum(Sales.Qty)",
      "bare Column + queryRef Sum(...) keeps the implicit Sum")
check(epb._projection_ref(_bare_col("Qty", "Sales.Qty")) == "Sales.Qty",
      "bare Column with a plain queryRef stays unaggregated")
check(epb._projection_ref(_bare_col("Qty", "Sum(Sales.OldQty)")) == "Sum(Sales.Qty)",
      "a stale queryRef inner name still gives the field's column, with the queryRef's Sum")
check(epb._projection_ref({"queryRef": "Sales.Total", "field": {"Measure": {
    "Expression": {"SourceRef": {"Entity": "Sales"}}, "Property": "Total"}}}) == "Sales.Total",
      "measures are never wrapped")

print(f"\n{'ALL PASS' if not fails else f'{len(fails)} FAILURE(S)'}")
for f in fails:
    print(f"  - {f}")
sys.exit(0 if not fails else 1)
