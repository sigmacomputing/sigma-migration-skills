# The `dataset-map.json` sentinel contract

`domo-to-sigma`'s `build-dm.rb` (`derive_map_entry`) flags any DataSet with
no connector stream config as:

```json
{"connectionId": "", "database": null, "schema": null, "table": null,
 "_source": "domo-landed-data",
 "_note": "no connector stream config found ... this DataSet has no warehouse location; land it or repoint by hand"}
```

Once this skill lands a DataSet, it patches that same entry:

- `database`/`schema`/`table` — the real Snowflake location.
- `_source` — rewritten to `"domo-landed-snowflake"`, a new tag. **Not**
  `"domo-stream-config"` (there's no real Domo connector stream behind it),
  and **not** left as `"domo-landed-data"` — that value is
  `column_preflight.rb`'s `SENTINEL_SOURCES` list, which tells the column
  pre-flight check to skip entries with no real warehouse table yet. Leaving
  the old tag would make the real preflight check silently never run against
  these tables going forward. `domo-landed-snowflake` is deliberately **not**
  added to `SENTINEL_SOURCES` — after landing there IS a real table, and the
  preflight check should run against it like any other.
- `_note` — removed (it described the now-resolved gap).
- `connectionId` — **never** touched, landed or not. It's a Sigma-side id
  with no Domo analog; every entry type in `dataset-map.json` requires a
  human to supply it, and this skill follows that same rule.
- `name` — preserved if a human (or an earlier auto-fill pass) already set
  one.

Column names inside the landed table are the **raw Domo column names**,
unchanged — this skill does **not** run them through
`DomoSigma.display_name()`. That transform is `build-dm.rb`'s own job when it
emits formula references (`[TableDisplayName/ColumnDisplayName]`), exactly as
it already does for connector-backed tables; landing raw names keeps this
skill's output identical in shape to what `build-dm.rb` already expects.
