#!/bin/sh
# Run every tests/*_test.sw — build to a temp binary, run, check exit code.
# Each test is `module Main` that sys_exit(0) on pass, non-zero on fail.
cd "$(dirname "$0")/.."
SWC=${SWC:-/Users/sky/swarmrt/bin/swc}
PASS=0; FAIL=0
for f in tests/*_test.sw; do
  m=$(basename "$f" _test.sw)
  out=$(mktemp -t swarm_test_$m)
  if ! "$SWC" build "$f" -o "$out" >/dev/null 2>&1; then
    echo "  ✗ $m  (build failed)"
    FAIL=$((FAIL+1)); rm -f "$out"; continue
  fi
  if perl -e 'alarm 5; exec @ARGV' "$out" >/dev/null 2>&1; then
    echo "  ✓ $m"
    PASS=$((PASS+1))
  else
    echo "  ✗ $m  (test logic failed, exit non-zero)"
    FAIL=$((FAIL+1))
  fi
  rm -f "$out"
done
echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
