# kpi_card.py — Python twin of shared/lib/kpi_card.rb. Emits the VERIFIED
# comparative KPI-card shape (a kpi-chart element with a value column AND a
# comparison column rendered as a delta badge). Consumed by the Python migration
# builders and documented as the house default in the sigma-workbooks skill. The
# emitted shape is language-neutral JSON — the .rb twin MUST emit
# sorted-key-identical output (guarded by shared/lib/testdata/kpi_card_golden.json).
#
#   import kpi_card
#   el = kpi_card.build(id="kpi-rev", name="Revenue", source_element_id="tbl-1",
#                       columns=[{"id": "rev_cur"}], value_column_id="rev_cur",
#                       comparison_column_id="rev_prior", good_direction="up")
#
# This emitter builds ONLY the kpi-chart element (a dict) — not a whole
# workbook, container, or layout — so it drops cleanly into any builder that
# lays out elements separately. Number/percent formatting is a COLUMN concern,
# not a value concern: pass it on the relevant columns[] entry, e.g.
# {"id": "rev_cur", "format": {"kind": "number", "formatString": "$,.0f"}} — it
# rides through the columns passthrough untouched.
#
# value_color=/value_font_size= are optional accent styling for the value
# itself (Task-1 GO shape: value:{columnId,color,fontSize}). Both None (the
# default) => value is just {"columnId": ...}, byte-identical to before these
# kwargs existed.
#
# Stdlib only (json); Windows-safe.

DELTA_GOOD = "#1a7f37"  # green
DELTA_BAD = "#cf222e"   # red


def build(id, name, source_element_id, columns, value_column_id,
          comparison_column_id=None,
          good_direction="up", title_color=None,
          value_color=None, value_font_size=None):
    if not id:
        raise ValueError("id required")
    if not value_column_id:
        raise ValueError("value_column_id required")

    cols = list(columns or [])
    has_cmp = bool(comparison_column_id)
    if has_cmp and not any(str(c["id"]) == str(comparison_column_id) for c in cols):
        cols = cols + [{"id": comparison_column_id}]

    name_obj = {"text": name}
    if title_color:
        name_obj["color"] = title_color

    value = {"columnId": value_column_id}
    if value_color is not None:
        value["color"] = value_color
    if value_font_size is not None:
        value["fontSize"] = value_font_size

    el = {
        "id": id,
        "kind": "kpi-chart",
        "name": name_obj,
        "source": {"kind": "table", "elementId": source_element_id},
        "columns": cols,
        "value": value,
    }

    if has_cmp:
        up = good_direction == "up"
        el["comparisonColumn"] = {"columnId": comparison_column_id}
        el["comparison"] = {
            "display": "delta",
            "colorGood": DELTA_GOOD if up else DELTA_BAD,
            "colorBad": DELTA_BAD if up else DELTA_GOOD,
        }
    return el
