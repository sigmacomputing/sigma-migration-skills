#!/usr/bin/env python3
"""looker_api client hardening regression (offline, creds-free, no network).

Guards the three connectivity/TLS fixes that a real Look-8 run needed by hand:

  env override    → LOOKER_BASE_URL / LOOKERSDK_BASE_URL win over the ini base
  port self-heal  → a login against a stale legacy :19999 base that times out
                    retries once on the port-stripped 443 base and memoizes it
  verified TLS    → _ctx(verify=True) returns a REAL verified context (the
                    pre-fix bug returned None → plain OpenSSL 3.x → cert reject);
                    _ctx(verify=False) is CERT_NONE (opt-in insecure)

Run: python3 tests/test_looker_client.py   (exit 0 = pass)
"""
import os
import ssl
import sys
import tempfile
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
sys.path.insert(0, SCRIPTS)
import looker_api  # noqa: E402


def _write_ini(base_url):
    f = tempfile.NamedTemporaryFile("w", suffix=".ini", delete=False)
    f.write(f"[Looker]\nbase_url={base_url}\nclient_id=x\nclient_secret=y\nverify_ssl=True\n")
    f.close()
    looker_api.INI = f.name
    return f.name


def test_env_override():
    _write_ini("https://ini.cloud.looker.com:19999")
    for k in ("LOOKER_BASE_URL", "LOOKERSDK_BASE_URL"):
        os.environ.pop(k, None)
    base, cid, csec, verify = looker_api._cfg()
    assert base == "https://ini.cloud.looker.com:19999/api/4.0", base
    assert (cid, csec, verify) == ("x", "y", True), (cid, csec, verify)

    os.environ["LOOKER_BASE_URL"] = "https://override.cloud.looker.com"
    try:
        assert looker_api._cfg()[0] == "https://override.cloud.looker.com/api/4.0"
    finally:
        os.environ.pop("LOOKER_BASE_URL", None)

    os.environ["LOOKERSDK_BASE_URL"] = "https://sdkvar.cloud.looker.com"
    try:
        assert looker_api._cfg()[0] == "https://sdkvar.cloud.looker.com/api/4.0"
    finally:
        os.environ.pop("LOOKERSDK_BASE_URL", None)
    print("PASS test_env_override")


def test_strip_port():
    assert looker_api._strip_port("https://h.cloud.looker.com:19999/api/4.0") == \
        "https://h.cloud.looker.com/api/4.0"
    assert looker_api._strip_port("https://h.cloud.looker.com/api/4.0") is None
    print("PASS test_strip_port")


def test_port_fallback():
    _write_ini("https://demo.cloud.looker.com:19999")
    looker_api._token_cache.clear()
    looker_api._resolved_base.clear()
    for k in ("LOOKER_BASE_URL", "LOOKERSDK_BASE_URL"):
        os.environ.pop(k, None)

    orig = looker_api._do_login
    calls = []

    def fake_do_login(base, cid, csec, verify):
        calls.append(base)
        if ":19999" in base:
            raise urllib.error.URLError("timed out")
        return "TOKEN_443"

    looker_api._do_login = fake_do_login
    try:
        base, tok, verify = looker_api.login()
        assert tok == "TOKEN_443", tok
        assert base == "https://demo.cloud.looker.com/api/4.0", base
        assert calls[0] == "https://demo.cloud.looker.com:19999/api/4.0", calls
        assert calls[1] == "https://demo.cloud.looker.com/api/4.0", calls
        # a second login is served from cache via the memoized 443 base — no retry
        calls.clear()
        _, tok2, _ = looker_api.login()
        assert tok2 == "TOKEN_443"
        assert calls == [], f"expected cache hit, got {calls}"
    finally:
        looker_api._do_login = orig
        looker_api._token_cache.clear()
        looker_api._resolved_base.clear()
    print("PASS test_port_fallback")


def test_http_error_not_treated_as_connectivity():
    """A real HTTP response (e.g. 401 bad creds) must NOT trigger the 443 fallback."""
    _write_ini("https://demo.cloud.looker.com:19999")
    looker_api._token_cache.clear()
    looker_api._resolved_base.clear()
    orig = looker_api._do_login
    calls = []

    def fake_do_login(base, cid, csec, verify):
        calls.append(base)
        raise urllib.error.HTTPError(base, 401, "Unauthorized", {}, None)

    looker_api._do_login = fake_do_login
    try:
        raised = False
        try:
            looker_api.login()
        except urllib.error.HTTPError:
            raised = True
        assert raised, "HTTPError should propagate, not fall back"
        assert calls == ["https://demo.cloud.looker.com:19999/api/4.0"], calls
    finally:
        looker_api._do_login = orig
        looker_api._token_cache.clear()
        looker_api._resolved_base.clear()
    print("PASS test_http_error_not_treated_as_connectivity")


def test_ctx():
    looker_api._ctx_cache.clear()
    verified = looker_api._ctx(True)
    assert verified is not None, "verified context must not be None (the pre-fix reject bug)"
    assert isinstance(verified, ssl.SSLContext)
    assert verified.verify_mode != ssl.CERT_NONE, "verified context must actually verify"

    looker_api._ctx_cache.clear()
    insecure = looker_api._ctx(False)
    assert insecure.verify_mode == ssl.CERT_NONE
    assert insecure.check_hostname is False
    print("PASS test_ctx")


if __name__ == "__main__":
    test_env_override()
    test_strip_port()
    test_port_fallback()
    test_http_error_not_treated_as_connectivity()
    test_ctx()
    print("ALL PASS")
