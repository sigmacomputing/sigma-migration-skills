# Lightdash → Sigma — Quickstart

Steps 1–3 are one-time; steps 4–5 are per dashboard. Sigma queries BigQuery in
place; no data is copied.

## 1. Install

Install this plugin and the companion `sigma-authoring` plugin
(`sigma-workbooks` + `sigma-data-models`):

```
/plugin install lightdash-to-sigma@sigma-migration-skills
/plugin install sigma-authoring@sigma-migration-skills
```

## 2. Sign in to Sigma

From the skill directory (`plugins/lightdash-to-sigma/skills/lightdash-to-sigma`):

```bash
export SIGMA_BASE_URL='https://<your-published-sigma-api-host>'
eval "$(bash scripts/browser-login.sh)"
```

## 3. Sigma BigQuery connection (skip if one exists)

Administration → Connections → Create → BigQuery. Enter the billing project and
the service-account JSON. The service account needs **BigQuery Data Viewer** and
**BigQuery Job User**. Verify by browsing a table in Sigma. Note the connection
id (`--connection-id`). Details: `refs/bigquery-dialect.md`.

## 4. Get the Lightdash source

Offline (recommended first run):

```bash
npm install -g @lightdash/cli
lightdash login https://<your-lightdash-url>
lightdash download            # charts + dashboards -> ./lightdash/
```

Also check out the dbt project the Lightdash project is built from and run
`dbt compile` (or `dbt parse`) so `target/manifest.json` exists. Arrange one
source directory:

```
<source-dir>/lightdash/charts, lightdash/dashboards    (from lightdash download)
<source-dir>/dbt/                                       (dbt project + target/manifest.json)
```

Live alternative (no dbt checkout): create a personal access token in
Lightdash (Settings → Personal access tokens) and
`export LIGHTDASH_URL=https://... LIGHTDASH_API_KEY=...`. Live paths are
unvalidated against a real instance.

## 5. Migrate and review

Preview first (posts nothing):

```bash
ruby scripts/migrate-lightdash.rb --source-dir <source-dir> --dashboard <slug> --explore <model> \
  --connection-id <id> --folder-id <id> --workdir run1 --dialect bigquery --dry-run
```

Then the real run (drop `--dry-run`). If the model has row/column security the run
stops at the RLS gate: review `rls-plan.json`, then re-run with `--ack-rls`
(plan reviewed and accepted). The run posts the data model WITHOUT the row filter
and records the planned RLS as a pending escape, so the verdict stays below GREEN.
Afterwards create the Sigma user attribute, add the row filter to the posted data
model, check that a user with no attribute value sees no rows, and record it:
`ruby scripts/apply-sigma-rls.rb --plan <workdir>/rls-plan.json --out <workdir>/rls-steps.json --applied "<who/how verified>"`,
then re-run `scripts/assert-phase6-ran.rb`.

If a data model already covers the model the run stops at the reuse check: re-run
with `--reuse-dm <id>` (build on it) or `--new-dm [REASON]` (create anyway, recorded
as a waiver). A live re-run otherwise creates a new data model and workbook. Review the degradation
ledger (`chart-gaps.json`) and `parity-report.json`; a migration is done only when
parity is green. A fixture to try: `fixtures/jaffle-orders/` (`--explore orders`).
