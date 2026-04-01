#!/usr/bin/env -S npx tsx
/**
 * SSE streaming benchmark — TypeScript
 * Measures: connect → fetch stream → read lines → JSON.parse → extract
 */

const PORT = parseInt(process.env.PORT || '3000', 10);
const EVENTS = parseInt(process.env.STREAM_EVENTS || '10000', 10);

interface StreamResult {
  lang: string;
  bench: string;
  events: number;
  extracted: number;
  total_ms: number;
  events_per_sec: number;
}

async function benchStream(provider: string): Promise<StreamResult> {
  const pathMap: Record<string, string> = {
    openai: '/openai/stream',
    anthropic: '/anthropic/stream',
    ollama: '/ollama/stream',
  };

  const url = `http://127.0.0.1:${PORT}${pathMap[provider]}?n=${EVENTS}`;

  const start = performance.now();
  const response = await fetch(url);
  const reader = response.body!.getReader();
  const decoder = new TextDecoder();

  let eventCount = 0;
  let extractCount = 0;
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop()!; // keep incomplete last line

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('data: ')) continue;
      const data = trimmed.slice(6);
      if (data === '[DONE]') continue;

      eventCount++;

      try {
        const parsed = JSON.parse(data);
        if (provider === 'openai') {
          if (parsed.choices?.[0]?.delta?.content != null) extractCount++;
        } else if (provider === 'anthropic') {
          if (parsed.delta?.text != null) extractCount++;
        } else {
          if (parsed.response != null) extractCount++;
        }
      } catch {}
    }
  }

  const elapsed = performance.now() - start;
  return {
    lang: 'typescript',
    bench: `sse_${provider}`,
    events: eventCount,
    extracted: extractCount,
    total_ms: Math.round(elapsed * 100) / 100,
    events_per_sec: Math.round(eventCount / (elapsed / 1000)),
  };
}

async function main() {
  for (const provider of ['openai', 'anthropic', 'ollama']) {
    const result = await benchStream(provider);
    console.log(JSON.stringify(result));
  }
}

main().catch(console.error);
