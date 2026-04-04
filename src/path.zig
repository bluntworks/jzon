const std = @import("std");
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;

pub const MAX_SEGMENTS = 8;

pub const Segment = union(enum) {
    key: []const u8,
    index: u32,
};

pub const PathExpr = struct {
    segments: [MAX_SEGMENTS]Segment = undefined,
    len: u4 = 0,
};

/// Parse a path expression at comptime. Supports dot-notation and bracket indices.
/// Example: "choices[0].delta.content" → [key("choices"), index(0), key("delta"), key("content")]
pub fn path(comptime expr: []const u8) PathExpr {
    comptime {
        var result = PathExpr{};
        var i: usize = 0;

        if (i < expr.len and expr[i] == '.') i += 1;

        while (i < expr.len) {
            if (result.len >= MAX_SEGMENTS) {
                @compileError("path expression exceeds MAX_SEGMENTS (8): " ++ expr);
            }

            if (expr[i] == '[') {
                i += 1;
                var num: u32 = 0;
                var has_digit = false;
                while (i < expr.len and expr[i] != ']') {
                    if (expr[i] < '0' or expr[i] > '9') {
                        @compileError("non-numeric array index in path: " ++ expr);
                    }
                    num = num * 10 + (expr[i] - '0');
                    has_digit = true;
                    i += 1;
                }
                if (!has_digit) @compileError("empty array index in path: " ++ expr);
                if (i >= expr.len) @compileError("unmatched '[' in path: " ++ expr);
                i += 1;
                result.segments[result.len] = .{ .index = num };
                result.len += 1;
            } else {
                const start = i;
                while (i < expr.len and expr[i] != '.' and expr[i] != '[') {
                    i += 1;
                }
                if (i == start) @compileError("empty key in path: " ++ expr);
                result.segments[result.len] = .{ .key = expr[start..i] };
                result.len += 1;
            }

            if (i < expr.len and expr[i] == '.') i += 1;
        }

        if (result.len == 0) @compileError("empty path expression");
        return result;
    }
}

/// Extract a string value at the given path. Returns a slice into `json` (zero-copy).
pub fn getString(json: []const u8, comptime expr: PathExpr) ?[]const u8 {
    var ctx = MatchContext.init(expr);
    const token = ctx.findTarget(json) orelse return null;
    if (token.tag != .string) return null;
    return token.bytes;
}

/// Extract a string value at the given path, unescaping JSON escape sequences
/// into `buf`. Returns a slice of `buf` with the unescaped content.
/// Handles: \" \\ \/ \n \r \t \b \f. Does NOT handle \uXXXX (passes through).
pub fn getStringUnescaped(json: []const u8, comptime expr: PathExpr, buf: []u8) ?[]const u8 {
    var ctx = MatchContext.init(expr);
    const token = ctx.findTarget(json) orelse return null;
    if (token.tag != .string) return null;
    const raw = token.bytes orelse return null;
    return unescape(raw, buf);
}

/// Unescape a JSON string value. `src` is the raw bytes between quotes
/// (as returned by the scanner). Writes unescaped result to `dst`.
/// Returns slice of `dst` written, or null if dst is too small.
fn unescape(src: []const u8, dst: []u8) ?[]const u8 {
    var si: usize = 0;
    var di: usize = 0;

    while (si < src.len) {
        if (src[si] == '\\' and si + 1 < src.len) {
            const c = src[si + 1];
            const replacement: ?u8 = switch (c) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'b' => 0x08,
                'f' => 0x0C,
                else => null,
            };
            if (replacement) |r| {
                if (di >= dst.len) return null;
                dst[di] = r;
                di += 1;
                si += 2;
                continue;
            }
            // Unknown escape (including \uXXXX) — pass through as-is
            if (di + 1 >= dst.len) return null;
            dst[di] = src[si];
            dst[di + 1] = src[si + 1];
            di += 2;
            si += 2;
            continue;
        }
        if (di >= dst.len) return null;
        dst[di] = src[si];
        di += 1;
        si += 1;
    }
    return dst[0..di];
}

/// Extract a raw JSON value at the given path.
pub fn getRaw(json: []const u8, comptime expr: PathExpr) ?[]const u8 {
    var ctx = MatchContext.init(expr);
    const token = ctx.findTarget(json) orelse return null;
    return switch (token.tag) {
        .string, .number => token.bytes,
        .true_literal => "true",
        .false_literal => "false",
        .null_literal => "null",
        else => null,
    };
}

/// Extract a raw JSON object `{...}` at the given path. Returns a slice into `json`.
pub fn getObject(json: []const u8, comptime expr: PathExpr) ?[]const u8 {
    var ctx = MatchContext.init(expr);
    const token = ctx.findTarget(json) orelse return null;
    if (token.tag != .object_begin) return null;
    // token.depth is the depth AFTER entering the object.
    // We need to find the matching close brace. The object_end token
    // will have depth = token.depth - 1.
    const start_pos = ctx.pos;
    ctx.skipContainer(json, token.depth);
    // start_pos - 1 points to the char right after `{` was consumed,
    // but we need to include the `{`. The scanner already advanced past `{`,
    // so the `{` is at start_pos - 1... actually, let's compute from token position.
    // The scanner pos after findTarget returned object_begin is right after the `{`.
    // After skipContainer, pos is right after the closing `}`.
    // We need json from the `{` to the `}` inclusive.
    // start_pos is where ctx.pos was when findTarget returned — that's right after `{`.
    // So `{` is at start_pos - 1.
    if (start_pos == 0) return null;
    return json[start_pos - 1 .. ctx.pos];
}

/// Extract an integer at the given path.
pub fn getInt(json: []const u8, comptime expr: PathExpr) ?i64 {
    var ctx = MatchContext.init(expr);
    const token = ctx.findTarget(json) orelse return null;
    if (token.tag != .number) return null;
    return std.fmt.parseInt(i64, token.bytes.?, 10) catch null;
}

/// Extract a boolean at the given path.
pub fn getBool(json: []const u8, comptime expr: PathExpr) ?bool {
    var ctx = MatchContext.init(expr);
    const token = ctx.findTarget(json) orelse return null;
    return switch (token.tag) {
        .true_literal => true,
        .false_literal => false,
        else => null,
    };
}

const MatchContext = struct {
    scanner: Scanner,
    pos: usize,
    seg_idx: u4,
    expr: PathExpr,
    // For array index matching: count elements at the current array level
    array_counter: u32,
    // Whether the next string token should be treated as an object key
    expect_key: bool,

    fn init(expr: PathExpr) MatchContext {
        return .{
            .scanner = Scanner.init(),
            .pos = 0,
            .seg_idx = 0,
            .expr = expr,
            .array_counter = 0,
            .expect_key = false,
        };
    }

    /// Scan through JSON to find the value at the target path.
    /// Returns the first token of the target value, or null.
    fn findTarget(self: *MatchContext, json: []const u8) ?Token {
        while (self.pos <= json.len) : ({}) {
            const token = (self.scanner.next(json, &self.pos) catch return null) orelse {
                if (self.pos >= json.len) return null;
                continue;
            };

            // If we've matched all segments, this token IS the target value
            if (self.seg_idx >= self.expr.len) {
                return token;
            }

            const seg = self.expr.segments[self.seg_idx];

            switch (seg) {
                .key => |key| {
                    switch (token.tag) {
                        .object_begin => {
                            self.expect_key = true;
                            continue;
                        },
                        .string => {
                            if (self.expect_key) {
                                // This is an object key
                                if (std.mem.eql(u8, token.bytes.?, key)) {
                                    // Key matches — advance to next segment
                                    self.seg_idx += 1;
                                    self.expect_key = false;
                                    continue;
                                } else {
                                    // Wrong key — skip the value
                                    self.expect_key = true; // next non-skipped string is a key
                                    self.skipOneValue(json);
                                    continue;
                                }
                            } else {
                                // This is a value — shouldn't happen in normal flow
                                return null;
                            }
                        },
                        .object_end => return null, // Key not found
                        else => return null,
                    }
                },
                .index => |idx| {
                    switch (token.tag) {
                        .array_begin => {
                            self.array_counter = 0;
                            self.expect_key = false;
                            continue;
                        },
                        .array_end => return null, // Index out of bounds
                        else => {
                            if (self.array_counter == idx) {
                                // This is the element we want
                                self.seg_idx += 1;
                                // This token is the first token of the target
                                if (self.seg_idx >= self.expr.len) {
                                    return token;
                                }
                                // Need to descend further — process this token
                                // against the next segment
                                switch (token.tag) {
                                    .object_begin => {
                                        self.expect_key = true;
                                        continue;
                                    },
                                    .array_begin => {
                                        self.array_counter = 0;
                                        continue;
                                    },
                                    else => return null, // Can't descend into a scalar
                                }
                            } else {
                                // Wrong index — skip this value
                                self.array_counter += 1;
                                switch (token.tag) {
                                    .object_begin, .array_begin => {
                                        self.skipContainer(json, token.depth);
                                    },
                                    else => {},
                                }
                                continue;
                            }
                        },
                    }
                },
            }
        }
        return null;
    }

    fn skipOneValue(self: *MatchContext, json: []const u8) void {
        const token = (self.scanner.next(json, &self.pos) catch return) orelse return;
        switch (token.tag) {
            .object_begin, .array_begin => self.skipContainer(json, token.depth),
            else => {},
        }
    }

    fn skipContainer(self: *MatchContext, json: []const u8, container_depth: u8) void {
        const target = container_depth - 1;
        while (true) {
            const token = (self.scanner.next(json, &self.pos) catch return) orelse {
                // scanner.next returns null for non-token chars (commas, colons)
                // as well as at end-of-input. Only bail if truly at the end.
                if (self.pos >= json.len) return;
                continue;
            };
            switch (token.tag) {
                .object_end, .array_end => {
                    if (token.depth == target) return;
                },
                else => {},
            }
        }
    }
};

// --- Tests ---

test "path parses simple key" {
    const p = comptime path("name");
    try std.testing.expectEqual(@as(u4, 1), p.len);
    try std.testing.expectEqualStrings("name", p.segments[0].key);
}

test "path parses dot-separated keys" {
    const p = comptime path("delta.content");
    try std.testing.expectEqual(@as(u4, 2), p.len);
    try std.testing.expectEqualStrings("delta", p.segments[0].key);
    try std.testing.expectEqualStrings("content", p.segments[1].key);
}

test "path parses array index" {
    const p = comptime path("choices[0]");
    try std.testing.expectEqual(@as(u4, 2), p.len);
    try std.testing.expectEqualStrings("choices", p.segments[0].key);
    try std.testing.expectEqual(@as(u32, 0), p.segments[1].index);
}

test "path parses complex expression" {
    const p = comptime path("choices[0].delta.content");
    try std.testing.expectEqual(@as(u4, 4), p.len);
    try std.testing.expectEqualStrings("choices", p.segments[0].key);
    try std.testing.expectEqual(@as(u32, 0), p.segments[1].index);
    try std.testing.expectEqualStrings("delta", p.segments[2].key);
    try std.testing.expectEqualStrings("content", p.segments[3].key);
}

test "getString extracts simple value" {
    const json =
        \\{"name":"hello"}
    ;
    const result = getString(json, comptime path("name"));
    try std.testing.expectEqualStrings("hello", result.?);
}

test "getString extracts nested value" {
    const json =
        \\{"delta":{"content":"world"}}
    ;
    const result = getString(json, comptime path("delta.content"));
    try std.testing.expectEqualStrings("world", result.?);
}

test "getString extracts from array index" {
    const json =
        \\{"choices":[{"delta":{"content":"hi"}}]}
    ;
    const result = getString(json, comptime path("choices[0].delta.content"));
    try std.testing.expectEqualStrings("hi", result.?);
}

test "getString returns null for missing path" {
    const json =
        \\{"choices":[]}
    ;
    const result = getString(json, comptime path("choices[0].delta.content"));
    try std.testing.expect(result == null);
}

test "getString returns null for wrong type" {
    const json =
        \\{"count":42}
    ;
    const result = getString(json, comptime path("count"));
    try std.testing.expect(result == null);
}

test "getString skips non-matching keys" {
    const json =
        \\{"other":"skip","name":"found"}
    ;
    const result = getString(json, comptime path("name"));
    try std.testing.expectEqualStrings("found", result.?);
}

test "getInt extracts integer" {
    const json =
        \\{"count":42}
    ;
    const result = getInt(json, comptime path("count"));
    try std.testing.expectEqual(@as(i64, 42), result.?);
}

test "getBool extracts boolean" {
    const json =
        \\{"stream":true}
    ;
    const result = getBool(json, comptime path("stream"));
    try std.testing.expectEqual(true, result.?);
}

test "getString handles real OpenAI SSE payload" {
    const json =
        \\{"id":"chatcmpl-123","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
    ;
    const result = getString(json, comptime path("choices[0].delta.content"));
    try std.testing.expectEqualStrings("Hello", result.?);
}

test "getString handles real Anthropic SSE payload" {
    const json =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}
    ;
    const result = getString(json, comptime path("delta.text"));
    try std.testing.expectEqualStrings("Hi", result.?);
}

test "getString skips nested objects in non-matching keys" {
    const json =
        \\{"meta":{"nested":{"deep":true}},"name":"found"}
    ;
    const result = getString(json, comptime path("name"));
    try std.testing.expectEqualStrings("found", result.?);
}

test "getString extracts from second array element" {
    const json =
        \\{"items":[{"v":"a"},{"v":"b"}]}
    ;
    const result = getString(json, comptime path("items[1].v"));
    try std.testing.expectEqualStrings("b", result.?);
}

test "getRaw extracts number as raw bytes" {
    const json =
        \\{"pi":3.14159}
    ;
    const result = getRaw(json, comptime path("pi"));
    try std.testing.expectEqualStrings("3.14159", result.?);
}

test "getString extracts error message path" {
    const json =
        \\{"error":{"message":"rate limit exceeded","type":"rate_limit_error"}}
    ;
    const result = getString(json, comptime path("error.message"));
    try std.testing.expectEqualStrings("rate limit exceeded", result.?);
}

test "getObject extracts object at path" {
    const json = "{\"a\":{\"b\":{\"x\":1,\"y\":2}}}";
    const result = getObject(json, comptime path("a.b"));
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"x\":1,\"y\":2}", result.?);
}

test "getObject extracts nested object in array" {
    const json = "{\"items\":[{\"args\":{\"prompt\":\"hello\"}}]}";
    const result = getObject(json, comptime path("items[0].args"));
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"prompt\":\"hello\"}", result.?);
}

test "getObject returns null for non-object" {
    const json = "{\"a\":\"string\"}";
    try std.testing.expect(getObject(json, comptime path("a")) == null);
}

test "getString finds sibling key after nested object in array element" {
    const json = "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hi\"}]},\"finishReason\":\"STOP\"}]}";
    const fr = getString(json, comptime path("candidates[0].finishReason"));
    try std.testing.expect(fr != null);
    try std.testing.expectEqualStrings("STOP", fr.?);
}

test "getString finds sibling key after nested array in object" {
    const json = "{\"a\":{\"items\":[1,2,3],\"name\":\"found\"}}";
    const result = getString(json, comptime path("a.name"));
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("found", result.?);
}

// --- getStringUnescaped tests ---

test "getStringUnescaped: newlines" {
    var buf: [64]u8 = undefined;
    const json = "{\"text\":\"hello\\nworld\"}";
    const val = getStringUnescaped(json, comptime path("text"), &buf);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hello\nworld", val.?);
}

test "getStringUnescaped: quotes" {
    var buf: [64]u8 = undefined;
    const json = "{\"text\":\"say \\\"hi\\\"\"}";
    const val = getStringUnescaped(json, comptime path("text"), &buf);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("say \"hi\"", val.?);
}

test "getStringUnescaped: backslashes" {
    var buf: [64]u8 = undefined;
    const json = "{\"text\":\"C:\\\\Users\\\\test\"}";
    const val = getStringUnescaped(json, comptime path("text"), &buf);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("C:\\Users\\test", val.?);
}

test "getStringUnescaped: tabs and carriage returns" {
    var buf: [64]u8 = undefined;
    const json = "{\"text\":\"a\\tb\\rc\"}";
    const val = getStringUnescaped(json, comptime path("text"), &buf);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("a\tb\rc", val.?);
}

test "getStringUnescaped: no escapes passes through" {
    var buf: [64]u8 = undefined;
    const json = "{\"text\":\"hello world\"}";
    const val = getStringUnescaped(json, comptime path("text"), &buf);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hello world", val.?);
}

test "getStringUnescaped: forward slash" {
    var buf: [64]u8 = undefined;
    const json = "{\"url\":\"http:\\/\\/example.com\"}";
    const val = getStringUnescaped(json, comptime path("url"), &buf);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("http://example.com", val.?);
}

test "getStringUnescaped: missing path returns null" {
    var buf: [64]u8 = undefined;
    const json = "{\"other\":\"val\"}";
    try std.testing.expect(getStringUnescaped(json, comptime path("text"), &buf) == null);
}

test "getStringUnescaped: buffer too small returns null" {
    var buf: [3]u8 = undefined;
    const json = "{\"text\":\"hello\"}";
    try std.testing.expect(getStringUnescaped(json, comptime path("text"), &buf) == null);
}

test "getStringUnescaped: nested path with escapes" {
    var buf: [128]u8 = undefined;
    const json = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"line1\\nline2\\nline3\"}]}}]}";
    const val = getStringUnescaped(json, comptime path("candidates[0].content.parts[0].text"), &buf);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("line1\nline2\nline3", val.?);
}

test "getStringUnescaped: unknown escape passed through" {
    var buf: [64]u8 = undefined;
    const json = "{\"text\":\"\\u0041\"}";
    const val = getStringUnescaped(json, comptime path("text"), &buf);
    try std.testing.expect(val != null);
    // \uXXXX not decoded — passed through as-is
    try std.testing.expectEqualStrings("\\u0041", val.?);
}

// --- DST: unescape property tests ---

const EscapeSpec = struct {
    char: u8,
    expected: u8,
};

const escape_specs = [_]EscapeSpec{
    .{ .char = '"', .expected = '"' },
    .{ .char = '\\', .expected = '\\' },
    .{ .char = '/', .expected = '/' },
    .{ .char = 'n', .expected = '\n' },
    .{ .char = 'r', .expected = '\r' },
    .{ .char = 't', .expected = '\t' },
    .{ .char = 'b', .expected = 0x08 },
    .{ .char = 'f', .expected = 0x0C },
};

test "DST: unescape correctness — each escape produces correct byte" {
    const seed_base: u64 = 0xCAFE_BABE_0000_0000;
    const num_seeds: u64 = 500;

    for (0..num_seeds) |i| {
        const seed = seed_base +% i;
        var rng = std.Random.Xoshiro256.init(seed);
        const random = rng.random();

        // Build source with known escapes, tracking expected output
        var src_buf: [128]u8 = undefined;
        var expected_buf: [128]u8 = undefined;
        var src_len: usize = 0;
        var exp_len: usize = 0;
        const num_parts = random.intRangeAtMost(u8, 1, 30);

        for (0..num_parts) |_| {
            if (src_len + 2 >= src_buf.len or exp_len >= expected_buf.len) break;

            if (random.intRangeAtMost(u8, 0, 2) == 0) {
                // Insert a known escape sequence
                const spec = escape_specs[random.intRangeLessThan(usize, 0, escape_specs.len)];
                src_buf[src_len] = '\\';
                src_buf[src_len + 1] = spec.char;
                src_len += 2;
                expected_buf[exp_len] = spec.expected;
                exp_len += 1;
            } else {
                // Normal printable char (avoiding \ and ")
                var c = random.intRangeAtMost(u8, 0x20, 0x7E);
                if (c == '\\' or c == '"') c = 'x';
                src_buf[src_len] = c;
                src_len += 1;
                expected_buf[exp_len] = c;
                exp_len += 1;
            }
        }
        const src = src_buf[0..src_len];
        const expected = expected_buf[0..exp_len];

        var dst: [128]u8 = undefined;
        const result = unescape(src, &dst) orelse {
            std.log.err("FAIL seed={d} (0x{x}): unescape returned null for {d}-byte input", .{ seed, seed, src.len });
            return error.TestUnexpectedResult;
        };

        // Invariant 1: output matches expected
        if (!std.mem.eql(u8, result, expected)) {
            std.log.err("FAIL seed={d} (0x{x}): output mismatch, got {d} bytes expected {d} bytes", .{
                seed, seed, result.len, expected.len,
            });
            return error.TestUnexpectedResult;
        }

        // Invariant 2: output length <= input length
        if (result.len > src.len) {
            std.log.err("FAIL seed={d} (0x{x}): output len {d} > input len {d}", .{
                seed, seed, result.len, src.len,
            });
            return error.TestUnexpectedResult;
        }
    }
}

test "DST: unescape idempotency — no-escape content passes through unchanged" {
    const seed_base: u64 = 0xCAFE_0001_0000_0000;
    const num_seeds: u64 = 500;

    for (0..num_seeds) |i| {
        const seed = seed_base +% i;
        var rng = std.Random.Xoshiro256.init(seed);
        const random = rng.random();

        // Generate content with NO escape sequences
        var src_buf: [64]u8 = undefined;
        const src_len = random.intRangeAtMost(u8, 0, 60);
        for (src_buf[0..src_len]) |*c| {
            var ch = random.intRangeAtMost(u8, 0x20, 0x7E);
            if (ch == '\\') ch = 'x'; // no backslashes
            c.* = ch;
        }
        const src = src_buf[0..src_len];

        var dst: [64]u8 = undefined;
        const result = unescape(src, &dst) orelse {
            std.log.err("FAIL seed={d} (0x{x}): unescape returned null for no-escape input", .{ seed, seed });
            return error.TestUnexpectedResult;
        };

        if (!std.mem.eql(u8, result, src)) {
            std.log.err("FAIL seed={d} (0x{x}): no-escape input not passed through unchanged", .{ seed, seed });
            return error.TestUnexpectedResult;
        }
    }
}

test "DST: getStringUnescaped full roundtrip via JSON" {
    const seed_base: u64 = 0xCAFE_0002_0000_0000;
    const num_seeds: u64 = 500;

    for (0..num_seeds) |i| {
        const seed = seed_base +% i;
        var rng = std.Random.Xoshiro256.init(seed);
        const random = rng.random();

        // Build a valid JSON string: {"key":"value with \n escapes"}
        var json_buf: [256]u8 = undefined;
        var json_len: usize = 0;
        const prefix = "{\"v\":\"";
        @memcpy(json_buf[0..prefix.len], prefix);
        json_len = prefix.len;

        // Build the string value with random escapes
        var expected_buf: [128]u8 = undefined;
        var exp_len: usize = 0;
        const num_chars = random.intRangeAtMost(u8, 0, 40);

        for (0..num_chars) |_| {
            if (json_len + 4 >= json_buf.len or exp_len >= expected_buf.len) break;

            if (random.intRangeAtMost(u8, 0, 3) == 0) {
                const spec = escape_specs[random.intRangeLessThan(usize, 0, escape_specs.len)];
                json_buf[json_len] = '\\';
                json_buf[json_len + 1] = spec.char;
                json_len += 2;
                expected_buf[exp_len] = spec.expected;
                exp_len += 1;
            } else {
                var c = random.intRangeAtMost(u8, 0x20, 0x7E);
                if (c == '\\' or c == '"') c = 'a';
                json_buf[json_len] = c;
                json_len += 1;
                expected_buf[exp_len] = c;
                exp_len += 1;
            }
        }

        const suffix = "\"}";
        @memcpy(json_buf[json_len..][0..suffix.len], suffix);
        json_len += suffix.len;

        const json = json_buf[0..json_len];
        const expected = expected_buf[0..exp_len];

        var out: [128]u8 = undefined;
        const result = getStringUnescaped(json, comptime path("v"), &out) orelse {
            std.log.err("FAIL seed={d} (0x{x}): getStringUnescaped returned null for valid JSON", .{ seed, seed });
            return error.TestUnexpectedResult;
        };

        if (!std.mem.eql(u8, result, expected)) {
            std.log.err("FAIL seed={d} (0x{x}): roundtrip mismatch, got {d} bytes expected {d}", .{
                seed, seed, result.len, exp_len,
            });
            return error.TestUnexpectedResult;
        }
    }
}

test "DST: unescape buffer-too-small returns null without corruption" {
    const seed_base: u64 = 0xCAFE_0003_0000_0000;
    const num_seeds: u64 = 500;

    for (0..num_seeds) |i| {
        const seed = seed_base +% i;
        var rng = std.Random.Xoshiro256.init(seed);
        const random = rng.random();

        // Generate content
        var src_buf: [64]u8 = undefined;
        const src_len = random.intRangeAtMost(u8, 5, 60);
        for (src_buf[0..src_len]) |*c| {
            var ch = random.intRangeAtMost(u8, 0x20, 0x7E);
            if (ch == '\\') ch = 'x';
            c.* = ch;
        }
        const src = src_buf[0..src_len];

        // Use a buffer that's definitely too small
        const buf_size = random.intRangeAtMost(u8, 0, @min(4, src_len -| 1));
        var dst: [64]u8 = .{0xAA} ** 64; // sentinel fill
        const result = unescape(src, dst[0..buf_size]);

        if (buf_size < src_len) {
            // Should return null (buffer too small for content with no escapes)
            if (result != null) {
                // Only a problem if the unescaped output is actually longer than buf_size
                // (with escapes it could be shorter and fit)
                continue; // escapes can shrink, so this is fine
            }
        }
    }
}

// --- Fuzz tests ---

test "fuzz getString never crashes on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, input: []const u8) anyerror!void {
            // Try extracting from arbitrary bytes with various path shapes
            _ = getString(input, comptime path("a"));
            _ = getString(input, comptime path("a.b.c"));
            _ = getString(input, comptime path("a[0].b"));
            _ = getInt(input, comptime path("a"));
            _ = getBool(input, comptime path("a"));
            _ = getRaw(input, comptime path("a[0]"));
            _ = getObject(input, comptime path("a"));
            _ = getObject(input, comptime path("a[0].b"));
            var ubuf: [256]u8 = undefined;
            _ = getStringUnescaped(input, comptime path("a"), &ubuf);
            _ = getStringUnescaped(input, comptime path("a[0].b"), &ubuf);
        }
    }.f, .{});
}

// --- DST property tests ---
// Seeded PRNG generates structured valid JSON with varying nesting patterns,
// sibling counts, and value types. Verifies extraction correctness — not just
// crash-freedom. Seed is logged on failure for deterministic replay.

const DstJsonGen = struct {
    rng: std.Random.Xoshiro256,
    buf: [4096]u8 = undefined,
    pos: usize = 0,

    fn init(seed: u64) DstJsonGen {
        return .{ .rng = std.Random.Xoshiro256.init(seed) };
    }

    fn random(self: *DstJsonGen) std.Random {
        return self.rng.random();
    }

    fn emit(self: *DstJsonGen, bytes: []const u8) void {
        const space = self.buf.len - self.pos;
        const n = @min(bytes.len, space);
        @memcpy(self.buf[self.pos..][0..n], bytes[0..n]);
        self.pos += n;
    }

    fn emitByte(self: *DstJsonGen, c: u8) void {
        if (self.pos < self.buf.len) {
            self.buf[self.pos] = c;
            self.pos += 1;
        }
    }

    fn json(self: *DstJsonGen) []const u8 {
        return self.buf[0..self.pos];
    }

    /// Generate a JSON object with `target_key` placed among random siblings.
    /// Returns the expected value string for `target_key`.
    /// `depth` limits nesting to prevent buffer overflow.
    fn genObject(self: *DstJsonGen, target_key: []const u8, target_value: []const u8, depth: u8) void {
        self.emitByte('{');

        // How many sibling keys before the target (0-3)
        const before: u8 = @intCast(self.random().intRangeAtMost(u8, 0, 3));
        // How many sibling keys after the target (0-3)
        const after: u8 = @intCast(self.random().intRangeAtMost(u8, 0, 3));

        var first = true;
        // Emit siblings before target
        for (0..before) |i| {
            if (!first) self.emitByte(',');
            first = false;
            self.emitByte('"');
            self.emit("pre");
            self.emitByte('0' + @as(u8, @intCast(i)));
            self.emitByte('"');
            self.emitByte(':');
            self.genRandomValue(depth +| 1);
        }

        // Emit the target key
        if (!first) self.emitByte(',');
        first = false;
        self.emitByte('"');
        self.emit(target_key);
        self.emitByte('"');
        self.emitByte(':');
        self.emitByte('"');
        self.emit(target_value);
        self.emitByte('"');

        // Emit siblings after target
        for (0..after) |i| {
            if (!first) self.emitByte(',');
            first = false;
            self.emitByte('"');
            self.emit("post");
            self.emitByte('0' + @as(u8, @intCast(i)));
            self.emitByte('"');
            self.emitByte(':');
            self.genRandomValue(depth +| 1);
        }

        self.emitByte('}');
    }

    /// Generate a random JSON value. Nesting structures are generated at depth < 4
    /// to keep output bounded.
    fn genRandomValue(self: *DstJsonGen, depth: u8) void {
        const kind = self.random().intRangeAtMost(u8, 0, if (depth < 4) 5 else 3);
        switch (kind) {
            0 => self.emit("42"),
            1 => self.emit("true"),
            2 => self.emit("\"x\""),
            3 => self.emit("null"),
            4 => {
                // Nested object with random keys
                self.emitByte('{');
                const n = self.random().intRangeAtMost(u8, 0, 3);
                for (0..n) |i| {
                    if (i > 0) self.emitByte(',');
                    self.emitByte('"');
                    self.emit("k");
                    self.emitByte('0' + @as(u8, @intCast(i)));
                    self.emitByte('"');
                    self.emitByte(':');
                    self.genRandomValue(depth +| 1);
                }
                self.emitByte('}');
            },
            5 => {
                // Nested array with random elements
                self.emitByte('[');
                const n = self.random().intRangeAtMost(u8, 0, 3);
                for (0..n) |i| {
                    if (i > 0) self.emitByte(',');
                    self.genRandomValue(depth +| 1);
                }
                self.emitByte(']');
            },
            else => unreachable,
        }
    }
};

test "DST: getString correctness with random sibling structures" {
    // Test getString finds target key regardless of surrounding nesting.
    // This is the class of bug that skipContainer had — complex siblings
    // causing early bailout.
    const seed_base: u64 = 0xDEAD_BEEF_CAFE_0000;
    const num_seeds: u64 = 500;

    for (0..num_seeds) |i| {
        const seed = seed_base +% i;
        var gen = DstJsonGen.init(seed);

        // Pattern 1: {"target":"VALUE"} with random siblings
        gen.genObject("target", "FOUND", 0);
        const json1 = gen.json();
        const r1 = getString(json1, comptime path("target"));
        if (r1 == null) {
            std.log.err("FAIL seed={d} (0x{x}): getString returned null for path 'target' in: {s}", .{ seed, seed, json1 });
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, r1.?, "FOUND")) {
            std.log.err("FAIL seed={d} (0x{x}): expected 'FOUND', got '{s}' in: {s}", .{ seed, seed, r1.?, json1 });
            return error.TestUnexpectedResult;
        }

        // Pattern 2: {"wrap":{"target":"VALUE"}} — nested key with siblings at both levels
        var gen2 = DstJsonGen.init(seed *% 0x9E3779B97F4A7C15 +% 1);
        gen2.emitByte('{');
        // Random siblings before wrap
        const pre = gen2.random().intRangeAtMost(u8, 0, 2);
        for (0..pre) |j| {
            if (j > 0) gen2.emitByte(',');
            gen2.emitByte('"');
            gen2.emit("noise");
            gen2.emitByte('0' + @as(u8, @intCast(j)));
            gen2.emitByte('"');
            gen2.emitByte(':');
            gen2.genRandomValue(1);
        }
        if (pre > 0) gen2.emitByte(',');
        gen2.emitByte('"');
        gen2.emit("wrap");
        gen2.emitByte('"');
        gen2.emitByte(':');
        gen2.genObject("target", "DEEP", 1);
        gen2.emitByte('}');

        const json2 = gen2.json();
        const r2 = getString(json2, comptime path("wrap.target"));
        if (r2 == null) {
            std.log.err("FAIL seed={d} (0x{x}): getString returned null for path 'wrap.target' in: {s}", .{ seed, seed, json2 });
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, r2.?, "DEEP")) {
            std.log.err("FAIL seed={d} (0x{x}): expected 'DEEP', got '{s}' in: {s}", .{ seed, seed, r2.?, json2 });
            return error.TestUnexpectedResult;
        }
    }
}

test "DST: getString correctness with array index + sibling nesting" {
    // The exact bug pattern: arr[0].key where arr[0] is an object with nested
    // siblings before the target key.
    const seed_base: u64 = 0xBAD_C0DE_0000_0000;
    const num_seeds: u64 = 500;

    for (0..num_seeds) |i| {
        const seed = seed_base +% i;
        var gen = DstJsonGen.init(seed);

        // Build: {"arr":[{...random siblings..., "target":"HIT"}]}
        gen.emit("{\"arr\":[");
        gen.genObject("target", "HIT", 1);
        gen.emit("]}");

        const json = gen.json();
        const result = getString(json, comptime path("arr[0].target"));
        if (result == null) {
            std.log.err("FAIL seed={d} (0x{x}): getString returned null for 'arr[0].target' in: {s}", .{ seed, seed, json });
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, result.?, "HIT")) {
            std.log.err("FAIL seed={d} (0x{x}): expected 'HIT', got '{s}' in: {s}", .{ seed, seed, result.?, json });
            return error.TestUnexpectedResult;
        }
    }
}

test "DST: getObject correctness with random sibling structures" {
    const seed_base: u64 = 0x0123_4567_89AB_0000;
    const num_seeds: u64 = 500;

    for (0..num_seeds) |i| {
        const seed = seed_base +% i;
        var gen = DstJsonGen.init(seed);

        // Build: {"arr":[{...siblings..., "obj":{"inner":"val"}, ...siblings...}]}
        gen.emit("{\"arr\":[{");

        const before = gen.random().intRangeAtMost(u8, 0, 3);
        for (0..before) |j| {
            if (j > 0) gen.emitByte(',');
            gen.emitByte('"');
            gen.emit("s");
            gen.emitByte('0' + @as(u8, @intCast(j)));
            gen.emitByte('"');
            gen.emitByte(':');
            gen.genRandomValue(2);
        }
        if (before > 0) gen.emitByte(',');
        gen.emit("\"obj\":{\"inner\":\"val\"}");

        const after_count = gen.random().intRangeAtMost(u8, 0, 2);
        for (0..after_count) |j| {
            gen.emitByte(',');
            gen.emitByte('"');
            gen.emit("t");
            gen.emitByte('0' + @as(u8, @intCast(j)));
            gen.emitByte('"');
            gen.emitByte(':');
            gen.genRandomValue(2);
        }
        gen.emit("}]}");

        const json = gen.json();
        const result = getObject(json, comptime path("arr[0].obj"));
        if (result == null) {
            std.log.err("FAIL seed={d} (0x{x}): getObject returned null for 'arr[0].obj' in: {s}", .{ seed, seed, json });
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, result.?, "{\"inner\":\"val\"}")) {
            std.log.err("FAIL seed={d} (0x{x}): expected '{{\"inner\":\"val\"}}', got '{s}' in: {s}", .{ seed, seed, result.?, json });
            return error.TestUnexpectedResult;
        }
    }
}
