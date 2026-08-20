# domo-import-to-snowflake

The **data track** for migrating Domo DataSets that have no connector-backed
warehouse table — API/webform/Excel-upload/sample data — into Snowflake.

Sigma queries live warehouse tables; it has no in-memory import engine. When
a Domo DataSet was landed directly into Domo with no connector behind it,
there is no warehouse table for Sigma to point at. This skill extracts the
DataSet's rows and lands them in Snowflake, then patches
`domo-to-sigma`'s own `discovery/dataset-map.json` sentinel entry
(`_source: "domo-landed-data"`) in place so the converter picks it up with no
further edits beyond `connectionId`.

- **In scope:** any Domo DataSet flagged `domo-landed-data` by `build-dm.rb`.
- **Out of scope:** connector-backed DataSets (already resolve via
  stream-config auto-fill); Beast Mode / dashboard logic conversion (that's
  `domo-to-sigma` itself).

See `SKILL.md` for the workflow and `refs/` for the gotchas. `PRIVACY.md`
covers data handling — note this skill moves **row-level data**, unlike the
read-only `domo-assessment` skill bundled with `domo-to-sigma`.
