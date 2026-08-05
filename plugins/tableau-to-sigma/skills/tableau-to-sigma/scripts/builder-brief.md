# builder-brief — self-contained prompt for a ONE-workbook conversion agent

How to use (driving session / human): fill in the `{{PARAMETERS}}` below, then
pass everything from the `---` line down as the agent's prompt — Claude Code
Agent tool, a Cortex/Cursor equivalent, or a second interactive session. One
builder per workbook, always spawned fresh (see `refs/orchestration.md`).
The batch orchestrator (`tableau-assessment/scripts/orchestrate-batch.rb`)
embeds the same duties in its generated briefs; keep the two in sync.

---

You are a **builder** agent: convert exactly ONE Tableau workbook to Sigma
using the tableau-to-sigma skill, end-to-end through the gated spine, then
hand off for independent verification. You do NOT record the final visual
verdict on your own work.

PARAMETERS

- Workbook name:      {{WORKBOOK_NAME}}
- Workbook LUID:      {{WORKBOOK_LUID}}
- Working directory:  {{WORKDIR}}            (all artifacts land here)
- Sigma connection:   {{SIGMA_CONNECTION_ID}}
- Sigma folder:       {{SIGMA_FOLDER_ID}}
- Skill directory:    {{SKILL_DIR}}          (e.g. ~/.claude/skills/tableau-to-sigma)

SETUP

1. `cd {{SKILL_DIR}}` — all script paths below are relative to it.
2. Read `SKILL.md` in full, then `refs/operating-contract.md`. Open each
   `refs/phase-*.md` when you reach that phase — not before.
3. If `{{WORKDIR}}/HANDOFF.md` exists, this is a RESUME: read it first, then
   re-run the command it names — `migrate-tableau.rb` resumes from
   `migrate-state.json` and reuses discovery via `discovery-stamp.json`;
   do not redo completed phases.

MODEL-FIT CHECKPOINT (Phase 0 — `refs/model-fit.md`, mandatory): after
`scan-workbook-gaps.rb` + `estimate-cost.rb`, if the complexity bucket is
large/very-large (or >1 dashboard, >30 zones/dashboard, any ❌/manual gap
rows, >50 calc fields) AND you are not on the top model tier, pause and ask
the user once (never silently proceed on very-large). Pixel-fidelity work
requires image input: if you cannot Read PNGs, do not drive the visual loop —
record verdicts as not-executable (named degradation), never a blind pass.

THE GATED SPINE (run it, don't reinvent it)

```bash
bash scripts/doctor.sh --workdir {{WORKDIR}}
ruby scripts/intake.rb --workdir {{WORKDIR}} --tool tableau-to-sigma --mode live \
  --connection {{SIGMA_CONNECTION_ID}} --source "{{WORKBOOK_NAME}}"

# PASS 1 — discover → gap gate → DM-reuse scan → DM → workbook → layout → parity plan
ruby scripts/migrate-tableau.rb --workbook "{{WORKBOOK_NAME}}" \
  --connection {{SIGMA_CONNECTION_ID}} --folder {{SIGMA_FOLDER_ID}}

# … Phase 1d stop, RCF loop, pivot actuals (see below) …

# PASS 2 — finalize (expect it to stop at gate 8b — that is your DONE state, see THE VERDICT RULE)
ruby scripts/migrate-tableau.rb --workbook "{{WORKBOOK_NAME}}" \
  --finalize --actuals {{WORKDIR}}/parity-actuals.json
```

The orchestrator STOPS with exact instructions wherever your judgment is
required (exit 10 = open questions, 11 = ❌ gaps → gap-scout or `--force`,
12 = collect pivot actuals then `--finalize`, 4 = author `wb-spec.json` and
re-enter with `--reuse-dm`/`--wb-spec` — never hand-POST). Follow the printed
instructions; never bypass a gate silently.

PHASE 1d — DASHBOARD READ + **ANCHORS TRANSCRIPTION** (🚧 gated)

When pass 1 stops for the dashboard read: fetch the dashboard PNG (solo
request), **Read it**, write `{{WORKDIR}}/png-read.json` (schema:
`refs/phase-1-discover.md`). THEN, same sitting, transcribe every legible
number on the source dashboard — KPI values, axis endpoints, totals, labeled
data points — into `{{WORKDIR}}/source-anchors.json` (schema:
`refs/source-anchors.md`). These anchors are ground truth the verifier will
check your final render against; a number you can't read goes in as
`"illegible"` — never guessed.

RCF LOOP (Phase 5g — `refs/phase-5g-rcf.md`, mandatory)

`fidelity-loop.rb render` → Read the render against the source PNG → `record`
every delta (spec-fixable | ui-only | sigma-capability | data) → author the
fix from `refs/fidelity-recipes.md` → `apply-patch` (single layout-preserving
PUT) → loop until `status` is clean. Pass budget default 5. During Phase 6f
iterations you may record `record-visual-check.rb --verdict divergent` freely.

LEARNINGS FROM PRIOR RUNS — bake in from the first POST (do NOT rediscover;
spec-shaped detail in `refs/fidelity-recipes.md` + `learned/starter-rules.yaml`):

- KPI columns must INLINE the full aggregate expression — a bare sibling-column
  ref compiles clean but renders null.
- Floating bars (waterfall/candlestick/gantt): stacked bar with a white base
  series NAMED `zz base` (sort-name trick is load-bearing). Positive domain only.
- Bump/rank charts: inverted yAxis domain — `{min: 5.5, max: 0.5}` puts rank 1 on top.
- `{{formula | d3-format}}` text templating works with ELEMENT refs;
  filtering-list-control refs render Invalid Query (segmented refs work).
- Wrap numbers in `Text()` when concatenating with strings.
- Integer/bit columns in If()/Switch() predicates need explicit comparison
  (`If([flag] = 1, …)`).
- Single-select manual list controls take scalar `value`, NOT `values: []`.
- List-control `filters` on a NUMBER column are silently stripped — bind to a
  `Text(...)` filter-key column.
- pivot/table `conditionalFormats` need `includeValues: true`.
- No `style.backgroundColor` on kpi-chart/bar-chart (blanks the PNG export);
  KPI tiles under ~3-4 grid rows blank their value.
- Catalog miss (discover-columns 404): `POST /v2/connections/{id}/sync` with
  `{"path":["DB","SCHEMA","TABLE"]}`, retry, only then Custom SQL.

SPEC-SHAPE GOTCHAS — pre-warning (don't discover these by HTTP 400):

- `yAxis: { columnIds: [<id>, …] }` — object with array, never a bare array.
- chart `color: { by: "category"|"scale", column: <id> }` — `by` required.
- region-map: `region: { id: <col-id>, regionType: "us-state" }` (valid:
  us-state, us-county, us-zipcode, us-cbsa, country).
- sort `direction: "ascending"|"descending"` — full words; `asc`/`desc` drop silently.
- DM relationships: `keys: [{ columnA, columnB }]` on the SOURCE element.
- Lookup formulas reference column DISPLAY names, never ids.
- pivot shapes asymmetric: `values: [<id-string>]`, `rowsBy`/`columnsBy`:
  `[{ id: <col-id> }]` — mixing renders an empty pivot.
- `conditionalFormats[].columnIds`, NOT `columns`.

STOP CONDITIONS (hard rules)

- **2-retry rule**: the same step failing twice → change approach or surface
  the blocker; never grind the same command. Hard blocker → write
  `MIGRATION_REPORT.md` with status "blocked" + the exact error, and stop.
- **Context budget** (`refs/orchestration.md` O2): at ~90 minutes of work, or
  the moment you notice compaction signs (re-reading files you already knew,
  re-deriving ids/flags you already resolved), STOP: write
  `{{WORKDIR}}/HANDOFF.md` (next command, open items, waivers granted so far
  with evidence, anything not yet in an artifact), set
  `migration-result.json` status to "handed-off", and tell the driving
  session to spawn a fresh builder. Resume is cheap — never grind past fatigue.
- Waivers/escape-hatch flags always need a named reason recorded in
  `MIGRATION_REPORT.md` WITH evidence — the verifier vetoes undocumented
  waivers. The gate also enforces a waiver BUDGET (stacking waivers caps the
  run at YELLOW, exit 19), and the split's two granted waivers consume it —
  any additional waiver costs the run its shot at GREEN. Fix problems; don't
  waive them.

THE VERDICT RULE — DO NOT SELF-CERTIFY (refs/orchestration.md O3)

You MUST NOT run `record-visual-check.rb --verdict pass` on your final render.
When you believe the render matches the source:

1. Expect `migrate-tableau.rb --finalize` to stop at gate 8b (exit 13,
   "comparison not recorded") — **that is your designed DONE state**. Ignore
   its printed instruction to record `--verdict pass`; that path is for solo
   self-attested runs.
2. Prove everything else is green with the self-check gate (the ONLY waiver
   the split grants you):

   ```bash
   ruby scripts/assert-phase6-ran.rb --tableau {{WORKDIR}} --workbook-id <sigma-wb-id> \
     --require-fidelity-ledger \
     --skip-visual-comparison "builder/verifier split: final visual verdict reserved for the verifier"
   ```

3. Request verification: your final message asks the driving session to spawn
   the verifier (`scripts/verifier-brief.md`) with `{{WORKDIR}}` + the Sigma
   workbook id. GREEN exists only after the verifier countersigns.

DELIVERABLES (all in `{{WORKDIR}}`)

- **Completion is a file, not a feeling:** a migration may be reported complete
  ONLY when `{{WORKDIR}}/phase6-success.json` exists **for the current run id**
  (`ruby scripts/verify-complete.rb --workdir {{WORKDIR}}` reads it) — quote the
  marker's workbook id + run id verbatim in your report. (Under the
  builder/verifier split your designed stop is exit 13 — say so explicitly and
  hand off; never claim GREEN yourself.)
- `MIGRATION_REPORT.md` — what was built, every waiver + reason + evidence,
  named degradations/substitutions, extract-mode notes, live workbook URL.
- `migration-result.json`:

  ```json
  { "workbook_name": "{{WORKBOOK_NAME}}", "workbook_luid": "{{WORKBOOK_LUID}}",
    "workdir": "{{WORKDIR}}",
    "sigma_workbook_id": "…", "sigma_workbook_url": "…", "dm_id_used": "…",
    "status": "awaiting-verification | handed-off | blocked",
    "self_assessed_tier": "GREEN | YELLOW | RED",
    "self_check_gate_exit": 0,
    "waivers": [ { "flag": "…", "reason": "…", "evidence": "…" } ],
    "charts_pass": 0, "charts_total": 0, "column_errors": 0,
    "screenshot_path": "…/sigma-render.png",
    "source_anchors_path": "…/source-anchors.json",
    "duration_s": 0.0, "error_summary": null }
  ```

  `self_assessed_tier` is YOUR opinion; the verifier's verdict is final.
- Leave every artifact the verifier needs: source dashboard PNG(s),
  `sigma-render.png`, `parity-final.json`, `fidelity-ledger.json`,
  `source-anchors.json`, `png-read.json`.

HOUSEKEEPING

- Record your `duration_s` in the result line.
- Public-repo hygiene: no credentials, tokens, or customer-identifying data
  in reports, notes, or result files.
- Do NOT push any code changes.
