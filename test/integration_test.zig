const std = @import("std");
const jzon = @import("jzon");

// --- OpenAI SSE payloads ---

test "OpenAI streaming delta content extraction" {
    const payloads = [_][]const u8{
        \\{"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        ,
    };

    const expected = [_]?[]const u8{ "", "Hello", " world", null };

    for (payloads, expected) |payload, exp| {
        const content = jzon.getString(payload, comptime jzon.path("choices[0].delta.content"));
        if (exp) |e| {
            try std.testing.expectEqualStrings(e, content.?);
        } else {
            try std.testing.expect(content == null);
        }
    }
}

test "OpenAI error response extraction" {
    const json =
        \\{"error":{"message":"Rate limit exceeded","type":"rate_limit_error","param":null,"code":"rate_limit_exceeded"}}
    ;
    const msg = jzon.getString(json, comptime jzon.path("error.message"));
    try std.testing.expectEqualStrings("Rate limit exceeded", msg.?);

    const err_type = jzon.getString(json, comptime jzon.path("error.type"));
    try std.testing.expectEqualStrings("rate_limit_error", err_type.?);
}

// --- Anthropic SSE payloads ---

test "Anthropic text delta extraction" {
    const json =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from Claude"}}
    ;
    const text = jzon.getString(json, comptime jzon.path("delta.text"));
    try std.testing.expectEqualStrings("Hello from Claude", text.?);
}

test "Anthropic input_json_delta assembly" {
    const chunks = [_][]const u8{
        \\{"city"
        ,
        \\: "San
        ,
        \\ Francisco",
        ,
        \\"state": "CA"}
        ,
    };

    var asmb = jzon.Assembler.init();
    defer asmb.deinit(std.testing.allocator);

    for (chunks) |chunk| {
        _ = try asmb.feed(std.testing.allocator, chunk);
    }

    try std.testing.expect(asmb.isComplete());
    // Verify the assembled JSON is valid by parsing with std.json
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        asmb.slice(),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("San Francisco", parsed.value.object.get("city").?.string);
    try std.testing.expectEqualStrings("CA", parsed.value.object.get("state").?.string);
}

test "Anthropic message_start metadata extraction" {
    const json =
        \\{"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-sonnet-4-20250514","stop_reason":null}}
    ;
    const model = jzon.getString(json, comptime jzon.path("message.model"));
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", model.?);

    const role = jzon.getString(json, comptime jzon.path("message.role"));
    try std.testing.expectEqualStrings("assistant", role.?);
}

// --- Ollama SSE payloads ---

test "Ollama streaming response extraction" {
    const json =
        \\{"model":"llama3","created_at":"2024-01-01T00:00:00Z","response":"Hi","done":false}
    ;
    const response = jzon.getString(json, comptime jzon.path("response"));
    try std.testing.expectEqualStrings("Hi", response.?);

    const done = jzon.getBool(json, comptime jzon.path("done"));
    try std.testing.expectEqual(false, done.?);
}

// --- Request building round-trip ---

test "request body round-trip: build with writer, validate with std.json" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var w = jzon.jsonWriter(fbs.writer());

    try w.beginTopObject();
    try w.string("model", "claude-sonnet-4-20250514");
    try w.integer("max_tokens", 1024);
    try w.boolean("stream", true);
    try w.beginArray("messages");
    try w.beginObjectElem();
    try w.string("role", "user");
    try w.string("content", "What is the weather in SF?");
    try w.end();
    try w.end();
    const tools_json =
        \\[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]
    ;
    try w.raw("tools", tools_json);
    try w.end();

    const result = fbs.getWritten();

    // Parse with std.json to verify well-formedness
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", obj.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 1024), obj.get("max_tokens").?.integer);
    try std.testing.expect(obj.get("stream").?.bool);

    const messages = obj.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);

    const tools = obj.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("get_weather", tools.items[0].object.get("function").?.object.get("name").?.string);
}

// --- Cross-component: extract from writer output ---

test "extract from writer output without round-trip through std.json" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var w = jzon.jsonWriter(fbs.writer());

    try w.beginTopObject();
    try w.string("status", "ok");
    try w.integer("count", 7);
    try w.end();

    const json = fbs.getWritten();

    try std.testing.expectEqualStrings("ok", jzon.getString(json, comptime jzon.path("status")).?);
    try std.testing.expectEqual(@as(i64, 7), jzon.getInt(json, comptime jzon.path("count")).?);
}
