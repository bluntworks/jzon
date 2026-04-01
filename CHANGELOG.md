# Changelog

## 2026-04-01

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
