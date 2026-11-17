---
name: lightdash-to-sigma
description: Convert a Lightdash dbt semantic layer plus its charts and dashboards into a Sigma data model and matching workbook. Use when migrating Lightdash content to Sigma, offline from `lightdash download` plus the dbt project, or live through the Lightdash API with a personal access token. Includes RLS gate and warehouse parity.
---

# Lightdash → Sigma

**Maturity: foundation.** The offline path (dbt project + `lightdash download`
files) is tested on a synthetic fixture. Live discovery, the Lightdash parity
oracle and the Sigma writes are coded against the documented APIs but
**unvalidated against a real Lightdash instance or a live Sigma POST**.
Unverified items to check on the first real run: the Lightdash `/code`
response envelopes, compiled-explore key names and `runQuery` row shape;
Sigma function names `Len`, `Mid`, `Ceiling`, `Greatest`, `Least`, `SplitPart`,
`DayOfYear`, `NullIf`, `Between`, `IsNotNull`, `Now`, `Today`, `PercentileCont`,
`Date(...)` on text dates, and the `%` operator; the DM `relationshipType`
value `"1:N"`; title-case column naming (`Order Date Month`); `[Metrics/<name>]`
resolving through the chart → base → master → DM chain; top-n on bar/line
charts; date/number range control shapes; the Lightdash 36-column grid width;
the Lightdash v1 `runQuery` endpoint (v2 async query endpoints exist and may
replace it); `tileTargets` default-targeting semantics.

One Lightdash explore (a dbt model plus its joins) → one Sigma data model; one
dashboard (+ its charts) → one workbook. Unsupported constructs are recorded as
degradation-ledger gaps, never guessed. Presentation-only differences (ECharts styling,
big-number comparison) and verification caveats are **notes** (`chart-gaps.json`
`notes`, plus warnings), not ledger entries: they never block GREEN. Anything that
changes data, grain, filters, sorting, limits or security, or drops an item, is a
ledger entry.

<!-- mandatory-pre-read -->
Read before converting:

- `refs/lightdash-source-contract.md`
- `refs/chart-map.md`
- `refs/security-rls.md`
<!-- /mandatory-pre-read -->

Also: `refs/table-calcs.md` (gaps) and `refs/bigquery-dialect.md` (warehouse).

## Auth

Lightdash (live only): `LIGHTDASH_URL` (e.g. `https://app.lightdash.cloud`) and
`LIGHTDASH_API_KEY` (a personal access token, sent as `Authorization: ApiKey`).
Offline runs need neither. Sigma, from this skill directory (interactive
browser OAuth; the refresh session lives only in the OS keychain):

```bash
export SIGMA_BASE_URL='https://<your-published-sigma-api-host>'
eval "$(bash scripts/browser-login.sh)"
```

Alternatives: a signed-in Sigma CLI (`sigma auth login`, optional
`SIGMA_CLI_PROFILE`), or for CI `SIGMA_CLIENT_ID` + `SIGMA_CLIENT_SECRET`.
Never print tokens or commit `auth.json`.

## One command

Sequences C2 → C9 and aborts on the first gate failure (`FATAL: <phase>`):

```bash
ruby scripts/migrate-lightdash.rb --source-dir <dir> --dashboard <slug> --explore <model> \
  --connection-id <id> --folder-id <id> --workdir <dir> --dialect bigquery [--ack-rls]
# live source instead of --source-dir:
ruby scripts/migrate-lightdash.rb --project <uuid> --dashboard <slug|uuid> --explore <model> ...
```

`--dry-run` runs only the offline steps (convert-dm, RLS plan, workbook build
with a placeholder DM id), prints the calls it would make and posts nothing;
`--dry-run` also makes the RLS gate report-only. `--ack-rls` /
`--ack-rls-complex REASON` are C9 below. With Lightdash credentials set,
`--project` is required (error otherwise). With no credentials parity is
**warehouse-only** and the run prints a loud warning (the result is not compared
with Lightdash). Sigma reuse, post and parity steps need a Sigma sign-in.

**Reuse and re-runs.** The reuse check always scans the org. A strong match
STOPS the run (`FATAL: reuse-check`) so a duplicate DM is never posted silently:
re-run with `--reuse-dm <id>` (nothing is posted to that DM; the workbook is built
on it after its columns/metrics are read back by name) or `--new-dm [REASON]`
(create anyway; recorded as a waiver, so the verdict is never GREEN). No match =
create. A live re-run creates a NEW data model and workbook each time unless you
pass `--reuse-dm <id>` for the DM the first run posted.

## Phase 0 — Assess (C1)

Scope with `lightdash-assessment` (scaffold: not implemented; see its SKILL.md).
Pick one explore and one dashboard first. Check `refs/chart-map.md` and
`refs/table-calcs.md` for what will land as gaps.

## Phase 1 — Discover (C2)

Offline: `<source-dir>` holds `lightdash/charts`, `lightdash/dashboards` (from
`lightdash download`) and the dbt project (`dbt/`, with `dbt/target/manifest.json`
from `dbt compile` or `dbt parse`). Live (no dbt checkout):

```bash
ruby scripts/lightdash-discover.rb --probe
ruby scripts/lightdash-discover.rb --project <uuid> --dashboard <slug|uuid|name> --out-dir discovery
```

Writes the same layout offline mode reads plus `explores/<id>.json` and
`manifest.json`. Convert live output with `--explores-dir discovery/explores`.

## Phase 1.5 — Reuse-check (C3)

`convert-dm.rb` writes `lightdash-signature.json`. Before creating a DM, score
existing Sigma DMs and reuse on a strong match (avoid sprawl):

```bash
ruby scripts/find-or-pick-dm.rb --workbook-signature lightdash-signature.json --auto-pick --refresh --out dm-match.json
```

Exit 0 = a candidate (`recommended_dm_id` in `dm-match.json`), exit 1 = none (the
file is still written). The orchestrator reads the file, writes `dm-mode.json`
(`create` or `reuse`) and stops on a match until you choose `--reuse-dm` / `--new-dm`.

## Phase 2 — Convert (C4)

```bash
ruby scripts/convert-dm.rb --source-dir <dir> --explore <model> \
  --connection-id <id> --folder-id <id> --out dm.json [--dialect bigquery]
# or: --explores-dir discovery/explores   (live path, no dbt checkout)
```

Outputs the envelope `{sigmaDataModel, stats, warnings, gaps, security, dialect,
explore}` plus `field-map.json` (Lightdash fieldId → Sigma column/metric; the
builder's only interface) and `lightdash-signature.json`. Shape: one
warehouse-table element per model, relationships from `meta.joins`, and one
"<Label> (Explore)" element holding every column and metric. BigQuery: 3-part
paths, case preserved (`refs/bigquery-dialect.md`). RLS is recorded under
`security`, not applied.

## Phase 3 — Post the data model + read back (C5) ← HARD GATE

```bash
ruby scripts/post-lightdash-dm.rb --spec dm.json --out dm-elements.json
```

POSTs `/v2/dataModels/spec` (PUTs in `extend` mode, writes nothing in `reuse` mode,
via `--mode dm-mode.json`), then **reads back** the live spec and exits 1 if an
authored element/column/metric (paired **by name**) is missing, counts differ
(not in reuse mode, where inherited extras are fine) or a column reads back
error-typed. The lookup (`dm-elements.json`) maps authored ids
to live ids. Never wire the workbook to client-side ids after a live POST.

## Phase 4 — Build the workbook (C6)

```bash
ruby scripts/build-lightdash-workbook.rb --dashboard <dir>/lightdash/dashboards/<slug>.yml \
  --charts-dir <dir>/lightdash/charts --dm-envelope dm.json --field-map field-map.json \
  --dm-id <read-back-dm-id> --dm-lookup dm-elements.json --folder-id <id> \
  --out wb.json --workbook-map-out workbook-map.json
ruby scripts/post-lightdash-workbook.rb --spec wb.json --out wb-ids.json   # --dry-run to preview
```

Hidden **Data** page with master table `tbl-master`; per-`tileTargets` base
tables `tbl-base-N`; controls target tables only (Sigma rejects chart/KPI
control targets). Charts source from those tables. Sidecars: `workbook-map.json`
(`element_id`, `source_element_id`, `applied_filters`), `chart-gaps.json`,
`control-scope.json`. Unmapped chart types become placeholders plus ledger
entries. Layout, control and preflight lints must pass or the builder exits 9.
Details: `refs/chart-map.md`.

## Phase 5 — Layout (C7)

The builder attaches the layout XML as the **last write**, after every element id
is final. A later spec PUT that omits `layout` wipes it: resend the layout.
Then visual-QA the exported PNG (`refs/layout-visual-qa.md`,
`scripts/sigma-export-png.py`).

## Phase 6 — Verify parity (C8) ← HARD GATE, never skip

```bash
ruby scripts/lightdash-query-oracle.rb --project <uuid> --workbook-map workbook-map.json \
  --charts-dir discovery/lightdash/charts --field-map field-map.json --out-dir expected
ruby scripts/verify-lightdash-parity.rb --workbook-id <id> --workbook-map workbook-map.json \
  --expected-dir expected --out parity-report.json --final-out parity-final.json
ruby scripts/assert-phase6-ran.rb --workdir <dir> --workbook-id <id> \
  --skip-visual-gate "lightdash-to-sigma v1 - no Lightdash UI render capability"
```

The oracle runs each chart's `metricQuery` against Lightdash, merging the
dashboard filters Sigma applies as defaulted controls (`applied_filters`), and
saves rows plus compiled SQL. It exits 3 if a `runQuery` fails or a non-placeholder
chart is skipped. Verify compares the visible chart element's export to those
rows: per-chart PASS / FAIL / SKIP; a non-placeholder chart with no oracle rows
**FAILS**; limit results whose sort is not a total order SKIP as nondeterministic. Without Lightdash
credentials use `--warehouse-only` (elements evaluate against the warehouse,
`verified_against=warehouse`; not a Lightdash comparison). Exit 0 PASS, 2 FAIL.
A migration is not done until parity is green and `assert-phase6-ran.rb` passes.

## Security: RLS / CLS (C9)

```bash
ruby scripts/detect-rls.rb --envelope dm.json --out rls-plan.json [--ack] [--ack-complex REASON]
ruby scripts/apply-sigma-rls.rb --plan rls-plan.json --out rls-steps.json
```

Gate exit: 0 none/acknowledged, 2 security present without `--ack`, 3 an
untranslatable `sql_filter`. A waiver needs **both** `--ack-rls` and
`--ack-rls-complex REASON`; it is recorded as an offramps `skip-flag-waived`,
shows as `recorded-escape`, and the verdict is **never GREEN**. `sql_filter` →
Sigma user attribute + DM row filter (fail-closed); `required_attributes` → CLS.
Apply is opt-in (`--apply --confirm`) and never invents attribute values.
The skill does **not** create the DM row filter, so any planned row filter /
column rule is recorded as a pending escape ("RLS planned, NOT applied") and the
verdict is never GREEN until you apply it on the DM, verify with a user that has
no attribute value (must see no rows) and record it with
`apply-sigma-rls.rb --plan rls-plan.json --out rls-steps.json --applied "<evidence>"`
(or `--rls-applied` on the orchestrator), which clears the pending record.
Details: `refs/security-rls.md`.

## Gaps

Unsupported source features go in the ledger (`chart-gaps.json`) and
`python3 scripts/escalate-gap.py` (opt-in issue filer). Never fake a feature.
Known gaps: table calcs beyond arithmetic, `percent_of_total` / running-total
metrics, custom dimensions, parameters, Liquid, window SQL, `sql_chart`,
treemap/gauge/map/sankey/custom charts, Lightdash spaces and permissions. See
`refs/table-calcs.md`.
