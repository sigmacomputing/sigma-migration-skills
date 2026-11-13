# The source map: where Solver's data lives in the warehouse

Solver reports read Solver's own data warehouse. Sigma reads the customer's warehouse. The source map is the
bridge: for every Solver fact and every `<dimension>.<field>` a report filters or lists, the warehouse
expression that holds the same thing. The converter never guesses one; an unmapped field stops the run (exit 2)
with the full list.

## Format

```json
{
  "connectionId": "<sigma-connection-id>",
  "fiscal_year_start_month": 1,
  "facts": {
    "GL_F_Trans": {
      "from": "FIN_DB.GL.GL_BALANCES f LEFT JOIN FIN_DB.GL.ACCOUNTS a ON a.ACCOUNT_CODE = f.ACCOUNT_CODE",
      "values": {"Value1": "f.AMOUNT"},
      "period": {"expr": "f.PERIOD_ID", "format": "yyyymm"}
    }
  },
  "attributes": {
    "d_Account.Code": "f.ACCOUNT_CODE",
    "d_Account.UDF001": "a.ROLLUP_1",
    "d_Scenario.Code": "f.SCENARIO",
    "d_dim0.Code": "f.ENTITY_CODE"
  },
  "fact_attributes": {"GL_F_Trans": {}}
}
```

- `from` is a FROM clause (tables, joins, or a parenthesised subquery such as a `UNION ALL` of an actuals table
  and a budget table with a literal scenario column). Predicates and values are evaluated inside the SELECT that
  owns it, so its aliases resolve.
- `values` maps each `Value…` the formulas read. `period.format` is `yyyymm` (a number like 202609) or `date`
  (any date in the month).
- `attributes` apply to every fact; `fact_attributes.<fact>` overrides per fact (two modules rarely share keys).
- `Period.PeriodId` needs no attribute entry: it is the fact's period.

## Choosing the table: source of truth, not the nearest copy

1. **Prefer the ERP's general ledger** (or the governed mart built on it) over a replicated copy of Solver's own
   tables. Replicated Solver feeds are often loaded by a one-off integration and can stop refreshing; the symptom
   is a report that matches for older periods and is empty or stale for recent ones. Check each candidate's
   last-loaded date and row count before mapping (`INFORMATION_SCHEMA.TABLES`, `MAX(<load column>)`).
2. **Budgets and forecasts** are often separate feeds. Find out which table is the budget of record and how it
   encodes scenarios: a feed that stores `Budget` + a year column breaks a report whose parameter says
   `25 Budget`. Map the scenario expression so the report's codes still match, or change the parameter values.
3. **Masters.** Account, entity and employee attributes Solver reads as UDFs may live in several warehouse
   copies. A master extract with a suspiciously round row count (exactly 10,000) may be capped. Compare the
   attributes the report filters on, not just the codes.
4. **Exclusion flags** (closed, divested or carved-out locations) usually live in a UDF. Confirm which flag the
   report's filters read and that the warehouse carries it.

## The Solver-shaped extract (pre-flight and offline parity)

`scripts/evaluate-solver-local.py` reads a CSV per fact whose header uses Solver's names:
`Period.PeriodId`, `d_Scenario.Code`, `d_Account.Code`, `d_dim0.Code`, `d_dim1.UDF001`, …, `GL_F_Trans.Value1`.
Produce it with one small aggregate query over the mapped tables (period × scenario × the fields the report
filters on, summed), never a full table dump. It lets you reproduce the executed run's anchors before anything
is posted to Sigma.

## Working with the data team

Data availability is its own workstream. For each report, track: the fact tables and their source of truth, the
masters, who owns each feed, how fresh it is, and what is missing. A missing table is a blocker with an owner,
not a reason to point the report at a stale copy.
