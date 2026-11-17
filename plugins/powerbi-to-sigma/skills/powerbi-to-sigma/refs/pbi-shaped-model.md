# Power BI-shaped mode (`--model-shape pbi`)

An opt-in shape for the Sigma data model and workbook. The default shape (`--model-shape views`) keeps its data
model and workbook specs, except that DATATABLE calculated tables now convert in both shapes. Views runs also write
the report files `pbi-map.*` and `limits.md`, and the native-source probe report gains a key. Use this mode when the customer should
be able to read the Sigma model like their Power BI model: a chart points at a table with a Power BI name,
not at a hidden Data page of generated masters.

```bash
ruby scripts/migrate-powerbi.rb ... --model-shape pbi            # add --probe-sources --connection <id> --folder <id> for the live checks
```

Evidence for every rule below: `corpus/powerbi/pbi-shaped-model/probes/LOG.md`. The offline regression case is
`corpus/powerbi/pbi-shaped-model/`. The live proof (three reports, both shapes, parity and timings) is
[`corpus/powerbi/pbi-shaped-model/live/COMPARISON.md`](../../../../../corpus/powerbi/pbi-shaped-model/live/COMPARISON.md).

## The rules

**Two layers.** The visible layer keeps Power BI names: tables, columns, relationships, measures, pages,
visual titles. Under it, the physical layer follows Sigma practice (materialization, flattening where it pays,
summary tables, Custom SQL). Anything physical that a user can see is named and described in Power BI terms.
A column keeps its Power BI name while its formula stays bound to the warehouse column.

**One element per Power BI table**, under the Power BI table name, scoped to what the report uses. No
`<X> View` elements. Power Query SQL stays Custom SQL and its description says so. Elements are placed on one
data model page per subject area (a fact and the dimensions it uses), with shared dimensions on a `Shared` page.

**Relationships** sit on the many side and are named after the target table. A second relationship between
the same pair (Power BI's inactive one) is named `<Target> (<fromColumn>)`; a `USERELATIONSHIP` measure uses that
path. Inactive relationships no measure activates are not carried and are listed as such in the map.

**Key-uniqueness check.** Before the data model POST, one warehouse query per relationship counts duplicate
(and NULL) keys in the target. A relationship whose target key is duplicated is dropped, and every formula that
went through it is recorded. The check needs a warehouse probe; see `--shape-probe-results` and
`--allow-unverified-keys` below. A probe that fails aborts with exit 10 and names the keys. With no probe at all the check is skipped (the run
says so), every relationship is kept unverified, and `limits.md` gets "Key check not run: N relationship(s)
unverified" (the map notes each relationship). Run the quick command line below with `--probe-sources` for the real check.

**Measure classes.** Every measure on a visible visual is classified and the class goes in the map:

| Class | What it is | Where it lands |
|---|---|---|
| A | aggregates and arithmetic over one table's columns, literal filters | a metric on that table, under its Power BI name |
| B | needs a related table's column (`RELATED`, a filter on a dimension column) | a metric on the fact's child element, reading `Lookup()` calc columns |
| C | time intelligence: YTD/QTD/MTD, prior year or period, rolling N days | a metric (fixed as-of anchor), a generated grouped element (follows the chart's date axis), or a generated Custom SQL summary over a dense day spine (rolling windows) |
| D | cross-fact grids, per-entity bucketing, snapshot logic, anything C cannot place | a page summary, completed from a scaffold (see `--scaffold-page-facts`) |

Class D also applies to a single visual (see "Held-back visuals" below).

Metrics sit on the table whose columns they read; Power BI display folders go in the metric's description (the
API cannot put metrics in folders). A top-level `+` or `-` between metrics reads a blank side as 0, as DAX does:
`If(IsNull(a) and IsNull(b), Null, Coalesce(a, 0) ± Coalesce(b, 0))` (a literal term drops the guard). Only a
top-level binary `+`/`-` is rewritten; one inside a function argument, or between aggregates inside another call, is not.
A metric ref matches the metric's name in any case and is written with the metric's own spelling.
DAX `DISTINCTCOUNT` counts BLANK as a value and `CountDistinct` ignores NULL, so a class A/B measure that uses it is
listed in `limits.md` (nullability is not probed).

**The "<Fact> (source)" split.** A fact is split only when a metric needs a related column. `<Fact> (source)`
is the base (raw columns, relationships). The child under the Power BI name carries the `Lookup()` calc
columns, the metrics, report-wide filters (null-safe) and its own copy of the relationships. Charts read the
child. A relationship-path column inside a data model element fails at query time; the `Lookup()` chain works.

**The workbook reads the data model directly.** No Data page, no master ids. Charts, KPIs and pivots source a
data model element and reference `[Metrics/<name>]`; KPI values keep the inline aggregate that preflight
requires for a single aggregate; a metric that reads another metric (Gross Margin, GM %) keeps its `[Metrics/<name>]`
references, which work live. A chart is at most two clicks from its source (child, then its source table).

**Slicers on summary tables.** A summary may carry a slicer's field as a column when that stays within 10x the
summary's size without it; the builder measures the row count both ways with one warehouse query. A carried
field becomes an outer grouping level (never the innermost; probes proved the innermost level has no effect).
Ratios are carried as numerator and denominator and divided in the consumer. If a slicer cannot be carried
(over 10x, or a sparse carry that would lose a carried-forward YTD), the page gets one plainly named live
element, "<Summary> - live, filtered by your slicer picks": exact numbers under any pick, a slower page. The
limits file lists each page that went live, with the counts behind the choice. A date slicer on a non-live
rolling summary filters the plotted days (it does not recompute the window).

**Boolean slicers** target a text filter column, `If(IsNull(x), Null, If(x, "True", "False"))`; no list control
targets a boolean column. A saved single selection is the control's `value`, not `values`.

**No-axis reads of time intelligence.** A grouped time-intelligence element has one row per period. A visual
with no date field at that grain reads it like this:

| Measure | Read |
|---|---|
| YTD / QTD / MTD | the value at the latest period in scope |
| prior year / prior period | the sum over the periods in scope |
| YoY % | a ratio of those sums |
| rolling N days | the window ending on the latest day in scope |

An empty latest period stays blank (it does not read 0). With a date axis at the element's grain each row is read as is.

**Held-back visuals (visual-level class D).** Some visuals cannot be exact on one element even when every measure
is class A to C. Each is held back, listed in `limits.md` and `pbi-map.md`, and goes the page-summary route
(`--scaffold-page-facts`, complete the draft, then `--page-facts`):

- a visual that needs two relationship paths to one table, such as a `USERELATIONSHIP` measure next to an
  active-path measure on a shared Date axis (Sigma reads one path per element);
- PREVIOUSYEAR / PREVIOUSQUARTER / PREVIOUSMONTH with no date field at the element's grain;
- a non-additive metric (average, ratio, distinct count) read through a grouped element by a visual that is not at
  the element's grain;
- an as-of measure (`CALCULATE([X], DATESBETWEEN(..., asof))`), which Power BI holds flat across the Date table: a visual
  that binds it with a Date-table field, mixes it with other measures under a page Date slicer, page filter, or a report or
  visual Date filter, or has a report/visual Date filter on an all-as-of visual (it cannot be kept off the element) is held
  back. An all-as-of visual under a page Date slicer or page filter keeps its element and the pick is not applied to it
  (listed as excluded in the control scope and under "As-of measures");
- a visual that binds a date field that is not provably a calendar level beside a grouped or rolling measure (see "Date fields");
- a `USERELATIONSHIP` visual where a Date control also reaches an active-path visual on the page, or any report-level Date filter;
- a visual that binds the column a `CALCULATE` filter replaces on an axis, or sits under a slicer, page, report or visual
  filter on it (the class entry carries `filter_columns`);
- a rolling visual on a page whose page filter targets a field the rolling element does not carry.

Without page facts a held-back visual is lost, so the field-loss gate stops the run with exit 10. Pass
`--allow-field-loss` to accept the loss (it is still reported). The scaffold follows the fact's source chain and
writes the join for each path to `closure.md`.

**Time-axis density probe.** A grouped element has rows only where its fact has rows, while Power BI shows every
Date-table period. When the Date table has periods with no fact rows (trailing periods or gaps), that fact's
grouped time-intelligence measures go to class D (page summary over the Date table). A warehouse probe
(`density:<Fact>:<grain>`) decides this and the result is in `pbi-shaped-model.json` (`time_density`). With no
probe result the element is still built and the run prints and lists "time-axis density not verified".

**Date fields.** A date-table field binds to a calendar level only when that is provable: the `Date`/`Day` column, a
calculated column `DATE(YEAR([Date]),MONTH([Date]),1)` or `STARTOF*([Date])`, or an integer Year, Quarter or Month
Number. Grouped elements carry the integers as extra keys of the grain level (`Year Number`, `Quarter Number`, `Month
Number`). A Quarter or Month Number with no Year beside it, and any fiscal, week, name, key or physical Month Start
field, gets no binding. (This integer-key shape is covered offline only; it is not yet run live.)

**Rolling windows.** A report filter on a non-date table (a list with no blank member) is written into the rolling
SQL as a null-safe, case-insensitive semi-join along the same relationship path; the rolling record names it
(`report_filters`). A Date-table filter is replaced inside the window by Power BI and is not applied. A filter that cannot
be written exactly sends the fact's rolling measures to class D. An empty window reads blank. `DATESBETWEEN` as a rolling
window is built only as `MAX(<date column>) - N .. MAX(<date column>)` over one column, like `DATESINPERIOD`. A prior
period (PY, PP, YoY %) at day grain is class D ("day-grain prior period not probed"). Each hold-back is in `limits.md`.

**Report filters.** A report-level filter applies to fact visuals through null-safe, case-insensitive filters on the fact's child. When
a fact carries the filter, the dimension element is left unfiltered (filtering it would blank the fact's
`Lookup()` columns). A slicer value list or a dimension-only visual therefore still shows the excluded members.
This is a listed limit.

**Slicers no element reaches.** A slicer whose field no element on its page reaches (for example, outside a page
summary's grain) is dropped and listed; it also trips the field-loss gate. This is a v1 limit. The follow-up is a
one-column value-list element per such slicer.

**DATATABLE calculated tables** become Custom SQL rows in both shapes, with literals typed from the declared column
types and escaped per warehouse dialect. A table whose cells do not match its declared types is skipped, not coerced.
A literal-rows element has no `FROM`, so it is not materialized and the native-source probe skips it in this mode.

**Materialization.** By default: generated summaries, completed page summaries, flattened children and Custom SQL fact sources are
materialized; plain warehouse-table facts and their children are not (a materialized child was no faster on
the test data). Children inherit a materialized base; relationship joins still run live. Sigma never drops
materialized tables when a schedule or model is deleted; that cleanup is a warehouse-side step.

**Flattening (`--flatten`).** A flattened child (`<Fact> (flattened)`) carries the related columns as
`Lookup()` calc columns in folders named after the dimension tables, with no relationships. Use it only for a busy,
join-heavy fact; it is refused for a fact where it gains nothing, and it is materialized.

## Flags

| Flag | Meaning |
|---|---|
| `--model-shape pbi\|views` | `pbi` builds this shape; `views` (default) is the existing build. |
| `--flatten A,B` | With `pbi`: Power BI tables to flatten, as above. |
| `--shape-probe-results FILE` | With `pbi`: replay captured key-check and slicer-carry results (`{"<key>": <sigma-sql-probe result>}`) instead of querying the warehouse. Offline runs and the corpus case use it. |
| `--allow-unverified-keys` | With `pbi`: continue when a relationship's key cannot be verified. The relationship is kept, and the waiver (with the keys) is recorded in `pbi-shaped-model.json`. Without it, an unverified key aborts with exit 10. |
| `--materialization-cron CRON` (+ `--materialization-timezone`, `--materialization-elements`) | Opt-in schedules for the materialization targets above; cron is required, timezone is IANA, elements narrows the targets. |
| `--scaffold-page-facts [PAGES]` | Draft class D page summaries into `<WORK>/page-facts-draft` (default: pages classified page-fact). With `--stop-before-post` it writes nothing to Sigma. |
| `--page-facts DIR` | Integrate the completed page summaries (`<page>/page-fact.json`) as data model elements the page's charts read, and wire their slicers. Needs `--connection`. |

Without `--page-facts`, class D measures and visuals are held back and recorded (map and limits); the field-loss gate then exits 10 unless `--allow-field-loss` is passed. The live key check and
slicer-carry probes need `--probe-sources`, `--connection` and `--folder`; without them both are skipped and
the run says so on the console, in `pbi-shaped-model.json` and in `limits.md`.

## Fallbacks the probes proved

| Rule | Fallback used |
|---|---|
| A metric reading a related column fails on the base | child element with a `Lookup()` chain (the "(source)" split) |
| Metric folders (`folders[].items` rejects metric ids) | the metric keeps its name; its description carries the Power BI display folder. Column folders still work |
| Rolling N days with `MovingSum` (counts rows, wrong after day gaps: 65% of days off in the probe) | Custom SQL summary over a dense day spine |
| Axis-following YTD/prior period | grouped child, Year as its own outer level, `CumulativeSum` / `DateLookback`; slicer fields only as outer levels |
| Parent metric inside a grouped element | a `[Metrics/<name>]` column on it (`[Sales Amount]` alone fails) |
| Report-wide filter that keeps NULL categories | `Lookup()` chain column plus a null-safe filter (not the relationship-path column) |
| Value list on a dimension column | direct data model source when some workbook element reads that element; otherwise a chart-domain list (it has a NULL member the dimension list lacks) |
| Boolean slicer | text filter column plus a list control |
| Renamed columns | set the display name; the formula keeps the physical token |
| Second (inactive) relationship to Date | works as a named relationship; no role-playing copy needed |

## Limits (stated up front in `limits.md`)

- **Class D.** Measures and visuals that need a page summary cannot look like Power BI; they need a completed
  scaffold, and the map says where each went. Visuals that mix measures from different summaries
  drop the measures their summary lacks; each such visual is listed.
- **Bidirectional and many-to-many relationships** are carried only where Sigma can express them; the limits
  file names what the measure does instead.
- **Live pages.** A page with slicers a summary cannot carry reads a live element: exact, but a warehouse query
  on every slicer change. Class D summaries and grouped summaries that cannot carry are reclassified or sent to
  the page-summary brief.
- **Physical names on non-friendly-name connections.** Sigma requires warehouse-table element names to be the
  physical table names there, so plain table reads keep warehouse names. The log records each reset. A
  friendly-name connection is unaffected.
- **CALCULATE-override measures.** A measure whose CALCULATE replaces a filter on a column is built from its
  literal filter, but a Sigma slicer on that column still applies. A visual that binds the filtered column on an axis,
  or sits under a slicer, page, report or visual filter on it, is class D (held back); the metric's description says so.
- **Controls not applied in live SQL.** Non-list, non-boolean and non-date controls are not applied inside a
  live element's SQL; each is listed with its reason.
- **Report filters and unreached slicers**, as above.
- **Time-axis density and non-additive reads**, as above.
- **Not in this mode:** reuse of an existing data model (the scan runs and says reuse is unsupported), bookmarks,
  and Phase E enhancements; the default shape keeps them.
- **Optional customer step:** Power Query SQL stays Custom SQL; the report offers it as a warehouse `CREATE
  VIEW` the customer can create and point the element at. The skill never creates it.

## Runtime checks in this mode

- **Phase 6 freshness** counts rows at each table's data model source (following child elements down to the
  warehouse table or Custom SQL) through the warehouse probe, and classifies MATCH / STALE-EXPLAINED / DIVERGENT as
  in the default shape. With no probe it reports SKIPPED with the reason.
- **Phase 6b control-flip** takes each list control's flip value from the warehouse, through the fact, most frequent
  value first, including page-summary Custom SQL. Switches and date ranges are picked by the usual probe. A control
  it cannot resolve (a computed column, no warehouse result, no probe) is listed as UNVERIFIED with the reason in
  `limits.md`.
- Both need `--probe-sources` with `--connection` and `--folder`, or `--shape-probe-results` to replay.

## Report files

Written into the work directory by `scripts/pbi-shaped-report.rb` (read-only: it never writes to a source or to Sigma):

| File | Holds |
|---|---|
| `pbi-map.json`, `pbi-map.md` | where each Power BI table, relationship, measure, visual and slicer went, with the reason when it is not one-to-one (split, renamed, re-keyed, dropped, summary, live, not carried, held back) |
| `limits.md` | the limits above that this run hit: held-back visuals, key check not run, as-of measures, rolling windows and report filters, date fields, USERELATIONSHIP, held-back time-intelligence forms, blank-as-zero, DISTINCTCOUNT, unreached and unapplied slicers (including a control with no column reaching an element), unverified controls, time-axis density, with row counts behind each carry/live decision |
| `comparison.json`, `comparison.md` | with `--compare-dir <other work dir>`: both shapes side by side (data model and SQL element counts against the 30-40 guidance, workbook elements, hidden or unread elements, clicks from chart to source, timings, parity) |

Run it on a finished work directory: `ruby scripts/pbi-shaped-report.rb --tmsl model.bim --signals signals.json
--dm-spec dm-spec.json --wb-spec workbook-spec.json --out-dir DIR [--compare-dir OTHER_WORK]`. Both shapes get a
map and limits; the pbi shape also reads `pbi-shaped-model.json`, `measure-classes.json` and `slicer-carry.json`.

## Security refusal

The mode does not port row- or column-level security. If any role has a table filter or a column or table permission,
(including a table-level `metadataPermission: none`) it stops before building anything, prints an open question naming the roles, and exits 10. Rerun without
`--model-shape pbi`; the default shape ports security (see "Security" in SKILL.md). Roles with no permissions
do not stop it.
