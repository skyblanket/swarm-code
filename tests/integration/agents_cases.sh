# Integration cases for the multi-agent / MCP / scheduler / persistence
# surfaces. Sourced by tests/integration/run.sh — uses its helpers
# (new_case, start_mock, run_swarm, cleanup, final_json, req_has,
# req_count, pass, fail) and its $ROOT / $BIN / $CASE* variables.
#
#   A1  MCP EOF             — a server that dies mid-call is "connection
#                             lost" (not a timeout) and the next call
#                             takes the reconnect path
#   A2  MCP id collision    — a server→client request reusing our id is
#                             answered (-32601; ping → {}) and never taken
#                             as the response
#   A3  MCP output text     — a successful result that merely CONTAINS
#                             "connection lost" / "did not respond" never
#                             touches server health (no reconnect), and
#                             headless --json stdout stays one line
#   A4  --mcp-server spec   — ping → {}, unknown tool → -32602, bad
#                             "jsonrpc" / object or null ids → -32600,
#                             notifications get no reply
#
# Run standalone: tests/integration/run.sh (these run after T1..T10).

FAKE_MCP="$ROOT/tests/integration/fake_mcp.py"

# mcp_settings <mode> — user settings.json wiring the fake MCP server
# (its stdin log lands in $CASE/mcp.log). The explicit allow keeps the
# test independent of headless permission defaults for mcp__ tools.
mcp_settings() {
    mkdir -p "$CASE_HOME/.swarm-code"
    cat >"$CASE_HOME/.swarm-code/settings.json" <<EOF
{"mcpServers": {"fake": {"command": "python3",
                         "args": ["$FAKE_MCP", "$1"],
                         "env": {"FAKE_MCP_LOG": "$CASE/mcp.log"}}},
 "permissions": {"mcp__fake__echo": "allow"}}
EOF
}

# n_inits — how many times the fake server was (re)initialised.
n_inits() {
    local n; n="$(grep -c '"method": *"initialize"' "$CASE/mcp.log" 2>/dev/null)"
    echo "${n:-0}"
}

# ------------------------------------------------------------
# A1 — server exits on tools/call: EOF is a lost connection
# ------------------------------------------------------------
a1() {
    new_case a1
    mcp_settings die_on_call
    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [
  {"type": "tool_calls", "calls": [{"id": "q1", "name": "mcp__fake__echo", "arguments": {"text": "one"}}]},
  {"type": "tool_calls", "calls": [{"id": "q2", "name": "mcp__fake__echo", "arguments": {"text": "two"}}]},
  {"type": "text", "content": "A1_DONE"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail A1 "mock failed to start"; return; }
    run_swarm -p "use the mcp tool" --no-resume --json
    cleanup
    local out; out="$(final_json)"
    if [ "$RC" -ne 0 ]; then fail A1 "exit code $RC"
    elif ! echo "$out" | grep -q "A1_DONE"; then fail A1 "final text missing: $out"
    elif ! req_has 1 "connection lost"; then fail A1 "first call not reported as connection lost"
    elif req_has 1 "did not respond"; then fail A1 "EOF misreported as a timeout"
    elif [ "$(n_inits)" -ne 2 ]; then fail A1 "expected a reconnect (2 initializes), got $(n_inits)"
    else pass A1; fi
}

# ------------------------------------------------------------
# A2 — server→client request with a colliding id + ping
# ------------------------------------------------------------
a2() {
    new_case a2
    mcp_settings collide
    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [
  {"type": "tool_calls", "calls": [{"id": "q1", "name": "mcp__fake__echo", "arguments": {"text": "one"}}]},
  {"type": "text", "content": "A2_DONE"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail A2 "mock failed to start"; return; }
    run_swarm -p "use the mcp tool" --no-resume --json
    cleanup
    local out; out="$(final_json)"
    if [ "$RC" -ne 0 ]; then fail A2 "exit code $RC"
    elif ! echo "$out" | grep -q "A2_DONE"; then fail A2 "final text missing: $out"
    elif req_has 1 "carried no result"; then fail A2 "server request taken as the response"
    elif ! req_has 1 "ECHO:one roots=-32601 ping=ok"; then fail A2 "server requests not answered per spec"
    else pass A2; fi
}

# ------------------------------------------------------------
# A3 — result text never drives health bookkeeping
# ------------------------------------------------------------
a3() {
    new_case a3
    mcp_settings ok
    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [
  {"type": "tool_calls", "calls": [{"id": "q1", "name": "mcp__fake__echo", "arguments": {"text": "log: db connection lost at 12:00"}}]},
  {"type": "tool_calls", "calls": [{"id": "q2", "name": "mcp__fake__echo", "arguments": {"text": "peer did not respond (twice)"}}]},
  {"type": "tool_calls", "calls": [{"id": "q3", "name": "mcp__fake__echo", "arguments": {"text": "again: did not respond"}}]},
  {"type": "tool_calls", "calls": [{"id": "q4", "name": "mcp__fake__echo", "arguments": {"text": "third connection lost"}}]},
  {"type": "text", "content": "A3_DONE"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail A3 "mock failed to start"; return; }
    run_swarm -p "use the mcp tool" --no-resume --json
    cleanup
    local lines; lines="$(wc -l <"$CASE/stdout.txt" | tr -d ' ')"
    if [ "$RC" -ne 0 ]; then fail A3 "exit code $RC"
    elif ! final_json | grep -q "A3_DONE"; then fail A3 "final text missing: $(final_json)"
    elif [ "$lines" -ne 1 ]; then fail A3 "stdout has $lines lines, want 1 JSON line"
    elif ! req_has 4 "ECHO:third connection lost"; then fail A3 "4th call did not succeed"
    elif req_has 4 "is not running"; then fail A3 "server marked failed by result text"
    elif [ "$(n_inits)" -ne 1 ]; then fail A3 "result text forced a reconnect ($(n_inits) initializes)"
    elif grep -q "reconnecting" "$CASE/stderr.txt"; then fail A3 "spurious reconnect notice"
    else pass A3; fi
}

# ------------------------------------------------------------
# A4 — --mcp-server envelope + method conformance (no LLM)
# ------------------------------------------------------------
a4() {
    new_case a4
    (
        cd "$WORK" || exit 97
        printf '%s\n' \
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"a4","version":"1"}}}' \
          '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
          '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
          '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}' \
          '{"jsonrpc":"1.0","id":4,"method":"ping"}' \
          '{"id":5,"method":"ping"}' \
          '{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}' \
          '{"jsonrpc":"2.0","id":"six","method":"no/such/method"}' |
            HOME="$CASE_HOME" perl -e 'alarm 20; exec @ARGV' "$BIN" --mcp-server \
            >"$CASE/stdout.txt" 2>"$CASE/stderr.txt"
    )
    RC=$?
    if [ "$RC" -ne 0 ]; then fail A4 "MCP server exit code $RC"; return; fi
    local why
    why="$(python3 - "$CASE/stdout.txt" <<'PYEOF'
import json, sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
msgs = []
for l in lines:
    try:
        msgs.append(json.loads(l))
    except ValueError:
        print("non-JSON stdout line: %r" % l[:120]); sys.exit(0)
def by_id(i):
    return [m for m in msgs if m.get("id") == i]
def code(m):
    return (m.get("error") or {}).get("code")
checks = [
    (len(msgs) == 7, "want 7 responses (notification unanswered), got %d" % len(msgs)),
    (all(m.get("jsonrpc") == "2.0" for m in msgs), "a response lacks jsonrpc 2.0"),
    (by_id(2) and by_id(2)[0].get("result") == {}, "ping must return an empty result"),
    (by_id(3) and code(by_id(3)[0]) == -32602, "unknown tool must be -32602"),
    (by_id(4) and code(by_id(4)[0]) == -32600, "jsonrpc 1.0 must be -32600"),
    (by_id(5) and code(by_id(5)[0]) == -32600, "missing jsonrpc must be -32600"),
    (len([m for m in by_id(None) if code(m) == -32600]) == 1, "object id must be -32600 with id null"),
    (not [m for m in msgs if isinstance(m.get("id"), dict)], "object id echoed back"),
    (by_id("six") and code(by_id("six")[0]) == -32601, "unknown method must be -32601"),
]
bad = [why for ok, why in checks if not ok]
print(bad[0] if bad else "")
PYEOF
)"
    if [ -n "$why" ]; then fail A4 "$why"
    else pass A4; fi
}

agents_cases() {
    a1
    a2
    a3
    a4
}
