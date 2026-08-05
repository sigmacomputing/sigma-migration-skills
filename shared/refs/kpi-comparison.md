# Comparative KPI cards — the house default

Verified spec-authorable and readback-stable (live-verified 2026-07-27): a `kpi-chart`
element carrying **both** a `value` column and a `comparisonColumn` renders a number plus
a Δ badge, and both survive `POST /v2/workbooks/spec` → `GET .../spec` unmodified. This
supersedes any earlier "comparison is UI-only / stripped on readback" guidance for this
exact shape — build comparative, don't retrofit later.

## The shape

```yaml
id: kpi-revenue
kind: kpi-chart
name:
  text: Revenue
  color: '#0B3D2E'          # kpi-chart name.color IS honored (see gotcha below)
source:
  kind: table
  elementId: kpi-source
columns:
  - id: rev_current
    formula: '[KPI Source/Current Revenue]'
    name: Current Revenue
    format: { kind: number, formatString: '$.3~s' }
  - id: rev_prior
    formula: '[KPI Source/Prior Revenue]'
    name: Prior Revenue
value:
  columnId: rev_current        # value.columnId, NOT value.id
comparisonColumn:
  columnId: rev_prior
comparison:
  display: delta
  colorGood: '#1a7f37'
  colorBad: '#cf222e'
```

Emit this with `shared/lib/kpi_card.rb` (`KpiCard.build`) / `shared/lib/kpi_card.py`
(`kpi_card.build`) rather than hand-rolling the Hash — both twins are golden-tested for
byte-identical output and already encode every gotcha below. Every migration builder and
every authoring flow should point at this one emitter instead of re-deriving the shape.

## Gotchas

- **`value.columnId`, not `value.id`.** The live API 400s on `value.id`
  (`"Invalid string: undefined"`).
- **`comparisonColumn: { columnId }`** is a separate top-level block from `value`, pointing
  at the prior/target column. `comparison: { display: "delta", colorGood, colorBad }`
  controls the Δ badge's colors — the emitter's `good_direction` flips which color means
  "good" (e.g. for a cost metric where down is good).
- **`name.color` on the `kpi-chart` element IS honored.** A `text` *element*'s
  `style.color` is not — don't conflate the two when styling a title.
- **Format via a format object** (`{ kind: number, formatString: '$.3~s' }`), never a
  hard-coded divisor/suffix baked into the formula. The format object re-scales
  automatically as the value crosses magnitude boundaries; a hard-coded `/1000` + a
  literal `"K"` suffix silently goes wrong the moment a number crosses into millions.
- **KPI sub-elements are often not individually exportable (404).** To verify a KPI's
  bound numbers, export the *source table* element, not the KPI element itself.
- **All headline numbers on one page should share one scope.** When several comparative
  KPIs sit on the same dashboard, back them all with the same filtered source/control
  scope — mixing a globally-filtered KPI with an unfiltered one produces deltas that look
  wrong even when each number is individually correct.
- **Ratio-type KPIs (a margin %, a conversion rate) need care, especially with fake
  example data.** Compute the ratio as `Sum(numerator)/Sum(denominator)` over each period
  — never as an average of per-row ratios, which silently misweights unequal denominators.
  When picking illustrative current/prior numbers for a mock or exemplar, keep the swing
  plausible (e.g. 31.2% → 33.8%, not 5% → 90%) — an unrealistic ratio delta undermines the
  exemplar's credibility and can misleadingly read as a real customer's figure.

## Verified 2026-07-27

Live E2E proof (`shared/scripts/verify-kpi-comparison-e2e.rb`): POST → export the source
table → GET readback — `comparisonColumn.columnId` intact and correct, `comparison.display
== "delta"`, colors intact. See
`plugins/sigma-authoring/skills/sigma-workbooks/reference/specification/kpis.md` for the
full KPI element reference and
`plugins/sigma-authoring/skills/sigma-workbooks/examples/comparative-kpi-card.yaml` for a
clone-able fragment.
