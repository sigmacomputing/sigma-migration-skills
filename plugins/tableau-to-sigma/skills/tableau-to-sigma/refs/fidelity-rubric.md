# Fidelity rubric — the scored per-dimension checklist for the Phase 5g RCF loop

> Each RCF pass, `fidelity-loop.rb render` prints the dimension headers below and you Read the
> rendered `rcf-pass-N.png` against the source dashboard PNG, scoring EVERY dimension. For each
> gap you find, `record` it and **classify** it: `spec-fixable` | `ui-only` | `sigma-capability`
> | `data`. Only `spec-fixable` deltas block the gate — fix those via `refs/fidelity-recipes.md`,
> re-render, re-score. This EXTENDS `layout-visual-qa.md` (the source-fidelity → structural →
> design rubrics) with the scoring loop and the two **functional** dimensions a pure visual diff
> misses (controls, accuracy).
>
> Convergence, observed across the exemplars: pass 1 fixes **structure** (missing tiles, wrong
> kinds); passes 2–3 fix **composition** (containers, tints, text); pass 4+ fixes **typography /
> number-format** detail. ~30–90s/pass. Default budget 5 passes; stop early on zero spec-fixable.

## Visual dimensions (Read the render against the source; see `layout-visual-qa.md` for the full boxes)

- **layout / containers** — same element set, same arrangement/reading order, banded (not a flat stack); no overlaps, no dead zones; nothing dropped or invented.
- **typography / text** — header → section title → KPI value → label form a real scale; titles present and not clipped; alignment intentional (left for text, natural for numbers).
- **palette / theme** — series/slice colors match the source brand (via `themeOverrides.categoricalScheme`); canvas + band tints match; accent reserved, not sprayed.
- **chart kinds + marks — SHAPE IDENTITY (hard fail, not a style point)** — every viz must be **recognizably the same visualization** as the source zone: same chart family, same encoding (bars/dots/cells/table), same per-row/per-column structure. A ranked **bar-table** (label + per-category bar columns + printed values) rebuilt as one grouped bar chart FAILS. An annotated strip panel rebuilt as generic bars FAILS. A categorical axis flattened to numeric codes FAILS. **Correct data rendered as a different viz is a fidelity failure, not an approximation** — the owner sees a different dashboard (field-caught: a run whose every value matched was judged "furthest from desired" because tile identities were substituted; gate 9b now requires a per-tile `shape_match` attestation). Marks/labels/reference lines carried; log scale present (mind the export-linear ceiling).
- **labels / number formats** — `$`/`%`/compact suffixes, decimals, and date formats match the source exactly (`$473.0K` not `$473.0k`); data labels on where the source has them.

## Functional dimensions (the visual diff alone misses these — check them explicitly)

- **controls / parameters** — every source parameter and quick-filter has a Sigma control of the **correct widget type** (dropdown→`list`, segmented→button, slider→number/range, date→date-range). An interactive source rebuilt as a static grid FAILS. On EXIT, prove the wiring with the flip test: `ruby scripts/probe-controls.rb --workbook-id <wb> --check-out-of-closure` (in-closure element changes when the control flips; out-of-closure does not). See `refs/control-parity.md`.
- **accuracy (KPI / table values)** — the numbers **in the render** equal the numbers in the source render. This catches what CSV parity can't: a format-string error (`$473.0k` vs `$473.0K`), a wrong aggregate (`Count` vs `CountDistinct`), or a wrong period window (last-12-months vs calendar-YTD) that still "passes" a bucket-count diff. Read the big KPI numbers and a few table cells side-by-side against the source card values.

## Classifying each delta

| Class | Meaning | Effect on the gate |
|---|---|---|
| `spec-fixable` | closeable via a spec change in `fidelity-recipes.md` | **BLOCKS** until resolved (or `--accept-residuals`) |
| `ui-only` | a real feature Sigma exposes only in the UI (KPI spark, tooltip beyond columnNames, trellis facet binding) | recorded → report; does not block |
| `sigma-capability` | Sigma has no equivalent (silently-dropped `useAsFilter`, pie percent-labels, map legend position) | recorded → report; does not block |
| `data` | a value/parity gap owned by Phase 6, not composition | recorded → hand to Phase 6; does not block |

## Exit criteria

The loop exits when **zero unresolved `spec-fixable` deltas remain** (or the pass budget is
exhausted and remaining spec-fixable deltas are explicitly waived with `--accept-residuals
id,id` NAMED in the report). `ui-only` / `sigma-capability` / `data` residuals flow verbatim to
`coverage.json` and the migration report. `assert-phase6-ran.rb --require-fidelity-ledger`
enforces this on the final gate (exit 15 while a spec-fixable delta is unresolved).
