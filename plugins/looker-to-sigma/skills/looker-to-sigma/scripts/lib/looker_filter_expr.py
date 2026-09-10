"""Translate the list/null subset of Looker filter expressions to Sigma.

Looker serializes tile filters as strings.  Treating every string as a literal
Sigma list value is unsafe: ``NOT NULL`` would otherwise mean “equal to the
text NOT NULL”.  This module is deliberately small and shared by workbook
generation and the offline parity oracle so both sides apply identical rules.
"""

import re


_DATE_OR_RANGE = (
    re.compile(r"^\d+\s+(second|minute|hour|day|week|month|quarter|year)s?$", re.I),
    re.compile(r"^(this|last|next|current)\s+", re.I),
    re.compile(r"^\d{4}[/-]\d{2}"),
    re.compile(r"^[><!]=?"),
    re.compile(r"^[\[(]"),
)


def _clean(token):
    return str(token).strip().strip('"').strip("'").strip()


def _sentinel(token):
    normalized = re.sub(r"\s+", " ", _clean(token)).upper()
    if normalized in {"NULL", "IS NULL"}:
        return [None]
    if normalized == "EMPTY":
        return [None, ""]
    return None


def parse_filter_expr(expr, column_id, filter_id=None):
    """Return a Sigma list filter for the supported Looker expression subset.

    Date/range/comparator expressions return ``None`` and remain on the
    builder's loud manual-review path.
    """
    raw = _clean(expr)
    if not raw or any(pattern.search(raw) for pattern in _DATE_OR_RANGE):
        return None

    normalized = re.sub(r"\s+", " ", raw).upper()
    if normalized in {"NOT NULL", "IS NOT NULL", "-NULL"}:
        mode, values = "exclude", [None]
    elif normalized in {"NOT EMPTY", "IS NOT EMPTY", "-EMPTY"}:
        mode, values = "exclude", [None, ""]
    else:
        tokens = [token for token in re.split(r"\s*,\s*", raw) if _clean(token)]
        exclude = bool(tokens) and all(_clean(token).startswith("-") for token in tokens)
        if any(_clean(token).startswith("-") for token in tokens) and not exclude:
            return None
        mode = "exclude" if exclude else "include"
        values = []
        for token in tokens:
            token = _clean(token)
            if exclude:
                token = _clean(token[1:])
            sentinel = _sentinel(token)
            if sentinel is not None:
                values.extend(sentinel)
            else:
                values.append(token)
        values = list(dict.fromkeys(values))
        if not values:
            return None

    result = {
        "columnId": column_id,
        "kind": "list",
        "mode": mode,
        "values": values,
    }
    if filter_id is not None:
        result["id"] = filter_id
    return result


def matches_filter_expr(value, expr):
    """Evaluate the supported subset for fixture/offline parity rows."""
    parsed = parse_filter_expr(expr, "_offline")
    if parsed is None:
        return None
    candidates = parsed["values"]
    matched = any(
        (candidate is None and value is None)
        or (
            candidate is not None
            and value is not None
            and str(value).casefold() == str(candidate).casefold()
        )
        for candidate in candidates
    )
    return matched if parsed["mode"] == "include" else not matched
