# Lightdash security → Sigma (RLS / CLS)

Lightdash enforces access in the semantic layer (dbt `meta`). `convert-dm.rb`
does **not** apply it; it records it in the envelope's `security` block, and the
C9 gate (`detect-rls.rb`) turns it into a Sigma plan.

## Mechanisms

| Lightdash | Sigma |
|---|---|
| Model `sql_filter` of the form `${TABLE}.col IN (${lightdash.attributes.X})` or `col = ${ld.attr.X}` (either attribute alias; optional quotes, parens, `${model.col}`) | User attribute `X` + a **data-model row filter** on that model's DM element: `[<Column>] in user attribute X` |
| Model `required_attributes` / `any_attributes` | `column_security` entry: whole-element access gating |
| Dimension `required_attributes` / `any_attributes` | `column_security` entry: column-level security on the explore column |
| Any other `sql_filter` shape (several conditions, functions, no attribute) | **Not translated**: `scope-cut` ledger gap, gate exit 3 |

Lightdash fails **closed**: a user with no value for the attribute sees no rows.
The Sigma filter must behave the same; verify with a user that has no value
for the attribute. The row filter sits on the DM element (not the workbook), so
every workbook built on the DM inherits it. A joined model's filter yields blank
lookups for restricted rows, not removed explore rows.

## Gate: `detect-rls.rb`

```bash
ruby scripts/detect-rls.rb --envelope dm.json --out rls-plan.json [--ack] [--ack-complex REASON] [--no-gate]
```

| Exit | Meaning |
|---|---|
| 0 | no row/column security; or the plan was acknowledged with `--ack` (and nothing untranslatable); or `--no-gate` (report only, used by `--dry-run`) |
| 2 | security exists and `--ack` was not given |
| 3 | an untranslatable `sql_filter` exists; `--ack` alone does not cover it |

A waiver of an untranslatable filter needs **both** `--ack` and
`--ack-complex REASON` (orchestrator: `--ack-rls` and `--ack-rls-complex REASON`).
`apply-sigma-rls.rb` then still plans the translatable parts, writes a
`recorded-escape` ledger entry per waived filter to `rls-gaps.json`, merges it
into `chart-gaps.json`, and appends a `skip-flag-waived` record to
`offramps.jsonl` (what the verdict reads). **A waived run can never be GREEN.**

## Applying

```bash
ruby scripts/apply-sigma-rls.rb --plan rls-plan.json --out rls-steps.json
ruby scripts/apply-sigma-rls.rb --plan rls-plan.json --out rls-steps.json --apply --confirm
```

Default is plan-only. `--apply` needs a Sigma token and `--confirm`, and still
creates nothing: attribute *values* are never invented, so it records
`apply-ready` and leaves creating the user attribute and the DM row filter to a
human (exit 2 when refused, 3 when the plan has untranslated gaps and no
waiver). Do not share the workbook with users before the row filter is in place.
`${lightdash.parameters.*}`, Liquid and subquery filters are gaps by design.

## Pending until applied

Because no script creates the row filter, every plan with `row_filters` or
`column_security` leaves one `skip-flag-waived` record per planned step in
`offramps.jsonl` (`RLS planned, NOT applied: ...`). The verdict is never GREEN
while one exists. After the filter is on the DM and a user with no attribute
value was verified to see no rows, run
`apply-sigma-rls.rb --plan rls-plan.json --out rls-steps.json --applied "<evidence>"`
(or pass `--rls-applied "<evidence>"` to `migrate-lightdash.rb`); that clears the
pending records and stores the note in `rls-steps.json`.
