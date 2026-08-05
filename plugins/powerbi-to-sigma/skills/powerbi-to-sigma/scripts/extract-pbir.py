#!/usr/bin/env python3
"""extract-pbir.py — pull a Power BI report's PBIR and emit a normalized signals.json.

The PBI analog of tableau-to-sigma's parse-twb-layout.rb. Given a PBIR report
folder (already on disk from a Fabric getDefinition, e.g. /tmp/pbir) OR a live
(workspaceId, reportId) to fetch, it walks the report definition and emits one
normalized record per visual: chart kind, the field bindings per role
(x / y / color / value / rows / columns), and canvas position (x,y,w,h) plus the
page geometry. That normalized signals.json is the single input to
build-workbook-from-pbir.rb.

PBIR (Power BI Enhanced Report) on-disk shape (see research/powerbi-visual-layout.md §2c):
    <Report>.Report/definition/
      pages/pages.json                  -> pageOrder, activePageName
      pages/<pg>/page.json              -> displayName, width, height
      pages/<pg>/visuals/<id>/visual.json -> position{x,y,z,width,height}, visual.visualType, visual.query.queryState

Field bindings live under visual.query.queryState.<Role>.projections[].queryRef
(e.g. "EMPLOYEES.Total Salary"); Role is Category/Y/Values/Rows/Columns/Series/etc.

Usage:
    # from an already-extracted PBIR folder (no network):
    python3 scripts/extract-pbir.py --pbir-dir /tmp/pbir --out /tmp/pbir/signals.json

    # fetch a live report first (device-code, cached token), then extract:
    python3 scripts/extract-pbir.py --workspace <wsId> --report <reportId> \
        --pbir-dir /tmp/pbir --out /tmp/pbir/signals.json

Idempotent: re-running overwrites signals.json; a fetch only re-downloads when
--workspace/--report are given (otherwise it parses whatever is on disk).
"""
import argparse, base64, json, os, sys, time
import importlib.util

CLIENT_ID = "ea0616ba-638b-4df5-95b9-636659ae5121"  # Power BI Desktop public client
_TENANT   = os.environ.get("PBI_TENANT", "organizations")  # #347: guest/B2B tenant via PBI_TENANT
AUTHORITY = f"https://login.microsoftonline.com/{_TENANT}"
SCOPES    = ["https://api.fabric.microsoft.com/.default"]
CACHE     = os.environ.get("PBI_TOKEN_CACHE") or ("/tmp/pbiauth/cache.bin" if _TENANT == "organizations" else f"/tmp/pbiauth/cache-{_TENANT}.bin")
FAB_BASE  = "https://api.fabric.microsoft.com/v1"

# PBIR visualType -> Sigma element kind (research/powerbi-visual-layout.md §4e).
# visualType -> Sigma kind + ROLE CLASS resolves through the catalogs
# (refs/catalogs/viz-kind.json + custom-visual.json) via lib/pbi_viz_kind.py — the
# SAME files the Ruby builder and extract-report-classic.py read, so the three can
# not drift. Replaces the hand-maintained VISUAL_KIND dict whose
# `.get(vtype, "bar")` default silently coerced any unrecognized visual into a bar
# chart (measured on 4 real customer .pbix files: 21 third-party date-picker
# slicers became bar charts, so nearly every page lost its date filter).


def _load_pbi_viz_kind():
    """Import lib/pbi_viz_kind.py by path (no sys.path mutation)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "pbi_viz_kind.py")
    spec = importlib.util.spec_from_file_location("pbi_viz_kind", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_vk = _load_pbi_viz_kind()
_VK = _vk.load(_vk.default_catalog_dir(__file__))

# PBI bar families: *Bar* visuals render HORIZONTALLY; *Column* visuals render
# vertically (Sigma's default). Sigma's bar-chart `orientation` field accepts
# ONLY "horizontal" — vertical is expressed by omitting the field; sending
# "vertical" is rejected (invalid_request). Verified via /v2/workbooks/{id}/spec
# PUT round-trip 2026-06-02.
HBAR_TYPES = {"barChart", "clusteredBarChart", "stackedBarChart",
              "hundredPercentStackedBarChart"}

# Stacking: PBI clustered -> Sigma "none" (side-by-side), stacked -> "stacked",
# 100% -> "normalized". The Sigma `stacking` enum is none|stacked|normalized
# (OpenAPI BarChart.stacking; "normalized" = "stack scaled to 100%"). "100" is
# NOT valid — the API rejects it as "Invalid value: string" (beads-sigma-pi8v).
# IMPORTANT: emit "none" explicitly — a multi-series Sigma bar defaults to
# STACKED, so a clustered PBI chart comes out stacked otherwise.
STACKED_TYPES = {"stackedBarChart", "stackedColumnChart", "stackedAreaChart",
                 "hundredPercentStackedBarChart", "hundredPercentStackedColumnChart"}
PCT_STACKED_TYPES = {"hundredPercentStackedBarChart", "hundredPercentStackedColumnChart"}

def _stacking(vtype):
    if vtype in PCT_STACKED_TYPES: return "normalized"
    if vtype in STACKED_TYPES: return "stacked"
    return "none"


def _fetch_pbir(ws, report, out_dir):
    """Download a report's PBIR parts into out_dir via Fabric getDefinition.

    Fast discovery: LRO polling is 0.5s-first + backoff (pbi_fabric.lro) instead
    of sleeping the full Retry-After before the first status check; a per-task
    timings.json lands next to the parts."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import pbi_fabric as fab  # injects truststore (corp TLS inspection — mandatory)
    tm = fab.Timings()
    tok = tm.timed("auth", lambda: fab.get_token())
    if not tok:
        sys.exit("AUTH FAIL — no token")
    try:
        defn = tm.timed("report-def", lambda: fab.fetch_definition(
            tok, ws, "reports", report, None, label="report getDefinition"))
    except RuntimeError as e:
        sys.exit(str(e))
    fab.write_parts(defn, out_dir, flatten=False)
    t = tm.write(os.path.join(out_dir, "timings.json"), status="ok", report=report)
    print(f"[extract-pbir] fetched PBIR -> {out_dir} "
          f"({t['totalSeconds']}s: " + "  ".join(f"{x['task']}={x['seconds']}s" for x in t["tasks"]) + ")",
          file=sys.stderr)


def _role_bindings(query_state):
    """{Role: [queryRef, ...]} from visual.query.queryState.

    bead hjke(c): a date-hierarchy role carries one projection PER LEVEL
    (Year/Quarter/Month/Day); the drilled-to level is flagged `active`. When any
    projection in a role carries an active flag, keep only the active one(s) so a
    day-drilled line binds Day instead of collapsing to the first level (Year).
    """
    out = {}
    for role, blk in (query_state or {}).items():
        projs = [p for p in blk.get("projections", []) if isinstance(p, dict)]
        active = [p for p in projs if p.get("active") is True]
        if active and len(active) < len(projs):
            print(f"[extract-pbir] drill: role {role} has {len(projs)} hierarchy level(s); "
                  f"using active level only", file=sys.stderr)
            projs = active
        refs = [p.get("queryRef") or p.get("nativeQueryRef") for p in projs]
        out[role] = [r for r in refs if r]
    return out


def _obj_flag(visual, key):
    """objects.<key>[0].properties.show.expr.Literal.Value -> True/False/None.

    bead n9u9 (labels) / ry0n (legend): PBI stores per-visual toggles as string
    literals 'true'/'false'; absent means tool default -> None (callers keep
    their back-compat behavior on None)."""
    for item in visual.get("objects", {}).get(key, []):
        v = item.get("properties", {}).get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        if v is not None:
            return str(v).strip("'").lower() == "true"
    return None


def _textbox_body(visual):
    """Best-effort text body for textbox/card-title visuals."""
    objs = visual.get("objects", {})
    for key in ("general", "text"):
        for item in objs.get(key, []):
            t = item.get("properties", {}).get("text", {}).get("expr", {}).get("Literal", {}).get("Value")
            if t:
                return t.strip("'")
    return None


def _visual_title(visual):
    """The PBI visual's title text (objects.title[].properties.text.expr.Literal.Value).
    Returns None when the title is hidden/unset so callers can fall back."""
    for item in visual.get("objects", {}).get("title", []):
        props = item.get("properties", {})
        # respect an explicit show:false
        show = props.get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        t = props.get("text", {}).get("expr", {}).get("Literal", {}).get("Value")
        if t and show != "false":
            return t.strip("'")
    return None


# bead f972: PBI aggregation function codes (query OrderBy / sortDefinition
# Aggregation.Function) -> the function name PBI uses in aggregated queryRefs
# ("Sum(ABSENCE_RECORDS.HOURS)").
AGG_FUNC = {0: "Sum", 1: "Avg", 2: "Min", 3: "Max", 4: "Count", 5: "CountNonNull"}


def _expr_queryref(expr):
    """Best-effort queryRef string from a PBI field expression (Measure/Column/
    Aggregation shapes). Returns None for shapes we don't model (hierarchies)."""
    if not isinstance(expr, dict):
        return None
    if "Aggregation" in expr:
        inner = _expr_queryref(expr["Aggregation"].get("Expression"))
        fn = AGG_FUNC.get(expr["Aggregation"].get("Function"), "Sum")
        return f"{fn}({inner})" if inner else None
    for k in ("Measure", "Column"):
        if k in expr:
            ent = (expr[k].get("Expression") or {}).get("SourceRef", {}).get("Entity")
            prop = expr[k].get("Property")
            if prop:
                return f"{ent}.{prop}" if ent else prop
    return None


def _sort_signal(visual):
    """bead f972: visual.query.sortDefinition.sort[0] -> {queryRef, direction}.

    PBIR carries the visual's sort as query.sortDefinition.sort[]: each entry is
    {field: <field expr>, direction: "Ascending"|"Descending"}. Resolve the sorted
    field back to a bound projection's queryRef (exact field-expression match
    first — projections carry the same `field` object — then a derived
    Entity.Property fallback) so the builder can map it to a Sigma column id."""
    sd = (visual.get("query") or {}).get("sortDefinition") or {}
    entries = sd.get("sort") or []
    qs = (visual.get("query") or {}).get("queryState") or {}
    if not entries:
        # No EXPLICIT sort persisted. Do NOT leave a table/matrix unsorted — Power BI
        # still applies a default: a table/matrix sorts by its FIRST column ascending.
        # Reproduce that so the migrated pivot matches the report; otherwise Sigma
        # applies its own (different) default and the row order silently diverges.
        # (Charts are excluded — their categorical/axis order is handled elsewhere.)
        # Caveat recorded downstream: the parity/executeQueries ROW ORDER is the DAX
        # ORDER BY, NOT this visual sort — never infer the sort from parity output.
        if str(visual.get("visualType", "")) in ("tableEx", "pivotTable", "matrix"):
            for role in ("Rows", "Category", "Values"):  # first non-empty = leftmost column
                for p in (qs.get(role) or {}).get("projections", []):
                    if isinstance(p, dict):
                        qr = p.get("queryRef") or p.get("nativeQueryRef")
                        if qr:
                            return {"queryRef": qr, "direction": "asc", "default": True}
        return None
    first = entries[0]
    direction = "desc" if str(first.get("direction", "")).lower().startswith("desc") else "asc"
    fld = first.get("field")
    for _role, blk in qs.items():
        for p in blk.get("projections", []):
            if isinstance(p, dict) and p.get("field") == fld:
                qr = p.get("queryRef") or p.get("nativeQueryRef")
                if qr:
                    return {"queryRef": qr, "direction": direction}
    qr = _expr_queryref(fld)
    return {"queryRef": qr, "direction": direction} if qr else None


def _proj_format(proj):
    """Best-effort numeric format carried on a projection (PBIR rarely inlines it,
    but newer exports may). Returns a Sigma-ish format hint string or None."""
    fmt = proj.get("format") or proj.get("formatString")
    return fmt if isinstance(fmt, str) and fmt else None


def _literal(prop):
    """Unwrap a PBI property's literal value: {expr:{Literal:{Value:"'x'"}}} -> "x".
    Numeric literals come through as "400D"/"0.45L" — strip the type suffix."""
    if not isinstance(prop, dict):
        return None
    v = (prop.get("expr") or {}).get("Literal", {}).get("Value")
    if v is None:
        return None
    s = str(v).strip()
    if s.startswith("'") and s.endswith("'"):
        return s[1:-1]
    # numeric literal with a trailing type tag (D=double, L=long, M=decimal)
    m = __import__("re").fullmatch(r"(-?\d+(?:\.\d+)?)[DLMF]?", s)
    return m.group(1) if m else s


def _color_literal(prop):
    """A PBI color property is either a flat literal ('#RRGGBB') or a themed
    solid color {solid:{color:{expr:{Literal:{Value:"'#...'"}}}}}. Return the hex
    string or None."""
    if not isinstance(prop, dict):
        return None
    direct = _literal(prop)
    if direct and str(direct).startswith("#"):
        return direct
    solid = (prop.get("solid") or {}).get("color")
    return _color_literal(solid) if solid else None


# bead (A) reference lines: PBI analytics-pane lines live in the visual's
# `objects` under axis-scoped keys. Each is a list of instances; each instance's
# `properties` carries {value, displayName, lineColor, show, ...}. A `value`
# literal -> a constant Sigma refMark; a measure-bound line (no flat value) is
# flagged via expr (the builder formula-wraps it). axis maps to Sigma's
# refMarks.axis: y-axis lines -> 'series', x-axis lines -> 'axis'.
REFLINE_OBJECT_AXIS = {
    "y1AxisReferenceLine": "series", "yAxisReferenceLine": "series",
    "y2AxisReferenceLine": "series2",
    "xAxisReferenceLine": "axis",
    "referenceLine": "series",          # generic (cartesian) constant line
}


def _reference_lines(visual):
    """PBI analytics-pane constant lines -> [{axis, value|expr, label, color, show}].
    Best-effort: PBIR records each line as objects.<key>[].properties with a
    `value` literal (constant) and optional displayName/lineColor."""
    out = []
    objs = visual.get("objects", {})
    for key, axis in REFLINE_OBJECT_AXIS.items():
        for item in objs.get(key, []):
            props = item.get("properties", {}) if isinstance(item, dict) else {}
            show = _literal(props.get("show", {}))
            if str(show).lower() == "false":
                continue
            value = _literal(props.get("value", {}))
            label = _literal(props.get("displayName", {})) or _literal(props.get("text", {}))
            color = _color_literal(props.get("lineColor", {})) or _color_literal(props.get("color", {}))
            if value is None:
                continue   # measure-bound / styling-only line — skip (no constant to plot)
            out.append({"axis": axis, "value": value,
                        "label": label, "color": color})
    return out


def _trend_line(visual):
    """PBI 'Trend line' analytics toggle (objects.trend show:true) -> {model}.
    PBI only offers a linear trend; Sigma's trendlines[].model = 'linear'."""
    for item in visual.get("objects", {}).get("trend", []):
        props = item.get("properties", {}) if isinstance(item, dict) else {}
        show = _literal(props.get("show", {}))
        if str(show).lower() == "true":
            return {"model": "linear"}
    return None


def _measure_color(visual):
    """bead (B) by-measure color: PBI 'Color saturation' / conditional fill-by-value
    on a bar/column/combo. PBIR encodes it under objects.dataPoint[].properties.fill
    as a fillRule whose gradient stops bind a measure (FieldDef/Aggregation), OR a
    flat colorSaturation. Returns {queryRef, scheme[], reverse} or None — the builder
    duplicates that measure onto a color:{by:scale} channel.

    We don't reproduce PBI's exact stops; we map to a 3-stop sequential scheme
    (low->high) and let the agent tune in Sigma. The signal we need is just WHICH
    measure drives the saturation."""
    objs = visual.get("objects", {})
    for item in objs.get("dataPoint", []) + objs.get("colorSaturation", []):
        props = item.get("properties", {}) if isinstance(item, dict) else {}
        fill = props.get("fill") or props.get("fillRule") or props.get("colorSaturation") or {}
        # the fillRule carries the driving measure under a FieldDef/Aggregation
        rule = (fill.get("fillRule") if isinstance(fill, dict) else None) or fill
        qr = _fillrule_measure(rule)
        if qr:
            stops = (rule.get("linearGradient2") or rule.get("linearGradient3") or {}) if isinstance(rule, dict) else {}
            lo = _color_literal((stops.get("min") or {}).get("color", {})) if isinstance(stops, dict) else None
            hi = _color_literal((stops.get("max") or {}).get("color", {})) if isinstance(stops, dict) else None
            scheme = [c for c in (lo, hi) if c] or ["#ffffcc", "#fd8d3c", "#bd0026"]
            return {"queryRef": qr, "scheme": scheme, "reverse": False}
    return None


def _fillrule_measure(rule):
    """The queryRef of the measure a fillRule's gradient binds, or None."""
    if not isinstance(rule, dict):
        return None
    # gradient stops nest the field under .min/.mid/.max .value, OR the rule
    # carries a top-level Aggregation/Measure under .field.
    for grad_key in ("linearGradient2", "linearGradient3"):
        grad = rule.get(grad_key)
        if isinstance(grad, dict):
            for stop in ("min", "mid", "max"):
                fld = (grad.get(stop) or {}).get("value") or (grad.get(stop) or {}).get("field")
                qr = _expr_queryref(fld) if fld else None
                if qr:
                    return qr
    fld = rule.get("field") or rule.get("expr")
    return _expr_queryref(fld) if fld else None


def _donut_label_style(visual):
    """PBI pie/donut detail-label style (objects.labels[].properties.labelStyle),
    e.g. 'Category, percent of total' / 'Data value'. Maps to Sigma donut
    dataLabel.labelDisplay so a percent-of-total donut migrates as percent, not $."""
    for item in (visual.get("objects", {}) or {}).get("labels", []):
        ls = _literal(((item or {}).get("properties", {}) or {}).get("labelStyle"))
        if ls:
            return str(ls)
    return None


def _card_value_color(visual):
    """PBI card/multiRowCard value font color (objects.labels[].properties.color)
    -> hex, or None. Style fidelity: PBI cards show the value in the theme accent;
    the builder puts this on the Sigma KPI `value.color`."""
    for item in (visual.get("objects", {}) or {}).get("labels", []):
        props = (item or {}).get("properties", {}) or {}
        c = _color_literal(props.get("color", {}) or {})
        if c:
            return c
    return None


_DISPLAY_UNITS = {
    "0": "auto", "1": "none", "1000": "thousands", "1000000": "millions",
    "1000000000": "billions", "1000000000000": "trillions",
}


def _display_units(visual):
    """PBI number display units (objects.labels/callout/calloutValue[].properties.
    labelDisplayUnits) -> 'auto'|'none'|'thousands'|'millions'|... or None.

    PBI serializes this only when NON-default, so None means the report is on the
    default 'Auto' (which abbreviates large values, e.g. '$126K'). The builder
    treats None/anything-but-'none' as abbreviate; explicit 'none' = full
    precision. (Style fidelity §5.)"""
    objs = visual.get("objects", {}) or {}
    for key in ("labels", "callout", "calloutValue", "dataLabels"):
        for item in objs.get(key, []) or []:
            props = (item or {}).get("properties", {}) or {}
            du = _literal(props.get("labelDisplayUnits"))
            if du is not None:
                return _DISPLAY_UNITS.get(str(du).split(".")[0], "auto")
    return None


def _card_alignment(visual):
    """PBI card callout horizontal alignment (objects.callout/labels[].properties.
    alignment | horizontalAlignment) -> 'left'|'center'|'right' or None. The
    builder maps it to the Sigma kpi-chart layout.anchor; None -> centered
    default (PBI stat cards center). (Style fidelity §6.)"""
    objs = visual.get("objects", {}) or {}
    for key in ("callout", "calloutValue", "labels", "general"):
        for item in objs.get(key, []) or []:
            props = (item or {}).get("properties", {}) or {}
            a = _literal(props.get("alignment") or props.get("horizontalAlignment"))
            if a:
                return str(a).lower()
    return None


def _show_totals(visual, vtype):
    """PBI matrix/tableEx show a Grand Total by default -> True; honor an explicit
    off toggle -> False. Non-table visuals -> None (irrelevant)."""
    if vtype not in ("tableEx", "tableExV2", "pivotTable", "matrix"):
        return None
    objs = visual.get("objects", {}) or {}
    for key in ("total", "grandTotal", "subTotals"):
        for item in objs.get(key, []):
            show = _literal(((item or {}).get("properties", {}) or {}).get("show"))
            if show is False or str(show).lower() == "false":
                return False
    return True  # PBI default


def _cf_color(node):
    """A color node inside a table/matrix conditional-format fill rule. PBI writes
    several shapes: a bare {Literal:{Value:"'#fff'"}}, an {expr:{Literal:...}}, a
    {solid:{color:...}}, a {color:...} wrapper, or a palette-indexed
    {ThemeDataColor:{ColorId,Percent}} (no static hex -> None). Returns hex or None."""
    if not isinstance(node, dict):
        return None
    if "ThemeDataColor" in node:
        return None  # palette-indexed; can't resolve to a hex without the theme
    lit = (node.get("Literal") or {}).get("Value")
    if lit is not None:
        s = str(lit).strip().strip("'")
        return s if s.startswith("#") else None
    for k in ("expr", "solid", "color"):
        if k in node:
            c = _cf_color(node[k])
            if c:
                return c
    return None


def _fill_rule_scheme(fill_rule):
    """Ordered low->high hex scheme from a FillRule's linearGradient2/linearGradient3
    (the PBI color-scale). Returns a list of hex stops (min[,mid],max) or None."""
    if not isinstance(fill_rule, dict):
        return None
    for key in ("linearGradient2", "linearGradient3"):
        grad = fill_rule.get(key)
        if isinstance(grad, dict):
            stops = []
            for stop in ("min", "mid", "center", "max"):
                s = grad.get(stop)
                if isinstance(s, dict):
                    c = _cf_color(s.get("color"))
                    if c:
                        stops.append(c)
            return stops or None
    return None


# PBI QueryComparisonKind -> operator. Standard enum (confirmed live via a Fabric
# round-trip): 0 Equal, 1 GreaterThan, 2 GreaterThanOrEqual, 3 LessThan, 4 LessThanOrEqual.
_CMP_OP = {0: "=", 1: ">", 2: ">=", 3: "<", 4: "<="}


def _lit_value(node):
    """A PBI literal node {Literal:{Value:"'x'"|"400D"}} -> "x" / "400" (type suffix
    D/L/M/F stripped), or None."""
    v = (node or {}).get("Literal", {}).get("Value")
    if v is None:
        return None
    s = str(v).strip()
    if s.startswith("'") and s.endswith("'"):
        return s[1:-1]
    m = __import__("re").fullmatch(r"(-?\d+(?:\.\d+)?)[DLMF]?", s)
    return m.group(1) if m else s


def _parse_comparison(cmp):
    """A PBI Comparison {ComparisonKind, Left, Right} -> {op, value, driver} or None.
    `driver` is the queryRef of the field being tested (Left) so the emitter can
    check it matches the formatted column."""
    if not isinstance(cmp, dict):
        return None
    op = _CMP_OP.get(cmp.get("ComparisonKind"))
    val = _lit_value(cmp.get("Right"))
    if op is None or val is None:
        return None
    return {"op": op, "value": val, "driver": _expr_queryref(cmp.get("Left"))}


def _parse_condition(cond):
    """A rule's Condition -> list of comparisons. A single `Comparison` -> [one];
    an `And` of two comparisons (a range band) -> [two]. Returns None for shapes
    we don't model (Or, nested boolean) so the emitter routes them to coverage."""
    if not isinstance(cond, dict):
        return None
    if "Comparison" in cond:
        c = _parse_comparison(cond["Comparison"])
        return [c] if c else None
    if "And" in cond:
        left = _parse_condition(cond["And"].get("Left"))
        right = _parse_condition(cond["And"].get("Right"))
        return (left + right) if (left and right) else None
    return None


def _parse_conditional_cases(cond):
    """A rules-based CF `Conditional` {Cases[], Default?} -> {rules:[{comparisons,color}],
    default:hex}. Each case = a Condition (1-2 comparisons) + a Value color."""
    rules = []
    for case in cond.get("Cases", []) if isinstance(cond, dict) else []:
        comps = _parse_condition((case or {}).get("Condition", {}))
        color = _cf_color((case or {}).get("Value") or {})
        if comps and color:
            rules.append({"comparisons": comps, "color": color})
    return {"rules": rules, "default": _cf_color(cond.get("Default") or {}) if isinstance(cond, dict) else None}


def _conditional_formats(visual, vtype):
    """Table/matrix conditional formatting -> normalized CF records.

    PBI stores per-column CF in the visual's `objects`, in two places:
      - objects.values[]          : backColor / fontColor cell coloring. The color
                                    expr is either a FillRule (a color-scale
                                    `linearGradient2/3`, or a rules `ruleDefinition`)
                                    or a bare Measure (field-value color — a DAX
                                    measure returns the hex directly). Scoped by
                                    selector.metadata (= the target column queryRef).
      - objects.columnFormatting[]: dataBars (in-cell bars). Same selector.
    Returns a list of {target, property, mode, ...} the builder maps to Sigma
    element-level conditionalFormats. mode ∈ gradient | fieldValue | rules | dataBars.
    Non-table visuals -> None (CF is a table/matrix feature)."""
    if vtype not in ("tableEx", "tableExV2", "pivotTable", "matrix"):
        return None
    objs = visual.get("objects", {}) or {}
    out = []
    # cell coloring: objects.values[] backColor / fontColor
    for item in objs.get("values", []):
        if not isinstance(item, dict):
            continue
        target = (item.get("selector") or {}).get("metadata")
        if not target:
            continue  # global (unscoped) style, not per-column CF
        props = item.get("properties", {}) or {}
        for prop_key, sigma_prop in (("backColor", "background"), ("fontColor", "font")):
            prop = props.get(prop_key)
            if not isinstance(prop, dict):
                continue
            expr = ((((prop.get("solid") or {}).get("color")) or {}).get("expr")) or {}
            rule = expr.get("FillRule")
            if isinstance(rule, dict):
                scheme = _fill_rule_scheme(rule.get("FillRule") or {})
                if scheme:
                    out.append({"target": target, "property": sigma_prop,
                                "mode": "gradient", "scheme": scheme,
                                "input": _expr_queryref(rule.get("Input"))})
                else:
                    # a FillRule with no gradient we recognize — surface it so the
                    # builder routes it to coverage instead of silently dropping.
                    out.append({"target": target, "property": sigma_prop,
                                "mode": "rules", "unresolved": True,
                                "input": _expr_queryref(rule.get("Input"))})
                continue
            # rules-based (thresholds): PBI serializes "Format style: Rules" as a
            # `Conditional` {Cases:[{Condition, Value(color)}], Default} expression
            # (NOT a FillRule) — confirmed against real PBIR (microsoft/fabric-toolbox).
            cond = expr.get("Conditional")
            if isinstance(cond, dict):
                parsed = _parse_conditional_cases(cond)
                rec = {"target": target, "property": sigma_prop, "mode": "rules",
                       "rules": parsed["rules"]}
                if parsed["default"]:
                    rec["default"] = parsed["default"]
                if not parsed["rules"]:
                    rec["unresolved"] = True  # Conditional we couldn't model -> coverage
                out.append(rec)
                continue
            # field-value: the color IS a measure (no wrapper). A bare
            # Literal/ThemeDataColor here is static styling, not CF -> skipped.
            mqr = _expr_queryref(expr)
            if mqr:
                out.append({"target": target, "property": sigma_prop,
                            "mode": "fieldValue", "measure": mqr})
    # data bars: objects.columnFormatting[] dataBars
    for item in objs.get("columnFormatting", []):
        if not isinstance(item, dict):
            continue
        target = (item.get("selector") or {}).get("metadata")
        db = (item.get("properties", {}) or {}).get("dataBars")
        if not target or not isinstance(db, dict):
            continue
        out.append({"target": target, "property": "background", "mode": "dataBars",
                    "positive": _color_literal(db.get("positiveColor")),
                    "negative": _color_literal(db.get("negativeColor"))})
    return out or None


def _report_theme(defn):
    """Report base-theme name (themeCollection.baseTheme.name), e.g. 'CY24SU10'.
    Drives lib/pbi_theme.rb's palette selection. None -> builder uses PBI default."""
    try:
        rep = json.load(open(os.path.join(defn, "report.json")))
        return ((rep.get("themeCollection", {}) or {}).get("baseTheme", {}) or {}).get("name")
    except Exception:
        return None


def extract(pbir_dir):
    defn = os.path.join(pbir_dir, "definition")
    if not os.path.isdir(defn):
        sys.exit(f"no definition/ under {pbir_dir} — is this a PBIR folder?")
    pages_meta = json.load(open(os.path.join(defn, "pages", "pages.json")))
    page_order = pages_meta.get("pageOrder", [])
    out_pages = []
    for pname in page_order:
        pdir = os.path.join(defn, "pages", pname)
        page = json.load(open(os.path.join(pdir, "page.json")))
        visuals = []
        vroot = os.path.join(pdir, "visuals")
        for vid in sorted(os.listdir(vroot)) if os.path.isdir(vroot) else []:
            vf = os.path.join(vroot, vid, "visual.json")
            if not os.path.exists(vf):
                continue
            v = json.load(open(vf))
            pos = v.get("position", {})
            visual = v.get("visual", {})
            vtype = visual.get("visualType", "unknown")
            qs = visual.get("query", {}).get("queryState", {})
            # per-field numeric format (queryRef -> format string), when PBIR inlines it
            formats = {}
            for _role, _blk in (qs or {}).items():
                for _p in _blk.get("projections", []):
                    if isinstance(_p, dict):
                        _qr = _p.get("queryRef") or _p.get("nativeQueryRef")
                        _f = _proj_format(_p)
                        if _qr and _f:
                            formats[_qr] = _f
            rec = {
                "visual_id": v.get("name", vid),
                "visual_type": vtype,
                "title": _visual_title(visual),
                "sigma_kind": (_vkr := _VK.resolve_or_guidance(vtype))["builder_kind"] or _vkr["role_class"],
            # role_class = what the visual DOES, so the coverage gate can tell a
            # FUNCTIONAL loss (a lost slicer = the page lost its filter) from a
            # cosmetic one; guidance names the closest Sigma construct.
            "role_class": _vkr["role_class"],
            "sigma_target": _vkr["sigma_target"],
            "viz_guidance": _vkr["guidance"],
            "viz_catalog": _vkr["catalog"],
            "approximate": _vkr["approximate"],
                "orientation": "horizontal" if vtype in HBAR_TYPES else None,
                "stacking": _stacking(vtype) if _vkr["builder_kind"] in ("bar", "area") else None,
                "x": pos.get("x", 0), "y": pos.get("y", 0),
                "w": pos.get("width", 0), "h": pos.get("height", 0),
                "z": pos.get("z", 0),
                "parent_group": v.get("parentGroupName"),
                "bindings": _role_bindings(qs),
                # bead f972: visual sort ({queryRef, direction asc|desc}) or None
                "sort": _sort_signal(visual),
                "formats": formats,
                # bead n9u9: PBI data-label toggle (objects.labels show) — true/false/None
                "data_labels": _obj_flag(visual, "labels"),
                # pie/donut detail-label style -> Sigma donut dataLabel.labelDisplay
                "label_style": _donut_label_style(visual),
                # bead ry0n: PBI legend toggle (objects.legend show) — true/false/None
                "legend": _obj_flag(visual, "legend"),
                # bead (A) reference lines: PBI analytics-pane constant lines ->
                # Sigma refMarks (wrapped value, label.visibility:'shown').
                "ref_lines": _reference_lines(visual),
                # bead (A) trend line: PBI 'Trend line' analytics toggle.
                "trend_line": _trend_line(visual),
                # bead (B) by-measure color: 'Color saturation' / FX fill-by-value
                # -> Sigma color:{by:scale, column:<dup measure>, scheme}.
                "measure_color": _measure_color(visual),
                # style fidelity: PBI card value font color -> Sigma KPI value.color
                "value_color": _card_value_color(visual),
                # style fidelity: PBI matrix/tableEx Grand Total (default on) ->
                # Sigma pivot-table totals:{showGrandTotals} (builder re-expresses a
                # grouped table as a pivot when set).
                "show_totals": _show_totals(visual, vtype),
                # style fidelity §5: PBI number display units (None = default
                # 'Auto' = abbreviate). Builder emits compact d3 `s` format on
                # KPI/chart measure columns to match PBI's "$126K" look.
                "display_units": _display_units(visual),
                # style fidelity §6: PBI card callout alignment -> KPI layout.anchor
                # (None = centered default).
                "value_align": _card_alignment(visual),
                # table/matrix conditional formatting (background/font color-scales,
                # rules, field-value measures, data bars) -> Sigma conditionalFormats.
                "conditional_formats": _conditional_formats(visual, vtype),
                # visual-level Filters-pane filters -> Sigma element filters (beads-sigma-3tx6)
                "filters": _filter_signals(v, "visual"),
            }
            if rec["sigma_kind"] == "text":
                rec["text"] = _textbox_body(visual)
            visuals.append(rec)
        visuals.sort(key=lambda r: (r["y"], r["x"]))
        # Visual-interaction overrides (slicer "edit interactions"): page.json
        # carries them as visualInteractions[{source, target, type}] ONLY when an
        # author edited them (absent = PBI defaults: slicers filter the page).
        # Normalized here so the workbook builder can honor a "NoFilter" edit
        # when wiring control targets (control-targeting wave, workstream B).
        interactions = []
        for ia in (page.get("visualInteractions") or []):
            if isinstance(ia, dict) and ia.get("source") and ia.get("target"):
                interactions.append({"source": ia["source"], "target": ia["target"],
                                     "type": str(ia.get("type", "")).lower()})
        out_pages.append({
            "page_id": page.get("name", pname),
            "page_title": page.get("displayName", pname),
            "page_w": page.get("width", 1280),
            "page_h": page.get("height", 720),
            "visuals": visuals,
            "interactions": interactions,
            # page-level Filters-pane filters -> Sigma page/master filters (beads-sigma-3tx6)
            "filters": _filter_signals(page, "page"),
        })
    # report-level filters (definition/report.json filterConfig)
    report_json = {}
    _rp = os.path.join(defn, "report.json")
    if os.path.exists(_rp):
        try:
            report_json = json.load(open(_rp))
        except Exception:
            report_json = {}
    return {"source": "pbir", "pbir_dir": pbir_dir,
            # style fidelity: report base-theme name -> Sigma themeOverrides palette
            "theme": _report_theme(defn),
            "filters": _filter_signals(report_json, "report"),
            "pages": out_pages}


# ── Report/page/visual FILTER extraction (beads-sigma-3tx6) ────────────────────
# Power BI stores real Filters-pane filters the extractor never read before, so
# migrated elements shipped UNFILTERED (over-broad data). Parse them here into
# normalized signals; the builder applies them (page/report -> master filter,
# visual -> element filter) and degrades unsupported shapes to coverage. Shapes +
# the verbatim real fixtures they were built from: refs/pbi-filter-spec.md /
# fixtures/pbir-filters.json.
_REL_TIMEUNIT = {0: "day", 1: "week", 2: "month", 3: "year"}  # INTERNAL DateSpan/DateAdd enum


def _filter_lit(node):
    """Typed literal decode for the FILTER path (bool/null preserved; text always
    from single-quotes; numeric type-suffix stripped). Separate from _lit_value so
    the conditional-formatting callers are unaffected."""
    v = (node or {}).get("Literal", {}).get("Value")
    if v is None:
        return None
    s = str(v).strip()
    if s.startswith("'") and s.endswith("'"):
        return s[1:-1].replace("''", "'")            # text — always
    low = s.lower()
    if low in ("true", "false"):
        return low == "true"
    if low == "null":
        return None
    m = re.fullmatch(r"(-?\d+(?:\.\d+)?)[dlmf]?", s, re.I)
    return m.group(1) if m else s


def _filter_target(entry):
    """queryRef of the field a filter targets: PBIR `field`, classic `expression`,
    else the first filterExpressionMetadata expression."""
    fld = entry.get("field") or entry.get("expression")
    qr = _expr_queryref(fld) if fld else None
    if not qr:
        exprs = (entry.get("filterExpressionMetadata") or {}).get("expressions") or []
        if exprs:
            qr = _expr_queryref(exprs[0])
    return qr


def _in_values(in_node):
    """In.Values rows-of-tuples -> flat value list (single-column filters)."""
    out = []
    for row in (in_node or {}).get("Values", []) or []:
        if isinstance(row, list) and row:
            out.append(_filter_lit(row[0]))
    return out


def _relative_window(where0):
    """Decode a RelativeDate Where into {anchor,n,unit,includeToday} or None.
    Between(DateAdd(-N unit)..Now) = last-N; Comparison(=DateSpan(Now,unit)) = this."""
    cond = (where0 or {}).get("Condition") or {}
    btw = cond.get("Between")
    if isinstance(btw, dict):
        lb = (((btw.get("LowerBound") or {}).get("DateSpan") or {}).get("Expression") or {})
        outer = lb.get("DateAdd") or {}
        amt, unit = outer.get("Amount"), outer.get("TimeUnit")
        if amt is not None and unit in _REL_TIMEUNIT:
            inner = ((outer.get("Expression") or {}).get("DateAdd") or {})
            include_today = inner.get("Amount") == 1 and inner.get("TimeUnit") == 0
            anchor = "last" if amt < 0 else "next"
            return {"anchor": anchor, "n": abs(int(amt)), "unit": _REL_TIMEUNIT[unit], "includeToday": include_today}
    cmp = cond.get("Comparison")
    if isinstance(cmp, dict) and cmp.get("ComparisonKind") == 0:
        ds = (cmp.get("Right") or {}).get("DateSpan") or {}
        if "Now" in (ds.get("Expression") or {}) and ds.get("TimeUnit") in _REL_TIMEUNIT:
            return {"anchor": "this", "n": 0, "unit": _REL_TIMEUNIT[ds["TimeUnit"]], "includeToday": True}
    return None


def _topn_signal(entry):
    """TopN: N from the subquery's Query.Top, ranking from its OrderBy. None if the
    slot was never configured (no subquery)."""
    for frm in ((entry.get("filter") or {}).get("From") or []):
        sub = ((frm.get("Expression") or {}).get("Subquery") or {}).get("Query")
        if isinstance(sub, dict) and sub.get("Top") is not None:
            ob = (sub.get("OrderBy") or [{}])[0]
            rank_expr = ob.get("Expression") or {}
            rank_by = _expr_queryref(rank_expr) or _expr_queryref((rank_expr.get("Aggregation") or {}).get("Expression"))
            return {"n": int(sub["Top"]),
                    "direction": "asc" if ob.get("Direction") == 1 else "desc",
                    "rankBy": rank_by}
    return None


def _is_auto_drill(entry):
    hc = entry.get("howCreated")
    if isinstance(hc, str):
        return hc.lower() in ("auto", "drill")
    return hc == 2  # int: 2=Drill (3/4=Include/Exclude carry real predicates; 0 ambiguous->keep)


def _filter_signal(entry, scope):
    """One filter entry -> a normalized signal, or None to skip (Auto/Drill)."""
    if not isinstance(entry, dict) or _is_auto_drill(entry):
        return None
    target = _filter_target(entry)
    ftype = str(entry.get("type", ""))
    inverted = str((((entry.get("objects") or {}).get("general") or [{}])[0].get("properties", {})
                    .get("isInvertedSelectionMode", {}).get("expr", {}).get("Literal", {}).get("Value", ""))).strip("'").lower() == "true"
    sig = {"scope": scope, "target": target, "raw_type": ftype}
    where = ((entry.get("filter") or {}).get("Where") or [])
    where0 = where[0] if where else None
    # no predicate persisted (field-only card / empty TopN / filters:[])
    if where0 is None:
        sig.update({"type": "list" if ftype != "TopN" else "top-n", "predicate": "none",
                    "values": [], "mode": "exclude" if inverted else "include"})
        return sig
    cond = (where0.get("Condition") or {})
    # RelativeDate
    if ftype == "RelativeDate" or "Between" in cond:
        win = _relative_window(where0)
        if win:
            sig.update({"type": "date-range", "window": win, "mode": "include"})
            return sig
    # TopN
    if ftype == "TopN":
        tn = _topn_signal(entry)
        if tn:
            sig.update({"type": "top-n", **tn, "mode": "include"})
            return sig
        sig.update({"type": "top-n", "predicate": "none"})
        return sig
    # Not(...) exclude wrapper (Not(In) / Not(Or(In,In)))
    if "Not" in cond:
        inner = (cond["Not"].get("Expression") or {})
        if "In" in inner:
            exprs = (inner["In"].get("Expressions") or [])
            if len(exprs) > 1:
                sig.update({"type": "list", "unsupported": "multi-column-key", "mode": "exclude"})
                return sig
            vals = _in_values(inner["In"])
            sig.update({"type": "list", "mode": "exclude", "values": vals})
            return sig
        sig.update({"type": "condition", "unsupported": "not-expression", "mode": "exclude"})
        return sig
    # In (include / exclude via inverted flag)
    if "In" in cond:
        exprs = (cond["In"].get("Expressions") or [])
        if len(exprs) > 1:
            sig.update({"type": "list", "unsupported": "multi-column-key"})
            return sig
        vals = _in_values(cond["In"])
        sig.update({"type": "list", "mode": "exclude" if inverted else "include", "values": vals})
        return sig
    # Contains / StartsWith text ops
    if "Contains" in cond or "StartsWith" in cond:
        op = "contains" if "Contains" in cond else "starts-with"
        node = cond.get("Contains") or cond.get("StartsWith")
        sig.update({"type": "condition", "op": op, "value": _filter_lit((node or {}).get("Right")), "mode": "include"})
        return sig
    # Comparison / And range (measure-target -> coverage)
    left_is_measure = isinstance((entry.get("field") or {}).get("Measure"), dict) or \
        isinstance((cond.get("Comparison") or {}).get("Left", {}).get("Measure"), dict)
    parsed = _parse_condition(cond)
    if parsed:
        if left_is_measure:
            sig.update({"type": "measure-filter", "condition": parsed, "unsupported": "post-aggregate"})
            return sig
        sig.update({"type": "number-range", "condition": parsed, "mode": "include"})
        return sig
    # And with a Not(==null) arm the base walker rejects, or any other tree -> coverage
    sig.update({"type": "condition", "unsupported": "unmodeled-condition"})
    return sig


def _filter_signals(container, scope):
    """Normalize a container's filters (PBIR filterConfig.filters[]) into signals.
    `container` is a page.json / visual.json-visual / report.json dict."""
    fc = container.get("filterConfig") or {}
    filters = fc.get("filters")
    if filters is None:
        raw = container.get("filters")           # classic (string) or already-list
        if isinstance(raw, str):
            try:
                raw = json.loads(raw)
            except Exception:
                raw = []
        filters = raw if isinstance(raw, list) else []
    out = []
    for entry in filters:
        s = _filter_signal(entry, scope)
        if s:
            out.append(s)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pbir-dir", default="/tmp/pbir")
    ap.add_argument("--workspace", help="fetch live report from this workspace id first")
    ap.add_argument("--report", help="fetch this report id first")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    if a.workspace and a.report:
        os.makedirs(a.pbir_dir, exist_ok=True)
        _fetch_pbir(a.workspace, a.report, a.pbir_dir)
    signals = extract(a.pbir_dir)
    out = a.out or os.path.join(a.pbir_dir, "signals.json")
    json.dump(signals, open(out, "w"), indent=2)
    nvis = sum(len(p["visuals"]) for p in signals["pages"])
    print(f"[extract-pbir] {len(signals['pages'])} page(s), {nvis} visual(s) -> {out}", file=sys.stderr)
    for p in signals["pages"]:
        for v in p["visuals"]:
            print(f"  {p['page_id']:>6} {v['visual_type']:>22} -> {v['sigma_kind']:<11} "
                  f"{ {k: vv for k, vv in v['bindings'].items()} }", file=sys.stderr)


if __name__ == "__main__":
    main()
