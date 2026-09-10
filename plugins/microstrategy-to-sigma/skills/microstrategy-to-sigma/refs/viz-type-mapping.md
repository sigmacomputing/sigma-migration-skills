# Dossier visualization types → Sigma element kinds

What the dossier API exposes per visualization is **shallow**: only
`visualizationType` + `definition.grid` (`rows` / `columns` / `metrics` /
`crossTab` / `metricsPosition`). There are no slot/encoding details beyond
which attributes and metrics sit on which grid axis. The converter therefore
maps `visualizationType` → a Sigma element kind via this lookup, feeds the
grid axes into the closest Sigma slots, and falls back to a **flagged table**
(data preserved, loud warning) for anything unmapped — never silently wrong.

**Status legend** — *extraction validated*: the type was pulled from real
demo-content dossiers and its `definition.grid` parsed as documented.
*Build*: whether the Sigma-element emission is part of the validated path.
Grid plus bar/line have live source-to-target evidence; waterfall uses the
released native shape; area is mechanically wired but still unverified. Do not
collapse those distinct evidence levels into a blanket "chart support" claim.

**Path B hand-build ✓** marks a shape proven on a live super-cube *rehost*
rebuild (`refs/path-b-rehost.md` §5) — spec-authored, POSTed, and
render/parity-verified end-to-end — but **not yet wired into the classic
converter's automated emission**. Treat it as a validated recipe to apply by
hand on Path B, not an auto-conversion. Also mapped there: a **synchronized-axis
bar chart** (MSTR's per-category same-scale panels) → `bar-chart`
`trellis:{rowsBy:[{columnId}]}` (needs a long facet dimension — unpivot wide
cube columns); **linked text boxes / chapter nav** → `button` + `navigate`
effect (or the built-in `settings.navigation` sidebar); a **dynamic last-N
chapter filter** → an element list filter pinned to the last N periods.

Counts below are from a 365-dossier / ~7,400-viz sweep of MicroStrategy's
public demo environment (Tutorial, MobileDashboards, Embedded Analytics,
AI Auto projects, 2026-06) — the extractor walker parsed **all** of them,
so every listed type is extraction-validated. Counts double as gap priority.

**Tiers.** *native* — a Sigma element kind reproduces the viz. **plugin tier**
— Sigma has **no native analog**; match it with a bespoke plugin element rather
than degrading to a table. *fallback* — flagged `table`, data preserved, loud
warning: the honest last resort, never presented as a match.

Sigma's complete visual set, enumerated from the compiled OpenAPI (2026-08-25):
`bar-chart · line-chart · area-chart · combo-chart · scatter-chart ·
donut-chart · pie-chart · kpi-chart · waterfall-chart · pivot-table · table ·
input-table · geography-map · region-map · point-map · plugin · container ·
tabbed-container · text · image · button · control · divider`. There is **no
treemap, sankey, or tile-heatmap**. (`VizTreemap` does appear in the OpenAPI —
as an *icon* name beside `Wand` and `Webhooks`. It is not a chart type.)

⚠️ **`heat_map` was mismapped here until 2026-08-25.** MicroStrategy's Heat Map
is a **treemap** — nested rectangles sized by a metric with a header band per
group — not a grid heatmap. This table previously claimed a `pivot-table` +
`backgroundScale` analog and marked it hand-build-✓. Shipped against a live
dossier it read as a plain table with cell shading: it dropped the size
encoding, the nesting, and the click-to-filter, and it was **rejected on
sight** by the reviewer. A tile that preserves the numbers but loses the
encoding is an *approximation*, not a match — say so, or fix it. See
`refs/plugin-tier.md`.

| MSTR `visualizationType` | n | Sigma element kind | Build |
|---|---|---|---|
| `grid` | 1893 | `table` (pivot when `crossTab: true`) | **validated (parity-verified)** |
| `kpi` | 1633 | `kpi-chart` | **Path B hand-build ✓** (roadmap for classic converter) |
| `bar_chart` | 810 | `bar-chart` | **validated** |
| `geospatial_service` | 331 | `region-map` / `point-map` (by geo attribute granularity — cognos `tiledmap` precedent) | roadmap |
| `line_chart` | 252 | `line-chart` | **validated** |
| `bubble_chart` | 221 | `scatter` (size slot) | roadmap |
| `heat_map` | 188 | **`plugin`** — a treemap. Sigma has no native one; `github.com/sigmacomputing/sigma-treemap-plugin`. Cross-filter a partner viz via a control (MSTR's `visualization_as_filter`) | **plugin tier** (was: pivot+`backgroundScale` — a LOSSY approximation, see below) |
| `combo_chart` | 182 | `combo` | roadmap |
| `area_chart` | 170 | `area-chart` | wired, **not live-verified** |
| `multi_metric_kpi` | 168 | a KPI-card row: per metric a `kpi-chart` with `comparisonColumn`+`comparison:{display:percentage,colorGood/Bad}` (Δ badge) + a "Previous …" subtitle `text` + a composite `area-chart` sparkline stacked below in the same container | **Path B hand-build ✓** (recipe: `path-b-rehost.md` §5) |
| `compound_grid` | 155 | `table` | roadmap |
| `microcharts` | 113 | `table` + composite `area-chart` sparklines (a borderless area-chart per row/metric; the KPI's own `trend` field is inert from spec) | **Path B hand-build ✓** (recipe: `path-b-rehost.md` §5) |
| `ring_chart` | 111 | `pie` (donut variant) | roadmap |
| `google_map` | 104 | `region-map` / `point-map` | roadmap |
| `pie_chart` | 90 | `pie` | roadmap |
| `comparison_kpi` | 67 | `kpi-chart` + `comparisonColumn`/`comparison` (the Δ badge IS spec-authorable) | **Path B hand-build ✓** |
| `sankey` | 42 | flagged `table` | fallback |
| `gauge` | 33 | `progress` when explicit value/range semantics exist; otherwise flagged `table` | **released, grounded-only** |
| `histogram` | 27 | `bar` (pre-binned) or flagged | fallback |
| `network` | 25 | flagged `table` | fallback |
| `waterfall` | 23 | `waterfall-chart` | **released** |
| `esri_map` | 21 | `region-map` / `point-map` | roadmap |
| `box_plot` | 16 | capability-gated `box-plot`; flagged `table` by default | gated (never claim native support without workspace verification) |
| `key_driver`, `time_series`, `auto_narratives`, `sequences_sunburst`, `forecast_line_chart`, `PageBy`, `ImageOverlay` | ≤12 ea | flagged `table` | fallback |
| **custom/marketplace vizzes** — any `HC*` (Highcharts), `D3*`, `Vitara*`, `EChart*`, `Arria*`, `Google*`, `CardWidget`, `RadarChart`, `SimpleKPIChart`, … | ~230 total | flagged `table` — third-party viz plugins, unconvertible by definition | fallback |
| *anything else* | — | flagged `table` fallback | fallback |

Custom-viz names are not a closed set (they're marketplace plugins) — treat
any type not in this table as custom and flag it.

**Structural-feature frequencies** from the same sweep (extractor handles all
of these; converter coverage noted): selectors 51% of dossiers, chapter
filters 49%, multi-dataset 42%, free-form `fields` — text 65% / image 54% /
shape 33% / **html 11%** — and nested panelStacks 23%. Multi-chapter dossiers
emit `navigation` tabs; nested panel stacks emit `tabbed-container` structure
only when every panel has concrete visualization children (otherwise the whole
container is a loud gap); only explicit print-break markers emit one-row
`page-break` elements (dossier page count and report pageBy do not); explicit
repeater metadata emits
`repeated-container`; explicit style/legend metadata is allowlisted; and
legend/drill selector labels remain loud gaps until extraction carries the
complete released control source/target bindings. Free-form text →
Sigma `text` elements; images/shapes/html are flagged; **attribute selectors
+ chapter filters → Sigma controls** (CONVERTED — wired to the selectors'
declared `targets` viz lists, `control-scope.json` sidecar, gate 7 +
flip-test; metric-condition selectors are flagged MANUAL). `feature-gaps.json`
records every detected released feature that lacked enough source semantics;
multi-dataset chapters still require one Sigma element per dataset-backed viz.

`fixtures/BUILD_SPEC.md` is the drag-and-drop spec for an "every viz type"
fixture dossier (REST cannot author visualizations — Library UI only); use it
to extend the validated set.

Keep `VIZ_MAPPED` in `../../microstrategy-assessment/scripts/assess.py` in
sync with this table — the assessment classifies estates against it.
