<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase E (opt-in) — enhance -->

## Phase E (opt-in) — Enhance

**OFF by default, everywhere.** Phase E never runs in batch/headless mode
without the explicit `--enhance` flag, and it only ever starts from a
**parity-verified** workbook (all Phase 6 gates green). It is powered by the
shared engine vendored byte-identically into the covered plugins
(`scripts/enhance-scan.rb` + `scripts/enhance-apply.rb` — md5 discipline,
same as `escalate-gap.py`).

```bash
# at --finalize, after gates are green:
ruby scripts/migrate-tableau.rb --workbook "<name>" --finalize \
  --actuals <workdir>/parity-actuals.json \
  --enhance                       # scan only → exit 14 with proposals
# present each candidate to the user (one AskUserQuestion checklist), then:
ruby scripts/migrate-tableau.rb --workbook "<name>" --finalize \
  --actuals <workdir>/parity-actuals.json \
  --enhance --enhance-accept all-low-risk    # or: id1,id2,...
```

The contract (trial-validated, 2026-06-10):

1. **Clone-first.** `enhance-apply.rb` GETs the parity workbook's spec and
   POSTs it as `"<name> — Enhanced"`. The 1:1 parity artifact is **never
   written** (the report records its `updatedAt` before/after as proof).
2. **Scan-then-propose.** `enhance-scan.rb` reads source signals (workdir
   artifacts: `calc-fields.json`, `dashboard-layout.json`, `migrate-state.json`,
   view CSVs) + the built spec + live element exports, and emits
   `enhancements.json` — each candidate `{id, category, evidence, proposed,
   risk, verdict_hint, patch}`. **Nothing applies without acceptance**:
   interactive runs present a per-item checklist (AskUserQuestion); headless
   runs pass `--enhance-accept id1,id2` or `--enhance-accept all-low-risk`.
3. **Apply + parity-unchanged gate.** Accepted items apply **one at a time**
   to the clone; after each, 2-3 untouched elements are spot-queried on the
   clone AND the original at the same instant (live-drift-proof) — any shift
   auto-reverts that item and flags it in `enhance-report.json`
   (applied/skipped/reverted + evidence).

Detector catalog (trial-validated; nothing speculative):

- **comparison-enrichment** — date-grouped master + revenue-like measure →
  latest-period KPI + delta-% KPI pair. KPI value columns INLINE the full
  `Sum(If(D = Max(D), v, Null))` expression — cross-column aggregate refs
  silently misevaluate in kpi-charts.
- **interactivity-recovery** — (a) list **selection controls** on
  reasonable-cardinality dims wired to the shared master (empty default =
  identical render); (b) **grain switcher** — segmented control + DateTrunc
  switch, default = parity grain; (c) **drill switcher** — segmented control +
  `If()` dimension switch where a finer dim exists (medium risk: heuristic
  hierarchy pairing); (d) **map restoration** (PBI signals) — point-map with
  `Switch()` centroid synthesis (medium risk: centroids must be filled into
  the patch before apply).
- **fidelity-polish** — null-bucket labeling (`Coalesce → "No <Dim>"`),
  month/date axis canonicalization (`MakeDate`; medium risk on multi-year
  sources — intentionally un-pools), stale-source freshness note (time-boxed
  wording), title corrections from source captions.

**Descoped — emitted as propose-in-UI notes, never spec changes** (all
trial-proven spec-unsupported): DM-metric promotion (metric refs don't resolve
through a workbook table), chart-as-filter (`useAsFilter` silently dropped on
readback), pie percent labels (`valueFormat:'percent'` silently dropped).

### Phase E layout placement + HARD screenshot checklist

Every applied item lands in the **container system** — never appended at the
page foot (that was the "PHASEE PBI Employee Dashboard" regression):

- selection controls → the **control band** (created under the header if the
  clone lacks one);
- comparison KPIs → the **KPI band**;
- grain/drill switchers → a slim row **inside the container of the chart they
  drive**;
- migration/freshness notes → a **slim note band directly under the header**.

If the cloned parity workbook predates container layouts (no `<GridContainer>`
in its layout), `enhance-apply.rb` **regenerates a banded layout** for the
clone first (builder machinery, `scripts/lib/layout.rb`), then applies items.
The finalize runs the shared layout lint (`scripts/lib/layout_lint.rb`: no
raw-id display names, no controls outside containers, no dead zones, no
generic header-band title — "Page 1"/"Sheet N"/"Dashboard N" never titles a
dashboard; the header carries the promoted source title → source display
name → workbook name — and no band whose elements fill <60% of the grid
columns, KPI bands of ≤4 tiles exempt) and
**exits 4 on violations** — a lint-failing clone must be fixed and re-PUT
before the run may be declared done.

**HARD screenshot checklist (mandatory at finalize).** The lint is mechanical;
your eyes are the last gate. Export the clone's **full-page PNG**
(`scripts/sigma-export-png.py`) and verify EVERY item, listing each with
pass/fail in your report:

- [ ] every chart/control title is human-readable (no raw element ids)
- [ ] the page has a header band (dark, full-width, carrying the SOURCE title
      or display name — never a generic "Page 1")
- [ ] selection controls sit together in a control band near the top
- [ ] every control is adjacent to / inside the container of what it filters
      (grain/drill switchers INSIDE their chart's container)
- [ ] no orphan elements below the fold (nothing dumped at the page foot)
- [ ] no dead zones; row heights look even across each band

