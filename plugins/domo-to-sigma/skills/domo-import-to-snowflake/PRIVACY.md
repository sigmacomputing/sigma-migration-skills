# Privacy & data handling

Unlike `domo-to-sigma`'s bundled read-only `domo-assessment` skill, this
skill moves **row-level data**:

- Extracts every row of a selected Domo DataSet via Domo's public
  `/v1/datasets/query/execute/{id}` endpoint.
- Writes that data to a local temp file (`Dir.mktmpdir`, removed
  automatically when the process exits) as CSV, then `PUT`s it to a
  Snowflake internal stage and `COPY INTO`s the target table.
- The landed data persists in the target Snowflake database/schema you
  specify via `--target-db`/`--target-schema` until you drop it — this skill
  never deletes what it lands.
- No data is sent anywhere except the Domo instance you already have
  credentials for and the Snowflake account your `--sf-conn` CLI connection
  points at. The optional `--sigma-connection` sync call touches only Sigma's
  connection-metadata endpoint (`POST /v2/connections/<id>/sync`) — it never
  transmits row data itself, only triggers Sigma's own warehouse catalog
  refresh.
