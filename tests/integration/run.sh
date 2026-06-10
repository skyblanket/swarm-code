#!/usr/bin/env bash
# Integration (E2E) suite — exercises the REAL built binary against a
# scripted mock LLM endpoint (tests/integration/mock_llm.py). No network,
# no API key; only python3 + curl (curl is what the runtime itself shells
# out to for SSE streaming).
#
# Every test runs with an ISOLATED $HOME (fresh temp dir) so nothing
# touches the developer's real ~/.swarm-code, and a fresh working dir so
# file tools can't scribble on the repo.
#
# Tests:
#   T1  plain prompt        — final --json line carries the mock's text
#   T2  bash round-trip     — mock asks for `echo`, binary executes it,
#                             mock's 2nd request must contain the output
#   T3  write+read          — file lands on disk, read result goes back
#   T4  hardline block      — mkfs is denied, side-effect never executes
#   T5  session journal     — journal written; a second run resumes it
#
# Exit code: 0 iff every test passes.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${BIN:-$ROOT/bin/swarm-code}"
MOCK_PY="$ROOT/tests/integration/mock_llm.py"

if [ ! -x "$BIN" ]; then
    echo "integration: binary not found at $BIN — run \`make\` first" >&2
    exit 1
fi
# Absolutize: run_swarm cds into a per-test workdir, so a relative
# BIN (e.g. make's ./bin/swarm-code) would stop resolving.
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
command -v python3 >/dev/null 2>&1 || { echo "integration: python3 required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "integration: curl required" >&2; exit 1; }

TMP="$(mktemp -d /tmp/swarm-integ.XXXXXX)"
PASS=0
FAIL=0
MOCK_PID=""

cleanup() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
    MOCK_PID=""
}
on_exit() {
    cleanup
    if [ "$FAIL" -eq 0 ]; then rm -rf "$TMP"; fi
}
trap on_exit EXIT

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1 — $2  (artifacts: $CASE)"; }

# start_mock <scenario-file> — boots mock_llm.py, sets PORT + REQLOG.
start_mock() {
    REQLOG="$CASE/requests.jsonl"
    local portfile="$CASE/port.txt"
    rm -f "$portfile"
    python3 "$MOCK_PY" --scenario "$1" --port-file "$portfile" --log "$REQLOG" &
    MOCK_PID=$!
    local i=0
    while [ $i -lt 100 ]; do
        [ -s "$portfile" ] && break
        kill -0 "$MOCK_PID" 2>/dev/null || { echo "mock died at startup" >&2; return 1; }
        sleep 0.1
        i=$((i + 1))
    done
    [ -s "$portfile" ] || { echo "mock never wrote port file" >&2; return 1; }
    PORT="$(cat "$portfile")"
}

# new_case <name> — fresh isolated dirs for one test.
new_case() {
    CASE="$TMP/$1"
    CASE_HOME="$CASE/home"
    WORK="$CASE/work"
    mkdir -p "$CASE_HOME" "$WORK"
}

# run_swarm <args...> — run the binary headless with the isolated env,
# 90s watchdog (LLM retry backoff can stack up on a broken path).
# Captures stdout/stderr into $CASE, sets RC.
run_swarm() {
    (
        cd "$WORK" || exit 97
        HOME="$CASE_HOME" \
        SWARM_CODE_ENDPOINT="http://127.0.0.1:$PORT" \
        SWARM_CODE_MODEL=test \
        SWARM_CODE_TOOL_FORMAT=native \
        SWARM_CODE_PLAN=off \
        "$BIN" "$@" </dev/null >"$CASE/stdout.txt" 2>"$CASE/stderr.txt"
    ) &
    local pid=$!
    ( sleep 90; kill -9 "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid"
    RC=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
}

# final_json — last {"status":...} line the binary printed.
final_json() { grep '"status"' "$CASE/stdout.txt" | tail -1; }

# req_has <n> <substring> — assert request #n to the mock contains the
# substring anywhere in its messages payload. Exit 0/1.
req_has() {
    python3 - "$REQLOG" "$1" "$2" <<'PYEOF'
import json, sys
path, n, needle = sys.argv[1], int(sys.argv[2]), sys.argv[3]
for line in open(path):
    r = json.loads(line)
    if r["n"] == n:
        sys.exit(0 if needle in json.dumps(r["body"].get("messages", [])) else 1)
sys.exit(1)
PYEOF
}

req_count() { wc -l <"$REQLOG" | tr -d ' '; }

# ------------------------------------------------------------
# T1 — plain prompt, final JSON line carries the scripted text
# ------------------------------------------------------------
t1() {
    new_case t1
    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [{"type": "text", "content": "INTEG_T1_MARKER done"}]}
EOF
    start_mock "$CASE/scenario.json" || { fail T1 "mock failed to start"; return; }
    run_swarm -p "say the t1 marker" --no-resume --json
    cleanup
    local out; out="$(final_json)"
    if [ "$RC" -ne 0 ]; then fail T1 "exit code $RC"
    elif ! echo "$out" | grep -q '"status":"ok"'; then fail T1 "no ok status: $out"
    elif ! echo "$out" | grep -q "INTEG_T1_MARKER"; then fail T1 "marker missing: $out"
    elif ! req_has 0 "say the t1 marker"; then fail T1 "mock never saw the prompt"
    elif [ "$(req_count)" -ne 1 ]; then fail T1 "expected 1 request, got $(req_count)"
    else pass T1; fi
}

# ------------------------------------------------------------
# T2 — bash tool round-trip: tool_call -> execute -> result -> final
# ------------------------------------------------------------
t2() {
    new_case t2
    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [
  {"type": "tool_calls", "calls": [
    {"id": "call_t2", "name": "bash",
     "arguments": {"command": "echo hello-integ-t2"}}]},
  {"type": "text", "content": "TOOL_OK_T2"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail T2 "mock failed to start"; return; }
    run_swarm -p "run the echo" --no-resume --json
    cleanup
    local out; out="$(final_json)"
    if [ "$RC" -ne 0 ]; then fail T2 "exit code $RC"
    elif ! echo "$out" | grep -q "TOOL_OK_T2"; then fail T2 "final text missing: $out"
    elif ! req_has 1 "hello-integ-t2"; then fail T2 "mock never saw the tool result"
    elif ! req_has 1 '"role": "tool"'; then fail T2 "no role:tool message in request 2"
    elif [ "$(req_count)" -ne 2 ]; then fail T2 "expected 2 requests, got $(req_count)"
    else pass T2; fi
}

# ------------------------------------------------------------
# T3 — write then read in a temp workdir
# ------------------------------------------------------------
t3() {
    new_case t3
    cat >"$CASE/scenario.json" <<EOF
{"responses": [
  {"type": "tool_calls", "calls": [
    {"id": "call_w", "name": "write",
     "arguments": {"path": "$WORK/note.txt", "content": "T3-CONTENT-ALPHA"}}]},
  {"type": "tool_calls", "calls": [
    {"id": "call_r", "name": "read",
     "arguments": {"path": "$WORK/note.txt"}}]},
  {"type": "text", "content": "RW_OK_T3"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail T3 "mock failed to start"; return; }
    run_swarm -p "write then read the note" --no-resume --json
    cleanup
    local out; out="$(final_json)"
    if [ "$RC" -ne 0 ]; then fail T3 "exit code $RC"
    elif ! echo "$out" | grep -q "RW_OK_T3"; then fail T3 "final text missing: $out"
    elif [ ! -f "$WORK/note.txt" ]; then fail T3 "write tool never created the file"
    elif ! grep -q "T3-CONTENT-ALPHA" "$WORK/note.txt"; then fail T3 "file content wrong"
    elif ! req_has 2 "T3-CONTENT-ALPHA"; then fail T3 "read result never reached the mock"
    elif [ "$(req_count)" -ne 3 ]; then fail T3 "expected 3 requests, got $(req_count)"
    else pass T3; fi
}

# ------------------------------------------------------------
# T4 — hardline block: mkfs is denied, side-effect never runs
# ------------------------------------------------------------
t4() {
    new_case t4
    local sentinel="$WORK/owned-by-mkfs"
    cat >"$CASE/scenario.json" <<EOF
{"responses": [
  {"type": "tool_calls", "calls": [
    {"id": "call_evil", "name": "bash",
     "arguments": {"command": "mkfs.ext4 /dev/null && touch $sentinel"}}]},
  {"type": "text", "content": "BLOCK_ACK_T4"}
]}
EOF
    start_mock "$CASE/scenario.json" || { fail T4 "mock failed to start"; return; }
    run_swarm -p "format the disk" --no-resume --json
    cleanup
    local out; out="$(final_json)"
    if [ -e "$sentinel" ]; then fail T4 "HARDLINE BREACH: blocked command executed"
    elif [ "$RC" -ne 0 ]; then fail T4 "exit code $RC"
    elif ! req_has 1 "permission denied"; then fail T4 "model never told the call was denied"
    elif ! echo "$out" | grep -q "BLOCK_ACK_T4"; then fail T4 "final text missing: $out"
    else pass T4; fi
}

# ------------------------------------------------------------
# T5 — session journal: written on run 1, resumed by run 2
# ------------------------------------------------------------
t5() {
    new_case t5
    local sessions="$CASE_HOME/.swarm-code/sessions"

    cat >"$CASE/scenario.json" <<'EOF'
{"responses": [{"type": "text", "content": "FIRST_RUN_DONE_T5"}]}
EOF
    start_mock "$CASE/scenario.json" || { fail T5 "mock failed to start"; return; }
    run_swarm -p "t5 first prompt" --json
    cleanup
    if [ "$RC" -ne 0 ]; then fail T5 "run 1 exit code $RC"; return; fi
    if [ ! -f "$sessions/.active" ]; then fail T5 "no .active pointer after run 1"; return; fi
    local journal; journal="$(cat "$sessions/.active")"
    if [ ! -f "$journal" ]; then fail T5 ".active points at a missing journal"; return; fi
    if ! grep -q "t5 first prompt" "$journal"; then fail T5 "journal missing the user prompt"; return; fi
    if ! grep -q "FIRST_RUN_DONE_T5" "$journal"; then fail T5 "journal missing the assistant reply"; return; fi

    # Run 2 in the SAME home, no --no-resume: must replay the journal —
    # the mock's one request must contain the run-1 conversation.
    cat >"$CASE/scenario2.json" <<'EOF'
{"responses": [{"type": "text", "content": "SECOND_RUN_DONE_T5"}]}
EOF
    start_mock "$CASE/scenario2.json" || { fail T5 "mock 2 failed to start"; return; }
    run_swarm -p "t5 second prompt" --json
    cleanup
    local out; out="$(final_json)"
    if [ "$RC" -ne 0 ]; then fail T5 "run 2 exit code $RC (resume crashed?)"
    elif ! echo "$out" | grep -q "SECOND_RUN_DONE_T5"; then fail T5 "run 2 final text missing: $out"
    elif ! req_has 0 "t5 first prompt"; then fail T5 "resumed request lacks run-1 prompt"
    elif ! req_has 0 "FIRST_RUN_DONE_T5"; then fail T5 "resumed request lacks run-1 reply"
    elif ! req_has 0 "t5 second prompt"; then fail T5 "resumed request lacks run-2 prompt"
    else pass T5; fi
}

# ------------------------------------------------------------

echo "integration: binary $BIN"
echo "integration: scratch $TMP"
t1
t2
t3
t4
t5

echo "----------------------------------------"
echo "integration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
