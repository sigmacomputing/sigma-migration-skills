# Fully-local `.pbix` → Sigma (no Fabric, no tenant)

When the user has only a local `.pbix` file on disk — not published to Power BI
Service / Fabric — you do **not** need the device-code CONNECT/EXTRACT flow. The
orchestrator extracts both halves locally:

```
ruby scripts/migrate-powerbi.rb --pbix <file.pbix> \
  --connection <SIGMA_CONN_UUID> --database <DB> --schema <SCHEMA> \
  --ref-dm <referenceDataModelId> --out <WORK>
```

`--pbix` runs a **Phase 0** that produces the same two artifacts the Fabric path
does, then the normal convert → build → verify pipeline runs unchanged:

| Half | Script | Source inside the `.pbix` |
| --- | --- | --- |
| Model (`model.bim`, TMSL) | `extract-model-pbix.py` | the binary VertiPaq `DataModel` blob (via **pbixray**) |
| Report (`signals.json`) | `extract-report-classic.py --pbix` | classic **UTF-16LE** `Report/Layout` or modern `Report/definition/` PBIR; **stdlib only** |

You can also run either extractor standalone:

```
python3 scripts/extract-model-pbix.py   --pbix <file.pbix> --out model.bim [--name "Sales"]
python3 scripts/extract-report-classic.py --pbix <file.pbix> --out signals.json
# or, from an already-extracted Report/Layout file (UTF-16LE or UTF-8):
python3 scripts/extract-report-classic.py --report-layout <Layout> --out signals.json
```

## Import-mode `.pbix` with no live warehouse

A local `.pbix` is usually **import mode** — a frozen snapshot with no warehouse to
point Sigma at. Land the frozen data into a warehouse first (see the Import-mode →
Snowflake data-landing skill), then pass that landing's connection/db/schema as
`--connection/--database/--schema`. The M queries pbixray recovers are carried into
`model.bim` partitions, so a `.pbix` that DID read from a warehouse keeps its table
names and the converter just repoints db/schema to your `--database/--schema`.

## Composite / live-connected reports (prefer the local `.pbix`; remote measures stop)

A **composite** report (local tables + a reference to a shared/remote dataset) or a
report **live-connected** to a shared dataset does NOT yield a complete model from
Fabric `getDefinition` — you get the report's bound model, which is missing the
report-local measures/calc tables (composite) or isn't resolvable standalone
(thin-live). Power BI also **blocks export-to-`.pbix`** for live-connected reports,
so device-auth can't just download it. The author's local `.pbix` carries the
report-local model, so prefer `--pbix`.

The local `.pbix` is still **not the complete model** when the report uses
DirectQuery to a published Power BI semantic model. Each remote measure is stored
as a pointer, not as DAX:

```
EXTERNALMEASURE("Net Revenue", DOUBLE, "DirectQuery to AS - Sales Model")
```

The measure's DAX lives in the remote model, so neither the `.pbix` nor a Fabric
`getDefinition` can translate it. The model's shared expressions (which
`extract-model-pbix.py` carries into `model.bim`) map each `DirectQuery to AS -
<model>` connection to `AnalysisServices.Database("powerbi://…/<workspace>",
"<model>")`.

Each table of the remote model the report uses is a DirectQuery **proxy table**:
its partition is an `entity` partition (TOM partition source type 5) whose
`entityName` is the table in the remote model and whose `expressionSource` is the
`DirectQuery to AS - <model>` shared expression. Its rows live in the remote model,
not in any warehouse table the file names. `extract-model-pbix.py` emits it the way
a Fabric `model.bim` does:

```json
{ "name": "Sales", "mode": "directQuery",
  "source": { "type": "entity", "entityName": "Sales",
              "expressionSource": "DirectQuery to AS - Sales Model" } }
```

pbixray's `schema` does not list a proxy table (it has no VertiPaq storage), so the
extractor takes the table from `tmschema_partitions` and its data columns from
`tmschema_columns`. pbixray's `tmschema_partitions` has no `ExpressionSourceID`
(0.15.x), so the extractor reads it from the metadata database pbixray already
opened (an internal attribute, best effort). When that fails, a model with one
remote connection binds the proxy table to it (noted in the table's annotations);
with several, `expressionSource` is left out, the note names the candidates, and
the stop below lists them instead of guessing. Before this, the extractor wrote a
`no Power Query (M) captured` placeholder and the converter pointed the table at
`--database/--schema` + the table name (`could not extract source path`), which
usually does not exist.

- **Remote measures and tables (every route).** Before conversion, the
  orchestrator scans the model the report uses (after MODEL SCOPE) for
  `EXTERNALMEASURE` pointers, for proxy tables, and for measures built on either,
  transitively (a measure is built on a proxy table when its DAX names the table:
  `'Sales'[Amount]`, `COUNTROWS(Sales)`). On a hit it STOPS (exit 10) with an OPEN
  QUESTION that names each remote model, its workspace and connection, its pointer
  measures and its proxy tables (with the remote table each mirrors);
  `<work>/external-measures.json` records it (`status: blocked`, `pointers[]`,
  `proxy_tables[]`, `dependents[]`). An `entity` partition over a warehouse SQL
  endpoint (Direct Lake) is not a proxy table. On the Fabric route the composite
  gate below stops first and names the same models and tables. Then either:
  1. migrate each remote semantic model first (it is published), then rerun this
     report with `--allow-incomplete-model` and re-point its Null metrics and
     placeholder tables at the migrated model; or
  2. continue knowingly with `--allow-incomplete-model`. The pointers and every
     measure built on them or on a proxy table become `Null` metrics (their
     description names the remote model or table; the pointer text is never
     shipped as a formula). A measure built on a remote one that the converter
     drops (a Sigma metric cannot reference another element's metric) is added
     back as a `Null` metric on its table's element, so its visuals still bind, and
     its converter warning is replaced with an `ℹ` note so neither the DAX gate nor
     the coverage gate asks for a restructure: no restructure can recover DAX that
     lives in another model. Each proxy table ships as a **zero-row placeholder**:
     its partition is rewritten to a typed `SELECT CAST(NULL AS <type>) AS "<col>",
     … FROM (SELECT 1 AS one) AS no_rows WHERE 1 = 0` (types for Snowflake,
     Databricks, BigQuery and Postgres/Redshift; untyped `NULL`s for any other
     warehouse), with a leading `/* Not migrated: … */` comment naming the remote
     table and model, and the NativeQuery restore turns it into the element's
     Custom SQL source. It is not dropped: dropping it would unbind every field on
     it, and the field-loss and coverage gates would then ask for a rebuild that
     the remote model makes impossible. Its fields bind and read as empty, and no
     guessed warehouse path ships; the converter's `could not extract source path`
     warning about it becomes an `ℹ` note. Each is a gap in `external-measures.json`
     (`status: accepted_incomplete`, `gaps[]` with the Power BI table, the data
     model element and `kind` `metric` / `column` / `table`), and the run records a
     `skip-flag-waived` escape in `offramps.jsonl`, so the degradation ledger
     cannot call the migration GREEN. Parity will flag the visuals over a
     placeholder table (they are empty): that is the gap, not a new bug.

  If a proxy table still reaches the data-model POST with the converter's
  fallback path (for example a `--converter-out` made from the full model, whose
  proxy tables the scoped run did not rewrite), the warehouse rejects it as
  unreadable. The orchestrator then prints a `REMOTE TABLE(S), not a missing
  GRANT` box naming the remote table and model, and leaves that table out of the
  GRANT advice: no GRANT can make a table readable that does not exist.

  The converter output is checked too: a pointer that only appears there (a
  `--converter-out` made from the full model) stops the run the same way, and
  `convert-model.rb` (the `run.sh` route) refuses a converter output that still
  carries one (exit 10). Measure references are read from the DAX with comments
  and strings skipped; `Table[Column]` is a column when that table has the
  column, so a local column that shares a remote measure's name is not mistaken
  for a reference to it. Calculated columns that use a remote measure are not
  tracked (the dm-resolver nulls a column that references a metric).

  Logic + tests: `scripts/lib/pbi_external_measure.rb`,
  `scripts/test-external-measure.rb` (synthetic fixture:
  `fixtures/composite-externalmeasure/`), and for the extractor's proxy-table
  shape `tests/test-extract-model-pbix.py`. Not covered: calculated columns that
  use a remote measure or a proxy table, and the `run.sh` route, which has no
  TMSL to tell a proxy element from a warehouse one.

Detection:
- **Fabric path (`--tmsl`):** the orchestrator scans the extracted TMSL for
  `entity` partitions bound to a remote model, partitions whose `expressionSource`
  names a shared expression connecting to a remote model, or M expressions
  (partition or shared) naming the AnalysisServices / Power BI dataset connector
  (`AnalysisServices.Database`, `PowerBI.Datasets`, `powerbi://`, …). On a hit it
  STOPS (exit 10) with an OPEN QUESTION asking for the local `.pbix` (override:
  `--allow-incomplete-model`), and names any remote models the measures point into. Storage mode is not a signal: Import models and
  DirectQuery partitions over a warehouse connector (`Snowflake.Databases`,
  `Sql.Database`, …) never trip it. Logic + tests: `scripts/lib/pbi_composite.rb`,
  `scripts/test-composite-gate.rb`.
- **Offline (`.pbix`):** `extract-model-pbix.py --detect-composite --pbix <file>`
  prints `{"composite":bool,"remoteArtifacts":[…]}` — the tell is the zip's
  `Connections` member listing `RemoteArtifacts` ([{DatasetId, ReportId}]) or a
  connection string pointing at a remote PBI model (`pbiazure` /
  `PbiModelDatabaseName`). Pure/stdlib — no pbixray. Unit-tested in
  `tests/test-extract-model-pbix.py`.

## pbixray install (the one fragile dependency)

Try `python -m pip install pbixray` in the selected interpreter first. Compatible
wheels are now available for some environments: CPython 3.14 on macOS arm64 was
tested with pbixray 0.15.5, xpress9 0.3.9 and xmhuffman 0.3.2. A universal
"must build from source" requirement is no longer accurate. The recipe below is
the fallback when a platform lacks a working wheel.

Only the **model** half needs pbixray. It is intentionally **not** in
`scripts/requirements.txt` (so the default `run.sh` venv bootstrap stays CI-robust):
Older `xpress9` and `xmhuffman` **PyPI sdists were broken** and required installation
**from source**. Install once, into the interpreter you pass as
`--python` (or the skill's `<work>/.venv`):

```
pip install apsw pandas xpress8 \
  "git+https://github.com/Hugoberry/xpress9-python@main" \
  "git+https://github.com/Hugoberry/xmhuffman-cython@main" \
  pbixray
```

Notes / caveats:
- `xpress8` ships a working wheel; `xpress9` + `xmhuffman` are the from-source builds
  (they need a C/Cython toolchain — Xcode CLT on macOS, `build-essential` on Linux).
- Verified working on CPython **3.13** (macOS arm64): `xpress9` built to 0.3.8,
  `xmhuffman` to 0.3.0, `pbixray` 0.15.2, `apsw`, `pandas`.
- Without pbixray, `extract-model-pbix.py` / `migrate-powerbi.rb --pbix` exit with a
  clear **"pbixray required for local model extraction"** message pointing here. The
  **report** front door (`extract-report-classic.py --pbix`) and the Fabric `--tmsl`
  path do **not** need pbixray.

## How the model maps (pbixray → TMSL)

`extract-model-pbix.py` reads these pbixray DataFrames and assembles a TMSL
`{ "name", "model": { "tables": […], "relationships": […] } }`:

| pbixray | → TMSL |
| --- | --- |
| `schema` (`TableName`,`ColumnName`,`PandasDataType`) | `table.columns[].{name,dataType,sourceColumn}` (pandas dtype → `int64`/`double`/`dateTime`/`boolean`/`binary`/`string`) |
| `dax_measures` (`TableName`,`Name`,`Expression`) | `table.measures[].{name,expression}` |
| `dax_columns` (`TableName`,`ColumnName`,`Expression`) | `table.columns[]` marked `type:"calculated"` |
| `dax_tables` (`TableName`,`Expression`) | `table.partitions[].source` marked `type:"calculated"`; output columns marked `type:"calculatedTableColumn"` |
| `power_query` (`TableName`,`Expression`) | regular-table `partitions[].source` (M passthrough → warehouse FQN; tables with neither M nor calculated-table DAX get an honest placeholder partition) |
| `m_parameters` (`ParameterName`,`Expression`,`Description`) | `model.expressions[]` (`kind:"m"`), as a Fabric `model.bim` carries them, so a NativeQuery's `{[Name=<parameter>]}` database resolves |
| `relationships` (`From*`,`To*`,`IsActive`,`CrossFilteringBehavior`) | `model.relationships[].{name,fromTable,fromColumn,toTable,toColumn,crossFilteringBehavior,isActive}` |

The assembly (`assemble_tmsl` / `build_model_from_pbixray`) is a pure function of
those DataFrames — unit-tested with mocked dataframes in
`tests/test-extract-model-pbix.py` (no pbixray needed), which also asserts the
emitted `model.bim` converts cleanly through the vendored converter.
