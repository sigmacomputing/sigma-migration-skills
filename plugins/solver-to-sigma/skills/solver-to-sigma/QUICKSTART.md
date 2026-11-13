# Solver → Sigma — Quickstart

## Offline, on the synthetic fixture (no credentials)

```bash
# from any scratch directory outside the repo; SKILL = the path to plugins/solver-to-sigma/skills/solver-to-sigma
python3 "$SKILL/scripts/convert-solver.py" --definition "$SKILL/fixtures/pnl-smoke/pnl-template.xlsx" \
    --source-map "$SKILL/fixtures/pnl-smoke/source-map.json" --name "Location P&L summary - Data" \
    --folder-id <folder-id> --out dm.json --plan-out plan.json
python3 "$SKILL/scripts/evaluate-solver-local.py" --plan plan.json \
    --facts GL_F_Trans="$SKILL/fixtures/pnl-smoke/gl.csv" --out values.json
python3 "$SKILL/scripts/compare-solver-parity.py" --plan plan.json \
    --run "$SKILL/fixtures/pnl-smoke/pnl-executed-run.xlsx" --values values.json --out parity.json
# parity GREEN: 39 cells compared, 0 mismatches, 0 unmatched, 0 gaps
python3 "$SKILL/tests/test_solver.py"
```

## Live

1. Sign in to Sigma (see the repo's `AGENTS.md` › Credentials; browser OAuth, the Sigma CLI or client credentials).
2. Write `source-map.json` for the customer's warehouse (`refs/source-map.md`), with the Sigma `connectionId`.
3. Run the pre-flight (SKILL.md Phase 1) and stop if the anchors do not match.
4. Convert, POST and read back, build, POST:
   ```bash
   python3 scripts/convert-solver.py --definition report.xlsx --source-map source-map.json \
       --name "<Report> - Data" --folder-id <folder-id> --out dm.json --plan-out plan.json
   python3 scripts/post-solver.py dm --spec dm.json --readback dm-readback.json
   python3 scripts/build-solver-workbook.py --plan plan.json --dm-readback dm-readback.json \
       --name "<Report>" --folder-id <folder-id> --out wb.json
   python3 scripts/post-solver.py workbook --spec wb.json --dry-run
   python3 scripts/post-solver.py workbook --spec wb.json --readback wb-readback.json   # later: --update <id>
   ```
5. Export the report table (and each expanded row) with the run's parameter values (`post-solver.py export`) and
   run `compare-solver-parity.py --sigma-export … --detail-export …` (SKILL.md Phase 6).
