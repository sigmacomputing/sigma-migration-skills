# Migration report format

`scripts/build-migration-report.rb` produces the final, converter-neutral
accounting report for a migration workdir. It is stdlib-only and reads existing
artifacts; it does not call either source system or Sigma.

## Usage

```bash
ruby scripts/build-migration-report.rb --workdir /path/to/workdir
ruby scripts/build-migration-report.rb --workdir /path/to/workdir --check
```

`--workdir` is required. The other options are:

| Option | Default |
| --- | --- |
| `--inventory PATH` | First existing `source-inventory.json`, `source-object-census.json`, or `inventory.json` in the workdir |
| `--markdown PATH` | `<workdir>/MIGRATION_REPORT.md` |
| `--json-out PATH` | `<workdir>/migration-result.json` |
| `--check` | Build both outputs in memory, compare them byte-for-byte with the files on disk, and write nothing |

Exit 0 means complete accounting with a GREEN or YELLOW verdict. Exit 1 means
RED, including a stale or missing output in `--check` mode. Exit 2 means the
invocation or an input JSON artifact is invalid.

Normal mode writes both reports even when the result is RED. This makes
omissions and contradictions visible. Check mode never writes.

## Source inventory

The inventory may be:

- an array of source objects;
- an object containing an `objects`, `source_objects`, `inventory`, or `items`
  array; or
- type-keyed arrays, either at the top level or below one of those container
  keys.

For example, these are equivalent:

```json
{
  "objects": [
    {"type": "dashboard", "id": "sales", "name": "Sales"}
  ]
}
```

```json
{
  "objects": {
    "dashboards": [
      {"id": "sales", "name": "Sales"}
    ]
  }
}
```

An object needs an `id` or `name`. Type-keyed arrays supply the type when an
object does not. Output identity and ordering are canonical: type, then ID,
then name, compared case-insensitively.

Every source object must resolve to exactly one of these terminal statuses:

| Status | Meaning |
| --- | --- |
| `migrated` | Faithfully built and accounted for |
| `approximated` | Built using an explicit substitute |
| `needs-review` | Accounted for, but still requires a named decision or review |
| `skipped` | Explicitly omitted |
| `not-applicable` | Deliberately outside the target's applicable surface |

Statuses can be on the inventory object itself, in an object's `accounting`
record, in root `accounting`/`statuses`/`records`/`coverage` records, or in
`coverage.json` and `*-controls-coverage.json`. Common producer vocabulary is
normalized: for example, `emitted`/`built`/`pass` become `migrated`,
`approximated` remains `approximated`, `degraded` becomes `needs-review`, and
`dropped` becomes `skipped`.

Repeating the same terminal status is allowed and preserves all evidence.
Different terminal statuses for the same source object are contradictory and
RED. A status record naming an object absent from the source inventory is also
an inconsistency, not extra inventory.

## Consumed artifacts

The builder records and evaluates these workdir artifacts when present:

- `coverage.json`
- `degradation-ledger.json`
- `parity-final.json`
- every `*-controls-coverage.json`
- `waivers.json`
- `*render-health*.json`, `*render_health*.json`, and JSON files below matching
  render-health directories
- `*blank-risk*.json`, `*blank_risk*.json`, and JSON files below matching
  blank-risk directories

Parity must explicitly pass. Render evidence must explicitly report healthy,
pass, or an equivalent boolean. A `parity-final.json` visual pass is accepted
as render evidence when there is no separate render-health artifact.
Blank-risk artifacts must explicitly be clear; when none exists, healthy render
evidence or the parity visual pass covers the check. Any explicit render
failure, blank/high-risk result, or indeterminate health artifact is RED.

The builder also checks internal counts it can verify without guessing,
including inventory totals/status counts and degradation-ledger class counts.
Declared counts that disagree with their detail records are RED.

## Verdict rules

- **GREEN**: every source object has exactly one terminal status; all are
  `migrated` or `not-applicable`; parity passes; render and blank-risk checks
  are healthy; and there are no waivers or degradation-ledger entries.
- **YELLOW**: accounting and hard checks are complete, but at least one object
  is `approximated`, `needs-review`, or `skipped`, or a waiver/degradation is
  recorded.
- **RED**: any source object is omitted or contradictory, an artifact report is
  inconsistent, parity fails or is absent, or render/blank-risk evidence fails
  or is absent.

`needs-review` and `skipped` are terminal accounting states, so a YELLOW report
can still exit 0. They are not silently treated as successful migration.

## JSON contract

`migration-result.json` has this top-level shape:

```json
{
  "schema_version": 1,
  "verdict": "GREEN",
  "summary": {
    "total": 1,
    "accounted": 1,
    "complete": true,
    "counts": {
      "migrated": 1,
      "approximated": 0,
      "needs-review": 0,
      "skipped": 0,
      "not-applicable": 0
    }
  },
  "source_objects": [],
  "checks": [],
  "artifacts": [],
  "degradations": [],
  "waivers": []
}
```

Each canonical source object includes `key`, `type`, `id`, `name`, `status`,
and `status_sources`. Each check includes `name`, `status` (`PASS` or `FAIL`),
and `message`. Artifact paths are relative to the workdir where possible.

The output has no wall-clock timestamp by default. If `SOURCE_DATE_EPOCH` is
set, the builder adds `generated_at` as the corresponding UTC ISO-8601 value.
The same inputs and environment therefore produce byte-identical JSON and
Markdown.

## Markdown agreement

`MIGRATION_REPORT.md` is rendered from the same in-memory document as the JSON.
Its verdict, total/accounted count, per-status counts, checks, canonical source
objects, artifacts, degradations, and waivers agree with
`migration-result.json`. `--check` regenerates both representations and catches
stale or manually edited output without changing either file.
