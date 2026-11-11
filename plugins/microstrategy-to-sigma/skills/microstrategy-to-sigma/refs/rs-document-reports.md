# Report Services documents → Sigma Reports (pixel-positioned print path)

A MicroStrategy **Report Services (RS) document** is the banded, print-oriented
artifact: invoices, statements, form letters. A **dossier** is the interactive
dashboard. Dossiers keep the workbook path (Phases 1–6). An RS document whose
printed PDF is the deliverable converts to a **Sigma Report** (`/v2/reports`):
fixed pages, absolute pixel layout, header/footer panels, a paginated detail
table. `scripts/convert-rs-document.py` does that conversion. Its mappings are in
`refs/catalogs/document-control.json`, and tests live in
`tests/test_rs_document_report.py`.

## Status (2026-10-29)

| Step | State |
|---|---|
| Definition → Sigma Report body | **Built + tested offline** (golden: `fixtures/rs-documents/golden/`) |
| Sigma structural acceptance | **Live `POST /v2/reports` `dryRun` valid** for invoice, banded and page-footer variants (non-persistent; probe source = an existing demo table) |
| Extracting the definition from MicroStrategy | **Not built.** The public REST API (and mstrio-py `Document`) exposes RS document *data* and *PDF export*, not sections/controls/positions. Today the definition is hand-built (see below) |
| Create + PDF export + side-by-side PDF parity | **Not done.** Needs a landed warehouse table, an approved destination, and the source PDF |

Don't claim pixel parity from a dry run. It proves Sigma accepts the shapes, not
how they print.

## Input contract — `mstr-rs-document/1`

One JSON file per document. `fixtures/rs-documents/tutorial-invoice.rs-document.json`
is the worked example, transcribed from Strategy's *Create a sample invoice
document* tutorial.

```jsonc
{
  "format": "mstr-rs-document/1",
  "provenance": {"kind": "hand-built", "basis": "...", "doc_ref": "https://..."},
  "document": {"id": "tutorial-invoice", "name": "Customer Invoice"},
  "page": {"width_in": 8.5, "height_in": 11, "margin_in": {"top": 0.5, "left": 0.5, ...}},
  "defaults": {"font_family": "Arial", "font_size_pt": 10},
  "dataset": {
    "name": "Invoice Lines",                        // Sigma table element name (formulas reference it)
    "source": {"kind": "warehouse-table", "path": ["DB", "SCHEMA", "TABLE"]},
    "fields": {                                     // key = MSTR object, "@FORM" for a non-DESC form
      "Customer":    {"column": "CUSTOMER_NAME", "type": "text",   "role": "attribute"},
      "Customer@ID": {"column": "CUSTOMER_ID",   "type": "number", "role": "attribute"},
      "Day":         {"column": "DAY_DATE", "type": "date", "role": "attribute", "date_format": "%m/%d/%Y"},
      "Cost":        {"column": "COST", "type": "number", "role": "metric", "aggregation": "Sum"}
    },
    "filters": [{"field": "Day", "kind": "date-range", "start": "2005-01-01", "end": "2005-03-31"},
                {"field": "Customer", "kind": "list", "values": ["..."]}],
    "sort": [{"field": "Day", "direction": "ascending"}]
  },
  "grouping": [{"field": "Customer", "page_break_between_groups": true,
                "sample_value": "Aaronson Maxwell",
                "functionally_dependent": ["Customer@ID", "Customer City", "Customer State"]}],
  "sections": [                                     // each kind at most once
    {"kind": "page-header", "height_in": 0.45, "controls": [...]},
    {"kind": "group-header", "height_in": 1.05, "controls": [...]},
    {"kind": "detail-header", ...}, {"kind": "detail", ...}, {"kind": "detail-footer", ...}
  ]
}
```

A **control** is `{id, type, left_in, top_in, width_in | width_mode: "100%", height_in, ...}`:

- `type: text` + `text`. MicroStrategy text-field syntax: literals, `{Attr}`,
  `{[Attr With Spaces]}`, `{Attr@ID}`, `{Metric}`, auto text `{&PAGE}` /
  `{&NPAGES}` / `{&PAGES}`, and `\n` for a CTRL+ENTER line break. Optional
  `format`: `font_size_pt`, `font_family`, `bold`, `italic`, `color`,
  `backcolor`, `align`, and `number: {category: Currency|Percent|Fixed|...}`.
- `type: image` + `image.url` (or `--image-url <id>=<https url>`).
- `type: line` + `line: {style: solid|dashed|dotted|double, weight, color}`.
- `type: rectangle` + `format.backcolor`.
- `assumed: [...]` lists every value the source did not state. Carry it through,
  because it tells the reviewer which positions to recheck against the source PDF.

Section kinds are `page-header`, `page-footer`, `document-header`,
`document-footer`, `group-header`, `group-footer`, `detail-header`, `detail`
and `detail-footer`. The `detail` section is required.

### Building a definition by hand

There's no extractor yet. Read the definition off the source document in
MicroStrategy Developer / Web (Property List → Left / Top / Width / Height in
inches, per control), or off the document's design spec. Use the rendered PDF
(`POST /api/documents/{id}/instances`, then `POST
/api/documents/{id}/instances/{instanceId}/pdf`, the endpoint
`scripts/export-dossier-pdf.py` already uses) to confirm positions and
fonts. Bind each dataset object to the warehouse column the dataset report
reads. The SQL view of the dataset report shows it.

## Mapping

| MicroStrategy | Sigma Report |
|---|---|
| Page size / margins | `config.pageWidth/pageHeight/margin` at 96 px/in (Letter = 816 × 1056). Sigma takes one margin, so uneven margins are a layout gap |
| Page Header / Page Footer | `panels[]` header/footer (height = section height); children panel-local, x offset by the margin |
| Document / Group / Detail-footer sections | absolute `<Element>`s on the body page: x = margin + Left, y = margin + header panel + section offset + Top |
| Detail Header + Detail | one `table`, `flow="paginated"`, full content width; a column per Detail data field ordered by Left, named by the Detail Header label within 0.15 in of its Left; the header band's backcolor/bold → `tableStyle.textStyles.columnHeader` |
| Text field `{Attr}` outside the detail | `{{First([<dataset>/<col>])}}` (+ ` \| <date format>`) |
| Text field `{Metric}` outside the detail | `{{Sum([<dataset>/<col>]) \| <d3 format>}}`: the section subtotal, as MicroStrategy documents it; the control's own format wins, and no format means unformatted |
| `{&PAGE}` / `{&NPAGES}` | `{{CurrentPageNumber()}}` / `{{TotalPageCount()}}` |
| Line | `divider` (weight pt → px; `double` → solid + gap) |
| Rectangle | header band → table header background; ≤ 0.1 in tall → divider; otherwise gap |
| Dataset report filters | table `filters` (`list`, `date-range`) |
| Font size | points × 96/72 → px in a `<span style>`; text boxes grow to Sigma's 24 px minimum line box (clipping evidence: `cognos-to-sigma/refs/print-reports.md`) |

### Grouping: invoice mode vs banded mode

- **Page break between groups** (one invoice per customer) → **invoice mode**.
  The body page is one group's document. A single-select `list` control on a
  hidden "Parameters" page filters the detail table. All header/footer text
  aggregates over that filtered table, so it shows the selected customer.
  `sample_value` / `--default-group-value` picks the default; without one, an
  export merges every group, which is a blocking gap. To reproduce "one PDF per
  customer", schedule the report once per control value. Schedules are not part
  of report contents, so that's a recorded `review` gap.
- **Grouping without page breaks** → **banded mode**. The table gets
  `groupings` (group key + the group-header attribute fields as keys) and
  footer metrics as `calculations`, named by the label to their left on the same
  row. Free-form group furniture (labels, lines, addresses) has no per-group
  slot, so it's a `layout` gap. A base-level sort on the grouping key is rejected
  by Sigma ("Sort column not in level"), so banded mode leaves it to the grouping.

`functionally_dependent` declares which header attributes have one value per
group. Anything else (the tutorial's Ship Date) still renders as `First()` and is
recorded as `review`.

### Why not `report-repeated-container`

The report-only repeated container (`pageBreakAfterRows`, pixel `containerSize`)
looks like the natural home for a banded group. Live dry runs on 2026-10-29 showed
it can't carry an invoice yet:

- Layout must be `<Element elementId="rc" ...>` with nested `<Element>`
  children. The workbook `<Container>` form returns `expected Element ... got <Container>`.
- Row-bound text fails in every documented naming form
  (`[<source name> repeated container/<col>]`, `[<table> repeated container/<col>]`,
  `[rc/<col>]`) with `Dependency not found`.
- `table` and `kpi-chart` children are rejected (`element kind 'table' is not allowed
  inside a report-repeated-container`). Only static text, image and divider
  children pass.
- A `table` source for the container must sit on the same page.

Revisit when row binding verifies. Then the group header can become a card, so
each customer prints on its own page without a schedule.

## Outputs and exit codes

- `--out`: the `POST /v2/reports` body `{name, folderId, description, contents}`
  (`folderId` defaults to the `{{FOLDER_ID}}` placeholder). Verify with `"dryRun": true`.
- `--gaps-out` `feature-gaps.json`: `{mode, blocking, gaps[{control, section,
  construct, severity, detail}], warnings}`. `blocking` means wrong data or a
  missing construct (unmapped control type, unknown field, composite detail
  text, unmapped filter, nested grouping, no default group value). `layout`
  means a visible difference to review in the PDF. `review` means a semantic
  choice to confirm.
- `--map-out` `control-map.json`: each source control → Sigma element id, root,
  and pixel box, for visual QA overlays.
- Exit 0 = no blocking gaps; 2 = blocking (outputs still written; `--allow-gaps`
  → 0); 1 = invalid definition.

## Workflow

```bash
python3 scripts/convert-rs-document.py --document doc.rs-document.json \
  --connection-id <conn> --folder-id <folder> --image-url logo=https://... \
  --out report.json --gaps-out feature-gaps.json --map-out control-map.json
# 1. dry run: POST /v2/reports with "dryRun": true (non-persistent)
# 2. create only after the user approves name + folder (reports have no DELETE endpoint)
# 3. export the PDF (POST /v2/reports/{id}/export) for each sample group value and
#    compare it page-by-page with the MicroStrategy PDF; review every layout gap
```

`cognos-to-sigma/scripts/compare-report-pdfs.py` (page count, paper size, text
and raster diff) can do the PDF comparison. Data parity is the same rule as every
converter: query the Sigma detail table for a group value and compare it with the
MicroStrategy document instance's dataset rows for that value.

## Known limits

- No extractor. The REST API doesn't return RS layout, and graphs, grids,
  panel stacks, selectors and HTML containers inside documents are unmapped
  (blocking) until they have a verified mapping.
- One grouping level. Nested groups are blocking.
- Detail table column x-positions and row heights follow Sigma's table layout,
  not the source Left/height. The detail box is a fixed height (`--detail-rows`),
  and content below it is pinned rather than flowing with the row count.
- Page numbers count across the whole Sigma report. MicroStrategy can restart
  them per group.
