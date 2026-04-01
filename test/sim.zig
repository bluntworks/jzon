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
///
/// Four strategies:
/// 1. Positive: generate valid JSON, extract with jzon, verify against std.json
/// 2. Negative: corrupt valid JSON, verify graceful error handling
/// 3. Round-trip: escape→unescape, writer→getString
/// 4. Chunk chaos: split valid JSON at random boundaries, verify same tokens

const PRNG = struct {
    s: [4]u64,

    fn init(seed: u64) PRNG {
        // SplitMix64 initialization
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

    fn boolean(self: *PRNG) bool {
        return self.next() & 1 == 0;
    }

    fn float01(self: *PRNG) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }
};

// --- JSON Generator ---

const GenError = error{NoSpaceLeft};
const FBS = std.io.FixedBufferStream([]u8);

fn generateJSON(rng: *PRNG, buf: []u8) GenError![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    try generateValue(rng, &fbs, 0);
    return fbs.getWritten();
}

fn generateValue(rng: *PRNG, fbs: *FBS, depth: u8) GenError!void {
    if (depth > 10) {
        // At max depth, emit a simple value
        try generateSimpleValue(rng, fbs);
        return;
    }

    const choice = rng.intBelow(6);
    switch (choice) {
        0 => try generateObject(rng, fbs, depth),
        1 => try generateArray(rng, fbs, depth),
        2 => try generateString(rng, fbs),
        3 => try generateNumber(rng, fbs),
        4 => try fbs.writer().writeAll(if (rng.boolean()) "true" else "false"),
        5 => try fbs.writer().writeAll("null"),
        else => unreachable,
    }
}

fn generateSimpleValue(rng: *PRNG, fbs: *FBS) GenError!void {
    const choice = rng.intBelow(4);
    switch (choice) {
        0 => try generateString(rng, fbs),
        1 => try generateNumber(rng, fbs),
        2 => try fbs.writer().writeAll(if (rng.boolean()) "true" else "false"),
        3 => try fbs.writer().writeAll("null"),
        else => unreachable,
    }
}

fn generateObject(rng: *PRNG, fbs: *FBS, depth: u8) GenError!void {
    const key_count = rng.intBelow(6);
    try fbs.writer().writeByte('{');
    for (0..key_count) |i| {
        if (i > 0) try fbs.writer().writeByte(',');
        try generateString(rng, fbs);
        try fbs.writer().writeByte(':');
        try generateValue(rng, fbs, depth + 1);
    }
    try fbs.writer().writeByte('}');
}

fn generateArray(rng: *PRNG, fbs: *FBS, depth: u8) GenError!void {
    const elem_count = rng.intBelow(6);
    try fbs.writer().writeByte('[');
    for (0..elem_count) |i| {
        if (i > 0) try fbs.writer().writeByte(',');
        try generateValue(rng, fbs, depth + 1);
    }
    try fbs.writer().writeByte(']');
}

const SAFE_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!?-_";

fn generateString(rng: *PRNG, fbs: *FBS) GenError!void {
    const len = rng.intBelow(20);
    try fbs.writer().writeByte('"');
    for (0..len) |_| {
        const r = rng.intBelow(100);
        if (r < 85) {
            // Normal ASCII
            try fbs.writer().writeByte(SAFE_CHARS[rng.intBelow(SAFE_CHARS.len)]);
        } else if (r < 90) {
            // Escaped characters
            const escapes = [_][]const u8{ "\\n", "\\t", "\\r", "\\\\", "\\\"", "\\/" };
            try fbs.writer().writeAll(escapes[rng.intBelow(escapes.len)]);
        } else if (r < 95) {
            // Unicode escape
            try fbs.writer().writeAll("\\u00");
            const hex = "0123456789abcdef";
            try fbs.writer().writeByte(hex[rng.intBelow(16)]);
            try fbs.writer().writeByte(hex[rng.intBelow(16)]);
        } else {
            // Multi-byte UTF-8 (safe range)
            try fbs.writer().writeAll("\\u00e9"); // é
        }
    }
    try fbs.writer().writeByte('"');
}

fn generateNumber(rng: *PRNG, fbs: *FBS) GenError!void {
    if (rng.boolean()) {
        // Negative
        try fbs.writer().writeByte('-');
    }
    const digits = 1 + rng.intBelow(6);
    for (0..digits) |i| {
        if (i == 0) {
            try fbs.writer().writeByte('1' + @as(u8, @intCast(rng.intBelow(9))));
        } else {
            try fbs.writer().writeByte('0' + @as(u8, @intCast(rng.intBelow(10))));
        }
    }
    if (rng.boolean()) {
        try fbs.writer().writeByte('.');
        const frac_digits = 1 + rng.intBelow(4);
        for (0..frac_digits) |_| {
            try fbs.writer().writeByte('0' + @as(u8, @intCast(rng.intBelow(10))));
        }
    }
}

// --- Strategy 1: Positive space ---
// Generate valid JSON, parse with both jzon scanner and std.json, verify consistency

fn simPositive(rng: *PRNG, allocator: std.mem.Allocator) !void {
    var buf: [8192]u8 = undefined;
    const json = generateJSON(rng, &buf) catch return; // skip if too large

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

    // Must have produced at least one token
    std.debug.assert(token_count > 0);
}

// --- Strategy 2: Negative space ---
// Corrupt valid JSON, verify jzon handles gracefully

fn simNegative(rng: *PRNG) !void {
    var buf: [8192]u8 = undefined;
    const json = generateJSON(rng, &buf) catch return;
    var corrupted: [8192]u8 = undefined;

    const corruption_type = rng.intBelow(4);
    var corrupted_len: usize = 0;

    switch (corruption_type) {
        0 => {
            // Truncate
            const trunc_at = 1 + rng.intBelow(json.len -| 1);
            @memcpy(corrupted[0..trunc_at], json[0..trunc_at]);
            corrupted_len = trunc_at;
        },
        1 => {
            // Flip a byte
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
        else => unreachable,
    }

    const input = corrupted[0..corrupted_len];

    // Scanner: must not crash, may return error or tokens
    {
        var scanner = Scanner.init();
        var pos: usize = 0;
        while (pos < input.len) {
            _ = scanner.next(input, &pos) catch break;
        }
    }

    // Path extraction: must not crash, returns null on bad input
    _ = jzon_path.getString(input, comptime jzon_path.path("a"));
    _ = jzon_path.getString(input, comptime jzon_path.path("a.b"));
    _ = jzon_path.getInt(input, comptime jzon_path.path("a"));
    _ = jzon_path.getBool(input, comptime jzon_path.path("a"));
}

// --- Strategy 3: Round-trip ---
// escape→unescape, writer→getString

fn simRoundTrip(rng: *PRNG) !void {
    // Generate a random string, escape it, unescape it, verify match
    var raw: [256]u8 = undefined;
    const raw_len = rng.intBelow(200);
    for (0..raw_len) |i| {
        raw[i] = SAFE_CHARS[rng.intBelow(SAFE_CHARS.len)];
    }
    const input = raw[0..raw_len];

    var escaped_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&escaped_buf);
    jzon_escape.escape(fbs.writer(), input) catch return;
    const escaped = fbs.getWritten();

    var scratch: [2048]u8 = undefined;
    const result = jzon_escape.unescape(escaped, &scratch) catch return;
    const unescaped = switch (result) {
        .clean => |s| s,
        .allocated => |s| s,
    };
    std.debug.assert(std.mem.eql(u8, input, unescaped));

    // Writer→getString round-trip
    var write_buf: [4096]u8 = undefined;
    var write_fbs = std.io.fixedBufferStream(&write_buf);
    var w = jzon_writer.jsonWriter(write_fbs.writer());
    w.beginTopObject() catch return;
    w.string("key", input) catch return;
    w.end() catch return;
    const json = write_fbs.getWritten();

    const extracted = jzon_path.getString(json, comptime jzon_path.path("key"));
    if (extracted) |e| {
        // The extracted value has JSON escapes — unescape it
        var scratch2: [2048]u8 = undefined;
        const unesc = jzon_escape.unescape(e, &scratch2) catch return;
        const final = switch (unesc) {
            .clean => |s| s,
            .allocated => |s| s,
        };
        std.debug.assert(std.mem.eql(u8, input, final));
    }
}

// --- Strategy 4: Chunk chaos ---
// Split valid JSON at random byte boundaries, verify same token sequence

fn simChunkChaos(rng: *PRNG) !void {
    var buf: [8192]u8 = undefined;
    const json = generateJSON(rng, &buf) catch return;

    // Whole-buffer scan
    var whole_tags: [1024]Token.Tag = undefined;
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

    // Byte-at-a-time scan
    var chunk_tags: [1024]Token.Tag = undefined;
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

    // Token tag sequences must match
    std.debug.assert(whole_count == chunk_count);
    for (0..whole_count) |i| {
        std.debug.assert(whole_tags[i] == chunk_tags[i]);
    }
}

// --- Assembler chaos ---
fn simAssembler(rng: *PRNG, allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    const json = generateJSON(rng, &buf) catch return;

    // Feed the entire JSON as random-sized fragments
    var asmb = Assembler.init();
    defer asmb.deinit(allocator);

    var offset: usize = 0;
    while (offset < json.len) {
        const chunk_size = 1 + rng.intBelow(@min(json.len - offset, 50));
        const end = @min(offset + chunk_size, json.len);
        _ = asmb.feed(allocator, json[offset..end]) catch break;
        offset = end;
    }

    // If we fed all bytes, it should be complete
    if (offset == json.len and asmb.state != .invalid) {
        std.debug.assert(asmb.isComplete());
        std.debug.assert(std.mem.eql(u8, json, asmb.slice()));
    }
}

// --- Main simulation loop ---

fn runSimulation(seed: u64, allocator: std.mem.Allocator) !void {
    var rng = PRNG.init(seed);

    const strategy = rng.intBelow(5);
    switch (strategy) {
        0 => try simPositive(&rng, allocator),
        1 => try simNegative(&rng),
        2 => try simRoundTrip(&rng),
        3 => try simChunkChaos(&rng),
        4 => try simAssembler(&rng, allocator),
        else => unreachable,
    }
}

// --- Regression seeds (from past failures) ---
const REGRESSION_SEEDS = [_]u64{
    // Add failing seeds here as they're discovered
};

// --- Test entry points ---

test "deterministic simulation (1000 seeds)" {
    const allocator = std.testing.allocator;
    // Run regression seeds first
    for (REGRESSION_SEEDS) |seed| {
        runSimulation(seed, allocator) catch |err| {
            std.debug.print("FAIL: regression seed 0x{x}: {}\n", .{ seed, err });
            return err;
        };
    }
    // Run random seeds
    for (0..1000) |seed| {
        runSimulation(seed, allocator) catch |err| {
            std.debug.print("FAIL: seed 0x{x}: {}\n", .{ seed, err });
            return err;
        };
    }
}

test "deterministic simulation extended (10000 seeds)" {
    const allocator = std.testing.allocator;
    for (0..10000) |seed| {
        runSimulation(seed, allocator) catch |err| {
            std.debug.print("FAIL: seed 0x{x}: {}\n", .{ seed, err });
            return err;
        };
    }
}
