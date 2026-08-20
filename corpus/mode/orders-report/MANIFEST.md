# mode / orders-report

Synthetic Report: 2 Queries (revenue trend, region breakdown) each with 1
Chart (Line, Bar), against a fictional `widget_orders` table (no real
warehouse schema — this fixture is purely synthetic, no live Mode/Sigma
connection required).

## Artifacts

| File | What it is |
|---|---|
| `../../../plugins/mode-to-sigma/skills/mode-to-sigma/test/fixtures/report-fixture.json` | mode-discover.rb-shaped Report: 2 Queries (`Monthly Revenue`, `Region Revenue`, 2 columns each), 2 Charts (Line, Bar), 0 Report Filters |
| `fixtures/dm-elements.json` | hand-authored `{query_token => {dataModelId, elementId, name, columns}}` map standing in for `post-dm.rb`'s real POST+readback (Task 6) — this corpus case is offline, so there is no live DM to read back. `columns` (added in the final-review fix wave) is the per-column `{raw field id -> DM display name}` list `post-dm.rb`'s readback now captures, letting `build-mode-workbook.rb` bind chart formulas to the real DM display name instead of the raw SQL alias |
| `checks.sh` | offline reconvert + schemaVersion assertion (see below) |

## Features exercised

- `sql`-kind DM element construction from a live-sampled column list
  (`build-dm.rb`)
- Line chart and Bar chart type mapping (`ModeChartMap.sigma_kind_for`)
- Hidden Data page (one table element per Query) + visible Report page
  (one chart per Mode Chart, notebook-flow layout) via `build-mode-workbook.rb`
- Chart columns formula-bound from the view's `x`/`y` field names, not shipped
  empty
- No Report Filters → `param-gaps.json` and `chart-column-gaps.json` both
  empty, no RLS/control-lint noise
- (final-review fix wave) DM element self-reference columns use the fixed
  `[Custom SQL/<raw column>]` sentinel, never the element's own authored name
  (`golden/data-model.json`'s column formulas)
- (final-review fix wave) chart columns reference the DM's real column
  DISPLAY NAME (e.g. `[Monthly Revenue/Order Month]`), looked up from
  `fixtures/dm-elements.json`'s `columns[]`, never the raw SQL alias
  (`[Monthly Revenue/order_month]` would be wrong)
- (final-review fix wave) both specs carry `schemaVersion: 1` — asserted by
  `checks.sh`, not visible to the plain goldens counts check

## Converter

```
cd plugins/mode-to-sigma/skills/mode-to-sigma
ruby scripts/build-dm.rb --report-json test/fixtures/report-fixture.json \
  --connection-id conn-test --folder-id folder-test --out /tmp/mode-dm.json --skip-reuse-check
```

Second step — the workbook, wired to the DM element ids a real run would only
learn after `post-dm.rb`'s POST+readback (Task 6). Offline, this corpus case
supplies those ids via the hand-authored `fixtures/dm-elements.json` above
instead of hitting a live Sigma org:

```
cd plugins/mode-to-sigma/skills/mode-to-sigma
ruby scripts/build-mode-workbook.rb --report-json test/fixtures/report-fixture.json \
  --dm-elements ../../../../corpus/mode/orders-report/fixtures/dm-elements.json \
  --folder-id folder-test --out /tmp/mode-wb.json
```

Then normalize both outputs:

```
python3 corpus/lib/corpus_check.py normalize /tmp/mode-dm.json > corpus/mode/orders-report/golden/data-model.json
python3 corpus/lib/corpus_check.py normalize /tmp/mode-wb.json > corpus/mode/orders-report/golden/workbook.json
```

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/mode-to-sigma/skills/mode-to-sigma/test/fixtures/report-fixture.json", "format": "json"},
    {"path": "fixtures/dm-elements.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1, "elements": 2, "columns": 4, "metrics": 0, "relationships": 0, "warnings": 0,
      "element_names": ["Monthly Revenue", "Region Revenue"]
    },
    "workbook.json": {
      "pages": 2, "elements": 4, "columns": 4, "metrics": 0, "relationships": 0, "warnings": 0,
      "element_names": ["Monthly Revenue", "Region Revenue", "Monthly Revenue Trend", "Revenue by Region"]
    }
  }
}
```
