<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 5g — RCF render-compare-fix fidelity loop -->

## Phase 5g — RCF (Render-Compare-Fix) fidelity loop (MANDATORY — hard-gated by gate 8d)

> **Why this phase exists.** The build pipeline is one-shot on *design*:
> `build-charts-from-signals` emits once, the layout PUTs once. A mechanically-correct
> workbook (0 error columns, CSV parity green) can still ship visibly off-brand — generic
> palette, wrong chart kind, KPI format drift, missing containers. The exemplar migrations
> reached near-exact parity only by iterating a **render → compare → classify → fix loop** that
> uses spec surface the builder never touches. This phase makes that loop a first-class,
> machine-enforced step so every conversion gets it — not just tribal knowledge in one session.
>
> **Runs BEFORE Phase 6** so composition fixes can't invalidate collected actuals, and each
> `apply-patch` re-runs the column-type guard + layout/control lint. Staged automatically by
> `migrate-tableau.rb` at the pass-1 tail (the ledger is initialized for you); enforced at
> `--finalize` by `assert-phase6-ran.rb --require-fidelity-ledger` (gate 8d). Disable only with
> `--rcf-passes 0` (loud WARN; gate 8d then waived).

> **Route selection.** The REST loop below is the default. When the agent has the
> Sigma MCP `build_workbook` / `screenshot` / `query` tools, run the **fixes**, and any
> later edits, through the Code Mode SDK instead of `apply-patch`, on the **hybrid route**:
> `sdk-begin` → `sdk-write` after every call → `sdk-export`. The export brings the live
> spec back into `wb-spec.json` and re-gates it (column guard, layout/control lint,
> phase-6 parity) before `--finalize`. The build, the ledger and gate 8d are the same on
> both routes, and the final budgeted `render` plus the blind grade are unchanged. Full
> route: `refs/phase-5g-sdk-hybrid.md`; SDK pitfalls: `refs/sdk-gotchas.md`.

The loop, per pass (~30–90s):

```
RENDER    ruby scripts/fidelity-loop.rb render --workdir <WORK>
          → rcf-pass-N.png (export API), bumps the pass counter, prints the rubric,
            enforces the pass budget (default 5; exit 3 when exhausted).
            Multi-dashboard workbook: every dashboard page is rendered and stacked
            into ONE composite rcf-pass-N.png (one pass), plus source-composite.png
            from dashboards/<Name>.png in the same order — the pair the blind grade
            and record-visual-check need. --page-id <id> renders just that page;
            --single-page just the ledger page.
COMPARE   Read rcf-pass-N.png against the SOURCE dashboard PNG (Phase 1d / visual-qa/
          <slug>.source.png), score EVERY dimension in refs/fidelity-rubric.md — including
          the two functional dimensions a visual diff misses: controls/parameters + accuracy
CLASSIFY  ruby scripts/fidelity-loop.rb record --workdir <WORK> --dimension <d> \
            --delta "<what differs>" --class spec-fixable|ui-only|sigma-capability|data \
            [--catalog-id <id>]   # REQUIRED for ui-only|sigma-capability (see below)
FIX       author a patch from refs/fidelity-recipes.md (ONLY the delta), then:
          ruby scripts/fidelity-loop.rb apply-patch --workdir <WORK> \
            --patch patch.json --resolves <ledger-ids>
          (single layout-preserving PUT → GET full spec, deep-merge by elementId, PUT back,
           re-run guard + lints — a fix that breaks a column or the layout fails the pass)
          Patch semantics: JSON `null` DELETES a key (e.g. `{"elements":[{"id":"x","xAxis":
          {"format":{"title":null}}}]}` removes an axis title; absent key = no-op).
          Shape: document keys flat or wrapped (`{"document":{"elements":[...],"settings":{...}}}`);
          page-nested elements and legacy themeName/themeOverrides are normalized. A non-document
          key (workbook `name`, a typo) or a path that would not reach the PUT body exits 4 before
          any write; a patched path absent from the readback exits 5 with --resolves withheld.
          A successful patch archives stale evidence under repair-checkpoints/<id>/prior-evidence/
          and REGENERATES parity-plan.json (a derived plan, bound to the document version) by
          re-running phase6-parity.rb PASS 1 with the dashboard scope / extract flag recovered
          from the old plan; if that fails the exact command is printed — run it, re-apply any
          operator waives from the archived plan, and re-collect actuals before --finalize.
LOOP      render → compare → fix until `fidelity-loop.rb status` is clean
EXIT      zero unresolved spec-fixable deltas (catalogued ui-only / sigma-capability / data
          residuals flow to the report). Fix budget spent: `status` prints `YELLOW-ready` (exit 0);
          leftover spec-fixable deltas ship as named YELLOW residuals; then `green-offer`. Waive genuinely-unclosable spec-fixable residuals ONLY via
          assert-phase6-ran.rb --accept-residuals id,id, NAMED in the report.
```

`ui-only` / `sigma-capability` REQUIRE `--catalog-id <id>`, an id in the shipped
`refs/sigma-platform-differences.json` (run `record --class sigma-capability` without
`--catalog-id` to list the shipped ids). A missing or unknown id exits 6, as does a `--dimension`
that maps to a different rubric dimension than the catalog entry's. A Sigma ceiling that is
NOT in the catalog is recorded `--class spec-fixable`: it blocks while the fix budget remains, then
becomes a named YELLOW residual. A new catalog entry needs live proof via a separate shared PR.

`fidelity-loop.rb status` prints `YELLOW-ready` and exits 0 once the fix budget is spent and only
spec-fixable entries / visual residuals remain (minor gaps on a passing blind grade are polish notes,
never residuals). `fidelity-loop.rb green-offer --workdir <WORK>` then prints JSON `{realistic,
gaps[{id|tile, dimension, description, route}], est_passes, why_not, blockers, polish_notes}`
(`route`: `recipe:<anchor>` or `sdk`; est_passes = ceil(gaps/3); an unrouted gap or unresolved data
entry is not realistic). Offer GREEN once per `refs/gates.md` §Finish.

Convergence pattern: pass 1 fixes **structure** (missing tiles, wrong kinds); passes 2–3 fix
**composition** (containers, tints, text); pass 4+ fixes **typography / number-format** detail.
Before hand-fixing a `numbers_formatted` or `palette_match` delta, read the build's
**`formats-emitted.json`** (next to the chart-spec output — PR-12): per tile it records every
source format string → the emitted Sigma format (`mapped|unmapped`; unmapped = the translator
refused, recorded never guessed) plus `series_color_maps` (member→color pinning status). A
`mapped`/`pinned` entry that still renders wrong is a spec/render finding worth recording; an
`unmapped` entry is the expected RCF chore.
Unresolved `spec-fixable` and `data` deltas block (`ui-only`/`sigma-capability` need `--catalog-id <id>`); classify genuine UI-only / capability ceilings using evidence — see the
"When NOT to loop" list in `refs/fidelity-recipes.md`. Full rubric + classification table:
`refs/fidelity-rubric.md`. Delta→fix catalog: `refs/fidelity-recipes.md`.

## Repair State And Budgets

A live patch validates shape, layout, and controls before its PUT. It requires a
fresh version-bound base, including when using `--full-spec`. Immediately before
writing, it preserves a local `repair-checkpoints/<id>/workbook-spec.json` and
hash manifest, then creates `repair-pending.json`. These artifacts can contain
customer metadata and stay local; never commit or upload them.
The checkpoint also retains the local `wb-spec.json`. The PUT sends only the
document and its numeric `documentVersion` precondition; an intervening change
is rejected by the server rather than overwritten between client-side checks.
Live repairs persist the complete prepared candidate, not a partial patch over
an older local spec. Recorded candidates have a checksum; older unbound candidate
files are not silently trusted for rollback.

The pending marker blocks further live patches, fidelity renders, and completion
until the post-write version readback, column check, and layout/control lints
succeed. A bound candidate is recorded before those guards, so a guard-failed
repair can be rolled back directly using that same checkpoint. Unknown responses
or changed versions remain pending and require reconciliation:

```bash
ruby scripts/fidelity-loop.rb recover --workdir <WORK>
```

Recovery verifies the checkpoint hash and archives old verification artifacts;
it does **not** restore the live workbook, certify the patch, or select a winning
candidate. Read back the live state, diagnose the failure, and rerun verification.
After a successful write or recovery, prior parity, completion, render, and
report evidence is retained under the checkpoint's `prior-evidence/`, not reused
as current. A checkpoint is explicitly `checkpoint-not-a-pass`.

Re-entry after a patch recollects parity against the live, patched workbook.
`--finalize`'s preflight re-collects archived `parity-actuals.json` itself
(`collect-parity-actuals.rb`) and names `phase6-parity.rb --tableau <WORK>
--workbook-id <wb>` when the plan could not be regenerated. Do **not** re-run
`migrate-tableau.rb` pass 1 for this: it rebuilds charts from the source signals
and reverts the RCF fixes.

After reviewing a regression, restore its recorded pre-repair state with:

```bash
ruby scripts/fidelity-loop.rb rollback --workdir <WORK> --checkpoint <id>
```

Rollback refuses a live document that no longer matches the recorded repair
candidate, uses the server version precondition, verifies the restored document,
and restores local spec/entry state without resetting pass or time budgets.
All old verification remains invalid. Unknown write outcomes must be reconciled
first; automatic scoring and best-candidate selection are not implemented.

New ledgers track wall time from initialization with a default 1,800-second
budget as well as the render-pass limit. Failed render attempts consume a pass.
Budget checks refuse new writes/renders after expiry and bound in-flight repair
requests and renderer processes by the remaining wall time. Cancelled renderers
are terminated and reaped; late output is not accepted. Old ledgers without timing
must obtain an attributed `extend` before another write/render. Rollback remains
available as a recovery operation and never resets spent budgets. Do not infer a
speedup from these limits.

When the wall-time budget is spent, `apply-patch`/`render` refuse and print the exact
`extend` command with the current caps filled in (alternative: stop repairing and record the
residuals as ui-only / sigma-capability or `--accept-residuals`).

`render` sizes its viewport from `lib/export_viewport.rb` (`ExportViewport.for(workdir:,
page_id:)` → `[w, h]`: source dashboard PNG IHDR, else wb-spec layout rows x 28px, else
1600x900; clamped 800-3200 x 600-6000); `--width/--height` override. The auto-picked RCF
page (init without `--page-id`) prefers a page named after a source dashboard, then any
non-data page; a page named `Data` or made only of tables is picked last.

Extending a budget requires actual user approval and a concrete repair hypothesis:

```bash
ruby scripts/fidelity-loop.rb extend --workdir <WORK> \
  --max-passes <increased-total> --max-seconds <increased-total> \
  --reason "<approved hypothesis and recovery plan>" --approved-by "<approver>"
```

Both values are new totals, strictly larger than the current ones; `started_at` is never reset, so
`--max-seconds` must exceed the time already elapsed plus the new allowance. The extension is
recorded in the ledger and does not relax fidelity gates.
The workdir lock prevents concurrent local apply/render/recovery operations;
version comparisons and the server-side PUT precondition protect repair writes.
This is not a cross-workdir lock or a transaction spanning other writers.
Renders record the image hash and matching
before/after document version; changed-version images remain diagnostic only.

Finalization does not reapply pivot totals after verification. Anchor exports
are read-only; make any totals repair before collecting fresh evidence.
Render health is measured from the current `sigma-render.png`, not inherited
from an older similarity record. The punch list preserves degradation entries
separately from independent verifier findings and cannot promote RED or YELLOW
verification to GREEN. Changing `verification-result.json` requires regenerating
the punch list; the completion check compares its recorded verifier hash/data.
The punch list also carries the current `migration-result.json` hash and failed
checks. A RED completion report (or any FAIL check) overrides a cleaner ledger
or GREEN independent verifier, without changing source-accounting dispositions.
RED or YELLOW independent verification still requires repair/re-verification,
even when the degradation ledger already contains scope cuts. A GREEN verdict
cannot override a reported numeric or structural divergence; explicitly accepted
cosmetic residue may remain GREEN. Report rebuilds preserve prior output under
`report-history/` rather than leaving stale output at the current report paths.

---


> **Gate 8d — RCF fidelity ledger (exit 15).** The single recorded verdict (8b) proves *someone looked once*; the Phase 5g RCF loop proves the composition was iterated to convergence. `migrate-tableau.rb --finalize` passes `--require-fidelity-ledger` (unless the loop was disabled with `--rcf-passes 0`), so `assert-phase6-ran.rb` exits 15 until `fidelity-ledger.json` has zero unresolved `spec-fixable` deltas. See **Phase 5g** above. This gate is OPT-IN and shared byte-identically across converters — other plugins are unaffected until they pass the flag.

---

## The 5g stanza as stated in the spine (relocated from SKILL.md — PR-15 diet)

### Phase 5g — RCF (render-compare-fix) fidelity loop — `refs/phase-5g-rcf.md`
After the workbook renders, iterate composition to convergence: `fidelity-loop.rb render`
exports the page → **Read it against the source dashboard PNG** and score every dimension
(`refs/fidelity-rubric.md`) → `record` each delta (spec-fixable / ui-only / sigma-capability /
data; `--catalog-id <id>` required for ui-only|sigma-capability) → author a fix from `refs/fidelity-recipes.md` and `apply-patch` (single layout-preserving
PUT) → loop until `fidelity-loop.rb status` is clean. DEFAULT-ON hard gate (PR-11):
`migrate-tableau.rb --finalize` passes `--require-fidelity-ledger` (gate 8d, exit 15), and the
gate also auto-enables itself from `migrate-state.json` `rcf_passes` on standalone runs;
`--rcf-passes 0` remains the explicit opt-out but records the named `--skip-fidelity-gate`
waiver (budget-counted) — never silence. The layout build also emits
`layout-arrangement.json` (source-vs-built ordering/quadrant/controls-shelf parity — gate 8e,
WARN-level this release, `--require-arrangement` to enforce), and gate 4b fails a run whose
run-state ledger shows the layout phase was never entered (exit 30). **Full loop, rubric, and
delta→fix catalog: `refs/phase-5g-rcf.md`, `refs/fidelity-rubric.md`, `refs/fidelity-recipes.md`.**
