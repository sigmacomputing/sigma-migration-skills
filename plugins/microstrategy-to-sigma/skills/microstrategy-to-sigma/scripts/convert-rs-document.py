#!/usr/bin/env python3
"""
convert-rs-document.py — MicroStrategy Report Services document -> Sigma Report.

Input is an `mstr-rs-document/1` JSON definition (contract: refs/rs-document-reports.md):
page setup, one dataset bound to a warehouse table, an optional grouping, and the
document's sections (page header, group header, detail header, detail, detail
footer, ...) with every layout control's position in inches. The public
MicroStrategy REST API does not expose Report Services layout, so today this file
is hand-built from the source document (see fixtures/rs-documents/).

Output is the `POST /v2/reports` request body ({name, folderId, contents}) —
the current, non-deprecated create endpoint; add "dryRun": true to verify it.

  - Geometry: inches -> px at 96 dpi (Letter = 816 x 1056); points -> px at 96/72.
    MicroStrategy positions are relative to the section inside the page margins;
    Sigma layout coordinates are page-absolute, so body x = margin + Left and body
    y = margin + header panel + section offset + Top. Panel children are local to
    the panel (y = Top) and offset by the left margin.
  - Page Header / Page Footer -> report header / footer panels.
  - Detail Header + Detail -> one paginated `table` (flow="paginated"): a column per
    Detail data field ordered by Left, named by the Detail Header label it is
    left-aligned with. A Detail Header band (rectangle) becomes the column-header
    background.
  - Grouping with "page break between groups" -> INVOICE mode: the page is one
    group's document, driven by a single-select list control on a hidden page;
    group-header / footer data fields become positioned text over the selected
    group ({{First([...])}} for attributes, {{Sum([...]) | fmt}} for metrics).
    Delivering one PDF per group value is a Sigma schedule over that control (not
    part of report contents). Grouping without page breaks -> BANDED mode: table
    groupings + calculations; free-form group furniture becomes a layout gap.
  - Every construct resolves through refs/catalogs/document-control.json (plus the
    shared number-format / aggregation catalogs); an unmapped construct is a
    BLOCKING gap in feature-gaps.json, never a silent approximation.

Usage:
  python3 scripts/convert-rs-document.py --document doc.rs-document.json \
      --connection-id <uuid> [--folder-id <uuid>] [--name "..."] \
      [--detail-rows 10] [--image-url logo=https://...] \
      [--out sigma_report_spec.json] [--gaps-out feature-gaps.json] \
      [--map-out control-map.json] [--allow-gaps]

Exit 0 = no blocking gaps; 2 = blocking gaps (outputs still written for review;
pass --allow-gaps to exit 0); 1 = invalid input.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import coverage_catalog as _cc  # noqa: E402

_CAT_DIR = _cc.default_catalog_dir(__file__)
DOC_CAT = _cc.load(_CAT_DIR, "document-control")  # RS control/section/line/auto-text -> Sigma
FMT_CAT = _cc.load(_CAT_DIR, "number-format")     # MSTR format category -> d3 format
AGG_CAT = _cc.load(_CAT_DIR, "aggregation")       # MSTR group function -> Sigma aggregate

FORMAT_ID = "mstr-rs-document/1"
PX_PER_IN = 96.0           # CSS reference pixel; Sigma's Letter default is 816 x 1056
PX_PER_PT = 96.0 / 72.0
THIN_RECT_IN = 0.1         # a rectangle no taller than this prints as a rule
LABEL_ALIGN_IN = 0.15      # Detail Header label <-> Detail field Left tolerance
SAME_ROW_IN = 0.05         # footer label <-> value Top tolerance (banded mode)
MIN_LINE_PX = 24           # Sigma Report text clips below a 24px line box at any font size
                           # (live export evidence: cognos-to-sigma refs/print-reports.md)
TOKEN_RE = re.compile(r"\{(&[A-Za-z]+|\[[^\]{}]+\]|[^{}\[\]@&][^{}@]*?)(?:@([A-Za-z]+))?\}")
BODY_ORDER = ["document-header", "group-header", "detail-header", "detail",
              "detail-footer", "group-footer", "document-footer"]


class InputError(Exception):
    pass


def px(inches):
    return int(round(float(inches) * PX_PER_IN))


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", str(s).lower()).strip("-") or "x"


def display_name(column):
    """Sigma's display name for a warehouse column (CUSTOMER_NAME -> Customer Name)."""
    return " ".join(w[:1].upper() + w[1:].lower() for w in str(column).split("_") if w)


def field_label(key):
    """MicroStrategy field key -> human column name (Customer@ID -> Customer ID)."""
    name, _, form = key.partition("@")
    return "%s %s" % (name, form.upper()) if form else name


def field_key(name, form):
    name = name[1:-1] if name.startswith("[") and name.endswith("]") else name
    form = (form or "").upper()
    return name if form in ("", "DESC") else "%s@%s" % (name, form)


def parse_text(text):
    """Split a text field into ('lit', s) / ('field', key) / ('auto', code) runs."""
    out, pos = [], 0
    for m in TOKEN_RE.finditer(text or ""):
        if m.start() > pos:
            out.append(("lit", text[pos:m.start()]))
        tok = m.group(1)
        if tok.startswith("&"):
            out.append(("auto", tok.lower()))
        else:
            out.append(("field", field_key(tok.strip(), m.group(2))))
        pos = m.end()
    if pos < len(text or ""):
        out.append(("lit", text[pos:]))
    return out


def md_escape(s):
    s = re.sub(r"([\\*_\[\]<>`])", r"\\\1", s)
    return s.replace("{{", "{\\{")


class Converter:
    def __init__(self, doc, args):
        self.doc, self.args = doc, args
        self.gaps, self.warnings, self.cmap = [], [], []
        self.elements, self.ids = [], set()
        self.page_lines, self.panel_lines, self.hidden_lines = [], [], []
        self.panels = []
        self.image_urls = dict(kv.split("=", 1) for kv in (args.image_url or []))
        self._validate()
        page = doc["page"]
        m = page.get("margin_in") or {}
        margins = {k: float(m.get(k, 0.5)) for k in ("top", "bottom", "left", "right")}
        if len(set(margins.values())) > 1:
            self.gap(None, "page", "uneven page margins", "layout",
                     "Sigma Reports take one margin; using the left margin %.2f in for all sides" % margins["left"])
        self.W, self.H = px(page["width_in"]), px(page["height_in"])
        self.M = px(margins["left"])
        self.CW = self.W - 2 * self.M
        self.defaults = doc.get("defaults") or {}
        ds = doc["dataset"]
        self.ds = ds
        self.fields = ds["fields"]
        self.table_name = ds["name"]
        self.src_table = ds["source"]["path"][-1]
        self.sections = {s["kind"]: s for s in doc["sections"]}
        self.grouping = doc.get("grouping") or []
        self.mode = "invoice" if self.grouping and self.grouping[0].get("page_break_between_groups") else (
            "banded" if self.grouping else "flat")
        self.columns = {}       # field key -> column dict (insertion = order)
        self.col_names = set()

    # ---------------------------------------------------------------- helpers
    def _validate(self):
        d = self.doc
        if d.get("format") != FORMAT_ID:
            raise InputError("expected format %r, got %r" % (FORMAT_ID, d.get("format")))
        for k in ("document", "page", "dataset", "sections"):
            if k not in d:
                raise InputError("missing top-level %r" % k)
        src = d["dataset"].get("source") or {}
        if src.get("kind") != "warehouse-table" or not src.get("path"):
            raise InputError("dataset.source must be a warehouse-table with a path (got %r)" % src.get("kind"))
        kinds = [s.get("kind") for s in d["sections"]]
        unknown = [k for k in kinds if k not in BODY_ORDER + ["page-header", "page-footer"]]
        if unknown:
            raise InputError("unknown section kind(s): %s" % ", ".join(unknown))
        if len(kinds) != len(set(kinds)):
            raise InputError("each section kind may appear once (got %s)" % kinds)

    def gap(self, control, section, construct, severity, detail):
        self.gaps.append({"control": control, "section": section, "construct": construct,
                          "severity": severity, "detail": detail})

    def catalog(self, key, control=None, section=None):
        row = DOC_CAT.resolve(key)
        if row is None:
            self.gap(control, section, key, "blocking",
                     "no documented mapping in refs/catalogs/document-control.json; nothing emitted")
        return row

    def new_id(self, base):
        eid, n = "rs-" + slug(base), 2
        while eid in self.ids:
            eid, n = "rs-%s-%d" % (slug(base), n), n + 1
        self.ids.add(eid)
        return eid

    def place(self, lines, eid, x, y, w, h, bound_w, bound_h, ctl=None, section=None, root=None, flow=False):
        x, y, w, h = int(round(x)), int(round(y)), max(1, int(round(w))), max(1, int(round(h)))
        if x + w > bound_w or y + h > bound_h or x < 0 or y < 0:
            self.gap(ctl, section, "out of bounds", "layout",
                     "%s at (%d,%d %dx%d) exceeds its %dx%d %s; clamped" % (eid, x, y, w, h, bound_w, bound_h, root))
            x, y = max(0, min(x, bound_w - 1)), max(0, min(y, bound_h - 1))
            w, h = min(w, bound_w - x), min(h, bound_h - y)
        lines.append('  <Element elementId="%s" x="%d" y="%d" width="%d" height="%d"%s/>'
                     % (eid, x, y, w, h, ' flow="paginated"' if flow else ""))
        self.cmap.append({"source_control": ctl, "section": section, "sigma_element": eid, "root": root,
                          "bbox_px": {"x": x, "y": y, "width": w, "height": h}})

    def font_px(self, fmt):
        pt = (fmt or {}).get("font_size_pt") or self.defaults.get("font_size_pt")
        return int(round(float(pt) * PX_PER_PT)) if pt else None

    def number_format(self, fmt, fkey, ctl, section):
        """d3 format string for a numeric field: the control's explicit MSTR format,
        else the field's; none = unformatted (never guessed from the name)."""
        num = (fmt or {}).get("number") or (self.fields.get(fkey) or {}).get("number")
        if not num:
            return None
        row = FMT_CAT.resolve_or_warn(str(num.get("category", "")).lower(), self.warnings,
                                      context="%s/%s" % (section, ctl))
        return row.get("sigma") if row else None

    # ---------------------------------------------------------------- columns
    def column(self, fkey, ctl=None, section=None, name=None, hidden=True):
        f = self.fields.get(fkey)
        if f is None:
            self.gap(ctl, section, "field %s" % fkey, "blocking",
                     "field is not in dataset.fields; add its warehouse column binding")
            return None
        col = self.columns.get(fkey)
        if col is None:
            cname = name or field_label(fkey)
            base, n = cname, 2
            while cname in self.col_names:
                cname, n = "%s (%d)" % (base, n), n + 1
            self.col_names.add(cname)
            col = {"id": "col-" + slug(fkey), "formula": "[%s/%s]" % (self.src_table, display_name(f["column"])),
                   "name": cname}
            if f.get("type") == "date" and f.get("date_format"):
                col["format"] = {"kind": "datetime", "formatString": f["date_format"]}
            col["hidden"] = hidden
            self.columns[fkey] = col
        elif not hidden:
            col["hidden"] = False
        return col

    def value_expr(self, fkey, fmt, ctl, section):
        """A text-field token -> a {{...}} formula over the detail table."""
        col = self.column(fkey, ctl, section)
        if col is None:
            return None
        f = self.fields[fkey]
        ref = "[%s/%s]" % (self.table_name, col["name"])
        if f.get("role") == "metric":
            agg_row = AGG_CAT.resolve_or_warn(f.get("aggregation", "Sum"), self.warnings,
                                              context="metric %s" % fkey)
            if not agg_row:
                self.gap(ctl, section, "aggregation %s" % f.get("aggregation"), "blocking",
                         "metric aggregation has no documented Sigma equivalent")
                return None
            expr, fstr = "%s(%s)" % (agg_row["sigma"], ref), self.number_format(fmt, fkey, ctl, section)
        else:
            expr = "First(%s)" % ref
            fstr = f.get("date_format") if f.get("type") == "date" else None
            if self.mode == "invoice" and fkey != self.group_field and fkey not in self.dependent:
                self.gap(ctl, section, "group-level attribute %s" % fkey, "review",
                         "not declared functionally dependent on %s; rendered as First() over the "
                         "selected group's rows in the table sort order" % self.group_field)
        return "{{%s%s}}" % (expr, " | " + fstr if fstr else "")

    # ------------------------------------------------------------------ text
    def text_body(self, c, section):
        fmt = c.get("format") or {}
        lines_out = []
        for line in (c.get("text") or "").split("\n"):
            parts = []
            for kind, val in parse_text(line):
                if kind == "lit":
                    parts.append(md_escape(val))
                elif kind == "field":
                    v = self.value_expr(val, fmt, c["id"], section)
                    if v is None:
                        return None
                    parts.append(v)
                else:
                    row = self.catalog("autotext:" + val, c["id"], section)
                    if row is None:
                        return None
                    parts.append(row["sigma"])
            s = "".join(parts)
            if not s.strip():
                lines_out.append(s)
                continue
            if fmt.get("bold") and fmt.get("italic"):
                s = "***%s***" % s
            elif fmt.get("bold"):
                s = "**%s**" % s
            elif fmt.get("italic"):
                s = "*%s*" % s
            style = []
            fp = self.font_px(fmt)
            if fp:
                style.append("font-size: %dpx" % fp)
            fam = fmt.get("font_family") or self.defaults.get("font_family")
            if fam:
                style.append("font-family: %s" % fam)
            if fmt.get("color"):
                style.append("color: %s" % fmt["color"])
            if fmt.get("backcolor"):
                style.append("background-color: %s" % fmt["backcolor"])
            if style:
                s = '<span style="%s">%s</span>' % ("; ".join(style), s)
            lines_out.append(s)
        body = "\\\n".join(lines_out)
        align = fmt.get("align")
        if align in ("center", "right"):
            body = '<p style="text-align: %s">%s</p>' % (align, body)
        return body

    # -------------------------------------------------------------- controls
    def emit_free(self, c, section, lines, ox, oy, bound_w, bound_h, root, sec_bottom):
        """A free-positioned control (panel, document/group section, invoice footer).
        sec_bottom is the y where the control's section ends in the same coordinates."""
        ctype = c.get("type")
        if self.catalog("control:" + str(ctype), c["id"], section) is None:
            return
        x = ox + px(c.get("left_in", 0))
        y = oy + px(c.get("top_in", 0))
        full = c.get("width_mode") == "100%"
        w = (self.CW - px(c.get("left_in", 0))) if full else px(c.get("width_in", 1))
        h = px(c.get("height_in", 0.17))
        if ctype == "text":
            body = self.text_body(c, section)
            if body is None:
                return
            eid = self.new_id(c["id"])
            self.elements.append({"id": eid, "kind": "text", "body": body})
            need = MIN_LINE_PX * len((c.get("text") or "").split("\n"))
            if h < need:
                h = need
                if y + h > sec_bottom:
                    self.gap(c["id"], section, "text taller than its section", "layout",
                             "grown to %dpx for Sigma's %dpx minimum line box, it runs %dpx past the "
                             "end of %s; check the export for overlap" % (h, MIN_LINE_PX, y + h - sec_bottom,
                                                                          section))
            self.place(lines, eid, x, y, w, h, bound_w, bound_h, c["id"], section, root)
        elif ctype == "image":
            img = c.get("image") or {}
            url = self.image_urls.get(c["id"]) or img.get("url")
            if not url:
                self.gap(c["id"], section, "image without a URL", "layout",
                         "no image URL in the definition; pass --image-url %s=https://... to place it" % c["id"])
                return
            eid = self.new_id(c["id"])
            el = {"id": eid, "kind": "image", "source": {"kind": "url", "url": url},
                  "style": {"fit": "contain", "horizontalAlign": "left", "verticalAlign": "top"}}
            if img.get("alt"):
                el["alt"] = img["alt"]
            self.elements.append(el)
            self.place(lines, eid, x, y, w, h, bound_w, bound_h, c["id"], section, root)
        elif ctype == "line":
            ln = c.get("line") or {}
            style = str(ln.get("style", "solid")).lower()
            row = self.catalog("line-style:" + style, c["id"], section)
            if row is None:
                return
            if style == "double":
                self.gap(c["id"], section, "double line", "layout",
                         "Sigma dividers have no double stroke; emitted %s" % row["sigma"])
            weight = max(1, int(round(float(ln.get("weight", 1)) * PX_PER_PT)))
            eid = self.new_id(c["id"])
            self.elements.append({"id": eid, "kind": "divider", "direction": "horizontal",
                                  "style": {"width": weight, "strokeStyle": row["sigma"],
                                            "color": ln.get("color") or "#000000"}})
            box = max(4, weight + 2)
            self.place(lines, eid, x, max(0, y - box // 2), w, box, bound_w, bound_h, c["id"], section, root)
        elif ctype == "rectangle":
            if float(c.get("height_in", 1)) <= THIN_RECT_IN:
                eid = self.new_id(c["id"])
                color = (c.get("format") or {}).get("backcolor") or "#000000"
                self.elements.append({"id": eid, "kind": "divider", "direction": "horizontal",
                                      "style": {"width": max(1, h), "strokeStyle": "solid", "color": color}})
                self.place(lines, eid, x, y, w, max(4, h), bound_w, bound_h, c["id"], section, root)
            else:
                self.gap(c["id"], section, "rectangle", "layout",
                         "Sigma Reports have no rectangle element; this band is not reproduced")

    # ----------------------------------------------------------------- table
    def detail_columns(self, detail, header):
        labels = [c for c in (header or {}).get("controls", []) if c.get("type") == "text"
                  and not any(k == "field" for k, _ in parse_text(c.get("text", "")))]
        used, ordered = set(), []
        for c in sorted(detail.get("controls", []), key=lambda c: float(c.get("left_in", 0))):
            if self.catalog("control:" + str(c.get("type")), c["id"], "detail") is None:
                continue
            if c.get("type") != "text":
                self.gap(c["id"], "detail", "detail %s" % c.get("type"), "layout",
                         "only data fields repeat per detail row in a Sigma table; not reproduced")
                continue
            runs = [r for r in parse_text(c.get("text", "")) if not (r[0] == "lit" and not r[1].strip())]
            if len(runs) != 1 or runs[0][0] != "field":
                self.gap(c["id"], "detail", "composite detail text", "blocking",
                         "a detail control must be a single data field; %r has literals or several fields"
                         % c.get("text"))
                continue
            fkey = runs[0][1]
            left = float(c.get("left_in", 0))
            match = min((l for l in labels if l["id"] not in used
                         and abs(float(l.get("left_in", 0)) - left) <= LABEL_ALIGN_IN),
                        key=lambda l: abs(float(l.get("left_in", 0)) - left), default=None)
            name = match["text"].strip() if match else None
            if match:
                used.add(match["id"])
            else:
                self.warnings.append("detail field %s has no Detail Header label within %.2f in; named %r"
                                     % (fkey, LABEL_ALIGN_IN, field_label(fkey)))
            col = self.column(fkey, c["id"], "detail", name=name, hidden=False)
            if col is None:
                continue
            fstr = self.number_format(c.get("format"), fkey, c["id"], "detail")
            if fstr:
                col["format"] = {"kind": "number", "formatString": fstr}
            ordered.append(col["id"])
            self.cmap.append({"source_control": c["id"], "section": "detail", "sigma_element": "rs-detail",
                              "root": "column", "column_id": col["id"]})
        for l in labels:
            if l["id"] not in used:
                self.gap(l["id"], "detail-header", "unmatched column label", "layout",
                         "Detail Header label %r is not left-aligned with any Detail field" % l.get("text"))
            else:
                self.cmap.append({"source_control": l["id"], "section": "detail-header",
                                  "sigma_element": "rs-detail", "root": "column header"})
        return ordered, labels

    def table_style(self, header, labels):
        band = next((c for c in (header or {}).get("controls", []) if c.get("type") == "rectangle"), None)
        th = {}
        if band:
            self.catalog("control:rectangle", band["id"], "detail-header")
            bg = (band.get("format") or {}).get("backcolor")
            if bg:
                th["backgroundColor"] = bg
            self.cmap.append({"source_control": band["id"], "section": "detail-header",
                              "sigma_element": "rs-detail", "root": "column header background"})
        if labels:
            lf = labels[0].get("format") or {}
            if all((l.get("format") or {}).get("bold") for l in labels):
                th["fontWeight"] = "bold"
            fp = self.font_px(lf)
            if fp:
                th["fontSize"] = fp
            if self.defaults.get("font_family"):
                th["font"] = self.defaults["font_family"]
        cell = {}
        if self.font_px(None):
            cell["fontSize"] = self.font_px(None)
        if self.defaults.get("font_family"):
            cell["font"] = self.defaults["font_family"]
        style = {"preset": "presentation", "gridLines": "none", "banding": "hidden", "outerBorder": "hidden"}
        ts = {}
        if th:
            ts["columnHeader"] = th
        if cell:
            ts["cell"] = cell
        if ts:
            style["textStyles"] = ts
        return style

    def filters(self):
        out = []
        for f in self.ds.get("filters") or []:
            col = self.column(f["field"], None, "dataset")
            if col is None:
                continue
            fid = "flt-" + slug(f["field"])
            if f["kind"] == "list":
                out.append({"id": fid, "columnId": col["id"], "kind": "list", "mode": "include",
                            "values": list(f["values"])})
            elif f["kind"] == "date-range":
                out.append({"id": fid, "columnId": col["id"], "kind": "date-range", "mode": "between",
                            "startDate": f["start"] + "T00:00:00Z", "endDate": f["end"] + "T23:59:59Z"})
            else:
                self.gap(None, "dataset", "filter kind %s" % f["kind"], "blocking",
                         "dataset filter %r has no converter mapping; rows would differ"
                         % f.get("source_expression", f["kind"]))
        return out

    def sort(self):
        out = []
        # A grouped (banded) table rejects a base-level sort on its grouping key
        # ("Sort column not in level", live dryRun 2026-10-29); groups order themselves.
        if self.grouping and self.mode == "invoice":
            col = self.column(self.group_field, None, "grouping")
            if col:
                out.append({"columnId": col["id"], "direction": self.grouping[0].get("sort", "ascending")})
        for s in self.ds.get("sort") or []:
            col = self.column(s["field"], None, "dataset")
            if col and all(o["columnId"] != col["id"] for o in out):
                out.append({"columnId": col["id"], "direction": s.get("direction", "ascending")})
        return out

    # ------------------------------------------------------------ banded mode
    def banded_groupings(self, table):
        gh, gf = self.sections.get("group-header"), self.sections.get("group-footer")
        df = self.sections.get("detail-footer")
        keys = [self.column(self.group_field, None, "grouping")["id"]]
        calcs = []
        for sec in (gh, df, gf):
            if not sec:
                continue
            labels = [c for c in sec.get("controls", []) if c.get("type") == "text"
                      and not any(k == "field" for k, _ in parse_text(c.get("text", "")))]
            for c in sec.get("controls", []):
                fields = [v for k, v in parse_text(c.get("text", "")) if k == "field"] if c.get("type") == "text" else []
                if not fields:
                    self.gap(c["id"], sec["kind"], "group furniture (%s)" % c.get("type"), "layout",
                             "banded mode renders group sections as table group rows; free-form "
                             "controls are not reproduced")
                    continue
                for fkey in fields:
                    f = self.fields.get(fkey)
                    if f is None:
                        self.column(fkey, c["id"], sec["kind"])
                        continue
                    if f.get("role") == "metric":
                        agg = AGG_CAT.resolve_or_warn(f.get("aggregation", "Sum"), self.warnings)
                        base = self.column(fkey, c["id"], sec["kind"])
                        lab = min((l for l in labels if abs(float(l.get("top_in", 0)) - float(c.get("top_in", 0)))
                                   <= SAME_ROW_IN and float(l.get("left_in", 0)) < float(c.get("left_in", 0))),
                                  key=lambda l: float(c.get("left_in", 0)) - float(l.get("left_in", 0)), default=None)
                        cname = lab["text"].strip() if lab else "%s of %s" % (agg["sigma"], base["name"])
                        cid = "calc-" + slug(c["id"])
                        calc = {"id": cid, "formula": "%s([%s])" % (agg["sigma"], base["name"]), "name": cname}
                        fstr = self.number_format(c.get("format"), fkey, c["id"], sec["kind"])
                        if fstr:
                            calc["format"] = {"kind": "number", "formatString": fstr}
                        table["columns"].append(calc)
                        calcs.append(cid)
                    elif fkey != self.group_field:
                        if fkey in self.dependent:
                            keys.append(self.column(fkey, c["id"], sec["kind"])["id"])
                            self.columns[fkey]["hidden"] = False
                        else:
                            self.gap(c["id"], sec["kind"], "group-level attribute %s" % fkey, "review",
                                     "not declared functionally dependent on %s; omitted from banded "
                                     "grouping to preserve its grain" % self.group_field)
        return [{"id": "grp-" + slug(self.group_field), "groupBy": list(dict.fromkeys(keys)),
                 "calculations": calcs}]

    # ------------------------------------------------------------------- run
    def run(self):
        if len(self.grouping) > 1:
            self.gap(None, "grouping", "nested grouping", "blocking",
                     "%d grouping levels; this converter handles one" % len(self.grouping))
        self.group_field = self.grouping[0]["field"] if self.grouping else None
        self.dependent = set((self.grouping[0].get("functionally_dependent") or []) if self.grouping else [])
        body_id, params_id = "rs-page-" + slug(self.doc["document"]["id"]), "rs-page-parameters"
        detail, dh = self.sections.get("detail"), self.sections.get("detail-header")
        if not detail:
            raise InputError("a document needs a detail section to drive the data table")
        for kind in self.sections:
            self.catalog("section:" + kind, None, kind)

        # panels
        hdr_h = ftr_h = 0
        for kind, ptype in (("page-header", "header"), ("page-footer", "footer")):
            sec = self.sections.get(kind)
            if not sec:
                continue
            pid, ph = "rs-panel-" + ptype, px(sec["height_in"])
            self.panels.append({"id": pid, "type": ptype, "title": "%s %s" % (self.doc["document"]["name"], ptype),
                                "pages": [body_id], "config": {"height": ph}})
            lines = []
            for c in sec.get("controls", []):
                self.emit_free(c, kind, lines, self.M, 0, self.W, ph, pid, ph)
            self.panel_lines.append('<Panel id="%s" type="%s">\n%s\n</Panel>' % (pid, ptype, "\n".join(lines))
                                    if lines else '<Panel id="%s" type="%s"/>' % (pid, ptype))
            hdr_h, ftr_h = (ph, ftr_h) if ptype == "header" else (hdr_h, ph)

        # detail table
        table = {"id": "rs-detail", "kind": "table", "name": self.table_name,
                 "source": {"kind": "warehouse-table", "connectionId": self.args.connection_id,
                            "path": list(self.ds["source"]["path"])},
                 "columns": []}
        self.ids.add("rs-detail")
        order, labels = self.detail_columns(detail, dh)

        # body sections, top to bottom
        y = self.M + hdr_h
        bottom = self.H - self.M - ftr_h
        detail_anchor = "detail-header" if dh else "detail"
        for kind in BODY_ORDER:
            if kind == detail_anchor:
                rows = self.args.detail_rows
                th = (px(dh["height_in"]) if dh else 0) + rows * px(detail["height_in"])
                self.place(self.page_lines, "rs-detail", self.M, y, self.CW, th, self.W, self.H,
                           None, "detail", body_id, flow=True)
                self.gap(None, "detail", "fixed detail box", "layout",
                         "the detail table gets a %d-row box (--detail-rows); content below it is pinned, "
                         "it does not move with the row count as MicroStrategy sections do" % rows)
                y += th
                continue
            sec = self.sections.get(kind)
            if not sec or kind == "detail":
                continue
            if self.mode == "banded" and kind in ("group-header", "group-footer", "detail-footer"):
                continue
            sh = px(sec["height_in"])
            for c in sec.get("controls", []):
                self.emit_free(c, kind, self.page_lines, self.M, y, self.W, self.H, body_id, y + sh)
            y += sh
        if y > bottom:
            self.gap(None, "page", "body overflow", "layout",
                     "body sections need %d px but the printable body ends at %d px" % (y, bottom))

        if self.mode == "banded":
            table["groupings"] = self.banded_groupings(table)
        flt = self.filters()
        srt = self.sort()
        table["columns"] = list(self.columns.values()) + [c for c in table["columns"] if c["id"].startswith("calc-")]
        table["order"] = order + [c["id"] for c in table["columns"] if c["id"] not in order]
        if flt:
            table["filters"] = flt
        if srt:
            table["sort"] = srt
        table["tableStyle"] = self.table_style(dh, labels)
        self.elements.insert(0, table)

        pages = [{"id": body_id, "name": self.doc["document"]["name"]}]
        if self.mode == "invoice":
            g = self.grouping[0]
            gcol = self.column(self.group_field, None, "grouping")
            default = self.args.default_group_value or g.get("sample_value")
            ctl = {"id": "rs-ctl-" + slug(self.group_field), "kind": "control",
                   "controlId": "rs-group-" + slug(self.group_field), "name": field_label(self.group_field),
                   "controlType": "list", "mode": "include", "selectionMode": "single",
                   "source": {"kind": "source", "source": {"kind": "table", "elementId": "rs-detail"},
                              "columnId": gcol["id"]},
                   "filters": [{"source": {"kind": "table", "elementId": "rs-detail"}, "columnId": gcol["id"]}]}
            if default:
                ctl["value"] = default
            self.ids.add(ctl["id"])
            self.elements.append(ctl)
            self.place(self.hidden_lines, ctl["id"], self.M, self.M, 320, 48, self.W, self.H,
                       None, "grouping", params_id)
            pages.append({"id": params_id, "name": "Parameters", "visibility": "hidden"})
            self.gap(None, "grouping", "page break between groups", "review",
                     "the report renders one %s at a time (control %r); schedule one PDF per value to "
                     "reproduce the per-group pages%s" % (self.group_field, ctl["controlId"],
                                                          "" if default else
                                                          "; no default value, so an unselected export merges every group"))
            if not default:
                self.gap(None, "grouping", "no default group value", "blocking",
                         "pass --default-group-value or set grouping[0].sample_value")
        if self.grouping and self.grouping[0].get("restart_page_numbers"):
            self.gap(None, "grouping", "page numbers restart per group", "layout",
                     "Sigma numbers pages across the whole report")

        layout = ['<?xml version="1.0" encoding="utf-8"?>',
                  '<Page id="%s">\n%s\n</Page>' % (body_id, "\n".join(self.page_lines))]
        if self.hidden_lines:
            layout.append('<Page id="%s">\n%s\n</Page>' % (params_id, "\n".join(self.hidden_lines)))
        layout += self.panel_lines
        contents = {"schemaVersion": 1, "kind": "report",
                    "config": {"pageWidth": self.W, "pageHeight": self.H, "margin": self.M},
                    "elements": self.elements, "pages": pages, "layout": "\n".join(layout)}
        if self.panels:
            contents["panels"] = self.panels
        name = self.args.name or self.doc["document"]["name"]
        return {"name": name, "folderId": self.args.folder_id or "{{FOLDER_ID}}",
                "description": "Converted from the MicroStrategy Report Services document %r (%s mode) by "
                               "microstrategy-to-sigma/convert-rs-document.py." % (self.doc["document"]["name"],
                                                                                  self.mode),
                "contents": contents}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--document", required=True, help="mstr-rs-document/1 JSON definition")
    ap.add_argument("--connection-id", required=True)
    ap.add_argument("--folder-id", default=None, help="destination folder (default placeholder {{FOLDER_ID}})")
    ap.add_argument("--name", default=None)
    ap.add_argument("--detail-rows", type=int, default=10, help="rows reserved for the detail table box")
    ap.add_argument("--default-group-value", default=None, help="invoice mode: group value shown by default")
    ap.add_argument("--image-url", action="append", metavar="CONTROL=URL", help="URL for an image control")
    ap.add_argument("--out", default="sigma_report_spec.json")
    ap.add_argument("--gaps-out", default="feature-gaps.json")
    ap.add_argument("--map-out", default="control-map.json")
    ap.add_argument("--allow-gaps", action="store_true", help="exit 0 even with blocking gaps")
    args = ap.parse_args(argv)
    try:
        with open(args.document, encoding="utf-8") as fh:
            doc = json.load(fh)
        conv = Converter(doc, args)
        spec = conv.run()
    except (InputError, KeyError, ValueError) as e:
        print("convert-rs-document: invalid document: %s" % e, file=sys.stderr)
        return 1
    blocking = [g for g in conv.gaps if g["severity"] == "blocking"]
    gaps = {"document": doc["document"]["name"], "mode": conv.mode, "blocking": len(blocking),
            "gaps": conv.gaps, "warnings": conv.warnings}
    cmap = {"document": doc["document"]["name"], "px_per_inch": PX_PER_IN, "margin_px": conv.M,
            "controls": conv.cmap}
    for path, obj in ((args.out, spec), (args.gaps_out, gaps), (args.map_out, cmap)):
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    kinds = {}
    for e in spec["contents"]["elements"]:
        kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    print("wrote %s (%s mode; %s) + %s (%d gaps, %d blocking) + %s"
          % (args.out, conv.mode, ", ".join("%s x%d" % kv for kv in sorted(kinds.items())),
             args.gaps_out, len(conv.gaps), len(blocking), args.map_out))
    for w in conv.warnings:
        print("  " + w)
    if blocking and not args.allow_gaps:
        for g in blocking:
            print("  BLOCKING %s/%s: %s — %s" % (g["section"], g["control"], g["construct"], g["detail"]),
                  file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
