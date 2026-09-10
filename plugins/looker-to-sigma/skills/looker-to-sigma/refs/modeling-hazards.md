# Complex dashboard modeling hazards

This is the fail-loud playbook for patterns that can compile successfully in
Sigma while returning blank, multiplied, or unstable values. The cases came
from a production-style course-funnel migration and are regression-tested by
`fixtures/skilltest-course-performance/`.

## Null-presence filters are operators

Looker tile filters such as `NOT NULL`, `-NULL`, `EMPTY`, and `-EMPTY` are not
literal list members. The builder translates them to Sigma list filters that
include or exclude `null` (and `""` for EMPTY). A workbook containing
`values:["NOT NULL"]` is wrong: it asks Sigma to match that text exactly.

## Keep dynamic parameters workbook-local

The documented Sigma UI can pass a workbook control to a data-model control,
but the workbook spec API rejected the UI-saved `parameters` payload in the
dashboard-7405 reproduction. Generated migrations therefore use:

1. a workbook-local manual `segmented` control;
2. a scalar default matching LookML `default_value`; and
3. formulas that reference `[controlId]` directly.

`dm-spec-dynamic-parameters.json` records converter branch metadata and
`dynamic-controls.json` records what was emitted. A referenced parameter whose
branches cannot be translated deterministically blocks the build unless
`--allow-static-dynamic` explicitly records the static-default degradation.

## Do not relate or join grouped elements blindly

Relationships and joins between two Custom SQL elements that already contain
`GROUP BY` or window `OVER(...)` clauses are treated as unsafe:

- a relationship returned all-null related columns in the field reproduction;
- replacing it with a physical join produced correct values but timed out even
  when both sides had only tens of rows.

These are observed platform behaviors, not a claim that every such Sigma model
must fail. `detect_modeling_hazards.py` blocks the shape until the migration
either rebuilds both sides at one explicit grain, moves the complete
join/window logic into one Custom SQL element, or records a justified
aggregation-ledger resolution.

## Broadcast values are non-additive

A grouped value can be repeated over hidden detail rows when consumed by a
chart. `Sum([Completion Rate])` then multiplies the correct value. Use `Max`
only when grain evidence proves every repeated value is identical; otherwise
reaggregate numerator and denominator at the consumer grain. The modeling
hazard scan writes these findings to `agg-semantics.json`, which is enforced by
the existing final gate.

## Window calculations require grain and order

Moving averages, moving standard deviations, lag, and cumulative functions are
row-order dependent. A translated calculation is not accepted merely because
it compiles. It needs:

- an explicit date/period grouping column;
- a stable ascending sort on that column; and
- the intended partition dimension.

When those cannot be represented faithfully in the workbook element, push the
window into Custom SQL with explicit `PARTITION BY` and `ORDER BY`.

## Safe writes and readback

Before a workbook write, the orchestrator:

1. runs the workbook shape preflight;
2. paginates every live data-model column and validates all workbook refs;
3. writes once;
4. reads the workbook spec back;
5. paginates every workbook column and fails on error types or stale refs.

For `--update-workbook`, `wb-write-base.json` records
`latestDocumentVersion` plus a canonical document hash. A later UI/API edit
causes the next unattended PUT to stop. `--force-overwrite` is explicit and
records the conflict in `write-conflicts.jsonl`.

## Offline regression

Run:

```bash
python3 tests/test_course_performance_fixture.py
python3 tests/test_filter_normalization.py
python3 tests/test_dynamic_parameters.py
python3 tests/test_modeling_hazards.py
python3 tests/test_safe_workbook_io.py
```

The course-performance test runs LookML parsing, local model conversion,
workbook generation, hazard derivation, and a SQLite window-function oracle
without Looker, Sigma, credentials, or network access.
