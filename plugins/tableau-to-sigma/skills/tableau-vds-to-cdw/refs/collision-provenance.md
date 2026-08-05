# Collision suffixes + ordinal provenance — the split contract

All names below are invented fixture names.

## The defect this closes

The pre-fix landing sanitized captions with `re.sub(r'[^A-Z0-9_]','_',c.upper())`
and **no collision bookkeeping**. Distinct captions that sanitize identically —
`Full Date`, `Full-Date`, `Full.Date` → `FULL_DATE` — produced duplicate column
names: a `CREATE TABLE` duplicate-column error on Snowflake, or silent column
loss via `dict(zip(...))` on both targets. Worse, no caption→column provenance
was exported, so any downstream consumer that projected a subset of the landing
(typed views, per-logical-table split views) had to *re-sanitize captions* to
guess column names — a name heuristic that is blind to suffixes. In a
multi-role datasource (e.g. three date-role logical tables each carrying a
`Full Date`-like caption) every role's view resolved to the *same* plain
column while the true suffixed columns sat orphaned: silent cross-role
Franken-views.

## What the landing now guarantees

1. **Deterministic collision suffixes.** Columns are assigned in
   `fields_json` request order: the first occurrence of a sanitized base keeps
   it; later collisions get `_2`, `_3`, … in encounter order. A suffixed
   candidate that itself collides with an already-taken name keeps counting.
   Pure function of the caption sequence — same request, same bytes, every run.
2. **An ordinal-keyed provenance manifest** lands next to every table:

   | target | manifest | columns |
   |---|---|---|
   | Snowflake | `<TARGET>__VDS_COLMAP` | `ORDINAL, FIELD_CAPTION, COLUMN_NAME` |
   | Databricks | `<target>__vds_colmap` | `ordinal, field_caption, column_name` |

   `ordinal` = the field's zero-based position in the `fields_json` array
   (aliases considered: the result caption is `fieldAlias` if set, else
   `fieldCaption`). The manifest is rewritten atomically with the table on
   every run, so it always describes the current landing.
3. **A duplicate-caption refusal.** Two fields whose *result captions* are
   identical are one dict key in the VDS OBJECTS response — positionally
   unrecoverable — so the load refuses before querying instead of landing
   ambiguous data.

## The downstream rule (per-logical-table splits, typed views, anything that projects)

**Resolve columns through the manifest by `ordinal`. Never re-sanitize
captions; never match on names.** The splitter's own metadata tells it which
field *positions* belong to each logical table (the same order it used to
build `fields_json`); the manifest turns positions into landed column names,
suffixes included. `resolve_projection` in `scripts/vds_landing_lib.py` is
the reference implementation and rejects anything that is not an int ordinal.

### Worked fixture

`fields_json` (request order → ordinals 0..5), three logical tables of a
fictional `ACME_RETAIL` datasource:

| ordinal | caption (per logical table) | landed column |
|---|---|---|
| 0 | `Full Date` (ORDERS_LT) | `FULL_DATE` |
| 1 | `Order Ref` (ORDERS_LT) | `ORDER_REF` |
| 2 | `Full-Date` (SHIPMENTS_LT) | `FULL_DATE_2` |
| 3 | `Carrier` (SHIPMENTS_LT) | `CARRIER` |
| 4 | `Full.Date` (RETURNS_LT) | `FULL_DATE_3` |
| 5 | `Reason Code` (RETURNS_LT) | `REASON_CODE` |

Per-table resolution consumes ordinals only:

```python
plan = build_column_plan(captions_from_fields(fields))   # or read the colmap
resolve_projection(plan, [0, 1])   # ORDERS_LT    -> ['FULL_DATE',   'ORDER_REF']
resolve_projection(plan, [2, 3])   # SHIPMENTS_LT -> ['FULL_DATE_2', 'CARRIER']
resolve_projection(plan, [4, 5])   # RETURNS_LT   -> ['FULL_DATE_3', 'REASON_CODE']
```

Each table projects its **own** date column. The name-heuristic path
(re-sanitizing `Full-Date` → `FULL_DATE`) would have pointed SHIPMENTS_LT and
RETURNS_LT at ORDERS_LT's column — exactly the bug.

### SQL shape (Snowflake shown; Databricks identical with backticks)

Generate each split view from the manifest, not from captions:

```sql
-- column list = COLUMN_NAME for this table's ordinals, in ordinal order
CREATE OR REPLACE VIEW DEMO_DB.PUBLIC.ACME_RETAIL_SHIPMENTS_LT AS
SELECT FULL_DATE_2, CARRIER          -- from __VDS_COLMAP ordinals (2, 3)
FROM DEMO_DB.PUBLIC.ACME_RETAIL_LANDING;
```

If a generator wants to stay in SQL, join its ordinal list against the
manifest:

```sql
SELECT COLUMN_NAME
FROM DEMO_DB.PUBLIC.ACME_RETAIL_LANDING__VDS_COLMAP
WHERE ORDINAL IN (2, 3)
ORDER BY ORDINAL;
```

## Compatibility

When no captions collide, suffixing is a no-op: landed names are byte-identical
to the legacy sanitizer's output (locked by the byte-stability test), so
existing no-collision landings, typed views, and Sigma sources are unaffected.
The only additive change is the `__VDS_COLMAP` manifest appearing next to the
table.

## Tests

`scripts/test_vds_landing_lib.py` (hermetic, stdlib-only):
colliding-caption fixture → per-table projections; no-collision byte-stability
vs the legacy sanitizer; suffix-vs-real-base collisions; duplicate-caption and
non-ordinal refusals; and a drift check that the shared block embedded in both
SKILL.md code listings is byte-identical to `scripts/vds_landing_lib.py`.
