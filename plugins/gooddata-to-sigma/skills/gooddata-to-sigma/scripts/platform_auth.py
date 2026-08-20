#!/usr/bin/env python3
"""platform_auth.py — legacy GoodData *Platform* (classic "bear", /gdc) auth.

The Platform is a DIFFERENT product from GoodData Cloud / .CN (which uses a
Bearer API token against /api/v1 — see discover.py + get_token.py). The classic
Platform authenticates with the SST/TT flow:

  1. POST /gdc/account/login  {postUserLogin: {login, password, verify_level:2}}
       -> SST (SuperSecured Token) in the `X-GDC-AuthSST` response header.
  2. GET  /gdc/account/token   (header X-GDC-AuthSST: <SST>)
       -> TT (Temporary Token) in the `X-GDC-AuthTT` response header. TTs are
          short-lived (~10 min); refresh from the SST on a 401.
  3. Every subsequent /gdc call: header `X-GDC-AuthTT: <TT>`.

IMPORTANT: the Platform REJECTS any request without a `User-Agent` header, so
every call here sets one.

This is the multi-instance answer for Platform customers: ONE host + ONE user
identity can enumerate EVERY project that user can access (`--list`), because
classic "instances" are projects under a single platform domain — unlike Cloud,
where each org is a separate host+token. (See refs/gooddata-platform-api.md.)

Credentials (env):
  GOODDATA_PLATFORM_HOST      e.g. https://acme.on.gooddata.com  (or secure.gooddata.com)
  GOODDATA_PLATFORM_USER      login email               ] username/password flow
  GOODDATA_PLATFORM_PASSWORD  password                  ]
  GOODDATA_PLATFORM_SST       pre-obtained SST          ] (alternative to user/pass)
  GOODDATA_INSECURE_TLS=1     disable TLS verification (default: verified, like discover.py)

CLI:
  python3 platform_auth.py --check          # login, print profile + project count
  python3 platform_auth.py --print-token    # print a fresh TT to stdout

Status: built from GoodData Platform REST docs (SST/TT flow, /gdc/account/*),
NOT yet exercised against a live Platform org. Header/body fallbacks are defensive
precisely because the live shape must be confirmed on first run.
"""
import json, os, ssl, sys, urllib.request, urllib.error

_UA = "sigma-gooddata-migration/1.0 (+platform)"


def _ssl_context():
    """TLS trust resolution. Some GoodData trial/corp endpoints present a CA
    chain Python rejects ("CA cert does not include key usage extension") that
    curl/browsers accept. Prefer the OS trust store (truststore), then certifi,
    then the stock verified context. NEVER silently downgrades: an unverified
    context is used ONLY when GOODDATA_INSECURE_TLS=1 is explicitly set, and it
    logs loudly."""
    if os.environ.get("GOODDATA_INSECURE_TLS") == "1":
        print("WARNING: GOODDATA_INSECURE_TLS=1 — TLS verification DISABLED for "
              "gooddata (insecure)", file=sys.stderr)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    try:
        import truststore  # OS trust store; matches curl/browser reachability
        return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    except Exception:
        pass
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        pass
    return ssl.create_default_context()


_CTX = _ssl_context()


def _host():
    h = os.environ.get("GOODDATA_PLATFORM_HOST")
    if not h:
        sys.exit("GOODDATA_PLATFORM_HOST is required (e.g. https://acme.on.gooddata.com)")
    return h.rstrip("/")


class PlatformClient:
    """Thin /gdc REST client with SST/TT auth and transparent TT refresh."""

    def __init__(self):
        self.host = _host()
        self.sst = os.environ.get("GOODDATA_PLATFORM_SST")
        self.tt = None

    # --- low-level request ------------------------------------------------
    def _raw(self, method, path, body=None, headers=None):
        url = path if path.startswith("http") else self.host + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("User-Agent", _UA)          # Platform rejects requests without it
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            resp = urllib.request.urlopen(req, timeout=60, context=_CTX)
            raw = resp.read()
            payload = json.loads(raw) if raw else {}
            return resp, payload
        except urllib.error.HTTPError as e:
            raise e

    # --- auth -------------------------------------------------------------
    def _login(self):
        """Exchange user/password for an SST (verify_level 2 -> header token)."""
        if self.sst:
            return
        user = os.environ.get("GOODDATA_PLATFORM_USER")
        pw = os.environ.get("GOODDATA_PLATFORM_PASSWORD")
        if not (user and pw):
            sys.exit("Set GOODDATA_PLATFORM_USER + GOODDATA_PLATFORM_PASSWORD, or "
                     "GOODDATA_PLATFORM_SST directly.")
        body = {"postUserLogin": {"login": user, "password": pw,
                                  "remember": 0, "verify_level": 2}}
        try:
            resp, payload = self._raw("POST", "/gdc/account/login", body)
        except urllib.error.HTTPError as e:
            sys.exit(f"Platform login failed ({e.code}): "
                     f"{e.read()[:300].decode(errors='replace')}")
        # verify_level 2 returns the SST in the response header; some builds also
        # echo it in the body. Header wins.
        self.sst = (resp.headers.get("X-GDC-AuthSST")
                    or (payload.get("userLogin", {}) or {}).get("token"))
        if not self.sst:
            sys.exit("Login succeeded but no SST returned (X-GDC-AuthSST). "
                     "Confirm verify_level handling for this org.")

    def _refresh_tt(self):
        """Mint a fresh TT from the SST."""
        self._login()
        try:
            resp, payload = self._raw("GET", "/gdc/account/token",
                                      headers={"X-GDC-AuthSST": self.sst})
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                sys.exit("SST rejected while minting TT — SST expired or invalid; "
                         "re-authenticate (check user/password).")
            sys.exit(f"TT request failed ({e.code}): "
                     f"{e.read()[:300].decode(errors='replace')}")
        self.tt = (resp.headers.get("X-GDC-AuthTT")
                   or (payload.get("userLogin", {}) or {}).get("token"))
        if not self.tt:
            sys.exit("Token endpoint returned no TT (X-GDC-AuthTT).")
        return self.tt

    def token(self):
        return self.tt or self._refresh_tt()

    # --- authenticated verbs (auto-refresh TT once on 401) ----------------
    def get(self, path):
        return self._call("GET", path)

    def post(self, path, body):
        return self._call("POST", path, body)

    def _call(self, method, path, body=None):
        for attempt in (1, 2):
            tt = self.token()
            try:
                _, payload = self._raw(method, path, body,
                                       headers={"X-GDC-AuthTT": tt})
                return payload
            except urllib.error.HTTPError as e:
                if e.code == 401 and attempt == 1:
                    self.tt = None          # expired TT -> refresh and retry once
                    continue
                sys.exit(f"{method} {path} -> {e.code}: "
                         f"{e.read()[:300].decode(errors='replace')}")

    # --- convenience ------------------------------------------------------
    def profile_id(self):
        """Resolve the logged-in account's profile id via the bootstrap resource."""
        boot = self.get("/gdc/app/account/bootstrap")
        prof = (((boot.get("bootstrapResource") or {}).get("accountSetting") or {})
                .get("links") or {}).get("self", "")
        return prof.rstrip("/").split("/")[-1] if prof else None

    def projects(self):
        """List every project the logged-in user can access.

        Returns [{"id","title","uri"}]. This is the cross-'instance' sweep:
        one token, all projects.
        """
        pid = self.profile_id()
        if not pid:
            sys.exit("Could not resolve profile id from bootstrap.")
        data = self.get(f"/gdc/account/profile/{pid}/projects")
        out = []
        for entry in data.get("projects", []) or []:
            p = entry.get("project", {})
            uri = (p.get("links") or {}).get("self", "")
            out.append({
                "id": uri.rstrip("/").split("/")[-1] if uri else None,
                "title": (p.get("meta") or {}).get("title"),
                "uri": uri,
            })
        return out


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="login, print profile + project count")
    ap.add_argument("--print-token", action="store_true", help="print a fresh TT")
    a = ap.parse_args()
    c = PlatformClient()
    if a.print_token:
        print(c.token()); return
    if a.check or not (a.print_token):
        pid = c.profile_id()
        projs = c.projects()
        print(f"host    : {c.host}")
        print(f"profile : {pid}")
        print(f"projects: {len(projs)} accessible")
        for p in projs[:50]:
            print(f"  - {p['id']}  {p['title']}")
        if len(projs) > 50:
            print(f"  … +{len(projs) - 50} more")


if __name__ == "__main__":
    main()
