#!/bin/sh
# Run every tests/*_test.sw — build to a temp binary, run, check exit code.
# Each test is `module Main` that sys_exit(0) on pass, non-zero on fail.
cd "$(dirname "$0")/.."
SWC=${SWC:-/Users/sky/swarmrt/bin/swc}
PASS=0; FAIL=0
for f in tests/*_test.sw; do
  m=$(basename "$f" _test.sw)
  out=$(mktemp -t swarm_test_${m}.XXXXXX)
  BUILD_LOG=$(mktemp -t swarm_test_build.XXXXXX)
  if ! "$SWC" build "$f" -o "$out" >"$BUILD_LOG" 2>&1; then
    echo "  ✗ $m  (build failed)"
    # Print last 5 lines of build error so CI can be diagnosed.
    sed 's/^/      /' "$BUILD_LOG" | tail -5
    rm -f "$out" "$BUILD_LOG"
    FAIL=$((FAIL+1)); continue
  fi
  rm -f "$BUILD_LOG"
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
