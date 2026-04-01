# jzon — Implementation Plan

## Context

LLM orchestration apps in Zig (like nullclaw) use `std.json` for parsing SSE streaming responses, extracting fields, and building API requests. This works but has concrete pain points:

1. **Full tree parse per SSE line** — `std.json.parseFromSlice(Value)` allocates a hash map tree to extract one string field, then frees it all. Happens hundreds of times per conversation.
2. **No partial JSON assembly** — Tool call arguments arrive as fragments (`partial_json` chunks). No way to incrementally assemble and detect completion. Currently dropped entirely.
3. **Request building by string concatenation** — Manual `buf.appendSlice("\"model\":\"")` across every provider. Error-prone, no automatic escaping/commas.

jzon is a zero-dependency Zig 0.15.2 library that solves exactly these three problems. Nothing more.

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

### 2. `scanner.zig` — Streaming Tokenizer (~800-1000 lines)

State machine that accepts byte slices incrementally and emits tokens. **Zero allocations.** ~128 bytes of state on the stack.

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

### 4. `assembler.zig` — Partial JSON Assembly (~150 lines)

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

### 5. `writer.zig` — JSON Builder (~400 lines)

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

## Implementation Order

1. **`escape.zig`** + tests — foundational, no deps
2. **`scanner.zig`** + tests — most complex, core dependency
3. **`path.zig`** + tests — built on scanner, highest value
4. **`writer.zig`** + tests — depends only on escape
5. **`assembler.zig`** + tests — simple state machine
6. **`root.zig`** — re-exports
7. **`build.zig` + `build.zig.zon`** — module export, test targets
8. **`test/integration_test.zig`** — real SSE payloads from OpenAI, Anthropic, Ollama

## Key Design Decisions

- **Zero allocations on hot path** — Scanner and path extraction never allocate. Results point into input slices.
- **No SAX callbacks** — Iterator-based API lets callers use normal control flow.
- **PathExpr max 8 segments** — LLM APIs never nest deeper than ~5. Stored inline, no heap.
- **No JSONPath/jq syntax** — Dot-bracket (`choices[0].delta.content`) covers every real pattern. Keeps parser trivial.
- **`raw()` on writer** — Essential for embedding pre-serialized tool schemas without round-tripping through parse/serialize.

## Verification

```bash
cd ~/code/jzon
zig build test --summary all       # all unit + integration tests pass
zig build -Doptimize=ReleaseSmall  # verify minimal binary contribution
```

Integration tests use captured SSE payloads from:
- OpenAI `choices[0].delta.content` streaming
- Anthropic `content_block_delta` with `text_delta` and `input_json_delta`
- Tool call argument assembly from partial chunks
- Error response extraction (`error.message` paths)
- Request body round-trip: build with writer, validate with `std.json.parseFromSlice`
