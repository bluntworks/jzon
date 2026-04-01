#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

EVENTS="${SIM_EVENTS:-500}"
PORT="${SIM_PORT:-3199}"
VERBOSE="${VERBOSE:-}"
SEEDS="${SIM_SEEDS:-42 12345 99999 0xdeadbeef 0xcafebabe 0x1337 7777 0xfeedface 0xbaadf00d 31337}"

VERBOSE_FLAG=""
if [ -n "$VERBOSE" ]; then
  VERBOSE_FLAG="--verbose"
fi

echo "=== jzon Server-Based Chaos Simulation ==="
echo "Events per seed: $EVENTS"
echo "Seeds: $SEEDS"
echo "Port: $PORT"
[ -n "$VERBOSE" ] && echo "Verbose: ON"
echo ""

# Build
echo "Building sim-client (ReleaseFast)..."
zig build -Doptimize=ReleaseFast 2>/dev/null
echo ""

# Start server
echo "Starting chaos server on port $PORT..."
PORT=$PORT node bench/server.js &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT
sleep 1

# Verify server is up
if ! curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
  echo "ERROR: Server failed to start"
  exit 1
fi

# Run seeds
PASS=0
FAIL=0
TOTAL_EVENTS=0
TOTAL_EXTRACTED=0
TOTAL_ERRORS=0

for seed in $SEEDS; do
  OUTPUT=$(./zig-out/bin/sim-client --seed "$seed" --events "$EVENTS" --port "$PORT" $VERBOSE_FLAG 2>&1)
  echo "$OUTPUT"

  # Parse the summary line
  if echo "$OUTPUT" | grep -q "status=PASS"; then
    PASS=$((PASS + 1))
    # Extract counts from output
    events=$(echo "$OUTPUT" | grep "^seed=" | sed 's/.*events=\([0-9]*\).*/\1/')
    extracted=$(echo "$OUTPUT" | grep "^seed=" | sed 's/.*extracted=\([0-9]*\).*/\1/')
    errors=$(echo "$OUTPUT" | grep "^seed=" | sed 's/.*errors=\([0-9]*\).*/\1/')
    TOTAL_EVENTS=$((TOTAL_EVENTS + events))
    TOTAL_EXTRACTED=$((TOTAL_EXTRACTED + extracted))
    TOTAL_ERRORS=$((TOTAL_ERRORS + errors))
  else
    FAIL=$((FAIL + 1))
  fi
done

# Cleanup
kill $SERVER_PID 2>/dev/null || true
trap - EXIT

# Summary
echo ""
echo "=== Simulation Summary ==="
echo "Seeds: $PASS passed, $FAIL failed ($(echo $SEEDS | wc -w | tr -d ' ') total)"
echo "Events: $TOTAL_EVENTS total, $TOTAL_EXTRACTED extracted, $TOTAL_ERRORS malformed"
if [ "$TOTAL_EVENTS" -gt 0 ]; then
  PCT=$((TOTAL_EXTRACTED * 100 / TOTAL_EVENTS))
  echo "Extraction rate: ${PCT}%"
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "FAILED — replay failing seeds with: ./zig-out/bin/sim-client --seed <SEED> --verbose"
  exit 1
else
  echo ""
  echo "ALL SEEDS PASSED"
fi
