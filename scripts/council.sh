#!/usr/bin/env bash
# Experimental repository-aware fusion panel for swarm-code.
#
# Runs three bounded, read-only panel agents in parallel, then asks a
# no-tools judge to synthesize consensus, contradictions, blind spots,
# and a final recommendation.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${SWARM_CODE_BIN:-$ROOT/bin/swarm-code}"
PROMPT="$*"
PANEL_TIMEOUT="${SWARM_COUNCIL_PANEL_TIMEOUT:-90}"
JUDGE_TIMEOUT="${SWARM_COUNCIL_JUDGE_TIMEOUT:-90}"
MAX_OUTPUT="${SWARM_COUNCIL_MAX_OUTPUT_TOKENS:-4096}"
PROFILES_CSV="${SWARM_COUNCIL_PROFILES:-kimi,kimi,kimi}"
JUDGE_PROFILE="${SWARM_COUNCIL_JUDGE_PROFILE:-kimi}"

if [ -z "$PROMPT" ]; then
    echo "usage: scripts/council.sh <question>" >&2
    exit 2
fi
if [ ! -x "$BIN" ]; then
    echo "council: binary not found at $BIN; run make first" >&2
    exit 2
fi
command -v python3 >/dev/null 2>&1 || {
    echo "council: python3 is required" >&2
    exit 2
}
command -v perl >/dev/null 2>&1 || {
    echo "council: perl is required for deadlines" >&2
    exit 2
}

TMP="$(mktemp -d /tmp/swarm-council.XXXXXX)"
PIDS=""
cleanup() {
    for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    if [ "${SWARM_COUNCIL_KEEP:-0}" != "1" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT INT TERM

IFS=',' read -r PROFILE_1 PROFILE_2 PROFILE_3 <<EOF
$PROFILES_CSV
EOF
PROFILE_1="${PROFILE_1:-kimi}"
PROFILE_2="${PROFILE_2:-$PROFILE_1}"
PROFILE_3="${PROFILE_3:-$PROFILE_1}"

role_prompt() {
    case "$1" in
        architect)
            echo "Focus on architecture, interfaces, reuse, and long-term maintainability."
            ;;
        skeptic)
            echo "Challenge assumptions. Focus on security, failure modes, tests, cost, and operational risks."
            ;;
        operator)
            echo "Focus on the smallest useful implementation, user experience, rollout, and observability."
            ;;
    esac
}

launch_panel() {
    idx="$1"
    role="$2"
    profile="$3"
    log="$TMP/panel-$idx.log"
    panel_prompt="READ-ONLY COUNCIL PANEL. The repository root is your current working directory: use relative paths only. Do not edit files, run shell commands, spawn subagents, or delegate. Use at most six tool calls, then answer. Start with the most relevant of README.md, REVIEW.md, scripts/council.sh, src/ToolRegistry.sw, src/ToolExecutor.sw, and src/main.sw. $(role_prompt "$role")

Question:
$PROMPT

Return at most 500 words with: findings, recommendation, risks, and confidence."
    (
        cd "$ROOT" || exit 97
        SWARM_CODE_EXECUTION_CONTEXT=council_panel \
        SWARM_CODE_PLAN=off \
        SWARM_CODE_NO_RESUME=1 \
        SWARM_CODE_MAX_OUTPUT_TOKENS="$MAX_OUTPUT" \
        perl -e 'alarm shift; exec @ARGV' "$PANEL_TIMEOUT" \
            "$BIN" --profile "$profile" -p "$panel_prompt" --no-resume --json
    ) >"$log" 2>&1 &
    PIDS="$PIDS $!"
    echo "  panel $idx: $role via $profile"
}

echo "council: launching bounded read-only panel"
launch_panel 1 architect "$PROFILE_1"
launch_panel 2 skeptic "$PROFILE_2"
launch_panel 3 operator "$PROFILE_3"

for pid in $PIDS; do
    wait "$pid" 2>/dev/null || true
done
PIDS=""

extract_summary() {
    python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
lines = open(path, errors="replace").read().splitlines()
for line in reversed(lines):
    try:
        value = json.loads(line)
    except Exception:
        continue
    if isinstance(value, dict) and isinstance(value.get("summary"), str):
        print(value["summary"])
        raise SystemExit
print("[panel failed or reached its deadline]")
PY
}

PANEL_1="$(extract_summary "$TMP/panel-1.log")"
PANEL_2="$(extract_summary "$TMP/panel-2.log")"
PANEL_3="$(extract_summary "$TMP/panel-3.log")"

cat >"$TMP/judge-prompt.txt" <<EOF
You are the bounded judge for a repository-aware council. Do not call tools.
Compare the independent panel responses. Do not merely average them.

Question:
$PROMPT

Architect panel:
$PANEL_1

Skeptic panel:
$PANEL_2

Operator panel:
$PANEL_3

Return at most 700 words with exactly these headings:
Consensus
Contradictions
Unique Insights
Blind Spots
Final Recommendation
Confidence
EOF

echo "council: panel complete; running judge via $JUDGE_PROFILE"
(
    cd "$ROOT" || exit 97
    SWARM_CODE_EXECUTION_CONTEXT=council_judge \
    SWARM_CODE_PLAN=off \
    SWARM_CODE_NO_RESUME=1 \
    SWARM_CODE_MAX_OUTPUT_TOKENS="$MAX_OUTPUT" \
    perl -e 'alarm shift; exec @ARGV' "$JUDGE_TIMEOUT" \
        "$BIN" --profile "$JUDGE_PROFILE" -p - --no-resume --json \
        <"$TMP/judge-prompt.txt"
) >"$TMP/judge.log" 2>&1
JUDGE_RC=$?

if [ "$JUDGE_RC" -ne 0 ]; then
    echo "council: judge failed or reached its deadline" >&2
    [ "${SWARM_COUNCIL_KEEP:-0}" = "1" ] && echo "artifacts: $TMP" >&2
    exit 1
fi

extract_summary "$TMP/judge.log"
[ "${SWARM_COUNCIL_KEEP:-0}" = "1" ] && echo "artifacts: $TMP" >&2
