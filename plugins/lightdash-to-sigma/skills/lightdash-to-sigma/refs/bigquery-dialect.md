# BigQuery dialect notes

BigQuery is the first-class warehouse for this skill (the fixture is BigQuery).
Sigma queries BigQuery in place; no data is copied.

## Relation resolution (physical table per model)

1. dbt `target/manifest.json` `nodes["model.<project>.<name>"].relation_name`
   (`` `proj`.`dataset`.`table` ``; backticks stripped, split on `.`).
2. Model `config.database` / `config.schema` / `config.alias` (or the manifest
   node's `database` / `schema` / `alias`).
3. `--default-database` / `--default-schema` + the model name.
4. YAML-only projects: `sql_from: PROJ.DATASET.TABLE`.

Live mode (`--explores-dir`): `tables.<t>.sqlTable`, or `database` + `schema`,
from the compiled explore.

## Path and case

- A Sigma warehouse-table `source.path` is **3-part**:
  `["<project>", "<dataset>", "<table>"]`.
- **Case is preserved.** BigQuery identifiers are case-sensitive; only Snowflake
  paths are upper-cased by the converter.
- Column refs assume Sigma title-cases snake_case BigQuery columns
  (`order_date` → `[orders/Order Date]`). Unverified against a live BigQuery
  connection: if the DM POST yields error columns, check the Sigma column display
  names first.
- Dialect order: `manifest.metadata.adapter_type` → `lightdash.config.yml`
  `warehouse.type` → `--dialect`. No answer = stop and ask; never guess.

## Sigma connection

Administration → Connections → Create → **BigQuery**. Provide the billing
project and a service-account JSON key. The service account needs
**BigQuery Data Viewer** (on the datasets Lightdash reads) and **BigQuery Job
User** (on the billing project). Verify by browsing a table in Sigma before
converting. The connection's id is `--connection-id`.

## Pitfalls

- Tables that require a partition filter fail parity queries; add a filter in
  the DM or pick another explore.
- Datasets in a different location than the connection's jobs need a matching
  location on the connection.
- `DATE_TRUNC` argument order differs by dialect; the formula engine accepts both
  forms and emits `DateTrunc("<unit>", ...)`.
