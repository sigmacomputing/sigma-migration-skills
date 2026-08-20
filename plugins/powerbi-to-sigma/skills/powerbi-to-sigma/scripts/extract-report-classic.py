#!/usr/bin/env python3
"""extract-report-classic.py — adapter for the CLASSIC single-file report layout.

Some Power BI reports come back from Fabric getDefinition as the legacy
single `report.json` (top-level `sections[]` with `visualContainers[]`, each
carrying a `config` JSON string) rather than the new exploded PBIR
(`definition/pages/<pg>/visuals/<id>/visual.json`). extract-pbir.py only
handles the new layout; this adapter normalizes the classic shape into the
SAME signals.json schema so build-workbook-from-pbir.rb can consume it.

The IDENTICAL classic shape also lives INSIDE a local `.pbix` file: a `.pbix`
is a zip whose `Report/Layout` member is a single JSON document (top-level
`sections[]`) encoded UTF-16LE — NOT the exploded PBIR. So this adapter is
also the fully-LOCAL report front door: point it at a `.pbix` (or an already
extracted `Report/Layout` file) with no Fabric/tenant involved.

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
import argparse, importlib.util, io, json, os, re, sys, zipfile

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

# Geo/map visuals bind Series(=location dim) + Size(=measure). The bar branch of
# the builder reads Category/Axis/X (dim) and Y/Values (measure), so remap —
# but ONLY for map visuals (bead ry0n): on a scatterChart, Size is the real
# bubble-size role and Series the legend; remapping them corrupts the scatter.
ROLE_REMAP = {
    "Size": "Y",
    "Location": "Category",
}
MAP_TYPES = {"map", "filledMap", "shapeMap", "azureMap"}


# Aggregation.Function enum -> modern queryRef wrapper (Sum(Table.Col)).
_AGG_FN = {0: "Sum", 1: "Avg", 2: "Min", 3: "Max", 4: "Count"}


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
        if arefs and arefs != refs:
            print(f"[classic] drill: role {role} -> active projection {arefs} "
                  f"(of {len(refs)} level(s))", file=sys.stderr)
            refs = arefs
        if refs:
            key = ROLE_REMAP.get(role, role) if vt in MAP_TYPES else role
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
        mapped_role = ROLE_REMAP.get(role, role) if vt in MAP_TYPES else role
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
    src.add_argument("--pbix", help="local .pbix file — unzips its Report/Layout (UTF-16LE) member")
    src.add_argument("--report-layout", help="an already-extracted Report/Layout file (UTF-16LE/utf-8)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    report = load_report(report_json=a.report_json, pbix=a.pbix, report_layout=a.report_layout)
    signals = extract(report)
    json.dump(signals, open(a.out, "w"), indent=2)
    nvis = sum(len(p["visuals"]) for p in signals["pages"])
    print(f"[classic] {len(signals['pages'])} page(s), {nvis} visual(s) -> {a.out}", file=sys.stderr)
    for p in signals["pages"]:
        for v in p["visuals"]:
            print(f"  {v['visual_type']:>14} -> {v['sigma_kind']:<6} {v['bindings']}", file=sys.stderr)


if __name__ == "__main__":
    main()
