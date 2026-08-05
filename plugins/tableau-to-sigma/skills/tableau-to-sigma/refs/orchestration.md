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
  ruby scripts/record-visual-check.rb --workdir <workdir> --agent-vision true \
    --verdict pass --checklist "<six dimensions>" \
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
> **hosted** converter (an optional, user-provided endpoint set via
> `SIGMA_CONVERTER_MCP_URL` — placeholder `<hosted-converter-mcp-url>`) uploads the `.twb` to
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
3. **Phase-1d dashboard-read is a WAIT-GATE at the DM-POST barrier**: do the
   PNG read while the orchestrator waits (`SIGMA_PNG_READ_TIMEOUT_S`, default
   480s) and the run continues in-process; the deadline is exit 18 naming the
   missing piece. Headless/CI callers with no driving agent to write the read
   should set `SIGMA_PNG_READ_TIMEOUT_S=0` — the gate then fails fast (exit
   18) instead of blocking the full bound; the wait banner's first line names
   this switch. A `png-read.json` older than this run's discovery fetch is
   set aside as `.stale` — never silently consumed.
4. At the pass-1 tail, when the artifacts prove the agent-mediated actuals
   list is EMPTY (all exportable charts machine-collected, no pivot grids, no
   markers, no per-tile visual sidecar) AND the agent-side gate obligations
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

## Still manual by design (the orchestrator stops and tells you)

**Still manual by design (the orchestrator stops and tells you):**
- **Parity actuals (pivot grids only)** — pass 1 now collects actuals for every
  exportable chart itself: `collect-parity-actuals.rb` pools the element CSV
  exports (`POST /v2/workbooks/{wb}/export` → poll → download, 5-wide, under
  `sigma_rest`'s auto-refresh) straight into `parity-actuals.json`. Only
  pivot-tables stay agent-mediated (their CSV export is the WIDE grid, not the
  long row/col/value tuples the plan compares) — pass 1 prints exactly those
  `mcp__sigma-mcp-v2__query` calls; merge their rows into the same file. When
  NOTHING stays agent-mediated (strict artifact-derived predicate), pass 1
  chains `--finalize` in-process instead of stopping at exit 12.
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
- **DM-reuse shape preflight** — when `--reuse-dm` hits a differently-shaped DM
  the workbook gate exits 4; run Phase 1.5b (`inspect-dm-shape.rb`) and the
  agent path against the reused DM.
