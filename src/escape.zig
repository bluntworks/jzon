const std = @import("std");

/// Writes RFC 8259 JSON-escaped version of `input` to `writer`.
pub fn escape(writer: anytype, input: []const u8) @TypeOf(writer).Error!void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                try writer.writeAll("\\u00");
                const hex = "0123456789abcdef";
                try writer.writeByte(hex[c >> 4]);
                try writer.writeByte(hex[c & 0x0F]);
            },
            else => try writer.writeByte(c),
        }
    }
}

/// Returns true if `s` contains any JSON escape sequences (backslash).
pub fn needsUnescape(s: []const u8) bool {
    for (s) |c| {
        if (c == '\\') return true;
    }
    return false;
}

pub const UnescapeResult = union(enum) {
    /// Input had no escapes — this slice points into the original input (zero-copy).
    clean: []const u8,
    /// Input had escapes — result is in the scratch buffer.
    allocated: []const u8,
};

pub const UnescapeError = error{
    InvalidEscape,
    ScratchBufferTooSmall,
    InvalidUnicodeEscape,
};

/// Unescapes a JSON string value. If no escapes are present, returns a slice
/// into `input` (zero-copy). Otherwise writes unescaped bytes into `scratch`.
pub fn unescape(input: []const u8, scratch: []u8) UnescapeError!UnescapeResult {
    if (!needsUnescape(input)) return .{ .clean = input };

    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '\\') {
            if (out >= scratch.len) return error.ScratchBufferTooSmall;
            scratch[out] = input[i];
            out += 1;
            i += 1;
            continue;
        }
        // Escape sequence
        i += 1; // skip backslash
        if (i >= input.len) return error.InvalidEscape;
        const escaped = input[i];
        i += 1;
        const replacement: u8 = switch (escaped) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'b' => 0x08,
            'f' => 0x0C,
            'u' => {
                // \uXXXX — decode hex codepoint
                if (i + 4 > input.len) return error.InvalidUnicodeEscape;
                const hex = input[i..][0..4];
                i += 4;
                const codepoint = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidUnicodeEscape;
                // Check for surrogate pair
                if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                    // High surrogate — expect \uXXXX low surrogate
                    if (i + 6 > input.len or input[i] != '\\' or input[i + 1] != 'u')
                        return error.InvalidUnicodeEscape;
                    i += 2;
                    const low_hex = input[i..][0..4];
                    i += 4;
                    const low = std.fmt.parseInt(u21, low_hex, 16) catch return error.InvalidUnicodeEscape;
                    if (low < 0xDC00 or low > 0xDFFF) return error.InvalidUnicodeEscape;
                    const combined: u21 = 0x10000 + (@as(u21, codepoint - 0xD800) << 10) + (low - 0xDC00);
                    const len = std.unicode.utf8Encode(combined, scratch[out..]) catch return error.ScratchBufferTooSmall;
                    out += len;
                    continue;
                } else if (codepoint >= 0xDC00 and codepoint <= 0xDFFF) {
                    return error.InvalidUnicodeEscape;
                }
                const len = std.unicode.utf8Encode(codepoint, scratch[out..]) catch return error.ScratchBufferTooSmall;
                out += len;
                continue;
            },
            else => return error.InvalidEscape,
        };
        if (out >= scratch.len) return error.ScratchBufferTooSmall;
        scratch[out] = replacement;
        out += 1;
    }
    return .{ .allocated = scratch[0..out] };
}

test "needsUnescape returns false for plain string" {
    try std.testing.expect(!needsUnescape("hello world"));
}

test "needsUnescape returns true for string with backslash" {
    try std.testing.expect(needsUnescape("hello\\nworld"));
}

test "unescape returns original slice when no escapes present" {
    const input = "hello world";
    var scratch: [64]u8 = undefined;
    const result = try unescape(input, &scratch);
    try std.testing.expectEqual(UnescapeResult{ .clean = input }, result);
}

test "unescape decodes basic escape sequences" {
    const input = "hello\\nworld\\t!";
    var scratch: [64]u8 = undefined;
    const result = try unescape(input, &scratch);
    switch (result) {
        .allocated => |s| try std.testing.expectEqualStrings("hello\nworld\t!", s),
        .clean => return error.TestExpectedEqual,
    }
}

test "escape encodes quotes backslashes and control chars" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try escape(fbs.writer(), "say \"hello\"\nnew\\line");
    try std.testing.expectEqualStrings("say \\\"hello\\\"\\nnew\\\\line", fbs.getWritten());
}

test "escape passes through plain ASCII unchanged" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try escape(fbs.writer(), "hello world");
    try std.testing.expectEqualStrings("hello world", fbs.getWritten());
}

// --- HARDEN: boundary and error tests ---

test "unescape returns error for truncated escape at end" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidEscape, unescape("hello\\", &scratch));
}

test "unescape returns error for invalid escape character" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidEscape, unescape("hello\\x", &scratch));
}

test "unescape returns error for truncated unicode escape" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidUnicodeEscape, unescape("\\u00", &scratch));
}

test "unescape returns error for lone low surrogate" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidUnicodeEscape, unescape("\\uDC00", &scratch));
}

test "unescape returns ScratchBufferTooSmall for tiny buffer" {
    var scratch: [2]u8 = undefined;
    try std.testing.expectError(error.ScratchBufferTooSmall, unescape("\\n\\n\\n", &scratch));
}

test "unescape decodes unicode BMP codepoint" {
    var scratch: [64]u8 = undefined;
    const result = try unescape("\\u0041", &scratch);
    switch (result) {
        .allocated => |s| try std.testing.expectEqualStrings("A", s),
        .clean => return error.TestExpectedEqual,
    }
}

test "unescape decodes surrogate pair" {
    var scratch: [64]u8 = undefined;
    // U+1F600 (grinning face) = \uD83D\uDE00
    const result = try unescape("\\uD83D\\uDE00", &scratch);
    switch (result) {
        .allocated => |s| try std.testing.expectEqualStrings("\u{1F600}", s),
        .clean => return error.TestExpectedEqual,
    }
}

test "unescape handles empty input" {
    var scratch: [64]u8 = undefined;
    const result = try unescape("", &scratch);
    switch (result) {
        .clean => |s| try std.testing.expectEqualStrings("", s),
        .allocated => return error.TestExpectedEqual,
    }
}

test "escape roundtrip preserves string" {
    const cases = [_][]const u8{ "hello", "line\nnewline", "tab\there", "quote\"inside", "", "back\\slash" };
    for (cases) |input| {
        var escaped_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&escaped_buf);
        try escape(fbs.writer(), input);
        const escaped = fbs.getWritten();

        var scratch: [256]u8 = undefined;
        const result = try unescape(escaped, &scratch);
        const unescaped = switch (result) {
            .clean => |s| s,
            .allocated => |s| s,
        };
        try std.testing.expectEqualStrings(input, unescaped);
    }
}

// --- Fuzz tests ---

test "fuzz unescape never crashes on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, input: []const u8) anyerror!void {
            var scratch: [4096]u8 = undefined;
            _ = unescape(input, &scratch) catch {};
        }
    }.f, .{});
}

test "fuzz escape then unescape roundtrips without crashing" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, input: []const u8) anyerror!void {
            // Escape arbitrary bytes (escape accepts any []const u8)
            var escaped_buf: [16384]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&escaped_buf);
            escape(fbs.writer(), input) catch return; // buffer too small is fine
            const escaped = fbs.getWritten();

            // Unescape must roundtrip back to original
            var scratch: [4096]u8 = undefined;
            const result = unescape(escaped, &scratch) catch return;
            const unescaped = switch (result) {
                .clean => |s| s,
                .allocated => |s| s,
            };
            // The roundtrip must produce the original input
            if (!std.mem.eql(u8, input, unescaped)) {
                return error.RoundtripMismatch;
            }
        }
    }.f, .{});
}
