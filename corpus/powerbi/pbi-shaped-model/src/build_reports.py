#!/usr/bin/env python3
"""Generate the Power BI test models (TMSL) and reports (PBIR) for the pbi-shaped-model corpus.

Reads the compact description `reports.json` and writes, under --out:

    manifest.json                      slug, displayName and (reports) model of every item
    <model-slug>/model.bim             TMSL (Import-mode Snowflake M partitions)
    <model-slug>/definition.pbism
    <report-slug>/definition.pbir      byConnection; the model id is the literal {MODEL_ID},
                                       which fabric_publish.py fills in at publish time
                                       (as is the workspace name token {WORKSPACE})
    <report-slug>/definition/...       PBIR pages and visuals
    <report-slug>/StaticResources/...  the base theme
    <report-slug>/report-bundle.json   flat {path: text} view of the report, for inspection

Snowflake coordinates are arguments, never defaults. The committed `out/` uses placeholders:

    python3 build_reports.py --out ../out --host example-account.snowflakecomputing.com \
        --warehouse EXAMPLE_WH --database SAMPLE_DB

The real values are passed on the command line only, into an untracked directory, for publishing.
Standard library only.
"""
import argparse
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = os.path.join(HERE, "reports.json")
THEME_NAME = "CY25SU12"
THEME_SRC = os.path.join(HERE, "static", THEME_NAME + ".json")
MODEL_ID_TOKEN = "{MODEL_ID}"
WORKSPACE_TOKEN = "{WORKSPACE}"  # replaced with the workspace name at publish time

SCHEMA_URL = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition"


# ----------------------------------------------------------------------------- model (TMSL)
def partition(name, host, warehouse, database, schema, table):
    return {"name": name, "mode": "import", "source": {"type": "m", "expression": [
        "let",
        f'  Source = Snowflake.Databases("{host}", "{warehouse}", [Role = null, CreateNavigationProperties = null, '
        f'ConnectionTimeout = null, CommandTimeout = null, Implementation = "2.0"]),',
        f'  #"Navigation 1" = Source{{[Name = "{database}", Kind = "Database"]}}[Data],',
        f'  #"Navigation 2" = #"Navigation 1"{{[Name = "{schema}", Kind = "Schema"]}}[Data],',
        f'  #"Navigation 3" = #"Navigation 2"{{[Name = "{table}", Kind = "Table"]}}[Data]',
        "in",
        '  #"Navigation 3"']}}


def column(row):
    name, src, dtype = row[0], row[1], row[2]
    summarize = row[3] if len(row) > 3 and row[3] else "none"
    fmt = row[4] if len(row) > 4 else None
    extra = row[5] if len(row) > 5 else {}
    c = {"name": name, "dataType": dtype, "sourceColumn": src, "summarizeBy": summarize}
    if fmt:
        c["formatString"] = fmt
    c.update(extra)
    return c


def table_def(name, t, host, warehouse, database, schema):
    cols = [column(r) for r in t["columns"]]
    for cc in t.get("calc", []):
        cols.append({"type": "calculated", "name": cc["name"], "dataType": cc["dataType"],
                     "isDataTypeInferred": True, "expression": cc["expression"],
                     "formatString": cc.get("formatString", "General"), "summarizeBy": "none"})
    out = {"name": name, "columns": cols,
           "partitions": [partition(name, host, warehouse, database, schema, t["source"])]}
    if t.get("category"):
        out["dataCategory"] = t["category"]
    return out


def calc_table_def(name, t):
    cols = []
    for cname, dtype in t["columns"]:
        c = {"name": cname, "dataType": dtype, "sourceColumn": f"[{cname}]", "type": "calculatedTableColumn",
             "summarizeBy": "none"}
        if cname in t.get("sortBy", {}):
            c["sortByColumn"] = t["sortBy"][cname]
        cols.append(c)
    return {"name": name, "columns": cols,
            "partitions": [{"name": name, "mode": "import",
                            "source": {"type": "calculated", "expression": t["expression"]}}]}


def measure_def(row):
    name, expr, fmt, folder = row
    return {"name": name, "expression": expr, "formatString": fmt, "displayFolder": folder}


def relationship_def(row):
    name, ft, fc, tt, tc = row[:5]
    r = {"name": name, "fromTable": ft, "fromColumn": fc, "toTable": tt, "toColumn": tc}
    if len(row) > 5 and row[5] is False:
        r["isActive"] = False
    return r


def model_def(spec, mspec, host, warehouse, database):
    tables = [table_def(n, spec["tables"][n], host, warehouse, database, spec["schema"]) for n in mspec["tables"]]
    tables += [calc_table_def(n, spec["calcTables"][n]) for n in mspec.get("calcTables", [])]
    by_name = {t["name"]: t for t in tables}
    for set_name in mspec["measureSets"]:
        for table, rows in spec["measureSets"][set_name].items():
            by_name[table].setdefault("measures", []).extend(measure_def(r) for r in rows)
    body = {
        "culture": "en-US", "defaultPowerBIDataSourceVersion": "powerBI_V3", "sourceQueryCulture": "en-US",
        "tables": tables, "relationships": [relationship_def(r) for r in mspec["relationships"]],
        "annotations": [{"name": "PBI_QueryOrder", "value": json.dumps([t["name"] for t in tables])}]}
    if mspec.get("roles"):
        body["roles"] = mspec["roles"]
    return {"name": mspec["name"], "compatibilityLevel": 1567, "model": body}


# ----------------------------------------------------------------------------- report (PBIR)
def lit(v):
    return {"expr": {"Literal": {"Value": v}}}


def parse_field(ref):
    kind, rest = ref.split(":", 1)
    entity, prop = rest.split(".", 1)
    return kind, entity, prop


def field_json(ref):
    kind, entity, prop = parse_field(ref)
    key = "Column" if kind == "c" else "Measure"
    return {key: {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def projection(ref, active=None):
    kind, entity, prop = parse_field(ref)
    p = {"field": field_json(ref), "queryRef": f"{entity}.{prop}", "nativeQueryRef": prop}
    if active is not None:
        p["active"] = active
    return p


def in_filter(entity, prop, values, exclude=False):
    cond = {"In": {"Expressions": [{"Column": {"Expression": {"SourceRef": {"Source": "t"}}, "Property": prop}}],
                   "Values": [[{"Literal": {"Value": "'" + v.replace("'", "''") + "'"}}] for v in values]}}
    if exclude:
        cond = {"Not": {"Expression": cond}}
    return {"Version": 2, "From": [{"Name": "t", "Entity": entity, "Type": 0}], "Where": [{"Condition": cond}]}


def visual_json(v, z):
    x0, y0, w, h = v["at"]
    unit_w, unit_h = 104, 40
    pos = {"x": round(16 + x0 * unit_w, 1), "y": round(8 + y0 * unit_h, 1), "width": round(w * unit_w - 8, 1),
           "height": round(h * unit_h - 8, 1), "z": z, "tabOrder": z}
    qs = {}
    for role, refs in v["fields"].items():
        qs[role] = {"projections": [projection(r, True if (v["type"] == "pivotTable" and role == "Rows") else None)
                                    for r in refs]}
        if v["type"] == "pivotTable" and role == "Rows":
            for i, p in enumerate(qs[role]["projections"]):
                p["active"] = i == 0
    out = {"$schema": f"{SCHEMA_URL}/visualContainer/2.5.0/schema.json", "name": v["id"], "position": pos,
           "visual": {"visualType": v["type"], "query": {"queryState": qs},
                      "visualContainerObjects": {"title": [{"properties": {
                          "show": lit("true"), "text": lit("'" + v["title"].replace("'", "''") + "'")}}]}}}
    objects = {}
    if v["type"] == "slicer":
        _, entity, prop = parse_field(v["fields"]["Values"][0])
        objects["data"] = [{"properties": {"mode": lit("'Dropdown'")}}]
        if v.get("select"):
            objects["general"] = [{"properties": {"filter": {"filter": in_filter(entity, prop, v["select"])}}}]
        if v.get("sync"):
            out["visual"]["syncGroup"] = {"groupName": v["sync"], "fieldChanges": True, "filterChanges": True}
    if v["type"] == "pivotTable":
        objects["subTotals"] = [{"properties": {"rowSubtotals": lit("true")}}]
    if objects:
        out["visual"]["objects"] = objects
    return out


def report_files(rspec, theme_text):
    files = {
        "definition.pbir": {
            "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json",
            "version": "4.0",
            "datasetReference": {"byConnection": {"connectionString":
                f'Data Source=powerbi://api.powerbi.com/v1.0/myorg/{WORKSPACE_TOKEN};initial catalog="{rspec["model"]}";'
                f'integrated security=ClaimsToken;semanticmodelid={MODEL_ID_TOKEN}'}}},
        "definition/version.json": {"$schema": f"{SCHEMA_URL}/versionMetadata/1.0.0/schema.json", "version": "2.0.0"},
        "definition/pages/pages.json": {"$schema": f"{SCHEMA_URL}/pagesMetadata/1.0.0/schema.json",
                                        "pageOrder": [p["id"] for p in rspec["pages"]],
                                        "activePageName": rspec["pages"][0]["id"]},
    }
    report = {
        "$schema": f"{SCHEMA_URL}/report/3.1.0/schema.json",
        "themeCollection": {"baseTheme": {"name": THEME_NAME, "type": "SharedResources",
                                          "reportVersionAtImport": {"visual": "2.5.0", "page": "2.0.0", "report": "3.1.0"}}},
        "resourcePackages": [{"name": "SharedResources", "type": "SharedResources", "items": [
            {"name": THEME_NAME, "path": f"BaseThemes/{THEME_NAME}.json", "type": "BaseTheme"}]}],
        "settings": {"isPersistentUserStateDisabled": True, "useStylableVisualContainerHeader": True,
                     "defaultFilterActionIsDataFilter": True, "defaultDrillFilterOtherVisuals": False,
                     "exportDataMode": "AllowSummarizedAndUnderlying"}}
    if rspec.get("filters"):
        report["filterConfig"] = {"filters": [{
            "name": f["name"], "field": {"Column": {"Expression": {"SourceRef": {"Entity": f["table"]}}, "Property": f["column"]}},
            "type": "Categorical", "howCreated": "User",
            "filter": in_filter(f["table"], f["column"], f["values"], exclude=f["mode"] == "exclude")}
            for f in rspec["filters"]]}
    files["definition/report.json"] = report
    for page in rspec["pages"]:
        base = f"definition/pages/{page['id']}"
        files[f"{base}/page.json"] = {"$schema": f"{SCHEMA_URL}/page/2.0.0/schema.json", "name": page["id"],
                                      "displayName": page["name"], "displayOption": "FitToPage",
                                      "width": 1280, "height": 720}
        for i, v in enumerate(page["visuals"]):
            files[f"{base}/visuals/{v['id']}/visual.json"] = visual_json(v, 1000 + i * 10)
    text = {p: json.dumps(c, indent=2, ensure_ascii=False) for p, c in files.items()}
    text[f"StaticResources/SharedResources/BaseThemes/{THEME_NAME}.json"] = theme_text
    return text


# ----------------------------------------------------------------------------- driver
def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def build(out_dir, host, warehouse, database, schema=None, spec_path=SPEC):
    with open(spec_path, encoding="utf-8") as f:
        spec = json.load(f)
    if schema:
        spec["schema"] = schema
    with open(THEME_SRC, encoding="utf-8") as f:
        theme_text = f.read()
    # Only remove directories this build owns (the item slugs in the spec); never anything else in out_dir.
    owned = [i["slug"] for i in spec["models"]] + [i["slug"] for i in spec["reports"]]
    for slug in owned:
        p = os.path.join(out_dir, slug)
        if os.path.isdir(p):
            shutil.rmtree(p)
    os.makedirs(out_dir, exist_ok=True)
    manifest = {"models": [], "reports": []}
    for ms in spec["models"]:
        model = model_def(spec, ms, host, warehouse, database)
        write(os.path.join(out_dir, ms["slug"], "model.bim"), json.dumps(model, indent=2, ensure_ascii=False))
        write(os.path.join(out_dir, ms["slug"], "definition.pbism"), json.dumps({
            "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json",
            "version": "4.2", "settings": {}}, indent=2))
        manifest["models"].append({"slug": ms["slug"], "displayName": ms["name"]})
    for rs in spec["reports"]:
        files = report_files(rs, theme_text)
        for p, text in files.items():
            write(os.path.join(out_dir, rs["slug"], p), text)
        write(os.path.join(out_dir, rs["slug"], "report-bundle.json"), json.dumps(files, indent=1, ensure_ascii=False))
        manifest["reports"].append({"slug": rs["slug"], "displayName": rs["name"], "model": rs["model"]})
    write(os.path.join(out_dir, "manifest.json"), json.dumps(manifest, indent=2))
    return manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--host", required=True, help="Snowflake host, e.g. example-account.snowflakecomputing.com")
    ap.add_argument("--warehouse", required=True)
    ap.add_argument("--database", required=True)
    ap.add_argument("--schema", default=None, help="default: the schema named in reports.json")
    a = ap.parse_args()
    man = build(a.out, a.host, a.warehouse, a.database, a.schema)
    print(f"wrote {len(man['models'])} models and {len(man['reports'])} reports to {a.out}")


if __name__ == "__main__":
    sys.exit(main())
