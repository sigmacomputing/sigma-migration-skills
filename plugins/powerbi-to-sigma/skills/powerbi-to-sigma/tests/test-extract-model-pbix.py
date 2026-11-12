#!/usr/bin/env python3
"""test-extract-model-pbix.py — synthetic unit test for the pbixray -> TMSL
assembly in extract-model-pbix.py.

The assembly (build_model_from_pbixray / assemble_tmsl) is a PURE function of
the pbixray DataFrames, so this test MOCKS the dataframes (a tiny FakeDF that
exposes .empty + .to_dict('records'), exactly what pbixray returns) with
GENERIC SALES_FACT / DATE_DIM data — no pbixray, no pandas, no .pbix, no
network. Asserts the emitted model.bim shape:
  * tables carry columns [{name,dataType,...}] with PandasDataType -> TMSL
    dataType mapping, and measures [{name,expression}]
  * relationships carry from/to table+column, crossFilteringBehavior, isActive
  * DAX calculated tables keep calculated partitions; regular tables keep M

Also loads the vendored converter (if `node` is present) and asserts the
emitted model.bim CONVERTS without error — the "flows through the convert
step" check from the task, kept synthetic.

Run: python3 tests/test-extract-model-pbix.py   (exit 0 = pass)
"""
import base64, importlib.util, json, os, shutil, subprocess, sys, tempfile, zipfile, zlib
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.join(HERE, "..")
SCRIPT = os.path.join(SKILL, "scripts", "extract-model-pbix.py")
CONVERTER = os.path.join(SKILL, "converter", "powerbi.mjs")


def _load_module():
    spec = importlib.util.spec_from_file_location("extract_model_pbix", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeDF:
    """Minimal stand-in for a pandas DataFrame as pbixray returns it: an
    .empty flag and .to_dict('records') yielding a list of row dicts."""
    def __init__(self, records):
        self._records = list(records)

    @property
    def empty(self):
        return len(self._records) == 0

    def to_dict(self, orient="records"):
        assert orient == "records", orient
        return [dict(r) for r in self._records]


class FakePBIXRay:
    """Mock of pbixray.PBIXRay exposing the DataFrame properties the assembly
    reads. Generic SALES_FACT / DATE_DIM model."""
    tables = ["SALES_FACT", "DATE_DIM"]
    schema = FakeDF([
        {"TableName": "SALES_FACT", "ColumnName": "SALE_ID", "PandasDataType": "Int64"},
        {"TableName": "SALES_FACT", "ColumnName": "AMOUNT", "PandasDataType": "Float64"},
        {"TableName": "SALES_FACT", "ColumnName": "SALE_DATE", "PandasDataType": "datetime64[ns]"},
        {"TableName": "SALES_FACT", "ColumnName": "IS_RETURN", "PandasDataType": "bool"},
        {"TableName": "DATE_DIM", "ColumnName": "Date", "PandasDataType": "datetime64[ns]"},
        {"TableName": "DATE_DIM", "ColumnName": "MONTH", "PandasDataType": "string"},
    ])
    dax_measures = FakeDF([
        {"TableName": "SALES_FACT", "Name": "Total Sales",
         "Expression": "SUM(SALES_FACT[AMOUNT])", "Description": "Sum of amount"},
        {"TableName": "SALES_FACT", "Name": "Sale Count",
         "Expression": "COUNTROWS(SALES_FACT)", "Description": ""},
    ])
    dax_columns = FakeDF([
        {"TableName": "SALES_FACT", "ColumnName": "Net Amount",
         "Expression": "SALES_FACT[AMOUNT] * 0.9"},
    ])
    dax_tables = FakeDF([
        {"TableName": "DATE_DIM",
         "Expression": 'ADDCOLUMNS(CALENDAR(DATE(2024,1,1), DATE(2024,12,31)), '
                       '"MONTH", FORMAT([Date], "MMM"))'},
    ])
    relationships = FakeDF([
        {"FromTableName": "SALES_FACT", "FromColumnName": "SALE_DATE",
         "ToTableName": "DATE_DIM", "ToColumnName": "Date",
         "IsActive": True, "CrossFilteringBehavior": "Single"},
        {"FromTableName": "SALES_FACT", "FromColumnName": "SALE_DATE",
         "ToTableName": "DATE_DIM", "ToColumnName": "Date",
         "IsActive": False, "CrossFilteringBehavior": "Both"},
    ])
    power_query = FakeDF([
        {"TableName": "SALES_FACT",
         "Expression": 'let Source = Snowflake.Databases("acct.snowflakecomputing.com","WH"),'
                       ' Nav = Source{[Name="RAW",Kind="Database"]}[Data],'
                       ' Sch = Nav{[Name="SALES",Kind="Schema"]}[Data],'
                       ' Tbl = Sch{[Name="SALES_FACT",Kind="Table"]}[Data] in Tbl'},
        # DATE_DIM deliberately has no M: dax_tables must supply its partition.
    ])
    m_parameters = FakeDF([
        {"ParameterName": "SourceDatabase", "Description": "source db",
         "Expression": '"RAW" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]'},
        {"ParameterName": "Warehouse", "Description": None,
         "Expression": '"WH" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]'},
    ])


def test_assembly():
    mod = _load_module()
    tmsl = mod.build_model_from_pbixray(FakePBIXRay(), "Synthetic Sales")

    assert tmsl["name"] == "Synthetic Sales"
    m = tmsl["model"]
    tbls = {t["name"]: t for t in m["tables"]}
    assert list(tbls) == ["SALES_FACT", "DATE_DIM"], f"table order {list(tbls)}"

    sf = tbls["SALES_FACT"]
    cols = {c["name"]: c for c in sf["columns"]}
    # PandasDataType -> TMSL dataType mapping.
    assert cols["SALE_ID"]["dataType"] == "int64", cols["SALE_ID"]
    assert cols["AMOUNT"]["dataType"] == "double", cols["AMOUNT"]
    assert cols["SALE_DATE"]["dataType"] == "dateTime", cols["SALE_DATE"]
    assert cols["IS_RETURN"]["dataType"] == "boolean", cols["IS_RETURN"]
    assert cols["SALE_ID"]["sourceColumn"] == "SALE_ID"
    # Calculated (DAX) column carried through, marked calculated (not a WH col).
    assert cols["Net Amount"]["type"] == "calculated", cols["Net Amount"]
    assert cols["Net Amount"]["expression"] == "SALES_FACT[AMOUNT] * 0.9"

    # Measures.
    meas = {x["name"]: x for x in sf["measures"]}
    assert meas["Total Sales"]["expression"] == "SUM(SALES_FACT[AMOUNT])", meas
    assert meas["Total Sales"]["description"] == "Sum of amount"
    assert "description" not in meas["Sale Count"], "empty description must be omitted"

    # Partitions: SALES_FACT passes M through (so the WH FQN survives); DATE_DIM
    # keeps its calculated-table DAX rather than becoming a fake warehouse path.
    sf_part = sf["partitions"][0]
    assert sf_part["mode"] == "import" and sf_part["source"]["type"] == "m"
    assert "Snowflake.Databases" in sf_part["source"]["expression"], sf_part
    dd_part = tbls["DATE_DIM"]["partitions"][0]
    assert dd_part["mode"] == "import"
    assert dd_part["source"]["type"] == "calculated", dd_part
    assert "ADDCOLUMNS(CALENDAR" in dd_part["source"]["expression"], dd_part
    dd_cols = {c["name"]: c for c in tbls["DATE_DIM"]["columns"]}
    assert dd_cols["Date"]["type"] == "calculatedTableColumn", dd_cols["Date"]
    assert dd_cols["Date"]["sourceColumn"] == "[Date]", dd_cols["Date"]

    # Relationships: field mapping + crossFilteringBehavior + isActive.
    rels = m["relationships"]
    assert len(rels) == 2, rels
    r0, r1 = rels
    assert (r0["fromTable"], r0["fromColumn"], r0["toTable"], r0["toColumn"]) == \
           ("SALES_FACT", "SALE_DATE", "DATE_DIM", "Date"), r0
    assert r0["crossFilteringBehavior"] == "oneDirection" and r0["isActive"] is True, r0
    assert r1["crossFilteringBehavior"] == "bothDirections" and r1["isActive"] is False, r1
    assert r0["name"] and r1["name"] and r0["name"] != r1["name"], "relationships need unique names"

    # M parameters become TMSL shared expressions (what a Fabric model.bim
    # carries), so a NativeQuery navigating {[Name=SourceDatabase]} resolves.
    exprs = {e["name"]: e for e in m.get("expressions", [])}
    assert set(exprs) == {"SourceDatabase", "Warehouse"}, exprs
    assert exprs["SourceDatabase"]["kind"] == "m", exprs
    assert exprs["SourceDatabase"]["expression"].startswith('"RAW" meta [IsParameterQuery=true'), exprs
    assert exprs["SourceDatabase"]["description"] == "source db", exprs
    assert "description" not in exprs["Warehouse"], exprs

    # assemble_tmsl accepts plain records too (no DataFrame needed).
    direct = mod.assemble_tmsl("X",
        [{"TableName": "T", "ColumnName": "C", "PandasDataType": "string"}],
        [], [])
    assert direct["model"]["tables"][0]["columns"][0]["dataType"] == "string"
    print("  ok [assembly]: columns/dataType, measures, calc cols/tables, partitions, relationships")
    return tmsl


def test_converts(tmsl):
    if not shutil.which("node"):
        print("  skip [convert]: node not found (assembly test still covers the shape)")
        return
    if not os.path.exists(CONVERTER):
        print("  skip [convert]: vendored converter not present")
        return
    with tempfile.TemporaryDirectory() as d:
        bim = os.path.join(d, "model.bim")
        with open(bim, "w") as f:
            json.dump(tmsl, f)
        shim = os.path.join(d, "conv.mjs")
        # Import the converter by file:// URL so the shim also runs on Windows
        # (Node rejects a bare absolute/drive-letter ESM specifier).
        conv_url = Path(CONVERTER).resolve().as_uri()
        with open(shim, "w") as f:
            f.write(
                "import { readFileSync } from 'node:fs';\n"
                f"import {{ convertPowerBIToSigma }} from {json.dumps(conv_url)};\n"
                f"const model = JSON.parse(readFileSync({json.dumps(bim)},'utf8'));\n"
                "const out = convertPowerBIToSigma(model, {connectionId:'11111111-2222-3333-4444-555555555555', database:'ANALYTICS', schema:'PUBLIC'});\n"
                "const bare = out.model || out.sigmaDataModel || out;\n"
                "const els = (bare.pages||[]).flatMap(p=>p.elements||[]);\n"
                "if (!els.length) { console.error('NO ELEMENTS'); process.exit(3); }\n"
                "const wh = els.find(e=>e.source && e.source.kind==='warehouse-table');\n"
                "if (!wh || !(wh.source.path||[]).includes('SALES_FACT')) { console.error('NO SALES_FACT PATH'); process.exit(4); }\n"
                "const cal = els.find(e=>e.source && e.source.kind==='sql' && /GENERATOR/.test(e.source.statement||''));\n"
                "if (!cal || /_placeholder/.test(cal.source.statement||'')) { console.error('NO CALCULATED DATE SPINE'); process.exit(5); }\n"
                "if (els.some(e=>(e.source&&e.source.path||[]).includes('DATE_DIM'))) { console.error('DATE_DIM BECAME WAREHOUSE TABLE'); process.exit(6); }\n"
                "console.log('CONVERT_OK elements='+els.length);\n")
        r = subprocess.run(["node", shim], capture_output=True, text=True)
        assert r.returncode == 0 and "CONVERT_OK" in r.stdout, \
            f"converter rejected the emitted model.bim ({r.returncode})\n{r.stdout}\n{r.stderr}"
        print(f"  ok [convert]: emitted model.bim flows through the vendored converter ({r.stdout.strip()})")


def test_composite_detection():
    """Composite / live-connection detection from the .pbix `Connections` doc
    (RemoteArtifacts is the offline tell). Pure function — fake dicts, no .pbix."""
    mod = _load_module()

    # RemoteArtifacts present -> composite.
    conns_remote = {"Version": 3,
                    "Connections": [{"Name": "EntityDataSource", "ConnectionType": "pbiServiceLive"}],
                    "RemoteArtifacts": [{"DatasetId": "ds-123", "ReportId": "rp-456"}]}
    assert mod.is_composite_connections(conns_remote) is True, "RemoteArtifacts must => composite"
    assert mod.remote_artifacts(conns_remote) == [{"DatasetId": "ds-123", "ReportId": "rp-456"}]

    # A plain local import model -> NOT composite.
    conns_local = {"Version": 3,
                   "Connections": [{"Name": "LocalModel", "ConnectionType": "structured",
                                    "ConnectionString": "Data Source=SNOWFLAKE"}]}
    assert mod.is_composite_connections(conns_local) is False, "local import must NOT be composite"
    assert mod.remote_artifacts(conns_local) == []

    # No RemoteArtifacts but a remote-model connection string -> composite.
    conns_pbiazure = {"Connections": [{"ConnectionString":
                       "Data Source=pbiazure://api.powerbi.com;Initial Catalog=x"}]}
    assert mod.is_composite_connections(conns_pbiazure) is True, "pbiazure conn => composite"

    # None / empty -> False (no Connections member).
    assert mod.is_composite_connections(None) is False
    assert mod.is_composite_connections({}) is False

    # CLI --detect-composite on synthetic .pbix zips (exercises read_pbix_connections + zip).
    with tempfile.TemporaryDirectory() as d:
        comp = os.path.join(d, "Composite.pbix")
        with zipfile.ZipFile(comp, "w") as z:
            z.writestr("Connections", json.dumps(conns_remote).encode("utf-8"))
            z.writestr("Report/Layout", "{}".encode("utf-16-le"))
        r = subprocess.run([sys.executable, SCRIPT, "--pbix", comp, "--detect-composite"],
                           capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        res = json.loads(r.stdout)
        assert res["composite"] is True and len(res["remoteArtifacts"]) == 1, res

        plain = os.path.join(d, "Local.pbix")
        with zipfile.ZipFile(plain, "w") as z:
            z.writestr("Connections", json.dumps(conns_local).encode("utf-8"))
        r = subprocess.run([sys.executable, SCRIPT, "--pbix", plain, "--detect-composite"],
                           capture_output=True, text=True)
        assert r.returncode == 0 and json.loads(r.stdout)["composite"] is False, r.stdout
    print("  ok [composite]: RemoteArtifacts/pbiazure => composite; local import => not; CLI probe works")


# --- full-fidelity model (Enter-data tables, incremental refresh, RLS, ...) ---
def _enter_data_m(rows, columns, tail):
    """The M an "Enter data" table carries: rows as base64(raw-deflate(JSON))."""
    raw = zlib.compressobj(9, zlib.DEFLATED, -15)
    blob = raw.compress(json.dumps(rows).encode("utf-8")) + raw.flush()
    b64 = base64.b64encode(blob).decode("ascii")
    cols = ", ".join(f"{c} = _t" for c in columns)
    return ('let\n'
            f'    Source = Table.FromRows(Json.Document(Binary.Decompress(Binary.FromText("{b64}", '
            'BinaryEncoding.Base64), Compression.Deflate)), let _t = ((type nullable text) meta '
            f'[Serialized.Text = true]) in type table [{cols}]),\n{tail}')


ENTER_ROWS = [["North", "100", "2024-01-01T00:00:00", "true", "a#(b)"],
              ["O'Neil \\ South\nEast", "250", None, "false", None]]
ENTER_COLS = ["Region", "Quota", '#"Valid From"', "Active", "Note"]
ENTER_TAIL = ('    #"Changed Type" = Table.TransformColumnTypes(Source,{{"Region", type text}, {"Quota", Int64.Type}}),\n'
              '    #"Renamed Columns" = Table.RenameColumns(#"Changed Type",{{"Quota", "Quota Target"}})\n'
              'in\n    #"Renamed Columns"')

INCR_M = ('let\n'
          '    Source = Value.NativeQuery(Snowflake.Databases("acct","WH"){[Name="RAW"]}[Data], '
          '"SELECT EVENT_ID, EVENT_TS FROM LOGS.EVENTS", null, [EnableFolding=true]),\n'
          '    #"Filtered Rows" = Table.SelectRows(Source, each [EVENT_TS] >= RangeStart and [EVENT_TS] < RangeEnd)\n'
          'in\n    #"Filtered Rows"')


class RichPBIXRay:
    """Mock of a pbixray.PBIXRay for a model that exercises every gap: an
    Enter-data table, an incremental-refresh table with no partition M, a
    calculated column pbixray also lists as a plain column, model-level column
    renames, hierarchies, a sort-by column and row-level security."""
    tables = ["ORDERS", "REGION_PARAM", "EVENTS", "CUSTOMER"]
    schema = FakeDF([
        {"TableName": "ORDERS", "ColumnName": "ORDER_ID", "PandasDataType": "Int64"},
        {"TableName": "ORDERS", "ColumnName": "AMOUNT", "PandasDataType": "Float64"},
        {"TableName": "ORDERS", "ColumnName": "ORDER_DATE", "PandasDataType": "datetime64[ns]"},
        {"TableName": "ORDERS", "ColumnName": "REGION", "PandasDataType": "string"},
        {"TableName": "ORDERS", "ColumnName": "Month Name", "PandasDataType": "string"},
        {"TableName": "ORDERS", "ColumnName": "Month Num", "PandasDataType": "Int64"},
        # the phantom: pbixray lists the calculated column as a plain one too
        {"TableName": "ORDERS", "ColumnName": "Net Amount", "PandasDataType": "Float64"},
        {"TableName": "REGION_PARAM", "ColumnName": "Region", "PandasDataType": "string"},
        {"TableName": "REGION_PARAM", "ColumnName": "Quota Target", "PandasDataType": "Int64"},
        {"TableName": "REGION_PARAM", "ColumnName": "Valid From", "PandasDataType": "datetime64[ns]"},
        {"TableName": "REGION_PARAM", "ColumnName": "Active", "PandasDataType": "bool"},
        {"TableName": "REGION_PARAM", "ColumnName": "Note", "PandasDataType": "string"},
        {"TableName": "EVENTS", "ColumnName": "EVENT_ID", "PandasDataType": "Int64"},
        {"TableName": "EVENTS", "ColumnName": "EVENT_TS", "PandasDataType": "datetime64[ns]"},
        {"TableName": "CUSTOMER", "ColumnName": "CUST_ID", "PandasDataType": "Int64"},
        {"TableName": "CUSTOMER", "ColumnName": "CustName", "PandasDataType": "string"},
        {"TableName": "CUSTOMER", "ColumnName": "COUNTRY", "PandasDataType": "string"},
        {"TableName": "CUSTOMER", "ColumnName": "CITY", "PandasDataType": "string"},
    ])
    dax_measures = FakeDF([])
    dax_columns = FakeDF([
        {"TableName": "ORDERS", "ColumnName": "Net Amount", "Expression": "ORDERS[AMOUNT] * 0.9"},
    ])
    dax_tables = FakeDF([])
    relationships = FakeDF([])
    m_parameters = FakeDF([])
    power_query = FakeDF([
        {"TableName": "REGION_PARAM", "Expression": _enter_data_m(ENTER_ROWS, ENTER_COLS, ENTER_TAIL)},
        {"TableName": "CUSTOMER", "Expression":
            'let Source = Snowflake.Databases("acct","WH"){[Name="RAW"]}[Data] in Source'},
        # ORDERS has no M and no policy: the honest placeholder partition stays.
    ])
    tmschema_columns = FakeDF([
        {"ID": 1, "TableName": "ORDERS", "Name": "ORDER_ID", "Type": 1, "DataType": 6, "SourceColumn": "ORDER_ID"},
        {"ID": 2, "TableName": "ORDERS", "Name": "AMOUNT", "Type": 1, "DataType": 10, "SourceColumn": "AMOUNT"},
        {"ID": 3, "TableName": "ORDERS", "Name": "ORDER_DATE", "Type": 1, "DataType": 9, "SourceColumn": "ORDER_DATE"},
        {"ID": 4, "TableName": "ORDERS", "Name": "REGION", "Type": 1, "DataType": 2, "SourceColumn": "REGION"},
        {"ID": 5, "TableName": "ORDERS", "Name": "Month Name", "Type": 1, "DataType": 2,
         "SourceColumn": "MONTH_NAME", "SortByColumnID": 6},
        {"ID": 6, "TableName": "ORDERS", "Name": "Month Num", "Type": 1, "DataType": 6,
         "SourceColumn": "MONTH_NUM", "SortByColumnID": float("nan")},
        {"ID": 7, "TableName": "ORDERS", "Name": "Net Amount", "Type": 2, "DataType": 8, "SourceColumn": None},
        {"ID": 10, "TableName": "REGION_PARAM", "Name": "Region", "Type": 1, "DataType": 2, "SourceColumn": "Region"},
        {"ID": 11, "TableName": "REGION_PARAM", "Name": "Quota Target", "Type": 1, "DataType": 6,
         "SourceColumn": "Quota Target"},
        {"ID": 12, "TableName": "REGION_PARAM", "Name": "Valid From", "Type": 1, "DataType": 9,
         "SourceColumn": "Valid From"},
        {"ID": 13, "TableName": "REGION_PARAM", "Name": "Active", "Type": 1, "DataType": 11, "SourceColumn": "Active"},
        {"ID": 14, "TableName": "REGION_PARAM", "Name": "Note", "Type": 1, "DataType": 2, "SourceColumn": "Note"},
        {"ID": 20, "TableName": "EVENTS", "Name": "EVENT_ID", "Type": 1, "DataType": 6, "SourceColumn": "EVENT_ID"},
        {"ID": 21, "TableName": "EVENTS", "Name": "EVENT_TS", "Type": 1, "DataType": 9, "SourceColumn": "EVENT_TS"},
        {"ID": 30, "TableName": "CUSTOMER", "Name": "CUST_ID", "Type": 1, "DataType": 6, "SourceColumn": "CUST_ID"},
        # model-level rename: the model calls it CustName, the query returns CUSTOMER_NAME
        {"ID": 31, "TableName": "CUSTOMER", "Name": "CustName", "Type": 1, "DataType": 2,
         "SourceColumn": "CUSTOMER_NAME"},
        {"ID": 32, "TableName": "CUSTOMER", "Name": "COUNTRY", "Type": 1, "DataType": 2, "SourceColumn": float("nan")},
        {"ID": 33, "TableName": "CUSTOMER", "Name": "CITY", "Type": 1, "DataType": 2, "SourceColumn": "CITY"},
    ])
    tmschema_refresh_policies = FakeDF([
        {"TableName": "EVENTS", "PolicyType": 1, "RollingWindowGranularity": 1, "RollingWindowPeriods": 48,
         "IncrementalGranularity": 0, "IncrementalPeriods": 10, "IncrementalPeriodsOffset": 0,
         "PollingExpression": None, "SourceExpression": INCR_M, "Mode": 0},
    ])
    tmschema_hierarchies = FakeDF([
        {"ID": 1, "TableName": "CUSTOMER", "Name": "Geography"},
        {"ID": 2, "TableName": "CUSTOMER", "Name": "Empty Hierarchy"},
    ])
    tmschema_levels = FakeDF([
        {"HierarchyName": "Geography", "TableName": "CUSTOMER", "Ordinal": 1, "Name": "City", "ColumnName": "CITY"},
        {"HierarchyName": "Geography", "TableName": "CUSTOMER", "Ordinal": 0, "Name": "Country", "ColumnName": "COUNTRY"},
    ])
    rls = FakeDF([
        {"TableName": "ORDERS", "RoleName": "Regional", "RoleDescription": "own region only",
         "FilterExpression": "[REGION] = USERPRINCIPALNAME()", "State": 1},
        {"TableName": "CUSTOMER", "RoleName": "Regional", "RoleDescription": "own region only",
         "FilterExpression": None, "State": 1},
        {"TableName": "ORDERS", "RoleName": "Executive", "RoleDescription": None,
         "FilterExpression": "TRUE()", "State": 1},
    ])


def _rich(dialect=None):
    mod = _load_module()
    if dialect is None:
        return mod, mod.build_model_from_pbixray(RichPBIXRay(), "Rich")
    return mod, mod.build_model_from_pbixray(RichPBIXRay(), "Rich", dialect=dialect)


def _tbl(tmsl, name):
    return next(t for t in tmsl["model"]["tables"] if t["name"] == name)


def test_phantom_calculated_columns():
    """F6: pbixray's schema lists a calculated column a second time as a plain
    column; only the calculated one may survive (the plain one binds to a SQL
    column that does not exist)."""
    _, tmsl = _rich()
    cols = [c for c in _tbl(tmsl, "ORDERS")["columns"] if c["name"] == "Net Amount"]
    assert len(cols) == 1 and cols[0]["type"] == "calculated", cols
    assert cols[0]["expression"] == "ORDERS[AMOUNT] * 0.9", cols
    assert cols[0]["dataType"] == "double", f"calculated column dataType must come from the model: {cols[0]}"
    print("  ok [F6]: calculated columns are emitted once, with their real dataType")


def test_source_column_and_datatype():
    """F10 + dataType: sourceColumn comes from tmschema_columns (model-level
    renames), and the TMSL dataType from the model rather than a pandas guess."""
    _, tmsl = _rich()
    cust = {c["name"]: c for c in _tbl(tmsl, "CUSTOMER")["columns"]}
    assert cust["CustName"]["sourceColumn"] == "CUSTOMER_NAME", cust["CustName"]
    assert cust["CUST_ID"]["sourceColumn"] == "CUST_ID", cust["CUST_ID"]
    assert cust["COUNTRY"]["sourceColumn"] == "COUNTRY", "a missing SourceColumn falls back to the name"
    orders = {c["name"]: c for c in _tbl(tmsl, "ORDERS")["columns"]}
    assert orders["AMOUNT"]["dataType"] == "decimal", f"fixed-decimal columns are decimal, not double: {orders['AMOUNT']}"
    assert orders["ORDER_DATE"]["dataType"] == "dateTime" and orders["ORDER_ID"]["dataType"] == "int64"
    assert orders["REGION"]["dataType"] == "string"
    # Without tmschema_columns the pandas mapping still applies (older pbixray / mocks).
    mod = _load_module()
    plain = mod.assemble_tmsl("X", [{"TableName": "T", "ColumnName": "C", "PandasDataType": "Float64"}], [], [])
    c = plain["model"]["tables"][0]["columns"][0]
    assert c["dataType"] == "double" and c["sourceColumn"] == "C", c
    # TOM data types also arrive as names.
    named = mod.assemble_tmsl("X", [{"TableName": "T", "ColumnName": "C", "PandasDataType": "string"}], [], [],
                              column_recs=[{"TableName": "T", "Name": "C", "Type": 1, "DataType": "Decimal"}])
    assert named["model"]["tables"][0]["columns"][0]["dataType"] == "decimal"
    print("  ok [F10]: sourceColumn from tmschema_columns; dataType from the model (decimal/dateTime/...)")


def test_sort_by_column():
    _, tmsl = _rich()
    orders = {c["name"]: c for c in _tbl(tmsl, "ORDERS")["columns"]}
    assert orders["Month Name"].get("sortByColumn") == "Month Num", orders["Month Name"]
    assert "sortByColumn" not in orders["Month Num"] and "sortByColumn" not in orders["REGION"], orders
    mod = _load_module()
    by_name = mod.assemble_tmsl("X", [{"TableName": "T", "ColumnName": "A", "PandasDataType": "string"},
                                      {"TableName": "T", "ColumnName": "B", "PandasDataType": "Int64"}], [], [],
                                column_recs=[{"TableName": "T", "Name": "A", "Type": 1, "DataType": 2,
                                              "SortByColumn": "B"}])
    assert by_name["model"]["tables"][0]["columns"][0]["sortByColumn"] == "B", by_name
    print("  ok [sortByColumn]: resolved from SortByColumnID or SortByColumn; absent otherwise")


def test_hierarchies():
    _, tmsl = _rich()
    hs = _tbl(tmsl, "CUSTOMER").get("hierarchies")
    assert hs and [h["name"] for h in hs] == ["Geography"], f"empty hierarchies are not emitted: {hs}"
    assert hs[0]["levels"] == [{"name": "Country", "ordinal": 0, "column": "COUNTRY"},
                               {"name": "City", "ordinal": 1, "column": "CITY"}], hs
    assert "hierarchies" not in _tbl(tmsl, "ORDERS")
    print("  ok [hierarchies]: levels ordered by ordinal, bound to their columns")


def test_roles():
    """G25: rls -> model.roles[].tablePermissions[].filterExpression, the shape
    the vendored converter's security detector reads."""
    _, tmsl = _rich()
    roles = {r["name"]: r for r in tmsl["model"].get("roles", [])}
    assert set(roles) == {"Regional", "Executive"}, roles
    reg = roles["Regional"]
    assert reg["modelPermission"] == "read" and reg["description"] == "own region only", reg
    assert reg["tablePermissions"] == [{"name": "ORDERS", "filterExpression": "[REGION] = USERPRINCIPALNAME()"}], reg
    assert "description" not in roles["Executive"], roles["Executive"]
    assert roles["Executive"]["tablePermissions"] == [{"name": "ORDERS", "filterExpression": "TRUE()"}]
    mod = _load_module()
    assert "roles" not in mod.assemble_tmsl("X", [], [], [])["model"], "no rls rows -> no roles key"
    print("  ok [G25]: roles[].tablePermissions[].filterExpression; table permissions without a filter are dropped")


def test_incremental_refresh_policy():
    """F5: a table whose partitions carry no M takes its source from the refresh
    policy's SourceExpression and carries a TMSL refreshPolicy."""
    _, tmsl = _rich()
    ev = _tbl(tmsl, "EVENTS")
    part = ev["partitions"][0]["source"]
    assert part["type"] == "m" and part["expression"] == INCR_M, part
    assert "pbixray: no Power Query" not in json.dumps(part), "must not be the placeholder partition"
    rp = ev["refreshPolicy"]
    assert rp["policyType"] == "basic", rp
    assert rp["rollingWindowGranularity"] == "month" and rp["rollingWindowPeriods"] == 48, rp
    assert rp["incrementalGranularity"] == "day" and rp["incrementalPeriods"] == 10, rp
    assert rp["mode"] == "import", rp
    assert "pollingExpression" not in rp and "RangeStart" in "\n".join(rp["sourceExpression"]), rp
    # A table that has its own M keeps it (policy only adds refreshPolicy).
    mod = _load_module()
    keep = mod.assemble_tmsl("X", [{"TableName": "T", "ColumnName": "C", "PandasDataType": "string"}], [], [],
                             mquery_recs=[{"TableName": "T", "Expression": "let Source = 1 in Source"}],
                             refresh_policy_recs=[{"TableName": "T", "PolicyType": 1, "RollingWindowGranularity": "Year",
                                                   "RollingWindowPeriods": 3, "SourceExpression": INCR_M}])
    t = keep["model"]["tables"][0]
    assert t["partitions"][0]["source"]["expression"] == "let Source = 1 in Source", t
    assert t["refreshPolicy"]["rollingWindowGranularity"] == "year", t
    print("  ok [F5]: no-M incremental tables source from SourceExpression and carry refreshPolicy")


def _ruby_fold(expr, dialect="snowflake", policy=None):
    """Fold the M through the real PbiNativeQuery; returns the parsed JSON."""
    rb = os.path.join(SKILL, "scripts", "lib")
    prog = ("require 'json'; require %s; e = JSON.parse(STDIN.read); "
            "n = PbiNativeQuery.extract_from_expression('T', e['m'], nil, e['policy']); f = PbiNativeQuery.fold(n, e['dialect']); "
            "puts JSON.generate('sql' => n.statement, 'folded_sql' => f.statement, 'unsupported' => f.unsupported, "
            "'renames' => f.renames, 'notes' => f.notes, 'database' => n.database)") % json.dumps(os.path.join(rb, "pbi_native_query"))
    r = subprocess.run(["ruby", "-e", prog], input=json.dumps({"m": expr, "dialect": dialect, "policy": policy}),
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_enter_data_to_sql():
    """F4: Table.FromRows "Enter data" partitions become a real SQL SELECT over
    the decoded rows (typed columns), never a placeholder path; later M steps
    stay foldable."""
    mod, tmsl = _rich()
    rp = _tbl(tmsl, "REGION_PARAM")
    src = rp["partitions"][0]["source"]
    assert src["type"] == "m", src
    m = src["expression"]
    assert "Table.FromRows" not in m and "Value.NativeQuery(" in m, m
    assert "pbixray: no Power Query" not in m, "must not be the placeholder partition"
    assert "Changed Type" in m and "Renamed Columns" in m, "later M steps are kept verbatim"
    assert "SigmaMigration" in json.dumps(rp.get("annotations", [])), rp.get("annotations")

    # The SQL is recovered by the real Ruby extractor (it is what runs at convert time).
    if shutil.which("ruby"):
        out = _ruby_fold(m)
        sql = out["sql"]
        assert out["unsupported"] == [], f"later steps must still fold: {out}"
        assert out["renames"] == {"Quota Target": "Quota"}, out["renames"]
        assert sql.startswith("SELECT CAST('North' AS VARCHAR) AS \"Region\", CAST(100 AS BIGINT) AS \"Quota\", "
                              "CAST('2024-01-01 00:00:00' AS TIMESTAMP) AS \"Valid From\", CAST(TRUE AS BOOLEAN) AS \"Active\", "
                              "CAST('a#(b)' AS VARCHAR) AS \"Note\""), sql
        assert "UNION ALL" in sql, sql
        # second row: quote doubled, backslash doubled, newline escaped, bare NULLs (row 1 fixes the types)
        assert "'O''Neil \\\\ South\\nEast', 250, NULL, FALSE, NULL" in sql, sql
        assert "FROM" not in sql, f"no table reference (a FROM would be read as a warehouse path): {sql}"
        # databricks: backtick identifiers + Databricks types
        dbx = _ruby_fold(_tbl(mod.build_model_from_pbixray(RichPBIXRay(), "Rich", dialect="databricks"), "REGION_PARAM")
                         ["partitions"][0]["source"]["expression"], "databricks")
        assert dbx["sql"].startswith("SELECT CAST('North' AS STRING) AS `Region`, CAST(100 AS BIGINT) AS `Quota`"), dbx["sql"]
        bq = _ruby_fold(_tbl(mod.build_model_from_pbixray(RichPBIXRay(), "Rich", dialect="BigQuery"), "REGION_PARAM")
                        ["partitions"][0]["source"]["expression"], "bigquery")
        assert bq["sql"].startswith("SELECT CAST('North' AS STRING) AS `Region`, CAST(100 AS INT64) AS `Quota`"), bq["sql"]
    else:
        print("  skip [F4 fold]: ruby not found")
    print("  ok [F4]: Enter-data rows become typed SQL; later steps fold; per-dialect identifiers/types")


def test_enter_data_edge_cases():
    mod = _load_module()
    empty_m = _enter_data_m([], ["A", "B"], "in\n    Source")
    out = mod.assemble_tmsl("X",
        [{"TableName": "T", "ColumnName": "A", "PandasDataType": "string"},
         {"TableName": "T", "ColumnName": "B", "PandasDataType": "Int64"}], [], [],
        mquery_recs=[{"TableName": "T", "Expression": empty_m}])
    m = out["model"]["tables"][0]["partitions"][0]["source"]["expression"]
    assert "Table.FromRows" not in m and "WHERE 1 = 0" in m, m
    # A list-of-names column spec and untyped (string) columns.
    raw = zlib.compressobj(9, zlib.DEFLATED, -15)
    blob = raw.compress(json.dumps([["x", 1]]).encode()) + raw.flush()
    named_m = ('let Source = Table.FromRows(Json.Document(Binary.Decompress(Binary.FromText("%s", BinaryEncoding.Base64), '
               'Compression.Deflate)), {"Name", "Count"}) in Source') % base64.b64encode(blob).decode()
    out = mod.assemble_tmsl("X", [{"TableName": "T", "ColumnName": "Name", "PandasDataType": "string"},
                                  {"TableName": "T", "ColumnName": "Count", "PandasDataType": "Int64"}], [], [],
                            mquery_recs=[{"TableName": "T", "Expression": named_m}])
    m = out["model"]["tables"][0]["partitions"][0]["source"]["expression"]
    assert "Table.FromRows" not in m and "CAST(1 AS BIGINT) AS \"\"Count\"\"" in m, m  # M doubles the quotes
    # Undecodable payload: the M is left exactly as it was (never a placeholder).
    broken = 'let Source = Table.FromRows(Json.Document(Binary.Decompress(Binary.FromText("!!!", BinaryEncoding.Base64), Compression.Deflate)), {"A"}) in Source'
    out = mod.assemble_tmsl("X", [{"TableName": "T", "ColumnName": "A", "PandasDataType": "string"}], [], [],
                            mquery_recs=[{"TableName": "T", "Expression": broken}])
    t = out["model"]["tables"][0]
    assert t["partitions"][0]["source"]["expression"] == broken, t["partitions"]
    assert any("Table.FromRows" in a.get("value", "") for a in t.get("annotations", [])), t
    # A value that does not fit its column type becomes NULL and is recorded, not guessed.
    cast_bad = _enter_data_m([["abc", "12"]], ["Label", "Qty"], "in\n    Source")
    out = mod.assemble_tmsl("X", [{"TableName": "T", "ColumnName": "Label", "PandasDataType": "Int64"},
                                  {"TableName": "T", "ColumnName": "Qty", "PandasDataType": "Int64"}], [], [],
                            mquery_recs=[{"TableName": "T", "Expression": cast_bad}])
    t = out["model"]["tables"][0]
    assert "CAST(NULL AS BIGINT) AS \"\"Label\"\"" in t["partitions"][0]["source"]["expression"], t["partitions"]
    assert any("Label" in a.get("value", "") for a in t.get("annotations", [])), t.get("annotations")
    print("  ok [F4 edges]: empty tables, name-list schema, unparsable values recorded, undecodable payload untouched")


def test_enter_data_int64_precision():
    """Whole-number cells above 2^53 must survive exactly (no float round trip)."""
    mod = _load_module()
    big = "9007199254740993"
    assert mod._sql_literal(big, "int64") == big, mod._sql_literal(big, "int64")
    assert mod._sql_literal(int(big), "int64") == big
    assert mod._sql_literal(" -" + big + " ", "int64") == "-" + big
    assert mod._sql_literal("3.0", "int64") == "3"
    assert mod._sql_literal("1e3", "int64") == "1000"
    assert mod._sql_literal("3.5", "int64") is None
    assert mod._sql_literal("abc", "int64") is None
    assert mod._sql_literal(True, "int64") is None
    m = _enter_data_m([[big, "x"]], ["Id", "Name"], "in\n    Source")
    out = mod.assemble_tmsl("X", [{"TableName": "T", "ColumnName": "Id", "PandasDataType": "Int64"},
                                  {"TableName": "T", "ColumnName": "Name", "PandasDataType": "string"}], [], [],
                            mquery_recs=[{"TableName": "T", "Expression": m}])
    expr = out["model"]["tables"][0]["partitions"][0]["source"]["expression"]
    assert "CAST(%s AS BIGINT)" % big in expr, expr
    print("  ok: Enter-data int64 keeps 16+ digit integers exact")


def _one_table_model(mod, rows, cols, ptypes, dialect="snowflake", culture=None, **kw):
    m = _enter_data_m(rows, cols, "in\n    Source")
    return mod.assemble_tmsl(
        "X", [{"TableName": "T", "ColumnName": c, "PandasDataType": t} for c, t in zip(cols, ptypes)], [], [],
        mquery_recs=[{"TableName": "T", "Expression": m}], dialect=dialect, culture=culture, **kw)


def test_enter_data_dates_parse_with_the_model_culture():
    """whole-5: Enter Data keeps dates as the typed text ('1/15/2024' in en-US); they must not become NULL."""
    mod = _load_module()
    assert mod._sql_literal("1/15/2024", "dateTime") == "CAST('2024-01-15 00:00:00' AS TIMESTAMP)"      # en-US default
    assert mod._sql_literal("12/25/2024", "dateTime", "en-US") == "CAST('2024-12-25 00:00:00' AS TIMESTAMP)"
    assert mod._sql_literal("15/01/2024", "dateTime", "en-GB") == "CAST('2024-01-15 00:00:00' AS TIMESTAMP)"
    assert mod._sql_literal("15.01.2024", "dateTime", "de-DE") == "CAST('2024-01-15 00:00:00' AS TIMESTAMP)"
    assert mod._sql_literal("2024/01/15", "dateTime", "ja-JP") == "CAST('2024-01-15 00:00:00' AS TIMESTAMP)"
    assert mod._sql_literal("1/15/2024 3:30 PM", "dateTime", "en-US") == "CAST('2024-01-15 15:30:00' AS TIMESTAMP)"
    assert mod._sql_literal("1/15/2024 12:05:09 AM", "dateTime", "en-US") == "CAST('2024-01-15 00:05:09' AS TIMESTAMP)"
    assert mod._sql_literal("2024-01-15", "dateTime", "de-DE") == "CAST('2024-01-15 00:00:00' AS TIMESTAMP)"  # ISO anywhere
    # the same text is a DIFFERENT date by culture: 3/4/2024 is March 4 in en-US, April 3 in en-GB
    assert "2024-03-04" in mod._sql_literal("3/4/2024", "dateTime", "en-US")
    assert "2024-04-03" in mod._sql_literal("3/4/2024", "dateTime", "en-GB")
    # never guessed: out-of-range for the culture's order, two-digit years, words
    assert mod._sql_literal("15/01/2024", "dateTime", "en-US") is None
    assert mod._sql_literal("1/15/24", "dateTime", "en-US") is None
    assert mod._sql_literal("January 15", "dateTime", "en-US") is None
    assert mod._sql_literal("2/30/2024", "dateTime", "en-US") is None
    assert mod._sql_literal("13:00 PM 1/1/2024", "dateTime", "en-US") is None
    out = _one_table_model(mod, [["1/1/2024", "1"], ["12/25/2024", "2"]], ["Date", "N"], ["datetime64[ns]", "Int64"])
    t = out["model"]["tables"][0]
    sql = t["partitions"][0]["source"]["expression"]
    sql = "\n".join(sql) if isinstance(sql, list) else sql
    assert "2024-01-01 00:00:00" in sql and "2024-12-25 00:00:00" in sql and "CAST(NULL AS TIMESTAMP)" not in sql, sql
    # de-DE culture: the same cells are D.M.Y text, '1/1/2024' no longer parses -> loud
    out = _one_table_model(mod, [["31.12.2024", "1"], ["1/15/2024", "2"]], ["Date", "N"], ["datetime64[ns]", "Int64"],
                           culture="de-DE")
    t = out["model"]["tables"][0]
    assert out["model"]["culture"] == "de-DE"
    notes = [a["value"] for a in t.get("annotations", [])]
    assert any("Date (row 2)" in n and "de-DE" in n and n.startswith("Enter data:") for n in notes), notes
    lines = mod.extract_warnings(out)
    assert any("Date (row 2)" in l for l in lines), lines
    print("  ok [whole-5]: Enter-data dates parse with the model culture; unparseable cells are named loudly")


def test_culture_is_read_from_pbixray_or_assumed_honestly():
    """pipeline-3 / whole-11: the model culture comes from the .pbix when pbixray exposes it."""
    mod = _load_module()

    class Bare(FakePBIXRay):
        pass

    plain = mod.build_model_from_pbixray(Bare(), "M")
    assert plain["model"]["culture"] == "en-US"
    ann = plain["model"].get("annotations") or []
    assert any(a["name"] == "SigmaMigration.CultureAssumed" and "en-US is assumed" in a["value"] for a in ann), ann
    assert any("en-US is assumed" in l for l in mod.extract_warnings(plain)), mod.extract_warnings(plain)

    class WithAttr(FakePBIXRay):
        culture = "de-DE"
    got = mod.build_model_from_pbixray(WithAttr(), "M")
    assert got["model"]["culture"] == "de-DE" and not got["model"].get("annotations"), got["model"]

    class WithTable(FakePBIXRay):
        cultures = FakeDF([{"Name": "fr-FR"}])
    assert mod.build_model_from_pbixray(WithTable(), "M")["model"]["culture"] == "fr-FR"

    class Several(FakePBIXRay):
        cultures = FakeDF([{"Name": "en-US"}, {"Name": "es-ES"}])
    sev = mod.build_model_from_pbixray(Several(), "M")
    assert sev["model"]["culture"] == "en-US"
    assert "es-ES" in sev["model"]["annotations"][0]["value"], sev["model"]["annotations"]

    class Meta(FakePBIXRay):
        metadata = FakeDF([{"Name": "Culture", "Value": "pt-BR"}, {"Name": "Other", "Value": "x"}])
    assert mod.build_model_from_pbixray(Meta(), "M")["model"]["culture"] == "pt-BR"

    class Junk(FakePBIXRay):
        culture = "not a culture!"
    assert mod.build_model_from_pbixray(Junk(), "M")["model"]["culture"] == "en-US"
    print("  ok [whole-11]: culture read from pbixray when exposed; en-US assumed (and flagged) otherwise")


def test_enter_data_dialects_ansi_and_unsupported():
    """compat: unknown warehouses never silently get Snowflake syntax."""
    mod = _load_module()
    for d in ("postgres", "redshift", "ansi", "Amazon Redshift"):
        out = _one_table_model(mod, [["a", "1.5"]], ["Name", "V"], ["string", "Float64"], dialect=d)
        sql = out["model"]["tables"][0]["partitions"][0]["source"]["expression"]
        sql = "\n".join(sql) if isinstance(sql, list) else sql
        assert "DOUBLE PRECISION" in sql and "AS DOUBLE)" not in sql and "VARCHAR" in sql, (d, sql)
    for d in ("azure_synapse", "mysql", "sqlserver", "oracle"):
        out = _one_table_model(mod, [["a", "1.5"]], ["Name", "V"], ["string", "Float64"], dialect=d)
        t = out["model"]["tables"][0]
        expr = t["partitions"][0]["source"]["expression"]
        expr = "\n".join(expr) if isinstance(expr, list) else expr
        assert "Table.FromRows" in expr and "NativeQuery" not in expr, (d, expr)
        notes = [a["value"] for a in t.get("annotations", [])]
        assert any(n.startswith("Enter-data SQL NOT generated") and d in n for n in notes), (d, notes)
        assert any("NOT generated" in l for l in mod.extract_warnings(out))
    try:
        mod.enter_data_sql(["A"], [["x"]], ["string"], "mysql")
        raise AssertionError("enter_data_sql must refuse an unsupported dialect")
    except ValueError:
        pass
    assert mod._normalize_dialect(None) == "snowflake" and mod._normalize_dialect("Snowflake") == "snowflake"
    print("  ok [compat]: postgres/redshift get ANSI types; synapse/mysql/other are refused with a loud note")


def test_dialect_help_names_the_real_flag():
    import subprocess
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts",
                                                     "extract-model-pbix.py"), "--help"], capture_output=True, text=True)
    assert "--dialect" in r.stdout and "passes its --warehouse-type" not in " ".join(r.stdout.split()), r.stdout
    print("  ok: --dialect help text names the flag the orchestrator passes")


def test_rich_model_converts():
    """End to end: the extracted model goes through the vendored converter and
    then the native-query restore (what migrate-powerbi.rb does). RLS is
    detected, the Enter-data table ends up as a Custom SQL element holding its
    rows (never a placeholder warehouse path), and the incremental-refresh table
    carries its rolling-window predicate."""
    if not shutil.which("node") or not os.path.exists(CONVERTER):
        print("  skip [rich convert]: node/converter not found")
        return
    _, tmsl = _rich()
    with tempfile.TemporaryDirectory() as d:
        bim = os.path.join(d, "model.bim")
        out_json = os.path.join(d, "converted.json")
        with open(bim, "w") as f:
            json.dump(tmsl, f)
        shim = os.path.join(d, "conv.mjs")
        conv_url = Path(CONVERTER).resolve().as_uri()
        with open(shim, "w") as f:
            f.write(
                "import { readFileSync, writeFileSync } from 'node:fs';\n"
                f"import {{ convertPowerBIToSigma }} from {json.dumps(conv_url)};\n"
                f"const model = JSON.parse(readFileSync({json.dumps(bim)},'utf8'));\n"
                "const out = convertPowerBIToSigma(model, {connectionId:'11111111-2222-3333-4444-555555555555', database:'ANALYTICS', schema:'PUBLIC'});\n"
                "const sec = out.security||[];\n"
                "if (!sec.some(s=>/Regional/.test(JSON.stringify(s)))) { console.error('NO RLS DETECTED '+JSON.stringify(sec)); process.exit(3); }\n"
                f"writeFileSync({json.dumps(out_json)}, JSON.stringify(out.model));\n"
                "console.log('CONVERT_OK security='+sec.length);\n")
        r = subprocess.run(["node", shim], capture_output=True, text=True)
        assert r.returncode == 0 and "CONVERT_OK" in r.stdout, f"converter rejected the model ({r.returncode})\n{r.stdout}\n{r.stderr}"
        if not shutil.which("ruby"):
            print("  skip [rich restore]: ruby not found")
            return
        rb = os.path.join(d, "restore.rb")
        with open(rb, "w") as f:
            f.write(
                "require 'json'\n"
                f"require {json.dumps(os.path.join(SKILL, 'scripts', 'lib', 'pbi_native_query'))}\n"
                f"dm = JSON.parse(File.read({json.dumps(out_json)}))\n"
                f"model = JSON.parse(File.read({json.dumps(bim)}))['model']\n"
                "result = PbiNativeQuery.apply!(dm, model)\n"
                "els = dm['pages'][0]['elements']\n"
                "param = els.find { |e| e['name'] == 'REGION_PARAM' }\n"
                "events = els.find { |e| e['name'] == 'EVENTS' }\n"
                "abort \"blockers: #{result['blockers']}\" unless result['blockers'].empty?\n"
                "abort 'enter data is not a sql element' unless param && param.dig('source', 'kind') == 'sql'\n"
                "abort 'enter data lost its rows' unless param['source']['statement'].include?(\"'North'\")\n"
                "abort 'quota column is not bound to the folded rename' unless param['columns'].any? { |c| c['name'] == 'Quota Target' && c['formula'] == '[Custom SQL/Quota]' }\n"
                "abort 'incremental window missing' unless events && events['source']['statement'].include?('DATEADD(month, -48')\n"
                "puts 'RESTORE_OK'\n")
        r2 = subprocess.run(["ruby", rb], capture_output=True, text=True)
        assert r2.returncode == 0 and "RESTORE_OK" in r2.stdout, f"{r2.stdout}\n{r2.stderr}"
    print(f"  ok [rich convert]: RLS detected; Enter-data is Custom SQL with its rows; incremental window folded ({r.stdout.strip()})")


def main():
    tmsl = test_assembly()
    test_converts(tmsl)
    test_composite_detection()
    test_phantom_calculated_columns()
    test_source_column_and_datatype()
    test_sort_by_column()
    test_hierarchies()
    test_roles()
    test_incremental_refresh_policy()
    test_enter_data_to_sql()
    test_enter_data_edge_cases()
    test_enter_data_int64_precision()
    test_enter_data_dates_parse_with_the_model_culture()
    test_culture_is_read_from_pbixray_or_assumed_honestly()
    test_enter_data_dialects_ansi_and_unsupported()
    test_dialect_help_names_the_real_flag()
    test_rich_model_converts()
    print("PASS test-extract-model-pbix.py")


if __name__ == "__main__":
    main()
