# tableau / lookup-grain-mismatch

**Synthetic twin of a field-failure shape** (PLAN-v3 PR-1, Wave 1). Invented
names on the neutral `DEMO_DB.ANALYTICS` demo star — no customer identifiers,
no live tenant. Reproduces the 2026-07-17 field root cause #1: a join/Lookup
synthesized on a **non-unique compound key** silently undercounts a core
metric, and nothing in the pipeline errors.

## The shape (what makes this workbook a trap)

- Published-virtual-connection federated datasource: relation labels carry the
  physical path only in parens (`SALES_FACT (ANALYTICS.SALES_FACT)`), the
  named-connection has **no dbname**, and every field id is a Tableau GUID —
  captions are the only handle on physical columns.
- The relation tree **self-joins the fact table** (`Sale Lines` vs `Buyer Day
  Detail`, same physical `SALES_FACT`) on the AND-wrapped compound key
  (buyer key × sale date). The fact is at sale-LINE grain, so the right side
  is NOT unique at that key — every `Unified *` / `Combined Margin` measure
  that reads a `(Buyer Day Detail)` column undercounts or fans out.
- Two single-key dim joins (`BUYER_DIM`, `ITEM_DIM`) that ARE unique — the
  probe must separate the safe joins from the poisoned one.
- Top-N (list) + Direction parameters driving `RANK_UNIQUE(IIF(...))` +
  an `In Top N` boolean filter; **param-driven dynamic titles**
  (`<[Parameters].[Parameter 2]> <[Parameters].[Parameter 1]> Buyers ...`);
  a **top-shelf control row** (2 paramctrl + 2 filter zones in the first
  horizontal band) — the layout/controls traps from the same field session.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | The synthetic workbook XML (4 worksheets + `Profit Watch` dashboard) |
| `join-plan.entries.json` | PINNED `lib/join_plan.rb` derivation (the join ledger, PR-4) |
| `probe-fixture/entry-*.json` | Canned probe results for `probe-join-keys.rb --fixture` (the offline seam): dims unique, self-join NON-UNIQUE (5000 rows over 1400 keys + sample duplicates) |
| `checks.sh` | Executable expectations, run by `run-corpus.sh --check` |

## Expected gate behaviors (encoded in checks.sh)

1. **Derivation**: `JoinPlan.derive(nil, twb, db:, schema:)` emits exactly the
   pinned 3 federated-join entries. W2.9 fixed the caption fold: the dim probe
   keys now strip the balanced role parenthetical
   (`Buyer Key (BUYER_DIM)` → `BUYER_KEY`, a real physical column). The
   remaining honest wart stays pinned on purpose: the self-join `right_table`
   keeps the unprobeable VC-inode FQN
   (`eeee….SALES_FACT (ANALYTICS.SALES_FACT)`) because the alias label has no
   paren path. A later PR that fixes that fold flips this pin.
2. **Probe**: `probe-join-keys.rb --fixture` → dims `unique`; the self-join is
   **refused** by the W2.9 identifier legality oracle (`sql_ident_check`) —
   the inode FQN never reaches SQL, status `error`, **exit 3**.
   FATAL coverage is kept in-case: re-probing with the `right_table`
   legalized to `ANALYTICS.SALES_FACT` proves it `non-unique` → **exit 2**
   with the JOIN-CARDINALITY FATAL block naming the entry, the compound
   keys, and sample duplicate keys.
3. **Gate 16** (`assert-phase6-ran.rb`, exit 23): blocks GREEN while the
   refused entry is unresolved (UNPROVEN); passes after
   `probe-join-keys.rb --resolve 2 --how preaggregated --reason "..."`
   records the evidence.

## Converter

No golden data model — this case pins the PR-4 join-ledger contract, not the
MCP converter output. Regenerate the pin with:

```
ruby -rjson -I plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib -r join_plan -e '
  puts JSON.pretty_generate(JoinPlan.derive(nil,
    File.read("corpus/tableau/lookup-grain-mismatch/workbook-content.twb", encoding: "UTF-8"),
    db: "DEMO_DB", schema: "ANALYTICS"))'
```

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "join-plan.entries.json", "format": "json"},
    {"path": "probe-fixture/entry-0.json", "format": "json"},
    {"path": "probe-fixture/entry-1.json", "format": "json"},
    {"path": "probe-fixture/entry-2.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
