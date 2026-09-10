# Path B — super-cube (Quick Cube) rehost + faithful rebuild

`SKILL.md` Phase 0.5 branches here when the dossier's dataset is a **super-cube**
(`subtype 779` — a file / Quick-Cube import, `Row Count - <name>.xlsx` metrics,
no live warehouse). There is no warehouse semantic model, so `extract.py` /
`convert.py` do **not** drive it. This ref is the depth behind the Path B steps:
extract the data correctly, land it so Sigma can see it, recover the derived
metrics, and rebuild the dossier with real fidelity (not a generic dashboard).

Everything below is live-validated on a real multi-table super-cube dossier
(4 Excel sheets → Snowflake → Sigma DM + 5-page workbook, row-parity exact).

---

## 1. Extract the data — a multi-sheet cube is MANY tables

A naive "pull the whole cube into one flat table" **fails** on a multi-sheet
import: requesting every attribute + metric at once cross-joins the sheets and
MSTR aborts with `Cartesian Join Governing`. The cube's auto-generated
`Row Count - <name>` metrics **enumerate the source tables** — extract each at
its own grain.

Use `scripts/extract-cube.py <cubeId> <outDir>` (one CSV per table +
`cube_manifest.json`). What it encodes, and what to know if hand-driving it:

- **Per-table request:** `POST /v2/cubes/{id}/instances` with
  `requestedObjects:{attributes:[that table's attrs], metrics:[measures + its Row Count]}`,
  then `GET /v2/cubes/{id}/instances/{iid}?offset=…` to page.
- **Membership by probe:** an attribute/measure belongs to a table iff it can be
  requested alongside that table's Row Count *without* a Cartesian abort.
  Conformed dims (Year/Quarter/Region/…) match several tables — that's expected.
- **Element lists are PAGE-SCOPED.** `data.headers.rows[r]` are element
  *indices* into **that page's own** `definition.grid.rows[i].elements` — resolve
  labels per page while paging, never carry indices across pages.
- **Fan-out guard (do not skip).** A conformed dim grouped with the wrong
  table's measure silently duplicates rows. Pull grand totals with **no
  attributes** (`requestedObjects.attributes: []`) and assert, after grouping,
  `SUM(row-count) == table total` and `SUM(measure) == measure grand total`.
  `extract-cube.py` fails (exit 1) if either mismatches. This is what proves the
  extracted CSV is the real table, not an inflated cross-join.

> A single-table cube (no `Row Count -` metrics) is the simple case: the whole
> grid is one table and the classic "flatten attrs-on-rows + metrics-on-columns"
> holds.

---

## 2. Land it so Sigma can see it

`COPY` the CSVs into the warehouse the Sigma connection reaches (quote
identifiers to preserve display names). Two gotchas that otherwise block the
DM/workbook POST:

- **Grant + sync.** The connection reads as a **service role**, not the role
  your loader (`snow` CLI, etc.) used to create the tables. So the new tables
  are invisible until you (a) `GRANT SELECT ON <DB>.<SCHEMA>.<TABLE> TO ROLE
  <the connection's role>` and (b) **schema-level** sync the connection:
  `POST /v2/connections/{connectionId}/sync {"path":["DB","SCHEMA"]}`.
  Table-level sync 404s until the table is already discovered, so sync the
  **schema** first. (Full story + how to find the connection's role:
  `sigma-data-models`.)
- **Prefer a `sql` DM source over `warehouse-table` for freshly-loaded tables.**
  A `warehouse-table` source resolves through Sigma's cached catalog, so a
  brand-new table often fails to POST (`Source not found`) until the sync above
  lands. A `sql` source (`{kind:sql, connectionId, statement:"SELECT … FROM
  DB.SCHEMA.TABLE"}`) runs live against the connection and resolves immediately
  — the role still needs `SELECT`, but there's no catalog-sync dependency. It
  also lets you alias columns to clean display names in one place.
- **Derive time attributes in that `sql` source.** MSTR dossiers routinely use
  Year / Quarter / Month attributes derived from a date the cube stores as a
  string. Do the derivation once in the SQL so the DM exposes clean typed columns
  — e.g. `TO_DATE(REPORT_DATE,'MM/DD/YYYY') AS "Date"`,
  `YEAR(…) AS "Year"`, `'Q'||QUARTER(…) AS "Quarter"`, `MONTHNAME(…) AS "Month"`
  — rather than fighting string dates in every downstream formula. A real DATE
  type also lets a KPI pick the latest period (`… [Date] = Date("YYYY-MM-DD") …`).

Rejoin the normal flow at **Phase 3** (build the DM, then the workbook).

---

## 3. Recover the DERIVED metrics — they aren't in the cube's objects

The dossier's headline metrics (e.g. Revenue / Cost / Operating Income /
margin %) are frequently **dossier-level derived metrics** — computed *in the
dossier*, so they do **not** appear in the cube's `availableObjects`. Recover
them, don't guess:

1. **Find their ids** in an executed viz: `GET …/visualizations/{key}` →
   `definition.grid.columns[…templateMetrics].elements[]` carries each metric's
   `name` + `id`.
2. **Reverse-engineer the definition** from the statement structure — which
   base rows they aggregate (e.g. Revenue = `Sum(Amount)` where
   `Category = "Revenues"`; Cost = the `Cost of Revenues` + `Operating Expenses`
   categories; Operating Income = Revenue + Cost; margin % = the ratio).
3. **Verify against the executed viz values across ALL periods**, not one.
   Export/execute the KPI (or trend) and confirm your formula reproduces every
   period before trusting it. Ship the reverse-engineered metric only once it
   matches; otherwise label it an approximation. (Cross-period verification is
   what separates "looks right for Q4" from "correct.")

These become metrics on the Sigma data model (`sigma-data-models`).

---

## 4. Capture the design INTENT before rebuilding

The bundle/vizzes tell you the data; they do **not** tell you the intended
*design*. Two cheap, high-value captures:

- **Read the dossier's own "Dashboard Details" / "About" chapter if it has one.**
  Many polished dossiers ship a documentation page that literally describes each
  chapter's chart kinds, filters, and interactions ("panel stack with a panel
  selector", "grids with outline mode", "heat map … filters the horizontal
  stacked bar to the right", "synchronized-axis bar chart", "default dynamic
  selection filter set to the last 4 quarters", "linked text boxes"). It is a
  design spec handed to you — read it first.
- **Execute every viz** (`…/instances/{mid}/chapters/{ck}/visualizations/{vk}`)
  for the exact attribute↔metric pairings and displayed values (the parity
  baseline + how derived metrics slice).
- **Vizzes on one page can carry DIFFERENT filters — detect them per viz.** A KPI
  may show the latest period, a table the current year, a trend all years, all on
  the same page. Heuristic: if a viz's value is a clean fraction of the all-data
  aggregate, look for a viz/chapter period filter before assuming your Sigma
  aggregation is wrong. (Reproduce with the pre-filtered-source pattern in §5.)
  Also expect **sub-1% deltas** vs the source's printed values — the shared demo
  cubes drift and a "current year"/dynamic-window boundary rarely lands on an
  exact calendar year; reconcile the delta, don't chase it as a logic bug.

**PDF-export limits (`export-dossier-pdf.py`):** it tends to render only the
*active/default* chapter and **blocks external images** (whitelist) — so the
branding logo comes back empty and other chapters may be missing. Don't treat
the PDF as the whole dashboard: execute each viz, and ask the customer for the
logo asset (Sigma `image` elements need a **hosted URL** — there is no upload
API). Match the source **theme** too (a dark dossier → `settings.theme.name:
Dark`), not the default light canvas.

---

## 5. Fidelity recipes — MSTR viz → Sigma element (live-validated on Path B)

These are the shapes that turn "right data, generic look" into a faithful
rebuild. All authored via `/v2/workbooks/spec`; see the `sigma-workbooks` skill
for full field reference and always clone shapes from a recent GET-back / the
compiled OpenAPI (`assets.sigmacomputing.com/openapi/public-rest-api/...`),
which is ahead of any vendored copy.

- **`multi_metric_kpi` → a row of comparative KPI cards.** Each card is a
  container holding: a `kpi-chart` with `comparisonColumn:{columnId}` +
  `comparison:{display:"percentage", colorGood, colorBad}` (the ▲/▼ delta
  badge), an optional "Previous Quarter: …" subtitle `text`, and — for the
  sparkline — a **separate borderless `area-chart` stacked BELOW the KPI in the
  same container** (the KPI's own `trend` field is inert from spec; the
  composite renders). Give the KPI ~6 grid rows or the comparison badge gets
  dropped (KPI drops lower items when short).
- **`grid` with outline mode / consolidations → `pivot-table`** with a
  `rowsBy` hierarchy (Category ▸ Description, etc.) and `columnsBy` the period.
  Consolidations are custom subtotal groupings; the hierarchy reproduces the
  shape (exact custom subtotal *ordering* is only approximated).
- **`heat_map` → `pivot-table` + `conditionalFormats:{type:backgroundScale}`**
  (a diverging scheme for signed values). This is a real analog — do **not**
  fall back to a flagged table. Wire heat-map→bar cross-filtering as a control
  if the source does.
- **`comparison_kpi` → `kpi-chart` with `comparisonColumn`** — the comparison is
  spec-authorable; don't flag it as manual.
- **synchronized-axis bar chart → `bar-chart` `trellis:{rowsBy:[{columnId}]}`**
  (one same-scale panel per category). Needs a **long** facet dimension, so if
  the cube stores the split as wide columns (one metric per category), **unpivot
  to long** — a `sql` source with `UNION ALL`/`UNPIVOT` (or a `transpose`
  source) that yields a `Department`-style column. Note: a column can't sit on
  both `trellis` and `color` — add a **duplicate column** for the color channel.
  > A **nested TIME axis** (Year▸Quarter shown under year brackets) is a
  > *different* thing — that is ONE chart, not panels. Build a single combined
  > period column (`Text([Year]) & " " & [Quarter]`) sorted chronologically on
  > the x-axis; do **not** trellis by year (trellis is for per-**category** small
  > multiples, and trellising a time split reads as disconnected mini-charts).
- **panel stack + panel selector → `tabbed-container`.** One `<Tab>` per panel
  (bare `<Element>` children only, no nested `<Container>` inside a `<Tab>`);
  drive it from a button with the `select-tab` effect if needed.
- **linked text boxes / chapter navigation → `button` elements with a
  `navigate` effect** (`effects:[{effect:navigate, target:{type:page, page:…}}]`),
  or the built-in side sidebar (`settings.navigation.pageSidebar:"enabled"`,
  `primary:"sidebar"`). **The `button` element has no color field** — its color
  is the theme primary, so set `settings.theme.overrides.colors.highlight` (else
  buttons render Sigma-blue). The `navigation` element renders as a horizontal
  tab bar and its vertical mode clips — stacked `button`s give the boxed look.
- **dynamic "last N quarters" chapter filter → an element list filter** pinned
  to the last N period values (MSTR's "default dynamic selection filter").
- **A grouped table that ALSO needs a filter → point it at a pre-filtered
  hidden source element, don't filter the grouped element itself.** A per-element
  list filter on, say, a `Year` column fights the element's `groupings`/top-n and
  renders wrong — the top-ranked row's values get duplicated across every row and
  the rest go blank (verified). The robust fix: add one hidden passthrough table
  (`retail-2023` = `Retail Base` with a single `Year = 2023` filter) and source
  the grouped tables/charts from *it*, grouping cleanly with **no** filter column
  of their own. (This supersedes any "just hide the filter column" advice — hiding
  it does not fix the grouping conflict.)
- **selector panels ("Choose Metric / Geo / Time") → `control` elements.** A
  `list` control needs TWO distinct bindings — a double-nested **`source`** that
  populates the dropdown's *options*, and a **`filters`** array that wires what it
  *filters* downstream. They are separate; the `filters` target must be a
  **table** element's column. Verified shape (live):
  ```
  { "kind": "control", "controlType": "list", "controlId": "YearCtl",
    "source":  { "kind": "source", "source": { "kind": "table", "elementId": "grid" }, "columnId": "col-year" },
    "filters": [ { "source": { "kind": "table", "elementId": "grid" }, "columnId": "col-year" } ] }
  ```
  **Omit `source` and the dropdown renders EMPTY** even though the POST returns
  200 — a `filters`-only control does not target/populate, so always render and
  confirm the options appear. A default selection is `values:[…]` and must match
  the column's underlying **type** (a numeric year is `2023`, not `"2023"` — a
  type mismatch silently fails to pre-select). MSTR selectors that dynamically
  add/remove GRID COLUMNS are **UI-only** — reproduce as filter controls over a
  fixed grid and flag the dynamic-column behavior.
- **`microcharts` → `table` with inline data bars / a composite sparkline**, but
  the tile's measure is frequently **absent from the viz `templateMetrics`** (an
  attribute-form or dossier-derived value). Recover it from the source or
  approximate it and **label the approximation** — never present a guessed metric
  as the source's exact one.
- **Theme:** `settings.theme.name:"Dark"` + `overrides.categoricalScheme` (the
  source's palette) + `overrides.colors.highlight` (accent). Set it once at the
  document level; per-element `color.scheme` still drives bar/line series.

---

## 6. Gates (same rigor as the classic path)

`assert-phase6-ran.rb` is wired for the classic path and does not apply to a
Path B hand-build, but you still MUST:

- **Row parity** — expected values come from MSTR (executed viz / report), never
  invented; money & counts exact.
- **Source-fidelity Visual QA** — render every page and compare to the source
  (PDF where it rendered, plus the executed-viz values and any screenshots).
  Right numbers in the wrong-looking dashboard still fails this gate.

Never declare done on an HTTP 200.
