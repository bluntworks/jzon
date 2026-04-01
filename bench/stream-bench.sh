#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

EVENTS="${STREAM_EVENTS:-10000}"
PORT="${PORT:-3198}"
export PORT STREAM_EVENTS="$EVENTS"

echo "=== jzon SSE Streaming Benchmark ==="
echo "Events per provider: $EVENTS"
echo "Port: $PORT"
echo ""

# Build
echo "Building Zig stream client (ReleaseFast)..."
zig build -Doptimize=ReleaseFast 2>/dev/null
echo ""

# Start server
echo "Starting SSE server on port $PORT..."
PORT=$PORT node bench/server.js &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT
sleep 1

if ! curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
  echo "ERROR: Server failed to start"
  exit 1
fi

# Collect results
RESULTS_FILE=$(mktemp)
trap "kill $SERVER_PID 2>/dev/null || true; rm -f $RESULTS_FILE" EXIT

echo "Running Zig streaming benchmark..."
for provider in openai anthropic ollama; do
  ./zig-out/bin/stream-bench --port "$PORT" --events "$EVENTS" --provider "$provider" >> "$RESULTS_FILE"
done

echo "Running TypeScript streaming benchmark..."
npx tsx bench/stream_client.ts >> "$RESULTS_FILE" 2>/dev/null

echo "Running Python streaming benchmark..."
python3 bench/stream_client.py >> "$RESULTS_FILE"

# Kill server
kill $SERVER_PID 2>/dev/null || true
trap "rm -f $RESULTS_FILE" EXIT

echo ""

# Print comparison table
python3 -c "
import json

results = {}
for line in open('$RESULTS_FILE'):
    line = line.strip()
    if not line: continue
    r = json.loads(line)
    key = (r['bench'], r['lang'])
    results[key] = r

providers = ['openai', 'anthropic', 'ollama']
langs = ['zig', 'typescript', 'python']
labels = {'sse_openai': 'OpenAI SSE', 'sse_anthropic': 'Anthropic SSE', 'sse_ollama': 'Ollama SSE'}

def fmt_rate(n):
    if n >= 1_000_000: return f'{n/1_000_000:.1f}M/s'
    if n >= 1_000: return f'{n/1_000:.1f}K/s'
    return f'{n}/s'

def fmt_ms(ms):
    if ms >= 1000: return f'{ms/1000:.2f}s'
    return f'{ms:.0f}ms'

print('┌───────────────────┬──────────────┬──────────────┬──────────────┐')
print('│ SSE Stream        │ Zig (jzon)   │ TypeScript   │ Python       │')
print('├───────────────────┼──────────────┼──────────────┼──────────────┤')

for provider in providers:
    bench = f'sse_{provider}'
    cols = []
    for lang in langs:
        r = results.get((bench, lang))
        if r:
            cols.append(fmt_rate(r['events_per_sec']))
        else:
            cols.append('N/A')
    label = labels.get(bench, bench)
    print(f'│ {label:<17} │ {cols[0]:>12} │ {cols[1]:>12} │ {cols[2]:>12} │')

print('├───────────────────┼──────────────┼──────────────┼──────────────┤')

for provider in providers:
    bench = f'sse_{provider}'
    cols = []
    for lang in langs:
        r = results.get((bench, lang))
        zig_r = results.get((bench, 'zig'))
        if r and zig_r and lang != 'zig':
            if r['events_per_sec'] > 0:
                speedup = zig_r['events_per_sec'] / r['events_per_sec']
                cols.append(f'{speedup:.1f}x slower')
            else:
                cols.append('N/A')
        elif lang == 'zig':
            cols.append('baseline')
        else:
            cols.append('N/A')
    label = labels.get(bench, bench)
    print(f'│ {label:<17} │ {cols[0]:>12} │ {cols[1]:>12} │ {cols[2]:>12} │')

print('├───────────────────┼──────────────┼──────────────┼──────────────┤')

# Total time row
for provider in providers:
    bench = f'sse_{provider}'
    cols = []
    for lang in langs:
        r = results.get((bench, lang))
        if r:
            cols.append(fmt_ms(r['total_ms']))
        else:
            cols.append('N/A')
    label = labels.get(bench, bench)
    print(f'│ {label:<17} │ {cols[0]:>12} │ {cols[1]:>12} │ {cols[2]:>12} │')

print('└───────────────────┴──────────────┴──────────────┴──────────────┘')
print()
print(f'Events per provider: {results.get((\"sse_openai\", \"zig\"), {}).get(\"events\", \"?\")}')
"
