#!/usr/bin/env python3
import copy
from warehouse_column_refs import apply

spec = {"pages": [{"elements": [{
    "name": "Order Fact", "source": {"kind": "warehouse-table", "connectionId": "conn",
    "path": ["DB", "S", "ORDER_FACT"]},
    "columns": [{"id": "inode-x/ORDER_ID", "formula": "[ORDER_FACT/Order Id]"},
                {"id": "calc", "formula": "Text([Order Fact/Order Id])", "name": "Text Id"}]
}, {"name": "Order View", "source": {"kind": "table", "elementId": "fact"},
    "columns": [{"id": "pass", "formula": "[Order Fact/Order Id]"}]}]}]}

def api(method, path, body=None):
    if method == "POST":
        return {"kind": "table", "inodeId": "t"}
    if path.startswith("/v2/connections/tables/"):
        return {"entries": [{"name": "ORDER_ID"}]}
    return {"friendlyName": False}

result = apply(spec, api)
fact, view = spec["pages"][0]["elements"]
assert fact["name"] == "ORDER_FACT"
assert fact["columns"][0] == {"id": "inode-x/ORDER_ID", "formula": "[ORDER_FACT/ORDER_ID]", "name": "Order Id"}
assert fact["columns"][1]["formula"] == "Text([ORDER_FACT/ORDER_ID])"
assert view["columns"][0] == {"id": "pass", "formula": "[ORDER_FACT/Order Id]", "name": "Order Id"}
assert result["connectionModes"] == {"conn": False}

friendly = copy.deepcopy(spec); original = copy.deepcopy(friendly)
apply(friendly, lambda *_args: {"friendlyName": True})
assert friendly == original
print("test_warehouse_column_refs: PASS")
