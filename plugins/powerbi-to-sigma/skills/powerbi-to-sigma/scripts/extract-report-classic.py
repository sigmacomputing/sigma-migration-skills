#!/usr/bin/env python3
"""extract-report-classic.py — adapter for the CLASSIC single-file report layout.

Some Power BI reports come back from Fabric getDefinition as the legacy
single `report.json` (top-level `sections[]` with `visualContainers[]`, each
carrying a `config` JSON string) rather than the new exploded PBIR
(`definition/pages/<pg>/visuals/<id>/visual.json`). extract-pbir.py only
handles the new layout; this adapter normalizes the classic shape into the
SAME signals.json schema so build-workbook-from-pbir.rb can consume it.

Classic `.pbix` files contain a UTF-16LE `Report/Layout` document. Modern
files can instead contain exploded `Report/definition/` PBIR. This local
front door detects either format and delegates PBIR to extract-pbir.py,
without Fabric authentication or translating away report metadata.

Classic report layout shape (report.json == .pbix Report/Layout):
  sections[] : { name, displayName, width, height, visualContainers[] }
    visualContainers[] : { x, y, width, height, z, config(JSON string) }
      config : { name, singleVisual:{ visualType, projections:{Role:[{queryRef}]},
                                      objects:{ title[], general[] (textbox) } } }

Usage (any ONE of the three inputs):
  # from a Fabric getDefinition report.json (UTF-8) — original behavior
  python3 extract-report-classic.py --report-json /tmp/pbir-orders/report.json \
      --out /tmp/pbir-orders/signals.json
  # from a fully-local .pbix (unzips the Report/Layout member, UTF-16LE) — no Fabric
  python3 extract-report-classic.py --pbix /path/Sales.pbix --out signals.json
  # from an already-extracted Report/Layout file (any of UTF-16LE/utf-8-sig/utf-8)
  python3 extract-report-classic.py --report-layout /path/Layout --out signals.json
"""
import argparse, importlib.util, io, json, os, re, sys, tempfile, zipfile
from pathlib import Path, PurePosixPath

# visualType -> Sigma kind + ROLE CLASS resolves through the catalogs
# (refs/catalogs/viz-kind.json + custom-visual.json) via lib/pbi_viz_kind.py — the
# SAME files the Ruby builder reads, so the two maps cannot drift.
#
# Replaces the hand-maintained VISUAL_KIND dict that used to live here (and a
# duplicate in extract-pbir.py), whose `.get(vtype, "bar")` default silently coerced
# any unrecognized visual into a bar chart. Measured on 4 real customer .pbix files:
# that turned 21 third-party Powerviz date-picker SLICERS into bar charts (nearly
# every page lost its date filter), plus 4 modern cardVisual cards and 5 decorative
# shapes. Nothing silently becomes a chart any more.


def _load_pbi_viz_kind():
    """Import lib/pbi_viz_kind.py by path (no sys.path mutation — this module is
    also imported by tests and by extract-pbir.py's sibling flow)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "pbi_viz_kind.py")
    spec = importlib.util.spec_from_file_location("pbi_viz_kind", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_vk = _load_pbi_viz_kind()
_VK = _vk.load(_vk.default_catalog_dir(__file__))

# *Bar* = horizontal, *Column* = vertical (Sigma default). Sigma's bar-chart
# `orientation` accepts only "horizontal"; vertical = omit the field.
# PBI visualType -> Sigma `stacking` enum (none|stacked|normalized). Classic
# files encode it in the TYPE NAME; without an explicit value Sigma defaults
# multi-series bars to STACKED, corrupting clustered PBI charts (customer
# catch on the Retail sample's clustered variance chart).
def _stacking(vtype):
    v = (vtype or "")
    if v.startswith("hundredPercentStacked"):
        return "normalized"
    if v.startswith("stacked"):
        return "stacked"
    return "none"


HBAR_TYPES = {"barChart", "clusteredBarChart", "stackedBarChart",
              "hundredPercentStackedBarChart"}

# Legacy geo/map visuals bind Location + Size. The bar fallback reads Category
# + Y, so retain that historical remap for those map types. Azure Maps has a
# distinct schema: X=longitude and Y=latitude, while Size and Series keep their
# literal meanings. Never apply either mapping to scatter charts.
ROLE_REMAP = {
    "Size": "Y",
    "Location": "Category",
}
MAP_TYPES = {"map", "filledMap", "shapeMap", "azureMap"}
AZURE_MAP_ROLE_REMAP = {
    "X": "Longitude",
    "Y": "Latitude",
    "Location": "Category",
}


def _map_role(role, visual_type):
    if visual_type == "azureMap":
        return AZURE_MAP_ROLE_REMAP.get(role, role)
    return ROLE_REMAP.get(role, role) if visual_type in MAP_TYPES else role


# Aggregation.Function enum -> modern queryRef wrapper (Sum(Table.Col)).
_AGG_FN = {0: "Sum", 1: "Avg", 2: "Count", 3: "Min", 4: "Max", 5: "CountNonNull",
           6: "Median", 7: "StandardDeviation", 8: "Variance"}  # QueryAggregateFunction


def _select_alias_map(sv):
    """Legacy classic layouts (PBIX vintage ~2017 and earlier, e.g. the MS
    'Retail Analysis Sample') bind projections by POSITIONAL aliases
    ('select', 'select1', ...) instead of qualified 'Table.Field' refs. The
    alias is prototypeQuery.Select[].Name, and that entry's Column/Measure/
    Aggregation expression carries the real Entity.Property (Entity via the
    From[] alias table). Map alias -> qualified ref; for modern classic files
    Name already IS the qualified ref, so the mapping is an identity."""
    pq = sv.get("prototypeQuery") or {}
    ents = {f.get("Name"): f.get("Entity") for f in pq.get("From", []) if isinstance(f, dict)}

    def qualify(expr):
        src = ((expr.get("Expression") or {}).get("SourceRef") or {}).get("Source")
        ent = ents.get(src)
        prop = expr.get("Property")
        return f"{ent}.{prop}" if ent and prop else None

    out = {}
    for sel in pq.get("Select", []):
        if not isinstance(sel, dict) or not sel.get("Name"):
            continue
        ref = None
        if "Column" in sel or "Measure" in sel or "HierarchyLevel" in sel:
            ref = qualify(sel.get("Column") or sel.get("Measure") or sel.get("HierarchyLevel") or {})
        elif "Aggregation" in sel:
            agg = sel["Aggregation"]
            inner = (agg.get("Expression") or {}).get("Column") or {}
            base = qualify(inner)
            fn = _AGG_FN.get(agg.get("Function"))
            ref = f"{fn}({base})" if base and fn else base
        if ref:
            out[sel["Name"]] = ref
    return out


_DATE_LEVEL_RE = re.compile(
    r"((?:^|\.)date\.variation\.|(?:^|\.)date hierarchy(?:\.|$)|(?:^|\.)(?:year|quarter|month|week|day|date)$)", re.I)
# User calendar hierarchies ("Calendar.Fiscal.Fiscal Month", "Time.Time Hierarchy.Yr",
# "Orders.ORDER_YEAR"). Every identifier (table, hierarchy, leaf) is split into lowercase
# WORDS (spaces, underscores, hyphens, dots, camelCase and digit boundaries), then matched as
# whole words, so ORDER_YEAR / OrderYear count but 'Candidates' / 'Status Updates' do not.
#  - a leaf is a date grain when one of its words is a grain word, unless it is clearly a
#    measure-like bucket ("Days Overdue Bucket", "Aging Band", "Months Since Signup");
#  - a table/hierarchy is date-scoped by the words date / calendar. Neither 'time' (a
#    timesheet's Client > Project > Task) nor 'fiscal' (a 'Fiscal Actuals' account tree) is
#    scope; 'fiscal' and 'period' count only as LEAF grain words (FISCAL_YEAR, FISCAL_PERIOD).
#  - under a date-scoped table/hierarchy a leaf may also be a compact grain (Y, Q, M, D,
#    FQ, FM); outside that scope a one-letter leaf is not a grain;
#  - the auto-date markers are anchored (a 'Date.Variation.' segment pair, a whole 'Date
#    Hierarchy' segment), so 'Candidate Hierarchy', a 'Product Variations' table or a
#    'Product.Variation.Color' hierarchy is not a date hierarchy.
# A role is a date hierarchy only with at least two levels that each carry a grain word, and
# at least two DISTINCT grain words between them (_is_date_hierarchy): Year + Month is a
# drill, while Order Date + Ship Date (one grain, 'date') or Fiscal Year + Holiday (Holiday
# has no grain) are independent columns and stay bound.
_DATE_GRAIN_WORDS = frozenset((
    "year", "years", "yr", "fy", "quarter", "qtr", "month", "months", "mth", "mo",
    "week", "wk", "day", "days", "date", "period", "periods", "fiscal"))
_DATE_SCOPED_GRAIN_WORDS = frozenset(("y", "q", "m", "d", "fq", "fm"))
_DATE_BUCKET_WORDS = frozenset((
    "overdue", "since", "bucket", "buckets", "band", "bands", "aging", "ageing", "age", "ages"))
_DATE_SCOPE_WORDS = frozenset(("date", "calendar"))


def _words(name):
    s = re.sub(r"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])|(?<=[A-Za-z])(?=\d)|(?<=\d)(?=[A-Za-z])",
               " ", str(name))
    return [w for w in re.split(r"[^A-Za-z0-9]+", s.lower()) if w]


def _date_grains(ref):
    parts = str(ref).split(".")
    leaf = set(_words(parts[-1]))
    if leaf & _DATE_BUCKET_WORDS:
        return set()
    grains = leaf & _DATE_GRAIN_WORDS
    if any(set(_words(p)) & _DATE_SCOPE_WORDS for p in parts[:-1]):
        grains |= leaf & _DATE_SCOPED_GRAIN_WORDS
    return grains


def _is_date_ref(ref):
    ref = str(ref)
    if _DATE_LEVEL_RE.search(ref):
        return True
    parts = ref.split(".")
    if _date_grains(ref):
        return True
    return any(set(_words(p)) & _DATE_SCOPE_WORDS for p in parts[:-1])


def _is_date_hierarchy(items, aliases=None):
    aliases = aliases or {}
    raw = [aliases.get(it["queryRef"], it["queryRef"])
           for it in items if isinstance(it, dict) and it.get("queryRef")]
    date_refs = [r for r in raw if _is_date_ref(r)]
    grain_sets = [g for g in (_date_grains(r) for r in date_refs) if g]
    grains = set().union(*grain_sets)
    # Distinct grains distinguish Year/Month drills from independent date columns.
    return len(grain_sets) >= 2 and len(grains) >= 2


def _matrix_levels(sv, vt):
    """{Role: {levels, active, date}} for a matrix's multi-level Rows/Columns roles
    (same shape as extract-pbir.py); None when nothing is multi-level."""
    if vt not in ("pivotTable", "matrix"):
        return None
    smap = _select_alias_map(sv)
    act = sv.get("activeProjections", {}) or {}
    out = {}
    for role in ("Rows", "Columns"):
        items = (sv.get("projections", {}) or {}).get(role) or []
        levels = [smap.get(it["queryRef"], it["queryRef"]) for it in items
                  if isinstance(it, dict) and it.get("queryRef")]
        if len(levels) < 2:
            continue
        active = [smap.get(it["queryRef"], it["queryRef"]) for it in (act.get(role) or [])
                  if isinstance(it, dict) and it.get("queryRef")]
        out[role] = {"levels": levels, "active": active,
                     "date": _is_date_hierarchy(items, smap)}
    return out or None


def _projections(sv, vt=None):
    # bead hjke(c): classic configs record the drilled-to hierarchy level in
    # singleVisual.activeProjections — prefer it over the full level list so a
    # day-drilled line binds Day instead of collapsing to Year.
    act = sv.get("activeProjections", {}) or {}
    smap = _select_alias_map(sv)
    out = {}
    for role, items in (sv.get("projections", {}) or {}).items():
        a = act.get(role) or []
        arefs = [smap.get(it["queryRef"], it["queryRef"]) for it in a
                 if isinstance(it, dict) and it.get("queryRef")]
        refs = [smap.get(it["queryRef"], it["queryRef"]) for it in items
                if isinstance(it, dict) and it.get("queryRef")]
        if (vt in ("pivotTable", "matrix") and role in ("Rows", "Columns")
                and arefs and arefs != refs and not _is_date_hierarchy(items, smap)):
            print(f"[classic] matrix: role {role} keeps all {len(refs)} level(s) "
                  f"({len(arefs)} active); Power BI opens it collapsed", file=sys.stderr)
        elif arefs and arefs != refs:
            print(f"[classic] drill: role {role} -> active projection {arefs} "
                  f"(of {len(refs)} level(s))", file=sys.stderr)
            refs = arefs
        if refs:
            key = _map_role(role, vt)
            out[key] = refs
    return out


def _drill_signal(sv, vt=None):
    """Return the complete ordered chart hierarchy when classic metadata has it.

    ``_projections`` keeps the saved active level for initial rendering.  The
    original ``projections`` plus ``activeProjections`` provide enough evidence
    to wire a native Sigma drill control without guessing target columns.
    """
    smap = _select_alias_map(sv)
    active = sv.get("activeProjections", {}) or {}
    for role, items in (sv.get("projections", {}) or {}).items():
        levels = [smap.get(it["queryRef"], it["queryRef"]) for it in items
                  if isinstance(it, dict) and it.get("queryRef")]
        if len(levels) < 2:
            continue
        active_refs = [smap.get(it["queryRef"], it["queryRef"])
                       for it in (active.get(role) or [])
                       if isinstance(it, dict) and it.get("queryRef")]
        # Category/Axis with multiple projections is Power BI's chart hierarchy
        # even at its top level; an activeProjections entry is stronger evidence
        # and also identifies the saved drill level.
        if role not in ("Category", "Axis", "X") and not active_refs:
            continue
        mapped_role = _map_role(role, vt)
        return {
            "role": mapped_role,
            "levels": levels,
            "active": active_refs[0] if active_refs else levels[0],
        }
    return None


def _title(sv):
    for it in sv.get("objects", {}).get("title", []):
        props = it.get("properties", {})
        show = props.get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        t = props.get("text", {}).get("expr", {}).get("Literal", {}).get("Value")
        if t and show != "false":
            return t.strip("'")
    return None


def _obj_flag(sv, key):
    """objects.<key>[0].properties.show.expr.Literal.Value -> True/False/None
    (bead n9u9 data labels / ry0n legend; same shape as extract-pbir.py)."""
    for it in sv.get("objects", {}).get(key, []):
        v = it.get("properties", {}).get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        if v is not None:
            return str(v).strip("'").lower() == "true"
    return None


def _sort_signal(sv):
    """bead f972: classic sort -> {queryRef, direction asc|desc} or None.

    Classic configs carry the visual's sort in prototypeQuery.OrderBy[]:
    {Direction: 1|2 (1=Ascending, 2=Descending), Expression: <field expr>}.
    The Expression is structurally IDENTICAL to one of prototypeQuery.Select[]'s
    entries (minus its Name/NativeReferenceName) — and that Select's `Name` is the
    exact queryRef the projections bind ("ABSENCE_RECORDS.Absence Count",
    "Sum(ABSENCE_RECORDS.HOURS)"), so match by expression equality."""
    pq = sv.get("prototypeQuery") or {}
    ob = pq.get("OrderBy") or []
    if not ob:
        return None
    first = ob[0]
    direction = "desc" if first.get("Direction") == 2 else "asc"
    expr = first.get("Expression")
    for sel in pq.get("Select", []):
        if not isinstance(sel, dict):
            continue
        sel_expr = {k: v for k, v in sel.items() if k not in ("Name", "NativeReferenceName")}
        if sel_expr == expr and sel.get("Name"):
            # resolve legacy 'selectN' aliases the same way projections do
            ref = _select_alias_map(sv).get(sel["Name"], sel["Name"])
            return {"queryRef": ref, "direction": direction}
    return None


def _textbox_body(sv):
    for para in sv.get("objects", {}).get("general", []):
        paras = para.get("properties", {}).get("paragraphs", [])
        for p in paras:
            for run in p.get("textRuns", []):
                v = run.get("value")
                if v:
                    return v
    return None


def _is_hidden(vc, cfg, sv):
    """G30: a classic visual is hidden when its container is flagged `hidden` or
    its single visual's display.mode is "hidden" (what Power BI writes for the
    Selection-pane eye)."""
    if vc.get("hidden") is True:
        return True
    disp = sv.get("display")
    return isinstance(disp, dict) and disp.get("mode") == "hidden"


def extract(report):
    out_pages = []
    for s in report.get("sections", []):
        visuals = []
        for vc in s.get("visualContainers", []):
            cfg = json.loads(vc.get("config", "{}"))
            sv = cfg.get("singleVisual", {})
            vt = sv.get("visualType", "unknown")
            # bead a1cv: image visuals are static assets (StaticResources). Emit a
            # kind='image' record carrying the registered-resource name — the
            # builder turns it into a Sigma image element when --image-map
            # supplies a hosted URL for it, and skips it (with a note) otherwise.
            if vt == "image":
                # resource name lives at objects.general[].properties.imageUrl
                # .expr.ResourcePackageItem.ItemName (classic) — regex fallback
                # for any RegisteredResources path form.
                m = re.search(r'"ItemName":\s*"([^"]+)"', json.dumps(cfg)) \
                    or re.search(r"RegisteredResources/([\w.\-]+)", json.dumps(cfg))
                ipos = (cfg.get("layouts", [{}])[0] or {}).get("position", {})
                rec = {
                    "visual_id": f"p{len(out_pages)}v{len(visuals)}image",
                    "visual_type": vt, "title": None, "sigma_kind": "image",
                    "orientation": None,
                    "x": vc.get("x") or ipos.get("x", 0), "y": vc.get("y") or ipos.get("y", 0),
                    "w": vc.get("width") or ipos.get("width", 0), "h": vc.get("height") or ipos.get("height", 0),
                    "z": vc.get("z") or ipos.get("z", 0), "parent_group": None, "bindings": {},
                    "sort": None, "formats": {}, "data_labels": None, "legend": None,
                    "resource": m.group(1) if m else None,
                    # image is a catalog row too, so every visual record carries the
                    # same role_class/guidance contract the coverage gate reads.
                    "role_class": _VK.resolve_or_guidance(vt)["role_class"],
                    "sigma_target": None, "viz_guidance": None,
                    "viz_catalog": "viz-kind", "approximate": False,
                }
                if _is_hidden(vc, cfg, sv):
                    rec["hidden"] = True
                visuals.append((cfg.get("name"), rec))
                continue
            # position: prefer vc top-level x/y/w/h, fall back to config layouts
            x = vc.get("x"); y = vc.get("y"); w = vc.get("width"); h = vc.get("height")
            if x is None:
                pos = (cfg.get("layouts", [{}])[0] or {}).get("position", {})
                x, y, w, h = pos.get("x", 0), pos.get("y", 0), pos.get("width", 0), pos.get("height", 0)
            # Catalog resolution. `builder_kind` is the coarse token
            # build-workbook-from-pbir.rb switches on (unchanged contract);
            # `role_class` is what the visual DOES (control|kpi|chart|table|text|
            # decoration|unsupported) so the coverage gate can tell a FUNCTIONAL
            # loss (a lost slicer = the page lost its filter) from a cosmetic one.
            vkind = _VK.resolve_or_guidance(vt)
            rec = {
                # bead npo0: classic config `name`s are NOT unique in pre-2018
                # files (truncated visualContainer strings collide) and the
                # builder derives element ids from visual_id — synthesize a
                # deterministic page/index id instead of trusting cfg name.
                "visual_id": f"p{len(out_pages)}v{len(visuals)}{vt[:8]}",
                "visual_type": vt,
                "title": _title(sv),
                "sigma_kind": vkind["builder_kind"] or vkind["role_class"],
                "role_class": vkind["role_class"],
                "sigma_target": vkind["sigma_target"],
                "viz_guidance": vkind["guidance"],
                "viz_catalog": vkind["catalog"],
                "approximate": vkind["approximate"],
                "orientation": "horizontal" if vt in HBAR_TYPES else None,
                "x": x or 0, "y": y or 0, "w": w or 0, "h": h or 0,
                "z": vc.get("z", 0),
                "parent_group": None,
                "bindings": _projections(sv, vt),
                # Preserve the full hierarchy separately from the active-level
                # binding so the workbook builder can emit controlType:drill.
                "drill": _drill_signal(sv, vt),
                "matrix_levels": _matrix_levels(sv, vt),
                # bead f972: visual sort ({queryRef, direction asc|desc}) or None
                "sort": _sort_signal(sv),
                "stacking": _stacking(vt) if vkind["builder_kind"] in ("bar", "area") else None,
                "formats": {},
                # bead n9u9: PBI data-label toggle (objects.labels show) — true/false/None
                "data_labels": _obj_flag(sv, "labels"),
                # bead ry0n: PBI legend toggle (objects.legend show) — true/false/None
                "legend": _obj_flag(sv, "legend"),
            }
            if rec["sigma_kind"] == "text":
                rec["text"] = _textbox_body(sv)
            # emitted ONLY when true: signals for a report with no hidden
            # visuals stay byte-identical.
            if _is_hidden(vc, cfg, sv):
                rec["hidden"] = True
            visuals.append((cfg.get("name"), rec))
        visuals.sort(key=lambda nr: (nr[1]["y"], nr[1]["x"]))
        # Visual-interaction overrides ("edit interactions"): the classic
        # section config (JSON string) carries visualInteractions[{source,
        # target, type}] ONLY when an author edited them; source/target are
        # config names — remapped here onto the synthesized visual_ids the
        # builder keys on (control-targeting wave, workstream B). Numeric
        # types: 3 = none/no-filter (the exemption the builder honors);
        # 1/2 = filter/highlight (both still filter-like — kept verbatim).
        name_to_id = {n: r["visual_id"] for n, r in visuals if n}
        interactions = []
        try:
            scfg = json.loads(s.get("config") or "{}")
        except (TypeError, ValueError):
            scfg = {}
        for ia in (scfg.get("visualInteractions") or []):
            src, tgt = name_to_id.get(ia.get("source")), name_to_id.get(ia.get("target"))
            if not (src and tgt):
                continue
            t = ia.get("type")
            interactions.append({"source": src, "target": tgt,
                                 "type": "none" if t in (3, "3", "none", "noFilter") else str(t).lower()})
        out_pages.append({
            "page_id": s.get("name"),
            "page_title": s.get("displayName", s.get("name")),
            "page_w": s.get("width", 1280),
            "page_h": s.get("height", 720),
            "visuals": [r for _n, r in visuals],
            "interactions": interactions,
        })
    return {"source": "report.json-classic", "pages": out_pages}


# --- input decoding ---------------------------------------------------------
# The classic layout arrives three ways: (1) a UTF-8 report.json from Fabric
# getDefinition (original --report-json path); (2) the raw `Report/Layout`
# member INSIDE a local .pbix zip — a SINGLE JSON doc that Power BI Desktop
# writes UTF-16LE (usually with a BOM); (3) an already-extracted Layout file
# on disk. (2)/(3) may be UTF-16LE, UTF-8-with-BOM, or plain UTF-8, so decode
# defensively: honor a BOM first, then try UTF-16LE (the Desktop default),
# then UTF-8. json.loads tolerates a leading BOM only for utf-8-sig, so we
# decode to str ourselves rather than handing bytes to json.
PBIX_LAYOUT_MEMBER = "Report/Layout"


def _decode_layout_bytes(raw):
    """bytes -> parsed JSON, trying the encodings a classic Report/Layout uses.

    Order: explicit BOM (UTF-16 LE/BE, UTF-8-sig) → UTF-16LE (Desktop default,
    no BOM) → UTF-8. Raises ValueError with a short diagnostic if none parse."""
    attempts = []
    if raw[:2] == b"\xff\xfe":
        attempts.append("utf-16")       # BOM-driven (LE)
    elif raw[:2] == b"\xfe\xff":
        attempts.append("utf-16")       # BOM-driven (BE)
    elif raw[:3] == b"\xef\xbb\xbf":
        attempts.append("utf-8-sig")
    # Desktop writes UTF-16LE (often no BOM); then plain UTF-8 / utf-8-sig.
    attempts += ["utf-16-le", "utf-8-sig", "utf-8", "utf-16"]
    last = None
    seen = set()
    for enc in attempts:
        if enc in seen:
            continue
        seen.add(enc)
        try:
            text = raw.decode(enc)
        except (UnicodeDecodeError, LookupError) as e:
            last = e
            continue
        text = text.lstrip("﻿")     # strip a decoded BOM char if present
        try:
            return json.loads(text)
        except ValueError as e:
            last = e
            continue
    raise ValueError(f"could not decode Report/Layout as JSON "
                     f"(tried {', '.join(attempts)}): {last}")


def load_report(report_json=None, pbix=None, report_layout=None):
    """Resolve exactly one input into a parsed classic-report dict."""
    if pbix:
        with zipfile.ZipFile(pbix) as z:
            names = set(z.namelist())
            member = PBIX_LAYOUT_MEMBER
            if member not in names:
                # Some tooling stores it with a backslash separator.
                alt = next((n for n in names if n.replace("\\", "/") == PBIX_LAYOUT_MEMBER), None)
                if not alt:
                    raise SystemExit(
                        f"FATAL: '{pbix}' has no '{PBIX_LAYOUT_MEMBER}' member — "
                        f"not a classic .pbix, or a thin/PBIR report. Members: "
                        f"{sorted(n for n in names if n.startswith('Report'))[:5]}")
                member = alt
            raw = z.read(member)
        return _decode_layout_bytes(raw)
    if report_layout:
        with open(report_layout, "rb") as f:
            return _decode_layout_bytes(f.read())
    with open(report_json, "rb") as f:
        # report.json from Fabric is UTF-8, but decode defensively anyway.
        return _decode_layout_bytes(f.read())


def main():
    ap = argparse.ArgumentParser(
        description="Normalize a classic Power BI report layout (report.json / "
                    ".pbix Report/Layout) into signals.json.")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--report-json", help="UTF-8 classic report.json (Fabric getDefinition)")
    src.add_argument("--pbix", help="local .pbix file with classic Report/Layout or Report/definition PBIR")
    src.add_argument("--report-layout", help="an already-extracted Report/Layout file (UTF-16LE/utf-8)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--dump-layout", metavar="PATH",
                    help="also write the decoded report definition JSON text to PATH "
                         "(classic Layout, or {part: text} for a PBIR .pbix) for model scoping")
    a = ap.parse_args()
    if a.pbix:
        with zipfile.ZipFile(a.pbix) as archive:
            members = [(info, info.filename.replace("\\", "/")) for info in archive.infolist()]
            names = {name for _, name in members}
            if "Report/definition/pages/pages.json" in names:
                # Reuse the PBIR parser rather than flattening away filters,
                # synced slicers and hierarchy metadata through classic JSON.
                with tempfile.TemporaryDirectory(prefix="pbi-report-") as directory:
                    seen = set()
                    dump_parts = {}
                    for info, name in members:
                        if not name.startswith("Report/definition/") or info.is_dir():
                            continue
                        relative = PurePosixPath(name[len("Report/"):])
                        if ".." in relative.parts or relative.is_absolute() or ":" in name:
                            raise SystemExit("FATAL: unsafe PBIR archive member")
                        if relative.as_posix() in seen:
                            raise SystemExit("FATAL: duplicate PBIR archive member")
                        seen.add(relative.as_posix())
                        target = Path(directory).joinpath(*relative.parts)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(archive.read(info))
                        dump_parts[relative.as_posix()] = target.read_text(encoding="utf-8", errors="replace")
                    page_index = Path(directory, 'definition', 'pages', 'pages.json')
                    for page_name in json.loads(page_index.read_text()).get('pageOrder', []):
                        if not isinstance(page_name, str) or page_name in ('', '.', '..') or any(c in page_name for c in '/\\:'):
                            raise SystemExit("FATAL: unsafe PBIR page name")
                    path = Path(__file__).with_name("extract-pbir.py")
                    spec = importlib.util.spec_from_file_location("pbi_report_extract", path)
                    parser = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(parser)
                    signals = parser.extract(directory)
                signals.pop("pbir_dir", None)  # temporary extraction path no longer exists
                signals["source"] = "pbix-pbir"
                if a.dump_layout:
                    with open(a.dump_layout, "w", encoding="utf-8") as dump:
                        json.dump(dump_parts, dump)
                with open(a.out, "w") as output:
                    json.dump(signals, output, indent=2)
                nvis = sum(len(p["visuals"]) for p in signals["pages"])
                print(f"[pbix-pbir] {len(signals['pages'])} page(s), {nvis} visual(s) -> {a.out}", file=sys.stderr)
                return
    report = load_report(report_json=a.report_json, pbix=a.pbix, report_layout=a.report_layout)
    signals = extract(report)
    if a.dump_layout:
        with open(a.dump_layout, "w", encoding="utf-8") as dump:
            json.dump(report, dump)
    json.dump(signals, open(a.out, "w"), indent=2)
    nvis = sum(len(p["visuals"]) for p in signals["pages"])
    print(f"[classic] {len(signals['pages'])} page(s), {nvis} visual(s) -> {a.out}", file=sys.stderr)
    for p in signals["pages"]:
        for v in p["visuals"]:
            print(f"  {v['visual_type']:>14} -> {v['sigma_kind']:<6} {v['bindings']}", file=sys.stderr)


if __name__ == "__main__":
    main()
