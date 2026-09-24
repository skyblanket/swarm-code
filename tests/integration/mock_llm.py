#!/usr/bin/env python3
"""Mock OpenAI-compatible SSE endpoint for swarm-code integration tests.

Serves scripted responses for POST /v1/chat/completions, one per request,
in order, from a scenario JSON file:

    {"responses": [
        {"type": "text", "content": "final answer"},
        {"type": "tool_calls", "calls": [
            {"id": "call_1", "name": "bash",
             "arguments": {"command": "echo hello"}}]}
    ],
     "silent": [ {"type": "text", "content": "summary"} ]}

Streaming requests ("stream": true — every agent turn) consume
"responses". Non-streaming requests (compaction's summarizer, the daemon
pulse) consume "silent" when the scenario has that key, else they share
the "responses" queue (the original behavior).

Response spec types:
  text        {"content": "..."}                   finish_reason "stop"
  tool_calls  {"calls": [{id, name, arguments}]}   finish_reason "tool_calls"
              arguments may be an object (JSON-encoded for you) or a raw
              STRING sent verbatim — e.g. a truncated '{"command": "ech'.
              Optional "content": prose streamed before the calls.
  raw         {"lines": ["data: {...}", ...]}      each line sent + "\\n\\n"
  http        {"status": 400, "body": "...", "headers": {...}}
Common keys: "finish" overrides the finish_reason (e.g. "length");
"delay_ms" / "delay" (seconds) sleep before answering, on the request's
own thread, so later requests are still served (a hung endpoint). A text
response may carry "chunk": <n> to stream its content in n-byte deltas
(real servers send many small deltas; the default is two halves).

Every request body is appended (one JSON object per line: n, kind, t, body)
to the log file, so the harness can assert exactly what the binary sent —
e.g. that a tool result message came back after a tool_calls response.
n counts per queue: stream requests 0,1,2…; silent requests 0,1,2… when
the scenario has a "silent" key.

If more requests arrive than there are scripted responses, a plain text
"MOCK-EXHAUSTED" response is served (so a looping binary terminates
instead of hanging) and the harness can detect the overrun in the log.

Usage:
    mock_llm.py --scenario s.json --port-file port.txt --log requests.jsonl

Binds 127.0.0.1 on an OS-assigned port; writes the chosen port to
--port-file once the server is listening. No deps beyond the stdlib.
"""

import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USAGE = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}


def ev(delta, finish=None, usage=None):
    e = {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
    if usage:
        e["usage"] = usage
    return e


def sse_text_events(spec):
    """Chunked OpenAI SSE frames for a plain assistant text response —
    two halves, or `chunk`-sized deltas when the spec gives one."""
    content = spec.get("content", "")
    chunk = int(spec.get("chunk") or 0)
    if chunk > 0:
        parts = [content[i:i + chunk] for i in range(0, len(content), chunk)] or [""]
    else:
        mid = max(1, len(content) // 2)
        parts = [content[:mid], content[mid:]] if len(content) > 1 else [content]
    events = [ev({"role": "assistant", "content": ""})]
    for p in parts:
        events.append(ev({"content": p}))
    events.append(ev({}, spec.get("finish", "stop"), USAGE))
    return events


def sse_tool_call_events(spec):
    """Chunked SSE frames for a tool_calls response. The first frame for
    each call carries index/id/name; the arguments JSON is split across
    two later frames to exercise the client's fragment reassembly."""
    events = []
    if spec.get("content"):
        events.append(ev({"role": "assistant", "content": spec["content"]}))
    for i, call in enumerate(spec["calls"]):
        args = call.get("arguments", {})
        args = args if isinstance(args, str) else json.dumps(args)
        mid = max(1, len(args) // 2)
        frags = [args[:mid], args[mid:]] if len(args) > 1 else [args]
        events.append(ev({
            "role": "assistant",
            "tool_calls": [{"index": i, "id": call["id"], "type": "function",
                            "function": {"name": call["name"],
                                         "arguments": ""}}]}))
        for frag in frags:
            events.append(ev({"tool_calls": [{"index": i,
                                              "function": {"arguments": frag}}]}))
    events.append(ev({}, spec.get("finish", "tool_calls"), USAGE))
    return events


class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    scenario = None
    log_path = None
    counters = {"stream": 0, "silent": 0}
    lock = threading.Lock()

    def log_message(self, fmt, *args):  # silence default stderr access log
        pass

    def send_body(self, status, ctype, payload, headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_body(404, "text/plain", b"")
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"_raw": raw}
        stream = body.get("stream") in (True, "true")
        kind = "stream" if stream else "silent"
        # Without a "silent" queue every request shares "responses" (and
        # one counter), exactly like the original mock.
        queue = kind if "silent" in self.scenario else "stream"

        with self.lock:
            n = self.counters[queue]
            self.counters[queue] += 1
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"n": n, "kind": kind, "t": time.time(),
                                    "body": body}) + "\n")

        responses = self.scenario.get(
            "silent" if queue == "silent" else "responses", [])
        spec = responses[n] if n < len(responses) else \
            {"type": "text", "content": "MOCK-EXHAUSTED"}
        if spec.get("delay_ms"):
            time.sleep(spec["delay_ms"] / 1000.0)
        if spec.get("delay"):
            time.sleep(float(spec["delay"]))
        t = spec.get("type", "text")

        if t == "http":
            self.send_body(spec.get("status", 500),
                           spec.get("ctype", "application/json"),
                           spec.get("body", "").encode(), spec.get("headers"))
            return
        if not stream:
            # Non-streaming chat.completion (compaction / pulse).
            payload = json.dumps({
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant",
                                         "content": spec.get("content", "")}}],
                "usage": USAGE}).encode()
            self.send_body(200, "application/json", payload)
            return

        if t == "raw":
            payload = b"".join(l.encode() + b"\n\n" for l in spec["lines"])
        else:
            events = sse_tool_call_events(spec) if t == "tool_calls" \
                else sse_text_events(spec)
            # Compact separators are load-bearing: the swarmrt SSE extractor
            # matches `"content":"` / `"arguments":"` with no space after the
            # colon, exactly like real OpenAI-compatible servers emit.
            payload = b""
            for e in events:
                payload += (b"data: "
                            + json.dumps(e, separators=(",", ":")).encode()
                            + b"\n\n")
            payload += b"data: [DONE]\n\n"
        self.send_body(200, "text/event-stream", payload)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--log", required=True)
    args = ap.parse_args()

    with open(args.scenario) as f:
        MockHandler.scenario = json.load(f)
    MockHandler.log_path = args.log
    open(args.log, "w").close()  # truncate

    server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
    with open(args.port_file, "w") as f:
        f.write(str(server.server_address[1]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
