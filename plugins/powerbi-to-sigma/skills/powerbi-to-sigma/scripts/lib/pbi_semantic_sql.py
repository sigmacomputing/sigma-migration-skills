"""Constrained DAX context compiler. Unsupported syntax fails before publishing.

Supports scalar aggregates, arithmetic, DIVIDE, CALCULATE equality/KEEPFILTERS/
REMOVEFILTERS/USERELATIONSHIP and calendar prior-period/YTD operations. Each
measure reads its own fact grain. SQL sources use the converted model's base
elements through sigma_element, not a second copy of the source data.
"""

import re


class Unsupported(ValueError):
    pass


def ident(value):
    return '"' + value.replace('"', '""') + '"'


def literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + value.replace("'", "''") + "'"


def split_args(text):
    result, start, depth, quote, bracket = [], 0, 0, None, False
    i = 0
    while i < len(text):
        char = text[i]
        if quote:
            if char == quote:
                if i + 1 < len(text) and text[i + 1] == quote:
                    i += 1
                else:
                    quote = None
        elif bracket:
            if char == "]":
                bracket = False
        elif char in "'\"":
            quote = char
        elif char == "[":
            bracket = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            result.append(text[start:i].strip())
            start = i + 1
        i += 1
    if quote or bracket or depth:
        raise Unsupported("Unbalanced DAX expression")
    result.append(text[start:].strip())
    return result


def reference(text):
    match = re.fullmatch(
        r"(?:'((?:[^']|'')+)'|([A-Za-z_][\w ]*))?\[([^\]]+)\]", text.strip()
    )
    if not match:
        raise Unsupported("Expected DAX reference: " + text)
    return ((match[1] or match[2] or "").replace("''", "'"), match[3])


def expression(text):
    text = text.strip()
    if text.startswith("(") and text.endswith(")"):
        try:
            split_args(text[1:-1])
            return expression(text[1:-1])
        except Unsupported:
            pass
    # Split arithmetic only outside calls, quotes, and field references.
    for operators in ("+-", "*/"):
        depth, quoted, bracket, positions = 0, None, False, []
        for i, char in enumerate(text):
            if quoted:
                if char == quoted:
                    quoted = None
            elif bracket:
                if char == "]":
                    bracket = False
            elif char in "'\"":
                quoted = char
            elif char == "[":
                bracket = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            elif depth == 0 and char in operators and i > 0:
                positions.append(i)
        if positions:
            pos = positions[-1]
            return (
                "binary",
                text[pos],
                expression(text[:pos]),
                expression(text[pos + 1 :]),
            )
    call = re.fullmatch(r"([A-Za-z_][A-Za-z_0-9.]*)\s*\((.*)\)", text, re.S)
    if call:
        return ("call", call[1].upper(), split_args(call[2]))
    if re.fullmatch(r"-?\d+(?:\.\d+)?", text):
        return ("number", text)
    return ("ref", *reference(text))


class Compiler:
    def __init__(self, model, sources):
        self.tables = {t["name"]: t for t in model["tables"]}
        self.measures = {
            m["name"]: (
                "".join(m["expression"])
                if isinstance(m["expression"], list)
                else m["expression"]
            )
            for t in model["tables"]
            for m in t.get("measures", [])
        }
        self.relationships = model.get("relationships", [])
        self.sources = sources
        for relation in self.relationships:
            if (
                relation.get("toCardinality", "one") != "one"
                or relation.get("crossFilteringBehavior", "oneDirection")
                != "oneDirection"
            ):
                raise Unsupported(
                    "Only many-to-one, one-direction relationships are supported"
                )
        if model.get("roles"):
            raise Unsupported("RLS/CLS requires an explicit security review")

    def column(self, table, column):
        if table not in self.sources or column not in self.sources[table]["columns"]:
            raise Unsupported(f"Unresolved source column {table}.{column}")
        return ident(self.sources[table]["columns"][column])

    def source(self, table):
        return "sigma_element(" + literal(self.sources[table]["name"]) + ")"

    def additive(self, name, groups, seen=()):
        """Whether pivot rollups can sum these per-cell values without re-evaluation."""
        if name in seen or name not in self.measures:
            return False
        node = expression(self.measures[name])
        if node[0] == "ref":
            return self.additive(node[2], groups, (*seen, name))
        if node[0] != "call":
            return False
        _, fn, args = node
        if fn in ("SUM", "COUNTROWS"):
            return True
        if fn != "CALCULATE" or len(args) != 2:
            return False
        inner = expression(args[0])
        try:
            modifier = expression(args[1])
        except Unsupported:
            return False
        if (
            inner[0] != "ref"
            or modifier[0] != "call"
            or modifier[1] not in ("SAMEPERIODLASTYEAR", "DATEADD")
        ):
            return False
        return self.additive(inner[2], groups, (*seen, name))

    def fact(self, node, seen=()):
        if node[0] == "ref":
            name = node[2]
            if name not in self.measures or name in seen:
                raise Unsupported("Unknown or cyclic measure " + name)
            return self.fact(expression(self.measures[name]), (*seen, name))
        if node[0] == "binary":
            return self.fact(node[2], seen) | self.fact(node[3], seen)
        if node[0] == "number":
            return set()
        _, fn, args = node
        arities = {
            "SUM": (1,),
            "AVERAGE": (1,),
            "MIN": (1,),
            "MAX": (1,),
            "DISTINCTCOUNT": (1,),
            "COUNTROWS": (1,),
            "DIVIDE": (2, 3),
            "TOTALYTD": (2,),
        }
        if fn in arities and len(args) not in arities[fn]:
            raise Unsupported("Unsupported argument count for " + fn)
        if fn in ("SUM", "AVERAGE", "MIN", "MAX", "DISTINCTCOUNT"):
            return {reference(args[0])[0]}
        if fn == "COUNTROWS":
            return {args[0].strip("'")}
        if fn in ("CALCULATE", "TOTALYTD"):
            return self.fact(expression(args[0]), seen)
        if fn == "DIVIDE":
            return self.fact(expression(args[0]), seen) | self.fact(
                expression(args[1]), seen
            )
        raise Unsupported("DAX function not supported: " + fn)

    def joins(self, fact, overrides=()):
        joins, aliases = [], {fact: "f"}
        pending = [r for r in self.relationships if r.get("isActive", True)]
        for left, right in overrides:
            hit = [
                r
                for r in self.relationships
                if (
                    (r["fromTable"], r["fromColumn"]) == left
                    and (r["toTable"], r["toColumn"]) == right
                )
                or (
                    (r["fromTable"], r["fromColumn"]) == right
                    and (r["toTable"], r["toColumn"]) == left
                )
            ]
            if len(hit) != 1:
                raise Unsupported(
                    "USERELATIONSHIP does not identify one modeled relationship"
                )
            relation = hit[0]
            pending = [
                r
                for r in pending
                if (r["fromTable"], r["toTable"])
                != (relation["fromTable"], relation["toTable"])
            ] + hit
        while True:
            available = [
                r
                for r in pending
                if r["fromTable"] in aliases and r["toTable"] not in aliases
            ]
            if not available:
                break
            r = available[0]
            if (
                r.get("toCardinality", "one") != "one"
                or r.get("crossFilteringBehavior", "oneDirection") != "oneDirection"
            ):
                raise Unsupported(
                    "Only many-to-one, one-direction relationships are supported"
                )
            right = r["toTable"]
            if len([p for p in available if p["toTable"] == right]) != 1:
                raise Unsupported("Ambiguous active relationship to " + right)
            alias = "d" + str(len(aliases))
            joins.append(
                f'LEFT JOIN {self.source(right)} {alias} ON {aliases[r["fromTable"]]}.{self.column(r["fromTable"],r["fromColumn"])} = {alias}.{self.column(right,r["toColumn"])}'
            )
            aliases[right] = alias
            pending.remove(r)
        return f"{self.source(fact)} f " + " ".join(joins), aliases

    def value_ref(self, table, col, aliases):
        return aliases[table] + "." + self.column(table, col)

    def predicates(self, filters, aliases, ignored=(), groups=(), dates=None):
        output = []
        for item in filters:
            table, col = item["field"]
            if (
                table not in aliases
                or (table, col) in ignored
                or (table, "*") in ignored
                or (dates and table == dates[0])
            ):
                continue
            value = self.value_ref(table, col, aliases)
            if "control" in item:
                ctl = item["control"]
                if item.get("range"):
                    lo, hi = (
                        ("start", "end") if item["range"] == "date" else ("min", "max")
                    )
                    for suffix, op in ((lo, ">="), (hi, "<=")):
                        parameter = "{{#formula [" + ctl + "]." + suffix + "}}"
                        output.append(
                            f"({parameter} IS NULL OR {value} {op} {parameter})"
                        )
                else:
                    output.append(
                        "(COALESCE({{#formula ArrayLength(["
                        + ctl
                        + "])}},0)=0 OR "
                        + value
                        + " IN {{"
                        + ctl
                        + "}})"
                    )
            elif "values" in item:
                values = item["values"]
                nonnull = [literal(v) for v in values if v is not None]
                tests = [value + " IN (" + ",".join(nonnull) + ")"] if nonnull else []
                if None in values:
                    tests.append(value + " IS NULL")
                condition = "(" + " OR ".join(tests) + ")" if tests else "FALSE"
                if item.get("exclude") and None not in values:
                    condition = "COALESCE(" + condition + ",FALSE)"
                output.append("NOT " + condition if item.get("exclude") else condition)
            else:
                raise Unsupported("Unmodeled filter predicate")
        for i, (table, col) in enumerate(groups):
            if (
                table in aliases
                and (table, col) not in ignored
                and (table, "*") not in ignored
                and not (dates and table == dates[0])
            ):
                output.append(
                    f'EQUAL_NULL({self.value_ref(table,col,aliases)},g.{ident("g"+str(i))})'
                )
        return output

    def date_set(self, date_ref, filters, groups):
        table, col = date_ref
        alias = {table: "dt"}
        cond = self.predicates(filters, alias, groups=groups)
        return (
            f"SELECT {self.value_ref(table,col,alias)} AS day FROM {self.source(table)} dt WHERE "
            + (" AND ".join(cond) or "TRUE")
        )

    def scalar(
        self,
        node,
        filters,
        groups,
        ignored=(),
        extra=(),
        time_context=None,
        overrides=(),
        seen=(),
    ):
        if node[0] == "number":
            return node[1]
        if node[0] == "ref":
            name = node[2]
            if name not in self.measures or name in seen:
                raise Unsupported("Unknown or cyclic measure " + name)
            return self.scalar(
                expression(self.measures[name]),
                filters,
                groups,
                ignored,
                extra,
                time_context,
                overrides,
                (*seen, name),
            )
        if node[0] == "binary":
            a = self.scalar(
                node[2], filters, groups, ignored, extra, time_context, overrides, seen
            )
            b = self.scalar(
                node[3], filters, groups, ignored, extra, time_context, overrides, seen
            )
            return f"({a} {node[1]} {b})"
        _, fn, args = node
        if fn == "DIVIDE":
            a = self.scalar(
                expression(args[0]),
                filters,
                groups,
                ignored,
                extra,
                time_context,
                overrides,
                seen,
            )
            b = self.scalar(
                expression(args[1]),
                filters,
                groups,
                ignored,
                extra,
                time_context,
                overrides,
                seen,
            )
            value = f"({a} / NULLIF({b},0))"
            if len(args) == 3:
                alternative = expression(args[2])
                if alternative[0] != "number":
                    raise Unsupported(
                        "DIVIDE alternate result must be a numeric constant"
                    )
                return f"CASE WHEN {b}=0 OR {b} IS NULL THEN {alternative[1]} ELSE {value} END"
            return value
        if fn in ("CALCULATE", "TOTALYTD"):
            if extra or ignored or time_context or overrides:
                raise Unsupported(
                    "Nested CALCULATE context modifications require a reviewed translation"
                )
            new_ignored, new_extra, new_overrides = (
                list(ignored),
                list(extra),
                list(overrides),
            )
            new_time = time_context
            modifiers = args[1:] if fn == "CALCULATE" else ["DATESYTD(" + args[1] + ")"]
            if fn == "TOTALYTD" and len(args) != 2:
                raise Unsupported(
                    "Fiscal TOTALYTD requires an explicit calendar implementation"
                )
            for modifier in modifiers:
                keep = re.fullmatch(r"KEEPFILTERS\s*\((.*)\)", modifier, re.I | re.S)
                term = keep[1] if keep else modifier
                equal = re.fullmatch(
                    r'(.+?\[[^\]]+\])\s*=\s*("(?:[^"]|"")*"|-?\d+(?:\.\d+)?)',
                    term,
                    re.S,
                )
                if equal:
                    ref = reference(equal[1])
                    self.column(*ref)
                    value = (
                        equal[2][1:-1].replace('""', '"')
                        if equal[2].startswith('"')
                        else float(equal[2])
                    )
                    if not keep:
                        new_ignored.append(ref)
                        new_extra = [e for e in new_extra if e["field"] != ref]
                    new_extra.append({"field": ref, "values": [value]})
                    continue
                mod = expression(modifier)
                if mod[0] != "call":
                    raise Unsupported("CALCULATE modifier " + modifier)
                _, op, values = mod
                if op in ("REMOVEFILTERS", "ALL") and len(values) == 1:
                    target = (
                        reference(values[0])
                        if "[" in values[0]
                        else (values[0].strip("'"), "*")
                    )
                    if target[0] not in self.tables:
                        raise Unsupported("Unknown filter-removal table " + target[0])
                    if target[1] == "*" and any(
                        r["fromTable"] == target[0] and r.get("isActive", True)
                        for r in self.relationships
                    ):
                        raise Unsupported(
                            "Expanded fact-table REMOVEFILTERS requires a reviewed translation"
                        )
                    if target[1] != "*":
                        self.column(*target)
                    new_ignored.append(target)
                elif op == "USERELATIONSHIP" and len(values) == 2:
                    new_overrides.append((reference(values[0]), reference(values[1])))
                elif op in ("SAMEPERIODLASTYEAR", "DATEADD", "DATESYTD"):
                    if new_time:
                        raise Unsupported("Nested calendar shifts are not supported")
                    unit, amount = (
                        ("year", -1) if op == "SAMEPERIODLASTYEAR" else ("year", 0)
                    )
                    if op == "DATEADD":
                        if len(values) != 3 or values[2].lower() not in (
                            "year",
                            "month",
                            "quarter",
                            "day",
                        ):
                            raise Unsupported("DATEADD unit")
                        unit, amount = values[2].lower(), int(values[1])
                    elif len(values) != 1:
                        raise Unsupported("Calendar function requires one date column")
                    new_time = (reference(values[0]), op, unit, amount)
                else:
                    raise Unsupported("CALCULATE modifier function " + op)
            return self.scalar(
                expression(args[0]),
                filters,
                groups,
                tuple(new_ignored),
                tuple(new_extra),
                new_time,
                tuple(new_overrides),
                seen,
            )
        if fn not in ("SUM", "AVERAGE", "MIN", "MAX", "DISTINCTCOUNT", "COUNTROWS"):
            raise Unsupported("DAX scalar function " + fn)
        table, col = (
            (args[0].strip("'"), None) if fn == "COUNTROWS" else reference(args[0])
        )
        source, aliases = self.joins(table, overrides)
        date_ref = time_context[0] if time_context else None
        cond = self.predicates(filters, aliases, ignored, groups, date_ref)
        cond += self.predicates(extra, aliases)
        if time_context:
            (dt, dc), op, unit, amount = time_context
            if dt not in aliases:
                raise Unsupported("Calendar does not reach measure fact")
            date_groups = [(i, c) for i, (t, c) in enumerate(groups) if t == dt]
            date_aliases = {dt: "dt"}
            keys = [
                self.value_ref(dt, c, date_aliases) + " AS " + ident("g" + str(i))
                for i, c in date_groups
            ]
            predicate = " AND ".join(self.predicates(filters, date_aliases)) or "TRUE"
            selection = (
                "SELECT "
                + ",".join(keys + [self.value_ref(dt, dc, date_aliases) + " AS day"])
                + " FROM "
                + self.source(dt)
                + " dt WHERE "
                + predicate
            )
            group_names = [ident("g" + str(i)) for i, c in date_groups]
            bounds = (
                "SELECT "
                + (",".join(group_names) + "," if group_names else "")
                + "MIN(day) lo,MAX(day) hi,COUNT(*) n FROM selected"
                + (" GROUP BY " + ",".join(group_names) if group_names else "")
            )
            value = self.value_ref(dt, dc, aliases)
            mapping_cols = ["b." + n for n in group_names]
            if op == "DATESYTD":
                date_condition = "shifted.day BETWEEN DATE_TRUNC('year',b.hi) AND b.hi"
            else:
                key_match = " AND ".join(
                    "EQUAL_NULL(s." + n + ",b." + n + ")" for n in group_names
                )
                date_condition = (
                    f"shifted.day IN (SELECT DATEADD({unit},{amount},s.day) FROM selected s"
                    + (" WHERE " + key_match if key_match else "")
                    + ")"
                )
                if unit in ("month", "quarter", "year"):
                    # Full calendar periods shift to full periods, including
                    # the unequal number of days in adjacent months/years.
                    date_condition = f"CASE WHEN b.lo=DATE_TRUNC('{unit}',b.lo) AND b.hi=DATEADD(day,-1,DATEADD({unit},1,DATE_TRUNC('{unit}',b.hi))) AND b.n=DATEDIFF(day,b.lo,b.hi)+1 THEN shifted.day BETWEEN DATEADD({unit},{amount},b.lo) AND DATEADD(day,-1,DATEADD({unit},{amount+1},DATE_TRUNC('{unit}',b.hi))) ELSE {date_condition} END"
                if op == "SAMEPERIODLASTYEAR":
                    penultimate = (
                        "EXISTS (SELECT 1 FROM selected s WHERE s.day=DATEADD(day,-1,b.hi)"
                        + (" AND " + key_match if key_match else "")
                        + ")"
                    )
                    extension = f"b.hi=LAST_DAY(b.hi) AND {penultimate} AND shifted.day BETWEEN DATEADD(year,-1,b.hi) AND LAST_DAY(DATEADD(year,-1,b.hi))"
                    date_condition = "(" + date_condition + ") OR (" + extension + ")"
            mapping = (
                f"WITH selected AS ({selection}), bounds AS ({bounds}) SELECT DISTINCT "
                + ",".join(mapping_cols + ["shifted.day"])
                + f" FROM bounds b CROSS JOIN ({self.date_set((dt,dc),[],[])}) shifted WHERE "
                + date_condition
            )
            source += f" JOIN ({mapping}) tm ON {value}=tm.day"
            cond += ["EQUAL_NULL(tm." + n + ",g." + n + ")" for n in group_names]
        aggregate = (
            "COUNT(*)"
            if col is None
            else f'{ {"AVERAGE":"AVG","DISTINCTCOUNT":"COUNT"}.get(fn,fn)}('
            + ("DISTINCT " if fn == "DISTINCTCOUNT" else "")
            + self.value_ref(table, col, aliases)
            + ")"
        )
        if fn == "COUNTROWS":
            aggregate = "NULLIF(COUNT(*),0)"
        return (
            f"(SELECT {aggregate} FROM {source} WHERE "
            + (" AND ".join(cond) or "TRUE")
            + ")"
        )

    def query(self, groups, measures, filters):
        for table, col in [*groups, *(f["field"] for f in filters)]:
            self.column(table, col)
        nodes = [expression("[" + m + "]") for m in measures]
        facts = set().union(*(self.fact(n) for n in nodes))
        contexts = []
        for fact in sorted(facts):
            source, aliases = self.joins(fact)
            if any(table not in aliases for table, _ in groups):
                raise Unsupported("Grouping does not reach every fact in visual")
            keys = [
                self.value_ref(t, c, aliases) + " AS " + ident("g" + str(i))
                for i, (t, c) in enumerate(groups)
            ]
            conditions = self.predicates(filters, aliases)
            contexts.append(
                "SELECT DISTINCT "
                + ",".join(keys or ["1 AS singleton"])
                + " FROM "
                + source
                + " WHERE "
                + (" AND ".join(conditions) or "TRUE")
            )
        if not groups:
            contexts = ["SELECT 1 AS singleton"]
        columns = ["g." + ident("g" + str(i)) for i in range(len(groups))]
        columns += [
            self.scalar(n, filters, groups) + " AS " + ident("v" + str(i))
            for i, n in enumerate(nodes)
        ]
        return (
            "WITH context AS ("
            + " UNION ".join(contexts)
            + ") SELECT "
            + ",\n".join(columns)
            + " FROM context g"
        )
