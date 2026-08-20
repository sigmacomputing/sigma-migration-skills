#!/usr/bin/env python3
"""Call a converter-source MCP tool over streamable HTTP.

Usage: mcp_convert.py <tool_name> <args_json_file> [out_file]
The args json file holds the tool arguments; values like {"@file": "path"}
are replaced with that file's content.

The hosted endpoint is never baked in — it is opt-in only, and only reachable
when SIGMA_MCP_CONVERTER_URL is explicitly set (no default, so no source data
can ever leave the machine without an explicit operator choice).
"""
import json
import os
import sys
import ssl
import urllib.request

try:
    import truststore
    truststore.inject_into_ssl()
    _CTX = None
except ImportError:
    # No truststore: fall back to a VERIFIED context, never unverified.
    _CTX = ssl.create_default_context()

URL = os.environ.get("SIGMA_MCP_CONVERTER_URL", "")


def post(payload, session=None):
    if not URL:
        print("FATAL: SIGMA_MCP_CONVERTER_URL is not set — no hosted converter "
              "endpoint configured (this path is opt-in only)", file=sys.stderr)
        sys.exit(1)
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    if session:
        req.add_header("mcp-session-id", session)
    resp = urllib.request.urlopen(req, timeout=300, context=_CTX) if _CTX else urllib.request.urlopen(req, timeout=300)
    sid = resp.headers.get("mcp-session-id", session)
    body = resp.read().decode()
    ctype = resp.headers.get("Content-Type", "")
    if "text/event-stream" in ctype:
        data = None
        for line in body.splitlines():
            if line.startswith("data:"):
                data = line[5:].strip()
        return (json.loads(data) if data else None), sid
    return (json.loads(body) if body.strip() else None), sid


def main():
    tool, args_file = sys.argv[1], sys.argv[2]
    out_file = sys.argv[3] if len(sys.argv) > 3 else None
    args = json.load(open(args_file))

    def resolve(v):
        if isinstance(v, dict) and "@file" in v:
            return open(v["@file"], encoding="utf-8").read()
        if isinstance(v, list):
            return [resolve(x) for x in v]
        if isinstance(v, dict):
            return {k: resolve(x) for k, x in v.items()}
        return v

    args = resolve(args)

    init, sid = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": {"protocolVersion": "2024-11-05",
                                 "capabilities": {},
                                 "clientInfo": {"name": "corpus", "version": "0"}}})
    if not sid:
        print("no session id; init response:", json.dumps(init)[:500], file=sys.stderr)
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    res, _ = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                   "params": {"name": tool, "arguments": args}}, sid)
    if res is None or "result" not in res:
        print("ERROR:", json.dumps(res)[:2000], file=sys.stderr)
        sys.exit(1)
    text = res["result"]["content"][0]["text"]
    if out_file:
        open(out_file, "w", encoding="utf-8").write(text)
        print("wrote", out_file, len(text), "bytes")
    else:
        print(text)


if __name__ == "__main__":
    main()
