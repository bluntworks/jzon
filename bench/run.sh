#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ITERATIONS="${BENCH_ITERATIONS:-100000}"
export BENCH_ITERATIONS="$ITERATIONS"

echo "=== jzon Benchmark Suite ==="
echo "Iterations: $ITERATIONS"
echo ""

# --- Build Zig client (build only, don't run) ---
echo "Building Zig benchmark (ReleaseFast)..."
zig build -Doptimize=ReleaseFast 2>/dev/null
echo ""

# --- Collect results ---
RESULTS_FILE=$(mktemp)
trap "rm -f $RESULTS_FILE" EXIT

echo "Running Zig benchmark..."
./zig-out/bin/bench >> "$RESULTS_FILE"

echo "Running TypeScript benchmark..."
npx tsx bench/client.ts >> "$RESULTS_FILE" 2>/dev/null

echo "Running Python benchmark..."
python3 bench/client.py >> "$RESULTS_FILE"

echo ""

# --- Print comparison table ---
python3 -c "
import json, sys

results = {}
for line in open('$RESULTS_FILE'):
    line = line.strip()
    if not line: continue
    r = json.loads(line)
    key = (r['bench'], r['lang'])
    results[key] = r

benches = ['path_extract', 'tool_assembly', 'request_build']
langs = ['zig', 'typescript', 'python']
labels = {'path_extract': 'Path extraction', 'tool_assembly': 'Tool assembly', 'request_build': 'Request build'}

def fmt_ops(n):
    if n >= 1_000_000: return f'{n/1_000_000:.1f}M/s'
    if n >= 1_000: return f'{n/1_000:.1f}K/s'
    return f'{n}/s'

# Header
print('┌───────────────────┬──────────────┬──────────────┬──────────────┐')
print('│ Benchmark         │ Zig (jzon)   │ TypeScript   │ Python       │')
print('├───────────────────┼──────────────┼──────────────┼──────────────┤')

for bench in benches:
    cols = []
    for lang in langs:
        r = results.get((bench, lang))
        if r:
            cols.append(fmt_ops(r['ops_per_sec']))
        else:
            cols.append('N/A')
    label = labels.get(bench, bench)
    print(f'│ {label:<17} │ {cols[0]:>12} │ {cols[1]:>12} │ {cols[2]:>12} │')

# Speedup row
print('├───────────────────┼──────────────┼──────────────┼──────────────┤')
for bench in benches:
    zig_r = results.get((bench, 'zig'))
    cols = []
    for lang in langs:
        r = results.get((bench, lang))
        if r and zig_r and lang != 'zig':
            if r['ops_per_sec'] > 0:
                speedup = zig_r['ops_per_sec'] / r['ops_per_sec']
                cols.append(f'{speedup:.1f}x slower')
            else:
                cols.append('N/A')
        elif lang == 'zig':
            cols.append('baseline')
        else:
            cols.append('N/A')
    label = labels.get(bench, bench)
    print(f'│ {label:<17} │ {cols[0]:>12} │ {cols[1]:>12} │ {cols[2]:>12} │')

print('└───────────────────┴──────────────┴──────────────┴──────────────┘')

# RSS row
print()
rss = {}
for lang in langs:
    for bench in benches:
        r = results.get((bench, lang))
        if r and r.get('peak_rss_kb', 0) > 0:
            rss[lang] = max(rss.get(lang, 0), r['peak_rss_kb'])
if rss:
    print('Peak RSS:  ', end='')
    for lang in langs:
        v = rss.get(lang, 0)
        if v > 0:
            print(f'  {lang}: {v/1024:.1f} MB', end='')
    print()
"
