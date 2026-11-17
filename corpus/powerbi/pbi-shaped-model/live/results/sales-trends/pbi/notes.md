# Sales Trends (pbi) notes

- Run: base command + `--model-shape pbi --materialization-cron "0 6 * * *" --page-facts <Trends page summary> --allow-field-loss` (see RUNBOOK 1c).
  `--allow-field-loss`: `Sales R28 by Customer Region` is held back and `Store Region: R28 and sales` drops its R28 field (the rolling window
  and the Sales table are different summaries); the default run exits 10 at the field-loss gate.
- `control-flip-auto.json`: what Phase 6b proved on its own (Customer Region, Store Region, Segment). The two Year entries are UNVERIFIED by design: the
  control reads the Custom SQL page summary, whose values the warehouse-side flip lookup does not list. `control-flip.json`: all five controls flipped
  with explicit `--value` afterwards (Year 2025, Customer Region East, Store Region South, Segment Consumer): 5/5 PASS. Under Year = 2025 the R28 KPI is
  9,281,327.26 and under Customer Region = East 1,940,320.60, both equal to the Power BI DAX values.
- `limits.md` and `pbi-map.md` were regenerated from the finished work directory with the fixed summary-home lookup (they read the auto flip results).

## Rerun (regression check after the later fixes)
Rerun with the saved Trends page summary and `--allow-field-loss` after the no-axis read, density probe, `Sum(If(..., Null))` and DATATABLE literal changes: exit 0, parity 15/15 built charts
(the same two documented not-whole visuals), materialization FRESH for both schedules, control flip 5/5 (Year by explicit `--value`). Density probe ran on the `Sales` fact: month 42 of 42 and quarter 14 of 14
Date-table periods present, not sparse, nothing reclassified, so `limits.md` has no "Time-axis density" section. These files are the rerun's (they replace the first runs').
