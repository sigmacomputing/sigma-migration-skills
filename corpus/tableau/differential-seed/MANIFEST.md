# tableau / differential-seed

W2.15 differential corpus SEED (10 dialect pairs — the 8–10 scope cut of the
~20-pair full set). Each pair pins one **field-caught dialect-divergence
class** between Tableau's calc dialect and Sigma's: the Tableau formula, the
**recorded output of the current vendored translator** (`sigma_expected` +
verify `warnings`), and per-oracle recording slots. This is **the regression
floor under any future engine flip** (W2.19): the checker re-runs every pair
through the bundle's own translator (the W2.13 probe-the-translator shim), so
an engine that changes ANY pair's translation fails here as a named diff, and
`diff-check.mjs --record` is the reviewed re-baseline path — drift can never
be silent.

Classes pinned (each traces to a live-verified hotfix or WINPROBE validation
recorded in `converter/PROVENANCE.json` / `refs/functions.json`):

| Pair | Class |
|---|---|
| `zn-agg-null-guard` | `ZN(agg)` → native `Zn` (the dominant field null-guard; no malformed Coalesce) |
| `zn-addition-stays-numeric` | numeric `ZN(a)+ZN(b)` keeps `+` (was silent string-concat `&`) |
| `string-guard-concat` | string-literal guard chains still convert `+` → `&` (the other direction) |
| `datetrunc-week-start-drop` | start-of-week 3rd arg dropped WITH a verify warning (was silent drift) |
| `contains-weekday-literal-kept` | the drop is SCOPED — `CONTAINS(x, 'monday')` keeps its literal (no-false-trip twin) |
| `datepart-weekday-numbering` | `DATEPART('weekday')` → `Weekday()` + numbering-verify warning |
| `datename-week-text` | `DATENAME('week')` → `Text(DatePart("week", …))` |
| `share-of-total-pattern` | `agg/TOTAL(agg)` → `PercentOfTotal(…, "grand_total")` (chart context) |
| `window-avg-bounded` | bounded `WINDOW_AVG` → `MovingAvg` chart formula |
| `iif-three-valued` | `IIF` → `If` + quote normalization |

**Three-oracle differential design.** Each pair carries slots for the three
in-repo oracles — VDS (`tableau-vds-to-cdw` evaluates the Tableau side),
ground-truth SQL (statement authored over the neutral synthetic seed table
`DEMO_DB.DEMO.SEED_ROWS(NUM_A, NUM_B, TXT_A, TXT_B, DATE_A, FLAG_A)`), and
the W2.14 batch probe (validates + types the Sigma side, 1 POST for all
pairs). Live recordings are **null (pending)** in the seed and may ONLY land
with provenance (`recorded_at` + `source` version key) — `checks.sh` FAILS a
bare recorded value (red line: version-keyed raw evidence, never fabricated).
The translator differential — fully offline — is the half that runs today.

## Artifacts

| File | What it is |
|---|---|
| `pairs.json` | 10 recorded dialect pairs + oracle slots |
| `diff-check.mjs` | translator-differential checker / `--record` re-baseliner |
| `checks.sh` | Executable expectations (see above) |

## Converter

Not a workbook conversion — `diff-check.mjs` shim-imports the vendored bundle
(`converter/tableau.mjs`, temp copy + appended export shim; the bundle is
never modified) and calls `tableauFormulaToSigma` /
`tableauWindowToSigmaChart` directly, exactly like
`scripts/dev/gen-translation-table.mjs` (W2.13).

## Expectations

```json
{
  "artifacts": [
    {"path": "pairs.json", "format": "json"},
    {"path": "diff-check.mjs", "format": "text"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
