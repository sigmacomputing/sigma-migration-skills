<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Orchestration-as-code — builder/verifier split + fresh-context discipline -->

# Orchestration-as-code — builder/verifier split, fresh contexts, context budgets

These are **REQUIREMENTS, not suggestions.** The same skill version, on the same
environment, produced a 10/10-GREEN batch in one run and shipped broken
workbooks in two others — and the difference was not the scripts, it was the
*orchestration shape*. The GREEN run used one fresh builder agent per workbook
plus independent verification. Both failed runs drove everything in ONE
marathon context for hours: quality collapsed late-session, the agent visibly
compaction-looped (re-deriving flags and file contents it had already used two
hours earlier), and the builder graded its own homework — recording `pass` on
visual checks a fresh pair of eyes would have failed. This ref turns that
lesson into rules.

The two prompt files that implement the pattern are self-contained and
agent-neutral:

- **`scripts/builder-brief.md`** — the per-workbook conversion agent's brief.
- **`scripts/verifier-brief.md`** — the independent verification agent's brief.

## O1. ONE workbook per builder context (MUST)

A builder agent converts exactly **one** workbook, start to finish. A
multi-workbook migration is **one builder agent per workbook, each spawned
fresh** — never one context that converts workbook 2 with workbook 1's history
still in its window. `tableau-assessment/scripts/orchestrate-batch.rb` emits
one builder brief per workbook for exactly this reason; do not "save time" by
feeding several briefs to one agent sequentially.

Why: the GREEN batch ran one fresh agent per workbook. Both field failures ran
everything in one context; by the third hour the agent was re-reading files it
had already summarized and re-deriving decisions it had already made
(compaction loops), and late-session output quality was measurably worse than
the first workbook's.

## O2. Context budget + handoff (MUST)

A builder that hits **either** of these signals MUST hand off instead of
grinding:

- **~90 minutes** of wall-clock work in one context, or
- **compaction signs**: it catches itself re-reading files it already knew,
  re-deriving flags/ids it already resolved, or losing track of which phase
  it is in.

Handoff protocol (the machinery already exists — resume is cheap):

1. **Run-state is already on disk.** The orchestrator maintains
   `<workdir>/migrate-state.json` (pass-2 resume point), a discovery
   fingerprint (`<workdir>/discovery-stamp.json` — lets a re-run reuse
   discovery artifacts instead of re-fetching), and `run-state.json` (the
   phase-chain ledger). Do not delete or hand-edit these.
2. **Write `<workdir>/HANDOFF.md`** summarizing, in this order:
   - the exact next command to run (usually the same `migrate-tableau.rb`
     invocation — it resumes from state and skips completed phases);
   - open items (unfixed RCF deltas, pending parity actuals, unanswered
     OPEN QUESTIONS, waivers granted so far with their evidence);
   - anything learned that is NOT in an artifact (e.g. "the `Region` control
     needs a Text() filter key — third retry pending").
3. The **driving session spawns a FRESH builder agent** (same brief,
   same parameters) whose first instruction is: read `<workdir>/HANDOFF.md`,
   then resume. Discovery reuse + phase skips make the restart cost minutes,
   not hours.

**Never grind past fatigue signs.** A handoff costs ~5 minutes; a
compaction-looping agent shipping a broken workbook costs a customer escalation.

**The orchestrator now measures the 90-minute budget for you.**
`migrate-tableau.rb` computes total elapsed time from the run-state ledger's
FIRST phase stamp (stamps merge by phase key, so the pass-1 start survives
resumes and `--finalize`) and, once it crosses 90 minutes, prints a one-time
`⏰⏰⏰ HANDOFF NUDGE` line at the next phase header. Treat that line as this
section firing: finish the current phase, write `<workdir>/HANDOFF.md` (step 2
above), and hand off to a fresh builder. The nudge is advisory — it never
blocks a phase — but ignoring it is exactly how the 6-hour single-context
field failure happened (zero subagents in 6 hours; by hour 3 the agent was
grepping its own transcript to recover commands it had already run).

## O3. Builder/verifier split (MUST for Tier-M+ and `--certified` — a bare GREEN requires the countersignature; Tier-S factory runs ship the LABELED verdict instead, see the carve-out below)

**The builder NEVER records the final visual verdict on its own work.** A
builder that has spent an hour making the render match has every incentive —
and demonstrated tendency — to see what it expects. Both field failures
self-recorded `pass` verdicts on dashboards a fresh reviewer flagged
immediately.

The rules:

- The builder runs the full gated spine including the Phase 5g RCF loop and
  Phase 6 parity. It may record `--verdict divergent` freely while iterating.
  It MUST NOT run `record-visual-check.rb --verdict pass` on the final render.
- When the builder believes the render matches, its terminal state is
  **gate 8b left unrecorded**. For its own exit report it runs the self-check
  gate with exactly two split-granted waivers:

  ```bash
  ruby scripts/assert-phase6-ran.rb --tableau <workdir> --workbook-id <wb> \
    --require-fidelity-ledger \
    --skip-visual-comparison "builder/verifier split: final visual verdict reserved for the verifier"
  ```

  Exit 0 there means "everything except the countersignature is green."
  (Running `migrate-tableau.rb --finalize` instead will stop at gate 8b,
  exit 13, and print instructions to record `--verdict pass` — under this
  split, **ignore that instruction**; it is for solo self-attested runs.)
  Note the gate's waiver budget: these two split-granted waivers consume it,
  so any additional waiver caps the run at YELLOW (exit 19) — fix problems
  rather than waiving them.
- A **SEPARATE verifier agent** — fresh context, zero builder history, given
  ONLY the workdir + Sigma workbook id — executes
  `scripts/verifier-brief.md`. It re-runs the gate with no new waivers,
  re-runs the anchor and similarity checks, and reads the source PNG vs the
  final render itself.
- **GREEN requires the verifier's countersignature.** The verifier — and only
  the verifier — records the final pass verdict, backed by a context-free
  blind grade (PR-9: the verifier first spawns a fresh grader subagent per
  `refs/blind-grader-brief.md`, which writes `<workdir>/blind-grade.json`):

  ```bash
  # v2 grade: no --verdict/--checklist (computed from the grade). Legacy v1 grade: add --verdict pass --checklist "<six dimensions>".
  ruby scripts/record-visual-check.rb --workdir <workdir> --agent-vision true \
    --blind-grade <workdir>/blind-grade.json \
    --notes "VERIFIER: <what was compared and matched>"
  ```

  **Convention (load-bearing): the verdict notes MUST start with `VERIFIER:`.**
  That prefix is how any later reader (or gate) can tell a countersigned
  verdict from a builder self-attestation. If your `record-visual-check.rb`
  supports a `--verifier` flag (`--help` lists it — the gate workstream is
  adding one), pass it as well; the `VERIFIER:` notes prefix stays required
  either way.
- A verdict of `pass` whose notes lack the `VERIFIER:` prefix is a builder
  self-attestation, **not** a countersignature. On Tier-M+ or any
  `--certified` run that means at best self-attested YELLOW, never GREEN.
- **Tier-S factory carve-out (wave 2, W2.3 — the ratified factory default).**
  On a Tier-S factory run (`migrate-state.json` `tier: "S"`, written by the
  orchestrator's tier ratchet) the verifier context is **optional**: it is
  spawned only for `--certified`, Tier-M+, or an explicit operator ask. A
  self-attested Tier-S GREEN is real and shippable, but it is **labeled, not
  bare**: the gate stamps `verdict_by: "builder-self-attested"`
  (`parity-final.json` + `phase6-success.json`; closed vocabulary
  `Offramp::VERDICT_BY`) and the verdict string everywhere — RESULT line,
  markers, report headline — is **`GREEN (factory, self-attested)`**, never
  the bare string `GREEN`. The label is greppable and `verify-complete.rb`
  fails (exit 6) any report that strips it. A verifier countersignature +
  gate re-run upgrades the workdir to a bare countersigned GREEN — which
  remains the only GREEN a `--certified` run may claim.

Result artifacts (who writes what):

| Artifact | Author | Meaning |
|---|---|---|
| `<workdir>/MIGRATION_REPORT.md` + `<workdir>/migration-result.json` | builder | self-assessed outcome, `status: "awaiting-verification"`, every waiver named WITH evidence |
| `<workdir>/verification-result.json` + the countersigned verdict in `parity-final.json` | verifier | the FINAL verdict (GREEN / YELLOW / RED) |
| batch result line with `verdict_by: "verifier"` (batch runs) | verifier | the workbook's batch verdict — the builder's line is self-assessed only |
| `verdict_by: "builder-self-attested"` + labeled `GREEN (factory, self-attested)` in `parity-final.json` / `phase6-success.json` | final gate (Tier-S factory) | the W2.3 self-attested factory verdict — real, labeled, greppable; countersigning + a gate re-run flips it to a bare GREEN |

## O4. Single-workbook flows: same split (with the same Tier-S carve-out)

This is not a batch-only rule. In a one-workbook **Tier-M+ or `--certified`**
conversion the builder (the current session or a spawned agent) finishes pass
1 + the fidelity loop, stops short of the pass verdict, and then **the human
or the driving session spawns the verifier** with `scripts/verifier-brief.md`.
A solo session that self-records `pass` produces a self-attested result —
on a **Tier-S factory run** that is the sanctioned default and the result is
the labeled `GREEN (factory, self-attested)` (quote the label verbatim in the
report — `verify-complete.rb` fails a bare-GREEN claim); on Tier-M+ it is
acceptable only when the user explicitly accepts it, it is not a countersigned
GREEN, and the report must say so.

## O5. How to spawn (agent-neutral)

The briefs are self-contained prompt files — any mechanism that starts a fresh
agent context works:

- **Claude Code**: the Agent tool (`subagent_type: 'general-purpose'`), one
  call per builder/verifier, brief as the prompt.
- **Cortex Code / Cursor / other agents**: their subagent or task equivalents.
- **No subagent support**: a second interactive session (new window, fresh
  context) given the brief verbatim.

Non-negotiables regardless of mechanism: the verifier gets a **fresh context**
(no builder transcript), and each builder gets **one workbook**. The driving
session's job is orchestration only — spawn, collect results, spawn verifiers —
not conversion work of its own.

---

## Converter backend + manual-spec fallback (relocated from SKILL.md — PR-15 diet)

> **Converter backend — LOCAL by default, zero config, never upload customer data silently.**
> The mechanical path needs the Tableau→Sigma converter, which is **not a server** — it's a
> pure function (`.twb` XML → Sigma JSON) run via `node`; nothing leaves the machine. A
> **prebuilt converter ships inside the skill** at `converter/tableau.mjs` and is auto-discovered
> as the guaranteed fallback, so the local path works with **no clone, no `npm install`, no
> network** (only `node` on PATH). A developer's own build still wins when present — set
> `TABLEAU_MCP_BUILD` to a `build/tableau.js`, `SIGMA_DATA_MODEL_MCP` to a checkout, or run
> `scripts/dev/fetch-converter.sh`. Refresh the vendored copy after the converter changes with
> `scripts/dev/vendor-converter.sh` (pinned source in `converter/PROVENANCE.json`). The
> **hosted** converter (`https://the hosted-converter endpoint (SIGMA_MCP_CONVERTER_URL)/mcp`) uploads the `.twb` to
> a third-party server and is used **only** with explicit `--converter hosted` (which overrides
> local auto-discovery) or `SIGMA_CONVERTER_ALLOW_HOSTED=1` — never on its own. See QUICKSTART
> "the data-model converter backend".
>
> **No converter available? Re-enter the GATED spine — do NOT hand-drive raw POSTs.**
> When no backend is configured, the fallback is *not* "build everything by hand and POST
> it yourself" (that skips preflight/control lint, Phase-6 parity, and the
> `assert-phase6-ran` hard gate — the exact way a workbook ships with missing controls and
> an unverified parity claim). Instead author the specs *once* and let the scripts run them:
> 1. Get the **DM spec** — normally the vendored local converter (`converter/tableau.mjs`)
>    produces this automatically; reach here only if even that can't run. In that case call
>    the hosted `sigma-data-model` MCP's `convert_tableau_to_sigma` on the `.twb` if it's
>    available to you, else author it by hand (see `sigma-data-models`).
> 2. Author the **workbook spec** (see the companion `sigma-workbooks` skill). Reference the
>    data model with placeholders the orchestrator binds to the live readback ids:
>    `"__DM_ID__"` (top-level `dataModelId`) and `"__DM_ELEMENT__:<ElementName>"` per element
>    (the fact element is `"__DM_ELEMENT__:__FACT__"`). An unresolved element ref aborts loudly.
> 3. Write `dm-spec.json` + `wb-spec.json` into the workdir and re-run the orchestrator with
>    `--dm-spec <path> --wb-spec <path>` (fresh build) — or, when the DM is **already posted**
>    (exit 4 workbook-layer handoff), `--reuse-dm <dataModelId> --wb-spec <path>`. Either way
>    the spec runs through validate → post-and-readback (preflight/control lint + column guard)
>    → layout → parity, and stops at exit 12 to collect actuals + `--finalize`. **A conversion
>    is not done until `assert-phase6-ran.rb` exits 0**, on this path too.

## Single-invocation flow (wave 1 — how the stops compose now)

Windows uses separate invocations at the exit-12 finalize checkpoint and the
exit-4 workbook-repair handoff. It does not attempt POSIX lock-descriptor
inheritance for automatic finalize or reuse self-healing. Resume only after
the previous process exits; the same workdir lock still excludes other writers.

The gates are unchanged; the STOPS batch (speed review #2). One driving
pattern per run:

1. Launch pass 1 in the background (`--quiet` keeps the poll payload small —
   refs/performance.md). Phase 1 is interleaved: the Tableau-side and
   Sigma-side lanes join before anything consumes discovery output.
2. **ONE pre-build checkpoint** consolidates gap review (exit 11), decisions
   (exit 10), and the WARN-only cost advisory into a single
   stop + a single artifact (`<WORK>/open-questions.json`) + a single re-entry
   (`--answers '<json>' [--force]` or `--yes`). Tagged entries embed their
   computed `targeted_key` — copy it verbatim into `--answers` (targeted wins
   over the bulk class id; unknown keys draw a WARN). Resolved answers are
   ledgered in `<WORK>/decisions.jsonl`.
3. **Phase-1d dashboard-read is a handoff at the DM-POST barrier**: default
   `SIGMA_PNG_READ_TIMEOUT_S=0` returns exit 18 naming the missing piece, so a
   blocking agent can read the PNG and resume. Runners that can act concurrently
   may set a positive bound (for example 480 seconds) to continue in-process
   when the read arrives. Neither mode skips verification.
   A `png-read.json` older than this run's discovery fetch is
   set aside as `.stale` — never silently consumed.
4. At the pass-1 tail, when the artifacts prove the agent-mediated actuals
   list is EMPTY (all exportable charts machine-collected, pivot grids included,
   no markers, no per-tile visual sidecar) AND the agent-side gate obligations
   are already discharged (visual verdict recorded on `parity-final.json` —
   gate 8b, waived by `--fast`; staged RCF ledger resolved — gate 8d),
   `--finalize` chains **in the same invocation**; otherwise exit 12 is
   unchanged. Cold runs never chain — the verdict only exists on re-entry
   workdirs, so a cold chain would predictably stop at gate 8b and pre-spend
   a finalize loop-log attempt. `SIGMA_NO_CHAIN_FINALIZE=1` opts out.
5. **E9.6 — mission scope threads end-to-end**: a `mission.json` STATED scope
   (`scope.dashboards`, or a single-view `/#/views/<wb>/<view>` URL in
   `scope.value`) maps onto `--dashboard` and constrains the parse, the calc
   working set, the open-questions surface, the ❌-gap STOP surface, and
   build planning. The gap SCAN itself stays workbook-wide (expectations are
   set for the whole file); at the checkpoint, an ❌ gap attributed entirely
   to out-of-scope worksheets is ledgered (`gap-out-of-scope` off-ramp note)
   instead of stopping, while unattributable gaps FAIL OPEN and still stop.
   Explicit `--dashboard` flags override (narrowing below the mission is
   recorded in `decisions.jsonl`); a scoped name matching nothing is a named
   STOP (exit 19) listing the workbook's dashboards; unscoped missions are
   unchanged.

## Re-entry with `--reuse-workbook` keeps the live layout

`--reuse-dm <id> --wb-spec <path> --reuse-workbook <id>` now GETs the live workbook
layout and, by default, **preserves** it (carried into the PUT, then re-applied by
`put-layout.rb` as the last write) so RCF layout fixes survive an iteration. An edit
that adds or removes elements is a **merge** onto the live layout
(`scripts/lib/layout_merge.rb`), never a regeneration: every live placement is kept,
ids the new spec dropped are pruned, and each NEW element is placed where the new
spec's own layout puts it (when that parent page/container exists live), else after
the last element of the same kind in the page's rail container (controls, text,
buttons), else full-width below the page content — overlapping siblings are pushed
down and an outgrown container grows. Each placement is printed and recorded under
`placed` / `pruned` in `<workdir>/layout-reuse-decision.json`. The layout is
regenerated from the Tableau zones only on `--regenerate-layout`, a blank live
layout, or a full rebuild that keeps under 30% of the live element ids.

## FIXED LOD used as a dimension

A `{FIXED [k] : AGG(f)}` calc (one dimension, one MIN/MAX/SUM/AVG/COUNT/COUNTD
over a field or its YEAR/QUARTER/MONTH/DAY) that a tile uses as a row/column
dimension is built mechanically after the per-page master split
(`scripts/lib/lod_dim_helper.rb`; offline / re-entry form:
`scripts/apply-lod-dim-helpers.rb --workdir <WORK> --spec wb-spec.json`): a
grouped helper on the Data page right after its master, reading the master's
data-model element UNFILTERED (Tableau computes FIXED before dimension filters,
so the page's controls deliberately do not reach it), and the tile column
rewritten to `Lookup([<Cap> Helper/<Cap>], [Master/<k>], [<Cap> Helper/<k>])`,
so the tile stays on its control-filtered master. No exit-4 handoff. Any
element the layout leaves unplaced keeps its document position; a helper
another element reads as its source is placed on the Data page.

## Dimension members with no fact rows

Tableau's relationship model keeps a dimension member with no fact rows (a
store with 0 orders still lists, revenue blank, orders 0); the fact-rooted
master drops it. After the FIXED-LOD pass, `scripts/lib/dim_preserve.rb`
(offline / re-entry form: `scripts/apply-dim-preserve.rb --workdir <WORK> --spec
wb-spec.json`) re-bases a tile on `<master>-keep-<table>` — the related
dimension's data-model element LEFT-OUTER joined to the fact view on the DM
relationship keys, placed right after the master — ONLY when every dimension in
the tile's view CSV comes from that one related table AND the CSV shows a member
whose every measure is blank or 0. DM metrics are inlined on the re-based tile
(metrics do not exist on a join); controls that filter the master also filter
the clone. A fact-table dimension, or a tile with no CSV, is never re-based.

Tableau's RANK skips nulls; Sigma's `Rank` ranks NULL first when descending
(no null option), so such a member took rank 1 and shifted every other rank.
After that pass `scripts/lib/null_rank.rb` rewrites every
`Rank/RankDense/RankPercentile(E, dir)` to `If(IsNull(E), Null, Fn(<E>,
"asc"))`, ranking `-(E)` for a descending rank: a NULL measure gets a NULL rank
and consumes no position (displayed ranks, Top-N rank helpers, table calcs). A
descending rank over an operand that is not provably numeric is left as is.

## Source drift between the Tableau capture and parity

If the warehouse loads between the Phase 1 view-CSV capture and the Phase 6
Sigma query, parity fails on a correct migration. Values stay STRICT; the
handling (`scripts/lib/source_drift.rb`) only ever explains or re-captures:

1. **Prevent:** Phase 1 captures view CSVs with `maxAge=1` (bypasses
   Tableau's view-data cache, which can serve an answer older than the
   warehouse).
2. **Diagnose:** when finalize parity fails, `source-drift.json` labels the
   failure `suspected-source-drift` if every diverged tile has the same keys on
   both sides and a small tile-level delta (total |change| / total |expected|
   <= 5%: a load lands in the newest rows, so the tile total moves by the loaded
   fraction even when one month moves a lot). The run stays NOT GREEN.
3. **Prove + recover:** `ruby scripts/recapture-source-views.rb --workdir <WORK>`
   re-exports the diverged views fresh and byte-compares them with the capture.
   A CHANGED CSV (evidence from the source itself) replaces the capture (old one
   archived under `views/captures/<ts>/`) and the exact re-plan / re-collect /
   finalize commands print — parity then re-runs strictly against it. An
   UNCHANGED CSV means the divergence is real; nothing is swapped. Phase 1d
   anchors transcribed from a moved view are listed as stale.

Ground truth cannot arbitrate this on a virtual connection (measures there are
anchor-only), which is why the proof comes from the source re-export.

## RCF repairs and a pass-1 re-run

`fidelity-loop.rb apply-patch` records every applied patch under
`<WORK>/rcf-patches/`. A pass-1 re-run rebuilds the spec and PUTs it in place,
reverting those repairs; the orchestrator then REOPENS the resolved
spec-fixable ledger entries (the 8d gate blocks) and prints the exact re-apply
commands. Re-applying a recorded patch is allowed past an exhausted render
budget (it is not a new repair).

## Seeded valued anchors (Tableau)

When Phase 1d is accepted, and again in the finalize preflight,
`scripts/seed-source-anchors.rb` gives every tile that has a view CSV but no
valued anchor one `view-csv` anchor (`derived_by: seed-source-anchors`, from its
first complete measure row), so gate 18 never needs a hand-added anchor; tiles
with no CSV are listed for a person to transcribe (refs/source-anchors.md).
Before the anchors lock exists it also rewrites a bare, over-precise `view-csv`
value (`0.641016176`) at the tile's DISPLAYED precision (`64.1%`); after the
lock, values are never changed (adding is not tampering; a change needs
`verify-anchors --retranscribed`).

A `coverage_waivers` entry is for a tile no anchor or oracle CAN cover (no view
CSV). Before the final gate, a waiver on a tile that has a view CSV, a valued
anchor matched in it (anchors-verdict.json) and a strict parity pass — or, for a
ground-truth-plan.json waiver, a `numeric_parity` match — is moved to
`coverage_notes` (`scripts/lib/coverage_retire.rb`): it excuses nothing, so it is
not a `resolution-waived` degradation and does not forfeit GREEN. A waiver short
of that keeps degrading.

## Warehouse db/schema for virtual connections

A virtual-connection workbook has no `<connection dbname=/schema=>`; its relations
read `table='[<vc-table-uuid>].[FACT_A (DB_A.FACT_A)]'` and its export
headers `State (DIM_B (DB_A.DIM_B))`. The UUID is the VC's table id, never a
schema, and the 2-part qualifier names the database **or** the schema (the VC drops
a level). The orchestrator lists the Sigma connection catalog (read-only
`GET /v2/connections/paths`) and accepts the one `database.schema` that holds
**every** VC table; a lone `--db` or `--schema` narrows the match. Two or more
holders, none, or a truncated catalog listing hard-stop with the exact
`--db … --schema …` line.

## `--finalize` preflight

`--finalize` first computes ONE prerequisite list (anchors verdict, join probe, LOD
audit, ground-truth derive/run/verify, parity plan), auto-runs what the workdir
allows, and otherwise stops with exit 29 and an ordered list of exact commands.
That stop is not a NOT-GREEN finalize: it never writes `loop-log.jsonl`.
Parity actuals older than `wb-spec.json` or `parity-plan.json` (an RCF patch
or apply-patch changed the workbook after collection) are re-collected
(`collect-parity-actuals.rb`) before any gate runs, so a finalize never spends
an attempt comparing the previous workbook.

Two pass-1 parity-plan and render stops are gone: a Tableau view-CSV column for
a field that sits ONLY on the worksheet's tooltip (no plotted channel or shelf;
`scripts/lib/tooltip_fields.rb`) is skipped with a recorded `skipped_columns`
reason instead of aborting "column identity is unresolved" (Sigma tooltips are
UI-only); the source dashboard PNG resolves `dashboards/<page name>.png` or
discovery's underscore form (`scripts/lib/source_png.rb`), so the RCF source
composite is written without copying files.
The RCF render viewport uses the source PNG's LOGICAL size: a capture whose
width is ~2x a dashboard's `canvas_px` width (discovery's `resolution=high`) is
halved, so the first pass renders at the dashboard's own size.

A `vds`-classified ground-truth tile whose source is NOT a published datasource
is verified by valued `view-csv` anchors matched in the tile instead, on positive
evidence only: every vds-oracle check is `skipped-embedded-ds` (a landed
embedded/federated extract), or `skipped-no-luid` AND the .twb datasource has no
`sqlproxy` connection and pds.json does not name it (`scripts/lib/ds_publication.rb`;
an embedded datasource over a virtual connection qualifies). It is stamped
`substituted_for: vds` with its `substitution_evidence`, listed in
`numeric_parity.oracle_substitutions` and named in the Python migration report
(the shared Ruby report: follow-up PR). It is a substitution, not a waiver. A
published datasource whose LUID did not resolve (`--offline`, no creds, failed
lookup) stays strict, as does an errored or unrun vds check.

## Still manual by design (the orchestrator stops and tells you)

**Still manual by design (the orchestrator stops and tells you):**
- **Parity actuals the exporter could not collect** — pass 1 collects actuals
  for every exportable chart itself over the REST API, no Sigma MCP required:
  `collect-parity-actuals.rb` pools the element exports
  (`POST /v2/workbooks/{wb}/export` → poll → download, 5-wide, under
  `sigma_rest`'s auto-refresh) straight into `parity-actuals.json`. Pivot-tables
  read the element's JSON export, which returns the long row/col/value tuples
  the plan compares (their CSV export is the WIDE grid). Only charts whose
  export failed, timed out or truncated stay agent-mediated: pass 1 prints an
  `mcp__sigma-mcp-v2__query` per chart for when the MCP is connected, and the
  REST/warehouse route (re-run the collector with a higher `--timeout` /
  `--row-limit`, or warehouse SQL) for when it is not; merge their rows into the
  same file. When NOTHING stays agent-mediated (strict artifact-derived
  predicate), pass 1 chains `--finalize` in-process instead of stopping at
  exit 12.
- **Empty-view-CSV recovery** — a view that exports an empty CSV produces no
  chart; surfaced at the consolidated pre-build checkpoint AND by the tile
  census at `--finalize` (exit 7 → rebuild the chart manually or explain with
  `--allow-missing-tiles`, naming the zones in your report). On a scoped run
  (E9.6) only in-scope views are surfaced.
- **Master-level calc overrides** — when the workbook layer exits 4 naming a
  field like `master/delivery speed tier`, translate the Tableau calc (see
  `calc-fields.json`) and re-run the same command with
  `--master-col 'Name=<Sigma formula>'`.
- **Shared relative-date filters** — `build-charts-from-signals.rb` now maps
  these to Sigma's native ROLLING date-range modes directly:
  `this <period>` → `mode:current`, `last N <period>` → `mode:last`
  (`value:N`, `unit`, `includeToday`), `next N` → `mode:next`. They roll with the
  clock — no frozen dates and no manual master-boolean workaround. Only a
  shifted/spanning window (one that doesn't anchor to now) falls back to a frozen
  `mode:between`, flagged `FROZEN — re-run to refresh`. If a shared relative-date
  filter still shows a uniform parity DIVERGE (every Sigma value too big),
  confirm the date key survived into the DM and the control's `filters` target
  wiring reached the chart's source. (Rolling emission verified 2026-07-01;
  shapes per `sigma-authoring` controls.md, live 2026-06-15.)
- **❌-unhandled gap features** — gap-scout subagent or `--force` (degraded).
- **DM-reuse shape preflight** — every resolved `--reuse-dm` now runs Phase
  1.5b (`inspect-dm-shape.rb`) before workbook authoring and writes
  `dm-denorm-plan.json`; unresolved columns still route to the exit-4 agent
  repair path.
- **Target-model plan** — `--target-model-plan` consumes an accepted
  cardinality-aware topology. `--table-profiles` can generate the plan in-run;
  remodeled/reuse modes require attributable acceptance, relationship targets
  remain behind the join probe, and substitutions require equivalence evidence.
