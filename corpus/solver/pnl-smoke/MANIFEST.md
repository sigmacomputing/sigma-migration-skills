# solver / pnl-smoke

Synthetic Solver report: a one-sheet location P&L (the shape of a Live Reporting Download, with the definition
embedded as `customXml/item1.xml` in UTF-16), its executed run, a Solver-shaped GL extract and a neutral source
map. Exercises a Report-level parameter filter (`{@Location}` = `*`), Column filters (scenario parameters
including a comma list, `{@Period}` and `PeriodCalc.GetFunction(YTD, @Period)`), Row filters (code ranges,
`AndNot`, `Contains`), signed `OSRGet` cells including the `_xll.OneStop.ReportPlayer.OSRFunctions.` prefix,
`IFERROR`, sheet subtotals, a ratio line, variance and variance-% columns, and an expanded row grouped by account.
The executed-run values come from an independent oracle in `make_fixtures.py`, not from the converter. No tokens,
no customer names.

## Artifacts

Plugin fixtures under `plugins/solver-to-sigma/skills/solver-to-sigma/fixtures/pnl-smoke/` (regenerate with
`python3 fixtures/pnl-smoke/make_fixtures.py`). The two `.xlsx` workbooks are not listed as artifacts because
the structural check reads artifacts as text; `checks.sh` and the plugin's `tests/test_solver.py` open both.

## Converter

```bash
python3 scripts/convert-solver.py --definition fixtures/pnl-smoke/pnl-template.xlsx \
  --source-map fixtures/pnl-smoke/source-map.json --name "Location P&L summary - Data" \
  --folder-id fixture-folder --out dm.json --plan-out plan.json
python3 scripts/build-solver-workbook.py --plan plan.json --dm-readback <dm.json spec + dataModelId> \
  --name "Location P&L summary" --folder-id fixture-folder --out wb.json
```

Run from the `solver-to-sigma` skill directory. `checks.sh` byte-diffs both goldens after id normalization, runs
the local evaluator and requires parity GREEN against the executed run (and RED for a wrong period), checks the
`.manifest` refusal, and runs the estate assessment.

## Expectations

```json
{
  "artifacts": [
    {
      "path": "../../../plugins/solver-to-sigma/skills/solver-to-sigma/fixtures/pnl-smoke/gl.csv",
      "format": "text"
    },
    {
      "path": "../../../plugins/solver-to-sigma/skills/solver-to-sigma/fixtures/pnl-smoke/source-map.json",
      "format": "json"
    },
    {
      "path": "checks.sh",
      "format": "text"
    }
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 6,
      "columns": 11,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0,
      "element_names": [
        "Summary lines",
        "Summary detail row 14",
        "Period",
        "Actual Scenario",
        "Budget Scenario",
        "Location"
      ]
    },
    "workbook.json": {
      "pages": 1,
      "elements": 7,
      "columns": 11,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0,
      "element_names": [
        "id0003",
        "Period",
        "Actual Scenario",
        "Budget Scenario",
        "Location",
        "Summary",
        "Revenue by account (row 14)"
      ]
    }
  }
}
```
