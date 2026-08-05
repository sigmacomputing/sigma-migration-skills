#!/usr/bin/env python3
"""Capture-layer unit tests: the normalizers must lift the Looker visualization column
order (vis_config.column_order) and hidden fields into the contract, WITHOUT reordering
query.fields itself (build_workbook owns display ordering).

Both source paths must agree:
  - fetch_looker_dashboard.normalize_element  (live API + Looks, via fetch_looker_look)
  - parse_lookml_dashboard.norm_element        (offline .dashboard.lookml)

Pure functions — no network, no warehouse.

Run: python3 tests/test_vis_column_order_capture.py   (exit 0 = pass)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
sys.path.insert(0, SCRIPTS)

import fetch_looker_dashboard as fd          # noqa: E402
import parse_lookml_dashboard as pl          # noqa: E402

A, B, C = "v.dim_a", "v.dim_b", "v.measure_c"


def test_api_normalize_element_captures_order_and_hidden():
    el = {"type": "vis", "query": {
        "model": "m", "view": "v",
        "fields": [A, B, C],
        "vis_config": {"type": "looker_grid", "column_order": [C, A, B],
                       "hidden_fields": [B],
                       "series_labels": {A: "Alpha", C: "Charlie"}}}}
    tile = fd.normalize_element(el, layout={"row": 0, "col": 0, "width": 24, "height": 8})
    assert tile["columnOrder"] == [C, A, B], tile["columnOrder"]
    assert tile["hiddenFields"] == [B], tile["hiddenFields"]
    assert tile["columnLabels"] == {A: "Alpha", C: "Charlie"}, tile["columnLabels"]
    assert tile["fields"] == [A, B, C], "fields (data order) must be preserved verbatim"
    print("[ok] API normalize_element: columnOrder + hiddenFields + columnLabels captured; fields intact")


def test_api_hidden_columns_alias():
    """Tolerate the legacy `hidden_columns` dict alias ({field: true})."""
    el = {"type": "vis", "query": {
        "model": "m", "view": "v", "fields": [A, B, C],
        "vis_config": {"type": "looker_grid", "hidden_columns": {B: True, C: False}}}}
    tile = fd.normalize_element(el, layout={})
    assert tile["hiddenFields"] == [B], tile["hiddenFields"]  # only truthy entries
    print("[ok] API normalize_element: hidden_columns dict alias → hiddenFields")


def test_api_absent_keys_default_empty():
    """No column_order / hidden state → empty lists (build_workbook falls back to fields)."""
    el = {"type": "vis", "query": {
        "model": "m", "view": "v", "fields": [A, B, C],
        "vis_config": {"type": "looker_grid"}}}
    tile = fd.normalize_element(el, layout={})
    assert tile["columnOrder"] == [] and tile["hiddenFields"] == [] and tile["columnLabels"] == {}, tile
    print("[ok] API normalize_element: absent keys → empty (byte-identical fallback)")


def test_lookml_norm_element_captures_order_and_hidden():
    el = {"name": "t", "type": "looker_grid", "model": "m", "explore": "v",
          "fields": [A, B, C], "column_order": [C, A, B], "hidden_fields": [B],
          "series_labels": {A: "Alpha", C: "Charlie"}}
    tile = pl.norm_element(el)
    assert tile["columnOrder"] == [C, A, B], tile["columnOrder"]
    assert tile["hiddenFields"] == [B], tile["hiddenFields"]
    assert tile["columnLabels"] == {A: "Alpha", C: "Charlie"}, tile["columnLabels"]
    assert tile["fields"] == [A, B, C]
    print("[ok] LookML norm_element: columnOrder + hiddenFields + columnLabels captured; fields intact")


def test_lookml_absent_keys_default_empty():
    el = {"name": "t", "type": "looker_grid", "model": "m", "explore": "v", "fields": [A, B, C]}
    tile = pl.norm_element(el)
    assert tile["columnOrder"] == [] and tile["hiddenFields"] == [] and tile["columnLabels"] == {}, tile
    print("[ok] LookML norm_element: absent keys → empty")


if __name__ == "__main__":
    test_api_normalize_element_captures_order_and_hidden()
    test_api_hidden_columns_alias()
    test_api_absent_keys_default_empty()
    test_lookml_norm_element_captures_order_and_hidden()
    test_lookml_absent_keys_default_empty()
    print("ALL PASS")
