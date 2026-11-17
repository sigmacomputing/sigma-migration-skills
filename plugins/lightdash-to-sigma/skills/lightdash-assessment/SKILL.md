---
name: lightdash-assessment
description: Inventory a Lightdash instance and produce a migration-readiness readout — environment counts, content mix, complexity, and a value/cost-ranked shortlist. Read-only. Scaffold; not implemented yet.
---

# Lightdash migration assessment (read-only)

**Not implemented yet (scaffold).** Assessments never write to Lightdash or post
to Sigma. Until this skill is built, scope by hand and hand the result to
`lightdash-to-sigma`:

1. Probe access: `ruby scripts/lightdash-discover.rb --probe` (run from the
   `lightdash-to-sigma` skill directory; needs `LIGHTDASH_URL` and
   `LIGHTDASH_API_KEY`).
2. Inventory manually: list dashboards, the charts on each, and the dbt models
   they use; note chart types that are gaps (`lightdash-to-sigma/refs/chart-map.md`),
   table calcs (`refs/table-calcs.md`), and models with `sql_filter` /
   `required_attributes` (`refs/security-rls.md`).
3. Rank by value (usage) over cost (gaps), pick one explore and one dashboard, and
   start the converter.

`scripts/dup-dashboards.py` (scaffolded dedup helper) is not wired in.
