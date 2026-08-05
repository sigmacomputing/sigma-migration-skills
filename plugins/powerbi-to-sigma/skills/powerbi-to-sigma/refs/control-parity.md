# Control parity — lint, flip test, and the MCP/export answer

SHARED ref, vendored byte-identical into every covered plugin's `refs/`
(md5 discipline). Companion to `scripts/lib/control_lint.rb` (gate 7 /
post-and-readback control lint) and `scripts/probe-controls.rb` (flip test).

## Why this exists

A migrated workbook can pass data parity, the column-type guard, and the
layout lint and still ship **broken interactivity**. The 2026-06 estate audit
of a live Sigma org found 86 controls across 36 kept workbooks: 8 DEAD (no
filter target, no formula reference — pure furniture), 18 PARTIAL (same-page
charts outside the control's reach; 8 of them bugs), and the Qlik class
(source dashboards full of listboxes migrated with zero controls). None of
the existing gates noticed, because every existing gate evaluates elements in
their default state.

## The three layers

1. **Control lint** (`scripts/lib/control_lint.rb`) — static spec analysis:
   dead controls, ghost filter targets, source-closure reach vs same-page
   queryable elements, source-signal coverage via the `control-scope.json`
   sidecar, and **conflicting cross-page control defaults** (the severe D11
   case below). Runs automatically in
   `post-and-readback.rb --type workbook` (exit 4) and as
   `assert-phase6-ran.rb` **gate 7** (exit 9, `--skip-control-lint` escape).
2. **control-scope.json contract** — emitted by the builder next to the
   workbook spec. Carries (a) `sourceFilterSignals`: how many filter-like
   signals the SOURCE artifact had (Tableau quick filters + actions, PBI
   slicers, Qlik listboxes, QuickSight/Cognos parameters+prompts, Looker
   dashboard filters, TS Liveboard filters) — `>0` with zero spec controls
   FAILS the lint; (b) per-control intent: `scope: "page"` (default — the
   control must reach every same-page queryable element) or
   `scope: ["Element name or id", ...]` (the **single-chart-switcher
   allowlist** for intentional narrow controls like grain/geo-level toggles)
   plus optional `mustReach` hard assertions. Full schema in the
   `control_lint.rb` header CONTRACT block. The in-spec `controlScope` key on
   a control element means the same thing but does NOT survive Sigma
   readback — the sidecar is the durable form.
3. **Flip test** (`scripts/probe-controls.rb`) — OPTIONAL Phase-6 runtime
   evidence, not the mandatory inner loop. Exports one in-closure element CSV
   with and without `parameters:{<controlId>: <first non-default value>}` —
   they must differ; with `--check-out-of-closure`, an out-of-closure element
   must NOT differ. Use it after hand-wiring controls, after estate repairs,
   or when the lint's static reach needs runtime confirmation.

## The MCP question — definitive answer (verified 2026-06-12, live Sigma org)

Tested by setting a saved default (`values: ["West"]`) on a live workbook's
Region list control (PHASEE, `64e78398`), then querying/exporting the same
in-closure bar chart every way available:

| Path | Control defaults applied? | Can set a control value? |
|---|---|---|
| `mcp__sigma-mcp-v2__query` (type=workbook) | **YES** — returned only the West row | **NO** — schema is `{type, workbookId, sql}` only; no parameter mechanism exists in the MCP query path |
| REST export, no `parameters` | **YES** — only the West row | n/a |
| REST `POST /v2/workbooks/{id}/export` with `"parameters": {"<controlId>": "<value>"}` | starts from defaults | **YES** — and the parameter **REPLACES** the saved default (parameters `{"ctl-region":"South"}` over a West default returned only South — no intersection) |

Consequences:

- MCP is fine for **default-state parity** (Phase 6 uses exactly that), and
  default-state MCP rows DO move if you change a control's saved default.
- MCP can NOT exercise a non-default control value — flip testing MUST go
  through the export API's `parameters` map. That is why probe-controls.rb is
  built on export.
- A parameter value that matches no data row returns an EMPTY (header-only)
  CSV, not an error — pick flip values from the column's actual domain
  (probe-controls.rb auto-picks from the control's value-source column).

## Repair recipes (what the lint tells you to do)

- **dead control, column exists on a master** → add
  `filters: [{source: {kind: "table", elementId: "<master>"}, columnId: "<col>"}]`
  (and point the control's own `source` at the same column for its value
  list).
- **dead control, column does NOT exist anywhere** → REMOVE the control.
  Honest beats decorative; do not fake-wire to an unrelated column.
- **partial reach, multi-master page** → add one filter target per master the
  control should govern (the column must exist on each); elements sourcing
  from those masters inherit via the closure.
- **partial reach, KPIs/charts unfiltered while the detail table filters**
  (each visual sourced its own narrow master; the control only targeted the
  table's master) → the fix is **one base table per page + control-targets-base**
  (build-workbook-from-pbir.rb `--source-mode page-base`, the DEFAULT): every
  visual on the page SOURCES the one page base master and each page control
  targets THAT base table's column, so the filter propagates to every visual
  through the source closure. Control filter targets a TABLE element (the base
  master) — the always-safe target. **Do NOT add a filter "passthrough" column
  to a chart or pivot to make it a direct control target**: the extra column
  corrupts the chart/pivot grouping and it renders "No data" (verified on live
  migrations). A passthrough column is tolerated only on a KPI (single-value,
  no grouping) or a plain grouped table; charts/pivots must be reached by
  PROPAGATION from a shared base table, never by a passthrough column. (This
  mirrors tableau-to-sigma / qlik-to-sigma, where every chart sources one
  master; the looker builder's listen-scope tables are the same idea.)
- **boolean / indicator slicer** → a boolean-typed slicer must NOT ship the
  string-slicer template (`controlType: list`, `mode: include`, `values: []`):
  Sigma treats an unset boolean `include` list as "include nothing" and ZEROES
  every targeted element. Seed the full boolean domain (`values: [true, false]`)
  so an unset control includes everything (= no filter), matching a PBI boolean
  slicer with nothing selected. The builder does this automatically for columns
  the TMSL model types as boolean/bit (else falls back to indicator-name shape:
  `Is…` / `Has…` / `…Ind` / `…Flag`).
- **intentional narrow control** (grain switcher driving one chart by
  formula) → annotate `scope: [...]` in control-scope.json; don't fake-wire.

After any repair: flip-test the workbook
(`ruby scripts/probe-controls.rb --workbook-id <id> --check-out-of-closure`).

## Severe D11 case: shared master + disjoint per-page control defaults = workbook-wide zero rows

The documented D11 multi-page control-bind defect is cross-page *leakage*
(flipping page A's control moves page B's numbers, because both bind the one
shared hidden master). Its severe special case is a full, silent **data
outage**: when two pages' controls default to non-empty, **disjoint** values on
the same logical column, Sigma **AND-composes** every control that filters a
shared source element — so the composed filter is `col IN [A] AND col IN [B]`
with `A ∩ B = ∅` → the master matches **zero rows** → every chart/KPI/table on
every page sourced from it reads EMPTY, with no error at build or POST.

Sigma composes by the shared master **element** in the source chain, not by
column identity, so duplicating the column under a second id (`m-website-type`
vs `m-website-type-overview`, both formula `[Custom SQL/Website Type]`) does
**not** dodge it. Control lint check (d) sees through that by grouping a target
table's columns by normalized formula.

Check (d) hard-fails this shape (blocks GREEN via gate 7). It fires only when
two controls on **different** pages target the **same** element+column-alias
with **non-empty, disjoint** defaults — the common default-all case
(`values: []`) never trips it. Two fixes, both of which the lint recommends:

- **Independent per-page masters** — give each audience/page its own
  independently-sourced master element (a distinct filter-target elementId per
  page), so the controls no longer compose against one source. (This is what
  the archived pre-regression version of the workbook that surfaced #485 did:
  `master-agent` / `master-leads` / `master-overview`.)
- **Overlapping (or default-all) defaults** — make the per-page defaults share a
  non-empty intersection, or leave them default-all, so the composed filter is
  satisfiable.

## Gotcha: list-control targets on NUMERIC columns are silently stripped
Same class as the datetime strip: a list control whose filter target column is
numeric returns PUT 200 but reads back `filters: null`. Fix: add a hidden
`Text()` cast column on the target element and point the control at the cast.
(Found live by gate 7 on the MicroStrategy retrofit, 2026-06-12.)

The general form — a list control's filter **TARGET binding** being silently
dropped despite a 200 (the `filters` key survives on readback but its
`columnId`/`source` are stripped, so the control filters nothing) — is
issue #456, a member of the `DROPPED_BY_API` family (distinct from #415/#417).
Because the `filters` key survives, a plain posted-vs-readback KEY diff can't
see it; the post-POST control-field census (where a converter wires one) also
compares the number of **bound** filter targets and flags any control that
binds zero targets on readback. The persisting shape is a TABLE-rooted target on
a STRING column; cast a numeric/datetime target with a hidden `Text([<col>])`
decode column and bind both the target and the value-source to it; an
unresolvable target is routed to the post-publish guide — never ship a control
that filters nothing. Contract row: sigma-workbooks
`reference/specification/controls.md` → "Dropped-by-API fields".

## Gotcha: a `[controlId]` formula reference is only "reach" if consumed type-compatibly
The lint counts a `[<controlId>]` reference in a calc/formula as control **reach**
— but reach ≠ resolves. A control's value is **typed** (`number`/`slider`→number,
`date-range`→a `{start,end}` variant, `list`/`segmented`→a set, `checkbox`/`switch`→
bool, `text`→text). Consuming it in a type-incompatible op (bare arithmetic on a
`date-range`/`list`, e.g. `[Range] + 1`) reads back clean but `#ERROR`s **at query
time** with `Expected number; received variant` — the same silent-until-query class
as the numeric-list-target strip above. Two failure shapes to avoid:
- referencing the element **`id`** instead of the **`controlId`** → `Unknown column`
  (never "reach"); and
- a type-mismatched `controlId` reference → counts as reach, renders, then `#ERROR`s.

Consume per type (`[Range].start`, `Text([Ctl])`, `[Col] = [ListCtl]`), don't strip
the control. Full syntax + typed-value table + worked examples:
`sigma-authoring/skills/sigma-workbooks/reference/specification/controls.md`
→ "Referencing a Control's Value in a Formula". (Verified live 2026-07-01.)
