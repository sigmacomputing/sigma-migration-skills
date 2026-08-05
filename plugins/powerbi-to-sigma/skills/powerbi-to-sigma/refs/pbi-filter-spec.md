# Power BI report-filter → Sigma parse/map spec

Built from 36 **verbatim** filter examples harvested from public PBIR + classic
reports (microsoft/fabric-toolbox, FabricTools/pbir-samples, MS Analysis-Services
SamplePBIP, databricks migration-accelerator, + community dashboards) — 2026-07-17.
This is the contract for `extract-pbir.py` `_filter_signals()` (extract) and
`build-workbook-from-pbir.rb` filter application. Real fixtures live in
`fixtures/pbir-filters.json`; the unit test asserts the extractor against them.

## 0. Container normalization (pre-parse — do this first)
- **PBIR** (exploded): `filterConfig.filters[]` — native JSON array, target key **`field`**,
  `howCreated` is a **string** (`User`/`Auto`/`Drill`). Scope: `report.json`/`filters.json`
  = report; `page.json` = page; `visuals/<id>/visual.json` = visual.
- **Classic**: `<container>.filters` is a **JSON string** → `json.loads` the file, then
  `json.loads` that string again (double-decode). Target key **`expression`**; `howCreated`
  is an **integer**. Scope: top-level `filters` = report; `section.filters` = page;
  `visualContainer.filters` = visual.
- Empty = `"[]"` or absent → no filters (guard; never assume `filter`/`Where` exists).
- **Route by BOTH `type` AND the Condition tree** — never `type` alone (a `Categorical`
  can carry `Not(In)`; `Advanced` `type` can sit *after* the `filter` key).
- **Auto/Drill skip:** drop filters that are cross-highlight/drill artifacts with no
  user predicate. `howCreated` string `Auto`/`Drill`, or int — but int `0` appears on BOTH
  auto AND ordinary user filters (ambiguous), and `3`=Include/`4`=Exclude drill artifacts
  still carry real predicates. Rule: skip only when NO user-meaningful predicate; keep
  Include(3)/Exclude(4). (Open Q — confirm via Fabric round-trip.)

## 1. Per-type parse + Sigma map
| PBI shape | Parse path | Normalized signal | Sigma |
|---|---|---|---|
| **Categorical In** | `filter.Where[0].Condition.In.Values` (rows-of-tuples; cols at `In.Expressions[].Column`) | `{type:list, mode:include, values, selectionMode: single iff objects.general[0].properties.requireSingleSelect==true}` | `list` include |
| **Categorical Not(In)** | `Condition.Not.Expression.In.Values` | `{type:list, mode:exclude, values}`; values==[null] → exclude-null | `list` exclude / is-not-blank |
| **isInvertedSelectionMode** flag | `objects.general[0].properties.isInvertedSelectionMode==true` | flip `mode:exclude` on the In values | `list` exclude |
| **type=Include / type=Exclude** | `Condition.In` / `Condition.Not.(In\|Or.{Left.In,Right.In})`; target from `filterExpressionMetadata.expressions[0]` if no top-level field | list include/exclude | `list`; **multi-column In (≥2 cols/tuple) → coverage** |
| **Advanced Comparison** (single) | `Condition.Comparison.{ComparisonKind,Left,Right.Literal}` | `{type:number-range, condition:[{op:_CMP_OP,value}]}` | `number-range` (one bound) |
| **Advanced And** (band + Not(==null)) | `Condition.And.{Left.Comparison, Right.Not.Expression.Comparison(==null)}` | `{type:number-range, condition:[min,max], notNull}` (Right arm = not-null guard, not a bound) | `number-range` min+max |
| **Advanced Contains** | `Condition.Contains.{Left,Right.Literal}` (no ComparisonKind) | `{type:condition, op:contains, value}` | text `Contains()` |
| **Advanced Comparison on Measure** | target at `field.Measure`; `Comparison.Left.Measure` | `{type:measure-filter, condition}` | **coverage** (post-aggregate/HAVING) unless element supports it |
| **Advanced Comparison on HierarchyLevel** | `field.HierarchyLevel.{...PropertyVariationSource.Property, .Level}` | `{type:number-range, target:baseDateCol, grain:Level, condition}` | date-part column (DateTrunc/DatePart) or **coverage** |
| **RelativeDate Between (Last N)** | `Condition.Between.{Expression.Column, LowerBound.DateSpan.Expression.DateAdd.{Amount,TimeUnit}, UpperBound.DateSpan.Now}`; inner `DateAdd(Now,+1,Day)` = includeToday | `{type:date-range, window:{anchor:last, n:abs(Amount), unit:TIMEUNIT[TimeUnit], includeToday}}` | `date-range` control (relative last-N) |
| **RelativeDate (This)** | single `Comparison{ComparisonKind:0, Left.Column, Right.DateSpan.{Now,TimeUnit}}` | `{type:date-range, window:{anchor:this, unit}}` | `date-range` control (this-period) |
| **RelativeDate slicer** | ALSO scan `singleVisual.objects.general[0].properties.filter.filter` (one level deeper than filterConfig) | same window decode | `date-range` control |
| **TopN (populated)** | N at `filter.From[Subquery].Expression.Subquery.Query.Top`; rank at that `Query.OrderBy[0].{Direction,Expression.(Measure\|Aggregation)}`; ranked col at `Query.Select[0].Column`; outer `Where.In.Table.SourceRef=='subquery'` (NO Values) | `{type:top-n, n, direction:{1:asc,2:desc}, rankBy}` | `top-n` filter |
| **TopN (empty)** / **field-only Categorical** / **filters:"[]"** | no `filter`/`Where` | `{predicate:none}` | coverage note / empty control — never fabricate a predicate |

Enums: `_CMP_OP {0:'=',1:'>',2:'>=',3:'<',4:'<='}`. Relative `TIMEUNIT {0:Day,1:Week,2:Month,3:Year}` (INTERNAL — not the powerbi-client JS enum; do NOT treat 5 as relative). Literal decode is **type-driven**: `'x'`→text (always, even numeric-looking), `true`/`false`→bool, `N…L`→int, `N.N…D`→double, `N…M`→decimal, `N…F`→float, `null`→null, bareword number→number.

## 2. Scope → Sigma placement
report/page filter → page/master-level Sigma filter (all elements on the Data-page master inherit — the bookmark `_bake_filters` pattern); visual filter → element filter. Target resolves through the same master-map/`field_spec` path so an unresolved target degrades to coverage, never a broken POST. `isHiddenInViewMode`/`isLockedInViewMode` still constrain data — apply (optionally map to control visibility/lock).

## 2b. Track 3b APPLICATION — shipped shapes + decisions (build-workbook-from-pbir.rb)
**VERIFIED element-filter shapes** (live PUT+GET round-trip 2026-07-17 on TJ Databricks Demo; memory `reference_sigma_element_filter_shapes`). These are the ELEMENT `filters[]` shapes, distinct from a *control*'s shape:
| signal type | Sigma element filter |
|---|---|
| `list` | `{id, columnId, kind:"list", mode:"include"\|"exclude", values:[…]}` |
| `number-range` | `{id, columnId, kind:"number-range", min?, max?}` — **`min`/`max`, NOT the control's `low`/`high`** (element `low`/`high` and positional `value:[lo,hi]` are silently dropped). Needs a NUMERIC target column. Bounds are inclusive; a PBI `>`/`<` is applied inclusively. |
| `top-n` | `{id, columnId, kind:"top-n", rankingFunction:"rank", mode:"top-n", rowCount:N}` — **visual scope only** (a top-n on a shared master caps every element sourcing it — memory `sigma-source-element-filter-propagates`). |

**Placement:** visual filter → the built element's own `filters[]` (only when the target column is PROJECTED on the element — element filters reference the element's own columns; resolved via the `_qr_cids` map). `pivot-table` element filters are silently dropped by Sigma → coverage. page/report filter → the source MASTER element(s) carrying the column (propagation = page-filter semantics); a page filter is applied only to masters used SOLELY by that page (a shared master can't be isolated → coverage); a report filter → every master carrying the column.

**Coverage (never a broken/inert filter):** date-range (no static element date filter — routed to coverage with a date-range-control action; **control emission is the documented fast-follow**), measure/HAVING, multi-column key, text/`contains`/`starts-with` conditions, unmodeled trees, page/report-scope top-n, unresolved + non-projected targets, pivot element filters. `predicate:none` (empty slots) = a faithful no-op → noted, never fabricated.

## 3. Open questions — DECIDED (Track 3b)
1. `howCreated` skip rule — kept as extract-3a shipped (skip Auto/Drill string; int 2=Drill; keep Include(3)/Exclude(4); int 0 ambiguous→keep). Unchanged.
2. Measure/HAVING → **coverage** (`degraded`, not recoverable). No element HAVING.
3. `_lit_value` typed decoder — done in 3a (`_filter_lit`, separate from the CF caller).
4. Multi-column key → **coverage** (no per-column decompose — loses AND-of-tuples).
5. RelativeDate `includeToday` → routed to coverage with the exact window (`last N unit, incl. today`) named in the action; **fidelity preserved when the date-range control is emitted** (control `includeToday` maps 1:1). No 1-day fudge shipped.
6. `Next N` / sub-day RelativeTime — STILL not shipped (`anchor:"next"` + Hour/Minute unconfirmed) → coverage.
7. HierarchyLevel grain → coverage (part of the date-range control fast-follow).
8. page/report scope → **page-wide filter on the source master**, with page-isolation (single-page master only) so a shared master isn't cross-page contaminated.
9. Empty slots → **skip + coverage note** (consistent; no disabled control).
10. TopN rank-by — Sigma `top-n` ranks by the row filter's own column via `rankingFunction:"rank"`; PBI's measure/direction rankBy is not separately expressible → shipped as rank-desc on the target column (direction/measure rankBy is a known simplification, noted in coverage detail when it differs).

Sources + full open-question detail: run transcript of the `pbir-filter-fixtures` sweep (36 examples, 24 public report URLs).
1. `howCreated` skip rule across string/int formats (int 0 ambiguous) — confirm via Fabric round-trip.
2. Measure-level (HAVING) filters — element-filter support or always coverage?
3. `_lit_value` typed decoder (bool/null/datetime, unescape `''`→`'`) without regressing the conditional-formatting callers.
4. Multi-column In (composite key) — per-column decompose (loses AND-of-tuples) or coverage?
5. RelativeDate `includeToday` fidelity vs a 1-day boundary + coverage flag.
6. `Next N` + sub-day RelativeTime (Hour/Minute) — internal TimeUnit codes UNCONFIRMED (not in corpus); do NOT ship until confirmed.
7. HierarchyLevel grain → which Sigma DateTrunc/DatePart column; coverage if absent.
8. page/report scope → page-wide filter vs replicate per element.
9. degenerate/empty slots → disabled control vs skip+coverage (pick one, consistently).
10. TopN rank-by beyond Sum-desc (Avg/Count/Min/Max/Measure, ascending) — Sigma top-n support?

Sources + full open-question detail: run transcript of the `pbir-filter-fixtures` sweep (36 examples, 24 public report URLs).
