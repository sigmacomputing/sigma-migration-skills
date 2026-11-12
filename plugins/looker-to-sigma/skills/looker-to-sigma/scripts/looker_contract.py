"""Phase 1 contract resolution for migrate-looker.py, split out so it is unit
testable offline.

`--contract PATH` lets an operator supply a pre-built / hand-reviewed dashboard
contract instead of fetching or parsing one. The supplied contract is an
escape hatch (refs/operating-contract.md), so it is gate-preserving:

* a `--contract-reason` is mandatory;
* when a live source (--dashboard-id / --look-id) is also given, the normal
  fetch STILL runs, into `contract.source.json`; live parity's EXPECTED side
  reads the SOURCE tile (never the supplied one), so a rewritten contract cannot
  grade itself;
* `contract-provenance.json` records the supplied path, its sha256 and a
  tile-level diff vs the source fetch, and it is surfaced in
  migration-result.json / MIGRATION_REPORT.md.
"""
import hashlib
import json
import os
import shutil

# Tile properties that define what a tile asks Looker for.
TILE_KEYS = ("explore", "fields", "filters", "dynamicFields", "pivots", "sorts")
SECTION_MARK = "<!-- looker-contract-annex -->"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def load_contract(path):
    with open(path) as f:
        dash = json.load(f)
    if isinstance(dash, list):
        dash = dash[0]
    return dash


def tile_map(dash):
    """name -> tile (first wins on a duplicate name, matching parity's by_name
    for the common case; later duplicates are ignored)."""
    out = {}
    for el in (dash or {}).get("elements") or []:
        out.setdefault(el.get("name"), el)
    return out


def diff_contracts(supplied, source):
    """Tile-level diff of the supplied contract against the source fetch.

    Returns {changedTiles:[{name, changed:[keys]}], addedTiles:[names] (in
    supplied only), removedTiles:[names] (in source only)}."""
    sup, src = tile_map(supplied), tile_map(source)
    changed = []
    for name in sorted(n for n in sup if n in src):
        keys = [k for k in TILE_KEYS if sup[name].get(k) != src[name].get(k)]
        if keys:
            changed.append({"name": name, "changed": keys})
    return {
        "changedTiles": changed,
        "addedTiles": sorted(n for n in sup if n not in src and n is not None),
        "removedTiles": sorted(n for n in src if n not in sup and n is not None),
    }


def resolve_phase1_contract(contract, reason, workdir, source_fetch=None):
    """Install a supplied contract as <workdir>/contract.json.

    source_fetch: optional callable(path) that fetches the live source contract
    into `path` (the caller passes the dashboard/look fetch). Returns
    (contract_path, source_dash_or_None, provenance). Raises ValueError for a
    missing reason or an unreadable contract."""
    if not str(reason or "").strip():
        raise ValueError("--contract requires --contract-reason \"<why a supplied "
                         "contract is needed>\" (an escape hatch must be named)")
    if not os.path.isfile(contract):
        raise ValueError(f"--contract file not found: {contract}")
    contract_path = os.path.join(workdir, "contract.json")
    if os.path.abspath(contract) != os.path.abspath(contract_path):
        shutil.copyfile(contract, contract_path)
    try:
        supplied = load_contract(contract_path)
        assert isinstance(supplied, dict) and isinstance(supplied.get("elements"), list)
    except Exception as ex:
        raise ValueError(f"--contract is not a dashboard contract (needs an 'elements' list): {ex}")
    prov = {
        "suppliedPath": os.path.abspath(contract),
        "sha256": sha256_file(contract_path),
        "reason": str(reason).strip(),
        "sourceFetched": False,
        "changedTiles": [], "addedTiles": [], "removedTiles": [],
    }
    source_dash = None
    if source_fetch is not None:
        source_path = os.path.join(workdir, "contract.source.json")
        source_fetch(source_path)
        source_dash = load_contract(source_path)
        prov["sourceFetched"] = True
        prov.update(diff_contracts(supplied, source_dash))
    with open(os.path.join(workdir, "contract-provenance.json"), "w") as f:
        json.dump(prov, f, indent=2)
        f.write("\n")
    return contract_path, source_dash, prov


def expected_tile_lookup(dash, source_dash):
    """The name -> tile map live parity's EXPECTED side must use: the source
    fetch when one exists (a supplied contract never grades itself), else the
    working contract."""
    return tile_map(source_dash if source_dash is not None else dash)


def _read_json(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


def _prov_markdown(prov):
    lines = [SECTION_MARK, "", "## Contract supplied, not fetched", "",
             f"- Supplied contract: `{prov.get('suppliedPath')}`",
             f"- sha256: `{prov.get('sha256')}`",
             f"- Reason: {prov.get('reason')}"]
    if prov.get("sourceFetched"):
        lines.append("- Source comparison: the live source was fetched (`contract.source.json`); "
                     "live parity expected values come from the SOURCE tiles, not the supplied ones.")
        for label, key in (("Tiles changed vs source", "changedTiles"),
                           ("Tiles added (not in source)", "addedTiles"),
                           ("Tiles removed (in source only)", "removedTiles")):
            items = prov.get(key) or []
            if key == "changedTiles":
                items = [f"{t['name']} ({', '.join(t['changed'])})" for t in items]
            lines.append(f"- {label}: {', '.join(items) if items else 'none'}")
    else:
        lines.append("- Source comparison: NONE. No live source was fetched, so there was no "
                     "live source comparison of this contract.")
    return lines


def _omission_markdown(acc):
    lines = ["", "## Accepted readiness omissions", "",
             f"- Reason: {acc.get('reason')}",
             "- Fields the readiness audit could not match to converter output, accepted by the operator:"]
    lines += [f"  - `{f}`" for f in acc.get("fields") or []]
    return lines


def annotate_report(workdir):
    """Surface the supplied-contract provenance and accepted readiness
    omissions in migration-result.json (top-level keys `contract_provenance`,
    `accepted_readiness_omissions`) and MIGRATION_REPORT.md. The shared
    build-migration-report.rb is vendored and untouched; this runs after it and
    never changes the verdict. Idempotent. Returns the list of annexes added."""
    prov = _read_json(os.path.join(workdir, "contract-provenance.json"))
    readiness = _read_json(os.path.join(workdir, "lookml-readiness.json")) or {}
    acc = readiness.get("acceptedOmissions")
    added = []
    if not prov and not acc:
        return added
    rpath = os.path.join(workdir, "migration-result.json")
    doc = _read_json(rpath)
    if isinstance(doc, dict):
        if prov:
            doc["contract_provenance"] = prov
        if acc:
            doc["accepted_readiness_omissions"] = acc
        with open(rpath, "w") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
    mpath = os.path.join(workdir, "MIGRATION_REPORT.md")
    if os.path.isfile(mpath):
        text = open(mpath).read().split(SECTION_MARK)[0].rstrip("\n") + "\n"
        extra = []
        if prov:
            extra += _prov_markdown(prov)
        if acc:
            extra += ([SECTION_MARK] if not prov else []) + _omission_markdown(acc)
        with open(mpath, "w") as f:
            f.write(text + "\n" + "\n".join(extra) + "\n")
    if prov:
        added.append("contract_provenance")
    if acc:
        added.append("accepted_readiness_omissions")
    return added
