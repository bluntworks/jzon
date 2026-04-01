# jzon — Design Rationale

## Origin

This library emerged from analyzing the JSON handling in nullclaw (a Zig 0.15.2 LLM runtime with 23+ AI providers) and asking: what would a purpose-built JSON library look like for apps that orchestrate LLM, image, video, and 3D generation APIs?

The target workload is an **orchestration harness** — an app that coordinates multiple AI inference servers over HTTP. It doesn't run models directly. It sends requests, parses streaming responses, detects tool calls, and chains outputs between systems.

## The Workload

The hot loop looks like this:

```
App ←—SSE—→ LLM inference server     (streaming JSON, tool call detection)
 ↓  (parsed tool calls trigger next stage)
App ←—HTTP—→ Image/Video/3D server    (request/response JSON)
 ↓  (results fed back into LLM context)
App ←—SSE—→ LLM again                (streaming JSON)
```

The LLM legs use Server-Sent Events (SSE) — a stream of `data: {JSON}\n\n` lines, each containing a small JSON object (~100-300 bytes) with an incremental text token or tool call fragment. A single conversation can involve hundreds or thousands of these lines.

The image/video/3D legs are standard request-response. JSON parsing there is straightforward and infrequent.

## Why Not std.json

Zig's standard library JSON works. Nullclaw ships with it. But it has specific costs for this workload:

### Problem 1: Allocation-per-line on the SSE hot path

Every SSE line gets this treatment (from nullclaw `src/providers/sse.zig:204-224`):

```zig
pub fn extractDeltaContent(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const choices = obj.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    const first = choices.array.items[0];
    if (first != .object) return null;
    const delta = first.object.get("delta") orelse return null;
    if (delta != .object) return null;
    const content = delta.object.get("content") orelse return null;
    if (content != .string) return null;
    if (content.string.len == 0) return null;
    return try allocator.dupe(u8, content.string);
}
```

`parseFromSlice(Value)` builds a tree of `std.json.ObjectMap` (hash maps) and `std.json.Array` nodes. For a ~200 byte SSE payload, it allocates multiple hash map buckets, string slices, and array buffers — only to extract a single 5-50 byte string, then frees everything.

This happens for every token the LLM generates. In a long conversation with tool use, that's thousands of allocate-parse-extract-free cycles on data that's already sitting in a contiguous buffer.

**jzon's solution: zero-copy path extraction.** The `path.getString()` function scans the JSON bytes directly using a streaming tokenizer, matching path segments by depth counting. When the target field is found, it returns a slice pointing into the input. No tree, no hash maps, no allocation, no freeing.

### Problem 2: Tool call fragments are dropped

LLM providers (especially Anthropic) stream tool call arguments as partial JSON fragments across multiple SSE events:

```
event: content_block_delta
data: {"type":"input_json_delta","partial_json":"{\"cmd\":"}

event: content_block_delta
data: {"type":"input_json_delta","partial_json":"\"ls\"}"}
```

The complete tool call arguments are `{"cmd":"ls"}`, but they arrive in pieces. Nullclaw's current code (`src/providers/sse.zig` `extractAnthropicDelta`) explicitly returns null for `input_json_delta` types — the fragments are silently discarded. Tool calls only work via the non-streaming response path.

This means the orchestrator can't detect tool calls mid-stream. It has to wait for the entire LLM response to complete before knowing what to do next. For an orchestration harness chaining multiple systems, this latency compounds.

**jzon's solution: the Assembler.** A lightweight state machine that accepts partial JSON chunks, tracks bracket/brace depth and string state, and reports when the accumulated buffer forms a complete JSON document. The caller feeds each `partial_json` chunk as it arrives from SSE and gets notified the moment the arguments are complete — potentially seconds before the LLM finishes its text response.

### Problem 3: Request building is manual string surgery

Every provider in nullclaw builds JSON request bodies by manual buffer concatenation (from `src/json_util.zig` and scattered across provider files):

```zig
try buf.appendSlice(allocator, "{\"model\":\"");
try json_util.appendJsonString(&buf, allocator, model_name);
try buf.appendSlice(allocator, "\",\"messages\":[");
// ... dozens more lines of manual JSON construction
```

This works but is error-prone — missing commas, unescaped strings, and mismatched brackets are easy bugs that only surface at runtime. The 10+ duplicated `appendJsonString` implementations across the codebase (before `json_util.zig` consolidated them) are evidence of the friction.

**jzon's solution: typed ObjectWriter/ArrayWriter.** A builder that handles comma insertion, string escaping, and nesting automatically. The `raw()` method is critical — tool parameter schemas are already JSON strings, and the builder can embed them directly without a parse-serialize round trip.

## Why Not Existing Libraries

### zimdjson (simdjson port)
SIMD-accelerated parsing at gigabytes/second. But SSE payloads are ~200 bytes each. The setup cost of SIMD state initialization likely exceeds the parse time. Also read-only — doesn't help with request building. And it's a significant binary size addition for a library that would mostly parse tiny documents.

### getty (serialization framework)
Solves the ergonomics of struct serialization/deserialization but doesn't address streaming, partial assembly, or zero-copy path extraction. It's a different tool for a different problem (mapping JSON to/from Zig types at rest, not processing a stream of small JSON documents).

### std.json Scanner
Zig's stdlib does have a low-level `Scanner` API. But it's designed to feed into `parseFromSlice`/`parseFromTokenSource` — the high-level APIs that build the full value tree. Using it directly for path extraction is possible but requires the caller to implement their own depth tracking, path matching, and subtree skipping. That's exactly what jzon's `path.zig` encapsulates.

## Scope Discipline

jzon deliberately does NOT include:

- **Full document parsing into a tree** — use `std.json` for that, it works fine
- **Schema validation** — out of scope, the harness knows what types it expects
- **JSONPath/jq query language** — dot-bracket paths cover every real LLM API pattern
- **SIMD optimization** — payloads are too small to benefit
- **Config file parsing** — one-shot at startup, `std.json` handles this perfectly
- **Provider-specific logic** — jzon is a JSON tool, not an LLM client library

The library should be ~3-5K lines of Zig. Five source files. Zero dependencies beyond `std`. If it grows beyond that, something has gone wrong with scope.

## Performance Characteristics

| Operation | std.json | jzon | Why |
|-----------|----------|------|-----|
| Extract one field from 200-byte SSE payload | ~15 allocations (tree + string dupe) | 0 allocations (slice into input) | No tree construction |
| Parse 1000 SSE lines in a conversation | ~15,000 alloc/free cycles | 0 alloc/free cycles for extraction | Tokenizer is stack-only |
| Detect tool call completion | Not possible during streaming | Immediate on bracket balance | Assembler tracks state across chunks |
| Build request body with 5 tools | Manual string concat, ~20 lines | Builder API, ~10 lines | Automatic commas/escaping |

## Relationship to Nullclaw

jzon is designed to be usable by nullclaw but is not coupled to it. The integration path would be:

1. Add jzon as a `build.zig.zon` dependency
2. Replace `extractDeltaContent` calls with `jzon.getString(data, comptime jzon.path("choices[0].delta.content"))`
3. Replace `extractAnthropicDelta` with the same pattern using `jzon.path("delta.text")`
4. Add `Assembler` to the Anthropic SSE handler to capture `input_json_delta` chunks
5. Optionally migrate request building to `ObjectWriter` (lower priority, existing code works)

Steps 2-3 alone would eliminate the most frequent allocations in the streaming path.
