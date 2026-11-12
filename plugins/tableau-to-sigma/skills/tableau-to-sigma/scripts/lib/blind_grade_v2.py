"""blind-grade/v2 rule for the Python runtime (stdlib only).

Mirrors scripts/lib/blind_grade.rb (load_catalog, validate_v2, faithful) field
for field: same constants, same result keys. test_blind_grade_v2.py proves the
two agree on shared fixtures. Only the SHIPPED catalog counts:
refs/sigma-platform-differences.json, resolved from this file's location.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

SCHEMA_V1 = "blind-grade/v1"
SCHEMA_V2 = "blind-grade/v2"
PASS_SCORE = 75
BORDERLINE = 5
GAP_SEVERITIES = ("major", "minor")
DIMENSION_KEYS = (
    "element_titles_hidden",
    "palette_match",
    "composition_match",
    "chart_shapes_match",
    "labels_legible",
    "numbers_formatted",
)
SHIPPED_CATALOG = (
    Path(__file__).resolve().parent.parent.parent / "refs" / "sigma-platform-differences.json"
)
_DATE = re.compile(r"\A\d{4}-\d{2}-\d{2}\Z")


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _insp(value: Any) -> str:
    """Ruby Object#inspect for the JSON scalars error messages quote."""
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(_insp(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{" + ", ".join(f"{_insp(k)} => {_insp(v)}" for k, v in value.items()) + "}"
    return str(value)


def _rb_class(value: Any) -> str:
    """Ruby class name of a parsed JSON value (error-text parity)."""
    if value is True:
        return "TrueClass"
    if value is False:
        return "FalseClass"
    if value is None:
        return "NilClass"
    return {int: "Integer", float: "Float", str: "String", list: "Array", dict: "Hash"}.get(type(value), type(value).__name__)


def _s(value: Any) -> str:
    return "" if value is None else str(value)


def shipped_catalog() -> dict[str, Any]:
    return load_catalog(SHIPPED_CATALOG)


def history_path_for(catalog_path: Any) -> str:
    """The catalog-history file that sits next to a catalog file."""
    text = str(catalog_path)
    return (text[: -len(".json")] if text.endswith(".json") else text) + "-history.json"


def load_catalog(path: Any, history_path: Any = None) -> dict[str, Any]:
    """-> {'ids','entries','sha256','errors','entry_hashes','history',
    'history_errors','history_path'}; sha256 is of the file bytes. The sibling
    <name>-history.json lists earlier catalogs (see catalog_compat)."""
    hist_path = str(history_path) if history_path is not None else history_path_for(path)
    p = Path(str(path))
    out = parse_catalog_bytes(p.read_bytes() if p.is_file() else None, path)
    hist = load_history(hist_path)
    out.update({"history": hist["records"], "history_errors": hist["errors"], "history_path": hist_path})
    return out


def parse_catalog_bytes(data: bytes | None, path: Any = "(catalog)") -> dict[str, Any]:
    """Mirror of BlindGrade.parse_catalog_bytes (data None = file missing)."""
    empty: dict[str, Any] = {"ids": [], "entries": [], "sha256": None, "entry_hashes": {}}
    if data is None:
        return {**empty, "errors": [f"catalog file not found: {path}"]}
    digest = hashlib.sha256(data).hexdigest()
    try:
        doc = json.loads(data)
    except ValueError as exc:
        return {**empty, "sha256": digest, "errors": [f"catalog is not valid JSON: {exc}"]}
    if not isinstance(doc, dict):
        return {**empty, "sha256": digest, "errors": ["catalog must be a JSON object"]}
    errors: list[str] = []
    if doc.get("version") != 1 or isinstance(doc.get("version"), bool):
        errors.append(f"catalog version must be 1 (got {_insp(doc.get('version'))})")
    entries = doc.get("entries")
    if not isinstance(entries, list):
        errors.append("catalog entries must be an Array")
        entries = []
    seen: set[str] = set()
    hashes: dict[str, str] = {}
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"catalog entry #{i} must be an object")
            continue
        raw_id = entry.get("id")
        # Ruby Object#to_s for the label: true -> "true" (not Python's "True").
        eid = ("true" if raw_id else "false") if isinstance(raw_id, bool) else _s(raw_id)
        label = f"#{i}" if not eid else _insp(eid)
        if not eid:
            errors.append(f"catalog entry {label}: id missing")
        if eid and not isinstance(entry.get("id"), str):
            errors.append(f"catalog entry {label}: id must be a string (got {_rb_class(entry.get('id'))})")
        if eid and eid in seen:
            errors.append(f"catalog entry {label}: duplicate id")
        if eid:
            seen.add(eid)
        if _s(entry.get("dimension")) not in DIMENSION_KEYS:
            errors.append(
                f"catalog entry {label}: dimension {_insp(entry.get('dimension'))} not one of "
                + ", ".join(DIMENSION_KEYS)
            )
        for key in ("description", "evidence"):
            if not _s(entry.get(key)).strip():
                errors.append(f"catalog entry {label}: {key} missing/empty")
        if not _DATE.match(_s(entry.get("last_verified"))):
            errors.append(
                f"catalog entry {label}: last_verified must be YYYY-MM-DD "
                f"(got {_insp(entry.get('last_verified'))})"
            )
        if "source_tools" in entry and not (
            isinstance(entry["source_tools"], list)
            and all(isinstance(t, str) for t in entry["source_tools"])
        ):
            errors.append(f"catalog entry {label}: source_tools must be an Array of strings")
        try:
            hashes[eid] = entry_hash(entry)
        except ValueError as exc:
            errors.append(f"catalog entry {label}: {exc}")
    ok = not errors
    ids = [_s(e.get("id")) for e in entries] if ok else []
    return {"ids": ids, "entries": entries, "sha256": digest,
            "entry_hashes": hashes if ok else {}, "errors": errors}


# ── catalog history (ancestor rule; mirrors BlindGrade in blind_grade.rb) ──────
HISTORY_SCHEMA = "sigma-platform-differences-history/v1"
_HEX64 = re.compile(r"\A[0-9a-f]{64}\Z")


def canonical_str(text: Any) -> str:
    out = ['"']
    for ch in str(text):
        cp = ord(ch)
        if cp == 0x22:
            out.append('\\"')
        elif cp == 0x5C:
            out.append("\\\\")
        elif 0x20 <= cp <= 0x7E:
            out.append(ch)
        elif cp > 0xFFFF:
            c = cp - 0x10000
            out.append("\\u%04x\\u%04x" % (0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF)))
        else:
            out.append("\\u%04x" % cp)
    out.append('"')
    return "".join(out)


def canonical_json(value: Any) -> str:
    """Byte-identical to BlindGrade.canonical_json (entry content hashes)."""
    if isinstance(value, dict):
        return "{" + ",".join(
            f"{canonical_str(k)}:{canonical_json(value[k])}" for k in sorted(value, key=str)
        ) + "}"
    if isinstance(value, list):
        return "[" + ",".join(canonical_json(v) for v in value) + "]"
    if isinstance(value, str):
        return canonical_str(value)
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, int):
        return str(value)
    ruby_class = {float: "Float"}.get(type(value), type(value).__name__)
    raise ValueError(
        f"unsupported value {ruby_class} in a catalog entry "
        "(strings, integers, booleans, null, arrays and objects only)"
    )


def entry_hash(entry: Any) -> str:
    return hashlib.sha256(canonical_json(entry).encode("ascii")).hexdigest()


def load_history(path: Any) -> dict[str, Any]:
    """-> {'records': {sha: {id: entry_hash}}, 'errors': [..]}; fails closed."""
    p = Path(str(path))
    if not p.is_file():
        return {"records": {}, "errors": [f"catalog history not found: {path}"]}
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except ValueError as exc:
        return {"records": {}, "errors": [f"catalog history is not valid JSON: {exc}"]}
    errors: list[str] = []
    if not (isinstance(doc, dict) and doc.get("schema") == HISTORY_SCHEMA):
        errors.append(f"catalog history schema must be {HISTORY_SCHEMA}")
    cats = doc.get("catalogs") if isinstance(doc, dict) else None
    if not isinstance(cats, list):
        errors.append("catalog history catalogs must be an Array")
        cats = []
    records: dict[str, dict[str, str]] = {}
    for i, c in enumerate(cats):
        sha = _s(c.get("sha256")) if isinstance(c, dict) else ""
        ents = c.get("entries") if isinstance(c, dict) else None
        if (
            not _HEX64.match(sha)
            or not isinstance(ents, dict)
            or any(not _s(k) or not _HEX64.match(_s(v)) for k, v in ents.items())
        ):
            errors.append(
                f"catalog history record #{i} is malformed (need {{sha256: 64-hex, entries: {{id: 64-hex}}}})"
            )
        elif sha in records:
            errors.append(f"catalog history lists {sha} twice")
        else:
            records[sha] = {_s(k): _s(v) for k, v in ents.items()}
    return {"records": records if not errors else {}, "errors": errors}


def catalog_compat(graded_sha: Any, catalog: dict[str, Any]) -> dict[str, Any]:
    """Mirror of BlindGrade.catalog_compat: current sha ok; an ancestor whose
    entries all survive unchanged ok (new_ids listed, re-grade optional);
    removed/changed entry or unknown sha refused."""
    g = _s(graded_sha).strip().lower()
    cur = _s(catalog.get("sha256"))
    base = {"graded_sha256": g, "current_sha256": cur,
            "graded_ids": list(catalog.get("ids") or []), "new_ids": []}
    if g and g == cur:
        return {**base, "ok": True, "status": "current", "error": None, "reason": None}

    def refused(why: str) -> dict[str, Any]:
        return {**base, "ok": False, "status": "refused", "graded_ids": [], "reason": why,
                "error": f"catalog_sha256 mismatch — grade stamped {_insp(graded_sha)} but the catalog on "
                         f"disk is {_insp(catalog.get('sha256'))}; {why}"}

    rec = (catalog.get("history") or {}).get(g)
    if rec is None:
        hist = Path(_s(catalog.get("history_path"))).name
        herr = list(catalog.get("history_errors") or [])
        if herr:
            why = (f"the catalog history ({hist}) is unusable ({'; '.join(herr)}), "
                   "so no earlier catalog can be accepted")
        else:
            why = (f"that sha is not an earlier catalog in {hist or 'the catalog history'} "
                   "(unknown catalog)")
        return refused(f"{why}. Re-grade against the shipped catalog")
    cur_h = catalog.get("entry_hashes") or {}
    removed = [i for i in rec if i not in cur_h]
    changed = [i for i in rec if i in cur_h and cur_h[i] != rec[i]]
    if removed or changed:
        parts = []
        def say(ids: list[str], what: str) -> str:
            one = len(ids) == 1
            return f"{'entry' if one else 'entries'} {', '.join(ids)} {'was' if one else 'were'} {what}"

        if removed:
            parts.append(say(removed, "REMOVED"))
        if changed:
            parts.append(say(changed, "CHANGED"))
        return refused(
            f"that is an earlier catalog, but since then {' and '.join(parts)} — a grade made "
            "against a retired or reworded platform difference must be re-graded against the shipped catalog"
        )
    return {**base, "ok": True, "status": "ancestor", "error": None, "reason": None, "graded_ids": list(rec),
            "new_ids": [i for i in (catalog.get("ids") or []) if i not in rec]}


def validate_v2(doc: dict[str, Any], catalog: dict[str, Any]) -> list[str]:
    """Errors for the v2-only fields of a grade doc."""
    errors: list[str] = []
    cat_ids = list(catalog.get("ids") or [])
    compat = catalog_compat(doc.get("catalog_sha256"), catalog)
    scores = doc.get("scores")
    if isinstance(scores, dict):
        for key in DIMENSION_KEYS:
            value = scores.get(key)
            if not (_is_int(value) and 0 <= value <= 10):
                errors.append(f"scores.{key} must be an integer 0..10 (got {_insp(value)})")
    else:
        errors.append(
            "scores missing — v2 needs an integer 0..10 for each of: " + ", ".join(DIMENSION_KEYS)
        )
    overall = doc.get("overall_score")
    if not (_is_int(overall) and 0 <= overall <= 100):
        errors.append(f"overall_score must be an integer 0..100 (got {_insp(overall)})")
    gaps = doc.get("gaps")
    if isinstance(gaps, list):
        for i, gap in enumerate(gaps):
            if not isinstance(gap, dict):
                errors.append(f"gaps[{i}] must be an object")
                continue
            for key in ("tile", "description"):
                if not _s(gap.get(key)).strip():
                    errors.append(f"gaps[{i}].{key} missing")
            if _s(gap.get("dimension")) not in DIMENSION_KEYS:
                errors.append(
                    f"gaps[{i}].dimension must be one of {', '.join(DIMENSION_KEYS)} "
                    f"(got {_insp(gap.get('dimension'))})"
                )
            if _s(gap.get("severity")) not in GAP_SEVERITIES:
                errors.append(f"gaps[{i}].severity must be major|minor (got {_insp(gap.get('severity'))})")
            cls = _s(gap.get("class"))
            if not cls:
                errors.append(f'gaps[{i}].class missing (need "fixable" or a catalog id)')
            elif cls != "fixable" and cls not in cat_ids:
                errors.append(
                    f"gaps[{i}] cites unknown catalog id {_insp(cls)} — a platform difference "
                    "must be a catalog entry (never invent one)"
                )
            elif cls != "fixable" and compat["status"] == "ancestor" and cls not in compat["graded_ids"]:
                errors.append(
                    f"gaps[{i}] cites catalog id {_insp(cls)}, which was added AFTER the catalog this grade "
                    f"names ({compat['graded_sha256'][:12]}…) — its grader could not have cited it; "
                    "re-grade against the shipped catalog"
                )
            elif cls != "fixable":
                entry = next(
                    (
                        e
                        for e in catalog.get("entries") or []
                        if isinstance(e, dict) and _s(e.get("id")) == cls
                    ),
                    None,
                )
                if entry and _s(gap.get("dimension")) != _s(entry.get("dimension")):
                    errors.append(
                        f"gaps[{i}] cites catalog id {_insp(cls)} (dimension {_insp(entry.get('dimension'))}) "
                        f"but the gap's dimension is {_insp(gap.get('dimension'))} — a platform "
                        "difference must sit on the dimension the catalog entry describes"
                    )
    else:
        errors.append("gaps must be an Array (use [] when there are none)")
    if not compat["ok"]:
        errors.append(compat["error"])
    return errors


def validate_dimensions(doc: dict[str, Any]) -> list[str]:
    dims = doc.get("dimensions")
    if not isinstance(dims, dict):
        return ["dimensions missing — the grade must cover: " + ", ".join(DIMENSION_KEYS)]
    missing = [
        k
        for k in DIMENSION_KEYS
        if not (isinstance(dims.get(k), dict) and _s(dims[k].get("verdict")) in ("pass", "fail"))
    ]
    if missing:
        return ["dimensions missing/invalid (need {verdict: pass|fail}): " + ", ".join(missing)]
    return []


def validate_extras(doc: dict[str, Any]) -> list[str]:
    """per_tile + verdict checks mirroring BlindGrade.load_and_validate (v2 branch)."""
    errors: list[str] = []
    pt = doc.get("per_tile")
    if (
        not isinstance(pt, list)
        or not pt
        or any(
            not isinstance(t, dict)
            or not _s(t.get("source_family"))
            or not _s(t.get("target_family"))
            for t in pt
        )
    ):
        errors.append(
            "per_tile missing/invalid — the grader must record "
            "{position, source_family, target_family} for every tile"
        )
    if "verdict" in doc and _s(doc.get("verdict")) not in ("pass", "fail"):
        errors.append(f"verdict must be pass|fail when present (got {_insp(doc.get('verdict'))})")
    return errors


def is_v2(doc: Any) -> bool:
    return isinstance(doc, dict) and doc.get("schema") == SCHEMA_V2


def faithful(docs: Any, catalog: dict[str, Any] | None = None) -> dict[str, Any]:
    """1 or 2 validated v2 docs -> the same keys as BlindGrade.faithful."""
    docs = list(docs)
    if len(docs) not in (1, 2):
        raise ValueError(f"faithful takes 1 or 2 grade docs (got {len(docs)})")
    score = sum(int(d.get("overall_score") or 0) for d in docs) / float(len(docs))
    needs_second = len(docs) == 1 and abs(score - PASS_SCORE) <= BORDERLINE
    gaps: list[dict[str, Any]] = []
    seen: set[tuple[str, ...]] = set()
    for doc in docs:
        for gap in doc.get("gaps") or []:
            ident = tuple(_s(gap.get(k)) for k in ("tile", "dimension", "description", "severity", "class"))
            if ident not in seen:
                seen.add(ident)
                gaps.append(gap)
    platform = [g for g in gaps if _s(g.get("class")) != "fixable"]
    fixable = [g for g in gaps if _s(g.get("class")) == "fixable"]
    residuals = [g for g in fixable if _s(g.get("severity")) == "minor"]
    major = [g for g in fixable if _s(g.get("severity")) == "major"]
    reasons: list[str] = []
    for dim in ("chart_shapes_match", "numbers_formatted"):
        if all(((d.get("dimensions") or {}).get(dim) or {}).get("verdict") == "pass" for d in docs):
            continue
        reasons.append(f"{dim} did not pass (a hard requirement regardless of score)")
    for gap in major:
        reasons.append(
            f"major fixable gap on {gap.get('tile')} ({gap.get('dimension')}): {gap.get('description')}"
        )
    if score < PASS_SCORE:
        reasons.append(f"score {_rb_float(score)} is below the pass bar {PASS_SCORE}")
    if needs_second:
        reasons.append(
            f"score {_rb_float(score)} is within {BORDERLINE} of {PASS_SCORE}; "
            "a second blind grader is required"
        )
    ok = not [r for r in reasons if "second blind grader" not in r]
    return {
        "faithful": ok,
        "score": score,
        "reasons": reasons,
        "needs_second": needs_second,
        "platform_differences": platform,
        "residuals": residuals,
        "fixable_major": major,
    }


def _is_minor(gap: dict[str, Any]) -> bool:
    return _s(gap.get("severity")).strip().lower() == "minor"


def v2_polish_notes(decision: dict[str, Any], artifact: str) -> list[dict[str, Any]]:
    """Minor residual gaps on a FAITHFUL grade: optional polish, not degradations."""
    if not decision["faithful"]:
        return []
    out: list[dict[str, Any]] = []
    for gap in decision["residuals"]:
        if not _is_minor(gap):
            continue
        note = {
            "item": f"{gap.get('tile')}: {gap.get('description')}",
            "dimension": _s(gap.get("dimension")),
            "source_artifact": artifact,
        }
        if note not in out:
            out.append(note)
    return out


def v2_degradations(decision: dict[str, Any], artifact: str) -> list[dict[str, Any]]:
    """The degradation entries a v2 decision owes migration-result.json.

    Single source for verify-complete.py (which writes them) and
    assert-phase6-ran.py (which requires them, matched on class+item).
    """
    out: list[dict[str, Any]] = []
    if not decision["faithful"]:
        out.append(
            {
                "class": "fidelity-residual",
                "kind": "fidelity-residual",
                "item": "visual verdict: divergent",
                "reason": "recorded source-vs-target visual gaps ship in the render",
                "source_artifact": artifact,
            }
        )
    for key in ("fixable_major", "residuals"):
        if key == "fixable_major":
            reason = (
                "major fixable gap recorded by the blind visual grade and left in the "
                "render (run is divergent)"
            )
        else:
            reason = "fixable gap recorded by the blind visual grade and left in the render"
        for gap in decision[key]:
            if key == "residuals" and decision["faithful"] and _is_minor(gap):
                continue  # minor gap on a faithful grade is a polish note
            severity = "major" if key == "fixable_major" else gap.get("severity")
            out.append(
                {
                    "class": "fidelity-residual",
                    "kind": "fidelity-residual",
                    "item": f"visual residual ({severity}): "
                    f"{gap.get('tile')}: {gap.get('description')}",
                    "reason": reason,
                    "source_artifact": artifact,
                }
            )
    return out


def _rb_float(value: float) -> str:
    """Ruby Float#to_s for the whole/half values scores take (72.0, 72.5)."""
    return repr(float(value))


SECOND_GRADE_NAME = "blind-grade-2.json"


def _load_doc(path: Path) -> tuple[Any, str | None]:
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle), None
    except (OSError, ValueError) as exc:
        return None, f"blind grade {path.name} is unreadable: {exc}"


def evaluate_grade_set(first_path: Path, catalog: dict[str, Any] | None = None) -> dict[str, Any]:
    """Validate a v2 grade (+ optional sibling blind-grade-2.json) and decide.

    -> {'v2': False} for a v1 / schema-less grade (callers keep the v1 rule), else
    {'v2': True, 'docs', 'paths', 'errors', 'decision'}. Second-grade rules match
    record-visual-check.rb: only when grade 1 alone is borderline, never the same
    file or identical bytes, both graded the same image pair; the decision uses the
    mean. Image-on-disk binding is the caller's job (it owns the expected paths).
    """
    first_path = Path(first_path)
    first, error = _load_doc(first_path)
    if error or not isinstance(first, dict):
        return {"v2": False}
    if not is_v2(first):
        return {"v2": False}
    catalog = catalog if catalog is not None else shipped_catalog()
    errors: list[str] = []
    if catalog.get("errors"):
        errors.append("shipped catalog is unusable: " + "; ".join(catalog["errors"]))
    docs: list[dict[str, Any]] = [first]
    paths: list[Path] = [first_path]
    second_path = first_path.parent / SECOND_GRADE_NAME
    has_second = second_path.is_file() and second_path.resolve() != first_path.resolve()
    if has_second:
        second, error = _load_doc(second_path)
        if error or not isinstance(second, dict):
            errors.append(error or f"blind grade {second_path.name} must be a JSON object")
        elif not is_v2(second):
            errors.append(
                f"{second_path.name} is not a {SCHEMA_V2} grade — both grades must be "
                f"{SCHEMA_V2}; mixed schemas cannot be averaged"
            )
        else:
            docs.append(second)
            paths.append(second_path)
    for doc, path in zip(docs, paths):
        problems = validate_dimensions(doc) + validate_extras(doc)
        if not catalog.get("errors"):
            problems += validate_v2(doc, catalog)
        errors.extend(f"{path.name}: {p}" for p in problems)
    if len(docs) == 2 and not errors:
        if first_path.read_bytes() == second_path.read_bytes():
            errors.append(
                f"{first_path.name} and {second_path.name} are the same grade (identical bytes) — "
                "the second grade must be an independent run of the brief by a fresh grader"
            )
        elif not faithful([docs[0]], catalog)["needs_second"]:
            errors.append(
                f"{second_path.name} given but the first grade alone is not borderline "
                f"(score {docs[0].get('overall_score')}, outside ±{BORDERLINE} of {PASS_SCORE}) — "
                "a second grade is only taken when the first is within the borderline band"
            )
        else:
            for key in ("source_sha256", "target_sha256"):
                if _s(docs[0].get(key)).lower() != _s(docs[1].get(key)).lower():
                    errors.append(
                        f"the two blind grades disagree on {key} — both graders must have "
                        "graded the SAME image pair"
                    )
    decision = None
    if not errors:
        decision = faithful(docs, catalog)
        if decision["needs_second"]:
            errors.append(
                f"second blind grader required (score within ±{BORDERLINE} of {PASS_SCORE}) — "
                f"the first grade scored {_rb_float(decision['score'])}; a pass is never recorded "
                f"on one borderline grade. Add an independent grade as {SECOND_GRADE_NAME} next to "
                "the first and re-run"
            )
    return {"v2": True, "docs": docs, "paths": paths, "errors": errors, "decision": decision}
