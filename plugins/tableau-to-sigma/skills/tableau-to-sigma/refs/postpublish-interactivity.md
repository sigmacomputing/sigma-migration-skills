# Post-publish interactivity guide (POSTPUBLISH_GUIDE.md)

**Disposition: mandatory emit whenever the source has ANY interactivity.**
Sigma's workbook spec cannot express Tableau's dashboard interaction layer —
filter / highlight / URL / navigation actions, parameter and set actions,
dynamic zone visibility, drill hierarchies, custom tooltips, show/hide
buttons. The conversion approximates some of it with controls; the rest used
to be silently dropped. The guide generator closes that gap: it hands the user
a document with exact Sigma UI steps for everything the spec can't carry, so
"workbooks-as-code doesn't support actions" ends with the user guided the
rest of the way, never with lost interactivity.

## When to run

**ALWAYS run the generator when the gap scan or the actions parse detects any
interaction** — i.e. when `scan-workbook-gaps.rb` reports any of:
dashboard filter/highlight/nav actions, parameter actions, drill hierarchies,
show/hide containers, viz-in-tooltip — or when `build-charts-from-signals.rb`
emitted a `*-actions.md` companion (its per-chart `[Action (X)]` view; the
guide is the user-facing superset). Running it on a workbook with zero
interactions is fine and cheap: it emits a minimal "no interactive actions
detected" guide, which keeps the gate check unconditional.

```bash
ruby scripts/build-postpublish-guide.rb \
  --twb  <workdir>/workbook-content.twb \
  --out  <workdir>/POSTPUBLISH_GUIDE.md \
  --wb-ids   <workdir>/wb-ids.json \          # AFTER the POST — names real elements
  --json-out <workdir>/postpublish-guide.json \
  --sigma-url "https://app.sigmacomputing.com/<org>/workbook/<id>"
```

Run it (or re-run it) **after** the workbook POST so `--wb-ids` resolves
Tableau sheet/dashboard/parameter names to the built Sigma elements, pages,
and controls — a guide that says "the control 'Select Metric' replaces this
parameter action" beats one that makes the user hunt. Pre-POST runs (no
`--wb-ids`) are valid for scoping; regenerate with ids before finalize.

## Gate contract

`<workdir>/POSTPUBLISH_GUIDE.md` — that exact filename, in the workdir — is
load-bearing: **when actions are detected in the .twb, the file must exist
before the conversion may declare GREEN (`assert-phase6-ran.rb` enforces
this).** The generator always writes the file (zero-action workbooks get the
minimal guide), so the safe pattern is simply: run the generator during Phase
6 wrap-up, unconditionally. Do not rename the output or write it anywhere but
the workdir.

The `--json-out` sidecar (`postpublish-guide.json`) is the machine-readable
form: `[{kind, caption, source, targets, fields, sigma_status, ui_steps,
notes}]` with `sigma_status` ∈ `ui-configurable` |
`control-equivalent-built` | `no-equivalent`. Downstream tooling (report
generation) reads this instead of scraping the markdown.

## The report must walk the user through it

The final conversion report (MIGRATION_REPORT.md / the agent's closing
summary) **must LINK the guide and walk the user through what's in it** —
e.g. "12 Tableau interactions need post-publish attention: 3 filter actions
(add via 'Use as filter'), 8 parameter actions (already built as controls —
verify), 1 highlight action (no Sigma equivalent — closest pattern inside).
Work through POSTPUBLISH_GUIDE.md's checklist." Silently dropping
interactivity — or burying it as a footnote — is a report defect: the user
must leave the conversion knowing exactly which interactions survived as
controls, which they can add in the UI, and which have no equivalent.

## Truthfulness rule

The guide states only verified Sigma UI step patterns ('Use as filter',
Button → 'Navigate to page', drill down, tooltip fields); anything uncertain
is tagged "verify in your Sigma version", and features with no equivalent
(cross-element highlight, viz-in-tooltip, show/hide toggles, dynamic zone
visibility, sets) say so plainly with the closest shipped pattern. When
editing the generator, never add a UI claim you have not verified against a
live Sigma build — truthfulness over completeness.

## Tests

`ruby scripts/test-postpublish-guide.rb` — offline, creds-free (committed
`test-fixtures/postpublish-*.twb`): per-kind detection counts, caption/GUID
resolution, wb-ids enrichment, verified step strings, and the zero-action
gate contract.
