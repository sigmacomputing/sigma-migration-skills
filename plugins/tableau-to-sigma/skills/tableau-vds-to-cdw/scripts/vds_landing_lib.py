#!/usr/bin/env python3
"""Pure column-plan layer for the VDS -> CDW landing (2026-07-30).

Why this exists: the historical landing sanitizer
(`re.sub(r'[^A-Z0-9_]', '_', caption.upper())`) did NO collision bookkeeping.
Two distinct captions that sanitize to the same name (e.g. "Full Date",
"Full-Date", "Full.Date" -> FULL_DATE) produced duplicate column names —
a CREATE TABLE duplicate-column error on Snowflake, or silent column loss
via dict(zip(...)) on both targets. And because no caption->column provenance
was exported, any downstream per-logical-table splitter was forced into name
heuristics that cannot see the collision at all.

This module is the single source of truth for the fix:

  * `captions_from_fields`  — result-column captions in fields_json request
    order (fieldAlias wins over fieldCaption). The index in this list is the
    field's ORDINAL — the positional provenance key for everything downstream.
  * `build_column_plan`     — deterministic collision-suffix assignment
    (first occurrence keeps the base name; later collisions get _2, _3 in
    encounter order) plus the ordinal->column manifest rows.
  * `resolve_projection`    — per-logical-table column resolution that
    consumes ONLY ordinals. No caption re-sanitization, no name heuristics:
    a splitter that knows which field positions belong to a logical table
    gets that table's OWN landed columns, suffixes included.

The Snowflake proc and Databricks notebook in ../SKILL.md embed the shared
block below verbatim (server-side code cannot import repo files);
scripts/test_vds_landing_lib.py asserts both embeds are byte-identical to
this file, so the shipped code is exactly the tested code.

Hermetic: stdlib only. Usage: python3 scripts/test_vds_landing_lib.py
"""
import re

# --- vds-landing shared column-plan (keep in sync with scripts/vds_landing_lib.py) ---
def sanitize_caption(caption):
    # Legacy UPPER_SNAKE sanitizer — byte-identical to the historical one.
    return re.sub(r'[^A-Z0-9_]', '_', caption.upper())

def captions_from_fields(fields):
    # Result captions in fields_json request order (= ordinal order). VDS keys
    # OBJECTS rows by fieldAlias else fieldCaption; duplicate result captions
    # collapse into one dict key (positionally unrecoverable) — refuse.
    caps = [f.get('fieldAlias') or f['fieldCaption'] for f in fields]
    seen = set()
    for c in caps:
        if c in seen:
            raise ValueError('duplicate result caption %r in fields — '
                             'positional recovery impossible; fix the request' % c)
        seen.add(c)
    return caps

def build_column_plan(captions):
    # plan[i] = {'ordinal': i, 'caption': captions[i], 'column': landed name}.
    # First occurrence of a sanitized base keeps it; later collisions get _2,
    # _3, ... in encounter order; a suffixed candidate that itself collides
    # keeps counting. Pure function of the caption sequence — deterministic.
    plan, taken, counts = [], set(), {}
    for i, cap in enumerate(captions):
        base = sanitize_caption(cap)
        n = counts.get(base, 1)
        col = base if n == 1 else '%s_%d' % (base, n)
        while col in taken:
            n += 1
            col = '%s_%d' % (base, n)
        counts[base] = n
        taken.add(col)
        plan.append({'ordinal': i, 'caption': cap, 'column': col})
    return plan

def resolve_projection(plan, ordinals):
    # Landed columns for one logical table, by field ordinal ONLY (positions
    # in the landing's fields_json order). Suffixes ride along. No caption
    # matching, no re-sanitization, no name heuristics.
    cols = []
    for o in ordinals:
        if not isinstance(o, int) or isinstance(o, bool):
            raise TypeError('ordinal %r is not an int — resolve by position, '
                            'never by name' % (o,))
        if o < 0 or o >= len(plan):
            raise ValueError('ordinal %d out of range for %d landed columns'
                             % (o, len(plan)))
        cols.append(plan[o]['column'])
    return cols
# --- end vds-landing shared column-plan ---
