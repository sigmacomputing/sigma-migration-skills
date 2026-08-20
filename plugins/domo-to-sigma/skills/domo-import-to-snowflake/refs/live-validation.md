# Live validation record

This is the durable record of what a real run against a live Domo instance
and a real Snowflake account confirmed, so the next reader doesn't have to
reconstruct it from commit messages. It supersedes the "open risk, confirm on
the first live run" framing that used to live in `scripts/lib/domo_extract.rb`
— that risk is now resolved, as recorded below.

## The real `query_dataset` response shape

`Domo.query_dataset(id, sql)` (`/v1/datasets/query/execute/{id}`) returns:

```json
{
  "columns": ["COL_A", "COL_B", "..."],
  "metadata": [{"type": "STRING", "...": "..."}, {"type": "LONG", "...": "..."}, "..."],
  "rows": [["...", "..."], "..."],
  "numRows": 42
}
```

`metadata` is **parallel-indexed to `columns`** — `metadata[i]` describes
`columns[i]`. This is the schema source `DomoExtract.extract_rows` actually
uses (`scripts/lib/domo_extract.rb`): it captures `columns` + `metadata[].type`
from the FIRST page only and builds `schema_cols` from the pair.

**This is not the same as `Domo.dataset(id)['schema']['columns']`.** That
field — the design doc's original plan for schema — was found **empty for 9
of the 10 real sample DataSets** tried during live validation. Only
`query_dataset`'s own response reliably carries type information for the
DataSets this skill exists to handle (landed/API/webform/Excel-upload data
with no connector). Every doc/comment in this skill that used to point at
`Domo.dataset(id)['schema']['columns']` has been corrected to point here.

## `metadata[].type` values observed live

Confirmed against real sample DataSets during live validation:

- `STRING`
- `LONG`
- `DATETIME`

**Not independently confirmed live:** `DECIMAL`, `DOUBLE`, `DATE` — these
three entries in `SnowflakeDDL::DOMO_TO_SNOWFLAKE`
(`scripts/lib/snowflake_ddl.rb`) are inferred from Domo's documented type
enum and from the content of columns that landed as those types, not from an
independently confirmed `metadata[].type` value on a live response. Treat
them as reasonable defaults, not as measured facts, until a real DataSet
surfaces one and it's checked against what actually appears on the wire.

## The PUT stage reference must be fully qualified

A relative table-stage reference (`@%<table>`) fails against a `snow sql
--connection <conn>` session that has no default database/schema configured
— the live failure was "session does not have a current database" (Snowflake
rejects the bare `%<table>` stage reference because it can't resolve which
database/schema the table stage belongs to without a session default).

`snowflake_load.rb`'s `load_sql` fixes this by fully qualifying the stage:
`@<database>.<schema>.%<table>` instead of `@%<table>`. This is why `PUT`
needs `database`/`schema` threaded through even though a bare `%<table>`
stage reference "looks" self-sufficient in Snowflake's own docs — it only
works when the session already has a current database/schema, which a
`snow sql --connection` session with no default configured does not have.

## `COPY INTO` needs `NULL_IF = ('')`

Domo represents null/missing values as an **empty string** in its
`query_dataset` CSV-shaped row data. Snowflake's default CSV `FILE_FORMAT`
does **not** treat an empty string as `NULL` for typed (non-`VARCHAR`)
columns — loading an empty string into a `NUMBER`/`TIMESTAMP_NTZ`/`DATE`
column without this setting fails with errors like:

```
Numeric value '' is not recognized
Timestamp '' is not recognized
```

`snowflake_load.rb`'s `load_sql` FILE_FORMAT includes `NULL_IF = ('')` to fix
this — an empty CSV field now loads as `NULL` for every column type, not just
`VARCHAR` (which tolerates an empty string as a zero-length string anyway).

## Scope of what was actually measured

Live validation confirmed **row-count parity only**: 10 real DataSets,
205,975 total rows, exact match against Domo's own `COUNT(*)` for every one.
That is the full extent of independent verification performed against real
data.

**Not independently verified:** column type fidelity or cell-value fidelity,
beyond whatever type coercion `COPY INTO` itself enforces (i.e., if a value
loaded without a `COPY INTO` error, Snowflake accepted it as the declared
column type — that is not the same as confirming the value matches Domo's
original value byte-for-byte or semantically). Anyone relying on this skill
for anything beyond "the right number of rows landed, typed well enough to
query" should independently spot-check cell values before trusting them for
anything precision-sensitive.
