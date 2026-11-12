# powerbi / page-facts-multipage

**Synthetic** three-page report (invented retail names, SQLite seed) that pins the
powerbi-to-sigma page-fact path end to end: `scaffold-page-fact.py` →
`integrate-page-fact.py` → `build-workbook-from-pbir.rb` (master-map `page_fields`) →
`wire-slicer-gate.py`. No customer identifiers, no live tenant. The inputs live in the
plugin's `fixtures/page-facts/` (referenced by relative path, not duplicated).

## The shape

| Page | Classification | What it exercises |
|---|---|---|
| Sales Overview | per-visual (scaffolded anyway with `--all-pages`) | one fact; a VAR/RETURN ratio; a CALCULATE that replaces a grouping filter (TODO); a saved Year selection on a slicer the page fact does not carry |
| Stock Cover | page-fact (two facts) | Stock and Sales in one pivot, UNION ALL'd at the shared grain; an ISBLANK filter; a one-hop (Region) and a two-hop (Manager) slicer gated through the union |
| Rollup | page-fact (USERELATIONSHIP) | measures that activate an inactive Sales -> Rollup bridge: the grain joins and the Supplier slicer reach Sales **through the bridge** (path weight), a DISTINCTCOUNT TODO bound to its page-fact NULL stub |

## Converter

No converter call: the case runs the skill's own scripts on the fixture. Golden outputs are
pinned byte-for-byte by `checks.sh`; regenerate them after an intended change with
`bash corpus/powerbi/page-facts-multipage/checks.sh --update` and review the diff.

`checks.sh` also runs the preflight, spec and control lints on the gated workbook, and
`check_sqlite.py` executes the generated SQL in SQLite: each page fact matches the independent
oracle, the gated SQL with every control empty equals the page fact, and three slicer picks
(one hop, a two-hop `(Blank)`, the bridge) answer like the oracle's filtered scenario.

## Timing (informational)

`checks.sh` prints the wall clock of the automated path. On the author's machine it is about
0.4 s for the three pages. In a real six-page migration the same steps were hand-written:
page-fact + oracle passes about 161 min, page integration about 37 min, slicer gating about
164 min (file-timestamp spans of that run; see the PR that added this case).

## Expectations

```json
{
  "artifacts": [
    {"path": "checks.sh", "format": "text"},
    {"path": "check_sqlite.py", "format": "text"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/page-facts/model.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/page-facts/signals.json", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/page-facts/dm-spec.json", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/page-facts/master-map.json", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/page-facts/seed.sql", "format": "text"},
    {"path": "golden/page-closure.json", "format": "json"},
    {"path": "golden/page-facts/sales-overview/page-fact.sql", "format": "text"},
    {"path": "golden/page-facts/stock-cover/page-fact.sql", "format": "text"},
    {"path": "golden/page-facts/rollup/page-fact.sql", "format": "text"},
    {"path": "golden/master-map.integrated.json", "format": "json"},
    {"path": "golden/slicer-gate.json", "format": "json"}
  ],
  "goldens": {
    "dm-spec.integrated.json": {
      "elements": 12,
      "element_names": ["Sales", "Stock", "Calendar", "Store", "Manager", "Product", "Supplier", "Rollup",
                        "Sales View", "Rollup Page Fact", "Sales Overview Page Fact", "Stock Cover Page Fact"]
    },
    "workbook-spec.gated.json": {"pages": 4, "elements": 49}
  }
}
```
