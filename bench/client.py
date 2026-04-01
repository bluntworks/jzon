#!/usr/bin/env python3
"""jzon benchmark client — Python (json.loads) baseline."""

import json
import os
import resource
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ITERATIONS = int(os.environ.get('BENCH_ITERATIONS', '100000'))
WARMUP = 1000

with open(os.path.join(SCRIPT_DIR, 'payloads.json')) as f:
    payloads = json.load(f)


def report(bench, iterations, total_ns):
    total_ms = total_ns / 1_000_000
    ops_per_sec = int(iterations / (total_ns / 1_000_000_000)) if total_ns > 0 else 0
    # ru_maxrss is in bytes on Linux, KB on macOS
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == 'linux':
        rss_kb = rss // 1024
    else:
        rss_kb = rss // 1024  # macOS reports in bytes too since recent versions

    result = {
        'lang': 'python',
        'bench': bench,
        'iterations': iterations,
        'total_ms': round(total_ms, 2),
        'ops_per_sec': ops_per_sec,
        'peak_rss_kb': rss_kb,
    }
    print(json.dumps(result))


# --- Benchmark 1: Path extraction ---
def bench_path_extract():
    chunks = payloads['openai_chunks']
    sink = 0

    # Warmup
    for _ in range(WARMUP):
        for chunk in chunks:
            parsed = json.loads(chunk)
            content = parsed.get('choices', [{}])[0].get('delta', {}).get('content')
            if content:
                sink += len(content)

    ops = ITERATIONS * len(chunks)
    start = time.perf_counter_ns()
    for _ in range(ITERATIONS):
        for chunk in chunks:
            parsed = json.loads(chunk)
            content = parsed.get('choices', [{}])[0].get('delta', {}).get('content')
            if content:
                sink += len(content)
    elapsed = time.perf_counter_ns() - start

    assert sink > 0
    report('path_extract', ops, elapsed)


# --- Benchmark 2: Tool call assembly ---
def bench_tool_assembly():
    fragments = payloads['tool_call_fragments']
    sink = 0

    # Warmup
    for _ in range(WARMUP):
        buf = ''
        for frag in fragments:
            buf += frag
        try:
            json.loads(buf)
            sink += 1
        except json.JSONDecodeError:
            pass

    start = time.perf_counter_ns()
    for _ in range(ITERATIONS):
        buf = ''
        for frag in fragments:
            buf += frag
            try:
                json.loads(buf)
                sink += 1
                break
            except json.JSONDecodeError:
                pass
    elapsed = time.perf_counter_ns() - start

    assert sink > 0
    report('tool_assembly', ITERATIONS, elapsed)


# --- Benchmark 3: Request building ---
def bench_request_build():
    fields = payloads['request_fields']
    tools = json.loads(fields['tools_json'])
    sink = 0

    # Warmup
    for _ in range(WARMUP):
        body = json.dumps({
            'model': fields['model'],
            'max_tokens': fields['max_tokens'],
            'stream': True,
            'messages': [{'role': 'user', 'content': fields['user_message']}],
            'tools': tools,
        })
        sink += len(body)

    start = time.perf_counter_ns()
    for _ in range(ITERATIONS):
        body = json.dumps({
            'model': fields['model'],
            'max_tokens': fields['max_tokens'],
            'stream': True,
            'messages': [{'role': 'user', 'content': fields['user_message']}],
            'tools': tools,
        })
        sink += len(body)
    elapsed = time.perf_counter_ns() - start

    assert sink > 0
    report('request_build', ITERATIONS, elapsed)


if __name__ == '__main__':
    bench_path_extract()
    bench_tool_assembly()
    bench_request_build()
