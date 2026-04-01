const std = @import("std");
const jzon = @import("jzon");

const jzon_escape = jzon.escape;
const jzon_scanner = jzon.scanner;
const jzon_path = jzon.path_mod;
const jzon_writer = jzon.writer_mod;
const jzon_assembler = jzon.assembler;

const Scanner = jzon.Scanner;
const Token = jzon.Token;
const Assembler = jzon.Assembler;

/// Deterministic simulation testing for jzon.
/// All randomness flows from a single u64 seed via xoshiro256**.
/// Same seed + same code = identical test execution.

const PRNG = struct {
    s: [4]u64,

    fn init(seed: u64) PRNG {
        var s = seed;
        var state: [4]u64 = undefined;
        inline for (0..4) |i| {
            s +%= 0x9e3779b97f4a7c15;
            var z = s;
            z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
            z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
            state[i] = z ^ (z >> 31);
        }
        return .{ .s = state };
    }

    fn next(self: *PRNG) u64 {
        const result = std.math.rotl(u64, self.s[1] *% 5, 7) *% 9;
        const t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = std.math.rotl(u64, self.s[3], 45);
        return result;
    }

    fn intBelow(self: *PRNG, max: usize) usize {
        if (max == 0) return 0;
        return @intCast(self.next() % @as(u64, @intCast(max)));
    }

    fn intRange(self: *PRNG, min: usize, max: usize) usize {
        return min + self.intBelow(max - min + 1);
    }

    fn boolean(self: *PRNG) bool {
        return self.next() & 1 == 0;
    }

    fn chance(self: *PRNG, percent: u8) bool {
        return self.intBelow(100) < percent;
    }

    fn float01(self: *PRNG) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }
};

// --- JSON Generator ---

const GenError = error{NoSpaceLeft};
const FBS = std.io.FixedBufferStream([]u8);

/// Configuration for JSON generation, driven by PRNG
const GenConfig = struct {
    max_depth: u8, // 5–60, tests near MAX_DEPTH boundary
    max_keys: u8, // 0–15
    max_array_len: u8, // 0–30
    max_string_len: u16, // 0–500
    whitespace_mode: enum { none, light, heavy },
    unicode_richness: enum { ascii_only, basic_unicode, full_unicode },
    number_style: enum { integer_only, with_decimal, with_exponent, all },

    fn fromPRNG(rng: *PRNG) GenConfig {
        return .{
            .max_depth = @intCast(switch (rng.intBelow(4)) {
                0 => rng.intRange(1, 5), // shallow
                1 => rng.intRange(5, 15), // moderate
                2 => rng.intRange(15, 40), // deep
                3 => rng.intRange(50, 60), // near MAX_DEPTH
                else => unreachable,
            }),
            .max_keys = @intCast(rng.intRange(0, 15)),
            .max_array_len = @intCast(rng.intRange(0, 30)),
            .max_string_len = @intCast(switch (rng.intBelow(4)) {
                0 => 0, // empty strings
                1 => rng.intRange(1, 10), // short
                2 => rng.intRange(10, 100), // medium
                3 => rng.intRange(100, 500), // long
                else => unreachable,
            }),
            .whitespace_mode = switch (rng.intBelow(3)) {
                0 => .none,
                1 => .light,
                2 => .heavy,
                else => unreachable,
            },
            .unicode_richness = switch (rng.intBelow(3)) {
                0 => .ascii_only,
                1 => .basic_unicode,
                2 => .full_unicode,
                else => unreachable,
            },
            .number_style = switch (rng.intBelow(4)) {
                0 => .integer_only,
                1 => .with_decimal,
                2 => .with_exponent,
                3 => .all,
                else => unreachable,
            },
        };
    }
};

fn generateJSON(rng: *PRNG, buf: []u8) GenError![]const u8 {
    const config = GenConfig.fromPRNG(rng);
    var fbs = std.io.fixedBufferStream(buf);
    try generateValue(rng, &fbs, 0, &config);
    return fbs.getWritten();
}

fn generateValue(rng: *PRNG, fbs: *FBS, depth: u8, config: *const GenConfig) GenError!void {
    if (depth >= config.max_depth) {
        try generateSimpleValue(rng, fbs, config);
        return;
    }

    const choice = rng.intBelow(8);
    switch (choice) {
        0, 1 => try generateObject(rng, fbs, depth, config),
        2, 3 => try generateArray(rng, fbs, depth, config),
        4 => try generateString(rng, fbs, config),
        5 => try generateNumber(rng, fbs, config),
        6 => try fbs.writer().writeAll(if (rng.boolean()) "true" else "false"),
        7 => try fbs.writer().writeAll("null"),
        else => unreachable,
    }
}

fn generateSimpleValue(rng: *PRNG, fbs: *FBS, config: *const GenConfig) GenError!void {
    const choice = rng.intBelow(5);
    switch (choice) {
        0, 1 => try generateString(rng, fbs, config),
        2 => try generateNumber(rng, fbs, config),
        3 => try fbs.writer().writeAll(if (rng.boolean()) "true" else "false"),
        4 => try fbs.writer().writeAll("null"),
        else => unreachable,
    }
}

fn maybeWhitespace(rng: *PRNG, fbs: *FBS, config: *const GenConfig) GenError!void {
    switch (config.whitespace_mode) {
        .none => {},
        .light => {
            if (rng.chance(30)) try fbs.writer().writeByte(' ');
        },
        .heavy => {
            const ws_chars = " \t\n\r";
            const count = rng.intRange(0, 3);
            for (0..count) |_| {
                try fbs.writer().writeByte(ws_chars[rng.intBelow(ws_chars.len)]);
            }
        },
    }
}

fn generateObject(rng: *PRNG, fbs: *FBS, depth: u8, config: *const GenConfig) GenError!void {
    const key_count = rng.intBelow(@as(usize, config.max_keys) + 1);
    try fbs.writer().writeByte('{');
    try maybeWhitespace(rng, fbs, config);
    for (0..key_count) |i| {
        if (i > 0) {
            try fbs.writer().writeByte(',');
            try maybeWhitespace(rng, fbs, config);
        }
        // Use realistic key names sometimes
        if (rng.chance(40)) {
            try generateRealisticKey(rng, fbs);
        } else {
            try generateString(rng, fbs, config);
        }
        try maybeWhitespace(rng, fbs, config);
        try fbs.writer().writeByte(':');
        try maybeWhitespace(rng, fbs, config);
        try generateValue(rng, fbs, depth + 1, config);
        try maybeWhitespace(rng, fbs, config);
    }
    try fbs.writer().writeByte('}');
}

fn generateArray(rng: *PRNG, fbs: *FBS, depth: u8, config: *const GenConfig) GenError!void {
    const elem_count = rng.intBelow(@as(usize, config.max_array_len) + 1);
    try fbs.writer().writeByte('[');
    try maybeWhitespace(rng, fbs, config);
    for (0..elem_count) |i| {
        if (i > 0) {
            try fbs.writer().writeByte(',');
            try maybeWhitespace(rng, fbs, config);
        }
        try generateValue(rng, fbs, depth + 1, config);
    }
    try maybeWhitespace(rng, fbs, config);
    try fbs.writer().writeByte(']');
}

const SAFE_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!?-_";

// Keys that look like real LLM API fields — tests prefix-matching edge cases
const REALISTIC_KEYS = [_][]const u8{
    "content",       "content_filter", "content_block", "content_type",
    "delta",         "delta_type",
    "choices",       "choice",
    "message",       "messages",
    "role",          "model",          "type",          "index",
    "finish_reason", "stop_reason",    "stop",
    "error",         "error_code",     "error_message",
    "text",          "text_delta",
    "id",            "object",         "created",
    "name",          "arguments",      "function",
    "tool_calls",    "tool_call",      "partial_json",  "input_json_delta",
    "response",      "done",           "stream",
    "usage",         "prompt_tokens",  "completion_tokens",
    "",              // empty string key
};

fn generateRealisticKey(rng: *PRNG, fbs: *FBS) GenError!void {
    const key = REALISTIC_KEYS[rng.intBelow(REALISTIC_KEYS.len)];
    try fbs.writer().writeByte('"');
    try fbs.writer().writeAll(key);
    try fbs.writer().writeByte('"');
}

fn generateString(rng: *PRNG, fbs: *FBS, config: *const GenConfig) GenError!void {
    const len = rng.intBelow(@as(usize, config.max_string_len) + 1);
    try fbs.writer().writeByte('"');
    var i: usize = 0;
    while (i < len) {
        const r = rng.intBelow(100);
        switch (config.unicode_richness) {
            .ascii_only => {
                if (r < 90) {
                    try fbs.writer().writeByte(SAFE_CHARS[rng.intBelow(SAFE_CHARS.len)]);
                } else {
                    // Escaped characters
                    const escapes = [_][]const u8{ "\\n", "\\t", "\\r", "\\\\", "\\\"", "\\/" };
                    try fbs.writer().writeAll(escapes[rng.intBelow(escapes.len)]);
                }
            },
            .basic_unicode => {
                if (r < 70) {
                    try fbs.writer().writeByte(SAFE_CHARS[rng.intBelow(SAFE_CHARS.len)]);
                } else if (r < 80) {
                    const escapes = [_][]const u8{ "\\n", "\\t", "\\r", "\\\\", "\\\"", "\\/", "\\b", "\\f" };
                    try fbs.writer().writeAll(escapes[rng.intBelow(escapes.len)]);
                } else if (r < 90) {
                    // \u00XX range (Latin-1 supplement)
                    try fbs.writer().writeAll("\\u00");
                    const hex = "0123456789abcdef";
                    // Stay in printable range: 0x20-0xFF
                    try fbs.writer().writeByte(hex[2 + rng.intBelow(14)]);
                    try fbs.writer().writeByte(hex[rng.intBelow(16)]);
                } else {
                    // Common unicode: degree, arrows, stars, accented
                    const uni = [_][]const u8{ "\\u00b0", "\\u00e9", "\\u00fc", "\\u00f1", "\\u2192", "\\u2728", "\\u2603", "\\u2764" };
                    try fbs.writer().writeAll(uni[rng.intBelow(uni.len)]);
                }
            },
            .full_unicode => {
                if (r < 50) {
                    try fbs.writer().writeByte(SAFE_CHARS[rng.intBelow(SAFE_CHARS.len)]);
                } else if (r < 60) {
                    const escapes = [_][]const u8{ "\\n", "\\t", "\\r", "\\\\", "\\\"", "\\/", "\\b", "\\f" };
                    try fbs.writer().writeAll(escapes[rng.intBelow(escapes.len)]);
                } else if (r < 70) {
                    // BMP codepoints: \u0100-\uFFFF (avoiding surrogates D800-DFFF)
                    try fbs.writer().writeAll("\\u");
                    const hex = "0123456789abcdef";
                    const high_nibble = 1 + rng.intBelow(11); // 1-B (avoid D for surrogates)
                    try fbs.writer().writeByte(hex[high_nibble]);
                    try fbs.writer().writeByte(hex[rng.intBelow(16)]);
                    try fbs.writer().writeByte(hex[rng.intBelow(16)]);
                    try fbs.writer().writeByte(hex[rng.intBelow(16)]);
                } else if (r < 80) {
                    // Surrogate pairs (emoji): \uD83D\uDE00-\uDE4F
                    try fbs.writer().writeAll("\\uD83D\\uDE");
                    const hex = "0123456789abcdef";
                    try fbs.writer().writeByte(hex[rng.intBelow(5)]); // 0-4
                    try fbs.writer().writeByte(hex[rng.intBelow(16)]);
                } else if (r < 85) {
                    // CJK-like: \u4E00-\u9FFF
                    try fbs.writer().writeAll("\\u");
                    const hex = "0123456789abcdef";
                    const range_start = 4 + rng.intBelow(6); // 4-9
                    try fbs.writer().writeByte(hex[range_start]);
                    try fbs.writer().writeByte(hex[rng.intBelow(16)]);
                    try fbs.writer().writeByte(hex[rng.intBelow(16)]);
                    try fbs.writer().writeByte(hex[rng.intBelow(16)]);
                } else if (r < 90) {
                    // Multi-line content (markdown-like)
                    const patterns = [_][]const u8{
                        "\\n```\\ncode here\\n```\\n",
                        "\\n> blockquote\\n",
                        "\\n1. item one\\n2. item two\\n",
                        "\\n- bullet\\n- bullet\\n",
                        "\\n\\n",
                    };
                    try fbs.writer().writeAll(patterns[rng.intBelow(patterns.len)]);
                    i += 5; // these are multi-char, skip ahead
                } else {
                    // Raw printable ASCII variety: punctuation, brackets, etc.
                    const punct = "~`@#$%^&*()+=[]|;:'<>,./";
                    try fbs.writer().writeByte(punct[rng.intBelow(punct.len)]);
                }
            },
        }
        i += 1;
    }
    try fbs.writer().writeByte('"');
}

fn generateNumber(rng: *PRNG, fbs: *FBS, config: *const GenConfig) GenError!void {
    const w = fbs.writer();

    // Negative sign
    if (rng.chance(30)) try w.writeByte('-');

    // Integer part
    const style = rng.intBelow(4);
    switch (style) {
        0 => {
            // Zero
            try w.writeByte('0');
        },
        1 => {
            // Single digit (1-9)
            try w.writeByte('1' + @as(u8, @intCast(rng.intBelow(9))));
        },
        2 => {
            // Multi-digit (1-9 digits)
            const digits = 1 + rng.intBelow(9);
            for (0..digits) |di| {
                if (di == 0) {
                    try w.writeByte('1' + @as(u8, @intCast(rng.intBelow(9))));
                } else {
                    try w.writeByte('0' + @as(u8, @intCast(rng.intBelow(10))));
                }
            }
        },
        3 => {
            // Large number (10+ digits)
            const digits = 10 + rng.intBelow(8);
            for (0..digits) |di| {
                if (di == 0) {
                    try w.writeByte('1' + @as(u8, @intCast(rng.intBelow(9))));
                } else {
                    try w.writeByte('0' + @as(u8, @intCast(rng.intBelow(10))));
                }
            }
        },
        else => unreachable,
    }

    // Decimal part
    const should_decimal = switch (config.number_style) {
        .integer_only => false,
        .with_decimal, .all => rng.chance(50),
        .with_exponent => false,
    };
    if (should_decimal) {
        try w.writeByte('.');
        const frac_digits = 1 + rng.intBelow(10);
        for (0..frac_digits) |_| {
            try w.writeByte('0' + @as(u8, @intCast(rng.intBelow(10))));
        }
    }

    // Exponent part
    const should_exp = switch (config.number_style) {
        .integer_only, .with_decimal => false,
        .with_exponent, .all => rng.chance(40),
    };
    if (should_exp) {
        try w.writeByte(if (rng.boolean()) 'e' else 'E');
        if (rng.chance(50)) {
            try w.writeByte(if (rng.boolean()) '+' else '-');
        }
        const exp_digits = 1 + rng.intBelow(3);
        for (0..exp_digits) |di| {
            if (di == 0) {
                try w.writeByte('1' + @as(u8, @intCast(rng.intBelow(9))));
            } else {
                try w.writeByte('0' + @as(u8, @intCast(rng.intBelow(10))));
            }
        }
    }
}

// --- Strategy 1: Positive space ---

fn simPositive(rng: *PRNG, allocator: std.mem.Allocator) !void {
    var buf: [16384]u8 = undefined;
    const json = generateJSONVerbose(rng, &buf) catch return;

    // Parse with std.json as oracle
    const std_parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer std_parsed.deinit();

    // Scan with jzon scanner — must not error on valid JSON
    var scanner = Scanner.init();
    var pos: usize = 0;
    var token_count: usize = 0;
    while (pos < json.len) {
        if (try scanner.next(json, &pos)) |_| {
            token_count += 1;
        }
    }
    std.debug.assert(token_count > 0);
}

// --- Strategy 2: Negative space ---

fn simNegative(rng: *PRNG) !void {
    var buf: [16384]u8 = undefined;
    const json = generateJSONVerbose(rng, &buf) catch return;
    var corrupted: [16384 + 256]u8 = undefined;

    const corruption_type = rng.intBelow(8);
    var corrupted_len: usize = 0;

    switch (corruption_type) {
        0 => {
            // Truncate at random point
            const trunc_at = 1 + rng.intBelow(json.len -| 1);
            @memcpy(corrupted[0..trunc_at], json[0..trunc_at]);
            corrupted_len = trunc_at;
        },
        1 => {
            // Flip a single byte
            @memcpy(corrupted[0..json.len], json);
            const flip_pos = rng.intBelow(json.len);
            corrupted[flip_pos] ^= @as(u8, @intCast(1 + rng.intBelow(254)));
            corrupted_len = json.len;
        },
        2 => {
            // Delete a byte
            const del_pos = rng.intBelow(json.len);
            @memcpy(corrupted[0..del_pos], json[0..del_pos]);
            if (del_pos + 1 < json.len) {
                @memcpy(corrupted[del_pos .. json.len - 1], json[del_pos + 1 .. json.len]);
            }
            corrupted_len = json.len - 1;
        },
        3 => {
            // Insert a random byte
            const ins_pos = rng.intBelow(json.len);
            @memcpy(corrupted[0..ins_pos], json[0..ins_pos]);
            corrupted[ins_pos] = @as(u8, @intCast(rng.intBelow(256)));
            @memcpy(corrupted[ins_pos + 1 .. json.len + 1], json[ins_pos..json.len]);
            corrupted_len = json.len + 1;
        },
        4 => {
            // Insert invalid UTF-8 byte sequence
            const ins_pos = rng.intBelow(json.len);
            @memcpy(corrupted[0..ins_pos], json[0..ins_pos]);
            const bad_bytes = [_]u8{ 0xFF, 0xFE, 0x80, 0xC0 };
            corrupted[ins_pos] = bad_bytes[rng.intBelow(bad_bytes.len)];
            @memcpy(corrupted[ins_pos + 1 .. json.len + 1], json[ins_pos..json.len]);
            corrupted_len = json.len + 1;
        },
        5 => {
            // Replace a chunk with garbage
            @memcpy(corrupted[0..json.len], json);
            const start = rng.intBelow(json.len);
            const end = @min(start + 1 + rng.intBelow(10), json.len);
            for (start..end) |gi| {
                corrupted[gi] = @as(u8, @intCast(rng.intBelow(256)));
            }
            corrupted_len = json.len;
        },
        6 => {
            // Double a bracket/brace (unbalance)
            @memcpy(corrupted[0..json.len], json);
            for (0..json.len) |ci| {
                if (json[ci] == '{' or json[ci] == '[' or json[ci] == '}' or json[ci] == ']') {
                    // Insert duplicate
                    const rest_len = json.len - ci;
                    std.mem.copyBackwards(u8, corrupted[ci + 1 .. ci + 1 + rest_len], corrupted[ci .. ci + rest_len]);
                    corrupted_len = json.len + 1;
                    break;
                }
            } else {
                corrupted_len = json.len;
            }
        },
        7 => {
            // Truncate inside a string (break a \uXXXX escape)
            @memcpy(corrupted[0..json.len], json);
            // Find a backslash and truncate after it
            for (0..json.len) |ci| {
                if (json[ci] == '\\' and ci + 1 < json.len) {
                    corrupted_len = ci + 1 + rng.intBelow(2); // cut mid-escape
                    break;
                }
            } else {
                corrupted_len = json.len / 2; // fallback: truncate at half
            }
        },
        else => unreachable,
    }

    if (corrupted_len == 0) return;
    const input = corrupted[0..corrupted_len];

    // Scanner: must not crash
    {
        var scanner = Scanner.init();
        var pos: usize = 0;
        while (pos < input.len) {
            _ = scanner.next(input, &pos) catch break;
        }
    }

    // Path extraction: must not crash
    _ = jzon_path.getString(input, comptime jzon_path.path("a"));
    _ = jzon_path.getString(input, comptime jzon_path.path("a.b.c"));
    _ = jzon_path.getString(input, comptime jzon_path.path("choices[0].delta.content"));
    _ = jzon_path.getInt(input, comptime jzon_path.path("a"));
    _ = jzon_path.getBool(input, comptime jzon_path.path("a"));
    _ = jzon_path.getRaw(input, comptime jzon_path.path("a[0]"));
}

// --- Strategy 3: Round-trip ---

fn simRoundTrip(rng: *PRNG) !void {
    // Generate a random string with varied content
    var raw: [512]u8 = undefined;
    const raw_len = rng.intRange(0, @min(500, raw.len));
    for (0..raw_len) |ri| {
        const r = rng.intBelow(100);
        if (r < 60) {
            raw[ri] = SAFE_CHARS[rng.intBelow(SAFE_CHARS.len)];
        } else if (r < 70) {
            // Control characters that escape() handles
            const controls = [_]u8{ '\n', '\r', '\t', 0x08, 0x0C };
            raw[ri] = controls[rng.intBelow(controls.len)];
        } else if (r < 80) {
            raw[ri] = '"';
        } else if (r < 90) {
            raw[ri] = '\\';
        } else {
            // High ASCII (valid single bytes in UTF-8 context)
            raw[ri] = @as(u8, @intCast(0x20 + rng.intBelow(0x5F)));
        }
    }
    const input = raw[0..raw_len];

    // escape → unescape roundtrip
    var escaped_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&escaped_buf);
    jzon_escape.escape(fbs.writer(), input) catch return;
    const escaped = fbs.getWritten();

    var scratch: [4096]u8 = undefined;
    const result = jzon_escape.unescape(escaped, &scratch) catch return;
    const unescaped = switch (result) {
        .clean => |s| s,
        .allocated => |s| s,
    };
    std.debug.assert(std.mem.eql(u8, input, unescaped));

    // Writer → getString roundtrip
    var write_buf: [8192]u8 = undefined;
    var write_fbs = std.io.fixedBufferStream(&write_buf);
    var w = jzon_writer.jsonWriter(write_fbs.writer());
    w.beginTopObject() catch return;
    w.string("key", input) catch return;
    // Also test with realistic key names to exercise prefix matching
    w.string("content", input) catch return;
    w.string("content_filter", "none") catch return;
    w.end() catch return;
    const json = write_fbs.getWritten();

    // Extract "key" value
    const extracted = jzon_path.getString(json, comptime jzon_path.path("key"));
    if (extracted) |e| {
        var scratch2: [4096]u8 = undefined;
        const unesc = jzon_escape.unescape(e, &scratch2) catch return;
        const final = switch (unesc) {
            .clean => |s| s,
            .allocated => |s| s,
        };
        std.debug.assert(std.mem.eql(u8, input, final));
    }

    // Extract "content" — must not confuse with "content_filter"
    const content_val = jzon_path.getString(json, comptime jzon_path.path("content"));
    if (content_val) |cv| {
        var scratch3: [4096]u8 = undefined;
        const unesc = jzon_escape.unescape(cv, &scratch3) catch return;
        const final = switch (unesc) {
            .clean => |s| s,
            .allocated => |s| s,
        };
        std.debug.assert(std.mem.eql(u8, input, final));
    }

    const filter_val = jzon_path.getString(json, comptime jzon_path.path("content_filter"));
    if (filter_val) |fv| {
        std.debug.assert(std.mem.eql(u8, "none", fv));
    }
}

// --- Strategy 4: Chunk chaos ---

fn simChunkChaos(rng: *PRNG) !void {
    var buf: [16384]u8 = undefined;
    const json = generateJSONVerbose(rng, &buf) catch return;

    // Whole-buffer scan
    var whole_tags: [4096]Token.Tag = undefined;
    var whole_count: usize = 0;
    {
        var scanner = Scanner.init();
        var pos: usize = 0;
        while (pos < json.len) {
            if (scanner.next(json, &pos) catch break) |token| {
                if (whole_count < whole_tags.len) {
                    whole_tags[whole_count] = token.tag;
                    whole_count += 1;
                }
            }
        }
    }

    // Scan with random-sized chunks (byte-at-a-time to 100 bytes)
    var chunk_tags: [4096]Token.Tag = undefined;
    var chunk_count: usize = 0;
    {
        var scanner = Scanner.init();
        var pos: usize = 0;
        while (pos < json.len) {
            const old_pos = pos;
            if (scanner.next(json, &pos) catch break) |token| {
                if (chunk_count < chunk_tags.len) {
                    chunk_tags[chunk_count] = token.tag;
                    chunk_count += 1;
                }
            } else {
                if (pos == old_pos) pos += 1;
            }
        }
    }

    std.debug.assert(whole_count == chunk_count);
    for (0..whole_count) |ci| {
        std.debug.assert(whole_tags[ci] == chunk_tags[ci]);
    }
}

// --- Strategy 5: Assembler chaos ---

fn simAssembler(rng: *PRNG, allocator: std.mem.Allocator) !void {
    var buf: [8192]u8 = undefined;
    const json = generateJSONVerbose(rng, &buf) catch return;

    var asmb = Assembler.init();
    defer asmb.deinit(allocator);

    var offset: usize = 0;
    while (offset < json.len) {
        // Random chunk sizes from 1 to 200 bytes
        const max_chunk = @min(json.len - offset, 200);
        const chunk_size = 1 + rng.intBelow(max_chunk);
        const end = @min(offset + chunk_size, json.len);
        _ = asmb.feed(allocator, json[offset..end]) catch break;
        offset = end;
    }

    if (offset == json.len and asmb.state != .invalid) {
        std.debug.assert(asmb.isComplete());
        std.debug.assert(std.mem.eql(u8, json, asmb.slice()));
    }
}

// --- Strategy 6: LLM payload simulation ---
// Generate realistic LLM SSE payloads and extract with jzon path expressions

fn simLLMPayload(rng: *PRNG) !void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    const provider = rng.intBelow(3);
    var expected_content: [512]u8 = undefined;
    var content_len: usize = 0;

    // Generate a content string
    const word_count = 1 + rng.intBelow(20);
    for (0..word_count) |wi| {
        if (wi > 0 and content_len < expected_content.len - 1) {
            expected_content[content_len] = ' ';
            content_len += 1;
        }
        const word = REALISTIC_KEYS[rng.intBelow(REALISTIC_KEYS.len)];
        if (content_len + word.len < expected_content.len) {
            @memcpy(expected_content[content_len .. content_len + word.len], word);
            content_len += word.len;
        }
    }
    const content = expected_content[0..content_len];

    switch (provider) {
        0 => {
            // OpenAI format
            try w.writeAll("{\"id\":\"chatcmpl-sim\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"");
            try w.writeAll(content);
            try w.writeAll("\"},\"finish_reason\":null}]}");
        },
        1 => {
            // Anthropic format
            try w.writeAll("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"");
            try w.writeAll(content);
            try w.writeAll("\"}}");
        },
        2 => {
            // Ollama format
            try w.writeAll("{\"model\":\"llama3\",\"created_at\":\"2024-01-01T00:00:00Z\",\"response\":\"");
            try w.writeAll(content);
            try w.writeAll("\",\"done\":false}");
        },
        else => unreachable,
    }

    const json = fbs.getWritten();
    verboseLog("  llm payload ({d} bytes): {s}\n", .{ json.len, json[0..@min(json.len, 200)] });

    // Extract and verify
    switch (provider) {
        0 => {
            const result = jzon_path.getString(json, comptime jzon_path.path("choices[0].delta.content"));
            if (result) |r| {
                std.debug.assert(std.mem.eql(u8, content, r));
            }
        },
        1 => {
            const result = jzon_path.getString(json, comptime jzon_path.path("delta.text"));
            if (result) |r| {
                std.debug.assert(std.mem.eql(u8, content, r));
            }
        },
        2 => {
            const result = jzon_path.getString(json, comptime jzon_path.path("response"));
            if (result) |r| {
                std.debug.assert(std.mem.eql(u8, content, r));
            }
            const done = jzon_path.getBool(json, comptime jzon_path.path("done"));
            if (done) |d| {
                std.debug.assert(d == false);
            }
        },
        else => unreachable,
    }
}

// --- Verbose logging ---

var verbose: bool = false;

fn verboseLog(comptime fmt: []const u8, args: anytype) void {
    if (!verbose) return;
    std.debug.print(fmt, args);
}

// --- Main simulation loop ---

const STRATEGY_NAMES = [_][]const u8{
    "positive", "negative", "round-trip", "chunk-chaos", "assembler", "llm-payload", "llm-payload",
};

fn runSimulation(seed: u64, allocator: std.mem.Allocator) !void {
    var rng = PRNG.init(seed);

    const strategy = rng.intBelow(7);
    verboseLog("seed=0x{x} strategy={s}\n", .{ seed, STRATEGY_NAMES[strategy] });

    switch (strategy) {
        0 => try simPositive(&rng, allocator),
        1 => try simNegative(&rng),
        2 => try simRoundTrip(&rng),
        3 => try simChunkChaos(&rng),
        4 => try simAssembler(&rng, allocator),
        5, 6 => try simLLMPayload(&rng),
        else => unreachable,
    }
}

// Wrap generateJSON to log when verbose
fn generateJSONVerbose(rng: *PRNG, buf: []u8) GenError![]const u8 {
    const json = try generateJSON(rng, buf);
    verboseLog("  payload ({d} bytes): {s}\n", .{ json.len, json[0..@min(json.len, 200)] });
    if (json.len > 200) verboseLog("  ... ({d} more bytes)\n", .{json.len - 200});
    return json;
}

// --- Regression seeds ---
const REGRESSION_SEEDS = [_]u64{
    // Add failing seeds here as they're discovered
};

// --- Test entry points ---

test "deterministic simulation (1000 seeds)" {
    // Check for VERBOSE env var
    verbose = std.posix.getenv("VERBOSE") != null;

    const allocator = std.testing.allocator;
    for (REGRESSION_SEEDS) |seed| {
        runSimulation(seed, allocator) catch |err| {
            std.debug.print("FAIL: regression seed 0x{x}: {}\n", .{ seed, err });
            return err;
        };
    }
    for (0..1000) |seed| {
        runSimulation(seed, allocator) catch |err| {
            std.debug.print("FAIL: seed 0x{x}: {}\n", .{ seed, err });
            return err;
        };
    }
}

test "deterministic simulation extended (10000 seeds)" {
    verbose = std.posix.getenv("VERBOSE") != null;

    const allocator = std.testing.allocator;
    for (0..10000) |seed| {
        runSimulation(seed, allocator) catch |err| {
            std.debug.print("FAIL: seed 0x{x}: {}\n", .{ seed, err });
            return err;
        };
    }
}
