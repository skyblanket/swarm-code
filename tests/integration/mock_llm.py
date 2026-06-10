#!/usr/bin/env python3
"""Mock OpenAI-compatible SSE endpoint for swarm-code integration tests.

Serves scripted responses for POST /v1/chat/completions, one per request,
in order, from a scenario JSON file:

    {"responses": [
        {"type": "text", "content": "final answer"},
        {"type": "tool_calls", "calls": [
            {"id": "call_1", "name": "bash",
             "arguments": {"command": "echo hello"}}]}
    ]}

Every request body is appended (one JSON object per line) to the log file,
so the harness can assert exactly what the binary sent — e.g. that a tool
result message came back after a tool_calls response.

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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def sse_text_events(content):
    """Chunked OpenAI SSE frames for a plain assistant text response."""
    mid = max(1, len(content) // 2)
    parts = [content[:mid], content[mid:]] if len(content) > 1 else [content]
    events = [{"choices": [{"index": 0,
                            "delta": {"role": "assistant", "content": ""},
                            "finish_reason": None}]}]
    for p in parts:
        events.append({"choices": [{"index": 0, "delta": {"content": p},
                                    "finish_reason": None}]})
    events.append({"choices": [{"index": 0, "delta": {},
                                "finish_reason": "stop"}],
                   "usage": {"prompt_tokens": 10, "completion_tokens": 5,
                             "total_tokens": 15}})
    return events


def sse_tool_call_events(calls):
    """Chunked SSE frames for a tool_calls response. The first frame for
    each call carries index/id/name; the arguments JSON is split across
    two later frames to exercise the client's fragment reassembly."""
    events = []
    for i, call in enumerate(calls):
        args = json.dumps(call.get("arguments", {}))
        mid = max(1, len(args) // 2)
        frags = [args[:mid], args[mid:]] if len(args) > 1 else [args]
        events.append({"choices": [{"index": 0, "delta": {
            "role": "assistant",
            "tool_calls": [{"index": i, "id": call["id"], "type": "function",
                            "function": {"name": call["name"],
                                         "arguments": ""}}]},
            "finish_reason": None}]})
        for frag in frags:
            events.append({"choices": [{"index": 0, "delta": {
                "tool_calls": [{"index": i,
                                "function": {"arguments": frag}}]},
                "finish_reason": None}]})
    events.append({"choices": [{"index": 0, "delta": {},
                                "finish_reason": "tool_calls"}],
                   "usage": {"prompt_tokens": 10, "completion_tokens": 5,
                             "total_tokens": 15}})
    return events


class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    scenario = None
    log_path = None
    counter = [0]
    lock = threading.Lock()

    def log_message(self, fmt, *args):  # silence default stderr access log
        pass

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"_raw": raw}

        with self.lock:
            n = self.counter[0]
            self.counter[0] += 1
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"n": n, "body": body}) + "\n")

        responses = self.scenario.get("responses", [])
        if n < len(responses):
            spec = responses[n]
        else:
            spec = {"type": "text", "content": "MOCK-EXHAUSTED"}

        if spec.get("type") == "tool_calls":
            events = sse_tool_call_events(spec["calls"])
        else:
            events = sse_text_events(spec.get("content", ""))

        # Compact separators are load-bearing: the swarmrt SSE extractor
        # matches `"content":"` / `"arguments":"` with no space after the
        # colon, exactly like real OpenAI-compatible servers emit.
        payload = b""
        for ev in events:
            payload += (b"data: "
                        + json.dumps(ev, separators=(",", ":")).encode()
                        + b"\n\n")
        payload += b"data: [DONE]\n\n"

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)


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
