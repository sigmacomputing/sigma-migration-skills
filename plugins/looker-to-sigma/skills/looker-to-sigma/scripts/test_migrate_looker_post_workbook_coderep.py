#!/usr/bin/env python3
"""test_migrate_looker_post_workbook_coderep.py — guards the workbook POST in
migrate-looker.py's main() against the workbook code-rep `document` wrapper
(live since 2026-08).

migrate-looker.py POSTs the build_workbook.py-produced flat spec to
/v2/workbooks/spec. The live workbook code-rep surface requires the nested
`document` envelope and 400s on a flat body.

migrate-looker.py's main() is a ~900-line monolithic orchestrator (this POST
depends on ~500 lines of prior CLI/discovery/build state — Looker API calls,
LookML conversion, a real dashboard fixture — so it can't be isolated into a
runnable unit offline) — source-level assertions, mirroring
tableau-to-sigma's test-workbook-target-coderep-unwrap.rb approach to the
same "can't isolate a god-function" problem, rather than a live/subprocess
run.

Usage: python3 scripts/test_migrate_looker_post_workbook_coderep.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "migrate-looker.py")).read()

FAILS = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        FAILS.append(msg)


check("import code_rep" in SRC, "migrate-looker.py imports code_rep")

# Isolate the workbook-POST block (a few lines around the `sigma("POST",
# "/v2/workbooks/spec", ...)` call) so we prove THIS call site wraps, not
# just that `code_rep` is mentioned somewhere in the ~1300-line file.
post_idx = SRC.find('sigma("POST", "/v2/workbooks/spec"')
check(post_idx >= 0, "the workbook-spec POST call is present")

if post_idx >= 0:
    window = SRC[max(0, post_idx - 400):post_idx + 80]
    wrap_m = re.search(
        r"post_body\s*=\s*code_rep\.wrap\(\s*code_rep\.document\(wspec\)\s*,\s*code_rep\.metadata\(wspec\)\s*\)",
        window)
    check(wrap_m is not None, "post_body = code_rep.wrap(code_rep.document(wspec), code_rep.metadata(wspec)) precedes the POST")
    check('sigma("POST", "/v2/workbooks/spec", post_body)' in window,
          "the POST call passes `post_body` (the wrapped spec), not the raw flat `wspec`")
    if wrap_m:
        wrap_end = max(0, post_idx - 400) + wrap_m.end()
        check(wrap_end <= post_idx, "the wrap assignment precedes the POST call (source order)")

# No OTHER (unwrapped) workbook-spec POST call site should exist in the file —
# a second, unguarded call would silently 400 while this test stays green.
all_post_sites = [m.start() for m in re.finditer(r'sigma\("POST",\s*"/v2/workbooks/spec"', SRC)]
check(len(all_post_sites) == 1,
      f"exactly one /v2/workbooks/spec POST call site in the file (got {len(all_post_sites)})")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
