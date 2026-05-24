#!/bin/sh
# Smoke test — boot-level sanity, no network, no API key needed.
# Goal: catch a completely broken binary (missing builtins, link
# errors, segfaults at startup) in under 5 seconds.
#
# Three checks:
#   1. --version returns the expected line
#   2. --print-config runs without crashing (exercises Config.load,
#      JSON parsing, env-var resolution)
#   3. swarm doctor exits with 0, 1, or 2 — anything else (segfault,
#      compile-time link error) is a fatal regression
#
# What this DOESN'T test: actual LLM calls. That's `make integ` (TODO)
# and runs only when SWARM_CODE_API_KEY is set.

set -e
BIN=${BIN:-./bin/swarm-code}
FAIL() { echo "FAIL: $1"; exit 1; }

# 1. --version
OUT=$($BIN --version 2>&1 | tail -1)
echo "$OUT" | grep -q "^swarm-code [0-9]" || FAIL "--version: $OUT"

# 2. --print-config (no LLM call)
$BIN --print-config >/dev/null 2>&1 || FAIL "--print-config crashed"

# 3. swarm doctor — accept exits 0 (green), 1 (warn), 2 (error).
#    Disable `set -e` around the call so a non-zero exit doesn't
#    short-circuit the script before we can inspect $?.
set +e
$BIN doctor >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -gt 2 ]; then FAIL "doctor crashed with exit $RC"; fi

echo "smoke ok"
