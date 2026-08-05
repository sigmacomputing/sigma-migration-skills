# tableau / preagg-kpi

**Synthetic twin of a field-failure shape** (PLAN-v3 PR-1, Wave 1). Invented
names on the neutral `DEMO_DB.ANALYTICS` demo star — no customer identifiers,
no live tenant. Reproduces the 2026-07-17 field root cause #3 (aggregation
semantics compile clean) and the #423 LOD failure classes (fuzzy alias +
silent drop), plus the dual-axis and integer-coded-dimension LOOKS-BAD traps.

## The shape (what makes this workbook a trap)

- Two `{FIXED [CAL_DATE] : COUNTD(...)}` LOD calcs materialize **day-grain
  distinct counts** (`Daily Distinct Buyers`, `Daily Active Sales`).
- Three KPI formulas consume them **ADDITIVELY** —
  `SUM([NET_AMOUNT]) / SUM([Daily Distinct Buyers])`,
  `SUM([Daily Active Sales]) / SUM([Daily Distinct Buyers])`,
  `SUM(IF ... ) / SUM([Daily Distinct Buyers])` — summing a pre-aggregated
  DISTINCT count over any grain other than day double-counts buyers. This
  compiled clean in every gate until PR-7: the aggregation-semantics lint
  (`audit-agg-semantics.rb` / `lib/agg_semantics_lint.rb`, gate 19 exit 26)
  now fires on exactly these formulas — see expectation 3 below.
- A **dual-axis combo** worksheet (`Amount vs Growth`) built the multi-pane
  way — three `<pane>`s with `y-axis-name`, a `(A + B)` rows shelf, and **no
  `synchronized='true'`** anywhere.
- An **integer-coded dimension filter** (`SITE_KEY`, integer, role=dimension)
  as a dashboard checkdropdown — the misclassification / silently-inert
  filter class (PR-18).
- A date `Anchor Week` parameter feeding a `DATEDIFF` calc, KPI
  customized-labels, and a sidebar control rail.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | The synthetic workbook XML (5 worksheets + `Wallet Pulse` dashboard) |
| `dm-spec.fixture.json` | Canned converter-emission fixture (the audit's `--dm-spec` seam): the FIELD shape — `Daily Distinct Buyers` fuzzy-aliased to a raw `ACTIVE_BUYER_FLAG` column, `Daily Active Sales` emitted nowhere, plus an emitted `Sum([Daily Distinct Buyers])` ratio column (the PR-7 emitted-side trap) |
| `lod-audit.entries.json` | PINNED `audit-lod-calcs.rb` ledger: `suspect-alias` + `silently-dropped` — honest CURRENT-code classification (run 2026-07-18) |
| `agg-semantics.entries.json` | PINNED `audit-agg-semantics.rb` ledger (PR-7): 9 hits — `additive-over-preagg` (SUM over the `{FIXED day: COUNTD}` calcs, source + emitted) and `preagg-ratio` (the ratio KPIs via the "Distinct" name token) |
| `probe-fixture-intdim/` | Offline fixture for the PR-18 cardinality probe (`entry-0.json` → low `distinct`) |
| `checks.sh` | Executable expectations, run by `run-corpus.sh --check` |

## Expected gate behaviors (encoded in checks.sh)

1. **LOD audit** (`audit-lod-calcs.rb`, run against the .twb census + the
   emission fixture): `Daily Distinct Buyers` → **suspect-alias** (emitted
   formula reads `ACTIVE_BUYER_FLAG`, not in the LOD's own reference set
   `{CAL_DATE, BUYER_KEY}`); `Daily Active Sales` → **silently-dropped**.
   Exit 2 with both FATAL blocks. Not guessed: this is what the current
   `lib/lod_audit.rb` classifies, pinned verbatim. (The lod-synth resolved
   path is covered by `scripts/test-lod-audit.rb`.)
2. **Gate 17** (`assert-phase6-ran.rb`, exit 24): blocks GREEN on the
   unresolved ledger; passes after `--resolve 0 --how manual` +
   `--resolve 1 --how waived` record evidence — after which **gate 19**
   (exit 26) takes over: LOD evidence with no `agg-semantics.json` = the
   aggregation lint never ran.
3. **Aggregation-semantics lint (PR-7 — LANDED; the gap this entry was built
   to close)**: `audit-agg-semantics.rb` against the .twb census + the
   dm-spec fixture fires on the three additive KPI formulas — every
   `SUM([Daily Distinct Buyers])` / `SUM([Daily Active Sales])` is
   `additive-over-preagg` (the consumed column is a `{FIXED day: COUNTD}`
   pre-aggregate) and each ratio KPI is `preagg-ratio` (the "Distinct" name
   token in a numerator/denominator) — exit 2, 9 entries pinned verbatim in
   `agg-semantics.entries.json`. Gate 19 (exit 26) blocks until every hit
   records a resolution; the checks resolve the source hits as
   `faithful-to-source` (the twin's story: the SOURCE mixes grains — the
   103.3%-KPI hazard is documented, not silently shipped) and the emitted
   duplicates as `n/a` (first-class — no fabricated metadata), then GREEN
   unblocks.
4. **Dual-axis known-limitation pin**: `parse-twb-layout.rb` reads
   `Amount vs Growth` as `chart_kind: "bar"`, `dual_axis: false` — the twin
   shape carries no `synchronized='true'`, and the current conservative
   detection only fires on explicit synchronization. The check FAILS LOUDLY
   if this ever flips, forcing the MANIFEST + pin update — that flip is the
   acceptance signal for a dual-axis detection fix (PR-10/PR-11 territory).
5. **Integer-coded dimension detection (PR-18 — LANDED; the gap this SITE_KEY
   shape was built to close)**: `parse-twb-layout.rb` flags the integer
   `SITE_KEY` quick filter `integer_dim: true` (shelf role = dimension +
   datatype = integer); a STRING list filter stays unflagged. The OPTIONAL
   warehouse-cardinality probe (`probe-int-dim-cardinality.rb`, fixture mode,
   via PR-4's one-shot-probe runner) confirms the low COUNT(DISTINCT SITE_KEY).
   Downstream, `build-charts-from-signals.rb` routes such a list control's
   filter target + value-source through a `Text([SITE_KEY])` decode column so
   the Sigma control's STRING option values actually filter (a raw numeric
   list-filter target is silently stripped).

## Converter

No golden data model — this case pins the LOD-audit ledger + layout-signal
contracts. Regenerate the pin with:

```
W=$(mktemp -d)
cp corpus/tableau/preagg-kpi/workbook-content.twb "$W/"
cp corpus/tableau/preagg-kpi/dm-spec.fixture.json "$W/dm-spec.json"
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/audit-lod-calcs.rb --workdir "$W"
# then copy the "entries" array of $W/lod-audit.json over lod-audit.entries.json
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/audit-agg-semantics.rb --workdir "$W"
# then copy the "entries" array of $W/agg-semantics.json over agg-semantics.entries.json
```

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "dm-spec.fixture.json", "format": "json"},
    {"path": "lod-audit.entries.json", "format": "json"},
    {"path": "agg-semantics.entries.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
