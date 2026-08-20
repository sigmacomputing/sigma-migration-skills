"""Ground warehouse-table references for Sigma connections without friendly names."""
import re
import urllib.parse


def _norm(value):
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())


def _match(entries, candidates):
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


def _columns(api, path):
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
    modes, cache, aliases, prefixes, id_map, unresolved = {}, {}, {}, set(), {}, []
    rewritten = rekeyed = reprefixed = 0
    elements = [e for p in (spec.get("pages") or []) for e in (p.get("elements") or [])]
    for element in elements:
        source = element.get("source") or {}
        if source.get("kind") != "warehouse-table":
            continue
        connection, path = str(source.get("connectionId") or ""), source.get("path")
        if not connection or not isinstance(path, list) or not path:
            continue
        if connection not in modes:
            modes[connection] = api("GET", f"/v2/connections/{connection}").get("friendlyName")
        friendly = modes[connection]
        if friendly not in (True, False):
            raise RuntimeError(f"connection {connection} did not report friendlyName")
        if friendly:
            continue
        old, physical_name = str(element.get("name") or ""), str(path[-1])
        if old and old != physical_name:
            if old in aliases and aliases[old] != physical_name:
                raise RuntimeError(f"ambiguous warehouse element name {old!r}")
            aliases[old] = physical_name
        element["name"] = physical_name
        key = (connection, tuple(path))
        if key not in cache:
            table = api("POST", f"/v2/connection/{connection}/lookup", {"path": path})
            if table.get("kind") != "table" or not table.get("inodeId"):
                raise RuntimeError(f"{'.'.join(path)} did not resolve to a table")
            cache[key] = _columns(api, f"/v2/connections/tables/{table['inodeId']}/columns")
        entries = cache[key]
        refs = {_norm(entry.get("name")): str(entry.get("name")) for entry in entries if entry.get("name")}
        prefixes.update(filter(None, (old, physical_name)))
        for column in element.get("columns") or []:
            match = re.fullmatch(r"\[([^\]/]+)/([^\]/]+)\]", str(column.get("formula") or ""))
            if not match:
                continue
            prefix, leaf = match.groups()
            cid = str(column.get("id") or "")
            id_leaf = cid.split("/", 1)[1] if "/" in cid else None
            physical = _match(entries, (leaf, column.get("name"), id_leaf))
            if not physical:
                if cid.startswith("inode-"):
                    unresolved.append(f"{'.'.join(path)}: {prefix}/{leaf}")
                continue
            column.setdefault("name", leaf)
            if cid.startswith("inode-") and id_leaf != physical:
                new_id = cid.split("/", 1)[0] + "/" + physical
                id_map[cid] = new_id
                column["id"] = new_id
                rekeyed += 1
            grounded = f"[{physical_name}/{physical}]"
            if column.get("formula") != grounded:
                column["formula"] = grounded
                rewritten += 1

        def same_element(node):
            nonlocal rewritten
            if isinstance(node, dict):
                display = None
                if isinstance(node.get("formula"), str):
                    def replace(match):
                        nonlocal display, rewritten
                        prefix, leaf = match.group(1), match.group(2)[1:]
                        if "/" in leaf or prefix not in (old, physical_name) or _norm(leaf) not in refs:
                            return match.group(0)
                        display = display or leaf
                        grounded = f"[{physical_name}/{refs[_norm(leaf)]}]"
                        rewritten += grounded != match.group(0)
                        return grounded
                    node["formula"] = re.sub(r"\[([^\]/]+)(/[^\]]+)\]", replace, node["formula"])
                if display and not node.get("name"):
                    node["name"] = display
                for key2, value in node.items():
                    if key2 != "formula":
                        same_element(value)
            elif isinstance(node, list):
                for value in node:
                    same_element(value)
        same_element(element)

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

    def derived(node):
        nonlocal reprefixed
        if isinstance(node, dict):
            display = None
            if isinstance(node.get("formula"), str):
                def replace(match):
                    nonlocal display, reprefixed
                    prefix, suffix = match.group(1), match.group(2)
                    replacement = aliases.get(prefix, prefix)
                    reprefixed += replacement != prefix
                    if "/" not in suffix[1:] and (prefix in prefixes or replacement in prefixes):
                        display = display or suffix[1:]
                    return f"[{replacement}{suffix}]"
                node["formula"] = re.sub(r"\[([^\]/]+)(/[^\]]+)\]", replace, node["formula"])
            if display and not node.get("name"):
                node["name"] = display
            for key, value in node.items():
                if key != "formula":
                    derived(value)
        elif isinstance(node, list):
            for value in node:
                derived(value)
    derived(spec)
    if unresolved:
        raise RuntimeError("warehouse columns not found in catalog: " + ", ".join(sorted(set(unresolved))))
    return {"rewritten": rewritten, "rekeyed": rekeyed, "reprefixed": reprefixed,
            "connectionModes": modes}
