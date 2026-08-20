"""Ground warehouse-table references for Sigma connections without friendly names."""
import copy
import json
import re
import urllib.parse


def _norm(value):
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())


def _catalog_match(entries, candidates):
    names = [str(entry.get("name") or "") for entry in entries if entry.get("name")]
    for candidate in [str(value) for value in candidates if value]:
        if candidate in names:
            return candidate
        folded = [name for name in names if name.lower() == candidate.lower()]
        if len(folded) == 1:
            return folded[0]
        normalized = [name for name in names if _norm(name) == _norm(candidate)]
        if len(normalized) == 1:
            return normalized[0]
    return None


def _list_entries(api, path):
    out, token = [], None
    while True:
        query = {"pageSize": 500}
        if token:
            query["pageToken"] = token
        page = api("GET", path + "?" + urllib.parse.urlencode(query))
        out.extend(page.get("entries") or [])
        token = page.get("nextPageToken")
        if not token:
            return out


def apply(spec, api):
    modes, lookups, aliases, prefixes, id_map, unresolved = {}, {}, {}, set(), {}, []
    rewritten = rekeyed = reprefixed = 0
    elements = [element for page in (spec.get("pages") or []) for element in (page.get("elements") or [])]

    for element in elements:
        source = element.get("source") or {}
        if source.get("kind") != "warehouse-table":
            continue
        connection_id, path = str(source.get("connectionId") or ""), source.get("path")
        if not connection_id or not isinstance(path, list) or not path:
            continue
        if connection_id not in modes:
            modes[connection_id] = api("GET", f"/v2/connections/{connection_id}").get("friendlyName")
        friendly = modes[connection_id]
        if friendly not in (True, False):
            raise RuntimeError(f"connection {connection_id} did not report friendlyName")
        if friendly:
            continue

        old_name, physical_name = str(element.get("name") or ""), str(path[-1])
        if old_name and old_name != physical_name:
            prior = aliases.get(old_name)
            if prior and prior != physical_name:
                raise RuntimeError(f"element {old_name!r} maps to both {prior!r} and {physical_name!r}")
            aliases[old_name] = physical_name
        element["name"] = physical_name
        key = (connection_id, tuple(path))
        if key not in lookups:
            table = api("POST", f"/v2/connection/{connection_id}/lookup", {"path": path})
            inode = table.get("inodeId")
            if table.get("kind") != "table" or not inode:
                raise RuntimeError(f"{'.'.join(path)} did not resolve to a table inode")
            lookups[key] = _list_entries(api, f"/v2/connections/tables/{inode}/columns")
        entries = lookups[key]
        refs = {_norm(entry.get("name")): str(entry.get("name")) for entry in entries if entry.get("name")}
        prefixes.update(filter(None, (old_name, physical_name)))

        for column in element.get("columns") or []:
            match = re.fullmatch(r"\[([^\]/]+)/([^\]/]+)\]", str(column.get("formula") or ""))
            if not match:
                continue
            prefix, leaf = match.groups()
            col_id = str(column.get("id") or "")
            id_leaf = col_id.split("/", 1)[1] if "/" in col_id else None
            physical = _catalog_match(entries, (leaf, column.get("name"), id_leaf))
            if not physical:
                if col_id.startswith("inode-"):
                    unresolved.append(f"{'.'.join(path)}: {prefix}/{leaf}")
                continue
            column.setdefault("name", leaf)
            if col_id.startswith("inode-") and id_leaf != physical:
                new_id = col_id.split("/", 1)[0] + "/" + physical
                id_map[col_id] = new_id
                column["id"] = new_id
                rekeyed += 1
            grounded = f"[{physical_name}/{physical}]"
            if column.get("formula") != grounded:
                column["formula"] = grounded
                rewritten += 1

        def ground_same(node):
            nonlocal rewritten
            if isinstance(node, dict):
                formula = node.get("formula")
                display = None
                if isinstance(formula, str):
                    def replace(match):
                        nonlocal display, rewritten
                        prefix, suffix = match.group(1), match.group(2)[1:]
                        if "/" in suffix or prefix not in (old_name, physical_name):
                            return match.group(0)
                        physical = refs.get(_norm(suffix))
                        if not physical:
                            return match.group(0)
                        display = display or suffix
                        grounded = f"[{physical_name}/{physical}]"
                        rewritten += grounded != match.group(0)
                        return grounded
                    node["formula"] = re.sub(r"\[([^\]/]+)(/[^\]]+)\]", replace, formula)
                if display and not node.get("name"):
                    node["name"] = display
                for key2, value in node.items():
                    if key2 != "formula":
                        ground_same(value)
            elif isinstance(node, list):
                for value in node:
                    ground_same(value)
        ground_same(element)

    def replace_ids(node):
        if isinstance(node, dict):
            for key, value in list(node.items()):
                node[key] = replace_ids(value)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                node[index] = replace_ids(value)
        elif isinstance(node, str):
            return id_map.get(node, node)
        return node
    replace_ids(spec)

    def reprefix(node):
        nonlocal reprefixed
        if isinstance(node, dict):
            formula, display = node.get("formula"), None
            if isinstance(formula, str):
                def replace(match):
                    nonlocal reprefixed, display
                    prefix, suffix = match.group(1), match.group(2)
                    replacement = aliases.get(prefix, prefix)
                    reprefixed += replacement != prefix
                    if "/" not in suffix[1:] and (prefix in prefixes or replacement in prefixes):
                        display = display or suffix[1:]
                    return f"[{replacement}{suffix}]"
                node["formula"] = re.sub(r"\[([^\]/]+)(/[^\]]+)\]", replace, formula)
            if display and not node.get("name"):
                node["name"] = display
            for key, value in node.items():
                if key != "formula":
                    reprefix(value)
        elif isinstance(node, list):
            for value in node:
                reprefix(value)
    reprefix(spec)

    if unresolved:
        raise RuntimeError("warehouse columns not found in catalog: " + ", ".join(sorted(set(unresolved))))
    return {"rewritten": rewritten, "rekeyed": rekeyed, "reprefixed": reprefixed,
            "connectionModes": modes}
