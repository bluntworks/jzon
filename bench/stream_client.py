#!/usr/bin/env python3
"""SSE streaming benchmark — Python
Measures: connect → read stream → split lines → json.loads → extract
"""

import json
import os
import time
import urllib.request

PORT = int(os.environ.get('PORT', '3000'))
EVENTS = int(os.environ.get('STREAM_EVENTS', '10000'))


def bench_stream(provider):
    path_map = {
        'openai': '/openai/stream',
        'anthropic': '/anthropic/stream',
        'ollama': '/ollama/stream',
    }

    url = f'http://127.0.0.1:{PORT}{path_map[provider]}?n={EVENTS}'

    start = time.perf_counter_ns()
    req = urllib.request.urlopen(url)

    event_count = 0
    extract_count = 0

    for raw_line in req:
        line = raw_line.decode('utf-8').strip()
        if not line.startswith('data: '):
            continue
        data = line[6:]
        if data == '[DONE]':
            break

        event_count += 1

        try:
            parsed = json.loads(data)
            if provider == 'openai':
                if parsed.get('choices', [{}])[0].get('delta', {}).get('content') is not None:
                    extract_count += 1
            elif provider == 'anthropic':
                if parsed.get('delta', {}).get('text') is not None:
                    extract_count += 1
            else:
                if parsed.get('response') is not None:
                    extract_count += 1
        except json.JSONDecodeError:
            pass

    req.close()
    elapsed_ns = time.perf_counter_ns() - start
    total_ms = elapsed_ns / 1_000_000
    events_per_sec = int(event_count / (elapsed_ns / 1_000_000_000)) if elapsed_ns > 0 else 0

    result = {
        'lang': 'python',
        'bench': f'sse_{provider}',
        'events': event_count,
        'extracted': extract_count,
        'total_ms': round(total_ms, 2),
        'events_per_sec': events_per_sec,
    }
    print(json.dumps(result))


if __name__ == '__main__':
    for provider in ['openai', 'anthropic', 'ollama']:
        bench_stream(provider)
