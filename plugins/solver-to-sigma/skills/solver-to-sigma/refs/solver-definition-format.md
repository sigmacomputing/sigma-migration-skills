# The Solver report definition (what the Download carries, and how it is evaluated)

Field-verified against Live Reporting downloads of several production reports (financial statements with
13 sheets and ~2,000 items, and list-style AP reports). Element and attribute names below are Solver's own.

## Where it is

A Live Reporting **Download** (`.xlsx`) is the report template: the sheet layout plus the full definition as a
custom XML part, `customXml/item1.xml`, usually **UTF-16** with a BOM. `scripts/solver_def.py` finds the first
custom XML part whose root is `ReportDefinition`. An **executed run** exported to Excel is the same layout with
values filled in and *no* definition; the template has no values. You need both.

A `*.xlsx.manifest` is something else entirely: ReportId, ReportName, the Solver URL, a timestamp, `RunOnlyMode`
and an **`AuthenticationToken` for the sender's session**. It is a credential. Never open, copy or log it.

## Shape

```
ReportDefinition
  Header
    Title, Author, Version, EngineVersion, DateCreated/Modified
    DataSources/DataSource  Name, Model (GUID), ModelVersion, Integration (e.g. SODS-MSSQL)
    ReportParameters/ReportParameter  Name, ParameterType (LookupEdit | PeriodSelection), DataType
                                      (System.Decimal | System.String | OneStop.PeriodInterval), Prompt,
                                      MultiSelection, Hidden, IsPeriod, AllowBlank, Loop (=dim.field: one
                                      output per member)
        Default  (may reference another parameter: {@Location})
        Source   Attribute="d_Scenario.Code" | "Period.PeriodId" | …
  Excel Sheet="<sheet name>"            (one per sheet)
    Mappings/Mapping/LayoutDefinition/Items/DefinitionItem*
```

Each `DefinitionItem` has `Type` = `Report` | `Column` | `Row` | `Cell`, 1-based `Row` / `Column` positions,
optional `Size` and `Expand="true"`, an `Elements` list and (Cell items) a `Formula`.

`DefinitionElement` is either `xsi:type="SelectionElement"` (it filters) or `ReferenceElement` (a cell that just
takes its row and column context). A SelectionElement carries:

```
FilterGroups/FilterGroup Name="<dimension>"/Filters/Expression
    DimensionName="d_Account"  Name="Code"|"UDF001"|"PeriodId"  Operator="In"|"Contains"
    Condition="4000:4999,6100"  LogicalOperator=(none)|And|Or|Not|AndNot|OrNot
Columns/ResultAttribute  DimensionName="GL_F_Trans"|"d_Account"  Name="Value1"|"Code"  Aggregation="Sum"|"Group"
```

Dimension names you will meet: `d_Account`, `d_Scenario`, `d_Category`, `Period`, `Date`, and the
customer-configured `d_dim0…d_dimN`; fact tables are `<module>_F_Trans` (`GL_F_Trans`, `OT2_F_Trans`, …) with
values `Value1…` and their own `UDF` columns. What `d_dim3` or `UDF007` *means* is customer configuration: ask.

## Evaluation rules (as compiled by `scripts/solver_compile.py`)

- **Context resolution.** For each dimension, the most specific level that filters it wins:
  **Cell > Row > Column > Report.** A Report item's filters apply everywhere unless overridden.
- **A FilterGroup is evaluated left to right**: `((e1 AndNot e2) Or e3)`. `Not` on the *first* expression is a
  unary NOT. Several groups on one element are ANDed.
- **Conditions** are comma lists of: a value, a range `lo:hi`, a wildcard `ab*` or `*` (everything), a parameter
  `{@Name}`, or (Period only) a period function `{PeriodCalc.GetFunction(FN, @Period)}`. Comparisons are
  case-insensitive; ranges on codes compare as text (they are codes, not numbers). `Contains` takes a quoted
  string. A parameter value may itself be a comma list (`BUD,ADJ`) or `*`. A missing attribute compares as `''`.
  Only a trailing wildcard is translated. Conditions on the `Date` dimension (`'{Date.AddDays(-7).SqlDate}':{@Date}`)
  and date-range parameters on attributes (`ParameterType="PeriodSelection"`, `DataType="OneStop.PeriodInterval"`,
  default `'2010-01-01':'2024-10-31'`, tested on the stored datetime at both ends) are reported as gaps.
- **Period functions** (YYYYMM periods, month arithmetic, fiscal year start configurable):

  | Function | Window ending at the selected period P |
  |---|---|
  | `{@Period}`, `TPTY` | P |
  | `TPLY` | P − 12 months |
  | `QTD` / `QTDLY` | quarter start → P (same window a year back) |
  | `YTD` / `LYTD` | fiscal year start → P (same window a year back) |
  | `R…NM`, e.g. `RBC12M` (+ `LY`) | the last N months ending at P (a year back) |

  Anything else is reported as a gap. Confirm the fiscal year start with the customer.
- **Formulas.** Cell formulas read facts with `OSRGet("GL_F_Trans","Value1")`, often signed (`=-OSRGet(...)`
  for credit-normal revenue) or wrapped (`=IFERROR(OSRGet(...)*1,0)`). Plain-Excel cells around them add
  subtotals (`=SUM(E10:E12)`, `=SUM(OSRRef(E30))`), ratios (`=IFERROR(E12/E10,0)`), and variance columns
  (`=E10-H10`). Sheet formulas may carry the prefix `_xll.OneStop.ReportPlayer.OSRFunctions.`; it is stripped.
  `IFERROR(x,)` (empty argument) means 0. `OSRGet` of an attribute (`"d_Account","Description"`), `TEXT`,
  `DOLLAR`, `&` concatenation and `IF(...,"+","-")` decorations are **text cells**: labels, not values.
- **Expanded rows** (`Expand="true"`) list one physical row per member in an executed run, grouped by the Row
  element's `Group` result attributes (or the attributes its cells read). Every row below the block moves down,
  which is why parity matches lines by label, not row number. Expanding *columns* are reported as a gap.

## What is not in the definition

Solver security (who may see which members), folder permissions, schedules and distribution lists, and the
semantics of UDF fields. Ask the Solver administrator; see SKILL.md › Security.
