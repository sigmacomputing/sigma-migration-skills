# Domo → Snowflake type mapping

| Domo `metadata[].type` | Snowflake |
|---|---|
| `STRING` | `VARCHAR` |
| `LONG` | `NUMBER(38,0)` |
| `DECIMAL` | `FLOAT` |
| `DOUBLE` | `FLOAT` |
| `DATE` | `DATE` |
| `DATETIME` | `TIMESTAMP_NTZ` |

Source: `Domo.query_dataset(id, sql)`'s own response — `columns` paired
positionally with `metadata[].type` on the FIRST page of the extraction
(`DomoExtract.extract_rows` in `scripts/lib/domo_extract.rb` builds
`schema_cols` from these two arrays). **Not**
`Domo.dataset(id)['schema']['columns']` — live validation found that field
empty for 9 of the 10 real sample DataSets tried, so this skill never reads
it for typing. See `refs/live-validation.md` for what was actually confirmed
live (`STRING`/`LONG`/`DATETIME` observed; `DECIMAL`/`DOUBLE`/`DATE` below are
inferred from Domo's documented type enum, not independently confirmed live).

**Any Domo type not in this table lands as `VARCHAR`, never aborts the
batch.** `SnowflakeDDL.unknown_types` surfaces these on stderr per dataset so
they're visible, not silent — widen the table in
`scripts/lib/snowflake_ddl.rb` if a real DataSet hits one (Domo's public docs
mention a few more, e.g. `PERCENT`/`DURATION`, that hadn't appeared anywhere
in this plugin's schema handling as of this skill's first build).
