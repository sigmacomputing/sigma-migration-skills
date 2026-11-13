# Visual QA (Solver)

Solver reports are printed statements, so the check is line order, labels and column headers rather than chart
styling.

1. Render each rebuilt page: `python3 scripts/sigma-export-png.py --workbook <id> --page <page-id> --out page.png`
   (see the script's `--help` for auth and options).
2. Open the executed run for the same parameters next to it and check:
   - every line is present, in the same order, with the same label (hidden helper rows excepted);
   - column headers match (scenario, period window, variance columns);
   - expanded blocks list the same members;
   - signs read the same way (revenue positive or negative as the business expects).
3. Record differences that are intentional (dropped decoration columns such as `+`/`-` arrows, per-line number
   formats) in the run's notes, and confirm them with the report owner.

A page that renders is not a page that matches: values are checked by `compare-solver-parity.py`, not by eye.
