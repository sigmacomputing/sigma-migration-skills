# Hand-written (Freeform SQL) datasets -> Sigma Custom SQL

A MicroStrategy report can be authored as **Freeform SQL**: the author types the
statement and maps its output columns to attributes and metrics by hand. There is
no schema object behind it, so `GET /model/reports/{id}?showExpressionAs=tokens`
(what `extract.py` calls for every dossier dataset) has no attribute/metric units
for it, and the semantic-model path (`convert.py`) has nothing to convert.

This path keeps the **SQL as the source of truth**. It captures the statement and
the MicroStrategy objects it maps to, then emits a Sigma data model with **one
Custom SQL element per dataset**. Scripts: `scripts/extract-sql-dataset.py`,
`scripts/convert-sql-datasets.py`, helpers in `scripts/lib/sql_dataset.py`. Tests:
`tests/test_sql_datasets.py` (offline, synthetic fixtures).

## Status

Everything is **built and tested offline**. No MicroStrategy endpoint below has
been exercised against a live server (the trial login was returning 401 when this
was written), so every response shape is a guess shaped from the REST docs. The
code tolerates missing keys and stores the raw responses on each record so a
first live run shows what the shapes really are.

| Step | State |
|---|---|
| SQL text via `POST /model/reports/{id}/instances?executionStage=resolve_prompts` (find `sqlStatement` anywhere in the response) | **UNVERIFIED live** |
| Fallback SQL via `POST /v2/reports/{id}/instances?limit=1` + `GET .../instances/{instanceId}/sqlView` | **UNVERIFIED live** (this one runs the report; see below) |
| Objects via `GET /v2/reports/{id}` (`definition.availableObjects`, else `definition.grid`) | **UNVERIFIED live** |
| Prompts via `GET /v2/reports/{id}/prompts`, then `/reports/{id}/prompts` | **UNVERIFIED live** |
| Listing a document's datasets via `GET /searches/results?usedByObject=<docId>;55&type=3` | **UNVERIFIED live** (`--document`; pass report ids if it fails) |
| Record -> Sigma data model (golden: `fixtures/sql-datasets/golden/`) | Built + tested offline |
| Sigma POST + readback gate for the emitted data model (Custom SQL element, metric named like its column) | **Not done** |
| Binding these datasets into a dossier / document workbook | **Not wired** (see Known limits) |
| Warehouse parity of the Custom SQL element vs the MicroStrategy report | **Not done** |

## Workflow

```bash
# 1. Capture. Never runs the report unless --allow-execute is passed.
python3 scripts/extract-sql-dataset.py <reportId> [<reportId> ...] [--document <docId>] \
  --out sql-datasets.json
# 2. Convert. One Custom SQL element per dataset.
python3 scripts/convert-sql-datasets.py --datasets sql-datasets.json \
  --connection-id <conn> --folder-id <folder> [--column-map map.json] \
  [--column-map-template-out tpl.json] --out sigma_dm_spec.json --gaps-out sql-dataset-gaps.json
# 3. Review every gap, then POST the data model only with an approved name + folder and run
#    SKILL.md's Phase 3 gate: read the spec back and fail on any column with `type: error`
#    (the element's formulas resolve only at query time).
# 4. Parity: run the captured SQL in the warehouse and compare its rows with the
#    Sigma element (and with the MicroStrategy report's data).
```

`extract.py` now also routes a dossier dataset that has no schema objects into
`bundle["sqlDatasets"]` (captured the same way, never executing). `convert.py`
**refuses** such a bundle and names each dataset, because binding them into the
dossier workbook is not wired. Convert the datasets with step 2 instead.

## Why it never executes by default

`resolve_prompts` asks MicroStrategy to resolve the prompts and generate the SQL
without running it. Running the report (`--allow-execute`) hits the customer's
warehouse; DBAs have flagged the CPU. With `--allow-execute` the report runs once
with `limit=1` to keep the result small (the SQL is expected to be unaffected by
the row limit; unverified), and only when the first route returned no SQL. Without it, a report whose SQL cannot be read gives a clear
error; either re-run with `--allow-execute` or put the SQL in the record by hand.

## Record contract — `mstr-sql-dataset/1`

```jsonc
{"format": "mstr-sql-dataset/1", "reportId": "...", "name": "Desk Coverage P&L",
 "provenance": {"sqlSource": "resolve_prompts" /* or "sqlView" */, "retrievedAtUtc": "..."},
 "sql": "<statement>",
 "objects": [{"kind": "attribute", "id": "...", "name": "Desk", "form": "DESC", "dataType": "varchar"},
             {"kind": "metric", "id": "...", "name": "Total PnL", "dataType": "numeric"}],
 "prompts": [{"id": "...", "name": "Trade Date From", "type": "value", "answer": "2026-01-01"}],
 "columnMap": null,   // optional [{alias, object, form}] (hand-edited)
 "warnings": [],      // capture-time notes (e.g. prompts endpoint failed)
 "raw": {"definition": ..., "prompts": ..., "sqlResponse": ...}}
```

The converter input wraps records as `{"format": "mstr-sql-datasets/1", "_extraction":
{...}, "datasets": [record, ...]}`. A report that could not be captured is
`{"reportId", "name", "error"}`. `fixtures/sql-datasets/` is a synthetic example
(shaped from the REST docs, not captured live).

## How output columns map to MicroStrategy objects

Columns are the output aliases of the statement's **final top-level SELECT**
(`select_aliases`: skips CTEs, `DISTINCT`, `TOP n`, comments; splits on top-level
commas; handles `AS`, a bare trailing alias, and `t.col` -> `col`; strips
`"x"` / `[x]` / `` `x` ``). It returns nothing for a `*` item or an unnamed
expression, and then a column map is required.

Aliases map to objects in this order, and each step only fills what the previous
one left open:

1. `--column-map` (`{"<reportId or report name>": [{"alias", "object", "form"}]}`).
2. The record's `columnMap` (same entry shape).
3. Name matching (`match_columns`). Names compare casefolded with spaces,
   underscores and hyphens dropped: the object name; `<attribute> <form>` /
   `<attribute>_<form>`; the bare attribute name for its DESC form (or its only
   form); `<attribute> id` for the ID form. An ambiguous match (two aliases that
   normalize alike, or two objects claiming one alias) matches nothing.

Names in the Sigma element: a metric keeps its name; an attribute keeps its name
for the DESC form (or a sole form) and is `<Attribute> <Form>` otherwise; an
alias no object claims keeps a friendly-cased alias. Each column formula is
`[Custom SQL/<alias>]`. Each metric object becomes a data model metric
`Sum([<column name>])`, with the aggregate taken from
`refs/catalogs/aggregation.json`.

## Gaps (`sql-dataset-gaps.json`)

`{blocking, gaps[{dataset, reportId, construct, severity, detail}], warnings}`.
Exit 0 = none blocking; 2 = blocking (outputs still written, `--allow-gaps` -> 0);
1 = invalid input (nothing written: unsafe SQL, wrong format, no `sql`).

| Severity | Construct | Meaning |
|---|---|---|
| blocking | `capture failed` | the record carries `error` |
| blocking | `select list not derivable` | `*` / unnamed expression and no column map; no element is emitted |
| blocking | `unmatched object` | no alias matched an object. `--column-map-template-out` writes `{reportId: [{alias: null, object, form}]}`; fill in the aliases and pass it to `--column-map` |
| blocking | `column map entry unresolved` | an entry names an alias not in the SQL or an object the report lacks |
| review | `metric aggregation` | MicroStrategy rolls a freeform-SQL metric up by its dynamic-aggregation setting, which the REST API does not expose. **Sum is assumed.** Confirm against the source and in parity |
| review | `prompt: <name>` | the prompt answer is baked into the captured SQL; recreate it as a Sigma control/parameter if users need to change it |
| review | `unused SQL alias` | an output column no object claims; kept as a plain column |
| review | `capture warning` | e.g. the prompts endpoints failed, so baked-in answers are unknown |

The SQL guard is the one `convert.py --multi-fact-sql` uses (single read-only
SELECT/CTE, no DDL/DML, no unresolved `{{ }}` / `${ }` placeholders). Comments
before the first token are dropped; a `;` anywhere else (including inside a
comment or string) is rejected as multi-statement.

## Known limits

- **Not bound into a workbook.** The output is a data model only. A dossier or
  document that reads these datasets still has to be rebuilt on top of it; the
  dossier converter stops on a bundle that carries `sqlDatasets`.
- **Prompts are baked in.** The SQL is the prompt-resolved statement for the
  answers the report had when captured. Prompt-driven variation is not rebuilt.
- **Dynamic aggregation is assumed Sum.** Non-additive metrics (ratios, distinct
  counts, averages) will be wrong until their aggregate is corrected by hand.
- A metric's row-level source column is named `<Metric> (SQL column)`, so the
  DM metric keeps the MicroStrategy name without colliding with a column (Sigma
  can drop an element's metrics from readback on a metric/column name clash).
- Multi-pass SQL (volatile tables, several statements) is rejected by the guard;
  conform it to one statement first, as for `--multi-fact-sql`.
- Security filters or other MicroStrategy-side logic applied outside the SQL are
  not part of the captured statement.
