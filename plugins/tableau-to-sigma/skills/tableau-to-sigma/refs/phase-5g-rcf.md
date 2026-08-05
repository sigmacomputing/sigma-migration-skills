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

The loop, per pass (~30–90s):

```
RENDER    ruby scripts/fidelity-loop.rb render --workdir <WORK>
          → rcf-pass-N.png (export API), bumps the pass counter, prints the rubric,
            enforces the pass budget (default 5; exit 3 when exhausted)
COMPARE   Read rcf-pass-N.png against the SOURCE dashboard PNG (Phase 1d / visual-qa/
          <slug>.source.png), score EVERY dimension in refs/fidelity-rubric.md — including
          the two functional dimensions a visual diff misses: controls/parameters + accuracy
CLASSIFY  ruby scripts/fidelity-loop.rb record --workdir <WORK> --dimension <d> \
            --delta "<what differs>" --class spec-fixable|ui-only|sigma-capability|data
FIX       author a patch from refs/fidelity-recipes.md (ONLY the delta), then:
          ruby scripts/fidelity-loop.rb apply-patch --workdir <WORK> \
            --patch patch.json --resolves <ledger-ids>
          (single layout-preserving PUT → GET full spec, deep-merge by elementId, PUT back,
           re-run guard + lints — a fix that breaks a column or the layout fails the pass)
LOOP      render → compare → fix until `fidelity-loop.rb status` is clean
EXIT      zero unresolved spec-fixable deltas (ui-only / sigma-capability / data residuals flow
          to the report). Waive genuinely-unclosable spec-fixable residuals ONLY via
          assert-phase6-ran.rb --accept-residuals id,id, NAMED in the report.
```

Convergence pattern: pass 1 fixes **structure** (missing tiles, wrong kinds); passes 2–3 fix
**composition** (containers, tints, text); pass 4+ fixes **typography / number-format** detail.
Before hand-fixing a `numbers_formatted` or `palette_match` delta, read the build's
**`formats-emitted.json`** (next to the chart-spec output — PR-12): per tile it records every
source format string → the emitted Sigma format (`mapped|unmapped`; unmapped = the translator
refused, recorded never guessed) plus `series_color_maps` (member→color pinning status). A
`mapped`/`pinned` entry that still renders wrong is a spec/render finding worth recording; an
`unmapped` entry is the expected RCF chore.
Only `spec-fixable` deltas block; classify UI-only / capability ceilings and move on — see the
"When NOT to loop" list in `refs/fidelity-recipes.md`. Full rubric + classification table:
`refs/fidelity-rubric.md`. Delta→fix catalog: `refs/fidelity-recipes.md`.

---


> **Gate 8d — RCF fidelity ledger (exit 15).** The single recorded verdict (8b) proves *someone looked once*; the Phase 5g RCF loop proves the composition was iterated to convergence. `migrate-tableau.rb --finalize` passes `--require-fidelity-ledger` (unless the loop was disabled with `--rcf-passes 0`), so `assert-phase6-ran.rb` exits 15 until `fidelity-ledger.json` has zero unresolved `spec-fixable` deltas. See **Phase 5g** above. This gate is OPT-IN and shared byte-identically across converters — other plugins are unaffected until they pass the flag.

---

## The 5g stanza as stated in the spine (relocated from SKILL.md — PR-15 diet)

### Phase 5g — RCF (render-compare-fix) fidelity loop — `refs/phase-5g-rcf.md`
After the workbook renders, iterate composition to convergence: `fidelity-loop.rb render`
exports the page → **Read it against the source dashboard PNG** and score every dimension
(`refs/fidelity-rubric.md`) → `record` each delta (spec-fixable / ui-only / sigma-capability /
data) → author a fix from `refs/fidelity-recipes.md` and `apply-patch` (single layout-preserving
PUT) → loop until `fidelity-loop.rb status` is clean. DEFAULT-ON hard gate (PR-11):
`migrate-tableau.rb --finalize` passes `--require-fidelity-ledger` (gate 8d, exit 15), and the
gate also auto-enables itself from `migrate-state.json` `rcf_passes` on standalone runs;
`--rcf-passes 0` remains the explicit opt-out but records the named `--skip-fidelity-gate`
waiver (budget-counted) — never silence. The layout build also emits
`layout-arrangement.json` (source-vs-built ordering/quadrant/controls-shelf parity — gate 8e,
WARN-level this release, `--require-arrangement` to enforce), and gate 4b fails a run whose
run-state ledger shows the layout phase was never entered (exit 30). **Full loop, rubric, and
delta→fix catalog: `refs/phase-5g-rcf.md`, `refs/fidelity-rubric.md`, `refs/fidelity-recipes.md`.**
