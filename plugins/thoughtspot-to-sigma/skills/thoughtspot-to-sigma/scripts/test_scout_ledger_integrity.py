#!/usr/bin/env python3
"""test_scout_ledger_integrity.py — the gap-scan gate's ScoutGate ledger must not
trust a bare "validated" status (issue #458).

Field failure: an agent blocked from the sanctioned --force path hand-wrote a
{"status":"validated"} line into scout-ledger.jsonl for a gap it had only reasoned
about — never probed against the live Sigma API. ScoutGate.classify accepted it
and let the run proceed past the gate as if real verification had happened. This
test proves the integrity fix, mirroring the resolution-EVIDENCE (join/lod/agg
ledgers) + anchor-immutability-lock (verify-anchors W1.3) patterns:
  (i)   a genuine scout record (live-probe evidence + signature) -> validated;
  (ii)  a hand-written bare "validated" line (no evidence, no signature)
        -> NOT validated (falls to escalated -> the gate still blocks);
  (iii) an escalated row whose status is flipped to "validated" out of band
        (signature no longer matches) -> NOT validated;
  (iv)  a hand-written "validated" line with FORGED evidence but no valid
        signature -> NOT validated;
  (v)   a gap with no ledger row at all -> unscouted (unchanged);
  (vi)  the genuine record round-trips through a JSON read -> still validated.

In this converter both the ledger WRITER (scout-validate.py -> lib/scout_gate.py)
and the GATE (-> lib/scout_gate.py#classify) are Python, so a single-language
suite covers the whole chain. Deterministic + offline (no Sigma creds / network).

Usage: python3 scripts/test_scout_ledger_integrity.py
"""
import datetime
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import scout_gate

FAILS = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)
    print("  %s  %s" % ("PASS" if cond else "FAIL", msg))


def genuine_evidence():
    # The evidence shape the genuine live probe records (scout-validate: the real
    # workbook id the POST created + a hash of the columns-readback + a probe
    # timestamp). Neutral, invented ids — no field/session data.
    return {"workbook_id": "wb-abc123", "response_sha256": "a" * 64,
            "phase": "columns",
            "probed_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}


print("test_scout_ledger_integrity:")

# (i) genuine scout record -> validated ---------------------------------------
with tempfile.TemporaryDirectory() as d:
    scout_gate.record(d, "MEASURE_A", "MEASURE_A", "validated", genuine_evidence())
    b = scout_gate.classify(d, ["MEASURE_A"])
    check(b["validated"] == ["MEASURE_A"] and not b["escalated"] and not b["unscouted"],
          "(i) genuine scout record (evidence + signature) classifies as validated")
    check(os.path.exists(scout_gate.key_path(d)),
          "(i) sanctioned record stamped the per-conversion signing key")

# (ii) hand-written bare "validated" — no evidence, no signature ---------------
with tempfile.TemporaryDirectory() as d:
    with open(scout_gate.ledger_path(d), "a") as f:
        f.write(json.dumps({"gap_id": "MEASURE_B", "feature": "MEASURE_B",
                            "status": "validated",
                            "at": datetime.datetime.now(datetime.timezone.utc).isoformat()}) + "\n")
    b = scout_gate.classify(d, ["MEASURE_B"])
    check(not b["validated"] and b["escalated"] == ["MEASURE_B"],
          '(ii) hand-written bare "validated" is NOT trusted -> falls to escalated (gate blocks)')

# (iii) an escalated row's status flipped to "validated" out of band ----------
with tempfile.TemporaryDirectory() as d:
    scout_gate.record(d, "MEASURE_C", "MEASURE_C", "escalated")
    raw = open(scout_gate.ledger_path(d)).read()
    # Flip the SIGNED escalated row to validated (and bolt on plausible evidence);
    # the signature was computed over status 'escalated', so it no longer matches.
    row = json.loads(raw.splitlines()[0])
    row["status"] = "validated"
    row["evidence"] = genuine_evidence()
    open(scout_gate.ledger_path(d), "w").write(json.dumps(row) + "\n")
    b = scout_gate.classify(d, ["MEASURE_C"])
    check(not b["validated"] and b["escalated"] == ["MEASURE_C"],
          "(iii) escalated->validated status flip breaks the signature -> NOT validated")

# (iv) forged evidence but no valid signature ---------------------------------
with tempfile.TemporaryDirectory() as d:
    # A genuine record for a DIFFERENT gap creates the key file, so the tamperer
    # even has a key present — but cannot produce a matching signature for a row it
    # invents.
    scout_gate.record(d, "OTHER", "OTHER", "validated", genuine_evidence())
    with open(scout_gate.ledger_path(d), "a") as f:
        f.write(json.dumps({"gap_id": "FORGED", "feature": "FORGED", "status": "validated",
                            "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                            "evidence": genuine_evidence(), "sig": "deadbeef" * 8}) + "\n")
    b = scout_gate.classify(d, ["OTHER", "FORGED"])
    check(b["validated"] == ["OTHER"] and b["escalated"] == ["FORGED"],
          '(iv) "validated" with forged evidence + bogus signature -> NOT validated')

# (v) no ledger row at all -> unscouted (unchanged) ---------------------------
with tempfile.TemporaryDirectory() as d:
    b = scout_gate.classify(d, ["NEVER_RAN"])
    check(b["unscouted"] == ["NEVER_RAN"] and not b["validated"],
          "(v) a gap the scout never ran for stays unscouted")

# (vi) genuine record survives a JSON write->read round trip ------------------
with tempfile.TemporaryDirectory() as d:
    scout_gate.record(d, "MEASURE_D", "MEASURE_D", "validated", genuine_evidence())
    rows = [json.loads(l) for l in open(scout_gate.ledger_path(d)).read().splitlines() if l.strip()]
    reordered = [{k: r[k] for k in sorted(r.keys())} for r in rows]
    open(scout_gate.ledger_path(d), "w").write("\n".join(json.dumps(r) for r in reordered) + "\n")
    b = scout_gate.classify(d, ["MEASURE_D"])
    check(b["validated"] == ["MEASURE_D"],
          "(vi) genuine validated row survives an honest JSON re-serialization")

print()
if not FAILS:
    print('ALL PASS — a hand-written/forged "validated" cannot defeat the gap-scan gate')
    sys.exit(0)
else:
    print("%d FAILED" % len(FAILS))
    sys.exit(1)
