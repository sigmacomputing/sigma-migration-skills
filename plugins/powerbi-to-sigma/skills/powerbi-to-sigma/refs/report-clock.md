# Report clock and materialization freshness

Two parity traps found on a real migration, then reproduced on a test org
(2026-11-16). Both are general: they show up on any report that uses `TODAY()` or
on any data model that has Sigma materializations.

## 1. One clock for "today"

Power BI evaluates `TODAY()`/`NOW()` on one clock. A naive migration evaluates them
on two:

| Where | Clock (verified) |
| --- | --- |
| Power BI service (`executeQueries`, published reports) | UTC: `NOW()` = `UTCNOW()` |
| Power BI Desktop | the author's machine time zone |
| Power BI calculated table/column using `TODAY()` | frozen at dataset **refresh** |
| Sigma `Today()` / `Now()` | literals that Sigma computes in the Sigma **account time zone**, e.g. `to_timestamp_ltz('2026-11-16T00:00:00+00:00')` on a UTC org (`CurrentTimezone()` names it) |
| Warehouse `CURRENT_DATE` / `CURRENT_TIMESTAMP` in Sigma Custom SQL | the warehouse **session** time zone; Sigma's own Snowflake sessions reported UTC while the account and user `TIMEZONE` were `America/Los_Angeles` |
| The same SQL run outside Sigma (worksheet, `snow` CLI, Power BI's connector) | the account/user `TIMEZONE`, `America/Los_Angeles` by default |

The converter produces both kinds: measures become `Today()` (Sigma clock), while a
`{ TODAY() }` calculated table becomes `SELECT CURRENT_DATE` and an
incremental-refresh window becomes `CURRENT_DATE()` (warehouse clock). Between two
midnights the clocks name different days. That moves rolling-N-day windows,
days-since, `Orders Today`, and MTD/YTD on the first of a month or year, both in
the built product and in parity. Between UTC and New York the band is
00:00–05:00 UTC; between UTC and Los Angeles it is 00:00–08:00 UTC.

### The fix: `--report-timezone` (default `UTC`)

`migrate-powerbi.rb --report-timezone <IANA>` names the report clock. The default,
UTC, is the Power BI service clock. Pass the zone the report's users mean by
"today" (Desktop-authored reports often mean local time). The build then pins every
clock site to that zone, independent of the Sigma account and the warehouse session
(`scripts/lib/pbi_report_clock.rb`):

| Site | Pinned expression |
| --- | --- |
| Sigma `Today()` | `DateTrunc("day", ConvertTimezone(Now(), "<tz>"))` |
| Sigma `Now()` | `ConvertTimezone(Now(), "<tz>")` |
| Snowflake `CURRENT_DATE` | `CAST(CONVERT_TIMEZONE('<tz>', CURRENT_TIMESTAMP()) AS DATE)` |
| Snowflake `CURRENT_TIMESTAMP` / `GETDATE()` | `CONVERT_TIMEZONE('<tz>', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ` |
| BigQuery `CURRENT_DATE()` / `CURRENT_DATETIME()` | `CURRENT_DATE('<tz>')` / `CURRENT_DATETIME('<tz>')` |
| Databricks `current_date()` | `CAST(from_utc_timestamp(to_utc_timestamp(current_timestamp(), current_timezone()), '<tz>') AS DATE)` |

Pins happen in two places: in the data model spec before validation and POST, and
in the workbook spec that `build-workbook-from-pbir.rb` writes. The workbook pass
also covers agent-authored master-map formulas from gap-scout. String literals
(including backslash escapes), `[column refs]`, comments, aliases (`AS now`) and
qualified columns (`t.now`) are never rewritten, and pinning is idempotent.

An **explicit** zone is authored and is never rewritten:
`ConvertTimezone(Now(), "X")`, a 2- or 3-argument `CONVERT_TIMEZONE`, or BigQuery
`CURRENT_DATE('X')`. When X is not the report zone, the site is recorded as off the
report clock (`zone: X`), and parity treats Sigma's clock as X. A warehouse without
a timezone-explicit form here (anything but Snowflake, Databricks or BigQuery) keeps
its SQL as written; those sites are recorded as unpinned, and Sigma formulas are
still pinned.
`<WORK>/report-clock.json` records the zone, its source, the expressions, and every
pinned or unpinned site. `run-provenance.json` carries `reportTimezone`.

A **reused data model is never rewritten**. Its bare clock sites are recorded as
`unpinned`, and parity refuses its today-relative charts.

### Oracle on the same clock

Run `build-oracle-sql.rb --report-clock <WORK>/report-clock.json`, or set
`report_timezone` in `oracle-input.json`. With either one it transpiles these:

- `CALCULATE(<agg>, DATESINPERIOD(D[Date], TODAY(), ±N, DAY|MONTH|QUARTER|YEAR))`:
  for -N the range is (today − N, today]; for +N it is [today, today + N).
- `CALCULATE(<agg>, DATESBETWEEN(D[Date], <start>, <end>))`, where each end is one
  of `TODAY()`, `TODAY()±N`, `DATE(YEAR(TODAY()),MONTH(TODAY()),1)`, the quarter
  start, `DATE(YEAR(TODAY()),1,1)`, or `DATE(y,m,d)`.
- `CALCULATE(<agg>, T[c] <op> <that date>)`, `DATEDIFF(<agg>, TODAY(), DAY)`, and a
  bare `TODAY()`.

`measures` (`{name: DAX}`) expands `[Measure]` references. Map the calendar's date
column to the fact's date column in `column_map` (`"Date": "ORDER_DATE"`); a
per-chart `column_map` overrides the global one. `--as-of 2026-11-17T03:00:00Z`
pins "today" to a fixed instant, which makes an oracle reproducible.
`TOTALMTD`/`SAMEPERIODLASTYEAR` (filter-context time intelligence) stay
unsupported. Without a report clock, any `TODAY()` measure stays
`supported:false`, and the oracle never falls back to the warehouse session clock.

A hand-written oracle has to use the same expression
(`record['warehouse_today_sql']`), never a bare `CURRENT_DATE`.

### Parity refuses two clocks

```
ruby scripts/phase6-parity-pbi.rb --local-sql --expected parity-expected.json \
  --oracle-sql chart-oracle-sql.json --workbook-id <wb> --out plan.json
ruby scripts/phase6-parity-pbi.rb --finalize --plan plan.json --actuals parity-actuals.json \
  --out-dir <WORK>          # reads <WORK>/report-clock.json + the built specs
```

A chart counts as today-relative if its oracle descriptor says so, or if its built
Sigma formula reads the clock (directly, or through a `[Metrics/…]` metric that does).
Each today-relative chart is classified `CLOCK-SKEW` unless all of these hold:

- the Sigma clock (the report zone when nothing is unpinned, otherwise the account
  or session zone), the oracle clock (`report-clock`, `powerbi-service` = UTC, or an
  unknown `warehouse-session`) and the report zone are all the same zone; and
- the oracle run (`--expected-as-of`, default the expected file's mtime) and the
  actuals (`--actuals-as-of`, default that file's mtime) fall on the same report
  day.

A mismatch is refused **at any hour**. Outside the disagreement band, values that
match by luck prove nothing. Overall status `CLOCK-SKEW` is not a pass, so the hard
gate refuses it. `parity-final.json` records the zone under `report_clock`; the
migration report ingests that file as its parity artifact.

When `--out-dir` is not the migration workdir, `--finalize` looks for
`report-clock.json`, the built specs and the materialization records in `--out-dir`,
beside the plan, and one level up; `--workdir` names the workdir explicitly. The
page-fact path (`parity-from-oracle.py --workdir`) applies the same materialization
gate. It refuses `CLOCK-SKEW` whenever any clock site is off the report clock,
because page facts carry no per-chart flags. A grouped today-relative oracle drops
groups whose windowed measure is blank, as Power BI does (`HAVING … IS NOT NULL` /
`> 0` for counts). With no tz database on the host (Windows, slim images), the
report day of a non-UTC zone cannot be computed, so parity fails closed.

`--source-timezone` is a separate setting. It converts UTC Export-API timestamps to
local days in the dimensions, and it is normally the report timezone.

## 2. Stale materializations

A materialized data-model element serves its **last run**. Facts verified on the
test org:

- Creating a schedule starts a run at once, so an immediate `:materialize` gets a
  409.
- The run lands in `<writeback db>.<schema>."t_mat_<materializationId>_<n>"`. A
  workbook element over the DM element compiles to `select … from …"t_mat_…"`, and
  `GET /v2/workbooks/{id}/queries` shows that SQL, which maps each element to its
  table.
- After an upstream insert, Sigma kept returning the old 10 rows while the live
  table had 15. A rerun refreshed the same `t_mat` table in place: its
  `LAST_ALTERED` moved, and only then did Sigma match.
- The job API (`GET …/materializations/{id}`) kept reporting the **first** run's
  `startedAt`/`readyAt`, and it said `ready` right after a new POST. Never trust it
  for freshness.

`scripts/check-materialization-freshness.rb --data-model <dm> --workdir <WORK>`
works out freshness from the warehouse. For each scheduled element it compares the
`t_mat` table's `LAST_ALTERED` with every upstream table's `LAST_ALTERED`, resolving
element-on-element sources transitively. It also checks the clock: an element that
reads it was frozen on its run's report day, so it is stale after midnight in the
report zone, whatever its other status. An element that reads no table at all, such
as a generated calendar or `SELECT CURRENT_DATE`, has nothing upstream to go stale;
the clock rule still applies to it. The verdict is `FRESH`, `STALE` (exit 3) or
`UNKNOWN` (exit 4). `UNKNOWN` means an upstream view, a missing table, or a dynamic
or unqualified source (migrate passes the connection's default database and schema).
`--allow-unknown` accepts UNKNOWN: it is recorded in the report, and `--finalize`
honors it, naming the accepted elements. `--rematerialize` refreshes
the stale elements. The script uses one private scratch workbook, which it always
deletes.

**Wait for materializations by polling run status or the wall clock, never one long
sleep, because host sleep stretches it.** `--wait SECONDS` re-reads the warehouse
every `--poll` seconds against a wall-clock (`CLOCK_REALTIME`) deadline, and it
waits only while a run can still change the answer (a STALE element, or a `t_mat`
table not visible yet). The monotonic clock pauses during host sleep on macOS, so it
cannot be trusted for this. The scratch SQL probe's state lives in the workdir, so a
workbook left by a failed poll is still deleted.

`migrate-powerbi.rb` runs the check with `--wait 900` before Phase 6 whenever it
created schedules. `phase6-parity-pbi.rb --finalize` returns `STALE-MATERIALIZATION`
in three cases: the check is missing; it is neither `FRESH` nor accepted `UNKNOWN`;
or it ran more than 2 h before or after the oracle or the actuals. A `NONE` result
is never aged.
