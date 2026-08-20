#!/usr/bin/env python3
"""Live discovery: Looker `GET /dashboards/{id}` -> the normalized dashboard
contract (refs/dashboard-contract.md). Works for user-defined AND LookML
dashboards (the API returns both as the same shape).

Auth from ~/.looker/looker.ini (client_credentials, API 4.0).

Usage:
  python3 fetch_looker_dashboard.py <dashboard_id> [out.json]
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request

import looker_api  # sibling: single source of truth for base resolution + SSL/truststore

INI = os.path.expanduser("~/.looker/looker.ini")


def _client():
    # Delegate to looker_api so the port fallback (legacy :19999 → 443), the
    # LOOKER_BASE_URL override, and the truststore SSL context all apply here too.
    base, tok, verify = looker_api.login()
    return base, tok, verify


def get(path):
    cache = getattr(get, "_cache", None)
    if cache is None:
        cache = get._cache = _client()
    base, tok, verify = cache
    req = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + tok})
    with urllib.request.urlopen(req, context=looker_api._ctx(verify), timeout=60) as r:
        return json.load(r)


def _query_of(el):
    """Return the query dict backing an element (direct query or via result_maker)."""
    if el.get("query"):
        return el["query"]
    rm = el.get("result_maker") or {}
    return rm.get("query") or {}


def _merge_of(el):
    """Merged-results tile → normalized merge block, else None. A Looker merge
    (`merge_result_id`) joins 2+ explore queries client-side on shared field
    values; the FIRST source is primary. We fetch the merge query + each source
    query so the converter can rebuild it as a Sigma join (or, until that lands,
    render the primary source and flag the rest — never silently drop columns)."""
    mid = el.get("merge_result_id")
    if not mid:
        return None
    try:
        mq = get(f"/merge_queries/{urllib.parse.quote(str(mid), safe='')}")
    except Exception as e:                     # don't fail the whole dashboard pull
        return {"id": str(mid), "error": f"could not fetch merge_query: {e}", "sourceQueries": []}
    srcs = []
    for i, sq in enumerate(mq.get("source_queries") or []):
        qid = sq.get("query_id")
        qd = {}
        if qid is not None:
            try:
                qd = get(f"/queries/{urllib.parse.quote(str(qid), safe='')}")
            except Exception:
                qd = {}
        srcs.append({
            "name": sq.get("name") or f"source_{i + 1}",
            "isPrimary": i == 0,
            "model": qd.get("model"), "explore": qd.get("view"),
            "fields": qd.get("fields") or [],
            "pivots": qd.get("pivots") or [],
            # merge_fields map this source's join field to the primary's join field
            "mergeFields": [{"sourceField": mf.get("source_field_name"),
                             "refField": mf.get("field_name")}
                            for mf in (sq.get("merge_fields") or [])],
        })
    return {"id": str(mid), "sourceQueries": srcs}


def _vis_config(el, q):
    """The active vis_config dict (query > result_maker > element)."""
    for src in (q.get("vis_config"), (el.get("result_maker") or {}).get("vis_config"), el.get("vis_config")):
        if isinstance(src, dict):
            return src
    return {}


def _vis_type(el, q):
    for src in (q.get("vis_config"), (el.get("result_maker") or {}).get("vis_config"), el.get("vis_config")):
        if isinstance(src, dict) and src.get("type"):
            return src["type"]
    return el.get("type")  # fallback ("vis"/"text")


def _reflines(vc):
    """vis_config.reference_lines[] -> normalized list (see parse_lookml_dashboard
    .norm_reflines). Looker keys: reference_type, line_value|value, range_start/
    range_end, label, color, line_width."""
    out = []
    for r in (vc.get("reference_lines") or []):
        if not isinstance(r, dict):
            continue
        out.append({
            "referenceType": (r.get("reference_type") or "line").lower(),
            "value": r.get("line_value") if r.get("line_value") is not None else r.get("value"),
            "rangeStart": r.get("range_start"), "rangeEnd": r.get("range_end"),
            "label": r.get("label"), "color": r.get("color"),
            "lineWidth": r.get("line_width"),
        })
    return out


def _color(vc):
    """vis_config color knobs -> normalized dict (series_colors / colors /
    color_application). Mirrors parse_lookml_dashboard.norm_color."""
    ca = vc.get("color_application") if isinstance(vc.get("color_application"), dict) else {}
    opts = ca.get("options") if isinstance(ca.get("options"), dict) else {}
    return {
        "seriesColors": vc.get("series_colors") if isinstance(vc.get("series_colors"), dict) else {},
        "palette": [c for c in (vc.get("colors") or []) if isinstance(c, str)],
        "colorApplication": {
            "collectionId": ca.get("collection_id"), "paletteId": ca.get("palette_id"),
            "custom": ca.get("custom") if isinstance(ca.get("custom"), dict) else None,
            "reverse": bool(opts.get("reverse")), "steps": opts.get("steps"),
        } if ca else None,
    }


def _legend(vc):
    """Documented Looker legend controls -> released Sigma legend fields."""
    hidden = vc.get("hide_legend")
    if hidden is None and vc.get("show_legend") is not None:
        hidden = not bool(vc.get("show_legend"))
    position = vc.get("legend_position")
    out = {}
    if hidden is True:
        out["visibility"] = "hidden"
    elif hidden is False:
        out["visibility"] = "shown"
    if position in ("left", "right"):
        out["position"] = position
    if position and position not in ("left", "right"):
        out["_unmappedPosition"] = position
    return out or None


def _style(vc):
    color = vc.get("background_color")
    return {"backgroundColor": color} if isinstance(color, str) and color.strip() else None


def _cell_viz(vc):
    """vis_config.series_cell_visualizations -> {fieldName: {scheme: [hex,...]|None}}
    for active in-cell data bars. Looker shape:
      {"view.field": {"is_active": true, "palette": {"palette_id"|"collection_id"|
      "custom_colors": [...]}}}.
    A field present (and not is_active:false) gets data bars; custom_colors becomes the
    Sigma low->high `scheme`, else None (let Sigma apply its default bar color).
    NOTE: Looker frequently omits this block from the dashboard/query API even when the
    render shows bars — those can't be recovered here (see build_workbook + SKILL.md)."""
    out = {}
    scv = vc.get("series_cell_visualizations")
    if not isinstance(scv, dict):
        return out
    for fld, cfg in scv.items():
        if not isinstance(cfg, dict) or cfg.get("is_active") is False:
            continue
        pal = cfg.get("palette") if isinstance(cfg.get("palette"), dict) else {}
        custom = [c for c in (pal.get("custom_colors") or []) if isinstance(c, str)]
        out[fld] = {"scheme": custom or None}
    return out


def _column_order(vc):
    """vis_config.column_order -> the VISUALIZATION column order (a list of Looker
    "view.field" names). This is the order the user set by dragging columns in a table
    viz; it differs from query.fields, which is the Data-tab order (Looker forces
    dimensions before measures there). Empty list when absent -> build_workbook falls
    back to the fields order, keeping non-reordered tiles byte-identical."""
    co = vc.get("column_order")
    return [f for f in co if isinstance(f, str)] if isinstance(co, list) else []


def _hidden_fields(vc):
    """Fields present in the query but HIDDEN from the visualization. Looker keeps a
    hidden dimension IN the query (so it still sets the GROUP-BY grain) and only hides
    the displayed column -> build_workbook keeps it in the group-by and marks the Sigma
    column hidden (never drops it, which would change the grain). Primary key is
    `hidden_fields` (list); tolerate a `hidden_columns` alias ({field: true} dict or a
    list). Empty when absent."""
    hf = vc.get("hidden_fields")
    if not isinstance(hf, list):
        hc = vc.get("hidden_columns")
        if isinstance(hc, dict):
            hf = [k for k, v in hc.items() if v]
        elif isinstance(hc, list):
            hf = hc
        else:
            hf = []
    return [f for f in hf if isinstance(f, str)]


def _series_labels(vc):
    """vis_config.series_labels -> {field: custom column label}. Looker lets you rename a
    table column in the VISUALIZATION (e.g. "Sales Region"), and that label differs from the
    Data-tab column name. Only str→str entries kept. Empty when absent -> build_workbook falls
    back to the humanized field name (byte-identical to before)."""
    sl = vc.get("series_labels")
    if not isinstance(sl, dict):
        return {}
    return {k: v for k, v in sl.items() if isinstance(k, str) and isinstance(v, str)}


def _dyn(df):
    """Looker returns dashboard_element.query.dynamic_fields as a JSON string."""
    if isinstance(df, str):
        try:
            return json.loads(df)
        except Exception:
            return []
    return df or []


def _listen(el):
    """filterName -> field, from result_maker.filterables[].listen."""
    out = {}
    rm = el.get("result_maker") or {}
    for f in rm.get("filterables") or []:
        for l in f.get("listen") or []:
            if l.get("dashboard_filter_name"):
                out[l["dashboard_filter_name"]] = l.get("field")
    return out


def normalize_element(el, layout=None):
    """One dashboard_element (or a synthesized Look tile) -> one contract tile dict,
    or None to skip. `layout` overrides the per-element layout dict (default {}).

    This is the single source of truth for tile normalization: a Look's synthesized
    element flows through here and normalizes byte-identically to a dashboard tile.
    """
    lay = layout if layout is not None else {}
    q = _query_of(el)
    # Text/markdown tiles (headers, notes) have no query/fields — capture them
    # as text elements so the builder can emit a Sigma text element.
    if el.get("type") == "text" or (not q and (el.get("title_text") or el.get("body_text"))):
        vc = _vis_config(el, q)
        return {
            "name": el.get("title") or el.get("title_text") or f"element_{el.get('id')}",
            "tileType": "text",
            "titleText": el.get("title_text"),
            "bodyText": el.get("body_text"),
            "subtitleText": el.get("subtitle_text"),
            "style": _style(vc),
            "tabName": el.get("tab_name"),
            "layout": lay,
        }
    if not q and el.get("type") in (None, "text") and not el.get("title"):
        return None
    # Merged-results tile: a `merge_result_id` joins multiple explore queries.
    # `q` (result_maker.query) is the PRIMARY source only, so render from it but
    # attach the full merge so the builder can join (or flag) the others.
    merge = _merge_of(el)
    if merge and merge.get("sourceQueries"):
        prim = next((s for s in merge["sourceQueries"] if s.get("isPrimary")), merge["sourceQueries"][0])
        if not q:                                   # fall back to the primary source query
            q = {"model": prim.get("model"), "view": prim.get("explore"),
                 "fields": prim.get("fields") or [], "pivots": prim.get("pivots") or []}
    vc = _vis_config(el, q)
    return {
        "name": el.get("title") or el.get("title_text") or f"element_{el.get('id')}",
        "tileType": _vis_type(el, q),
        "merge": merge,
        "model": q.get("model"), "explore": q.get("view"),
        "fields": q.get("fields") or [],
        "pivots": q.get("pivots") or [],
        # native small-multiples signal (looker_donut_multiples → Sigma trellis).
        # Mirrors parse_lookml_dashboard.norm_trellis so both source paths feed the
        # source-agnostic builder the same {shape, orientation} signal.
        "trellis": ({"shape": "donut_multiples", "orientation": "cols"}
                    if _vis_type(el, q) == "looker_donut_multiples" else None),
        "filters": q.get("filters") or {},
        "sorts": q.get("sorts") or [],
        "limit": int(q["limit"]) if str(q.get("limit") or "").isdigit() else q.get("limit"),
        "listen": _listen(el),
        "dynamicFields": _dyn(q.get("dynamic_fields")),
        "noteText": el.get("note_text"), "subtitleText": el.get("subtitle_text"),
        "bodyText": el.get("body_text"),
        "showComparison": bool(vc.get("show_comparison")),
        "comparisonType": vc.get("comparison_type"),
        "legend": _legend(vc),
        "style": _style(vc),
        "tabName": el.get("tab_name"),
        # chart reference lines + color encoding (vis_config) → Sigma refMarks/color
        "referenceLines": _reflines(vc),
        "color": _color(vc),
        "cellVisualizations": _cell_viz(vc),
        # table column order + hidden columns (vis_config) → build_workbook reorders
        # the displayed columns to the viz order and hides hidden ones (keeping hidden
        # dims in the group-by). Empty when absent → fields order, byte-identical.
        "columnOrder": _column_order(vc),
        "hiddenFields": _hidden_fields(vc),
        "columnLabels": _series_labels(vc),
        "layout": lay,
    }


def _explore_field_meta(model, explore):
    """GET /lookml_models/{model}/explores/{explore} -> {field_name: {category,
    aggType?, valueFormat?}}. Cached per (model, explore). Empty on any error."""
    cache = getattr(_explore_field_meta, "_c", None)
    if cache is None:
        cache = {}; _explore_field_meta._c = cache
    key = (model, explore)
    if key in cache:
        return cache[key]
    meta = {}
    if model and explore:
        try:
            ex = get("/lookml_models/%s/explores/%s" % (
                urllib.parse.quote(str(model), safe=""), urllib.parse.quote(str(explore), safe="")))
            flds = ex.get("fields") or {}
            for cat, items in (("dimension", flds.get("dimensions") or []),
                               ("measure", flds.get("measures") or [])):
                for fdef in items:
                    nm = fdef.get("name")
                    if not nm:
                        continue
                    m = {"category": cat}
                    if cat == "measure":
                        m["aggType"] = fdef.get("type")
                        # base column, kept fully-qualified ("view.col") so the
                        # workbook builder can compute the denorm suffix correctly.
                        sql = fdef.get("sql")
                        if sql:
                            m["sql"] = sql
                            r = re.search(r"\$\{(?:TABLE\}\.)?([\w.]+)\}?", sql)
                            if r:
                                col = r.group(1)
                                vw = nm.split(".")[0]
                                m["baseColumn"] = col if "." in col else "%s.%s" % (vw, col)
                    vf = fdef.get("value_format_name") or fdef.get("value_format")
                    if vf:
                        m["valueFormat"] = vf
                    meta[nm] = m
        except Exception:
            pass
    cache[key] = meta
    return meta


def build_field_meta(elements):
    """Authoritative dim/measure category per referenced field, from the explore
    metadata API + dynamic_fields hints. Returns {field: {category, aggType?,
    baseColumn?, valueFormat?}}. Empty when the API is unreachable (the caller then
    omits `fieldMeta` and build_workbook falls back to view-.lkml classification)."""
    out = {}
    for el in elements:
        em = _explore_field_meta(el.get("model"), el.get("explore"))
        for f in (el.get("fields") or []) + (el.get("pivots") or []):
            if f in em:
                out[f] = em[f]
        # dynamic_fields (table calcs / custom measures) — authoritative _kind_hint
        for dfld in (el.get("dynamicFields") or []):
            if not isinstance(dfld, dict):
                continue
            nm = (dfld.get("table_calculation") or dfld.get("measure")
                  or dfld.get("dimension") or dfld.get("name"))
            if not nm:
                continue
            kind = dfld.get("_kind_hint")
            if dfld.get("measure") or kind == "measure":
                out[nm] = {"category": "measure", "aggType": dfld.get("type") or "sum",
                           "baseColumn": dfld.get("based_on")}
            else:
                out[nm] = {"category": "dimension"}
    return out


def normalize(d):
    # active layout -> element_id -> {row,col,width,height}
    layout_mode, comp_by_el = "newspaper", {}
    for lay in d.get("dashboard_layouts", []):
        if lay.get("active"):
            layout_mode = lay.get("type", "newspaper")
            for c in lay.get("dashboard_layout_components", []):
                comp_by_el[c.get("dashboard_element_id")] = {
                    "row": c.get("row"), "col": c.get("column"),
                    "width": c.get("width"), "height": c.get("height")}

    filters = []
    for f in d.get("dashboard_filters", []):
        filters.append({
            "name": f.get("name"), "title": f.get("title"), "type": f.get("type"),
            "model": f.get("model"), "explore": f.get("explore"),
            "dimension": f.get("dimension"),
            "defaultValue": f.get("default_value"),
            "allowMultiple": f.get("allow_multiple_values"),
        })

    elements = []
    for el in d.get("dashboard_elements", []):
        tile = normalize_element(el, comp_by_el.get(el.get("id"), {}))
        if tile is not None:
            elements.append(tile)

    return {
        "id": str(d.get("id")),
        "title": d.get("title"),
        "layoutMode": layout_mode,
        "source": "api",
        "lookmlLinkId": d.get("lookml_link_id"),
        # Looker 26.4 introduced dashboard tabs. API versions that expose these
        # fields flow through; older versions simply return an empty list.
        "tabs": [{"name": t.get("name"), "label": t.get("label") or t.get("name")}
                 for t in (d.get("tabs") or []) if isinstance(t, dict) and t.get("name")],
        "style": _style(d),
        "filterPanel": {
            "location": "top" if d.get("filters_location_top", True) else "sidebar",
            "collapsed": bool(d.get("filters_bar_collapsed")),
        },
        "filters": filters,
        "elements": elements,
    }


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    did = sys.argv[1]
    d = get(f"/dashboards/{urllib.parse.quote(did, safe='')}")
    contract = normalize(d)
    out = sys.argv[2] if len(sys.argv) > 2 else None
    txt = json.dumps(contract, indent=2)
    if out:
        with open(out, "w") as f:
            f.write(txt)
        print(f"wrote {out}: {len(contract['elements'])} elements, {len(contract['filters'])} filters")
    else:
        print(txt)


if __name__ == "__main__":
    main()
