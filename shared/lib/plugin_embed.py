# plugin_embed.py — Python twin of shared/lib/plugin_embed.rb. Emits the
# VERIFIED Sigma {kind:"plugin"} element block. ALL config values are bare
# strings (object form is rejected, masked "Invalid kind:\"plugin\""). Twin
# emits sorted-key-identical output (shared/lib/testdata/plugin_embed_golden.json).
# Stdlib only (json); Windows-safe.
import json


def build(id, plugin_id, source_element_id, bindings, extra_config=None):
    if not id:
        raise ValueError("id required")
    if not plugin_id:
        raise ValueError("plugin_id required")
    if not source_element_id:
        raise ValueError("source_element_id required")

    config = {"source": {"kind": "element", "elementId": source_element_id}}
    for k, v in (bindings or {}).items():
        config[str(k)] = str(v)  # bare string columnId
    for k, v in (extra_config or {}).items():
        config[str(k)] = str(v)  # ALL config values -> string

    return {"id": id, "kind": "plugin", "pluginId": plugin_id, "config": config}
