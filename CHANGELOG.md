# Changelog

## 2026-04-01

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
