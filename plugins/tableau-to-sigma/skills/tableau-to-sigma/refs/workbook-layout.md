<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. REDIRECT STUB: this 68.7KB file was split by consumption phase (E9.3 phase-scoped refs, 2026-07-27). Nothing was deleted — every section moved verbatim to one of the four files below. Script comments and cross-plugin docs that name refs/workbook-layout.md resolve here and route on. -->

# Workbook Layout Reference — moved (split by phase)

This file was split into four phase-scoped refs so a phase loads only what it
consumes. Every section relocated **verbatim**; open the file for the phase
you are on:

| Old section (this file) | Now lives in | Read at |
|---|---|---|
| Reading the .twb dashboard layout; zone `kind` values; `chart_kind` values; Percent → Sigma 24-col grid; Tableau dashboard object → Sigma element | `refs/twb-zone-mapping.md` | Phase 1/1d |
| Grid system; Layout XML structure; Page/Element/Container; Ruby helpers (`gc()`/`le()`/`page_xml()`); Typical + canonical page layouts; Row sizing guide; Full spec assembly with layout; Common mistakes; Minimum tile heights | `refs/layout-grid.md` | Phase 5d |
| Multi-series chart patterns (small multiples/trellis, area, combo, scatter, refMarks, trendlines, axis format, dual-axis, tooltips, data labels); Map elements (region-map, point-map, geographic role → `regionType`, bar-chart fallback) | `refs/chart-patterns.md` | Phase 5 |
| Visual formatting properties NOT available via spec API; Element kinds supported; Element-type field requirements (KPI, column format, pivot table, table extras, pie/donut, text, image, divider, button, container, histogram); Control elements (filter targets + all control types, element-level top-n) | `refs/element-kinds.md` | Phase 5 |

> **Spec shape lives in `sigma-workbooks`.** The split files are
> Tableau-conversion-specific; for canonical workbook spec shape (element
> kinds, sources, controls, formulas, formatting) defer to the
> `sigma-workbooks` skill's `reference/specification/` — when a split file
> disagrees, that reference wins. Layout is always generated with Ruby —
> never hand-write layout XML (`refs/layout-grid.md`).
