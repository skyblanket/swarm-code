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
#   A8  subagent guardrail  — a subagent's 8 failing reads stop the
#                             SUBAGENT (partial result + reason), never
#                             the parent's turn
#   A9  explore is read-only — an explore subagent's bash / write calls
#                             are refused (nothing executes)
#   A10 subagent max steps  — hitting the step limit returns the work so
#                             far, not just a notice
#   A11 subagent big answer — a 320KB answer reaches the parent capped
#   A12 subagent LLM hang   — a hung endpoint fails the subagent after
#                             the configured LLM timeout, with a reason
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

# tool_msg_len <req#> <tool_call_id> — byte length of that tool result
# in request #n (the parent's view of a task result).
tool_msg_len() {
    python3 - "$REQLOG" "$1" "$2" <<'PYEOF2'
import json, sys
path, n, tcid = sys.argv[1], int(sys.argv[2]), sys.argv[3]
for line in open(path):
    r = json.loads(line)
    if r["n"] == n:
        for m in r["body"].get("messages", []):
            if m.get("role") == "tool" and m.get("tool_call_id") == tcid:
                print(len(m.get("content") or "")); sys.exit(0)
print(-1)
PYEOF2
}

# ------------------------------------------------------------
# A8 — subagent failure streak halts the subagent, not the parent
# ------------------------------------------------------------
a8() {
    new_case a8
    python3 - "$CASE/scenario.json" <<'PYEOF2'
import json, sys
reads = [{"id": "r%d" % i, "name": "read", "arguments": {"path": "missing_%d.txt" % i}} for i in range(8)]
json.dump({"responses": [
    {"type": "tool_calls", "calls": [{"id": "m1", "name": "task", "arguments": {
        "description": "find config", "prompt": "locate the config file", "subagent_type": "explore"}}]},
    {"type": "tool_calls", "calls": reads},
    # Next request must be the PARENT's: the halted subagent never asks again.
    {"type": "text", "content": "A8_MAIN_FINAL"}]}, open(sys.argv[1], "w"))
PYEOF2
    start_mock "$CASE/scenario.json" || { fail A8 "mock failed to start"; return; }
    run_swarm -p "find the config" --no-resume --json
    cleanup
    local out; out="$(final_json)"
    if [ "$RC" -ne 0 ]; then fail A8 "exit code $RC: $out"
    elif grep -q "guardrail halt\]" "$CASE/stderr.txt"; then fail A8 "subagent's streak halted the PARENT turn"
    elif ! echo "$out" | grep -q '"status":"ok"'; then fail A8 "parent did not finish ok: $out"
    elif ! echo "$out" | grep -q "A8_MAIN_FINAL"; then fail A8 "halted subagent kept calling the LLM: $out"
    elif ! req_has 2 "subagent stopped: guardrail halt"; then fail A8 "parent never got the subagent's halt result"
    elif ! req_has 2 "missing_7.txt"; then fail A8 "partial result lacks the subagent's tool digest"
    else pass A8; fi
}

# ------------------------------------------------------------
# A9 — explore subagent cannot run bash or write
# ------------------------------------------------------------
a9() {
    new_case a9
    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [
  {"type": "tool_calls", "calls": [{"id": "m1", "name": "task", "arguments": {"description": "survey", "prompt": "look around read-only", "subagent_type": "explore"}}]},
  {"type": "tool_calls", "calls": [{"id": "s1", "name": "bash", "arguments": {"command": "touch EXPLORE_RAN_BASH"}}]},
  {"type": "tool_calls", "calls": [{"id": "s2", "name": "write", "arguments": {"path": "explore_wrote.txt", "content": "x"}}]},
  {"type": "text", "content": "sub done"},
  {"type": "text", "content": "A9_MAIN_DONE"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail A9 "mock failed to start"; return; }
    run_swarm -p "survey the repo" --no-resume --json
    cleanup
    if [ -e "$WORK/EXPLORE_RAN_BASH" ]; then fail A9 "explore subagent ran bash"
    elif [ -e "$WORK/explore_wrote.txt" ]; then fail A9 "explore subagent wrote a file"
    elif [ "$RC" -ne 0 ]; then fail A9 "exit code $RC"
    elif ! req_has 2 "not available to an explore (read-only) subagent"; then fail A9 "bash refusal not explained"
    elif ! req_has 3 "not available to an explore (read-only) subagent"; then fail A9 "write refusal not explained"
    elif ! final_json | grep -q "A9_MAIN_DONE"; then fail A9 "final text missing: $(final_json)"
    else pass A9; fi
}

# ------------------------------------------------------------
# A10 — max steps returns the work done so far
# ------------------------------------------------------------
a10() {
    new_case a10
    python3 - "$CASE/scenario.json" <<'PYEOF2'
import json, sys
steps = [{"type": "tool_calls", "content": "", "calls": [{"id": "g%d" % i, "name": "bash",
          "arguments": {"command": "echo FINDING_%d" % i}}]} for i in range(15)]
json.dump({"responses": [
    {"type": "tool_calls", "calls": [{"id": "m1", "name": "task", "arguments": {
        "description": "dig", "prompt": "investigate", "subagent_type": "general"}}]}]
    + steps + [{"type": "text", "content": "A10_MAIN_DONE"}]}, open(sys.argv[1], "w"))
PYEOF2
    start_mock "$CASE/scenario.json" || { fail A10 "mock failed to start"; return; }
    run_swarm -p "investigate" --no-resume --json
    cleanup
    if [ "$RC" -ne 0 ]; then fail A10 "exit code $RC"
    elif [ "$(req_count)" -ne 17 ]; then fail A10 "expected 17 requests (1 + 15 sub + 1), got $(req_count)"
    elif ! req_has 16 "15-step limit"; then fail A10 "no max-steps notice"
    elif ! req_has 16 "FINDING_14"; then fail A10 "subagent's findings discarded at max steps"
    elif ! final_json | grep -q "A10_MAIN_DONE"; then fail A10 "final text missing"
    else pass A10; fi
}

# ------------------------------------------------------------
# A11 — a huge subagent answer is capped before it reaches the parent
# ------------------------------------------------------------
a11() {
    new_case a11
    python3 - "$CASE/scenario.json" <<'PYEOF2'
import json, sys
big = "".join("finding %06d: details details details\n" % i for i in range(8000))  # ~320KB
json.dump({"responses": [
    {"type": "tool_calls", "calls": [{"id": "m1", "name": "task", "arguments": {
        "description": "dig", "prompt": "investigate", "subagent_type": "general"}}]},
    # Small deltas, like a real server (one huge delta is cut by the
    # runtime's SSE reader and would not reproduce the uncapped answer).
    {"type": "text", "content": big, "chunk": 2000},
    {"type": "text", "content": "A11_MAIN_DONE"}]}, open(sys.argv[1], "w"))
PYEOF2
    start_mock "$CASE/scenario.json" || { fail A11 "mock failed to start"; return; }
    run_swarm -p "investigate" --no-resume --json
    cleanup
    local n; n="$(tool_msg_len 2 m1)"
    if [ "$RC" -ne 0 ]; then fail A11 "exit code $RC"
    elif [ "$n" -lt 0 ]; then fail A11 "parent never received the task result"
    elif [ "$n" -gt 26000 ]; then fail A11 "subagent answer reached the parent uncapped ($n bytes)"
    elif ! req_has 2 "bytes of the subagent's answer elided"; then fail A11 "no truncation marker"
    elif ! req_has 2 "finding 000000" || ! req_has 2 "finding 007999"; then fail A11 "head/tail of the answer lost"
    else pass A11; fi
}

# ------------------------------------------------------------
# A12 — a hung LLM endpoint fails the subagent after the LLM timeout
# ------------------------------------------------------------
a12() {
    new_case a12
    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [
  {"type": "tool_calls", "calls": [{"id": "m1", "name": "task", "arguments": {"description": "dig", "prompt": "investigate", "subagent_type": "general"}}]},
  {"type": "text", "content": "never delivered", "delay": 15},
  {"type": "text", "content": "A12_MAIN_DONE"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail A12 "mock failed to start"; return; }
    SWARM_CODE_LLM_TIMEOUT_MS=3000 run_swarm -p "investigate" --no-resume --json
    cleanup
    # How long the parent was blocked: subagent request (#1) → the
    # parent's next request (#2). Must track the 3s LLM timeout, not
    # the old fixed 300s wait (nor the endpoint's 15s stall).
    local gap
    gap="$(python3 -c 'import json,sys; t={}
for l in open(sys.argv[1]):
    r=json.loads(l); t[r["n"]]=r["t"]
print(int(t[2]-t[1]) if 1 in t and 2 in t else 999)' "$REQLOG")"
    if [ "$RC" -ne 0 ]; then fail A12 "exit code $RC: $(final_json)"
    elif [ "$gap" -gt 10 ]; then fail A12 "parent blocked ${gap}s on a hung subagent LLM call"
    elif ! req_has 2 "no response from the LLM within 3s"; then fail A12 "failure reason not surfaced"
    elif ! final_json | grep -q "A12_MAIN_DONE"; then fail A12 "final text missing: $(final_json)"
    else pass A12; fi
}

agents_cases() {
    a1
    a2
    a3
    a4
    a5
    a6
    a7
    a8
    a9
    a10
    a11
    a12
}
