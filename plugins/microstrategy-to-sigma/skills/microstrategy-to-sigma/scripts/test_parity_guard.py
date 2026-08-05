#!/usr/bin/env python3
"""Regression test for the microstrategy verify_parity empty-check guard (2026-07-10).

Before: verify_parity.py with an empty expected_parity.json ({}) left all_green
True (the compare loop is skipped) and exited 0 — an empty/placeholder workbook
passed vacuously. The guard rejects 0 expected reports BEFORE any Sigma API call.
Offline: a dummy token clears the import-time token check; the guard fires before
the network.

    python3 scripts/test_parity_guard.py
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
VP = os.path.join(HERE, "verify_parity.py")
fails = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        fails.append(msg)


with tempfile.TemporaryDirectory() as d:
    empty = os.path.join(d, "empty.json")
    json.dump({}, open(empty, "w"))
    env = dict(os.environ, SIGMA_API_TOKEN="dummy")  # clears the import-time token check
    r = subprocess.run([sys.executable, VP, "--expected", empty, "--workbook-id", "wb-x"],
                       capture_output=True, text=True, env=env)
    check(r.returncode != 0, f"empty expected_parity.json => non-zero exit (got {r.returncode})")
    check("NOT parity-clean" in (r.stdout + r.stderr), "prints the 0-reports NOT-parity-clean message")
    # guard must fire BEFORE the Sigma API call (no spec GET attempted)
    check("spec GET failed" not in (r.stdout + r.stderr), "guard fires before any Sigma API call")

print()
if fails:
    print(f"{len(fails)} FAILURE(S):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
