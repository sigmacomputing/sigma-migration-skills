#!/usr/bin/env python3
"""Build a complete Tableau-to-Sigma parity plan without Ruby.

The source dashboard layout is part of the contract: every displayed Tableau
data tile must map to a Sigma element and to a non-empty source CSV. The script
does not emit partial plans or composite/MCP placeholders.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import code_rep  # noqa: E402


class PlanError(RuntimeError):
    """The available artifacts cannot prove a complete parity plan."""


NON_DATA_KINDS = {"control", "text", "image", "container"}
PREFERRED_COLUMN_PREFIXES = ("x-", "c-", "y-", "y2-", "k-", "p-", "calc-")


def load_json(path: Path):
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def normalize(value) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())


def element_display_name(element: dict) -> str:
    name = element.get("name")
    if not isinstance(name, dict):
        return str(name or element.get("id") or "")
    text = str(name.get("text") or "").strip()
    if text:
        return text
    return re.sub(r"^el-", "", str(element.get("id") or "")).replace("-", " ")


def chart_zone(zone) -> bool:
    return (
        isinstance(zone, dict)
        and zone.get("kind") == "chart"
        and bool(str(zone.get("caption") or "").strip())
    )


def plotted_zone(zone) -> bool:
    if not chart_zone(zone):
        return False
    rows = zone.get("rows_shelf") if isinstance(zone.get("rows_shelf"), dict) else {}
    cols = zone.get("cols_shelf") if isinstance(zone.get("cols_shelf"), dict) else {}
    shelf_count = sum(
        int(shelf.get(key) or 0)
        for shelf in (rows, cols)
        for key in ("dim_count", "measure_count")
    )
    return bool(zone.get("measures")) or shelf_count > 0


def normalize_dashboards(raw) -> list[dict]:
    if isinstance(raw, list):
        dashboards = raw
    elif isinstance(raw, dict) and isinstance(raw.get("dashboards"), list):
        dashboards = raw["dashboards"]
    elif isinstance(raw, dict):
        dashboards = [raw]
    else:
        raise PlanError("dashboard layout must be an array or object")
    if any(not isinstance(item, dict) for item in dashboards):
        raise PlanError("dashboard layout entries must be objects")
    return dashboards


def scope_dashboards(dashboards: list[dict], scope: list[str]) -> list[dict]:
    if not scope:
        return dashboards
    selected = []
    for wanted in scope:
        wanted = wanted.strip()
        exact = [
            dashboard
            for dashboard in dashboards
            if str(dashboard.get("dashboard") or "").strip().casefold() == wanted.casefold()
        ]
        matches = exact or [
            dashboard
            for dashboard in dashboards
            if wanted.casefold() in str(dashboard.get("dashboard") or "").casefold()
        ]
        for dashboard in matches:
            if dashboard not in selected:
                selected.append(dashboard)
    if not selected:
        raise PlanError(
            "--dashboard/--page matched no source dashboard in dashboard-layout.json"
        )
    return selected


def scope_pages(spec: dict, scope: list[str]) -> list[dict]:
    pages = [
        page
        for page in code_rep.document(spec).get("pages", [])
        if isinstance(page, dict)
    ]
    if not scope:
        return pages
    selected = []
    for page in pages:
        name = str(page.get("name") or "")
        page_id = str(page.get("id") or "")
        if any(
            wanted.casefold() == name.casefold()
            or wanted.casefold() in name.casefold()
            or wanted.casefold() == page_id.casefold()
            for wanted in scope
        ):
            selected.append(page)
    if not selected:
        raise PlanError("--dashboard/--page matched no workbook page")
    return selected


def workbook_charts(spec: dict, scope: list[str], explicit_master_ids: list[str]) -> list[dict]:
    elements = code_rep.workbook_elements(spec)
    if not elements:
        raise PlanError("workbook readback contains no elements")
    pages = scope_pages(spec, scope)
    if scope:
        page_ids = {str(page.get("id") or "") for page in pages}
        page_by_element = code_rep.workbook_page_by_element(spec)
        scoped = [
            element
            for element in elements
            if str((page_by_element.get(element.get("id")) or {}).get("id") or "")
            in page_ids
        ]
    else:
        scoped = elements

    if explicit_master_ids:
        masters = set(explicit_master_ids)
    else:
        masters = {
            str(element.get("id"))
            for element in elements
            if element.get("kind") == "table"
            and element.get("visibleAsSource") is False
            and (element.get("source") or {}).get("kind") == "data-model"
        }
        if not masters:
            masters = {
                str(element.get("id"))
                for element in elements
                if str(element.get("id") or "").startswith("master")
            }

    changed = True
    while changed:
        changed = False
        for element in elements:
            source = element.get("source") or {}
            element_id = str(element.get("id") or "")
            if (
                element.get("kind") == "table"
                and element.get("visibleAsSource") is False
                and source.get("elementId") in masters
                and element_id not in masters
            ):
                masters.add(element_id)
                changed = True

    charts = []
    for element in scoped:
        element_id = str(element.get("id") or "")
        if element_id in masters or element.get("kind") in NON_DATA_KINDS:
            continue
        source = element.get("source") or {}
        from_master = source.get("elementId") in masters
        from_model = source.get("kind") == "data-model"
        if from_master or from_model:
            charts.append(element)
    if not charts:
        raise PlanError("workbook readback has no displayed data elements in scope")
    return charts


def workbook_views(get_workbook: dict) -> list[dict]:
    raw = (get_workbook.get("views") or {}).get("view", [])
    views = raw if isinstance(raw, list) else [raw]
    if any(not isinstance(view, dict) for view in views):
        raise PlanError("get-workbook.json views must be objects")
    if any(not str(view.get("id") or "") or not str(view.get("name") or "") for view in views):
        raise PlanError("every Tableau view must have a non-empty id and name")
    names = [str(view["name"]) for view in views]
    if len(set(names)) != len(names):
        raise PlanError("get-workbook.json contains duplicate Tableau view names")
    return views


def unique_view_match(views: list[dict], wanted: str) -> dict:
    exact = [view for view in views if str(view["name"]) == wanted]
    candidates = exact or [
        view for view in views if normalize(view["name"]) == normalize(wanted)
    ]
    if not candidates:
        raise PlanError(f"no Tableau view matches {wanted!r}")
    if len(candidates) != 1:
        raise PlanError(f"ambiguous Tableau view match for {wanted!r}")
    return candidates[0]


def parse_cell(value):
    if value is None or str(value).strip() == "":
        return None
    text = str(value).strip()
    percent = text.endswith("%")
    try:
        number = float(re.sub(r"[,$%]", "", text))
    except ValueError:
        return value
    return number / 100.0 if percent else number


def read_expected_csv(path: Path, chart_name: str, with_dimension_count: bool = False):
    if not path.is_file():
        raise PlanError(f"displayed tile {chart_name!r} is missing source CSV {path}")
    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.reader(handle))
    if not rows or not rows[0]:
        raise PlanError(f"displayed tile {chart_name!r} has an empty source CSV")
    header, body = rows[0], rows[1:]
    if not body:
        raise PlanError(
            f"displayed tile {chart_name!r} has zero source data rows; refusing a vacuous plan"
        )
    if any(len(row) != len(header) for row in body):
        raise PlanError(f"displayed tile {chart_name!r} has ragged source CSV rows")

    measure_names = next(
        (index for index, name in enumerate(header) if name.strip().casefold() == "measure names"),
        None,
    )
    measure_values = next(
        (index for index, name in enumerate(header) if name.strip().casefold() == "measure values"),
        None,
    )
    dimension_count = 0 if len(header) == 1 else 1
    if measure_names is not None and measure_values is not None:
        dimensions = [index for index in range(len(header)) if index not in (measure_names, measure_values)]
        dimension_count = len(dimensions)
        labels = []
        wide = {}
        order = []
        for row in body:
            # a table calc's label carries its addressing ("Rank - Mo along Table (Down)");
            # the Sigma column is named for the calc itself, so pivot under the base name
            label = strip_tc_addressing(row[measure_names])
            if label and label not in labels:
                labels.append(label)
            key = tuple(row[index] for index in dimensions)
            if key not in wide:
                wide[key] = {}
                order.append(key)
            if not label or label in wide[key]:
                raise PlanError(f"source export reshape refused for {chart_name!r}: empty or duplicate measure cell; resolve source grain explicitly")
            wide[key][label] = row[measure_values]
        header = [*(header[index] for index in dimensions), *labels]
        body = [[*key, *(wide[key].get(label) for label in labels)] for key in order]

    expected = [
        [
            parse_cell(value)
            if index >= dimension_count
            else (None if value.strip() == "" else value)
            for index, value in enumerate(row)
        ]
        for row in body
    ]
    if with_dimension_count:
        return header, expected, dimension_count
    return header, expected


def strip_tc_addressing(header: str) -> str:
    # a table calc's addressing tail ("Rank along Table (Down)") is not part of its name
    return re.sub(
        r"\s+along\s+(?:(?:Table|Pane|Cell)\b(?:\s*\([^)]*\))?|[^()\[\]]+)\s*$",
        "",
        str(header),
        flags=re.I,
    ).strip()


def header_base(header: str) -> str:
    value = strip_tc_addressing(header)
    value = re.sub(
        r"^(?:sum|avg|average|min|max|median|distinct count|count) of ",
        "",
        value,
        flags=re.I,
    )
    value = re.sub(r"^(?:avg|sum|min|max|med|cnt|ctd)\.\s*", "", value, flags=re.I)
    value = re.sub(
        r"^(?:second|minute|hour|day|week|month|quarter|year) of ",
        "",
        value,
        flags=re.I,
    )
    return value.strip()


def vc_split(header: str) -> tuple[str, list[str]]:
    """Split "<field> (<table> (<schema>.<table>))" (possibly repeated) into (field, [table, ...])."""
    current = str(header).strip()
    tables: list[str] = []
    pattern = re.compile(r"^(.*\S)\s*\(([^()]*)\(([^()]*\.[^()]*)\)\s*\)$", re.S)
    while True:
        match = pattern.match(current)
        if not match:
            return current, tables
        tables.append(match.group(2).strip())
        current = match.group(1).strip()


GENERATED_GEO = re.compile(
    r"^(?:latitude|longitude|country|state|state/province|county|city|postcode|zip code|region|continent)\s*\(generated\)$",
    re.I,
)
FLAG_VALUES = {"true", "false", "yes", "no"}


TOOLTIP_GUID = re.compile(r"\[(?:[a-z]+:)?([^:\]\[]+)(?::[a-z]+)?\]$", re.I)


def field_guids(value: object) -> list[str]:
    if isinstance(value, dict):
        return [guid for item in value.values() for guid in field_guids(item)]
    if isinstance(value, list):
        return [guid for item in value for guid in field_guids(item)]
    match = TOOLTIP_GUID.search(str(value))
    return [match.group(1)] if match else []


def tooltip_only_captions(dashboards: list[dict], meta: dict, worksheet: str) -> list[str]:
    """Fields the worksheet's zone carries ONLY on its tooltip (no plotted
    channel, no shelf): a Tableau view CSV exports them, a Sigma element has
    no counterpart column (tooltips are UI-only). Mirrors lib/tooltip_fields.rb."""
    zone = next(
        (
            z
            for d in dashboards
            for z in (d.get("zones") or [])
            if isinstance(z, dict) and str(z.get("caption") or "") == str(worksheet) and z.get("tooltip_fields")
        ),
        None,
    )
    if not zone:
        return []
    # Plotted = a non-tooltip marks-card channel or a rows/columns shelf
    # (measures / aggregations / calculations list every marks-card field).
    channels = zone.get("channels") if isinstance(zone.get("channels"), dict) else {}
    plotted = {k: v for k, v in channels.items() if k != "tooltip"}
    elsewhere = set(field_guids([plotted, zone.get("rows_shelf"), zone.get("cols_shelf")]))
    by_guid = meta.get("columns_by_guid") if isinstance(meta.get("columns_by_guid"), dict) else {}
    out: list[str] = []
    for ref in zone.get("tooltip_fields") or []:
        match = TOOLTIP_GUID.search(str(ref))
        if not match or match.group(1) in elsewhere:
            continue
        column = by_guid.get(match.group(1))
        caption = column.get("caption") if isinstance(column, dict) else None
        caption = caption or match.group(1)
        if caption not in out:
            out.append(caption)
    return out


def drop_unplotted_columns(
    element: dict, header: list[str], body: list[list[str]], tooltip_only: list[str] | None = None
) -> tuple[list[str], list[list[str]], list[dict]]:
    """Drop export columns that have no Sigma counterpart AND are provably
    Tableau-generated geo columns or formatting-only flags. Every drop is
    returned as {header, reason}; anything else is left for select_columns to
    resolve (or abort on)."""
    if len(header) < 2:
        return header, body, []
    skipped: list[dict] = []
    keep: list[int] = []
    for index, name in enumerate(header):
        reason = None
        if select_columns(element, [name], probe=True, all_headers=header) is None:
            values = [str(row[index]).strip() for row in body if row[index] is not None and str(row[index]).strip()]
            if GENERATED_GEO.match(str(name).strip()):
                reason = "Tableau-generated geographic column; no Sigma counterpart"
            elif any(
                cap.casefold() in {header_base(vc_split(name)[0]).casefold(), str(name).strip().casefold()}
                for cap in (tooltip_only or [])
            ):
                reason = (
                    "Tableau tooltip-only field (on the tooltip, no plotted channel); Sigma tooltips are "
                    "UI-only, so the element has no counterpart column"
                )
            elif values and all(value.lower() in FLAG_VALUES for value in values):
                reason = "formatting-only flag column (boolean/constant text values, not a plotted field of the Sigma element)"
        if reason:
            skipped.append({"header": name, "reason": reason})
        else:
            keep.append(index)
    if not skipped:
        return header, body, []
    return [header[i] for i in keep], [[row[i] for i in keep] for row in body], skipped


def project_plotted_columns(
    element: dict, columns: list[str], expected: list[list], dimension_count: int
) -> tuple[list[str], list[list], list[str]]:
    """Pie / donut: keep only the plotted color + value columns.

    Sigma's element export and MCP query return only a pie's plotted channels,
    so a matched-but-unplotted column (a "% of total" label kept after a bar ->
    pie convert_to) could never be collected. Drop unplotted MEASURE columns
    (at or after the CSV's dimension count, every cell numeric or blank; the
    same rule as the Ruby builder) from the plan and expected rows; an unplotted
    dimension would change the grain, so the plan is then left as is.
    Mirrors auto-parity-plan.rb.
    """
    if element.get("kind") not in ("pie-chart", "donut-chart"):
        return columns, expected, []
    encoded = [
        (element.get(channel) or {}).get("columnId")
        for channel in ("color", "value")
        if isinstance(element.get(channel), dict)
    ]
    encoded = [column for column in encoded if column]
    drop = [index for index, column in enumerate(columns) if column not in encoded]
    measure_only = bool(expected) and all(
        index >= dimension_count
        and all(row[index] is None or isinstance(row[index], (int, float)) for row in expected)
        for index in drop
    )
    if len(encoded) != 2 or not all(column in columns for column in encoded) or not drop or not measure_only:
        return columns, expected, []
    keep = [index for index in range(len(columns)) if index not in drop]
    return (
        [columns[index] for index in keep],
        [[row[index] for index in keep] for row in expected],
        [columns[index] for index in drop],
    )


def select_columns(element: dict, headers: list[str], probe: bool = False, all_headers: list[str] | None = None):
    all_columns = [
        column for column in (element.get("columns") or []) if isinstance(column, dict)
    ]
    # The data model disambiguates a VC field shared by several tables as
    # "<field> (<table>)" while the export header carries the fully qualified
    # "<field> (<table> (<schema>.<table>))": match the forms BOTH ways. A
    # Sigma-side "(<x>)" suffix is only peeled when <x> is a VC table named by
    # some export header or element column, so "Revenue (USD)" never collapses.
    known_tables = {
        table.strip().casefold()
        for text in list(all_headers or headers) + [str(c.get("name") or "") for c in all_columns]
        for table in vc_split(text)[1]
        if table.strip()
    }

    def column_forms(name: str) -> set[str]:
        forms = {name, strip_tc_addressing(name)}
        vc_base, _ = vc_split(name)
        forms.add(vc_base)
        match = re.match(r"^(.*\S)\s*\(([^()]+)\)$", vc_base)
        if match and match.group(2).strip().casefold() in known_tables:
            forms.add(match.group(1))
        return {form.strip().casefold() for form in forms}

    selected = []
    for header in headers:
        stripped, vc_tables = vc_split(header)
        base = header_base(stripped)
        header_forms = {str(header).strip(), stripped, base}
        for table in vc_tables:
            header_forms.update({f"{stripped} ({table})", f"{base} ({table})"})
        header_forms = {form.strip().casefold() for form in header_forms}
        # A table keeps Tableau's full header ("Rank - Mo along Table (Down)") as its column
        # name while the pivoted CSV header is the base name, so match the column's base too.
        candidates = [
            column
            for column in all_columns
            if str(column.get("name") or "").strip().casefold()
            in {str(header).strip().casefold(), stripped.casefold(), base.casefold()}
            or strip_tc_addressing(str(column.get("name") or "")).casefold() == base.casefold()
            or column_forms(str(column.get("name") or "").strip()) & header_forms
        ]
        if len(candidates) > 1 and vc_tables:
            # ambiguous base name: the table qualifier disambiguates
            by_table = [
                column
                for column in candidates
                if any(
                    table and table.casefold() in " ".join(
                        str(column.get(key) or "") for key in ("name", "table", "source", "id")
                    ).casefold()
                    for table in vc_tables
                )
            ]
            candidates = by_table or candidates
        def rank(column):
            return (str(column.get("name") or "").strip().casefold() != str(header).strip().casefold(), next(
                (
                    index
                    for index, prefix in enumerate(PREFERRED_COLUMN_PREFIXES)
                    if str(column.get("id") or "").startswith(prefix)
                ),
                99,
            ))
        candidates.sort(key=rank)
        if len(candidates) > 1 and rank(candidates[0]) == rank(candidates[1]):
            raise PlanError(f"ambiguous source column {header!r} on Sigma element {element.get('id')!r}")
        selected.append(candidates[0] if candidates else None)
    if probe:
        return selected[0]
    if all(selected) and len({column["id"] for column in selected}) == len(headers):
        return [column["id"] for column in selected]
    if element.get("kind") == "kpi-chart" and len(all_columns) == 1 and len(headers) == 1:
        return [all_columns[0]["id"]]

    raise PlanError(f"source export column identity is unresolved for Sigma element {element.get('id')!r}: {headers!r}; positional guessing is not parity evidence")


def layout_renames(dashboards: list[dict]) -> dict[str, str]:
    renames = {}
    for dashboard in dashboards:
        for zone in dashboard.get("zones") or []:
            if not isinstance(zone, dict):
                continue
            caption = str(zone.get("caption") or "")
            display = str(zone.get("display_title") or "").strip()
            if caption and display and caption != display:
                renames.setdefault(caption, display)
    return renames


CARRIED_LEDGER_FILE = "carried-calc-filters.json"
CARRIED_NOTE = "carried by build-charts-from-signals.rb"


def load_carried_ledger(tableau_dir: Path) -> list[dict]:
    """Calc-filters build-charts-from-signals.rb carried onto a Sigma element.

    Absent or unreadable ledger = [] = no auto-resolution (the gate stays manual).
    """
    path = tableau_dir / CARRIED_LEDGER_FILE
    if not path.is_file():
        return []
    try:
        data = load_json(path)
    except (OSError, ValueError):
        return []
    entries = data.get("entries") if isinstance(data, dict) else None
    return [e for e in entries if isinstance(e, dict)] if isinstance(entries, list) else []


def same_filter_definition(left: dict, right: dict) -> bool:
    # The carry-forward fingerprint: a changed definition never inherits a resolution.
    return (
        str(left.get("filter_type") or "") == str(right.get("filter_type") or "")
        and sorted(map(str, left.get("members") or []))
        == sorted(map(str, right.get("members") or []))
        and str(left.get("min") or "") == str(right.get("min") or "")
        and str(left.get("max") or "") == str(right.get("max") or "")
    )


def carried_ledger_match(
    entry: dict,
    ledger: list[dict],
    dashboard: str | None = None,
    same_definition: bool = True,
) -> dict | None:
    """The ledger entry that carried this hidden filter, or None.

    Tile matches exactly (caption whitespace is part of the key); then calc_ref,
    or the calc caption when either side has no calc_ref. A ledger entry for
    another dashboard (when both name one) does not count.
    """
    for item in ledger:
        if str(item.get("worksheet") or "") != str(entry.get("tile") or ""):
            continue
        if dashboard and item.get("dashboard") and item.get("dashboard") != dashboard:
            continue
        if entry.get("calc_ref") and item.get("calc_ref"):
            same_calc = entry["calc_ref"] == item["calc_ref"]
        elif entry.get("caption") and item.get("calc_caption"):
            same_calc = entry["caption"] == item["calc_caption"]
        else:
            same_calc = False
        if same_calc and (not same_definition or same_filter_definition(entry, item)):
            return item
    return None


def hidden_filters(
    dashboards: list[dict],
    prior_output: dict | None,
    carried_ledger: list[dict] | None = None,
) -> list[dict]:
    prior = {}
    for item in (prior_output or {}).get("hidden_filters", []):
        if isinstance(item, dict) and item.get("status") in {"translated", "waived"}:
            prior[(item.get("tile"), item.get("calc_ref"))] = item

    def norm(text) -> str:
        return re.sub(r"[^a-z0-9]", "", str(text or "").lower())

    output = []
    for dashboard in dashboards:
        # A worksheet filter whose field is ALSO a quick filter on this
        # dashboard is not hidden - it is the visible control's own filter.
        # Left at "All" (a plain member list with no members) it restricts
        # nothing. A restrictive one still gates, and so do wildcard, condition
        # and top-N filters, which also carry an empty member list.
        quick_filter_caps = {
            norm(z.get("filter_column_caption"))
            for z in dashboard.get("zones") or []
            if z.get("kind") == "filter"
        }
        for zone in dashboard.get("zones") or []:
            if not chart_zone(zone):
                continue
            for item in zone.get("hidden_filters") or []:
                if not isinstance(item, dict):
                    continue
                if (
                    str(item.get("filter_type") or "") == "categorical"
                    and str(item.get("kind") or "") == "list"
                    and not item.get("topn")
                    and not item.get("members")
                    and item.get("min") is None
                    and item.get("max") is None
                    and norm(item.get("caption")) in quick_filter_caps
                ):
                    continue
                entry = {
                    "tile": zone.get("caption"),
                    "calc_ref": item.get("calc_ref"),
                    "caption": item.get("caption"),
                    "filter_type": item.get("filter_type"),
                    "members": item.get("members"),
                    "min": item.get("min"),
                    "max": item.get("max"),
                    "status": "unresolved",
                }
                entry = {key: value for key, value in entry.items() if value is not None}
                previous = prior.get((entry.get("tile"), entry.get("calc_ref")))
                if previous and all(
                    (
                        str(previous.get("filter_type") or "")
                        == str(entry.get("filter_type") or ""),
                        sorted(map(str, previous.get("members") or []))
                        == sorted(map(str, entry.get("members") or [])),
                        str(previous.get("min") or "") == str(entry.get("min") or ""),
                        str(previous.get("max") or "") == str(entry.get("max") or ""),
                    )
                ):
                    entry["status"] = previous["status"]
                    for key in ("waive_reason", "translation", "translated_to", "note"):
                        if previous.get(key) is not None:
                            entry[key] = previous[key]
                # Machine handoff: a filter the builder already put on a Sigma element
                # (same tile + calc, SAME definition) resolves without a human edit.
                if entry["status"] == "unresolved" and carried_ledger:
                    carried = carried_ledger_match(
                        entry, carried_ledger, dashboard.get("dashboard")
                    )
                    if carried:
                        entry["status"] = "translated"
                        entry["translated_to"] = str(
                            carried.get("sigma_formula")
                            or carried.get("sigma_column")
                            or carried.get("mode")
                            or ""
                        )
                        entry["note"] = CARRIED_NOTE
                    elif carried_ledger_match(
                        entry, carried_ledger, dashboard.get("dashboard"), False
                    ):
                        print(
                            f"hidden_filters gate: [{entry.get('tile')}] "
                            f"{entry.get('calc_ref')} was carried but its definition "
                            "CHANGED since the build - NOT auto-resolved",
                            file=sys.stderr,
                        )
                output.append(entry)
    return output


def build_plan(
    tableau_dir: Path,
    workbook_spec_path: Path,
    *,
    workbook_id: str | None = None,
    renames: dict[str, str] | None = None,
    master_ids: list[str] | None = None,
    dashboards_scope: list[str] | None = None,
    prior_output: dict | None = None,
) -> dict:
    scope = dashboards_scope or []
    get_workbook = load_json(tableau_dir / "get-workbook.json")
    views = workbook_views(get_workbook)
    spec = load_json(workbook_spec_path)
    raw_layout = load_json(tableau_dir / "dashboard-layout.json")
    all_dashboards = normalize_dashboards(raw_layout)
    scoped_dashboards = scope_dashboards(all_dashboards, scope)
    source_zones = [
        zone
        for dashboard in scoped_dashboards
        for zone in (dashboard.get("zones") or [])
        if plotted_zone(zone)
    ]
    if not source_zones:
        raise PlanError("source layout has no displayed data tiles in scope")
    source_names = list(
        dict.fromkeys(str(zone["caption"]).strip() for zone in source_zones)
    )
    source_norms = {normalize(name) for name in source_names}

    effective_renames = layout_renames(all_dashboards)
    effective_renames.update(renames or {})
    reverse_renames = {target: source for source, target in effective_renames.items()}
    provenance_path = tableau_dir / "chart-provenance.json"
    provenance = {}
    if provenance_path.is_file():
        raw_provenance = load_json(provenance_path)
        if not isinstance(raw_provenance, dict) or not isinstance(
            raw_provenance.get("elements"), dict
        ):
            raise PlanError("chart-provenance.json must contain an elements object")
        provenance = raw_provenance["elements"]

    meta_path = tableau_dir / "dashboard-layout-meta.json"
    try:
        layout_meta = load_json(meta_path) if meta_path.is_file() else {}
    except Exception:
        layout_meta = {}
    if not isinstance(layout_meta, dict):
        layout_meta = {}

    charts = workbook_charts(spec, scope, master_ids or [])
    entries = []
    for element in charts:
        sigma_name = element_display_name(element)
        element_id = str(element.get("id") or "")
        provenance_entry = provenance.get(element_id)
        if isinstance(provenance_entry, dict) and str(
            provenance_entry.get("worksheet") or ""
        ).strip():
            tableau_name = str(provenance_entry["worksheet"])
            matched_via = "provenance"
        else:
            tableau_name = reverse_renames.get(sigma_name, sigma_name)
            matched_via = "name-fallback"
        view = unique_view_match(views, tableau_name)
        if normalize(view["name"]) not in source_norms:
            raise PlanError(
                f"Sigma displayed element {element_id!r} maps to Tableau view "
                f"{view['name']!r}, which is not a displayed source tile in scope"
            )
        header, expected, dimension_count = read_expected_csv(
            tableau_dir / "views" / f"{view['id']}.csv", sigma_name, with_dimension_count=True
        )
        header, expected, skipped_columns = drop_unplotted_columns(
            element, header, expected, tooltip_only_captions(all_dashboards, layout_meta, tableau_name)
        )
        columns = select_columns(element, header)
        names_by_id = {column["id"]: column.get("name") for column in element.get("columns", [])}
        columns, expected, unplotted = project_plotted_columns(element, columns, expected, dimension_count)
        entry = {
            "chart": sigma_name,
            "tableau_view": view["name"],
            "sigma_element_id": element_id,
            "sigma_kind": element.get("kind"),
            "sigma_columns": columns,
            "sigma_column_names": [names_by_id[column] for column in columns],
            "matched_via": matched_via,
            "expected": expected,
        }
        if unplotted:
            entry["unplotted_columns"] = [names_by_id.get(column, column) for column in unplotted]
        if skipped_columns:
            entry["skipped_columns"] = skipped_columns
        if workbook_id:
            select = ", ".join(
                f'"{column}" AS f{index}' for index, column in enumerate(columns)
            )
            entry["sql_template"] = (
                f'SELECT {select} FROM "workbook"."{element_id}" ORDER BY 1'
            )
            entry["workbookId"] = workbook_id
        entries.append(entry)

    matched_source = {normalize(entry["tableau_view"]) for entry in entries}
    missing = [name for name in source_names if normalize(name) not in matched_source]
    if missing:
        raise PlanError(
            "displayed source tile(s) have no Sigma parity element: "
            + ", ".join(repr(name) for name in missing)
        )
    chart_names = [entry["chart"] for entry in entries]
    duplicates = sorted({name for name in chart_names if chart_names.count(name) > 1})
    if duplicates:
        raise PlanError(
            "duplicate Sigma chart names cannot be represented by the existing "
            "name-keyed parity-actuals contract: " + ", ".join(repr(name) for name in duplicates)
        )

    filters = hidden_filters(
        scoped_dashboards, prior_output, load_carried_ledger(tableau_dir)
    )
    unresolved = [
        item for item in filters if item.get("status") not in {"translated", "waived"}
    ]
    csv_files = list((tableau_dir / "views").glob("*.csv"))
    csv_mtime = max((int(path.stat().st_mtime) for path in csv_files), default=0)
    extract = get_workbook.get("hasExtracts") is True or str(
        get_workbook.get("hasExtracts")
    ).lower() == "true"
    return {
        "extract": extract,
        "charts": entries,
        "hidden_filters": filters,
        "plan_status": "needs_review" if unresolved else "green",
        "composite_stub": False,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source_csv_max_mtime": csv_mtime,
        "dashboards_scope": scope,
    }


def atomic_write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def parse_rename(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("--rename must be TABLEAU=SIGMA")
    source, target = value.split("=", 1)
    if not source or not target:
        raise argparse.ArgumentTypeError("--rename sides must be non-empty")
    return source, target


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tableau", required=True)
    parser.add_argument("--workbook-spec", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--workbook-id")
    parser.add_argument("--master-id", action="append", default=[])
    parser.add_argument("--rename", action="append", type=parse_rename, default=[])
    parser.add_argument("--dashboard", "--page", action="append", default=[])
    parser.add_argument(
        "--no-fetch",
        action="store_true",
        help="compatibility flag; this builder never fetches actuals",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    out_path = Path(args.out)
    try:
        prior = load_json(out_path) if out_path.is_file() else None
        plan = build_plan(
            Path(args.tableau),
            Path(args.workbook_spec),
            workbook_id=args.workbook_id,
            renames=dict(args.rename),
            master_ids=args.master_id,
            dashboards_scope=args.dashboard,
            prior_output=prior,
        )
        atomic_write_json(out_path, plan)
    except (OSError, ValueError, json.JSONDecodeError, PlanError) as exc:
        print(f"FATAL: parity plan incomplete: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {out_path}")
    print(f"  charts matched: {len(plan['charts'])}")
    print(f"  extract flag:   {plan['extract']}")
    print("  actuals: collect with collect-parity-actuals.py (Sigma REST export)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
