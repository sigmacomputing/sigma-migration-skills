# Making Sigma see the newly-landed tables

A freshly created warehouse table is invisible to Sigma until two things happen.
The tool does both when you pass `--sigma-connection <id>`; otherwise do them
manually.

## 1. GRANT (in the generated `load.sql`)

The Sigma connection queries as some Snowflake role (for an OAuth connection,
each user's own role; `PUBLIC` covers everyone). The tool appends:

```sql
GRANT USAGE  ON SCHEMA <db>.<schema>               TO ROLE <grant-role>;   -- default PUBLIC
GRANT SELECT ON ALL TABLES IN SCHEMA <db>.<schema> TO ROLE <grant-role>;
```

Override the role with `--grant-role <ROLE>`; `--grant-role ""` skips grants.

## 2. Connection sync

Even after GRANT, a DM POST fails with:

```
Source not found: warehouse table 'DB.SCHEMA.TABLE' on connection '<uuid>'.
```

…until the connection has indexed the new table. Trigger per table:

```
POST /v2/connections/<connectionId>/sync
Body: {"path": ["<DB>", "<SCHEMA>", "<TABLE>"]}
```

The tool calls this for every landed table (`sigma_sync`, using
`SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET`). Note the endpoint is `/sync` and it
takes a `path` body — there is no separate `/lookup` route (404).
