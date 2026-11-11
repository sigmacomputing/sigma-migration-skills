"""Source-aware layout for semantic workbooks; never divide a narrow slicer rail.

Power BI coordinates establish ordering and side-by-side relationships, not
Sigma control heights. Keep controls compact and stack split hierarchy levels.
"""

import hashlib
# Escapes text for generated XML; nothing here parses XML.
from xml.sax.saxutils import escape  # nosemgrep: python.lang.security.use-defused-xml.use-defused-xml


def layout_id(text):
    return "layout-" + hashlib.sha256(text.encode()).hexdigest()[:12]


def apply_layout(document, signals, mapping, data_page_id):
    generated_ids = set()
    for page in signals["pages"]:
        pid = page["page_id"]
        generated_ids.update(
            (
                layout_id(pid + "/title"),
                layout_id(pid + "/header"),
                layout_id(pid + "/body"),
            )
        )
        generated_ids.update(
            layout_id(pid + "/band" + str(i)) for i in range(len(page["visuals"]))
        )
    elements = {
        e["id"]: e for e in document["elements"] if e["id"] not in generated_ids
    }
    data = next(p for p in document["pages"] if p["id"] == data_page_id)
    content_pages = [p for p in document["pages"] if p["id"] != data_page_id]
    if len(content_pages) != len(signals["pages"]):
        raise ValueError("Workbook and source page counts differ")
    pages = {
        source["page_id"]: target
        for source, target in zip(signals["pages"], content_pages)
    }
    mapped = {(m["page"], m["visual"]): m for m in mapping}
    generated = []
    xml = []

    def leaf(eid, left, right, top, bottom):
        return f'<Element elementId="{escape(eid)}" gridColumn="{left} / {right}" gridRow="{top} / {bottom}"/>'

    def section(key, top, bottom, children):
        cid = layout_id(key)
        generated.append(
            {
                "id": cid,
                "kind": "container",
                "name": key,
                "elementGap": "shown",
                "spacing": "small",
                "style": {"padding": "none"},
            }
        )
        return (
            f'<Container elementId="{cid}" type="grid" gridColumn="1 / 25" gridRow="{top} / {bottom}" '
            'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">'
            + "".join(children)
            + "</Container>"
        )

    placed = set()
    for source_page in signals["pages"]:
        pid = source_page["page_id"]
        page = pages[pid]
        page["backgroundColor"] = "#F7F8FA"
        page["pageWidth"] = "full"
        xml.append(
            f'<Page id="{page["id"]}" type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">'
        )
        visuals = sorted(source_page["visuals"], key=lambda v: (v["y"], v["x"]))
        global_controls = [
            v
            for v in visuals
            if v["visual_type"] == "slicer"
            and v.get("sync_group")
            and len(mapped[(pid, v["visual_id"])]["elementIds"]) == 1
        ][:2]
        title_id = layout_id(pid + "/title")
        title = source_page["page_title"].lstrip("0123456789 ").strip()
        generated.append({"id": title_id, "kind": "text", "body": "## " + title})
        header = [leaf(title_id, 1, 13, 1, 4)]
        for i, v in enumerate(global_controls):
            ids = mapped[(pid, v["visual_id"])]["elementIds"]
            header.append(leaf(ids[0], 13 + i * 6, 19 + i * 6, 1, 4))
            placed.add(ids[0])
            if elements[ids[0]].get("controlType") != "synced":
                elements[ids[0]]["name"] = v["bindings"]["Values"][0].split(".", 1)[-1]
        xml.append(section(pid + "/header", 1, 4, header))
        remaining = [v for v in visuals if v not in global_controls]
        rails = [
            v
            for v in remaining
            if v["visual_type"] == "slicer"
            and len(mapped[(pid, v["visual_id"])]["elementIds"]) > 1
        ]
        if rails:
            body = []
            rail_bottom = 1
            for v in rails:
                ids = mapped[(pid, v["visual_id"])]["elementIds"]
                for eid in ids:
                    body.append(leaf(eid, 1, 6, rail_bottom, rail_bottom + 3))
                    placed.add(eid)
                    rail_bottom += 4
                rail_bottom += 1
            top = 1
            for v in [v for v in remaining if v not in rails]:
                ids = mapped[(pid, v["visual_id"])]["elementIds"]
                if len(ids) != 1:
                    raise ValueError("Unexpected multi-element data visual")
                eid = ids[0]
                drill = eid + "-drill"
                if drill in elements:
                    body.append(leaf(drill, 6, 13, top, top + 3))
                    placed.add(drill)
                    top += 3
                height = 19 if elements[eid]["kind"] in ("table", "pivot-table") else 12
                body.append(leaf(eid, 6, 25, top, top + height))
                placed.add(eid)
                top += height + 1
            xml.append(section(pid + "/body", 5, 5 + max(top - 1, rail_bottom), body))
        else:
            # Connected vertical intervals form source rows. A chart beside two
            # stacked KPIs stays a single block, while the top KPI strip becomes
            # four equal-width cells without rounding-created holes.
            bands = []
            for v in remaining:
                if not bands or v["y"] >= max(x["y"] + x["h"] for x in bands[-1]) - 1:
                    bands.append([v])
                else:
                    bands[-1].append(v)
            top = 5
            for bi, band in enumerate(bands):
                band_ids = [
                    mapped[(pid, v["visual_id"])]["elementIds"][0] for v in band
                ]
                kinds = {elements[eid]["kind"] for eid in band_ids}
                height = (
                    3
                    if kinds == {"control"}
                    else (
                        5
                        if kinds == {"kpi-chart"}
                        else 17 if kinds == {"table"} else 14
                    )
                )
                lo = min(v["x"] for v in band)
                hi = max(v["x"] + v["w"] for v in band)
                ylo = min(v["y"] for v in band)
                yhi = max(v["y"] + v["h"] for v in band)
                # Round nearby source edges to a shared boundary. Gutters are
                # native Sigma element spacing, not empty grid columns.
                boundaries = sorted(
                    {v["x"] for v in band} | {v["x"] + v["w"] for v in band}
                )
                snapped = {}
                for edge in boundaries:
                    line = round((edge - lo) / (hi - lo) * 24) + 1
                    snapped[edge] = max(1, min(25, line))
                children = []
                drills = [
                    eid + "-drill" for eid in band_ids if eid + "-drill" in elements
                ]
                offset = 3 if drills else 0
                if len(drills) > 4:
                    raise ValueError("A chart band supports up to four drill selectors")
                for i, drill in enumerate(drills):
                    children.append(leaf(drill, 1 + i * 6, 7 + i * 6, 1, 4))
                    placed.add(drill)
                single_row = max(v["y"] for v in band) - ylo < 5
                if single_row:
                    ordered = sorted(zip(band, band_ids), key=lambda pair: pair[0]["x"])
                    edges = (
                        [1]
                        + [
                            round(
                                (
                                    (
                                        ordered[i - 1][0]["x"]
                                        + ordered[i - 1][0]["w"]
                                        + ordered[i][0]["x"]
                                    )
                                    / 2
                                    - lo
                                )
                                / (hi - lo)
                                * 24
                            )
                            + 1
                            for i in range(1, len(ordered))
                        ]
                        + [25]
                    )
                    for i, (v, eid) in enumerate(ordered):
                        children.append(
                            leaf(
                                eid,
                                edges[i],
                                edges[i + 1],
                                1 + offset,
                                height + 1 + offset,
                            )
                        )
                        placed.add(eid)
                else:
                    for v, eid in zip(band, band_ids):
                        left = snapped[v["x"]]
                        right = snapped[v["x"] + v["w"]]
                        row = round((v["y"] - ylo) / (yhi - ylo) * height) + 1
                        end = round((v["y"] + v["h"] - ylo) / (yhi - ylo) * height) + 1
                        children.append(
                            leaf(
                                eid,
                                left,
                                max(left + 1, right),
                                row + offset,
                                max(row + 1, end) + offset,
                            )
                        )
                        placed.add(eid)
                xml.append(
                    section(
                        pid + "/band" + str(bi), top, top + height + offset, children
                    )
                )
                top += height + offset + 1
        xml.append("</Page>")
    # Helpers belong on a genuinely hidden page, not an ignored `hidden` key.
    data.pop("hidden", None)
    data["visibility"] = "hidden"
    xml.insert(
        0,
        f'<Page id="{data["id"]}" type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">'
        + "".join(
            leaf(
                eid,
                1 + (i % 2) * 12,
                13 + (i % 2) * 12,
                (i // 2) * 10 + 1,
                (i // 2) * 10 + 11,
            )
            for i, eid in enumerate(e for e in elements if e not in placed)
        )
        + "</Page>",
    )
    document["elements"] = list(elements.values()) + generated
    document["layout"] = "\n".join(xml)
    document.setdefault("settings", {}).update(
        {
            "theme": {
                "name": "Light",
                "overrides": {
                    "categoricalScheme": ["#118DFF", "#12239E", "#E66C37"],
                    "titleFont": {
                        "fontSize": 14,
                        "fontWeight": "normal",
                        "color": "#17212B",
                    },
                    "space": {"unit": "small", "showElementPadding": "shown"},
                    "elementBorder": {"color": "#E1E5EA", "width": 1},
                    "borderRadius": "round",
                    "tableStyles": {
                        "preset": "presentation",
                        "cellSpacing": "small",
                        "gridLines": "horizontal",
                        "banding": "shown",
                    },
                },
            }
        }
    )
    for e in elements.values():
        if e["kind"] == "kpi-chart":
            e["value"].update(fontSize=32, fontWeight="bold")
            e["layout"].update(anchor="center", verticalAnchor="center")
        if e["kind"] in ("table", "pivot-table"):
            e["tableStyle"] = {
                "preset": "presentation",
                "cellSpacing": "small",
                "gridLines": "horizontal",
                "banding": "shown",
            }
        if e["kind"] in ("bar-chart", "line-chart"):
            e["xAxis"]["format"] = {"labels": {"labelAngle": 0, "fontSize": 11}}
        for c in e.get("columns", []):
            fmt = c.get("format") or {}
            if fmt.get("kind") == "number":
                fmt["displayNullAs"] = "(Blank)"
                if "%" not in fmt.get("formatString", "") and e["kind"] in (
                    "bar-chart",
                    "line-chart",
                    "kpi-chart",
                ):
                    fmt["formatString"] = ",.4s" if e["kind"] == "kpi-chart" else ",.3s"
            elif fmt.get("kind") == "datetime" and e["kind"] == "line-chart":
                fmt["formatString"] = "%b %Y"
