# Fidelity rubric — the per-dimension checklist for the blind grade and the RCF loop

Shared across all `*-to-sigma` migration plugins (canonical: `shared/refs/`).

> **The standard is the business user's:** would someone who uses the source dashboard recognise
> this as the same dashboard, find every number where they expect it, and trust it? Deduct for what
> that person would notice and care about. Do not deduct for **platform differences** (things Sigma
> renders differently and a build cannot change; see `refs/sigma-platform-differences.json`) or for
> cosmetic noise such as typeface, gutter widths or a few pixels of spacing.
>
> Two readers use this file. The **blind grader** (`refs/blind-grader-brief.md`) scores the six
> dimensions below from the two images alone. A **builder** running a fidelity loop (where the
> skill ships one) reads each render against the source, scoring every dimension and the two
> functional ones, and classifies each gap. This EXTENDS `layout-visual-qa.md` with the scoring and
> the two **functional** dimensions a pure visual diff misses (controls, accuracy).
>
> Convergence, observed across the exemplars: pass 1 fixes **structure** (missing tiles, wrong
> kinds); passes 2–3 fix **composition** (containers, tints, text); pass 4+ fixes **typography /
> number-format** detail. Stop early when nothing fixable remains.

## Visual dimensions (these are the six graded dimensions and their `scores`)

- **element_titles_hidden** — no exposed or truncated element-title chrome that the source hides.
- **palette_match** — series/slice colors, canvas and band tints read as the source brand; accent reserved, not sprayed. Exact hex is not required; a different hue family is.
- **composition_match** (layout / containers) — same element set, same arrangement and reading order, banded rather than a flat stack; no overlaps, no dead zones; nothing dropped or invented. Pixel-exact is not required; grouping and reading order are.
- **chart_shapes_match** — SHAPE IDENTITY, **a hard requirement, not a style point.** Every viz must be recognizably the same visualization as the source tile: same chart family, same encoding (bars/dots/cells/table), same per-row/per-column structure. A ranked **bar-table** (label + per-category bar columns + printed values) rebuilt as one grouped bar chart FAILS. An annotated strip panel rebuilt as generic bars FAILS. A categorical axis flattened to numeric codes FAILS. A **missing tile** FAILS. **Correct data rendered as a different viz is a fidelity failure, not an approximation** — the owner sees a different dashboard. Source navigation/action chrome (buttons, tab strips) is not a visualization tile.
- **labels_legible** — no truncated or clipped labels, values, rows or columns; no leaked control stubs or raw data-prep tables on the canvas.
- **numbers_formatted** — `$`/`%`/compact suffixes, decimals and date formats match the source (`$473.0K` not `$473.0k`); data labels on where the source has them. A **wrong or mis-formatted number** FAILS.

## Functional dimensions (the visual diff alone misses these — check them explicitly)

- **controls / parameters** — every source parameter and quick-filter has a Sigma control of the **correct widget type** (dropdown→`list`, segmented→button, slider→number/range, date→date-range). An interactive source rebuilt as a static grid FAILS. Where the skill ships a flip test (`scripts/probe-controls.rb`), prove the wiring on EXIT (see `control-parity.md` where present).
- **accuracy (KPI / table values)** — the numbers **in the render** equal the numbers in the source render. This catches what CSV parity can't: a format-string error (`$473.0K` vs `$473.0k`), a wrong aggregate (`Count` vs `CountDistinct`), or a wrong period window (last-12-months vs calendar-YTD) that still "passes" a bucket-count diff. Read the big KPI numbers and a few table cells side-by-side against the source.

## Severity (blind-grade gaps)

A gap is **`major`** when the business user above would notice it and care (a wrong or missing
number, an unrecognisable or missing tile, a control that is gone, a layout they could not
navigate). It is **`minor`** when it is visible on a close look but they would shrug. The grade's
pass decision is computed by `record-visual-check.rb`, not by the grader: a high-enough
`overall_score`, `chart_shapes_match` and `numbers_formatted` passing, and no `major` fixable gap.
Graders do not compute or tune toward that bar. On a passing grade, every `minor` fixable gap is
a **polish note** (report section "Minor polish notes"), not a degradation: it never forces
YELLOW. On a divergent grade every fixable gap is a `fidelity-residual` and the run is YELLOW.

## Classifying each delta

| Class | Meaning | Effect on the gate |
|---|---|---|
| `fixable` / `spec-fixable` | closeable via a spec change (see the skill's fidelity recipes where present) | blocks while fix budget remains; a `major` one keeps the visual grade from passing |
| platform difference (catalog id) | matches a description in `sigma-platform-differences.json`; Sigma renders it this way and a build cannot change it | **recorded, never blocks**: not scored, not a waiver, never forfeits GREEN |
| `ui-only` | a real feature Sigma exposes only in the UI (KPI spark, tooltip beyond columnNames, trellis facet binding) | with a shipped catalog id: a recorded platform difference, never blocks. Without one: treated as `spec-fixable` (blocks while fix budget remains; a YELLOW residual once it is spent) |
| `sigma-capability` | Sigma has no equivalent (silently-dropped `useAsFilter`, pie percent-labels, map legend position) and the shipped catalog lists it | with a shipped catalog id: a recorded platform difference, never blocks. Without one: treated as `spec-fixable` (blocks while fix budget remains; a YELLOW residual once it is spent) |
| `data` | a value/parity gap owned by the parity phase, not composition | recorded → hand to parity; does not block |

## Exit criteria

A fidelity loop exits when **no unresolved `spec-fixable` deltas remain** or the pass budget is
spent; whatever is left is named in the report and the run finishes with those residuals listed.
Platform differences, `ui-only` and `data` entries flow verbatim to `coverage.json` and the
migration report under their own headings.
