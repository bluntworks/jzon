# jzon — Implementation Plan (Tiger-Style)

## Context

LLM orchestration apps in Zig (like nullclaw) use `std.json` for parsing SSE streaming responses, extracting fields, and building API requests. This works but has concrete pain points:

1. **Full tree parse per SSE line** — `std.json.parseFromSlice(Value)` allocates a hash map tree to extract one string field, then frees it all. Happens hundreds of times per conversation.
2. **No partial JSON assembly** — Tool call arguments arrive as fragments (`partial_json` chunks). No way to incrementally assemble and detect completion. Currently dropped entirely.
3. **Request building by string concatenation** — Manual `buf.appendSlice("\"model\":\"")` across every provider. Error-prone, no automatic escaping/commas.

jzon is a zero-dependency Zig 0.15.2 library that solves exactly these three problems. Nothing more.

## Tiger-Style Applicability

jzon is a **library for orchestration harnesses**, not a safety-critical database. Calibrate accordingly:

| Principle | Applies to jzon? | Notes |
|-----------|-------------------|-------|
| Typed errors, validate at boundaries | **Always** | All external JSON input is untrusted |
| Make invalid states unrepresentable | **Always** | Scanner/Assembler states, Writer nesting |
| Resource lifecycle tracking | **Always** | Assembler owns a buffer; Writer borrows one |
| Property/fuzz testing | **Always** | Parsers must handle arbitrary input without crashing |
| Static allocation, no malloc on hot paths | **Yes** | Scanner and path extraction must be zero-alloc. Assembler appends to a caller-owned buffer |
| Assertions that crash in prod | **Selective** | Assert programmer bugs (API misuse). Return errors for malformed JSON (runtime condition) |
| Full determinism | **Yes** | No randomness, no time, no iteration-order dependence. Same bytes in → same result out |
| Hard resource bounds | **Yes** | PathExpr max 8 segments, Scanner stack depth bounded, Assembler depth bounded |

## Repo Setup

`~/code/jzon/` — standalone git repo, Zig package consumable via `build.zig.zon`.

```
jzon/
├── build.zig
├── build.zig.zon
├── LICENSE                 # MIT
├── src/
│   ├── root.zig            # Public API re-exports
│   ├── scanner.zig         # Streaming JSON tokenizer
│   ├── path.zig            # Zero-copy path extraction
│   ├── assembler.zig       # Partial JSON fragment assembler
│   ├── writer.zig          # JSON object/array builder
│   └── escape.zig          # String escape/unescape
└── test/
    └── integration_test.zig  # Real SSE payloads from providers
```

## Components

### 1. `escape.zig` — String Escaping (~100 lines)

Shared by writer (escape on output) and path (unescape on extraction).

- `escape(writer, string) !void` — RFC 8259 escaping to any writer
- `unescape(input, scratch_buf) UnescapeResult` — zero-copy when no escapes present
- `needsUnescape(s) bool` — fast scan

**Tiger-Style discipline:**

- **Validate at boundary**: `unescape` must handle truncated escape sequences (e.g., input ending with `\`) — return error, never read past input bounds.
- **Bounded scratch buffer**: `unescape` takes a caller-provided `scratch_buf`. If the unescaped result would exceed `scratch_buf.len`, return `error.ScratchBufferTooSmall`. Never allocate.
- **Deterministic**: Same input bytes → same output. No locale, no state.
- **Fuzz target**: `unescape` must accept arbitrary `[]const u8` without crashing. Malformed escapes return errors, never panic.

### 2. `scanner.zig` — Streaming Tokenizer (~800-1000 lines)

State machine that accepts byte slices incrementally and emits tokens. **Zero allocations.** All state lives on the stack.

```zig
const scanner = Scanner.init(.{});
var iter = scanner.feed(chunk1);
while (iter.next()) |token| { ... }
// later, more bytes arrive:
iter = scanner.feed(chunk2);
while (iter.next()) |token| { ... }
```

Tokens: `object_begin`, `object_end`, `array_begin`, `array_end`, `string`, `number`, `true_literal`, `false_literal`, `null_literal`, `colon`, `comma`.

Each token carries a `bytes` slice pointing into the input and a `depth` counter.

**Tiger-Style discipline:**

- **Static allocation**: Scanner state is a fixed-size struct (~128 bytes). No heap. Use a bounded stack for nesting depth:
  ```zig
  const MAX_DEPTH = 64;
  nesting_stack: [MAX_DEPTH]enum { object, array } = undefined,
  depth: u6 = 0, // u6 naturally bounded to 0..63
  ```
  `MAX_DEPTH = 64` exceeds any real LLM API payload. Exceeding it returns `error.MaxDepthExceeded`.

- **State machine with explicit transitions**: Scanner internal state is an enum. Every byte advances the state machine through validated transitions:
  ```zig
  const State = enum {
      value,           // expecting a JSON value
      object_key,      // expecting a string key or '}'
      object_colon,    // expecting ':'
      object_value,    // expecting a value after ':'
      array_elem,      // expecting a value or ']'
      string,          // inside a string
      string_escape,   // after '\' in a string
      string_unicode,  // in \uXXXX
      number,          // inside a number
      literal,         // inside true/false/null
      post_value,      // after a value, expecting ',', '}', ']', or EOF
      done,            // complete document parsed
  };
  ```
  Invalid transitions (e.g., `]` when in `object_key`) return `error.UnexpectedToken`, never UB.

- **Validate cross-constraints at comptime**:
  ```zig
  comptime {
      std.debug.assert(@sizeOf(Scanner) <= 256);
      std.debug.assert(MAX_DEPTH <= std.math.maxInt(u6) + 1);
  }
  ```

- **Determinism**: No hash maps, no sets, no iteration-order dependence. Pure function of `(state, byte) → (state, ?token)`.

- **Assert invariants**: After emitting `object_end` / `array_end`, assert `depth > 0` before decrementing. After `done`, assert `depth == 0`.

- **Fuzz target**: Feed arbitrary byte sequences. Must never crash — only return tokens or errors.

### 3. `path.zig` — Zero-Copy Path Extraction (~500 lines)

The highest-value component. Replaces the `extractDeltaContent` pattern.

```zig
// Before (20 lines, allocates):
const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
defer parsed.deinit();
// ... 15 lines of .get() / type checks ...
return try allocator.dupe(u8, content.string);

// After (1 line, zero alloc):
const content = jzon.getString(json_str, comptime jzon.path("choices[0].delta.content"));
```

API:
- `path(expr) PathExpr` — compile `"choices[0].delta.content"` (works at comptime)
- `getString(json, path) ?[]const u8` — extract string, returns slice into input
- `getRaw(json, path) ?[]const u8` — extract any value as raw JSON bytes
- `getInt(json, path) ?i64`
- `getBool(json, path) ?bool`

Implementation: uses Scanner internally, skips non-matching subtrees by depth counting.

**Tiger-Style discipline:**

- **Bounded path segments**: `PathExpr` is stored inline, no heap:
  ```zig
  const MAX_SEGMENTS = 8;
  const PathExpr = struct {
      segments: [MAX_SEGMENTS]Segment = undefined,
      len: u4 = 0, // u4 naturally bounded to 0..15, MAX_SEGMENTS=8 fits

      const Segment = union(enum) {
          key: []const u8,   // .field_name
          index: u32,        // [0], [1], ...
      };
  };
  ```
  Comptime: `path()` is `comptime` — a path expression that exceeds 8 segments is a compile error, not a runtime error.

- **Validate at comptime**: `path("choices[0].delta.content")` is parsed at compile time. Malformed expressions (unmatched `[`, non-numeric index) are compile errors:
  ```zig
  pub fn path(comptime expr: []const u8) PathExpr {
      comptime {
          var result = PathExpr{};
          // parse... if anything is wrong:
          @compileError("invalid path expression: " ++ expr);
          return result;
      }
  }
  ```

- **Zero allocation**: `getString` returns `?[]const u8` — a slice into the input. The caller never needs to free anything. `getInt` and `getBool` return values, not pointers.

- **Subtree skipping by depth**: When a path segment doesn't match, skip the entire subtree by counting depth until it returns to the entry depth. This is O(bytes) but never allocates and stops early on match.

- **Error separation**: Malformed JSON → returns `null` (the field simply wasn't found in valid structure). This is a deliberate choice: path extraction is a query, not validation. The caller handles `null` with normal control flow (`orelse`, `if`).

### 4. `writer.zig` — JSON Builder (~400 lines)

Generic over any writer type (buffer, file, socket).

```zig
var buf: std.ArrayListUnmanaged(u8) = .empty;
var obj = jzon.objectBuf(&buf, allocator);
try obj.string("model", "claude-sonnet-4");
var msgs = try obj.beginArray("messages");
  var msg = try msgs.beginObjectElem();
  try msg.string("role", "user");
  try msg.string("content", prompt);
  try msg.end();
try msgs.end();
try obj.boolean("stream", true);
try obj.raw("tools", prebuilt_tools_json);  // pass-through without re-parse
try obj.end();
```

Handles commas, escaping, nesting automatically. The `raw()` method embeds pre-serialized JSON (like tool parameter schemas).

**Tiger-Style discipline:**

- **Make invalid states unrepresentable**: The writer uses a typestate-like pattern where `beginArray` returns an `ArrayWriter` and `beginObject` returns an `ObjectWriter`. You can't call `.string(key, val)` on an `ArrayWriter` (wrong method) or `.end()` on the wrong nesting level (tracked by depth).

- **Bounded nesting depth**: Track nesting with a fixed-size stack, same `MAX_DEPTH = 64` as Scanner:
  ```zig
  const MAX_DEPTH = 64;
  nesting_stack: [MAX_DEPTH]enum { object, array } = undefined,
  depth: u6 = 0,
  ```
  Exceeding depth returns `error.MaxDepthExceeded`.

- **Assert API contract**: Calling `.end()` when `depth == 0` is a programmer bug → assertion failure. Calling `.string()` after `.end()` on a completed writer is a programmer bug → assertion failure. These are misuse of the API, not runtime conditions.

- **`raw()` is trusted but documented**: `raw()` embeds arbitrary bytes. The caller asserts it's valid JSON. This is intentional — re-parsing would defeat the purpose. Document the contract clearly.

- **Comma state machine**: Track `needs_comma: bool` per nesting level. Assert it's reset on `begin*` and set after each value. This is simple enough to be obviously correct.

### 5. `assembler.zig` — Partial JSON Assembly (~150 lines)

For tool call `partial_json` chunks (Anthropic `input_json_delta` events).

```zig
var asm = Assembler.init();
defer asm.deinit(allocator);

_ = try asm.feed(allocator, "{\"cmd\":");   // incomplete
_ = try asm.feed(allocator, "\"ls\"}");     // complete!
if (asm.isComplete()) {
    const args = asm.slice(); // "{\"cmd\":\"ls\"}"
}
```

Tracks bracket depth and string state. Reports completion when all brackets balance outside strings.

**Tiger-Style discipline:**

- **State machine with explicit states**:
  ```zig
  const State = enum {
      empty,       // no data fed yet
      incomplete,  // brackets don't balance
      complete,    // valid complete JSON document
      invalid,     // structural error detected (terminal)
  };
  ```
  `invalid` is a terminal state — once entered, all subsequent `feed()` calls return `error.AssemblerInvalid`. This prevents accumulating garbage after a structural error.

- **Bounded depth tracking**: Same principle as Scanner — track bracket/brace depth with a bounded counter:
  ```zig
  depth: u32 = 0,
  in_string: bool = false,
  escape_next: bool = false,
  ```
  If `depth` would exceed a reasonable limit (e.g., 256), transition to `invalid`.

- **Single allocation strategy**: The Assembler appends to a `std.ArrayListUnmanaged(u8)`. This is the one component that allocates, because partial chunks must be accumulated. The caller provides the allocator and calls `deinit`. The buffer grows but is never shrunk — simple, predictable.

- **Lifecycle**: `init → feed* → (complete | invalid) → deinit`. Assert `state != .invalid` on `feed`. Assert `state == .complete` on `slice()`. Calling `slice()` on an incomplete assembler is a programmer bug → assertion failure.

- **Reset for reuse**: Provide `reset()` to clear the buffer and return to `empty` state, allowing the same Assembler to be reused for the next tool call without reallocating.

## Implementation Order

1. **`escape.zig`** + tests — foundational, no deps
2. **`scanner.zig`** + tests — most complex, core dependency
3. **`path.zig`** + tests — built on scanner, highest value
4. **`writer.zig`** + tests — depends only on escape
5. **`assembler.zig`** + tests — simple state machine
6. **`root.zig`** — re-exports
7. **`build.zig` + `build.zig.zon`** — module export, test targets
8. **`test/integration_test.zig`** — real SSE payloads from OpenAI, Anthropic, Ollama

## Shared Constants and Comptime Validation

Define shared constants in a `constants.zig` or at the top of `root.zig`:

```zig
pub const MAX_DEPTH = 64;          // Scanner, Writer nesting limit
pub const MAX_PATH_SEGMENTS = 8;   // PathExpr inline capacity
pub const MAX_ASSEMBLER_DEPTH = 256; // Assembler bracket depth limit

comptime {
    // MAX_DEPTH fits in u6
    std.debug.assert(MAX_DEPTH <= std.math.maxInt(u6) + 1);
    // Path segments fit in u4
    std.debug.assert(MAX_PATH_SEGMENTS <= std.math.maxInt(u4) + 1);
    // Scanner struct stays small (cache-friendly)
    std.debug.assert(@sizeOf(Scanner) <= 256);
}
```

## Key Design Decisions

- **Zero allocations on hot path** — Scanner and path extraction never allocate. Results point into input slices.
- **No SAX callbacks** — Iterator-based API lets callers use normal control flow.
- **PathExpr max 8 segments** — LLM APIs never nest deeper than ~5. Stored inline, no heap. Enforced at comptime.
- **No JSONPath/jq syntax** — Dot-bracket (`choices[0].delta.content`) covers every real pattern. Keeps parser trivial.
- **`raw()` on writer** — Essential for embedding pre-serialized tool schemas without round-tripping through parse/serialize. Caller asserts validity.
- **Assertions for API misuse, errors for bad data** — Calling `slice()` on an incomplete Assembler is a bug (assert). Feeding malformed JSON is a runtime condition (return error).
- **Bounded everything** — Nesting depth, path segments, assembler depth all have explicit compile-time limits. Exceeding them returns typed errors, never UB.

## Testing Strategy

### Unit Tests (per module)

Standard edge cases plus Tiger-Style invariant checks:

- **Roundtrip properties**: `unescape(escape(s)) == s` for all valid strings
- **Scanner idempotence**: Feeding the same bytes as one chunk vs. split at every byte boundary must produce identical token sequences
- **Path extraction correctness**: Extract from known payloads, verify against expected values
- **Writer well-formedness**: Output of every Writer operation must parse with `std.json.parseFromSlice`

### Fuzz Tests

Every component that accepts external input gets a fuzz target:

- `escape.zig`: Arbitrary bytes to `unescape` — must return result or error, never crash
- `scanner.zig`: Arbitrary bytes to `feed` — must return tokens or errors, never crash, depth never negative
- `assembler.zig`: Arbitrary byte sequences split at random points to `feed` — must not crash, `isComplete()` must be consistent with bracket depth
- `path.zig`: Arbitrary bytes as JSON input to `getString` — must return `?[]const u8` or `null`, never crash

### Integration Tests

Real SSE payloads captured from:
- OpenAI `choices[0].delta.content` streaming
- Anthropic `content_block_delta` with `text_delta` and `input_json_delta`
- Tool call argument assembly from partial chunks
- Error response extraction (`error.message` paths)
- Request body round-trip: build with writer, validate with `std.json.parseFromSlice`

## Verification

```bash
cd ~/code/jzon
zig build test --summary all       # all unit + integration + fuzz tests pass
zig build -Doptimize=ReleaseSmall  # verify minimal binary contribution
```
