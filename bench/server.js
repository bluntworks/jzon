#!/usr/bin/env node
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const payloads = JSON.parse(fs.readFileSync(path.join(__dirname, 'payloads.json'), 'utf8'));
const PORT = parseInt(process.env.PORT || '3000', 10);

// --- Seeded PRNG (xoshiro128**) ---
class PRNG {
  constructor(seed) {
    // SplitMix64 to initialize state from single seed
    let s = BigInt(seed) | 0n;
    const sm = () => {
      s = (s + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
      let z = s;
      z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
      z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
      return z ^ (z >> 31n);
    };
    this.s = [
      Number(sm() & 0xffffffffn),
      Number(sm() & 0xffffffffn),
      Number(sm() & 0xffffffffn),
      Number(sm() & 0xffffffffn),
    ];
  }

  next() {
    const s = this.s;
    const result = (((s[1] * 5) << 7 | (s[1] * 5) >>> 25) * 9) >>> 0;
    const t = s[1] << 9;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = (s[3] << 11 | s[3] >>> 21);
    return result;
  }

  // Random int in [0, max)
  int(max) { return this.next() % max; }

  // Random float in [0, 1)
  float() { return this.next() / 0x100000000; }

  // Pick random element from array
  pick(arr) { return arr[this.int(arr.length)]; }

  // Random boolean with given probability of true
  chance(p) { return this.float() < p; }
}

// --- Random content generation ---
const WORDS = [
  'hello', 'world', 'the', 'quick', 'brown', 'fox', 'jumps', 'over',
  'lazy', 'dog', 'function', 'return', 'const', 'var', 'let', 'async',
  'await', 'import', 'export', 'class', 'struct', 'enum', 'type',
  'error', 'null', 'true', 'false', 'undefined', 'promise', 'result',
  'interface', 'module', 'package', 'implements', 'extends', 'abstract',
  'volatile', 'synchronized', 'transient', 'native', 'static', 'final',
  'override', 'virtual', 'template', 'typename', 'namespace', 'using',
  'delegate', 'event', 'property', 'operator', 'constructor', 'destructor',
];

const UNICODE_CHARS = [
  '\\u00b0', '\\u2728', '\\u2603', '\\u00e9', '\\u00fc', '\\u2192',
  '\\u00f1', '\\u00e8', '\\u00e0', '\\u00f6', '\\u2764', '\\u2605',
  '\\u00a9', '\\u00ae', '\\u2022', '\\u2013', '\\u2014', '\\u201c', '\\u201d',
];

const CODE_SNIPPETS = [
  '```python\\ndef hello():\\n    print(\\\"hello world\\\")\\n```',
  '```javascript\\nconst x = await fetch(\\\"/api\\\");\\nconst data = x.json();\\n```',
  '```zig\\nconst std = @import(\\\"std\\\");\\npub fn main() !void {}\\n```',
  '```bash\\ncurl -s http://localhost:3000/health\\necho \\\"done\\\"\\n```',
  '```sql\\nSELECT * FROM users WHERE id = 1;\\n```',
  '```\\n// generic code block\\nfor (i = 0; i < n; i++) { }\\n```',
];

const MARKDOWN_PATTERNS = [
  '\\n> This is a blockquote\\n> with multiple lines\\n',
  '\\n1. First item\\n2. Second item\\n3. Third item\\n',
  '\\n- Bullet point\\n- Another bullet\\n  - Nested bullet\\n',
  '\\n| Col A | Col B |\\n|-------|-------|\\n| val1  | val2  |\\n',
  '\\n---\\n',
  '**bold text**',
  '*italic text*',
  '`inline code`',
  '[link text](https://example.com)',
];

const MULTI_SENTENCE = [
  'Let me think about that for a moment.',
  'The answer involves several considerations.',
  'Here is what I found after analyzing the data.',
  'Based on the available information, I can provide the following.',
  'There are multiple approaches to consider here.',
  'I need to clarify a few things before answering.',
];

function randomContent(rng, minWords, maxWords) {
  const contentStyle = rng.int(10);

  if (contentStyle < 5) {
    // Simple word sequence (50%)
    const count = minWords + rng.int(maxWords - minWords + 1);
    const parts = [];
    for (let i = 0; i < count; i++) {
      parts.push(rng.pick(WORDS));
      if (rng.chance(0.05)) parts.push('\\n');
      if (rng.chance(0.04)) parts.push(rng.pick(UNICODE_CHARS));
      if (rng.chance(0.03)) parts.push('\\"');
      if (rng.chance(0.03)) parts.push('\\\\');
      if (rng.chance(0.02)) parts.push('\\t');
      if (rng.chance(0.02)) parts.push('\\/');
    }
    return parts.join(' ');
  } else if (contentStyle < 7) {
    // Code snippet (20%)
    return rng.pick(CODE_SNIPPETS);
  } else if (contentStyle < 8) {
    // Markdown-heavy (10%)
    const parts = [rng.pick(MULTI_SENTENCE)];
    parts.push(rng.pick(MARKDOWN_PATTERNS));
    parts.push(rng.pick(WORDS) + ' ' + rng.pick(WORDS) + ' ' + rng.pick(WORDS));
    if (rng.chance(0.5)) parts.push(rng.pick(MARKDOWN_PATTERNS));
    return parts.join(' ').replace(/"/g, '\\"');
  } else if (contentStyle < 9) {
    // Long multi-sentence (10%)
    const sentences = 2 + rng.int(5);
    const parts = [];
    for (let s = 0; s < sentences; s++) {
      parts.push(rng.pick(MULTI_SENTENCE));
    }
    return parts.join(' ').replace(/"/g, '\\"');
  } else {
    // Empty or single char (10%) — edge cases
    const edge = rng.int(4);
    if (edge === 0) return '';          // empty content
    if (edge === 1) return ' ';         // single space
    if (edge === 2) return rng.pick(UNICODE_CHARS); // single unicode
    return rng.pick(WORDS);             // single word
  }
}

function makeOpenAIChunk(content) {
  return `{"id":"chatcmpl-sim","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"${content}"},"finish_reason":null}]}`;
}

function makeAnthropicChunk(text) {
  return `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"${text}"}}`;
}

function makeOllamaChunk(response) {
  return `{"model":"llama3","created_at":"2024-01-01T00:00:00Z","response":"${response}","done":false}`;
}

// --- Fault injection ---
function corruptJSON(rng, json) {
  const corruption = rng.int(7);
  const bytes = Buffer.from(json);
  switch (corruption) {
    case 0: // Truncate
      return bytes.slice(0, 1 + rng.int(bytes.length - 1)).toString();
    case 1: { // Flip a byte
      const pos = rng.int(bytes.length);
      bytes[pos] = bytes[pos] ^ (1 + rng.int(254));
      return bytes.toString();
    }
    case 2: // Delete a byte
      return Buffer.concat([bytes.slice(0, rng.int(bytes.length)), bytes.slice(rng.int(bytes.length) + 1)]).toString();
    case 3: // Unbalance brackets — remove closing
      return json.replace(/[}\]]/, '');
    case 4: // Insert invalid UTF-8
      return json.slice(0, rng.int(json.length)) + '\xff\xfe' + json.slice(rng.int(json.length));
    case 5: // Double a bracket
      return json.replace(/([{}\[\]])/, '$1$1');
    case 6: // Replace chunk with garbage
      const start = rng.int(json.length);
      const end = Math.min(start + 1 + rng.int(15), json.length);
      return json.slice(0, start) + 'XXXX' + json.slice(end);
  }
  return json;
}

// --- SSE helpers ---
function sseHeaders(res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
  });
}

function sseEvent(res, data) {
  res.write(`data: ${data}\n\n`);
}

// --- Benchmark endpoints (clean, fast) ---
function handleBenchStream(res, chunks, n) {
  sseHeaders(res);
  for (let i = 0; i < n; i++) {
    sseEvent(res, chunks[i % chunks.length]);
  }
  sseEvent(res, '[DONE]');
  res.end();
}

// --- Simulation endpoint (chaotic, seeded) ---
function handleSimStream(res, seed, n) {
  const rng = new PRNG(seed);
  const oracle = [];

  sseHeaders(res);

  for (let i = 0; i < n; i++) {
    const strategy = rng.float();
    let json, expected, type;

    if (strategy < 0.70) {
      // Clean event with extractable value
      const provider = rng.int(3);
      const content = randomContent(rng, 1, 8);
      switch (provider) {
        case 0:
          json = makeOpenAIChunk(content);
          type = 'openai';
          break;
        case 1:
          json = makeAnthropicChunk(content);
          type = 'anthropic';
          break;
        case 2:
          json = makeOllamaChunk(content);
          type = 'ollama';
          break;
      }
      expected = content;
      oracle.push({ index: i, type, valid: true, expected });
    } else if (strategy < 0.85) {
      // Clean event but chunked delivery (still valid JSON)
      const content = randomContent(rng, 1, 5);
      json = makeOpenAIChunk(content);
      type = 'openai';
      expected = content;
      oracle.push({ index: i, type, valid: true, expected, chunked: true });
    } else if (strategy < 0.95) {
      // Malformed event
      const content = randomContent(rng, 1, 3);
      const validJson = makeOpenAIChunk(content);
      json = corruptJSON(rng, validJson);
      type = 'malformed';
      oracle.push({ index: i, type, valid: false });
    } else {
      // Tool call fragment start (simplified — single complete tool call)
      const toolJson = `{"city":"${rng.pick(WORDS)}","action":"${rng.pick(WORDS)}"}`;
      json = `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"${toolJson.replace(/"/g, '\\"')}"}}`;
      type = 'tool_call';
      oracle.push({ index: i, type, valid: true, expected: toolJson });
    }

    sseEvent(res, json);
  }

  sseEvent(res, '[DONE]');
  res.end();

  return oracle;
}

// --- Server ---
let lastOracle = [];

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const n = parseInt(url.searchParams.get('n') || '1000', 10);

  switch (url.pathname) {
    case '/openai/stream':
      handleBenchStream(res, payloads.openai_chunks, n);
      break;

    case '/anthropic/stream':
      handleBenchStream(res, payloads.anthropic_chunks, n);
      break;

    case '/ollama/stream':
      handleBenchStream(res, payloads.ollama_chunks, n);
      break;

    case '/sim/stream': {
      const seed = parseInt(url.searchParams.get('seed') || '0', 10);
      lastOracle = handleSimStream(res, seed, n);
      break;
    }

    case '/sim/oracle':
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(lastOracle));
      break;

    case '/health':
      res.writeHead(200);
      res.end('ok');
      break;

    default:
      res.writeHead(404);
      res.end('not found');
  }
});

server.listen(PORT, () => {
  console.log(`jzon mock SSE server listening on http://localhost:${PORT}`);
  console.log(`Endpoints:`);
  console.log(`  GET /openai/stream?n=1000`);
  console.log(`  GET /anthropic/stream?n=1000`);
  console.log(`  GET /ollama/stream?n=1000`);
  console.log(`  GET /sim/stream?seed=42&n=1000`);
  console.log(`  GET /sim/oracle`);
  console.log(`  GET /health`);
});
