# tableau / logical-model-objectgraph

## Provenance — READ THIS FIRST

**`workbook-content.twb` in this directory is now GENUINE Tableau Server
output.** It was published live to a real Tableau Cloud site (a
`class='snowflake'` federated datasource, a real object-graph relationships
model, a worksheet, and a dashboard) via the REST API
(`POST /api/3.22/sites/{site}/workbooks?overwrite=true`, multipart/mixed,
`connectionCredentials` embedding), then downloaded back
(`GET /sites/{site}/workbooks/{id}/content`) — the file in this directory is
that downloaded, Tableau-Server-processed XML, not the hand-typed upload.

This replaces the PREVIOUS state of this fixture, which was hand-authored/
derived XML that only looked like real Tableau output (see git history for
that version and its own provenance note). That version's own MANIFEST said a
follow-up would replace it with genuine served output once available offline
— this is that follow-up.

**Identifiers neutralized for repo hygiene.** The live build used a real
Snowflake account/schema/connection already used by several other live
fixtures in this repo, and a dedicated scratch service role/user created for
this Tableau connection specifically. Per `tools/hygiene-patterns.txt` (this
repo's hard no-test-org-identifiers rule, enforced by `tools/hygiene-sweep.sh`
on every commit), the served `.twb`'s connection `server`/`dbname`/`schema`
attributes were replaced with neutral placeholders
(`example.snowflakecomputing.com` / `ANALYTICS` / `PUBLIC`, matching this
corpus's existing placeholder convention) before vendoring. This is a
post-download string substitution on 2 attributes and every `[SCHEMA].[TABLE]`
path — the object-graph, metadata-records, relationships, worksheet, and
dashboard structure Tableau actually produced are otherwise byte-for-byte
untouched. Real environment specifics (which account, which connection ID,
which live-verified evidence) are not repeated in this file for the same
reason; they were reported to the requester directly and are recorded on
`[bead]`'s note.

### What changed from the hand-authored version, and why (live finding)

The hand-authored fixture modeled Tableau's "auto-matched, no serialized key"
case (`FACT_WIDE → DIM_CUSTOMER`, now `LMOG_FACT_WIDE → LMOG_DIM_CUSTOMER`) by
omitting `<expression>` from that `<relationship>` entirely — an assumption
about what genuine Tableau output looks like that was **never verified
against real Tableau** until this task.

**It's wrong.** Publishing that exact shape to a real Tableau Server returns:

```
HTTP 400011: There was a problem publishing the file '...'..
(0x2805CF18 : com.tableausoftware.domain.exception.NativeException:
The relationship/expression tag is missing or invalid)
```

Real Tableau Server requires every `<object-graph><relationships><relationship>`
to carry some `<expression>` — a relationship with none does not survive
publish. This fixture's `LMOG_FACT_WIDE → LMOG_DIM_CUSTOMER` relationship was
changed to a plain serialized physical-equality expression
(`CUSTOMER_KEY = CUSTOMER_KEY`) to publish successfully.

**Consequence for the derivation ladder this fixture exercises:** case 1
(`LMOG_DIM_CUSTOMER`) no longer exercises the name-inference rung — it is now
`derivedVia: "serialized"`, the same rung as the plain-key case. The
name-inference rung (a relationship whose *serialized* expression is present
but not usable as a *physical* key — e.g. wrapped in `IFNULL`/`DATETRUNC` —
so the converter falls back to matching column names) is now exercised
**solely** by case 4 (`LMOG_DIM_STORE`, unchanged: `IFNULL([STORE_KEY],-1) =
[STORE_KEY]`). This is a genuine, live-verified correction to the original
fixture's design, not a downgrade of coverage — the ladder's other 3 rungs
(serialized, mixed/partial, unwired-but-recorded) are all still exercised, and
the STORE case alone is sufficient to prove name-inference recovery (see
`test-relationship-derivation.rb`'s test 7, repointed from
`LMOG_DIM_CUSTOMER` to `LMOG_DIM_STORE` accordingly).

**One further live-only implication:** a relationship this repo's own
`converter/tableau.mjs` treats as "no serialized key at all" (the ladder's
name-inference-from-nothing rung, as originally imagined) may not be
constructible via a genuinely Tableau-Server-processed `.twb` at all — every
relationship Tableau will actually publish carries an expression. If a real
prospect's Tableau workbook truly has zero-condition auto-matched
relationships reaching Sigma's converter, they most likely arrived there via
some path other than a hand-typed `.twb` upload (e.g. Tableau Desktop's own
internal auto-match UI may serialize an empty-but-present `<expression>`
rather than omitting the tag, which would still trigger the same ladder rung
in the converter — this was not verified either way; flagging as an open
question, not a claim).

## The shape (what this fixture exercises)

One fact (`LMOG_FACT_WIDE`, 64 columns) related to five dimensions:

1. **`LMOG_FACT_WIDE` → `LMOG_DIM_CUSTOMER` (plain serialized physical key).**
   `CUSTOMER_KEY = CUSTOMER_KEY` (metadata-record ordinal **54** on
   `LMOG_FACT_WIDE`). Expected: `derivedVia: "serialized"`, not partial.
2. **`LMOG_FACT_WIDE` → `LMOG_DIM_PRODUCT` (mixed physical + computed).** The
   `<expression op='AND'>` ANDs together one physical equality
   (`PRODUCT_KEY = PRODUCT_KEY`, metadata-record ordinal **57** on
   `LMOG_FACT_WIDE`) with one purely-computed condition
   (`DATETRUNC('month',[ORDER_TS]) = [EFFECTIVE_MONTH]`). The physical half
   wires; the computed half is dropped. Expected: `derivedVia: "serialized"`,
   `partial: true`, `droppedConditions: 1`.
3. **`LMOG_FACT_WIDE` → `LMOG_DIM_DATE` (computed-only, inference fails).**
   The sole condition is `DATETRUNC('day',[ORDER_TS]) = [CALENDAR_KEY]` — no
   physical column on either side. `LMOG_FACT_WIDE` and `LMOG_DIM_DATE`
   deliberately share **no** column name (`CALENDAR_KEY` is never duplicated
   on the fact), so the name-inference fallback also fails. Expected:
   recorded in the ledger, `derivedVia: "unwired"`, never silently dropped
   from the report.
4. **`LMOG_FACT_WIDE` → `LMOG_DIM_STORE` (computed-only, inference SUCCEEDS —
   this fixture's sole remaining name-inference case; see the live-finding
   note above).** The sole condition is `IFNULL([STORE_KEY],-1) =
   [STORE_KEY]` — computed on its left operand, so no physical pair survives.
   `LMOG_FACT_WIDE` and `LMOG_DIM_STORE` DO share a key-shaped column name
   (`STORE_KEY`, metadata-record ordinal **62** on `LMOG_FACT_WIDE`), so
   name-inference fires and wires it — but the `IFNULL` null-coalescing
   Tableau required is dropped, making the wired join WIDER than Tableau's.
   Expected: `derivedVia: "name-inference"`, `partial: true`,
   `droppedConditions: 1`, plus a dropped-condition warning.
5. **`LMOG_FACT_WIDE` → `LMOG_DIM_REGION` (plain serialized physical key —
   NEW, added for this live pass, orthogonal to the derivation ladder above).**
   `REGION_KEY = REGION_KEY` (metadata-record ordinal **63** on
   `LMOG_FACT_WIDE`). Structurally identical to case 1 — what makes this case
   different is **`LMOG_DIM_REGION` is deliberately NON-UNIQUE on
   `REGION_KEY`** in the live warehouse table backing it (one key value
   duplicated across 2 rows). This is invisible to the offline converter (it
   only sees a clean serialized key) and exists specifically to exercise
   gate 16's live join-cardinality probe (`probe-join-keys.rb`) — see the
   live validation section below.

**Ordinal placement / pagination coverage.** `LMOG_FACT_WIDE` carries 64
metadata-record columns (ordinals 0–63); `CUSTOMER_KEY` sits at ordinal 54,
`PRODUCT_KEY` at 57, `STORE_KEY` at 62, and `REGION_KEY` at 63 — all past the
50-column boundary that the columns-endpoint pagination fix (#565,
`fix(tableau): paginate every columns-endpoint read`) addressed.
`test-relationship-derivation.rb` and this directory's `checks.sh` only
exercise the converter's in-process `.twb`-parsing path (no Sigma REST
calls), so the ordinal placement does not by itself invoke the paginated
`/columns` reader in an offline run — **that reader was exercised live, for
real, against the real warehouse table backing this fixture, and it found a
regression.** See "Live validation" below.

## Live validation (2026-08) — what was actually run, what passed, what didn't

This section documents the E2E live pass this fixture was built for: real
Snowflake tables, a real Tableau Server publish/download round-trip, the real
`converter/tableau.mjs` against the real served `.twb`, and a real gate-16
probe against the real warehouse. Unrounded, as measured.

### M1 — column-discovery pagination: LIVE REGRESSION FOUND AND FIXED

`discover-columns.rb` against the real 64-column warehouse table backing
`LMOG_FACT_WIDE` initially returned **50 of 64 columns** — silently truncated,
missing `CUSTOMER_KEY`/`PRODUCT_KEY`/`STORE_KEY`/`REGION_KEY` entirely. This
is exactly the bug class bead `[bead]` was originally filed for and
PR #565 (merged, tableau-to-sigma 1.3.5) was believed to have fixed
end-to-end. It hadn't, for this specific endpoint:

```
GET .../columns?limit=1000              -> 50 entries, nextPageToken: 50
GET .../columns?limit=1000&page=50      -> 50 entries AGAIN (page 1 repeats —
                                            `page` is silently ignored server-side)
GET .../columns?limit=1000&pageToken=50 -> 14 entries, nextPageToken: null
```

`Sigma.list_entries` (`shared/lib/sigma_rest.rb`) — what `discover-columns.rb`
and `discover-warehouse-columns.rb` were routed through by PR #565 — follows
a `nextPage` response field / `page` request param. The real
`/v2/connections/tables/<inode>/columns` endpoint never sends `nextPage` at
all; it sends `nextPageToken` and expects `pageToken`. `list_entries`'s
termination check fires after page 1 every time against this endpoint, so
the fix "worked" by every existing offline test (which stub the assumed
shape) while remaining silently broken live.

**Fixed** (this branch, plugin-local — see `scripts/lib/
warehouse_columns_pagination.rb`; bead reopened as `[bead]`, back
to P0). Re-verified live after the fix: `discover-columns.rb` against the
same real table now returns **all 64 columns**, with the four join keys at
their correct 0-based indices **54, 57, 62, 63**. Full plugin test suite
re-run: `PASS=196 FAIL=0`.

### M2/M3 — relationship derivation ladder: LIVE, against the genuinely served `.twb`

Running the real `converter/tableau.mjs` against this fixture's real,
Tableau-Server-served `.twb` (the exact file in this directory) produces
(rendered as plain text here, not a ```json fence, so it is not mistaken by
`corpus_check.py`'s manifest parser for the Expectations block at the bottom
of this file — that parser takes the FIRST ```json fenced block it finds):

```
{
  "serialized": 5,
  "wired": 4,
  "entries": [
    { "left": "LMOG_FACT_WIDE", "right": "LMOG_DIM_CUSTOMER", "derivedVia": "serialized", "keyCount": 1 },
    { "left": "LMOG_FACT_WIDE", "right": "LMOG_DIM_PRODUCT", "derivedVia": "serialized", "keyCount": 1, "partial": true, "droppedConditions": 1 },
    { "left": "LMOG_FACT_WIDE", "right": "LMOG_DIM_DATE", "derivedVia": "unwired", "reason": "no existing column name matches on both sides", "candidates": [] },
    { "left": "LMOG_FACT_WIDE", "right": "LMOG_DIM_STORE", "derivedVia": "name-inference", "keyCount": 1, "partial": true, "droppedConditions": 1 },
    { "left": "LMOG_FACT_WIDE", "right": "LMOG_DIM_REGION", "derivedVia": "serialized", "keyCount": 1 }
  ]
}
```

This matches `relationship-coverage.expected.json` byte-for-byte (regenerated
per the recipe below against the real served `.twb`) and is pinned by
`checks.sh` and `test-relationship-derivation.rb` (both updated for the new
table names, the 5th relationship, and the case-1 correction above; both
GREEN — see `checks.sh`'s own output for the exact pass lines).

Deriving the join-plan ledger (`scripts/lib/join_plan.rb`, the same module
`migrate-tableau.rb` calls during a real DM build) against this same real
`.twb` + the converter's real DM output produces one `federated-join` entry
per wired relationship (`LMOG_DIM_CUSTOMER`, `LMOG_DIM_PRODUCT`,
`LMOG_DIM_STORE`, `LMOG_DIM_REGION` — `LMOG_DIM_DATE` correctly absent, since
it never wired), each carrying `derived_via` and, for the partial cases,
`partial`/`dropped_conditions` — proof the DM-build path (not just the raw
converter) carries this fixture's ladder result through to what gate 16
actually probes.

### Gate 16 + PR #590 resolution surfacing: LIVE, against the real warehouse

`scripts/probe-join-keys.rb`, run against the join-plan ledger above with a
live Sigma connection, against the REAL warehouse tables:

```
==================== JOIN-CARDINALITY FATAL ====================
entry #3 (federated-join): LMOG_FACT_WIDE -> LMOG_DIM_REGION on (REGION_KEY)
  right side NOT unique at the key grain: 6 row(s) over 5 distinct key(s)
  sample duplicate keys:
    REGION_KEY=3  -> 2 rows
================================================================
probe-join-keys: 1 unresolved non-unique entr(y/ies) — the final gate (exit 23) will refuse GREEN.
  UNIQUE  #0 federated-join: LMOG_DIM_CUSTOMER unique on (CUSTOMER_KEY) — 20 row(s), 20 key(s)
  UNIQUE  #1 federated-join: LMOG_DIM_PRODUCT unique on (PRODUCT_KEY) — 15 row(s), 15 key(s)
  UNIQUE  #2 federated-join: LMOG_DIM_STORE unique on (STORE_KEY) — 10 row(s), 10 key(s)
  NON-UNIQUE  #3 federated-join: LMOG_DIM_REGION on (REGION_KEY) — 6 row(s) over 5 key(s)
```

Deliberately built that way: `LMOG_DIM_REGION` has 6 rows over 5 distinct
`REGION_KEY` values (one duplicated), and gate 16 caught it live, correctly,
against the real table — exactly the "field failure: target at a finer grain
than the key" class this gate exists to stop, and exactly the case this
fixture's 5th relationship was added to prove live (the offline converter
alone cannot see this — it only sees a clean serialized key; see case 5
above).

Resolved per the sanctioned remedy: a pre-aggregated helper query
(`SELECT REGION_KEY, MIN(REGION_NAME) AS REGION_NAME FROM <table> GROUP BY
REGION_KEY`) was verified live to be unique at the `REGION_KEY` grain (5
rows/5 keys), then the resolution was recorded:

```
ruby scripts/probe-join-keys.rb --workdir <W> --resolve 3 --how preaggregated \
  --reason "LMOG_DIM_REGION non-unique on REGION_KEY (6 rows/5 keys, REGION_KEY=3
  duplicated x2, live-verified 2026-08-03). Resolved via a pre-aggregated helper:
  SELECT REGION_KEY, MIN(REGION_NAME) AS REGION_NAME FROM <table> GROUP BY
  REGION_KEY, grouped to the REGION_KEY grain. Re-probed against that helper
  live: 5 rows/5 keys, unique — confirmed before recording this resolution."
```

`scripts/lib/join_plan_resolutions.rb` (PR #590 / bead `[bead]`, not
yet merged to `main` at the time of this fixture — cherry-picked onto this
branch to exercise it) then correctly surfaces that resolution. Running
`migrate-tableau.rb`'s exact end-of-run block (reproduced standalone here
since the full orchestrator run could not be completed — see "Known,
unresolved limitation" below) against the resolved ledger prints:

```
============== JOIN-CARDINALITY RESOLUTIONS (gate 16) ==============
   1 gate-16 join-cardinality resolution(s) recorded in join-plan.json (each added or accepted a helper element / arbitrary-match risk to fix a non-unique join target):

   - LMOG_FACT_WIDE -> LMOG_DIM_REGION (federated-join, preaggregated): LMOG_DIM_REGION non-unique on REGION_KEY (6 rows/5 keys, REGION_KEY=3 duplicated x2, live-verified 2026-08-03). Resolved via a pre-aggregated helper: SELECT REGION_KEY, MIN(REGION_NAME) AS REGION_NAME FROM <table> GROUP BY REGION_KEY, grouped to the REGION_KEY grain. Re-probed against that helper live: 5 rows/5 keys, unique — confirmed before recording this resolution.
======================================================================
```

And `assert-phase6-ran.rb`'s gate 16 logic itself (reproduced standalone
against the same resolved ledger, same reason as above), exits 0:

```
[OK] gate 16: join-cardinality ledger resolved — 3 unique, 1 resolved of 4 (join-plan.json)
exit code: 0
```

### Known, unresolved limitation: published-workbook rendering

**This is a real gap, not softened.** The Tableau workbook was published
successfully (HTTP 201) to a real Tableau Server/Cloud site, with a real
embedded live Snowflake connection (`embedPassword: true`, confirmed
authenticating live — Snowflake's own query history shows the embedded
service credential successfully running `USE WAREHOUSE`/`USE DATABASE`/a
catalog-probe query). **But every render of that published workbook comes
back genuinely empty**: `GET /views/{id}/data` returns HTTP 200 with a
**0-byte CSV**; `GET /views/{id}/image` returns HTTP 200 with a **2x2 pixel
PNG**. The actual per-view `SELECT` against the warehouse tables is **never
issued at all** — Snowflake's query history shows the connection-test query
repeating, never the real one, on both the main fixture workbook and an
isolated single-table diagnostic workbook built specifically to narrow this
down.

Four hypotheses were tested; three were ruled out, one is suspected but not
confirmed:

1. Cross-table join complexity in the worksheet — ruled out (a single-table-
   only worksheet, no dimension fields at all, also renders empty).
2. Worksheet structural shape (missing `<column-instance>` mappings) — this
   WAS the real fix for a separate, genuine publish-time 400
   ("no visual representation in the workbook"), cloned from a real,
   confirmed-rendering workbook's exact XML shape on the same site — but does
   not explain the empty render.
3. Missing `<panes>/<mark>/<encodings>` — added back in combination with #2 —
   still empty.
4. **(Suspected, not confirmed.)** Every workbook found on the test site that
   *does* render live data goes through a Tableau Virtual Connection
   (`class='publishedConnection'`) or `sqlproxy` layer — never a bare embedded
   `class='snowflake'` connection with inline credentials, which is what this
   fixture's workbook uses. The site may filter/restrict direct ad-hoc DB
   connections from actually serving queries even though publish-time
   validation and lightweight connection tests succeed. Not confirmed by any
   site-settings flag; would need either building a Virtual Connection or
   switching to an embedded-Hyper-extract-based workbook to test properly —
   both explicitly out of scope for this fixture (a separate investigation).

**Consequence:** `migrate-tableau.rb`'s Phase 1d gate (`assert-dashboard-read.rb`,
which requires a real PNG render of the source dashboard) is **NOT exercised
by this fixture** and should be treated as still-unvalidated against a
genuinely live-published, directly-embedded-connection Tableau workbook. The
M2/M3 and gate-16 evidence above was gathered by driving the converter and
`probe-join-keys.rb`/`join_plan_resolutions.rb` directly against the real
served `.twb` and the real warehouse — not by completing a full
`migrate-tableau.rb` orchestrator run, which cannot get past Phase 1d against
this specific published workbook. A full orchestrated run against this
fixture (or a workbook built via a Virtual Connection / extract, once that
investigation happens) remains an open follow-up.

### Live infrastructure left behind (not cleaned up — a deliberate later decision)

- **Snowflake**: 6 real tables (`LMOG_FACT_WIDE` + 5 dimensions, matching the
  shape above) in a pre-existing scratch schema in this repo's shared sandbox
  Snowflake account (the same account/schema several of this repo's other
  live fixtures already use — not named literally here per the hygiene-sweep
  policy above). A dedicated scratch role and password-auth service user were
  created specifically for the Tableau connection (least-privilege: `USAGE`
  on the warehouse/database/schema, `SELECT` on only these 6 tables).
- **Tableau**: 2 published workbooks on the test site's default project,
  both named to be unambiguous scratch content safe to delete
  ("LMOG Live Fixture -- scratch, safe to delete" and
  "LMOG Diagnostic Test - safe to delete").
- None of this was deleted as part of this task. Cleanup is a separate,
  deliberate decision for whoever owns that environment.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | Genuine Tableau-Server-served workbook XML (identifiers neutralized per repo hygiene policy — see Provenance above) |
| `relationship-coverage.expected.json` | PINNED `relationshipCoverage` object emitted by `converter/tableau.mjs` for this fixture (5 serialized, 4 wired, 1 recorded-unwired). This is the converter's RAW, camelCase JS output (`derivedVia`, `keyCount`, `droppedConditions`), checked by `checks.sh` below — it is a different artifact from, and predates, `scripts/emit-relationship-coverage.rb`'s snake_case `relationship-coverage.json` (`derived_via`, `key_count`, `dropped_conditions`), which that script writes to a run's `<workdir>` for PR2b's gate 22 to consume. Same values, same entries, deliberately different key casing for two different consumers — do not assume this file pins the emitter's output. |
| `checks.sh` | Executable expectations, run by `run-corpus.sh --check`. Offline/converter-only — see the note at the top of that file for exactly what it does and does not prove; the live warehouse/gate-16 evidence above is NOT re-derivable offline and is documented here instead. |

## Expected behaviors (encoded in checks.sh)

1. Running `convertTableauToSigma` over `workbook-content.twb` (connectionId
   `test-conn`, database `TESTDB`, schema `TESTSCHEMA`) produces a
   `relationshipCoverage` object that matches
   `relationship-coverage.expected.json` byte-for-byte: `serialized: 5`,
   `wired: 4`, and the five per-relationship entries described above keyed
   by target (`LMOG_DIM_CUSTOMER`, `LMOG_DIM_PRODUCT`, `LMOG_DIM_DATE`,
   `LMOG_DIM_STORE`, `LMOG_DIM_REGION`).
2. `CUSTOMER_KEY`, `PRODUCT_KEY`, `STORE_KEY`, and `REGION_KEY` — the four
   columns actually wired as join keys — have metadata-record `<ordinal>`
   values past 50 on `LMOG_FACT_WIDE`.
3. `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-relationship-derivation.rb`
   (Task 2's contract test, updated for this fixture's real table names and
   the case-1 live correction) passes at its default (no
   `TEST_RELATIONSHIP_DERIVATION_TWB` override) path against this exact
   fixture.
4. **Not encoded here (live-only, cannot be exercised offline):** M1
   pagination against a real warehouse table, and gate 16's join-cardinality
   probe + resolution surfacing against a real non-unique warehouse table.
   Both are documented with real, unrounded evidence in the "Live
   validation" section above instead of being faked as an offline check.

## Converter

Regenerate the pin with:

```
node -e "
import('/absolute/path/to/plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/tableau.mjs').then(async ({ convertTableauToSigma }) => {
  const fs = await import('node:fs');
  const xml = fs.readFileSync('corpus/tableau/logical-model-objectgraph/workbook-content.twb', 'utf8');
  const out = convertTableauToSigma(xml, { connectionId: 'test-conn', database: 'TESTDB', schema: 'TESTSCHEMA', tableMapping: {} });
  console.log(JSON.stringify(out.relationshipCoverage, null, 2));
});
"
# then copy stdout over relationship-coverage.expected.json
```

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "relationship-coverage.expected.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
