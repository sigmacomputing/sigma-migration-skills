# What gets landed (and what's deliberately skipped)

The tool lands **only stored source data**. Everything derived is left for the
converter to recreate in Sigma — one source of truth, no drift.

## Skipped tables

- **Auto date tables** — `DateTableTemplate_*` and `LocalDateTable_*`. These are
  Power BI's internal time-intelligence scaffolding, not source data. Sigma
  handles dates natively.
- **Pure calculated tables** — any table whose columns are *all* calculated.

## Skipped columns (within a landed table)

- **Calculated columns** (`type: calculated` / `calculatedTableColumn`) — DAX
  logic. The converter re-emits these as Sigma formula columns. Example: the
  Retail sample's `Store` has 19 columns but only **14** are stored; the 5 extras
  (`Open Year`, `Store Type`, `Open Month`, …) are `Year([Open Date])`-style calcs.
- **Binary columns** (`dataType: binary`) — embedded images/blobs. No warehouse
  representation, AND critically they **collapse `EVALUATE <table>` to 1 row**.
  (Observed: `District` has a `DMImage` binary column; `COUNTROWS` = 9 but
  `EVALUATE 'District'` returned 1. Fixed by projecting explicit scalar columns
  via `SELECTCOLUMNS` and dropping binary.)

## Not skipped: hidden ≠ skip

A table can be `isHidden: true` and still be real source data — the Retail
sample hides its 923k-row `Sales` fact. The skip rule keys on *calc-only /
auto-date*, never on `isHidden`.

## Type mapping (TMSL `dataType` → Snowflake)

| PBI | Snowflake |
|---|---|
| int64 | NUMBER(38,0) |
| double | FLOAT |
| decimal | NUMBER(38,4) |
| string | VARCHAR |
| boolean | BOOLEAN |
| dateTime | TIMESTAMP_NTZ |
