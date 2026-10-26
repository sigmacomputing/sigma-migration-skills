# MicroStrategy multi-fact semantics → Sigma modeling

The array of tables on a MicroStrategy fact expression is an **eligibility
list**, not a join plan. Treating every table in that array as simultaneously
active causes false multi-fact blockers.

## What MicroStrategy actually does

1. A fact can have several expressions, and each expression lists logical
   tables capable of evaluating it. The order has no significance.
   [Strategy fact-expression API](https://www2.strategy.com/producthelp/current/mstrio-py/mstrio.modeling.expression.fact_expression.html)
2. For a report, the SQL Engine first finds tables that can resolve its
   template attributes, filters, facts, and metric dimensionality. When more
   than one table remains, it chooses the table with the **lowest logical table
   size** (the highest aggregation). A tie can fall to in-memory order, so it
   is not safe to guess.
   [Logical table sizes](https://www2.microstrategy.com/producthelp/Current/ProjectDesignGuide/WebHelp/Lang_1033/Content/Defining_logical_table_sizes.htm)
   · [table-selection algorithm](https://community.microstrategy.com/s/article/KB5300-How-MicroStrategy-SQL-Generation-Engine-calculates)
3. When no one table resolves all facts, MicroStrategy evaluates metric
   components in separate passes and joins the intermediate results. **Metric
   Join Type** governs joins between report metrics; **Formula Join Type**
   governs components inside split/compound metrics. Report settings can
   override metric defaults.
   [Metric Join Type](https://www2.strategy.com/producthelp/Current/SystemAdmin/WebHelp/Lang_1033/Content/metric_JOIN_TYPE.htm)
4. Depending on VLDB settings and warehouse capabilities, those passes become
   temporary/volatile tables, derived tables, or CTEs. Some Analytical Engine,
   partitioning, and outer-join cases require temporary-table fallback.
   [Intermediate tables](https://www2.strategy.com/producthelp/Current/PostgreSQL/en-us/Content/PostgreSQL/Temp_Table_creation.htm)
   · [fallback table type](https://www2.strategy.com/producthelp/current/AdvancedReportingGuide/WebHelp/Lang_1033/Content/FallBack_Table_Type.htm)

## Why the Sigma shape differs

- A Sigma join executes at the joined row grain. Directly joining two fact
  tables on shared dimensional keys can create many-to-many fanout and inflate
  `Sum`/`Count`.
- Sigma relationships are deferred but support many-to-one/one-to-one
  cardinality; they are not a replacement for MicroStrategy's metric-pass
  merge.
  [Sigma joins overview](https://help.sigmacomputing.com/docs/joins-overview)
  · [Sigma relationships](https://help.sigmacomputing.com/docs/define-relationships-in-data-models)
- Sigma custom SQL accepts one statement, so a MicroStrategy temporary-table
  plan must become one CTE/derived-table query or a customer-managed conformed
  warehouse view.
  [Sigma custom-SQL representation](https://help.sigmacomputing.com/docs/example-representation-data-model-with-a-custom-sql-element)

## Converter decision

`plan_multifact.py` applies the safe subset of MicroStrategy's election:

1. recursively resolve each report metric to facts;
2. intersect each fact's candidate table set;
3. require alternate candidates to expose identical attribute-key signatures
   (higher-level template attributes can resolve through hierarchy joins, so
   direct-ID membership would be too strict);
4. elect a candidate only when one table has a unique minimum `logicalSize`;
5. require executed `sqlView` and parity verification because filters and
   metric dimensionality can further constrain the SQL Engine's choice.

If every report elects the same table, `convert.py` continues on the normal
star path. Ties, different elected roots, or no common candidate use the
conformed-SQL recovery. Never resolve these cases by deleting fact mappings,
selecting the first table, or directly joining fact tables.

For a true multipass report, preserve all of the following in the CTE/view:

- each metric pass's grouping grain;
- Formula Join Type inside split/compound metrics;
- Metric Join Type between report metrics;
- null handling (`COALESCE`/zero behavior);
- final attribute-description joins and report filters;
- prompt/security substitutions from the executed instance.

Only row-level parity against the executed MicroStrategy report proves that
the translation preserved these semantics.
