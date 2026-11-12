<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 5g — HYBRID route: the RCF fix loop and later edits through the Sigma MCP Code Mode SDK, with spec export-back + re-gate. -->

# Phase 5g — hybrid SDK route

**Use it when** the agent has the Sigma MCP `build_workbook`, `screenshot` and
`query` tools. **Otherwise** use the REST loop in `refs/phase-5g-rcf.md`
(`fidelity-loop.rb render / record / apply-patch`), which stays the default.
The Python runtime profile has no `fidelity-loop`, so it always uses the REST
route.

**What changes and what does not.** The gated code-rep build is untouched:
the spec POST, layout, parity plan, anchors, and every pass-1 gate. Only the
*fixes* move. Each render → compare → fix pass runs through Code Mode
programs instead of `apply-patch` JSON patches. After the loop, the live code
representation is exported back into `<workdir>/wb-spec.json`, which keeps it
authoritative and reproducible, and is re-gated before `--finalize`.
*(Why: in the 2026-11-05 A/B on three workbooks, values were exact in every
arm. The hybrid route scored 73.5 in blind side-by-sides against 59.8 for
`apply-patch`, took 36.6 min against 57, and passed an edit test in 2.5 min
against 10. A whole-workbook SDK build varied from run to run and left no
spec on disk, which is why the build stays code-rep.)*

Read `refs/sdk-gotchas.md` before the first write.

## The loop

```bash
# 0. pass 1 of migrate-tableau.rb has run (ledger initialized, workbook GREEN on its gates)
ruby scripts/fidelity-loop.rb sdk-begin --workdir <WORK> --mcp-server <sigma MCP server name>
```

`sdk-begin` takes a version-bound checkpoint and writes `repair-pending.json`.
While the session is open, that marker blocks `render`, `apply-patch`,
`verify-complete` (exit 12) and `--finalize`; their refusal names the open
session and the command that releases it. `sdk-begin` refuses when the RCF
pass budget is spent, so the final budgeted render is always possible, and
(exit 3, like `render`) once the elapsed-time budget has expired.

Per pass:

1. **SCREENSHOT** the page with the MCP `screenshot` tool, or start from the
   staged 6f render. Compare it with the source PNG and score it against
   `refs/fidelity-rubric.md`. SDK screenshots are working views only; they are
   never grading evidence and never consume `max_passes`.
2. **RECORD** each delta exactly as on the REST route:
   `fidelity-loop.rb record --dimension D --delta "..." --class C`.
3. **FIX** with one `build_workbook` call
   (`target: {type: existing, workbookId: <id>}`). Save the program text and
   the tool output to files, then **record the write immediately**:

   ```bash
   ruby scripts/fidelity-loop.rb sdk-write --workdir <WORK> \
     --program prog.py --result out.txt --summary "<what it changed>" --claims e0,e2
   # a run that raised:
   ruby scripts/fidelity-loop.rb sdk-write --workdir <WORK> --program prog.py \
     --result out.txt --status failed --error "<message>" --summary "<intent>"
   ruby scripts/fidelity-loop.rb sdk-reread --workdir <WORK> --evidence describe.txt
   ```

   Each write's program and result are kept under `<workdir>/sdk-writes/`
   (local, 0600, never committed) with their sha256 and the document version
   the write produced. `--claims` names the ledger entries the write fixes;
   they resolve only after the export re-gates. A failed write sets
   `needs_reread`, because partial state may persist. Re-read the page and
   record it before any further write or the export. A write made after the
   elapsed-time budget expired is still recorded (`over_budget: true`), but
   `sdk-write` exits 3: get an attributed `extend` before exporting, or roll
   the session back. With no open session, `sdk-write` refuses (exit 2) and
   says why the last session closed. Run `sdk-begin` before the next
   `build_workbook` call.
4. Loop until the page matches.

## Export-back + re-gate

```bash
ruby scripts/fidelity-loop.rb sdk-export --workdir <WORK>
```

1. The live document version must equal the last recorded write. A mismatch
   means an **unrecorded write** (exit 4): record it, or roll back.
2. It GETs the live code representation and persists it to `wb-spec.json`,
   then refreshes the session checkpoint's rollback candidate.
3. It runs the column-type guard (paginated; an unread list fails closed),
   `LayoutLint`, `ControlLint` (with `control-scope.json`), and a check that
   the version stayed stable. On any failure: exit 5, state `export-failed`,
   and the session **stays open**. Fix it with more writes and export again.
4. When the guards pass, the session closes (unless parity comes back
   unverified; see step 5). Prior parity, render, blind-grade
   and completion evidence is archived (it described an older document),
   `wb-readback.json` is refreshed, and the claimed entries are marked
   resolved with `resolved_via: {route: "sdk", session, writes}`.
5. **Phase-6 parity on the exported spec:** `phase6-parity.rb` pass 1
   rebuilds the plan from the exported spec and re-collects REST actuals.
   The archived plan is not reused, which is the same as after a REST
   `apply-patch`, so operator waivers recorded in the old plan must be
   re-applied. Pass 1 counts a chart as collected when it has rows or the
   pivot `render-verify-required` marker; a plan with no collectible charts
   (the anchors oracle) goes straight to `phase6-parity.rb --finalize`.
   - PASS: exit 0, state `exported`.
   - DIVERGE: exit 7, state `parity-failed`, plus a **data-class** ledger
     entry (`source: sdk-export-parity`) that blocks gate 8d unconditionally.
     Fix it in a new session; a passing export resolves the entry.
   - Incomplete actuals: exit 5, state `parity-unverified`. The session
     **stays open** (marker kept), as after a guard failure. Either supply
     the missing charts with
     `fidelity-loop.rb sdk-regate --workdir <WORK> --actuals FILE`, which
     re-runs only the parity step and only while the live version still
     equals the export, or fix with more writes (`sdk-write` each; the state
     returns to `open`) and `sdk-export` again.
   - Pie and donut charts export and query only their color and value
     channels. The rebuilt plan therefore compares those columns only, and
     drops unplotted measure columns such as a `% of total` label kept after
     a `convert_to('pie')`. They are listed in the plan's `unplotted_columns`.

## Then finish exactly as on the REST route

1. `fidelity-loop.rb render`: one budgeted REST export render,
   version-bound. It is the only render the blind grader may grade, so gate
   8b is unchanged.
2. Run a fresh blind grader (`refs/blind-grader-brief.md`), then
   `record-visual-check.rb --blind-grade`.
3. Run `migrate-tableau.rb --finalize`. It refuses (exit 3) while
   `sdk.state` is anything other than `exported` or `rolled-back`, and when
   the live document version is not exactly the last export's. A render does
   not update `wb-spec.json`, so it can't make a later version authoritative.
   This check catches any write after the export, including an SDK call made
   without a session; open a session and export again. `fidelity-loop.rb status`
   makes the same checks, including the live-version read, and exits 6 on
   any of them.
4. If the source has drill-hierarchy crosstabs, run the pivot-collapse step
   in `refs/postpublish-interactivity.md` **after** this. Any later
   contents PUT re-expands the pivot.

## Later edits

A user-requested edit after GREEN is a new session: `sdk-begin` → writes →
`sdk-export` → render → blind grade → `--finalize`. The repair budget
(default 1800 s from init) has usually expired by then. Record the user's
request first with `fidelity-loop.rb extend --max-passes <higher> --max-seconds <higher>
--approved-by "<user>" --reason "<the edit>"`. The extension does not relax any gate.

## Rollback

`fidelity-loop.rb rollback --workdir <WORK> --checkpoint <sdk.sessions[-1].checkpoint>`
restores the pre-session workbook from anywhere in an open session, including
`export-failed`, as long as every write is recorded. It first rebinds the
rollback candidate to the live state at the last recorded write, and refuses
(exit 4) when the live version shows an unrecorded write. On success
`sdk.state` becomes `rolled-back`, which finalize accepts, and the
pre-session ledger entries are restored. All verification must be
recollected.

`fidelity-loop.rb recover` on an open session archives its marker without
an export and sets `sdk.state` to `reconciled`. Finalize stays blocked
until a new session (`sdk-begin`) is exported.

## Ledger shape (additive)

```json
"route": "sdk",
"sdk": {
  "state": "open | export-failed | exported | parity-failed | parity-unverified | rolled-back | reconciled",
  "sessions": [{
    "id": "s1", "checkpoint": "<32 hex>", "base_version": "7", "mcp_server": "...",
    "needs_reread": false,
    "writes": [{ "id": "w1", "status": "ok", "summary": "...", "program_sha256": "...",
                 "program_path": "sdk-writes/s1-w1/program.py", "result_sha256": "...",
                 "document_version": "8", "claims": ["e0"], "error": null }],
    "rereads": [], "exports": [{ "document_version": "8", "guards": "pass", "parity": "pass",
                                  "wb_spec_sha256": "...", "resolved": ["e0"] }]
  }]
}
```

**Gate 8d** (shared `assert-phase6-ran.rb`, unchanged) reads only `entries`.
SDK-resolved entries carry the same `resolved: true` as REST-resolved ones,
so the gate accepts them. The SDK-specific integrity checks (export-back
done, re-gate passed) are enforced tableau-locally: `repair-pending.json`
plus the `--finalize` and chain-predicate checks through
`lib/sdk_route.rb`. Data-class entries, including the automatic parity entry,
still block whenever the ledger exists.

Tests: `ruby scripts/test-fidelity-sdk-hybrid.rb` (offline; covers
begin → write → export → parity, failed-write reread, an unrecorded write, a
guard-failure retry, divergence, unverified → regate or more writes in the
same session, status drift, the open-session refusal text, the time and pass
budgets, rollback, and recover). Pie projection:
`ruby scripts/test-parity-pie-projection.rb`. Live-proof evidence (2026-11-05):
`scripts/fixtures/sdk-hybrid-live-proof/`.
