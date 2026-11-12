# Large `.pbix` / PBIR reports (many pages, NativeQuery models, slicer-heavy)

Read this before converting a report that has any of the following:
- several pages, or dozens of slicers;
- a large import model whose partitions are `Value.NativeQuery` SQL;
- measures that mix facts under slicer-driven "as-of" dates.

It records what made such reports slow (several pages, a few hundred visuals, thousands of measures) and the path that now gets them through in far fewer passes.

## Why these reports were slow

| Where the time went | Root cause | Now |
|---|---|---|
| Getting a DM that POSTs (~35%) | ~25 model-shape gaps found one 400 at a time; every rerun re-extracted for 60-120 s | model gaps fixed at extraction, `dm-resolver` before POST, `--probe-sources` gate, extraction cache |
| Measures (~40%) | the converter translates measures one by one, out of context; most visual measures did not bind | page-fact pattern (below) |
| Verification (~15%) | no way to run SQL against the source warehouse | `sigma-sql-probe.py`, `parity-from-oracle.py` |
| Workbook mechanics (~10%) | dropped saved slicer selections, cross-page control composition, hidden visuals laid out, empty containers | builder fixes (below) |

## The fast path

```bash
ruby scripts/migrate-powerbi.rb --pbix <file.pbix> --connection <id> --folder <folderId> \
  --probe-sources --out <WORK>
```

Rerun with the same `--out` after fixing anything: Phase 0/1 extraction is cached.

### 1. Extraction is complete (no flags)

`extract-model-pbix.py` now emits what the converter needs. Each of these was a hand fix before:
- **"Enter data" tables** (`Table.FromRows`) become typed SQL rows: a `Value.NativeQuery` over a `UNION ALL` of literal SELECTs, not a placeholder warehouse path.
  - Date cells are the text the author typed, so they are parsed in the model culture's numeric order (en-US `1/15/2024` is M/D/Y; de-DE `15.01.2024` is D.M.Y). ISO dates parse in any culture. Two-digit years, month names and out-of-range parts are not guessed: the cell loads as NULL.
  - Every NULLed cell is a loud warning (`[pbix-model] WARNING ...` and `<WORK>/extract-notes.json`), not only a `SigmaMigration.ExtractNote` annotation.
  - SQL types: Snowflake, Databricks and BigQuery as before; Postgres and Redshift get generic ANSI types (`DOUBLE PRECISION`). Any other `--warehouse-type` (Synapse, SQL Server, MySQL, ...) is refused: the partition is left as extracted, with a loud note, rather than emitting Snowflake syntax that fails at the warehouse.
- **Model culture**: pbixray documents no culture accessor. The extractor probes for one (`culture`, `model_culture`, a `cultures` table, a `metadata` Name/Value row) and uses it when found. When it is not found, **en-US is assumed** and that is recorded (annotation `SigmaMigration.CultureAssumed`, a `[pbix-model] WARNING`, `extract-notes.json`). For a non-en-US `.pbix`, check the culture in Power BI Desktop; Enter-data dates and text-to-number casts follow it. The `--tmsl` route carries the real `model.culture`.
- **Incremental-refresh tables** with no partition M take their source from the refresh policy's `SourceExpression` and carry `refreshPolicy`. `RangeStart`/`RangeEnd` predicates fold to a rolling window anchored at today, recorded as an approximation.
- **Phantom columns** (plain copies of calculated columns) are dropped.
- **Model metadata** comes through: real `SourceColumn` model-level renames, accurate `dataType`, `hierarchies[].levels[]`, and `sortByColumn` when pbixray exposes it.
- **RLS roles** are emitted as `model.roles[].tablePermissions`. Without them, the RLS gate silently never fires.

`extract-pbir.py` now carries:
- **saved slicer selections** as `slicer_state.saved_selection` (`2026L` is an int, `true`/`false` are booleans);
- **field-bound refs**: a `queryRef` can be stale after a measure rename, so bindings follow `field.*.Property`;
- **slicer-self filters**, marked so they never become defaults;
- **`hidden: true`** on visuals, including members of hidden groups;
- a top-level **`bookmarks`** list.

### 2. The DM is fixed before it is posted

- **Name sanitising** (`name-sanitize.json`): a `/` in a column or measure name cannot be referenced in a Sigma formula, so it becomes U+2215 consistently in the TMSL, the DAX and the signals.
- **NativeQuery fold**: Power Query steps after native SQL fold into the SQL, and M parameters qualify 2-part names. SQL output names containing `/` are aliased (`slashAliases`).
- **`lib/pbi_dm_resolver.rb`** (writes `dm-resolver.json`) runs after the restore and before validation. It:
  - remaps stale converter prefixes;
  - rewrites refs to the exact target name, matching case-, space- and punctuation-insensitively and following relationship paths;
  - translates leaked DAX: comments, `DIVIDE`, `LASTDATE`, `IN {…}`, `AND()`/`OR()`, `<> null`, and so on;
  - turns `DateTrunc` over `YYYYMMDD` integer keys into `MakeDate(...)`;
  - de-duplicates element ids;
  - nulls, and records, anything that resolves nowhere.
- **Distinct-values calculated tables** (`lib/pbi_calc_table_sql.rb`, writes `calc-table-sql.json`): a calculated table that is `DISTINCT`/`VALUES`/`SUMMARIZE`/`DISTINCT(SELECTCOLUMNS)` over one table's plain columns (comments, one `VAR..RETURN`, and a filter-less `CALCULATETABLE` are unwrapped) becomes `SELECT DISTINCT ... FROM (<source SQL>)`, and its relationships are restored. This runs after the resolver and before the calculated-table gate.
  - Any other shape (filter argument, `ADDCOLUMNS`, measures), or a source table that is unresolved or itself a placeholder, is untouched, so the gate still stops.
  - Calculated columns that merely copy a sibling column are kept. The rest are listed under `pending_calculated_columns` and must be re-authored. Casing and `VALUES` blank-row differences are recorded as notes.
- **`--probe-sources`** runs every Custom SQL element once against the warehouse (LIMIT 1 plus `SYSTEM$TYPEOF`). It:
  - writes `sql-output-names.json` for the resolver, stamped (`sql-output-names.stamp.json`) with each statement's hash. A later run without `--probe-sources` ignores the names of any element whose SQL changed, and says so, instead of nulling refs that are now valid;
  - folds casts where the TMSL type differs from the warehouse type. For example, VARCHAR `'True'`/`'False'` becomes boolean; otherwise a boolean slicer default silently fails to filter.
  - **stops (exit 10) on any bound column missing from the SQL output**. This replaces the POST→400→fix loop.
  - `--probe-results FILE` replays captured results offline; `--probe-allow-missing` nulls the binding instead of stopping.
  - A statement the probe cannot name the columns of (a zero-row result on BigQuery) is reported as unverified, never as "every column missing", and does not stop the run.
  - The per-statement probe cache (`native-source-probe.cache.json`) is keyed on connection, dialect and SQL text, with a timestamp per entry. Entries older than `--probe-cache-max-age-hours` (default 24) are re-probed. If you fixed the warehouse (added a column to a view) and the SQL text is unchanged, rerun with `--probe-no-cache`; the STOP box says so.
  - The scratch probe workbook is created once and looked up by its unique name after a 5xx/524 on create (never blindly re-created), then deleted.
  - A numeric 0/1 column the model types boolean is cast with `IFF(c IS NULL, NULL, c <> 0)` (Snowflake) or `(c <> 0)`; `TRY_TO_BOOLEAN` takes text only.
- **`--stop-before-post`** creates nothing in Sigma on any path: build-new (after the DM spec validates), DM reuse (explicit or auto-picked) and the workbook phase. The only Sigma object it can touch is the `--probe-sources` scratch workbook, which is deleted.
- **Extraction cache**: a fingerprint in `run-provenance.json` skips Phase 0/1 on reruns. `--reuse-extract` and `--no-reuse-extract` override it.

### 3. The workbook is built for multi-page, slicer-heavy reports

- **Page-local master copies**: each page's elements and controls use their own child copy of a shared master. Slicer defaults then never AND-compose across pages, which can silently empty other pages; the control lint flags it.
- **Sync groups**: the primary control targets every member page's copy. A saved selection on any member page becomes the default.
- **Control defaults**:
  - Saved selections become typed control defaults.
  - A boolean list control is never `include []`, which matches ZERO rows in Sigma; "all" is `exclude []`.
  - A slicer's own visual-level filter is never used as a default.
- **Held-back visuals** are recorded in coverage:
  - hidden visuals, unless a bookmark shows them;
  - visuals with no bound measure.
- **No empty containers**: an empty layout `<Container>` makes `PUT /v2/workbooks/{id}/contents` return **HTTP 500**, not a 400, so it is never emitted.
- **Layout**: control bands wrap at 6 per row, each kind meets its minimum height (pivot/table 10 rows), a band stretches when its sibling is held back, and legend bands use `gridTemplateRows="auto"`.
- **Labels**: slicer labels use the field name, date axes are formatted, and a field's own parenthetical routes to its View column (`Date (Fiscal Month)` → `Date (Fiscal Month) (DimDate)`).

## Measures: classify the page, then build it

The converter is good at measure-by-measure translation. Report pages often are not measure-by-measure: one matrix can
mix inventory, sales and forecast measures by a shared dimension, under an as-of date and year/period slicers.
Classify each page before building it:

| Page shape | Build | Typical visuals |
|---|---|---|
| One fact, time series or pivots (Sales/Cost/GP/OM, rolling windows, LY) | Sigma formulas on that fact's joined `<Fact> View`, with per-visual sourcing (`--source-mode per-visual`) | single-fact trend charts and pivots |
| Several facts in one visual; measures evaluated per entity then bucketed or aggregated again; slicer-driven as-of dates the page's default filters would remove | **One page-fact SQL element**: grain = shared dims × selectors, one pre-computed column per measure component; Sigma only sums and divides | KPI matrices, bucketed per-entity measures, rolling-window charts |

Write the page-fact SQL from the page's DAX closure. Check it against an **independent oracle SQL** written from the same
DAX: `sigma-sql-probe.py` runs both, and `parity-from-oracle.py` compares them and writes `parity-final.json`. A closure of
50+ measures usually collapses to about 15 additive parts under the page's default filters.

### Slicers on dimensions a page fact does not carry

A page fact pre-computes windows or ratios at a fixed grain, so a slicer on any other dimension has no column to
filter, and the control lint reports it dead. Adding every slicer dimension to the grain multiplies the rows (one
factor per slicer dimension) and breaks non-additive parts. Instead, filter where Power BI does:
on the fact rows, before the windows.

1. Find the slicer's path in the model: the ACTIVE relationship chain from the slicer table to each fact the page
   reads (for example dimension A → `fact.A_KEY`; dimension B → dimension C → `fact.C_KEY`; a dimension
   that relates to several facts filters every one of them). Check the page's DAX for `ALL`/`REMOVEFILTERS`/`TREATAS`
   over that table.
2. Copy the page fact's SQL into a workbook Custom SQL element and add one predicate per slicer, as a semi-join so a
   duplicate dimension key cannot multiply rows:
   `(CASE WHEN {{#formula ArrayLength([Ctl])}} = 0 THEN TRUE ELSE fact.KEY IN (SELECT KEY FROM dim WHERE COL IN {{Ctl}}) END)`.
   Empty selection = no filter, as in Power BI.
3. Keep the default view fast: the page copy element the charts read gets `source: union` of (a) a child of the
   materialized data-model element filtered to `ArrayLength([Ctl1]) + … = 0` and (b) the parameterized SQL gated with
   `({{#formula ArrayLength([Ctl1])}} + {{#formula ArrayLength([Ctl2])}} + …) > 0` inside each fact CTE. Sigma inlines
   the template values as literals, so Snowflake folds the gate and skips the closed branch.
   - **`USERELATIONSHIP` changes the slicer path.** When the page's measures wrap their fact scan in
     `USERELATIONSHIP(Bridge[Key], Fact[Key])` and the slicer table also reaches the fact directly, both paths are
     one-to-many (same priority tier) and Power BI takes the one holding the activated relationship (higher path weight;
     Microsoft Learn, *Model relationships*, "Resolve relationship path ambiguity"). Filter through the bridge then
     (for example a slicer on the bridged dimension reaches the fact rows through the bridge's source key), and write the oracle the same way:
     an oracle that copies the direct-path assumption will agree with the wrong SQL.
   - **(Blank) is a member.** Power BI slicers list NULL attributes as "(Blank)", and the blank virtual row of a
     one-side table also collects fact rows with a NULL or unmatched key. Give each control a value list of
     `Coalesce(<col>, "(Blank)")`, compare `COALESCE(attr, '(Blank)') IN {{Ctl}}`, and add
     `OR ('(Blank)' IN {{Ctl}} AND (fk IS NULL OR fk NOT IN (SELECT key FROM dim WHERE key IS NOT NULL)))`.
   - A hierarchy slicer wired at its top level only cannot reproduce a sub-level pick; add one param control per level
     (ANDed) when the source report users drill.
4. Verify: render the parameterized SQL with every template neutral (gate open, each control empty) and compare it
   with the data-model element (row count and measure sums must be identical); then compare a filtered export
   (`/export` with `parameters`) against an independent oracle that applies the same predicate.

Verified live behaviours:
- `IN {{Ctl}}` renders a multi-select list control as a quoted SQL list, with apostrophes escaped; an empty control
  renders an empty array, so always guard it with `ArrayLength`.
- One `{{#formula …}}` template holding a long sum (10 `ArrayLength` terms) fails the POST with "Formula exceeded
  depth limit"; use one template per control and add them in SQL.
- A union's output columns are read as `[Union of N Sources/<col>]`; `matches[].sourceColumns` take the bare `[<col>]`.
- The export API's `parameters` reach a control that has no `filters` target and is referenced only in SQL.
- The control lint counts a control referenced as `[ControlId]` in a column formula as live (the gate column does this).

## Sigma behaviours that bite (verified live)

- A name containing `/`, as in `[A/B]`, gives "Dependency not found". Refs are case-insensitive but not punctuation-insensitive.
- `DateLookback(MovingSum(...))` and `MovingSum(DateLookback(...))` both return EMPTY. Define LY on the sibling column
  instead: `DateLookback([<TY column name>], [<x column name>], 1, "year")`.
- A control that filters the date range removes prior-period rows before window functions run. If the model's date
  table is not marked as a date table, Power BI keeps that filter too (DATEADD does not escape it). Blank LY series under
  a fiscal-year slicer can therefore be faithful; check before "fixing" them.
- A workbook element-level list filter `include [false]` on a boolean column is silently ignored; `exclude [true]` works.
  A list control with `include [false]` does work. An element list filter `include [true]` on a boolean FORMULA column
  is dropped at POST (absent from the readback); filter a numeric gate instead (`list include [0]` or a `number-range`).
- PBIR visuals that are hidden, with no bookmark that shows them, are permanently hidden. Do not lay them out. The classic Report/Layout route emits no `bookmarks` key, so there nothing is held back: hidden visuals are laid out and recorded with an informational coverage note. Held-back hidden visuals are recorded `recoverable: false`.

## Visual fidelity (screenshot-compared reports)

- Signals now carry PBI display names (`display_names`), slicer header titles (`header_title`) and ABSOLUTE visual boxes (group-relative PBIR offsets are summed up the `parentGroupName` chain; raw values stay in `x_rel`/`y_rel`). A visual fully covered (>= 95%) by one higher-z visible visual is held back like a hidden one ("occluded by <visual> on the default view", same bookmark exception). Hidden slicers that still filter sit in a bottom band, "Filters hidden in the source report". `tableEx` stays a flat table, number formats come from TMSL `formatString`, and `--model` alone now drives sort-by-column.
- `scripts/crop-source-visuals.py --signals S --page P --screenshot PNG --out-dir DIR [--offset X,Y --scale S]` writes one PNG per visible visual plus `crops.json` (read these for gate-13 anchors and per-visual compare).
- `scripts/layout-geometry-check.rb --signals S --spec WB.json` reports per-visual IoU of the Sigma grid box against the source box and flags inverted left/right or above/below order (informational, exit 0).
- Pick the layout mode with that check. `--layout clean` reflows visuals into uniform bands, which typically scores a low IoU and inverts the source's reading order. `--layout pbi` (canvas-proportional, group offsets resolved) keeps the arrangement, and `polish-layout.rb` then tidies it. Use `pbi` plus polish when the result will be compared with the source pages.
- Screenshots carry state the `.pbix` does not: selections in a hidden slicer pane ("Show slicers" button). Test a mismatch against plausible hidden-slicer states (visible rows constrain them) before calling the DAX misread, and ask for the pane's state with the screenshot.
- Text amounts (`"$1,234.50 "`) are parsed with the model culture before a text→number cast, as Power Query does; a bare `TRY_TO_DOUBLE` returns NULL for them. Comma-decimal is decided by the FULL culture tag, not the language: de-DE/fr-FR/es-ES/it-IT/pt-BR/... use `1.234,56`, but de-CH, de-LI, it-CH and es-MX/es-US/es-PR/es-DO/es-GT/es-PE/es-419 use `.` as the decimal, and en-ZA/en-DK/en-NL/en-SE/en-150 use `,` (CLDR). fr-CH is comma-decimal in CLDR. Swiss apostrophe grouping is stripped.
- `Text.From(<date|datetime|decimal>)` in a folded `Table.AddColumn` is culture-formatted text in Power Query but ISO/locale-free text after the fold: it carries an approximation note.
- Parity: the literal text `None`, `null`, `nan` is a real member, not a NULL (only an empty cell, `(Blank)`, JSON null or a float NaN is blank). A chart with zero rows on both sides is reported `empty-both, unverified` and fails the gate: nothing was compared.

## Polish the layout (after any `--layout` mode)

```bash
ruby scripts/polish-layout.rb --spec WB.json --signals SIGNALS.json [--out OUT.json] [--layout-out L.xml]
```

Run it on the built spec after the builder, whatever `--layout` mode you used and before the POST/PUT. It is for pages where `pbi` came out ragged (uneven slicers, mismatched cards, over-tall tables, dozens of hidden-pane slicers) or `clean` lost the arrangement (23 controls in one row, huge KPI tiles, a crushed table). It ignores the existing layout and re-derives it from the SOURCE boxes in `signals.json`, so re-running is safe: it is deterministic and idempotent. Without `--out` it rewrites `--spec` in place; the layout stays wherever it came in (top-level `layout` or `document.layout`). Then run `layout-geometry-check.rb` and the render gate.

What it does, per page matched to a signals page (other pages, such as the hidden Data page, are untouched):
- **Keeps the arrangement.** An XY-cut over the content boxes (horizontal cut first, then vertical; overlaps under 8 px are ignored unless the boxes sit side by side) gives a tree of bands and columns. Columns split the 24-column span in proportion to their source widths, with minimums (chart 6, table 8, KPI 3, text 4). Peers in one band (all KPIs) get equal widths and identical heights. Sibling columns are equalised by stretching the last chart or table of the shorter one; KPIs and text are never stretched.
- **Sizes to the house rules.** KPI 5 rows; chart 10 (12 when its source box is 300 px or taller); table `clamp(5 + ceil(1.25n), 10, 30)`, pivot `clamp(5 + ceil(1.25n) + 2L, 10, 32)` (L = `columnsBy` levels; n + 1 with a totals row), `n` = `row_cardinality` (14 when absent); caption 3 rows (+1 per ~180 characters); section label 2. Nothing goes below `KIND_MIN_ROWS`.
- **Stacks the bands.** Header (kept if present, else made from the page name); one control band for the visible slicers (6 per row, 4 columns each, date ranges 6, 3 rows per row, source order); the content; then, only when slicers are hidden in the source (or have no source match), a Filters drawer (`--hidden-controls drawer`, the default: an overlay `drawer-<page>` plus a "More filters (N)" button at the right end of the control band, or of the header band when there are no visible controls; the controls sit one per row in an overlay `<Page>` appended after the real pages, with their filter targets unchanged and no reset button) or, with `--hidden-controls band`, a bottom band with a small **More filters** label and those controls. A legend control rides inside its chart's own container, and is dropped when the chart has no color/series column. No empty container is ever emitted.
- **Tweaks elements.** Tables and pivots get `tableStyle: {preset: presentation}` unless set; every number-formatted column gets `displayNullAs: ""` (blank instead of "null"); a caption loses leading `#` marks; a section label becomes `### <label>`.

Limits: slicers that sat in ONE source row but wrap onto several control rows show up as left/right "inversions" in the geometry check (reading order is kept, row-major); more than 12 columns in one band wrap onto a second row.
