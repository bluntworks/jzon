const std = @import("std");

pub const MAX_DEPTH = 64;

pub const Token = struct {
    tag: Tag,
    /// For string/number tokens, the raw bytes (without quotes for strings).
    /// Points into the input slice.
    bytes: ?[]const u8 = null,
    depth: u8 = 0,

    pub const Tag = enum {
        object_begin,
        object_end,
        array_begin,
        array_end,
        string,
        number,
        true_literal,
        false_literal,
        null_literal,
    };
};

pub const Error = error{
    UnexpectedToken,
    MaxDepthExceeded,
    UnexpectedEndOfInput,
    InvalidNumber,
    InvalidEscape,
    InvalidLiteral,
};

pub const Scanner = struct {
    state: State = .value,
    depth: u8 = 0,
    nesting_stack: [MAX_DEPTH]Container = undefined,

    // String tracking
    string_start: usize = 0,
    after_string: AfterString = .post_value,

    // Number tracking
    number_start: usize = 0,

    // Literal tracking
    literal_expected: []const u8 = "",
    literal_index: u8 = 0,
    literal_tag: Token.Tag = .null_literal,

    const Container = enum { object, array };
    const AfterString = enum { object_colon, post_value, done };

    const State = enum {
        value,
        object_start,
        object_key,
        object_colon,
        object_value,
        array_start,
        array_elem,
        string,
        string_escape,
        number,
        literal,
        post_value,
        done,
    };

    pub fn init() Scanner {
        return .{};
    }

    pub fn next(self: *Scanner, input: []const u8, pos: *usize) Error!?Token {
        while (pos.* < input.len) {
            const c = input[pos.*];

            // Handle continuation states first
            switch (self.state) {
                .string, .string_escape => return self.continueString(input, pos),
                .number => return self.continueNumber(input, pos),
                .literal => return self.continueLiteral(input, pos),
                else => {},
            }

            // Skip whitespace
            switch (c) {
                ' ', '\t', '\n', '\r' => {
                    pos.* += 1;
                    continue;
                },
                else => {},
            }

            pos.* += 1;

            switch (self.state) {
                .value => return self.startValue(c, .done, input, pos),
                .object_value, .array_elem => return self.startValue(c, .post_value, input, pos),
                .object_start => switch (c) {
                    '}' => return self.popContainer(),
                    '"' => return self.beginString(pos.*, .object_colon, input, pos),
                    else => return error.UnexpectedToken,
                },
                .object_key => switch (c) {
                    '"' => return self.beginString(pos.*, .object_colon, input, pos),
                    else => return error.UnexpectedToken,
                },
                .object_colon => switch (c) {
                    ':' => {
                        self.state = .object_value;
                        continue;
                    },
                    else => return error.UnexpectedToken,
                },
                .array_start => switch (c) {
                    ']' => return self.popContainer(),
                    else => return self.startValue(c, .post_value, input, pos),
                },
                .post_value => return self.handlePostValue(c),
                .done => return error.UnexpectedToken,
                .string, .string_escape, .number, .literal => unreachable,
            }
        }
        return null;
    }

    fn startValue(self: *Scanner, c: u8, after_str: AfterString, input: []const u8, pos: *usize) Error!?Token {
        // For values inside containers, after_string should be .post_value
        // For top-level values, after_string should be .done
        const after = if (self.depth == 0) AfterString.done else after_str;
        switch (c) {
            '{' => return try self.pushObject(),
            '[' => return try self.pushArray(),
            '"' => return self.beginString(pos.*, after, input, pos),
            '-', '0'...'9' => {
                self.number_start = pos.* - 1;
                self.state = .number;
                return self.continueNumber(input, pos);
            },
            't' => return self.beginLiteral("true", .true_literal, input, pos),
            'f' => return self.beginLiteral("false", .false_literal, input, pos),
            'n' => return self.beginLiteral("null", .null_literal, input, pos),
            else => return error.UnexpectedToken,
        }
    }

    fn beginString(self: *Scanner, start: usize, after: AfterString, input: []const u8, pos: *usize) Error!?Token {
        self.string_start = start;
        self.after_string = after;
        self.state = .string;
        return self.continueString(input, pos);
    }

    fn beginLiteral(self: *Scanner, expected: []const u8, tag: Token.Tag, input: []const u8, pos: *usize) Error!?Token {
        self.literal_expected = expected;
        self.literal_index = 1;
        self.literal_tag = tag;
        self.state = .literal;
        return self.continueLiteral(input, pos);
    }

    fn continueString(self: *Scanner, input: []const u8, pos: *usize) Error!?Token {
        while (pos.* < input.len) {
            const c = input[pos.*];
            pos.* += 1;

            if (self.state == .string_escape) {
                switch (c) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u' => {
                        self.state = .string;
                        continue;
                    },
                    else => return error.InvalidEscape,
                }
            }

            switch (c) {
                '"' => {
                    const bytes = input[self.string_start .. pos.* - 1];
                    self.state = switch (self.after_string) {
                        .object_colon => .object_colon,
                        .post_value => .post_value,
                        .done => .done,
                    };
                    return Token{ .tag = .string, .bytes = bytes, .depth = self.depth };
                },
                '\\' => {
                    self.state = .string_escape;
                    continue;
                },
                0x00...0x1F => return error.UnexpectedToken,
                else => continue,
            }
        }
        return null;
    }

    fn continueNumber(self: *Scanner, input: []const u8, pos: *usize) Error!?Token {
        while (pos.* < input.len) {
            const c = input[pos.*];
            switch (c) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {
                    pos.* += 1;
                    continue;
                },
                else => {
                    const bytes = input[self.number_start..pos.*];
                    self.state = if (self.depth == 0) .done else .post_value;
                    return Token{ .tag = .number, .bytes = bytes, .depth = self.depth };
                },
            }
        }
        // At end of input, emit what we have
        const bytes = input[self.number_start..pos.*];
        self.state = if (self.depth == 0) .done else .post_value;
        return Token{ .tag = .number, .bytes = bytes, .depth = self.depth };
    }

    fn continueLiteral(self: *Scanner, input: []const u8, pos: *usize) Error!?Token {
        while (pos.* < input.len) {
            if (self.literal_index >= self.literal_expected.len) {
                self.state = if (self.depth == 0) .done else .post_value;
                return Token{ .tag = self.literal_tag, .depth = self.depth };
            }
            if (input[pos.*] != self.literal_expected[self.literal_index]) {
                return error.InvalidLiteral;
            }
            self.literal_index += 1;
            pos.* += 1;
        }
        if (self.literal_index >= self.literal_expected.len) {
            self.state = if (self.depth == 0) .done else .post_value;
            return Token{ .tag = self.literal_tag, .depth = self.depth };
        }
        return null;
    }

    fn handlePostValue(self: *Scanner, c: u8) Error!?Token {
        if (self.depth == 0) return error.UnexpectedToken;
        const container = self.nesting_stack[self.depth - 1];
        switch (c) {
            ',' => {
                self.state = if (container == .object) .object_key else .array_elem;
                return null;
            },
            '}' => {
                if (container != .object) return error.UnexpectedToken;
                return self.popContainer();
            },
            ']' => {
                if (container != .array) return error.UnexpectedToken;
                return self.popContainer();
            },
            else => return error.UnexpectedToken,
        }
    }

    fn pushObject(self: *Scanner) Error!Token {
        if (self.depth >= MAX_DEPTH) return error.MaxDepthExceeded;
        self.nesting_stack[self.depth] = .object;
        self.depth += 1;
        self.state = .object_start;
        return Token{ .tag = .object_begin, .depth = self.depth };
    }

    fn pushArray(self: *Scanner) Error!Token {
        if (self.depth >= MAX_DEPTH) return error.MaxDepthExceeded;
        self.nesting_stack[self.depth] = .array;
        self.depth += 1;
        self.state = .array_start;
        return Token{ .tag = .array_begin, .depth = self.depth };
    }

    fn popContainer(self: *Scanner) Token {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        const tag: Token.Tag = if (self.nesting_stack[self.depth] == .object) .object_end else .array_end;
        self.state = if (self.depth == 0) .done else .post_value;
        return Token{ .tag = tag, .depth = self.depth };
    }

    comptime {
        std.debug.assert(MAX_DEPTH <= std.math.maxInt(u8));
        std.debug.assert(@sizeOf(Scanner) <= 256);
    }
};

// --- Tests ---

fn collectTokens(input: []const u8) !std.ArrayListUnmanaged(Token) {
    var scanner = Scanner.init();
    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    var pos: usize = 0;
    while (true) {
        if (try scanner.next(input, &pos)) |token| {
            try tokens.append(std.testing.allocator, token);
        } else {
            if (pos >= input.len) break;
        }
    }
    return tokens;
}

fn expectTags(tokens: []const Token, expected: []const Token.Tag) !void {
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |tag, i| {
        try std.testing.expectEqual(tag, tokens[i].tag);
    }
}

test "scanner emits object_begin and object_end for empty object" {
    var tokens = try collectTokens("{}");
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{ .object_begin, .object_end });
}

test "scanner emits tokens for key-value pair" {
    var tokens = try collectTokens(
        \\{"key":"value"}
    );
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{ .object_begin, .string, .string, .object_end });
    try std.testing.expectEqualStrings("key", tokens.items[1].bytes.?);
    try std.testing.expectEqualStrings("value", tokens.items[2].bytes.?);
}

test "scanner handles numbers" {
    var tokens = try collectTokens(
        \\{"n":42}
    );
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{ .object_begin, .string, .number, .object_end });
    try std.testing.expectEqualStrings("42", tokens.items[2].bytes.?);
}

test "scanner handles negative and decimal numbers" {
    var tokens = try collectTokens(
        \\{"v":-3.14}
    );
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("-3.14", tokens.items[2].bytes.?);
}

test "scanner handles true false null" {
    var tokens = try collectTokens(
        \\{"a":true,"b":false,"c":null}
    );
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{
        .object_begin,
        .string, .true_literal,
        .string, .false_literal,
        .string, .null_literal,
        .object_end,
    });
}

test "scanner handles arrays" {
    var tokens = try collectTokens("[1,2,3]");
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{ .array_begin, .number, .number, .number, .array_end });
}

test "scanner handles empty array" {
    var tokens = try collectTokens("[]");
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{ .array_begin, .array_end });
}

test "scanner handles nested objects" {
    var tokens = try collectTokens(
        \\{"a":{"b":1}}
    );
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{
        .object_begin, .string, .object_begin, .string, .number, .object_end, .object_end,
    });
    try std.testing.expectEqual(@as(u8, 1), tokens.items[0].depth);
    try std.testing.expectEqual(@as(u8, 2), tokens.items[2].depth);
}

test "scanner handles whitespace" {
    var tokens = try collectTokens(
        \\  {  "key"  :  "value"  }
    );
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{ .object_begin, .string, .string, .object_end });
}

test "scanner handles string with escapes" {
    var tokens = try collectTokens(
        \\{"k":"hello \"world\""}
    );
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello \\\"world\\\"", tokens.items[2].bytes.?);
}

test "scanner returns error for unexpected token" {
    var scanner = Scanner.init();
    var pos: usize = 0;
    const input = "{x}";
    // '{' produces object_begin
    const tok = try scanner.next(input, &pos);
    try std.testing.expectEqual(Token.Tag.object_begin, tok.?.tag);
    // 'x' should produce error
    try std.testing.expectError(error.UnexpectedToken, scanner.next(input, &pos));
}

test "scanner tracks depth correctly" {
    var tokens = try collectTokens(
        \\{"a":[{"b":1}]}
    );
    defer tokens.deinit(std.testing.allocator);
    // {=1 "a"=1 [=2 {=3 "b"=3 1=3 }=2 ]=1 }=0
    try std.testing.expectEqual(@as(u8, 1), tokens.items[0].depth); // outer {
    try std.testing.expectEqual(@as(u8, 2), tokens.items[2].depth); // [
    try std.testing.expectEqual(@as(u8, 3), tokens.items[3].depth); // inner {
    try std.testing.expectEqual(@as(u8, 2), tokens.items[6].depth); // inner }
    try std.testing.expectEqual(@as(u8, 1), tokens.items[7].depth); // ]
    try std.testing.expectEqual(@as(u8, 0), tokens.items[8].depth); // outer }
}

test "scanner handles array of strings" {
    var tokens = try collectTokens(
        \\["a","b","c"]
    );
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{ .array_begin, .string, .string, .string, .array_end });
}

test "scanner handles mixed array values" {
    var tokens = try collectTokens(
        \\[1,"two",true,null]
    );
    defer tokens.deinit(std.testing.allocator);
    try expectTags(tokens.items, &.{ .array_begin, .number, .string, .true_literal, .null_literal, .array_end });
}

// --- Fuzz tests ---

test "fuzz scanner never crashes on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var input_buf: [4096]u8 = undefined;
            const len = smith.sliceWithHash(&input_buf, 0);
            const input = input_buf[0..len];
            var scanner = Scanner.init();
            var pos: usize = 0;
            while (pos < input.len) {
                _ = scanner.next(input, &pos) catch break;
            }
        }
    }.f, .{});
}

// --- Scanner idempotence: byte-at-a-time must produce same tags as whole-buffer ---

test "scanner produces same tokens regardless of chunk boundaries" {
    const cases = [_][]const u8{
        \\{"a":1,"b":[true,null],"c":{"d":"e"}}
        ,
        \\[1,"two",false,{"nested":[3,4]}]
        ,
        \\{"escape":"hello \"world\"\nnewline"}
        ,
    };

    for (cases) |json| {
        // Whole buffer
        var whole = try collectTokens(json);
        defer whole.deinit(std.testing.allocator);

        // Byte-at-a-time
        var scanner = Scanner.init();
        var byte_tokens: std.ArrayListUnmanaged(Token.Tag) = .empty;
        defer byte_tokens.deinit(std.testing.allocator);
        var pos: usize = 0;
        while (pos < json.len) {
            const old_pos = pos;
            if (scanner.next(json, &pos) catch break) |token| {
                try byte_tokens.append(std.testing.allocator, token.tag);
            } else {
                // If pos didn't advance and we got null, move forward to avoid infinite loop
                if (pos == old_pos) pos += 1;
            }
        }

        // Tags must match
        try std.testing.expectEqual(whole.items.len, byte_tokens.items.len);
        for (whole.items, 0..) |token, i| {
            try std.testing.expectEqual(token.tag, byte_tokens.items[i]);
        }
    }
}
