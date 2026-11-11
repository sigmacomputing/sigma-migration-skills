#!/usr/bin/env python3
"""test_migrate_looker_post_workbook_coderep.py — guards the workbook POST in
migrate-looker.py's main() against the workbook code-rep wrapper (the nested
`contents` envelope; `document` on the retired /spec endpoints).

migrate-looker.py POSTs the build_workbook.py-produced spec to POST
/v2/workbooks (replaces via PUT /v2/workbooks/{id}/contents). The live workbook
code-rep surface requires the nested `contents` envelope and 400s on a flat body.

migrate-looker.py's main() is a ~900-line monolithic orchestrator (this POST
depends on ~500 lines of prior CLI/discovery/build state — Looker API calls,
LookML conversion, a real dashboard fixture — so it can't be isolated into a
runnable unit offline) — source-level assertions, mirroring
tableau-to-sigma's test-workbook-target-coderep-unwrap.rb approach to the
same "can't isolate a god-function" problem, rather than a live/subprocess
run.

Usage: python3 scripts/test_migrate_looker_post_workbook_coderep.py
"""
import ast
import json
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

# Isolate the workbook-create block (the `sigma("POST", code_rep.create_path(),
# ...)` call) so we prove THIS call site builds a `contents` body, not just that
# `code_rep` is mentioned somewhere in the ~1300-line file.
post_call = 'sigma("POST", code_rep.create_path(), code_rep.create_body(wspec))'
post_idx = SRC.find(post_call)
check(post_idx >= 0, "the workbook POST goes to code_rep.create_path() with a code_rep.create_body(wspec) body")

# The replace branch must PUT /contents through the same adapter, and the
# readbacks must GET ?includeContents=true.
check('sigma("PUT", code_rep.update_path(a.update_workbook),' in SRC
      and "code_rep.update_body(wspec)" in SRC,
      "the update branch PUTs code_rep.update_path(...) with a code_rep.update_body(wspec) body")
check(len(re.findall(r'code_rep\.read_path\(', SRC)) >= 2,
      "workbook readbacks (drift guard + post-write) use code_rep.read_path(...)")

# No OTHER workbook POST call site, and no deprecated /spec workbook endpoint,
# should exist in the file -- a second, unguarded call would silently 400 while
# this test stays green.
all_post_sites = [m.start() for m in re.finditer(r'sigma\("POST",\s*code_rep\.create_path\(\)', SRC)]
check(len(all_post_sites) == 1,
      f"exactly one workbook POST call site in the file (got {len(all_post_sites)})")
check(not re.search(r"/v2/workbooks[^\"'\s]*/spec", SRC),
      "no deprecated /v2/workbooks/**/spec endpoint remains in migrate-looker.py")

# Readiness/accounting/report orchestration contract. These source-level checks
# guard ordering in the monolithic main() without live Looker/Sigma credentials.
main_src = SRC[SRC.find("def main():"):]
audit_idx = main_src.find('"audit-lookml-readiness.mjs"')
allow_idx = main_src.find("SIGMA_POSTS_ALLOWED = True")
folder_idx = main_src.find("folder = resolve_folder")
check(audit_idx >= 0, "orchestrator invokes the LookML readiness audit")
check(all(name in main_src for name in (
    "lookml-readiness.json", "lookml-field-census.json", "formula-mapping.json"
)), "readiness audit writes all three mandatory artifacts")
check(0 <= audit_idx < allow_idx < folder_idx,
      "readiness passes before Sigma POSTs are enabled or a folder can be created")
check("Sigma POST {path} refused before the LookML readiness gate passed" in SRC,
      "sigma() enforces no POST before readiness at runtime")
check("return READINESS_BLOCKED_EXIT" in main_src and
      main_src.find("return READINESS_BLOCKED_EXIT") < allow_idx,
      "blocked readiness exits distinctly without enabling POSTs")

prelim_idx = main_src.find("preliminary_accounting_rc = run_looker_accounting")
gate_idx = main_src.find("grc, _ = run(gate_cmd")
final_idx = main_src.find("final_accounting_rc = run_looker_accounting")
report_idx = main_src.find('"build-migration-report.rb"')
result_idx = main_src.rfind('print("\\n================ RESULT')
check(0 <= prelim_idx < gate_idx < final_idx < report_idx < result_idx,
      "preliminary accounting, gate, final accounting, report, RESULT are ordered")
check('"visual-similarity.json"' in SRC and '"render-health.json"' in SRC and
      '"png_health.py"' in SRC,
      "render health derives from similarity evidence or a Sigma PNG")
check("report_rc == 0" in main_src and 'report_verdict != "RED"' in main_src,
      "failed or RED completion report prevents migration success")
check("args.yes" not in SRC and "not a.yes" in SRC,
      "gap-scout gate uses parsed namespace a.yes")

# Execute the isolated destination resolver with a fake Sigma request function.
tree = ast.parse(SRC)
resolver_node = next(
    node for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "my_documents_id"
)
resolver_namespace = {"json": json}
resolver_calls = []


def fake_sigma(method, path, body=None):
    resolver_calls.append((method, path, body))
    responses = {
        "/v2/whoami": {"userId": "member-1"},
        "/v2/members/member-1": {"homeFolderId": "home-folder-id"},
    }
    return json.dumps(responses[path])


resolver_namespace["sigma"] = fake_sigma
exec(
    compile(
        ast.fix_missing_locations(
            ast.Module(body=[resolver_node], type_ignores=[])
        ),
        filename="migrate-looker.py",
        mode="exec",
    ),
    resolver_namespace,
)
check(
    resolver_namespace["my_documents_id"]() == "home-folder-id",
    "My Documents resolves from the authenticated member's homeFolderId",
)
check(
    resolver_calls == [
        ("GET", "/v2/whoami", None),
        ("GET", "/v2/members/member-1", None),
    ],
    "homeFolderId resolution avoids legacy file-list scans",
)

def fake_legacy_sigma(method, path, body=None):
    responses = {
        "/v2/whoami": {"userId": "member-1"},
        "/v2/members/member-1": {},
        "/v2/members/member-1/files": {
            "entries": [{
                "id": "my-documents-id",
                "parentId": "wrong-parent-id",
                "path": "My Documents",
            }]
        },
    }
    return json.dumps(responses[path])


resolver_namespace["sigma"] = fake_legacy_sigma
check(
    resolver_namespace["my_documents_id"]() == "my-documents-id",
    "legacy My Documents fallback returns the folder id, not parentId",
)

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
