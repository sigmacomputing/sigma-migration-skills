<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. E9.1 single-ownership home: this file is the SOLE owner of orchestrator exit codes and final-gate semantics (relocated verbatim from SKILL.md — E9 diet, 2026-07-27). SKILL.md keeps one-line pointers; per-gate prose lives in refs/script-map.md + refs/phase-6-parity.md. -->

# Gates & exit codes — the one catalog

Read this when an orchestrator run stops with a nonzero exit, before finalize,
and whenever a waiver is on the table. Every code below is a **designed stop
with printed instructions** — a routing exit is the skill working, not failing.

> **An orchestrator STOP is an instruction to YOU (the agent), not a handoff to
> a human — keep going.** A routing exit (exit-4 workbook handoff, "CONVERTER
> STOP") authorizes you to do the next step yourself: author the spec it names
> and **re-enter the gated spine** (exit 4: `--reuse-dm <id> --wb-spec <path>`).
> "The DM is posted" is not a finish line. Do not report done or wait for a
> human at these STOPs; the only finish line is `verify-complete.rb` exit 0.
> *(Relocated verbatim from SKILL.md STEP 1 — E9 diet.)*

## Orchestrator (`migrate-tableau.rb`) exit codes

Exit codes:
`10` = OPEN QUESTIONS (re-run with `--yes`/`--answers`), `11` = ❌-unhandled
gap-scan features (gap-scout or `--force`), `12` = pass 1 done, parity PENDING
(collect mcp-v2 actuals, then `--finalize`), `16` = pass 1 built + POSTed but
`<workdir>/manual-residues.json` carries `unbuilt` window/table-calc residue(s)
a dashboard tile plots — build each from the printed checklist, set
`status:"built"`, then `--finalize` (the final gate refuses GREEN on `unbuilt`
residues, exit 22; waiver `--accept-manual-residues "<calc,...>"`,
budget-counted), `4` = DM posted but the workbook layer needs an agent-authored
spec — re-enter with `--reuse-dm <id> --wb-spec <path>` (never hand-POST),
`3` = a gate failed, `14` = migration GREEN + Phase E proposals pending,
`0` = ALL gates green (only reachable via `--finalize`),
`18` = the Phase-1d dashboard-read WAIT-GATE deadline passed — `png-read.json`
still missing/unverified/stale after `SIGMA_PNG_READ_TIMEOUT_S` (default 0s;
positive bounds are opt-in for concurrent runners) at the DM-POST barrier:
do the read (fetch the dashboard
PNG, Read it, write `<workdir>/png-read.json` with `"verified": true` —
schema in `refs/phase-1-discover.md`), then re-run the same command
(discovery is cached, the re-entry is cheap; genuinely no PNG access →
`--skip-dashboard-read "<reason>"`),
`19` = scope stop: a stated `--dashboard` / `mission.json` scope matched
NOTHING in this workbook (E9.6) — fix the scope from the banner's printed
dashboard list and re-run; a scoped mission never silently fans out to the
full workbook, and no Sigma objects were created.
`29` = `--finalize` PREFLIGHT stop: a prerequisite artifact (anchors verdict, join
probe, LOD audit, ground-truth derive/run/verify, parity plan, an unrecorded
blind grade — with an RCF ledger the printed `record-visual-check.rb` command
carries `--screenshot <latest render>`) is missing and could not
be produced automatically — the printed ordered list gives the exact command for each.
The preflight auto-runs every step that can run non-interactively BEFORE any gate, and
this stop writes nothing to `loop-log.jsonl` (it never consumes an attempt toward
`SIGMA_LOOP_ATTEMPT_CAP`); fix the list, then re-run the same `--finalize`.
`26` = optional `--wait` budget expired while the child remains alive: inspect
the PID/log and `migration-process.json`; do not start another run until it exits.
`28` = another migration holds the workdir's OS lock; the second writer is refused.
`30` = local TWB/MCP source evidence missing, stale, ambiguous, or incomplete;
follow `mcp-evidence-request.json` and `refs/mcp-source.md`, not PAT setup.
The lock survives in-process finalize/reuse-repair exec and is released by the OS
on exit, including an abrupt kill. Do not delete `migration.lock` to bypass it.
A tool timeout can terminate a POSIX process with **exit 143** (SIGTERM).
That is not the live-child exit 26 or a completed checkpoint: inspect the
process and lock state before resuming.
DM-reuse is **reuse-first** (auto-reuses a covering DM, skipping the POST);
`--reuse-dm <id>` pins one, `--skip-reuse-scan` forces build-new. Optional
`--enhance [--enhance-accept <ids|all-low-risk>]` runs Phase E after all gates
are green. **Still manual by design** (parity actuals the exporter could not
collect, empty-view-CSV recovery, `--master-col` overrides, gap-scout escalations,
DM-reuse shape preflight): `refs/orchestration.md` §Still manual.

Exit `17` routes to `refs/extract-landing.md` (extract landing); exit `2` from
`resolve-project.rb` = STOP and ask the user with the printed candidates
(`refs/phase-1-discover.md` §Phase 1a).

### Exit-4 handoff discipline (relocated from SKILL.md — E9 diet)

> **At the exit-4 handoff, PATCH the auto-built `<WORK>/wb-spec.json` — do NOT
> rewrite it.** Edit ONLY the fields/tiles it names, keeping every other
> element **and every controlId** exactly as built, then re-enter with
> `--reuse-dm <id> --wb-spec <WORK>/wb-spec.json`. A from-scratch rewrite
> drifts controlIds from `control-scope.json` and fails control-lint wholesale
> (the #1 way this handoff spirals). For a master-level calc, prefer
> `--master-col` over hand-editing the tile.

`workbook-handoff.json` records the failing child stage, exit, error, and any
identified fields. Exit 4 is not necessarily a translation failure: a validation,
reference, or API error may require a different repair. Never infer missing calcs
from a generic handoff. `execution-identity.json` and `execution-history.jsonl`
identify the installed implementation and selected converter; these stay in the
run workdir, never in the plugin.

## The final gate (`assert-phase6-ran.rb`) — exit-code table (load-bearing)

> **Same numerals, different processes.** Orchestrator exit codes (above) and
> this final-gate table are SEPARATE namespaces — e.g. orchestrator 18/19 =
> wait-gate deadline / scope stop, while final-gate 18/19 = anchors / waiver
> budget. Route by which process printed the exit, never by the number alone.

Exits 0 only when ALL pass. Full prose per gate: `refs/script-map.md` +
`refs/phase-6-parity.md`.

| Exit | Gate | Fails when / escape |
|---|---|---|
| 1 | parity sentinel | `parity-final.json` missing |
| 2 | parity | FAIL / extract-mode-without-flag / `charts_total==0` unbacked |
| 4 | orphans | uncleaned posted workbooks (`cleanup-orphan-workbooks.rb`) |
| 5 | live columns | any live `type=error` column |
| 6 | layout | no non-empty layout applied (`document.layout` — spec is `document`-wrapped, see `refs/phase-5-workbook.md`) |
| 7 | tile census | unexplained missing zones / `--allow-missing-tiles N` |
| 8 | layout lint | `lib/layout_lint.rb` / `--skip-layout-lint` |
| 9 | control lint | `lib/control_lint.rb`, `control-scope.json` / `--skip-control-lint` |
| 10 | visual render | no `sigma-render.png` or `screenshots/_manifest.json` / `--skip-visual-gate "<reason>"` |
| 13 | visual verdict | unrecorded or self-attested pass — needs sha-bound `blind_grade` (PR-9) or recorded `--no-vision-waiver` / `--skip-visual-comparison "<reason>"` |
| 14 | layout fill | `layout-census.json` dropped tile or `grid_fill_pct < --min-grid-fill` / `--skip-layout-fill "<reason>"` |
| 15 | 8d RCF ledger | unresolved spec-fixable deltas (`--require-fidelity-ledger`, default-on at `--finalize`); `--accept-residuals id,id` — data-class NEVER. Hybrid-route entries resolved via `sdk-export` (`resolved_via.route: sdk`) count like REST ones; an un-exported or failed-re-gate SDK session stops `--finalize` first (exit 3, `refs/phase-5g-sdk-hybrid.md`) |
| 18 | 13 anchors | `source-anchors.json` <5 anchors or failing `anchors-verdict.json`; also `--skip-parity-gate` without passing anchors / `--skip-anchors-gate "<reason>"` |
| 19 | waiver budget | >2 quality waivers → YELLOW cap; no escape flag |
| 20 | 14 visual similarity | `visual-similarity.py` floor fail / `--skip-visual-similarity "<reason>"` |
| 21 | 7b control flip | control doesn't filter live (`probe-controls.rb`), or no evidence on an enforced run / `--skip-flip-test "<reason>"` → `--skip-control-flip` (budget-counted) |
| 22 | 15 manual residues | `manual-residues.json` still `unbuilt` / `--accept-manual-residues "<calc,...>"` (budget-counted) |
| 23 | 16 join cardinality | `join-plan.json` unprobed / non-unique Lookup target (`probe-join-keys.rb`, `--resolve <i> --how <preaggregated\|waived> --reason`); entries with status `emitted` (a REAL `"kind": "join"` in the dm-spec — wave-2 shape 2) are terminal, evidence-bound to the spec; no skip flag |
| 24 | 17 LOD ledger | `lod-audit.json` suspect-alias / silently-dropped unresolved (`audit-lod-calcs.rb`); no skip flag |
| 25 | 18 ground truth | displayed tile with no `numeric_parity` match and no `coverage_waivers` entry; `diverge`/`conflict` NEVER waivable; no skip flag |
| 26 | 19 agg semantics | `agg-semantics.json` unresolved additive-over-preagg / countd-as-sum / preagg-ratio (`audit-agg-semantics.rb --how <reaggregated\|n/a\|faithful-to-source>`); no skip flag |
| 27 | 20 semantic edits | `semantic-edits.json` unproven or `match:false` (`probe-equivalence.rb`); NO waiver — revert or redesign |
| 28 | 21 chart-kind parity | live element family ≠ verified `png-read.json` kind; substitutions recorded as `kind_waivers` at read time |
| 29 | 8e layout arrangement | `--require-arrangement` set + `layout-arrangement.json` missing/malformed after a layout build, or violations present; WARN-only without the flag |
| 30 | 4b layout ran | run-state shows the layout phase never entered |
| 31 | 7c controls census | source control never built, undeclared in `control-scope.json` and unnamed in `controls-waivers.json`; no skip flag |

A parameter that is only DECLARED (no sheet calc or filter reads it, no dashboard
shows it) is not a source control: the builder emits no control for it, records it
under `control-scope.json` `ignoredSignals` and the controls census `ignored`
(status `not-applicable`), so gate 7c, reconstruction integrity and the degradation
ledger never see it — no `controls-waivers.json` entry is needed. A parameter a
dashboard shows but nothing reads stays a visible `source-inert` control.

An LOD calc that no worksheet, dashboard or filter uses (the gap scan's
`field_statistics.unused_field_names`) is classified `unused-source` (resolved)
by both `audit-lod-calcs.rb` and the orchestrator's own Phase-4 audit — no
`--how waived` resolution and no degradation entry.

The control-field census treats a posted EMPTY value the readback omits (a
metric-switch parameter control's `filters: []` — formulas read it, it filters
no element) as no drop; a bound filter target that vanishes still warns.

The guide-residue check (assert-action-gates.rb) accepts a guide with zero
`<!-- ledger-key -->` markers only when `build-postpublish-guide.rb` stamped
`<!-- ledger-residue: none -->` (every detected action auto-wired) AND the ledger's
residue is empty; a marker-less guide over emitted actions still fails closed.

Finalize precondition stops (exit 29, never a loop-log attempt) include the
visual record: re-checked right after Phase 6 writes `parity-final.json`, so
even the FIRST `--finalize` stops before the gate battery when parity passed but
no verdict is recorded. The printed `record-blind-grade.rb` command carries
`--screenshot <latest RCF render>`; a grade the shared recorder refuses is
archived as `blind-grade.refused-<n>.json` (reason in
`blind-grade-refusals.jsonl`), and a failing grade under an already-recorded
`divergent` verdict never blocks. `numeric-parity.json` is fresh only while the
input digest it stamps (anchors verdict, ground-truth actuals, Sigma actuals,
source anchors, live spec) is unchanged; the anchors verdict is stale once
`source-anchors.json` or `wb-spec.json` is newer.

The finalize loop breaker's attempt identity includes a digest of the
agent-changed inputs (source anchors, png-read, waivers, residues, blind grade,
actuals, live spec, and the recorded resolutions in the LOD / join / fidelity
ledgers) — progress between two identical-status finalizes is a new attempt.

The exit-4 loop breaker's attempt identity includes a digest of the input spec
(`--wb-spec`/`--dm-spec`, else the generated spec): an identical error after an
edited spec is a new attempt; `SIGMA_LOOP_ATTEMPT_CAP` still bounds the run.

On the all-embedded (`charts_total==0`) ANCHORS-ORACLE path, substitution also
requires per-displayed-tile anchor coverage (`anchor_coverage.covered ==
displayed`, or `coverage_waivers` naming each uncovered tile). Subagent flows
MUST call this gate as their final step.

### Tableau-local structural gates

These run alongside the shared final gate and are included in the
orchestrator's GREEN predicate:

| Gate | Artifact | Failure |
|---|---|---|
| Relationship completeness | `relationship-coverage.json` | Missing/stale coverage, count mismatch, unwired edge, `partial:true`, or dropped relationship condition. No waiver. |
| Relationship evidence (reused DM) | `relationship-map.json` + `migrate-state.json` `relationship_route` | Replaces the row above only for a DM reused by explicit `--reuse-dm <id>` (Python: `--data-model-id`) that the workdir did not post. Fails on a stale map, an unprobed/failed/errored edge probe (target not unique or unmatched keys), an affected worksheet missing from or failing parity, a dropped/disconnected table a migrated worksheet uses, or an ambiguous table name. Still no waiver: a `reason` is display-only. See `refs/phase-3-datamodel.md`. |
| Visible dashboards | `dashboard-coverage.json` + `dashboard-scope.json` | Any non-empty visible Tableau dashboard lacks a Sigma page unless excluded by stated/CLI scope. No waiver. |
| SQL provenance | `sql-provenance.json` | A DM `source.kind:"sql"` element matches neither source Custom SQL nor a recognized generated helper, and has no reasoned override backed by `proof.match:true`. No waiver. |

All three run before the relevant Sigma POST and are re-derived at completion;
hand-editing their result files fails the stale-artifact check.

## 🚧 GATE convention

> **🚧 GATE convention.** A step marked **🚧 GATE** is backed by a script that
> *fails the run* if the step was skipped — not advisory. Every 🚧 GATE requires
> an **artifact** (a file on disk) and a downstream check that refuses to
> proceed without it. Current gates: **Phase 1d source dashboard-read**
> (`png-read.json` → `assert-dashboard-read.rb`, re-enforced inside
> `build-charts-from-signals.rb`), **Phase 6 source-parity** and **Phase 6f
> visual render** (`assert-phase6-ran.rb`).

## Waiver discipline (relocated from SKILL.md — E9 diet)

> **Waiver discipline — waivers are for impossibilities, not obstacles.** Every
> `--skip-*` / `--allow-*` / `--accept-*` / `--min-pass-rate <1` flag attests a
> verification could NOT run — not a lever to turn a red gate green. The gate
> stamps `waivers` + `waiver_count` into `parity-final.json`; **more than 2
> quality waivers caps the migration at YELLOW** (exit 19; the sanctioned
> builder→verifier `--skip-visual-comparison` is a policy exclusion), and
> **data-class fidelity residuals can never be waived**.
> Reaching for a third waiver means: stop and fix.

## Verdict model (PR-14) — GREEN / YELLOW / PARTIAL (relocated from SKILL.md — E9 diet)

> **Verdict model (PR-14) — GREEN / YELLOW / PARTIAL.** Every gate run derives
> `degradation-ledger.json` from the artifacts (`lib/degradation_ledger.rb` —
> mechanical, never self-reported) and prints ONE verdict with the ledger
> inline. **GREEN requires an EMPTY ledger.** Any non-scope-cut entry (or
> exceeded budget) → **YELLOW**. **Any scope cut caps at PARTIAL.** Stamped into
> `phase6-success.json` + `parity-final.json`; `verify-complete.rb` re-derives
> offline and **fails (exit 6) if your report contradicts it** — quote the
> ledger verbatim, never a verdict it doesn't support. **Wave-2 label (W2.3):**
> a Tier-S factory run with no verifier countersignature stamps
> `verdict_by: "builder-self-attested"` and its GREEN is the labeled string
> **`GREEN (factory, self-attested)`** — never bare; `verify-complete.rb`
> fails a claim that strips (or fabricates) the label. Tier-scaled budget
> (W2.1): Tier-S caps quality waivers at **1** (M/full keep 2).

## Finish: blind grade v2, YELLOW, and the one GREEN offer

1. **Grade.** Spawn a FRESH blind grader (`refs/blind-grader-brief.md`; parameters
   `{{SOURCE_PNG}}`, `{{TARGET_PNG}}`, `{{RUBRIC_PATH}}`=`refs/fidelity-rubric.md`,
   `{{CATALOG_PATH}}`=`refs/sigma-platform-differences.json`, `{{OUT_JSON}}`=`blind-grade.json`).
   Pass bar `overall_score >= 75`; `chart_shapes_match` and `numbers_formatted` must pass; no
   `fixable` gap with severity `major`. A score within 5 of 75 needs a second, independent
   grader (`OUT_JSON`=`blind-grade-2.json`), decided on the mean. Platform differences from the
   shipped catalog never lower a score or forfeit GREEN. On a passing grade, every `minor`
   fixable gap is a **polish note**: the report lists it under "Minor polish notes"
   (`migration-result.json` `polish_notes`), it is not a degradation and it never forces YELLOW.
   Every fixable gap of a divergent grade, and any `major` gap, still ships as a YELLOW `fidelity-residual`.
2. **Record.** `ruby scripts/record-visual-check.rb --workdir <WORK> --agent-vision true
   --blind-grade <WORK>/blind-grade.json --notes "..."` (omit `--verdict`/`--checklist`: a v2 grade
   computes the verdict; a legacy v1 grade still needs `--verdict pass --checklist "..."`). If it
   exits 2 with "second blind grader required (score within +-5 of 75)", run the second grader
   and re-run the same command adding `--blind-grade-2 <WORK>/blind-grade-2.json`.
   `agent_vision` (here and in `doctor.json`, `null` when the doctor could not tell) is the
   builder's own ability to read images. Who graded is `parity-final.json` `visual_graded_by`
   (`blind-grader`, `builder (no-vision waiver)`, `none`), stamped by the gate.
3. **YELLOW?** When the verdict is YELLOW (fix budget spent, `fidelity-loop.rb status` prints
   `YELLOW-ready`), run `ruby scripts/fidelity-loop.rb green-offer --workdir <WORK>`. It prints
   JSON `{realistic, gaps[{id|tile, dimension, description, route}], est_passes, why_not,
   blockers, polish_notes}` (any waiver, escape, scope cut or layout/png residual in the degradation ledger makes
   it not realistic: GREEN is forfeited); routes are `recipe:<anchor>` (a `refs/fidelity-recipes.md` heading) or `sdk`.
   `why_not` "GREEN, optional polish: N notes" means nothing forfeits GREEN and only polish notes
   remain: make no offer, list the notes as optional polish. "no fixable gaps remain; N polish
   notes" means something else forfeits GREEN (see `blockers` and the migration report).
4. **Offer once.** If `realistic`, ask the user exactly once, naming the gaps and the estimate:
   "This finished YELLOW. These N gaps look fixable in about P more passes — want me to keep
   going for GREEN?"
5. **Yes.** `ruby scripts/fidelity-loop.rb extend --workdir <WORK> --max-passes <current+N>
   --max-seconds <elapsed+allowance seconds> --approved-by "<user>" --reason "<the gaps>"`, then
   loop render/compare/fix and re-grade (a fresh grader each time). Both values are new TOTALS
   and must be strictly larger than the current ones; `started_at` is never reset, so
   `--max-seconds` must exceed the time already elapsed plus the new allowance.
6. **No, or not `realistic`.** Finish YELLOW and say why (the `why_not`, or the user's no). Never
   ask twice, and never extend without an actual user yes.

**Python profile** (`--runtime-profile python`): there is no RCF ledger, so `green-offer` exits 2
("no fidelity-ledger.json") and `status` does not apply; no GREEN offer is made on this profile.
Write `blind-grade.json` (and `blind-grade-2.json` beside it when told "second blind grader
required"), then re-run the same `python3 scripts/migrate-tableau.py ... --blind-grade
<WORK>/blind-grade.json` (the second grade is picked up from the sibling file; there is no flag).
Read the gaps from `migration-result.json` `visual_fidelity.fixable_major` / `residuals` (on a
faithful grade the minor ones are `polish_notes`, not degradations, and the run can be GREEN); an
unfaithful grade finishes YELLOW (`verify-complete.py` adds the divergent `fidelity-residual`
degradations; `assert-phase6-ran.py` requires them and refuses GREEN). Fix what you can, re-render,
and delete a now-stale `blind-grade-2.json` before re-grading. If gaps remain, finish YELLOW and say
so.

The run verdict is the **worse of the gate's degradation-ledger verdict and
`migration-result.json`** (`scripts/lib/final_verdict.rb`): source objects the census marks
`approximated` / `needs-review` / `skipped` are not ledger entries, so an empty ledger (for example
polish notes only) is not GREEN on its own. `--finalize` re-stamps `phase6-success.json` and
`parity-final.json` (`verdict`, keeping the gate's as `gate_verdict`), prints `VERDICT` and a
`STATUS` that is GREEN only when both are, and `verify-complete.rb` prints the same verdict.
Before building the report, `--finalize` writes its gate battery to `finalize-gates.json`; any failed gate
makes `migration-result.json` RED, so the report never says GREEN while a hard gate failed.

Unresolved `spec-fixable` entries after the budget is spent become named YELLOW
`fidelity-residual`s and stop blocking gate 8d; data-class residuals and value gates are unchanged.
