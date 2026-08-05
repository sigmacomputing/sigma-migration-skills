# tableau / param-default-controls

W2.17 fixture: true parameter defaults. A synthetic (neutral-name) workbook
whose Parameters datasource exercises every control branch of the converter's
parameter emission — both directions:

- **defaults applied** (the .twb carries a current value):
  - `Region Pick` — list param, current `"West"`, member alias (`West` → `Western`)
    → list control with `values: ["West"]` (labels preserved)
  - `As Of Date` — date param, current `#2024-06-01#`
    → `controlType: "date"`, `mode: "="`, `value: "2024-06-01"` (was: hardcoded
    date-range last-90 regardless of the workbook's value)
  - `Top Limit` — integer param, current `25` → `controlType: "number"`,
    `mode: "="`, `value: 25` (was: valueless number-range)
  - `Name Match` — string param, current `"ACME"` → text control with `value`
- **fail-open preserved** (no current value in the .twb — behavior unchanged):
  - `Rate Band` — real param with a range domain → number-range, no value
  - `Cutoff Date` — date param without a value → date-range last-90 + the
    "adjust in Sigma UI" warning

Warnings name every applied default ("from the workbook's current value") so
the report shows where parity comes from.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | Synthetic workbook XML: 6 parameters + one snowflake table datasource |
| `checks.sh` | Executable expectations: converter↔golden lockstep (node-guarded) + both-directions W2.17 pins |

## Converter

Vendored bundle (`plugins/tableau-to-sigma/.../converter/tableau.mjs`)
`convertTableauToSigma` with `xml_content=<workbook-content.twb>`,
`datasource_index=0`, empty connection/database/schema. Golden generated from
the vendored bundle (which carries the W2.17 local patch — see
`converter/PROVENANCE.json` `local_patches`), normalized via
`corpus/lib/corpus_check.py normalize`.

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 7,
      "columns": 3,
      "metrics": 1,
      "relationships": 0,
      "warnings": 7,
      "metric_names": ["Net Revenue"]
    }
  }
}
```
