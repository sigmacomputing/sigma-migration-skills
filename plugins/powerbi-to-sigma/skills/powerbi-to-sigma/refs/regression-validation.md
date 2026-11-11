# Synthetic regression validation

## Baseline and evidence

The regression source is a five-page Power BI report with seven tables, two
facts, 17 measures, nine relationships and 42 visuals. Its fixed Import-mode
data includes year boundaries, leap day, missing fact rows, tied product ranks,
cancelled records and local/UTC timestamps. Source validation uses an independent
Python oracle (29 DAX checks) and six browser interaction checks.

The full baseline does **not** complete. It exposes missing time-intelligence
measures, CALCULATE filter-context loss, incomplete date/control reach and a
mixed-fact visual. Do not confuse the baseline model's clean column types with
semantic parity. Do not weaken the completion gate or publish the incomplete
full workbook to get a green result.

The first repair batch covers:

- Local PBIX with modern `Report/definition/` PBIR as well as classic
  `Report/Layout`; unsafe archive paths and page names are rejected.
- Modern `visualContainerObjects` titles and saved categorical slicer selections,
  preserving numeric, text and boolean literal types.
- Source camelCase column aliases and entity-qualified joined dimensions.
- Lowercase new workbook-generated column ids; existing DM ids and control
  handles remain unchanged.
- Preflight-safe inline KPI aggregates, current KPI alignment enums, and omission
  of the DM-only `visibleAsSource` attribute from workbook elements.

A **four-visual qualification subset**, explicitly named as not a full migration,
passed local preflight, server verification, create/update/readback, PNG rendering
and exact live exports: selected-region revenue, alternate-region revenue and
Top-5 with a cutoff tie (six included products, two excluded). Export parameters
were keyed by control variable name; saved control state was unchanged afterward.
This proves those fixes only, not the full report.

## Full-report retest

The opt-in `build-semantic-workbook.py` path now preserves the regression
report's DAX context using converted data-model sources. All 28 data-visual
exports match Power BI; 20 explicit runtime checks cover sync/page scope,
replacement/intersection filters, year selection, date/number clearing and drill
levels. Matrix detail, subtotal and grand-total values and colors are retained.

The full workbook was rendered and its layout repaired after user review.
Hierarchy levels use a readable left rail rather than narrow horizontal inputs;
filters/KPIs use compact aligned bands. The user accepted level-dropdown
hierarchy controls and initially expanded native pivots. The completion gate
therefore reports **YELLOW**, not pixel-identical GREEN. Source screenshots,
six measured anchors and the layout/control/tile censuses are retained in the
private run evidence. The shared synced-control scope fix is a separate
dependency: the old lint consumed the primary's annotation before linting copies.

Usage, supported scope and explicit limits: `semantic-context.md`.

## Ongoing qualification requirements

- Verify prior-year, prior-month, YTD and YoY across visual grains without
  filtering away required history. Check multi-year selection and calendar edges.
- Preserve replacement versus intersection semantics for CALCULATE/KEEPFILTERS
  and REMOVEFILTERS. A source already filtered by a slicer cannot implement a
  measure that restores excluded rows with a conditional aggregate alone.
- Verify every report/page filter's source relationship reach, including both
  facts and intentionally disconnected controls. Shared masters must not leak
  page-only filters into another page.
- Verify synced slicers against distinct page sources, date-range propagation,
  numeric range controls, hierarchy selection, totals formatting and initial
  collapsed state. Schema acceptance is not behavioral evidence.
- Keep verifying all source data visuals, not just the qualification subset; exercise
  adoption, source swaps and ID preservation after a real complete migration.

## Environment observations

- Source PNG/PDF ExportTo returned `FeatureNotAvailableError` in the test
  environment. Authenticated user-owned embedding with the existing device-login
  Power BI token rendered every page and supported slicer/export tests. This
  route requires suitable browser tooling and delegated permissions; do not
  create public embeds or change tenant settings as a workaround.
- The downloaded PBIX included a binary DataModel and modern PBIR report parts.
  The model extractor recovered all seven tables, 17 measures and nine
  relationships. A `Connections.RemoteArtifacts` entry alone did not establish
  that this Import-mode model was composite.
- New warehouse tables required a Sigma connection sync before lookup succeeded.
- A valid Sigma CLI profile containing spaces/parentheses was rejected by the
  shared token provider's profile-name validation. The test used an explicitly
  acquired CLI access token instead. Fix the provider separately in shared
  infrastructure; never rename the user's profile without permission.

Keep raw tenant IDs, downloaded PBIX connection metadata, credentials, and live
readbacks outside committed fixtures. Offline tests should use synthetic names
and values and must continue running without live credentials.
