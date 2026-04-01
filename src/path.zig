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
            const token = (self.scanner.next(json, &self.pos) catch return) orelse return;
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
