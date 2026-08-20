---
name: domo-import-to-snowflake
description: Land a Domo DataSet with no connector-backed warehouse table (API/webform/Excel-upload/sample data) into Snowflake so domo-to-sigma's build-dm.rb can resolve it. Use when discovery/dataset-map.json has one or more entries flagged _source: "domo-landed-data" (build-dm.rb's own sentinel for a DataSet it found no warehouse mapping for), or a cold run against Domo's own sample/demo content needs its DataSets landed first. This is the DATA track that runs BEFORE domo-to-sigma converts the model/dashboard logic. Not for connector-backed DataSets (those already resolve via stream-config auto-fill) and not a logic/Beast-Mode converter.
user-invocable: true
---

# Domo (landed data) → Snowflake

Sigma is warehouse-native: every DM table resolves as live SQL against a
connected warehouse. `domo-to-sigma`'s `build-dm.rb` already knows how to
auto-fill `discovery/dataset-map.json` for connector-backed DataSets (Domo's
own Snowflake connector carries `databaseName`/`schemaName`/`tableName` in
its stream config), but a DataSet landed directly into Domo — API, webform,
Excel upload, or Domo's own sample/demo content — has no warehouse table at
all. `build-dm.rb` flags this rather than guessing: the entry gets
`_source: "domo-landed-data"` and an unmistakable sentinel table name,
`<TABLE:LANDED_DATA_NO_WAREHOUSE_SOURCE>`. This skill extracts that DataSet's
rows and lands them in Snowflake, then patches the entry in place so the very
next `build-dm.rb` run resolves it like any other DataSet.

**Two tracks, one migration** (this skill is track 1):

```
1. DATA   (this skill)      domo-landed-data DataSets → Snowflake tables + dataset-map.json patched
2. LOGIC  (domo-to-sigma)   Beast Modes / cards / layout → Sigma dashboard — unchanged
```

Track 2 needs no separate repoint step: `build-dm.rb` already reads
`dataset-map.json` directly, so once this skill patches an entry, the next
`build-dm.rb`/`migrate-domo.rb` run just works.

> Skip this skill for connector-backed DataSets — they already resolve via
> `build-dm.rb`'s existing stream-config auto-fill.

## What it does

`scripts/domo_import_to_snowflake.rb` (generic — no hardcoded dataset ids):

1. **Select** — reads the sibling `domo-to-sigma` skill's
   `discovery/dataset-map.json`; auto-detects every `_source: "domo-landed-data"`
   entry, or takes an explicit `--dataset-id` subset.
2. **Extract + schema** — `Domo.query_dataset(id, sql)`, paginated
   explicitly, with a measured `COUNT(*)` row-count parity check (never
   assumed). Column types come from the same response's `metadata[].type`
   (paired positionally with `columns`), **not** `Domo.dataset(id)['schema']`
   — live validation found that field empty for 9 of 10 real sample
   DataSets. See `refs/type-mapping.md` for the Domo → Snowflake type table
   and `refs/live-validation.md` for what was confirmed live.
3. **Load** — typed `CREATE TABLE` + `snow sql` `PUT`/`COPY INTO`, then a
   `GRANT SELECT` (default role `PUBLIC`, overridable).
4. **Sync** — `--sigma-connection <uuid>` triggers `POST /v2/connections/<id>/sync`
   once after the whole batch, so new tables resolve immediately.
5. **Patch** — rewrites the landed entries' `database`/`schema`/`table` and
   `_source` in `dataset-map.json` (see `refs/naming-and-sentinel.md`).
   `connectionId` is never touched — same rule as every other entry type.

## Run

```bash
# dry run — extract + print DDL + row-count parity check, touch nothing in Snowflake
ruby scripts/domo_import_to_snowflake.rb --target-db <DB> --target-schema <SCHEMA> --dry-run

# full: land every domo-landed-data entry in dataset-map.json
ruby scripts/domo_import_to_snowflake.rb \
  --target-db <DB> --target-schema <SCHEMA> \
  --sf-conn <snow-cli-connection> --sigma-connection <sigma-connection-uuid>

# restrict to specific DataSets
ruby scripts/domo_import_to_snowflake.rb --dataset-id <id1>,<id2> --target-db <DB> --target-schema <SCHEMA> --sf-conn <snow-cli-connection>
```

Useful flags: `--grant-role <ROLE>` (default `PUBLIC`), `--limit-rows N`
(cheap smoke test), `--band-size N` (pagination page size, default 20000).

Requires: the Snowflake CLI (`snow`) configured with the connection named by
`--sf-conn`; `DOMO_ACCESS_TOKEN`/`DOMO_CLIENT_ID`/`DOMO_CLIENT_SECRET`/
`DOMO_INSTANCE` in the environment (same as `domo-to-sigma` itself); and
`SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` for `--sigma-connection` sync.

## Then hand off

Run the sibling `domo-to-sigma` skill's normal pipeline — `build-dm.rb` now
resolves the landed DataSets like any connector-backed one, no further edits
beyond supplying `connectionId` for any entry that doesn't already have one.

## Gotchas (read `refs/` before a real run)

- `refs/type-mapping.md` — the Domo → Snowflake type table and its one
  confirmed-live gap (unrecognized types default to `VARCHAR`, never abort).
- `refs/naming-and-sentinel.md` — why `_source` gets rewritten to
  `domo-landed-snowflake` instead of left as the sentinel, and why
  `connectionId` is never touched.
- `refs/live-validation.md` — what the live run actually confirmed: the real
  `query_dataset` response shape, the fully-qualified PUT stage requirement,
  the `NULL_IF = ('')` COPY INTO requirement, and the scope of what was
  measured (row-count parity only — not column type or cell-value fidelity).
