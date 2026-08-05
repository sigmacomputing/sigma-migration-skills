"""Shared run-each-time gap-scout ledger — Python side.

Mirrors scout_gate.rb's contract EXACTLY, including the integrity fix (issue #458).
A per-conversion JSONL ledger at <workdir>/scout-ledger.jsonl, one row per scouted
gap:
    {"gap_id": ..., "feature": ..., "status": "validated"|"escalated"|"accepted",
     "at": ..., "evidence": {...}, "sig": ...}

In the Power BI / Qlik converters the WRITER is Python (scout-validate.py appends via
record() below) while the GATE that reads it is Ruby (migrate-*.rb -> scout_gate.rb
#classify). So the two sides must agree byte-for-byte on how a row is signed, or a
genuine Python-recorded `validated` row would be rejected by the Ruby gate. That is
why the canonical serialization here is a line-for-line mirror of scout_gate.rb:

  * canonical_row -> compact JSON (no spaces), keys in the FIXED order
    gap_id/feature/status/at/evidence, matching Ruby's JSON.generate;
  * canonical_evidence -> evidence stored/signed with its keys SORTED, so the
    signature is stable across a JSON round trip (write here, read back in Ruby);
  * sign -> SHA256 over "<secret>\n<canonical_row>" with the per-conversion secret
    (.scout-ledger.key, created 0600 by the first sanctioned record).

INTEGRITY (issue #458): a `validated` status is the only one that lets a feature
migrate, so it is the one an under-pressure caller is tempted to forge by hand-
writing a bare {"status":"validated"} line. A `validated` row is honored ONLY when
it carries live-probe evidence (real Sigma workbook id + SHA-256 of the columns
readback + a probe timestamp) AND a signature that re-verifies against the per-
conversion secret. A hand-written line (no evidence, no signature) or an `escalated`
row whose status was flipped to `validated` (signature no longer matches) falls
through to the escalated bucket, so the gap-scan gate still blocks. The genuine
scout path records evidence + signature and passes unchanged.

Dependency-free (stdlib json/os/datetime/hashlib/secrets only) so it can be vendored
into any plugin's scripts/lib/ unchanged.
"""
import json
import os
import sys
import datetime
import hashlib
import secrets

LEDGER = "scout-ledger.jsonl"
# Per-conversion signing secret, written ONCE by the first sanctioned record and
# read back to verify row signatures. A hand-written ledger line carries no
# signature this secret produced, so it cannot pass as `validated`.
KEYFILE = ".scout-ledger.key"


def ledger_path(workdir):
    return os.path.join(str(workdir or ""), LEDGER)


def key_path(workdir):
    return os.path.join(str(workdir or ""), KEYFILE)


def load_or_create_key(workdir):
    """The sanctioned signing secret for this conversion. Created on first use with
    owner-only perms; a concurrent creator wins the race harmlessly (we re-read).
    None only if the workdir is unwritable — which fails safe (an unsignable
    `validated` claim is rejected)."""
    p = key_path(workdir)
    try:
        if os.path.exists(p):
            with open(p) as f:
                return f.read().strip()
        secret = secrets.token_hex(32)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, secret.encode("utf-8"))
        finally:
            os.close(fd)
        return secret
    except FileExistsError:
        try:
            with open(p) as f:
                return f.read().strip()
        except OSError:
            return None
    except OSError:
        return None


def load_key(workdir):
    """Read-only key accessor for classify — NEVER creates one. If no sanctioned
    writer ever ran (no key file), a `validated` row cannot verify -> rejected."""
    p = key_path(workdir)
    try:
        if not os.path.exists(p):
            return None
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return None


def canonical_evidence(ev):
    """Evidence is stored key-sorted so the signature is stable across JSON round
    trips. Flat string->scalar map (workbook id, response hash, probe timestamp)."""
    if not isinstance(ev, dict) or not ev:
        return None
    return {str(k): ev[k] for k in sorted(ev.keys(), key=str)}


def canonical_row(row):
    """Deterministic serialization of the row's SEMANTIC content — a byte-for-byte
    mirror of scout_gate.rb#canonical_row (compact JSON, fixed key order). `sig` is
    excluded so the same call verifies a row that already carries one."""
    obj = {
        "gap_id": str(row.get("gap_id", "")),
        "feature": str(row.get("feature", "")),
        "status": str(row.get("status", "")),
        "at": str(row.get("at", "")),
        "evidence": canonical_evidence(row.get("evidence")),
    }
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def sign(secret, row):
    return hashlib.sha256(
        (str(secret) + "\n" + canonical_row(row)).encode("utf-8")
    ).hexdigest()


def probe_evidence(ev):
    """Does this evidence object actually reference a live probe? The sanctioned
    writer records the real Sigma workbook id the validation POST created plus a
    hash of the columns-readback response. A bare/empty blob does not qualify."""
    return (
        isinstance(ev, dict)
        and str(ev.get("workbook_id", "")).strip() != ""
        and str(ev.get("response_sha256", "")).strip() != ""
    )


def validated_evidence(row, secret):
    """A ledger row counts as a genuinely VALIDATED scout result only when it is
    marked validated, carries live-probe evidence, AND its signature verifies
    against the per-conversion secret. The whole integrity check (#458)."""
    if not isinstance(row, dict) or str(row.get("status")) != "validated":
        return False
    if not probe_evidence(row.get("evidence")):
        return False
    sig = str(row.get("sig", ""))
    if sig == "" or str(secret or "") == "":
        return False
    return sig == sign(secret, row)


def record(workdir, gap_id, feature, status, evidence=None):
    """Append one scout result. Non-fatal on error (never crash a good scout).
    `evidence` (required in practice for status 'validated') is the live-probe
    record; every row is signed with the sanctioned per-conversion secret so an
    out-of-band edit is tamper-evident. Signature-compatible with scout_gate.rb."""
    if not workdir or not os.path.isdir(workdir):
        return False
    row = {
        "gap_id": str(gap_id or feature),
        "feature": str(feature),
        "status": str(status),
        "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    ev = canonical_evidence(evidence)
    if ev:
        row["evidence"] = ev
    secret = load_or_create_key(workdir)
    if secret:
        row["sig"] = sign(secret, row)
    try:
        with open(ledger_path(workdir), "a") as f:
            f.write(json.dumps(row) + "\n")
        return True
    except OSError as e:
        print("scout-ledger write failed (non-fatal): %s" % e, file=sys.stderr)
        return False


def read_ledger(workdir):
    p = ledger_path(workdir)
    if not os.path.exists(p):
        return []
    out = []
    with open(p) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def classify(workdir, gap_ids):
    """Split unhandled gap-ids into unscouted / escalated / validated buckets.
    Mirrors scout_gate.rb#classify EXACTLY: a `validated` row is honored only when
    its live-probe evidence + signature verify (#458); an unverifiable one is
    treated as unvalidated and falls through to escalated."""
    secret = load_key(workdir)
    by = {}
    for e in read_ledger(workdir):
        by.setdefault(str(e.get("gap_id")), []).append(e)
    unscouted = [g for g in gap_ids if str(g) not in by]
    rest = [g for g in gap_ids if str(g) in by]
    validated = [g for g in rest if any(validated_evidence(x, secret) for x in by[str(g)])]
    escalated = [g for g in rest if g not in validated]
    return {"unscouted": unscouted, "escalated": escalated, "validated": validated}
