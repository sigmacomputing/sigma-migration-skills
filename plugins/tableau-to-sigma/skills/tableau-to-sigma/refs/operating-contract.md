# Migration Operating Contract — read before you touch anything

> A tool- and model-agnostic set of guardrails for any agent running a BI→Sigma
> migration. The failure it prevents: an agent runs for an hour and ships a
> structurally-clean but visually-empty, numerically-wrong workbook, then reports
> "done, 0 errors." Fidelity is not optional and it is not eyeballed — it is gated.

## Ground truth
- **The source dashboard is the spec.** Before building, obtain (a) its **rendered
  image** — Tableau REST `Query View Image` with the PAT works with no MCP — and
  (b) its **calc definitions + filters** from the source file (`.twb` etc.). You are
  matching *that*, not your idea of it.

## Build from the source's own logic
- **KPIs are usually parameter/ratio/LOD-driven, not `SUM(column)`.** Read each
  field's calc. If the model already materialized the source's validated calc as a
  column (e.g. a `…(copy)…` field), `SUM` *that* — it already encodes the per-row
  logic. Use the source's exact aggregate (`Count` vs `CountDistinct` matters).
- **Map source parameters → Sigma controls; wire `filters` to the base tables.**
  Apply the source's dashboard/period filters so aggregates run over the same
  **population** — otherwise ratios/averages drift even when formulas are "right."
- **Rebuild every source viz** (donuts, trends, matrices). If a viz has no standalone
  data export, reconstruct it from the model. **Never silently drop a tile.**

## Verify — don't assume (this is what keeps you on the rails)
- After every write, GET the spec back. A rejected PUT is **atomic** — read the 400.
- **Render EVERY page** to PNG and compare side-by-side to the source image. A page
  that is >40% empty, missing tiles, or visually unlike the source is a **FAIL** — fix it.
- **Value-check**: for each KPI/table, compare the **number** to the source's number.
  "It compiles" is not "it matches." Record the comparison.
- Verify the model's existing filter state (`GET /columns`, read element `filters`)
  before assuming anything is or isn't applied.

## Don't spin, don't fake
- **"Can't verify" ≠ "passed."** If a gate can't pass, STOP and report the specific
  blocker. Do not waive it silently or loop to force green.
- Escape hatches (skip/allow flags) require a **named reason that goes in the report**.
- If you've retried the same failing step ~2×, change approach or surface it — never grind.

## Structural edits to source semantics require a recorded proof (PR-8)
- **Dropping a join, collapsing a table, or rewriting a filter is FORBIDDEN without a
  recorded equivalence proof — BEFORE the edit ships.** A field agent deleted a LEFT
  JOIN as "provably no-op" on fraud data with zero verification; the key was a
  non-unique flag column, so the join was fanning out rows and the "no-op" changed
  every count downstream. "Provably no-op" is proven by `scripts/probe-equivalence.rb`
  — COUNT(\*), COUNT(DISTINCT grain) and per-measure SUM checksums measured on BOTH
  sides through the warehouse — **never asserted**. The proof lives in
  `<workdir>/semantic-edits.json`; an edit with no proof entry is UNPROVEN and the
  final gate (gate 20, exit 27) refuses GREEN for it, exactly as for a proof that
  came back `match:false`.
- **A mismatch means the edit does not ship.** Revert it (removing the edit removes
  the entry) or redesign it until the probes agree. There is no waive path:
  equivalence is measured, not negotiated. An intentionally-different rewrite is not
  an equivalence claim — that is a user-initiated scope change and belongs in the
  migration report's scope record, never in this ledger.
- **Declare every structural edit — the gate can only police what you declare.** No
  mechanism can detect an edit nobody recorded; the declaration is this contract's
  requirement, not the gate's discovery. The mechanical net for an UNDECLARED edit is
  the join-cardinality ledger (gate 16 — the candidate join is on record before any
  edit) and the ground-truth oracle (gate 18 — ground-truth SQL derives from the
  SOURCE signals independently of the built spec, so a silently dropped join shifts
  the built numbers away from the derived truth and diverges). Relying on that net
  instead of declaring is itself a contract violation.

## Never negotiate fidelity down (field-caught, v5.5 e2e)
- **This is a PRODUCTION migration, not a demo — regardless of who is watching
  or why.** The bar is EXACT parity against the same warehouse, always. At a
  wall you have exactly two moves: **follow the STOP/handoff the orchestrator
  printed**, or **surface the blocker plainly and stop**. NEVER a third path:
  no "lighter"/"simplified"/"good-enough-for-the-demo" builds, no dropping
  tiles/filters/calcs to look finished. Cutting fidelity to escape a struggle
  is a **worse failure than stopping**. If a lighter scope is wanted, the
  **user** decides that explicitly — you never volunteer it.
  *(Relocated verbatim from SKILL.md STEP 1 — E9 diet.)*
- **NEVER propose reducing scope as a response to difficulty.** "Something lighter for
  the demo", "a simplified version", "skip the hard tiles for now" are all the same
  move: converting YOUR struggle into THE USER'S loss, silently. The mission is exact
  parity; a struggling step does not renegotiate the mission.
- The only permitted moves when stuck: **(1) fix it; (2) a NAMED stop/handoff** (the
  exit codes exist for this — exit 4 is a work item with two forward paths, exit 16 is
  a build-it checklist; follow their printed instructions); **(3) ask the user with the
  full-fidelity path stated FIRST** and the cost of each option made explicit.
- Descoping happens only when the USER initiates it, and what was descoped is recorded
  in the final report — never proposed by you as an escape.
- A designed STOP (exit 4/10/11/12/16/17) is the skill working, not failing. Read its
  printed instructions and DO them; giving up at a designed stop is abandoning a
  migration that is mid-flight and healthy.

## "No data" and product-limitation discipline (field-proven; 2026-07)
- **A chart that renders "No data" is YOUR build being broken until proven otherwise.**
  Never conclude it is a platform/render artifact. **PRODUCT FACT:** Sigma's export
  endpoints (CSV *and* PNG) execute the live warehouse query — a CSV that returns rows
  proves the query runs, so a blank PNG over that element means the chart's own query
  returns **zero rows**. "The export doesn't run queries" is false and is the exact
  rationalization that shipped a dataless dashboard GREEN.
- **The two real causes** (fix these, never wave them): a **control/filter literal that
  matches no rows** (e.g. control value `"Region A & B"` vs a calc emitting
  `"Region A and B"`), and a **calc comparing a NUMBER column to a string
  literal** (`If([Year] = "2014", …)` compiles clean, renders NULL; a date-part filter as
  a string list `["2015"]` against a `TIMESTAMP` never matches). `verify-anchors.rb`
  reports empty displayed tiles (`dashboard_tiles_empty`); the gate refuses GREEN.
- **Confirm a fix by looking at the RENDER, not the DM.** A correct DM formula is
  necessary, not sufficient — re-render or re-run `verify-anchors.rb` and confirm the
  tile shows data (`tiles_all_nonempty`).
- **Never conclude a product limitation without a probe.** Before recording any
  `sigma-capability` residual, prove it: run the same operation two ways (e.g. table
  export vs chart render) and attach the evidence. `fidelity-loop.rb` refuses a
  "no data / empty" delta classed as `sigma-capability`/`ui-only` without a `--probe`.
- **The measurement is the anchors, not the actuals.** Never edit `source-anchors.json`
  to match what the live workbook returns — that reconciles the ruler to the thing it
  measures. A genuine re-transcription (you re-read the SOURCE image) uses
  `--retranscribed "<why>"`, which logs the diff into the report. `verify-anchors.rb`
  locks the file hash and refuses a silent edit.
- **Extract drift is handled by `--extract-tol`, NEVER by editing anchors.** On an
  extract-based workbook (`hasExtracts=true` / landed extracts) the source PNG shows
  extract-stale values while the landed warehouse is fresher, so a printed-precision
  anchor miss can be legitimate drift — the sanctioned response is
  `verify-anchors.rb --extract-tol <F>` (e.g. `0.02` = ±2% relative). The tolerance
  only activates when the workdir's own artifacts mark extracts, every
  tolerance-admitted match is recorded per anchor (`tolerance_used` + `drift`) and
  surfaced by the gates, and it MUST be named in the migration report. Rewriting
  `source-anchors.json` to the live actuals remains tampering on every source type.

## Credential hygiene
- **NEVER echo credential values (tokens, secrets, PATs) into output, commands, or
  files — reference env var names only. When displaying config, mask all but the
  last 4 characters.** `scripts/lib/redact.rb` (`Redact.mask` / `Redact.scrub`) is
  the one sanctioned masking path — a secret pasted into a log, a command line, or
  a report file is a leak even when the run itself is healthy.

## Tooling discipline (don't burn the clock)
- **Run `--help` before any flag you have not used this session.** Inventing a flag
  (`--force-new-workbook`, `--dm-spec`, `--workdir` on the wrong script) costs a
  round-trip each; the scripts print usage on an unknown flag.
- **Stay on the orchestrated path.** Hand-editing generated specs and driving raw
  POST/PUTs is where runs fall off the rails (the orchestrator regenerates specs and
  overwrites hand fixes; a raw DM PUT can re-mint element ids and brick a live
  workbook). If a STOP asks for one fix, do that one thing and re-run the same command.
- **Long single-context runs drift.** If the handoff nudge fires (60/90/120m), write
  `HANDOFF.md` and hand off — resume is cheap. A run pushed to GREEN deep in one
  compaction-looped context is how a false GREEN happens.

## Done means
- 0 error columns; every page rendered and visually matching the source; every KPI's
  number matching the source (or the delta explained); controls present and wired; no
  silently dropped tiles. Anything short of that is **reported, not hidden.**
