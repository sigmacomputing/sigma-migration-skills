# Local diagnostics

Diagnostics are local bookkeeping, not telemetry uploads and not a completion
gate. They never change the migration's exit code or waive missing evidence.

## Automatic coverage

`diagnostic-events/` contains separate immutable start/end JSON records with
UTC timestamps, a random activity ID, operation, runtime and exit code. End
records use a monotonic elapsed timer. A killed process can leave only a start;
that is incomplete evidence, not a zero-duration or successful operation.

- Ruby: orchestrator invocations (excluding the `--wait` observer), children
  launched through `run!` / `run_wb!`, fidelity-loop commands, and
  `verify-complete.rb`. Exec handoffs close the old invocation before resuming.
- Python: orchestrator invocations, its `run()` children, and
  `verify-complete.py`. Direct API calls and other subprocess call sites are
  covered only by their enclosing invocation, not separately timed.
- Ruby child failures record a coarse category, not captured output or argv.
  Invocation/repair records list which of four named local artifacts changed
  (`wb-spec.json`, `dm-spec.json`, `dashboard-layout.json`, `fidelity-ledger.json`).
  Their contents and hashes are not included in diagnostic events.
- Existing `execution-history.jsonl` supplies Ruby implementation/converter
  fingerprints. Runtime versions are recorded by both profiles. An absent
  build identity stays missing; export never substitutes the exporter's build
  for the build that performed the migration.

When the host actually exposes its model and effort settings, it may supply
`SIGMA_DIAGNOSTICS_MODEL` and `SIGMA_DIAGNOSTICS_EFFORT` to the migration process.
Do not guess these from an agent nickname, doctor output or cost estimate.
Unsupported/missing values become `unknown`. No token-usage or cost estimate
is presented as measured usage. These two optional settings are the only
environment metadata collected; no environment dump is read or packaged.

## MCP and manual work

An external agent's MCP calls, edits, and visual inspection cannot be observed
automatically by the subprocess. Around such work, start one explicit timer:

```bash
python3 scripts/diagnostics.py begin --workdir <WORK> --kind mcp --operation mcp-source
# Perform the MCP activity, then use the printed activity ID:
python3 scripts/diagnostics.py end --workdir <WORK> --id <ACTIVITY_ID> --exit-code 0
```

On Windows use the bootstrap-selected Python command (`python` when applicable).
Kinds: `mcp`, `repair`, `review`. Operations: `mcp-source`, `mcp-query`,
`manual-spec-edit`, `visual-review`, `runtime-repair`. End failed activities with
a nonzero exit code; if interrupted, leave the start unmatched rather than
invent an end. Explicit timers measure elapsed wall time between the commands,
not CPU time, model thinking, or an independently observed tool duration.
They do not read manual edit contents or record changed-artifact details.

## Customer-controlled ZIP

After stopping the migration, or when requesting diagnostics, run:

```bash
python3 scripts/diagnostics.py bundle --workdir <WORK> --out <WORK>/diagnostics.zip
```

The output must not already exist. The command creates one ZIP locally; it
has no network or upload operation. Review every member before choosing to
share the ZIP. Keep it outside the repository. Creation uses owner-only
permissions where supported; Windows protection follows the directory ACL.

The ZIP contains typed projections of explicitly named timing, execution,
handoff, fidelity, numeric/visual, and completion artifacts. Unknown strings
are replaced with opaque aliases (no reverse map is included). It excludes
raw logs/errors, credentials, auth/environment files, customer rows, formulas,
source workbooks, images, paths, tenant IDs and arbitrary attachments. The
same excluded string gets a consistent alias within that bundle. Recognized
build hashes, model/runtime identifiers, statuses, counts and timestamps remain
and may still be sensitive. This is not a general-purpose redactor for arbitrary
files, and a targeted, separately reviewed error/formula may still be needed.

`collection.json` identifies missing, malformed, unsafe, oversized and partially
readable inputs. Symlink/nonregular inputs are refused. Artifact reads are
bounded to 5 MiB each, events to 16 KiB each, and 10,000 event files per export.
The live source files are never modified. A live export is not a transactionally
consistent snapshot of the migration; prefer exporting after it stops.

`SUMMARY.json` derives only from the final sanitized bytes in the ZIP.
`MANIFEST.json` hashes those same packaged bytes, including the summary and
README, but not itself. Never append a hand-edited summary or reuse pre-redaction
hashes after packaging.

## Interpreting results

Summed phases and nested/parallel activities can overlap. Use the interval union
for covered wall time, and keep the elapsed span and unmeasured gaps separate.
Legacy phase-only logs are explicitly labeled reconstructed intervals. Clock
jumps or unmatched events are flagged, not repaired by guessing. Time before
the first or after the last usable activity is not reconstructed. No unmeasured
gap can be attributed to model thinking, idle time, or an API wait without more
evidence.

Nonzero exits include designed handoffs. Operation counts reveal repeated builds,
renders and repairs only within the recorded coverage. Fidelity render counts
come from the existing ledger, not a claim that every render was observed.
The last observed completion-check result and reported artifact verdicts are
separate: an old pass is not a fresh completion certificate. Only the unchanged
completion gates can authorize reporting a migration as done.
