#!/usr/bin/env python3
"""Generate the synthetic pnl-smoke fixtures (deterministic; stdlib only). Rerun after changing this file:

    python3 fixtures/pnl-smoke/make_fixtures.py

Writes, next to this file:
  pnl-template.xlsx      a Live Reporting Download-shaped workbook: one sheet "Summary" plus the report definition
                         as customXml/item1.xml (UTF-16), the way Solver embeds it
  pnl-executed-run.xlsx  the same layout with values, as an executed run export (no definition; expanded row filled)
  gl.csv                 a Solver-shaped GL extract (columns named <dimension>.<field>, <fact>.<value>)
  source-map.json        a neutral source map (DEMO_DB.FINANCE.*)

The executed-run values come from the plain-Python oracle below, NOT from the converter, so tests that compare the
compiler's output with them are a real check. All names, codes and amounts are synthetic.
"""
import csv
import io
import json
import math
import os
import random
import zipfile
from xml.sax.saxutils import escape  # nosemgrep: python.lang.security.use-defused-xml.use-defused-xml

HERE = os.path.dirname(os.path.abspath(__file__))
PERIOD = 202609
LOCATIONS = ["L01", "L02", "L03"]
ACCOUNTS = {"4100": "Product revenue", "4200": "Service revenue", "5100": "Cost of goods", "6100": "Salaries",
            "6200": "Rent", "6900": "Intercompany charges"}
DEPTS = {"6100": "Field Operations", "6200": "Facilities", "6900": "Shared Services"}
SCENARIOS = ["ACT", "BUD", "ADJ"]

# --------------------------------------------------------------------------------------------- data
def periods():
    out, y, m = [], 2025, 1
    while y * 100 + m <= PERIOD:
        out.append(y * 100 + m)
        m += 1
        if m == 13:
            y, m = y + 1, 1
    return out


def gl_rows():
    rnd = random.Random(20261112)
    rows = []
    for p in periods():
        for loc in LOCATIONS:
            for sc in SCENARIOS:
                if sc == "ADJ" and rnd.random() < 0.5:
                    continue
                for acct, desc in ACCOUNTS.items():
                    base = {"4": -50000, "5": 18000, "6": 9000}[acct[0]]
                    amt = round(base * (0.6 + rnd.random()) * (0.1 if sc == "ADJ" else 1), 2)
                    rows.append({"Period.PeriodId": p, "d_Scenario.Code": sc, "d_Account.Code": acct,
                                 "d_Account.Description": desc, "d_dim0.Code": loc,
                                 "d_dim1.UDF001": DEPTS.get(acct, ""), "GL_F_Trans.Value1": amt})
    return rows


# --------------------------------------------------------------------------------------------- oracle
def oracle(rows):
    """Expected report values computed directly (independent of the converter)."""
    def s(pred):
        return math.fsum(r["GL_F_Trans.Value1"] for r in rows if pred(r))     # exact on every Python version
    act = lambda r: r["d_Scenario.Code"] == "ACT"
    bud = lambda r: r["d_Scenario.Code"] in ("BUD", "ADJ")
    mtd = lambda r: r["Period.PeriodId"] == PERIOD
    ytd = lambda r: PERIOD // 100 * 100 + 1 <= r["Period.PeriodId"] <= PERIOD
    rev = lambda r: "4000" <= r["d_Account.Code"] <= "4999"
    cos = lambda r: "5000" <= r["d_Account.Code"] <= "5999"
    opx = lambda r: "6000" <= r["d_Account.Code"] <= "6999" and r["d_Account.Code"] != "6900"
    cli = lambda r: "FIELD" in r["d_dim1.UDF001"].upper()
    v = {}
    for col, sc, per in (("D", act, mtd), ("E", bud, mtd), ("G", act, ytd)):
        R = -s(lambda r: sc(r) and per(r) and rev(r))
        Cs = s(lambda r: sc(r) and per(r) and cos(r))
        O = s(lambda r: sc(r) and per(r) and opx(r))
        Cl = s(lambda r: sc(r) and per(r) and cli(r))
        GM = R - Cs
        v[col] = {6: R, 7: Cs, 8: GM, 9: (GM / R if R else 0), 10: O, 11: GM - O, 12: Cl}
    lines = {}
    for row in (6, 7, 8, 9, 10, 11, 12):
        F = v["D"][row] - v["E"][row]
        H = (F / v["E"][row]) if v["E"][row] else 0
        lines[row] = {"D": v["D"][row], "E": v["E"][row], "F": F, "G": v["G"][row], "H": H}
    detail = []
    for acct in sorted(a for a in ACCOUNTS if a.startswith("4")):
        D = -s(lambda r: act(r) and mtd(r) and r["d_Account.Code"] == acct)
        E = -s(lambda r: bud(r) and mtd(r) and r["d_Account.Code"] == acct)
        detail.append({"B": ACCOUNTS[acct], "C": acct, "D": round(D, 6), "E": round(E, 6)})
    return lines, detail


# --------------------------------------------------------------------------------------------- definition XML
LABELS = {6: "Revenue", 7: "Cost of sales", 8: "Gross margin", 9: "Gross margin %", 10: "Operating expenses",
          11: "EBITDA", 12: "Field payroll", 14: "Revenue by account"}
HEADERS = {"B": "Line", "D": "Actual", "E": "Budget", "F": "Variance", "G": "YTD Actual", "H": "Variance %"}
SHEET_FORMULAS = {8: "=D6-D7", 9: "=IFERROR(D8/D6,0)", 11: "=D8-D10"}     # per Solver column, letters swapped below


def expr(dim, name, cond, op="In", logic=None):
    lo = f' LogicalOperator="{logic}"' if logic else ""
    return f'<Expression DimensionName="{dim}" Name="{name}" Operator="{op}" Condition="{escape(cond, {chr(34): "&quot;"})}"{lo} />'


def group(name, *exprs):
    return f'<FilterGroup Name="{name}"><Filters>{"".join(exprs)}</Filters></FilterGroup>'


def selection(groups="", results=""):
    return (f'<DefinitionElement xsi:type="SelectionElement"><Dimensions />'
            f'<FilterGroups>{groups}</FilterGroups><Columns>{results}</Columns></DefinitionElement>')


def item(attrs, elements, formula=None):
    f = (f"<Formula>{escape(formula)}</Formula><HistoryElement UseOffset=\"false\"><Columns /><Dimensions /><FilterGroups />"
         f"</HistoryElement>") if formula else ""
    return (f"<DefinitionItem {attrs}><Elements>{elements}</Elements>{f}<DrillTos />"
            f'<Storage StoreAlways="false"><Mappings /></Storage></DefinitionItem>')


def param(name, ptype, dtype, prompt, default, source, extra="", xsd="string"):
    return (f'<ReportParameter Name="{name}" ParameterType="{ptype}" DataType="{dtype}" Prompt="{prompt}"{extra}>'
            f'<Default xsi:type="xsd:{xsd}">{escape(default)}</Default><Source Attribute="{source}" /></ReportParameter>')


def definition_xml():
    col = lambda c, groups: item(f'Type="Column" Column="{c}"', selection(groups))
    row = lambda r, groups, extra="", results="": item(f'Type="Row" Row="{r}"{extra}', selection(groups, results))
    ref = lambda r, c: f'<DefinitionElement xsi:type="ReferenceElement" Row="{r}" Column="{c}" />'
    cell = lambda r, c, f: item(f'Type="Cell" Row="{r}" Column="{c}"', ref(r, c), f)
    items = [item('Type="Report" Size="0"', selection(group("d_dim0", expr("d_dim0", "Code", "{@Location}"))))]
    items += [col(4, group("d_Scenario", expr("d_Scenario", "Code", "{@Actual Scenario}")) + group("Period", expr("Period", "PeriodId", "{@Period}"))),
              col(5, group("d_Scenario", expr("d_Scenario", "Code", "{@Budget Scenario}")) + group("Period", expr("Period", "PeriodId", "{@Period}"))),
              col(7, group("d_Scenario", expr("d_Scenario", "Code", "{@Actual Scenario}"))
                  + group("Period", expr("Period", "PeriodId", "{PeriodCalc.GetFunction(YTD, @Period)}")))]
    items += [row(6, group("d_Account", expr("d_Account", "Code", "4000:4999"))),
              row(7, group("d_Account", expr("d_Account", "Code", "5000:5999"))),
              row(10, group("d_Account", expr("d_Account", "Code", "6000:6999"), expr("d_Account", "Code", "6900", logic="AndNot"))),
              row(12, group("d_dim1", expr("d_dim1", "UDF001", '"field"', op="Contains"))),
              row(14, group("d_Account", expr("d_Account", "Code", "4000:4999")), ' Expand="true"',
                  '<ResultAttribute DimensionName="d_Account" Name="Code" Aggregation="Group" />')]
    for c in (4, 5, 7):
        items += [cell(6, c, '=-_xll.OneStop.ReportPlayer.OSRFunctions.OSRGet("GL_F_Trans","Value1")'),
                  cell(7, c, '=OSRGet("GL_F_Trans","Value1")'), cell(10, c, '=OSRGet("GL_F_Trans","Value1")'),
                  cell(12, c, '=IFERROR(OSRGet("GL_F_Trans","Value1")*1,0)')]
    items += [cell(14, 2, '=OSRGet("d_Account","Description")'), cell(14, 3, '=OSRGet("d_Account","Code")'),
              cell(14, 4, '=-OSRGet("GL_F_Trans","Value1")'), cell(14, 5, '=-OSRGet("GL_F_Trans","Value1")')]
    params = [param("Period", "LookupEdit", "System.Decimal", "Choose Period", "202609", "Period.PeriodId", ' IsPeriod="true" MultiSelection="false"', "decimal"),
              param("Actual Scenario", "LookupEdit", "System.String", "Choose Actual Scenario", "ACT", "d_Scenario.Code", ' Hidden="true"'),
              param("Budget Scenario", "LookupEdit", "System.String", "Choose Budget Scenario(s)", "BUD,ADJ", "d_Scenario.Code"),
              param("Location", "LookupEdit", "System.String", "Choose Location", "*", "d_dim0.Code", ' AllowBlank="true"')]
    return ('<?xml version="1.0" encoding="utf-16"?>\n'
            '<ReportDefinition xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">'
            '<Header><Id>00000000-0000-0000-0000-000000000001</Id><Title>Location P&amp;L summary (synthetic)</Title>'
            '<Author>fixture</Author><Version>1</Version><EngineVersion>5.0</EngineVersion><DateCreated>2026-01-01T00:00:00</DateCreated>'
            '<DateModified>2026-01-01T00:00:00</DateModified><DatePublished xsi:nil="true" /><PreserveFormulas>false</PreserveFormulas>'
            '<DataSources><DataSource Name="Source1" Model="00000000-0000-0000-0000-000000000002" ModelVersion="5.0" '
            'ModelCompatibilityVersion="1.0" Integration="SODS-MSSQL" /></DataSources>'
            f'<ReportParameters>{"".join(params)}</ReportParameters><ReportExpressions /><DrillToDefinitions /></Header>'
            '<Content><TableSources /></Content>'
            f'<Excel Sheet="Summary"><Mappings><Mapping><LayoutDefinition><Items>{"".join(items)}</Items>'
            '</LayoutDefinition></Mapping></Mappings></Excel></ReportDefinition>')


# --------------------------------------------------------------------------------------------- xlsx writer
def cell_xml(ref, v=None, f=None):
    if f is not None:
        val = "" if v is None else (f"<v>{v}</v>" if not isinstance(v, str) else f"<v>{escape(v)}</v>")
        t = ' t="str"' if isinstance(v, str) else ""
        return f'<c r="{ref}"{t}><f>{escape(f.lstrip("="))}</f>{val}</c>'
    if isinstance(v, str):
        return f'<c r="{ref}" t="inlineStr"><is><t>{escape(v)}</t></is></c>'
    return f'<c r="{ref}"><v>{v}</v></c>'


def sheet_xml(cells):
    rows = {}
    for ref, (v, f) in cells.items():
        r = int("".join(ch for ch in ref if ch.isdigit()))
        rows.setdefault(r, []).append(cell_xml(ref, v, f))
    body = "".join(f'<row r="{r}">{"".join(sorted(cs, key=lambda x: (len(x.split(chr(34))[1]), x)))}</row>'
                   for r, cs in sorted(rows.items()))
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            f'<sheetData>{body}</sheetData></worksheet>')


def write_xlsx(path, cells, definition=None):
    ct = ['<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
          '<Default Extension="xml" ContentType="application/xml"/>',
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
          '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>']
    if definition:
        ct.append('<Override PartName="/customXml/itemProps1.xml" ContentType="application/vnd.openxmlformats-officedocument.customXmlProperties+xml"/>')
    # ZIP_STORED: members stay plain bytes, so tools/hygiene-sweep.sh can scan them, and zlib's version never
    # reaches the output; fixed timestamps keep it byte-stable
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        def put(name, data):
            zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_STORED
            z.writestr(zi, data)
        put("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' + "".join(ct) + "</Types>")
        put("_rels/.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>')
        put("xl/workbook.xml", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="Summary" sheetId="1" r:id="rId1"/></sheets></workbook>')
        rels = ['<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>']
        if definition:
            rels.append('<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml" Target="../customXml/item1.xml"/>')
        put("xl/_rels/workbook.xml.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + "".join(rels) + "</Relationships>")
        put("xl/worksheets/sheet1.xml", sheet_xml(cells))
        if definition:
            put("customXml/item1.xml", definition.encode("utf-16"))
            put("customXml/itemProps1.xml", '<?xml version="1.0" encoding="UTF-8" standalone="no"?>'
                '<ds:datastoreItem ds:itemID="{00000000-0000-0000-0000-000000000003}" '
                'xmlns:ds="http://schemas.openxmlformats.org/officeDocument/2006/customXml"><ds:schemaRefs/></ds:datastoreItem>')
            put("customXml/_rels/item1.xml.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXmlProps" Target="itemProps1.xml"/>'
                '</Relationships>')


def layout_cells(values=None, detail=None):
    cells = {"B2": ("Location P&L summary (synthetic)", None)}
    for L, h in HEADERS.items():
        cells[f"{L}4"] = (h, None)
    for r, lab in LABELS.items():
        cells[f"B{r}"] = (lab, None)
    for r, f in SHEET_FORMULAS.items():
        for L in ("D", "E", "G"):
            cells[f"{L}{r}"] = (None if values is None else values[r][L], f.replace("D", L))
    for r in (6, 7, 8, 9, 10, 11, 12):
        cells[f"F{r}"] = (None if values is None else values[r]["F"], f"=D{r}-E{r}")
        cells[f"H{r}"] = (None if values is None else values[r]["H"], f"=IFERROR(F{r}/E{r},0)")
        if values is not None:
            for L in ("D", "E", "G"):
                cells.setdefault(f"{L}{r}", (values[r][L], None))
                if cells[f"{L}{r}"][1] is None:
                    cells[f"{L}{r}"] = (values[r][L], None)
    if detail is not None:                           # an executed run: one physical row per expanded member
        del cells["B14"]
        for i, d in enumerate(detail):
            for L in ("B", "C", "D", "E"):
                cells[f"{L}{14 + i}"] = (d[L], None)
    return cells


def main():
    rows = gl_rows()
    with open(os.path.join(HERE, "gl.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    lines, detail = oracle(rows)
    write_xlsx(os.path.join(HERE, "pnl-template.xlsx"), layout_cells(), definition_xml())
    run_vals = {r: {k: round(v, 6) for k, v in vals.items()} for r, vals in lines.items()}
    write_xlsx(os.path.join(HERE, "pnl-executed-run.xlsx"), layout_cells(run_vals, detail))
    sm = {"connectionId": "<connection-id>", "fiscal_year_start_month": 1,
          "facts": {"GL_F_Trans": {"from": "DEMO_DB.FINANCE.GL_FACT f LEFT JOIN DEMO_DB.FINANCE.DEPARTMENTS d ON d.DEPT_ID = f.DEPT_ID",
                                   "values": {"Value1": "f.AMOUNT"},
                                   "period": {"expr": "f.PERIOD_ID", "format": "yyyymm"}}},
          "attributes": {"d_Account.Code": "f.ACCOUNT_CODE", "d_Account.Description": "f.ACCOUNT_NAME",
                         "d_Scenario.Code": "f.SCENARIO", "d_dim0.Code": "f.LOCATION_CODE", "d_dim1.UDF001": "d.DEPT_GROUP"}}
    with open(os.path.join(HERE, "source-map.json"), "w") as fh:
        json.dump(sm, fh, indent=1)
        fh.write("\n")
    print(f"wrote fixtures: {len(rows)} GL rows, {len(lines)} lines, {len(detail)} expanded members")


if __name__ == "__main__":
    main()
