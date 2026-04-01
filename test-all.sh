#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "=== jzon Full Test Suite ==="
echo ""

# --- 1. Unit tests + fuzz smoke tests + deterministic simulation ---
echo "--- Unit tests, fuzz, and deterministic simulation ---"
zig build test --summary all
echo ""

# --- 2. Build benchmark client ---
echo "--- Building benchmarks (ReleaseFast) ---"
zig build -Doptimize=ReleaseFast
echo ""

# --- 3. Benchmarks ---
echo "--- Benchmarks: Zig vs TypeScript vs Python ---"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-10000}" bash bench/run.sh
echo ""

# --- 4. Server-based chaos simulation ---
echo "--- Server-based chaos simulation ---"
PORT=3199 node bench/server.js &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT
sleep 1

SEEDS=(42 12345 99999 0xdeadbeef 0xcafebabe 0x1337 7777 0xfeedface)
FAIL=0

for seed in "${SEEDS[@]}"; do
  if ! ./zig-out/bin/sim-client --seed "$seed" --events 1000 --port 3199; then
    echo "FAIL: seed $seed"
    FAIL=1
  fi
done

kill $SERVER_PID 2>/dev/null || true
trap - EXIT
echo ""

# --- Summary ---
if [ "$FAIL" -eq 0 ]; then
  echo "=== ALL TESTS PASSED ==="
else
  echo "=== SOME TESTS FAILED ==="
  exit 1
fi
