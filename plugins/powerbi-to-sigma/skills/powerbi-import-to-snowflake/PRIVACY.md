# Privacy & data handling — `powerbi-import-to-snowflake`

Read this before running the skill, and share it with your privacy / security /
legal team if your organization reviews tools that move data.

## What this skill does with data — it MOVES ROW-LEVEL DATA

Unlike the read-only assessment skills, this skill **extracts the actual rows**
from an Import-mode Power BI model and **writes them into your Snowflake**. Plan
accordingly.

It connects to three systems on your behalf:

1. **Your Power BI / Fabric tenant** — Fabric REST + Power BI REST, authenticated
   as **you** via a Microsoft first-party public client (device-code sign-in, no
   Entra app, no admin consent). Token cached locally at `/tmp/pbiauth/cache.bin`.
   Reads: model structure (TMSL `getDefinition`) and **table rows** via
   `/executeQueries`.
2. **Your Snowflake** — via the Snowflake CLI (`snow`), using your configured
   connection. Writes: `CREATE TABLE` + `PUT`/`COPY` of the extracted rows, plus
   `GRANT`s. Nothing is dropped or overwritten outside the target schema you name.
3. **Your Sigma org** (only with `--sigma-connection`) — `POST /v2/connections/
   <id>/sync` to index the new tables. Sends only table *paths*, not row data.

## What crosses the Anthropic API

The agent driving this skill runs through Claude. **Row data does not need to
pass through the model** — extraction writes rows straight to local CSV and then
to Snowflake. What the agent sees is metadata (table/column names, types, row
counts) and any output you ask it to summarize. Avoid pasting extracted row
values into the conversation if they are sensitive.

## Local artifacts

- `out/<dataset>/*.csv` — the extracted rows, on your disk. Delete when done.
- `out/<dataset>/manifest.json`, `load.sql` — metadata + DDL, no secrets.
- `/tmp/pbiauth/cache.bin` — your cached Power BI token.

## Least privilege

- Land into a **dedicated schema** you control (`--target-schema`), not a shared one.
- `--grant-role` defaults to `PUBLIC`; scope it to the Sigma connection's role
  for tighter access, or `--grant-role ""` to grant nothing and handle it yourself.
- Use `--dry-run` first to review the generated `load.sql` before any write.
