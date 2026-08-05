# Tile-grain ground-truth oracle — derivation, execution, comparison, gate

The PLAN-v3 centerpiece: an oracle that answers **"are the numbers right?"** by
deriving, per parity-plan tile, the SQL that computes the tile's value straight
from the warehouse — from the **source .twb signals**, never from the built
workbook. A source that renders `##` becomes irrelevant: warehouse SQL doesn't
render. Part A (PR-5) covers derivation + execution + the coverage ledger;
part B (PR-6) compares the actuals against the Sigma element exports, stamps
`numeric_parity`, and wires the hard coverage gate (gate 18, exit 25).

## Independence contract

Ground-truth SQL derives from the .twb ONLY:

- **zones** — `parse-twb-layout.rb` output (`dashboard-layout.json` +
  `*-meta.json`): shelves, aggregations, worksheet filters, channels;
- **the raw .twb** — datasource table/join specs (physical `<relation
  type='join'>` AND the 2020.2+ relationship/object-graph model) and
  datasource/extract-level filters;
- **extracted calc formulas** — `calc-fields.json` (falling back to the layout
  meta's `columns_by_guid` formulas).

`scripts/lib/ground_truth_sql.rb` and its drivers import **nothing** from
`build-charts-from-signals.rb` and read nothing from the built wb-spec — the
oracle cannot share the builder's misreadings (test-enforced in
`test-ground-truth-derive.rb`).

**The documented common-mode residue:** a calc measure's SQL consumes the same
extracted formula text the DM build translated. Every such dependency is
recorded per tile in `provenance.calc_dependencies` (name + `formula_hash` +
source artifact) so a translation bug is *traceable*; anchors
(`refs/source-anchors.md`) remain the fully independent channel.

## Classifications — the coverage ledger

Every parity-plan chart gets **exactly one** entry in `ground-truth-plan.json`;
nothing silently drops out (`summary.coverage_complete` asserts it):

| classification | meaning | downstream |
|---|---|---|
| `warehouse-sql` | entry carries executable `SELECT <dims>, <AGG(measure)> FROM <.twb-joined tables> WHERE <worksheet + datasource filters> GROUP BY …` | `run-ground-truth.rb` executes it |
| `vds` | the tile's value is a window/table calc (RUNNING_*, RANK, percent-of-total quick calc, …) — Tableau must compute it. **Demoted to `anchor-only` when the tile's datasource carries a join-plan ledger join not proven `unique`** (see "VDS is NOT a valid oracle for fan-out-fed tiles" below) | the existing `scripts/vds-oracle.rb` path |
| `anchor-only` | blends, LOD calcs, relationship models with non-unique related tables, IF/CASE calcs and filter kinds outside the mechanical SQL subset — with the **reason named** | rendered-source anchors carry the value bar |
| `unverifiable(reason)` | no source zone matched / no measures / no resolvable warehouse table | named in the report; PR-6 will require a waiver |

Derivation is deliberately conservative: it emits SQL only for constructs it
can rewrite **mechanically** (plain aggregates, user-agg ratio calcs with a
`NULLIF` divide-by-zero guard, `ZN`→`COALESCE`, `COUNTD`→`COUNT(DISTINCT …)`,
member/range/wildcard filters, parameter defaults substituted and recorded in
`provenance.parameters`). Anything it cannot prove, it refuses with a named
reason — a fanned-out or guessed ground truth would be silently wrong, the
exact failure class this oracle exists to catch. Relationship-model joins are
derived only when every related table is unique-keyed (a LEFT JOIN to a unique
key cannot change the fact grain); otherwise the tile is anchor-only rather
than replicating Tableau's per-viz join culling.

## ⚠️ VDS is NOT a valid oracle for fan-out-fed tiles

Run-found hazard (Twin-B e2e, 2026-07-19): **VDS queries the datasource
through Tableau's logical layer, which CULLS relationship joins per-viz — VDS
returns relationship-culled (un-fanned) data.** A tile whose rendered value is
fed by a fan-out join (a `.twb` join whose right side is not proven unique on
the keys) therefore gets a VDS answer that can **agree with a Sigma build that
silently dropped the join** — a false-green oracle for the exact defect gate
16 (the join-cardinality ledger) exists to catch. In that live run the DM
shipped without an embedded-DS LEFT JOIN and every tile diverged 3–23×; a
VDS-based ground truth would have vouched for the wrong numbers.

Mechanically enforced: `derive-ground-truth.rb` reads the workdir's
`join-plan.json` (lib/join_plan.rb — gate 16's ledger) and **demotes `vds` to
`anchor-only`** (reason `vds-oracle unsafe: …` naming the join) for any tile
whose datasource carries a ledger join entry not at status `unique`. A join
**proven unique** by `probe-join-keys.rb` cannot fan out, so the tile keeps
its `vds` classification — probe the ledger *before* deriving ground truth to
keep VDS coverage. `warehouse-sql` tiles are unaffected: their SQL replicates
the join explicitly, fan-out and all. Rendered-source anchors also remain
valid — the rendered source *does* see the fan-out.

## Artifacts

- `<WORK>/ground-truth-plan.json` — the ledger: per-tile classification, SQL,
  per-tile provenance (zone/worksheet, dims, measures, which worksheet +
  datasource filters fed the WHERE, calc dependencies, parameter values),
  `generated_at`, and a `consumer` pointer.
- `<WORK>/ground-truth-actuals.json` — per-entry execution results (`ok` rows,
  `error`, `row-explosion`, `deadline-skipped`, `skipped-<classification>`),
  stamped with `plan_generated_at` so PR-6 can bind actuals to the exact plan.

## Running it

```bash
# 1. Derive the ledger (offline; after parse-twb-layout + auto-parity-plan):
ruby scripts/derive-ground-truth.rb --workdir <WORK> \
  [--twb <WORK>/workbook-content.twb] [--db <DB> --schema <SCHEMA>]

# 2. Execute the warehouse-sql entries (same probe-workbook Custom SQL seam
#    as probe-join-keys.rb — no new credential path):
ruby scripts/run-ground-truth.rb --workdir <WORK> \
  --connection-id <id> [--folder-id <id>] [--timeout 600] [--row-limit 5000]

# offline tests: --fixture DIR with entry-<plan-index>.json canned results
```

Bounded-exports rules (PR #426 lessons): one **total** `--timeout` deadline for
the run (per-entry progress lines; expiry → loud `[PARTIAL]`, exit 3, never a
hang) and a `LIMIT`-guarded query per entry — ground truth is aggregated, so
more than `--row-limit` rows means a missing/exploded GROUP BY and fails loud
(`row-explosion`, exit 2).

## Part B — comparison (`scripts/verify-ground-truth.rb`)

```bash
# 3. After collect-parity-actuals.rb (Sigma-side exports) and, when present,
#    verify-anchors.rb / vds-oracle.rb:
ruby scripts/verify-ground-truth.rb --workdir <WORK> \
  [--tol 1e-4] [--extract-tol F]   # extract-tol honored ONLY on extract-marked workdirs
```

Joins `ground-truth-actuals.json` rows against the tile's Sigma element export
(`parity-actuals.json`, the collect-parity-actuals shapes — status markers like
`render-verify-required` make the tile `unverified`, never a false diverge) on
the tile's **dims**, canonicalized by `scripts/lib/dim_canon.rb` — the same
canonicalizer `verify-parity.rb` uses (incl. the e2e-defect date forms
`1/4/2026 12:00:00 AM` and `Feb 4, 24`), so "the same bucket" can never mean
two different things across oracles. Each measure compares by relative diff
against `--tol` (strict, default `1e-4`); actuals must bind to the exact plan
(`plan_generated_at`), else the run is refused as stale.

Per tile it stamps — into `parity-final.json` (**extending** its existing
shape; also written standalone to `numeric-parity.json`):

```json
"numeric_parity": { "plan_generated_at": "…", "tiles": {
  "<chart>": { "oracle": "warehouse-sql|vds|anchors",
               "verdict": "match|diverge|unverified",
               "max_rel_diff": 0.0, "rows_compared": 12,
               "reason": null, "conflict": { "…": "only when oracles disagree" } } } }
```

`vds` tiles read their verdicts from `vds-oracle.json` (match/near = verified);
`anchor-only`/`unverifiable` tiles are credited **only by VALUED anchors** —
numeric anchors with `provenance` `view-csv`|`vds` (never `png-eyeball`, never
name-only roster labels) that matched **in** the tile (`refs/source-anchors.md`).

Exit codes: 0 clean; 1 usage/missing/stale inputs; 2 = any **diverge** or
**conflict** (FATAL — names tile + measure + both values).

## Anchors coexistence contract

**Anchors are rendered-source truth; this oracle is warehouse truth.** They
are different oracles and a disagreement is evidence of a real bug — never
noise to reconcile:

| oracle (warehouse) | anchors (rendered source) | meaning |
|---|---|---|
| diverge | matched in the tile | **FATAL-investigate: DATA BUG** — the warehouse disagrees with what the source rendered (drifted/wrong warehouse data, or a wrong ground-truth derivation) |
| match | missing (hint aimed at the tile) | **FATAL-investigate: TRANSLATION/SOURCE-READING BUG** — Sigma faithfully computes something the source never rendered (wrong tile semantics) |
| match | matched | verified — two independent oracles agree |

`verify-ground-truth.rb` **never auto-resolves a conflict**: it records
`conflict` on the stamp, prints BOTH sides' evidence, and exits 2. Never edit
the ground truth or the anchors to make them agree with the workbook.

## The hard gate — gate 18 (`assert-phase6-ran.rb`, exit 25)

**Every displayed tile must be numeric-verified by ≥1 oracle**: a
`numeric_parity` `match` (warehouse-sql / vds / valued anchors), or a named
waiver in `ground-truth-plan.json`:

```json
"coverage_waivers": [ { "tile": "<chart>", "reason": "<why no oracle can verify it>" } ]
```

`anchor-only`/`unverifiable` tiles **without** valued-anchor coverage fail the
gate NAMING each tile. A `diverge` or `conflict` stamp is **never waivable**.
Missing/stale stamps fail ("the comparison never ran"); a workdir carrying the
derivation inputs (a `.twb` + `parity-plan.json`) with **no** ledger at all
also fails, belt-and-braces. There is **no skip flag** — the ledger waiver is
the only sanctioned escape (the join-plan / lod-audit doctrine: evidence lives
in the ledger, not in a CLI flag a re-run forgets).
