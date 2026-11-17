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

`dropped-unused` (a control the builder never placed because nothing reads it)
also becomes `skipped`.

Repeating the same terminal status is allowed and preserves all evidence.
Different terminal statuses for the same source object are contradictory and
RED. One exception: `migrated` beside a `needs-review` that is only the
census's "built, but final parity does not prove it" rationale resolves to
`needs-review` (the conservative status) with both evidence entries kept; a
census "no matching built object" or any other mix stays contradictory. A
status record naming an object absent from the source inventory is also
an inconsistency, not extra inventory.

Records match an inventory object by id, then name; within each, the exact
spelling (unstripped, case-sensitive) is tried before the folded one, so names
that differ only by whitespace stay distinct. When a name is shared by one
worksheet and its dashboard zone(s), a record with a missing or other type
(e.g. a `chart`) routes to the worksheet; zones are reached by id or zone type.

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

### Report clock and materialization freshness

`parity-final.json` may carry two optional blocks (powerbi-to-sigma 1.15.0+,
written by `phase6-parity-pbi.rb --finalize` and `parity-from-oracle.py`; see
that skill's `refs/report-clock.md`):

- `report_clock`: the one IANA timezone the build and the oracle use for
  `TODAY()`/`NOW()`. Keys: `report_timezone`, `report_timezone_source`,
  `sigma_clock`, `oracle_clock`, `oracle_kind`, `report_day`, `expected_as_of`,
  `actual_as_of`, `unpinned_sites`, `record`, `today_relative_charts[]`, and
  `clock_skew[{chart, reason}]`.
- `materialization_freshness`: the pre-parity freshness check. Keys: `status`
  (`FRESH`, `NONE`, `STALE`, `UNKNOWN`, `UNREADABLE` or `NOT-CHECKED`),
  `checked_at`, `path`, `stale[]`, `unknown[]`, plus `accepted_unknown[]`
  (only after `--allow-unknown`) and `scheduled[]` (only for `NOT-CHECKED`).

A missing or `null` block renders nothing. The two refusal statuses,
`CLOCK-SKEW` and `STALE-MATERIALIZATION`, are not parity passes. The parity
check names them with what was recorded:

- the skewed charts and their reasons, or, on the page-fact path, the number of
  clock sites off the report clock;
- the stale or unknown elements, the schedules that were never checked, or a
  passing check that was not taken close enough to the oracle and the Sigma
  actuals.

A chart listed in `clock_skew` was never compared, so the parity check fails
whatever the overall status says.

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
  inconsistent, parity fails or is absent (including `CLOCK-SKEW` and
  `STALE-MATERIALIZATION`), or render/blank-risk evidence fails or is absent.

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

Two more top-level keys appear only when `parity-final.json` records the
matching block:

- `report_clock`: the recorded keys listed above, plus
  `today_relative_chart_count` and `source_artifact: "parity-final.json"`.
- `materialization_freshness`: `status`, `checked_at`, `path`, `stale`,
  `unknown`, `accepted_unknown` and `scheduled` when recorded, and
  `source_artifact`.

Recorded absolute paths (`record`, `path`) are made workdir-relative. Relative
paths are kept as written.

The output has no wall-clock timestamp by default. If `SOURCE_DATE_EPOCH` is
set, the builder adds `generated_at` as the corresponding UTC ISO-8601 value.
The same inputs and environment therefore produce byte-identical JSON and
Markdown.

## Markdown agreement

`MIGRATION_REPORT.md` is rendered from the same in-memory document as the JSON.
Its verdict, total/accounted count, per-status counts, checks, canonical source
objects, artifacts, degradations, and waivers agree with
`migration-result.json`. When recorded, a `## Report clock` section follows the
checks. It gives the timezone and its source, the today-relative chart count,
the Sigma and oracle clocks, any clock sites off the report clock, and one line
per `CLOCK-SKEW` chart with its reason. A `## Materialization freshness`
section gives the status, when it was checked, and the stale, unknown (or
accepted-unknown) and never-checked elements. `--check` regenerates both representations and catches
stale or manually edited output without changing either file.
