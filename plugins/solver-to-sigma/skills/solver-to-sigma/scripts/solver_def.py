#!/usr/bin/env python3
"""Read a Solver report definition into a plain-JSON intermediate representation (IR).

Source: the report's Live Reporting **Download** (.xlsx). Solver embeds the full report definition in the
workbook as a custom XML part (``customXml/item*.xml``, usually UTF-16) whose root element is
``ReportDefinition``. The sheets carry the layout: labels, number formats and plain-Excel formulas around the
Solver cells. A decoded definition saved as ``.xml`` is accepted too (no sheet layout then).

Stdlib only. Never reads a ``*.manifest`` file: those carry a Solver session token, not a definition.

IR shape (all keys always present)::

    {"title", "author", "engine_version", "data_sources": [{"name","integration","model_version"}],
     "parameters": [{"name","type","data_type","prompt","default","source","multi","hidden","is_period","loop","allow_blank"}],
     "sheets": [{"name", "items": [{"type","row","col","size","expand","elements":[ELEMENT]}],
                 "cells": {"E10": {"v": value, "f": formula, "fmt": number_format}}}]}
    ELEMENT = {"kind": "SelectionElement"|"ReferenceElement", "row", "col",
               "filters": [{"group": name, "exprs": [{"dim","field","op","cond","logic"}]}],
               "results": [{"dim","name","aggregation"}], "formula": text|None}
"""
import json
import re
import sys
import zipfile
import xml.etree.ElementTree as ET  # nosemgrep: python.lang.security.use-defused-xml.use-defused-xml

XSI_TYPE = "{http://www.w3.org/2001/XMLSchema-instance}type"
MAIN_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PKG_REL_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}"


class NotADefinition(Exception):
    """The file holds no Solver ReportDefinition (or is a credential we refuse to read)."""


def _tag(e):
    return e.tag.split("}")[-1]


def _decode(raw):
    """Custom XML parts are usually UTF-16 with a BOM; tolerate UTF-8 too."""
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    if raw[:3] == b"\xef\xbb\xbf":
        return raw[3:].decode("utf-8")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-16")


def _strip_decl(text):
    # ElementTree refuses a str that still declares a non-UTF-8 encoding
    return re.sub(r"^\s*<\?xml[^>]*\?>", "", text, count=1)


def refuse_credentials(path):
    if str(path).lower().endswith(".manifest"):
        raise NotADefinition(
            f"{path}: a Solver .manifest holds a session AuthenticationToken, not a report definition. "
            "Do not open, copy or log it; ask the sender to delete it and send the Live Reporting Download (.xlsx).")


def definition_root_from_xlsx(path):
    with zipfile.ZipFile(path) as z:
        for name in sorted(n for n in z.namelist() if n.lower().startswith("customxml/item") and n.lower().endswith(".xml")
                           and "props" not in n.lower()):
            text = _strip_decl(_decode(z.read(name)))
            try:
                root = ET.fromstring(text)
            except ET.ParseError:
                continue
            if _tag(root) == "ReportDefinition":
                return root
    raise NotADefinition(f"{path}: no customXml part with a ReportDefinition root. Is this the Live Reporting Download, "
                         "not a plain Excel export of a run?")


# ---------------------------------------------------------------------------------------------- sheet layout
def _col_letters(ref):
    m = re.match(r"\$?([A-Z]+)\$?(\d+)$", ref)
    return (m.group(1), int(m.group(2))) if m else (None, None)


def col_to_num(letters):
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n


def num_to_col(n):
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


REF_RX = re.compile(r"(?<![A-Za-z0-9_.])(\$?)([A-Z]{1,3})(\$?)(\d+)(?![A-Za-z0-9_(])")


def shift_formula(f, dr, dc):
    """Move a formula's relative A1 references by (dr rows, dc columns), as Excel does when filling down or
    across; $-anchored parts and string literals are left alone."""
    def sh(m):
        c = m.group(2) if m.group(1) else num_to_col(col_to_num(m.group(2)) + dc)
        r = m.group(4) if m.group(3) else str(int(m.group(4)) + dr)
        return f"{m.group(1)}{c}{m.group(3)}{r}"
    parts = re.split(r'("[^"]*")', f)
    return "".join(p if i % 2 else REF_RX.sub(sh, p) for i, p in enumerate(parts))


def _cells_in(rng):
    a, _, b = rng.replace("$", "").partition(":")
    (ca, ra), (cb, rb) = _col_letters(a), _col_letters(b or a)
    return [(num_to_col(c), r) for c in range(col_to_num(ca), col_to_num(cb) + 1) for r in range(ra, rb + 1)]


def read_xlsx_cells(path):
    """{sheet name: {"A1": {"v": value, "f": formula or None, "fmt": format or None}}} — values, formulas, formats."""
    out = {}
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        shared = []
        if "xl/sharedStrings.xml" in names:
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")).iter(MAIN_NS + "si"):
                shared.append("".join(t.text or "" for t in si.iter(MAIN_NS + "t")))
        fmts, xf_fmt = {}, []
        if "xl/styles.xml" in names:
            st = ET.fromstring(z.read("xl/styles.xml"))
            nf = st.find(MAIN_NS + "numFmts")
            for f in (nf if nf is not None else []):
                fmts[f.attrib.get("numFmtId")] = f.attrib.get("formatCode")
            cx = st.find(MAIN_NS + "cellXfs")
            for xf in (cx if cx is not None else []):
                xf_fmt.append(fmts.get(xf.attrib.get("numFmtId")))
        wb = ET.fromstring(z.read("xl/workbook.xml"))
        rels = {}
        if "xl/_rels/workbook.xml.rels" in names:
            for r in ET.fromstring(z.read("xl/_rels/workbook.xml.rels")).iter(PKG_REL_NS + "Relationship"):
                rels[r.attrib["Id"]] = r.attrib["Target"]
        for sh in wb.iter(MAIN_NS + "sheet"):
            target = rels.get(sh.attrib.get(REL_NS + "id"), "")
            target = target.lstrip("/")
            part = target if target.startswith("xl/") else "xl/" + target
            if part not in names:
                continue
            raw = list(ET.fromstring(z.read(part)).iter(MAIN_NS + "c"))
            masters, arrays = {}, []
            for c in raw:                                       # pass 1: shared-formula masters, array formulas
                f = c.find(MAIN_NS + "f")
                if f is not None and f.text:
                    if f.attrib.get("t") == "shared" and f.attrib.get("si") is not None:
                        masters[f.attrib["si"]] = (c.attrib.get("r"), f.text)
                    elif f.attrib.get("t") == "array" and ":" in (f.attrib.get("ref") or ""):
                        arrays.append(f.attrib["ref"])
            cells = {}
            for c in raw:
                ref, t = c.attrib.get("r"), c.attrib.get("t")
                v, f = c.find(MAIN_NS + "v"), c.find(MAIN_NS + "f")
                val = None
                if t == "s" and v is not None:
                    val = shared[int(v.text)]
                elif t == "inlineStr":
                    val = "".join(x.text or "" for x in c.iter(MAIN_NS + "t"))
                elif t in ("str", "e") and v is not None:
                    val = v.text
                elif t == "b" and v is not None:
                    val = v.text == "1"
                elif v is not None and v.text is not None:
                    try:
                        val = float(v.text)
                        if val.is_integer():
                            val = int(val)
                    except ValueError:
                        val = v.text
                s = c.attrib.get("s")
                fmt = xf_fmt[int(s)] if s is not None and int(s) < len(xf_fmt) else None
                ftxt = ("=" + f.text) if (f is not None and f.text) else None
                if f is not None and not f.text and f.attrib.get("t") == "shared":
                    # a filled-down formula: Excel stores the text once, on the master; children carry only si
                    m = masters.get(f.attrib.get("si"))
                    if m:
                        (mc, mr), (cc, cr) = _col_letters(m[0]), _col_letters(ref)
                        ftxt = "=" + shift_formula(m[1], cr - mr, col_to_num(cc) - col_to_num(mc))
                    else:
                        ftxt = "=UNRESOLVED_SHARED_FORMULA()"         # compiles to a gap, never to the cached value
                if val is None and ftxt is None:
                    continue
                cells[ref] = {"v": val, "f": ftxt, "fmt": fmt}
            for rng in arrays:                                  # a multi-cell array formula is not translated
                for col, row in _cells_in(rng):
                    if f"{col}{row}" in cells:
                        cells[f"{col}{row}"]["f"] = "=UNRESOLVED_ARRAY_FORMULA()"
            out[sh.attrib.get("name")] = cells
    return out


# ---------------------------------------------------------------------------------------------- definition
def _filters(el):
    out = []
    for fg in el.iter("FilterGroup"):
        exprs = [{"dim": e.attrib.get("DimensionName", ""), "field": e.attrib.get("Name", ""),
                  "op": e.attrib.get("Operator", "In"), "cond": e.attrib.get("Condition", ""),
                  "logic": e.attrib.get("LogicalOperator")} for e in fg.iter("Expression")]
        if exprs:
            out.append({"group": fg.attrib.get("Name") or exprs[0]["dim"], "exprs": exprs})
    return out


def _int(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None


def parse_definition(root):
    h = root.find("Header")
    g = lambda p: (h.findtext(p) if h is not None else None)
    params = []
    for p in (h.iter("ReportParameter") if h is not None else []):
        d, s = p.find("Default"), p.find("Source")
        params.append({"name": p.attrib.get("Name"), "type": p.attrib.get("ParameterType"),
                       "data_type": p.attrib.get("DataType"), "prompt": p.attrib.get("Prompt"),
                       "default": (d.text if d is not None else None), "source": (s.attrib.get("Attribute") if s is not None else None),
                       "multi": p.attrib.get("MultiSelection") == "true", "hidden": p.attrib.get("Hidden") == "true",
                       "is_period": p.attrib.get("IsPeriod") == "true", "loop": p.attrib.get("Loop"),
                       "allow_blank": p.attrib.get("AllowBlank") == "true"})
    sources = [{"name": d.attrib.get("Name"), "integration": d.attrib.get("Integration"),
                "model_version": d.attrib.get("ModelVersion")} for d in (h.iter("DataSource") if h is not None else [])]
    sheets = []
    for ex in root.findall("Excel"):
        items = []
        holder = ex.find("Mappings/Mapping/LayoutDefinition/Items")
        for it in (holder if holder is not None else []):
            f = it.find("Formula")
            els = []
            for de in it.iter("DefinitionElement"):
                els.append({"kind": de.attrib.get(XSI_TYPE, "SelectionElement"),
                            "row": _int(de.attrib.get("Row")), "col": _int(de.attrib.get("Column")),
                            "filters": _filters(de),
                            "results": [{"dim": r.attrib.get("DimensionName"), "name": r.attrib.get("Name"),
                                         "aggregation": r.attrib.get("Aggregation")} for r in de.iter("ResultAttribute")]})
            items.append({"type": it.attrib.get("Type"), "row": _int(it.attrib.get("Row")), "col": _int(it.attrib.get("Column")),
                          "size": _int(it.attrib.get("Size")), "expand": it.attrib.get("Expand") == "true",
                          "formula": (f.text.strip() if f is not None and f.text else None), "elements": els})
        sheets.append({"name": ex.attrib.get("Sheet"), "items": items, "cells": {}})
    return {"title": g("Title"), "author": g("Author"), "engine_version": g("EngineVersion"),
            "data_sources": sources, "parameters": params, "sheets": sheets}


def load(path, with_cells=True):
    """IR from a Download .xlsx (definition + sheet layout) or a decoded definition .xml."""
    refuse_credentials(path)
    p = str(path).lower()
    if p.endswith(".xml"):
        with open(path, "rb") as fh:
            root = ET.fromstring(_strip_decl(_decode(fh.read())))
        if _tag(root) != "ReportDefinition":
            raise NotADefinition(f"{path}: root is <{_tag(root)}>, not <ReportDefinition>")
        return parse_definition(root)
    ir = parse_definition(definition_root_from_xlsx(path))
    if with_cells:
        cells = read_xlsx_cells(path)
        for sh in ir["sheets"]:
            sh["cells"] = cells.get(sh["name"], {})
    return ir


def run_values(path):
    """Values of an EXECUTED run export (same layout, numbers filled in): {sheet: {"E10": number}}."""
    refuse_credentials(path)
    return {s: {r: c["v"] for r, c in cells.items() if isinstance(c["v"], (int, float)) and not isinstance(c["v"], bool)}
            for s, cells in read_xlsx_cells(path).items()}


if __name__ == "__main__":
    json.dump(load(sys.argv[1]), sys.stdout, indent=1, default=str)
