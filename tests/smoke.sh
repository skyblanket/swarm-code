#!/bin/sh
# Minimum sanity check: bin builds + runs + dispatches a tool.
set -e
BIN=${BIN:-./bin/swarm-code}
OUT=$($BIN -p "Use bash to print exactly: SMOKE_OK" 2>&1)
echo "$OUT" | grep -q "SMOKE_OK" || { echo "FAIL: smoke test"; echo "$OUT"; exit 1; }
echo "smoke ok"
