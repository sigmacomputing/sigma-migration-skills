# Constrained semantic-context build path

Use this **opt-in Snowflake-only path** after the ordinary converter has created
and read back a data model, when the workbook builder cannot preserve DAX filter
context or a visual spans multiple facts. It does not replace the converter,
invent missing fields, or declare migration completion.

## Supported scope

- Explicit measures composed from SUM, AVERAGE, MIN, MAX, COUNTROWS and
  DISTINCTCOUNT, arithmetic, and DIVIDE with an optional numeric constant default.
- CALCULATE with equality predicates, KEEPFILTERS equality predicates,
  REMOVEFILTERS/ALL on a dimension, and a modeled USERELATIONSHIP.
- Calendar SAMEPERIODLASTYEAR, DATEADD and two-argument TOTALYTD, including the
  prior-year month-end extension needed when February gains a leap day.
- Native KPIs, one-dimensional bar/line charts, detail/grouped tables and pivots;
  a shared-dimension visual can aggregate independent facts without fact fanout.
- Categorical report/page filters and saved inclusive list selections, synced
  slicers, date/number ranges and visual Top-N with cutoff ties.

The compiler is deliberately limited. Unsupported expressions raise an error
before the workbook file is written. It rejects security-bearing source models,
bidirectional/many-to-many relationships, nested CALCULATE context changes,
expanded-fact-table filter removal, saved range/hierarchy slicer predicates,
conflicting synced defaults, unsupported visual roles, edited visual
interactions and unsupported filter shapes. Calendar behavior is qualified by
the fixture, **not** a claim of complete DAX compatibility. Additional cases need
source-oracle tests, particularly noncontiguous date selections, blank dimension
members, non-additive pivot subtotals, fiscal calendars and sparse date domains.

Review inherited Sigma security separately before choosing this path: the
`sigma_element()` SQL interface is not an acceptable way to bypass column-level
security. Use only converted base elements whose security and grain have been
verified for this report.

## Build

Run from the Power BI skill directory, with artifacts produced by the standard
extraction/conversion/readback flow:

```bash
python3 scripts/build-semantic-workbook.py \
  --model <model.bim> --signals <signals.json> \
  --master-map <master-map.json> --connection <connection-id> \
  --warehouse-type snowflake --folder-id <folder-id> \
  --reviewed-no-rls-cls --accept-ui-adaptations \
  --name "<workbook name>" --out <WORK>/workbook-spec.json
```

The workbook references the converted data model's base elements. Generated SQL
evaluates measures at the visual's grain with the report/page/slicer context in
the right place. Controls use bound Sigma SQL parameters, not string substitution
of user-entered values. Outputs also include `semantic-visual-map.json`,
`semantic-controls.json` and `control-scope.json`.

`--reviewed-no-rls-cls` records the required source-security review.
`--accept-ui-adaptations` is required when hierarchy/pivot/drill adaptations are
present; pass it only after the user approves those differences.

The layout uses source ordering and side-by-side relationships, but does not
copy fixed Power BI control-box heights. Hierarchy levels stack in a usable
left rail. Global controls share a compact header; helper tables are on a hidden
Data page. This layout rule is covered by an idempotency/placement regression.

## Publish and verify

1. Run local preflight and spec validation, then server verification/dry-run.
   Use the shared `lib/code_rep.py` or Ruby `CodeRep` endpoint helpers: on-disk
   files retain `document`, but `POST /v2/workbooks` takes `contents` and
   `dryRun: true` for verification. Read with
   `GET /v2/workbooks/{id}?includeContents=true`; update with
   `PUT /v2/workbooks/{id}/contents`, preserving the read `documentVersion`.
   Do not send the on-disk wrapper directly or use deprecated `/spec` endpoints.
2. For a **new** workbook using `sigma_element()` references, first create its
   populated converted-DM source elements with a valid Data-page layout. Then
   apply the complete validated document to that same workbook ID. A single
   create can pass dry-run yet fail at persistence with `No matching record`
   because the referenced source elements do not exist yet. Never present the
   intermediate Data-only workbook as a finished migration.
3. Read back the full document, verify source bindings and every retained column,
   and render every visible page. Keep layout in the final write.
4. Compare **every** data visual to Power BI exports or executeQueries at matching
   scope. Parse pivot headers/subtotals without dropping their numeric checks.
   Rounded source percentage CSVs need a source-derived unrounded ratio oracle,
   not a broad tolerance applied to all values.
5. Exercise primary/synced controls, multi-year selection, explicit date/number
   set-and-clear, unaffected measures and out-of-page negative controls. Export
   parameters use control variable names and must not persist control changes.
6. Keep source images, tile/control census, layout census, real anchor checks,
   render review and runtime evidence in the workdir. Run `adopt-workbook.rb` and
   the standard completion gate. Do not create a success marker by hand.

## Explicit UI adaptations

Hierarchy slicers become separate level dropdowns; this is not an arbitrary-path
tree-selection equivalent. Native Sigma pivots open expanded because collapsed
state is not exposed by the workbook spec. Ask for acceptance before calling
that result complete. A drill-level selector provides both directions instead
of replicating Power BI's drill toolbar. These must remain visible in the
migration readout; numeric parity does not make the interaction surfaces identical.

The five-page regression workbook completed the gate with **YELLOW** for the
user-accepted UI differences: 28/28 data visuals matched, 20 explicit runtime
checks passed, native control probes passed, and source anchors/layout checks
passed. No source/data gate was waived. See `regression-validation.md` for the
baseline and first-batch fixes.
