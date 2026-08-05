#!/usr/bin/env python3
"""Offline tests for scripts/vds_landing_lib.py (2026-07-30).

Deterministic + hermetic: stdlib only — no Tableau, no Snowflake, no
Databricks, no network. All fixture names are invented (ACME_RETAIL etc.).

Covers the collision-suffix defect class: colliding captions must land as
suffixed columns with ordinal provenance, per-logical-table projections must
resolve each table's OWN columns by ordinal (no name heuristics), the
no-collision path must be byte-stable against the legacy sanitizer, and the
shared block embedded in SKILL.md (Snowflake proc + Databricks notebook)
must be byte-identical to the lib.

Usage:  python3 scripts/test_vds_landing_lib.py
"""
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "vds_landing_lib", os.path.join(HERE, "vds_landing_lib.py"))
lib = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lib)

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")


print("Part A — hermetic import (stdlib only)")
for m in ("requests", "snowflake", "pyspark", "tableauhyperapi"):
    check(m not in sys.modules,
          f"importing vds_landing_lib does not import {m}")

print("Part B — captions_from_fields (request order = ordinal order)")
fields = [
    {"fieldCaption": "Full Date"},
    {"fieldCaption": "Order Ref"},
    {"fieldCaption": "Full-Date"},
    {"fieldCaption": "Carrier"},
    {"fieldCaption": "Full.Date"},
    {"fieldCaption": "Reason Code"},
    {"fieldCaption": "Sales", "function": "SUM", "fieldAlias": "Total Sales"},
]
caps = lib.captions_from_fields(fields)
check(caps == ["Full Date", "Order Ref", "Full-Date", "Carrier",
               "Full.Date", "Reason Code", "Total Sales"],
      "captions follow fields_json order; fieldAlias wins over fieldCaption")
try:
    lib.captions_from_fields([{"fieldCaption": "Carrier"},
                              {"fieldCaption": "Lane", "fieldAlias": "Carrier"}])
    check(False, "duplicate result caption refused")
except ValueError:
    check(True, "duplicate result caption refused")

print("Part C — colliding-caption fixture: suffixes + per-table projections")
plan = lib.build_column_plan(caps)
check([e["column"] for e in plan]
      == ["FULL_DATE", "ORDER_REF", "FULL_DATE_2", "CARRIER",
          "FULL_DATE_3", "REASON_CODE", "TOTAL_SALES"],
      "colliding captions get _2/_3 in encounter order; others untouched")
check([e["ordinal"] for e in plan] == list(range(7)),
      "ordinals are 0..n-1 in request order")
check([e["caption"] for e in plan] == caps,
      "plan preserves the original captions (caption->column provenance)")
# Three fictional logical tables of ACME_RETAIL, each with its own date-role
# caption that sanitizes to FULL_DATE. Ordinal lists come from the splitter's
# own metadata (the same order it built fields_json in) — no names involved.
orders_lt    = lib.resolve_projection(plan, [0, 1])
shipments_lt = lib.resolve_projection(plan, [2, 3])
returns_lt   = lib.resolve_projection(plan, [4, 5])
check(orders_lt == ["FULL_DATE", "ORDER_REF"],
      "ORDERS_LT projects its own date column (FULL_DATE)")
check(shipments_lt == ["FULL_DATE_2", "CARRIER"],
      "SHIPMENTS_LT projects its own date column (FULL_DATE_2), not ORDERS_LT's")
check(returns_lt == ["FULL_DATE_3", "REASON_CODE"],
      "RETURNS_LT projects its own date column (FULL_DATE_3), not ORDERS_LT's")
check(len({orders_lt[0], shipments_lt[0], returns_lt[0]}) == 3,
      "the three role tables project three DISTINCT landed columns")

print("Part D — suffixed candidate colliding with a real base name")
tricky = lib.build_column_plan(["Margin", "Margin_2", "margin"])
check([e["column"] for e in tricky] == ["MARGIN", "MARGIN_2", "MARGIN_3"],
      "collision with a pre-existing _2 base keeps counting to _3")
tricky2 = lib.build_column_plan(["Margin", "margin", "Margin_2"])
check([e["column"] for e in tricky2] == ["MARGIN", "MARGIN_2", "MARGIN_2_2"],
      "encounter order decides who owns MARGIN_2; later literal base dedupes")

print("Part E — no-collision path is byte-stable (legacy-identical)")
clean_caps = ["Order Ref", "Country/Region", "Sub-Category", "Total Sales"]
legacy = [re.sub(r'[^A-Z0-9_]', '_', c.upper()) for c in clean_caps]
p1 = lib.build_column_plan(clean_caps)
p2 = lib.build_column_plan(list(clean_caps))
check([e["column"] for e in p1] == legacy,
      "no-collision landed names byte-equal the legacy sanitizer output")
b1 = json.dumps(p1, sort_keys=True).encode("utf-8")
b2 = json.dumps(p2, sort_keys=True).encode("utf-8")
check(b1 == b2, "two independent runs serialize to identical bytes")
golden = (b'[{"caption": "Order Ref", "column": "ORDER_REF", "ordinal": 0}, '
          b'{"caption": "Country/Region", "column": "COUNTRY_REGION", "ordinal": 1}, '
          b'{"caption": "Sub-Category", "column": "SUB_CATEGORY", "ordinal": 2}, '
          b'{"caption": "Total Sales", "column": "TOTAL_SALES", "ordinal": 3}]')
check(b1 == golden, "no-collision plan matches the golden byte string")

print("Part F — resolve_projection refuses name heuristics")
try:
    lib.resolve_projection(plan, ["FULL_DATE"])
    check(False, "string (name) ordinal refused with TypeError")
except TypeError:
    check(True, "string (name) ordinal refused with TypeError")
try:
    lib.resolve_projection(plan, [True])
    check(False, "bool ordinal refused with TypeError")
except TypeError:
    check(True, "bool ordinal refused with TypeError")
for bad in (-1, len(plan)):
    try:
        lib.resolve_projection(plan, [bad])
        check(False, f"out-of-range ordinal {bad} refused with ValueError")
    except ValueError:
        check(True, f"out-of-range ordinal {bad} refused with ValueError")
check(lib.resolve_projection(plan, []) == [], "empty ordinal list -> empty projection")

print("Part G — SKILL.md embeds are byte-identical to the lib (no drift)")
BEGIN = ("# --- vds-landing shared column-plan "
         "(keep in sync with scripts/vds_landing_lib.py) ---\n")
END = "# --- end vds-landing shared column-plan ---\n"


def shared_blocks(text):
    blocks, pos = [], 0
    while True:
        s = text.find(BEGIN, pos)
        if s == -1:
            return blocks
        e = text.find(END, s)
        if e == -1:
            raise AssertionError("unterminated shared block")
        blocks.append(text[s:e + len(END)])
        pos = e + len(END)


with open(os.path.join(HERE, "vds_landing_lib.py"), encoding="utf-8") as f:
    lib_blocks = shared_blocks(f.read())
with open(os.path.join(HERE, "..", "SKILL.md"), encoding="utf-8") as f:
    md_blocks = shared_blocks(f.read())
check(len(lib_blocks) == 1, "lib carries exactly one shared block")
check(len(md_blocks) == 2,
      "SKILL.md embeds the shared block twice (Snowflake proc + Databricks notebook)")
for i, blk in enumerate(md_blocks):
    check(blk == lib_blocks[0],
          f"SKILL.md embed #{i + 1} is byte-identical to the lib's shared block")

print()
if fails:
    print(f"{len(fails)} FAILURE(S)")
    for m in fails:
        print(f"  - {m}")
    sys.exit(1)
print("ALL PASS")
