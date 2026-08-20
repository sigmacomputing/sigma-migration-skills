#!/usr/bin/env python3
"""Conservative Qlik LOAD-expression to warehouse-SQL translation.

Only row-wise functions with direct SQL equivalents are accepted. Unsupported
functions return ``None`` so callers can block before posting a partial model.
"""
import re


FUNCTIONS = {
    "upper": "UPPER",
    "lower": "LOWER",
    "trim": "TRIM",
    "len": "LENGTH",
    "length": "LENGTH",
    "left": "LEFT",
    "right": "RIGHT",
    "year": "YEAR",
    "month": "MONTH",
    "day": "DAY",
    "date": "DATE",
    "floor": "FLOOR",
    "ceil": "CEIL",
    "ceiling": "CEIL",
    "round": "ROUND",
    "abs": "ABS",
    "coalesce": "COALESCE",
    "alt": "COALESCE",
}
KEYWORDS = {"and", "or", "not", "null", "true", "false"}


def split_args(text):
    parts, current, depth, quote = [], [], 0, None
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == quote:
                if index + 1 < len(text) and text[index + 1] == quote:
                    current.append(text[index + 1])
                    index += 1
                else:
                    quote = None
        elif char in "'\"":
            quote = char
            current.append(char)
        elif char == "(":
            depth += 1
            current.append(char)
        elif char == ")":
            depth -= 1
            current.append(char)
        elif char == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        index += 1
    if current or text.strip():
        parts.append("".join(current).strip())
    return parts


def outer_call(text):
    match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(", text)
    if not match:
        return None
    start = match.end() - 1
    depth, quote = 0, None
    for index in range(start, len(text)):
        char = text[index]
        if quote:
            if char == quote:
                quote = None
            continue
        if char in "'\"":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                if text[index + 1 :].strip():
                    return None
                return match.group(1), text[start + 1 : index]
    return None


def split_operators(text):
    parts, current, depth, quote = [], [], 0, None
    for char in text:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            continue
        if char in "'\"":
            quote = char
            current.append(char)
        elif char == "(":
            depth += 1
            current.append(char)
        elif char == ")":
            depth -= 1
            current.append(char)
        elif char in "+-*/&" and depth == 0:
            # Keep unary signs with their atom; every other operator separates
            # two recursively translatable operands.
            if char in "+-" and not "".join(current).strip():
                current.append(char)
            else:
                parts.append("".join(current).strip())
                parts.append(char)
                current = []
        else:
            current.append(char)
    if current:
        parts.append("".join(current).strip())
    return parts


def split_boolean(text, operator):
    """Split a top-level AND/OR without touching quoted values or nested calls."""
    parts, current, depth, quote = [], [], 0, None
    index = 0
    upper = text.upper()
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            index += 1
            continue
        if char in "'\"":
            quote = char
            current.append(char)
            index += 1
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        after = index + len(operator)
        if depth == 0 and upper.startswith(operator, index):
            before_ok = index == 0 or text[index - 1].isspace()
            after_ok = after == len(text) or text[after].isspace()
        else:
            before_ok = after_ok = False
        if before_ok and after_ok:
            parts.append("".join(current).strip())
            current = []
            index = after
            continue
        current.append(char)
        index += 1
    if current:
        parts.append("".join(current).strip())
    return parts


def sql_identifier(name, alias, column_names):
    actual = column_names.get(name.upper(), name)
    quoted = '"' + actual.replace('"', '""') + '"' if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", actual) else actual
    return f"{alias}.{quoted}" if alias else quoted


def translate_atom(text, alias, column_names):
    text = text.strip()
    if not text:
        return None
    if re.fullmatch(r"'(?:''|[^'])*'", text) or re.fullmatch(r'"(?:""|[^"])*"', text):
        return text
    if re.fullmatch(r"-?\d+(?:\.\d+)?", text):
        return text
    bracketed = re.fullmatch(r"\[([^]]+)\]", text)
    if bracketed:
        return sql_identifier(bracketed.group(1), alias, column_names)
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", text):
        return text.upper() if text.lower() in KEYWORDS else sql_identifier(text, alias, column_names)
    return None


def translate_condition(text, alias, column_names):
    text = text.strip()
    call = outer_call(text)
    if call and call[0].lower() in ("match", "wildmatch"):
        args = split_args(call[1])
        if len(args) < 2:
            return None
        subject = translate(args[0], alias, column_names)
        values = [translate(arg, alias, column_names) for arg in args[1:]]
        if subject is None or any(value is None for value in values):
            return None
        if call[0].lower() == "match":
            return f"{subject} IN ({', '.join(values)})"
        return "(" + " OR ".join(f"{subject} LIKE {value.replace('*', '%').replace('?', '_')}" for value in values) + ")"

    for operator in ("OR", "AND"):
        parts = split_boolean(text, operator)
        if len(parts) > 1:
            translated = [translate_condition(part, alias, column_names) for part in parts]
            return None if any(part is None for part in translated) else f" {operator} ".join(translated)
    comparison = re.match(r"^(.*?)\s*(>=|<=|<>|!=|=|>|<)\s*(.*?)$", text)
    if comparison:
        left = translate(comparison.group(1), alias, column_names)
        right = translate(comparison.group(3), alias, column_names)
        return None if left is None or right is None else f"{left} {comparison.group(2)} {right}"
    value = translate(text, alias, column_names)
    return f"COALESCE({value}, FALSE)" if value else None


def translate(text, alias="", column_names=None):
    column_names = {str(key).upper(): value for key, value in (column_names or {}).items()}
    text = str(text or "").strip()
    call = outer_call(text)
    if call:
        name, body = call[0].lower(), call[1]
        args = split_args(body)
        if name == "if":
            if len(args) not in (2, 3):
                return None
            condition = translate_condition(args[0], alias, column_names)
            then_value = translate(args[1], alias, column_names)
            else_value = translate(args[2], alias, column_names) if len(args) == 3 else "NULL"
            if None in (condition, then_value, else_value):
                return None
            return f"CASE WHEN {condition} THEN {then_value} ELSE {else_value} END"
        if name in ("match", "wildmatch"):
            return translate_condition(text, alias, column_names)
        sql_name = FUNCTIONS.get(name)
        if not sql_name:
            return None
        translated = [translate(arg, alias, column_names) for arg in args]
        if any(arg is None for arg in translated):
            return None
        return f"{sql_name}({', '.join(translated)})"

    atomic = translate_atom(text, alias, column_names)
    if atomic is not None:
        return atomic

    # Translate simple arithmetic/concatenation while preserving quoted strings.
    pieces = split_operators(text)
    if len(pieces) > 1:
        output = []
        for index, piece in enumerate(pieces):
            if index % 2:
                output.append("||" if piece == "&" else piece)
            else:
                atom = translate(piece, alias, column_names)
                if atom is None:
                    return None
                output.append(atom)
        return " ".join(output)
    return None


def referenced_columns(text):
    """Best-effort identifiers used by an expression, excluding functions/literals."""
    without_strings = re.sub(r"'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"", " ", str(text or ""))
    function_names = {match.group(1).upper() for match in re.finditer(r"\b([A-Za-z_]\w*)\s*\(", without_strings)}
    names = []
    for bracketed, plain in re.findall(r"\[([^]]+)\]|\b([A-Za-z_][A-Za-z0-9_$]*)\b", without_strings):
        name = bracketed or plain
        if name.upper() in function_names or name.lower() in KEYWORDS or name.upper() in {"AS"}:
            continue
        if name not in names:
            names.append(name)
    return names
