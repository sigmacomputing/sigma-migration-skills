# pbi-shaped-model tools (live-only)

These tools talk to a real Snowflake account. `checks.sh` never runs them;
they are for hand-run live probes and for building the Power BI test reports.

## seed.sh

Creates schema `ZZ_CLAUDE_PBI_SHAPED` (CREATE OR REPLACE on every table) and
grants read on it. Set these environment variables first; no defaults exist:

- `SNOW_CONNECTION` - snow CLI connection name
- `SEED_DB` - target database
- `SIGMA_READ_ROLE` - role granted USAGE on the schema and SELECT on its tables

Optional:

- `PBI_READ_ROLE` - a second role (for example the role of the Power BI Snowflake
  data source's service user) that gets the same grants. CREATE OR REPLACE drops
  grants on every reseed, so set it whenever Power BI reads this schema. Unset, it
  defaults to `SIGMA_READ_ROLE` (a harmless repeat grant).

```bash
SNOW_CONNECTION=... SEED_DB=... SIGMA_READ_ROLE=... [PBI_READ_ROLE=...] bash seed.sh
```

`AS_OF` holds 2026-06-15 although the data runs to 2026-06-30, so an as-of anchor
differs from a max-date anchor.

The data is generated sample data with invented names. It is deterministic
(HASH-derived from row sequence numbers), so reruns produce identical rows.

## Power BI test items (live-only)

`src/build_reports.py` turns `src/reports.json` into four semantic models (TMSL) and three reports
(PBIR) under `out/`. The committed `out/` uses placeholder Snowflake coordinates:

```bash
python3 src/build_reports.py --out out --host example-account.snowflakecomputing.com \
  --warehouse EXAMPLE_WH --database SAMPLE_DB
```

| Model | Reports on it |
|---|---|
| `Retail Sales Model` | `Retail Sales` (Overview, Shipping, Slicers) |
| `Retail Sales Trends Model` | `Sales Trends` (Trends, Rolling) |
| `Retail Inventory Model` | `Inventory and Purchasing` (Cover) |
| `Retail Sales Model (RLS)` | none; one role, used only to prove the refusal |

To publish, regenerate into an untracked directory with the real host, warehouse and database
(command line only; never commit that directory), then:

```bash
PBI_GATEWAY_ID=... PBI_DATASOURCE_ID=... python3 tools/fabric_publish.py --workspace Test --dir <real-out> --refresh
python3 tools/verify_pbi.py --workspace Test --dir <real-out> --snow-connection <read-only conn> --database <db>
```

`fabric_publish.py` creates each item, or updates it in place with `updateDefinition` on a re-run. It
binds each model to an existing Snowflake data source (`Default.BindToGateway`), which must already hold
working credentials: the M source is `Snowflake.Databases("<host>", "<warehouse>", ...)`, so the data
source path is exactly `<host>;<warehouse>`. It never enters credentials. The role behind that data
source needs read on the schema (`PBI_READ_ROLE` above).

`verify_pbi.py` writes `live/pbi-verify.json` (no ids, host or database). Per model it checks the refresh
state, that every measure is non-blank through `executeQueries`, that every visual's `SUMMARIZECOLUMNS`
(with the report-wide filter and saved slicer selections applied) returns rows with non-blank measures,
and that Sales Amount, Units, Sales by Ship Date (by month), Sales YTD (As Of) and Open PO Units equal
warehouse SQL.

**Rendering was not possible**: the export API is off on this trial capacity and a browser cannot be used.
A formatting problem that a DAX query cannot see would not be caught.

Power BI rejects two measures with one name in a model ("a Measure with the same name already exists"),
so the `Units` name collision is a measure on `Sales` against a column on `Inventory`.
