# Changelog

## 2026-04-01

### Server-based chaos simulation client

- `test/sim_client.zig`: Zig executable that connects to the Node chaos server, consumes SSE stream with jzon, validates extractions across providers (OpenAI, Anthropic, Ollama, tool calls).
- Accepts `--seed`, `--events`, `--port` flags for reproducible runs.
- Reports extracted vs error counts per seed. ~95% extraction rate with ~5-10% intentional fault injection.
- Usage: `node bench/server.js & ./zig-out/bin/sim-client --seed 0xdeadbeef --events 500`

### Deterministic simulation testing (Tiger-Style DST)

- TigerBeetle-inspired deterministic simulation: all randomness from one u64 seed, same seed = identical test execution.
- Five strategies: positive (valid JSON vs std.json oracle), negative (corrupted JSON), round-trip (escape/unescape + writer/getString), chunk chaos (split at random byte boundaries), assembler (random-sized fragments).
- PRNG-driven parameters: object depth 0-10, keys 0-5, strings 0-20 chars with escapes/unicode, numbers with decimals/negatives.
- 1000 seeds run in `zig build test`, 10000 seeds in extended test. Regression seed array for known failures.
- Total: 194 tests passing.

### Benchmark infrastructure

- **Mock SSE server** (`bench/server.js`): Node.js server with benchmark endpoints (OpenAI, Anthropic, Ollama) and seeded chaos simulation endpoint for deterministic testing.
- **Three benchmark clients** comparing jzon (Zig) vs TypeScript (`JSON.parse`) vs Python (`json.loads`) on identical payloads:
  - Path extraction: jzon 1.8M/s vs TS 859K/s vs Python 222K/s (2-8x faster)
  - Request building: jzon 1.1M/s vs TS 424K/s vs Python 125K/s (2.6-9x faster)
  - Tool assembly: jzon 127K/s vs TS 24K/s vs Python 55K/s
- **Orchestrator** (`bench/run.sh`): builds, runs all three, prints comparison table
- Peak RSS: Zig ~1MB, TypeScript ~80MB, Python ~8MB

### Fuzz tests and scanner idempotence test

- Added fuzz tests to all input-facing components using `std.testing.fuzz`:
  - `escape.zig`: Arbitrary bytes to `unescape` + escape/unescape roundtrip
  - `scanner.zig`: Arbitrary bytes through tokenizer
  - `path.zig`: Arbitrary bytes as JSON to `getString`/`getInt`/`getBool`/`getRaw`
  - `assembler.zig`: Arbitrary bytes as single chunk + byte-at-a-time split
- Added scanner idempotence test: whole-buffer vs byte-at-a-time produces identical token sequences
- Continuous coverage-guided fuzzing (`zig build fuzz --fuzz`) blocked by Zig 0.15.2 build runner bug (null `fuzz_context` panic). Fuzz functions run as single-pass smoke tests in normal `zig build test`. Will work when Zig fixes the plumbing — no code changes needed.
- Total: 192 tests passing

### jzon v0.1.0 — all components implemented

- **path.zig** (18 tests): Zero-copy path extraction with comptime path expressions. `getString`, `getRaw`, `getInt`, `getBool`. Skips non-matching subtrees by depth counting. Handles real OpenAI and Anthropic SSE payloads.
- **writer.zig** (10 tests): JSON builder generic over any `std.io.Writer`. Automatic comma insertion, string escaping, bounded nesting (`MAX_DEPTH=64`). `raw()` passthrough for pre-serialized JSON. Output validated against `std.json.parseFromSlice`.
- **assembler.zig** (11 tests): Partial JSON fragment assembler for tool call streaming. Explicit state machine (`empty→incomplete→complete|invalid`). Bounded depth tracking, reset for reuse.
- **root.zig**: Public API re-exports for ergonomic `jzon.getString(...)` usage.
- **integration tests** (8 tests): Real SSE payloads from OpenAI, Anthropic, Ollama. Tool call assembly with `std.json` validation. Request body round-trip (writer → path extraction).
- **Total: 174 tests passing across 7 test targets.**

### escape.zig and scanner.zig implemented

- **escape.zig** (15 tests): RFC 8259 string escaping/unescaping. Zero-copy `unescape` returns slice into input when no escapes present. Full unicode support including surrogate pairs. Bounded scratch buffer, no heap allocation. Roundtrip property test verifies `unescape(escape(s)) == s`.
- **scanner.zig** (14 tests): Streaming JSON tokenizer with explicit 13-state state machine. Zero heap allocations — all state in a ~128-byte struct. Bounded nesting depth (`MAX_DEPTH=64`, comptime validated). Handles all JSON value types: objects, arrays, strings (with escapes), numbers, true/false/null. Depth tracking verified across nested structures.
- **Build system**: `build.zig` + `build.zig.zon` for Zig 0.15.2. Per-file test targets plus integration test with `jzon` module import.

### Plan rewritten with Tiger-Style discipline

- Added Tiger-Style applicability matrix calibrating principles to jzon's domain (library, not safety-critical DB)
- Each component (`escape`, `scanner`, `path`, `writer`, `assembler`) now specifies bounded resources, state machine design, assertion vs error separation, comptime validation, and fuzz targets
- Added shared constants section with `comptime` cross-constraint validation (`MAX_DEPTH`, `MAX_PATH_SEGMENTS`, `MAX_ASSEMBLER_DEPTH`)
- Scanner and Assembler now have explicit state enums with validated transitions
- Writer uses typestate pattern and bounded nesting stack
- Added comprehensive testing strategy: roundtrip properties, fuzz targets for every input-facing component
- Rationale updated with Tiger-Style alignment section explaining zero-alloc, bounded resources, fatal/recoverable error separation, boundary validation, determinism, and explicit state machines
- Added bounds table documenting every resource limit with rationale
