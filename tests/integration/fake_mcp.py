#!/usr/bin/env python3
"""Scripted stdio MCP server for swarm-code's MCP-client integration tests.

    fake_mcp.py <mode>

Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout and exposes one tool,
`echo` ({"text": str} -> "ECHO:<text>"). Every line received is appended to
$FAKE_MCP_LOG (prefixed "IN "), so a test can count handshakes (one
"initialize" per (re)connect) and inspect the client's replies.

Modes:
  ok           well-behaved server
  die_on_call  exits as soon as a tools/call arrives (connection lost mid-call)
  collide      before answering tools/call <id>, sends the client a
               server->client request that REUSES <id> (roots/list) plus a
               ping, and waits (<=5s) for the client's replies; the tool
               result then reports what came back:
                 "ECHO:<text> roots=<error code|missing> ping=<ok|bad|missing>"
"""
import json
import os
import select
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "ok"
log = open(os.environ.get("FAKE_MCP_LOG", "/dev/null"), "a")


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


_buf = b""


def read_line(timeout=None):
    """One line from fd 0 via select+os.read — sys.stdin's own buffering
    would hide already-read lines from select(). None on timeout / EOF."""
    global _buf
    while b"\n" not in _buf:
        r, _, _ = select.select([0], [], [], timeout)
        if not r:
            return None
        chunk = os.read(0, 65536)
        if not chunk:
            return None
        _buf += chunk
    line, _buf = _buf.split(b"\n", 1)
    text = line.decode("utf-8", "replace") + "\n"
    log.write("IN " + text)
    log.flush()
    return text


def collect_replies(want_ids, timeout=5.0):
    """Read client lines until every id in want_ids got a reply."""
    got = {}
    while len(got) < len(want_ids):
        line = read_line(timeout)
        if not line:
            break
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if isinstance(m, dict) and "method" not in m and m.get("id") in want_ids:
            got[m["id"]] = m
    return got


while True:
    line = read_line()
    if not line:
        break
    try:
        m = json.loads(line)
    except ValueError:
        continue
    mid = m.get("id")
    meth = m.get("method")
    if meth == "initialize":
        out({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
            "serverInfo": {"name": "fake", "version": "1"}}})
    elif meth == "tools/list":
        out({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{
            "name": "echo", "description": "echo text",
            "inputSchema": {"type": "object",
                            "properties": {"text": {"type": "string"}}}}]}})
    elif meth == "tools/call":
        text = str(m.get("params", {}).get("arguments", {}).get("text"))
        if mode == "die_on_call":
            sys.exit(0)
        suffix = ""
        if mode == "collide":
            out({"jsonrpc": "2.0", "id": mid, "method": "roots/list"})
            out({"jsonrpc": "2.0", "id": "srv-ping-1", "method": "ping"})
            got = collect_replies([mid, "srv-ping-1"])
            roots = got.get(mid)
            ping = got.get("srv-ping-1")
            roots_s = str(roots["error"].get("code")) if roots and "error" in roots else "missing"
            ping_s = "missing" if ping is None else ("ok" if ping.get("result") == {} else "bad")
            suffix = " roots=%s ping=%s" % (roots_s, ping_s)
        out({"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": "ECHO:" + text + suffix}]}})
