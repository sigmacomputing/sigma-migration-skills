#!/usr/bin/env python3
"""test-pbi-filters.py — unit test for extract-pbir.py's report-filter extraction
(_filter_signal), asserted against VERBATIM filter shapes harvested from public
PBIR/classic reports (refs/pbi-filter-spec.md; 2026-07-17 sweep). Pure, no network.
Run: python3 scripts/test-pbi-filters.py
"""
import importlib.util, json, os, sys

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("extract_pbir", os.path.join(_here, "extract-pbir.py"))
ep = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ep)

fails = 0
def ok(name, cond, got=None):
    global fails
    print(("  ok  " if cond else "FAIL  ") + name + ("" if cond else f"   got={got!r}"))
    if not cond:
        fails += 1

def sig(fixture_json, scope="visual"):
    return ep._filter_signal(json.loads(fixture_json), scope)

# Verbatim (neutral-named) fixtures from the harvest — one per real shape.
CAT_IN = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"T"}},"Property":"Unit"}},"type":"Categorical","filter":{"Version":2,"From":[{"Name":"t","Entity":"T","Type":0}],"Where":[{"Condition":{"In":{"Expressions":[{"Column":{"Expression":{"SourceRef":{"Source":"t"}},"Property":"Unit"}}],"Values":[[{"Literal":{"Value":"\'megabytes\'"}}],[{"Literal":{"Value":"\'gigabytes\'"}}]]}}}]},"howCreated":"User"}'
CAT_BOOL = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"T"}},"Property":"Flag"}},"type":"Categorical","filter":{"Version":2,"Where":[{"Condition":{"In":{"Expressions":[{"Column":{"Expression":{"SourceRef":{"Source":"t"}},"Property":"Flag"}}],"Values":[[{"Literal":{"Value":"true"}}]]}}}]},"howCreated":"User"}'
NOT_IN = '{"expression":{"Column":{"Expression":{"SourceRef":{"Entity":"T"}},"Property":"ConsGiving"}},"filter":{"Version":2,"Where":[{"Condition":{"Not":{"Expression":{"In":{"Expressions":[{"Column":{"Expression":{"SourceRef":{"Source":"c"}},"Property":"ConsGiving"}}],"Values":[[{"Literal":{"Value":"null"}}]]}}}}}]},"type":"Categorical","howCreated":0}'
INVERTED = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"T"}},"Property":"WorkLocation"}},"type":"Categorical","howCreated":"User","filter":{"Version":2,"Where":[{"Condition":{"In":{"Expressions":[{"Column":{"Expression":{"SourceRef":{"Source":"t"}},"Property":"WorkLocation"}}],"Values":[[{"Literal":{"Value":"\'HQ\'"}}]]}}}]},"objects":{"general":[{"properties":{"isInvertedSelectionMode":{"expr":{"Literal":{"Value":"true"}}}}}]}}'
FIELD_ONLY = '{"expression":{"Column":{"Expression":{"SourceRef":{"Entity":"T"}},"Property":"City"}},"type":"Categorical","howCreated":1}'
ADV_CMP = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"Inv"}},"Property":"Cost"}},"filter":{"Version":2,"Where":[{"Condition":{"Comparison":{"ComparisonKind":1,"Left":{"Column":{"Expression":{"SourceRef":{"Source":"i"}},"Property":"Cost"}},"Right":{"Literal":{"Value":"1M"}}}}}]},"type":"Advanced","howCreated":"User"}'
ADV_AND = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"Cal"}},"Property":"RelMonth"}},"type":"Advanced","filter":{"Version":2,"Where":[{"Condition":{"And":{"Left":{"Comparison":{"ComparisonKind":2,"Left":{"Column":{"Expression":{"SourceRef":{"Source":"o"}},"Property":"RelMonth"}},"Right":{"Literal":{"Value":"-18L"}}}},"Right":{"Comparison":{"ComparisonKind":4,"Left":{"Column":{"Expression":{"SourceRef":{"Source":"o"}},"Property":"RelMonth"}},"Right":{"Literal":{"Value":"0L"}}}}}}}]},"howCreated":"User"}'
ADV_CONTAINS = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"Inv"}},"Property":"Colour"}},"filter":{"Version":2,"Where":[{"Condition":{"Contains":{"Left":{"Column":{"Expression":{"SourceRef":{"Source":"i"}},"Property":"Colour"}},"Right":{"Literal":{"Value":"\'Yellow\'"}}}}}]},"type":"Advanced","howCreated":"User"}'
ADV_MEASURE = '{"field":{"Measure":{"Expression":{"SourceRef":{"Entity":"Inv"}},"Property":"SumOfQty"}},"filter":{"Version":2,"Where":[{"Condition":{"Comparison":{"ComparisonKind":3,"Left":{"Measure":{"Expression":{"SourceRef":{"Source":"i"}},"Property":"SumOfQty"}},"Right":{"Literal":{"Value":"30L"}}}}}]},"type":"Advanced"}'
RELDATE_LAST = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"Cal"}},"Property":"DateKey"}},"type":"RelativeDate","filter":{"Version":2,"Where":[{"Condition":{"Between":{"Expression":{"Column":{"Expression":{"SourceRef":{"Source":"c"}},"Property":"DateKey"}},"LowerBound":{"DateSpan":{"Expression":{"DateAdd":{"Expression":{"DateAdd":{"Expression":{"Now":{}},"Amount":1,"TimeUnit":0}},"Amount":-30,"TimeUnit":0}},"TimeUnit":0}},"UpperBound":{"DateSpan":{"Expression":{"Now":{}},"TimeUnit":0}}}}}]},"howCreated":"User"}'
RELDATE_THIS = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"Cal"}},"Property":"Date"}},"type":"RelativeDate","filter":{"Version":2,"Where":[{"Condition":{"Comparison":{"ComparisonKind":0,"Left":{"Column":{"Expression":{"SourceRef":{"Source":"c"}},"Property":"Date"}},"Right":{"DateSpan":{"Expression":{"Now":{}},"TimeUnit":1}}}}}]}}'
TOPN = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"T"}},"Property":"Street"}},"type":"TopN","filter":{"Version":2,"From":[{"Name":"subquery","Expression":{"Subquery":{"Query":{"Version":2,"From":[{"Name":"n","Entity":"T","Type":0}],"Select":[{"Column":{"Expression":{"SourceRef":{"Source":"n"}},"Property":"Street"},"Name":"field"}],"OrderBy":[{"Direction":2,"Expression":{"Measure":{"Expression":{"SourceRef":{"Source":"n"}},"Property":"Pct"}}}],"Top":10}}},"Type":2},{"Name":"n","Entity":"T","Type":0}],"Where":[{"Condition":{"In":{"Expressions":[{"Column":{"Expression":{"SourceRef":{"Source":"n"}},"Property":"Street"}}],"Table":{"SourceRef":{"Source":"subquery"}}}}}]}}'
TOPN_EMPTY = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"T"}},"Property":"ItemNo"}},"type":"TopN","howCreated":"User"}'
EXCLUDE_MULTICOL = '{"filter":{"Version":2,"Where":[{"Condition":{"Not":{"Expression":{"In":{"Expressions":[{"Column":{"Expression":{"SourceRef":{"Source":"v"}},"Property":"Channel"}},{"Column":{"Expression":{"SourceRef":{"Source":"v"}},"Property":"ChannelType"}}],"Values":[[{"Literal":{"Value":"\'N/A\'"}},{"Literal":{"Value":"null"}}]]}}}}}]},"type":"Exclude","howCreated":4}'
AUTO = '{"field":{"Column":{"Expression":{"SourceRef":{"Entity":"T"}},"Property":"X"}},"type":"Categorical","howCreated":"Auto","filter":{"Version":2,"Where":[{"Condition":{"In":{"Expressions":[{"Column":{"Expression":{"SourceRef":{"Source":"t"}},"Property":"X"}}],"Values":[[{"Literal":{"Value":"\'a\'"}}]]}}}]}}'

s = sig(CAT_IN)
ok("Categorical In -> list include with text values + target", s["type"] == "list" and s["mode"] == "include" and s["values"] == ["megabytes", "gigabytes"] and s["target"] == "T.Unit", s)
ok("bool literal decoded true (not 'true' string)", sig(CAT_BOOL)["values"] == [True], sig(CAT_BOOL))
s = sig(NOT_IN)
ok("Not(In) -> list exclude (type=Categorical, tree walked)", s["type"] == "list" and s["mode"] == "exclude", s)
ok("isInvertedSelectionMode -> list exclude", sig(INVERTED)["mode"] == "exclude", sig(INVERTED))
s = sig(FIELD_ONLY)
ok("field-only card -> predicate none (no fabricated Where)", s.get("predicate") == "none" and s["values"] == [], s)
s = sig(ADV_CMP)
ok("Advanced Comparison -> number-range, op '>'", s["type"] == "number-range" and s["condition"][0]["op"] == ">", s)
ok("Advanced And -> number-range with two bounds", len(sig(ADV_AND)["condition"]) == 2, sig(ADV_AND))
s = sig(ADV_CONTAINS)
ok("Advanced Contains -> condition contains", s["type"] == "condition" and s["op"] == "contains" and s["value"] == "Yellow", s)
ok("Advanced on Measure -> measure-filter unsupported (coverage)", sig(ADV_MEASURE).get("unsupported") == "post-aggregate", sig(ADV_MEASURE))
s = sig(RELDATE_LAST)
ok("RelativeDate Between -> date-range last N=30 day includeToday", s["type"] == "date-range" and s["window"] == {"anchor": "last", "n": 30, "unit": "day", "includeToday": True}, s)
ok("RelativeDate This -> date-range this week", sig(RELDATE_THIS)["window"]["anchor"] == "this" and sig(RELDATE_THIS)["window"]["unit"] == "week", sig(RELDATE_THIS))
s = sig(TOPN)
ok("TopN populated -> top-n n=10 desc", s["type"] == "top-n" and s["n"] == 10 and s["direction"] == "desc", s)
ok("TopN empty -> predicate none (no guessed N)", sig(TOPN_EMPTY).get("predicate") == "none", sig(TOPN_EMPTY))
ok("Exclude multi-column key -> unsupported (coverage)", sig(EXCLUDE_MULTICOL).get("unsupported") == "multi-column-key", sig(EXCLUDE_MULTICOL))
ok("Auto filter skipped (None)", sig(AUTO) is None, sig(AUTO))

print("\nALL PASS" if not fails else f"\n{fails} FAILED")
sys.exit(0 if not fails else 1)
