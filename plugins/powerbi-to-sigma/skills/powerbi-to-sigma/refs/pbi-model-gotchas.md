# Power BI model/report gotcha backlog + public test corpus

Source: an exhaustive web-research sweep (2026-07-17, 8-agent fan-out — TMSL/TMDL
structure, warehouse-connector M shapes, advanced modeling features, DAX,
PBIR/report layer, + public sample files) done after a real enterprise customer
migration surfaced a cluster of latent gaps our synthetic fixtures never hit.
This is the **prioritized backlog + regression corpus** so we can work through the
long tail deliberately. Status tags are the researcher's inference unless marked
**VERIFIED** (grepped against `src/powerbi.ts` / the skill scripts on 2026-07-17).

**Why our fixtures missed these:** every prior fixture was happy-path — PBI table
name == physical table, Snowflake/UPPER matching case, single granted schema, small
+ simple DAX. Real enterprise models use friendly names over `vw_` views, Databricks
lowercase, mostly-ungranted multi-schema, 100s of tables, heavy `CALCULATE`.

## VERIFIED gaps (grepped; beaded)
| Gap | Stage | Bead |
|---|---|---|
| M-parser warehouse families: SQL-family flat `[Schema=,Item=]`, `Sql.Databases()` two-tier, Databricks shape-B, BigQuery Name-only 3-tier | convert | `[bead].9` (path families remain regression targets; do not lose them during re-vendor) |
| Field parameters (`NAMEOF` calc tables) → phantom warehouse table; should be a control-driven `Switch([ctl],…)` picker | convert | `[bead].10` (P2) |
| Multi-partition tables + incremental-refresh `refreshPolicy.sourceExpression` + Direct Lake/`entity` partitions (only `partitions[0]` read) | convert | `[bead].11` (P2) |
| Relationship fidelity: many-to-many + bidirectional `crossFilteringBehavior` not inspected (fan-out / wrong subtotals) | convert | `[bead].12` (P2) |
| Metadata cluster: `sortByColumn` (alpha sort), KPI measure sub-object (target/status/trend), hierarchies `levels[]`, `column.summarizeBy` default agg, nested `displayFolder` | convert | `[bead].13` (P3) |
| Report filters (`filterConfig` Where-tree, In/Not/Between/Comparison, ComparisonKind, TopN, RelativeDate, `howCreated` Auto/Drill noise, inverted selection, Passthrough) never extracted | extract-pbir + build-workbook | Track 3a (extract) + 3b (apply: list/number-range/top-n → element/master filters; measure/multi-col/date-range → coverage) SHIPPED; date-range-control emission is the fast-follow |
| Friendly table name ≠ physical view: element-name/formula-prefix reconciliation | build-DM | `[bead]` (SHIPPED #401) |
| Sigma connection `friendlyName:false`: title-cased converter refs (for example `Order Id`) must be grounded to exact catalog names (`ORDER_ID`) while retaining explicit display names | build-DM | SHIPPED 1.8.31; `lib/warehouse_column_refs.rb` reads connection metadata + paginated table columns before validation/POST |
| Cross-table measure referencing a dim column dropped (should translate via the relationship) | convert | `[bead].8` (P2) |
| Time-intel date grain hardcoded to month (ignores active hierarchy level) | dax/build | `[bead]` (P3) |

**Correction to the research:** VAR/RETURN decomposition IS handled (17 hits in the
converter) — the critic's "completely absent" was wrong. Don't bead it.

## Already-handled (don't re-flag)
Kind-chain nav (Snowflake/Databricks-A/BigQuery-with-Kind/Athena), Redshift 2-level
Name-nav, calculated tables (CALENDAR/GENERATESERIES → SQL spine; else loud
placeholder), native-query partitions (`Value.NativeQuery` / connector `Query=`
preserved as complete named Custom SQL by `lib/pbi_native_query.rb`; post-query M
steps gate), calc groups (excluded as source + loud item stubs; array-valued item
expressions normalized before conversion), RLS/OLS
(makeRlsSecurity/makeClsSecurity, surfaced not injected), USERELATIONSHIP (activated
as named alt join), inactive rels (only emitted if a measure uses them), rowNumber/
isGenerated skipped, calc columns (window/EARLIER → SQL helpers), binary skipped,
array-or-string M/DAX, classic report.json + PBIR both parsed, `Aggregation.Function`
enum decode, `sortDefinition` read (never inferred from row order), unmapped visual →
loud `approximated`, bookmarks → per-state workbooks, visualInteractions read, geo
`dataCategory` → map kind, Databricks lowercase casing (lanq.7), multi-schema override
(lanq.6), cause-grouped coverage + ungranted-schema grant surfacing (Track 1),
measure entity-alias + friendly/physical reconciliation (Track 2).

## Optimistic "handled" to re-audit (critic)
- **Snowflake `[Role=…]` dropped** — can bind row-access policies; dropping silently
  changes row counts (RLS/correctness, not benign).
- **Unity Catalog off-by-one** — a 3-part Databricks catalog.schema.table via Kind-chain
  can double-scope if the Sigma connection is already catalog-pinned.
- **Context transition** (measure-ref inside SUMX/AVERAGEX) — the genuinely hard iterator
  case; largely unrepresentable.
- **Time-intel** — depends on a *marked date table*; semi-additive (CLOSINGBALANCE) +
  custom fiscal (4-4-5) fall through.
- **OLS** — table-level `metadataPermission=none` (whole-table) + measure-leakage exceed
  column masking.
- **Report-extension measures** — live-connected reports can define measures in the
  *report* (not the .bim) with their own DAX → no BIM match → silently lost.

## Untriaged long tail (from the 116-item sweep — audit before assuming handled)
DAX everyday 80%: `RELATED`/`RELATEDTABLE` (esp. a calc column used as a join key),
`SWITCH`/`SWITCH(TRUE())`, `SELECTEDVALUE`/`HASONEVALUE`/`ISINSCOPE`, `DIVIDE`,
`COALESCE`/`IFERROR`, `PATH*` (parent-child — exercised by the ProData P&L corpus),
`TREATAS`/`CONCATENATEX`, `CALCULATETABLE`/`SUMMARIZE`/`ADDCOLUMNS`, semi-additive +
custom-fiscal time-intel, measure-to-measure dependency ordering. Modeling:
`alternateOf` aggregation tables, composite/DQ-over-AS proxy tables, `DATATABLE()`
literals, `detailRowsDefinition`, `column.variations`/`defaultHierarchy`,
`what-if`/dynamic-M parameters, shared M functions/`expressionSource`. Non-warehouse
M families (Excel/CSV/SharePoint/Web/Dataflows/Dataverse/Salesforce/OData/ODBC/Kusto/
SAP) — handled by the sibling land-then-repoint project (`pbi-nonwarehouse-sources`).
Report layer: field-well→encoding mapping, conditional formatting (MERGED per
`pbi-conditional-formatting` — confirm), style `objects` (titles/labels/legend/format),
themes, small multiples (DONE — the "Small multiples" field well maps to Sigma's
native `trellis`; `build-workbook-from-pbir.rb` → `TrellisEmit.apply`), matrix
subtotals, buttons/drillthrough/page-nav actions,
slicer mode (dropdown/relative-date/between), Deneb/Vega custom visuals, mobile layout.

## Public test corpus (real files; warehouse-connected where possible)
| Priority | URL | Exercises |
|---|---|---|
| P0 | databricks-solutions/powerbi-on-databricks-migration-accelerator `/samples-pbip` | THE multi-connector corpus: same TPC-H model × 6 warehouses (Databricks A+B, Snowflake, Redshift, Synapse, SqlServer, Postgres) — every M-shape gap in one place. PBIP/TMDL. |
| P0 | Rajesh6174/PowerBISync `…Introducing calculation groups RLS.SemanticModel/model.bim` | Calc groups + RLS together (TMSL JSON, loads directly). |
| P0 | microsoft/Analysis-Services `pbidevmode/…/SamplePBIP/Sales.SemanticModel` | MS "Smart Calcs" calc group + `Table.RenameColumns` friendly renames (name vs sourceColumn). Pair with sibling `Sales.Report` for field-well/buttons. |
| P0 | microsoft/powerbi-desktop-samples `Sales & Returns Sample v201912.pbix` | Buttons, drillthrough, custom tooltips, what-if params, conditional formatting, bookmarks — the report-layer gaps. Also binary `.pbix` ingestion. |
| P0 | microsoft/Analysis-Services `AsPartitionProcessing…/Model.bim` | OLS (`metadataPermission=none`) + multiple per-year query partitions. |
| P1 | Hugoberry/duckdb-pbix-extension `data/adventure/Model.bim` | M column renames hidden in the script (sourceColumn = final M name). |
| P1 | cyphou/Tableau-To-PowerBI `…Complex_Enterprise…/roles.tmdl` | Dynamic RLS: USERPRINCIPALNAME IN{}, ==, &&/\|\|. |
| P1 | malganis35/hotel-reservation-databricks-free `…/expressions.tmdl` | Databricks shape-B `Catalog=` + parameterized host from expressions.tmdl. |
| P1 | ProdataSQL/FinancialModelling `01_P&L_ParentChild…/Scenario.tmdl` | `PATH*` parent-child + friendly renames + ALL-CAPS physical vs Title-case friendly. |
| P1 | mthierba/tmdl-history `Contoso.bim` | Incremental-refresh `refreshPolicy` + escaped/nested `displayFolder`. |
| P1 | BLMgithub/automated-predictive-pipeline `…/predictions_nextweek.tmdl` | Native-query partition (`Value.NativeQuery` embedded SELECT). |
| P1 | AS AdventureWorks tutorial model (learn.microsoft / microsoft/Analysis-Services) | KPI sub-objects (target/status/trend), perspectives, cultures, hierarchies, `detailRowsDefinition`, `variations`. |
| P2 | jonaolden/yaml2pbip `…/Rate.tmdl` | Snowflake UPPER + `Kind="View"` + `#"…"` parameter Name=. |
| P2 | joeip0411/job_listing `…/dim__skill.tmdl` | Athena shifted roles (Glue catalog as Database). |
| P2 | TabularEditor/TabularEditor `TOMWrapperTest/TestData/AllProperties.bim` | sortByColumn, perspectives, hierarchies; pair with NewDeserializer.bim (cultures). |
| P2 | microsoft/fabric-samples + semantic-link-labs | Direct Lake `mode:directLake` partition (`entityName`/`schemaName`, no M). |
| P2 | pbi-tools#290 / data-goblin TMDL examples | Field parameters (`NAMEOF` calc table). |

Full 116-item sweep + the adversarial critic are archived in the run transcript
(`beads-sigma` epic notes). Work the P0/P1 corpus into `fixtures/` as gaps are fixed.
