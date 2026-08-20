# Posting converter output to Sigma — required spec fixups

The `convert_powerbi_to_sigma` MCP output (`sigmaDataModel`) is NOT directly postable. These fixups were discovered posting the Employee Dashboard DM (`b0d1f611`) + workbook (`b093a40f`) on 2026-05-31. Tracked as converter gap `[bead]`; until the converter emits them, the skill's post step applies them.

## Data model — `POST /v2/dataModels/spec`
The bare `sigmaDataModel` (`{name, pages}`) is rejected. Wrap/augment to:
```json
{ "name": "...", "schemaVersion": 1, "folderId": "<uuid>", "ownerId": "<id>", "pages": [...] }
```
1. **`schemaVersion: 1`** (integer). Missing → `{"summary":"schemaVersion: Invalid 1: undefined"}`.
2. **`folderId` (UUID) + `ownerId`** — not produced by the converter (environmental). Pull from a reference DM:
   `GET /v2/dataModels?limit=1` → `GET /v2/dataModels/{id}/spec` → reuse its `folderId`/`ownerId`. (This is the tableau-to-sigma reuse logic — `find-or-pick-dm.rb`.)
3. **Element `name`** on every base `warehouse-table` element — set to `source.path[-1]` (the table name). The converter leaves base elements unnamed (only joined "…View" elements get names), but workbook masters reference DM elements **by name** (`[EMPLOYEES/Col]`), so unnamed elements are unreferenceable.

Post with `tableau-to-sigma/scripts/post-and-readback.rb --type datamodel --spec <file>` (handles 401-refresh + the column-type `error` guard).

### Gotcha: PUT reassigns element IDs
`PUT /v2/dataModels/{id}/spec` (e.g. to add element names) **reassigns server element IDs**. Always GET the spec back after a PUT and use the *new* IDs for the workbook's masters.

## Workbook — `POST /v2/workbooks/spec`
- **`document`-wrapped, not flat** (verified live 2026-08-03, including on `/verify`
  2026-08-04): `schemaVersion`, `pages`, `kind`, and `layout` nest under a top-level
  `document` key; `name`/`folderId` stay outside it. Needs `document.schemaVersion: 1` +
  `folderId`. (No `ownerId` required.) The DM POST above is a *different* surface and
  stays flat — don't wrap it.
- **Data page**: hidden `table` masters, one per DM element used: `source:{kind:"data-model", dataModelId, elementId}`, columns `[{id,name,formula:"[ElementName/Col]"}]`, named (e.g. `EMP`, `ABS`).
- **Chart elements** source from a master: `source:{kind:"table", elementId:"<master id>"}`.
  - bar/line: `"xAxis":{"columnId":"<dimColId>"}`, `"yAxis":{"columnIds":["<measColId>"]}`
  - pie/donut: `"color":{"id":"<dimColId>"}`, `"value":{"id":"<measColId>"}`
  - text/title: `{"id":..., "kind":"text", "body":"## Title"}`
  - dim formula `[Master/Col]` (or `DateTrunc("month",[Master/Date])`); measure formula wraps it: `CountDistinct([Master/Id])`, `Sum([Master/Hours])`.
- Workbook POST **keeps** the element/page IDs you provide (unlike the DM PUT).

## Layout — never leave charts stacked
Charts post fine with no `layout` (they stack vertically) — but that's not done. Apply the
24-col grid via a single `document.layout` XML string (see *Workbook* above) and
`put-layout.rb`. See `research/powerbi-visual-layout.md §4` for the px→grid math and
`tableau-to-sigma/refs/workbook-layout.md` for the XML shape (`<Page>`/`<Element>`/`<Container>`).

## Reference IDs from the validated run (the demo Sigma org)
- Snowflake connection `gxb98765` = `ab12cd34-5678-40ab-8def-1234567890ab` (holds `DEMO_DB.DEMO.*` workforce tables).
- DM `Power BI Import` = `b0d1f611-2088-4570-95cb-70590860af53`.
- Workbook `Employee Dashboard (from Power BI)` = `b093a40f-bd63-4d9d-9f33-2f2e79d14373`.
