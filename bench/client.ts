#!/usr/bin/env -S npx tsx
import { readFileSync } from 'fs';
import { join } from 'path';
import { performance } from 'perf_hooks';

const payloads = JSON.parse(readFileSync(join(__dirname, 'payloads.json'), 'utf8'));
const ITERATIONS = parseInt(process.env.BENCH_ITERATIONS || '100000', 10);
const WARMUP = 1000;

interface BenchResult {
  lang: string;
  bench: string;
  iterations: number;
  total_ms: number;
  ops_per_sec: number;
  peak_rss_kb: number;
}

function report(bench: string, iterations: number, totalMs: number): void {
  const result: BenchResult = {
    lang: 'typescript',
    bench,
    iterations,
    total_ms: Math.round(totalMs * 100) / 100,
    ops_per_sec: Math.round(iterations / (totalMs / 1000)),
    peak_rss_kb: Math.round(process.memoryUsage().rss / 1024),
  };
  console.log(JSON.stringify(result));
}

// --- Benchmark 1: Path extraction ---
function benchPathExtract(): void {
  const chunks = payloads.openai_chunks as string[];
  let sink = 0; // prevent DCE

  // Warmup
  for (let i = 0; i < WARMUP; i++) {
    for (const chunk of chunks) {
      const parsed = JSON.parse(chunk);
      const content = parsed.choices?.[0]?.delta?.content;
      if (content) sink += content.length;
    }
  }

  const ops = ITERATIONS * chunks.length;
  const start = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    for (const chunk of chunks) {
      const parsed = JSON.parse(chunk);
      const content = parsed.choices?.[0]?.delta?.content;
      if (content) sink += content.length;
    }
  }
  const elapsed = performance.now() - start;

  if (sink === 0) process.exit(1); // never happens, prevents DCE
  report('path_extract', ops, elapsed);
}

// --- Benchmark 2: Tool call assembly ---
function benchToolAssembly(): void {
  const fragments = payloads.tool_call_fragments as string[];
  let sink = 0;

  // Warmup
  for (let i = 0; i < WARMUP; i++) {
    let buf = '';
    for (const frag of fragments) {
      buf += frag;
    }
    try { JSON.parse(buf); sink++; } catch {}
  }

  const start = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    let buf = '';
    for (const frag of fragments) {
      buf += frag;
      try {
        JSON.parse(buf);
        sink++;
        break;
      } catch {}
    }
  }
  const elapsed = performance.now() - start;

  if (sink === 0) process.exit(1);
  report('tool_assembly', ITERATIONS, elapsed);
}

// --- Benchmark 3: Request building ---
function benchRequestBuild(): void {
  const fields = payloads.request_fields;
  let sink = 0;

  // Warmup
  for (let i = 0; i < WARMUP; i++) {
    const body = JSON.stringify({
      model: fields.model,
      max_tokens: fields.max_tokens,
      stream: true,
      messages: [{ role: 'user', content: fields.user_message }],
      tools: JSON.parse(fields.tools_json),
    });
    sink += body.length;
  }

  const start = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    const body = JSON.stringify({
      model: fields.model,
      max_tokens: fields.max_tokens,
      stream: true,
      messages: [{ role: 'user', content: fields.user_message }],
      tools: JSON.parse(fields.tools_json),
    });
    sink += body.length;
  }
  const elapsed = performance.now() - start;

  if (sink === 0) process.exit(1);
  report('request_build', ITERATIONS, elapsed);
}

// --- Run all ---
benchPathExtract();
benchToolAssembly();
benchRequestBuild();
