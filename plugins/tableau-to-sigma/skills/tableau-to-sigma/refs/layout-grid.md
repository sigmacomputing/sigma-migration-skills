<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Split from refs/workbook-layout.md (E9.3 phase-scoped refs, 2026-07-27): this file owns the 24-col grid, layout XML, Ruby helpers, page recipes, assembly, and the mistake table. Siblings: twb-zone-mapping.md (.twb zone tables), chart-patterns.md (multi-series + maps), element-kinds.md (element/control field requirements). -->

# Workbook Layout Reference

> **Spec shape lives in `sigma-workbooks`.** This file is Tableau-conversion-specific: Ruby layout generation, multi-series chart patterns, dashboard-translation idioms. For the canonical workbook spec shape (element kinds, sources, controls, formulas, formatting), read the `sigma-workbooks` skill's `reference/specification/`. Treat that as the source of truth — when this file disagrees, the sigma-workbooks reference wins.

Layout is always generated with Ruby. Never hand-write layout XML.

## Grid system

Sigma uses a 24-column CSS grid. Rows are numbered from 1 and use span-style notation:
- `gridColumn="1 / 25"` — full width (columns 1 through 24)
- `gridColumn="1 / 13"` — left half
- `gridColumn="13 / 25"` — right half
- `gridRow="1 / 7"` — rows 1 through 6 (6 units tall)

Row heights are relative units (auto). KPIs are ~6 units tall, charts 12-18 units.

## Layout XML structure

The layout is a **single field on the workbook spec's `document` object** — NOT a per-page
field. It is one XML string containing all pages concatenated, each identified by the
server-assigned page ID.

> Workbook specs require a top-level `document` key wrapping `schemaVersion`/`pages`/`kind`/
> `layout` (confirmed live 2026-08-03, including on `POST /v2/workbooks/spec/verify`
> 2026-08-04); only `name`/`folderId`/`ownerId` stay outside it. Data-model specs remain
> flat — do not wrap those. `layout` lived at the request root before this change; every
> `spec['layout']` / `spec.layout` reference below means `spec['document']['layout']` now.

```json
{
  "name": "My Workbook",
  "document": {
    "layout": "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Page type=\"grid\" ...>...</Page>\n<Page ...>...</Page>",
    "pages": [
      {"id": "Hn2bYOjeRL", "name": "Overview", "elements": [...]},
      {"id": "gAPPHE3kaD", "name": "Product",  "elements": [...]}
    ]
  }
}
```

**Critical:** Do NOT set `layout` on individual page objects. The API silently ignores per-page
layout fields — the workbook will appear unstyled even though PUT returns `success: true`.
Strip any `layout` key from page objects before writing the PUT body.

### Page tag — required attributes

Each page in the layout XML must use this exact format, with the server-assigned page `id`:

```xml
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="Hn2bYOjeRL">
  ...
</Page>
```

A bare `<Page>` tag without `type`, `gridTemplateColumns`, `gridTemplateRows`, and `id` is ignored.

### Element — for plain elements (charts, tables, KPIs)

```xml
<Element elementId="abc123" gridColumn="1 / 25" gridRow="1 / 7"/>
```

### Container — for container elements that wrap children

```xml
<Container elementId="container-id" type="grid"
  gridColumn="1 / 25" gridRow="1 / 9"
  gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <Element elementId="kpi-1-id" gridColumn="1 / 7" gridRow="1 / 9"/>
  <Element elementId="kpi-2-id" gridColumn="7 / 13" gridRow="1 / 9"/>
  <Element elementId="kpi-3-id" gridColumn="13 / 19" gridRow="1 / 9"/>
  <Element elementId="kpi-4-id" gridColumn="19 / 25" gridRow="1 / 9"/>
</Container>
```

Only `<Element>` and `<Container>` are valid on live Sigma workbook endpoints.
The historical `<LayoutElement>` and `<GridContainer>` aliases receive HTTP 400
and must be accepted only when reading old local artifacts.

**Critical:** Container elements MUST use `<Container>`, not `<Element type="grid">`.
Using `<Element>` for a container causes empty containers to appear in the published workbook.

**Critical — inner KPI row spans must match the container outer span.** `gridTemplateRows="auto"`
does NOT fill available container height — rows size to content minimum. A KPI at `gridRow="1 / 2"`
inside an 8-row container renders as a tiny sliver with truncated names. Always set the inner
`gridRow` end value equal to the container's outer end value (e.g., container at `1 / 9` → KPIs
at `1 / 9`).

## Ruby helpers

```ruby
require 'yaml'
require 'date'
require 'json'

def gc(eid, c0, c1, r0, r1, inner)
  "<Container elementId=\"#{eid}\" type=\"grid\" " \
  "gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\" " \
  "gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\">\n#{inner}\n</Container>"
end

def le(eid, c0, c1, r0, r1)
  "  <Element elementId=\"#{eid}\" gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\"/>"
end

# page_id is the server-assigned page ID (e.g. "Hn2bYOjeRL"), NOT the page name
def page_xml(page_id, *children)
  header = "<Page type=\"grid\" gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\" id=\"#{page_id}\">"
  [header, *children, "</Page>"].join("\n")
end
```


## Typical page layout: 4 KPIs + line chart + 2 bar charts

```ruby
# Read the current spec (server-assigned IDs required)
spec = YAML.safe_load(File.read('/tmp/current-spec.yaml'), permitted_classes: [Date, Time])

# Find the Overview page and extract element IDs by name
overview = spec['pages'].find { |p| p['name'] == 'Overview' }
els = overview['elements'].each_with_object({}) { |e, h| h[e['name']] = e['id'] }

container_id  = els['KPI Row']        # container element
kpi1_id       = els['Total Sales']
kpi2_id       = els['Total Profit']
kpi3_id       = els['Profit Ratio']
kpi4_id       = els['Sales per Customer']
line_id       = els['Monthly Sales by Segment']
bar1_id       = els['Monthly Sales by Category']
bar2_id       = els['Sales by Ship Mode']

# Container spans outer rows 1-9 (8 units). Inner KPIs MUST span rows 1-9 to fill the container.
# Using 1/2 here would render KPIs as a tiny sliver — names invisible.
kpi_inner = [
  le(kpi1_id,  1,  7, 1, 9),
  le(kpi2_id,  7, 13, 1, 9),
  le(kpi3_id, 13, 19, 1, 9),
  le(kpi4_id, 19, 25, 1, 9)
].join("\n")

overview_layout = "<Page>\n" \
  "#{gc(container_id, 1, 25, 1, 9, kpi_inner)}\n" \
  "#{le(line_id,  1, 25,  9, 22)}\n" \
  "#{le(bar1_id,  1, 13, 22, 34)}\n" \
  "#{le(bar2_id, 13, 25, 22, 34)}\n" \
  "</Page>"
```

## Other canonical page layouts

### Title + filter shelf + 2×3 chart grid

The most common Tableau-derived layout: dashboard title at the top, a row of
filter controls beneath it, and 6 charts in a 2-row × 3-column grid.

```ruby
overview_layout = page_xml(
  'page-overview',
  le('title-text',         1, 25,  1,  3),     # title bar (full width)

  le('el-ctl-date',        1,  9,  3,  6),     # 3 controls horizontal
  le('el-ctl-region',      9, 17,  3,  6),
  le('el-ctl-state',      17, 25,  3,  6),

  le('el-chart-1',         1,  9,  6, 18),     # row 1 of charts
  le('el-chart-2',         9, 17,  6, 18),
  le('el-chart-3',        17, 25,  6, 18),

  le('el-chart-4',         1,  9, 18, 30),     # row 2 of charts
  le('el-chart-5',         9, 17, 18, 30),
  le('el-chart-6',        17, 25, 18, 30)
)
```

### Title + filter sidebar (left) + content

Alternative when the Tableau dashboard has filters stacked vertically on the
left. The sidebar takes ~6 cols; the content grid takes the remaining 18.

```ruby
overview_layout = page_xml(
  'page-overview',
  le('title-text',     1, 25,  1,  3),

  le('el-ctl-date',    1,  7,  3,  9),         # sidebar — 3 controls stacked
  le('el-ctl-region',  1,  7,  9, 15),
  le('el-ctl-state',   1,  7, 15, 21),

  le('el-chart-1',     7, 25,  3, 15),         # content area: 2 cols × 2 rows
  le('el-chart-2',     7, 16, 15, 27),
  le('el-chart-3',    16, 25, 15, 27)
)
```

### Title + 4 KPIs + hero + 2×2 grid

Useful when the source dashboard has a KPI strip up top (executive overview pattern):

```ruby
kpi_inner = [
  le('kpi-1',  1,  7, 1, 9),
  le('kpi-2',  7, 13, 1, 9),
  le('kpi-3', 13, 19, 1, 9),
  le('kpi-4', 19, 25, 1, 9)
].join("\n")

overview_layout = page_xml(
  'page-overview',
  le('title-text',         1, 25,  1,  3),
  gc('kpi-row',            1, 25,  3, 11, kpi_inner),
  le('el-hero',            1, 25, 11, 24),     # full-width hero chart
  le('el-chart-1',         1, 13, 24, 36),     # 2×2 grid
  le('el-chart-2',        13, 25, 24, 36),
  le('el-chart-3',         1, 13, 36, 48),
  le('el-chart-4',        13, 25, 36, 48)
)
```

## Row sizing guide

| Content | Typical row span |
|---|---|
| KPI row container (single row of KPIs) | 8–9 outer rows |
| KPI row container (two rows of KPIs) | 12–14 outer rows |
| Wide line/area chart | 13 rows |
| Bar chart (half-width) | 12–13 rows |
| Data table | 15–20 rows |

> **Critical — KPI inner row span must equal the container outer span.**
> `gridTemplateRows="auto"` inside a Container does NOT expand rows to fill
> the container height. If your KPIs use `gridRow="1 / 2"` inside a container
> that spans 6 outer rows, the KPIs render as a tiny sliver — names invisible,
> values barely readable.
>
> **Rule:** inner `gridRow` end value must match the container's outer row span.
> Container at `gridRow="1 / 9"` (8 outer rows) → KPIs inside at `gridRow="1 / 9"`.
>
> For two rows of KPIs in one container (container outer `1 / 13`):
> - First row: inner `gridRow="1 / 7"` (6 inner units)
> - Second row: inner `gridRow="7 / 13"` (6 inner units)

## Full spec assembly with layout

```ruby
# Merge layout into a copy of the current spec, then PUT
spec = YAML.safe_load(File.read('/tmp/current-spec.yaml'), permitted_classes: [Date, Time])
doc = Sigma::CodeRep.document(spec)  # tolerates a legacy flat GET too — see shared/lib/code_rep.rb

# Build per-page XML using server-assigned IDs
pages_by_name = doc['pages'].each_with_object({}) { |p, h| h[p['name']] = p }

overview_xml  = page_xml(pages_by_name['Overview']['id'],  ...)
product_xml   = page_xml(pages_by_name['Product']['id'],   ...)
# ...

# Set ONE layout field on `document` — remove any layout from page objects
doc['pages'].each { |p| p.delete('layout') }
doc['layout'] = [
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
  overview_xml,
  product_xml
].join("\n")

spec = Sigma::CodeRep.wrap(doc, extra: Sigma::CodeRep.metadata(spec))  # writes always nest
File.write('/tmp/workbook-with-layout.json', JSON.pretty_generate(spec))
```

Then PUT:
```bash
curl -s -X PUT \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/workbook-with-layout.json \
  "$SIGMA_BASE_URL/v2/workbooks/<workbookId>/spec"
```

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Using `"kind": "kpi"` | `"Invalid kind: 'kpi'"` | The correct kind is `"kpi-chart"` — never `"kpi"` |
| Using `"kind": "pie"` | `"Invalid kind: 'pie'"` | The correct kind is `"pie-chart"` — the official example library is wrong here |
| Using `"kind": "donut"` | `"Invalid kind: 'donut'"` | The correct kind is `"donut-chart"` — the official example library is wrong here |
| KPI names invisible or truncated inside container | Inner `gridRow` too small — e.g., `1 / 2` inside a 6-row container | Set inner end value = container outer end value: container `1 / 9` → KPIs `1 / 9` |
| KPIs appear as a tiny sliver at top of container | Same root cause as above | Same fix — match inner row span to container outer span |
| Setting `layout` on each page object instead of on `document` | PUT returns success but UI shows no layout change | Set `spec['document']['layout']` once; strip `layout` from all page objects |
| Bare `<Page>` tag without `type`/`id` attributes | Layout ignored silently | Use `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="<pageId>">` |
| Using `measures` instead of `yAxis` on bar/line charts | `"Invalid array: ...yAxis, got undefined"` | Replace `measures` with `yAxis` |
| KPI missing `value` field | `"Invalid object: ...value, got undefined"` | Add `"value": {"columnId": "<col-id>"}` to every `kpi-chart` element |
| Using `rows`/`columnGroups` on a pivot table | API accepts silently but pivot does not render | Use `rowsBy`/`columnsBy` (object arrays) and `values` (string array) |
| Using IDs from POST body instead of GET response | Layout elements don't appear | Always GET spec after POST to get real IDs |
| `<Element>` for a container | Empty container visible | Use `<Container>` for elements that have children |
| Hand-writing layout XML | Off-grid sizing, overlapping elements | Use Ruby helpers; let math determine positions |
| Overlapping row ranges | Elements hidden behind each other | Draw row ranges on paper; ensure no two elements share rows on the same column span |
| Fallback `els.values[N]` when page has fewer elements than expected | `elementId=""` in XML — PUT rejected with `invalid_request` | Guard with `(le(id, ...) if id)` and call `.compact` on the children array before passing to `page_xml` |
| Using `dimension` on a `line-chart` | Works but is non-canonical | Use `xAxis` for both `bar-chart` and `line-chart` |

### Minimum tile heights (grid rows) — the render-blank floor

Sigma renders a tile BLANK (page and PNG export) below a per-kind grid-row
minimum, and hand-authored layouts routinely trip the layout lint on this (a
real run collected 19 violations). The enforced floors
(`SigmaLayout::KIND_MIN_ROWS`, mirrored in the layout lint):

| element kind | min gridRow span | why |
|---|---|---|
| `kpi-chart` | 4 | value + label need ~4 rows to render at all |
| any `*-chart` | 8 | axis/labels suppressed and the tile blanks below ~8 |
| `table` / `pivot-table` | 10 | header row + a few data rows |
| `control` | 2 | one input strip; 2 keeps the label visible |
| `text` | 2 | |

When authoring `layout` XML by hand, give every element at least its floor —
the lint (gate 6) fails otherwise, and shrinking a section to match tight
source geometry must come out of GAPS, not out of tile heights.
