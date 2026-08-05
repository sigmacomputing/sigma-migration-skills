# powerbi-import-to-snowflake

The **data track** for migrating an Import-mode Power BI model to a
warehouse-native tool (Sigma).

Sigma queries live warehouse tables — it has no in-memory import engine. When a
`.pbix` imports its data from Excel / Power Query / flat files, there is no
warehouse behind it, so the data must be landed first. This skill extracts the
model's source tables and lands them in Snowflake, producing a manifest that the
`powerbi-to-sigma` converter's output repoints onto — with column names aligned
so no remapping is needed.

- **In scope:** Import-mode (or the Import tables of a mixed model) → Snowflake.
- **Out of scope:** DirectQuery models (already on a warehouse); DAX/relationship
  conversion (that's `powerbi-to-sigma`).

See `SKILL.md` for the workflow and `refs/` for the gotchas. `PRIVACY.md`
covers data handling — note this skill moves **row-level data**, unlike the
read-only assessment skills.

Validated end-to-end on Microsoft's public Retail Analysis Sample: 923,371 SALES
rows landed with exact row parity; the converted Sigma data model returned
`$41,013,686.95` total regular sales — matching the Power BI value to the cent.
