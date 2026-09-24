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
#   A5  schedule.json shape — a wrong-shape file ({"jobs":[]}) or a job
#                             with "last_run":"yesterday" no longer
#                             crashes the interactive session; one warning
#   A6  corrupt schedule    — /schedule refuses to overwrite a damaged
#                             schedule.json (file byte-identical)
#   A7  unattended jobs     — a scheduled job's child runs with
#                             SWARM_CODE_DENY_DANGEROUS=1: `rm -rf ~/…`
#                             requested by its model is denied
#
# A5-A7 drive the binary INTERACTIVELY (the scheduler runs off main's
# heartbeat) through tests/integration/pty_run.py.
#
# Run standalone: tests/integration/run.sh (these run after T1..T10).

FAKE_MCP="$ROOT/tests/integration/fake_mcp.py"
PTY_RUN="$ROOT/tests/integration/pty_run.py"

# run_pty <script.json> — run the binary interactively in a pty with
# the isolated env; transcript → $CASE/pty.txt, "ALIVE"/"DEAD n" →
# $PTY_STATUS. 90s watchdog, like run_swarm.
run_pty() {
    PTY_STATUS="$(
        cd "$WORK" || exit 97
        HOME="$CASE_HOME" \
        SWARM_CODE_EXECUTION_CONTEXT=main \
        SWARM_CODE_ENDPOINT="http://127.0.0.1:$PORT" \
        SWARM_CODE_MODEL=test \
        SWARM_CODE_TOOL_FORMAT=native \
        SWARM_CODE_PLAN=off \
        SWARM_CODE_BIN="$BIN" \
        TERM=xterm SW_NO_TITLE=1 \
        perl -e 'alarm 90; exec @ARGV' python3 "$PTY_RUN" "$CASE/pty.txt" "$1" \
            "$BIN" --no-resume 2>"$CASE/pty.err"
    )"
}

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

# ------------------------------------------------------------
# A5 — wrong-shape schedule.json must not kill the session
# ------------------------------------------------------------
a5() {
    new_case a5
    local sched="$CASE_HOME/.swarm-code/schedule.json"
    mkdir -p "$CASE_HOME/.swarm-code"
    echo '{"responses": []}' >"$CASE/scenario.json"
    # Survive 3+ heartbeat ticks, then prove main still answers input (a
    # panicked main can leave the process itself lingering).
    cat >"$CASE/pty.json" <<'EOF'
[{"wait": 7}, {"send": "/schedules\r"},
 {"until_out": "see /help for /schedule usage", "timeout": 8}]
EOF
    start_mock "$CASE/scenario.json" || { fail A5 "mock failed to start"; return; }
    printf '%s' '{"jobs":[]}' >"$sched"
    run_pty "$CASE/pty.json"
    local s1="$PTY_STATUS"; cp "$CASE/pty.txt" "$CASE/pty1.txt"
    printf '%s' '[{"id":"1","expr":"1h","prompt":"x","last_run":"yesterday"}]' >"$sched"
    cp "$sched" "$CASE/sched2.orig"
    run_pty "$CASE/pty.json"
    local s2="$PTY_STATUS"
    cleanup
    local warns; warns="$(grep -c "schedule: " "$CASE/pty1.txt")"
    if [ "$s1" != "ALIVE" ] || grep -q "panic:" "$CASE/pty1.txt" ||
       ! grep -q "see /help for /schedule usage" "$CASE/pty1.txt"; then
        fail A5 "session crashed/unresponsive with {\"jobs\":[]} ($s1)"
    elif ! grep -q "must be a JSON array" "$CASE/pty1.txt"; then fail A5 "no warning for a non-array schedule.json"
    elif [ "$warns" -ne 1 ]; then fail A5 "warning printed $warns times, want once"
    elif [ "$s2" != "ALIVE" ] || grep -q "panic:" "$CASE/pty.txt" ||
         ! grep -q "see /help for /schedule usage" "$CASE/pty.txt"; then
        fail A5 "session crashed/unresponsive on last_run:\"yesterday\" ($s2)"
    elif ! grep -q "last_run must be a timestamp" "$CASE/pty.txt"; then fail A5 "no warning for the bad job"
    elif ! cmp -s "$sched" "$CASE/sched2.orig"; then fail A5 "tick rewrote an entry it could not validate"
    else pass A5; fi
}

# ------------------------------------------------------------
# A6 — /schedule must not replace a corrupt schedule.json
# ------------------------------------------------------------
a6() {
    new_case a6
    local sched="$CASE_HOME/.swarm-code/schedule.json"
    mkdir -p "$CASE_HOME/.swarm-code"
    printf '%s' '[{"id":"1","expr":"1d","prompt":"nightly report","last_run":0,"runs":3},{"id":"2",' >"$sched"
    cp "$sched" "$CASE/sched.orig"
    echo '{"responses": []}' >"$CASE/scenario.json"
    cat >"$CASE/pty.json" <<'EOF'
[{"wait": 4}, {"send": "/schedule \"5m\" \"new job\"\r"},
 {"until_out": "refusing to overwrite", "timeout": 8}, {"wait": 1}]
EOF
    start_mock "$CASE/scenario.json" || { fail A6 "mock failed to start"; return; }
    run_pty "$CASE/pty.json"
    cleanup
    if [ "$PTY_STATUS" != "ALIVE" ] || grep -q "panic:" "$CASE/pty.txt"; then fail A6 "session died ($PTY_STATUS)"
    elif ! cmp -s "$sched" "$CASE/sched.orig"; then fail A6 "corrupt schedule.json was overwritten: $(head -c 200 "$sched")"
    elif ! grep -q "refusing to overwrite" "$CASE/pty.txt"; then fail A6 "no clear refusal message"
    else pass A6; fi
}

# ------------------------------------------------------------
# A7 — a due job's child must not auto-approve dangerous bash
# ------------------------------------------------------------
a7() {
    new_case a7
    mkdir -p "$CASE_HOME/.swarm-code" "$CASE_HOME/victim"
    touch "$CASE_HOME/victim/keep"
    cat >"$CASE_HOME/.swarm-code/schedule.json" <<'EOF'
[{"id":"1","expr":"30s","prompt":"cleanup the victim dir","created_at":0,"last_run":0,"runs":0,"paused":false}]
EOF
    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [
  {"type": "tool_calls", "calls": [{"id": "c1", "name": "bash", "arguments": {"command": "rm -rf ~/victim && echo gone"}}]},
  {"type": "text", "content": "CRON_DONE_A7"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail A7 "mock failed to start"; return; }
    cat >"$CASE/pty.json" <<EOF
[{"until": "$CASE/requests.jsonl", "contains": "\"n\": 1", "timeout": 40}, {"wait": 3}]
EOF
    run_pty "$CASE/pty.json"
    cleanup
    if [ ! -e "$CASE_HOME/victim/keep" ]; then fail A7 "SCHEDULED JOB DELETED ~/victim (dangerous bash auto-approved)"
    elif [ "$(req_count)" -lt 2 ]; then fail A7 "scheduled job never ran ($(req_count) requests)"
    elif ! req_has 1 "permission denied"; then fail A7 "child was not told the command was denied"
    else pass A7; fi
}

agents_cases() {
    a1
    a2
    a3
    a4
    a5
    a6
    a7
}
